import 'dart:convert';

import 'package:drift/drift.dart';
import '../../core/constants/personal_spool_policy.dart';

import '../models/rfid_tag_identity.dart';
import 'database.dart';

/// Complete AMS identifiers are retained. A matching four-byte prefix only
/// suggests a confirmation; it is never an automatic UID conversion.
class PersonalAmsIdentity {
  const PersonalAmsIdentity({
    required this.reportedUid,
    required this.tagUid,
    this.history = const [],
    this.candidates = const [],
    this.requiresConfirmation = false,
    this.aliasOwner,
    this.stockCandidates = const [],
    this.sourceTagUids = const {},
  });

  final String reportedUid;
  final String tagUid;
  final List<RfidSpoolBinding> history;
  final List<RfidSpoolBinding> candidates;
  final bool requiresConfirmation;
  final String? aliasOwner;
  final List<PersonalAmsStockCandidate> stockCandidates;
  final Set<String> sourceTagUids;

  bool get isPersonalTag =>
      history.any((b) => isConsumableRfidTagType(b.tagType)) ||
      sourceTagUids.isNotEmpty;

  int? get currentConsumableId {
    final active = history.where((b) => b.isActive).toList();
    if (active.length != 1) return null;
    final current = active.single;
    if (!isConsumableRfidTagType(current.tagType) ||
        history.any((b) => b.cycle > current.cycle) ||
        history
                .where((b) => b.cycle == current.cycle && b.status != 'retired')
                .length !=
            1) {
      return null;
    }
    return current.consumableId;
  }

  /// Unconfirmed candidates participate only in collision rejection.
  Set<String> get collisionKeys => {
    if (tagUid.isNotEmpty) tagUid.toLowerCase(),
    if (requiresConfirmation)
      for (final candidate in candidates) candidate.tagUid.toLowerCase(),
    if (requiresConfirmation)
      for (final source in sourceTagUids) source.toLowerCase(),
  };
}

/// An already received physical spool that the user may explicitly choose.
/// This is not a current RFID binding and never participates in auto-bind.
class PersonalAmsStockCandidate {
  const PersonalAmsStockCandidate({
    required this.consumableId,
    required this.inventoryUid,
    required this.tagUid,
    required this.tagType,
    required this.ownerAccount,
  });
  final int consumableId;
  final String inventoryUid;
  final String tagUid;
  final String tagType;
  final String ownerAccount;
}

class PersonalAmsIdentityResolver {
  PersonalAmsIdentityResolver._(
    this._bindings,
    this._aliases,
    this._stock,
    this._sourceCards,
  );

  final List<({String owner, RfidSpoolBinding binding})> _bindings;
  final List<QueryRow> _aliases;
  final List<PersonalAmsStockCandidate> _stock;
  final List<({String owner, String tag})> _sourceCards;

