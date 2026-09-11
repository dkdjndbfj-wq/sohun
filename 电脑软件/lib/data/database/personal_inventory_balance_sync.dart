import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/personal_spool_policy.dart';
import '../models/personal_inventory_sync.dart';
import 'database.dart';

class PersonalInventoryBalanceConflict {
  const PersonalInventoryBalanceConflict(this.serverUrl, this.remote);
  final String serverUrl;
  final PersonalInventoryRecord remote;
}

/// A common ancestor distinguishes a metadata-only edit from an actual stock
/// change. Conflicting balances are kept for explicit physical reconciliation.
extension PersonalInventoryBalanceSync on ConsumableDao {
  Future<Map<String, PersonalInventoryRecord>> readInventorySyncBaselines(
    String owner,
    String server,
  ) async {
    final rows = await customSelect(
      'SELECT inventory_uid, record_json FROM personal_inventory_sync_baselines '
      'WHERE owner_account = ? AND server_url = ?',
      variables: [Variable(owner), Variable(server)],
    ).get();
    return {
      for (final row in rows)
        row.read<String>('inventory_uid'): PersonalInventoryRecord.fromJson(
          jsonDecode(row.read<String>('record_json')) as Map<String, dynamic>,
        ),
    };
  }

  Future<void> saveInventorySyncBaselines(
    String owner,
    String server,
    Iterable<PersonalInventoryRecord> records,
  ) async {
    for (final record in records) {
      await customStatement(
        'INSERT INTO personal_inventory_sync_baselines(owner_account, server_url, inventory_uid, record_json) '
        'VALUES (?, ?, ?, ?) ON CONFLICT(owner_account, server_url, inventory_uid) '
        'DO UPDATE SET record_json = excluded.record_json',
        [owner, server, record.uid.toLowerCase(), jsonEncode(record.toJson())],
      );
    }
  }

  Future<void> retainInventoryBalanceConflict(
    String owner,
    String server,
    PersonalInventoryRecord remote,
  ) => customStatement(
    'INSERT INTO personal_inventory_balance_conflicts(owner_account, server_url, inventory_uid, record_json) '
    'VALUES (?, ?, ?, ?) ON CONFLICT(owner_account, server_url, inventory_uid) '
    'DO UPDATE SET record_json = excluded.record_json',
    [owner, server, remote.uid.toLowerCase(), jsonEncode(remote.toJson())],
  );

  Future<void> clearInventoryBalanceConflict(
    String owner,
    String server,
    String uid,
  ) => customStatement(
    'DELETE FROM personal_inventory_balance_conflicts WHERE owner_account = ? AND server_url = ? AND inventory_uid = ?',
    [owner, server, uid.toLowerCase()],
  );

  Future<List<PersonalInventoryBalanceConflict>> readInventoryBalanceConflicts(
    String uid, {
    required String? ownerAccount,
  }) async {
    if (ownerAccount == null) return const [];
    final rows = await customSelect(
      'SELECT server_url, record_json FROM personal_inventory_balance_conflicts '
      'WHERE owner_account = ? AND inventory_uid = ?',
      variables: [
        Variable(ownerAccount.trim().toLowerCase()),
        Variable(uid.toLowerCase()),
      ],
    ).get();
    return [
      for (final row in rows)
        PersonalInventoryBalanceConflict(
          row.read<String>('server_url'),
          PersonalInventoryRecord.fromJson(
            jsonDecode(row.read<String>('record_json')) as Map<String, dynamic>,
          ),
        ),
    ];
  }

  Future<void> reconcilePersonalInventoryBalance(
    int id,
    PersonalInventoryBalanceConflict conflict,
    double remainingGrams,
  ) async {
    await transaction(() async {
      final row = await getById(id);
      final owner = await getOwnerAccount(id);
      if (row == null || owner == null || row.uid != conflict.remote.uid) {
        throw StateError('耗材卷或所属账号已变化，请刷新后重试');
      }
      final individual = await isIndividualPersonalSpool(id);
      if (individual && row.totalGrams != personalSpoolCapacityGrams) {
        throw StateError('历史耗材卷规格不是固定 1000 g，原始余额已保留，请先核对规格');
      }
      final maximum = individual ? personalSpoolCapacityGrams : 100000.0;
      if (!remainingGrams.isFinite ||
          remainingGrams < 0 ||
          remainingGrams > maximum) {
        throw ArgumentError('请填写 0 到 $maximum g 之间的实际余量');
      }
      final binding = await getRfidSpoolBindingById(id);
      if (individual &&
          (binding == null ||
              binding.status == 'replaced' ||
              binding.status == 'retired')) {
        throw StateError('该卷已结束标签关联，请先刷新生命周期');
      }
      final pending = await customSelect(
        'SELECT id FROM print_task_consumables WHERE consumable_id = ? AND consumed_at IS NULL LIMIT 1',
        variables: [Variable(id)],
      ).getSingleOrNull();
      if (pending != null) throw StateError('该卷仍有未结算任务，请先完成本机任务结算再核对余量');
      final current = await readInventoryBalanceConflicts(
        row.uid,
        ownerAccount: owner,
      );
      if (!current.any(
        (entry) =>
            entry.serverUrl == conflict.serverUrl &&
            jsonEncode(entry.remote.toJson()) ==
                jsonEncode(conflict.remote.toJson()),
      )) {
        throw StateError('冲突记录已变化，请刷新后重新核对');
      }
      await customUpdate(
        'UPDATE consumables SET remaining_grams = ?, lifecycle_status = ?, updated_at = ? WHERE id = ?',
        variables: [
          Variable(remainingGrams),
          Variable(remainingGrams <= 0 ? 'depleted' : 'active'),
          Variable(DateTime.now()),
          Variable(id),
        ],
        updates: {consumables},
      );
      await customStatement(
        'INSERT INTO personal_inventory_events(event_uid, owner_account, inventory_uid, rfid_tag_uid, '
        'rfid_tag_cycle, event_type, before_grams, after_grams, delta_grams, occurred_at, source, note) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          const Uuid().v4(),
          owner,
          row.uid,
          binding?.tagUid.isNotEmpty == true ? binding!.tagUid : null,
          binding?.tagUid.isNotEmpty == true ? binding!.cycle : null,
          'balance_reconciled',
          row.remainingGrams,
          remainingGrams,
          remainingGrams - row.remainingGrams,
          DateTime.now().millisecondsSinceEpoch,
          'manual',
          '用户核对实际余量；云端先前记录 ${conflict.remote.remainingGrams} g',
        ],
      );
      await saveInventorySyncBaselines(owner, conflict.serverUrl, [
        conflict.remote,
      ]);
      await clearInventoryBalanceConflict(owner, conflict.serverUrl, row.uid);
    });
  }
}
