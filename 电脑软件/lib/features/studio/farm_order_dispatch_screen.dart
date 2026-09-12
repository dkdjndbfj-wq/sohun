import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/services/printer_fleet_connection_manager.dart';
import '../../core/constants/personal_spool_policy.dart';
import '../../core/services/material_identity_service.dart';
import '../../core/services/printer_model_normalizer.dart';
import '../../core/services/slice_artifact_hash_service.dart';
import '../../core/services/studio_dispatch_service.dart';
import '../../core/utils/color_utils.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/database.dart';
import '../../data/database/models/print_queue_item.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../data/database/models/scheduler_models.dart';
import '../../data/database/models/studio_models.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_connector.dart';
import '../../data/external/slicer/bambu_studio_slicing_service.dart';
import '../../data/external/slicer/production_package_inspector.dart';
import '../../providers/farm_slice_intake_provider.dart';
import '../../providers/farm_slicing_preset_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/print_queue_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/slicer_provider.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_design.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_work_order_dialog.dart';
import 'farm_auto_eject_policy.dart';
import 'farm_lan_bulk_import_dialog.dart';
import 'farm_slicing_workflow.dart';

final _farmPlatePreviewProvider =
    FutureProvider.family<Uint8List?, _FarmPlatePreviewRequest>(
        (ref, request) async {
  final inspection = await ProductionPackageInspector.inspect(request.path);
  return inspection?.plates
      .where((item) => item.plateIndex == request.plateIndex)
      .firstOrNull
      ?.thumbnailBytes;
});

Future<void> cleanupUnusedFarmSliceArtifacts(WidgetRef ref) async {
  final snapshot = await ref.read(studioDaoProvider).getDefaultSnapshot();
  final protectedPaths = <String>{
    for (final plate in snapshot.productionPlates)
      if (plate.sliceArtifactPath?.trim().isNotEmpty == true)
        plate.sliceArtifactPath!.trim(),
    ...await ref.read(printQueueDaoProvider).getAllArtifactPaths(),
  };
  await BambuStudioSlicingService.cleanupUnreferencedArtifacts(
    protectedPaths: protectedPaths,
  );
}

class _FarmPlatePreviewRequest {
  const _FarmPlatePreviewRequest({
    required this.path,
    required this.plateIndex,
  });

  final String path;
  final int plateIndex;

  @override
  bool operator ==(Object other) =>
      other is _FarmPlatePreviewRequest &&
      other.path == path &&
      other.plateIndex == plateIndex;

  @override
  int get hashCode => Object.hash(path, plateIndex);
}

/// Returns only plates that contain production work.
///
/// New 3MF imports already discard empty build plates through
/// [ProductionPackageInspection.productionPlates]. This second guard keeps old
/// or remotely-synced empty plate rows out of dispatch as well.
List<StudioProductionPlate> farmDispatchablePlatesForOrder(
  StudioSnapshot snapshot,
  String orderId,
) {
  final plateIdsWithItems = snapshot.orderItems
      .where(
        (item) =>
            item.orderId == orderId &&
            item.perRunQuantity > 0 &&
            item.requiredQuantity > 0,
      )
      .map((item) => item.plateId)
      .toSet();
  final plateIdsWithWork = snapshot.workOrders
      .where((item) => item.orderId == orderId)
      .map((item) => item.productionPlateId)
      .whereType<String>()
      .toSet();
  return snapshot.productionPlates
      .where((plate) => plate.orderId == orderId)
      .where(
        (plate) =>
            plateIdsWithItems.contains(plate.id) ||
            plateIdsWithWork.contains(plate.id) ||
            plate.isSliced ||
            plate.sliceArtifactPath?.trim().isNotEmpty == true ||
            plate.estimatedSeconds > 0 ||
            plate.estimatedGrams > .01 ||
            plate.totalLayers > 0 ||
            plate.activeFilaments.isNotEmpty,
      )
      .toList(growable: false);
}

class FarmOrderDispatchScreen extends ConsumerWidget {
  const FarmOrderDispatchScreen({
    super.key,
    this.title = '生产调度',
    this.subtitle = '以订单为中心查看完成度、正在打印的机器和每一盘剩余产能。',
    this.headerActions = const [],
    this.showCreateOrderAction = true,
  });

