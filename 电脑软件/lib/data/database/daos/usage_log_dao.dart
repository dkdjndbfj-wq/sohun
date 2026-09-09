import 'dart:async';

import 'package:drift/drift.dart';
import '../database.dart';
import '../tables.dart';

part 'usage_log_dao.g.dart';

/// 消耗记录数据访问层。每次「已用完」或部分消耗都会落一条记录，用于回溯统计。
@DriftAccessor(tables: [UsageLogs, Printers, Consumables])
class UsageLogDao extends DatabaseAccessor<AppDatabase>
    with _$UsageLogDaoMixin {
  UsageLogDao(super.db);

  Stream<List<UsageLog>> watchAll() {
    final query = select(usageLogs)
      ..orderBy([
        (t) => OrderingTerm(expression: t.loggedAt, mode: OrderingMode.desc),
      ]);
    return query.watch();
  }

  Future<List<UsageLog>> getAll() {
    final query = select(usageLogs)
      ..orderBy([
        (t) => OrderingTerm(expression: t.loggedAt, mode: OrderingMode.desc),
      ]);
    return query.get();
  }

  Future<List<UsageLog>> getPersonal() async {
    final all = await getAll();
    final rows = await customSelect(
      "SELECT id FROM consumables WHERE inventory_scope = 'farm'",
    ).get();
    final farmIds = rows.map((row) => row.read<int>('id')).toSet();
    return all
        .where(
          (item) =>
              item.consumableId == null || !farmIds.contains(item.consumableId),
        )
        .toList();
  }

  /// Returns personal usage that belongs to one sohun account, plus live
  /// anonymous inventory that can still be claimed after an offline entry.
  ///
  /// A log whose consumable was deleted is attributed through the immutable
  /// inventory event projection. Older orphan logs without such evidence are
  /// visible only in signed-out local mode, never to an arbitrary account.
  Future<List<UsageLog>> getPersonalForOwnerAccount(String ownerAccount) async {
    final owner = ownerAccount.trim();
    final all = await getAll();
    final String ownerPredicate;
    final List<Variable<Object>> variables;
    if (owner.isEmpty) {
      ownerPredicate = '''
        (c.id IS NOT NULL AND c.inventory_scope = 'personal'
          AND (c.owner_account IS NULL OR trim(c.owner_account) = ''))
        OR (c.id IS NULL AND
          (e.owner_account IS NULL OR trim(e.owner_account) = ''))
      ''';
      variables = const [];
    } else {
      ownerPredicate = '''
        (c.id IS NOT NULL AND c.inventory_scope = 'personal' AND
          (lower(trim(c.owner_account)) = lower(trim(?))
            OR c.owner_account IS NULL OR trim(c.owner_account) = ''))
        OR (c.id IS NULL AND
          lower(trim(e.owner_account)) = lower(trim(?)))
      ''';
      variables = [Variable(owner), Variable(owner)];
    }
    final rows = await customSelect(
      'SELECT DISTINCT u.id FROM usage_logs u '
      'LEFT JOIN consumables c ON c.id = u.consumable_id '
      "LEFT JOIN personal_inventory_events e ON e.local_source_key = 'usage:' || u.id "
      'WHERE $ownerPredicate',
      variables: variables,
    ).get();
    final ids = rows.map((row) => row.read<int>('id')).toSet();
    return all.where((item) => ids.contains(item.id)).toList();
  }

  Stream<List<UsageLog>> watchPersonal() {
    late StreamController<List<UsageLog>> controller;
    StreamSubscription<List<UsageLog>>? usageSubscription;
    StreamSubscription<List<Consumable>>? inventorySubscription;

    Future<void> reload() async {
      try {
        final items = await getPersonal();
        if (!controller.isClosed) controller.add(items);
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      }
    }

    controller = StreamController<List<UsageLog>>(
      onListen: () {
        usageSubscription = select(usageLogs).watch().listen((_) => reload());
        inventorySubscription = select(
          consumables,
        ).watch().listen((_) => reload());
        reload();
      },
      onCancel: () async {
        await usageSubscription?.cancel();
        await inventorySubscription?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  Stream<List<UsageLog>> watchPersonalForOwnerAccount(String ownerAccount) {
    final owner = ownerAccount.trim();
    late StreamController<List<UsageLog>> controller;
    StreamSubscription<List<UsageLog>>? usageSubscription;
    StreamSubscription<List<Consumable>>? inventorySubscription;

    Future<void> reload() async {
      try {
        final items = await getPersonalForOwnerAccount(owner);
        if (!controller.isClosed) controller.add(items);
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      }
    }

    controller = StreamController<List<UsageLog>>(
      onListen: () {
        usageSubscription = select(usageLogs).watch().listen((_) => reload());
        inventorySubscription = select(
          consumables,
        ).watch().listen((_) => reload());
        reload();
      },
      onCancel: () async {
        await usageSubscription?.cancel();
        await inventorySubscription?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<int> addLog(UsageLogsCompanion entry, {String? taskUid}) {
    return transaction(() async {
      final id = await into(usageLogs).insert(entry);
      if (taskUid?.trim().isNotEmpty == true) {
        // Enrich the safe projection before this source transaction commits.
        // The file name/path in the local task is never part of the ledger.
        await customStatement(
          "UPDATE personal_inventory_events SET task_uid = ? "
          "WHERE local_source_key = ? AND origin = 'local'",
          [taskUid!.trim(), 'usage:$id'],
        );
      }
      return id;
    });
  }

  Future<List<UsageLog>> getForConsumable(int consumableId) {
    return (select(usageLogs)
          ..where((t) => t.consumableId.equals(consumableId))
          ..orderBy([(t) => OrderingTerm.desc(t.loggedAt)]))
        .get();
  }

  Future<int> deleteLog(int id) {
    return (delete(usageLogs)..where((t) => t.id.equals(id))).go();
  }
}
