import 'dart:async';

import 'package:drift/drift.dart';

import '../data/database/database.dart';
import '../data/models/rfid_tag_identity.dart';

/// One local audit record for a phone NFC tag operation.
///
/// This is deliberately separate from the current inventory row. The
/// inventory row answers "what is this spool now?" while this table answers
/// "which tag was written/read, when and with what result?". A tag UID is not
/// unique here: CUID/FUID cards may intentionally share a UID and a user may
/// rewrite the same card many times.
class RfidTagRecord {
  const RfidTagRecord({
    this.id,
    required this.tagUid,
    this.tagType = '',
    this.technology = '',
    this.profile = 'ams',
    this.operation = 'write',
    this.status = 'success',
    this.inventoryUid,
    this.ownerAccount,
    this.brand = '',
    this.model = '',
    this.colorHex = '',
    this.colorName,
    this.bytesWritten,
    this.bytesRead,
    this.blocksWritten,
    this.blocksVerified,
    this.pagesWritten,
    this.pagesRead,
    this.verified = false,
    this.message,
    required this.occurredAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? occurredAt,
       updatedAt = updatedAt ?? occurredAt;

  final int? id;
  final String tagUid;
  final String tagType;
  final String technology;
  final String profile;
  final String operation;
  final String status;
  final String? inventoryUid;
  final String? ownerAccount;
  final String brand;
  final String model;
  final String colorHex;
  final String? colorName;
  final int? bytesWritten;
  final int? bytesRead;
  final int? blocksWritten;
  final int? blocksVerified;
  final int? pagesWritten;
  final int? pagesRead;
  final bool verified;
  final String? message;
  final DateTime occurredAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get succeeded => status.trim().toLowerCase() == 'success';

  /// History is retained for diagnostics, but only confirmed consumable tags
  /// may supply a spool or material-template picker.
  bool get isConsumableTagRecord =>
      profile.trim().toLowerCase() == 'ams' &&
      isConsumableRfidTagType(tagType) &&
      !technology.toLowerCase().contains('ntag') &&
      !technology.toLowerCase().contains('ultralight');

  RfidTagRecord copyWith({
    int? id,
    String? tagUid,
    String? tagType,
    String? technology,
    String? profile,
    String? operation,
    String? status,
    String? inventoryUid,
    String? ownerAccount,
    String? brand,
    String? model,
    String? colorHex,
    String? colorName,
    int? bytesWritten,
    int? bytesRead,
    int? blocksWritten,
    int? blocksVerified,
    int? pagesWritten,
    int? pagesRead,
    bool? verified,
    String? message,
    DateTime? occurredAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return RfidTagRecord(
      id: id ?? this.id,
      tagUid: tagUid ?? this.tagUid,
      tagType: tagType ?? this.tagType,
      technology: technology ?? this.technology,
      profile: profile ?? this.profile,
      operation: operation ?? this.operation,
      status: status ?? this.status,
      inventoryUid: inventoryUid ?? this.inventoryUid,
      ownerAccount: ownerAccount ?? this.ownerAccount,
      brand: brand ?? this.brand,
      model: model ?? this.model,
      colorHex: colorHex ?? this.colorHex,
      colorName: colorName ?? this.colorName,
      bytesWritten: bytesWritten ?? this.bytesWritten,
      bytesRead: bytesRead ?? this.bytesRead,
      blocksWritten: blocksWritten ?? this.blocksWritten,
      blocksVerified: blocksVerified ?? this.blocksVerified,
      pagesWritten: pagesWritten ?? this.pagesWritten,
      pagesRead: pagesRead ?? this.pagesRead,
      verified: verified ?? this.verified,
      message: message ?? this.message,
      occurredAt: occurredAt ?? this.occurredAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory RfidTagRecord.fromRow(QueryRow row) {
    final occurredAt = _dateFromMilliseconds(row.read<int>('occurred_at'));
    final createdAt = _dateFromMilliseconds(row.read<int>('created_at'));
    final updatedAt = _dateFromMilliseconds(row.read<int>('updated_at'));
    return RfidTagRecord(
      id: row.read<int?>('id'),
      tagUid: row.read<String>('tag_uid'),
      tagType: row.read<String>('tag_type'),
      technology: row.read<String>('technology'),
      profile: row.read<String>('profile'),
      operation: row.read<String>('operation'),
      status: row.read<String>('status'),
      inventoryUid: row.read<String?>('inventory_uid'),
      ownerAccount: row.read<String?>('owner_account'),
      brand: row.read<String>('brand'),
      model: row.read<String>('model'),
      colorHex: row.read<String>('color_hex'),
      colorName: row.read<String?>('color_name'),
      bytesWritten: row.read<int?>('bytes_written'),
      bytesRead: row.read<int?>('bytes_read'),
      blocksWritten: row.read<int?>('blocks_written'),
      blocksVerified: row.read<int?>('blocks_verified'),
      pagesWritten: row.read<int?>('pages_written'),
      pagesRead: row.read<int?>('pages_read'),
      verified: (row.read<int?>('verified') ?? 0) != 0,
      message: row.read<String?>('message'),
      occurredAt: occurredAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'id': id,
    'tag_uid': tagUid,
    'tag_type': tagType,
    'technology': technology,
    'profile': profile,
    'operation': operation,
    'status': status,
    'inventory_uid': inventoryUid,
    'owner_account': ownerAccount,
    'brand': brand,
    'model': model,
    'color_hex': colorHex,
    'color_name': colorName,
    'bytes_written': bytesWritten,
    'bytes_read': bytesRead,
    'blocks_written': blocksWritten,
    'blocks_verified': blocksVerified,
    'pages_written': pagesWritten,
    'pages_read': pagesRead,
    'verified': verified ? 1 : 0,
    'message': message,
    'occurred_at': occurredAt.millisecondsSinceEpoch,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  static DateTime _dateFromMilliseconds(int milliseconds) =>
      DateTime.fromMillisecondsSinceEpoch(milliseconds);
}

/// Local append-only storage for CUID/FUID/NTAG operation history.
///
/// Raw card blocks, authentication keys and signatures never enter this
/// repository. Only the UID, safe tag metadata and the app-owned consumable
/// fields are retained, so the history can be displayed without making it a
/// second source of truth for inventory.
class MobileRfidTagRepository extends DatabaseAccessor<AppDatabase> {
  MobileRfidTagRepository(super.db);

  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  /// Broadcast used by [watch]. It only carries an invalidation signal.
  Stream<void> get changeStream => _changeController.stream;

  void _emit() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  /// Append an arbitrary operation record and return its local database ID.
  ///
  /// Empty UIDs are rejected because a history row without a physical tag
  /// cannot be useful for a later rewrite or troubleshooting operation.
  Future<int> record(RfidTagRecord entry) async {
    final tagUid = normalizeRfidTagUid(entry.tagUid);
    if (tagUid.isEmpty) {
      throw ArgumentError.value(entry.tagUid, 'tagUid', '标签 UID 不能为空');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await customInsert(
      '''
      INSERT INTO rfid_tag_records(
        tag_uid, tag_type, technology, profile, operation, status,
        inventory_uid, owner_account, brand, model, color_hex, color_name,
        bytes_written, bytes_read, blocks_written, blocks_verified,
        pages_written, pages_read, verified, message,
        occurred_at, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable(tagUid),
        Variable(entry.tagType.trim()),
        Variable(entry.technology.trim()),
        Variable(_defaultText(entry.profile, 'ams')),
        Variable(_defaultText(entry.operation, 'write')),
        Variable(_defaultText(entry.status, 'success')),
        Variable(_nullableText(entry.inventoryUid)),
        Variable(_normalizedOwner(entry.ownerAccount)),
        Variable(entry.brand.trim()),
        Variable(entry.model.trim()),
        Variable(entry.colorHex.trim()),
        Variable(_nullableText(entry.colorName)),
        Variable(entry.bytesWritten),
        Variable(entry.bytesRead),
        Variable(entry.blocksWritten),
        Variable(entry.blocksVerified),
        Variable(entry.pagesWritten),
        Variable(entry.pagesRead),
        Variable(entry.verified ? 1 : 0),
        Variable(_nullableText(entry.message)),
        Variable(entry.occurredAt.millisecondsSinceEpoch),
        Variable(entry.createdAt.millisecondsSinceEpoch),
        Variable(
          entry.updatedAt.millisecondsSinceEpoch == 0
              ? now
              : entry.updatedAt.millisecondsSinceEpoch,
        ),
      ],
    );
    _emit();
    return id;
  }

  /// Append a successful or failed AMS/CUID/FUID write event.
  Future<int> recordWrite({
    required String tagUid,
    String? tagType,
    String? technology,
    String profile = 'ams',
    String status = 'success',
    String? inventoryUid,
    String? ownerAccount,
    String brand = '',
    String model = '',
    String colorHex = '',
    String? colorName,
    int? bytesWritten,
    int? blocksWritten,
    int? blocksVerified,
    int? pagesWritten,
    bool verified = false,
    String? message,
    DateTime? occurredAt,
  }) {
    final at = occurredAt ?? DateTime.now();
    return record(
      RfidTagRecord(
        tagUid: tagUid,
        tagType: tagType ?? '',
        technology: technology ?? '',
        profile: profile,
        operation: 'write',
        status: status,
        inventoryUid: inventoryUid,
        ownerAccount: ownerAccount,
        brand: brand,
        model: model,
        colorHex: colorHex,
        colorName: colorName,
        bytesWritten: bytesWritten,
        blocksWritten: blocksWritten,
        blocksVerified: blocksVerified,
        pagesWritten: pagesWritten,
        verified: verified,
        message: message,
        occurredAt: at,
      ),
    );
  }

  /// Append a successful or failed tag scan event.
  Future<int> recordScan({
    required String tagUid,
    String? tagType,
    String? technology,
    String profile = 'ams',
    String status = 'success',
    String? inventoryUid,
    String? ownerAccount,
    String brand = '',
    String model = '',
    String colorHex = '',
    String? colorName,
    int? bytesRead,
    int? pagesRead,
    bool verified = false,
    String? message,
    DateTime? occurredAt,
  }) {
    final at = occurredAt ?? DateTime.now();
    return record(
      RfidTagRecord(
        tagUid: tagUid,
        tagType: tagType ?? '',
        technology: technology ?? '',
        profile: profile,
        operation: 'scan',
        status: status,
        inventoryUid: inventoryUid,
        ownerAccount: ownerAccount,
        brand: brand,
        model: model,
        colorHex: colorHex,
        colorName: colorName,
        bytesRead: bytesRead,
        pagesRead: pagesRead,
        verified: verified,
        message: message,
        occurredAt: at,
      ),
    );
  }

  /// Links a scan/write event to the concrete spool instance that was saved.
  ///
  /// Binding is append-only because a reused CUID/FUID must retain every
  /// cycle's relationship instead of moving one mutable pointer.
  Future<int> recordBinding({
    required String tagUid,
    required String inventoryUid,
    String? ownerAccount,
    String? tagType,
    String? technology,
    String profile = 'ams',
    String status = 'success',
    String brand = '',
    String model = '',
    String colorHex = '',
    String? colorName,
    required int cycle,
    String? message,
    DateTime? occurredAt,
  }) {
    final at = occurredAt ?? DateTime.now();
    return record(
      RfidTagRecord(
        tagUid: tagUid,
        tagType: tagType ?? '',
        technology: technology ?? '',
        profile: profile,
        operation: 'bind',
        status: status,
        inventoryUid: inventoryUid,
        ownerAccount: ownerAccount,
        brand: brand,
        model: model,
        colorHex: colorHex,
        colorName: colorName,
        verified: true,
        message: '周期 $cycle${message == null ? '' : ' · $message'}',
        occurredAt: at,
      ),
    );
  }

  /// Return recent records, optionally restricted to an account, tag or
  /// operation. The caller owns the account scope; passing null deliberately
  /// returns all local records for diagnostics.
  Future<List<RfidTagRecord>> list({
    String? ownerAccount,
    String? tagUid,
    String? profile,
    String? operation,
    int limit = 100,
  }) async {
    final conditions = <String>[];
    final variables = <Variable>[];
    // Preserve the distinction between an omitted scope (diagnostic query)
    // and an explicitly blank owner (only rows created while signed out).
    final ownerWasProvided = ownerAccount != null;
    final owner = _normalizedOwner(ownerAccount) ?? '';
    final tag = tagUid == null ? null : normalizeRfidTagUid(tagUid);
    final normalizedProfile = profile?.trim();
    final normalizedOperation = operation?.trim();
    if (ownerWasProvided) {
      if (owner.isEmpty) {
        conditions.add("(owner_account IS NULL OR trim(owner_account) = '')");
      } else {
        conditions.add('lower(trim(owner_account)) = lower(trim(?))');
        variables.add(Variable(owner));
      }
    }
    if (tag != null && tag.isNotEmpty) {
      conditions.add(
        "(lower(trim(tag_uid)) = lower(trim(?)) OR "
        "lower(replace(replace(replace(replace(replace(trim(tag_uid), ' ', ''), ':', ''), '-', ''), '_', ''), '.', '')) = lower(?))",
      );
      variables.add(Variable(tag));
      variables.add(Variable(tag));
    }
    if (normalizedProfile != null && normalizedProfile.isNotEmpty) {
      conditions.add('profile = ?');
      variables.add(Variable(normalizedProfile));
    }
    if (normalizedOperation != null && normalizedOperation.isNotEmpty) {
      conditions.add('operation = ?');
      variables.add(Variable(normalizedOperation));
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final safeLimit = limit.clamp(1, 500);
    final rows = await customSelect(
      'SELECT * FROM rfid_tag_records $where '
      'ORDER BY occurred_at DESC, id DESC LIMIT $safeLimit',
      variables: variables,
    ).get();
    return rows.map(RfidTagRecord.fromRow).toList(growable: false);
  }

  /// Lists reusable physical tags that are present on inventory rows.
  ///
  /// Operation history is intentionally local-only, while the inventory row
  /// (including its `rfid_tag_uid`) is part of the account snapshot synced to
  /// the desktop client.  A newly installed phone can therefore have a
  /// perfectly valid saved tag even though it has no local history rows yet.
  /// This method exposes those rows as picker records without pretending that
  /// the remote snapshot contains a verified NFC read/write event.
  ///
  /// Only explicitly identified CUID/FUID bindings are candidates. Empty or
  /// generic Classic types need a new card-type confirmation before reuse;
  /// neither UID length nor historical inventory metadata proves a card type.
  Future<List<RfidTagRecord>> listInventoryTagBindings({
    String? ownerAccount,
    int limit = 100,
  }) async {
    final conditions = <String>[
      "inventory_scope = 'personal'",
      "coalesce(trim(rfid_tag_uid), '') != ''",
      "lower(trim(rfid_tag_type)) IN ('cuid', 'fuid')",
    ];
    final variables = <Variable>[];
    final ownerWasProvided = ownerAccount != null;
    final owner = _normalizedOwner(ownerAccount) ?? '';
    if (ownerWasProvided) {
      if (owner.isEmpty) {
        conditions.add("(owner_account IS NULL OR trim(owner_account) = '')");
      } else {
        conditions.add(
          "(lower(trim(owner_account)) = lower(trim(?)) "
          "OR owner_account IS NULL OR trim(owner_account) = '')",
        );
        variables.add(Variable(owner));
      }
    }
    final safeLimit = limit.clamp(1, 500);
    final stockConditions = conditions
        .map(
          (condition) => condition
              .replaceAll('rfid_tag_uid', 'source_rfid_tag_uid')
              .replaceAll('rfid_tag_type', 'source_rfid_tag_type'),
        )
        .toList();
    final physicalSelect =
        'SELECT id, uid, manufacturer, model, color_hex, color_name, '
        'rfid_tag_uid, rfid_tag_type, rfid_tag_cycle, lifecycle_status, '
        'owner_account, created_at, updated_at, 0 AS source_record '
        'FROM consumables WHERE ${conditions.join(' AND ')}';
    final sourceSelect =
        'SELECT id, uid, manufacturer, model, color_hex, color_name, '
        'source_rfid_tag_uid AS rfid_tag_uid, source_rfid_tag_type AS rfid_tag_type, '
        '1 AS rfid_tag_cycle, lifecycle_status, owner_account, created_at, updated_at, 1 AS source_record '
        'FROM consumables WHERE ${stockConditions.join(' AND ')}';
    final withSources = attachedDatabase.schemaVersion >= 56;
    final rows = await customSelect(
      '$physicalSelect ${withSources ? 'UNION ALL $sourceSelect' : ''} '
      'ORDER BY updated_at DESC, id DESC LIMIT $safeLimit',
      variables: [...variables, if (withSources) ...variables],
    ).get();

    final result = <RfidTagRecord>[];
    for (final row in rows) {
      final tagUid = normalizeRfidTagUid(
        row.read<String?>('rfid_tag_uid') ?? '',
      );
      if (tagUid.isEmpty) continue;
      final tagType = row.read<String?>('rfid_tag_type')?.trim() ?? '';
      if (!isConsumableRfidTagType(tagType)) continue;
      final occurredAt = _readDateTime(row, 'updated_at');
      final createdAt = _readDateTime(row, 'created_at', fallback: occurredAt);
      result.add(
        RfidTagRecord(
          tagUid: tagUid,
          tagType: tagType,
          technology: 'MIFARE_CLASSIC',
          profile: 'ams',
          operation: 'inventory',
          status: 'success',
          inventoryUid: row.read<String?>('uid'),
          ownerAccount: row.read<String?>('owner_account'),
          brand: row.read<String?>('manufacturer') ?? '',
          model: row.read<String?>('model') ?? '',
          colorHex: row.read<String?>('color_hex') ?? '',
          colorName: row.read<String?>('color_name'),
          verified: false,
          message: row.read<int>('source_record') == 1
              ? '可重复用于加库存的耗材资料卡'
              : '来自同步库存绑定；尚未在本机执行 NFC 操作',
          occurredAt: occurredAt,
          createdAt: createdAt,
          updatedAt: occurredAt,
        ),
      );
    }
    return result;
  }

  /// Claims history written while signed out (or under a legacy owner key)
  /// for the current account. This is deliberately an exact owner migration;
  /// rows belonging to another account are never touched.
  Future<int> claimOwnerAccount({
    required String ownerAccount,
    Iterable<String> legacyOwnerAccounts = const <String>[],
  }) async {
    final owner = _normalizedOwner(ownerAccount) ?? '';
    if (owner.isEmpty) return 0;
    final legacy = legacyOwnerAccounts
        .map((value) => _normalizedOwner(value) ?? '')
        .where((value) => value.isNotEmpty && value != owner)
        .toSet()
        .toList(growable: false);
    if (legacy.isEmpty) return 0;
    final count = await customUpdate(
      'UPDATE rfid_tag_records SET owner_account = ?, updated_at = ? '
      'WHERE lower(trim(owner_account)) IN '
      '(${List.filled(legacy.length, '?').join(',')})',
      variables: [
        Variable(owner),
        Variable(DateTime.now().millisecondsSinceEpoch),
        for (final value in legacy) Variable(value),
      ],
    );
    if (count > 0) _emit();
    return count;
  }

  /// Convenience lookup for showing the most recent state of one tag.
  Future<RfidTagRecord?> latestForTag(
    String tagUid, {
    String? ownerAccount,
    String? profile,
  }) async {
    final records = await list(
      ownerAccount: ownerAccount,
      tagUid: tagUid,
      profile: profile,
      limit: 1,
    );
    return records.isEmpty ? null : records.first;
  }

  /// Reactive recent history stream for a mobile list or diagnostics sheet.
  Stream<List<RfidTagRecord>> watch({
    String? ownerAccount,
    String? tagUid,
    String? profile,
    String? operation,
    int limit = 100,
  }) {
    late StreamController<List<RfidTagRecord>> controller;
    StreamSubscription<void>? subscription;

    Future<void> reload() async {
      try {
        final records = await list(
          ownerAccount: ownerAccount,
          tagUid: tagUid,
          profile: profile,
          operation: operation,
          limit: limit,
        );
        if (!controller.isClosed) controller.add(records);
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      }
    }

    controller = StreamController<List<RfidTagRecord>>(
      onListen: () {
        // Subscribe before the first query so a scan that completes while the
        // initial rows are loading cannot be lost between snapshots.
        subscription = _changeController.stream.listen((_) => reload());
        reload();
      },
      onCancel: () async {
        await subscription?.cancel();
        // The wrapper owns this controller; closing it prevents a paused
        // inventory route from retaining a listener until the repository is
        // disposed with the database provider.
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<int> count({
    String? ownerAccount,
    String? tagUid,
    String? profile,
    String? operation,
  }) async {
    final rows = await list(
      ownerAccount: ownerAccount,
      tagUid: tagUid,
      profile: profile,
      operation: operation,
      limit: 500,
    );
    return rows.length;
  }

  /// Releases the invalidation stream when this repository is owned by a
  /// Riverpod provider.
  void dispose() {
    _changeController.close();
  }

  static String _defaultText(String value, String fallback) {
    final normalized = value.trim();
    return normalized.isEmpty ? fallback : normalized;
  }

  static String? _nullableText(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String? _normalizedOwner(String? value) {
    if (value == null) return null;
    // Keep an explicitly blank owner distinct from an omitted owner. The
    // former means "signed-out history" when used as a list filter; the
    // latter means an unrestricted diagnostic query.
    return value.trim().toLowerCase();
  }

  static DateTime _readDateTime(
    QueryRow row,
    String column, {
    DateTime? fallback,
  }) {
    try {
      return row.read<DateTime>(column);
    } catch (_) {
      final raw = row.data[column];
      if (raw is DateTime) return raw;
      if (raw is num) {
        return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
      }
      return fallback ?? DateTime.now();
    }
  }
}
