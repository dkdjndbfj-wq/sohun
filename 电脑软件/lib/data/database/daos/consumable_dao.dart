import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/constants/personal_spool_policy.dart';
import '../database.dart';
import '../personal_ams_identity.dart';
import '../personal_spool_handoff.dart';
import '../personal_rfid_stock.dart';
import '../../models/personal_inventory_sync.dart';
import '../../models/personal_inventory_event.dart';
import '../../models/rfid_tag_identity.dart';
import '../../models/rfid_tag_history.dart';
import '../tables.dart';

part 'consumable_dao.g.dart';

/// 每卷标准克数（1 卷 = 1kg）。
const double gramsPerRoll = personalSpoolCapacityGrams;

const personalInventoryScope = 'personal';
const farmInventoryScope = 'farm';

class FarmConsumableMetadata {
  const FarmConsumableMetadata({
    required this.archived,
    required this.colorMode,
    this.archivedAt,
    this.brandCode,
    this.secondaryColorHex,
  });

  final bool archived;
  final DateTime? archivedAt;
  final String? brandCode;
  final String colorMode;
  final String? secondaryColorHex;

  bool get hasMultipleColors =>
      colorMode != 'solid' && secondaryColorHex?.trim().isNotEmpty == true;
}

/// 已登记实体卷按卷号计数；旧聚合库存按 1 kg 分卷，余卷也占一盘。
int inventoryRollCount(double remainingGrams, {bool individualSpool = false}) {
  if (!remainingGrams.isFinite || remainingGrams <= 0) return 0;
  if (individualSpool) return 1;
  return (remainingGrams / gramsPerRoll).ceil();
}

/// 从聚合库存中取一卷可绑定的实际克数，任何物理料盘最多 1000g。
///
/// [alreadyBoundRolls] 表示同一库存记录已被多少个物理料位占用。
double singleRollAvailableGrams(
  double remainingGrams, {
  int alreadyBoundRolls = 0,
}) {
  if (!remainingGrams.isFinite || remainingGrams <= 0) return 0;
  final unassigned =
      remainingGrams - alreadyBoundRolls.clamp(0, 1 << 30) * gramsPerRoll;
  return unassigned.clamp(0.0, gramsPerRoll).toDouble();
}

/// 耗材 + 归属账号包装视图。
///
/// [ownerAccount] 是由服务器地址和稳定服务端用户 ID 派生的不透明键，null
/// 表示尚未关联账号（离线手动添加）。用于多账号耗材隔离。
/// 由于 build_runner 不可用，owner_account 列不在 drift 代码生成范围内，
/// 通过 raw SQL 单独查询后包装到此类。
class ConsumableWithOwner {
  final Consumable consumable;
  final String? ownerAccount;

  ConsumableWithOwner(this.consumable, {this.ownerAccount});

  /// 是否属于指定账号（null 账号视为"未关联"，匹配 null ownerAccount）。
  bool belongsTo(String? account) {
    if (account == null) return ownerAccount == null;
    return ownerAccount == account;
  }
}

/// 耗材物理参数（v12 新增，raw SQL 读写，不进 drift 代码生成）。
///
/// 用于 RFID 自动填充 + 干燥提醒联动 + 成本精度。
class ConsumableParams {
  /// 密度 g/cm³（PLA≈1.24, PETG≈1.27, ABS≈1.04, TPU≈1.21）。
  /// 影响切片重量估算精度。null 表示未设置。
  final double? density;

  /// 推荐喷嘴温度 ℃（从 RFID nozzle_temp_max 填充）。null 表示未设置。
  final double? recommendedNozzleTemp;

  /// 吸湿性档位：'high' / 'medium' / 'low'。
  /// drying_reminder_service 按此档位决定提醒周期，null 则按材质名推断。
  final String? hygroscopicity;

  const ConsumableParams({
    this.density,
    this.recommendedNozzleTemp,
    this.hygroscopicity,
  });

  bool get isEmpty =>
      density == null &&
      recommendedNozzleTemp == null &&
      hygroscopicity == null;
}

/// The reusable physical tag binding attached to one spool instance.
///
/// A tag UID can occur in many rows; [cycle] is the monotonically increasing
/// replacement number for that tag and [status] preserves the old row after a
/// roll is depleted or replaced.
class RfidSpoolBinding {
  const RfidSpoolBinding({
    required this.consumableId,
    required this.inventoryUid,
    required this.tagUid,
    this.tagType,
    required this.cycle,
    required this.status,
    this.previousInventoryUid,
    this.tagHistory = const [],
    this.isHistoricalTag = false,
  });

  final int consumableId;
  final String inventoryUid;
  final String tagUid;
  final String? tagType;
  final int cycle;
  final String status;
  final String? previousInventoryUid;
  final List<RfidTagHistoryEntry> tagHistory;
  final bool isHistoricalTag;

  RfidTagHistoryEntry get identity => RfidTagHistoryEntry(
    tagUid: tagUid,
    tagType: tagType,
    cycle: cycle,
    previousInventoryUid: previousInventoryUid,
  );

  bool get isActive => status == 'active';
}

