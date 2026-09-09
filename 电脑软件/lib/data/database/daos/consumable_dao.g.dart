// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'consumable_dao.dart';

// ignore_for_file: type=lint
mixin _$ConsumableDaoMixin on DatabaseAccessor<AppDatabase> {
  $ConsumablesTable get consumables => attachedDatabase.consumables;
  ConsumableDaoManager get managers => ConsumableDaoManager(this);
}

class ConsumableDaoManager {
  final _$ConsumableDaoMixin _db;
  ConsumableDaoManager(this._db);
  $$ConsumablesTableTableManager get consumables =>
      $$ConsumablesTableTableManager(_db.attachedDatabase, _db.consumables);
}