  /// One inventory/alias snapshot per AMS update, not one full inventory scan
  /// per slot or historical cycle.
  /// Loads either a global integrity snapshot or the inventory visible to one
  /// personal account. Passing null keeps the global mode used by collision
  /// and migration checks. A non-null owner includes that owner and anonymous
  /// local rows, matching the personal inventory picker.
  static Future<PersonalAmsIdentityResolver> load(
    AppDatabase db, {
    String? ownerAccount,
  }) async {
    final scopedOwner = ownerAccount?.trim().toLowerCase();
    bool ownerVisible(String? value) {
      if (scopedOwner == null) return true;
      final stored = _ownerKey(value);
      return stored.isEmpty || stored == scopedOwner;
    }

    final rows = await db
        .customSelect(
          'SELECT id, uid, owner_account, rfid_tag_uid, rfid_tag_type, rfid_tag_cycle, '
          'lifecycle_status, previous_consumable_uid FROM consumables '
          "WHERE inventory_scope = 'personal' AND coalesce(trim(rfid_tag_uid), '') != '' "
          'ORDER BY rfid_tag_cycle DESC, updated_at DESC, id DESC',
        )
        .get();
    final aliases =
        (await db.customSelect('SELECT * FROM personal_ams_uid_aliases').get())
            .where((row) => ownerVisible(row.read<String>('owner_account')))
            .toList(growable: false);
    final stock = <PersonalAmsStockCandidate>[];
    final sourceCards = <({String owner, String tag})>[];
    if (db.schemaVersion >= 56) {
      final sourcedRows = await db
          .customSelect(
            'SELECT id, uid, owner_account, source_rfid_tag_uid, source_rfid_tag_type, '
            'rfid_tag_uid, total_grams, remaining_grams, lifecycle_status FROM consumables '
            "WHERE inventory_scope = 'personal' AND source_rfid_tag_uid IS NOT NULL",
          )
          .get();
      for (final row in sourcedRows) {
        final tag = row.read<String>('source_rfid_tag_uid');
        final owner = _ownerKey(row.read<String?>('owner_account'));
        if (!ownerVisible(owner)) continue;
        sourceCards.add((owner: owner, tag: tag));
        final lifecycle = row.read<String>('lifecycle_status');
        final hasCurrentTag =
            row.read<String?>('rfid_tag_uid')?.trim().isNotEmpty == true;
        if (row.read<double>('total_grams') != personalSpoolCapacityGrams ||
            !canReusePersonalSpool(row.read<double>('remaining_grams')) ||
            (lifecycle != 'active' && lifecycle != 'replaced') ||
            (lifecycle == 'active' && hasCurrentTag))
          continue;
        stock.add(
          PersonalAmsStockCandidate(
            consumableId: row.read<int>('id'),
            inventoryUid: row.read<String>('uid'),
            tagUid: tag,
            tagType: row.read<String>('source_rfid_tag_type'),
            ownerAccount: owner,
          ),
        );
      }
      // Keep recognizing a reusable material card even after its last stock
      // row was deleted. A receipt is durable evidence of its personal use.
      final receipts = await db
          .customSelect(
            'SELECT owner_account, payload_json FROM personal_stock_receipts',
          )
          .get();
      for (final receipt in receipts) {
        if (!ownerVisible(receipt.read<String>('owner_account'))) continue;
        final payload = jsonDecode(receipt.read<String>('payload_json')) as Map;
        final tag = payload['tagUid'];
        if (tag is String)
          sourceCards.add((
            owner: _ownerKey(receipt.read<String>('owner_account')),
            tag: tag,
          ));
      }
    }
    return PersonalAmsIdentityResolver._(
      [
        for (final row in rows)
          if (ownerVisible(row.read<String?>('owner_account')))
            (
              owner: _ownerKey(row.read<String?>('owner_account')),
              binding: RfidSpoolBinding(
                consumableId: row.read<int>('id'),
                inventoryUid: row.read<String>('uid'),
                tagUid: normalizeRfidTagUid(row.read<String>('rfid_tag_uid')),
                tagType: row.read<String?>('rfid_tag_type'),
                cycle: row.read<int>('rfid_tag_cycle'),
                status: row.read<String>('lifecycle_status'),
                previousInventoryUid: row.read<String?>(
                  'previous_consumable_uid',
                ),
              ),
            ),
      ],
      aliases,
      stock,
      sourceCards,
    );
  }

  PersonalAmsIdentity resolve(String value) {
    final base = _resolveBindings(value);
    final reported = base.reportedUid;
    // A full registered identity has priority over another card's prefix.
    if (reported.length == 16 &&
        base.history.any(
          (binding) =>
              isConsumableRfidTagType(binding.tagType) &&
              binding.tagUid == reported,
        )) {
      return base;
    }
    bool matches(String owner, String tag) =>
        (base.aliasOwner == null || owner == base.aliasOwner) &&
        (rfidTagUidEquals(base.tagUid, tag) ||
            (RegExp(r'^[0-9A-F]{16}$').hasMatch(reported) &&
                reported.startsWith(tag)));
    final sourceTags = _sourceCards
        .where((source) => matches(source.owner, source.tag))
        .map((source) => source.tag)
        .toSet();
    if (sourceTags.isEmpty) {
      // Older CUID/FUID inventory may predate durable stock receipts. Once a
      // physical unload marks its latest cycle replaced, offer that exact old
      // roll for explicit continuation instead of treating a copied Bambu
      // payload as proof that the same physical spool returned.
      final legacyRemnant = base.currentConsumableId == null
          ? base.history
                .where(
                  (binding) =>
                      binding.status == 'replaced' &&
                      isConsumableRfidTagType(binding.tagType),
                )
                .firstOrNull
          : null;
      if (legacyRemnant == null) return base;
      return PersonalAmsIdentity(
        reportedUid: base.reportedUid,
        tagUid: base.tagUid,
        history: base.history,
        candidates: [legacyRemnant],
        requiresConfirmation: true,
        aliasOwner: base.aliasOwner,
      );
    }
    return PersonalAmsIdentity(
      reportedUid: base.reportedUid,
      tagUid: base.tagUid,
      history: base.history,
      candidates: base.candidates,
      aliasOwner: base.aliasOwner,
      sourceTagUids: sourceTags,
      stockCandidates: _stock
          .where((stock) => matches(stock.ownerAccount, stock.tagUid))
          .toList(),
      requiresConfirmation:
          base.requiresConfirmation || base.currentConsumableId == null,
    );
  }

