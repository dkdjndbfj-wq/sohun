// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'printer_dao.dart';

// ignore_for_file: type=lint
mixin _$PrinterDaoMixin on DatabaseAccessor<AppDatabase> {
  $PrintersTable get printers => attachedDatabase.printers;
  $ConsumablesTable get consumables => attachedDatabase.consumables;
  $PrinterChannelsTable get printerChannels => attachedDatabase.printerChannels;
  $UsageLogsTable get usageLogs => attachedDatabase.usageLogs;
  PrinterDaoManager get managers => PrinterDaoManager(this);
}

class PrinterDaoManager {
  final _$PrinterDaoMixin _db;
  PrinterDaoManager(this._db);
  $$PrintersTableTableManager get printers =>
      $$PrintersTableTableManager(_db.attachedDatabase, _db.printers);
  $$ConsumablesTableTableManager get consumables =>
      $$ConsumablesTableTableManager(_db.attachedDatabase, _db.consumables);
  $$PrinterChannelsTableTableManager get printerChannels =>
      $$PrinterChannelsTableTableManager(
          _db.attachedDatabase, _db.printerChannels);
  $$UsageLogsTableTableManager get usageLogs =>
      $$UsageLogsTableTableManager(_db.attachedDatabase, _db.usageLogs);
}