  final String title;
  final String subtitle;
  final List<Widget> headerActions;
  final bool showCreateOrderAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final printers = ref.watch(printersWithChannelsProvider);
    final fleet = ref.watch(fleetPrinterStatesProvider);
    final stock = ref.watch(farmConsumablesProvider).valueOrNull ?? const [];
    final canAssign = ref.watch(currentFarmPermissionProvider('job.assign'));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FarmPageHeader(
            title: title,
            subtitle: subtitle,
            actions: [
              ...headerActions,
              if (showCreateOrderAction)
                FilledButton.icon(
                  onPressed: !canAssign
                      ? null
                      : () => showFarmWorkOrderDialog(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('新建订单'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: snapshot.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('订单调度读取失败：$error')),
              data: (studio) => printers.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(child: Text('打印机读取失败：$error')),
                data: (printerItems) => _FarmOrderDispatchBody(
                  studio: studio,
                  printers: printerItems,
                  fleet: fleet,
                  stock: stock,
                  canAssign: canAssign,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FarmOrderDispatchBody extends ConsumerWidget {
  const _FarmOrderDispatchBody({
    required this.studio,
    required this.printers,
    required this.fleet,
    required this.stock,
    required this.canAssign,
  });

  final StudioSnapshot studio;
  final List<PrinterWithChannels> printers;
  final List<FleetPrinterState> fleet;
  final List<Consumable> stock;
  final bool canAssign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queues = <String, List<PrintQueueItem>>{
      for (final printer in printers)
        if (printer.serial case final serial?)
          serial: ref.watch(printQueueProvider(serial)),
    };
    final activeOrders = studio.orders
        .where((order) =>
            order.status != StudioOrderStatus.cancelled &&
            order.status != StudioOrderStatus.delivered)
        .toList(growable: false);
    final pendingRuns = studio.workOrders
        .where((item) =>
            item.printerId == null &&
            item.status != StudioWorkOrderStatus.completed &&
            item.status != StudioWorkOrderStatus.cancelled)
        .fold<int>(0, (sum, item) => sum + item.quantity);
    final printing = queues.values
        .expand((items) => items)
        .where((item) => item.status == PrintQueueStatus.printing)
        .length;
    final waitingRemoval = queues.values
        .expand((items) => items)
        .where((item) => item.status == PrintQueueStatus.waitingRemoval)
        .length;
    return Column(
      children: [
        _DispatchSummary(
          values: [
            ('进行中订单', '${activeOrders.length}'),
            ('待分配运行', '$pendingRuns'),
            ('打印中设备', '$printing'),
            ('等待取件', '$waitingRemoval'),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: activeOrders.isEmpty
              ? const _DispatchEmpty()
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: activeOrders.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final order = activeOrders[index];
                    return _OrderDispatchRow(
                      order: order,
                      studio: studio,
                      printers: printers,
                      fleet: fleet,
                      queues: queues,
                      onOpen: () => _showOrderDispatchDialog(
                        context,
                        order.id,
                        canAssign: canAssign,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _DispatchSummary extends StatelessWidget {
  const _DispatchSummary({required this.values});
  final List<(String, String)> values;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          for (var index = 0; index < values.length; index++) ...[
            if (index > 0) const SizedBox(width: 10),
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(FarmPalette.radius),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Row(
                  children: [
                    Text(values[index].$2,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800)),
                    const SizedBox(width: 9),
                    Text(values[index].$1,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ],
        ],
      );
}

class _OrderDispatchRow extends StatelessWidget {
  const _OrderDispatchRow({
    required this.order,
    required this.studio,
    required this.printers,
    required this.fleet,
    required this.queues,
    required this.onOpen,
  });

  final StudioOrder order;
  final StudioSnapshot studio;
  final List<PrinterWithChannels> printers;
  final List<FleetPrinterState> fleet;
  final Map<String, List<PrintQueueItem>> queues;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final workOrders = studio.workOrders
        .where((item) => item.orderId == order.id)
        .toList(growable: false);
    final plates = farmDispatchablePlatesForOrder(studio, order.id);
    final total = workOrders.fold<int>(0, (sum, item) => sum + item.quantity);
    final completed = workOrders.fold<int>(
      0,
      (sum, item) => sum + item.completedQuantity,
    );
    var liveFraction = 0.0;
    final activeLabels = <String>[];
    for (final workOrder in workOrders) {
      final printer = printers
          .where((item) => item.printer.id == workOrder.printerId)
          .firstOrNull;
      final serial = printer?.serial;
      final queueItem = serial == null
          ? null
          : queues[serial]
              ?.where((item) => item.studioWorkOrderId == workOrder.id)
              .firstOrNull;
      if (queueItem?.status == PrintQueueStatus.printing ||
          workOrder.status == StudioWorkOrderStatus.printing) {
        final percent = fleet
                .where((item) => item.serial == serial)
                .firstOrNull
                ?.lastStatus
                ?.mcPercent ??
            0;
        liveFraction += percent.clamp(0, 100) / 100;
        final name = printer?.printer.name ?? printer?.printer.model ?? '打印机';
        final plate = plates
            .where((item) => item.id == workOrder.productionPlateId)
            .firstOrNull;
        activeLabels.add(
          plates.length > 1 && plate != null ? '$name · ${plate.name}' : name,
        );
      }
    }
    final progress =
        total == 0 ? 0.0 : ((completed + liveFraction) / total).clamp(0.0, 1.0);
    final pendingSlice = plates.where((item) => !item.isSliced).length;
    final pendingAssign = workOrders
        .where((item) => item.printerId == null)
        .fold<int>(0, (sum, item) => sum + item.quantity);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(FarmPalette.radius),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(FarmPalette.radius),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 250,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(order.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Text(
                      '${order.orderNo}${order.dueAt == null ? '' : ' · ${DateFormat('MM-dd HH:mm').format(order.dueAt!)} 交付'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text('已完成 $completed / $total',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const Spacer(),
                        Text('${(progress * 100).toStringAsFixed(0)}%'),
                      ],
                    ),
                    const SizedBox(height: 7),
                    LinearProgressIndicator(value: progress, minHeight: 6),
                    const SizedBox(height: 6),
                    Text(
                      activeLabels.isEmpty
                          ? '当前没有正在打印的机器'
                          : '正在打印：${activeLabels.join('、')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              SizedBox(
                width: 190,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _DispatchTag(
                      label: pendingSlice == 0 ? '切片就绪' : '待切片 $pendingSlice',
                      color: pendingSlice == 0
                          ? FarmVisual.primary
                          : FarmVisual.warning,
                    ),
                    _DispatchTag(
                      label: '待分配 $pendingAssign',
                      color: pendingAssign == 0
                          ? FarmVisual.primary
                          : FarmVisual.warning,
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.account_tree_outlined, size: 17),
                label: const Text('排产'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showOrderDispatchDialog(
  BuildContext context,
  String orderId, {
  required bool canAssign,
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _OrderDispatchDialog(
        orderId: orderId,
        canAssign: canAssign,
      ),
    );

class _OrderDispatchDialog extends ConsumerWidget {
  const _OrderDispatchDialog({required this.orderId, required this.canAssign});
  final String orderId;
  final bool canAssign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider).valueOrNull;
    final printers =
        ref.watch(printersWithChannelsProvider).valueOrNull ?? const [];
    final fleet = ref.watch(fleetPrinterStatesProvider);
    final stock = ref.watch(farmConsumablesProvider).valueOrNull ?? const [];
    if (snapshot == null) {
      return const Dialog(
          child: SizedBox(
              width: 900,
              height: 620,
              child: Center(child: CircularProgressIndicator())));
    }
    final order =
        snapshot.orders.where((item) => item.id == orderId).firstOrNull;
    if (order == null) {
      return const AlertDialog(title: Text('订单已不存在'));
    }
    final plates = farmDispatchablePlatesForOrder(snapshot, orderId);
    final packagePaths = {
      for (final package in snapshot.productionPackages)
        package.id: package.localPath,
    };
    final workOrders = snapshot.workOrders
        .where((item) => item.orderId == orderId)
        .toList(growable: false);
    final queues = <String, List<PrintQueueItem>>{
      for (final printer in printers)
        if (printer.serial case final serial?)
          serial: ref.watch(printQueueProvider(serial)),
    };
    final groups = <String, List<PrinterWithChannels>>{};
    for (final printer in printers) {
      final key =
          PrinterModelNormalizer.normalize(printer.printer.model).toLowerCase();
      groups.putIfAbsent(key, () => []).add(printer);
    }
    final hasAnyAms = fleet.any(
      (state) =>
          detectedAmsState(state.lastStatus) == AmsDetectionState.present,
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1280,
        height: 780,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(order.title,
                            style: const TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w800)),
                        Text('${order.orderNo} · 把右侧机型拖到需要生产的盘上',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: plates.isEmpty
                        ? const Center(child: Text('该订单没有可排产的非空盘'))
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: plates.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 12),
                            itemBuilder: (context, index) => _PlateDispatchCard(
                              plate: plates[index],
                              sourcePath: packagePaths[plates[index].packageId],
                              workOrders: workOrders
                                  .where((item) =>
                                      item.productionPlateId ==
                                      plates[index].id)
                                  .toList(growable: false),
                              printers: printers,
                              fleet: fleet,
                              queues: queues,
                              canAssign: canAssign,
                              onModelDropped: (modelKey) => scheduleFarmPlate(
                                context,
                                ref,
                                plate: plates[index],
                                modelKey: modelKey,
                                snapshot: snapshot,
                                printers: printers,
                                fleet: fleet,
                                stock: stock,
                              ),
                            ),
                          ),
                  ),
                  Container(
                    width: 330,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      border: Border(
                        left: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text('打印机型号',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w800)),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Text(
                            hasAnyAms
                                ? '拖动机型到左侧盘卡，再选择具体机器和供料槽位。'
                                : '拖动机型到左侧盘卡，再选择具体机器和外挂料位。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Expanded(
                          child: groups.isEmpty
                              ? const Center(child: Text('暂无已登记打印机'))
                              : ListView(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 0, 12, 16),
                                  children: [
                                    for (final entry in groups.entries)
                                      _PrinterModelCard(
                                        modelKey: entry.key,
                                        printers: entry.value,
                                        fleet: fleet,
                                        enabled: canAssign,
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlateDispatchCard extends StatelessWidget {
  const _PlateDispatchCard({
    required this.plate,
    required this.sourcePath,
    required this.workOrders,
    required this.printers,
    required this.fleet,
    required this.queues,
    required this.canAssign,
    required this.onModelDropped,
  });
  final StudioProductionPlate plate;
  final String? sourcePath;
  final List<StudioWorkOrder> workOrders;
  final List<PrinterWithChannels> printers;
  final List<FleetPrinterState> fleet;
  final Map<String, List<PrintQueueItem>> queues;
  final bool canAssign;
  final ValueChanged<String> onModelDropped;

  @override
  Widget build(BuildContext context) {
    final completed = workOrders.fold<int>(
      0,
      (sum, item) => sum + item.completedQuantity,
    );
    final unassigned = workOrders
        .where((item) => item.printerId == null)
        .fold<int>(0, (sum, item) => sum + item.quantity);
    final assigned = workOrders
        .where((item) => item.printerId != null)
        .toList(growable: false);
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => canAssign && unassigned > 0,
      onAcceptWithDetails: (details) => onModelDropped(details.data),
      builder: (context, candidates, rejected) {
        final highlight = candidates.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: highlight
                ? FarmVisual.primary.withValues(alpha: .06)
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(FarmPalette.radius),
            border: Border.all(
              color: highlight
                  ? FarmVisual.primary
                  : Theme.of(context).colorScheme.outlineVariant,
              width: highlight ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PlatePreview(plate: plate, sourcePath: sourcePath),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            platesLabel(plate),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w800),
                          ),
                        ),
                        _DispatchTag(
                          label: _sliceLabel(plate.sliceStatus),
                          color: plate.isSliced
                              ? FarmVisual.primary
                              : FarmVisual.warning,
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '已完成 $completed / ${plate.requiredRuns} · 待分配 $unassigned · '
                      '${plate.isMulticolor ? '${plate.activeFilaments.length} 色' : '单色'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (plate.activeFilaments.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 7,
                        runSpacing: 6,
                        children: [
                          for (final filament in plate.activeFilaments)
                            _FilamentDot(filament: filament),
                        ],
                      ),
                    ],
                    if (assigned.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      for (final workOrder in assigned)
                        _AssignedPrinterProgress(
                          workOrder: workOrder,
                          printer: printers
                              .where((item) =>
                                  item.printer.id == workOrder.printerId)
                              .firstOrNull,
                          fleet: fleet,
                          queues: queues,
                        ),
                    ],
                    if (unassigned > 0) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLowest,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.drag_indicator_rounded,
                                size: 17,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                            const SizedBox(width: 7),
                            Text(highlight ? '松开以选择具体打印机' : '把右侧机型拖到这里安排生产'),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PlatePreview extends ConsumerWidget {
  const _PlatePreview({required this.plate, required this.sourcePath});
  final StudioProductionPlate plate;
  final String? sourcePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = sourcePath?.trim();
    final fallback = path == null || path.isEmpty
        ? null
        : ref
            .watch(
              _farmPlatePreviewProvider(
                _FarmPlatePreviewRequest(
                  path: path,
                  plateIndex: plate.plateIndex,
                ),
              ),
            )
            .valueOrNull;
    final preview = plate.thumbnailBytes ?? fallback;
    return Container(
      width: 116,
      height: 92,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: preview == null
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.view_in_ar_outlined,
                    color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 5),
                const Text('等待盘预览', style: TextStyle(fontSize: 10)),
              ],
            )
          : Image.memory(
              preview,
              key: ValueKey(
                'farm-plate-preview-${plate.id}-${preview.lengthInBytes}',
              ),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
            ),
    );
  }
}

class _PrinterModelCard extends StatelessWidget {
  const _PrinterModelCard({
    required this.modelKey,
    required this.printers,
    required this.fleet,
    required this.enabled,
  });
  final String modelKey;
  final List<PrinterWithChannels> printers;
  final List<FleetPrinterState> fleet;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final displayModel = printers.first.printer.model;
    final schedulable = printers.where((printer) {
      final serial = printer.serial;
      final state = fleet.where((item) => item.serial == serial).firstOrNull;
      return serial != null &&
          state != null &&
          state.canAcceptQueuedTask(SchedulingConfig.defaults);
    }).length;
    final amsCount = printers.where((printer) {
      final state =
          fleet.where((state) => state.serial == printer.serial).firstOrNull;
      return detectedAmsState(state?.lastStatus) == AmsDetectionState.present;
    }).length;
    final card = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.precision_manufacturing_outlined,
              color: enabled && schedulable > 0
                  ? FarmVisual.primary
                  : Theme.of(context).colorScheme.outline),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayModel,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(
                  amsCount == 0
                      ? '可排产 $schedulable / ${printers.length} 台'
                      : '可排产 $schedulable / ${printers.length} 台 · '
                          '带 AMS $amsCount 台',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Icon(Icons.drag_indicator_rounded, size: 18),
        ],
      ),
    );
    if (!enabled || schedulable == 0) return Opacity(opacity: .55, child: card);
    return Draggable<String>(
      data: modelKey,
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(width: 300, child: card),
      ),
      childWhenDragging: Opacity(opacity: .35, child: card),
      child: card,
    );
  }
}

/// Opens the physical-printer scheduling flow for one production plate.
///
/// [modelKey] is supplied by the drag-and-drop dispatch board. The project
/// order row omits it so operators can choose directly from all available
/// printers without leaving the order page.
final Set<String> _dispatchingProductionPlateIds = <String>{};

Future<void> scheduleFarmPlate(
  BuildContext context,
  WidgetRef ref, {
  required StudioProductionPlate plate,
  String? modelKey,
  required StudioSnapshot snapshot,
  required List<PrinterWithChannels> printers,
  required List<FleetPrinterState> fleet,
  required List<Consumable> stock,
}) async {
  if (!_dispatchingProductionPlateIds.add(plate.id)) {
    showSnack(context, '这一盘正在排产，请等待当前操作完成', error: true);
    return;
  }
  try {
    await _scheduleFarmPlateUnlocked(
      context,
      ref,
      plate: plate,
      modelKey: modelKey,
      snapshot: snapshot,
      printers: printers,
      fleet: fleet,
      stock: stock,
    );
  } finally {
    _dispatchingProductionPlateIds.remove(plate.id);
  }
}

Future<void> _scheduleFarmPlateUnlocked(
  BuildContext context,
  WidgetRef ref, {
  required StudioProductionPlate plate,
  String? modelKey,
  required StudioSnapshot snapshot,
  required List<PrinterWithChannels> printers,
  required List<FleetPrinterState> fleet,
  required List<Consumable> stock,
}) async {
  final workOrders = snapshot.workOrders
      .where((item) =>
          item.productionPlateId == plate.id && item.printerId == null)
      .toList(growable: false);
  final unassigned =
      workOrders.fold<int>(0, (sum, item) => sum + item.quantity);
  if (unassigned <= 0) {
    showSnack(context, '这个盘已经没有待分配份数', error: true);
    return;
  }
  final selection = await _showPhysicalPrinterPicker(
    context,
    ref: ref,
    modelKey: modelKey,
    printers: printers,
    fleet: fleet,
    maxRuns: unassigned,
  );
  if (selection == null || !context.mounted) return;
  final printer = selection.printer;
  final serial = printer.serial;
  if (serial == null) {
    showSnack(context, '这台打印机没有设备序列号，不能加入队列', error: true);
    return;
  }

  var slicingStarted = false;
  try {
    final target = requireFarmSlicingTarget([
      FarmSlicingPrinterCandidate(
        printer: printer,
        state: selection.state,
      ),
    ]);
    // Ordinary order dispatch always uses manual removal. Automatic ejection
    // belongs to the dedicated batch-production page where the operator
    // chooses one file, one printer pool and one explicit batch policy.
    var artifactPath = plate.sliceArtifactPath;
    var artifactSha256 = plate.sliceArtifactSha256;
    var filaments = plate.filaments;
    var estimatedGrams = plate.estimatedGrams;
    final sameTarget = plate.sliceTargetModel?.trim().isNotEmpty == true &&
        PrinterModelNormalizer.sameModel(
          plate.sliceTargetModel!,
          target.model,
        ) &&
        plate.sliceNozzleDiameter != null &&
        (plate.sliceNozzleDiameter! - target.nozzleDiameter).abs() < .001;
    if (mustRebuildPlateArtifact(
      isSliced: plate.isSliced,
      artifactPath: artifactPath,
      sameTarget: sameTarget,
      artifactAutoEjectEnabled: plate.autoEjectEnabled,
      useAutoEject: false,
    )) {
      final preset = await showFarmSlicingPresetPicker(
        context,
        ref,
        target: target,
      );
      if (preset == null || !context.mounted) return;
      final package = snapshot.productionPackages
          .where((item) => item.id == plate.packageId)
          .firstOrNull;
      final sourcePath = package?.localPath;
      if (sourcePath == null || sourcePath.trim().isEmpty) {
        throw StateError('本机没有这个订单的源 3MF，无法按 ${target.model} 切片');
      }
      final slicer = await ref.read(activeSlicerStatusProvider.future);
      final executable = slicer?.executablePath;
      if (executable == null) throw StateError('未找到 Bambu Studio');
      await ref.read(studioDaoProvider).updateProductionPlateSlice(
            id: plate.id,
            status: StudioPlateSliceStatus.slicing,
          );
      slicingStarted = true;
      await ref.read(farmSlicingPresetsProvider.notifier).validateManagedPreset(
            preset,
            model: target.model,
            nozzleDiameter: target.nozzleDiameter,
          );
      final result =
          await ref.read(farmSliceIntakeProvider.notifier).runManagedSlice(
                () => BambuStudioSlicingService.sliceProject(
                  executablePath: executable,
                  sourcePath: sourcePath,
                  plateIndex: plate.plateIndex,
                  settingsPaths: preset.settingsPaths,
                  filamentSettingsPaths: preset.filamentSettingsPaths,
                  autoEjectGcode: null,
                ),
                inspectionOf: (result) => result.inspection,
                sourcePath: sourcePath,
              );
      final sliced = result.inspection.plates
          .where(
              (item) => item.plateIndex == plate.plateIndex && item.hasToolpath)
          .firstOrNull;
      if (sliced == null) throw StateError('切片结果中没有这一盘的刀路');
      filaments = [
        for (final item in sliced.filaments)
          StudioPlateFilamentUsage(
            toolIndex: item.toolIndex,
            grams: item.grams,
            vendor: item.vendor,
            materialType: item.materialType,
            colorHex: item.colorHex,
            trayId: item.trayId,
            sku: item.sku,
            usedForObject: item.usedForObject,
            usedForSupport: item.usedForSupport,
            groupId: item.groupId,
            nozzleDiameter: item.nozzleDiameter,
            volumeType: item.volumeType,
          ),
      ];
      estimatedGrams = sliced.estimatedGrams;
      artifactPath = result.outputPath;
      artifactSha256 = result.inspection.artifactSha256;
      await ref.read(studioDaoProvider).updateProductionPlateSlice(
            id: plate.id,
            status: StudioPlateSliceStatus.sliced,
            artifactPath: result.outputPath,
            artifactSha256: result.inspection.artifactSha256,
            estimatedSeconds: sliced.estimatedSeconds,
            estimatedGrams: sliced.estimatedGrams,
            totalLayers: sliced.totalLayers,
            toolChangeCount: sliced.toolChangeCount,
            filaments: filaments,
            targetModel: target.model,
            nozzleDiameter: target.nozzleDiameter,
            autoEjectEnabled: false,
            thumbnailBytes: sliced.thumbnailBytes,
          );
      slicingStarted = false;
    }
    if (!context.mounted) return;
    final activeFilaments = StudioPlateFilamentUsage.activeByTool(filaments);
    final materialRequirements = activeFilaments.isNotEmpty
        ? activeFilaments
        : [
            StudioPlateFilamentUsage(
              toolIndex: 0,
              grams: estimatedGrams,
            ),
          ];
    if (materialRequirements.length > 1 &&
        detectedAmsState(selection.state.lastStatus) !=
            AmsDetectionState.present) {
      throw StateError(
        '这一盘是多色打印，但 ${printer.printer.name ?? printer.printer.model} '
        '没有识别到已连接的 AMS，不能进行多色槽位映射',
      );
    }
    final mapping = await _showMaterialMappingDialog(
      context,
      plateName: plate.name,
      printer: printer,
      printerStatus: selection.state.lastStatus,
      filaments: materialRequirements,
      farmStockIds: stock.map((item) => item.id).toSet(),
      runs: selection.runs,
    );
    if (mapping == null || !context.mounted) return;
    final demandByChannel = <int, double>{};
    for (final filament in materialRequirements) {
      final slot = mapping[filament.toolIndex]!;
      demandByChannel.update(
        slot.channel.id,
        (value) => value + filament.grams * selection.runs,
        ifAbsent: () => filament.grams * selection.runs,
      );
    }
    for (final demand in demandByChannel.entries) {
      final availability = await ref
          .read(studioDaoProvider)
          .getPrinterChannelAvailableGrams(demand.key);
      if (availability + .001 < demand.value) {
        throw StateError('所选槽位只剩 ${availability.toStringAsFixed(1)}g 可分配，'
            '本次需要 ${demand.value.toStringAsFixed(1)}g');
      }
    }
    final maxTool = mapping.keys.fold<int>(-1, math.max);
    final amsMapping = maxTool < 0
        ? null
        : List<int>.generate(
            maxTool + 1,
            (tool) => mapping[tool]?.channel.channelIndex ?? -1,
            growable: false,
          );
    final consumableByTool = {
      for (final entry in mapping.entries)
        entry.key: entry.value.consumable!.id,
    };
    final printerChannelByTool = {
      for (final entry in mapping.entries) entry.key: entry.value.channel.id,
    };
    final resolvedArtifactPath = artifactPath;
    if (resolvedArtifactPath == null || resolvedArtifactPath.trim().isEmpty) {
      throw StateError('切片文件路径不可用，请重新切片后再分配');
    }
    final stableArtifact =
        await SliceArtifactHashService.computeStable(resolvedArtifactPath);
    if (stableArtifact == null) {
      throw StateError('切片文件不存在、为空或仍在变化，请重新切片后再排产');
    }
    if (artifactSha256?.trim().isNotEmpty == true &&
        artifactSha256 != stableArtifact.sha256Hex) {
      throw StateError('切片文件内容已经变化，请重新切片后再排产');
    }
    artifactSha256 = stableArtifact.sha256Hex;
    final filename = resolvedArtifactPath.split(RegExp(r'[/\\]')).last;
    final dispatchService = StudioDispatchService(
      database: ref.read(databaseProvider),
      studioDao: ref.read(studioDaoProvider),
      printQueueDao: ref.read(printQueueDaoProvider),
    );
    await dispatchService.dispatchPlateRuns(
      StudioPlateDispatchRequest(
        productionPlateId: plate.id,
        printerId: printer.printer.id,
        printerSerial: serial,
        runs: selection.runs,
        gcodePath: resolvedArtifactPath,
        filename: filename,
        artifactSha256: artifactSha256,
        consumableByTool: consumableByTool,
        printerChannelByTool: printerChannelByTool,
        amsMapping: amsMapping,
      ),
    );
    final startFailure = await ref
        .read(printQueueProvider(serial).notifier)
        .activateCommittedStudioDispatch([resolvedArtifactPath]);
    unawaited(cleanupUnusedFarmSliceArtifacts(ref));
    if (context.mounted) {
      showSnack(
        context,
        startFailure == null
            ? '${plate.name} 已分配给 ${printer.printer.name ?? printer.printer.model}，'
                '共 ${selection.runs} 份 · 人工取件'
            : '排产已经完整保存，但自动启动被阻止：$startFailure',
        tone: startFailure == null
            ? AppNoticeTone.success
            : AppNoticeTone.warning,
      );
    }
  } catch (error) {
    // A slicing failure changes the plate state. Assignment, material or queue
    // failures leave an already-valid slice intact so the operator can retry.
    if (slicingStarted) {
      await ref.read(studioDaoProvider).updateProductionPlateSlice(
            id: plate.id,
            status: StudioPlateSliceStatus.failed,
          );
    }
    if (context.mounted) showSnack(context, '排产失败：$error', error: true);
  }
}

class _PrinterSelection {
  const _PrinterSelection(this.printer, this.runs, this.state);
  final PrinterWithChannels printer;
  final int runs;
  final FleetPrinterState state;
}

Future<_PrinterSelection?> _showPhysicalPrinterPicker(
  BuildContext context, {
  required WidgetRef ref,
  String? modelKey,
  required List<PrinterWithChannels> printers,
  required List<FleetPrinterState> fleet,
  required int maxRuns,
}) async {
  var runs = 1;
  var currentFleet = fleet;
  final matching = printers
      .where(
        (item) =>
            modelKey == null ||
            PrinterModelNormalizer.normalize(item.printer.model)
                    .toLowerCase() ==
                modelKey,
      )
      .toList(growable: false)
    ..sort((a, b) {
      bool available(PrinterWithChannels printer) {
        final state = currentFleet
            .where((item) => item.serial == printer.serial)
            .firstOrNull;
        return state?.canAcceptQueuedTask(SchedulingConfig.defaults) == true;
      }

      final availability =
          (available(b) ? 1 : 0).compareTo(available(a) ? 1 : 0);
      if (availability != 0) return availability;
      return (a.printer.name ?? a.printer.model)
          .compareTo(b.printer.name ?? b.printer.model);
    });
  return showDialog<_PrinterSelection>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(
          modelKey == null
              ? '选择空闲打印机'
              : '选择 ${matching.firstOrNull?.printer.model ?? '打印机'}',
        ),
        content: SizedBox(
          width: 850,
          height: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('本次安排份数',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: runs,
                    items: [
                      for (var value = 1; value <= maxRuns; value++)
                        DropdownMenuItem(value: value, child: Text('$value 份')),
                    ],
                    onChanged: (value) => setState(() => runs = value ?? 1),
                  ),
                  const Spacer(),
                  Text('打印中的机器可以预排，当前任务结束后按队列继续',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: matching.isEmpty
                    ? const Center(
                        child: Text('没有符合机型条件的打印机，请添加设备后重试'),
                      )
                    : GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 2.2,
                        ),
                        itemCount: matching.length,
                        itemBuilder: (context, index) {
                          final printer = matching[index];
                          final state = currentFleet
                              .where((item) => item.serial == printer.serial)
                              .firstOrNull;
                          final available = printer.serial != null &&
                              state != null &&
                              state.canAcceptQueuedTask(
                                  SchedulingConfig.defaults);
                          return _PhysicalPrinterCard(
                            printer: printer,
                            state: state,
                            enabled: available,
                            onTap: available
                                ? () => Navigator.pop(context,
                                    _PrinterSelection(printer, runs, state))
                                : null,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              final added = await showFarmLanBulkImportDialog(context, ref);
              if (added > 0 && context.mounted) {
                Navigator.pop(context);
              }
            },
            icon: const Icon(Icons.add_rounded, size: 17),
            label: const Text('添加打印机'),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              await ref
                  .read(printerFleetConnectionManagerProvider.notifier)
                  .monitorAllConfigured();
              currentFleet = ref.read(fleetPrinterStatesProvider);
              if (context.mounted) setState(() {});
            },
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('刷新状态'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ],
      ),
    ),
  );
}

class _PhysicalPrinterCard extends StatelessWidget {
  const _PhysicalPrinterCard({
    required this.printer,
    required this.state,
    required this.enabled,
    required this.onTap,
  });
  final PrinterWithChannels printer;
  final FleetPrinterState? state;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final amsState = detectedAmsState(state?.lastStatus);
    final ams = printer.channels
        .where((item) => !isExternalFeedChannel(item.channel.channelIndex))
        .where((_) => amsState != AmsDetectionState.absent)
        .toList(growable: false);
    final external = printer.channels
        .where((item) => isExternalFeedChannel(item.channel.channelIndex))
        .toList(growable: false);
    final running = state?.lastStatus?.gcodeState == BambuGcodeState.running;
    final unavailableReason = _printerUnavailableReason(printer, state);
    return Opacity(
      opacity: enabled ? 1 : .55,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(FarmPalette.radius),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(FarmPalette.radius),
              border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(printer.printer.name ?? printer.printer.model,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                    _DispatchTag(
                      label: enabled
                          ? (running ? '打印中 · 可预排' : '空闲')
                          : unavailableReason,
                      color: enabled ? FarmVisual.primary : FarmVisual.warning,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                    amsState == AmsDetectionState.absent
                        ? '${printer.printer.model} · 外挂 ${external.length} 槽'
                        : '${printer.printer.model} · '
                            '${detectedAmsSummary(state?.lastStatus)} · '
                            '外挂 ${external.length} 槽',
                    style: Theme.of(context).textTheme.bodySmall),
                if (!enabled) ...[
                  const SizedBox(height: 3),
                  Text(
                    _printerUnavailableDetail(printer, state),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  '槽位克数：${printer.channels.where((slot) => slot.consumable != null).map((slot) => '${printerFeedChannelLabel(slot.channel.channelIndex, storedLabel: slot.channel.label, compact: true)} ${slot.channel.loadedRemainingGrams.toStringAsFixed(0)}g').join(' · ')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: [
                    for (final slot in [...ams, ...external].take(8))
                      _SlotMaterialMini(slot: slot),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _printerUnavailableReason(
  PrinterWithChannels printer,
  FleetPrinterState? state,
) {
  if (printer.serial?.trim().isNotEmpty != true) return '缺少序列号';
  if (state == null) return '尚未监控';
  if (!state.isLanCapable) return '仅云端';
  if (state.isConnecting ||
      state.connectionState == PrinterConnectionState.connecting ||
      state.connectionState == PrinterConnectionState.reconnecting) {
    return '连接中';
  }
  if (state.connectionState != PrinterConnectionState.connected) return '离线';
  if (state.isStale(SchedulingConfig.defaults)) return '状态过期';
  if (state.lastStatus?.upgradeStatus?.isNotEmpty == true) return '升级中';
  return switch (state.lastStatus?.gcodeState) {
    BambuGcodeState.failed => '设备异常',
    BambuGcodeState.offline => '设备离线',
    BambuGcodeState.slicing => '设备切片中',
    BambuGcodeState.unknown || null => '状态未知',
    _ => '暂不可用',
  };
}

String _printerUnavailableDetail(
  PrinterWithChannels printer,
  FleetPrinterState? state,
) {
  final reason = _printerUnavailableReason(printer, state);
  return switch (reason) {
    '缺少序列号' => '请编辑设备并补全序列号',
    '尚未监控' => '点击下方“刷新状态”连接这台设备',
    '仅云端' => '自动排产需要局域网 Access Code 配置',
    '连接中' => '正在获取打印机实时状态，请稍候刷新',
    '离线' || '设备离线' => '检查打印机电源、网络和局域网地址',
    '状态过期' => '实时状态超过 5 分钟未更新，请刷新设备',
    '升级中' => '固件升级结束后才能安排新任务',
    '设备异常' => '先在设备页处理打印机报错',
    '设备切片中' => '等待设备结束当前切片状态',
    _ => '当前状态不允许安全排产，请刷新后重试',
  };
}

Future<Map<int, ChannelWithConsumable>?> _showMaterialMappingDialog(
  BuildContext context, {
  required String plateName,
  required PrinterWithChannels printer,
  required BambuPrinterStatus? printerStatus,
  required List<StudioPlateFilamentUsage> filaments,
  required Set<int> farmStockIds,
  required int runs,
}) async {
  final isMulticolor = filaments.length > 1;
  final amsState = detectedAmsState(printerStatus);
  final channels = printer.channels.where((slot) {
    final consumable = slot.consumable;
    if (consumable == null ||
        slot.farmRollPaused ||
        slot.channel.loadedRemainingGrams <= minimumReusableSpoolGrams ||
        !farmStockIds.contains(consumable.id)) return false;
    final external = isExternalFeedChannel(slot.channel.channelIndex);
    if (!external && amsState != AmsDetectionState.present) return false;
    return !isMulticolor || !external;
  }).toList(growable: false);
  final dao =
      ProviderScope.containerOf(context, listen: false).read(studioDaoProvider);
  final availableByChannel = <int, double>{};
  for (final channel in channels) {
    availableByChannel[channel.channel.id] =
        await dao.getPrinterChannelAvailableGrams(channel.channel.id);
  }
  if (!context.mounted) return null;
  final selected = <int, ChannelWithConsumable>{};
  for (final filament in filaments) {
    final match = channels.where((slot) {
      final item = slot.consumable!;
      final typeMatches = filament.materialType?.trim().isNotEmpty != true ||
          MaterialIdentityService.sameFamily(
            item.materialType,
            filament.materialType!,
          );
      final colorMatches = filament.colorHex?.trim().isNotEmpty != true ||
          item.colorHex.toUpperCase() == filament.colorHex!.toUpperCase();
      final enough = (availableByChannel[slot.channel.id] ?? 0) + .001 >=
          filament.grams * runs;
      return typeMatches && colorMatches && enough;
    }).firstOrNull;
    if (match != null) selected[filament.toolIndex] = match;
  }
  return showDialog<Map<int, ChannelWithConsumable>>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('$plateName · ${isMulticolor ? '确认 AMS 映射' : '确认供料槽位'}'),
        content: SizedBox(
          width: 700,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isMulticolor
                    ? '多色盘只允许使用 AMS 槽位。每个工具颜色都必须匹配已装机耗材。'
                    : '选择这份任务实际使用的 AMS 或外挂料位。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final filament in filaments) ...[
                Row(
                  children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color:
                            ColorUtils.fromHex(filament.colorHex ?? '#BFC5CC'),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color:
                                Theme.of(context).colorScheme.outlineVariant),
                      ),
                    ),
                    const SizedBox(width: 9),
                    SizedBox(
                      width: 150,
                      child: Text(
                          '工具 ${filament.toolIndex + 1} · ${filament.materialType ?? '未知材质'}'),
                    ),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: selected[filament.toolIndex]?.channel.id,
                        decoration: const InputDecoration(labelText: '供料槽位'),
                        items: [
                          for (final slot in channels.where((slot) {
                            final item = slot.consumable!;
                            final typeMatches =
                                filament.materialType?.trim().isNotEmpty !=
                                        true ||
                                    MaterialIdentityService.sameFamily(
                                      item.materialType,
                                      filament.materialType!,
                                    );
                            final colorMatches =
                                filament.colorHex?.trim().isNotEmpty != true ||
                                    item.colorHex.toUpperCase() ==
                                        filament.colorHex!.toUpperCase();
                            final enough =
                                (availableByChannel[slot.channel.id] ?? 0) +
                                        .001 >=
                                    filament.grams * runs;
                            return typeMatches && colorMatches && enough;
                          }))
                            DropdownMenuItem(
                              value: slot.channel.id,
                              child: Text(
                                  '${printerFeedChannelLabel(slot.channel.channelIndex, storedLabel: slot.channel.label)} · '
                                  '${slot.consumable!.manufacturer} ${slot.consumable!.materialType} · '
                                  '当前 ${slot.channel.loadedRemainingGrams.toStringAsFixed(0)}g · '
                                  '可排 ${(availableByChannel[slot.channel.id] ?? 0).toStringAsFixed(0)}g'),
                            ),
                        ],
                        onChanged: (value) {
                          final slot = channels
                              .where((item) => item.channel.id == value)
                              .firstOrNull;
                          if (slot != null) {
                            setState(() => selected[filament.toolIndex] = slot);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: selected.length == filaments.length
                ? () => Navigator.pop(context, selected)
                : null,
            child: const Text('确认并加入队列'),
          ),
        ],
      ),
    ),
  );
}

class _AssignedPrinterProgress extends StatelessWidget {
  const _AssignedPrinterProgress({
    required this.workOrder,
    required this.printer,
    required this.fleet,
    required this.queues,
  });
  final StudioWorkOrder workOrder;
  final PrinterWithChannels? printer;
  final List<FleetPrinterState> fleet;
  final Map<String, List<PrintQueueItem>> queues;

  @override
  Widget build(BuildContext context) {
    final serial = printer?.serial;
    final queue = serial == null
        ? null
        : queues[serial]
            ?.where((item) => item.studioWorkOrderId == workOrder.id)
            .firstOrNull;
    final percent = queue?.status == PrintQueueStatus.printing
        ? (fleet
                    .where((item) => item.serial == serial)
                    .firstOrNull
                    ?.lastStatus
                    ?.mcPercent ??
                0)
            .clamp(0, 100)
        : workOrder.status == StudioWorkOrderStatus.completed
            ? 100
            : 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              printer?.printer.name ?? printer?.printer.model ?? '已分配设备',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: LinearProgressIndicator(value: percent / 100, minHeight: 5),
          ),
          const SizedBox(width: 8),
          SizedBox(
              width: 38,
              child: Text('$percent%', style: const TextStyle(fontSize: 11))),
          SizedBox(
            width: 72,
            child: Text(
              queue?.status.label ?? _workOrderLabel(workOrder.status),
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilamentDot extends StatelessWidget {
  const _FilamentDot({required this.filament});
  final StudioPlateFilamentUsage filament;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: ColorUtils.fromHex(filament.colorHex ?? '#BFC5CC'),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text('T${filament.toolIndex + 1} ${filament.materialType ?? ''}',
                style: const TextStyle(fontSize: 10)),
          ],
        ),
      );
}

class _SlotMaterialMini extends StatelessWidget {
  const _SlotMaterialMini({required this.slot});
  final ChannelWithConsumable slot;
  @override
  Widget build(BuildContext context) {
    final item = slot.consumable;
    return Tooltip(
      message: item == null
          ? '${slot.channel.label} 未装料'
          : slot.farmRollPaused
              ? '${slot.channel.label} 维修暂存 · 保留 ${slot.channel.loadedRemainingGrams.toStringAsFixed(0)}g · 不参与排产'
              : '${item.manufacturer} · ${item.materialType} · ${item.colorName ?? item.colorHex}',
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: item == null
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : ColorUtils.fromHex(item.colorHex),
          shape: BoxShape.circle,
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
    );
  }
}

class _DispatchTag extends StatelessWidget {
  const _DispatchTag({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.w700)),
      );
}

class _DispatchEmpty extends StatelessWidget {
  const _DispatchEmpty();
  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.assignment_outlined, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text('暂无需要排产的订单'),
            SizedBox(height: 4),
            Text('新建订单后，每一盘都会自动出现在这里'),
          ],
        ),
      );
}

String platesLabel(StudioProductionPlate plate) =>
    '第 ${plate.plateIndex} 盘 · ${plate.name}';

String _sliceLabel(StudioPlateSliceStatus status) => switch (status) {
      StudioPlateSliceStatus.pending => '待切片',
      StudioPlateSliceStatus.slicing => '切片中',
      StudioPlateSliceStatus.sliced => '切片就绪',
      StudioPlateSliceStatus.failed => '切片失败',
    };

String _workOrderLabel(StudioWorkOrderStatus status) => switch (status) {
      StudioWorkOrderStatus.queued => '待分配',
      StudioWorkOrderStatus.assigned => '排队中',
      StudioWorkOrderStatus.printing => '打印中',
      StudioWorkOrderStatus.paused => '待切片',
      StudioWorkOrderStatus.completed => '已完成',
      StudioWorkOrderStatus.failed => '失败',
      StudioWorkOrderStatus.cancelled => '取消',
    };
