import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/cluster_planning_service.dart';
import '../core/services/printer_fleet_connection_manager.dart';
import '../data/database/database.dart';
import '../data/database/daos/print_queue_dao.dart';
import '../data/database/daos/printer_dao.dart';
import '../data/database/daos/studio_dao.dart';
import '../data/database/models/print_queue_item.dart';
import '../data/database/models/scheduler_models.dart';
import '../data/external/printer/bambu_printer_models.dart';
import '../data/prefs/app_prefs.dart';
import 'consumable_provider.dart';
import 'database_provider.dart';
import 'print_queue_provider.dart';
import 'printer_provider.dart';
import 'scheduler_provider.dart';
import 'studio_provider.dart';

export '../core/services/cluster_planning_service.dart';

final clusterPlanningServiceProvider = Provider<ClusterPlanningService>(
  (ref) => ClusterPlanningService(),
);

/// Observe database queue changes without constructing PrintQueueNotifier:
/// constructing/activating an executor here would turn a preview into printing.
final clusterQueueRevisionProvider = StreamProvider.autoDispose<int>((
  ref,
) async* {
  final dao = ref.watch(printQueueDaoProvider);
  var revision = 0;
  yield revision;
  await for (final _ in dao.onChange) {
    yield ++revision;
  }
});

/// Personal materials stay account-scoped; farm materials stay workspace-scoped.
/// The fleet may be visible across accounts, but a foreign material is never an
/// eligible source just because it is attached to a visible printer.
final clusterConsumablesProvider = FutureProvider<List<Consumable>>((ref) {
  return ref.watch(studioModeEnabledProvider)
      ? ref.watch(farmConsumablesProvider.future)
      : ref.watch(consumablesProvider.future);
});

/// Fully read-only candidate projection. No model result, reservation, queue
/// write, printer command or startup of a printing executor happens here.
final clusterPlanningSnapshotProvider =
    FutureProvider.autoDispose<ClusterPlanningSnapshot>((ref) async {
      final service = ref.watch(clusterPlanningServiceProvider);
      final studioFuture = ref.watch(studioSnapshotProvider.future);
      final printersFuture = ref.watch(printersWithChannelsProvider.future);
      final stockFuture = ref.watch(clusterConsumablesProvider.future);
      final fleet = {
        for (final item in ref.watch(fleetPrinterStatesProvider))
          item.serial: item,
      };
      final config = ref.watch(schedulingConfigProvider);
      final farmMode = ref.watch(studioModeEnabledProvider);
      final studioDao = ref.watch(studioDaoProvider);
      final queueDao = ref.watch(printQueueDaoProvider);
      ref.watch(clusterQueueRevisionProvider);
      // No new MQTT event is needed to expire an old status. It also refreshes
      // reservations created by legacy workflows with independent change buses.
      final timer = Timer(const Duration(seconds: 30), ref.invalidateSelf);
      ref.onDispose(timer.cancel);

      final studio = await studioFuture;
      final printers = await printersFuture;
      final stock = await stockFuture;
      return _buildClusterSnapshot(
        service: service,
        studio: studio,
        printers: printers,
        stock: stock,
        fleet: fleet,
        studioDao: studioDao,
        queueDao: queueDao,
        farmMode: farmMode,
        config: config,
      );
    });

typedef ClusterDispatchValidator =
    Future<String?> Function(
      String plateId,
      int printerId,
      int runs,
      Map<int, int> channelByTool,
      String expectedArtifactSha256,
    );

/// Called after the operator confirms actual mapping, immediately before the
/// existing dispatch transaction. It only refreshes facts and checks them;
/// it never reserves material, queues a job or constructs a print executor.
final clusterDispatchValidatorProvider = Provider<ClusterDispatchValidator>((
  ref,
) {
  return (
    plateId,
    printerId,
    runs,
    channelByTool,
    expectedArtifactSha256,
  ) async {
    if (runs <= 0) return '打印份数必须大于零';
    final mapping = Map<int, int>.unmodifiable(channelByTool);
    final service = ref.read(clusterPlanningServiceProvider);
    final studioDao = ref.read(studioDaoProvider);
    final printerDao = ref.read(printerDaoProvider);
    final stockDao = ref.read(consumableDaoProvider);
    final queueDao = ref.read(printQueueDaoProvider);
    final farmMode = ref.read(studioModeEnabledProvider);
    final owner = ref.read(personalInventoryAccountScopeProvider).ownerAccount;
    final config = ref.read(schedulingConfigProvider);
    try {
      final selected = await printerDao.getByIdWithChannels(printerId);
      final serial = selected?.serial;
      if (serial == null || serial.isEmpty) return '所选设备已移除或没有有效序列号';
      final refreshedState = await ref
          .read(printerFleetConnectionManagerProvider.notifier)
          .ensureFreshStatus(serial, config);
      if (refreshedState == null) return '无法刷新所选设备状态，请稍后重试';
      // Read source tables after telemetry has synchronized physical channels.
      final studio = await studioDao.getDefaultSnapshot();
      final printers = await printerDao.getAllPrintersWithChannels();
      final stock = farmMode
          ? await stockDao.getFarm(studio.workspace.id)
          : await stockDao.getPersonalForOwnerAccount(owner);
      final fleet = {
        for (final item in ref.read(fleetPrinterStatesProvider))
          item.serial: item,
      };
      final snapshot = await _buildClusterSnapshot(
        service: service,
        studio: studio,
        printers: printers,
        stock: stock,
        fleet: fleet,
        studioDao: studioDao,
        queueDao: queueDao,
        farmMode: farmMode,
        config: config,
        fixedPlateId: plateId,
        fixedChannelByTool: mapping,
      );
      if (!identical(studioDao, ref.read(studioDaoProvider)) ||
          farmMode != ref.read(studioModeEnabledProvider) ||
          owner !=
              ref.read(personalInventoryAccountScopeProvider).ownerAccount) {
        return '账号或工作区已变化，请重新打开本盘';
      }
      return validateClusterSnapshotSelection(
        snapshot: snapshot,
        plateId: plateId,
        printerId: printerId,
        runs: runs,
        channelByTool: mapping,
        expectedArtifactSha256: expectedArtifactSha256,
      );
    } catch (_) {
      return '无法完成最新设备、队列和耗材检查，请刷新后重试';
    }
  };
});

