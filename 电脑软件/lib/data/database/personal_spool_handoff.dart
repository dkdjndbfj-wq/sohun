import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';
import 'daos/filament_cost_config_dao.dart';
import 'daos/consumable_dao.dart';

/// Personal spool changes and their accounting happen in the caller's channel
/// transaction. No historical consumption is moved to a different spool.
class PersonalSpoolHandoff {
  PersonalSpoolHandoff(this.db);

  final AppDatabase db;

  Future<void> assertNotReservedElsewhere(
    int consumableId,
    int printerId,
    int channelIndex,
  ) async {
    final row = await db
        .customSelect(
          'SELECT p.id FROM print_task_consumables p '
          'LEFT JOIN print_tasks t ON t.id = p.task_id '
          'WHERE p.consumable_id = ? AND p.consumed_at IS NULL '
          'AND (coalesce(p.printer_id, t.printer_id, -1) != ? '
          'OR p.channel_index != ?) LIMIT 1',
          variables: [
            Variable(consumableId),
            Variable(printerId),
            Variable(channelIndex),
          ],
        )
        .getSingleOrNull();
    if (row != null) throw StateError('这卷耗材仍被其他供料位的任务占用，请先结算或重新分配任务');
  }

  Future<bool> hasPending(int consumableId) async =>
      await db
          .customSelect(
            'SELECT id FROM print_task_consumables WHERE consumable_id = ? '
            'AND consumed_at IS NULL LIMIT 1',
            variables: [Variable(consumableId)],
          )
          .getSingleOrNull() !=
      null;

  Future<void> unload(
    PrinterChannel channel,
    Consumable old, {
    required int newConsumableId,
    double? measuredRemaining,
  }) async {
    final binding = await db.consumableDao.getRfidSpoolBindingById(old.id);
    final tagged = binding?.tagUid.isNotEmpty == true;
    final individual = await db.consumableDao.isIndividualPersonalSpool(old.id);
    final maxGrams = individual ? old.totalGrams : gramsPerRoll;
    final accounted = individual
        ? old.remainingGrams
        : math.min(
            old.remainingGrams,
            channel.loadedRemainingGrams > 0
                ? channel.loadedRemainingGrams
                : maxGrams,
          );
    final remaining = measuredRemaining ?? accounted;
    if (!remaining.isFinite || remaining < 0 || remaining > maxGrams) {
      throw ArgumentError('旧卷余量必须在 0～${maxGrams.toStringAsFixed(0)}g 之间');
    }
    if (tagged &&
        (binding!.status == 'replaced' || binding.status == 'retired')) {
      throw StateError('旧卷标签周期已结束，请先核对该供料位的实际耗材');
    }
    // Progress is an estimate, not a scale reading. A measurement cannot be
    // silently distributed across several outstanding tasks or color tools.
    if (await hasPending(old.id) && (remaining - accounted).abs() > 0.0001) {
      throw StateError('该卷还有未结算任务；换卷时保留账面余量，称重差额请在任务结算后核对');
    }
    await splitTasks(channel, old.id, newConsumableId);
    final delta = accounted - remaining;
    if (delta.abs() > 0.0001) {
      await db.consumableDao.adjustGrams(old.id, delta);
      // Only previously unaccounted consumption is logged. Repeated unloads
      // never re-log the spool's entire lifetime consumption.
      if (delta > 0) {
        await db.usageLogDao.addLog(
          UsageLogsCompanion.insert(
            printerId: Value(channel.printerId),
            channelIndex: Value(channel.channelIndex),
            consumableId: Value(old.id),
            consumedGrams: Value(delta),
            finished: Value(remaining == 0),
            note: const Value('换卷时确认的未记账消耗'),
          ),
        );
      }
      await record(
        channel,
        old.id,
        'spool_weighed',
        before: accounted,
        after: remaining,
      );
    }
    await record(
      channel,
      old.id,
      'spool_unloaded',
      before: remaining,
      after: remaining,
    );
  }

