import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/app_variant.dart';
import '../../core/utils/sqlite_snapshot.dart';
import 'tables.dart';
import 'personal_inventory_event_schema.dart';
import 'personal_ams_identity.dart';
import 'personal_rfid_stock.dart';
import 'device_workbench_store.dart';
import 'daos/consumable_dao.dart';
import 'daos/printer_dao.dart';
import 'daos/usage_log_dao.dart';

// v12：导出 ConsumableDao + ConsumableParams，供 add_consumable_sheet 等使用
export 'daos/consumable_dao.dart'
    show
        ConsumableDao,
        ConsumableParams,
        ConsumableWithOwner,
        FarmConsumableMetadata,
        RfidSpoolBinding;
export 'personal_rfid_stock.dart'
    show PersonalRfidStockSource, PersonalStockReceipt;

part 'database.g.dart';

/// 应用本地数据库（drift / SQLite）。
/// 通过代码生成产生 database.g.dart，运行 `dart run build_runner build` 即可。
/// 注意：PrintTasks 表用 raw SQL 创建（不走 drift 代码生成），
/// 因为 drift_dev 2.34 与 sqlparser 0.44 不兼容，build_runner 无法运行。
/// PrintTasks 的 CRUD 通过 PrintTaskDao 的 customSelect/customStatement 实现。
@DriftDatabase(
  tables: [Consumables, Printers, PrinterChannels, UsageLogs],
  daos: [ConsumableDao, PrinterDao, UsageLogDao],
)
class AppDatabase extends _$AppDatabase {
  static const int kSchemaVersion = 56;

  AppDatabase() : _schemaVersion = kSchemaVersion, super(_open());

  AppDatabase.forTesting(super.e) : _schemaVersion = kSchemaVersion;

  /// Allows migration tests to materialize each historical schema version.
  /// Production construction always uses [kSchemaVersion].
  AppDatabase.forTestingAtVersion(super.e, this._schemaVersion)
    : assert(_schemaVersion >= 1 && _schemaVersion <= kSchemaVersion);

  final int _schemaVersion;

