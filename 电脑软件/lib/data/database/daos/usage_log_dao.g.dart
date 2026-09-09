// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'usage_log_dao.dart';

// ignore_for_file: type=lint
mixin _$UsageLogDaoMixin on DatabaseAccessor<AppDatabase> {
  $PrintersTable get printers => attachedDatabase.printers;
  $ConsumablesTable get consumables => attachedDatabase.consumables;
  $UsageLogsTable get usageLogs => attachedDatabase.usageLogs;
  UsageLogDaoManager get managers => UsageLogDaoManager(this);
}

class UsageLogDaoManager {
  final _$UsageLogDaoMixin _db;
  UsageLogDaoManager(this._db);
  $$PrintersTableTableManager get printers =>
      $$PrintersTableTableManager(_db.attachedDatabase, _db.printers);
  $$ConsumablesTableTableManager get consumables =>
      $$ConsumablesTableTableManager(_db.attachedDatabase, _db.consumables);
  $$UsageLogsTableTableManager get usageLogs =>
      $$UsageLogsTableTableManager(_db.attachedDatabase, _db.usageLogs);
}