/// 耗材数据访问层。提供库存的 CRUD 与流式监听。
@DriftAccessor(tables: [Consumables])
class ConsumableDao extends DatabaseAccessor<AppDatabase>
    with _$ConsumableDaoMixin {
  ConsumableDao(super.db);

  Future<Map<int, PersonalRfidStockSource>> getPersonalRfidStockSourcesMap(
    Iterable<int> ids,
  ) => PersonalRfidStockStore(attachedDatabase).sources(ids);

  Future<bool> isIndividualPersonalSpool(int id) async {
    if (await isFarmConsumable(id)) return false;
    return (await getRfidSpoolBindingById(id))?.tagUid.isNotEmpty == true ||
        (await getPersonalRfidStockSourcesMap([id])).containsKey(id);
  }

  Future<PersonalStockReceipt> addPersonalStockFromRfidCard({
    required String operationUid,
    required String tagUid,
    required String tagType,
    required PersonalInventoryRecord template,
    required int quantity,
    String? ownerAccount,
    DateTime? now,
  }) => PersonalRfidStockStore(attachedDatabase).receive(
    operationUid: operationUid,
    tagUid: tagUid,
    tagType: tagType,
    template: template,
    quantity: quantity,
    ownerAccount: ownerAccount,
    now: now,
  );

  Future<PersonalStockReceipt> addPersonalStockManual({
    required String operationUid,
    required PersonalInventoryRecord template,
    required int quantity,
    String? ownerAccount,
  }) => PersonalRfidStockStore(attachedDatabase).receiveManual(
    operationUid: operationUid,
    template: template,
    quantity: quantity,
    ownerAccount: ownerAccount,
  );

  Future<RfidSpoolBinding> attachPersonalRfidTagToExistingStock({
    required int consumableId,
    required String tagUid,
    required String tagType,
    String? ownerAccount,
    bool continueCurrentTask = false,
    DateTime? now,
  }) => PersonalRfidStockStore(attachedDatabase).activate(
    consumableId: consumableId,
    tagUid: tagUid,
    tagType: tagType,
    ownerAccount: ownerAccount,
    continueCurrentTask: continueCurrentTask,
    now: now,
  );

  String get _rfidHistoryColumn => attachedDatabase.schemaVersion >= 54
      ? 'rfid_tag_history'
      : "'[]' AS rfid_tag_history";

  List<RfidSpoolBinding> _bindingsForTag(List<QueryRow> rows, String tag) {
    final bindings = <RfidSpoolBinding>[];
    for (final row in rows) {
      final binding = _rfidBindingFromRow(row);
      if (rfidTagUidEquals(binding.tagUid, tag)) bindings.add(binding);
      for (final old in binding.tagHistory) {
        if (!rfidTagUidEquals(old.tagUid, tag)) continue;
        bindings.add(
          RfidSpoolBinding(
            consumableId: binding.consumableId,
            inventoryUid: binding.inventoryUid,
            tagUid: old.tagUid,
            tagType: old.tagType,
            cycle: old.cycle,
            status: 'replaced',
            previousInventoryUid: old.previousInventoryUid,
            isHistoricalTag: true,
          ),
        );
      }
    }
    // Keep SQL's timestamp/id tie order while inserting archived identities.
    final indexed = bindings.indexed.toList();
    indexed.sort((a, b) {
      final cycle = b.$2.cycle.compareTo(a.$2.cycle);
      if (cycle != 0) return cycle;
      if (a.$2.isActive != b.$2.isActive) return a.$2.isActive ? -1 : 1;
      return a.$1.compareTo(b.$1);
    });
    return indexed.map((entry) => entry.$2).toList(growable: false);
  }

  Stream<List<Consumable>> watchAll() {
    final query = select(consumables)
      ..orderBy([
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ]);
    return query.watch();
  }

  Future<List<Consumable>> getAll() {
    final query = select(consumables)
      ..orderBy([
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ]);
    return query.get();
  }

  Future<List<Consumable>> getPersonal() =>
      _getScoped(scope: personalInventoryScope);

  /// Reads personal rows owned by [ownerAccount] plus legacy rows that have
  /// never been associated with an account. The latter are claimed by the
  /// first signed-in personal account during synchronization.
  Future<List<Consumable>> getPersonalForOwnerAccount(
    String ownerAccount,
  ) async {
    final normalized = ownerAccount.trim();
    final all = await getPersonal();
    final rows = normalized.isEmpty
        ? await customSelect(
            "SELECT id FROM consumables "
            "WHERE inventory_scope = 'personal' "
            "AND (owner_account IS NULL OR trim(owner_account) = '')",
          ).get()
        : await customSelect(
            "SELECT id FROM consumables "
            "WHERE inventory_scope = 'personal' "
            "AND (lower(trim(owner_account)) = lower(trim(?)) "
            "OR owner_account IS NULL OR trim(owner_account) = '')",
            variables: [Variable<String>(normalized)],
          ).get();
    final ids = rows.map((row) => row.read<int>('id')).toSet();
    return all.where((item) => ids.contains(item.id)).toList();
  }

  /// Watches the personal inventory visible to one sohun account.
  ///
  /// Legacy rows with a null owner are included so the first account login
  /// can claim them through the existing synchronization flow. Farm rows and
  /// rows owned by another account never enter this stream.
  Stream<List<Consumable>> watchPersonalForOwnerAccount(String ownerAccount) {
    final normalized = ownerAccount.trim();

    late StreamController<List<Consumable>> controller;
    StreamSubscription<List<Consumable>>? subscription;

    Future<void> reload() async {
      try {
        final items = await getPersonalForOwnerAccount(normalized);
        if (!controller.isClosed) controller.add(items);
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      }
    }

    controller = StreamController<List<Consumable>>(
      onListen: () {
        subscription = select(consumables).watch().listen((_) => reload());
        reload();
      },
      onCancel: () async {
        await subscription?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<List<Consumable>> getFarm(String workspaceId) {
    if (workspaceId.trim().isEmpty) return Future.value(const []);
    return _getScoped(scope: farmInventoryScope, workspaceId: workspaceId);
  }

  Future<bool> isFarmConsumable(int id) async {
    final row = await customSelect(
      "SELECT 1 FROM consumables WHERE id = ? AND inventory_scope = 'farm' LIMIT 1",
      variables: [Variable<int>(id)],
    ).getSingleOrNull();
    return row != null;
  }

  Stream<List<Consumable>> watchPersonal() =>
      _watchScoped(scope: personalInventoryScope);

  Stream<List<Consumable>> watchFarm(String workspaceId) {
    if (workspaceId.trim().isEmpty) {
      return Stream.value(const <Consumable>[]);
    }
    return _watchScoped(scope: farmInventoryScope, workspaceId: workspaceId);
  }

  Future<List<Consumable>> _getScoped({
    required String scope,
    String? workspaceId,
  }) async {
    final all = await getAll();
    final rows = await customSelect(
      'SELECT id FROM consumables WHERE inventory_scope = ? '
      '${workspaceId == null ? '' : 'AND farm_workspace_id = ?'}',
      variables: [
        Variable<String>(scope),
        if (workspaceId != null) Variable<String>(workspaceId),
      ],
    ).get();
    final ids = rows.map((row) => row.read<int>('id')).toSet();
    return all.where((item) => ids.contains(item.id)).toList();
  }

  Stream<List<Consumable>> _watchScoped({
    required String scope,
    String? workspaceId,
  }) {
    late StreamController<List<Consumable>> controller;
    StreamSubscription<List<Consumable>>? subscription;

    Future<void> reload() async {
      try {
        final items = await _getScoped(scope: scope, workspaceId: workspaceId);
        if (!controller.isClosed) controller.add(items);
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      }
    }

    controller = StreamController<List<Consumable>>(
      onListen: () {
        subscription = select(consumables).watch().listen((_) => reload());
        reload();
      },
      onCancel: () async {
        await subscription?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  /// 监听所有耗材 + 归属账号（多账号隔离用）。
  ///
  /// 用 StreamController 合并 drift select watch 和 raw SQL owner_account 查询，
  /// consumables 表任何变化都触发重新加载并附加 owner_account 字段。
  Stream<List<ConsumableWithOwner>> watchAllWithOwner() {
    late StreamController<List<ConsumableWithOwner>> controller;
    StreamSubscription? sub;

    Future<void> reload() async {
      try {
        final list = await getAllWithOwner();
        if (!controller.isClosed) controller.add(list);
      } catch (e) {
        if (!controller.isClosed) controller.addError(e);
      }
    }

    controller = StreamController<List<ConsumableWithOwner>>(
      onListen: () {
        sub = select(consumables).watch().listen((_) => reload());
        reload();
      },
      onCancel: () {
        sub?.cancel();
        controller.close();
      },
    );
    return controller.stream;
  }

  /// 查询所有耗材 + 归属账号（一次性）。
  ///
  /// 实现方式：drift select 查 Consumable 列表 + raw SQL 查 owner_account map，
  /// 合并后返回 [ConsumableWithOwner] 列表。避免手动构造每个 Consumable 字段。
  Future<List<ConsumableWithOwner>> getAllWithOwner() async {
    final list = await getAll();
    final ownerMap = await _loadOwnerAccountMap();
    return [
      for (final c in list)
        ConsumableWithOwner(c, ownerAccount: ownerMap[c.id]),
    ];
  }

  /// 查询 owner_account 字段（raw SQL，因该列不在 drift 代码生成范围内）。
  /// 返回 Map<consumableId, ownerAccount>，null 表示未关联账号。
  Future<Map<int, String?>> _loadOwnerAccountMap() async {
    final rows = await customSelect(
      'SELECT id, owner_account FROM consumables',
    ).get();
    final map = <int, String?>{};
    for (final row in rows) {
      map[row.read<int>('id')] = row.read<String?>('owner_account');
    }
    return map;
  }

  /// 设置耗材归属账号（raw SQL）。
  ///
  /// [ownerAccount] 是账号作用域的不透明键，传 null 清除归属。
  /// 用于新增耗材时自动填充当前活跃账号，或迁移耗材到其他账号。
  Future<void> setOwnerAccount(int id, String? ownerAccount) async {
    return transaction(() async {
      final normalized = ownerAccount?.trim().toLowerCase();
      final previousOwner = await getOwnerAccount(id);
      final binding =
          attachedDatabase.schemaVersion >= 53 && !await isFarmConsumable(id)
          ? await getRfidSpoolBindingById(id)
          : null;
      await customUpdate(
        'UPDATE consumables SET owner_account = ? WHERE id = ?',
        variables: [
          Variable(normalized?.isEmpty == true ? null : normalized),
          Variable(id),
        ],
        updates: {consumables},
      );
      if (binding != null) {
        await transferPersonalAmsIdentityOwner(
          attachedDatabase,
          tagUid: binding.tagUid,
          previousOwner: previousOwner,
          nextOwner: normalized,
        );
      }
      if (attachedDatabase.schemaVersion >= 56) {
        // Anonymous stock is claimed on first sign-in. The durable receipt
        // follows the same claim so a delayed retry cannot create new rolls.
        final source = (await getPersonalRfidStockSourcesMap([id]))[id];
        if (source != null &&
            (previousOwner ?? '').trim().isEmpty &&
            normalized?.isNotEmpty == true) {
          await customUpdate(
            'UPDATE personal_stock_receipts SET owner_account = ? '
            "WHERE operation_uid = ? AND trim(owner_account) = ''",
            variables: [Variable(normalized), Variable(source.receiptUid)],
          );
        }
      }
    });
  }

  /// Reads the account owner for one personal inventory row.
  Future<String?> getOwnerAccount(int id) async {
    final row = await customSelect(
      'SELECT owner_account FROM consumables WHERE id = ? LIMIT 1',
      variables: [Variable<int>(id)],
    ).getSingleOrNull();
    return row?.read<String?>('owner_account');
  }

  /// Verifies that a personal inventory row belongs to the active Sohun
  /// account before a channel or print operation can use it.
  ///
  /// Farm rows keep their workspace authorization path and are accepted here.
  /// Anonymous personal rows are available to signed-out users; a signed-in
  /// account can atomically claim one when [claimAnonymous] is true.
  Future<bool> ensurePersonalConsumableAccess(
    int id, {
    required String? ownerAccount,
    bool claimAnonymous = false,
  }) {
    final expected = ownerAccount?.trim().toLowerCase() ?? '';
    return transaction(() async {
      final row = await customSelect(
        'SELECT inventory_scope, owner_account FROM consumables '
        'WHERE id = ? LIMIT 1',
        variables: [Variable<int>(id)],
      ).getSingleOrNull();
      if (row == null) return false;
      if (row.read<String>('inventory_scope') == farmInventoryScope) {
        return true;
      }
      final stored = row.read<String?>('owner_account')?.trim().toLowerCase();
      if (stored?.isNotEmpty == true) {
        return expected.isNotEmpty && stored == expected;
      }
      if (expected.isEmpty || !claimAnonymous) return true;
      return _claimAnonymousPersonalInventoryChain(id, expected);
    });
  }

  /// Claims one anonymous physical inventory chain for an authenticated user.
  ///
  /// A reusable CUID/FUID can span several lifecycle rows, and one material
  /// card receipt can create several concrete stock rows. Claiming only the
  /// row currently clicked would leave the previous cycles or sibling rolls
  /// visible to the next account on the same computer. This method follows
  /// both tag and receipt links, rejects an already mixed-owner component, and
  /// moves the rows plus their durable identity/history records atomically.
  Future<bool> _claimAnonymousPersonalInventoryChain(
    int consumableId,
    String expectedOwner,
  ) async {
    final owner = expectedOwner.trim().toLowerCase();
    if (owner.isEmpty) return false;
    final hasAmsIdentity = attachedDatabase.schemaVersion >= 53;
    final hasStockSource = attachedDatabase.schemaVersion >= 56;
    final rows = await customSelect(
      'SELECT id, uid, owner_account, '
      '${hasAmsIdentity ? 'rfid_tag_uid' : "'' AS rfid_tag_uid"}, '
      '${hasAmsIdentity ? 'previous_consumable_uid' : "NULL AS previous_consumable_uid"}, '
      '${attachedDatabase.schemaVersion >= 54 ? 'rfid_tag_history' : "'[]' AS rfid_tag_history"}, '
      '${hasStockSource ? 'source_rfid_tag_uid' : "NULL AS source_rfid_tag_uid"}, '
      '${hasStockSource ? 'stock_receipt_uid' : "NULL AS stock_receipt_uid"} '
      'FROM consumables WHERE inventory_scope = \'personal\'',
    ).get();
    final start = rows.where((row) => row.read<int>('id') == consumableId);
    if (start.isEmpty) return false;

    String key(String? value) => value?.trim().toLowerCase() ?? '';
    List<RfidTagHistoryEntry> claimHistory(QueryRow row) {
      try {
        return RfidTagHistoryEntry.parseList(
          jsonDecode(row.read<String>('rfid_tag_history')),
        );
      } catch (_) {
        return const [];
      }
    }

    Set<String> rowTags(QueryRow row) => {
      key(row.read<String?>('rfid_tag_uid')),
      key(row.read<String?>('source_rfid_tag_uid')),
      for (final history in claimHistory(row)) key(history.tagUid),
    }..remove('');
    Set<String> rowInventoryLinks(QueryRow row) => {
      key(row.read<String>('uid')),
      key(row.read<String?>('previous_consumable_uid')),
      for (final history in claimHistory(row))
        key(history.previousInventoryUid),
    }..remove('');

    final componentIds = <int>{consumableId};
    final tags = <String>{...rowTags(start.single)};
    final inventoryLinks = <String>{...rowInventoryLinks(start.single)};
    final receipts = <String>{
      key(start.single.read<String?>('stock_receipt_uid')),
    }..remove('');
    var expanded = true;
    while (expanded) {
      expanded = false;
      for (final row in rows) {
        final id = row.read<int>('id');
        final receipt = key(row.read<String?>('stock_receipt_uid'));
        final nextTags = rowTags(row);
        final nextInventoryLinks = rowInventoryLinks(row);
        if (!componentIds.contains(id) &&
            (receipt.isEmpty || !receipts.contains(receipt)) &&
            nextTags.intersection(tags).isEmpty &&
            nextInventoryLinks.intersection(inventoryLinks).isEmpty) {
          continue;
        }
        if (componentIds.add(id)) expanded = true;
        if (receipt.isNotEmpty && receipts.add(receipt)) expanded = true;
        final previousTagCount = tags.length;
        tags.addAll(nextTags);
        if (tags.length != previousTagCount) expanded = true;
        final previousInventoryLinkCount = inventoryLinks.length;
        inventoryLinks.addAll(nextInventoryLinks);
        if (inventoryLinks.length != previousInventoryLinkCount) {
          expanded = true;
        }
      }
    }

    final component = rows.where(
      (row) => componentIds.contains(row.read<int>('id')),
    );
    if (component.any((row) {
      final stored = key(row.read<String?>('owner_account'));
      return stored.isNotEmpty && stored != owner;
    })) {
      return false;
    }
    // Keep orphaned historical UIDs too. A previous cycle may already have
    // been deleted locally while its immutable event/tag ledger remains.
    final inventoryUids = Set<String>.from(inventoryLinks);

    final tagVariables = [for (final tag in tags) Variable<String>(tag)];
    final uidVariables = [
      for (final inventoryUid in inventoryUids) Variable<String>(inventoryUid),
    ];
    final receiptVariables = [
      for (final receipt in receipts) Variable<String>(receipt),
    ];
    final aliasRows = tags.isEmpty
        ? const <QueryRow>[]
        : await customSelect(
            'SELECT owner_account, ams_uid, tag_uid '
            'FROM personal_ams_uid_aliases WHERE lower(trim(tag_uid)) IN '
            '(${List.filled(tags.length, '?').join(',')})',
            variables: tagVariables,
          ).get();
    if (aliasRows.any((row) {
      final stored = key(row.read<String>('owner_account'));
      return stored.isNotEmpty && stored != owner;
    })) {
      return false;
    }
    for (final alias in aliasRows.where(
      (row) => key(row.read<String>('owner_account')).isEmpty,
    )) {
      final existing = await customSelect(
        'SELECT tag_uid FROM personal_ams_uid_aliases '
        'WHERE lower(trim(owner_account)) = ? AND lower(trim(ams_uid)) = ?',
        variables: [
          Variable(owner),
          Variable(key(alias.read<String>('ams_uid'))),
        ],
      ).getSingleOrNull();
      if (existing != null &&
          key(existing.read<String>('tag_uid')) !=
              key(alias.read<String>('tag_uid'))) {
        return false;
      }
    }

    final linkedOwnerPredicates = <String>[];
    final linkedOwnerVariables = <Variable<String>>[];
    final linkedOwnerValues = <String>[];
    if (inventoryUids.isNotEmpty) {
      linkedOwnerPredicates.add(
        'lower(trim(inventory_uid)) IN '
        '(${List.filled(inventoryUids.length, '?').join(',')})',
      );
      linkedOwnerVariables.addAll(uidVariables);
      linkedOwnerValues.addAll(inventoryUids);
    }
    if (tags.isNotEmpty) {
      linkedOwnerPredicates.add(
        'lower(trim(rfid_tag_uid)) IN '
        '(${List.filled(tags.length, '?').join(',')})',
      );
      linkedOwnerVariables.addAll(tagVariables);
      linkedOwnerValues.addAll(tags);
    }
    if (linkedOwnerPredicates.isNotEmpty) {
      final ownerTables = [
        if (attachedDatabase.schemaVersion >= 50) 'personal_inventory_events',
        if (attachedDatabase.schemaVersion >= 47) 'rfid_tag_records',
      ];
      for (final table in ownerTables) {
        final predicates = table == 'rfid_tag_records'
            ? linkedOwnerPredicates
                  .map(
                    (predicate) =>
                        predicate.replaceAll('rfid_tag_uid', 'tag_uid'),
                  )
                  .toList(growable: false)
            : linkedOwnerPredicates;
        final mixed = await customSelect(
          'SELECT 1 FROM $table WHERE (${predicates.join(' OR ')}) '
          "AND coalesce(trim(owner_account), '') != '' "
          'AND lower(trim(owner_account)) != ? LIMIT 1',
          variables: [...linkedOwnerVariables, Variable(owner)],
        ).getSingleOrNull();
        if (mixed != null) return false;
      }
    }
    if (receipts.isNotEmpty) {
      final mixedReceipt = await customSelect(
        'SELECT 1 FROM personal_stock_receipts WHERE lower(trim(operation_uid)) '
        'IN (${List.filled(receipts.length, '?').join(',')}) '
        "AND trim(owner_account) != '' AND lower(trim(owner_account)) != ? LIMIT 1",
        variables: [...receiptVariables, Variable(owner)],
      ).getSingleOrNull();
      if (mixedReceipt != null) return false;
    }

    final anonymousIds = component
        .where((row) => key(row.read<String?>('owner_account')).isEmpty)
        .map((row) => row.read<int>('id'))
        .toList(growable: false);
    if (anonymousIds.isNotEmpty) {
      final updated = await customUpdate(
        'UPDATE consumables SET owner_account = ? WHERE id IN '
        '(${List.filled(anonymousIds.length, '?').join(',')}) '
        "AND coalesce(trim(owner_account), '') = ''",
        variables: [
          Variable(owner),
          for (final id in anonymousIds) Variable<int>(id),
        ],
        updates: {consumables},
      );
      if (updated != anonymousIds.length) {
        throw StateError('库存归属已变化，请刷新后重试');
      }
    }
    for (final alias in aliasRows.where(
      (row) => key(row.read<String>('owner_account')).isEmpty,
    )) {
      final amsUid = alias.read<String>('ams_uid');
      final existing = await customSelect(
        'SELECT tag_uid FROM personal_ams_uid_aliases '
        'WHERE lower(trim(owner_account)) = ? AND lower(trim(ams_uid)) = ?',
        variables: [Variable(owner), Variable(key(amsUid))],
      ).getSingleOrNull();
      if (existing == null) {
        await customStatement(
          'UPDATE personal_ams_uid_aliases SET owner_account = ? '
          "WHERE trim(owner_account) = '' AND ams_uid = ?",
          [owner, amsUid],
        );
      } else {
        await customStatement(
          'DELETE FROM personal_ams_uid_aliases '
          "WHERE trim(owner_account) = '' AND ams_uid = ?",
          [amsUid],
        );
      }
    }
    if (linkedOwnerPredicates.isNotEmpty) {
      final ownerTables = [
        if (attachedDatabase.schemaVersion >= 50) 'personal_inventory_events',
        if (attachedDatabase.schemaVersion >= 47) 'rfid_tag_records',
      ];
      for (final table in ownerTables) {
        final predicates = table == 'rfid_tag_records'
            ? linkedOwnerPredicates
                  .map(
                    (predicate) =>
                        predicate.replaceAll('rfid_tag_uid', 'tag_uid'),
                  )
                  .toList(growable: false)
            : linkedOwnerPredicates;
        await customStatement(
          'UPDATE $table SET owner_account = ? '
          "WHERE coalesce(trim(owner_account), '') = '' "
          'AND (${predicates.join(' OR ')})',
          [owner, ...linkedOwnerValues],
        );
      }
    }
    if (receipts.isNotEmpty) {
      await customStatement(
        'UPDATE personal_stock_receipts SET owner_account = ? '
        "WHERE trim(owner_account) = '' AND lower(trim(operation_uid)) IN "
        '(${List.filled(receipts.length, '?').join(',')})',
        [owner, ...receipts],
      );
    }
    return true;
  }

  /// 批量设置归属账号（事务保护）。
  ///
  /// 用于把现有未关联账号的耗材批量归属到当前活跃账号。
  Future<void> batchSetOwnerAccount(List<int> ids, String? ownerAccount) async {
    if (ids.isEmpty) return;
    return transaction(() async {
      for (final id in ids) {
        await setOwnerAccount(id, ownerAccount);
      }
    });
  }

  /// Moves only legacy email-owned data that the current server proves belongs
  /// to [nextOwnerAccount].
  ///
  /// The old `email|personal` key did not contain a server or immutable user
  /// ID, so claiming every row with that key would leak data after account
  /// deletion/re-registration or between self-hosted servers. A record is
  /// migrated only when its random inventory UID is already present in the
  /// authenticated account's remote snapshot. A tombstone uses the same rule
  /// against the server's deleted UID set. Ambiguous local-only rows remain
  /// quarantined under the legacy key instead of being uploaded to a possibly
  /// unrelated account.
  Future<int> migrateVerifiedLegacyPersonalOwner({
    required String legacyOwnerAccount,
    required String nextOwnerAccount,
    required String serverUrl,
    required Iterable<String> remoteInventoryUids,
    required Iterable<String> remoteDeletedUids,
  }) async {
    final legacy = legacyOwnerAccount.trim().toLowerCase();
    final next = nextOwnerAccount.trim().toLowerCase();
    final server = serverUrl.trim();
    if (legacy.isEmpty || next.isEmpty || server.isEmpty || legacy == next) {
      return 0;
    }
    final remote = remoteInventoryUids
        .map((uid) => uid.trim().toLowerCase())
        .where((uid) => uid.isNotEmpty)
        .toSet();
    final remoteDeleted = remoteDeletedUids
        .map((uid) => uid.trim().toLowerCase())
        .where((uid) => uid.isNotEmpty)
        .toSet();
    if (remote.isEmpty && remoteDeleted.isEmpty) return 0;

    return transaction(() async {
      final existingNextRows = await customSelect(
        "SELECT uid FROM consumables WHERE inventory_scope = 'personal' "
        'AND lower(trim(owner_account)) = lower(trim(?))',
        variables: [Variable(next)],
      ).get();
      final existingNext = existingNextRows
          .map((row) => row.read<String>('uid').trim().toLowerCase())
          .where((uid) => uid.isNotEmpty)
          .toSet();
      final legacyRows = await customSelect(
        "SELECT id, uid FROM consumables WHERE inventory_scope = 'personal' "
        'AND lower(trim(owner_account)) = lower(trim(?))',
        variables: [Variable(legacy)],
      ).get();
      final migrated = <String>{};
      for (final row in legacyRows) {
        final uid = row.read<String>('uid').trim().toLowerCase();
        if (!remote.contains(uid) || existingNext.contains(uid)) continue;
        await setOwnerAccount(row.read<int>('id'), next);
        migrated.add(uid);
      }

      final migratedDeleted = <String>{};
      final legacyTombstones = await customSelect(
        'SELECT uid, deleted_at FROM personal_inventory_tombstones '
        'WHERE lower(trim(owner_account)) = lower(trim(?))',
        variables: [Variable(legacy)],
      ).get();
      for (final row in legacyTombstones) {
        final rawUid = row.read<String>('uid').trim();
        final uid = rawUid.toLowerCase();
        if (!remoteDeleted.contains(uid)) continue;
        await customStatement(
          'INSERT INTO personal_inventory_tombstones(owner_account, uid, deleted_at) '
          'VALUES (?, ?, ?) ON CONFLICT(owner_account, uid) DO UPDATE SET '
          'deleted_at = MAX(deleted_at, excluded.deleted_at)',
          [next, rawUid, row.read<int>('deleted_at')],
        );
        await customStatement(
          'DELETE FROM personal_inventory_tombstones '
          'WHERE lower(trim(owner_account)) = lower(trim(?)) '
          'AND lower(trim(uid)) = lower(trim(?))',
          [legacy, rawUid],
        );
        migratedDeleted.add(uid);
      }

      final verified = <String>{...migrated, ...migratedDeleted};
      if (verified.isEmpty) return 0;

      final legacyEvents = await customSelect(
        'SELECT event_uid, inventory_uid FROM personal_inventory_events '
        'WHERE lower(trim(owner_account)) = lower(trim(?))',
        variables: [Variable(legacy)],
      ).get();
      final migratedEventUids = <String>[];
      for (final row in legacyEvents) {
        if (!verified.contains(
          row.read<String>('inventory_uid').trim().toLowerCase(),
        )) {
          continue;
        }
        final eventUid = row.read<String>('event_uid');
        await customStatement(
          'UPDATE personal_inventory_events SET owner_account = ? '
          'WHERE event_uid = ? AND lower(trim(owner_account)) = lower(trim(?))',
          [next, eventUid, legacy],
        );
        migratedEventUids.add(eventUid);
      }
      for (final uid in verified) {
        await customStatement(
          'UPDATE rfid_tag_records SET owner_account = ? '
          'WHERE lower(trim(owner_account)) = lower(trim(?)) '
          'AND lower(trim(inventory_uid)) = lower(trim(?))',
          [next, legacy, uid],
        );
      }

      final receipts = await customSelect(
        'SELECT operation_uid, inventory_uids_json FROM personal_stock_receipts '
        'WHERE lower(trim(owner_account)) = lower(trim(?))',
        variables: [Variable(legacy)],
      ).get();
      for (final row in receipts) {
        try {
          final decoded = jsonDecode(row.read<String>('inventory_uids_json'));
          if (decoded is! List || decoded.isEmpty) continue;
          final receiptUids = decoded
              .whereType<String>()
              .map((uid) => uid.trim().toLowerCase())
              .where((uid) => uid.isNotEmpty)
              .toSet();
          if (receiptUids.length != decoded.length ||
              !receiptUids.every(verified.contains)) {
            continue;
          }
          await customStatement(
            'UPDATE personal_stock_receipts SET owner_account = ? '
            'WHERE operation_uid = ? AND lower(trim(owner_account)) = lower(trim(?))',
            [next, row.read<String>('operation_uid'), legacy],
          );
        } on FormatException {
          // A malformed historical receipt is not evidence of ownership. Keep
          // it quarantined; normal inventory synchronization can still run.
        }
      }

      for (final table in [
        'personal_inventory_sync_baselines',
        'personal_inventory_balance_conflicts',
      ]) {
        final rows = await customSelect(
          'SELECT inventory_uid, record_json FROM $table '
          'WHERE lower(trim(owner_account)) = lower(trim(?)) AND server_url = ?',
          variables: [Variable(legacy), Variable(server)],
        ).get();
        for (final row in rows) {
          final inventoryUid = row.read<String>('inventory_uid');
          if (!verified.contains(inventoryUid.trim().toLowerCase())) continue;
          await customStatement(
            'INSERT OR IGNORE INTO $table('
            'owner_account, server_url, inventory_uid, record_json) '
            'VALUES (?, ?, ?, ?)',
            [next, server, inventoryUid, row.read<String>('record_json')],
          );
          await customStatement(
            'DELETE FROM $table WHERE lower(trim(owner_account)) = lower(trim(?)) '
            'AND server_url = ? AND lower(trim(inventory_uid)) = lower(trim(?))',
            [legacy, server, inventoryUid],
          );
        }
      }
      for (final eventUid in migratedEventUids) {
        await customStatement(
          'INSERT OR IGNORE INTO personal_inventory_event_receipts('
          'owner_account, server_url, event_uid) '
          'SELECT ?, server_url, event_uid FROM personal_inventory_event_receipts '
          'WHERE lower(trim(owner_account)) = lower(trim(?)) '
          'AND server_url = ? AND event_uid = ?',
          [next, legacy, server, eventUid],
        );
        await customStatement(
          'DELETE FROM personal_inventory_event_receipts '
          'WHERE lower(trim(owner_account)) = lower(trim(?)) '
          'AND server_url = ? AND event_uid = ?',
          [legacy, server, eventUid],
        );
      }
      return migrated.length + migratedDeleted.length;
    });
  }

  /// 按归属账号查询耗材（多账号筛选用）。
  ///
  /// [ownerAccount] 为 null 时返回所有未关联账号的耗材。
  Future<List<ConsumableWithOwner>> getByOwnerAccount(
    String? ownerAccount,
  ) async {
    final all = await getAllWithOwner();
    return all.where((e) => e.belongsTo(ownerAccount)).toList();
  }

  /// 耗材物理参数（v12 新增，raw SQL，因 build_runner 不可用）。
  ///
  /// [density] 密度 g/cm³（影响切片重量估算精度）。
  /// [recommendedNozzleTemp] 推荐喷嘴温度 ℃（从 RFID 填充）。
  /// [hygroscopicity] 吸湿性档位 'high'/'medium'/'low'（干燥提醒用）。
  Future<ConsumableParams> getParams(int id) async {
    final rows = await customSelect(
      'SELECT density, recommended_nozzle_temp, hygroscopicity FROM consumables WHERE id = ?',
      variables: [Variable(id)],
    ).get();
    if (rows.isEmpty) return const ConsumableParams();
    final row = rows.first;
    return ConsumableParams(
      density: row.read<double?>('density'),
      recommendedNozzleTemp: row.read<double?>('recommended_nozzle_temp'),
      hygroscopicity: row.read<String?>('hygroscopicity'),
    );
  }

  /// 批量查询耗材物理参数（避免 N+1，库存列表用）。
  Future<Map<int, ConsumableParams>> getParamsMap(List<int> ids) async {
    if (ids.isEmpty) return {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await customSelect(
      'SELECT id, density, recommended_nozzle_temp, hygroscopicity FROM consumables WHERE id IN ($placeholders)',
      variables: [for (final id in ids) Variable(id)],
    ).get();
    final map = <int, ConsumableParams>{};
    for (final row in rows) {
      map[row.read<int>('id')] = ConsumableParams(
        density: row.read<double?>('density'),
        recommendedNozzleTemp: row.read<double?>('recommended_nozzle_temp'),
        hygroscopicity: row.read<String?>('hygroscopicity'),
      );
    }
    return map;
  }

  /// 设置耗材物理参数（raw SQL）。
  ///
  /// 传 null 表示清除该字段。用于新增耗材后写入 RFID 解析的参数，
  /// 或用户手动修改参数。
  Future<void> setParams(
    int id, {
    double? density,
    double? recommendedNozzleTemp,
    String? hygroscopicity,
    bool clearDensity = false,
    bool clearTemp = false,
    bool clearHygro = false,
  }) async {
    final sets = <String>[];
    final vars = <Variable>[];
    if (clearDensity) {
      sets.add('density = NULL');
    } else if (density != null) {
      sets.add('density = ?');
      vars.add(Variable<double>(density));
    }
    if (clearTemp) {
      sets.add('recommended_nozzle_temp = NULL');
    } else if (recommendedNozzleTemp != null) {
      sets.add('recommended_nozzle_temp = ?');
      vars.add(Variable<double>(recommendedNozzleTemp));
    }
    if (clearHygro) {
      sets.add('hygroscopicity = NULL');
    } else if (hygroscopicity != null) {
      sets.add('hygroscopicity = ?');
      vars.add(Variable<String>(hygroscopicity));
    }
    if (sets.isEmpty) return;
    vars.add(Variable(id));
    await customUpdate(
      'UPDATE consumables SET ${sets.join(', ')} WHERE id = ?',
      variables: vars,
      updates: {consumables},
    );
  }

  Future<Consumable?> getById(int id) {
    return (select(
      consumables,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Finds a personal inventory row by the stable cross-device UID.
  ///
  /// Farm rows may use their own identifiers, so the scope predicate is
  /// intentionally part of this lookup even though [uid] is normally unique.
  Future<Consumable?> getPersonalByUid(
    String uid, {
    String? ownerAccount,
  }) async {
    final normalized = uid.trim();
    if (normalized.isEmpty) return null;
    final owner = ownerAccount?.trim();
    // A null/blank owner means an offline, unclaimed row. It must never be
    // treated as a wildcard: otherwise a logged-out phone could update a
    // spool belonging to another sohun account. A signed-in owner may also
    // claim legacy rows whose owner column is still null/blank.
    final ownerPredicate = owner?.isNotEmpty == true
        ? 'AND (lower(trim(owner_account)) = lower(trim(?)) OR owner_account IS NULL OR trim(owner_account) = \'\') '
        : 'AND (owner_account IS NULL OR trim(owner_account) = \'\') ';
    final row = await customSelect(
      "SELECT id FROM consumables "
      "WHERE lower(trim(uid)) = lower(trim(?)) AND inventory_scope = 'personal' "
      '$ownerPredicate'
      'LIMIT 1',
      variables: [
        Variable<String>(normalized),
        if (owner?.isNotEmpty == true) Variable<String>(owner!),
      ],
    ).getSingleOrNull();
    if (row == null) return null;
    return getById(row.read<int>('id'));
  }

  /// Finds the personal inventory row currently bound to one physical RFID
  /// tray. This makes a repeated mobile write idempotent instead of creating
  /// another logical spool for the same tag.
  Future<Consumable?> getPersonalByTrayUuid(
    String trayUuid, {
    String? ownerAccount,
  }) async {
    final normalized = trayUuid.trim();
    if (normalized.isEmpty) return null;
    final owner = ownerAccount?.trim();
    final ownerPredicate = owner?.isNotEmpty == true
        ? 'AND (lower(trim(owner_account)) = lower(trim(?)) OR owner_account IS NULL OR trim(owner_account) = \'\') '
        : 'AND (owner_account IS NULL OR trim(owner_account) = \'\') ';
    final row = await customSelect(
      "SELECT id FROM consumables "
      "WHERE inventory_scope = 'personal' "
      'AND lower(trim(tray_uuid)) = lower(trim(?)) '
      '$ownerPredicate'
      'LIMIT 1',
      variables: [
        Variable<String>(normalized),
        if (owner?.isNotEmpty == true) Variable<String>(owner!),
      ],
    ).getSingleOrNull();
    if (row == null) return null;
    return getById(row.read<int>('id'));
  }

  /// Returns all personal spool instances that have used one reusable
  /// CUID/FUID tag, newest lifecycle first. The list deliberately allows
  /// duplicate tag UIDs: one physical card can label many successive rolls.
  Future<List<RfidSpoolBinding>> getPersonalRfidSpoolHistory(
    String tagUid, {
    String? ownerAccount,
  }) async {
    final normalized = normalizeRfidTagUid(tagUid);
    if (normalized.isEmpty) return const [];
    final owner = ownerAccount?.trim();
    final ownerPredicate = owner?.isNotEmpty == true
        ? 'AND (lower(trim(owner_account)) = lower(trim(?)) OR owner_account IS NULL OR trim(owner_account) = \'\') '
        : 'AND (owner_account IS NULL OR trim(owner_account) = \'\') ';
    final rows = await customSelect(
      "SELECT id, uid, rfid_tag_uid, rfid_tag_type, rfid_tag_cycle, "
      "lifecycle_status, previous_consumable_uid, $_rfidHistoryColumn FROM consumables "
      "WHERE inventory_scope = 'personal' AND trim(rfid_tag_uid) != '' "
      '$ownerPredicate'
      "ORDER BY rfid_tag_cycle DESC, CASE lifecycle_status WHEN 'active' THEN 0 WHEN 'depleted' THEN 1 WHEN 'replaced' THEN 2 ELSE 3 END, updated_at DESC, id DESC",
      variables: [if (owner?.isNotEmpty == true) Variable<String>(owner!)],
    ).get();
    return _bindingsForTag(rows, normalized);
  }

  Future<RfidSpoolBinding?> getPersonalActiveRfidSpool(
    String tagUid, {
    String? ownerAccount,
  }) async {
    final history = await getPersonalRfidSpoolHistory(
      tagUid,
      ownerAccount: ownerAccount,
    );
    final active = history.where((binding) => binding.isActive).toList();
    return active.length == 1 && active.single == history.first
        ? active.single
        : null;
  }

  /// Finds the newest personal spool associated with a physical CUID/FUID
  /// identity.  Unlike [getByTrayUuid], this lookup is deliberately allowed
  /// to return one of several lifecycle rows because a reusable card can label
  /// many successive rolls.  The first active/newest row is authoritative.
  Future<Consumable?> getPersonalByRfidTagUid(
    String tagUid, {
    String? ownerAccount,
  }) async {
    final history = await getPersonalRfidSpoolHistory(
      tagUid,
      ownerAccount: ownerAccount,
    );
    for (final binding in history) {
      final row = await getById(binding.consumableId);
      if (row != null) return row;
    }

    // v47 mobile builds temporarily stored the physical UID in tray_uuid.
    // Keep that migration path alive for desktop AMS packets that expose only
    // tag_uid, while retaining the same account boundary.
    final normalized = normalizeRfidTagUid(tagUid);
    if (normalized.isEmpty) return null;
    final owner = ownerAccount?.trim();
    final ownerPredicate = owner?.isNotEmpty == true
        ? 'AND (lower(trim(owner_account)) = lower(trim(?)) OR owner_account IS NULL OR trim(owner_account) = \'\') '
        : 'AND (owner_account IS NULL OR trim(owner_account) = \'\') ';
    final rows = await customSelect(
      "SELECT * FROM consumables WHERE inventory_scope = 'personal' "
      "AND trim(tray_uuid) != '' $ownerPredicate"
      'ORDER BY updated_at DESC, id DESC',
      variables: [if (owner?.isNotEmpty == true) Variable<String>(owner!)],
    ).get();
    for (final row in rows) {
      final tray = row.read<String?>('tray_uuid');
      if (tray != null && rfidTagUidEquals(tray, normalized)) {
        return rowToConsumable(row);
      }
    }
    return null;
  }

  /// Unscoped physical-tag lookup for ownership checks in mobile write flows.
  /// It must never be used to populate a user-visible inventory list.
  Future<Consumable?> getAnyPersonalByRfidTagUid(String tagUid) async {
    final history = await getAnyPersonalRfidSpoolHistory(tagUid);
    if (history.isNotEmpty) {
      final active = history.where((binding) => binding.isActive).toList();
      // Never guess between concurrent cycles or fall back to a retired row.
      if (active.length != 1 || active.single != history.first) return null;
      return getById(active.single.consumableId);
    }
    final normalized = normalizeRfidTagUid(tagUid);
    if (normalized.isEmpty) return null;
    final rows = await customSelect(
      "SELECT * FROM consumables WHERE inventory_scope = 'personal' "
      "AND trim(tray_uuid) != '' AND coalesce(trim(rfid_tag_uid), '') = '' "
      "ORDER BY updated_at DESC, id DESC",
    ).get();
    for (final row in rows) {
      final tray = row.read<String?>('tray_uuid');
      if (tray != null && rfidTagUidEquals(tray, normalized)) {
        return rowToConsumable(row);
      }
    }
    return null;
  }

  /// Ownership-audit lookup with no account scope. Callers must use this only
  /// to reject cross-account tag claims; it must never feed an inventory list.
  Future<List<RfidSpoolBinding>> getAnyPersonalRfidSpoolHistory(
    String tagUid,
  ) async {
    final normalized = normalizeRfidTagUid(tagUid);
    if (normalized.isEmpty) return const [];
    final rows = await customSelect(
      "SELECT id, uid, rfid_tag_uid, rfid_tag_type, rfid_tag_cycle, "
      "lifecycle_status, previous_consumable_uid, $_rfidHistoryColumn FROM consumables "
      "WHERE inventory_scope = 'personal' AND trim(rfid_tag_uid) != '' "
      "ORDER BY rfid_tag_cycle DESC, CASE lifecycle_status WHEN 'active' THEN 0 WHEN 'depleted' THEN 1 WHEN 'replaced' THEN 2 ELSE 3 END, updated_at DESC, id DESC",
    ).get();
    return _bindingsForTag(rows, normalized);
  }

  Future<RfidSpoolBinding?> getRfidSpoolBindingById(int consumableId) async {
    final row = await customSelect(
      'SELECT id, uid, rfid_tag_uid, rfid_tag_type, rfid_tag_cycle, '
      'lifecycle_status, previous_consumable_uid, $_rfidHistoryColumn FROM consumables WHERE id = ? '
      'LIMIT 1',
      variables: [Variable<int>(consumableId)],
    ).getSingleOrNull();
    return row == null ? null : _rfidBindingFromRow(row);
  }

  Future<Map<int, RfidSpoolBinding>> getRfidSpoolBindingsMap(
    Iterable<int> consumableIds,
  ) async {
    final ids = consumableIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await customSelect(
      'SELECT id, uid, rfid_tag_uid, rfid_tag_type, rfid_tag_cycle, '
      'lifecycle_status, previous_consumable_uid, $_rfidHistoryColumn FROM consumables '
      'WHERE id IN ($placeholders) AND rfid_tag_uid IS NOT NULL '
      "AND trim(rfid_tag_uid) != ''",
      variables: [for (final id in ids) Variable<int>(id)],
    ).get();
    return {
      for (final row in rows) row.read<int>('id'): _rfidBindingFromRow(row),
    };
  }

  /// Updates only lifecycle metadata. Inventory grams remain untouched so a
  /// replacement can never refill or erase the old spool's balance.
  Future<void> updateRfidSpoolLifecycle(
    int consumableId, {
    required String status,
  }) async {
    if (!validConsumableLifecycleStatuses.contains(status)) {
      throw ArgumentError.value(status, 'status', '未知的耗材生命周期状态');
    }
    if (status == 'active' && await isIndividualPersonalSpool(consumableId)) {
      final item = await getById(consumableId);
      final previous = await getRfidSpoolBindingById(consumableId);
      if (item != null) {
        _requireStandardPersonalSpool(item);
        if (previous?.status != 'active' &&
            !canReusePersonalSpool(item.remainingGrams)) {
          throw StateError('余量必须大于 30 g 才能重新启用耗材卷');
        }
      }
    }
    await customUpdate(
      'UPDATE consumables SET lifecycle_status = ?, updated_at = ? WHERE id = ?',
      variables: [
        Variable<String>(status),
        Variable<DateTime>(DateTime.now()),
        Variable<int>(consumableId),
      ],
      updates: {consumables},
    );
  }

  /// Starts a confirmed replacement, atomically preserving the old spool and
  /// its task/usage references. Passing the old row ID also rejects stale UIs.
  Future<RfidSpoolBinding> replacePersonalRfidSpool({
    required int consumableId,
    required double initialGrams,
    bool continueCurrentTask = false,
    DateTime? now,
  }) async {
    if (!canReusePersonalSpool(initialGrams)) {
      throw ArgumentError('每卷规格固定为 1000 g，换入卷的余量必须大于 30 g 且不超过 1000 g');
    }
    return transaction(() async {
      final old = await getById(consumableId);
      final binding = await getRfidSpoolBindingById(consumableId);
      if (old == null ||
          binding == null ||
          binding.tagUid.isEmpty ||
          await isFarmConsumable(consumableId)) {
        throw StateError('只能为已登记标签的个人耗材卷创建下一周期');
      }
      if (binding.tagType == 'ams' && old.trayUuid?.isNotEmpty == true) {
        throw StateError('原厂料卷请通过装入新卷登记，不能复用原厂卷号');
      }
      if (!isConsumableRfidTagType(binding.tagType)) {
        throw StateError('只有已确认的 CUID/FUID 可以复用换卷；其他卡型或未确认历史仅供查看');
      }
      _requireStandardPersonalSpool(old);
      final owner = await getOwnerAccount(consumableId);
      final history = await getPersonalRfidSpoolHistory(
        binding.tagUid,
        ownerAccount: owner,
      );
      final currentCycle = history
          .where((b) => b.cycle == binding.cycle)
          .toList();
      final unresolved = currentCycle
          .where((b) => b.status != 'retired')
          .toList();
      final selectedCurrent = unresolved.length == 1
          ? unresolved.single.consumableId == consumableId
          : unresolved.isEmpty && currentCycle.length == 1;
      if (history.isEmpty ||
          history.first.consumableId != consumableId ||
          !selectedCurrent ||
          history.where((b) => b.isActive).length > 1) {
        throw StateError('标签周期已变化或存在冲突，请刷新库存后重试');
      }
      final pending = await customSelect(
        'SELECT id FROM print_task_consumables WHERE consumable_id = ? '
        'AND consumed_at IS NULL LIMIT 1',
        variables: [Variable(consumableId)],
      ).getSingleOrNull();
      PrinterChannel? taskChannel;
      if (pending != null && continueCurrentTask) {
        final channels = await (select(
          attachedDatabase.printerChannels,
        )..where((t) => t.consumableId.equals(consumableId))).get();
        if (channels.length != 1) {
          throw StateError('无法唯一确认正在使用该卷的供料位，请先核对任务');
        }
        taskChannel = channels.single;
      } else if (pending != null) {
        throw StateError('该卷仍有关联的未结算任务，请在打印机所在设备确认换卷接续，或先完成任务结算');
      }
      final timestamp = now ?? DateTime.now();
      await updateRfidSpoolLifecycle(
        consumableId,
        status: binding.status == 'retired'
            ? 'retired'
            : old.remainingGrams <= 0
            ? 'depleted'
            : 'replaced',
      );
      // A confirmed tag transfer ends the old physical slot association.
      // Preserve the old stock and task ledger; the next AMS packet can bind
      // the new inventory UID even if it reports the same physical tag.
      await customUpdate(
        'UPDATE printer_channels SET consumable_id = NULL, loaded_spool_uid = NULL, '
        'loaded_remaining_grams = 0, farm_roll_paused = 0, updated_at = ? '
        'WHERE consumable_id = ?',
        variables: [Variable(timestamp), Variable(consumableId)],
        updates: {attachedDatabase.printerChannels},
      );
      final newId = await upsertPersonalInventoryRecord(
        PersonalInventoryRecord(
          uid: const Uuid().v4(),
          manufacturer: old.manufacturer,
          model: old.model,
          materialType: old.materialType,
          colorHex: old.colorHex,
          colorName: old.colorName,
          totalGrams: personalSpoolCapacityGrams,
          remainingGrams: initialGrams,
          purchaseDate: timestamp,
          createdAt: timestamp,
          updatedAt: timestamp,
          density: old.density,
          recommendedNozzleTemp: old.recommendedNozzleTemp,
          hygroscopicity: old.hygroscopicity,
          rfidTagUid: binding.tagUid,
          rfidTagType: binding.tagType,
          rfidTagCycle: binding.cycle + 1,
          lifecycleStatus: 'active',
          previousConsumableUid: old.uid,
        ),
        ownerAccount: owner,
      );
      final next = (await getRfidSpoolBindingById(newId))!;
      if (taskChannel != null) {
        final handoff = PersonalSpoolHandoff(attachedDatabase);
        await handoff.splitTasks(taskChannel, consumableId, newId);
        await handoff.record(
          taskChannel,
          consumableId,
          'spool_unloaded',
          before: old.remainingGrams,
          after: old.remainingGrams,
        );
        await attachedDatabase.printerDao.bindConsumable(taskChannel.id, newId);
      }
      await customInsert(
        'INSERT INTO rfid_tag_records(tag_uid, tag_type, operation, inventory_uid, '
        'owner_account, brand, model, color_hex, message, occurred_at, created_at, updated_at) '
        "VALUES (?, ?, 'replace', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        variables: [
          Variable(binding.tagUid),
          Variable(binding.tagType ?? ''),
          Variable(next.inventoryUid),
          Variable(owner?.trim().toLowerCase()),
          Variable(old.manufacturer),
          Variable(old.model),
          Variable(old.colorHex),
          Variable(
            '第 ${binding.cycle} 卷 → 第 ${next.cycle} 卷；上一卷 ${old.uid}；每卷规格 1000 g，新卷余量 $initialGrams g',
          ),
          Variable(timestamp.millisecondsSinceEpoch),
          Variable(timestamp.millisecondsSinceEpoch),
          Variable(timestamp.millisecondsSinceEpoch),
        ],
      );
      return next;
    });
  }

  /// Reuses a leftover spool with an unused physical tag. The previous binding
  /// remains queryable, and no stock or consumption is moved to another UID.
  Future<RfidSpoolBinding> rebindPersonalRfidSpool({
    required int consumableId,
    required String expectedTagUid,
    required String newTagUid,
    required String newTagType,
    required String? ownerAccount,
  }) async {
    final tag = normalizeRfidTagUid(newTagUid);
    final type = newTagType.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{8}$').hasMatch(tag) ||
        !const {'CUID', 'FUID'}.contains(type)) {
      throw ArgumentError('请输入新 CUID/FUID 标签的 8 位十六进制 UID');
    }
    return transaction(() async {
      final item = await getById(consumableId);
      final binding = await getRfidSpoolBindingById(consumableId);
      final owner = (ownerAccount ?? '').trim().toLowerCase();
      final storedOwner = (await getOwnerAccount(consumableId) ?? '')
          .trim()
          .toLowerCase();
      if (item == null ||
          binding == null ||
          await isFarmConsumable(consumableId) ||
          (storedOwner.isNotEmpty && storedOwner != owner)) {
        throw StateError('找不到当前账号的个人耗材卷');
      }
      if (binding.status != 'replaced' ||
          !isConsumableRfidTagType(binding.tagType) ||
          !canReusePersonalSpool(item.remainingGrams) ||
          !rfidTagUidEquals(binding.tagUid, expectedTagUid)) {
        throw StateError('该卷状态已变化；只有标签已转移且余量大于 30 g 的旧卷可以换绑');
      }
      _requireStandardPersonalSpool(item);
      if (binding.tagHistory.length >= 32) throw StateError('该卷已达到 32 次换绑上限');
      final history = await getPersonalRfidSpoolHistory(
        binding.tagUid,
        ownerAccount: owner,
      );
      if (!history.any(
        (next) =>
            next.cycle == binding.cycle + 1 &&
            next.previousInventoryUid?.toLowerCase() == item.uid.toLowerCase(),
      )) {
        throw StateError('无法确认原标签的下一卷，请先同步并核对标签链路');
      }
      if (rfidTagUidEquals(tag, binding.tagUid) ||
          (await getAnyPersonalRfidSpoolHistory(tag)).isNotEmpty ||
          await getAnyPersonalByRfidTagUid(tag) != null ||
          await customSelect(
                'SELECT 1 FROM personal_ams_uid_aliases WHERE tag_uid = ? OR substr(ams_uid, 1, 8) = ? LIMIT 1',
                variables: [Variable(tag), Variable(tag)],
              ).getSingleOrNull() !=
              null) {
        throw StateError('新标签已有绑定或识别记录，请使用未登记的标签');
      }
      final pending = await customSelect(
        'SELECT 1 FROM print_task_consumables WHERE consumable_id = ? AND consumed_at IS NULL LIMIT 1',
        variables: [Variable(consumableId)],
      ).getSingleOrNull();
      final loaded = await customSelect(
        'SELECT 1 FROM printer_channels WHERE consumable_id = ? LIMIT 1',
        variables: [Variable(consumableId)],
      ).getSingleOrNull();
      if (pending != null || loaded != null) {
        throw StateError('该卷仍被供料位或未结算任务占用，请先卸料并结算');
      }
      final now = DateTime.now();
      if (storedOwner.isEmpty && owner.isNotEmpty)
        await setOwnerAccount(consumableId, owner);
      await setRfidSpoolBinding(
        consumableId,
        tagUid: tag,
        tagType: type,
        cycle: 1,
        status: 'active',
        tagHistory: [...binding.tagHistory, binding.identity],
        updatedAt: now,
      );
      await customStatement(
        'INSERT INTO personal_inventory_events(event_uid, owner_account, inventory_uid, '
        'rfid_tag_uid, rfid_tag_cycle, event_type, before_grams, after_grams, delta_grams, '
        'occurred_at, source, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          const Uuid().v4(),
          owner.isEmpty ? null : owner,
          item.uid,
          tag,
          1,
          'tag_rebound',
          item.remainingGrams,
          item.remainingGrams,
          0,
          now.millisecondsSinceEpoch,
          'manual',
          '旧标签 ${binding.tagUid} 第 ${binding.cycle} 卷换绑到 $tag；余量不变',
        ],
      );
      return (await getRfidSpoolBindingById(consumableId))!;
    });
  }

  /// Resolves a fork after the user identifies the physical current roll.
  /// Other candidates remain as retired history; no balances are combined.
  Future<void> resolvePersonalRfidSpoolConflict(int chosenId) async {
    await transaction(() async {
      final chosen = await getRfidSpoolBindingById(chosenId);
      if (chosen == null ||
          chosen.tagUid.isEmpty ||
          await isFarmConsumable(chosenId)) {
        throw StateError('找不到个人耗材卷');
      }
      final owner = await getOwnerAccount(chosenId);
      final history = await getPersonalRfidSpoolHistory(
        chosen.tagUid,
        ownerAccount: owner,
      );
      final candidates = history
          .where(
            (b) =>
                b.status != 'retired' &&
                (b.cycle == chosen.cycle || b.isActive),
          )
          .toList();
      if (chosen.status == 'retired' ||
          candidates.length < 2 ||
          chosen.cycle != history.first.cycle) {
        throw StateError('冲突已变化，请刷新后选择最新周期中实际正在使用的耗材卷');
      }
      for (final other in candidates.where((b) => b.consumableId != chosenId)) {
        final pending = await customSelect(
          'SELECT id FROM print_task_consumables WHERE consumable_id = ? AND consumed_at IS NULL LIMIT 1',
          variables: [Variable(other.consumableId)],
        ).getSingleOrNull();
        if (pending != null) throw StateError('另一候选卷仍有未结算任务，请先核对并结算');
        await updateRfidSpoolLifecycle(other.consumableId, status: 'retired');
        await customUpdate(
          'UPDATE printer_channels SET consumable_id = NULL, loaded_spool_uid = NULL, '
          'loaded_remaining_grams = 0, farm_roll_paused = 0 WHERE consumable_id = ?',
          variables: [Variable(other.consumableId)],
          updates: {attachedDatabase.printerChannels},
        );
      }
      final time = DateTime.now().millisecondsSinceEpoch;
      await customInsert(
        'INSERT INTO rfid_tag_records(tag_uid, operation, inventory_uid, owner_account, '
        'message, occurred_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(chosen.tagUid),
          const Variable('resolve'),
          Variable(chosen.inventoryUid),
          Variable(owner?.trim().toLowerCase()),
          const Variable('用户核对当前卷；其他冲突卷保留余额并停用标签关联'),
          Variable(time),
          Variable(time),
          Variable(time),
        ],
      );
    });
  }

  /// Archives a tagged personal spool while keeping its immutable UID,
  /// predecessor pointer, and consumption history. Physical deletion of a
  /// tagged row would make a reused CUID/FUID cycle impossible to audit, so
  /// callers use this explicit lifecycle transition instead.
  Future<void> retirePersonalRfidSpool(int consumableId) async {
    await transaction(() async {
      final binding = await getRfidSpoolBindingById(consumableId);
      if (binding == null ||
          binding.tagUid.isEmpty ||
          await isFarmConsumable(consumableId)) {
        throw StateError('只有带 RFID 标签的个人耗材卷可以归档');
      }
      final pending = await customSelect(
        'SELECT id FROM print_task_consumables WHERE consumable_id = ? '
        'AND consumed_at IS NULL LIMIT 1',
        variables: [Variable<int>(consumableId)],
      ).getSingleOrNull();
      if (pending != null) {
        throw StateError('该卷仍有关联的未结算任务，请先完成任务结算');
      }
      await updateRfidSpoolLifecycle(consumableId, status: 'retired');
      final owner = await getOwnerAccount(consumableId);
      final now = DateTime.now().millisecondsSinceEpoch;
      await customStatement(
        'INSERT INTO rfid_tag_records(tag_uid, operation, inventory_uid, owner_account, '
        'occurred_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [binding.tagUid, 'archive', binding.inventoryUid, owner, now, now, now],
      );
      await customUpdate(
        'UPDATE printer_channels SET consumable_id = NULL, loaded_spool_uid = NULL, '
        'loaded_remaining_grams = 0, farm_roll_paused = 0, updated_at = ? '
        'WHERE consumable_id = ?',
        variables: [
          Variable<DateTime>(DateTime.now()),
          Variable<int>(consumableId),
        ],
        updates: {attachedDatabase.printerChannels},
      );
    });
  }

  /// Reads the durable account ledger. Events are captured by v51 triggers
  /// when source rows are inserted, never regenerated during synchronization.
  Future<void> claimPersonalInventoryEvents(String ownerAccount) async {
    final owner = ownerAccount.trim().toLowerCase();
    if (owner.isEmpty) throw ArgumentError('同步账本需要账号');
    await customStatement(
      "UPDATE personal_inventory_events SET owner_account = ? "
      "WHERE coalesce(trim(owner_account), '') = '' AND EXISTS ("
      "SELECT 1 FROM consumables c WHERE lower(c.uid) = lower(inventory_uid) "
      "AND c.inventory_scope = 'personal' AND "
      "(coalesce(trim(c.owner_account), '') = '' OR lower(trim(c.owner_account)) = ?))",
      [owner, owner],
    );
  }

  Future<List<PersonalInventoryEvent>> getPersonalInventoryEvents(
    String ownerAccount, {
    int? limit,
  }) async {
    await claimPersonalInventoryEvents(ownerAccount);
    final rows = await customSelect(
      'SELECT * FROM personal_inventory_events WHERE lower(trim(owner_account)) = ? '
      'ORDER BY occurred_at, event_uid${limit == null ? '' : ' LIMIT ?'}',
      variables: [
        Variable(ownerAccount.trim().toLowerCase()),
        if (limit != null) Variable(limit),
      ],
    ).get();
    return rows.map(_eventFromRow).toList(growable: false);
  }

  /// Immutable import. Existing local events retain their origin on roundtrip.
  Future<void> upsertPersonalInventoryEvents(
    Iterable<PersonalInventoryEvent> events, {
    required String ownerAccount,
  }) async {
    final owner = ownerAccount.trim().toLowerCase();
    if (owner.isEmpty) throw ArgumentError('同步账本需要账号');
    for (final input in events) {
      final event = PersonalInventoryEvent.fromJson(input.toJson());
      final existing = await customSelect(
        'SELECT * FROM personal_inventory_events WHERE lower(event_uid) = lower(?)',
        variables: [Variable(event.eventUid)],
      ).getSingleOrNull();
      if (existing != null) {
        final existingOwner = existing
            .read<String?>('owner_account')
            ?.trim()
            .toLowerCase();
        if (existingOwner != owner) throw StateError('个人耗材事件属于其他账号，拒绝覆盖');
        if (jsonEncode(_eventFromRow(existing).toJson()) !=
            jsonEncode(event.toJson())) {
          throw StateError('同一个人耗材事件内容冲突，原始记录已保留');
        }
        continue;
      }
      await customStatement(
        'INSERT INTO personal_inventory_events('
        'event_uid, owner_account, inventory_uid, rfid_tag_uid, rfid_tag_cycle, '
        'event_type, before_grams, after_grams, delta_grams, occurred_at, source, '
        'note, origin, printer_uid, printer_name, channel_index, task_uid) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          event.eventUid,
          owner,
          event.inventoryUid,
          event.rfidTagUid,
          event.rfidTagCycle,
          event.eventType,
          event.beforeGrams,
          event.afterGrams,
          event.deltaGrams,
          event.occurredAt.millisecondsSinceEpoch,
          event.source,
          event.note,
          'remote',
          event.printerUid,
          event.printerName,
          event.channelIndex,
          event.taskUid,
        ],
      );
    }
  }

  Future<List<PersonalInventoryEvent>> getPersonalInventoryEventsForUid(
    String inventoryUid, {
    required String? ownerAccount,
    int limit = 200,
    int offset = 0,
  }) async {
    final rows = await customSelect(
      'SELECT * FROM personal_inventory_events WHERE lower(inventory_uid) = lower(?) '
      "AND coalesce(nullif(lower(trim(owner_account)), ''), '') = ? "
      'ORDER BY occurred_at DESC, event_uid LIMIT ? OFFSET ?',
      variables: [
        Variable(inventoryUid.trim()),
        Variable(ownerAccount?.trim().toLowerCase() ?? ''),
        Variable(limit.clamp(1, 500)),
        Variable(math.max(0, offset)),
      ],
    ).get();
    return rows.map(_eventFromRow).toList(growable: false);
  }

  /// Totals are calculated over the whole ledger, independent of UI paging.
  /// AMS observations and print estimates are not added to settled usage.
  Future<double> getPersonalInventoryConsumedGrams(
    String inventoryUid, {
    required String? ownerAccount,
  }) async {
    final row = await customSelect(
      'SELECT coalesce(-sum(delta_grams), 0) AS grams FROM personal_inventory_events '
      "WHERE lower(inventory_uid) = lower(?) AND (source = 'usage' OR event_type = 'manual_consumption') "
      "AND coalesce(nullif(lower(trim(owner_account)), ''), '') = ?",
      variables: [
        Variable(inventoryUid.trim()),
        Variable(ownerAccount?.trim().toLowerCase() ?? ''),
      ],
    ).getSingle();
    return row.read<double>('grams');
  }

  Future<List<PersonalInventoryEvent>> getPendingPersonalInventoryEvents(
    String ownerAccount,
    String serverUrl, {
    int limit = 200,
  }) async {
    await claimPersonalInventoryEvents(ownerAccount);
    final rows = await customSelect(
      "SELECT e.* FROM personal_inventory_events e WHERE e.origin = 'local' "
      'AND lower(trim(e.owner_account)) = ? AND NOT EXISTS ('
      'SELECT 1 FROM personal_inventory_event_receipts r WHERE r.owner_account = ? '
      'AND r.server_url = ? AND r.event_uid = e.event_uid) '
      'ORDER BY e.occurred_at, e.event_uid LIMIT ?',
      variables: [
        Variable(ownerAccount),
        Variable(ownerAccount),
        Variable(serverUrl),
        Variable(limit.clamp(1, 200)),
      ],
    ).get();
    return rows.map(_eventFromRow).toList(growable: false);
  }

  Future<void> acknowledgePersonalInventoryEvents(
    String ownerAccount,
    String serverUrl,
    Iterable<PersonalInventoryEvent> events,
  ) async {
    for (final event in events) {
      await customStatement(
        'INSERT OR IGNORE INTO personal_inventory_event_receipts '
        '(owner_account, server_url, event_uid) VALUES (?, ?, ?)',
        [ownerAccount, serverUrl, event.eventUid],
      );
    }
  }

  Future<int> getPersonalInventoryEventCursor(
    String ownerAccount,
    String serverUrl,
  ) async {
    final row = await customSelect(
      'SELECT cursor FROM personal_inventory_event_cursors WHERE owner_account = ? AND server_url = ?',
      variables: [Variable(ownerAccount), Variable(serverUrl)],
    ).getSingleOrNull();
    return row?.read<int>('cursor') ?? 0;
  }

  Future<void> setPersonalInventoryEventCursor(
    String ownerAccount,
    String serverUrl,
    int cursor,
  ) => customStatement(
    'INSERT INTO personal_inventory_event_cursors(owner_account, server_url, cursor) '
    'VALUES (?, ?, ?) ON CONFLICT(owner_account, server_url) DO UPDATE SET cursor = excluded.cursor',
    [ownerAccount, serverUrl, cursor],
  );

  PersonalInventoryEvent _eventFromRow(QueryRow row) => PersonalInventoryEvent(
    eventUid: row.read<String>('event_uid'),
    inventoryUid: row.read<String>('inventory_uid'),
    rfidTagUid: _normalizedNullableTag(row.read<String?>('rfid_tag_uid')),
    rfidTagCycle:
        _normalizedNullableTag(row.read<String?>('rfid_tag_uid')) == null
        ? null
        : (row.read<int?>('rfid_tag_cycle') ?? 1),
    eventType: row.read<String>('event_type'),
    beforeGrams: row.read<double?>('before_grams'),
    afterGrams: row.read<double?>('after_grams'),
    deltaGrams: row.read<double?>('delta_grams'),
    occurredAt: DateTime.fromMillisecondsSinceEpoch(
      row.read<int>('occurred_at'),
      isUtc: true,
    ),
    source: row.read<String>('source'),
    note: row.read<String?>('note'),
    isRemote: row.read<String>('origin') == 'remote',
    printerUid: row.read<String?>('printer_uid'),
    printerName: row.read<String?>('printer_name'),
    channelIndex: row.read<int?>('channel_index'),
    taskUid: row.read<String?>('task_uid'),
  );

  static String? _normalizedNullableTag(String? value) {
    final normalized = value == null ? '' : normalizeRfidTagUid(value);
    return normalized.isEmpty ? null : normalized;
  }

  Future<void> setRfidSpoolBinding(
    int consumableId, {
    String? tagUid,
    String? tagType,
    required int cycle,
    required String status,
    String? previousInventoryUid,
    DateTime? updatedAt,
    List<RfidTagHistoryEntry>? tagHistory,
    bool preserveLegacyWeights = false,
  }) async {
    final normalized = tagUid == null ? null : normalizeRfidTagUid(tagUid);
    if (normalized != null && normalized.isEmpty) {
      throw ArgumentError.value(tagUid, 'tagUid', '标签 UID 不能为空');
    }
    if (cycle < 1) throw ArgumentError.value(cycle, 'cycle', '标签周期必须从 1 开始');
    if (!validConsumableLifecycleStatuses.contains(status)) {
      throw ArgumentError.value(status, 'status', '未知的耗材生命周期状态');
    }
    final normalizedType = tagType?.trim();
    final normalizedPrevious = previousInventoryUid?.trim();
    if (normalized != null && !preserveLegacyWeights) {
      final item = await getById(consumableId);
      if (item != null && !await isFarmConsumable(consumableId)) {
        _requireStandardPersonalSpool(item);
        final previous = await getRfidSpoolBindingById(consumableId);
        final activating =
            previous == null ||
            previous.tagUid != normalized ||
            previous.cycle != cycle ||
            previous.status != 'active';
        if (status == 'active' &&
            activating &&
            !canReusePersonalSpool(item.remainingGrams)) {
          throw StateError('余量必须大于 30 g 才能装入或继续使用耗材卷');
        }
      }
    }
    await customUpdate(
      'UPDATE consumables SET rfid_tag_uid = ?, rfid_tag_type = ?, '
      'rfid_tag_cycle = ?, lifecycle_status = ?, previous_consumable_uid = ?, '
      'updated_at = ? WHERE id = ?',
      variables: [
        normalized == null
            ? const Variable(null)
            : Variable<String>(normalized),
        normalizedType == null || normalizedType.isEmpty
            ? const Variable(null)
            : Variable<String>(normalizedType),
        Variable<int>(cycle),
        Variable<String>(status),
        normalizedPrevious == null || normalizedPrevious.isEmpty
            ? const Variable(null)
            : Variable<String>(normalizedPrevious),
        Variable<DateTime>(updatedAt ?? DateTime.now()),
        Variable<int>(consumableId),
      ],
      updates: {consumables},
    );
    if (tagHistory != null && attachedDatabase.schemaVersion >= 54) {
      await customUpdate(
        'UPDATE consumables SET rfid_tag_history = ? WHERE id = ?',
        variables: [
          Variable(
            jsonEncode(tagHistory.map((entry) => entry.toJson()).toList()),
          ),
          Variable(consumableId),
        ],
        updates: {consumables},
      );
    }
  }

  RfidSpoolBinding _rfidBindingFromRow(QueryRow row) {
    return RfidSpoolBinding(
      consumableId: row.read<int>('id'),
      inventoryUid: row.read<String>('uid'),
      tagUid: row.read<String?>('rfid_tag_uid') ?? '',
      tagType: row.read<String?>('rfid_tag_type'),
      cycle: row.read<int?>('rfid_tag_cycle') ?? 1,
      status: row.read<String?>('lifecycle_status') ?? 'active',
      previousInventoryUid: row.read<String?>('previous_consumable_uid'),
      tagHistory: RfidTagHistoryEntry.parseList(
        jsonDecode(row.read<String>('rfid_tag_history')),
      ),
    );
  }

  /// Looks up a personal row without applying an account filter. This method
  /// is intentionally explicit and is used only for ownership checks (for
  /// example, rejecting a logged-out write against another account's tag).
  Future<Consumable?> getAnyPersonalByTrayUuid(String trayUuid) async {
    final normalized = trayUuid.trim();
    if (normalized.isEmpty) return null;
    final row = await customSelect(
      "SELECT id FROM consumables "
      "WHERE inventory_scope = 'personal' "
      "AND lower(trim(tray_uuid)) = lower(trim(?)) LIMIT 1",
      variables: [Variable<String>(normalized)],
    ).getSingleOrNull();
    if (row == null) return null;
    return getById(row.read<int>('id'));
  }

  /// Inserts or updates one account-synchronised personal inventory row.
  ///
  /// The companion deliberately writes every shared field so a desktop pull
  /// cannot leave stale color, remaining-weight, or RFID metadata behind.
  /// [preserveLegacyWeights] is reserved for synchronization of existing
  /// historical records. It preserves evidence without authorizing use of a
  /// non-standard spool; receipt, binding and consumption entries reject it.
  Future<int> upsertPersonalInventoryRecord(
    PersonalInventoryRecord record, {
    String? ownerAccount,
    bool preserveLegacyWeights = false,
  }) async {
    return transaction(() async {
      final source = PersonalRfidStockSource.fromRecord(
        record,
        preserveLegacyWeights: preserveLegacyWeights,
      );
      final existing = await getPersonalByUid(
        record.uid,
        ownerAccount: ownerAccount,
      );
      final individual =
          record.rfidTagUid?.trim().isNotEmpty == true ||
          source != null ||
          (existing != null && await isIndividualPersonalSpool(existing.id));
      if (individual && !preserveLegacyWeights) {
        _requireStandardPersonalSpoolWeights(
          record.totalGrams,
          record.remainingGrams,
        );
      }
      if (existing != null && source != null) {
        // Validate provenance before writing any weight or metadata.
        await PersonalRfidStockStore(
          attachedDatabase,
        ).setSource(existing.id, source);
      }
      final companion = ConsumablesCompanion(
        id: existing == null ? const Value.absent() : Value(existing.id),
        uid: Value(record.uid),
        manufacturer: Value(record.manufacturer),
        model: Value(record.model),
        materialType: Value(record.materialType),
        colorHex: Value(record.colorHex),
        colorName: Value(record.colorName),
        totalGrams: Value(record.totalGrams),
        remainingGrams: Value(record.remainingGrams),
        batchNo: Value(record.batchNo),
        purchaseDate: Value(record.purchaseDate),
        note: Value(record.note),
        createdAt: Value(record.createdAt),
        updatedAt: Value(record.updatedAt),
        density: Value(record.density),
        recommendedNozzleTemp: Value(record.recommendedNozzleTemp),
        hygroscopicity: Value(record.hygroscopicity),
        trayUuid: Value(record.trayUuid),
        rfidSyncedAt: Value(record.rfidSyncedAt),
      );
      if (existing == null) {
        final id = await addConsumable(
          ConsumablesCompanion.insert(
            uid: Value(record.uid),
            manufacturer: record.manufacturer,
            model: record.model,
            materialType: Value(record.materialType),
            colorHex: Value(record.colorHex),
            colorName: Value(record.colorName),
            totalGrams: Value(record.totalGrams),
            remainingGrams: Value(record.remainingGrams),
            batchNo: Value(record.batchNo),
            purchaseDate: Value(record.purchaseDate),
            note: Value(record.note),
            createdAt: Value(record.createdAt),
            updatedAt: Value(record.updatedAt),
            density: Value(record.density),
            recommendedNozzleTemp: Value(record.recommendedNozzleTemp),
            hygroscopicity: Value(record.hygroscopicity),
            trayUuid: Value(record.trayUuid),
            rfidSyncedAt: Value(record.rfidSyncedAt),
          ),
        );
        if (ownerAccount?.trim().isNotEmpty == true) {
          await setOwnerAccount(id, ownerAccount!.trim());
        }
        await setRfidSpoolBinding(
          id,
          tagUid: record.rfidTagUid,
          tagType: record.rfidTagType,
          cycle: record.rfidTagCycle,
          status: record.lifecycleStatus,
          previousInventoryUid: record.previousConsumableUid,
          tagHistory: record.rfidTagHistory,
          updatedAt: record.updatedAt,
          preserveLegacyWeights: preserveLegacyWeights,
        );
        await PersonalRfidStockStore(attachedDatabase).setSource(id, source);
        return id;
      }
      await updateConsumable(
        companion,
        preserveLegacyWeights: preserveLegacyWeights,
      );
      if (ownerAccount?.trim().isNotEmpty == true) {
        await setOwnerAccount(existing.id, ownerAccount!.trim());
      }
      await setRfidSpoolBinding(
        existing.id,
        tagUid: record.rfidTagUid,
        tagType: record.rfidTagType,
        cycle: record.rfidTagCycle,
        status: record.lifecycleStatus,
        previousInventoryUid: record.previousConsumableUid,
        tagHistory: record.rfidTagHistory,
        updatedAt: record.updatedAt,
        preserveLegacyWeights: preserveLegacyWeights,
      );
      return existing.id;
    });
  }

  Future<int> addConsumable(ConsumablesCompanion entry) async {
    final id = await into(consumables).insert(entry);
    await customUpdate(
      "UPDATE consumables SET uid = ? WHERE id = ? AND (uid IS NULL OR trim(uid) = '')",
      variables: [Variable(const Uuid().v4()), Variable(id)],
      updates: {consumables},
    );
    return id;
  }

  void _requireStandardPersonalSpool(Consumable item) =>
      _requireStandardPersonalSpoolWeights(
        item.totalGrams,
        item.remainingGrams,
      );

  void _requireStandardPersonalSpoolWeights(double total, double remaining) {
    if (total != personalSpoolCapacityGrams ||
        !remaining.isFinite ||
        remaining < 0 ||
        remaining > personalSpoolCapacityGrams) {
      throw StateError('每卷规格固定为 1000 g，余量须在 0 至 1000 g；历史异常重量已保留，请先核对');
    }
  }

  Future<void> setInventoryScope(
    int id, {
    required String scope,
    String? farmWorkspaceId,
  }) async {
    if (scope != personalInventoryScope && scope != farmInventoryScope) {
      throw ArgumentError.value(scope, 'scope', '未知的库存域');
    }
    if (scope == farmInventoryScope &&
        (farmWorkspaceId == null || farmWorkspaceId.trim().isEmpty)) {
      throw ArgumentError.value(
        farmWorkspaceId,
        'farmWorkspaceId',
        '农场库存必须关联工作区',
      );
    }
    await customUpdate(
      'UPDATE consumables SET inventory_scope = ?, farm_workspace_id = ? '
      'WHERE id = ?',
      variables: [
        Variable<String>(scope),
        Variable(scope == farmInventoryScope ? farmWorkspaceId : null),
        Variable<int>(id),
      ],
      updates: {consumables},
    );
  }

  Future<int> addFarmConsumable(
    ConsumablesCompanion entry, {
    required String workspaceId,
  }) async {
    final id = await addConsumable(entry);
    await setInventoryScope(
      id,
      scope: farmInventoryScope,
      farmWorkspaceId: workspaceId,
    );
    return id;
  }

  /// 新增耗材并设置归属账号（多账号隔离用）。
  ///
  /// [ownerAccount] 是账号作用域的不透明键，null 表示未关联账号。
  /// 返回新插入的耗材 id。
  Future<int> addConsumableWithOwner(
    ConsumablesCompanion entry, {
    String? ownerAccount,
  }) async {
    final id = await addConsumable(entry);
    if (ownerAccount != null) {
      await setOwnerAccount(id, ownerAccount);
    }
    return id;
  }

  Future<bool> updateConsumable(
    ConsumablesCompanion entry, {
    bool preserveLegacyWeights = false,
  }) async {
    if (!preserveLegacyWeights &&
        (entry.totalGrams.present || entry.remainingGrams.present)) {
      final current = await getById(entry.id.value);
      if (current != null && await isIndividualPersonalSpool(current.id)) {
        _requireStandardPersonalSpoolWeights(
          entry.totalGrams.present
              ? entry.totalGrams.value
              : current.totalGrams,
          entry.remainingGrams.present
              ? entry.remainingGrams.value
              : current.remainingGrams,
        );
      }
    }
    return (update(consumables)..where((t) => t.id.equals(entry.id.value)))
        .write(entry)
        .then((rows) => rows > 0);
  }

  /// 将当前农场的一组仓库库存余量归零，保留批次、装机和生产历史。
  Future<void> archiveFarmConsumables(
    Iterable<int> ids, {
    required String workspaceId,
  }) async {
    return setFarmConsumablesArchived(
      ids,
      workspaceId: workspaceId,
      archived: true,
    );
  }

  Future<void> restoreFarmConsumables(
    Iterable<int> ids, {
    required String workspaceId,
  }) {
    return setFarmConsumablesArchived(
      ids,
      workspaceId: workspaceId,
      archived: false,
    );
  }

  Future<void> setFarmConsumablesArchived(
    Iterable<int> ids, {
    required String workspaceId,
    required bool archived,
  }) async {
    final uniqueIds = ids.toSet().toList();
    if (uniqueIds.isEmpty) return;
    final placeholders = List.filled(uniqueIds.length, '?').join(',');
    await transaction(() async {
      final updated = await customUpdate(
        'UPDATE consumables SET archived = ?, archived_at = ?, updated_at = ? '
        "WHERE inventory_scope = 'farm' AND farm_workspace_id = ? "
        'AND id IN ($placeholders)',
        variables: [
          Variable(archived ? 1 : 0),
          Variable(
            archived ? DateTime.now().millisecondsSinceEpoch ~/ 1000 : null,
          ),
          Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable(workspaceId),
          for (final id in uniqueIds) Variable(id),
        ],
        updates: {consumables},
      );
      if (updated != uniqueIds.length) {
        throw StateError('部分库存不属于当前农场，状态更新已拒绝');
      }
    });
  }

  Future<Map<int, FarmConsumableMetadata>> getFarmConsumableMetadata(
    Iterable<int> ids, {
    required String workspaceId,
  }) async {
    final uniqueIds = ids.toSet().toList();
    if (uniqueIds.isEmpty) return const {};
    final placeholders = List.filled(uniqueIds.length, '?').join(',');
    final rows = await customSelect(
      'SELECT id, archived, archived_at, brand_code, color_mode, '
      'secondary_color_hex FROM consumables '
      "WHERE inventory_scope = 'farm' AND farm_workspace_id = ? "
      'AND id IN ($placeholders)',
      variables: [
        Variable(workspaceId),
        for (final id in uniqueIds) Variable(id),
      ],
    ).get();
    return {
      for (final row in rows)
        row.read<int>('id'): FarmConsumableMetadata(
          archived: row.read<int>('archived') == 1,
          archivedAt: switch (row.read<int?>('archived_at')) {
            final value? => DateTime.fromMillisecondsSinceEpoch(value * 1000),
            null => null,
          },
          brandCode: row.read<String?>('brand_code'),
          colorMode: row.read<String?>('color_mode') ?? 'solid',
          secondaryColorHex: row.read<String?>('secondary_color_hex'),
        ),
    };
  }

  Future<void> updateFarmConsumableMetadata(
    Iterable<int> ids, {
    required String workspaceId,
    required String brandCode,
    required String colorMode,
    String? secondaryColorHex,
  }) async {
    final uniqueIds = ids.toSet().toList();
    if (uniqueIds.isEmpty) return;
    final placeholders = List.filled(uniqueIds.length, '?').join(',');
    final updated = await customUpdate(
      'UPDATE consumables SET brand_code = ?, color_mode = ?, '
      'secondary_color_hex = ?, updated_at = ? '
      "WHERE inventory_scope = 'farm' AND farm_workspace_id = ? "
      'AND id IN ($placeholders)',
      variables: [
        Variable(brandCode),
        Variable(colorMode),
        Variable(secondaryColorHex),
        Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
        Variable(workspaceId),
        for (final id in uniqueIds) Variable(id),
      ],
      updates: {consumables},
    );
    if (updated != uniqueIds.length) {
      throw StateError('部分库存不属于当前农场，元数据更新已拒绝');
    }
  }

  Future<int> deleteConsumable(int id) {
    return transaction(() async {
      final row = await customSelect(
        'SELECT uid, inventory_scope, owner_account, rfid_tag_uid FROM consumables WHERE id = ? LIMIT 1',
        variables: [Variable<int>(id)],
      ).getSingleOrNull();
      if (row != null &&
          row.read<String?>('inventory_scope') == personalInventoryScope) {
        if (row.read<String?>('rfid_tag_uid')?.trim().isNotEmpty == true) {
          throw StateError('带 RFID 标签的耗材卷不能物理删除，请使用“归档耗材卷”保留生命周期历史');
        }
        await _assertPersonalStockDeletionAllowed(id);
        final uid = row.read<String?>('uid')?.trim() ?? '';
        final owner = row.read<String?>('owner_account')?.trim() ?? '';
        if (uid.isNotEmpty && owner.isNotEmpty) {
          await customStatement(
            'INSERT INTO personal_inventory_tombstones(owner_account, uid, deleted_at) '
            'VALUES (?, ?, ?) ON CONFLICT(owner_account, uid) DO UPDATE SET '
            'deleted_at = MAX(deleted_at, excluded.deleted_at)',
            [owner, uid, DateTime.now().millisecondsSinceEpoch],
          );
        }
      }
      return (delete(consumables)..where((t) => t.id.equals(id))).go();
    });
  }

  /// Received stock is one physical spool even before a tag is activated.
  /// A delete must not clear its live task/channel foreign keys and silently
  /// stop consumption accounting. Call from the same transaction as deletion.
  Future<void> _assertPersonalStockDeletionAllowed(int id) async {
    if (!(await getPersonalRfidStockSourcesMap([id])).containsKey(id)) return;
    final pending = await customSelect(
      'SELECT 1 FROM print_task_consumables WHERE consumable_id = ? '
      'AND consumed_at IS NULL LIMIT 1',
      variables: [Variable(id)],
    ).getSingleOrNull();
    if (pending != null) {
      throw StateError('该独立库存卷仍有未结算任务，请先完成任务结算再删除');
    }
    final loaded = await customSelect(
      'SELECT 1 FROM printer_channels WHERE consumable_id = ? LIMIT 1',
      variables: [Variable(id)],
    ).getSingleOrNull();
    if (loaded != null) {
      throw StateError('该独立库存卷仍装在供料位，请先卸料再删除');
    }
  }

  Future<Map<String, DateTime>> getPersonalInventoryTombstones(
    String ownerAccount,
  ) async {
    final normalizedOwner = ownerAccount.trim();
    if (normalizedOwner.isEmpty) return const {};
    final rows = await customSelect(
      'SELECT uid, deleted_at FROM personal_inventory_tombstones '
      'WHERE lower(trim(owner_account)) = lower(trim(?)) ORDER BY deleted_at ASC',
      variables: [Variable<String>(normalizedOwner)],
    ).get();
    final result = <String, DateTime>{};
    for (final row in rows) {
      final uid = row.read<String>('uid').trim();
      if (uid.isEmpty) continue;
      final key = uid.toLowerCase();
      final timestamp = DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('deleted_at'),
        isUtc: true,
      );
      final current = result[key];
      if (current == null || timestamp.isAfter(current))
        result[key] = timestamp;
    }
    return result;
  }

  Future<void> removePersonalInventoryTombstone(
    String ownerAccount,
    String uid,
  ) async {
    final owner = ownerAccount.trim();
    final normalizedUid = uid.trim();
    if (owner.isEmpty || normalizedUid.isEmpty) return;
    await customStatement(
      'DELETE FROM personal_inventory_tombstones '
      'WHERE lower(trim(owner_account)) = lower(trim(?)) '
      'AND lower(trim(uid)) = lower(trim(?))',
      [owner, normalizedUid],
    );
  }

  Future<int> deletePersonalByUid(String uid, {required String ownerAccount}) =>
      transaction(() async {
        final normalizedUid = uid.trim();
        final owner = ownerAccount.trim();
        if (normalizedUid.isEmpty || owner.isEmpty) return 0;
        final tagged = await customSelect(
          'SELECT id FROM consumables WHERE lower(trim(uid)) = lower(trim(?)) '
          'AND inventory_scope = ? '
          "AND (lower(trim(owner_account)) = lower(trim(?)) "
          "OR owner_account IS NULL OR trim(owner_account) = '') "
          "AND coalesce(trim(rfid_tag_uid), '') != '' LIMIT 1",
          variables: [
            Variable<String>(normalizedUid),
            Variable<String>(personalInventoryScope),
            Variable<String>(owner),
          ],
        ).getSingleOrNull();
        if (tagged != null) {
          throw StateError('带 RFID 标签的历史耗材不能物理删除，请改为归档');
        }
        final targets = await customSelect(
          'SELECT id FROM consumables WHERE lower(trim(uid)) = lower(trim(?)) '
          'AND inventory_scope = ? '
          'AND (lower(trim(owner_account)) = lower(trim(?)) '
          "OR owner_account IS NULL OR trim(owner_account) = '')",
          variables: [
            Variable<String>(normalizedUid),
            Variable<String>(personalInventoryScope),
            Variable<String>(owner),
          ],
        ).get();
        for (final target in targets) {
          await _assertPersonalStockDeletionAllowed(target.read<int>('id'));
        }
        final result = await customUpdate(
          'DELETE FROM consumables WHERE lower(trim(uid)) = lower(trim(?)) '
          'AND inventory_scope = ? '
          "AND (lower(trim(owner_account)) = lower(trim(?)) "
          "OR owner_account IS NULL OR trim(owner_account) = '')",
          variables: [
            Variable<String>(normalizedUid),
            Variable<String>(personalInventoryScope),
            Variable<String>(owner),
          ],
          updates: {consumables},
        );
        return result;
      });

  /// Returns the number of active/history records that would lose their
  /// material reference. Farm inventory uses this before offering a delete;
  /// a spool that has been bound or consumed is archived instead of silently
  /// destroying production history.
  Future<int> farmConsumableReferenceCount(
    int id, {
    required String workspaceId,
  }) async {
    final row = await customSelect(
      '''SELECT
        (SELECT COUNT(*) FROM printer_channels WHERE consumable_id = ?) +
        (SELECT COUNT(*) FROM studio_work_order_materials
          WHERE consumable_id = ? AND workspace_id = ?) AS refs''',
      variables: [Variable(id), Variable(id), Variable(workspaceId)],
    ).getSingle();
    return row.read<int>('refs');
  }

  Future<void> deleteFarmConsumable(
    int id, {
    required String workspaceId,
  }) async {
    await transaction(() async {
      final item = await customSelect(
        "SELECT id, total_grams FROM consumables WHERE id = ? AND inventory_scope = 'farm' AND farm_workspace_id = ?",
        variables: [Variable(id), Variable(workspaceId)],
      ).getSingleOrNull();
      if (item == null) throw StateError('只能删除当前农场的库存卷');
      final refs = await farmConsumableReferenceCount(
        id,
        workspaceId: workspaceId,
      );
      if (refs > 0) {
        throw StateError('该耗材已绑定打印机或产生生产工单，不能物理删除；请使用“归档库存”');
      }
      final batchItem = await customSelect(
        'SELECT item.batch_id, item.roll_count, batch.roll_count AS batch_roll_count '
        'FROM studio_inventory_batch_items item '
        'JOIN studio_inventory_batches batch ON batch.id = item.batch_id '
        'WHERE item.consumable_id = ?',
        variables: [Variable(id)],
      ).getSingleOrNull();
      if (batchItem != null) {
        final batchId = batchItem.read<String>('batch_id');
        final rollCount = batchItem.read<int>('roll_count');
        final batchRollCount = batchItem.read<int>('batch_roll_count');
        if (rollCount >= batchRollCount) {
          await customUpdate(
            'DELETE FROM studio_inventory_batches WHERE id = ?',
            variables: [Variable(batchId)],
          );
        } else {
          await customUpdate(
            'UPDATE studio_inventory_batches SET '
            'roll_count = roll_count - ?, '
            'total_grams = MAX(0, total_grams - ?) WHERE id = ?',
            variables: [
              Variable(rollCount),
              Variable(item.read<double>('total_grams')),
              Variable(batchId),
            ],
          );
        }
      }
      await deleteConsumable(id);
    });
  }

  /// A tagged row is one fixed 1000 g spool with its exact remaining balance.
  /// Aggregate inventory may contain multiple 1000 g rolls.
  Future<double> deductOneRoll(int id) async {
    return transaction(() async {
      final item = await getById(id);
      if (item == null) return 0.0;
      if (item.remainingGrams <= 0) return 0.0;
      final binding = await getRfidSpoolBindingById(id);
      final tagged =
          binding?.tagUid.isNotEmpty == true && !await isFarmConsumable(id);
      final individual =
          tagged ||
          (await getPersonalRfidStockSourcesMap([id])).containsKey(id);
      if (individual) _requireStandardPersonalSpool(item);
      if (individual) {
        if (binding != null && !binding.isActive)
          throw StateError('历史卷已结束标签关联，不能继续扣料');
        final pending = await customSelect(
          'SELECT id FROM print_task_consumables WHERE consumable_id = ? AND consumed_at IS NULL LIMIT 1',
          variables: [Variable(id)],
        ).getSingleOrNull();
        if (pending != null) throw StateError('该卷仍有未结算任务，请先完成任务结算');
      }
      final consumed = individual
          ? item.remainingGrams
          : item.remainingGrams >= gramsPerRoll
          ? gramsPerRoll
          : item.remainingGrams;
      final next = math.max(0.0, item.remainingGrams - consumed);
      await (update(consumables)..where((t) => t.id.equals(id))).write(
        ConsumablesCompanion(
          remainingGrams: Value(next),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await _syncRfidLifecycleForRemaining(id, next);
      if (individual) {
        await customStatement(
          'INSERT INTO personal_inventory_events(event_uid, owner_account, inventory_uid, '
          'rfid_tag_uid, rfid_tag_cycle, event_type, before_grams, after_grams, delta_grams, '
          'occurred_at, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            const Uuid().v4(),
            await getOwnerAccount(id),
            item.uid,
            tagged ? binding!.tagUid : null,
            tagged ? binding!.cycle : null,
            'manual_consumption',
            item.remainingGrams,
            next,
            -consumed,
            DateTime.now().millisecondsSinceEpoch,
            'manual',
          ],
        );
      }
      return consumed;
    });
  }

  /// 增加 1 卷（1000g）。用于卡片加号按钮，纯库存调整，不写日志。
  /// 注意：不修改 totalGrams（totalGrams 代表初始入库总量，保持不变）。
  /// 返回新增后的剩余克数。
  Future<double> addOneRoll(int id) async {
    return addRolls(id, 1);
  }

  /// 一次补入多卷同款耗材。用于打印方案发现余量不足时原子补齐库存。
  Future<double> addRolls(int id, int rolls) async {
    if (rolls <= 0) {
      final item = await getById(id);
      return item?.remainingGrams ?? 0.0;
    }
    return transaction(() async {
      final item = await getById(id);
      if (item == null) return 0.0;
      if (await isIndividualPersonalSpool(id) && !await isFarmConsumable(id)) {
        throw StateError('这是一卷独立库存，请通过资料卡另行加库存，不能把多卷克数并入旧卷');
      }
      final next = item.remainingGrams + gramsPerRoll * rolls;
      await (update(consumables)..where((t) => t.id.equals(id))).write(
        ConsumablesCompanion(
          remainingGrams: Value(next),
          updatedAt: Value(DateTime.now()),
        ),
      );
      return next;
    });
  }

  /// 按克数扣减/回补耗材库存。
  ///
  /// [grams] 为正数表示扣减（消耗），为负数表示回补（完成修正时多扣的加回）。
  /// 扣减到 0 为止（不会变负）。remainingGrams 可以包含后来补充的多卷库存，
  /// 因此不能再用初始 totalGrams 作为上限。
  ///
  /// 用于「实时扣减+完成修正」策略：
  /// - 打印中：grams = 本次估算消耗 - 上次估算消耗（正数，扣减）
  /// - 完成时：grams = 最终实际消耗 - 实时已扣减（正负皆可，修正差额）
  ///
  /// 返回实际扣减/回补的克数（库存不足时可能小于传入扣减值）。
  Future<double> adjustGrams(int id, double grams) async {
    if (!grams.isFinite) throw ArgumentError('消耗克数必须是有限数值');
    if (grams == 0) return 0;
    return transaction(() async {
      final item = await getById(id);
      if (item == null) return 0.0;
      final binding = await getRfidSpoolBindingById(id);
      final tagged =
          binding?.tagUid.isNotEmpty == true && !await isFarmConsumable(id);
      final individual =
          tagged ||
          (await getPersonalRfidStockSourcesMap([id])).containsKey(id);
      if (individual &&
          (binding!.status == 'replaced' || binding.status == 'retired')) {
        throw StateError('历史卷已结束标签关联，拒绝延迟扣料或回补');
      }
      if (individual) _requireStandardPersonalSpool(item);
      if (tagged) {
        final history = await getPersonalRfidSpoolHistory(
          binding!.tagUid,
          ownerAccount: await getOwnerAccount(id),
        );
        if (history.any(
          (next) =>
              next.cycle == binding.cycle + 1 &&
              next.previousInventoryUid?.toLowerCase() ==
                  item.uid.toLowerCase(),
        )) {
          throw StateError('标签已换入新卷，不能再修改旧卷余量');
        }
      }
      var next = item.remainingGrams - grams; // grams>0 扣减，grams<0 回补
      // 只约束下限。补充多卷后 remainingGrams 合法地可能大于 totalGrams。
      if (next < 0) next = 0;
      if (individual && next > personalSpoolCapacityGrams) {
        next = personalSpoolCapacityGrams;
      }
      final actual = item.remainingGrams - next;
      await (update(consumables)..where((t) => t.id.equals(id))).write(
        ConsumablesCompanion(
          remainingGrams: Value(next),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await _syncRfidLifecycleForRemaining(id, next);
      return actual;
    });
  }

  Future<void> _syncRfidLifecycleForRemaining(int id, double remaining) async {
    await customUpdate(
      'UPDATE consumables SET lifecycle_status = ? WHERE id = ? '
      "AND inventory_scope = 'personal' AND (coalesce(trim(rfid_tag_uid), '') != '' "
      '${attachedDatabase.schemaVersion >= 56 ? 'OR source_rfid_tag_uid IS NOT NULL' : ''}) '
      "AND lifecycle_status IN ('active', 'depleted')",
      variables: [
        Variable(remaining <= 0 ? 'depleted' : 'active'),
        Variable(id),
      ],
      updates: {consumables},
    );
  }

  /// 按 trayUuid 查耗材（拓竹原厂料装机自动识别用）。
  Future<Consumable?> getByTrayUuid(String trayUuid) async {
    final normalized = trayUuid.trim();
    if (normalized.isEmpty) return null;
    final rows = await customSelect(
      'SELECT * FROM consumables '
      'WHERE lower(trim(tray_uuid)) = lower(trim(?)) LIMIT 1',
      variables: [Variable<String>(normalized)],
    ).get();
    if (rows.isEmpty) return null;
    return rowToConsumable(rows.first);
  }

  /// 更新普通用户 RFID 耗材余量。
  ///
  /// 农场行代表仓库整卷数量，RFID 单卷克数只能写入打印机槽位，
  /// 因此这里用库存域条件做最后一道防串账保护。
  Future<void> updateRfidSync({
    required int consumableId,
    required double remainingGrams,
  }) async {
    if (!remainingGrams.isFinite) return;
    final item = await getById(consumableId);
    if (item == null) return;
    if ((await getPersonalRfidStockSourcesMap([
      consumableId,
    ])).containsKey(consumableId))
      return;
    if (await isIndividualPersonalSpool(consumableId)) {
      _requireStandardPersonalSpool(item);
    } else if (item.totalGrams != personalSpoolCapacityGrams ||
        item.remainingGrams > personalSpoolCapacityGrams) {
      // One RFID reading must never replace a multi-roll aggregate balance.
      return;
    }
    final singleRollGrams = remainingGrams
        .clamp(0.0, personalSpoolCapacityGrams)
        .toDouble();
    await customUpdate(
      'UPDATE consumables SET remaining_grams = ?, rfid_synced_at = ?, '
      "updated_at = ? WHERE id = ? AND inventory_scope != 'farm' "
      "AND (coalesce(trim(rfid_tag_uid), '') = '' OR lifecycle_status = 'active')",
      variables: [
        Variable<double>(singleRollGrams),
        Variable<int>(DateTime.now().millisecondsSinceEpoch),
        Variable<int>(_epochSeconds()),
        Variable<int>(consumableId),
      ],
      updates: {consumables},
    );
  }

  /// 更新耗材的 trayUuid（拓竹原厂料首次装机时建立关联）。
  Future<void> updateTrayUuid(int consumableId, String trayUuid) async {
    await customUpdate(
      'UPDATE consumables SET tray_uuid = ?, updated_at = ? WHERE id = ?',
      variables: [
        Variable<String>(trayUuid),
        Variable<int>(_epochSeconds()),
        Variable<int>(consumableId),
      ],
      updates: {consumables},
    );
  }

  /// raw SQL 行转 [Consumable] 模型（含 v14 数字孪生字段 trayUuid / rfidSyncedAt）。
  ///
  /// 生成的 $ConsumablesTable.map 不含 v14 列（build_runner 不可用），
  /// 用此方法手动读取全部列，包括 tray_uuid 和 rfid_synced_at。
  Consumable rowToConsumable(QueryRow row) {
    return Consumable(
      id: row.read<int>('id'),
      uid: row.read<String>('uid'),
      manufacturer: row.read<String>('manufacturer'),
      model: row.read<String>('model'),
      materialType: row.read<String>('material_type'),
      colorHex: row.read<String>('color_hex'),
      colorName: row.read<String?>('color_name'),
      totalGrams: row.read<double>('total_grams'),
      remainingGrams: row.read<double>('remaining_grams'),
      batchNo: row.read<String?>('batch_no'),
      purchaseDate: row.read<DateTime?>('purchase_date'),
      note: row.read<String?>('note'),
      createdAt: row.read<DateTime>('created_at'),
      updatedAt: row.read<DateTime>('updated_at'),
      trayUuid: row.read<String?>('tray_uuid'),
      rfidSyncedAt: row.read<int?>('rfid_synced_at'),
    );
  }

  int _epochSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
