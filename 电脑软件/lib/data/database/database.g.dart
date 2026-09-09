// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ConsumablesTable extends Consumables
    with TableInfo<$ConsumablesTable, Consumable> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConsumablesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
      'uid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _manufacturerMeta =
      const VerificationMeta('manufacturer');
  @override
  late final GeneratedColumn<String> manufacturer = GeneratedColumn<String>(
      'manufacturer', aliasedName, false,
      additionalChecks:
          GeneratedColumn.checkTextLength(minTextLength: 1, maxTextLength: 64),
      type: DriftSqlType.string,
      requiredDuringInsert: true);
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
      'model', aliasedName, false,
      additionalChecks:
          GeneratedColumn.checkTextLength(minTextLength: 1, maxTextLength: 64),
      type: DriftSqlType.string,
      requiredDuringInsert: true);
  static const VerificationMeta _materialTypeMeta =
      const VerificationMeta('materialType');
  @override
  late final GeneratedColumn<String> materialType = GeneratedColumn<String>(
      'material_type', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('PLA'));
  static const VerificationMeta _colorHexMeta =
      const VerificationMeta('colorHex');
  @override
  late final GeneratedColumn<String> colorHex = GeneratedColumn<String>(
      'color_hex', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('#FFFFFF'));
  static const VerificationMeta _colorNameMeta =
      const VerificationMeta('colorName');
  @override
  late final GeneratedColumn<String> colorName = GeneratedColumn<String>(
      'color_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _totalGramsMeta =
      const VerificationMeta('totalGrams');
  @override
  late final GeneratedColumn<double> totalGrams = GeneratedColumn<double>(
      'total_grams', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(1000.0));
  static const VerificationMeta _remainingGramsMeta =
      const VerificationMeta('remainingGrams');
  @override
  late final GeneratedColumn<double> remainingGrams = GeneratedColumn<double>(
      'remaining_grams', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(1000.0));
  static const VerificationMeta _batchNoMeta =
      const VerificationMeta('batchNo');
  @override
  late final GeneratedColumn<String> batchNo = GeneratedColumn<String>(
      'batch_no', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _purchaseDateMeta =
      const VerificationMeta('purchaseDate');
  @override
  late final GeneratedColumn<DateTime> purchaseDate = GeneratedColumn<DateTime>(
      'purchase_date', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _densityMeta =
      const VerificationMeta('density');
  @override
  late final GeneratedColumn<double> density = GeneratedColumn<double>(
      'density', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _recommendedNozzleTempMeta =
      const VerificationMeta('recommendedNozzleTemp');
  @override
  late final GeneratedColumn<double> recommendedNozzleTemp =
      GeneratedColumn<double>('recommended_nozzle_temp', aliasedName, true,
          type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _hygroscopicityMeta =
      const VerificationMeta('hygroscopicity');
  @override
  late final GeneratedColumn<String> hygroscopicity = GeneratedColumn<String>(
      'hygroscopicity', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _trayUuidMeta =
      const VerificationMeta('trayUuid');
  @override
  late final GeneratedColumn<String> trayUuid = GeneratedColumn<String>(
      'tray_uuid', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _rfidSyncedAtMeta =
      const VerificationMeta('rfidSyncedAt');
  @override
  late final GeneratedColumn<int> rfidSyncedAt = GeneratedColumn<int>(
      'rfid_synced_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        uid,
        manufacturer,
        model,
        materialType,
        colorHex,
        colorName,
        totalGrams,
        remainingGrams,
        batchNo,
        purchaseDate,
        note,
        createdAt,
        updatedAt,
        density,
        recommendedNozzleTemp,
        hygroscopicity,
        trayUuid,
        rfidSyncedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'consumables';
  @override
  VerificationContext validateIntegrity(Insertable<Consumable> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uid')) {
      context.handle(
          _uidMeta, uid.isAcceptableOrUnknown(data['uid']!, _uidMeta));
    }
    if (data.containsKey('manufacturer')) {
      context.handle(
          _manufacturerMeta,
          manufacturer.isAcceptableOrUnknown(
              data['manufacturer']!, _manufacturerMeta));
    } else if (isInserting) {
      context.missing(_manufacturerMeta);
    }
    if (data.containsKey('model')) {
      context.handle(
          _modelMeta, model.isAcceptableOrUnknown(data['model']!, _modelMeta));
    } else if (isInserting) {
      context.missing(_modelMeta);
    }
    if (data.containsKey('material_type')) {
      context.handle(
          _materialTypeMeta,
          materialType.isAcceptableOrUnknown(
              data['material_type']!, _materialTypeMeta));
    }
    if (data.containsKey('color_hex')) {
      context.handle(_colorHexMeta,
          colorHex.isAcceptableOrUnknown(data['color_hex']!, _colorHexMeta));
    }
    if (data.containsKey('color_name')) {
      context.handle(_colorNameMeta,
          colorName.isAcceptableOrUnknown(data['color_name']!, _colorNameMeta));
    }
    if (data.containsKey('total_grams')) {
      context.handle(
          _totalGramsMeta,
          totalGrams.isAcceptableOrUnknown(
              data['total_grams']!, _totalGramsMeta));
    }
    if (data.containsKey('remaining_grams')) {
      context.handle(
          _remainingGramsMeta,
          remainingGrams.isAcceptableOrUnknown(
              data['remaining_grams']!, _remainingGramsMeta));
    }
    if (data.containsKey('batch_no')) {
      context.handle(_batchNoMeta,
          batchNo.isAcceptableOrUnknown(data['batch_no']!, _batchNoMeta));
    }
    if (data.containsKey('purchase_date')) {
      context.handle(
          _purchaseDateMeta,
          purchaseDate.isAcceptableOrUnknown(
              data['purchase_date']!, _purchaseDateMeta));
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('density')) {
      context.handle(_densityMeta,
          density.isAcceptableOrUnknown(data['density']!, _densityMeta));
    }
    if (data.containsKey('recommended_nozzle_temp')) {
      context.handle(
          _recommendedNozzleTempMeta,
          recommendedNozzleTemp.isAcceptableOrUnknown(
              data['recommended_nozzle_temp']!, _recommendedNozzleTempMeta));
    }
    if (data.containsKey('hygroscopicity')) {
      context.handle(
          _hygroscopicityMeta,
          hygroscopicity.isAcceptableOrUnknown(
              data['hygroscopicity']!, _hygroscopicityMeta));
    }
    if (data.containsKey('tray_uuid')) {
      context.handle(_trayUuidMeta,
          trayUuid.isAcceptableOrUnknown(data['tray_uuid']!, _trayUuidMeta));
    }
    if (data.containsKey('rfid_synced_at')) {
      context.handle(
          _rfidSyncedAtMeta,
          rfidSyncedAt.isAcceptableOrUnknown(
              data['rfid_synced_at']!, _rfidSyncedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Consumable map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Consumable(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uid'])!,
      manufacturer: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}manufacturer'])!,
      model: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}model'])!,
      materialType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}material_type'])!,
      colorHex: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}color_hex'])!,
      colorName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}color_name']),
      totalGrams: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}total_grams'])!,
      remainingGrams: attachedDatabase.typeMapping.read(
          DriftSqlType.double, data['${effectivePrefix}remaining_grams'])!,
      batchNo: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}batch_no']),
      purchaseDate: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}purchase_date']),
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
      density: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}density']),
      recommendedNozzleTemp: attachedDatabase.typeMapping.read(
          DriftSqlType.double,
          data['${effectivePrefix}recommended_nozzle_temp']),
      hygroscopicity: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}hygroscopicity']),
      trayUuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}tray_uuid']),
      rfidSyncedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}rfid_synced_at']),
    );
  }

  @override
  $ConsumablesTable createAlias(String alias) {
    return $ConsumablesTable(attachedDatabase, alias);
  }
}

class Consumable extends DataClass implements Insertable<Consumable> {
  final int id;
  final String uid;
  final String manufacturer;
  final String model;
  final String materialType;
  final String colorHex;
  final String? colorName;
  final double totalGrams;
  final double remainingGrams;
  final String? batchNo;
  final DateTime? purchaseDate;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double? density;
  final double? recommendedNozzleTemp;
  final String? hygroscopicity;
  final String? trayUuid;
  final int? rfidSyncedAt;
  const Consumable(
      {required this.id,
      required this.uid,
      required this.manufacturer,
      required this.model,
      required this.materialType,
      required this.colorHex,
      this.colorName,
      required this.totalGrams,
      required this.remainingGrams,
      this.batchNo,
      this.purchaseDate,
      this.note,
      required this.createdAt,
      required this.updatedAt,
      this.density,
      this.recommendedNozzleTemp,
      this.hygroscopicity,
      this.trayUuid,
      this.rfidSyncedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uid'] = Variable<String>(uid);
    map['manufacturer'] = Variable<String>(manufacturer);
    map['model'] = Variable<String>(model);
    map['material_type'] = Variable<String>(materialType);
    map['color_hex'] = Variable<String>(colorHex);
    if (!nullToAbsent || colorName != null) {
      map['color_name'] = Variable<String>(colorName);
    }
    map['total_grams'] = Variable<double>(totalGrams);
    map['remaining_grams'] = Variable<double>(remainingGrams);
    if (!nullToAbsent || batchNo != null) {
      map['batch_no'] = Variable<String>(batchNo);
    }
    if (!nullToAbsent || purchaseDate != null) {
      map['purchase_date'] = Variable<DateTime>(purchaseDate);
    }
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || density != null) {
      map['density'] = Variable<double>(density);
    }
    if (!nullToAbsent || recommendedNozzleTemp != null) {
      map['recommended_nozzle_temp'] = Variable<double>(recommendedNozzleTemp);
    }
    if (!nullToAbsent || hygroscopicity != null) {
      map['hygroscopicity'] = Variable<String>(hygroscopicity);
    }
    if (!nullToAbsent || trayUuid != null) {
      map['tray_uuid'] = Variable<String>(trayUuid);
    }
    if (!nullToAbsent || rfidSyncedAt != null) {
      map['rfid_synced_at'] = Variable<int>(rfidSyncedAt);
    }
    return map;
  }

  ConsumablesCompanion toCompanion(bool nullToAbsent) {
    return ConsumablesCompanion(
      id: Value(id),
      uid: Value(uid),
      manufacturer: Value(manufacturer),
      model: Value(model),
      materialType: Value(materialType),
      colorHex: Value(colorHex),
      colorName: colorName == null && nullToAbsent
          ? const Value.absent()
          : Value(colorName),
      totalGrams: Value(totalGrams),
      remainingGrams: Value(remainingGrams),
      batchNo: batchNo == null && nullToAbsent
          ? const Value.absent()
          : Value(batchNo),
      purchaseDate: purchaseDate == null && nullToAbsent
          ? const Value.absent()
          : Value(purchaseDate),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      density: density == null && nullToAbsent
          ? const Value.absent()
          : Value(density),
      recommendedNozzleTemp: recommendedNozzleTemp == null && nullToAbsent
          ? const Value.absent()
          : Value(recommendedNozzleTemp),
      hygroscopicity: hygroscopicity == null && nullToAbsent
          ? const Value.absent()
          : Value(hygroscopicity),
      trayUuid: trayUuid == null && nullToAbsent
          ? const Value.absent()
          : Value(trayUuid),
      rfidSyncedAt: rfidSyncedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(rfidSyncedAt),
    );
  }