  PersonalAmsIdentity _resolveBindings(String value) {
    final reported = normalizeRfidTagUid(value);
    final exact = _bindings
        .where((r) => rfidTagUidEquals(r.binding.tagUid, reported))
        .map((r) => r.binding)
        .toList();
    if (_hasUnconfirmedCurrentType(exact)) {
      // Known non-consumable or unconfirmed legacy tags retain their history.
      // They must not fall through to automatic official-spool creation.
      return PersonalAmsIdentity(
        reportedUid: reported,
        tagUid: reported,
        history: exact,
        requiresConfirmation: true,
      );
    }
    final aliases = _aliases
        .where((r) => rfidTagUidEquals(r.read<String>('ams_uid'), reported))
        .toList();
    if (aliases.isNotEmpty) {
      final targets = <String>{};
      for (final alias in aliases) {
        final owner = alias.read<String>('owner_account');
        final uid = alias.read<String>('tag_uid');
        if (_bindings.any(
          (r) => r.owner == owner && rfidTagUidEquals(r.binding.tagUid, uid),
        )) {
          targets.add(uid);
        }
      }
      if (aliases.length == 1 &&
          targets.length == 1 &&
          exact.where((b) => b.isActive).isEmpty) {
        final canonical = targets.single;
        final owner = aliases.single.read<String>('owner_account');
        final history = _bindings
            .where(
              (r) =>
                  r.owner == owner &&
                  rfidTagUidEquals(r.binding.tagUid, canonical),
            )
            .map((r) => r.binding)
            .toList();
        return PersonalAmsIdentity(
          reportedUid: reported,
          tagUid: canonical,
          aliasOwner: owner,
          history: history,
          requiresConfirmation: _hasUnconfirmedCurrentType(history),
        );
      }
      // Conflicting accounts, another full-length identity, or an orphaned
      // alias must never fall through to automatic official-spool creation.
      return PersonalAmsIdentity(
        reportedUid: reported,
        tagUid: reported,
        history: exact,
        requiresConfirmation: true,
      );
    }
    final prefixHistory = RegExp(r'^[0-9A-F]{16}$').hasMatch(reported)
        ? _bindings
              .where(
                (r) =>
                    r.binding.tagType?.trim().toLowerCase() != 'ams' &&
                    r.binding.tagUid.length == 8 &&
                    reported.startsWith(r.binding.tagUid),
              )
              .map((r) => r.binding)
              .toList()
        : <RfidSpoolBinding>[];
    final candidates = prefixHistory
        .where((b) => isConsumableRfidTagType(b.tagType))
        .toList();
    // A registered full-length reusable ID is already explicit evidence.
    final knownExact = exact.any((b) => isReusableRfidTagType(b.tagType ?? ''));
    return PersonalAmsIdentity(
      reportedUid: reported,
      tagUid: reported,
      history: exact,
      candidates: candidates,
      requiresConfirmation: !knownExact && prefixHistory.isNotEmpty,
    );
  }
}

bool _hasUnconfirmedCurrentType(List<RfidSpoolBinding> history) {
  if (history.isEmpty) return false;
  final latestCycle = history
      .map((b) => b.cycle)
      .reduce((a, b) => a > b ? a : b);
  return history.any(
    (b) =>
        (b.isActive || b.cycle == latestCycle) &&
        b.tagType?.trim().toLowerCase() != 'ams' &&
        !isConsumableRfidTagType(b.tagType),
  );
}