  Future<void> finish(PrinterChannel channel, Consumable item) async {
    if (await hasPending(item.id)) {
      throw StateError('该卷仍有未结算任务；请使用换卷接续任务，或先结算任务再标记用完');
    }
    final individual = await db.consumableDao.isIndividualPersonalSpool(
      item.id,
    );
    final consumed = individual
        ? item.remainingGrams
        : math.min(
            item.remainingGrams,
            channel.loadedRemainingGrams > 0
                ? channel.loadedRemainingGrams
                : gramsPerRoll,
          );
    if (consumed > 0) {
      final actual = await db.consumableDao.adjustGrams(item.id, consumed);
      await db.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          printerId: Value(channel.printerId),
          channelIndex: Value(channel.channelIndex),
          consumableId: Value(item.id),
          consumedGrams: Value(actual),
          finished: const Value(true),
          note: const Value('手动确认本卷已用完'),
        ),
      );
    }
    await record(channel, item.id, 'spool_unloaded', before: 0, after: 0);
  }

  Future<void> splitTasks(PrinterChannel channel, int oldId, int newId) async {
    final rows = await db
        .customSelect(
          'SELECT p.*, t.uid AS task_uid, t.status AS task_status, '
          'coalesce(p.printer_id, t.printer_id) AS effective_printer_id '
          'FROM print_task_consumables p JOIN print_tasks t ON t.id = p.task_id '
          'WHERE p.consumable_id = ? AND p.consumed_at IS NULL ORDER BY p.id',
          variables: [Variable(oldId)],
        )
        .get();
    if (rows.isEmpty) return;
    final next = await db.consumableDao.getById(newId);
    if (next == null || await db.consumableDao.isFarmConsumable(newId)) {
      throw StateError('个人打印任务需要换入个人库存中的实体卷');
    }
    final oldOwner = await db.consumableDao.getOwnerAccount(oldId);
    final newOwner = await db.consumableDao.getOwnerAccount(newId);
    if (oldOwner != null && newOwner != null && oldOwner != newOwner) {
      throw StateError('任务换卷不能使用其他账号的耗材');
    }
    final costDao = FilamentCostConfigDao(db);
    final cost = await costDao.matchCost(
      vendor: next.manufacturer,
      materialType: next.materialType,
      colorHex: next.colorHex,
    );
    costDao.dispose();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in rows) {
      if (row.read<int?>('effective_printer_id') != channel.printerId ||
          row.read<int>('channel_index') != channel.channelIndex) {
        throw StateError('旧卷还有其他供料位的未结算任务，不能转移任务消耗');
      }
      if (!const {
        'planned',
        'printing',
        'paused',
      }.contains(row.read<String>('task_status'))) {
        throw StateError('旧卷有待恢复的任务结算，请先完成结算再换卷');
      }
      final spent = row.read<double>('last_deducted_grams');
      final estimate = row.read<double>('estimated_grams');
      final start = row.read<double>('segment_start_grams');
      if (!spent.isFinite ||
          spent < 0 ||
          spent > estimate ||
          !start.isFinite ||
          start < 0) {
        throw StateError('旧卷任务的已记账用量超出预计范围，请先核对任务');
      }
      final changed = await db.customUpdate(
        'UPDATE print_task_consumables SET estimated_grams = ?, consumed_grams = ?, '
        'consumed_at = ?, updated_at = ? WHERE id = ? AND consumed_at IS NULL '
        'AND last_deducted_grams = ?',
        variables: [
          Variable(spent),
          Variable(spent),
          Variable(now),
          Variable(now),
          Variable(row.read<int>('id')),
          Variable(spent),
        ],
      );
      if (changed != 1) throw StateError('任务用量已变化，请刷新后换卷');
      await db.customInsert(
        'INSERT INTO print_task_consumables(task_id, printer_id, channel_index, '
        'consumable_id, tool_index, estimated_grams, segment_start_grams, '
        'cost_per_kg_snapshot, matched_cost_config_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(row.read<int>('task_id')),
          Variable(channel.printerId),
          Variable(channel.channelIndex),
          Variable(newId),
          Variable(row.read<int>('tool_index')),
          Variable(estimate - spent),
          Variable(start + spent),
          Variable(cost?.costPerKg),
          Variable(cost?.id),
          Variable(now),
          Variable(now),
        ],
      );
      if (spent > 0) {
        await db.usageLogDao.addLog(
          UsageLogsCompanion.insert(
            printerId: Value(channel.printerId),
            channelIndex: Value(channel.channelIndex),
            consumableId: Value(oldId),
            consumedGrams: Value(spent),
            finished: const Value(false),
            note: const Value('换卷分段结算（按已同步消耗）'),
          ),
          taskUid: row.read<String>('task_uid'),
        );
      }
    }
    db.notifyUpdates({const TableUpdate('print_task_consumables')});
  }

  Future<void> record(
    PrinterChannel channel,
    int id,
    String type, {
    required double before,
    required double after,
  }) async {
    final item = await db.consumableDao.getById(id);
    final binding = await db.consumableDao.getRfidSpoolBindingById(id);
    if (item == null || !await db.consumableDao.isIndividualPersonalSpool(id))
      return;
    final printer = await db.printerDao.getById(channel.printerId);
    await db.customStatement(
      'INSERT INTO personal_inventory_events(event_uid, owner_account, inventory_uid, '
      'rfid_tag_uid, rfid_tag_cycle, event_type, before_grams, after_grams, delta_grams, '
      'occurred_at, source, printer_uid, printer_name, channel_index) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        const Uuid().v4(),
        await db.consumableDao.getOwnerAccount(id),
        item.uid,
        binding?.tagUid.isNotEmpty == true ? binding!.tagUid : null,
        binding?.tagUid.isNotEmpty == true ? binding!.cycle : null,
        type,
        before,
        after,
        after - before,
        DateTime.now().millisecondsSinceEpoch,
        'manual',
        printer?.uid,
        printer?.name,
        channel.channelIndex,
      ],
    );
  }
}