  factory Consumable.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Consumable(
      id: serializer.fromJson<int>(json['id']),
      uid: serializer.fromJson<String>(json['uid']),
      manufacturer: serializer.fromJson<String>(json['manufacturer']),
      model: serializer.fromJson<String>(json['model']),
      materialType: serializer.fromJson<String>(json['materialType']),
      colorHex: serializer.fromJson<String>(json['colorHex']),
      colorName: serializer.fromJson<String?>(json['colorName']),
      totalGrams: serializer.fromJson<double>(json['totalGrams']),
      remainingGrams: serializer.fromJson<double>(json['remainingGrams']),
      batchNo: serializer.fromJson<String?>(json['batchNo']),
      purchaseDate: serializer.fromJson<DateTime?>(json['purchaseDate']),
      note: serializer.fromJson<String?>(json['note']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      density: serializer.fromJson<double?>(json['density']),
      recommendedNozzleTemp:
          serializer.fromJson<double?>(json['recommendedNozzleTemp']),
      hygroscopicity: serializer.fromJson<String?>(json['hygroscopicity']),
      trayUuid: serializer.fromJson<String?>(json['trayUuid']),
      rfidSyncedAt: serializer.fromJson<int?>(json['rfidSyncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uid': serializer.toJson<String>(uid),
      'manufacturer': serializer.toJson<String>(manufacturer),
      'model': serializer.toJson<String>(model),
      'materialType': serializer.toJson<String>(materialType),
      'colorHex': serializer.toJson<String>(colorHex),
      'colorName': serializer.toJson<String?>(colorName),
      'totalGrams': serializer.toJson<double>(totalGrams),
      'remainingGrams': serializer.toJson<double>(remainingGrams),
      'batchNo': serializer.toJson<String?>(batchNo),
      'purchaseDate': serializer.toJson<DateTime?>(purchaseDate),
      'note': serializer.toJson<String?>(note),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'density': serializer.toJson<double?>(density),
      'recommendedNozzleTemp':
          serializer.toJson<double?>(recommendedNozzleTemp),
      'hygroscopicity': serializer.toJson<String?>(hygroscopicity),
      'trayUuid': serializer.toJson<String?>(trayUuid),
      'rfidSyncedAt': serializer.toJson<int?>(rfidSyncedAt),
    };
  }

  Consumable copyWith(
          {int? id,
          String? uid,
          String? manufacturer,
          String? model,
          String? materialType,
          String? colorHex,
          Value<String?> colorName = const Value.absent(),
          double? totalGrams,
          double? remainingGrams,
          Value<String?> batchNo = const Value.absent(),
          Value<DateTime?> purchaseDate = const Value.absent(),
          Value<String?> note = const Value.absent(),
          DateTime? createdAt,
          DateTime? updatedAt,
          Value<double?> density = const Value.absent(),
          Value<double?> recommendedNozzleTemp = const Value.absent(),
          Value<String?> hygroscopicity = const Value.absent(),
          Value<String?> trayUuid = const Value.absent(),
          Value<int?> rfidSyncedAt = const Value.absent()}) =>
      Consumable(
        id: id ?? this.id,
        uid: uid ?? this.uid,
        manufacturer: manufacturer ?? this.manufacturer,
        model: model ?? this.model,
        materialType: materialType ?? this.materialType,
        colorHex: colorHex ?? this.colorHex,
        colorName: colorName.present ? colorName.value : this.colorName,
        totalGrams: totalGrams ?? this.totalGrams,
        remainingGrams: remainingGrams ?? this.remainingGrams,
        batchNo: batchNo.present ? batchNo.value : this.batchNo,
        purchaseDate:
            purchaseDate.present ? purchaseDate.value : this.purchaseDate,
        note: note.present ? note.value : this.note,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        density: density.present ? density.value : this.density,
        recommendedNozzleTemp: recommendedNozzleTemp.present
            ? recommendedNozzleTemp.value
            : this.recommendedNozzleTemp,
        hygroscopicity:
            hygroscopicity.present ? hygroscopicity.value : this.hygroscopicity,
        trayUuid: trayUuid.present ? trayUuid.value : this.trayUuid,
        rfidSyncedAt:
            rfidSyncedAt.present ? rfidSyncedAt.value : this.rfidSyncedAt,
      );
  Consumable copyWithCompanion(ConsumablesCompanion data) {
    return Consumable(
      id: data.id.present ? data.id.value : this.id,
      uid: data.uid.present ? data.uid.value : this.uid,
      manufacturer: data.manufacturer.present
          ? data.manufacturer.value
          : this.manufacturer,
      model: data.model.present ? data.model.value : this.model,
      materialType: data.materialType.present
          ? data.materialType.value
          : this.materialType,
      colorHex: data.colorHex.present ? data.colorHex.value : this.colorHex,
      colorName: data.colorName.present ? data.colorName.value : this.colorName,
      totalGrams:
          data.totalGrams.present ? data.totalGrams.value : this.totalGrams,
      remainingGrams: data.remainingGrams.present
          ? data.remainingGrams.value
          : this.remainingGrams,
      batchNo: data.batchNo.present ? data.batchNo.value : this.batchNo,
      purchaseDate: data.purchaseDate.present
          ? data.purchaseDate.value
          : this.purchaseDate,
      note: data.note.present ? data.note.value : this.note,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      density: data.density.present ? data.density.value : this.density,
      recommendedNozzleTemp: data.recommendedNozzleTemp.present
          ? data.recommendedNozzleTemp.value
          : this.recommendedNozzleTemp,
      hygroscopicity: data.hygroscopicity.present
          ? data.hygroscopicity.value
          : this.hygroscopicity,
      trayUuid: data.trayUuid.present ? data.trayUuid.value : this.trayUuid,
      rfidSyncedAt: data.rfidSyncedAt.present
          ? data.rfidSyncedAt.value
          : this.rfidSyncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Consumable(')
          ..write('id: $id, ')
          ..write('uid: $uid, ')
          ..write('manufacturer: $manufacturer, ')
          ..write('model: $model, ')
          ..write('materialType: $materialType, ')
          ..write('colorHex: $colorHex, ')
          ..write('colorName: $colorName, ')
          ..write('totalGrams: $totalGrams, ')
          ..write('remainingGrams: $remainingGrams, ')
          ..write('batchNo: $batchNo, ')
          ..write('purchaseDate: $purchaseDate, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('density: $density, ')
          ..write('recommendedNozzleTemp: $recommendedNozzleTemp, ')
          ..write('hygroscopicity: $hygroscopicity, ')
          ..write('trayUuid: $trayUuid, ')
          ..write('rfidSyncedAt: $rfidSyncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      uid,
      manufacturer,
      model,
      materialType,
      colorHex,
      colorName,
      totalGrams,
      remainingGrams,
      batchNo,
      purchaseDate,
      note,
      createdAt,
      updatedAt,
      density,
      recommendedNozzleTemp,
      hygroscopicity,
      trayUuid,
      rfidSyncedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Consumable &&
          other.id == this.id &&
          other.uid == this.uid &&
          other.manufacturer == this.manufacturer &&
          other.model == this.model &&
          other.materialType == this.materialType &&
          other.colorHex == this.colorHex &&
          other.colorName == this.colorName &&
          other.totalGrams == this.totalGrams &&
          other.remainingGrams == this.remainingGrams &&
          other.batchNo == this.batchNo &&
          other.purchaseDate == this.purchaseDate &&
          other.note == this.note &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.density == this.density &&
          other.recommendedNozzleTemp == this.recommendedNozzleTemp &&
          other.hygroscopicity == this.hygroscopicity &&
          other.trayUuid == this.trayUuid &&
          other.rfidSyncedAt == this.rfidSyncedAt);
}

class ConsumablesCompanion extends UpdateCompanion<Consumable> {
  final Value<int> id;
  final Value<String> uid;
  final Value<String> manufacturer;
  final Value<String> model;
  final Value<String> materialType;
  final Value<String> colorHex;
  final Value<String?> colorName;
  final Value<double> totalGrams;
  final Value<double> remainingGrams;
  final Value<String?> batchNo;
  final Value<DateTime?> purchaseDate;
  final Value<String?> note;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<double?> density;
  final Value<double?> recommendedNozzleTemp;
  final Value<String?> hygroscopicity;
  final Value<String?> trayUuid;
  final Value<int?> rfidSyncedAt;
  const ConsumablesCompanion({
    this.id = const Value.absent(),
    this.uid = const Value.absent(),
    this.manufacturer = const Value.absent(),
    this.model = const Value.absent(),
    this.materialType = const Value.absent(),
    this.colorHex = const Value.absent(),
    this.colorName = const Value.absent(),
    this.totalGrams = const Value.absent(),
    this.remainingGrams = const Value.absent(),
    this.batchNo = const Value.absent(),
    this.purchaseDate = const Value.absent(),
    this.note = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.density = const Value.absent(),
    this.recommendedNozzleTemp = const Value.absent(),
    this.hygroscopicity = const Value.absent(),
    this.trayUuid = const Value.absent(),
    this.rfidSyncedAt = const Value.absent(),
  });
  ConsumablesCompanion.insert({
    this.id = const Value.absent(),
    this.uid = const Value.absent(),
    required String manufacturer,
    required String model,
    this.materialType = const Value.absent(),
    this.colorHex = const Value.absent(),
    this.colorName = const Value.absent(),
    this.totalGrams = const Value.absent(),
    this.remainingGrams = const Value.absent(),
    this.batchNo = const Value.absent(),
    this.purchaseDate = const Value.absent(),
    this.note = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.density = const Value.absent(),
    this.recommendedNozzleTemp = const Value.absent(),
    this.hygroscopicity = const Value.absent(),
    this.trayUuid = const Value.absent(),
    this.rfidSyncedAt = const Value.absent(),
  })  : manufacturer = Value(manufacturer),
        model = Value(model);
  static Insertable<Consumable> custom({
    Expression<int>? id,
    Expression<String>? uid,
    Expression<String>? manufacturer,
    Expression<String>? model,
    Expression<String>? materialType,
    Expression<String>? colorHex,
    Expression<String>? colorName,
    Expression<double>? totalGrams,
    Expression<double>? remainingGrams,
    Expression<String>? batchNo,
    Expression<DateTime>? purchaseDate,
    Expression<String>? note,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<double>? density,
    Expression<double>? recommendedNozzleTemp,
    Expression<String>? hygroscopicity,
    Expression<String>? trayUuid,
    Expression<int>? rfidSyncedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uid != null) 'uid': uid,
      if (manufacturer != null) 'manufacturer': manufacturer,
      if (model != null) 'model': model,
      if (materialType != null) 'material_type': materialType,
      if (colorHex != null) 'color_hex': colorHex,
      if (colorName != null) 'color_name': colorName,
      if (totalGrams != null) 'total_grams': totalGrams,
      if (remainingGrams != null) 'remaining_grams': remainingGrams,
      if (batchNo != null) 'batch_no': batchNo,
      if (purchaseDate != null) 'purchase_date': purchaseDate,
      if (note != null) 'note': note,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (density != null) 'density': density,
      if (recommendedNozzleTemp != null)
        'recommended_nozzle_temp': recommendedNozzleTemp,
      if (hygroscopicity != null) 'hygroscopicity': hygroscopicity,
      if (trayUuid != null) 'tray_uuid': trayUuid,
      if (rfidSyncedAt != null) 'rfid_synced_at': rfidSyncedAt,
    });
  }

  ConsumablesCompanion copyWith(
      {Value<int>? id,
      Value<String>? uid,
      Value<String>? manufacturer,
      Value<String>? model,
      Value<String>? materialType,
      Value<String>? colorHex,
      Value<String?>? colorName,
      Value<double>? totalGrams,
      Value<double>? remainingGrams,
      Value<String?>? batchNo,
      Value<DateTime?>? purchaseDate,
      Value<String?>? note,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt,
      Value<double?>? density,
      Value<double?>? recommendedNozzleTemp,
      Value<String?>? hygroscopicity,
      Value<String?>? trayUuid,
      Value<int?>? rfidSyncedAt}) {
    return ConsumablesCompanion(
      id: id ?? this.id,
      uid: uid ?? this.uid,
      manufacturer: manufacturer ?? this.manufacturer,
      model: model ?? this.model,
      materialType: materialType ?? this.materialType,
      colorHex: colorHex ?? this.colorHex,
      colorName: colorName ?? this.colorName,
      totalGrams: totalGrams ?? this.totalGrams,
      remainingGrams: remainingGrams ?? this.remainingGrams,
      batchNo: batchNo ?? this.batchNo,
      purchaseDate: purchaseDate ?? this.purchaseDate,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      density: density ?? this.density,
      recommendedNozzleTemp:
          recommendedNozzleTemp ?? this.recommendedNozzleTemp,
      hygroscopicity: hygroscopicity ?? this.hygroscopicity,
      trayUuid: trayUuid ?? this.trayUuid,
      rfidSyncedAt: rfidSyncedAt ?? this.rfidSyncedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (manufacturer.present) {
      map['manufacturer'] = Variable<String>(manufacturer.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (materialType.present) {
      map['material_type'] = Variable<String>(materialType.value);
    }
    if (colorHex.present) {
      map['color_hex'] = Variable<String>(colorHex.value);
    }
    if (colorName.present) {
      map['color_name'] = Variable<String>(colorName.value);
    }
    if (totalGrams.present) {
      map['total_grams'] = Variable<double>(totalGrams.value);
    }
    if (remainingGrams.present) {
      map['remaining_grams'] = Variable<double>(remainingGrams.value);
    }
    if (batchNo.present) {
      map['batch_no'] = Variable<String>(batchNo.value);
    }
    if (purchaseDate.present) {
      map['purchase_date'] = Variable<DateTime>(purchaseDate.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (density.present) {
      map['density'] = Variable<double>(density.value);
    }
    if (recommendedNozzleTemp.present) {
      map['recommended_nozzle_temp'] =
          Variable<double>(recommendedNozzleTemp.value);
    }
    if (hygroscopicity.present) {
      map['hygroscopicity'] = Variable<String>(hygroscopicity.value);
    }
    if (trayUuid.present) {
      map['tray_uuid'] = Variable<String>(trayUuid.value);
    }
    if (rfidSyncedAt.present) {
      map['rfid_synced_at'] = Variable<int>(rfidSyncedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConsumablesCompanion(')
          ..write('id: $id, ')
          ..write('uid: $uid, ')
          ..write('manufacturer: $manufacturer, ')
          ..write('model: $model, ')
          ..write('materialType: $materialType, ')
          ..write('colorHex: $colorHex, ')
          ..write('colorName: $colorName, ')
          ..write('totalGrams: $totalGrams, ')
          ..write('remainingGrams: $remainingGrams, ')
          ..write('batchNo: $batchNo, ')
          ..write('purchaseDate: $purchaseDate, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('density: $density, ')
          ..write('recommendedNozzleTemp: $recommendedNozzleTemp, ')
          ..write('hygroscopicity: $hygroscopicity, ')
          ..write('trayUuid: $trayUuid, ')
          ..write('rfidSyncedAt: $rfidSyncedAt')
          ..write(')'))
        .toString();
  }
}

class $PrintersTable extends Printers with TableInfo<$PrintersTable, Printer> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PrintersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
      'uid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _brandMeta = const VerificationMeta('brand');
  @override
  late final GeneratedColumn<String> brand = GeneratedColumn<String>(
      'brand', aliasedName, false,
      additionalChecks:
          GeneratedColumn.checkTextLength(minTextLength: 1, maxTextLength: 64),
      type: DriftSqlType.string,
      requiredDuringInsert: true);
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
      'model', aliasedName, false,
      additionalChecks:
          GeneratedColumn.checkTextLength(minTextLength: 1, maxTextLength: 64),
      type: DriftSqlType.string,
      requiredDuringInsert: true);
  static const VerificationMeta _channelCountMeta =
      const VerificationMeta('channelCount');
  @override
  late final GeneratedColumn<int> channelCount = GeneratedColumn<int>(
      'channel_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _imageAssetMeta =
      const VerificationMeta('imageAsset');
  @override
  late final GeneratedColumn<String> imageAsset = GeneratedColumn<String>(
      'image_asset', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _isCustomImageMeta =
      const VerificationMeta('isCustomImage');
  @override
  late final GeneratedColumn<bool> isCustomImage = GeneratedColumn<bool>(
      'is_custom_image', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("is_custom_image" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _ownerAccountMeta =
      const VerificationMeta('ownerAccount');
  @override
  late final GeneratedColumn<String> ownerAccount = GeneratedColumn<String>(
      'owner_account', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        uid,
        name,
        brand,
        model,
        channelCount,
        imageAsset,
        isCustomImage,
        note,
        createdAt,
        updatedAt,
        ownerAccount
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'printers';
  @override
  VerificationContext validateIntegrity(Insertable<Printer> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uid')) {
      context.handle(
          _uidMeta, uid.isAcceptableOrUnknown(data['uid']!, _uidMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    }
    if (data.containsKey('brand')) {
      context.handle(
          _brandMeta, brand.isAcceptableOrUnknown(data['brand']!, _brandMeta));
    } else if (isInserting) {
      context.missing(_brandMeta);
    }
    if (data.containsKey('model')) {
      context.handle(
          _modelMeta, model.isAcceptableOrUnknown(data['model']!, _modelMeta));
    } else if (isInserting) {
      context.missing(_modelMeta);
    }
    if (data.containsKey('channel_count')) {
      context.handle(
          _channelCountMeta,
          channelCount.isAcceptableOrUnknown(
              data['channel_count']!, _channelCountMeta));
    }
    if (data.containsKey('image_asset')) {
      context.handle(
          _imageAssetMeta,
          imageAsset.isAcceptableOrUnknown(
              data['image_asset']!, _imageAssetMeta));
    }
    if (data.containsKey('is_custom_image')) {
      context.handle(
          _isCustomImageMeta,
          isCustomImage.isAcceptableOrUnknown(
              data['is_custom_image']!, _isCustomImageMeta));
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('owner_account')) {
      context.handle(
          _ownerAccountMeta,
          ownerAccount.isAcceptableOrUnknown(
              data['owner_account']!, _ownerAccountMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Printer map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Printer(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uid'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name']),
      brand: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}brand'])!,
      model: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}model'])!,
      channelCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}channel_count'])!,
      imageAsset: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}image_asset']),
      isCustomImage: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_custom_image'])!,
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
      ownerAccount: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}owner_account']),
    );
  }

  @override
  $PrintersTable createAlias(String alias) {
    return $PrintersTable(attachedDatabase, alias);
  }
}

class Printer extends DataClass implements Insertable<Printer> {
  final int id;
  final String uid;
  final String? name;
  final String brand;
  final String model;
  final int channelCount;
  final String? imageAsset;
  final bool isCustomImage;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 所属拓竹账号标识（email|region_code 格式，如 "user@example.com|China"）
  /// null 表示未关联账号（手动添加的本地打印机）
  /// 用于多账号场景下记录打印机归属
  final String? ownerAccount;
  const Printer(
      {required this.id,
      required this.uid,
      this.name,
      required this.brand,
      required this.model,
      required this.channelCount,
      this.imageAsset,
      required this.isCustomImage,
      this.note,
      required this.createdAt,
      required this.updatedAt,
      this.ownerAccount});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uid'] = Variable<String>(uid);
    if (!nullToAbsent || name != null) {
      map['name'] = Variable<String>(name);
    }
    map['brand'] = Variable<String>(brand);
    map['model'] = Variable<String>(model);
    map['channel_count'] = Variable<int>(channelCount);
    if (!nullToAbsent || imageAsset != null) {
      map['image_asset'] = Variable<String>(imageAsset);
    }
    map['is_custom_image'] = Variable<bool>(isCustomImage);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || ownerAccount != null) {
      map['owner_account'] = Variable<String>(ownerAccount);
    }
    return map;
  }

  PrintersCompanion toCompanion(bool nullToAbsent) {
    return PrintersCompanion(
      id: Value(id),
      uid: Value(uid),
      name: name == null && nullToAbsent ? const Value.absent() : Value(name),
      brand: Value(brand),
      model: Value(model),
      channelCount: Value(channelCount),
      imageAsset: imageAsset == null && nullToAbsent
          ? const Value.absent()
          : Value(imageAsset),
      isCustomImage: Value(isCustomImage),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      ownerAccount: ownerAccount == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerAccount),
    );
  }

  factory Printer.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Printer(
      id: serializer.fromJson<int>(json['id']),
      uid: serializer.fromJson<String>(json['uid']),
      name: serializer.fromJson<String?>(json['name']),
      brand: serializer.fromJson<String>(json['brand']),
      model: serializer.fromJson<String>(json['model']),
      channelCount: serializer.fromJson<int>(json['channelCount']),
      imageAsset: serializer.fromJson<String?>(json['imageAsset']),
      isCustomImage: serializer.fromJson<bool>(json['isCustomImage']),
      note: serializer.fromJson<String?>(json['note']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      ownerAccount: serializer.fromJson<String?>(json['ownerAccount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uid': serializer.toJson<String>(uid),
      'name': serializer.toJson<String?>(name),
      'brand': serializer.toJson<String>(brand),
      'model': serializer.toJson<String>(model),
      'channelCount': serializer.toJson<int>(channelCount),
      'imageAsset': serializer.toJson<String?>(imageAsset),
      'isCustomImage': serializer.toJson<bool>(isCustomImage),
      'note': serializer.toJson<String?>(note),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'ownerAccount': serializer.toJson<String?>(ownerAccount),
    };
  }

  Printer copyWith(
          {int? id,
          String? uid,
          Value<String?> name = const Value.absent(),
          String? brand,
          String? model,
          int? channelCount,
          Value<String?> imageAsset = const Value.absent(),
          bool? isCustomImage,
          Value<String?> note = const Value.absent(),
          DateTime? createdAt,
          DateTime? updatedAt,
          Value<String?> ownerAccount = const Value.absent()}) =>
      Printer(
        id: id ?? this.id,
        uid: uid ?? this.uid,
        name: name.present ? name.value : this.name,
        brand: brand ?? this.brand,
        model: model ?? this.model,
        channelCount: channelCount ?? this.channelCount,
        imageAsset: imageAsset.present ? imageAsset.value : this.imageAsset,
        isCustomImage: isCustomImage ?? this.isCustomImage,
        note: note.present ? note.value : this.note,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        ownerAccount:
            ownerAccount.present ? ownerAccount.value : this.ownerAccount,
      );
  Printer copyWithCompanion(PrintersCompanion data) {
    return Printer(
      id: data.id.present ? data.id.value : this.id,
      uid: data.uid.present ? data.uid.value : this.uid,
      name: data.name.present ? data.name.value : this.name,
      brand: data.brand.present ? data.brand.value : this.brand,
      model: data.model.present ? data.model.value : this.model,
      channelCount: data.channelCount.present
          ? data.channelCount.value
          : this.channelCount,
      imageAsset:
          data.imageAsset.present ? data.imageAsset.value : this.imageAsset,
      isCustomImage: data.isCustomImage.present
          ? data.isCustomImage.value
          : this.isCustomImage,
      note: data.note.present ? data.note.value : this.note,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      ownerAccount: data.ownerAccount.present
          ? data.ownerAccount.value
          : this.ownerAccount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Printer(')
          ..write('id: $id, ')
          ..write('uid: $uid, ')
          ..write('name: $name, ')
          ..write('brand: $brand, ')
          ..write('model: $model, ')
          ..write('channelCount: $channelCount, ')
          ..write('imageAsset: $imageAsset, ')
          ..write('isCustomImage: $isCustomImage, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('ownerAccount: $ownerAccount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, uid, name, brand, model, channelCount,
      imageAsset, isCustomImage, note, createdAt, updatedAt, ownerAccount);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Printer &&
          other.id == this.id &&
          other.uid == this.uid &&
          other.name == this.name &&
          other.brand == this.brand &&
          other.model == this.model &&
          other.channelCount == this.channelCount &&
          other.imageAsset == this.imageAsset &&
          other.isCustomImage == this.isCustomImage &&
          other.note == this.note &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.ownerAccount == this.ownerAccount);
}

class PrintersCompanion extends UpdateCompanion<Printer> {
  final Value<int> id;
  final Value<String> uid;
  final Value<String?> name;
  final Value<String> brand;
  final Value<String> model;
  final Value<int> channelCount;
  final Value<String?> imageAsset;
  final Value<bool> isCustomImage;
  final Value<String?> note;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<String?> ownerAccount;
  const PrintersCompanion({
    this.id = const Value.absent(),
    this.uid = const Value.absent(),
    this.name = const Value.absent(),
    this.brand = const Value.absent(),
    this.model = const Value.absent(),
    this.channelCount = const Value.absent(),
    this.imageAsset = const Value.absent(),
    this.isCustomImage = const Value.absent(),
    this.note = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.ownerAccount = const Value.absent(),
  });
  PrintersCompanion.insert({
    this.id = const Value.absent(),
    this.uid = const Value.absent(),
    this.name = const Value.absent(),
    required String brand,
    required String model,
    this.channelCount = const Value.absent(),
    this.imageAsset = const Value.absent(),
    this.isCustomImage = const Value.absent(),
    this.note = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.ownerAccount = const Value.absent(),
  })  : brand = Value(brand),
        model = Value(model);
  static Insertable<Printer> custom({
    Expression<int>? id,
    Expression<String>? uid,
    Expression<String>? name,
    Expression<String>? brand,
    Expression<String>? model,
    Expression<int>? channelCount,
    Expression<String>? imageAsset,
    Expression<bool>? isCustomImage,
    Expression<String>? note,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<String>? ownerAccount,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uid != null) 'uid': uid,
      if (name != null) 'name': name,
      if (brand != null) 'brand': brand,
      if (model != null) 'model': model,
      if (channelCount != null) 'channel_count': channelCount,
      if (imageAsset != null) 'image_asset': imageAsset,
      if (isCustomImage != null) 'is_custom_image': isCustomImage,
      if (note != null) 'note': note,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (ownerAccount != null) 'owner_account': ownerAccount,
    });
  }

  PrintersCompanion copyWith(
      {Value<int>? id,
      Value<String>? uid,
      Value<String?>? name,
      Value<String>? brand,
      Value<String>? model,
      Value<int>? channelCount,
      Value<String?>? imageAsset,
      Value<bool>? isCustomImage,
      Value<String?>? note,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt,
      Value<String?>? ownerAccount}) {
    return PrintersCompanion(
      id: id ?? this.id,
      uid: uid ?? this.uid,
      name: name ?? this.name,
      brand: brand ?? this.brand,
      model: model ?? this.model,
      channelCount: channelCount ?? this.channelCount,
      imageAsset: imageAsset ?? this.imageAsset,
      isCustomImage: isCustomImage ?? this.isCustomImage,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      ownerAccount: ownerAccount ?? this.ownerAccount,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (brand.present) {
      map['brand'] = Variable<String>(brand.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (channelCount.present) {
      map['channel_count'] = Variable<int>(channelCount.value);
    }
    if (imageAsset.present) {
      map['image_asset'] = Variable<String>(imageAsset.value);
    }
    if (isCustomImage.present) {
      map['is_custom_image'] = Variable<bool>(isCustomImage.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (ownerAccount.present) {
      map['owner_account'] = Variable<String>(ownerAccount.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PrintersCompanion(')
          ..write('id: $id, ')
          ..write('uid: $uid, ')
          ..write('name: $name, ')
          ..write('brand: $brand, ')
          ..write('model: $model, ')
          ..write('channelCount: $channelCount, ')
          ..write('imageAsset: $imageAsset, ')
          ..write('isCustomImage: $isCustomImage, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('ownerAccount: $ownerAccount')
          ..write(')'))
        .toString();
  }
}

class $PrinterChannelsTable extends PrinterChannels
    with TableInfo<$PrinterChannelsTable, PrinterChannel> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PrinterChannelsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _printerIdMeta =
      const VerificationMeta('printerId');
  @override
  late final GeneratedColumn<int> printerId = GeneratedColumn<int>(
      'printer_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES printers (id) ON DELETE CASCADE'));
  static const VerificationMeta _channelIndexMeta =
      const VerificationMeta('channelIndex');
  @override
  late final GeneratedColumn<int> channelIndex = GeneratedColumn<int>(
      'channel_index', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
      'label', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('A'));
  static const VerificationMeta _consumableIdMeta =
      const VerificationMeta('consumableId');
  @override
  late final GeneratedColumn<int> consumableId = GeneratedColumn<int>(
      'consumable_id', aliasedName, true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES consumables (id) ON DELETE SET NULL'));
  static const VerificationMeta _loadedRemainingGramsMeta =
      const VerificationMeta('loadedRemainingGrams');
  @override
  late final GeneratedColumn<double> loadedRemainingGrams =
      GeneratedColumn<double>('loaded_remaining_grams', aliasedName, false,
          type: DriftSqlType.double,
          requiredDuringInsert: false,
          defaultValue: const Constant(0));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        printerId,
        channelIndex,
        label,
        consumableId,
        loadedRemainingGrams,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'printer_channels';
  @override
  VerificationContext validateIntegrity(Insertable<PrinterChannel> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('printer_id')) {
      context.handle(_printerIdMeta,
          printerId.isAcceptableOrUnknown(data['printer_id']!, _printerIdMeta));
    } else if (isInserting) {
      context.missing(_printerIdMeta);
    }
    if (data.containsKey('channel_index')) {
      context.handle(
          _channelIndexMeta,
          channelIndex.isAcceptableOrUnknown(
              data['channel_index']!, _channelIndexMeta));
    } else if (isInserting) {
      context.missing(_channelIndexMeta);
    }
    if (data.containsKey('label')) {
      context.handle(
          _labelMeta, label.isAcceptableOrUnknown(data['label']!, _labelMeta));
    }
    if (data.containsKey('consumable_id')) {
      context.handle(
          _consumableIdMeta,
          consumableId.isAcceptableOrUnknown(
              data['consumable_id']!, _consumableIdMeta));
    }
    if (data.containsKey('loaded_remaining_grams')) {
      context.handle(
          _loadedRemainingGramsMeta,
          loadedRemainingGrams.isAcceptableOrUnknown(
              data['loaded_remaining_grams']!, _loadedRemainingGramsMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PrinterChannel map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PrinterChannel(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      printerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}printer_id'])!,
      channelIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}channel_index'])!,
      label: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}label'])!,
      consumableId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}consumable_id']),
      loadedRemainingGrams: attachedDatabase.typeMapping.read(
          DriftSqlType.double,
          data['${effectivePrefix}loaded_remaining_grams'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $PrinterChannelsTable createAlias(String alias) {
    return $PrinterChannelsTable(attachedDatabase, alias);
  }
}

class PrinterChannel extends DataClass implements Insertable<PrinterChannel> {
  final int id;
  final int printerId;
  final int channelIndex;
  final String label;
  final int? consumableId;
  final double loadedRemainingGrams;
  final DateTime updatedAt;
  const PrinterChannel(
      {required this.id,
      required this.printerId,
      required this.channelIndex,
      required this.label,
      this.consumableId,
      required this.loadedRemainingGrams,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['printer_id'] = Variable<int>(printerId);
    map['channel_index'] = Variable<int>(channelIndex);
    map['label'] = Variable<String>(label);
    if (!nullToAbsent || consumableId != null) {
      map['consumable_id'] = Variable<int>(consumableId);
    }
    map['loaded_remaining_grams'] = Variable<double>(loadedRemainingGrams);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  PrinterChannelsCompanion toCompanion(bool nullToAbsent) {
    return PrinterChannelsCompanion(
      id: Value(id),
      printerId: Value(printerId),
      channelIndex: Value(channelIndex),
      label: Value(label),
      consumableId: consumableId == null && nullToAbsent
          ? const Value.absent()
          : Value(consumableId),
      loadedRemainingGrams: Value(loadedRemainingGrams),
      updatedAt: Value(updatedAt),
    );
  }

  factory PrinterChannel.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PrinterChannel(
      id: serializer.fromJson<int>(json['id']),
      printerId: serializer.fromJson<int>(json['printerId']),
      channelIndex: serializer.fromJson<int>(json['channelIndex']),
      label: serializer.fromJson<String>(json['label']),
      consumableId: serializer.fromJson<int?>(json['consumableId']),
      loadedRemainingGrams:
          serializer.fromJson<double>(json['loadedRemainingGrams']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'printerId': serializer.toJson<int>(printerId),
      'channelIndex': serializer.toJson<int>(channelIndex),
      'label': serializer.toJson<String>(label),
      'consumableId': serializer.toJson<int?>(consumableId),
      'loadedRemainingGrams': serializer.toJson<double>(loadedRemainingGrams),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  PrinterChannel copyWith(
          {int? id,
          int? printerId,
          int? channelIndex,
          String? label,
          Value<int?> consumableId = const Value.absent(),
          double? loadedRemainingGrams,
          DateTime? updatedAt}) =>
      PrinterChannel(
        id: id ?? this.id,
        printerId: printerId ?? this.printerId,
        channelIndex: channelIndex ?? this.channelIndex,
        label: label ?? this.label,
        consumableId:
            consumableId.present ? consumableId.value : this.consumableId,
        loadedRemainingGrams: loadedRemainingGrams ?? this.loadedRemainingGrams,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  PrinterChannel copyWithCompanion(PrinterChannelsCompanion data) {
    return PrinterChannel(
      id: data.id.present ? data.id.value : this.id,
      printerId: data.printerId.present ? data.printerId.value : this.printerId,
      channelIndex: data.channelIndex.present
          ? data.channelIndex.value
          : this.channelIndex,
      label: data.label.present ? data.label.value : this.label,
      consumableId: data.consumableId.present
          ? data.consumableId.value
          : this.consumableId,
      loadedRemainingGrams: data.loadedRemainingGrams.present
          ? data.loadedRemainingGrams.value
          : this.loadedRemainingGrams,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PrinterChannel(')
          ..write('id: $id, ')
          ..write('printerId: $printerId, ')
          ..write('channelIndex: $channelIndex, ')
          ..write('label: $label, ')
          ..write('consumableId: $consumableId, ')
          ..write('loadedRemainingGrams: $loadedRemainingGrams, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, printerId, channelIndex, label,
      consumableId, loadedRemainingGrams, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PrinterChannel &&
          other.id == this.id &&
          other.printerId == this.printerId &&
          other.channelIndex == this.channelIndex &&
          other.label == this.label &&
          other.consumableId == this.consumableId &&
          other.loadedRemainingGrams == this.loadedRemainingGrams &&
          other.updatedAt == this.updatedAt);
}

class PrinterChannelsCompanion extends UpdateCompanion<PrinterChannel> {
  final Value<int> id;
  final Value<int> printerId;
  final Value<int> channelIndex;
  final Value<String> label;
  final Value<int?> consumableId;
  final Value<double> loadedRemainingGrams;
  final Value<DateTime> updatedAt;
  const PrinterChannelsCompanion({
    this.id = const Value.absent(),
    this.printerId = const Value.absent(),
    this.channelIndex = const Value.absent(),
    this.label = const Value.absent(),
    this.consumableId = const Value.absent(),
    this.loadedRemainingGrams = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  PrinterChannelsCompanion.insert({
    this.id = const Value.absent(),
    required int printerId,
    required int channelIndex,
    this.label = const Value.absent(),
    this.consumableId = const Value.absent(),
    this.loadedRemainingGrams = const Value.absent(),
    this.updatedAt = const Value.absent(),
  })  : printerId = Value(printerId),
        channelIndex = Value(channelIndex);
  static Insertable<PrinterChannel> custom({
    Expression<int>? id,
    Expression<int>? printerId,
    Expression<int>? channelIndex,
    Expression<String>? label,
    Expression<int>? consumableId,
    Expression<double>? loadedRemainingGrams,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (printerId != null) 'printer_id': printerId,
      if (channelIndex != null) 'channel_index': channelIndex,
      if (label != null) 'label': label,
      if (consumableId != null) 'consumable_id': consumableId,
      if (loadedRemainingGrams != null)
        'loaded_remaining_grams': loadedRemainingGrams,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  PrinterChannelsCompanion copyWith(
      {Value<int>? id,
      Value<int>? printerId,
      Value<int>? channelIndex,
      Value<String>? label,
      Value<int?>? consumableId,
      Value<double>? loadedRemainingGrams,
      Value<DateTime>? updatedAt}) {
    return PrinterChannelsCompanion(
      id: id ?? this.id,
      printerId: printerId ?? this.printerId,
      channelIndex: channelIndex ?? this.channelIndex,
      label: label ?? this.label,
      consumableId: consumableId ?? this.consumableId,
      loadedRemainingGrams: loadedRemainingGrams ?? this.loadedRemainingGrams,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (printerId.present) {
      map['printer_id'] = Variable<int>(printerId.value);
    }
    if (channelIndex.present) {
      map['channel_index'] = Variable<int>(channelIndex.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (consumableId.present) {
      map['consumable_id'] = Variable<int>(consumableId.value);
    }
    if (loadedRemainingGrams.present) {
      map['loaded_remaining_grams'] =
          Variable<double>(loadedRemainingGrams.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PrinterChannelsCompanion(')
          ..write('id: $id, ')
          ..write('printerId: $printerId, ')
          ..write('channelIndex: $channelIndex, ')
          ..write('label: $label, ')
          ..write('consumableId: $consumableId, ')
          ..write('loadedRemainingGrams: $loadedRemainingGrams, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $UsageLogsTable extends UsageLogs
    with TableInfo<$UsageLogsTable, UsageLog> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UsageLogsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _printerIdMeta =
      const VerificationMeta('printerId');
  @override
  late final GeneratedColumn<int> printerId = GeneratedColumn<int>(
      'printer_id', aliasedName, true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES printers (id) ON DELETE SET NULL'));
  static const VerificationMeta _channelIndexMeta =
      const VerificationMeta('channelIndex');
  @override
  late final GeneratedColumn<int> channelIndex = GeneratedColumn<int>(
      'channel_index', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _consumableIdMeta =
      const VerificationMeta('consumableId');
  @override
  late final GeneratedColumn<int> consumableId = GeneratedColumn<int>(
      'consumable_id', aliasedName, true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES consumables (id) ON DELETE SET NULL'));
  static const VerificationMeta _consumedGramsMeta =
      const VerificationMeta('consumedGrams');
  @override
  late final GeneratedColumn<double> consumedGrams = GeneratedColumn<double>(
      'consumed_grams', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _finishedMeta =
      const VerificationMeta('finished');
  @override
  late final GeneratedColumn<bool> finished = GeneratedColumn<bool>(
      'finished', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("finished" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _loggedAtMeta =
      const VerificationMeta('loggedAt');
  @override
  late final GeneratedColumn<DateTime> loggedAt = GeneratedColumn<DateTime>(
      'logged_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        printerId,
        channelIndex,
        consumableId,
        consumedGrams,
        finished,
        note,
        loggedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'usage_logs';
  @override
  VerificationContext validateIntegrity(Insertable<UsageLog> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('printer_id')) {
      context.handle(_printerIdMeta,
          printerId.isAcceptableOrUnknown(data['printer_id']!, _printerIdMeta));
    }
    if (data.containsKey('channel_index')) {
      context.handle(
          _channelIndexMeta,
          channelIndex.isAcceptableOrUnknown(
              data['channel_index']!, _channelIndexMeta));
    }
    if (data.containsKey('consumable_id')) {
      context.handle(
          _consumableIdMeta,
          consumableId.isAcceptableOrUnknown(
              data['consumable_id']!, _consumableIdMeta));
    }
    if (data.containsKey('consumed_grams')) {
      context.handle(
          _consumedGramsMeta,
          consumedGrams.isAcceptableOrUnknown(
              data['consumed_grams']!, _consumedGramsMeta));
    }
    if (data.containsKey('finished')) {
      context.handle(_finishedMeta,
          finished.isAcceptableOrUnknown(data['finished']!, _finishedMeta));
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('logged_at')) {
      context.handle(_loggedAtMeta,
          loggedAt.isAcceptableOrUnknown(data['logged_at']!, _loggedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  UsageLog map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UsageLog(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      printerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}printer_id']),
      channelIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}channel_index'])!,
      consumableId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}consumable_id']),
      consumedGrams: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}consumed_grams'])!,
      finished: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}finished'])!,
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note']),
      loggedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}logged_at'])!,
    );
  }

  @override
  $UsageLogsTable createAlias(String alias) {
    return $UsageLogsTable(attachedDatabase, alias);
  }
}

class UsageLog extends DataClass implements Insertable<UsageLog> {
  final int id;
  final int? printerId;
  final int channelIndex;
  final int? consumableId;
  final double consumedGrams;
  final bool finished;
  final String? note;
  final DateTime loggedAt;
  const UsageLog(
      {required this.id,
      this.printerId,
      required this.channelIndex,
      this.consumableId,
      required this.consumedGrams,
      required this.finished,
      this.note,
      required this.loggedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || printerId != null) {
      map['printer_id'] = Variable<int>(printerId);
    }
    map['channel_index'] = Variable<int>(channelIndex);
    if (!nullToAbsent || consumableId != null) {
      map['consumable_id'] = Variable<int>(consumableId);
    }
    map['consumed_grams'] = Variable<double>(consumedGrams);
    map['finished'] = Variable<bool>(finished);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['logged_at'] = Variable<DateTime>(loggedAt);
    return map;
  }

  UsageLogsCompanion toCompanion(bool nullToAbsent) {
    return UsageLogsCompanion(
      id: Value(id),
      printerId: printerId == null && nullToAbsent
          ? const Value.absent()
          : Value(printerId),
      channelIndex: Value(channelIndex),
      consumableId: consumableId == null && nullToAbsent
          ? const Value.absent()
          : Value(consumableId),
      consumedGrams: Value(consumedGrams),
      finished: Value(finished),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      loggedAt: Value(loggedAt),
    );
  }

  factory UsageLog.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UsageLog(
      id: serializer.fromJson<int>(json['id']),
      printerId: serializer.fromJson<int?>(json['printerId']),
      channelIndex: serializer.fromJson<int>(json['channelIndex']),
      consumableId: serializer.fromJson<int?>(json['consumableId']),
      consumedGrams: serializer.fromJson<double>(json['consumedGrams']),
      finished: serializer.fromJson<bool>(json['finished']),
      note: serializer.fromJson<String?>(json['note']),
      loggedAt: serializer.fromJson<DateTime>(json['loggedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'printerId': serializer.toJson<int?>(printerId),
      'channelIndex': serializer.toJson<int>(channelIndex),
      'consumableId': serializer.toJson<int?>(consumableId),
      'consumedGrams': serializer.toJson<double>(consumedGrams),
      'finished': serializer.toJson<bool>(finished),
      'note': serializer.toJson<String?>(note),
      'loggedAt': serializer.toJson<DateTime>(loggedAt),
    };
  }

  UsageLog copyWith(
          {int? id,
          Value<int?> printerId = const Value.absent(),
          int? channelIndex,
          Value<int?> consumableId = const Value.absent(),
          double? consumedGrams,
          bool? finished,
          Value<String?> note = const Value.absent(),
          DateTime? loggedAt}) =>
      UsageLog(
        id: id ?? this.id,
        printerId: printerId.present ? printerId.value : this.printerId,
        channelIndex: channelIndex ?? this.channelIndex,
        consumableId:
            consumableId.present ? consumableId.value : this.consumableId,
        consumedGrams: consumedGrams ?? this.consumedGrams,
        finished: finished ?? this.finished,
        note: note.present ? note.value : this.note,
        loggedAt: loggedAt ?? this.loggedAt,
      );
  UsageLog copyWithCompanion(UsageLogsCompanion data) {
    return UsageLog(
      id: data.id.present ? data.id.value : this.id,
      printerId: data.printerId.present ? data.printerId.value : this.printerId,
      channelIndex: data.channelIndex.present
          ? data.channelIndex.value
          : this.channelIndex,
      consumableId: data.consumableId.present
          ? data.consumableId.value
          : this.consumableId,
      consumedGrams: data.consumedGrams.present
          ? data.consumedGrams.value
          : this.consumedGrams,
      finished: data.finished.present ? data.finished.value : this.finished,
      note: data.note.present ? data.note.value : this.note,
      loggedAt: data.loggedAt.present ? data.loggedAt.value : this.loggedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UsageLog(')
          ..write('id: $id, ')
          ..write('printerId: $printerId, ')
          ..write('channelIndex: $channelIndex, ')
          ..write('consumableId: $consumableId, ')
          ..write('consumedGrams: $consumedGrams, ')
          ..write('finished: $finished, ')
          ..write('note: $note, ')
          ..write('loggedAt: $loggedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, printerId, channelIndex, consumableId,
      consumedGrams, finished, note, loggedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UsageLog &&
          other.id == this.id &&
          other.printerId == this.printerId &&
          other.channelIndex == this.channelIndex &&
          other.consumableId == this.consumableId &&
          other.consumedGrams == this.consumedGrams &&
          other.finished == this.finished &&
          other.note == this.note &&
          other.loggedAt == this.loggedAt);
}

class UsageLogsCompanion extends UpdateCompanion<UsageLog> {
  final Value<int> id;
  final Value<int?> printerId;
  final Value<int> channelIndex;
  final Value<int?> consumableId;
  final Value<double> consumedGrams;
  final Value<bool> finished;
  final Value<String?> note;
  final Value<DateTime> loggedAt;
  const UsageLogsCompanion({
    this.id = const Value.absent(),
    this.printerId = const Value.absent(),
    this.channelIndex = const Value.absent(),
    this.consumableId = const Value.absent(),
    this.consumedGrams = const Value.absent(),
    this.finished = const Value.absent(),
    this.note = const Value.absent(),
    this.loggedAt = const Value.absent(),
  });
  UsageLogsCompanion.insert({
    this.id = const Value.absent(),
    this.printerId = const Value.absent(),
    this.channelIndex = const Value.absent(),
    this.consumableId = const Value.absent(),
    this.consumedGrams = const Value.absent(),
    this.finished = const Value.absent(),
    this.note = const Value.absent(),
    this.loggedAt = const Value.absent(),
  });
  static Insertable<UsageLog> custom({
    Expression<int>? id,
    Expression<int>? printerId,
    Expression<int>? channelIndex,
    Expression<int>? consumableId,
    Expression<double>? consumedGrams,
    Expression<bool>? finished,
    Expression<String>? note,
    Expression<DateTime>? loggedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (printerId != null) 'printer_id': printerId,
      if (channelIndex != null) 'channel_index': channelIndex,
      if (consumableId != null) 'consumable_id': consumableId,
      if (consumedGrams != null) 'consumed_grams': consumedGrams,
      if (finished != null) 'finished': finished,
      if (note != null) 'note': note,
      if (loggedAt != null) 'logged_at': loggedAt,
    });
  }

  UsageLogsCompanion copyWith(
      {Value<int>? id,
      Value<int?>? printerId,
      Value<int>? channelIndex,
      Value<int?>? consumableId,
      Value<double>? consumedGrams,
      Value<bool>? finished,
      Value<String?>? note,
      Value<DateTime>? loggedAt}) {
    return UsageLogsCompanion(
      id: id ?? this.id,
      printerId: printerId ?? this.printerId,
      channelIndex: channelIndex ?? this.channelIndex,
      consumableId: consumableId ?? this.consumableId,
      consumedGrams: consumedGrams ?? this.consumedGrams,
      finished: finished ?? this.finished,
      note: note ?? this.note,
      loggedAt: loggedAt ?? this.loggedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (printerId.present) {
      map['printer_id'] = Variable<int>(printerId.value);
    }
    if (channelIndex.present) {
      map['channel_index'] = Variable<int>(channelIndex.value);
    }
    if (consumableId.present) {
      map['consumable_id'] = Variable<int>(consumableId.value);
    }
    if (consumedGrams.present) {
      map['consumed_grams'] = Variable<double>(consumedGrams.value);
    }
    if (finished.present) {
      map['finished'] = Variable<bool>(finished.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (loggedAt.present) {
      map['logged_at'] = Variable<DateTime>(loggedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UsageLogsCompanion(')
          ..write('id: $id, ')
          ..write('printerId: $printerId, ')
          ..write('channelIndex: $channelIndex, ')
          ..write('consumableId: $consumableId, ')
          ..write('consumedGrams: $consumedGrams, ')
          ..write('finished: $finished, ')
          ..write('note: $note, ')
          ..write('loggedAt: $loggedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ConsumablesTable consumables = $ConsumablesTable(this);
  late final $PrintersTable printers = $PrintersTable(this);
  late final $PrinterChannelsTable printerChannels =
      $PrinterChannelsTable(this);
  late final $UsageLogsTable usageLogs = $UsageLogsTable(this);
  late final ConsumableDao consumableDao = ConsumableDao(this as AppDatabase);
  late final PrinterDao printerDao = PrinterDao(this as AppDatabase);
  late final UsageLogDao usageLogDao = UsageLogDao(this as AppDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [consumables, printers, printerChannels, usageLogs];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules(
        [
          WritePropagation(
            on: TableUpdateQuery.onTableName('printers',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('printer_channels', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('consumables',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('printer_channels', kind: UpdateKind.update),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('printers',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('usage_logs', kind: UpdateKind.update),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('consumables',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('usage_logs', kind: UpdateKind.update),
            ],
          ),
        ],
      );
}

typedef $$ConsumablesTableCreateCompanionBuilder = ConsumablesCompanion
    Function({
  Value<int> id,
  Value<String> uid,
  required String manufacturer,
  required String model,
  Value<String> materialType,
  Value<String> colorHex,
  Value<String?> colorName,
  Value<double> totalGrams,
  Value<double> remainingGrams,
  Value<String?> batchNo,
  Value<DateTime?> purchaseDate,
  Value<String?> note,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<double?> density,
  Value<double?> recommendedNozzleTemp,
  Value<String?> hygroscopicity,
  Value<String?> trayUuid,
  Value<int?> rfidSyncedAt,
});
typedef $$ConsumablesTableUpdateCompanionBuilder = ConsumablesCompanion
    Function({
  Value<int> id,
  Value<String> uid,
  Value<String> manufacturer,
  Value<String> model,
  Value<String> materialType,
  Value<String> colorHex,
  Value<String?> colorName,
  Value<double> totalGrams,
  Value<double> remainingGrams,
  Value<String?> batchNo,
  Value<DateTime?> purchaseDate,
  Value<String?> note,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<double?> density,
  Value<double?> recommendedNozzleTemp,
  Value<String?> hygroscopicity,
  Value<String?> trayUuid,
  Value<int?> rfidSyncedAt,
});

final class $$ConsumablesTableReferences
    extends BaseReferences<_$AppDatabase, $ConsumablesTable, Consumable> {
  $$ConsumablesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$PrinterChannelsTable, List<PrinterChannel>>
      _printerChannelsRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.printerChannels,
              aliasName: 'consumables__id__printer_channels__consumable_id');

  $$PrinterChannelsTableProcessedTableManager get printerChannelsRefs {
    final manager = $$PrinterChannelsTableTableManager(
            $_db, $_db.printerChannels)
        .filter((f) => f.consumableId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_printerChannelsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$UsageLogsTable, List<UsageLog>>
      _usageLogsRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.usageLogs,
              aliasName: 'consumables__id__usage_logs__consumable_id');

  $$UsageLogsTableProcessedTableManager get usageLogsRefs {
    final manager = $$UsageLogsTableTableManager($_db, $_db.usageLogs)
        .filter((f) => f.consumableId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_usageLogsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$ConsumablesTableFilterComposer
    extends Composer<_$AppDatabase, $ConsumablesTable> {
  $$ConsumablesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uid => $composableBuilder(
      column: $table.uid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get manufacturer => $composableBuilder(
      column: $table.manufacturer, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get model => $composableBuilder(
      column: $table.model, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get materialType => $composableBuilder(
      column: $table.materialType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get colorHex => $composableBuilder(
      column: $table.colorHex, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get colorName => $composableBuilder(
      column: $table.colorName, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get totalGrams => $composableBuilder(
      column: $table.totalGrams, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get remainingGrams => $composableBuilder(
      column: $table.remainingGrams,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get batchNo => $composableBuilder(
      column: $table.batchNo, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get purchaseDate => $composableBuilder(
      column: $table.purchaseDate, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get density => $composableBuilder(
      column: $table.density, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get recommendedNozzleTemp => $composableBuilder(
      column: $table.recommendedNozzleTemp,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get hygroscopicity => $composableBuilder(
      column: $table.hygroscopicity,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get trayUuid => $composableBuilder(
      column: $table.trayUuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get rfidSyncedAt => $composableBuilder(
      column: $table.rfidSyncedAt, builder: (column) => ColumnFilters(column));

  Expression<bool> printerChannelsRefs(
      Expression<bool> Function($$PrinterChannelsTableFilterComposer f) f) {
    final $$PrinterChannelsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.printerChannels,
        getReferencedColumn: (t) => t.consumableId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PrinterChannelsTableFilterComposer(
              $db: $db,
              $table: $db.printerChannels,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> usageLogsRefs(
      Expression<bool> Function($$UsageLogsTableFilterComposer f) f) {
    final $$UsageLogsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.usageLogs,
        getReferencedColumn: (t) => t.consumableId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$UsageLogsTableFilterComposer(
              $db: $db,
              $table: $db.usageLogs,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$ConsumablesTableOrderingComposer
    extends Composer<_$AppDatabase, $ConsumablesTable> {
  $$ConsumablesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uid => $composableBuilder(
      column: $table.uid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get manufacturer => $composableBuilder(
      column: $table.manufacturer,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get model => $composableBuilder(
      column: $table.model, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get materialType => $composableBuilder(
      column: $table.materialType,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get colorHex => $composableBuilder(
      column: $table.colorHex, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get colorName => $composableBuilder(
      column: $table.colorName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get totalGrams => $composableBuilder(
      column: $table.totalGrams, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get remainingGrams => $composableBuilder(
      column: $table.remainingGrams,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get batchNo => $composableBuilder(
      column: $table.batchNo, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get purchaseDate => $composableBuilder(
      column: $table.purchaseDate,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get density => $composableBuilder(
      column: $table.density, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get recommendedNozzleTemp => $composableBuilder(
      column: $table.recommendedNozzleTemp,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get hygroscopicity => $composableBuilder(
      column: $table.hygroscopicity,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get trayUuid => $composableBuilder(
      column: $table.trayUuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get rfidSyncedAt => $composableBuilder(
      column: $table.rfidSyncedAt,
      builder: (column) => ColumnOrderings(column));
}

class $$ConsumablesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConsumablesTable> {
  $$ConsumablesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get manufacturer => $composableBuilder(
      column: $table.manufacturer, builder: (column) => column);

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<String> get materialType => $composableBuilder(
      column: $table.materialType, builder: (column) => column);

  GeneratedColumn<String> get colorHex =>
      $composableBuilder(column: $table.colorHex, builder: (column) => column);

  GeneratedColumn<String> get colorName =>
      $composableBuilder(column: $table.colorName, builder: (column) => column);

  GeneratedColumn<double> get totalGrams => $composableBuilder(
      column: $table.totalGrams, builder: (column) => column);

  GeneratedColumn<double> get remainingGrams => $composableBuilder(
      column: $table.remainingGrams, builder: (column) => column);

  GeneratedColumn<String> get batchNo =>
      $composableBuilder(column: $table.batchNo, builder: (column) => column);

  GeneratedColumn<DateTime> get purchaseDate => $composableBuilder(
      column: $table.purchaseDate, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<double> get density =>
      $composableBuilder(column: $table.density, builder: (column) => column);

  GeneratedColumn<double> get recommendedNozzleTemp => $composableBuilder(
      column: $table.recommendedNozzleTemp, builder: (column) => column);

  GeneratedColumn<String> get hygroscopicity => $composableBuilder(
      column: $table.hygroscopicity, builder: (column) => column);

  GeneratedColumn<String> get trayUuid =>
      $composableBuilder(column: $table.trayUuid, builder: (column) => column);

  GeneratedColumn<int> get rfidSyncedAt => $composableBuilder(
      column: $table.rfidSyncedAt, builder: (column) => column);

  Expression<T> printerChannelsRefs<T extends Object>(
      Expression<T> Function($$PrinterChannelsTableAnnotationComposer a) f) {
    final $$PrinterChannelsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.printerChannels,
        getReferencedColumn: (t) => t.consumableId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PrinterChannelsTableAnnotationComposer(
              $db: $db,
              $table: $db.printerChannels,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> usageLogsRefs<T extends Object>(
      Expression<T> Function($$UsageLogsTableAnnotationComposer a) f) {
    final $$UsageLogsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.usageLogs,
        getReferencedColumn: (t) => t.consumableId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$UsageLogsTableAnnotationComposer(
              $db: $db,
              $table: $db.usageLogs,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$ConsumablesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ConsumablesTable,
    Consumable,
    $$ConsumablesTableFilterComposer,
    $$ConsumablesTableOrderingComposer,
    $$ConsumablesTableAnnotationComposer,
    $$ConsumablesTableCreateCompanionBuilder,
    $$ConsumablesTableUpdateCompanionBuilder,
    (Consumable, $$ConsumablesTableReferences),
    Consumable,
    PrefetchHooks Function({bool printerChannelsRefs, bool usageLogsRefs})> {
  $$ConsumablesTableTableManager(_$AppDatabase db, $ConsumablesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConsumablesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConsumablesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConsumablesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uid = const Value.absent(),
            Value<String> manufacturer = const Value.absent(),
            Value<String> model = const Value.absent(),
            Value<String> materialType = const Value.absent(),
            Value<String> colorHex = const Value.absent(),
            Value<String?> colorName = const Value.absent(),
            Value<double> totalGrams = const Value.absent(),
            Value<double> remainingGrams = const Value.absent(),
            Value<String?> batchNo = const Value.absent(),
            Value<DateTime?> purchaseDate = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<double?> density = const Value.absent(),
            Value<double?> recommendedNozzleTemp = const Value.absent(),
            Value<String?> hygroscopicity = const Value.absent(),
            Value<String?> trayUuid = const Value.absent(),
            Value<int?> rfidSyncedAt = const Value.absent(),
          }) =>
              ConsumablesCompanion(
            id: id,
            uid: uid,
            manufacturer: manufacturer,
            model: model,
            materialType: materialType,
            colorHex: colorHex,
            colorName: colorName,
            totalGrams: totalGrams,
            remainingGrams: remainingGrams,
            batchNo: batchNo,
            purchaseDate: purchaseDate,
            note: note,
            createdAt: createdAt,
            updatedAt: updatedAt,
            density: density,
            recommendedNozzleTemp: recommendedNozzleTemp,
            hygroscopicity: hygroscopicity,
            trayUuid: trayUuid,
            rfidSyncedAt: rfidSyncedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uid = const Value.absent(),
            required String manufacturer,
            required String model,
            Value<String> materialType = const Value.absent(),
            Value<String> colorHex = const Value.absent(),
            Value<String?> colorName = const Value.absent(),
            Value<double> totalGrams = const Value.absent(),
            Value<double> remainingGrams = const Value.absent(),
            Value<String?> batchNo = const Value.absent(),
            Value<DateTime?> purchaseDate = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<double?> density = const Value.absent(),
            Value<double?> recommendedNozzleTemp = const Value.absent(),
            Value<String?> hygroscopicity = const Value.absent(),
            Value<String?> trayUuid = const Value.absent(),
            Value<int?> rfidSyncedAt = const Value.absent(),
          }) =>
              ConsumablesCompanion.insert(
            id: id,
            uid: uid,
            manufacturer: manufacturer,
            model: model,
            materialType: materialType,
            colorHex: colorHex,
            colorName: colorName,
            totalGrams: totalGrams,
            remainingGrams: remainingGrams,
            batchNo: batchNo,
            purchaseDate: purchaseDate,
            note: note,
            createdAt: createdAt,
            updatedAt: updatedAt,
            density: density,
            recommendedNozzleTemp: recommendedNozzleTemp,
            hygroscopicity: hygroscopicity,
            trayUuid: trayUuid,
            rfidSyncedAt: rfidSyncedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$ConsumablesTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {printerChannelsRefs = false, usageLogsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (printerChannelsRefs) db.printerChannels,
                if (usageLogsRefs) db.usageLogs
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (printerChannelsRefs)
                    await $_getPrefetchedData<Consumable, $ConsumablesTable,
                            PrinterChannel>(
                        currentTable: table,
                        referencedTable: $$ConsumablesTableReferences
                            ._printerChannelsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ConsumablesTableReferences(db, table, p0)
                                .printerChannelsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.consumableId == item.id),
                        typedResults: items),
                  if (usageLogsRefs)
                    await $_getPrefetchedData<Consumable, $ConsumablesTable,
                            UsageLog>(
                        currentTable: table,
                        referencedTable: $$ConsumablesTableReferences
                            ._usageLogsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ConsumablesTableReferences(db, table, p0)
                                .usageLogsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.consumableId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$ConsumablesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $ConsumablesTable,
    Consumable,
    $$ConsumablesTableFilterComposer,
    $$ConsumablesTableOrderingComposer,
    $$ConsumablesTableAnnotationComposer,
    $$ConsumablesTableCreateCompanionBuilder,
    $$ConsumablesTableUpdateCompanionBuilder,
    (Consumable, $$ConsumablesTableReferences),
    Consumable,
    PrefetchHooks Function({bool printerChannelsRefs, bool usageLogsRefs})>;
typedef $$PrintersTableCreateCompanionBuilder = PrintersCompanion Function({
  Value<int> id,
  Value<String> uid,
  Value<String?> name,
  required String brand,
  required String model,
  Value<int> channelCount,
  Value<String?> imageAsset,
  Value<bool> isCustomImage,
  Value<String?> note,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<String?> ownerAccount,
});
typedef $$PrintersTableUpdateCompanionBuilder = PrintersCompanion Function({
  Value<int> id,
  Value<String> uid,
  Value<String?> name,
  Value<String> brand,
  Value<String> model,
  Value<int> channelCount,
  Value<String?> imageAsset,
  Value<bool> isCustomImage,
  Value<String?> note,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<String?> ownerAccount,
});

final class $$PrintersTableReferences
    extends BaseReferences<_$AppDatabase, $PrintersTable, Printer> {
  $$PrintersTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$PrinterChannelsTable, List<PrinterChannel>>
      _printerChannelsRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.printerChannels,
              aliasName: 'printers__id__printer_channels__printer_id');

  $$PrinterChannelsTableProcessedTableManager get printerChannelsRefs {
    final manager =
        $$PrinterChannelsTableTableManager($_db, $_db.printerChannels)
            .filter((f) => f.printerId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_printerChannelsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$UsageLogsTable, List<UsageLog>>
      _usageLogsRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.usageLogs,
              aliasName: 'printers__id__usage_logs__printer_id');

  $$UsageLogsTableProcessedTableManager get usageLogsRefs {
    final manager = $$UsageLogsTableTableManager($_db, $_db.usageLogs)
        .filter((f) => f.printerId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_usageLogsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$PrintersTableFilterComposer
    extends Composer<_$AppDatabase, $PrintersTable> {
  $$PrintersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uid => $composableBuilder(
      column: $table.uid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get brand => $composableBuilder(
      column: $table.brand, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get model => $composableBuilder(
      column: $table.model, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get channelCount => $composableBuilder(
      column: $table.channelCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get imageAsset => $composableBuilder(
      column: $table.imageAsset, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isCustomImage => $composableBuilder(
      column: $table.isCustomImage, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get ownerAccount => $composableBuilder(
      column: $table.ownerAccount, builder: (column) => ColumnFilters(column));

  Expression<bool> printerChannelsRefs(
      Expression<bool> Function($$PrinterChannelsTableFilterComposer f) f) {
    final $$PrinterChannelsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.printerChannels,
        getReferencedColumn: (t) => t.printerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PrinterChannelsTableFilterComposer(
              $db: $db,
              $table: $db.printerChannels,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> usageLogsRefs(
      Expression<bool> Function($$UsageLogsTableFilterComposer f) f) {
    final $$UsageLogsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.usageLogs,
        getReferencedColumn: (t) => t.printerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$UsageLogsTableFilterComposer(
              $db: $db,
              $table: $db.usageLogs,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$PrintersTableOrderingComposer
    extends Composer<_$AppDatabase, $PrintersTable> {
  $$PrintersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uid => $composableBuilder(
      column: $table.uid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get brand => $composableBuilder(
      column: $table.brand, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get model => $composableBuilder(
      column: $table.model, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get channelCount => $composableBuilder(
      column: $table.channelCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get imageAsset => $composableBuilder(
      column: $table.imageAsset, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isCustomImage => $composableBuilder(
      column: $table.isCustomImage,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get ownerAccount => $composableBuilder(
      column: $table.ownerAccount,
      builder: (column) => ColumnOrderings(column));
}

class $$PrintersTableAnnotationComposer
    extends Composer<_$AppDatabase, $PrintersTable> {
  $$PrintersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get brand =>
      $composableBuilder(column: $table.brand, builder: (column) => column);

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<int> get channelCount => $composableBuilder(
      column: $table.channelCount, builder: (column) => column);

  GeneratedColumn<String> get imageAsset => $composableBuilder(
      column: $table.imageAsset, builder: (column) => column);

  GeneratedColumn<bool> get isCustomImage => $composableBuilder(
      column: $table.isCustomImage, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get ownerAccount => $composableBuilder(
      column: $table.ownerAccount, builder: (column) => column);

  Expression<T> printerChannelsRefs<T extends Object>(
      Expression<T> Function($$PrinterChannelsTableAnnotationComposer a) f) {
    final $$PrinterChannelsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.printerChannels,
        getReferencedColumn: (t) => t.printerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PrinterChannelsTableAnnotationComposer(
              $db: $db,
              $table: $db.printerChannels,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> usageLogsRefs<T extends Object>(
      Expression<T> Function($$UsageLogsTableAnnotationComposer a) f) {
    final $$UsageLogsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.usageLogs,
        getReferencedColumn: (t) => t.printerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$UsageLogsTableAnnotationComposer(
              $db: $db,
              $table: $db.usageLogs,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$PrintersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PrintersTable,
    Printer,
    $$PrintersTableFilterComposer,
    $$PrintersTableOrderingComposer,
    $$PrintersTableAnnotationComposer,
    $$PrintersTableCreateCompanionBuilder,
    $$PrintersTableUpdateCompanionBuilder,
    (Printer, $$PrintersTableReferences),
    Printer,
    PrefetchHooks Function({bool printerChannelsRefs, bool usageLogsRefs})> {
  $$PrintersTableTableManager(_$AppDatabase db, $PrintersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PrintersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PrintersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PrintersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uid = const Value.absent(),
            Value<String?> name = const Value.absent(),
            Value<String> brand = const Value.absent(),
            Value<String> model = const Value.absent(),
            Value<int> channelCount = const Value.absent(),
            Value<String?> imageAsset = const Value.absent(),
            Value<bool> isCustomImage = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<String?> ownerAccount = const Value.absent(),
          }) =>
              PrintersCompanion(
            id: id,
            uid: uid,
            name: name,
            brand: brand,
            model: model,
            channelCount: channelCount,
            imageAsset: imageAsset,
            isCustomImage: isCustomImage,
            note: note,
            createdAt: createdAt,
            updatedAt: updatedAt,
            ownerAccount: ownerAccount,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uid = const Value.absent(),
            Value<String?> name = const Value.absent(),
            required String brand,
            required String model,
            Value<int> channelCount = const Value.absent(),
            Value<String?> imageAsset = const Value.absent(),
            Value<bool> isCustomImage = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<String?> ownerAccount = const Value.absent(),
          }) =>
              PrintersCompanion.insert(
            id: id,
            uid: uid,
            name: name,
            brand: brand,
            model: model,
            channelCount: channelCount,
            imageAsset: imageAsset,
            isCustomImage: isCustomImage,
            note: note,
            createdAt: createdAt,
            updatedAt: updatedAt,
            ownerAccount: ownerAccount,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$PrintersTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: (
              {printerChannelsRefs = false, usageLogsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (printerChannelsRefs) db.printerChannels,
                if (usageLogsRefs) db.usageLogs
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (printerChannelsRefs)
                    await $_getPrefetchedData<Printer, $PrintersTable,
                            PrinterChannel>(
                        currentTable: table,
                        referencedTable: $$PrintersTableReferences
                            ._printerChannelsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$PrintersTableReferences(db, table, p0)
                                .printerChannelsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.printerId == item.id),
                        typedResults: items),
                  if (usageLogsRefs)
                    await $_getPrefetchedData<Printer, $PrintersTable,
                            UsageLog>(
                        currentTable: table,
                        referencedTable:
                            $$PrintersTableReferences._usageLogsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$PrintersTableReferences(db, table, p0)
                                .usageLogsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.printerId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$PrintersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PrintersTable,
    Printer,
    $$PrintersTableFilterComposer,
    $$PrintersTableOrderingComposer,
    $$PrintersTableAnnotationComposer,
    $$PrintersTableCreateCompanionBuilder,
    $$PrintersTableUpdateCompanionBuilder,
    (Printer, $$PrintersTableReferences),
    Printer,
    PrefetchHooks Function({bool printerChannelsRefs, bool usageLogsRefs})>;
typedef $$PrinterChannelsTableCreateCompanionBuilder = PrinterChannelsCompanion
    Function({
  Value<int> id,
  required int printerId,
  required int channelIndex,
  Value<String> label,
  Value<int?> consumableId,
  Value<double> loadedRemainingGrams,
  Value<DateTime> updatedAt,
});
typedef $$PrinterChannelsTableUpdateCompanionBuilder = PrinterChannelsCompanion
    Function({
  Value<int> id,
  Value<int> printerId,
  Value<int> channelIndex,
  Value<String> label,
  Value<int?> consumableId,
  Value<double> loadedRemainingGrams,
  Value<DateTime> updatedAt,
});

final class $$PrinterChannelsTableReferences extends BaseReferences<
    _$AppDatabase, $PrinterChannelsTable, PrinterChannel> {
  $$PrinterChannelsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $PrintersTable _printerIdTable(_$AppDatabase db) =>
      db.printers.createAlias('printer_channels__printer_id__printers__id');

  $$PrintersTableProcessedTableManager get printerId {
    final $_column = $_itemColumn<int>('printer_id')!;

    final manager = $$PrintersTableTableManager($_db, $_db.printers)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_printerIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $ConsumablesTable _consumableIdTable(_$AppDatabase db) =>
      db.consumables
          .createAlias('printer_channels__consumable_id__consumables__id');

  $$ConsumablesTableProcessedTableManager? get consumableId {
    final $_column = $_itemColumn<int>('consumable_id');
    if ($_column == null) return null;
    final manager = $$ConsumablesTableTableManager($_db, $_db.consumables)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_consumableIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$PrinterChannelsTableFilterComposer
    extends Composer<_$AppDatabase, $PrinterChannelsTable> {
  $$PrinterChannelsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get channelIndex => $composableBuilder(
      column: $table.channelIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get loadedRemainingGrams => $composableBuilder(
      column: $table.loadedRemainingGrams,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  $$PrintersTableFilterComposer get printerId {
    final $$PrintersTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.printerId,
        referencedTable: $db.printers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PrintersTableFilterComposer(
              $db: $db,
              $table: $db.printers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$ConsumablesTableFilterComposer get consumableId {
    final $$ConsumablesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.consumableId,
        referencedTable: $db.consumables,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConsumablesTableFilterComposer(
              $db: $db,
              $table: $db.consumables,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PrinterChannelsTableOrderingComposer
    extends Composer<_$AppDatabase, $PrinterChannelsTable> {
  $$PrinterChannelsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get channelIndex => $composableBuilder(
      column: $table.channelIndex,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get loadedRemainingGrams => $composableBuilder(
      column: $table.loadedRemainingGrams,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  $$PrintersTableOrderingComposer get printerId {
    final $$PrintersTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.printerId,
        referencedTable: $db.printers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PrintersTableOrderingComposer(
              $db: $db,
              $table: $db.printers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$ConsumablesTableOrderingComposer get consumableId {
    final $$ConsumablesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.consumableId,
        referencedTable: $db.consumables,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConsumablesTableOrderingComposer(
              $db: $db,
              $table: $db.consumables,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PrinterChannelsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PrinterChannelsTable> {
  $$PrinterChannelsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get channelIndex => $composableBuilder(
      column: $table.channelIndex, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<double> get loadedRemainingGrams => $composableBuilder(
      column: $table.loadedRemainingGrams, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$PrintersTableAnnotationComposer get printerId {
    final $$PrintersTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.printerId,
        referencedTable: $db.printers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PrintersTableAnnotationComposer(
              $db: $db,
              $table: $db.printers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$ConsumablesTableAnnotationComposer get consumableId {
    final $$ConsumablesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.consumableId,
        referencedTable: $db.consumables,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConsumablesTableAnnotationComposer(
              $db: $db,
              $table: $db.consumables,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PrinterChannelsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PrinterChannelsTable,
    PrinterChannel,
    $$PrinterChannelsTableFilterComposer,
    $$PrinterChannelsTableOrderingComposer,
    $$PrinterChannelsTableAnnotationComposer,
    $$PrinterChannelsTableCreateCompanionBuilder,
    $$PrinterChannelsTableUpdateCompanionBuilder,
    (PrinterChannel, $$PrinterChannelsTableReferences),
    PrinterChannel,
    PrefetchHooks Function({bool printerId, bool consumableId})> {
  $$PrinterChannelsTableTableManager(
      _$AppDatabase db, $PrinterChannelsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PrinterChannelsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PrinterChannelsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PrinterChannelsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> printerId = const Value.absent(),
            Value<int> channelIndex = const Value.absent(),
            Value<String> label = const Value.absent(),
            Value<int?> consumableId = const Value.absent(),
            Value<double> loadedRemainingGrams = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              PrinterChannelsCompanion(
            id: id,
            printerId: printerId,
            channelIndex: channelIndex,
            label: label,
            consumableId: consumableId,
            loadedRemainingGrams: loadedRemainingGrams,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int printerId,
            required int channelIndex,
            Value<String> label = const Value.absent(),
            Value<int?> consumableId = const Value.absent(),
            Value<double> loadedRemainingGrams = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              PrinterChannelsCompanion.insert(
            id: id,
            printerId: printerId,
            channelIndex: channelIndex,
            label: label,
            consumableId: consumableId,
            loadedRemainingGrams: loadedRemainingGrams,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$PrinterChannelsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({printerId = false, consumableId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (printerId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.printerId,
                    referencedTable:
                        $$PrinterChannelsTableReferences._printerIdTable(db),
                    referencedColumn:
                        $$PrinterChannelsTableReferences._printerIdTable(db).id,
                  ) as T;
                }
                if (consumableId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.consumableId,
                    referencedTable:
                        $$PrinterChannelsTableReferences._consumableIdTable(db),
                    referencedColumn: $$PrinterChannelsTableReferences
                        ._consumableIdTable(db)
                        .id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$PrinterChannelsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PrinterChannelsTable,
    PrinterChannel,
    $$PrinterChannelsTableFilterComposer,
    $$PrinterChannelsTableOrderingComposer,
    $$PrinterChannelsTableAnnotationComposer,
    $$PrinterChannelsTableCreateCompanionBuilder,
    $$PrinterChannelsTableUpdateCompanionBuilder,
    (PrinterChannel, $$PrinterChannelsTableReferences),
    PrinterChannel,
    PrefetchHooks Function({bool printerId, bool consumableId})>;
typedef $$UsageLogsTableCreateCompanionBuilder = UsageLogsCompanion Function({
  Value<int> id,
  Value<int?> printerId,
  Value<int> channelIndex,
  Value<int?> consumableId,
  Value<double> consumedGrams,
  Value<bool> finished,
  Value<String?> note,
  Value<DateTime> loggedAt,
});
typedef $$UsageLogsTableUpdateCompanionBuilder = UsageLogsCompanion Function({
  Value<int> id,
  Value<int?> printerId,
  Value<int> channelIndex,
  Value<int?> consumableId,
  Value<double> consumedGrams,
  Value<bool> finished,
  Value<String?> note,
  Value<DateTime> loggedAt,
});

final class $$UsageLogsTableReferences
    extends BaseReferences<_$AppDatabase, $UsageLogsTable, UsageLog> {
  $$UsageLogsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $PrintersTable _printerIdTable(_$AppDatabase db) =>
      db.printers.createAlias('usage_logs__printer_id__printers__id');

  $$PrintersTableProcessedTableManager? get printerId {
    final $_column = $_itemColumn<int>('printer_id');
    if ($_column == null) return null;
    final manager = $$PrintersTableTableManager($_db, $_db.printers)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_printerIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $ConsumablesTable _consumableIdTable(_$AppDatabase db) =>
      db.consumables.createAlias('usage_logs__consumable_id__consumables__id');

  $$ConsumablesTableProcessedTableManager? get consumableId {
    final $_column = $_itemColumn<int>('consumable_id');
    if ($_column == null) return null;
    final manager = $$ConsumablesTableTableManager($_db, $_db.consumables)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_consumableIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$UsageLogsTableFilterComposer
    extends Composer<_$AppDatabase, $UsageLogsTable> {
  $$UsageLogsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get channelIndex => $composableBuilder(
      column: $table.channelIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get consumedGrams => $composableBuilder(
      column: $table.consumedGrams, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get finished => $composableBuilder(
      column: $table.finished, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get loggedAt => $composableBuilder(
      column: $table.loggedAt, builder: (column) => ColumnFilters(column));

  $$PrintersTableFilterComposer get printerId {
    final $$PrintersTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.printerId,
        referencedTable: $db.printers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PrintersTableFilterComposer(
              $db: $db,
              $table: $db.printers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$ConsumablesTableFilterComposer get consumableId {
    final $$ConsumablesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.consumableId,
        referencedTable: $db.consumables,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConsumablesTableFilterComposer(
              $db: $db,
              $table: $db.consumables,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$UsageLogsTableOrderingComposer
    extends Composer<_$AppDatabase, $UsageLogsTable> {
  $$UsageLogsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get channelIndex => $composableBuilder(
      column: $table.channelIndex,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get consumedGrams => $composableBuilder(
      column: $table.consumedGrams,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get finished => $composableBuilder(
      column: $table.finished, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get loggedAt => $composableBuilder(
      column: $table.loggedAt, builder: (column) => ColumnOrderings(column));

  $$PrintersTableOrderingComposer get printerId {
    final $$PrintersTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.printerId,
        referencedTable: $db.printers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PrintersTableOrderingComposer(
              $db: $db,
              $table: $db.printers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$ConsumablesTableOrderingComposer get consumableId {
    final $$ConsumablesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.consumableId,
        referencedTable: $db.consumables,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConsumablesTableOrderingComposer(
              $db: $db,
              $table: $db.consumables,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$UsageLogsTableAnnotationComposer
    extends Composer<_$AppDatabase, $UsageLogsTable> {
  $$UsageLogsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get channelIndex => $composableBuilder(
      column: $table.channelIndex, builder: (column) => column);

  GeneratedColumn<double> get consumedGrams => $composableBuilder(
      column: $table.consumedGrams, builder: (column) => column);

  GeneratedColumn<bool> get finished =>
      $composableBuilder(column: $table.finished, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<DateTime> get loggedAt =>
      $composableBuilder(column: $table.loggedAt, builder: (column) => column);

  $$PrintersTableAnnotationComposer get printerId {
    final $$PrintersTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.printerId,
        referencedTable: $db.printers,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PrintersTableAnnotationComposer(
              $db: $db,
              $table: $db.printers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$ConsumablesTableAnnotationComposer get consumableId {
    final $$ConsumablesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.consumableId,
        referencedTable: $db.consumables,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConsumablesTableAnnotationComposer(
              $db: $db,
              $table: $db.consumables,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$UsageLogsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $UsageLogsTable,
    UsageLog,
    $$UsageLogsTableFilterComposer,
    $$UsageLogsTableOrderingComposer,
    $$UsageLogsTableAnnotationComposer,
    $$UsageLogsTableCreateCompanionBuilder,
    $$UsageLogsTableUpdateCompanionBuilder,
    (UsageLog, $$UsageLogsTableReferences),
    UsageLog,
    PrefetchHooks Function({bool printerId, bool consumableId})> {
  $$UsageLogsTableTableManager(_$AppDatabase db, $UsageLogsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UsageLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UsageLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UsageLogsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int?> printerId = const Value.absent(),
            Value<int> channelIndex = const Value.absent(),
            Value<int?> consumableId = const Value.absent(),
            Value<double> consumedGrams = const Value.absent(),
            Value<bool> finished = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<DateTime> loggedAt = const Value.absent(),
          }) =>
              UsageLogsCompanion(
            id: id,
            printerId: printerId,
            channelIndex: channelIndex,
            consumableId: consumableId,
            consumedGrams: consumedGrams,
            finished: finished,
            note: note,
            loggedAt: loggedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int?> printerId = const Value.absent(),
            Value<int> channelIndex = const Value.absent(),
            Value<int?> consumableId = const Value.absent(),
            Value<double> consumedGrams = const Value.absent(),
            Value<bool> finished = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<DateTime> loggedAt = const Value.absent(),
          }) =>
              UsageLogsCompanion.insert(
            id: id,
            printerId: printerId,
            channelIndex: channelIndex,
            consumableId: consumableId,
            consumedGrams: consumedGrams,
            finished: finished,
            note: note,
            loggedAt: loggedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$UsageLogsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({printerId = false, consumableId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (printerId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.printerId,
                    referencedTable:
                        $$UsageLogsTableReferences._printerIdTable(db),
                    referencedColumn:
                        $$UsageLogsTableReferences._printerIdTable(db).id,
                  ) as T;
                }
                if (consumableId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.consumableId,
                    referencedTable:
                        $$UsageLogsTableReferences._consumableIdTable(db),
                    referencedColumn:
                        $$UsageLogsTableReferences._consumableIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$UsageLogsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $UsageLogsTable,
    UsageLog,
    $$UsageLogsTableFilterComposer,
    $$UsageLogsTableOrderingComposer,
    $$UsageLogsTableAnnotationComposer,
    $$UsageLogsTableCreateCompanionBuilder,
    $$UsageLogsTableUpdateCompanionBuilder,
    (UsageLog, $$UsageLogsTableReferences),
    UsageLog,
    PrefetchHooks Function({bool printerId, bool consumableId})>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ConsumablesTableTableManager get consumables =>
      $$ConsumablesTableTableManager(_db, _db.consumables);
  $$PrintersTableTableManager get printers =>
      $$PrintersTableTableManager(_db, _db.printers);
  $$PrinterChannelsTableTableManager get printerChannels =>
      $$PrinterChannelsTableTableManager(_db, _db.printerChannels);
  $$UsageLogsTableTableManager get usageLogs =>
      $$UsageLogsTableTableManager(_db, _db.usageLogs);
}
