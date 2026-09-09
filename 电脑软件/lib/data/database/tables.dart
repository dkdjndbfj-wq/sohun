import 'package:drift/drift.dart';

/// 耗材库存表。每卷耗材一条记录。
class Consumables extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uid => text().withDefault(const Constant(''))();
  TextColumn get manufacturer => text().withLength(min: 1, max: 64)();
  TextColumn get model => text().withLength(min: 1, max: 64)();
  TextColumn get materialType => text().withDefault(const Constant('PLA'))();
  TextColumn get colorHex => text().withDefault(const Constant('#FFFFFF'))();
  TextColumn get colorName => text().nullable()();
  RealColumn get totalGrams => real().withDefault(const Constant(1000.0))();
  RealColumn get remainingGrams => real().withDefault(const Constant(1000.0))();
  TextColumn get batchNo => text().nullable()();
  DateTimeColumn get purchaseDate => dateTime().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  // v12：耗材物理参数，用于 RFID 自动填充 + 干燥提醒联动 + 成本精度。
  // density 默认 1.24（PLA 常见值），单位 g/cm³，影响切片重量估算精度。
  RealColumn get density => real().nullable()();
  // 推荐喷嘴温度（℃），从 RFID nozzle_temp_max 填充，用户可改。
  RealColumn get recommendedNozzleTemp => real().nullable()();
  // 吸湿性档位：'high' / 'medium' / 'low' / null。
  // drying_reminder_service 按此档位决定提醒周期，null 则按材质名推断。
  TextColumn get hygroscopicity => text().nullable()();

  // v14：数字孪生 - 拓竹 RFID 唯一标识，用于装机自动识别和跨任务追踪单卷耗材。
  // 第三方料无 UUID（空字符串）。
  TextColumn get trayUuid => text().nullable()();

  // v14：上次 RFID 残量同步时间戳（毫秒），用于判断同步新鲜度。
  IntColumn get rfidSyncedAt => integer().nullable()();

}

/// 打印机表。channelCount 决定多色系统的通道数（1=单色，4=一组多色系统）。
class Printers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uid => text().withDefault(const Constant(''))();
  TextColumn get name => text().nullable()();
  TextColumn get brand => text().withLength(min: 1, max: 64)();
  TextColumn get model => text().withLength(min: 1, max: 64)();
  IntColumn get channelCount => integer().withDefault(const Constant(1))();
  TextColumn get imageAsset => text().nullable()();
  BoolColumn get isCustomImage =>
      boolean().withDefault(const Constant(false))();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  /// 所属拓竹账号标识（email|region_code 格式，如 "user@example.com|China"）
  /// null 表示未关联账号（手动添加的本地打印机）
  /// 用于多账号场景下记录打印机归属
  TextColumn get ownerAccount => text().nullable()();
}

/// 打印机通道表。每通道绑定一卷当前正在消耗的耗材（多色系统的核心）。
class PrinterChannels extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get printerId =>
      integer().references(Printers, #id, onDelete: KeyAction.cascade)();
  IntColumn get channelIndex => integer()();
  TextColumn get label => text().withDefault(const Constant('A'))();
  IntColumn get consumableId => integer()
      .nullable()
      .references(Consumables, #id, onDelete: KeyAction.setNull)();
  RealColumn get loadedRemainingGrams =>
      real().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// 消耗记录表。每次「已用完」或部分消耗都记录一条，便于回溯统计。
/// 外键用 setNull：删除打印机/耗材时不丢历史记录，仅置空引用。
class UsageLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get printerId => integer()
      .nullable()
      .references(Printers, #id, onDelete: KeyAction.setNull)();
  IntColumn get channelIndex => integer().withDefault(const Constant(0))();
  IntColumn get consumableId => integer()
      .nullable()
      .references(Consumables, #id, onDelete: KeyAction.setNull)();
  RealColumn get consumedGrams => real().withDefault(const Constant(0.0))();
  BoolColumn get finished => boolean().withDefault(const Constant(true))();
  TextColumn get note => text().nullable()();
  DateTimeColumn get loggedAt => dateTime().withDefault(currentDateAndTime)();
}

// 打印任务表（print_tasks）的定义不在此文件中。
// 因 drift_dev 2.34 与 sqlparser 0.44 不兼容，该表不走 drift 代码生成，
// 改由 database.dart 的 _createPrintTasksTable 用 raw SQL 创建，
// 字段含义与 Dart 模型见 lib/data/database/models/print_task.dart。
