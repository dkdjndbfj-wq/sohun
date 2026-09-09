import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/database.dart';
import '../data/database/daos/ams_change_event_dao.dart';
import '../data/database/daos/filament_cost_config_dao.dart';
import '../data/database/daos/print_task_consumable_dao.dart';
import '../data/database/daos/print_task_dao.dart';
import '../data/database/daos/printer_dao.dart';
import '../data/database/daos/studio_quote_config_dao.dart';
import '../data/database/daos/telemetry_event_dao.dart';
import '../data/database/daos/consumable_twin_dao.dart';
import '../data/database/models/consumable_twin_event.dart';
import '../data/models/material_health_profile.dart';
import '../data/database/daos/usage_log_dao.dart';
import '../mobile/mobile_rfid_tag_repository.dart';

/// 数据库单例。App 全局共享一份，dispose 时关闭连接。
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final consumableDaoProvider = Provider<ConsumableDao>(
  (ref) => ref.watch(databaseProvider).consumableDao,
);

final printerDaoProvider = Provider<PrinterDao>(
  (ref) => ref.watch(databaseProvider).printerDao,
);

final usageLogDaoProvider = Provider<UsageLogDao>(
  (ref) => ref.watch(databaseProvider).usageLogDao,
);

/// Local append-only history for mobile CUID/FUID/NTAG operations.
///
/// Inventory remains the shared source of truth; this provider only keeps
/// enough safe metadata to reuse and audit physical tags without storing raw
/// card blocks or authentication keys.
final mobileRfidTagRepositoryProvider = Provider<MobileRfidTagRepository>(
  (ref) {
    final repository = MobileRfidTagRepository(ref.watch(databaseProvider));
    ref.onDispose(repository.dispose);
    return repository;
  },
);

/// PrintTaskDao 单例。
/// 因 PrintTasks 表不走 drift 代码生成，不通过 @DriftDatabase 的 daos 注册，
/// 这里手动实例化。dispose 时释放内部 StreamController。
final printTaskDaoProvider = Provider<PrintTaskDao>((ref) {
  final db = ref.watch(databaseProvider);
  final dao = PrintTaskDao(db);
  ref.onDispose(dao.dispose);
  return dao;
});

/// FilamentCostConfigDao 单例（耗材成本配置，raw SQL DAO）。
/// 同样不走 drift 代码生成，手动实例化。
final filamentCostConfigDaoProvider = Provider<FilamentCostConfigDao>((ref) {
  final db = ref.watch(databaseProvider);
  final dao = FilamentCostConfigDao(db);
  ref.onDispose(dao.dispose);
  return dao;
});

final studioQuoteConfigDaoProvider = Provider<StudioQuoteConfigDao>((ref) {
  final dao = StudioQuoteConfigDao(ref.watch(databaseProvider));
  ref.onDispose(dao.dispose);
  return dao;
});

/// PrintTaskConsumableDao 单例（打印任务↔耗材卷关联，raw SQL DAO）。
/// 用于实时扣减+完成修正+成本结算。
final printTaskConsumableDaoProvider = Provider<PrintTaskConsumableDao>((ref) {
  final db = ref.watch(databaseProvider);
  final dao = PrintTaskConsumableDao(db);
  ref.onDispose(dao.dispose);
  return dao;
});

/// AmsChangeEventDao 单例（AMS 换料事件，raw SQL DAO）。
/// 用于监听 trayNow 变化记录换料事件，提升多色任务成本精度。
final amsChangeEventDaoProvider = Provider<AmsChangeEventDao>((ref) {
  final db = ref.watch(databaseProvider);
  final dao = AmsChangeEventDao(db);
  ref.onDispose(dao.dispose);
  return dao;
});

/// TelemetryEventDao 单例（遥测事件队列，raw SQL DAO）。
/// 配合 TelemetryService：采集 → 内存聚合 → 落库 → 上传社区服务器。
final telemetryEventDaoProvider = Provider<TelemetryEventDao>((ref) {
  final db = ref.watch(databaseProvider);
  final dao = TelemetryEventDao(db);
  ref.onDispose(dao.dispose);
  return dao;
});

/// 耗材数字孪生事件账本 DAO。所有耗材生命周期轨迹统一从此入口读取。
final consumableTwinDaoProvider = Provider<ConsumableTwinDao>((ref) {
  final dao = ConsumableTwinDao(ref.watch(databaseProvider));
  ref.onDispose(dao.dispose);
  return dao;
});

/// 某卷耗材的生命周期时间线，供库存详情和质量闭环页面复用。
final consumableTwinTimelineProvider =
    FutureProvider.autoDispose.family<List<ConsumableTwinEvent>, String>(
  (ref, trayUuid) {
    if (trayUuid.trim().isEmpty) return const [];
    return ref.watch(consumableTwinDaoProvider).getTimeline(trayUuid.trim());
  },
);

final materialHealthProfileProvider =
    FutureProvider.autoDispose.family<MaterialHealthProfile, String>(
  (ref, key) async {
    final uuids = key.split('|').where((value) => value.isNotEmpty);
    final lists = await Future.wait(
      uuids.map((uuid) => ref.read(consumableTwinDaoProvider).getTimeline(uuid)),
    );
    return MaterialHealthProfile.fromEvents(lists.expand((e) => e).toList());
  },
);
