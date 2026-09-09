import 'dart:convert';
import 'package:drift/drift.dart';
import '../models/personal_device.dart';
import 'database.dart';

Future<void> prepareDeviceWorkbench(Migrator m) async {
  await m.database.customStatement(
    '''CREATE TABLE IF NOT EXISTS device_workbench_sync_state(
    account_key TEXT PRIMARY KEY, maintenance_cursor INTEGER NOT NULL DEFAULT 0)''',
  );
  await m.database.customStatement(
    '''CREATE TABLE IF NOT EXISTS device_workbench_cache(
    account_key TEXT NOT NULL, printer_key TEXT NOT NULL, device_token TEXT NOT NULL,
    payload TEXT NOT NULL, maintenance_cursor INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(account_key,printer_key))''',
  );
  await m.database.customStatement(
    '''CREATE TABLE IF NOT EXISTS device_maintenance_cache(
    account_key TEXT NOT NULL, event_uid TEXT NOT NULL, printer_key TEXT NOT NULL,
    payload TEXT NOT NULL, pending INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(account_key,event_uid))''',
  );
  await m.database.customStatement(
    '''CREATE INDEX IF NOT EXISTS device_maintenance_by_device
    ON device_maintenance_cache(account_key,printer_key)''',
  );
  await m.database.customStatement(
    '''CREATE TABLE IF NOT EXISTS device_tag_operations(
    id INTEGER PRIMARY KEY AUTOINCREMENT, account_key TEXT NOT NULL,
    printer_key TEXT NOT NULL, device_token TEXT NOT NULL, tag_uid TEXT NOT NULL,
    occurred_at INTEGER NOT NULL)''',
  );
}

class DeviceWorkbenchStore {
  DeviceWorkbenchStore(this.db);
  final AppDatabase db;

  Future<List<PersonalDevice>> devices(String owner) async =>
      (await db
              .customSelect(
                'SELECT payload FROM device_workbench_cache WHERE account_key=? ORDER BY printer_key',
                variables: [Variable(owner)],
              )
              .get())
          .map(
            (r) => PersonalDevice.fromJson(
              jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
            ),
          )
          .toList();

  Future<void> putDevice(String owner, PersonalDevice device) =>
      db.customStatement(
        '''
    INSERT INTO device_workbench_cache(account_key,printer_key,device_token,payload) VALUES(?,?,?,?)
    ON CONFLICT(account_key,printer_key) DO UPDATE SET device_token=excluded.device_token,payload=excluded.payload''',
        [
          owner,
          device.printerKey,
          device.deviceToken,
          jsonEncode(device.toJson()),
        ],
      );

  Future<void> replaceDevices(
    String owner,
    List<PersonalDevice> devices,
  ) => db.transaction(() async {
    for (final device in devices) {
      await putDevice(owner, device);
    }
    final keep = devices.map((d) => d.printerKey).toList();
    await db.customStatement(
      'DELETE FROM device_workbench_cache WHERE account_key=? ${keep.isEmpty ? '' : 'AND printer_key NOT IN (${List.filled(keep.length, '?').join(',')})'}',
      [owner, ...keep],
    );
  });

  Future<void> forgetDevice(String owner, String key) => db.customStatement(
    'DELETE FROM device_workbench_cache WHERE account_key=? AND printer_key=?',
    [owner, key],
  );

