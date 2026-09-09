import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../models/personal_inventory_sync.dart';
import '../models/rfid_tag_identity.dart';
import 'database.dart';
import 'personal_spool_handoff.dart';

/// Receipt provenance is distinct from the current physical tag binding.
/// A material card may receive any number of independent spools over time.
class PersonalRfidStockSource {
  const PersonalRfidStockSource({
    required this.tagUid,
    required this.tagType,
    required this.receiptUid,
    required this.index,
    required this.quantity,
  });

  /// Null for an explicit manual receipt; never synthesize a physical card.
  final String? tagUid;
  final String? tagType;
  final String receiptUid;
  final int index;
  final int quantity;

  Map<String, Object?> toJson() => {
    'sourceRfidTagUid': tagUid,
    'sourceRfidTagType': tagType,
    'stockReceiptUid': receiptUid,
    'stockReceiptIndex': index,
    'stockReceiptQuantity': quantity,
  };

  static PersonalRfidStockSource? fromRecord(PersonalInventoryRecord record) {
    if (record.sourceRfidTagUid == null &&
        record.sourceRfidTagType == null &&
        record.stockReceiptUid == null &&
        record.stockReceiptIndex == null &&
        record.stockReceiptQuantity == null) {
      return null;
    }
    final manual =
        record.sourceRfidTagUid == null && record.sourceRfidTagType == null;
    final tag = manual
        ? null
        : normalizeRfidTagUid(record.sourceRfidTagUid ?? '');
    final type = manual
        ? null
        : (record.sourceRfidTagType ?? '').trim().toUpperCase();
    final receipt = (record.stockReceiptUid ?? '').trim().toLowerCase();
    final index = record.stockReceiptIndex ?? -1;
    final quantity = record.stockReceiptQuantity ?? 0;
    if (!manual) _validateCard(tag!, type!);
    _validateReceipt(receipt, quantity);
    if (index < 0 || index >= quantity) {
      throw ArgumentError('入库批次序号不正确');
    }
    if (!record.totalGrams.isFinite ||
        record.totalGrams <= 0 ||
        record.totalGrams > 100000 ||
        !record.remainingGrams.isFinite ||
        record.remainingGrams < 0 ||
        record.remainingGrams > record.totalGrams) {
      throw ArgumentError('逐卷入库的余量不能超过该卷实际净重');
    }
    return PersonalRfidStockSource(
      tagUid: tag,
      tagType: type,
      receiptUid: receipt,
      index: index,
      quantity: quantity,
    );
  }
}

class PersonalStockReceipt {
  const PersonalStockReceipt({
    required this.operationUid,
    required this.inventoryUids,
    required this.consumableIds,
    required this.replayed,
  });

  final String operationUid;
  final List<String> inventoryUids;

  /// Deleted/archived receipts are never recreated. This list includes only
  /// rows still present; [inventoryUids] retains the original receipt in full.
  final List<int> consumableIds;
  final bool replayed;
}

void _validateCard(String tag, String type) {
  if (!RegExp(r'^[0-9A-F]{8}$').hasMatch(tag) ||
      !isConsumableRfidTagType(type)) {
    throw ArgumentError('耗材入库只支持已确认的 4 字节 CUID/FUID；NTAG213 用于设备工作台');
  }
}

void _validateReceipt(String receipt, int quantity) {
  if (!RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(receipt) ||
      quantity < 1 ||
      quantity > 100) {
    throw ArgumentError('入库需要独立操作 UUID，数量必须为 1 至 100 卷');
  }
}

String _owner(String? value) => (value ?? '').trim().toLowerCase();

class PersonalRfidStockStore {
  PersonalRfidStockStore(this.db);
  final AppDatabase db;