  @override
  int get schemaVersion => _schemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createPrintTasksTable(m);
      await _createFilamentCostConfigsTable(m);
      await _createPrintTaskConsumablesTable(m);
      await _createDataIntegrityIndexes(m);
      await _createAmsChangeEventsTable(m);
      await _createErrorLogsTable(m);
      await _prepareConsumableInventoryScope(m);
      // serial 列不在 drift 表定义中（build_runner 无法运行），
      // 用 raw SQL 补充，确保全新安装也有该列。
      await _addColumnIfMissing(m, 'printers', 'serial', 'TEXT');
      // v11：consumables 表新增 owner_account 列（多账号场景记录耗材归属）。
      // email|region_code 格式，null 表示未关联账号（手动添加或单账号场景）。
      // 用于多账号耗材隔离：库存列表支持按账号筛选，统计可按账号分组。
      await _addColumnIfMissing(m, 'consumables', 'owner_account', 'TEXT');
      // v12：consumables 表新增耗材物理参数列（密度/推荐温度/吸湿性档位）。
      // 用于 RFID 自动填充 + 干燥提醒联动。旧数据默认 null。
      await _addColumnIfMissing(m, 'consumables', 'density', 'REAL');
      await _addColumnIfMissing(
        m,
        'consumables',
        'recommended_nozzle_temp',
        'REAL',
      );
      await _addColumnIfMissing(m, 'consumables', 'hygroscopicity', 'TEXT');
      // v14：数字孪生 - 耗材加 tray_uuid（拓竹 RFID UUID）和 rfid_synced_at（同步时间戳）。
      // m.createAll() 基于生成的 $ConsumablesTable（build_runner 不可用，未含 v14 列），
      // 用 raw SQL 补列，与 v11/v12 模式一致。
      await _addColumnIfMissing(m, 'consumables', 'tray_uuid', 'TEXT');
      await _addColumnIfMissing(m, 'consumables', 'rfid_synced_at', 'INTEGER');
      // v13：print_tasks 加 batch_id（批次识别）；新建 print_queue 表；
      // printers 加 queue_enabled / batch_recognition 开关列。
      // 注意：batch_id 已在 _createPrintTasksTable 的 CREATE TABLE 中定义，
      // 此处不能再 ALTER（会抛 duplicate column name）。
      await _addColumnIfMissing(
        m,
        'printers',
        'queue_enabled',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _addColumnIfMissing(
        m,
        'printers',
        'batch_recognition',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _createPrintQueueTable(m);
      // v15：跨打印机智能调度任务表。
      await _createSchedulerTasksTable(m);
      // v18：参数效果闭环基础表。
      await _createPresetSnapshotsTable(m);
      await _createPresetApplicationsTable(m);
      await _createPresetSliceArtifactsTable(m);
      await _createPresetPrintResultsTable(m);
      await _createPresetTaskAttributionsTable(m);
      // v19：故障/数字孪生/调度/实验/可观测性表。
      await _createPrinterFaultEventsTable(m);
      await _createConsumableTwinEventsTable(m);
      await _createSchedulerTaskMaterialsTable(m);
      await _createSpoolReservationsTable(m);
      await _createParameterExperimentsTable(m);
      await _createTelemetryEventsTable(m);
      await _createLocalPresetTables(m);
      await _createStudioTables(m);
      await _createStudioQuoteConfigTables(m);
      await _createStudioActivityGuards(m);
      await _prepareFarmChannelRollState(m);
      await _prepareFarmDataIntegrityV41(m);
      await _prepareFarmInventoryV44(m, migrateExisting: true);
      // v47：手机 NFC 标签操作历史。标签 UID 不是唯一约束：CUID/FUID
      // 可以被复制，用户也可能重复写入同一张标签，因此每次操作都追加一条记录。
      await _createRfidTagRecordsTable(m);
      await _createPersonalInventoryTombstonesTable(m);
      if (_schemaVersion >= 50) {
        await _createPersonalInventoryEventsTable(m);
      }
      if (_schemaVersion >= 49) {
        await _prepareRfidSpoolLifecycle(m, migrateExisting: true);
      }
      if (_schemaVersion >= 51) {
        await preparePersonalInventoryEventOutbox(m);
      }
      if (_schemaVersion >= 52) {
        await _prepareTaskSpoolSegments(m);
      }
      if (_schemaVersion >= 53) {
        await preparePersonalAmsUidAliases(m);
      }
      if (_schemaVersion >= 54) {
        await _addColumnIfMissing(
          m,
          'consumables',
          'rfid_tag_history',
          "TEXT NOT NULL DEFAULT '[]'",
        );
      }
      await _ensureTrayUuidUniqueIndex(m);
      if (_schemaVersion >= 55) await prepareDeviceWorkbench(m);
      if (_schemaVersion >= 56) await preparePersonalRfidStock(m);
    },
    onUpgrade: (m, from, to) async {
      if (from < 2 && to >= 2) {
        if (!await _columnExists(m, 'printers', 'name')) {
          await m.addColumn(printers, printers.name);
        }
      }
      if (from < 3 && to >= 3) {
        // v3：新增 PrintTasks 表（raw SQL，不走 drift 代码生成）
        await _createPrintTasksTable(m);
      }
      if (from < 4 && to >= 4) {
        // v4：新增 FilamentCostConfigs 表（耗材成本配置：品牌+材质+颜色→每公斤单价）
        await _createFilamentCostConfigsTable(m);
      }
      if (from < 5 && to >= 5) {
        // v5：给 printers 表加 serial 列，用于同步云端设备到本地。
        // serial 列不进 drift 代码生成（build_runner 不可用），用 raw SQL 添加。
        await _addColumnIfMissing(m, 'printers', 'serial', 'TEXT');
      }
      if (from < 6 && to >= 6) {
        // v6：新增 print_task_consumables 表（打印任务↔耗材卷关联，
        // 支持实时扣减+完成修正+成本结算）。raw SQL 创建。
        await _createPrintTaskConsumablesTable(m);
      }
      if (from < 7 && to >= 7) {
        // v7：增加 consumed_at 列，记录消耗实际发生时间（实时扣减/结算时刻）。
        // 折线图和汇总用此字段而非 updated_at，确保跨天任务消耗按实际时间分布。
        //
        // 注意：v6 的 _createPrintTaskConsumablesTable 用最新版 SQL 创建表，
        // 已包含 consumed_at 列。从 v5 或更低版本一次性升到 v11 时，v6 创建的
        // 表已有该列，直接 ALTER 会因 "duplicate column name" 失败。
        // 用 PRAGMA table_info 检查列是否存在，存在则跳过 ALTER。
        final cols = await m.database
            .customSelect('PRAGMA table_info(print_task_consumables)')
            .get();
        final hasConsumedAt = cols.any(
          (row) => row.data['name'] == 'consumed_at',
        );
        if (!hasConsumedAt) {
          await m.database.customStatement(
            'ALTER TABLE print_task_consumables ADD COLUMN consumed_at INTEGER',
          );
        }
        // 旧数据迁移：用 updated_at 填充 consumed_at
        await m.database.customStatement(
          'UPDATE print_task_consumables SET consumed_at = updated_at WHERE consumed_at IS NULL',
        );
        await m.database.customStatement(
          'CREATE INDEX IF NOT EXISTS idx_ptc_consumed ON print_task_consumables(consumed_at);',
        );
      }
      if (from < 8 && to >= 8) {
        // v8：新增 ams_change_events 表（AMS 精确换料统计）。
        // 监听 MQTT trayNow 字段变化，记录每次实际换料事件，
        // 提升多色任务成本精度（替代按 mc_percent 比例估算的粗略模式）。
        await _createAmsChangeEventsTable(m);
      }
      if (from < 9 && to >= 9) {
        // v9：Printers 表新增 owner_account 列（多账号场景记录打印机归属）。
        // email|region_code 格式，null 表示未关联账号（手动添加的本地打印机）。
        // 多账号功能要求本地打印机记录跨账号共享，但仍需记录原始归属账号。
        // 部分旧构建已通过生成表结构提前创建该列，但 user_version 仍低于 9。
        // 迁移必须幂等，否则应用会在启动时因 duplicate column name 无法加载。
        if (!await _columnExists(m, 'printers', 'owner_account')) {
          await m.addColumn(printers, printers.ownerAccount);
        }
      }
      if (from < 10 && to >= 10) {
        // v10：新增 error_logs 表（全局错误收集，替代 catch (_) {} 静默吞异常）。
        // 所有未捕获异常、扣减失败、FTP 上传失败、MQTT 异常等均会写入此表，
        // 用户可在"诊断中心"查看近期错误并导出日志包。
        await _createErrorLogsTable(m);
      }
      if (from < 11 && to >= 11) {
        // v11：consumables 表新增 owner_account 列（多账号场景记录耗材归属）。
        // email|region_code 格式，null 表示未关联账号（手动添加或单账号场景）。
        // 用于多账号耗材隔离：库存列表支持按账号筛选，统计可按账号分组。
        // 旧数据 owner_account 默认为 null（未关联账号），保持向后兼容。
        await _addColumnIfMissing(m, 'consumables', 'owner_account', 'TEXT');
      }
      if (from < 12 && to >= 12) {
        // v12：consumables 表新增耗材物理参数列。
        // density(g/cm³) 影响切片重量估算；recommended_nozzle_temp(℃) 从 RFID 填充；
        // hygroscopicity(high/medium/low) 用于干燥提醒按卷差异化周期。
        await _addColumnIfMissing(m, 'consumables', 'density', 'REAL');
        await _addColumnIfMissing(
          m,
          'consumables',
          'recommended_nozzle_temp',
          'REAL',
        );
        await _addColumnIfMissing(m, 'consumables', 'hygroscopicity', 'TEXT');
      }
      if (from < 13 && to >= 13) {
        // v13：批次识别 + 打印队列。
        // print_tasks 加 batch_id（同文件名+10分钟窗口的多台任务归为同批次）。
        // printers 加 queue_enabled（打印队列开关）/ batch_recognition（批次识别开关）。
        // 新建 print_queue 表（队列任务列表）。
        //
        // 注意：从 v2 及以下跨版本升级时，_createPrintTasksTable 已创建
        // 含 batch_id 的表，直接 ALTER 会抛 duplicate column name。
        // 用 PRAGMA table_info 检查列是否存在，与 v7 consumed_at 迁移模式一致。
        await _addColumnIfMissing(m, 'print_tasks', 'batch_id', 'TEXT');
        await _addColumnIfMissing(
          m,
          'printers',
          'queue_enabled',
          'INTEGER NOT NULL DEFAULT 0',
        );
        await _addColumnIfMissing(
          m,
          'printers',
          'batch_recognition',
          'INTEGER NOT NULL DEFAULT 0',
        );
        await _createPrintQueueTable(m);
      }
      if (from < 14 && to >= 14) {
        // v14：数字孪生 - 耗材加 tray_uuid（拓竹 RFID UUID）和 rfid_synced_at（同步时间戳）。
        // 用 PRAGMA table_info 检查列是否存在，避免跨版本升级时重复 ALTER。
        await _addColumnIfMissing(m, 'consumables', 'tray_uuid', 'TEXT');
        await _addColumnIfMissing(
          m,
          'consumables',
          'rfid_synced_at',
          'INTEGER',
        );
      }
      if (from < 15 && to >= 15) {
        // v15：跨打印机智能调度任务表。
        // 调度器只把任务分配到同机型组打印机（gcode 不兼容是硬约束）。
        await _createSchedulerTasksTable(m);
      }
      if (from < 16 && to >= 16) {
        // v16：ams_change_events 表新增 color_hex 列。
        // 外挂料多色打印换色提醒功能：记录每次换色的目标颜色 HEX，
        // 便于回溯换色历史。旧数据 color_hex 默认 null（保持向后兼容）。
        // 用 PRAGMA table_info 检查列是否存在，避免跨版本升级重复 ALTER。
        await _addColumnIfMissing(m, 'ams_change_events', 'color_hex', 'TEXT');
      }
      if (from < 17 && to >= 17) {
        await _createDataIntegrityIndexes(m);
      }
      if (from < 18 && to >= 18) {
        // v18：参数效果闭环基础表。
        // preset_snapshots：不可变参数快照，按 fingerprint_schema_version + content_hash 唯一复用。
        // preset_applications：参数应用账本，记录每次真正写入切片软件的成功事件。
        // preset_slice_artifacts：切片产物 hash 绑定，用于精确归因打印任务到参数。
        // preset_print_results：打印结果单一事实来源，关联任务/快照/应用记录 + 自动指标 + 用户评价。
        await _createPresetSnapshotsTable(m);
        await _createPresetApplicationsTable(m);
        await _createPresetSliceArtifactsTable(m);
        await _createPresetPrintResultsTable(m);
      }
      if (from < 19 && to >= 19) {
        // v19：故障/数字孪生/调度/实验/可观测性表。
        await _createPrinterFaultEventsTable(m);
        await _createConsumableTwinEventsTable(m);
        await _createSchedulerTaskMaterialsTable(m);
        await _createSpoolReservationsTable(m);
        await _createParameterExperimentsTable(m);
        await _createTelemetryEventsTable(m);
      }
      if (from < 20 && to >= 20) {
        // v20：RFID 数字孪生增强。
        // 1. consumable_twin_events 加 printer_serial 列（本地追踪，不上传）。
        await _addColumnIfMissing(
          m,
          'consumable_twin_events',
          'printer_serial',
          'TEXT NOT NULL DEFAULT \'\'',
        );
        // 2. consumables.tray_uuid 唯一索引：同一 trayUuid 只能对应一卷耗材。
        //    先去重：保留 rfid_synced_at 最新或 remaining_grams 最小的记录，
        //    其余重复记录的 tray_uuid 置空（回退为普通库存）。
        await _dedupeTrayUuidConflicts(m);
        await m.database.customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_consumables_tray_uuid_unique '
          "ON consumables(tray_uuid) WHERE tray_uuid IS NOT NULL AND tray_uuid != ''",
        );
      }
      if (from < 21 && to >= 21) {
        // v21：调度器增强 - print_queue 关联 scheduler_tasks + 精确机型匹配列。
        //
        // 1. print_queue 加 scheduler_task_id + 唯一索引：
        //    任务书要求禁止靠文件名反查，同一调度任务不能重复入队。
        await _addColumnIfMissing(
          m,
          'print_queue',
          'scheduler_task_id',
          'INTEGER',
        );
        await m.database.customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_pq_scheduler_task_unique '
          'ON print_queue(scheduler_task_id) '
          'WHERE scheduler_task_id IS NOT NULL',
        );
        //
        // 2. scheduler_tasks 加 target_model / target_nozzle_diameter：
        //    任务书要求精确匹配 canonical 型号 + 喷嘴直径，
        //    不能靠宽泛机型组（A1组/P1组/X1组）作为发送现成 G-code 的安全依据。
        //    旧任务无此信息时为 NULL，调度器回退到 model_group + 默认 0.4mm。
        await _addColumnIfMissing(m, 'scheduler_tasks', 'target_model', 'TEXT');
        await _addColumnIfMissing(
          m,
          'scheduler_tasks',
          'target_nozzle_diameter',
          'REAL',
        );
      }
      if (from < 22 && to >= 22) {
        // v22：一个产物可能对应多个参数应用，不能静默归给首次应用。
        await m.database.customStatement(
          'DROP INDEX IF EXISTS idx_slice_artifacts_sha256',
        );
        await m.database.customStatement(
          'CREATE INDEX IF NOT EXISTS idx_slice_artifacts_sha256 '
          'ON preset_slice_artifacts(artifact_sha256)',
        );
        await m.database.customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_slice_artifacts_hash_app '
          'ON preset_slice_artifacts(artifact_sha256, application_id)',
        );
        await _createPresetTaskAttributionsTable(m);
      }
      if (from < 23 && to >= 23) {
        // v23: keep the immutable community publication revision separate
        // from the optimistic-lock revision of an uploaded print result.
        await _addColumnIfMissing(
          m,
          'preset_print_results',
          'community_result_revision',
          'INTEGER',
        );
      }
      if (from < 24 && to >= 24) {
        // v24: parameter experiment runs can enter the real print queue.
        await _addColumnIfMissing(
          m,
          'print_queue',
          'experiment_run_id',
          'TEXT',
        );
        await _addColumnIfMissing(
          m,
          'print_queue',
          'experiment_snapshot_id',
          'TEXT',
        );
        await _addColumnIfMissing(
          m,
          'print_queue',
          'experiment_application_id',
          'TEXT',
        );
        await _addColumnIfMissing(
          m,
          'print_queue',
          'experiment_attribution',
          'TEXT',
        );
        await _addColumnIfMissing(m, 'print_queue', 'artifact_sha256', 'TEXT');
        await m.database.customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_pq_experiment_run_unique '
          'ON print_queue(experiment_run_id) '
          'WHERE experiment_run_id IS NOT NULL',
        );
      }
      if (from < 25 && to >= 25) {
        // v25: consolidate all SQLite structure under this migration
        // authority. These tables were previously created after open by
        // MigrationManager, so IF NOT EXISTS preserves existing data.
        await _createLocalPresetTables(m);
      }
      if (from < 26 && to >= 26) {
        // v26: optional print-farm / studio workspace. All tables remain
        // local when the mode is disabled and can later sync by stable ID.
        await _createStudioTables(m);
      }
      if (from < 27 && to >= 27) {
        // v27: farm mode becomes a separate operational workspace with
        // batch receiving and password-protected customer portal metadata.
        await _createStudioTables(m);
      }
      if (from < 28 && to >= 28) {
        // v28: a sliced production package is decomposed into plates and
        // customer-facing items before farm work orders are allocated.
        await _createStudioTables(m);
      }
      if (from < 29 && to >= 29) {
        // v29: every plate keeps an independent slicing lifecycle and
        // artifact, so capacity can be assigned plate by plate.
        await _createStudioTables(m);
      }
      if (from < 30 && to >= 30) {
        // v30: farm organizations keep independent staff identities and
        // lifecycle metadata while the mode switch remains a UI entry.
        await _createStudioTables(m);
      }
      if (from < 31 && to >= 31) {
        // v31: one farm employee may carry multiple concurrent roles.
        await _createStudioTables(m);
      }
      if (from < 32 && to >= 32) {
        // v32: reserve and settle every production plate tool independently
        // for the exact quantity assigned to each farm work order.
        await _createStudioTables(m);
        // Early and RFID-created inventory rows could use the historical
        // empty default. Cloud material mappings need a stable per-spool ID.
        if (await _tableExists(m, 'consumables')) {
          await m.database.customStatement(
            "UPDATE consumables SET uid = lower(hex(randomblob(16))) "
            "WHERE uid IS NULL OR trim(uid) = ''",
          );
        }
      }
      if (from < 33 && to >= 33) {
        // v33: keep the scheduler-confirmed tool-to-AMS mapping with the
        // queued artifact so busy printers can accept future work safely.
        if (await _tableExists(m, 'print_queue')) {
          await _addColumnIfMissing(
            m,
            'print_queue',
            'ams_mapping_json',
            'TEXT',
          );
          await _addColumnIfMissing(
            m,
            'print_queue',
            'studio_work_order_id',
            'TEXT REFERENCES studio_work_orders(id) ON DELETE SET NULL',
          );
          if (await _columnExists(m, 'print_queue', 'status')) {
            await m.database.customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS idx_pq_studio_work_order_unique '
              'ON print_queue(studio_work_order_id) '
              "WHERE studio_work_order_id IS NOT NULL AND status != 'cancelled'",
            );
          }
        }
      }
      if (from < 34 && to >= 34) {
        // v34: separate personal inventory from farm workspace inventory
        // and repair legacy DateTime values written in milliseconds.
        await _createStudioTables(m);
        await _prepareConsumableInventoryScope(m, migrateExisting: true);
      }
      if (from < 35 && to >= 35) {
        // v35: batch receiving stores identical rolls as one aggregated
        // inventory row, while preserving batch roll count and unit size.
        await _createStudioTables(m);
        // Some historical migration fixtures intentionally contain only
        // the tables introduced by that release. Keep the migration
        // idempotent instead of assuming printer_channels is present.
        if (await _tableExists(m, 'printer_channels')) {
          await _addColumnIfMissing(
            m,
            'printer_channels',
            'loaded_remaining_grams',
            'REAL NOT NULL DEFAULT 0',
          );
          await m.database.customUpdate(
            'UPDATE printer_channels SET loaded_remaining_grams = 1000 '
            'WHERE consumable_id IS NOT NULL AND loaded_remaining_grams <= 0',
          );
        }
        await _consolidateLegacyFarmInventory(m);
      }
      if (from < 36 && to >= 36) {
        // v36: a farm roll temporarily removed for jam clearing or
        // printer maintenance keeps its exact slot grams and cannot be
        // scheduled until the operator explicitly resumes it.
        await _prepareFarmChannelRollState(m, reconcileExisting: true);
      }
      if (from < 37 && to >= 37) {
        // v37：农场身份收敛为管理员/成员，并增加可同步的操作署名记录。
        await _createStudioTables(m);
      }
      if (from < 38 && to >= 38) {
        // v38：修复历史农场库存中“有到货批次、但批次明细丢失”
        // 以及批次卷数仍按旧记录条数而不是实际 1000g 卷数统计的问题。
        await _createStudioTables(m);
        await _repairFarmInventoryBatchLinks(m);
      }
      if (from < 39 && to >= 39) {
        // v39：操作记录是审计凭证，只允许追加，禁止被业务代码修改或删除。
        await _createStudioTables(m);
        await _createStudioActivityGuards(m);
      }
      if (from < 40 && to >= 40) {
        // v40：每次农场打印重试拥有独立尝试编号与结果账本，
        // 连续失败可以逐次计入损耗，并保留停止、质检报废和待核对历史。
        await _createPrintQueueTable(m);
        await _createStudioTables(m);
      }
      if (from < 41 && to >= 41) {
        // v41：本地农场按登录账号隔离；同步实体保留删除墓碑和更新时间；
        // 打印机槽位单独保存当前物理 RFID 卷标识，避免同 SKU 多卷串位。
        await _createStudioTables(m);
        await _prepareFarmDataIntegrityV41(m);
      }
      if (from < 42 && to >= 42) {
        // v42：生产盘记录当前切片产物是否包含自动取件脚本。
        // NULL 代表旧版或外部导入产物，排产时不得当作已确认的安全状态复用。
        await _createStudioTables(m);
      }
      if (from < 43 && to >= 43) {
        // v43：批量连续生产队列项记录批次与本项取件策略。
        // NULL 的 auto_continue 保留旧队列的全局无人值守兼容语义；
        // 新的订单/批量页会明确写入 true 或 false。
        await _createPrintQueueTable(m);
      }
      if (from < 44 && to >= 44) {
        // v44：农场库存使用可恢复归档状态，支持多色信息、品牌标准码，
        // 入库批次明细支持保留审计记录的冲销。
        await _createStudioTables(m);
        await _prepareFarmInventoryV44(m, migrateExisting: true);
      }
      if (from < 45 && to >= 45) {
        await _createStudioQuoteConfigTables(m);
      }
      if (from < 46 && to >= 46) {
        // v46: fresh databases previously skipped the v20 tray UUID
        // index because it only ran from onUpgrade. Make repeated RFID
        // writes idempotent for every database generation.
        await _ensureTrayUuidUniqueIndex(m);
      }
      if (from < 47 && to >= 47) {
        // v47：保留每次手机 NFC 标签写入/扫描事件，支持重复 CUID/FUID
        // 记录、批量入库审计和失败重试，不与耗材卷 tray_uuid 唯一绑定混用。
        await _createRfidTagRecordsTable(m);
      }
      if (from < 48 && to >= 48) {
        // v48：个人库存同步保留删除墓碑，避免删除在另一台设备上复活。
        await _createPersonalInventoryTombstonesTable(m);
      }
      if (from < 49 && to >= 49) {
        // v49：CUID/FUID 是可复用的物理标签身份，不能继续作为单卷
        // tray_uuid/库存 uid。给每卷增加标签身份、复用周期和生命周期，
        // 并把旧版手机写入的 personal.tray_uuid 安全迁移到新字段。
        await _prepareRfidSpoolLifecycle(m, migrateExisting: true);
      }
      if (from < 50 && to >= 50) {
        // v50：把 NFC、换卷、数字孪生和打印消耗事件统一成可同步的
        // 个人账本。原始 RFID 块、密钥和打印机凭据仍不进入此表。
        await _createPersonalInventoryEventsTable(m);
      }
      if (from < 51 && to >= 51) {
        await preparePersonalInventoryEventOutbox(m);
      }
      if (from < 52 && to >= 52) {
        await _prepareTaskSpoolSegments(m);
      }
      if (from < 53 && to >= 53) {
        await preparePersonalAmsUidAliases(m);
      }
      if (from < 54 && to >= 54) {
        await _addColumnIfMissing(
          m,
          'consumables',
          'rfid_tag_history',
          "TEXT NOT NULL DEFAULT '[]'",
        );
      }
      if (from < 55 && to >= 55) await prepareDeviceWorkbench(m);
      if (from < 56 && to >= 56) await preparePersonalRfidStock(m);
    },
    // 启用 SQLite 外键约束。drift 默认不启用，需要 PRAGMA 显式开启。
    // 注意：PRAGMA foreign_keys = ON 只对新事务生效，不会立即校验已有数据，
    // 因此对存量库无破坏性影响。
    // 启用后，printers 被删除时关联表（print_task_consumables.printer_id /
    // usage_logs.printer_id 等）会按 ON DELETE SET NULL 自动置空引用。
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // A process cannot still be slicing after the app restarted. Mark
      // interrupted plate jobs retryable instead of leaving them stuck.
      final studioPlateTable = await customSelect(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' "
        "AND name = 'studio_production_plates' LIMIT 1",
      ).getSingleOrNull();
      if (studioPlateTable != null) {
        await customStatement(
          "UPDATE studio_production_plates SET slice_status = 'failed', "
          "updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000 "
          "WHERE slice_status = 'slicing'",
        );
      }
      await _repairFarmInventoryBatchLinksOnOpen();
    },
  );

  Future<void> _createPersonalInventoryTombstonesTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS personal_inventory_tombstones(
        owner_account TEXT NOT NULL,
        uid TEXT NOT NULL,
        deleted_at INTEGER NOT NULL,
        PRIMARY KEY(owner_account, uid)
      );
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_personal_inventory_tombstones_time '
      'ON personal_inventory_tombstones(owner_account, deleted_at)',
    );
  }

  /// v50：个人耗材不可变事件账本。
  ///
  /// 该表是跨设备同步的安全投影；本地原始表仍保留完整细节，云端只接收
  /// 下列有限字段。event_uid 由来源和稳定内容生成，重复上传是幂等的。
  Future<void> _createPersonalInventoryEventsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS personal_inventory_events(
        event_uid TEXT PRIMARY KEY,
        owner_account TEXT,
        inventory_uid TEXT NOT NULL,
        rfid_tag_uid TEXT,
        rfid_tag_cycle INTEGER,
        event_type TEXT NOT NULL,
        before_grams REAL,
        after_grams REAL,
        delta_grams REAL,
        occurred_at INTEGER NOT NULL,
        source TEXT NOT NULL DEFAULT 'local',
        note TEXT,
        origin TEXT NOT NULL DEFAULT 'local'
      );
    ''');
    await _addColumnIfMissing(
      m,
      'personal_inventory_events',
      'origin',
      "TEXT NOT NULL DEFAULT 'local'",
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_personal_inventory_events_owner_time '
      'ON personal_inventory_events(owner_account, occurred_at DESC, event_uid)',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_personal_inventory_events_inventory_time '
      'ON personal_inventory_events(inventory_uid, occurred_at DESC)',
    );
  }

  /// v49：为可复用 CUID/FUID 建立“标签身份 → 卷实例”链路。
  ///
  /// `consumables.uid` 始终是一卷耗材实例的稳定同步 ID；
  /// `rfid_tag_uid` 允许重复，`rfid_tag_cycle` 区分同一张标签的第 N 卷。
  /// 这样旧卷可以保留打印消耗历史，新卷使用新的库存 uid，而不是覆盖旧卷。
  Future<void> _prepareRfidSpoolLifecycle(
    Migrator m, {
    bool migrateExisting = false,
  }) async {
    if (!await _tableExists(m, 'consumables')) return;
    await _addColumnIfMissing(m, 'consumables', 'rfid_tag_uid', 'TEXT');
    await _addColumnIfMissing(m, 'consumables', 'rfid_tag_type', 'TEXT');
    await _addColumnIfMissing(
      m,
      'consumables',
      'rfid_tag_cycle',
      'INTEGER NOT NULL DEFAULT 1',
    );
    await _addColumnIfMissing(
      m,
      'consumables',
      'lifecycle_status',
      "TEXT NOT NULL DEFAULT 'active'",
    );
    await _addColumnIfMissing(
      m,
      'consumables',
      'previous_consumable_uid',
      'TEXT',
    );

    if (migrateExisting && await _tableExists(m, 'rfid_tag_records')) {
      // v47 的移动端曾把 CUID/FUID 写进 tray_uuid。只迁移能在操作历史
      // 中确认是 AMS/MIFARE 的记录，避免误伤官方 Bambu trayUuid。
      await m.database.customStatement('''
        UPDATE consumables
        SET rfid_tag_uid = trim(tray_uuid),
            tray_uuid = NULL
        WHERE inventory_scope = 'personal'
          AND trim(COALESCE(tray_uuid, '')) != ''
          AND EXISTS (
            SELECT 1 FROM rfid_tag_records r
            WHERE r.profile = 'ams'
              AND lower(
                replace(replace(replace(replace(trim(r.tag_uid), ':', ''), ' ', ''), '-', ''), '_', '')
              ) = lower(
                replace(replace(replace(replace(trim(consumables.tray_uuid), ':', ''), ' ', ''), '-', ''), '_', '')
              )
          )
          AND (rfid_tag_uid IS NULL OR trim(rfid_tag_uid) = '')
      ''');
    }
    await m.database.customStatement('''
      UPDATE consumables
      SET rfid_tag_cycle = CASE
        WHEN rfid_tag_cycle IS NULL OR rfid_tag_cycle < 1 THEN 1
        ELSE rfid_tag_cycle
      END,
      lifecycle_status = CASE
        WHEN remaining_grams <= 0
          AND trim(COALESCE(lifecycle_status, '')) IN ('', 'active') THEN 'depleted'
        WHEN trim(COALESCE(lifecycle_status, '')) = '' THEN
          'active'
        ELSE lifecycle_status
      END
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_consumables_rfid_tag '
      'ON consumables(inventory_scope, owner_account, rfid_tag_uid, '
      'rfid_tag_cycle, updated_at DESC)',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_consumables_lifecycle '
      'ON consumables(inventory_scope, lifecycle_status, updated_at DESC)',
    );
  }

  Future<void> _repairFarmInventoryBatchLinksOnOpen() async {
    final requiredTables = await customSelect(
      "SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' "
      "AND name IN ('consumables', 'studio_inventory_batches', "
      "'studio_inventory_batch_items')",
    ).getSingle();
    if (requiredTables.read<int>('count') != 3) return;
    final consumableColumns = (await customSelect(
      'PRAGMA table_info(consumables)',
    ).get()).map((row) => row.read<String>('name')).toSet();
    final batchItemColumns = (await customSelect(
      'PRAGMA table_info(studio_inventory_batch_items)',
    ).get()).map((row) => row.read<String>('name')).toSet();
    if (!consumableColumns.containsAll({
          'farm_workspace_id',
          'inventory_scope',
          'batch_no',
          'total_grams',
        }) ||
        !batchItemColumns.containsAll({
          'roll_count',
          'grams_per_roll',
          'unit_cost',
        })) {
      return;
    }
    final hasVoided = batchItemColumns.contains('voided');
    final activeItemCondition = hasVoided ? ' AND voided = 0' : '';
    final activeJoinedItemCondition = hasVoided ? ' AND item.voided = 0' : '';

    await customStatement('''
      INSERT OR IGNORE INTO studio_inventory_batch_items(
        id, batch_id, consumable_id, roll_count, grams_per_roll,
        unit_cost, created_at, updated_at
      )
      SELECT
        'repair-' || batch.id || '-' || consumable.id,
        batch.id,
        consumable.id,
        MAX(1, CAST(ROUND(consumable.total_grams / 1000.0) AS INTEGER)),
        1000,
        0,
        batch.created_at,
        batch.created_at
      FROM studio_inventory_batches batch
      JOIN consumables consumable
        ON consumable.farm_workspace_id = batch.workspace_id
       AND consumable.inventory_scope = 'farm'
       AND trim(COALESCE(consumable.batch_no, '')) = trim(batch.batch_no)
      WHERE trim(batch.batch_no) != ''
    ''');
    await customStatement('''
      UPDATE studio_inventory_batch_items
      SET roll_count = (
            SELECT MAX(
              1,
              CAST(ROUND(consumable.total_grams / 1000.0) AS INTEGER)
            )
            FROM consumables consumable
            WHERE consumable.id = studio_inventory_batch_items.consumable_id
          ),
          grams_per_roll = 1000
       WHERE EXISTS(
        SELECT 1 FROM consumables consumable
        WHERE consumable.id = studio_inventory_batch_items.consumable_id
           AND consumable.inventory_scope = 'farm'
       )$activeItemCondition
    ''');
    await customStatement('''
      UPDATE studio_inventory_batches
      SET roll_count = (
            SELECT COALESCE(SUM(item.roll_count), 0)
            FROM studio_inventory_batch_items item
            WHERE item.batch_id = studio_inventory_batches.id$activeJoinedItemCondition
          ),
          total_grams = (
            SELECT COALESCE(SUM(consumable.total_grams), 0)
            FROM studio_inventory_batch_items item
            JOIN consumables consumable ON consumable.id = item.consumable_id
            WHERE item.batch_id = studio_inventory_batches.id$activeJoinedItemCondition
          )
       WHERE EXISTS(
         SELECT 1 FROM studio_inventory_batch_items item
         WHERE item.batch_id = studio_inventory_batches.id$activeJoinedItemCondition
       )
    ''');
  }

  Future<void> _createLocalPresetTables(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS parameter_presets (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        author TEXT,
        material TEXT,
        scene TEXT,
        params_json TEXT NOT NULL,
        is_builtin INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS filament_presets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        vendor TEXT,
        material_type TEXT,
        color_hex TEXT,
        color_name TEXT,
        diameter REAL,
        density REAL,
        spool_weight REAL,
        note TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
  }

  Future<bool> _columnExists(
    Migrator m,
    String tableName,
    String columnName,
  ) async {
    final columns = await m.database
        .customSelect('PRAGMA table_info("$tableName")')
        .get();
    return columns.any((row) => row.data['name'] == columnName);
  }

  Future<bool> _tableExists(Migrator m, String tableName) async {
    final row = await m.database
        .customSelect(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
          variables: [Variable<String>(tableName)],
        )
        .getSingleOrNull();
    return row != null;
  }

  Future<void> _addColumnIfMissing(
    Migrator m,
    String tableName,
    String columnName,
    String definition,
  ) async {
    if (!await _tableExists(m, tableName)) return;
    if (await _columnExists(m, tableName, columnName)) return;
    await m.database.customStatement(
      'ALTER TABLE "$tableName" ADD COLUMN "$columnName" $definition',
    );
  }

  /// Keeps the ordinary inventory and farm inventory in separate local data
  /// domains. The generated Drift table intentionally does not include these
  /// raw-SQL columns because the project cannot currently run build_runner.
  Future<void> _prepareConsumableInventoryScope(
    Migrator m, {
    bool migrateExisting = false,
  }) async {
    if (!await _tableExists(m, 'consumables')) return;
    await _addColumnIfMissing(
      m,
      'consumables',
      'inventory_scope',
      "TEXT NOT NULL DEFAULT 'personal'",
    );
    await _addColumnIfMissing(m, 'consumables', 'farm_workspace_id', 'TEXT');

    // Drift stores DateTime as Unix seconds. Older raw SQL paths wrote
    // milliseconds (and a later cloud round-trip could amplify that again).
    // Normalize both forms before any generated SELECT maps the rows.
    await m.database.customStatement('''
      UPDATE consumables
      SET purchase_date = CASE
        WHEN purchase_date IS NULL THEN NULL
        WHEN ABS(purchase_date) >= 100000000000000
          THEN CAST(purchase_date / 1000000 AS INTEGER)
        WHEN ABS(purchase_date) >= 100000000000
          THEN CAST(purchase_date / 1000 AS INTEGER)
        ELSE purchase_date
      END,
      created_at = CASE
        WHEN ABS(created_at) >= 100000000000000
          THEN CAST(created_at / 1000000 AS INTEGER)
        WHEN ABS(created_at) >= 100000000000
          THEN CAST(created_at / 1000 AS INTEGER)
        ELSE created_at
      END,
      updated_at = CASE
        WHEN ABS(updated_at) >= 100000000000000
          THEN CAST(updated_at / 1000000 AS INTEGER)
        WHEN ABS(updated_at) >= 100000000000
          THEN CAST(updated_at / 1000 AS INTEGER)
        ELSE updated_at
      END
    ''');

    if (migrateExisting) {
      // Existing farm rows are discoverable from the farm tables. Everything
      // else remains personal inventory by design.
      if (await _tableExists(m, 'studio_inventory_batch_items') &&
          await _tableExists(m, 'studio_inventory_batches')) {
        await m.database.customStatement('''
          UPDATE consumables
          SET inventory_scope = 'farm',
              farm_workspace_id = (
                SELECT b.workspace_id
                FROM studio_inventory_batch_items bi
                JOIN studio_inventory_batches b ON b.id = bi.batch_id
                WHERE bi.consumable_id = consumables.id
                LIMIT 1
              )
          WHERE EXISTS (
            SELECT 1
            FROM studio_inventory_batch_items bi
            JOIN studio_inventory_batches b ON b.id = bi.batch_id
            WHERE bi.consumable_id = consumables.id
          )
        ''');
      }
      if (await _tableExists(m, 'studio_inventory_events')) {
        await m.database.customStatement('''
          UPDATE consumables
          SET inventory_scope = 'farm',
              farm_workspace_id = (
                SELECT e.workspace_id
                FROM studio_inventory_events e
                WHERE e.consumable_id = consumables.id
                LIMIT 1
              )
          WHERE inventory_scope = 'personal'
            AND EXISTS (
              SELECT 1 FROM studio_inventory_events e
              WHERE e.consumable_id = consumables.id
            )
        ''');
      }
      if (await _tableExists(m, 'studio_work_order_materials') &&
          await _tableExists(m, 'studio_work_orders')) {
        await m.database.customStatement('''
          UPDATE consumables
          SET inventory_scope = 'farm',
              farm_workspace_id = (
                SELECT w.workspace_id
                FROM studio_work_order_materials wm
                JOIN studio_work_orders w ON w.id = wm.work_order_id
                WHERE wm.consumable_id = consumables.id
                LIMIT 1
              )
          WHERE inventory_scope = 'personal'
            AND EXISTS (
              SELECT 1
              FROM studio_work_order_materials wm
              JOIN studio_work_orders w ON w.id = wm.work_order_id
              WHERE wm.consumable_id = consumables.id
            )
        ''');
      }
    }

    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_consumables_inventory_scope '
      'ON consumables(inventory_scope, farm_workspace_id)',
    );
  }

  Future<void> _prepareFarmChannelRollState(
    Migrator m, {
    bool reconcileExisting = false,
  }) async {
    await _addColumnIfMissing(
      m,
      'printer_channels',
      'farm_roll_paused',
      'INTEGER NOT NULL DEFAULT 0',
    );
    if (!reconcileExisting ||
        !await _tableExists(m, 'consumables') ||
        !await _columnExists(m, 'consumables', 'inventory_scope') ||
        !await _columnExists(m, 'printer_channels', 'loaded_remaining_grams')) {
      return;
    }
    // Before v36, farm printing deducted both the aggregated inventory row
    // and the slot balance. Convert the old aggregate into unopened warehouse
    // rolls by removing every currently loaded roll's observed grams, then
    // normalize the warehouse remainder to whole 1000g units.
    await m.database.customStatement('''
      UPDATE consumables
      SET remaining_grams = MAX(
        0,
        CAST((remaining_grams - COALESCE((
          SELECT SUM(pc.loaded_remaining_grams)
          FROM printer_channels pc
          WHERE pc.consumable_id = consumables.id
        ), 0)) / 1000 AS INTEGER) * 1000
      )
      WHERE inventory_scope = 'farm'
    ''');
  }

  Future<void> _prepareFarmDataIntegrityV41(Migrator m) async {
    if (await _tableExists(m, 'studio_workspaces')) {
      await _addColumnIfMissing(
        m,
        'studio_workspaces',
        'account_scope',
        'TEXT',
      );
      await m.database.customStatement(
        'CREATE INDEX IF NOT EXISTS idx_studio_workspaces_account_scope '
        'ON studio_workspaces(account_scope, created_at)',
      );
    }
    if (await _tableExists(m, 'studio_production_plates')) {
      await _addColumnIfMissing(
        m,
        'studio_production_plates',
        'updated_at',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await m.database.customStatement(
        'UPDATE studio_production_plates SET updated_at = created_at '
        'WHERE updated_at <= 0',
      );
    }
    if (await _tableExists(m, 'studio_inventory_batches')) {
      await _addColumnIfMissing(
        m,
        'studio_inventory_batches',
        'updated_at',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await m.database.customStatement(
        'UPDATE studio_inventory_batches SET updated_at = created_at '
        'WHERE updated_at <= 0',
      );
    }
    if (await _tableExists(m, 'studio_inventory_batch_items')) {
      await _addColumnIfMissing(
        m,
        'studio_inventory_batch_items',
        'updated_at',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await m.database.customStatement(
        'UPDATE studio_inventory_batch_items SET updated_at = created_at '
        'WHERE updated_at <= 0',
      );
    }
    if (await _tableExists(m, 'studio_workspaces')) {
      await m.database.customStatement('''
        CREATE TABLE IF NOT EXISTS studio_sync_tombstones(
          workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          deleted_at INTEGER NOT NULL,
          PRIMARY KEY(workspace_id, entity_type, entity_id)
        )
      ''');
    }
    if (await _tableExists(m, 'printer_channels')) {
      await _addColumnIfMissing(
        m,
        'printer_channels',
        'loaded_spool_uid',
        'TEXT',
      );
      if (await _tableExists(m, 'consumables')) {
        await m.database.customStatement('''
          UPDATE printer_channels
          SET loaded_spool_uid = CASE
            WHEN id = (
              SELECT MIN(other.id) FROM printer_channels other
              WHERE other.consumable_id = printer_channels.consumable_id
            ) THEN COALESCE(
              NULLIF((SELECT tray_uuid FROM consumables
                      WHERE id = printer_channels.consumable_id), ''),
              lower(hex(randomblob(16)))
            )
            ELSE lower(hex(randomblob(16)))
          END
          WHERE consumable_id IS NOT NULL
            AND loaded_remaining_grams > 0
            AND (loaded_spool_uid IS NULL OR trim(loaded_spool_uid) = '')
        ''');
      }
      await m.database.customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_printer_channels_loaded_spool_uid '
        'ON printer_channels(loaded_spool_uid) '
        "WHERE loaded_spool_uid IS NOT NULL AND trim(loaded_spool_uid) != ''",
      );
    }
  }

  Future<void> _prepareFarmInventoryV44(
    Migrator m, {
    bool migrateExisting = false,
  }) async {
    await _addColumnIfMissing(
      m,
      'consumables',
      'archived',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(m, 'consumables', 'archived_at', 'INTEGER');
    await _addColumnIfMissing(m, 'consumables', 'brand_code', 'TEXT');
    await _addColumnIfMissing(
      m,
      'consumables',
      'color_mode',
      "TEXT NOT NULL DEFAULT 'solid'",
    );
    await _addColumnIfMissing(m, 'consumables', 'secondary_color_hex', 'TEXT');
    await _addColumnIfMissing(
      m,
      'studio_inventory_batch_items',
      'voided',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      m,
      'studio_inventory_batch_items',
      'void_reason',
      'TEXT',
    );
    await _addColumnIfMissing(
      m,
      'studio_inventory_batch_items',
      'voided_at',
      'INTEGER',
    );

    if (migrateExisting &&
        await _columnExists(m, 'consumables', 'inventory_scope')) {
      await m.database.customStatement('''
        UPDATE consumables
        SET archived = 1,
            archived_at = COALESCE(archived_at, updated_at)
        WHERE inventory_scope = 'farm' AND remaining_grams <= 0
      ''');
      await m.database.customStatement('''
        UPDATE consumables
        SET color_mode = CASE
          WHEN lower(model) LIKE '%multi-color%' THEN 'multi'
          WHEN lower(model) LIKE '%gradient%' THEN 'gradient'
          ELSE COALESCE(NULLIF(color_mode, ''), 'solid')
        END
      ''');
    }
    if (await _tableExists(m, 'consumables')) {
      await m.database.customStatement(
        'CREATE INDEX IF NOT EXISTS idx_consumables_farm_archived '
        'ON consumables(inventory_scope, farm_workspace_id, archived)',
      );
    }
  }

  /// v20 迁移辅助：dedupe consumables.tray_uuid 冲突。
  ///
  /// 在创建 tray_uuid 唯一索引前调用。同一 trayUuid 只能对应一卷耗材，
  /// 重复记录的 tray_uuid 置空（回退为普通库存）。
  ///
  /// 保留策略：rfid_synced_at 最新（最近同步）的记录保留 tray_uuid；
  /// 若 rfid_synced_at 相同或为空，则 remaining_grams 最小的记录保留
  /// （已用得最多的卷视为"主"卷）；若仍无法区分，按 id 最小者保留。
  Future<void> _dedupeTrayUuidConflicts(Migrator m) async {
    // 先确认 tray_uuid 列存在（v14 添加，理论上 v20 升级时一定存在，
    // 但防御性检查避免早期开发版数据库异常）。
    if (!await _columnExists(m, 'consumables', 'tray_uuid')) return;

    // 查出所有有 tray_uuid 的记录，按 tray_uuid 分组找重复。
    final rows = await m.database
        .customSelect(
          "SELECT id, tray_uuid, rfid_synced_at, remaining_grams "
          "FROM consumables "
          "WHERE tray_uuid IS NOT NULL AND tray_uuid != '' "
          "ORDER BY tray_uuid ASC, id ASC",
        )
        .get();

    // 按 tray_uuid 分组
    final groups = <String, List<_ConsumableTrayRow>>{};
    for (final row in rows) {
      final uuid = row.read<String>('tray_uuid');
      final id = row.read<int>('id');
      final syncedAt = row.data['rfid_synced_at'] as int?;
      final remaining =
          (row.data['remaining_grams'] as num?)?.toDouble() ?? 0.0;
      groups
          .putIfAbsent(uuid, () => [])
          .add(
            _ConsumableTrayRow(
              id: id,
              trayUuid: uuid,
              rfidSyncedAt: syncedAt,
              remainingGrams: remaining,
            ),
          );
    }

    // 对每组重复 tray_uuid，保留一条，其余置空
    for (final entry in groups.entries) {
      final list = entry.value;
      if (list.length <= 1) continue;

      // 排序：rfid_synced_at 倒序（null 视为 0）→ remaining_grams 升序 → id 升序
      list.sort((a, b) {
        final aSync = a.rfidSyncedAt ?? 0;
        final bSync = b.rfidSyncedAt ?? 0;
        if (aSync != bSync) return bSync.compareTo(aSync);
        if (a.remainingGrams != b.remainingGrams) {
          return a.remainingGrams.compareTo(b.remainingGrams);
        }
        return a.id.compareTo(b.id);
      });

      // 保留第一条，其余 tray_uuid 置空
      final keepId = list.first.id;
      for (final r in list) {
        if (r.id == keepId) continue;
        await m.database.customStatement(
          "UPDATE consumables SET tray_uuid = '' WHERE id = ${r.id}",
        );
      }
    }
  }

  Future<void> _ensureTrayUuidUniqueIndex(Migrator m) async {
    if (!await _columnExists(m, 'consumables', 'tray_uuid')) return;
    await _dedupeTrayUuidConflicts(m);
    await m.database.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_consumables_tray_uuid_unique '
      "ON consumables(tray_uuid) WHERE tray_uuid IS NOT NULL AND tray_uuid != ''",
    );
  }

  /// 创建手机 NFC 标签操作历史表（schema v47）。
  ///
  /// 该表有意不把 ``tag_uid`` 设为唯一：CUID/FUID 采购卡可以使用相同
  /// UID，且同一张卡被重写时也应留下独立历史。耗材库存的
  /// ``consumables.rfid_tag_uid`` + ``rfid_tag_cycle`` 负责标签到具体卷
  /// 的生命周期绑定；本表只负责可追溯的写入/扫描/绑定事件。
  Future<void> _createRfidTagRecordsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS rfid_tag_records(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tag_uid TEXT NOT NULL,
        tag_type TEXT NOT NULL DEFAULT '',
        technology TEXT NOT NULL DEFAULT '',
        profile TEXT NOT NULL DEFAULT 'ams',
        operation TEXT NOT NULL DEFAULT 'write',
        status TEXT NOT NULL DEFAULT 'success',
        inventory_uid TEXT,
        owner_account TEXT,
        brand TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL DEFAULT '',
        color_hex TEXT NOT NULL DEFAULT '',
        color_name TEXT,
        bytes_written INTEGER,
        bytes_read INTEGER,
        blocks_written INTEGER,
        blocks_verified INTEGER,
        pages_written INTEGER,
        pages_read INTEGER,
        verified INTEGER NOT NULL DEFAULT 0,
        message TEXT,
        occurred_at INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    await m.database.customStatement('''
      CREATE INDEX IF NOT EXISTS idx_rfid_tag_records_owner_time
      ON rfid_tag_records(owner_account, occurred_at DESC, id DESC);
    ''');
    await m.database.customStatement('''
      CREATE INDEX IF NOT EXISTS idx_rfid_tag_records_tag_time
      ON rfid_tag_records(tag_uid, occurred_at DESC, id DESC);
    ''');
    await m.database.customStatement('''
      CREATE INDEX IF NOT EXISTS idx_rfid_tag_records_inventory
      ON rfid_tag_records(inventory_uid, occurred_at DESC);
    ''');
  }

  /// 防止同一物理任务或同一工具关联在活跃期被重复创建。
  /// 历史终态数据不强制去重，避免升级时删除既有台账。
  Future<void> _createDataIntegrityIndexes(Migrator m) async {
    // 部分早期开发版数据库的 user_version 已提升，但任务表仍是残缺结构。
    // 索引迁移只在所需列完整时执行，避免阻断其他独立表的数据升级。
    final taskColumns = await _columnNames(m, 'print_tasks');
    const requiredTaskColumns = {
      'id',
      'uid',
      'status',
      'finished_at',
      'updated_at',
    };
    if (taskColumns.containsAll(requiredTaskColumns)) {
      // 保留重复历史，只让最新一条继续处于活跃状态。
      await m.database.customStatement('''
        UPDATE print_tasks
        SET status = 'cancelled',
            finished_at = COALESCE(finished_at, updated_at)
        WHERE uid != ''
          AND status IN ('planned', 'printing', 'paused')
          AND id NOT IN (
            SELECT MAX(id)
            FROM print_tasks
            WHERE uid != ''
              AND status IN ('planned', 'printing', 'paused')
            GROUP BY uid
          );
      ''');
      await m.database.customStatement('''
        CREATE UNIQUE INDEX IF NOT EXISTS idx_print_tasks_active_uid
        ON print_tasks(uid)
        WHERE uid != '' AND status IN ('planned', 'printing', 'paused');
      ''');
    }

    final ptcColumns = await _columnNames(m, 'print_task_consumables');
    const requiredPtcColumns = {
      'id',
      'task_id',
      'tool_index',
      'consumed_at',
      'consumed_grams',
      'created_at',
      'updated_at',
    };
    if (ptcColumns.containsAll(requiredPtcColumns)) {
      await m.database.customStatement('''
        UPDATE print_task_consumables
        SET consumed_at = COALESCE(updated_at, created_at),
            consumed_grams = 0
        WHERE consumed_at IS NULL
          AND id NOT IN (
            SELECT MAX(id)
            FROM print_task_consumables
            WHERE consumed_at IS NULL
            GROUP BY task_id, tool_index
          );
      ''');
      await m.database.customStatement('''
        CREATE UNIQUE INDEX IF NOT EXISTS idx_ptc_active_task_tool
        ON print_task_consumables(task_id, tool_index)
        WHERE consumed_at IS NULL;
      ''');
    }
  }

  Future<Set<String>> _columnNames(Migrator m, String tableName) async {
    final columns = await m.database
        .customSelect('PRAGMA table_info("$tableName")')
        .get();
    return columns.map((row) => row.data['name'] as String).toSet();
  }

  /// 创建 print_tasks 表（raw SQL）。
  /// 字段含义与 Dart 模型见 lib/data/database/models/print_task.dart。
  Future<void> _createPrintTasksTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS print_tasks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uid TEXT NOT NULL DEFAULT '',
        printer_id INTEGER REFERENCES printers(id) ON DELETE SET NULL,
        consumable_id INTEGER REFERENCES consumables(id) ON DELETE SET NULL,
        gcode_path TEXT NOT NULL,
        task_name TEXT NOT NULL,
        estimated_grams REAL NOT NULL DEFAULT 0.0,
        estimated_seconds INTEGER NOT NULL DEFAULT 0,
        actual_grams REAL NOT NULL DEFAULT 0.0,
        started_at INTEGER,
        finished_at INTEGER,
        last_mc_percent INTEGER NOT NULL DEFAULT 0,
        last_layer INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'planned',
        source TEXT NOT NULL DEFAULT 'bambu_studio',
        per_filament_grams TEXT,
        note TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        batch_id TEXT
      );
    ''');
  }

  /// 创建 print_queue 表（v13 新增，打印队列）。
  ///
  /// 状态机：queued → printing → waiting_removal → completed（或 cancelled）
  /// - queued：待打印，按 sort_order 排序
  /// - printing：已发送到打印机，MQTT 监测中
  /// - waiting_removal：打印完成，等待用户取件确认
  /// - completed：取件确认完成（无人值守模式跳过此状态直接 completed）
  /// - cancelled：用户取消
  Future<void> _createPrintQueueTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS print_queue(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        printer_serial TEXT NOT NULL,
        gcode_path TEXT NOT NULL,
        filename TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'queued',
        sort_order INTEGER NOT NULL DEFAULT 0,
        queued_at INTEGER NOT NULL,
        started_at INTEGER,
        completed_at INTEGER,
        print_task_id INTEGER REFERENCES print_tasks(id) ON DELETE SET NULL,
        scheduler_task_id INTEGER,
        experiment_run_id TEXT,
        experiment_snapshot_id TEXT,
        experiment_application_id TEXT,
        experiment_attribution TEXT,
        artifact_sha256 TEXT,
        ams_mapping_json TEXT,
        attempt_no INTEGER NOT NULL DEFAULT 1,
        auto_continue INTEGER,
        batch_id TEXT,
        batch_index INTEGER,
        batch_total INTEGER,
        studio_work_order_id TEXT REFERENCES studio_work_orders(id) ON DELETE SET NULL
      );
    ''');
    await _addColumnIfMissing(
      m,
      'print_queue',
      'attempt_no',
      'INTEGER NOT NULL DEFAULT 1',
    );
    await _addColumnIfMissing(m, 'print_queue', 'auto_continue', 'INTEGER');
    await _addColumnIfMissing(m, 'print_queue', 'batch_id', 'TEXT');
    await _addColumnIfMissing(m, 'print_queue', 'batch_index', 'INTEGER');
    await _addColumnIfMissing(m, 'print_queue', 'batch_total', 'INTEGER');
    if (await _columnExists(m, 'print_queue', 'printer_serial') &&
        await _columnExists(m, 'print_queue', 'status')) {
      await m.database.customStatement(
        'CREATE INDEX IF NOT EXISTS idx_pq_printer_status '
        'ON print_queue(printer_serial, status);',
      );
    }
    // v21：唯一索引防止同一调度任务重复入队（仅对非 NULL 值生效）
    if (await _columnExists(m, 'print_queue', 'scheduler_task_id')) {
      await m.database.customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_pq_scheduler_task_unique '
        'ON print_queue(scheduler_task_id) '
        'WHERE scheduler_task_id IS NOT NULL',
      );
    }
    if (await _columnExists(m, 'print_queue', 'experiment_run_id')) {
      await m.database.customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_pq_experiment_run_unique '
        'ON print_queue(experiment_run_id) '
        'WHERE experiment_run_id IS NOT NULL',
      );
    }
    if (await _columnExists(m, 'print_queue', 'studio_work_order_id') &&
        await _columnExists(m, 'print_queue', 'status')) {
      await m.database.customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_pq_studio_work_order_unique '
        'ON print_queue(studio_work_order_id) '
        "WHERE studio_work_order_id IS NOT NULL AND status != 'cancelled'",
      );
    }
  }

  /// 创建 scheduler_tasks 表（v15 新增，跨打印机智能调度）。
  ///
  /// 调度器只把任务分配到同机型组打印机（拓竹不同机型 gcode 不兼容是硬约束）。
  /// - model_group：机型组标识（PrinterModelGroup.name，如 a1/p1/x1/h2d）
  /// - status：pending/assigned/printing/completed/cancelled
  /// - assigned_printer_id：外键 printers(id)，ON DELETE SET NULL 保留历史
  ///
  /// 字段含义与 Dart 模型见 lib/data/database/models/scheduler_models.dart。
  Future<void> _createSchedulerTasksTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS scheduler_tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        gcode_path TEXT NOT NULL,
        gcode_filename TEXT NOT NULL,
        model_group TEXT NOT NULL,
        required_material TEXT NOT NULL,
        required_color_hex TEXT,
        estimated_grams REAL NOT NULL DEFAULT 0,
        estimated_seconds INTEGER,
        status TEXT NOT NULL DEFAULT 'pending',
        assigned_printer_id INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        assigned_at INTEGER,
        completed_at INTEGER,
        note TEXT,
        target_model TEXT,
        target_nozzle_diameter REAL,
        FOREIGN KEY (assigned_printer_id) REFERENCES printers(id) ON DELETE SET NULL
      )
    ''');
    // 按状态筛选（待分配列表用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_scheduler_status ON scheduler_tasks(status);',
    );
    // 按排序顺序取待分配任务（调度器消费队列用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_scheduler_sort ON scheduler_tasks(status, sort_order);',
    );
  }

  /// 创建 filament_cost_configs 表（raw SQL）。
  /// 业务规则：同一品牌 + 材质 + 颜色 统一一个每公斤成本价。
  /// 字段含义与 Dart 模型见 lib/data/database/models/filament_cost_config.dart。
  Future<void> _createFilamentCostConfigsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS filament_cost_configs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        vendor TEXT NOT NULL DEFAULT '',
        material_type TEXT NOT NULL DEFAULT '',
        color_hex TEXT NOT NULL DEFAULT '',
        cost_per_kg REAL NOT NULL DEFAULT 0.0,
        note TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    // 便于按品牌+材质+颜色快速查找（无论颜色是否通配）
    await m.database.customStatement('''
      CREATE INDEX IF NOT EXISTS idx_filament_cost_match
      ON filament_cost_configs(vendor, material_type, color_hex);
    ''');
  }

  /// 创建 print_task_consumables 表（raw SQL）。
  ///
  /// 记录打印任务消耗的每卷耗材：
  /// - task_id + tool_index 唯一标识任务里某个挤出机
  /// - consumable_id 外键 consumables，ON DELETE SET NULL 保留历史
  /// - estimated_grams 切片预估该卷消耗
  /// - consumed_grams 最终实际消耗（完成时写入）
  /// - last_deducted_grams 实时扣减累计值（完成时算差额修正）
  /// - cost_per_kg_snapshot 成本快照（防后期改价影响历史）
  ///
  /// 字段含义与 Dart 模型见 lib/data/database/models/print_task_consumable.dart。
  Future<void> _prepareTaskSpoolSegments(Migrator m) async {
    await _addColumnIfMissing(
      m,
      'print_task_consumables',
      'segment_start_grams',
      'REAL NOT NULL DEFAULT 0.0',
    );
  }

  Future<void> _createPrintTaskConsumablesTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS print_task_consumables(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER NOT NULL REFERENCES print_tasks(id) ON DELETE CASCADE,
        printer_id INTEGER REFERENCES printers(id) ON DELETE SET NULL,
        channel_index INTEGER NOT NULL DEFAULT 0,
        consumable_id INTEGER REFERENCES consumables(id) ON DELETE SET NULL,
        tool_index INTEGER NOT NULL DEFAULT 0,
        estimated_grams REAL NOT NULL DEFAULT 0.0,
        consumed_grams REAL NOT NULL DEFAULT 0.0,
        last_deducted_grams REAL NOT NULL DEFAULT 0.0,
        cost_per_kg_snapshot REAL,
        matched_cost_config_id INTEGER REFERENCES filament_cost_configs(id) ON DELETE SET NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        consumed_at INTEGER
      );
    ''');
    // 按任务查关联记录（实时面板/完成结算用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_ptc_task ON print_task_consumables(task_id);',
    );
    // 按耗材卷查累计消耗（库存页用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_ptc_consumable ON print_task_consumables(consumable_id);',
    );
    // 按消耗时间汇总（折线图/成本页用，v7 新增）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_ptc_consumed ON print_task_consumables(consumed_at);',
    );
  }

  /// 创建 ams_change_events 表（raw SQL）。
  ///
  /// 记录 AMS 多色打印过程中的每次换料事件：
  /// - 监听 MQTT `print.tray_now` 字段变化触发
  /// - 关联当前活跃任务和通道绑定的耗材卷
  /// - 用于提升多色任务成本精度（替代按 mc_percent 比例估算的粗略模式）
  ///
  /// 字段含义与 Dart 模型见 lib/data/database/models/ams_change_event.dart。
  Future<void> _createAmsChangeEventsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS ams_change_events(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        printer_id INTEGER REFERENCES printers(id) ON DELETE SET NULL,
        task_id INTEGER REFERENCES print_tasks(id) ON DELETE CASCADE,
        channel_index INTEGER NOT NULL,
        tool_index INTEGER NOT NULL,
        consumable_id INTEGER REFERENCES consumables(id) ON DELETE SET NULL,
        event_type TEXT NOT NULL,
        previous_remaining_grams REAL,
        consumed_grams_at_event REAL DEFAULT 0,
        occurred_at INTEGER NOT NULL,
        note TEXT,
        color_hex TEXT
      );
    ''');
    // 按任务查关联记录（任务详情页用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_ams_events_task ON ams_change_events(task_id);',
    );
    // 按耗材卷查累计换料历史（耗材详情页用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_ams_events_consumable ON ams_change_events(consumable_id);',
    );
    // 按时间排序/分桶（折线图/时间轴用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_ams_events_time ON ams_change_events(occurred_at);',
    );
  }

  /// v10：错误日志表，全局收集异常，替代 catch (_) {} 静默吞异常。
  ///
  /// **字段说明**：
  /// - level：error / warning / info
  /// - source：模块名（如 print_task / ftp / mqtt / cloud_api / gcode_parser）
  /// - message：错误消息（简短）
  /// - stack_trace：完整堆栈（可空）
  /// - context：附加上下文（JSON 字符串，如 taskId/printerId 等）
  /// - created_at：毫秒时间戳
  ///
  /// **保留策略**：诊断中心展示最近 500 条，超过自动清理。
  Future<void> _createErrorLogsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS error_logs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        level TEXT NOT NULL DEFAULT 'error',
        source TEXT NOT NULL DEFAULT 'unknown',
        message TEXT NOT NULL,
        stack_trace TEXT,
        context TEXT,
        created_at INTEGER NOT NULL
      );
    ''');
    // 按时间倒序查询（诊断中心用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_error_logs_time ON error_logs(created_at);',
    );
    // 按来源筛选（模块化排查用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_error_logs_source ON error_logs(source);',
    );
  }

  /// v18：参数快照表（不可变）。
  ///
  /// 相同 fingerprint_schema_version + content_hash 可以复用同一快照行；
  /// 快照创建后禁止覆盖。展示名称不属于快照身份。
  Future<void> _createPresetSnapshotsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS preset_snapshots(
        id TEXT PRIMARY KEY,
        fingerprint_schema_version INTEGER NOT NULL,
        content_hash TEXT NOT NULL,
        preset_json TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    // 联合唯一索引：相同 schema + hash 复用同一快照，避免重复存储。
    await m.database.customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_preset_snapshots_hash
      ON preset_snapshots(fingerprint_schema_version, content_hash);
    ''');
  }

  /// v18：参数应用账本表。
  ///
  /// 每次 _applyPreset 真正写入成功后记录一条。
  /// 是把参数可靠归因到后续打印任务的必要桥梁。
  Future<void> _createPresetApplicationsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS preset_applications(
        id TEXT PRIMARY KEY,
        snapshot_id TEXT NOT NULL REFERENCES preset_snapshots(id) ON DELETE RESTRICT,
        display_name TEXT NOT NULL DEFAULT '',
        local_preset_id TEXT,
        community_publication_id TEXT,
        community_version_id TEXT,
        community_revision INTEGER,
        slicer_process_settings_id TEXT,
        experiment_id TEXT,
        experiment_arm TEXT,
        applied_at INTEGER NOT NULL
      );
    ''');
    // 按快照查应用记录（参数表现汇总用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_preset_applications_snapshot ON preset_applications(snapshot_id);',
    );
    // 按本地预设 ID 查最近应用（候选归因用，不作为精确归因）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_preset_applications_local ON preset_applications(local_preset_id);',
    );
  }

  /// v18：切片产物 hash 绑定表。
  ///
  /// 在文件写入稳定后把切片产物 SHA-256 绑定到 application。
  /// 任务优先按切片产物 hash 精确归因，其次才使用明确参数元数据。
  Future<void> _createPresetSliceArtifactsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS preset_slice_artifacts(
        id TEXT PRIMARY KEY,
        application_id TEXT NOT NULL REFERENCES preset_applications(id) ON DELETE CASCADE,
        artifact_sha256 TEXT NOT NULL,
        artifact_size INTEGER NOT NULL DEFAULT 0,
        artifact_modified_at INTEGER,
        artifact_kind TEXT NOT NULL DEFAULT 'gcode',
        local_path TEXT NOT NULL DEFAULT '',
        bound_at INTEGER NOT NULL
      );
    ''');
    // 同一内容可能由多个应用生成；保留所有候选，任务侧只在唯一时精确归因。
    await m.database.customStatement('''
      CREATE INDEX IF NOT EXISTS idx_slice_artifacts_sha256
      ON preset_slice_artifacts(artifact_sha256);
    ''');
    await m.database.customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_slice_artifacts_hash_app
      ON preset_slice_artifacts(artifact_sha256, application_id);
    ''');
    // 按应用记录查绑定产物
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_slice_artifacts_app ON preset_slice_artifacts(application_id);',
    );
  }

  /// v22：打印任务创建时冻结的参数归因上下文。
  Future<void> _createPresetTaskAttributionsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS preset_task_attributions(
        task_id INTEGER PRIMARY KEY REFERENCES print_tasks(id) ON DELETE CASCADE,
        snapshot_id TEXT REFERENCES preset_snapshots(id) ON DELETE SET NULL,
        application_id TEXT REFERENCES preset_applications(id) ON DELETE SET NULL,
        preset_display_name TEXT NOT NULL DEFAULT '',
        attribution TEXT NOT NULL DEFAULT 'unknown',
        community_publication_id TEXT,
        community_version_id TEXT,
        community_revision INTEGER,
        artifact_sha256 TEXT,
        print_settings_id TEXT,
        printer_settings_id TEXT,
        nozzle_diameter REAL,
        plate_type TEXT,
        material_profile TEXT,
        material_type TEXT,
        created_at INTEGER NOT NULL
      );
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_task_attribution_application '
      'ON preset_task_attributions(application_id);',
    );
  }

  /// v18：打印结果表（单一事实来源）。
  ///
  /// 同一个 print_task 最多生成一条结果主记录（task_id 唯一索引防重复结算）。
  /// 自动采集任务事实 + 用户补充评价分开存储。
  Future<void> _createPresetPrintResultsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS preset_print_results(
        id TEXT PRIMARY KEY,
        client_run_id TEXT NOT NULL UNIQUE,
        task_id INTEGER NOT NULL,
        task_uid TEXT NOT NULL DEFAULT '',
        snapshot_id TEXT REFERENCES preset_snapshots(id) ON DELETE SET NULL,
        application_id TEXT REFERENCES preset_applications(id) ON DELETE SET NULL,
        preset_display_name TEXT NOT NULL DEFAULT '',
        attribution TEXT NOT NULL DEFAULT 'unknown',
        community_publication_id TEXT,
        community_version_id TEXT,
        community_revision INTEGER,
        community_result_revision INTEGER,
        printer_model TEXT NOT NULL DEFAULT '',
        nozzle_diameter REAL,
        plate_type TEXT,
        material_profile TEXT,
        material_type TEXT,
        material_batch_no TEXT,
        ams_humidity REAL,
        ams_humidity_sampled_at INTEGER,
        technical_status TEXT NOT NULL DEFAULT 'finished',
        user_outcome TEXT,
        failure_code TEXT,
        failure_category TEXT,
        estimated_grams REAL NOT NULL DEFAULT 0,
        actual_grams REAL NOT NULL DEFAULT 0,
        estimated_seconds INTEGER NOT NULL DEFAULT 0,
        actual_seconds INTEGER NOT NULL DEFAULT 0,
        rating INTEGER,
        adhesion_ok INTEGER,
        quality_score INTEGER,
        user_note TEXT,
        evidence_level TEXT NOT NULL DEFAULT 'device_recorded',
        share_consent TEXT NOT NULL DEFAULT 'not_shared',
        sync_status TEXT NOT NULL DEFAULT 'not_shared',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    // task_id 唯一索引：防止重复 MQTT 消息生成多条结果
    await m.database.customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_preset_print_results_task
      ON preset_print_results(task_id);
    ''');
    // 按快照汇总参数表现
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_preset_print_results_snapshot ON preset_print_results(snapshot_id);',
    );
    // 按社区发布 ID 汇总
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_preset_print_results_pub ON preset_print_results(community_publication_id);',
    );
    // 按技术状态筛选统计
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_preset_print_results_status ON preset_print_results(technical_status);',
    );
    // 按同步状态筛选上传队列
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_preset_print_results_sync ON preset_print_results(sync_status);',
    );
  }

  /// v19：故障事件表。
  ///
  /// 同一台打印机、同一代码、同一持续状态只创建一个故障生命周期；
  /// 清除后再次出现才新建事件。序列号不进入可分享数据。
  Future<void> _createPrinterFaultEventsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS printer_fault_events(
        id TEXT PRIMARY KEY,
        event_uid TEXT NOT NULL UNIQUE,
        printer_id INTEGER REFERENCES printers(id) ON DELETE CASCADE,
        printer_serial TEXT NOT NULL DEFAULT '',
        task_id INTEGER REFERENCES print_tasks(id) ON DELETE SET NULL,
        code TEXT NOT NULL,
        severity TEXT NOT NULL DEFAULT 'warning',
        title TEXT NOT NULL DEFAULT '',
        summary TEXT NOT NULL DEFAULT '',
        first_seen_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        cleared_at INTEGER,
        user_confirmed_at INTEGER,
        knowledge_base_version TEXT,
        raw_payload TEXT
      );
    ''');
    // 按打印机+代码查活动事件（去重核心索引）
    await m.database.customStatement('''
      CREATE INDEX IF NOT EXISTS idx_fault_events_printer_code
      ON printer_fault_events(printer_serial, code, cleared_at);
    ''');
    // 按任务查故障历史
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_fault_events_task ON printer_fault_events(task_id);',
    );
    // 按严重性筛选
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_fault_events_severity ON printer_fault_events(severity, last_seen_at);',
    );
  }

  /// v19：耗材数字孪生事件账本表。
  ///
  /// RFID 观测值、打印估算扣减值和用户手动修正都写入事件账本。
  /// 不能只覆盖 remainingGrams 后丢失来源。
  Future<void> _createConsumableTwinEventsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS consumable_twin_events(
        id TEXT PRIMARY KEY,
        event_uid TEXT NOT NULL UNIQUE,
        consumable_id INTEGER NOT NULL REFERENCES consumables(id) ON DELETE CASCADE,
        tray_uuid TEXT NOT NULL DEFAULT '',
        event_type TEXT NOT NULL,
        printer_id INTEGER REFERENCES printers(id) ON DELETE SET NULL,
        printer_serial TEXT NOT NULL DEFAULT '',
        ams_id INTEGER,
        slot_index INTEGER,
        before_grams REAL,
        after_grams REAL,
        rfid_percent INTEGER,
        tray_weight REAL,
        ams_humidity REAL,
        observed_at INTEGER NOT NULL,
        source TEXT NOT NULL DEFAULT 'mqtt',
        task_id INTEGER REFERENCES print_tasks(id) ON DELETE SET NULL
      );
    ''');
    // 按耗材卷查轨迹事件
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_twin_events_consumable ON consumable_twin_events(consumable_id, observed_at);',
    );
    // 按 tray_uuid 查轨迹（数字孪生核心索引）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_twin_events_uuid ON consumable_twin_events(tray_uuid, observed_at);',
    );
    // 按事件类型筛选
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_twin_events_type ON consumable_twin_events(event_type, observed_at);',
    );
  }

  /// v19：调度任务材料需求子表。
  ///
  /// 多色任务必须逐个工具匹配材料和余量。
  /// 不能把多色任务压成一个 required_material。
  Future<void> _createSchedulerTaskMaterialsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS scheduler_task_materials(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scheduler_task_id INTEGER NOT NULL REFERENCES scheduler_tasks(id) ON DELETE CASCADE,
        tool_index INTEGER NOT NULL,
        material_profile TEXT NOT NULL DEFAULT '',
        material_type TEXT NOT NULL DEFAULT '',
        required_color_hex TEXT,
        estimated_grams REAL NOT NULL DEFAULT 0,
        assigned_consumable_id INTEGER REFERENCES consumables(id) ON DELETE SET NULL
      );
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_scheduler_materials_task ON scheduler_task_materials(scheduler_task_id);',
    );
  }

  /// v19：耗材卷预留表。
  ///
  /// 排队任务先预留耗材；两个任务不能同时把同一卷剩余量各算一遍。
  Future<void> _createSpoolReservationsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS spool_reservations(
        id TEXT PRIMARY KEY,
        scheduler_task_id INTEGER NOT NULL REFERENCES scheduler_tasks(id) ON DELETE CASCADE,
        consumable_id INTEGER NOT NULL REFERENCES consumables(id) ON DELETE CASCADE,
        tool_index INTEGER NOT NULL DEFAULT 0,
        reserved_grams REAL NOT NULL DEFAULT 0,
        reserved_at INTEGER NOT NULL,
        released_at INTEGER,
        status TEXT NOT NULL DEFAULT 'active'
      );
    ''');
    // 按耗材卷查活动预留（余量计算核心索引）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_spool_reservations_consumable ON spool_reservations(consumable_id, status);',
    );
    // 按调度任务查预留
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_spool_reservations_task ON spool_reservations(scheduler_task_id);',
    );
  }

  /// v19：参数实验平台表（实验/变体/运行）。
  ///
  /// 外键删除策略保留历史。删除当前参数预设不能删除已执行实验的快照。
  Future<void> _createParameterExperimentsTable(Migrator m) async {
    // 实验主表
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS parameter_experiments(
        id TEXT PRIMARY KEY,
        experiment_uid TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        goal TEXT NOT NULL DEFAULT '',
        baseline_snapshot_id TEXT REFERENCES preset_snapshots(id) ON DELETE SET NULL,
        control_variables TEXT NOT NULL DEFAULT '',
        evaluation_metrics TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'draft',
        target_repeats INTEGER NOT NULL DEFAULT 3,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        archived_at INTEGER
      );
    ''');
    // 变体表
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS experiment_variants(
        id TEXT PRIMARY KEY,
        variant_uid TEXT NOT NULL UNIQUE,
        experiment_id TEXT NOT NULL REFERENCES parameter_experiments(id) ON DELETE CASCADE,
        label TEXT NOT NULL DEFAULT 'A',
        snapshot_id TEXT REFERENCES preset_snapshots(id) ON DELETE SET NULL,
        diff_summary TEXT NOT NULL DEFAULT '',
        revision INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL
      );
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_experiment_variants_exp ON experiment_variants(experiment_id);',
    );
    // 运行表
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS experiment_runs(
        id TEXT PRIMARY KEY,
        run_uid TEXT NOT NULL UNIQUE,
        experiment_id TEXT NOT NULL REFERENCES parameter_experiments(id) ON DELETE CASCADE,
        variant_id TEXT NOT NULL REFERENCES experiment_variants(id) ON DELETE CASCADE,
        run_order INTEGER NOT NULL,
        task_id INTEGER REFERENCES print_tasks(id) ON DELETE SET NULL,
        result_id TEXT REFERENCES preset_print_results(id) ON DELETE SET NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        created_at INTEGER NOT NULL,
        completed_at INTEGER
      );
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_experiment_runs_exp ON experiment_runs(experiment_id, run_order);',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_experiment_runs_variant ON experiment_runs(variant_id);',
    );
  }

  /// v19：遥测事件队列表。
  ///
  /// 独立队列表，不复用 error_logs。
  /// 可上传事件采用白名单，不在白名单中的本地指标不得进入上传队列。
  Future<void> _createTelemetryEventsTable(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS telemetry_events(
        id TEXT PRIMARY KEY,
        event_uid TEXT NOT NULL UNIQUE,
        event_name TEXT NOT NULL,
        result_category TEXT,
        duration_ms INTEGER,
        attributes TEXT NOT NULL DEFAULT '{}',
        recorded_at INTEGER NOT NULL,
        upload_status TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_retry_at INTEGER
      );
    ''');
    // 按上传状态筛选队列
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_telemetry_upload ON telemetry_events(upload_status, next_retry_at);',
    );
    // 按事件名和时间查询（指标汇总用）
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_telemetry_name_time ON telemetry_events(event_name, recorded_at);',
    );
  }

  Future<void> _createStudioQuoteConfigTables(Migrator m) async {
    if (await _tableExists(m, 'studio_quotes')) {
      await _addColumnIfMissing(
        m,
        'studio_quotes',
        'order_id',
        'TEXT REFERENCES studio_orders(id) ON DELETE SET NULL',
      );
      await m.database.customStatement(
        'CREATE INDEX IF NOT EXISTS idx_studio_quotes_order '
        'ON studio_quotes(workspace_id, order_id, created_at DESC);',
      );
    }
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_quote_settings(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL UNIQUE REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        labor_rate_per_hour REAL NOT NULL DEFAULT 30 CHECK(labor_rate_per_hour >= 0),
        electricity_rate_per_hour REAL NOT NULL DEFAULT 1 CHECK(electricity_rate_per_hour >= 0),
        risk_reserve_percent REAL NOT NULL DEFAULT 8 CHECK(risk_reserve_percent BETWEEN 0 AND 100),
        markup_percent REAL NOT NULL DEFAULT 30 CHECK(markup_percent BETWEEN 0 AND 100),
        packaging_cost REAL NOT NULL DEFAULT 2 CHECK(packaging_cost >= 0),
        minimum_order_price REAL NOT NULL DEFAULT 0 CHECK(minimum_order_price >= 0),
        updated_at INTEGER NOT NULL
      );
    ''');
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_machine_cost_configs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        brand TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL DEFAULT '',
        wear_cost_per_hour REAL NOT NULL DEFAULT 0 CHECK(wear_cost_per_hour >= 0),
        note TEXT,
        active INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL,
        UNIQUE(workspace_id, brand, model)
      );
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_machine_cost_match '
      'ON studio_machine_cost_configs(workspace_id, active, brand, model);',
    );
  }

  Future<void> _createStudioTables(Migrator m) async {
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_workspaces(
        id TEXT PRIMARY KEY,
        remote_id TEXT,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    await _addColumnIfMissing(m, 'studio_workspaces', 'remote_id', 'TEXT');
    await _addColumnIfMissing(m, 'studio_workspaces', 'account_scope', 'TEXT');
    await m.database.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_studio_workspaces_remote_id '
      'ON studio_workspaces(remote_id) WHERE remote_id IS NOT NULL;',
    );
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_members(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        display_name TEXT NOT NULL,
        email TEXT,
        role TEXT NOT NULL CHECK(role IN ('owner', 'admin', 'operator')),
        active INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL
      );
    ''');
    await _addColumnIfMissing(m, 'studio_members', 'login_name', 'TEXT');
    await _addColumnIfMissing(m, 'studio_members', 'employee_no', 'TEXT');
    await _addColumnIfMissing(m, 'studio_members', 'phone', 'TEXT');
    await _addColumnIfMissing(m, 'studio_members', 'recovery_email', 'TEXT');
    await _addColumnIfMissing(
      m,
      'studio_members',
      'account_status',
      "TEXT NOT NULL DEFAULT 'active'",
    );
    await _addColumnIfMissing(
      m,
      'studio_members',
      'primary_role_code',
      "TEXT NOT NULL DEFAULT 'member'",
    );
    await _addColumnIfMissing(
      m,
      'studio_members',
      'must_change_password',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(m, 'studio_members', 'last_login_at', 'INTEGER');
    await _addColumnIfMissing(m, 'studio_members', 'deactivated_at', 'INTEGER');
    await _addColumnIfMissing(
      m,
      'studio_members',
      'role_codes_json',
      "TEXT NOT NULL DEFAULT '[]'",
    );
    await m.database.customStatement(
      "UPDATE studio_members SET primary_role_code = 'owner', "
      "account_status = 'active' WHERE role = 'owner'",
    );
    await m.database.customStatement(
      "UPDATE studio_members SET role_codes_json = '[\"owner\"]' "
      "WHERE role = 'owner' AND role_codes_json = '[]'",
    );
    await m.database.customStatement(
      "UPDATE studio_members SET role = 'operator', primary_role_code = 'member' "
      "WHERE role != 'owner'",
    );
    await m.database.customStatement(
      "UPDATE studio_members SET role_codes_json = '[\"member\"]' "
      "WHERE role != 'owner'",
    );
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_activity_events(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        actor_member_id TEXT,
        actor_display_name TEXT NOT NULL,
        actor_identity TEXT NOT NULL CHECK(actor_identity IN ('administrator', 'member')),
        action_code TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        summary TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_activity_entity '
      'ON studio_activity_events(workspace_id, entity_type, entity_id, created_at DESC);',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_activity_actor '
      'ON studio_activity_events(workspace_id, actor_member_id, created_at DESC);',
    );
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_customers(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        contact_name TEXT,
        phone TEXT,
        email TEXT,
        note TEXT,
        archived INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_orders(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        customer_id TEXT REFERENCES studio_customers(id) ON DELETE SET NULL,
        order_no TEXT NOT NULL,
        title TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('draft', 'confirmed', 'production', 'completed', 'delivered', 'cancelled')),
        due_at INTEGER,
        total_price REAL NOT NULL DEFAULT 0,
        note TEXT,
        public_note TEXT,
        portal_video_enabled INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE(workspace_id, order_no)
      );
    ''');
    await _addColumnIfMissing(m, 'studio_orders', 'public_note', 'TEXT');
    await _addColumnIfMissing(
      m,
      'studio_orders',
      'portal_video_enabled',
      'INTEGER NOT NULL DEFAULT 1',
    );
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_work_orders(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        order_id TEXT NOT NULL REFERENCES studio_orders(id) ON DELETE CASCADE,
        scheduler_task_id INTEGER REFERENCES scheduler_tasks(id) ON DELETE SET NULL,
        title TEXT NOT NULL,
        quantity INTEGER NOT NULL DEFAULT 1 CHECK(quantity > 0),
        completed_quantity INTEGER NOT NULL DEFAULT 0 CHECK(completed_quantity >= 0),
        status TEXT NOT NULL CHECK(status IN ('queued', 'assigned', 'printing', 'paused', 'completed', 'failed', 'cancelled')),
        assigned_member_id TEXT REFERENCES studio_members(id) ON DELETE SET NULL,
        printer_id INTEGER REFERENCES printers(id) ON DELETE SET NULL,
        estimated_seconds INTEGER,
        material_cost_snapshot REAL NOT NULL DEFAULT 0,
        quoted_price_snapshot REAL NOT NULL DEFAULT 0,
        note TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_production_packages(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        order_id TEXT NOT NULL REFERENCES studio_orders(id) ON DELETE CASCADE,
        source_name TEXT NOT NULL,
        local_path TEXT,
        artifact_sha256 TEXT,
        artifact_kind TEXT NOT NULL,
        slicer_name TEXT,
        slicer_version TEXT,
        target_model TEXT,
        nozzle_diameter REAL,
        created_at INTEGER NOT NULL
      );
    ''');
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_production_plates(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        order_id TEXT NOT NULL REFERENCES studio_orders(id) ON DELETE CASCADE,
        package_id TEXT NOT NULL REFERENCES studio_production_packages(id) ON DELETE CASCADE,
        plate_index INTEGER NOT NULL,
        name TEXT NOT NULL,
        required_runs INTEGER NOT NULL CHECK(required_runs > 0),
        estimated_seconds INTEGER NOT NULL DEFAULT 0,
        estimated_grams REAL NOT NULL DEFAULT 0,
        slice_status TEXT NOT NULL DEFAULT 'pending',
        slice_artifact_path TEXT,
        slice_artifact_sha256 TEXT,
        slice_target_model TEXT,
        slice_nozzle_diameter REAL,
        auto_eject_enabled INTEGER,
        thumbnail_base64 TEXT,
        total_layers INTEGER NOT NULL DEFAULT 0,
        tool_change_count INTEGER NOT NULL DEFAULT 0,
        filament_usage_json TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL,
        UNIQUE(package_id, plate_index)
      );
    ''');
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'slice_status',
      "TEXT NOT NULL DEFAULT 'pending'",
    );
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'slice_artifact_path',
      'TEXT',
    );
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'slice_artifact_sha256',
      'TEXT',
    );
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'slice_target_model',
      'TEXT',
    );
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'slice_nozzle_diameter',
      'REAL',
    );
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'auto_eject_enabled',
      'INTEGER',
    );
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'thumbnail_base64',
      'TEXT',
    );
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'total_layers',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'tool_change_count',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'filament_usage_json',
      "TEXT NOT NULL DEFAULT '[]'",
    );
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_order_items(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        order_id TEXT NOT NULL REFERENCES studio_orders(id) ON DELETE CASCADE,
        package_id TEXT NOT NULL REFERENCES studio_production_packages(id) ON DELETE CASCADE,
        plate_id TEXT NOT NULL REFERENCES studio_production_plates(id) ON DELETE CASCADE,
        source_key TEXT NOT NULL,
        name TEXT NOT NULL,
        per_run_quantity INTEGER NOT NULL CHECK(per_run_quantity > 0),
        required_quantity INTEGER NOT NULL CHECK(required_quantity > 0),
        created_at INTEGER NOT NULL
      );
    ''');
    await _addColumnIfMissing(
      m,
      'studio_work_orders',
      'production_plate_id',
      'TEXT REFERENCES studio_production_plates(id) ON DELETE SET NULL',
    );
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_work_order_materials(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        work_order_id TEXT NOT NULL REFERENCES studio_work_orders(id) ON DELETE CASCADE,
        production_plate_id TEXT NOT NULL REFERENCES studio_production_plates(id) ON DELETE CASCADE,
        tool_index INTEGER NOT NULL,
        material_type TEXT,
        color_hex TEXT,
        sku TEXT,
        estimated_grams REAL NOT NULL DEFAULT 0,
        consumable_id INTEGER REFERENCES consumables(id) ON DELETE SET NULL,
        printer_channel_id INTEGER REFERENCES printer_channels(id) ON DELETE SET NULL,
        reserved_grams REAL NOT NULL DEFAULT 0,
        consumed_grams REAL NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'unallocated'
          CHECK(status IN ('unallocated', 'reserved', 'settled', 'released')),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        settled_at INTEGER,
        UNIQUE(work_order_id, tool_index)
      );
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_work_order_materials_work_order '
      'ON studio_work_order_materials(work_order_id, tool_index);',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_work_order_materials_consumable '
      'ON studio_work_order_materials(consumable_id, status);',
    );
    await _addColumnIfMissing(
      m,
      'studio_work_order_materials',
      'printer_channel_id',
      'INTEGER REFERENCES printer_channels(id) ON DELETE SET NULL',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_work_order_materials_channel '
      'ON studio_work_order_materials(printer_channel_id, status);',
    );
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_print_attempts(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        work_order_id TEXT NOT NULL REFERENCES studio_work_orders(id) ON DELETE CASCADE,
        print_queue_id INTEGER REFERENCES print_queue(id) ON DELETE SET NULL,
        attempt_no INTEGER NOT NULL CHECK(attempt_no > 0),
        printer_serial TEXT,
        outcome TEXT NOT NULL CHECK(outcome IN (
          'completed', 'failed', 'stopped', 'quality_rejected', 'accounting_review'
        )),
        progress_percent INTEGER,
        consumed_grams REAL NOT NULL DEFAULT 0,
        material_cost REAL NOT NULL DEFAULT 0,
        failure_reason TEXT,
        error_code TEXT,
        started_at INTEGER,
        ended_at INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE(print_queue_id, attempt_no)
      );
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_print_attempts_work_order '
      'ON studio_print_attempts(work_order_id, ended_at DESC);',
    );
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_quotes(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        customer_id TEXT REFERENCES studio_customers(id) ON DELETE SET NULL,
        order_id TEXT REFERENCES studio_orders(id) ON DELETE SET NULL,
        cost_config_id INTEGER REFERENCES filament_cost_configs(id) ON DELETE SET NULL,
        quote_no TEXT NOT NULL,
        title TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('draft', 'sent', 'accepted', 'rejected', 'expired')),
        material_label TEXT NOT NULL,
        estimated_grams REAL NOT NULL DEFAULT 0,
        material_cost_per_kg_snapshot REAL NOT NULL DEFAULT 0,
        machine_hours REAL NOT NULL DEFAULT 0,
        machine_rate_per_hour REAL NOT NULL DEFAULT 0,
        labor_hours REAL NOT NULL DEFAULT 0,
        labor_rate_per_hour REAL NOT NULL DEFAULT 0,
        electricity_cost REAL NOT NULL DEFAULT 0,
        packaging_cost REAL NOT NULL DEFAULT 0,
        risk_percent REAL NOT NULL DEFAULT 0,
        markup_percent REAL NOT NULL DEFAULT 0,
        total_cost REAL NOT NULL DEFAULT 0,
        quoted_price REAL NOT NULL DEFAULT 0,
        note TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE(workspace_id, quote_no)
      );
    ''');
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_inventory_events(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        consumable_id INTEGER NOT NULL REFERENCES consumables(id) ON DELETE CASCADE,
        event_type TEXT NOT NULL,
        delta_grams REAL NOT NULL,
        reason TEXT NOT NULL,
        member_id TEXT REFERENCES studio_members(id) ON DELETE SET NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_share_links(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        order_id TEXT NOT NULL REFERENCES studio_orders(id) ON DELETE CASCADE,
        token_preview TEXT NOT NULL,
        public_url TEXT,
        active INTEGER NOT NULL DEFAULT 1,
        expires_at INTEGER,
        password_required INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL
      );
    ''');
    await _addColumnIfMissing(
      m,
      'studio_share_links',
      'password_required',
      'INTEGER NOT NULL DEFAULT 1',
    );
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_inventory_batches(
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        batch_no TEXT NOT NULL,
        supplier TEXT,
        received_at INTEGER NOT NULL,
        roll_count INTEGER NOT NULL CHECK(roll_count > 0),
        total_grams REAL NOT NULL CHECK(total_grams > 0),
        note TEXT,
        member_id TEXT REFERENCES studio_members(id) ON DELETE SET NULL,
        created_at INTEGER NOT NULL,
        UNIQUE(workspace_id, batch_no)
      );
    ''');
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_inventory_batch_items(
        id TEXT PRIMARY KEY,
        batch_id TEXT NOT NULL REFERENCES studio_inventory_batches(id) ON DELETE CASCADE,
        consumable_id INTEGER NOT NULL UNIQUE REFERENCES consumables(id) ON DELETE CASCADE,
        roll_count INTEGER NOT NULL DEFAULT 1,
        grams_per_roll REAL NOT NULL DEFAULT 1000,
        unit_cost REAL NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
    ''');
    await _addColumnIfMissing(
      m,
      'studio_inventory_batch_items',
      'roll_count',
      'INTEGER NOT NULL DEFAULT 1',
    );
    await _addColumnIfMissing(
      m,
      'studio_inventory_batch_items',
      'grams_per_roll',
      'REAL NOT NULL DEFAULT 1000',
    );
    await _addColumnIfMissing(
      m,
      'studio_inventory_batches',
      'updated_at',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      m,
      'studio_inventory_batch_items',
      'updated_at',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      m,
      'studio_production_plates',
      'updated_at',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await m.database.customStatement('''
      CREATE TABLE IF NOT EXISTS studio_sync_tombstones(
        workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        deleted_at INTEGER NOT NULL,
        PRIMARY KEY(workspace_id, entity_type, entity_id)
      );
    ''');
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_orders_status ON studio_orders(workspace_id, status, due_at);',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_work_orders_status ON studio_work_orders(workspace_id, status, created_at);',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_production_packages_order ON studio_production_packages(workspace_id, order_id, created_at);',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_production_plates_order ON studio_production_plates(workspace_id, order_id, plate_index);',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_order_items_plate ON studio_order_items(workspace_id, plate_id);',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_inventory_events_time ON studio_inventory_events(workspace_id, created_at DESC);',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_studio_inventory_batches_time ON studio_inventory_batches(workspace_id, received_at DESC);',
    );
  }

  Future<void> _createStudioActivityGuards(Migrator m) async {
    if (!await _tableExists(m, 'studio_activity_events')) return;
    await m.database.customStatement('''
      CREATE TRIGGER IF NOT EXISTS studio_activity_events_no_update
      BEFORE UPDATE ON studio_activity_events
      BEGIN
        SELECT RAISE(ABORT, 'studio activity history is immutable');
      END;
    ''');
    await m.database.customStatement('''
      CREATE TRIGGER IF NOT EXISTS studio_activity_events_no_delete
      BEFORE DELETE ON studio_activity_events
      BEGIN
        SELECT RAISE(ABORT, 'studio activity history is immutable');
      END;
    ''');
  }

  Future<void> _consolidateLegacyFarmInventory(Migrator m) async {
    if (!await _tableExists(m, 'consumables') ||
        !await _tableExists(m, 'studio_inventory_batch_items')) {
      return;
    }
    final groups = await m.database.customSelect('''
      SELECT farm_workspace_id, manufacturer, model, material_type, color_hex,
             COALESCE(color_name, '') AS color_name_key,
             COALESCE(batch_no, '') AS batch_no_key,
             COALESCE(note, '') AS note_key,
             GROUP_CONCAT(id) AS ids, COUNT(*) AS item_count
      FROM consumables
      WHERE inventory_scope = 'farm'
        AND farm_workspace_id IS NOT NULL
        AND (tray_uuid IS NULL OR trim(tray_uuid) = '')
      GROUP BY farm_workspace_id, manufacturer, model, material_type,
               color_hex, color_name_key, batch_no_key, note_key
      HAVING COUNT(*) > 1
    ''').get();
    for (final group in groups) {
      final ids = group
          .read<String>('ids')
          .split(',')
          .map(int.tryParse)
          .whereType<int>()
          .toList();
      if (ids.length < 2) continue;
      final placeholders = List.filled(ids.length, '?').join(',');
      final references = await m.database
          .customSelect(
            'SELECT '
            '(SELECT COUNT(*) FROM printer_channels WHERE consumable_id IN ($placeholders)) + '
            '(SELECT COUNT(*) FROM studio_work_order_materials WHERE consumable_id IN ($placeholders)) AS refs',
            variables: [
              for (final id in ids) Variable(id),
              for (final id in ids) Variable(id),
            ],
          )
          .getSingle();
      if (references.read<int>('refs') > 0) continue;

      final rows = await m.database
          .customSelect(
            'SELECT id, total_grams, remaining_grams FROM consumables '
            'WHERE id IN ($placeholders) ORDER BY id',
            variables: [for (final id in ids) Variable(id)],
          )
          .get();
      if (rows.length < 2) continue;
      final keeperId = rows.first.read<int>('id');
      final redundantIds = rows
          .skip(1)
          .map((row) => row.read<int>('id'))
          .toList(growable: false);
      final totalGrams = rows.fold<double>(
        0,
        (sum, row) => sum + row.read<double>('total_grams'),
      );
      final remainingGrams = rows.fold<double>(
        0,
        (sum, row) => sum + row.read<double>('remaining_grams'),
      );

      final batchRows = await m.database
          .customSelect(
            'SELECT id, batch_id, consumable_id, roll_count, grams_per_roll '
            'FROM studio_inventory_batch_items WHERE consumable_id IN ($placeholders) '
            'ORDER BY CASE WHEN consumable_id = ? THEN 0 ELSE 1 END, created_at',
            variables: [for (final id in ids) Variable(id), Variable(keeperId)],
          )
          .get();
      if (batchRows.isNotEmpty) {
        final keeperBatchItem = batchRows.first;
        final rollCount = batchRows.fold<int>(
          0,
          (sum, row) => sum + row.read<int>('roll_count'),
        );
        await m.database.customUpdate(
          'UPDATE studio_inventory_batch_items SET consumable_id = ?, '
          'roll_count = ?, grams_per_roll = ? WHERE id = ?',
          variables: [
            Variable(keeperId),
            Variable(rollCount),
            Variable(keeperBatchItem.read<double>('grams_per_roll')),
            Variable(keeperBatchItem.read<String>('id')),
          ],
        );
        final redundantBatchItems = batchRows
            .skip(1)
            .map((row) => row.read<String>('id'))
            .toList(growable: false);
        for (final id in redundantBatchItems) {
          await m.database.customUpdate(
            'DELETE FROM studio_inventory_batch_items WHERE id = ?',
            variables: [Variable(id)],
          );
        }
      }
      if (await _tableExists(m, 'studio_inventory_events')) {
        await m.database.customUpdate(
          'UPDATE studio_inventory_events SET consumable_id = ? '
          'WHERE consumable_id IN (${List.filled(redundantIds.length, '?').join(',')})',
          variables: [
            Variable(keeperId),
            for (final id in redundantIds) Variable(id),
          ],
        );
      }
      await m.database.customUpdate(
        'UPDATE consumables SET total_grams = ?, remaining_grams = ?, '
        'updated_at = ? WHERE id = ?',
        variables: [
          Variable(totalGrams),
          Variable(remainingGrams),
          Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable(keeperId),
        ],
        updates: {consumables},
      );
      for (final id in redundantIds) {
        await m.database.customUpdate(
          'DELETE FROM consumables WHERE id = ?',
          variables: [Variable(id)],
          updates: {consumables},
        );
      }
    }
  }

  Future<void> _repairFarmInventoryBatchLinks(Migrator m) async {
    if (!await _tableExists(m, 'consumables') ||
        !await _tableExists(m, 'studio_inventory_batches') ||
        !await _tableExists(m, 'studio_inventory_batch_items')) {
      return;
    }

    // Older farm builds could leave the batch header while losing all item
    // links. Rebuild those links from the stable workspace + batch number
    // carried by each inventory row.
    await m.database.customUpdate('''
      INSERT OR IGNORE INTO studio_inventory_batch_items(
        id, batch_id, consumable_id, roll_count, grams_per_roll,
        unit_cost, created_at, updated_at
      )
      SELECT
        'repair-' || batch.id || '-' || consumable.id,
        batch.id,
        consumable.id,
        MAX(1, CAST(ROUND(consumable.total_grams / 1000.0) AS INTEGER)),
        1000,
        0,
        batch.created_at,
        batch.created_at
      FROM studio_inventory_batches batch
      JOIN consumables consumable
        ON consumable.farm_workspace_id = batch.workspace_id
       AND consumable.inventory_scope = 'farm'
       AND trim(COALESCE(consumable.batch_no, '')) = trim(batch.batch_no)
      WHERE trim(batch.batch_no) != ''
    ''');

    // Roll count is a physical batch fact. For farm stock it must always be
    // derived from the original total grams at 1000g per roll, never from the
    // number of legacy database rows.
    await m.database.customUpdate('''
      UPDATE studio_inventory_batch_items
      SET roll_count = (
            SELECT MAX(
              1,
              CAST(ROUND(consumable.total_grams / 1000.0) AS INTEGER)
            )
            FROM consumables consumable
            WHERE consumable.id = studio_inventory_batch_items.consumable_id
          ),
          grams_per_roll = 1000
      WHERE EXISTS(
        SELECT 1 FROM consumables consumable
        WHERE consumable.id = studio_inventory_batch_items.consumable_id
          AND consumable.inventory_scope = 'farm'
      )
    ''');

    await m.database.customUpdate('''
      UPDATE studio_inventory_batches
      SET roll_count = (
            SELECT SUM(item.roll_count)
            FROM studio_inventory_batch_items item
            WHERE item.batch_id = studio_inventory_batches.id
          ),
          total_grams = (
            SELECT SUM(consumable.total_grams)
            FROM studio_inventory_batch_items item
            JOIN consumables consumable ON consumable.id = item.consumable_id
            WHERE item.batch_id = studio_inventory_batches.id
          )
      WHERE EXISTS(
        SELECT 1 FROM studio_inventory_batch_items item
        WHERE item.batch_id = studio_inventory_batches.id
      )
    ''');
  }
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final documents = await getApplicationDocumentsDirectory();
    // Documents is shared by both installers. Keep each product in its own
    // folder so a personal install can never open or migrate farm data.
    final dir = Directory(p.join(documents.path, AppVariant.dataNamespace));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'consumable_tracker.sqlite'));
    // Preserve an existing personal installation created before product
    // separation. Farm installs intentionally start with a fresh database.
    if (AppVariant.isPersonal && !await file.exists()) {
      final legacy = File(p.join(documents.path, 'consumable_tracker.sqlite'));
      await importLegacyDatabaseIfNeeded(legacy: legacy, target: file);
    }
    return NativeDatabase.createInBackground(file);
  });
}

/// 内部辅助：[_dedupeTrayUuidConflicts] 用的行数据。
class _ConsumableTrayRow {
  final int id;
  final String trayUuid;
  final int? rfidSyncedAt;
  final double remainingGrams;
  const _ConsumableTrayRow({
    required this.id,
    required this.trayUuid,
    required this.rfidSyncedAt,
    required this.remainingGrams,
  });
}