/// Called only by the explicit desktop identity-confirmation action, inside
/// the same transaction as channel/task handoff. Aliases are local to this
/// installation; inventory/cloud IDs remain the NFC UID and physical-roll UID.
Future<void> confirmPersonalAmsIdentity(
  AppDatabase db, {
  required int consumableId,
  required String reportedUid,
}) async {
  final dao = db.consumableDao;
  final binding = await dao.getRfidSpoolBindingById(consumableId);
  final reported = normalizeRfidTagUid(reportedUid);
  if (binding == null ||
      !binding.isActive ||
      !isReusableRfidTagType(binding.tagType ?? '') ||
      !RegExp(r'^[0-9A-F]{8}$').hasMatch(binding.tagUid) ||
      !RegExp(r'^[0-9A-F]{16}$').hasMatch(reported) ||
      !reported.startsWith(binding.tagUid) ||
      await dao.isFarmConsumable(consumableId)) {
    throw StateError('请核对 AMS 完整标识与已登记的当前 CUID/FUID 标签，不能关联其他耗材');
  }
  final owner = await dao.getOwnerAccount(consumableId);
  final snapshot = await PersonalAmsIdentityResolver.load(db);
  final current = PersonalAmsIdentity(
    reportedUid: reported,
    tagUid: binding.tagUid,
    history: snapshot._bindings
        .where(
          (r) =>
              r.owner == _ownerKey(owner) &&
              rfidTagUidEquals(r.binding.tagUid, binding.tagUid),
        )
        .map((r) => r.binding)
        .toList(),
  );
  if (current.currentConsumableId != consumableId) {
    throw StateError('标签当前卷存在冲突或已变化，请先核对生命周期');
  }
  final fullHistory = await dao.getAnyPersonalRfidSpoolHistory(reported);
  if (fullHistory.any((b) => b.isActive)) {
    throw StateError('AMS 完整标识已关联另一卷，请先核对并归档错误关联，不能覆盖原账');
  }
  final existing = await db
      .customSelect(
        'SELECT tag_uid FROM personal_ams_uid_aliases WHERE owner_account = ? AND ams_uid = ?',
        variables: [Variable(_ownerKey(owner)), Variable(reported)],
      )
      .getSingleOrNull();
  if (snapshot._aliases.any(
    (alias) =>
        rfidTagUidEquals(alias.read<String>('ams_uid'), reported) &&
        alias.read<String>('owner_account') != _ownerKey(owner),
  )) {
    throw StateError('该 AMS 标识已确认给另一账号的库存，请先核对耗材归属');
  }
  if (existing != null &&
      !rfidTagUidEquals(existing.read<String>('tag_uid'), binding.tagUid)) {
    throw StateError('该 AMS 标识已有另一条确认关系，不能静默替换');
  }
  await db.customStatement(
    'INSERT INTO personal_ams_uid_aliases(owner_account, ams_uid, tag_uid, confirmed_at) '
    'VALUES (?, ?, ?, ?) ON CONFLICT(owner_account, ams_uid) DO NOTHING',
    [
      _ownerKey(owner),
      reported,
      binding.tagUid,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );
}

/// Follow an explicit inventory-owner change only after the complete old tag
/// history has left that owner. A retired roll is still part of that history.
Future<void> transferPersonalAmsIdentityOwner(
  AppDatabase db, {
  required String tagUid,
  required String? previousOwner,
  required String? nextOwner,
}) async {
  final previous = _ownerKey(previousOwner);
  final next = _ownerKey(nextOwner);
  if (db.schemaVersion < 53 || previous == next || tagUid.isEmpty) return;
  final aliases = await db
      .customSelect(
        'SELECT * FROM personal_ams_uid_aliases WHERE owner_account = ? AND tag_uid = ?',
        variables: [Variable(previous), Variable(normalizeRfidTagUid(tagUid))],
      )
      .get();
  if (aliases.isEmpty) return;
  final snapshot = await PersonalAmsIdentityResolver.load(db);
  if (snapshot._bindings.any(
    (r) => r.owner == previous && rfidTagUidEquals(r.binding.tagUid, tagUid),
  )) {
    return;
  }
  for (final alias in aliases) {
    final amsUid = alias.read<String>('ams_uid');
    final existing = snapshot._aliases
        .where(
          (r) =>
              r.read<String>('owner_account') == next &&
              rfidTagUidEquals(r.read<String>('ams_uid'), amsUid),
        )
        .firstOrNull;
    if (existing == null) {
      await db.customStatement(
        'UPDATE personal_ams_uid_aliases SET owner_account = ? WHERE owner_account = ? AND ams_uid = ?',
        [next, previous, amsUid],
      );
    } else if (rfidTagUidEquals(existing.read<String>('tag_uid'), tagUid)) {
      await db.customStatement(
        'DELETE FROM personal_ams_uid_aliases WHERE owner_account = ? AND ams_uid = ?',
        [previous, amsUid],
      );
    }
    // Conflicting destinations retain the orphaned alias and block resolution.
  }
}

String _ownerKey(String? value) => value?.trim().toLowerCase() ?? '';

Future<void> preparePersonalAmsUidAliases(Migrator m) async {
  await m.database.customStatement('''
    CREATE TABLE IF NOT EXISTS personal_ams_uid_aliases(
      owner_account TEXT NOT NULL,
      ams_uid TEXT NOT NULL COLLATE NOCASE,
      tag_uid TEXT NOT NULL COLLATE NOCASE,
      confirmed_at INTEGER NOT NULL,
      PRIMARY KEY(owner_account, ams_uid)
    )
  ''');
}