Future<ClusterPlanningSnapshot> _buildClusterSnapshot({
  required ClusterPlanningService service,
  required StudioSnapshot studio,
  required List<PrinterWithChannels> printers,
  required List<Consumable> stock,
  required Map<String, FleetPrinterState> fleet,
  required StudioDao studioDao,
  required PrintQueueDao queueDao,
  required bool farmMode,
  required SchedulingConfig config,
  String? fixedPlateId,
  Map<int, int>? fixedChannelByTool,
}) async {
  final stockById = {for (final item in stock) item.id: item};
  final availabilityById = <int, StudioConsumableAvailability>{};
  final channels = <int, double>{};
  for (final printer in printers) {
    for (final slot in printer.channels) {
      final consumable = slot.consumable;
      if (consumable == null || !stockById.containsKey(consumable.id)) continue;
      final physical = await studioDao.getPrinterChannelAvailableGrams(
        slot.channel.id,
      );
      final aggregate = availabilityById[consumable.id] ??= await studioDao
          .getConsumableAvailability(
            consumable.id,
            workspaceId: studio.workspace.id,
          );
      // Physical channels already subtract Studio reservations. Legacy jobs
      // lack physical farm-roll IDs: subtract their claims conservatively too.
      final free = math.max(
        0.0,
        physical -
            aggregate.schedulerReservedGrams -
            aggregate.printTaskReservedGrams,
      );
      channels[slot.channel.id] = farmMode
          ? free
          : math.min(free, aggregate.availableGrams);
    }
  }
  final counts = <String, int>{};
  final seconds = <String, int?>{};
  for (final printer in printers) {
    final serial = printer.serial;
    if (serial == null || serial.isEmpty || counts.containsKey(serial)) {
      continue;
    }
    final queue = (await queueDao.getByPrinter(
      serial,
    )).where((item) => !item.status.isTerminal).toList(growable: false);
    counts[serial] = queue.length;
    seconds[serial] = clusterQueueDelaySeconds(
      queue: queue,
      workOrders: studio.workOrders,
      state: fleet[serial],
    );
  }
  return service.build(
    studio: studio,
    printers: printers,
    fleet: fleet,
    allowedConsumableIds: stockById.keys.toSet(),
    channelAvailableGrams: channels,
    activeQueueCounts: counts,
    farmInventory: farmMode,
    availableAfterSeconds: seconds,
    config: config,
    fixedPlateId: fixedPlateId,
    fixedChannelByTool: fixedChannelByTool,
  );
}

/// Earliest machine time only, excluding manual removal and queue-preparation
/// delays. Unknown durations remain null, never the misleading value zero.
int? clusterQueueDelaySeconds({
  required List<PrintQueueItem> queue,
  required List<StudioWorkOrder> workOrders,
  required FleetPrinterState? state,
}) {
  final status = state?.lastStatus;
  if (status == null || status.gcodeState == null) return null;
  if (queue.any((item) => item.status == PrintQueueStatus.waitingRemoval)) {
    return null;
  }
  // A printer reports remaining time for one physical job only. Conflicting
  // active queue rows cannot all be covered by that single telemetry reading.
  if (queue.where((item) => item.status == PrintQueueStatus.printing).length >
      1) {
    return null;
  }
  final stateIdle =
      status.gcodeState == BambuGcodeState.idle ||
      status.gcodeState == BambuGcodeState.finish;
  final stateRunning =
      status.gcodeState == BambuGcodeState.running ||
      status.gcodeState == BambuGcodeState.prepare ||
      status.gcodeState == BambuGcodeState.init;
  if (!stateIdle && !stateRunning) return null;
  var result = 0;
  if (stateRunning) {
    final remainingMinutes = status.mcRemainingTime;
    if (remainingMinutes == null || remainingMinutes < 0) return null;
    result = remainingMinutes * 60;
  }
  for (final item in queue) {
    if (item.status == PrintQueueStatus.printing) {
      if (!stateRunning) return null;
      continue;
    }
    if (item.status != PrintQueueStatus.queued) continue;
    final work = workOrders
        .where((work) => work.id == item.studioWorkOrderId)
        .firstOrNull;
    final duration = work?.estimatedSeconds;
    if (duration == null || duration <= 0) return null;
    result += duration;
  }
  return result;
}