  Future<Map<int, PersonalRfidStockSource>> sources(Iterable<int> ids) async {
    final unique = ids.toSet().toList();
    if (unique.isEmpty || db.schemaVersion < 56) return {};
    final result = <int, PersonalRfidStockSource>{};
    for (var offset = 0; offset < unique.length; offset += 400) {
      final batch = unique.skip(offset).take(400).toList();
      final rows = await db
          .customSelect(
            'SELECT id, source_rfid_tag_uid, source_rfid_tag_type, stock_receipt_uid, '
            'stock_receipt_index, stock_receipt_quantity FROM consumables '
            "WHERE inventory_scope = 'personal' AND stock_receipt_uid IS NOT NULL "
            'AND id IN (${List.filled(batch.length, '?').join(',')})',
            variables: [for (final id in batch) Variable(id)],
          )
          .get();
      for (final row in rows) {
        result[row.read<int>('id')] = PersonalRfidStockSource(
          tagUid: row.read<String?>('source_rfid_tag_uid'),
          tagType: row.read<String?>('source_rfid_tag_type'),
          receiptUid: row.read<String>('stock_receipt_uid'),
          index: row.read<int>('stock_receipt_index'),
          quantity: row.read<int>('stock_receipt_quantity'),
        );
      }
    }
    return result;
  }

  Future<void> setSource(int id, PersonalRfidStockSource? source) async {
    if (source == null) return; // Older clients must not erase provenance.
    if (db.schemaVersion < 56) throw StateError('请先升级库存数据库');
    final previous = (await sources([id]))[id];
    if (previous != null &&
        jsonEncode(previous.toJson()) != jsonEncode(source.toJson())) {
      throw StateError('已登记库存的来源卡与入库批次不能改写');
    }
    await db.customUpdate(
      'UPDATE consumables SET source_rfid_tag_uid = ?, source_rfid_tag_type = ?, '
      'stock_receipt_uid = ?, stock_receipt_index = ?, stock_receipt_quantity = ? '
      "WHERE id = ? AND inventory_scope = 'personal'",
      variables: [
        Variable(source.tagUid),
        Variable(source.tagType),
        Variable(source.receiptUid),
        Variable(source.index),
        Variable(source.quantity),
        Variable(id),
      ],
      updates: {db.consumables},
    );
  }

  Future<PersonalStockReceipt> receive({
    required String operationUid,
    required String tagUid,
    required String tagType,
    required PersonalInventoryRecord template,
    required int quantity,
    String? ownerAccount,
    DateTime? now,
  }) async {
    _validateCard(normalizeRfidTagUid(tagUid), tagType.trim().toUpperCase());
    return _receive(
      operationUid: operationUid,
      tagUid: tagUid,
      tagType: tagType,
      template: template,
      quantity: quantity,
      ownerAccount: ownerAccount,
      now: now,
    );
  }

  Future<PersonalStockReceipt> receiveManual({
    required String operationUid,
    required PersonalInventoryRecord template,
    required int quantity,
    String? ownerAccount,
    DateTime? now,
  }) => _receive(
    operationUid: operationUid,
    template: template,
    quantity: quantity,
    ownerAccount: ownerAccount,
    now: now,
  );