  Future<void> enqueueMaintenance(
    String owner,
    DeviceMaintenanceRecord record,
  ) => db.transaction(() async {
    final device = (await devices(owner))
        .where((d) => d.printerKey == record.printerKey && !d.archived)
        .firstOrNull;
    if (owner.isEmpty || device == null) throw StateError('请先在当前账号打开有权访问的设备');
    if (!deviceMaintenanceTypes.containsKey(record.kind) ||
        record.notes.length > 2000 ||
        record.performedAt.isAfter(
          DateTime.now().add(const Duration(minutes: 5)),
        ) ||
        (record.nextDueAt?.isBefore(record.performedAt) ?? false))
      throw ArgumentError('维护记录或日期不正确');
    final existing = await db
        .customSelect(
          'SELECT payload FROM device_maintenance_cache WHERE account_key=? AND event_uid=?',
          variables: [Variable(owner), Variable(record.eventId)],
        )
        .getSingleOrNull();
    final payload = jsonEncode(record.toJson());
    if (existing != null && existing.read<String>('payload') != payload)
      throw StateError('维护记录不能覆盖已有事件');
    if (existing == null)
      await db.customStatement(
        'INSERT INTO device_maintenance_cache(account_key,event_uid,printer_key,payload,pending) VALUES(?,?,?,?,1)',
        [owner, record.eventId, record.printerKey, payload],
      );
  });

  Future<List<DeviceMaintenanceRecord>> maintenance(
    String owner, {
    String? printerKey,
    bool pendingOnly = false,
  }) async =>
      (await db
              .customSelect(
                'SELECT payload,pending FROM device_maintenance_cache WHERE account_key=? ${printerKey == null ? '' : 'AND printer_key=?'} ${pendingOnly ? 'AND pending=1' : ''}',
                variables: [
                  Variable(owner),
                  if (printerKey != null) Variable(printerKey),
                ],
              )
              .get())
          .map(
            (r) => DeviceMaintenanceRecord.fromJson(
              jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
              pending: r.read<int>('pending') == 1,
            ),
          )
          .toList()
        ..sort((a, b) => b.performedAt.compareTo(a.performedAt));

  Future<void> acknowledge(String owner, DeviceMaintenanceRecord record) =>
      db.customStatement(
        '''
    INSERT INTO device_maintenance_cache(account_key,event_uid,printer_key,payload,pending) VALUES(?,?,?,?,0)
    ON CONFLICT(account_key,event_uid) DO UPDATE SET payload=excluded.payload,pending=0''',
        [owner, record.eventId, record.printerKey, jsonEncode(record.toJson())],
      );

  Future<int> cursor(String owner) async =>
      (await db
              .customSelect(
                'SELECT maintenance_cursor FROM device_workbench_sync_state WHERE account_key=?',
                variables: [Variable(owner)],
              )
              .getSingleOrNull())
          ?.read<int>('maintenance_cursor') ??
      0;

  Future<void> importPage(
    String owner,
    DeviceMaintenancePage page,
  ) => db.transaction(() async {
    for (final record in page.records) {
      // A conflicting local pending record must remain visible for retry.
      await db.customStatement(
        '''INSERT INTO device_maintenance_cache(account_key,event_uid,printer_key,payload,pending)
        VALUES(?,?,?,?,0) ON CONFLICT(account_key,event_uid) DO UPDATE SET payload=excluded.payload
        WHERE device_maintenance_cache.pending=0''',
        [owner, record.eventId, record.printerKey, jsonEncode(record.toJson())],
      );
    }
    await db.customStatement(
      'INSERT INTO device_workbench_sync_state(account_key,maintenance_cursor) VALUES(?,?) ON CONFLICT(account_key) DO UPDATE SET maintenance_cursor=excluded.maintenance_cursor',
      [owner, page.cursor],
    );
  });

  Future<void> recordTagWrite(
    String owner,
    PersonalDevice device,
    String tagUid,
  ) async {
    final current = (await devices(owner))
        .where(
          (d) =>
              d.printerKey == device.printerKey &&
              d.deviceToken == device.deviceToken &&
              !d.archived,
        )
        .firstOrNull;
    if (current == null) throw StateError('设备共享关系已变化，请刷新后重试');
    await db.customStatement(
      'INSERT INTO device_tag_operations(account_key,printer_key,device_token,tag_uid,occurred_at) VALUES(?,?,?,?,?)',
      [
        owner,
        device.printerKey,
        device.deviceToken,
        tagUid,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }
}