  Future<PersonalStockReceipt> _receive({
    required String operationUid,
    String? tagUid,
    String? tagType,
    required PersonalInventoryRecord template,
    required int quantity,
    String? ownerAccount,
    DateTime? now,
  }) async {
    final operation = operationUid.trim().toLowerCase();
    final tag = tagUid == null ? null : normalizeRfidTagUid(tagUid);
    final type = tagType?.trim().toUpperCase();
    final owner = _owner(ownerAccount);
    _validateReceipt(operation, quantity);
    PersonalRfidStockSource.fromRecord(
      template.copyWith(
        sourceRfidTagUid: tag,
        sourceRfidTagType: type,
        stockReceiptUid: operation,
        stockReceiptIndex: 0,
        stockReceiptQuantity: quantity,
      ),
    );
    if (template.remainingGrams <= 0) throw ArgumentError('新增库存每卷必须有可用余量');
    for (final value in [
      template.manufacturer,
      template.model,
      template.materialType,
    ]) {
      if (value.trim().isEmpty || value.trim().length > 64) {
        throw ArgumentError('请填写有效的品牌、型号和材料');
      }
    }
    final payload = jsonEncode({
      'tagUid': tag,
      'tagType': type,
      'quantity': quantity,
      'manufacturer': template.manufacturer.trim(),
      'model': template.model.trim(),
      'materialType': template.materialType.trim(),
      'colorHex': template.colorHex,
      'colorName': template.colorName,
      'totalGrams': template.totalGrams,
      'remainingGrams': template.remainingGrams,
      'batchNo': template.batchNo,
      'purchaseDate': template.purchaseDate?.toUtc().toIso8601String(),
      'note': template.note,
      'density': template.density,
      'recommendedNozzleTemp': template.recommendedNozzleTemp,
      'hygroscopicity': template.hygroscopicity,
    });
    return db.transaction(() async {
      final receipt = await db
          .customSelect(
            'SELECT owner_account, payload_json, inventory_uids_json FROM personal_stock_receipts '
            'WHERE operation_uid = ?',
            variables: [Variable(operation)],
          )
          .getSingleOrNull();
      if (receipt != null) {
        if (_owner(receipt.read<String>('owner_account')) != owner) {
          throw StateError('该入库操作属于其他账号，请返回当前账号重新核对');
        }
        if (receipt.read<String>('payload_json') != payload) {
          throw StateError('同一次入库重试的数量或资料发生变化，请重新确认入库');
        }
        return _receiptResult(
          operation,
          (jsonDecode(receipt.read<String>('inventory_uids_json')) as List)
              .cast<String>(),
          owner,
          replayed: true,
        );
      }
      // A synchronized stock row can outlive its installation-local receipt.
      // Its operation UUID must still never be used to manufacture new stock.
      final imported = await db
          .customSelect(
            'SELECT uid, owner_account, stock_receipt_quantity FROM consumables '
            'WHERE stock_receipt_uid = ? ORDER BY stock_receipt_index',
            variables: [Variable(operation)],
          )
          .get();
      if (imported.isNotEmpty) {
        if (imported.any(
          (row) => _owner(row.read<String?>('owner_account')) != owner,
        )) {
          throw StateError('该入库操作属于其他账号');
        }
        throw StateError('该操作已经入库并同步，请在库存核对原批次；新增补货需重新确认');
      }
      final timestamp = now ?? DateTime.now();
      final uids = <String>[];
      for (var index = 0; index < quantity; index++) {
        final uid = const Uuid().v5(operation, 'stock:$index');
        uids.add(uid);
        await db.consumableDao.upsertPersonalInventoryRecord(
          PersonalInventoryRecord(
            uid: uid,
            manufacturer: template.manufacturer.trim(),
            model: template.model.trim(),
            materialType: template.materialType.trim(),
            colorHex: template.colorHex,
            colorName: template.colorName,
            totalGrams: template.totalGrams,
            remainingGrams: template.remainingGrams,
            batchNo: template.batchNo,
            purchaseDate: template.purchaseDate ?? timestamp,
            note: template.note,
            createdAt: timestamp,
            updatedAt: timestamp,
            density: template.density,
            recommendedNozzleTemp: template.recommendedNozzleTemp,
            hygroscopicity: template.hygroscopicity,
            sourceRfidTagUid: tag,
            sourceRfidTagType: type,
            stockReceiptUid: operation,
            stockReceiptIndex: index,
            stockReceiptQuantity: quantity,
          ),
          ownerAccount: owner.isEmpty ? null : owner,
        );
        await db.customInsert(
          'INSERT INTO personal_inventory_events(event_uid, owner_account, inventory_uid, '
          'event_type, before_grams, after_grams, delta_grams, occurred_at, source, '
          "note, local_source_key) VALUES (?, ?, ?, 'stock_received', 0, ?, ?, ?, ?, ?, ?)",
          variables: [
            Variable('stock:$operation:$index'),
            Variable(owner.isEmpty ? null : owner),
            Variable(uid),
            Variable(template.remainingGrams),
            Variable(template.remainingGrams),
            Variable(timestamp.millisecondsSinceEpoch),
            Variable(tag == null ? 'manual' : 'nfc'),
            Variable(
              '${tag == null ? '手动确认' : '资料卡 $tag'}入库，第 ${index + 1}/$quantity 卷',
            ),
            Variable('stock:$operation:$index'),
          ],
        );
      }
      await db.customInsert(
        'INSERT INTO personal_stock_receipts(operation_uid, owner_account, payload_json, '
        'inventory_uids_json, created_at) VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable(operation),
          Variable(owner),
          Variable(payload),
          Variable(jsonEncode(uids)),
          Variable(timestamp.millisecondsSinceEpoch),
        ],
      );
      return _receiptResult(operation, uids, owner, replayed: false);
    });
  }

  Future<PersonalStockReceipt> _receiptResult(
    String operation,
    List<String> uids,
    String owner, {
    required bool replayed,
  }) async {
    final ids = <int>[];
    for (final uid in uids) {
      final row = await db.consumableDao.getPersonalByUid(
        uid,
        ownerAccount: owner.isEmpty ? null : owner,
      );
      if (row != null) ids.add(row.id);
    }
    return PersonalStockReceipt(
      operationUid: operation,
      inventoryUids: List.unmodifiable(uids),
      consumableIds: List.unmodifiable(ids),
      replayed: replayed,
    );
  }

  Future<RfidSpoolBinding> activate({
    required int consumableId,
    required String tagUid,
    required String tagType,
    String? ownerAccount,
    bool continueCurrentTask = false,
    DateTime? now,
  }) async {
    final tag = normalizeRfidTagUid(tagUid);
    final type = tagType.trim().toUpperCase();
    final owner = _owner(ownerAccount);
    _validateCard(tag, type);
    return db.transaction(() async {
      final dao = db.consumableDao;
      final stock = await dao.getById(consumableId);
      final source = (await sources([consumableId]))[consumableId];
      if (stock == null ||
          source == null ||
          stock.remainingGrams <= 0 ||
          source.tagUid != tag ||
          source.tagType != type ||
          _owner(await dao.getOwnerAccount(consumableId)) != owner) {
        throw StateError('请选择当前账号通过这张资料卡已入库且仍有余量的耗材卷');
      }
      final bound = await dao.getRfidSpoolBindingById(consumableId);
      final reactivatingSameCardRemnant =
          bound != null &&
          bound.status == 'replaced' &&
          isConsumableRfidTagType(bound.tagType) &&
          rfidTagUidEquals(bound.tagUid, tag);
      if (bound == null ||
          (bound.status != 'active' && !reactivatingSameCardRemnant)) {
        throw StateError('该卷已结束使用或归档，请选择仍可用的库存');
      }
      if (reactivatingSameCardRemnant && bound.tagHistory.length >= 32) {
        throw StateError('该卷已达到 32 次标签生命周期记录上限');
      }
      final history = await dao.getPersonalRfidSpoolHistory(
        tag,
        ownerAccount: owner.isEmpty ? null : owner,
      );
      final latest = history.isEmpty ? null : history.first;
      if (history.any((entry) => !isConsumableRfidTagType(entry.tagType)) ||
          history.where((entry) => entry.isActive).length > 1 ||
          (latest != null &&
              history
                      .where(
                        (entry) =>
                            entry.cycle == latest.cycle &&
                            entry.status != 'retired',
                      )
                      .length >
                  1)) {
        throw StateError('标签用途或当前周期存在冲突，请先核对库存');
      }
      if (bound.tagUid.isNotEmpty) {
        if (bound.isActive &&
            bound.tagUid == tag &&
            latest?.consumableId == consumableId) {
          return bound;
        }
        if (!reactivatingSameCardRemnant) {
          throw StateError('该卷已有标签使用记录，请核对当前卷或使用余料换绑');
        }
      }
      for (final other in await dao.getAnyPersonalRfidSpoolHistory(tag)) {
        if (other.isActive &&
            _owner(await dao.getOwnerAccount(other.consumableId)) != owner) {
          throw StateError('该标签仍关联其他账号的当前耗材，请先核对标签和账号归属');
        }
      }
      final stockTasks = await db
          .customSelect(
            'SELECT 1 FROM print_task_consumables WHERE consumable_id = ? '
            'AND consumed_at IS NULL LIMIT 1',
            variables: [Variable(consumableId)],
          )
          .getSingleOrNull();
      if (stockTasks != null) throw StateError('所选库存仍有未结算任务，请先核对');
      final stockChannel = await db
          .customSelect(
            'SELECT 1 FROM printer_channels WHERE consumable_id = ? LIMIT 1',
            variables: [Variable(consumableId)],
          )
          .getSingleOrNull();
      if (stockChannel != null) throw StateError('所选库存已装在供料位，请先卸料');
      final timestamp = now ?? DateTime.now();
      PrinterChannel? taskChannel;
      Consumable? old;
      if (latest != null) {
        if (_owner(await dao.getOwnerAccount(latest.consumableId)) != owner) {
          throw StateError('标签旧周期属于其他账号，请先完成账号归属同步');
        }
        old = await dao.getById(latest.consumableId);
        final pending = await db
            .customSelect(
              'SELECT 1 FROM print_task_consumables WHERE consumable_id = ? '
              'AND consumed_at IS NULL LIMIT 1',
              variables: [Variable(latest.consumableId)],
            )
            .getSingleOrNull();
        if (pending != null) {
          final channels =
              await (db.select(db.printerChannels)..where(
                    (channel) =>
                        channel.consumableId.equals(latest.consumableId),
                  ))
                  .get();
          if (!continueCurrentTask || channels.length != 1) {
            throw StateError('旧卷仍有未结算任务，请在打印机所在设备确认换卷接续');
          }
          taskChannel = channels.single;
        }
        await dao.updateRfidSpoolLifecycle(
          latest.consumableId,
          status: latest.status == 'retired'
              ? 'retired'
              : (old?.remainingGrams ?? 0) <= 0
              ? 'depleted'
              : 'replaced',
        );
        await db.customUpdate(
          'UPDATE printer_channels SET consumable_id = NULL, loaded_spool_uid = NULL, '
          'loaded_remaining_grams = 0, farm_roll_paused = 0, updated_at = ? '
          'WHERE consumable_id = ?',
          variables: [Variable(timestamp), Variable(latest.consumableId)],
          updates: {db.printerChannels},
        );
      }
      await dao.setRfidSpoolBinding(
        consumableId,
        tagUid: tag,
        tagType: type,
        cycle: (latest?.cycle ?? 0) + 1,
        status: 'active',
        previousInventoryUid: latest?.inventoryUid,
        updatedAt: timestamp,
        tagHistory: reactivatingSameCardRemnant
            ? [...bound.tagHistory, bound.identity]
            : null,
      );
      if (taskChannel != null && latest != null) {
        final handoff = PersonalSpoolHandoff(db);
        await handoff.splitTasks(
          taskChannel,
          latest.consumableId,
          consumableId,
        );
        await handoff.record(
          taskChannel,
          latest.consumableId,
          'spool_unloaded',
          before: old!.remainingGrams,
          after: old.remainingGrams,
        );
        await db.printerDao.bindConsumable(taskChannel.id, consumableId);
      }
      await db.customInsert(
        'INSERT INTO rfid_tag_records(tag_uid, tag_type, operation, inventory_uid, '
        'owner_account, brand, model, color_hex, message, occurred_at, created_at, updated_at) '
        "VALUES (?, ?, 'activate_stock', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        variables: [
          Variable(tag),
          Variable(type),
          Variable(stock.uid),
          Variable(owner.isEmpty ? null : owner),
          Variable(stock.manufacturer),
          Variable(stock.model),
          Variable(stock.colorHex),
          Variable(
            reactivatingSameCardRemnant
                ? '重新装入同一资料卡下的旧余料卷；保留原余量且库存不增加'
                : '将资料卡关联到已入库的实际耗材卷；库存不再增加',
          ),
          Variable(timestamp.millisecondsSinceEpoch),
          Variable(timestamp.millisecondsSinceEpoch),
          Variable(timestamp.millisecondsSinceEpoch),
        ],
      );
      return (await dao.getRfidSpoolBindingById(consumableId))!;
    });
  }
}

Future<void> preparePersonalRfidStock(Migrator m) async {
  final db = m.database;
  final columns =
      (await db.customSelect('PRAGMA table_info(consumables)').get())
          .map((row) => row.read<String>('name'))
          .toSet();
  for (final entry in {
    'source_rfid_tag_uid': 'TEXT',
    'source_rfid_tag_type': 'TEXT',
    'stock_receipt_uid': 'TEXT',
    'stock_receipt_index': 'INTEGER',
    'stock_receipt_quantity': 'INTEGER',
  }.entries) {
    if (!columns.contains(entry.key)) {
      await db.customStatement(
        'ALTER TABLE consumables ADD COLUMN ${entry.key} ${entry.value}',
      );
    }
  }
  await db.customStatement('''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_personal_stock_receipt_item
    ON consumables(stock_receipt_uid, stock_receipt_index)
    WHERE stock_receipt_uid IS NOT NULL
  ''');
  await db.customStatement('''
    CREATE TABLE IF NOT EXISTS personal_stock_receipts(
      operation_uid TEXT PRIMARY KEY,
      owner_account TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      inventory_uids_json TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');
}
