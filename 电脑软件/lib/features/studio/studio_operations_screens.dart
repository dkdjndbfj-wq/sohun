import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:drift/drift.dart' show Value;

import '../../core/services/printer_fleet_connection_manager.dart';
import '../../core/services/farm_material_type_catalog_service.dart';
import '../../core/services/material_identity_service.dart';
import '../../core/services/farm_brand_catalog_service.dart';
import '../../core/services/studio_dispatch_service.dart';
import '../../core/utils/color_utils.dart';
import '../../data/database/models/scheduler_models.dart';
import '../../data/database/models/print_queue_item.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/database.dart';
import '../../data/database/models/studio_models.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_connector.dart';
import '../../data/external/slicer/bambu_studio_slicing_service.dart';
import '../../data/external/slicer/production_package_inspector.dart';
import '../../providers/database_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/print_queue_provider.dart';
import '../../providers/scheduler_provider.dart';
import '../../providers/slicer_provider.dart';
import '../../providers/studio_provider.dart';
import '../../providers/farm_slice_intake_provider.dart';
import '../../providers/farm_slicing_preset_provider.dart';
import '../../providers/farm_material_type_catalog_provider.dart';
import '../../providers/farm_brand_catalog_provider.dart';
import '../../providers/farm_consumable_metadata_provider.dart';
import 'farm_ui/farm_design.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_ui/farm_components.dart';
import 'farm_ui/farm_brand_picker.dart';
import 'studio_screens.dart';
import 'farm_material_color_dialog.dart';
import 'farm_lan_bulk_import_dialog.dart';
import 'farm_order_dispatch_screen.dart';
import 'farm_slicing_workflow.dart';
import 'farm_work_order_dialog.dart';
import 'studio_plate_filament_summary.dart';
import 'studio_work_order_materials.dart';

final _projectPlatePreviewProvider =
    FutureProvider.family<Uint8List?, _ProjectPlatePreviewRequest>(
        (ref, request) async {
  final inspection = await ProductionPackageInspector.inspect(request.path);
  return inspection?.plates
      .where((item) => item.plateIndex == request.plateIndex)
      .firstOrNull
      ?.thumbnailBytes;
});

class _ProjectPlatePreviewRequest {
  const _ProjectPlatePreviewRequest({
    required this.path,
    required this.plateIndex,
  });

  final String path;
  final int plateIndex;

  @override
  bool operator ==(Object other) =>
      other is _ProjectPlatePreviewRequest &&
      other.path == path &&
      other.plateIndex == plateIndex;

  @override
  int get hashCode => Object.hash(path, plateIndex);
}

class StudioFarmOverviewScreen extends ConsumerWidget {
  const StudioFarmOverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final fleet = ref.watch(fleetPrinterStatesProvider);
    final tasks = ref.watch(schedulerTasksProvider).valueOrNull ?? const [];
    final consumables =
        ref.watch(farmConsumablesProvider).valueOrNull ?? const [];
    final deferredSlices = ref.watch(farmSliceIntakeProvider).deferred;
    return _FarmPage(
      title: '总控台',
      subtitle: '生产状态、订单进度与风险集中处理',
      actions: [
        FilledButton.icon(
          onPressed: ref.watch(currentFarmPermissionProvider('job.assign'))
              ? () => showFarmWorkOrderDialog(context)
              : null,
          icon: const Icon(Icons.add_rounded, size: 17),
          label: const Text('新建订单'),
        ),
        OutlinedButton.icon(
          onPressed: () => ref
              .read(printerFleetConnectionManagerProvider.notifier)
              .monitorAllConfigured(),
          icon: const Icon(Icons.refresh_rounded, size: 17),
          label: const Text('刷新设备'),
        ),
      ],
      child: snapshot.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('农场数据读取失败：$error')),
        data: (studio) {
          final now = DateTime.now();
          final activeOrders = studio.orders
              .where((item) => !_orderIsTerminal(item.status))
              .toList();
          final urgentOrders = activeOrders.where((item) {
            final due = item.dueAt;
            return due != null && due.difference(now).inDays <= 3;
          }).toList()
            ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
          final running = fleet
              .where(
                (item) =>
                    item.lastStatus?.gcodeState == BambuGcodeState.running,
              )
              .length;
          final issues = fleet
              .where(
                (item) =>
                    item.connectionState == PrinterConnectionState.error ||
                    item.lastStatus?.gcodeState == BambuGcodeState.failed,
              )
              .toList();
          final pendingTasks =
              tasks.where((item) => !item.status.isTerminal).toList();
          final warehouseRolls = consumables.fold<int>(
            0,
            (sum, item) => sum + (item.remainingGrams / 1000).floor(),
          );
          return Column(
            children: [
              _FarmSummaryBar(
                items: [
                  ('运行设备', '$running / ${fleet.length}'),
                  ('异常设备', '${issues.length}'),
                  ('待完成订单', '${activeOrders.length}'),
                  ('临近交付', '${urgentOrders.length}'),
                  ('待处理切片', '${deferredSlices.length}'),
                  ('仓库库存', '$warehouseRolls 卷'),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _FarmPanel(
                        title: '需处理',
                        subtitle: '设备异常与三天内交付项目',
                        child: ListView(
                          children: [
                            for (final item in issues)
                              _CompactAlertRow(
                                icon: Icons.error_outline_rounded,
                                title: item.displayLabel,
                                detail: item.connectionState ==
                                        PrinterConnectionState.error
                                    ? '设备连接异常，请检查 LAN 配置与网络'
                                    : '打印任务报告失败，需要人工处理',
                                color: FarmVisual.danger,
                              ),
                            for (final order in urgentOrders)
                              _CompactAlertRow(
                                icon: Icons.schedule_rounded,
                                title: order.title,
                                detail:
                                    '${order.orderNo} · ${DateFormat('MM-dd').format(order.dueAt!)} 交付',
                                color: FarmVisual.warning,
                              ),
                            if (deferredSlices.isNotEmpty)
                              for (final request in deferredSlices)
                                _CompactAlertRow(
                                  icon: Icons.content_cut_rounded,
                                  title: request.inspection.displayName,
                                  detail:
                                      '${request.inspection.plates.length} 盘切片等待建立订单',
                                  color: FarmVisual.primary,
                                  onTap: () => ref
                                      .read(farmSliceIntakeProvider.notifier)
                                      .restore(request.id),
                                ),
                            if (issues.isEmpty &&
                                urgentOrders.isEmpty &&
                                deferredSlices.isEmpty)
                              const _FarmEmpty(
                                icon: Icons.check_circle_outline_rounded,
                                text: '当前没有需要立即处理的事项',
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _FarmPanel(
                        title: '生产队列',
                        subtitle: '${pendingTasks.length} 个任务等待或正在执行',
                        child: pendingTasks.isEmpty
                            ? const _FarmEmpty(
                                icon: Icons.playlist_add_check_circle_outlined,
                                text: '当前没有生产任务',
                              )
                            : ListView.separated(
                                itemCount: pendingTasks.length > 10
                                    ? 10
                                    : pendingTasks.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final task = pendingTasks[index];
                                  return SizedBox(
                                    height: 54,
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 92,
                                          child: _StatusTag(
                                            label: _schedulerStatusLabel(
                                              task.status,
                                            ),
                                            color: _schedulerStatusColor(
                                              task.status,
                                              Theme.of(context).colorScheme,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            task.gcodeFilename,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        SizedBox(
                                          width: 120,
                                          child: Text(
                                            task.assignedPrinterName ?? '等待分配',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.right,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _FarmPanel(
                        title: '设备状态',
                        subtitle: '${fleet.length} 台设备处于农场监控范围',
                        child: fleet.isEmpty
                            ? const _FarmEmpty(
                                icon: Icons.precision_manufacturing_outlined,
                                text: '还没有连接农场设备',
                              )
                            : ListView.separated(
                                itemCount:
                                    fleet.length > 10 ? 10 : fleet.length,
                                separatorBuilder: (_, __) => const Divider(),
                                itemBuilder: (context, index) {
                                  final printer = fleet[index];
                                  final failed = printer.connectionState ==
                                          PrinterConnectionState.error ||
                                      printer.lastStatus?.gcodeState ==
                                          BambuGcodeState.failed;
                                  final running =
                                      printer.lastStatus?.gcodeState ==
                                          BambuGcodeState.running;
                                  return _CompactAlertRow(
                                    icon: failed
                                        ? Icons.error_outline_rounded
                                        : running
                                            ? Icons.print_outlined
                                            : Icons.check_circle_outline,
                                    title: printer.displayLabel,
                                    detail: _farmPrinterOverviewDetail(printer),
                                    color: failed
                                        ? FarmVisual.danger
                                        : running
                                            ? FarmVisual.primary
                                            : Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

String _farmPrinterOverviewDetail(FleetPrinterState printer) {
  final connection = switch (printer.connectionState) {
    PrinterConnectionState.connected => '在线',
    PrinterConnectionState.connecting => '连接中',
    PrinterConnectionState.reconnecting => '重连中',
    PrinterConnectionState.error => '连接异常',
    PrinterConnectionState.disconnected => '离线',
  };
  final task = switch (printer.lastStatus?.gcodeState) {
    BambuGcodeState.running => '打印中',
    BambuGcodeState.pause => '已暂停',
    BambuGcodeState.finish => '已完成',
    BambuGcodeState.failed => '任务失败',
    BambuGcodeState.idle => '空闲',
    _ => '等待状态',
  };
  final model = printer.reportedModel?.trim();
  return [
    if (model != null && model.isNotEmpty) model,
    connection,
    task,
  ].join(' · ');
}

class StudioProjectOrdersScreen extends ConsumerWidget {
  const StudioProjectOrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final canManageOrder =
        ref.watch(currentFarmPermissionProvider('order.manage'));
    final canShare = ref.watch(currentFarmPermissionProvider('customer.share'));
    final canSlice = ref.watch(currentFarmPermissionProvider('plate.slice'));
    final canAssign = ref.watch(currentFarmPermissionProvider('job.assign'));
    return _FarmPage(
      title: '项目订单',
      subtitle: '打印机上报完成后订单自动完成；失败打印按进度计入耗材损耗，处理后可直接重试。',
      actions: [
        FilledButton.icon(
          onPressed: snapshot.valueOrNull == null || !canManageOrder
              ? null
              : () => showFarmWorkOrderDialog(context),
          icon: const Icon(Icons.add_rounded, size: 17),
          label: const Text('新建订单'),
        ),
      ],
      child: snapshot.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('订单读取失败：$error')),
        data: (studio) {
          if (studio.orders.isEmpty) {
            return const _FarmEmpty(
              icon: Icons.assignment_outlined,
              text: '还没有项目订单',
            );
          }
          return Column(
            children: [
              const _ProjectOrderHeader(),
              Expanded(
                child: ListView.separated(
                  itemCount: studio.orders.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) => _ProjectOrderRow(
                    studio: studio,
                    order: studio.orders[index],
                    canManageOrder: canManageOrder,
                    canShare: canShare,
                    canSlice: canSlice,
                    canAssign: canAssign,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class StudioTeamOperationsScreen extends ConsumerWidget {
  const StudioTeamOperationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final canCreate = ref.watch(currentFarmPermissionProvider('member.create'));
    final canUpdate = ref.watch(currentFarmPermissionProvider('member.update'));
    final canDisable =
        ref.watch(currentFarmPermissionProvider('member.disable'));
    final canReset =
        ref.watch(currentFarmPermissionProvider('member.reset_credential'));
    return _FarmPage(
      title: '成员管理',
      subtitle: '删除成员只会终止账号访问；历史工单和操作记录永久保留，便于后续复查。',
      actions: [
        FilledButton.icon(
          onPressed: snapshot.valueOrNull == null || !canCreate
              ? null
              : () => showStudioMemberDialog(
                    context,
                    ref,
                    snapshot.value!.workspace,
                  ),
          icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
          label: const Text('添加成员'),
        ),
      ],
      child: snapshot.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('团队读取失败：$error')),
        data: (studio) {
          final members = studio.members
              .where((item) => item.accountStatus != 'removed')
              .toList(growable: false);
          final removed = studio.members.length - members.length;
          final active = members.where((item) => item.active).length;
          return Column(
            children: [
              _FarmSummaryBar(
                items: [
                  ('活跃成员', '$active / ${members.length}'),
                  (
                    '管理员',
                    '${members.where((item) => item.active && item.role == StudioMemberRole.owner).length}'
                  ),
                  (
                    '成员',
                    '${members.where((item) => item.active && item.role != StudioMemberRole.owner).length}'
                  ),
                  ('已删除账号', '$removed（记录保留）'),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        children: [
                          const _TeamHeader(),
                          Expanded(
                            child: ListView.separated(
                              itemCount: members.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) => _TeamRow(
                                member: members[index],
                                workOrders: studio.workOrders,
                                canUpdate: canUpdate,
                                canDisable: canDisable,
                                canReset: canReset,
                                activity: studio.latestActivityFor(
                                  'member',
                                  members[index].id,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    const SizedBox(
                      width: 310,
                      child: _PermissionMatrix(),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class StudioDispatchScreen extends ConsumerWidget {
  const StudioDispatchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(schedulerTasksProvider);
    final autoEnabled = ref.watch(autoScheduleEnabledProvider);
    final running = ref.watch(schedulerNotifierProvider).isLoading;
    final fleet = ref.watch(fleetPrinterStatesProvider);
    final canAssign = ref.watch(currentFarmPermissionProvider('job.assign'));
    return _FarmPage(
      title: '生产调度',
      subtitle: '按状态、机型和喷嘴约束集中处理队列，避免在多个体验型页面之间切换。',
      actions: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('自动分配', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 6),
            Switch.adaptive(
              value: autoEnabled,
              onChanged: !canAssign
                  ? null
                  : (value) => ref
                      .read(autoScheduleEnabledProvider.notifier)
                      .setEnabled(value),
            ),
          ],
        ),
        FilledButton.icon(
          onPressed: running || !canAssign
              ? null
              : () =>
                  ref.read(schedulerNotifierProvider.notifier).autoSchedule(),
          icon: running
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome_motion_outlined, size: 17),
          label: const Text('立即调度'),
        ),
      ],
      child: tasks.when(
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('调度任务读取失败：$error')),
        data: (items) {
          final pending = items.where((item) => !item.status.isTerminal).length;
          final connected = fleet
              .where(
                (item) =>
                    item.connectionState == PrinterConnectionState.connected,
              )
              .length;
          return Column(
            children: [
              _FarmSummaryBar(
                items: [
                  ('待处理任务', '$pending'),
                  ('已连接设备', '$connected / ${fleet.length}'),
                  (
                    '可自动下发',
                    '${fleet.where((item) => item.isLanCapable).length}'
                  ),
                  ('自动调度', autoEnabled ? '已开启' : '已关闭'),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: items.isEmpty
                    ? const _FarmEmpty(
                        icon: Icons.playlist_add_check_circle_outlined,
                        text: '当前没有调度任务',
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final task = items[index];
                          return _DispatchRow(task: task);
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DispatchRow extends StatelessWidget {
  const _DispatchRow({required this.task});

  final SchedulerTask task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 68,
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: _StatusTag(
              label: _schedulerStatusLabel(task.status),
              color: _schedulerStatusColor(task.status, scheme),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              task.gcodeFilename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: Text(task.targetModel ?? task.modelGroup.label),
          ),
          SizedBox(
            width: 100,
            child: Text(
              task.targetNozzleDiameter == null
                  ? '喷嘴未知'
                  : '${task.targetNozzleDiameter} mm',
            ),
          ),
          SizedBox(
            width: 120,
            child: Text(
              task.assignedPrinterName ?? '等待分配',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class StudioBatchInventoryScreen extends ConsumerWidget {
  const StudioBatchInventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final inventory = ref.watch(farmConsumablesProvider);
    final canAdjust =
        ref.watch(currentFarmPermissionProvider('inventory.adjust'));
    return _FarmPage(
      title: '批量库存',
      subtitle: '按到货批次录入；库存卷只读展示，卷数统一在入库批次中调整，每卷固定 1000g。',
      actions: [
        OutlinedButton.icon(
          onPressed: snapshot.valueOrNull == null || !canAdjust
              ? null
              : () => _showFarmSingleReceiveDialog(
                    context,
                    ref,
                    snapshot.valueOrNull!,
                  ),
          icon: const Icon(Icons.add_circle_outline, size: 17),
          label: const Text('单条入库'),
        ),
        FilledButton.icon(
          onPressed: snapshot.valueOrNull == null || !canAdjust
              ? null
              : () => _showBatchReceiveDialog(
                    context,
                    ref,
                    snapshot.valueOrNull!,
                  ),
          icon: const Icon(Icons.playlist_add_outlined, size: 17),
          label: const Text('批量入库'),
        ),
      ],
      child: snapshot.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('农场库存读取失败：$error')),
        data: (studio) => inventory.when(
          skipLoadingOnRefresh: true,
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('耗材库存读取失败：$error')),
          data: (items) {
            final metadataState = ref.watch(farmConsumableMetadataProvider);
            if (metadataState.isLoading && metadataState.valueOrNull == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final metadata =
                metadataState.valueOrNull ?? <int, FarmConsumableMetadata>{};
            final batchItemsByConsumable = {
              for (final item in studio.inventoryBatchItems)
                item.consumableId: item,
            };
            final inventoryGroups = _groupFarmInventory(
              items,
              batchItemsByConsumable,
              metadata,
            );
            final archivedGroups = _groupFarmInventory(
              items,
              batchItemsByConsumable,
              metadata,
              includeArchived: true,
            ).where((group) => group.archived).toList();
            final physicalRolls = inventoryGroups.fold<int>(
              0,
              (sum, group) => sum + group.availableRolls,
            );
            return DefaultTabController(
              length: 3,
              child: Column(
                children: [
                  _FarmSummaryBar(
                    items: [
                      ('仓库整卷', '$physicalRolls 卷'),
                      ('耗材类型', '${inventoryGroups.length} 种'),
                      ('到货批次', '${studio.inventoryBatches.length}'),
                      (
                        '最近入库',
                        studio.inventoryBatches.isEmpty
                            ? '暂无'
                            : DateFormat('MM-dd HH:mm').format(
                                studio.inventoryBatches.first.receivedAt,
                              )
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 300,
                      child: TabBar(
                        tabs: const [
                          Tab(text: '库存卷'),
                          Tab(text: '已归档'),
                          Tab(text: '入库批次'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _FarmInventoryList(
                          groups: inventoryGroups,
                          workspaceId: studio.workspace.id,
                          canAdjust: canAdjust,
                        ),
                        _FarmInventoryList(
                          groups: archivedGroups,
                          workspaceId: studio.workspace.id,
                          canAdjust: canAdjust,
                          archived: true,
                        ),
                        studio.inventoryBatches.isEmpty
                            ? const _FarmEmpty(
                                icon: Icons.inventory_2_outlined,
                                text: '暂无批量入库记录',
                              )
                            : Column(
                                children: [
                                  const _BatchHeader(),
                                  Expanded(
                                    child: ListView.separated(
                                      itemCount: studio.inventoryBatches.length,
                                      separatorBuilder: (_, __) =>
                                          const Divider(height: 1),
                                      itemBuilder: (context, index) {
                                        final batch =
                                            studio.inventoryBatches[index];
                                        final member = studio.members
                                            .where((item) =>
                                                item.id == batch.memberId)
                                            .firstOrNull;
                                        return _BatchRow(
                                          batch: batch,
                                          memberName: member?.displayName,
                                          studio: studio,
                                          inventoryItems: items,
                                          canEdit: canAdjust,
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class StudioCustomerPortalScreen extends ConsumerWidget {
  const StudioCustomerPortalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final role = ref.watch(currentStudioRoleProvider);
    final canManage =
        role == StudioMemberRole.owner || role == StudioMemberRole.admin;
    return DefaultTabController(
      length: 1,
      child: Column(
        children: [
          Container(
            height: 44,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: const SizedBox(
              width: 180,
              child: TabBar(
                tabs: [Tab(text: '订单用户门户')],
              ),
            ),
          ),
          Expanded(
            child: snapshot.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('客户门户读取失败：$error')),
              data: (studio) => TabBarView(
                children: [
                  _PortalLinksPanel(studio: studio, canManage: canManage),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PortalLinksPanel extends ConsumerWidget {
  const _PortalLinksPanel({required this.studio, required this.canManage});

  final StudioSnapshot studio;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _FarmPage(
      title: '订单用户门户',
      subtitle: '一个订单对应一个独立用户与密码；无需维护或关联客户档案，只能查看本订单进度与关联设备画面。',
      child: studio.orders.isEmpty
          ? const _FarmEmpty(
              icon: Icons.language_outlined,
              text: '先建立项目订单，再为该订单用户创建进度链接',
            )
          : Column(
              children: [
                const _PortalHeader(),
                Expanded(
                  child: ListView.separated(
                    itemCount: studio.orders.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final order = studio.orders[index];
                      final link = studio.shareLinks
                          .where(
                            (item) => item.orderId == order.id && item.active,
                          )
                          .firstOrNull;
                      return SizedBox(
                        height: 62,
                        child: Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    order.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    order.orderNo,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Expanded(child: Text('订单独立用户')),
                            SizedBox(
                              width: 100,
                              child: _StatusTag(
                                label: link == null ? '未创建' : '已启用',
                                color: link == null
                                    ? Theme.of(context).colorScheme.outline
                                    : FarmVisual.primary,
                              ),
                            ),
                            SizedBox(
                              width: 110,
                              child: Text(
                                link?.expiresAt == null
                                    ? '-'
                                    : DateFormat('yyyy-MM-dd')
                                        .format(link!.expiresAt!),
                              ),
                            ),
                            SizedBox(
                              width: 100,
                              child: Text(
                                order.portalVideoEnabled ? '打印时可见' : '已关闭',
                              ),
                            ),
                            SizedBox(
                              width: 120,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (link == null)
                                    IconButton(
                                      tooltip: '创建密码保护链接',
                                      onPressed: !canManage
                                          ? null
                                          : () => createStudioCustomerShare(
                                                context,
                                                ref,
                                                order,
                                              ),
                                      icon: const Icon(Icons.add_link_rounded),
                                    )
                                  else ...[
                                    IconButton(
                                      tooltip: '复制链接',
                                      onPressed: !canManage
                                          ? null
                                          : () => handleStudioShareAction(
                                                context,
                                                ref,
                                                link,
                                                'copy',
                                              ),
                                      icon: const Icon(Icons.copy_rounded),
                                    ),
                                    IconButton(
                                      tooltip: '撤销链接',
                                      onPressed: !canManage
                                          ? null
                                          : () => handleStudioShareAction(
                                                context,
                                                ref,
                                                link,
                                                'revoke',
                                              ),
                                      icon: const Icon(Icons.link_off_rounded),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

// Kept only to render legacy snapshots in migration/debug tooling. The farm
// navigation no longer exposes a separate customer directory: each order owns
// its portal identity directly.
// ignore: unused_element
class _CustomerDirectoryPanel extends ConsumerWidget {
  const _CustomerDirectoryPanel({
    required this.studio,
    required this.canManage,
  });

  final StudioSnapshot studio;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _FarmPage(
      title: '客户档案',
      subtitle: '联系人信息仅供农场团队使用，不会出现在客户公开进度页。',
      actions: [
        FilledButton.icon(
          onPressed: !canManage
              ? null
              : () => showStudioCustomerDialog(
                    context,
                    ref,
                    studio.workspace,
                  ),
          icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
          label: const Text('添加客户'),
        ),
      ],
      child: studio.customers.isEmpty
          ? const _FarmEmpty(
              icon: Icons.groups_2_outlined,
              text: '还没有客户档案',
            )
          : Column(
              children: [
                const _CustomerHeader(),
                Expanded(
                  child: ListView.separated(
                    itemCount: studio.customers.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final customer = studio.customers[index];
                      final orders = studio.orders
                          .where((item) => item.customerId == customer.id)
                          .length;
                      return SizedBox(
                        height: 62,
                        child: Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                customer.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Expanded(child: Text(customer.contactName ?? '-')),
                            Expanded(child: Text(customer.phone ?? '-')),
                            Expanded(
                              flex: 2,
                              child: Text(
                                customer.email ?? '-',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            SizedBox(width: 90, child: Text('$orders 个')),
                            SizedBox(
                              width: 90,
                              child: Switch.adaptive(
                                value: !customer.archived,
                                onChanged: !canManage
                                    ? null
                                    : (active) => ref
                                        .read(studioDaoProvider)
                                        .setCustomerArchived(
                                          customer.id,
                                          !active,
                                        ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _ProjectOrderHeader extends StatelessWidget {
  const _ProjectOrderHeader();

  @override
  Widget build(BuildContext context) {
    final style = _tableHeaderStyle(context);
    return Container(
      height: 36,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.only(left: 16, right: 42),
      child: Row(
        children: [
          SizedBox(width: 108, child: Text('状态', style: style)),
          Expanded(flex: 2, child: Text('项目 / 订单号', style: style)),
          Expanded(child: Text('打印文件', style: style)),
          SizedBox(width: 106, child: Text('交付', style: style)),
          SizedBox(width: 150, child: Text('完成率 / 耗材成本', style: style)),
          SizedBox(width: 104, child: Text('客户页', style: style)),
          SizedBox(width: 134, child: Text('操作', style: style)),
        ],
      ),
    );
  }
}

class _ProjectOrderRow extends ConsumerWidget {
  const _ProjectOrderRow({
    required this.studio,
    required this.order,
    required this.canManageOrder,
    required this.canShare,
    required this.canSlice,
    required this.canAssign,
  });

  final StudioSnapshot studio;
  final StudioOrder order;
  final bool canManageOrder;
  final bool canShare;
  final bool canSlice;
  final bool canAssign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packages = studio.productionPackages
        .where((item) => item.orderId == order.id)
        .toList();
    final workOrders =
        studio.workOrders.where((item) => item.orderId == order.id).toList();
    final productionPlates = studio.productionPlates
        .where((item) => item.orderId == order.id)
        .toList();
    final configuredPrinters =
        ref.watch(printersWithChannelsProvider).valueOrNull ?? const [];
    final fleet = ref.watch(fleetPrinterStatesProvider);
    final farmStock =
        ref.watch(farmConsumablesProvider).valueOrNull ?? const [];
    final share = studio.shareLinks
        .where((item) => item.orderId == order.id && item.active)
        .firstOrNull;
    final total = workOrders.fold<int>(0, (sum, item) => sum + item.quantity);
    final completed = workOrders.fold<int>(
      0,
      (sum, item) => sum + item.completedQuantity,
    );
    final materialCost = workOrders.fold<double>(
      0,
      (sum, item) => sum + item.materialCostSnapshot,
    );
    final completion = total == 0 ? 0.0 : completed / total;
    final activity = studio.latestActivityFor('order', order.id);
    return ExpansionTile(
      tilePadding: const EdgeInsets.only(left: 16, right: 6),
      childrenPadding: const EdgeInsets.fromLTRB(124, 0, 42, 10),
      minTileHeight: 66,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Row(
        children: [
          SizedBox(
            width: 108,
            child: _StatusTag(
              label: _farmOrderStatusLabel(order.status),
              color: _farmOrderStatusColor(
                order.status,
                Theme.of(context).colorScheme,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  order.orderNo,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                _ActivityStamp(event: activity),
              ],
            ),
          ),
          Expanded(
            child: Text(
              packages.isEmpty
                  ? '未添加'
                  : packages.length == 1
                      ? packages.single.sourceName
                      : '${packages.length} 个文件',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 106,
            child: Text(
              order.dueAt == null
                  ? '-'
                  : DateFormat('MM-dd').format(order.dueAt!),
            ),
          ),
          SizedBox(
            width: 150,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: completion,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 42,
                      child: Text('${(completion * 100).round()}%'),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '累计耗材 ¥${materialCost.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 104,
            child: Text(share == null ? '未创建' : '已启用'),
          ),
          SizedBox(
            width: 134,
            child: Row(
              children: [
                IconButton(
                  tooltip: '添加工单',
                  onPressed: !canManageOrder
                      ? null
                      : () => showStudioWorkOrderDialog(
                            context,
                            ref,
                            studio,
                            order,
                          ),
                  icon: const Icon(Icons.add_task_rounded, size: 19),
                ),
                if (share == null)
                  IconButton(
                    tooltip: '创建客户进度链接',
                    onPressed: !canShare
                        ? null
                        : () => createStudioCustomerShare(
                              context,
                              ref,
                              order,
                            ),
                    icon: const Icon(Icons.add_link_rounded, size: 19),
                  )
                else
                  PopupMenuButton<String>(
                    tooltip: '客户进度链接',
                    enabled: canShare,
                    onSelected: !canShare
                        ? null
                        : (action) => handleStudioShareAction(
                              context,
                              ref,
                              share,
                              action,
                            ),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'copy', child: Text('复制链接')),
                      PopupMenuItem(value: 'revoke', child: Text('撤销链接')),
                    ],
                    icon: const Icon(Icons.link_rounded, size: 19),
                  ),
              ],
            ),
          ),
        ],
      ),
      children: [
        if (productionPlates.isEmpty)
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('该订单还没有可查看的生产盘'),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 6.0;
              final columns = constraints.maxWidth >= 940
                  ? 6
                  : constraints.maxWidth >= 700
                      ? 5
                      : constraints.maxWidth >= 560
                          ? 4
                          : constraints.maxWidth >= 420
                              ? 3
                              : constraints.maxWidth >= 280
                                  ? 2
                                  : 1;
              final cardWidth = columns == 1
                  ? constraints.maxWidth
                  : (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final plate in productionPlates)
                    SizedBox(
                      width: cardWidth,
                      child: _ProjectPlateSliceRow(
                        studio: studio,
                        plate: plate,
                        package: packages
                            .where((item) => item.id == plate.packageId)
                            .firstOrNull,
                        workOrders: workOrders
                            .where((item) => item.productionPlateId == plate.id)
                            .toList(growable: false),
                        printers: configuredPrinters,
                        fleet: fleet,
                        farmStock: farmStock,
                        canSlice: canSlice,
                        canManageProduction: canAssign,
                        onSlice: (package) => _sliceExistingProductionPlate(
                          context,
                          ref,
                          package,
                          plate,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        if (workOrders.isEmpty)
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('尚未拆分生产工单'),
            ),
          )
        else
          for (final workOrder
              in workOrders.where((item) => item.productionPlateId == null))
            _ProjectWorkOrderRow(
              studio: studio,
              workOrder: workOrder,
              printers: configuredPrinters,
              canManage: canManageOrder,
            ),
      ],
    );
  }
}

class _ProjectPlateSliceRow extends ConsumerStatefulWidget {
  const _ProjectPlateSliceRow({
    required this.studio,
    required this.plate,
    required this.package,
    required this.workOrders,
    required this.printers,
    required this.fleet,
    required this.farmStock,
    required this.canSlice,
    required this.canManageProduction,
    required this.onSlice,
  });

  final StudioSnapshot studio;
  final StudioProductionPlate plate;
  final StudioProductionPackage? package;
  final List<StudioWorkOrder> workOrders;
  final List<PrinterWithChannels> printers;
  final List<FleetPrinterState> fleet;
  final List<Consumable> farmStock;
  final bool canSlice;
  final bool canManageProduction;
  final Future<void> Function(StudioProductionPackage package) onSlice;

  @override
  ConsumerState<_ProjectPlateSliceRow> createState() =>
      _ProjectPlateSliceRowState();
}

class _ProjectPlateSliceRowState extends ConsumerState<_ProjectPlateSliceRow> {
  var _detailsExpanded = false;
  var _scheduling = false;
  var _slicingLocally = false;

  Future<void> _slicePlate() async {
    if (_slicingLocally || widget.package == null) return;
    setState(() => _slicingLocally = true);
    try {
      await widget.onSlice(widget.package!);
    } finally {
      if (mounted) setState(() => _slicingLocally = false);
    }
  }

  Future<void> _schedulePlate() async {
    if (_scheduling) return;
    setState(() => _scheduling = true);
    try {
      if (widget.printers.isEmpty) {
        await showFarmLanBulkImportDialog(context, ref);
        return;
      }
      await scheduleFarmPlate(
        context,
        ref,
        plate: widget.plate,
        snapshot: widget.studio,
        printers: widget.printers,
        fleet: widget.fleet,
        stock: widget.farmStock,
      );
    } finally {
      if (mounted) setState(() => _scheduling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plate = widget.plate;
    final sliced = plate.sliceStatus == StudioPlateSliceStatus.sliced;
    final slicing =
        plate.sliceStatus == StudioPlateSliceStatus.slicing || _slicingLocally;
    final completed = widget.workOrders.fold<int>(
      0,
      (sum, item) => sum + item.completedQuantity,
    );
    final unassigned = widget.workOrders
        .where((item) => item.printerId == null)
        .fold<int>(0, (sum, item) => sum + item.quantity);
    final assigned = widget.workOrders
        .where(
          (item) =>
              item.printerId != null &&
              item.status != StudioWorkOrderStatus.cancelled,
        )
        .toList(growable: false);
    final resliceBlocked = sliced && assigned.isNotEmpty;
    final assignedPrinterNames = <String>{
      for (final workOrder in assigned)
        widget.printers
                .where((item) => item.printer.id == workOrder.printerId)
                .firstOrNull
                ?.printer
                .name ??
            widget.printers
                .where((item) => item.printer.id == workOrder.printerId)
                .firstOrNull
                ?.printer
                .model ??
            '未识别设备',
    };
    final idlePrinterCount = widget.fleet
        .where(
          (item) => item.canAutoDispatch(SchedulingConfig.defaults),
        )
        .where(
          (item) =>
              widget.printers.any((printer) => printer.serial == item.serial),
        )
        .length;
    final queuedPrinterCount = widget.fleet
        .where(
          (item) => item.canAcceptQueuedTask(SchedulingConfig.defaults),
        )
        .where(
          (item) =>
              widget.printers.any((printer) => printer.serial == item.serial),
        )
        .length;
    final assignedIds = assigned.map((item) => item.id).toSet();
    final failedCount = assigned
        .where((item) => item.status == StudioWorkOrderStatus.failed)
        .length;
    final missingMaterialCount = assigned.where((workOrder) {
      if (workOrder.status == StudioWorkOrderStatus.completed) return false;
      final materials = widget.studio.workOrderMaterials
          .where((item) => item.workOrderId == workOrder.id)
          .toList(growable: false);
      return (materials.isEmpty && plate.estimatedGrams > .01) ||
          materials.any((item) => !item.isAllocated);
    }).length;
    final accountingReviewCount = widget.studio.printAttempts
        .where(
          (item) =>
              assignedIds.contains(item.workOrderId) &&
              item.needsAccountingReview,
        )
        .map((item) => item.workOrderId)
        .toSet()
        .length;
    final hasIssues = failedCount > 0 ||
        missingMaterialCount > 0 ||
        accountingReviewCount > 0;
    final detailsExpanded = _detailsExpanded;
    final metricLabel = sliced
        ? '${_formatPlateDuration(plate.estimatedSeconds)} · '
            '${plate.estimatedGrams.toStringAsFixed(1)} g · '
            '${plate.totalLayers} 层'
        : null;
    Widget buildStatus() => SizedBox(
          width: 64,
          child: _StatusTag(
            label: sliced
                ? '已切片'
                : slicing
                    ? '切片中'
                    : plate.sliceStatus == StudioPlateSliceStatus.failed
                        ? '切片失败'
                        : '待切片',
            color: sliced
                ? Colors.green
                : plate.sliceStatus == StudioPlateSliceStatus.failed
                    ? FarmVisual.danger
                    : FarmVisual.warning,
          ),
        );
    Widget buildTitle() => Text(
          '第 ${plate.plateIndex} 盘 · ${plate.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        );
    Widget buildMetrics({double? width}) => SizedBox(
          width: width,
          child: Text(
            metricLabel!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );
    final sliceAction = Tooltip(
      message: resliceBlocked
          ? '该盘已有排产或生产记录；先撤回未开工任务，已开工任务不能覆盖切片'
          : sliced
              ? '重新生成这一盘的切片文件'
              : '只切当前这一盘',
      child: OutlinedButton.icon(
        onPressed: !widget.canSlice ||
                slicing ||
                widget.package == null ||
                resliceBlocked
            ? null
            : _slicePlate,
        icon: Icon(
          sliced ? Icons.refresh_rounded : Icons.content_cut_rounded,
          size: 13,
        ),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          visualDensity: VisualDensity.compact,
        ),
        label: Text(
          slicing ? '切片中' : '切片',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10),
        ),
      ),
    );
    final scheduleAction = Tooltip(
      message: !sliced
          ? '先完成这一盘切片，再选择打印机排产'
          : widget.printers.isEmpty
              ? '还没有打印机，点击直接扫描并添加设备'
              : unassigned <= 0
                  ? '这一盘的生产数量已全部排产'
                  : idlePrinterCount > 0
                      ? '$idlePrinterCount 台空闲打印机可排产'
                      : queuedPrinterCount > 0
                          ? '没有空闲设备，可预排正在打印的设备'
                          : '选择打印机排产',
      child: FilledButton.icon(
        key: ValueKey('schedule-production-plate-${plate.id}'),
        onPressed: !widget.canManageProduction ||
                !sliced ||
                slicing ||
                _scheduling ||
                unassigned <= 0
            ? null
            : _schedulePlate,
        icon: Icon(
          widget.printers.isEmpty
              ? Icons.add_rounded
              : Icons.precision_manufacturing_outlined,
          size: 13,
        ),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          visualDensity: VisualDensity.compact,
        ),
        label: Text(
          _scheduling
              ? '排产中'
              : unassigned <= 0
                  ? '已排产'
                  : '排产',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10),
        ),
      ),
    );
    return Container(
      key: ValueKey('project-plate-card-${plate.id}'),
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: hasIssues
            ? Border.all(
                color: failedCount > 0 ? FarmVisual.danger : FarmVisual.warning,
              )
            : Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProjectPlatePreview(
            plate: plate,
            package: widget.package,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              buildStatus(),
              const SizedBox(width: 4),
              Expanded(
                child: buildTitle(),
              ),
            ],
          ),
          if (metricLabel != null) ...[
            const SizedBox(height: 4),
            buildMetrics(),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: sliceAction),
              const SizedBox(width: 4),
              Expanded(child: scheduleAction),
            ],
          ),
          if (widget.workOrders.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  assigned.isEmpty
                      ? Icons.pending_actions_outlined
                      : Icons.print_outlined,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '生产 $completed / ${plate.requiredRuns}'
                    '${unassigned > 0 ? ' · 待排产 $unassigned' : ''}'
                    '${assignedPrinterNames.isEmpty ? '' : ' · ${assignedPrinterNames.join('、')}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (failedCount > 0 ||
                missingMaterialCount > 0 ||
                accountingReviewCount > 0 ||
                assigned.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 2,
                  runSpacing: 2,
                  alignment: WrapAlignment.end,
                  children: [
                    if (failedCount > 0)
                      _PlateIssueBadge(
                        label: '失败 $failedCount',
                        color: FarmVisual.danger,
                      ),
                    if (missingMaterialCount > 0)
                      _PlateIssueBadge(
                        label: '缺料 $missingMaterialCount',
                        color: FarmVisual.warning,
                      ),
                    if (accountingReviewCount > 0)
                      _PlateIssueBadge(
                        label: '待核对 $accountingReviewCount',
                        color: FarmVisual.warning,
                      ),
                    if (assigned.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => setState(
                          () => _detailsExpanded = !_detailsExpanded,
                        ),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 30),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: Icon(
                          detailsExpanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 15,
                        ),
                        label: Text(
                          '打印明细 ${assigned.length}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
          ],
          if (sliced)
            StudioPlateFilamentSummary(
              filaments: plate.filaments,
              toolChangeCount: plate.toolChangeCount,
              requiredRuns: plate.requiredRuns,
              compact: true,
            ),
          if (detailsExpanded)
            for (final workOrder in assigned)
              _ProjectWorkOrderRow(
                studio: widget.studio,
                workOrder: workOrder,
                printers: widget.printers,
                canManage: widget.canManageProduction,
              ),
        ],
      ),
    );
  }
}

class _ProjectPlatePreview extends ConsumerWidget {
  const _ProjectPlatePreview({
    required this.plate,
    required this.package,
  });

  final StudioProductionPlate plate;
  final StudioProductionPackage? package;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = package?.localPath?.trim();
    final fallback = path == null || path.isEmpty
        ? null
        : ref
            .watch(
              _projectPlatePreviewProvider(
                _ProjectPlatePreviewRequest(
                  path: path,
                  plateIndex: plate.plateIndex,
                ),
              ),
            )
            .valueOrNull;
    final preview = plate.thumbnailBytes ?? fallback;
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Container(
        key: ValueKey('project-plate-preview-${plate.id}'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: preview == null
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.view_in_ar_outlined,
                    size: 21,
                    color: scheme.outline,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    path == null || path.isEmpty ? '暂无模型预览' : '读取模型预览',
                    style: TextStyle(
                      fontSize: 9,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            : Image.memory(
                preview,
                key: ValueKey(
                  'project-plate-preview-image-${plate.id}-${preview.lengthInBytes}',
                ),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
              ),
      ),
    );
  }
}

class _PlateIssueBadge extends StatelessWidget {
  const _PlateIssueBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 5),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          border: Border.all(color: color.withValues(alpha: .45)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

Future<void> _sliceExistingProductionPlate(
  BuildContext context,
  WidgetRef ref,
  StudioProductionPackage package,
  StudioProductionPlate plate,
) async {
  var slicingStarted = false;
  final sourcePath = package.localPath;
  if (sourcePath == null || sourcePath.trim().isEmpty) {
    showSnack(context, '本机没有这个项目的源 3MF 路径，无法继续按盘切片', error: true);
    return;
  }
  final printers = await ref.read(printersWithChannelsProvider.future);
  if (!context.mounted) return;
  final printer = await showFarmSlicingPrinterPicker(
    context,
    printers: printers,
    fleet: ref.read(fleetPrinterStatesProvider),
  );
  if (printer == null || !context.mounted) return;
  late final FarmSlicingTarget target;
  try {
    target = requireFarmSlicingTarget([printer]);
  } on FarmSlicingWorkflowException catch (error) {
    showSnack(context, error.message, error: true);
    return;
  }
  final preset = await showFarmSlicingPresetPicker(
    context,
    ref,
    target: target,
  );
  if (preset == null || !context.mounted) return;
  final slicer = await ref.read(activeSlicerStatusProvider.future);
  if (!context.mounted) return;
  final executable = slicer?.executablePath;
  if (executable == null) {
    showSnack(context, '未找到 Bambu Studio，请先在切片设置中配置程序路径', error: true);
    return;
  }
  final dao = ref.read(studioDaoProvider);
  try {
    await dao.updateProductionPlateSlice(
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
              ),
              inspectionOf: (result) => result.inspection,
              sourcePath: sourcePath,
            );
    final slicedPlate = result.inspection.plates
        .where(
          (item) => item.plateIndex == plate.plateIndex && item.hasToolpath,
        )
        .firstOrNull;
    if (slicedPlate == null) {
      throw const BambuStudioSliceException('切片结果中没有所选盘的刀路');
    }
    await dao.updateProductionPlateSlice(
      id: plate.id,
      status: StudioPlateSliceStatus.sliced,
      artifactPath: result.outputPath,
      artifactSha256: result.inspection.artifactSha256,
      estimatedSeconds: slicedPlate.estimatedSeconds,
      estimatedGrams: slicedPlate.estimatedGrams,
      totalLayers: slicedPlate.totalLayers,
      toolChangeCount: slicedPlate.toolChangeCount,
      targetModel: target.model,
      nozzleDiameter: target.nozzleDiameter,
      autoEjectEnabled: false,
      thumbnailBytes: slicedPlate.thumbnailBytes,
      filaments: [
        for (final item in slicedPlate.filaments)
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
      ],
    );
    unawaited(cleanupUnusedFarmSliceArtifacts(ref));
    if (context.mounted) {
      showSnack(context, '第 ${plate.plateIndex} 盘切片完成，其他盘状态不变');
    }
  } catch (error) {
    if (slicingStarted) {
      await dao.updateProductionPlateSlice(
        id: plate.id,
        status: StudioPlateSliceStatus.failed,
      );
    }
    if (context.mounted) {
      showSnack(context, '第 ${plate.plateIndex} 盘切片失败：$error', error: true);
    }
  }
}

String _formatPlateDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  return hours > 0 ? '$hours 小时 $minutes 分' : '$minutes 分钟';
}

class _ProjectWorkOrderRow extends ConsumerWidget {
  const _ProjectWorkOrderRow({
    required this.studio,
    required this.workOrder,
    required this.printers,
    required this.canManage,
  });

  final StudioSnapshot studio;
  final StudioWorkOrder workOrder;
  final List<PrinterWithChannels> printers;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final member = studio.members
        .where((item) => item.id == workOrder.assignedMemberId)
        .firstOrNull;
    final productionPlate = studio.productionPlates
        .where((item) => item.id == workOrder.productionPlateId)
        .firstOrNull;
    final waitingForSlice = productionPlate != null &&
        productionPlate.sliceStatus != StudioPlateSliceStatus.sliced;
    final assignedPrinter = printers
        .where((item) => item.printer.id == workOrder.printerId)
        .firstOrNull;
    final needsManualMulticolor = productionPlate?.isMulticolor == true &&
        assignedPrinter != null &&
        assignedPrinter.channels
                .where(
                  (item) => !isExternalFeedChannel(item.channel.channelIndex),
                )
                .length <
            productionPlate!.activeFilaments.length;
    final materials = studio.workOrderMaterials
        .where((item) => item.workOrderId == workOrder.id)
        .toList();
    final attempts = studio.printAttempts
        .where((item) => item.workOrderId == workOrder.id)
        .toList();
    final assignedSerial = assignedPrinter?.serial?.trim();
    final queue = assignedSerial == null || assignedSerial.isEmpty
        ? const <PrintQueueItem>[]
        : ref.watch(printQueueProvider(assignedSerial));
    final linkedQueue = queue
        .where(
          (item) =>
              item.studioWorkOrderId == workOrder.id &&
              item.status != PrintQueueStatus.cancelled,
        )
        .firstOrNull;
    final alreadyQueued = linkedQueue != null;
    final canRetry = linkedQueue?.status == PrintQueueStatus.failed &&
        linkedQueue?.id != null;
    final canWithdraw = workOrder.printerId != null &&
        workOrder.completedQuantity == 0 &&
        workOrder.status != StudioWorkOrderStatus.printing &&
        workOrder.status != StudioWorkOrderStatus.completed &&
        workOrder.status != StudioWorkOrderStatus.cancelled &&
        linkedQueue?.status != PrintQueueStatus.printing &&
        linkedQueue?.status != PrintQueueStatus.waitingRemoval &&
        linkedQueue?.status != PrintQueueStatus.completed;
    final activity = studio.latestActivityFor('work_order', workOrder.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 76,
                    child: _StatusTag(
                      label: waitingForSlice
                          ? '待切片'
                          : _farmWorkOrderStatusLabel(workOrder.status),
                      color: waitingForSlice
                          ? FarmVisual.warning
                          : _farmWorkOrderStatusColor(
                              workOrder.status,
                              Theme.of(context).colorScheme,
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                workOrder.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${workOrder.completedQuantity}/${workOrder.quantity}',
                              style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          member?.displayName ?? '未分配成员',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: workOrder.completion,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        _ActivityStamp(event: activity),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Tooltip(
                    message: canRetry
                        ? '失败损耗已计入成本；检查耗材后重试'
                        : alreadyQueued
                            ? '该工单已在设备队列中'
                            : '加入打印机队列',
                    child: IconButton(
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: !canManage ||
                              assignedSerial == null ||
                              assignedSerial.isEmpty ||
                              workOrder.status ==
                                  StudioWorkOrderStatus.completed ||
                              workOrder.status ==
                                  StudioWorkOrderStatus.cancelled
                          ? null
                          : canRetry
                              ? () => _retryFarmWorkOrder(
                                    context,
                                    ref,
                                    serial: assignedSerial,
                                    queueItemId: linkedQueue!.id!,
                                  )
                              : productionPlate == null ||
                                      waitingForSlice ||
                                      assignedPrinter == null ||
                                      alreadyQueued
                                  ? null
                                  : () => _enqueueFarmWorkOrder(
                                        context,
                                        ref,
                                        workOrder: workOrder,
                                        plate: productionPlate,
                                        printer: assignedPrinter,
                                        materials: materials,
                                      ),
                      icon: Icon(
                        canRetry
                            ? Icons.refresh_rounded
                            : Icons.playlist_add_rounded,
                        size: 19,
                      ),
                    ),
                  ),
                  if (canWithdraw)
                    PopupMenuButton<String>(
                      tooltip: '排产操作',
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: EdgeInsets.zero,
                      enabled: canManage,
                      onSelected: (action) => _withdrawOrReassignFarmWorkOrder(
                        context,
                        ref,
                        workOrder: workOrder,
                        plate: productionPlate!,
                        printers: printers,
                        serial: assignedSerial,
                        reassign: action == 'reassign',
                      ),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'reassign',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.swap_horiz_rounded, size: 19),
                            title: Text('撤回并改派'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'withdraw',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.undo_rounded, size: 19),
                            title: Text('撤回排产'),
                          ),
                        ),
                      ],
                      icon: const Icon(Icons.more_horiz_rounded, size: 19),
                    ),
                  if (workOrder.status == StudioWorkOrderStatus.completed)
                    Tooltip(
                      message: '成品不合格：保留本次成本并重新生产',
                      child: IconButton(
                        constraints: const BoxConstraints.tightFor(
                          width: 36,
                          height: 36,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: !canManage
                            ? null
                            : () => _rejectFarmWorkOrderQuality(
                                  context,
                                  ref,
                                  workOrder: workOrder,
                                  serial: assignedSerial,
                                  queueItem: linkedQueue,
                                ),
                        icon: const Icon(
                          Icons.replay_circle_filled_outlined,
                          size: 19,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        StudioWorkOrderMaterialSummary(
          materials: materials,
          onManage: !canManage || waitingForSlice
              ? null
              : () => showStudioMaterialAllocationDialog(
                    context,
                    ref,
                    workOrder: workOrder,
                    materials: materials,
                  ),
        ),
        if (attempts.isNotEmpty) _PrintAttemptSummary(attempts: attempts),
        if (needsManualMulticolor)
          Padding(
            padding: const EdgeInsets.only(top: 5, left: 8, right: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 14,
                  color: FarmVisual.warning,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '当前打印机没有足够的 AMS 通道：请改派多色设备，或按换料序列手动换料。',
                    style: TextStyle(
                      fontSize: 9,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PrintAttemptSummary extends StatelessWidget {
  const _PrintAttemptSummary({required this.attempts});

  final List<StudioPrintAttempt> attempts;

  @override
  Widget build(BuildContext context) {
    final wasteAttempts = attempts.where((item) => item.isWaste).toList();
    final wasteGrams = wasteAttempts.fold<double>(
      0,
      (sum, item) => sum + item.consumedGrams,
    );
    final totalCost = attempts.fold<double>(
      0,
      (sum, item) => sum + item.materialCost,
    );
    final needsReview = attempts.any((item) => item.needsAccountingReview);
    final color = needsReview
        ? FarmVisual.warning
        : wasteAttempts.isNotEmpty
            ? FarmVisual.danger
            : Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 5, left: 8, right: 8),
      child: Row(
        children: [
          Icon(
            needsReview ? Icons.receipt_long_outlined : Icons.history_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              needsReview
                  ? '打印尝试 ${attempts.length} 次 · 有成本待核对记录'
                  : '打印尝试 ${attempts.length} 次 · 异常 ${wasteAttempts.length} 次'
                      '${wasteAttempts.isEmpty ? '' : ' · 损耗 ${wasteGrams.toStringAsFixed(1)} g'}'
                      ' · 累计 ¥${totalCost.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _rejectFarmWorkOrderQuality(
  BuildContext context,
  WidgetRef ref, {
  required StudioWorkOrder workOrder,
  required String? serial,
  required PrintQueueItem? queueItem,
}) async {
  final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('登记成品不合格'),
          content: const Text(
            '本次打印的耗材和成本会完整保留，工单将重新开放生产。'
            '如果当前耗材不足，系统会要求换卷后才能重试。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认报废并重开'),
            ),
          ],
        ),
      ) ??
      false;
  if (!confirmed || !context.mounted) return;
  try {
    final hasQueue = serial?.isNotEmpty == true && queueItem?.id != null;
    final reserved = hasQueue
        ? await ref
            .read(printQueueProvider(serial!).notifier)
            .rejectCompletedFarmPrint(
              queueItemId: queueItem!.id!,
              workOrderId: workOrder.id,
            )
        : await ref
            .read(studioDaoProvider)
            .rejectCompletedWorkOrderForQuality(id: workOrder.id);
    if (context.mounted) {
      showSnack(
        context,
        reserved ? '已登记成品不合格；本次成本已保留，可以检查后重试' : '已登记成品不合格；本次成本已保留，请先重新分配耗材',
        tone: reserved ? AppNoticeTone.warning : AppNoticeTone.error,
      );
    }
  } catch (error) {
    if (context.mounted) showSnack(context, '登记失败：$error', error: true);
  }
}

Future<void> _retryFarmWorkOrder(
  BuildContext context,
  WidgetRef ref, {
  required String serial,
  required int queueItemId,
}) async {
  try {
    await ref
        .read(printQueueProvider(serial).notifier)
        .retryFailed(queueItemId);
    if (context.mounted) showSnack(context, '失败任务已重新排队，历史损耗不会重复扣除');
  } catch (error) {
    if (context.mounted) showSnack(context, '重试失败：$error', error: true);
  }
}

Future<void> _withdrawOrReassignFarmWorkOrder(
  BuildContext context,
  WidgetRef ref, {
  required StudioWorkOrder workOrder,
  required StudioProductionPlate plate,
  required List<PrinterWithChannels> printers,
  required String? serial,
  required bool reassign,
}) async {
  final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(reassign ? '撤回并改派打印机' : '撤回排产'),
          content: Text(
            reassign
                ? '当前未开始的队列任务会取消，原耗材预留会释放，然后重新选择打印机和槽位。'
                : '当前未开始的队列任务会取消，原耗材预留会释放，数量恢复为待排产。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(reassign ? '继续改派' : '确认撤回'),
            ),
          ],
        ),
      ) ??
      false;
  if (!confirmed || !context.mounted) return;
  try {
    final service = StudioDispatchService(
      database: ref.read(databaseProvider),
      studioDao: ref.read(studioDaoProvider),
      printQueueDao: ref.read(printQueueDaoProvider),
    );
    await service.withdrawAssignedRun(workOrder.id);
    if (serial?.trim().isNotEmpty == true) {
      await ref.read(printQueueProvider(serial!).notifier).startIfIdle();
    }
    if (!context.mounted) return;
    if (!reassign) {
      showSnack(context, '已撤回排产，数量和耗材预留均已恢复');
      return;
    }
    final freshSnapshot =
        await ref.read(studioDaoProvider).getDefaultSnapshot();
    final freshPlate = freshSnapshot.productionPlates
        .where((item) => item.id == plate.id)
        .firstOrNull;
    if (freshPlate == null) throw StateError('撤回后找不到原生产盘');
    final freshPrinters = await ref.read(printersWithChannelsProvider.future);
    final stock = await ref.read(farmConsumablesProvider.future);
    if (!context.mounted) return;
    await scheduleFarmPlate(
      context,
      ref,
      plate: freshPlate,
      snapshot: freshSnapshot,
      printers: freshPrinters.isEmpty ? printers : freshPrinters,
      fleet: ref.read(fleetPrinterStatesProvider),
      stock: stock,
    );
  } catch (error) {
    if (context.mounted) showSnack(context, '撤回或改派失败：$error', error: true);
  }
}

Future<void> _enqueueFarmWorkOrder(
  BuildContext context,
  WidgetRef ref, {
  required StudioWorkOrder workOrder,
  required StudioProductionPlate plate,
  required PrinterWithChannels printer,
  required List<StudioWorkOrderMaterial> materials,
}) async {
  final serial = printer.serial?.trim() ?? '';
  final artifactPath = plate.sliceArtifactPath?.trim() ?? '';
  if (serial.isEmpty || artifactPath.isEmpty || !plate.isSliced) {
    showSnack(context, '请先完成这一盘切片并分配可联网打印机', error: true);
    return;
  }
  if (materials.any((item) => !item.isAllocated)) {
    showSnack(context, '请先为每个耗材通道分配库存卷', error: true);
    return;
  }
  final channelByConsumable = <int, int>{
    for (final channel in printer.channels)
      if (channel.consumable case final consumable?)
        consumable.id: channel.channel.channelIndex,
  };
  final slotByTool = <int, int>{};
  for (final material in materials) {
    final consumableId = material.consumableId;
    final channel =
        consumableId == null ? null : channelByConsumable[consumableId];
    if (channel == null) {
      showSnack(
        context,
        'T${material.toolIndex} 分配的库存卷尚未装入 ${printer.printer.name ?? serial}',
        error: true,
      );
      return;
    }
    if (plate.isMulticolor && isExternalFeedChannel(channel)) {
      showSnack(context, '多色盘不能自动排到外挂料位，请把各颜色装入 AMS', error: true);
      return;
    }
    slotByTool[material.toolIndex] = channel;
  }
  final maxTool = slotByTool.keys.fold<int>(
    -1,
    (value, tool) => tool > value ? tool : value,
  );
  final mapping = maxTool < 0
      ? null
      : List<int>.generate(
          maxTool + 1,
          (tool) => slotByTool[tool] ?? -1,
          growable: false,
        );
  final filename = artifactPath.split(RegExp(r'[/\\]')).last;
  try {
    await ref.read(printQueueProvider(serial).notifier).enqueueStudioWorkOrder(
          workOrderId: workOrder.id,
          gcodePath: artifactPath,
          filename: filename,
          amsMapping: mapping,
          artifactSha256: plate.sliceArtifactSha256,
        );
    if (context.mounted) {
      showSnack(
        context,
        '已加入 ${printer.printer.name ?? serial} 队列；设备忙碌时会排在当前任务之后',
      );
    }
  } catch (error) {
    if (context.mounted) showSnack(context, '$error', error: true);
  }
}

class _TeamHeader extends StatelessWidget {
  const _TeamHeader();

  @override
  Widget build(BuildContext context) {
    final style = _tableHeaderStyle(context);
    return Container(
      height: 36,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(flex: 2, child: Text('成员', style: style)),
          SizedBox(width: 240, child: Text('身份', style: style)),
          SizedBox(width: 100, child: Text('进行中', style: style)),
          SizedBox(width: 100, child: Text('已完成件', style: style)),
          SizedBox(width: 84, child: Text('启用', style: style)),
          const SizedBox(width: 84),
        ],
      ),
    );
  }
}

class _TeamRow extends ConsumerWidget {
  const _TeamRow({
    required this.member,
    required this.workOrders,
    required this.canUpdate,
    required this.canDisable,
    required this.canReset,
    this.activity,
  });

  final StudioMember member;
  final List<StudioWorkOrder> workOrders;
  final bool canUpdate;
  final bool canDisable;
  final bool canReset;
  final StudioActivityEvent? activity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assigned = workOrders.where(
      (item) =>
          item.assignedMemberId == member.id &&
          item.status != StudioWorkOrderStatus.completed &&
          item.status != StudioWorkOrderStatus.cancelled,
    );
    final completed = workOrders
        .where((item) => item.assignedMemberId == member.id)
        .fold<int>(0, (sum, item) => sum + item.completedQuantity);
    final canEdit = canUpdate && member.role != StudioMemberRole.owner;
    final identity = member.role == StudioMemberRole.owner ? '管理员' : '成员';
    return SizedBox(
      height: 62,
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  member.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  member.loginName == null
                      ? member.email ?? '主账号'
                      : '${member.loginName} · ${_farmAccountStatusLabel(member.accountStatus)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                _ActivityStamp(event: activity),
              ],
            ),
          ),
          SizedBox(
            width: 240,
            child: _StatusTag(
              label: identity,
              color: member.role == StudioMemberRole.owner
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.secondary,
            ),
          ),
          SizedBox(width: 100, child: Text('${assigned.length} 个')),
          SizedBox(width: 100, child: Text('$completed 件')),
          SizedBox(
            width: 84,
            child: Switch.adaptive(
              value: member.active,
              onChanged: !canEdit || !canDisable
                  ? null
                  : (active) async {
                      try {
                        await ref
                            .read(studioCloudServiceProvider)
                            .updateFarmStaff(
                              member.id,
                              accountStatus: active ? 'active' : 'deactivated',
                            );
                      } catch (error) {
                        if (context.mounted) {
                          showSnack(context, '修改成员状态失败：$error', error: true);
                        }
                      }
                    },
            ),
          ),
          SizedBox(
            width: 84,
            child: Row(
              children: [
                IconButton(
                  tooltip: '重置成员密码',
                  onPressed: !canEdit || !canReset || member.loginName == null
                      ? null
                      : () async {
                          try {
                            final result = await ref
                                .read(studioCloudServiceProvider)
                                .resetFarmStaffCredential(member.id);
                            final password =
                                result['initialPassword'] as String? ?? '';
                            if (!context.mounted) return;
                            await AppDialog.show<void>(
                              context: context,
                              title: '新的初始密码',
                              content: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('此密码只显示一次，成员下次登录必须重新改密。'),
                                  const SizedBox(height: 12),
                                  SelectableText(password),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () async {
                                    await Clipboard.setData(
                                      ClipboardData(text: password),
                                    );
                                    if (context.mounted) {
                                      showSnack(context, '初始密码已复制');
                                    }
                                  },
                                  child: const Text('复制'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('我已保存'),
                                ),
                              ],
                            );
                          } catch (error) {
                            if (context.mounted) {
                              showSnack(context, '重置成员密码失败：$error',
                                  error: true);
                            }
                          }
                        },
                  icon: const Icon(Icons.password_outlined, size: 18),
                ),
                IconButton(
                  tooltip: '删除成员',
                  onPressed: !canEdit || !canDisable
                      ? null
                      : () async {
                          final confirmed = await AppDialog.confirm(
                            context,
                            '删除成员',
                            '确定删除“${member.displayName}”吗？该账号会立即失去农场访问权限，成员本身不会再出现在列表中；其历史工单和所有操作记录将永久保留，不能删除。',
                            confirmText: '删除成员',
                            destructive: true,
                          );
                          if (!confirmed || !context.mounted) return;
                          try {
                            await ref
                                .read(studioCloudServiceProvider)
                                .removeFarmStaff(member.id);
                            if (context.mounted) {
                              showSnack(context, '成员已删除，历史操作记录已保留');
                            }
                          } catch (error) {
                            if (context.mounted) {
                              showSnack(context, '删除成员失败：$error', error: true);
                            }
                          }
                        },
                  icon: const Icon(Icons.person_remove_outlined, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionMatrix extends StatelessWidget {
  const _PermissionMatrix();

  @override
  Widget build(BuildContext context) {
    return const _FarmPanel(
      title: '身份与协作',
      subtitle: '同一农场只区分管理员与成员，业务权限一致',
      child: Column(
        children: [
          _PermissionRow(
            role: '管理员',
            detail: '农场主账号；创建和停用成员，并使用全部农场功能',
          ),
          Divider(height: 1),
          _PermissionRow(
            role: '成员',
            detail: '共享订单、切片、设备、库存与设置；所有操作都会署名并记录时间',
          ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.role, required this.detail});

  final String role;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              role,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: Text(
              detail,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PortalHeader extends StatelessWidget {
  const _PortalHeader();

  @override
  Widget build(BuildContext context) {
    final style = _tableHeaderStyle(context);
    return Container(
      height: 36,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(flex: 2, child: Text('项目', style: style)),
          Expanded(child: Text('订单用户', style: style)),
          SizedBox(width: 100, child: Text('链接', style: style)),
          SizedBox(width: 110, child: Text('有效期', style: style)),
          SizedBox(width: 100, child: Text('视频', style: style)),
          SizedBox(width: 120, child: Text('操作', style: style)),
        ],
      ),
    );
  }
}

class _CustomerHeader extends StatelessWidget {
  const _CustomerHeader();

  @override
  Widget build(BuildContext context) {
    final style = _tableHeaderStyle(context);
    return Container(
      height: 36,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(flex: 2, child: Text('客户', style: style)),
          Expanded(child: Text('联系人', style: style)),
          Expanded(child: Text('电话', style: style)),
          Expanded(flex: 2, child: Text('邮箱', style: style)),
          SizedBox(width: 90, child: Text('订单', style: style)),
          SizedBox(width: 90, child: Text('启用', style: style)),
        ],
      ),
    );
  }
}

class _FarmPanel extends StatelessWidget {
  const _FarmPanel({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Padding(padding: const EdgeInsets.all(12), child: child),
          ),
        ],
      ),
    );
  }
}

class _CompactAlertRow extends StatelessWidget {
  const _CompactAlertRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right_rounded, size: 18),
          ],
        ),
      ),
    );
  }
}

TextStyle _tableHeaderStyle(BuildContext context) => TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 11,
      fontWeight: FontWeight.w700,
    );

bool _orderIsTerminal(StudioOrderStatus status) =>
    status == StudioOrderStatus.completed ||
    status == StudioOrderStatus.delivered ||
    status == StudioOrderStatus.cancelled;

String _farmOrderStatusLabel(StudioOrderStatus status) => switch (status) {
      StudioOrderStatus.draft => '草稿',
      StudioOrderStatus.confirmed => '已确认',
      StudioOrderStatus.production => '生产中',
      StudioOrderStatus.completed => '已完成',
      StudioOrderStatus.delivered => '已交付',
      StudioOrderStatus.cancelled => '已取消',
    };

Color _farmOrderStatusColor(StudioOrderStatus status, ColorScheme scheme) =>
    switch (status) {
      StudioOrderStatus.production => scheme.primary,
      StudioOrderStatus.completed ||
      StudioOrderStatus.delivered =>
        FarmVisual.primary,
      StudioOrderStatus.cancelled => scheme.outline,
      StudioOrderStatus.confirmed => FarmVisual.blue,
      StudioOrderStatus.draft => FarmVisual.warning,
    };

String _farmWorkOrderStatusLabel(StudioWorkOrderStatus status) =>
    switch (status) {
      StudioWorkOrderStatus.queued => '排队',
      StudioWorkOrderStatus.assigned => '已分配',
      StudioWorkOrderStatus.printing => '打印中',
      StudioWorkOrderStatus.paused => '已暂停',
      StudioWorkOrderStatus.completed => '已完成',
      StudioWorkOrderStatus.failed => '异常',
      StudioWorkOrderStatus.cancelled => '已取消',
    };

Color _farmWorkOrderStatusColor(
  StudioWorkOrderStatus status,
  ColorScheme scheme,
) =>
    switch (status) {
      StudioWorkOrderStatus.printing => scheme.primary,
      StudioWorkOrderStatus.completed => FarmVisual.primary,
      StudioWorkOrderStatus.failed => FarmVisual.danger,
      StudioWorkOrderStatus.cancelled => scheme.outline,
      _ => FarmVisual.warning,
    };

String _farmAccountStatusLabel(String status) => switch (status) {
      'pending_activation' => '待首次改密',
      'active' => '正常',
      'deactivated' => '已停用',
      'removed' => '已删除',
      _ => status,
    };

class _FarmInventoryGroup {
  const _FarmInventoryGroup({
    required this.items,
    required this.batchItems,
    required this.archived,
    this.colorMode = 'solid',
    this.secondaryColorHex,
    this.brandCode,
  });

  final List<Consumable> items;
  final List<StudioInventoryBatchItem?> batchItems;
  final bool archived;
  final String colorMode;
  final String? secondaryColorHex;
  final String? brandCode;

  Consumable get representative => items.first;

  int get totalRolls {
    var result = 0;
    for (var index = 0; index < items.length; index++) {
      final batch = batchItems[index];
      result += batch?.rollCount ??
          math.max(1, (items[index].totalGrams / 1000).ceil());
    }
    return result;
  }

  int get availableRolls {
    var result = 0;
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final batch = batchItems[index];
      final available = item.remainingGrams <= 0
          ? 0
          : math.max(1, (item.remainingGrams / 1000).ceil());
      result += batch == null ? available : available.clamp(0, batch.rollCount);
    }
    return result;
  }

  String get batchLabel {
    final batches = items
        .map((item) => item.batchNo?.trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toSet();
    if (batches.isEmpty) return '-';
    if (batches.length == 1) return batches.single;
    return '${batches.length} 个批次';
  }
}

List<_FarmInventoryGroup> _groupFarmInventory(
  List<Consumable> items,
  Map<int, StudioInventoryBatchItem> batchItemsByConsumable,
  Map<int, FarmConsumableMetadata> metadata, {
  bool includeArchived = false,
}) {
  final grouped = <String, List<Consumable>>{};
  for (final item in items) {
    final itemMetadata = metadata[item.id];
    final archived = itemMetadata?.archived ?? false;
    if (includeArchived != archived) continue;
    final brandCode = itemMetadata?.brandCode?.trim().isNotEmpty == true
        ? itemMetadata!.brandCode!.trim().toLowerCase()
        : FarmBrandCatalogService.normalize(item.manufacturer).code;
    final colorMode = itemMetadata?.colorMode ?? 'solid';
    final secondaryColor =
        itemMetadata?.secondaryColorHex?.trim().toUpperCase() ?? '';
    final key = [
      brandCode,
      item.model.trim().toLowerCase(),
      item.materialType.trim().toLowerCase(),
      item.colorHex.trim().toUpperCase(),
      colorMode,
      secondaryColor,
      archived,
    ].join('|');
    grouped.putIfAbsent(key, () => []).add(item);
  }
  final result = [
    for (final groupItems in grouped.values)
      _FarmInventoryGroup(
        items: groupItems,
        batchItems: [
          for (final item in groupItems) batchItemsByConsumable[item.id],
        ],
        archived: metadata[groupItems.first.id]?.archived ?? false,
        colorMode: metadata[groupItems.first.id]?.colorMode ?? 'solid',
        secondaryColorHex: metadata[groupItems.first.id]?.secondaryColorHex,
        brandCode: metadata[groupItems.first.id]?.brandCode,
      ),
  ];
  if (!includeArchived) {
    result.removeWhere((group) => group.archived || group.availableRolls <= 0);
  }
  result.sort((a, b) {
    final manufacturer =
        a.representative.manufacturer.compareTo(b.representative.manufacturer);
    if (manufacturer != 0) return manufacturer;
    return a.representative.materialType
        .compareTo(b.representative.materialType);
  });
  return result;
}

class _FarmInventoryList extends ConsumerWidget {
  const _FarmInventoryList({
    required this.groups,
    required this.workspaceId,
    required this.canAdjust,
    this.archived = false,
  });

  final List<_FarmInventoryGroup> groups;
  final String workspaceId;
  final bool canAdjust;
  final bool archived;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (groups.isEmpty) {
      return const _FarmEmpty(
        icon: Icons.inventory_2_outlined,
        text: '农场库存为空，请先新增库存卷或批量入库',
      );
    }
    return Column(
      children: [
        Container(
          height: 36,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              const SizedBox(width: 42),
              Expanded(
                  flex: 2,
                  child: Text('耗材', style: _tableHeaderStyle(context))),
              Expanded(child: Text('颜色', style: _tableHeaderStyle(context))),
              SizedBox(
                  width: 110,
                  child: Text('批次', style: _tableHeaderStyle(context))),
              SizedBox(
                  width: 150,
                  child: Text('仓库卷数', style: _tableHeaderStyle(context))),
              SizedBox(
                  width: 112,
                  child: Text('操作', style: _tableHeaderStyle(context))),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: groups.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final group = groups[index];
              final item = group.representative;
              final colorName = item.colorName?.trim().isNotEmpty == true
                  ? item.colorName!
                  : item.colorHex;
              final colorDecoration = group.colorMode == 'solid'
                  ? BoxDecoration(
                      color: ColorUtils.fromHex(item.colorHex),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    )
                  : BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          ColorUtils.fromHex(item.colorHex),
                          ColorUtils.fromHex(
                            group.secondaryColorHex ?? item.colorHex,
                          ),
                        ],
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    );
              return SizedBox(
                height: 62,
                child: Row(
                  children: [
                    SizedBox(
                      width: 42,
                      child: Center(
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: colorDecoration,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${item.manufacturer} · ${item.materialType}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          Text(item.model,
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                    Expanded(
                        child:
                            Text('$colorName\n${item.colorHex}', maxLines: 2)),
                    SizedBox(width: 110, child: Text(group.batchLabel)),
                    SizedBox(
                      width: 150,
                      child: Text(
                        '${group.availableRolls} 卷',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: group.availableRolls <= 1
                              ? FarmVisual.warning
                              : null,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 112,
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '编辑库存资料或归档',
                            onPressed: !canAdjust
                                ? null
                                : archived
                                    ? () async {
                                        await ref
                                            .read(consumableDaoProvider)
                                            .restoreFarmConsumables(
                                              group.items
                                                  .map((item) => item.id),
                                              workspaceId: workspaceId,
                                            );
                                        if (context.mounted) {
                                          showSnack(context, '库存已恢复');
                                        }
                                      }
                                    : () => _editFarmInventoryGroup(
                                          context,
                                          ref,
                                          group,
                                          workspaceId,
                                        ),
                            icon: Icon(
                              archived
                                  ? Icons.unarchive_outlined
                                  : Icons.edit_outlined,
                              size: 18,
                            ),
                          ),
                          IconButton(
                            tooltip: '删除库存卷',
                            onPressed: !canAdjust
                                ? null
                                : () => _deleteFarmStock(
                                    context, ref, group, workspaceId),
                            icon: const Icon(Icons.delete_outline, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

Future<bool> _pickFarmInventoryType({
  required BuildContext context,
  required List<String> catalog,
  required TextEditingController model,
}) async {
  const customEntry = '其他 / 自定义类型';
  final current = FarmMaterialTypeCatalogService.stripBrandPrefix(model.text);
  final options = <String>{
    if (current.isNotEmpty) current,
    ...catalog,
  }.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))
    ..add(customEntry);
  final result = await showMaterialPicker(
    context: context,
    materials: options,
    selected: current.isEmpty ? null : current,
    title: '选择耗材类型',
    searchHint: '搜索耗材类型，例如 PLA Silk、PETG Basic',
    countUnit: '种耗材类型',
    emptyLabel: '没有匹配的耗材类型',
  );
  var selected = result?.value?.trim();
  if (selected == null || selected.isEmpty) return false;
  if (selected == customEntry) {
    selected = await _showCustomFarmInventoryTypeDialog(context);
    if (selected == null || selected.isEmpty) return false;
  }

  model.text = FarmMaterialTypeCatalogService.stripBrandPrefix(selected);
  return true;
}

Future<String?> _showCustomFarmInventoryTypeDialog(BuildContext context) async {
  final controller = TextEditingController();
  String? error;
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('添加其他耗材类型'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '这里只填写型号，不要带品牌。保存入库后，该型号会进入农场自己的类型目录。',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 60,
                decoration: InputDecoration(
                  labelText: '耗材型号',
                  hintText: '例如 PETG Basic、PLA Matte',
                  errorText: error,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = FarmMaterialTypeCatalogService.stripBrandPrefix(
                controller.text,
              ).trim();
              if (value.length < 2) {
                setState(() => error = '请输入完整型号');
                return;
              }
              Navigator.pop(dialogContext, value);
            },
            child: const Text('添加并使用'),
          ),
        ],
      ),
    ),
  );
  Future<void>.delayed(kThemeAnimationDuration * 2, controller.dispose);
  return result;
}

String _farmInventoryMaterialFamily(String model) {
  final selectedType =
      FarmMaterialTypeCatalogService.stripBrandPrefix(model).trim();
  final family = MaterialIdentityService.normalize(selectedType).family.trim();
  return family.isEmpty ? selectedType : family;
}

enum _FarmInventoryEditAction { cancel, save, archive }

Future<void> _editFarmInventoryGroup(
  BuildContext context,
  WidgetRef ref,
  _FarmInventoryGroup group,
  String workspaceId,
) async {
  final modelCatalog = await ref.read(farmMaterialTypeCatalogProvider.future);
  final brandCatalog = await ref.read(farmBrandCatalogProvider.future);
  if (!context.mounted) return;
  final item = group.representative;
  var brandCode = group.brandCode ??
      FarmBrandCatalogService.normalize(item.manufacturer).code;
  final manufacturer = TextEditingController(
    text: FarmBrandCatalogService.normalize(item.manufacturer).label,
  );
  final model = TextEditingController(
    text: FarmMaterialTypeCatalogService.stripBrandPrefix(
      item.model,
      manufacturer: item.manufacturer,
    ),
  );
  final colorName = TextEditingController(text: item.colorName ?? '');
  final colorHex = TextEditingController(text: item.colorHex);
  final colorMode = TextEditingController(text: group.colorMode);
  final secondaryColorHex = TextEditingController(
    text: group.secondaryColorHex ?? '',
  );
  final note = TextEditingController(text: item.note ?? '');
  final action = await showDialog<_FarmInventoryEditAction>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('编辑同款库存 · ${group.totalRolls} 卷'),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: FarmBrandPickerField(
                      value: manufacturer.text,
                      onTap: () async {
                        final selected = await showFarmBrandPicker(
                          context: context,
                          brands: brandCatalog,
                          selectedCode: brandCode,
                        );
                        if (selected == null || !context.mounted) return;
                        setState(() {
                          brandCode = selected.code;
                          manufacturer.text = selected.label;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: MaterialPickerField(
                      key: const ValueKey('farm-inventory-edit-model-picker'),
                      label: '耗材类型',
                      value: model.text.trim().isEmpty
                          ? '请选择类型'
                          : model.text.trim(),
                      onTap: () async {
                        final changed = await _pickFarmInventoryType(
                          context: context,
                          catalog: modelCatalog,
                          model: model,
                        );
                        if (changed && context.mounted) setState(() {});
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              FarmMaterialColorField(
                hexController: colorHex,
                nameController: colorName,
                modeController: colorMode,
                secondaryHexController: secondaryColorHex,
                label: '耗材颜色',
              ),
              const SizedBox(height: 10),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: '备注'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              _FarmInventoryEditAction.cancel,
            ),
            child: const Text('取消'),
          ),
          TextButton.icon(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (confirmContext) => AlertDialog(
                  title: const Text('归档同款库存'),
                  content: Text(
                    '确认归档这组 ${group.totalRolls} 卷库存？'
                    '入库批次、生产流水和已装机槽位记录都会保留，原余量也会保留。',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(confirmContext, false),
                      child: const Text('取消'),
                    ),
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(confirmContext, true),
                      icon: const Icon(Icons.archive_outlined, size: 17),
                      label: const Text('确认归档'),
                    ),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) {
                Navigator.pop(context, _FarmInventoryEditAction.archive);
              }
            },
            icon: const Icon(Icons.archive_outlined, size: 17),
            label: const Text('归档库存'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _FarmInventoryEditAction.save),
            child: const Text('保存整组'),
          ),
        ],
      ),
    ),
  );
  if (action == null ||
      action == _FarmInventoryEditAction.cancel ||
      !context.mounted) {
    manufacturer.dispose();
    model.dispose();
    colorName.dispose();
    colorHex.dispose();
    colorMode.dispose();
    secondaryColorHex.dispose();
    note.dispose();
    return;
  }
  if (action == _FarmInventoryEditAction.archive) {
    try {
      final dao = ref.read(consumableDaoProvider);
      await dao.archiveFarmConsumables(
        group.items.map((item) => item.id),
        workspaceId: workspaceId,
      );
      await recordCurrentFarmActivity(
        ref,
        actionCode: 'inventory.archived',
        entityType: 'consumable',
        entityId: item.uid,
        summary: '归档同款库存 · ${group.totalRolls} 卷',
      );
      if (context.mounted) showSnack(context, '同款库存已归档，原余量已保留');
    } catch (error) {
      if (context.mounted) showSnack(context, '归档失败：$error', error: true);
    }
    manufacturer.dispose();
    model.dispose();
    colorName.dispose();
    colorHex.dispose();
    colorMode.dispose();
    secondaryColorHex.dispose();
    note.dispose();
    return;
  }
  final normalizedHex = colorHex.text.trim().toUpperCase();
  final normalizedMode = colorMode.text.trim().toLowerCase();
  final normalizedSecondary = secondaryColorHex.text.trim().toUpperCase();
  if (manufacturer.text.trim().isEmpty ||
      model.text.trim().isEmpty ||
      !RegExp(r'^#[0-9A-F]{6}$').hasMatch(normalizedHex) ||
      !const {'solid', 'multi', 'gradient'}.contains(normalizedMode) ||
      (normalizedMode != 'solid' &&
          !RegExp(r'^#[0-9A-F]{6}$').hasMatch(normalizedSecondary))) {
    showSnack(context, '品牌和耗材类型不能为空，颜色必须是 #RRGGBB', error: true);
  } else {
    final materialFamily = _farmInventoryMaterialFamily(model.text);
    final dao = ref.read(consumableDaoProvider);
    for (final source in group.items) {
      await dao.updateConsumable(
        ConsumablesCompanion(
          id: Value(source.id),
          manufacturer: Value(manufacturer.text.trim()),
          model: Value(model.text.trim()),
          materialType: Value(materialFamily),
          colorHex: Value(normalizedHex),
          colorName: Value(
            colorName.text.trim().isEmpty ? null : colorName.text.trim(),
          ),
          note: Value(note.text.trim().isEmpty ? null : note.text.trim()),
          updatedAt: Value(DateTime.now()),
        ),
      );
    }
    await dao.updateFarmConsumableMetadata(
      group.items.map((source) => source.id),
      workspaceId: workspaceId,
      brandCode: brandCode,
      colorMode: normalizedMode,
      secondaryColorHex: normalizedMode == 'solid' ? null : normalizedSecondary,
    );
    await recordCurrentFarmActivity(
      ref,
      actionCode: 'inventory.metadata_updated',
      entityType: 'consumable',
      entityId: item.uid,
      summary:
          '更新库存资料 · ${manufacturer.text.trim()} ${model.text.trim()} $normalizedHex',
    );
    if (context.mounted) showSnack(context, '同款库存资料已整组更新');
  }
  manufacturer.dispose();
  model.dispose();
  colorName.dispose();
  colorHex.dispose();
  colorMode.dispose();
  secondaryColorHex.dispose();
  note.dispose();
}

Future<void> _deleteFarmStock(
  BuildContext context,
  WidgetRef ref,
  _FarmInventoryGroup group,
  String workspaceId,
) async {
  final dao = ref.read(consumableDaoProvider);
  var references = 0;
  for (final item in group.items) {
    references += await dao.farmConsumableReferenceCount(
      item.id,
      workspaceId: workspaceId,
    );
  }
  if (!context.mounted) return;
  if (references > 0) {
    showSnack(
      context,
      '该耗材已绑定打印机或存在生产流水，不能直接删除；可将余量调整为 0 归档。',
      error: true,
    );
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除农场库存卷'),
      content: Text('确认删除「${group.representative.manufacturer} '
          '${group.representative.colorName ?? group.representative.colorHex}」'
          '这一整组 ${group.totalRolls} 卷库存？此操作不可撤销。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除')),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    for (final item in group.items) {
      await dao.deleteFarmConsumable(item.id, workspaceId: workspaceId);
      await ref.read(studioDaoProvider).recordSyncDeletion(
            workspaceId: workspaceId,
            entityType: 'inventoryItem',
            entityId: item.uid,
            notify: false,
          );
    }
    await recordCurrentFarmActivity(
      ref,
      actionCode: 'inventory.deleted',
      entityType: 'consumable',
      entityId: group.representative.uid,
      summary: '删除未使用库存组 · ${group.totalRolls} 卷',
    );
    if (context.mounted) showSnack(context, '同款库存已整组删除');
  } catch (error) {
    if (context.mounted) showSnack(context, '$error', error: true);
  }
}

class _BatchHeader extends StatelessWidget {
  const _BatchHeader();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 11,
      fontWeight: FontWeight.w700,
    );
    return Container(
      height: 36,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(flex: 2, child: Text('批次', style: style)),
          Expanded(flex: 2, child: Text('供应商', style: style)),
          SizedBox(width: 100, child: Text('卷数', style: style)),
          SizedBox(width: 120, child: Text('仓库余量', style: style)),
          SizedBox(width: 150, child: Text('入库时间', style: style)),
          Expanded(child: Text('经办人', style: style)),
          SizedBox(width: 144, child: Text('操作', style: style)),
        ],
      ),
    );
  }
}

class _BatchRow extends StatelessWidget {
  const _BatchRow({
    required this.batch,
    required this.studio,
    required this.inventoryItems,
    required this.canEdit,
    this.memberName,
  });

  final StudioInventoryBatch batch;
  final StudioSnapshot studio;
  final List<Consumable> inventoryItems;
  final bool canEdit;
  final String? memberName;

  @override
  Widget build(BuildContext context) {
    final consumablesById = {
      for (final item in inventoryItems) item.id: item,
    };
    final activeBatchItems = studio.inventoryBatchItems
        .where((item) => item.batchId == batch.id && !item.voided)
        .toList(growable: false);
    final effectiveRollCount = activeBatchItems.fold<int>(
      0,
      (sum, item) => sum + item.rollCount,
    );
    final remainingRolls = activeBatchItems.fold<int>(
      0,
      (sum, item) =>
          sum +
          (consumablesById[item.consumableId]?.remainingGrams ?? 0) ~/ 1000,
    );
    final activity = studio.latestActivityFor('inventory_batch', batch.id);
    return SizedBox(
      height: 62,
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  batch.batchNo,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                _ActivityStamp(event: activity),
              ],
            ),
          ),
          Expanded(flex: 2, child: Text(batch.supplier ?? '未填写')),
          SizedBox(width: 100, child: Text('$effectiveRollCount 卷')),
          SizedBox(
            width: 120,
            child: Text('$remainingRolls 卷'),
          ),
          SizedBox(
            width: 150,
            child:
                Text(DateFormat('yyyy-MM-dd HH:mm').format(batch.receivedAt)),
          ),
          Expanded(child: Text(memberName ?? '未指定')),
          SizedBox(
            width: 144,
            child: Row(
              children: [
                IconButton(
                  tooltip: '调整卷数',
                  onPressed: canEdit
                      ? () => _showAdjustInventoryBatchRollCountsDialog(
                            context,
                            batch,
                            studio,
                            inventoryItems,
                          )
                      : null,
                  icon:
                      const Icon(Icons.format_list_numbered_rounded, size: 18),
                ),
                IconButton(
                  tooltip: '编辑入库批次资料',
                  onPressed: canEdit
                      ? () =>
                          _showEditInventoryBatchDialog(context, batch, studio)
                      : null,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
                IconButton(
                  tooltip: '删除入库批次',
                  onPressed: canEdit
                      ? () => _showDeleteInventoryBatchDialog(
                            context,
                            batch,
                            studio,
                          )
                      : null,
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showDeleteInventoryBatchDialog(
  BuildContext context,
  StudioInventoryBatch batch,
  StudioSnapshot studio,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除入库批次'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定删除批次“${batch.batchNo}”及其全部库存明细吗？'),
            const SizedBox(height: 10),
            Text(
              '只有从未装入打印机、未被工单引用且库存数量没有发生变化的批次才能删除。删除后无法恢复。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('确认删除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final container = ProviderScope.containerOf(context);
  try {
    await container.read(studioDaoProvider).deleteInventoryBatch(
          batchId: batch.id,
          workspaceId: studio.workspace.id,
        );
    if (context.mounted) showSnack(context, '入库批次 ${batch.batchNo} 已删除');
  } catch (error) {
    if (context.mounted) {
      showSnack(context, '删除失败：$error', error: true);
    }
  }
}

Future<void> _showAdjustInventoryBatchRollCountsDialog(
  BuildContext context,
  StudioInventoryBatch batch,
  StudioSnapshot studio,
  List<Consumable> inventoryItems,
) async {
  final container = ProviderScope.containerOf(context);
  final metadata = await container.read(farmConsumableMetadataProvider.future);
  if (!context.mounted) return;
  final items = studio.inventoryBatchItems
      .where((item) => item.batchId == batch.id)
      .toList(growable: false);
  final consumablesById = {
    for (final item in inventoryItems) item.id: item,
  };
  if (items.isEmpty) {
    showSnack(context, '该入库批次没有可调整的耗材明细', error: true);
    return;
  }

  final controllers = {
    for (final item in items)
      if (!item.voided)
        item.id: TextEditingController(text: '${item.rollCount}'),
  };
  var saving = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final parsedCounts = {
          for (final entry in controllers.entries)
            entry.key: int.tryParse(entry.value.text.trim()),
        };
        final valid = parsedCounts.isNotEmpty &&
            parsedCounts.values.every(
              (value) => value != null && value >= 1 && value <= 500,
            );
        final totalRolls = valid
            ? parsedCounts.values.fold<int>(0, (sum, value) => sum + value!)
            : null;
        return AlertDialog(
          title: Text('调整入库批次卷数 · ${batch.batchNo}'),
          content: SizedBox(
            width: 820,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '这里只调整该入库批次的卷数。每卷固定按 1000g 计算，库存卷页面不提供数量或克数调整。',
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 380),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final consumable = consumablesById[item.consumableId];
                      final colorHex = consumable?.colorHex ?? '#9CA3AF';
                      final colorMetadata = metadata[item.consumableId];
                      final title = consumable == null
                          ? '耗材记录 #${item.consumableId}'
                          : '${consumable.manufacturer} · ${consumable.materialType}';
                      final subtitle = consumable == null
                          ? '原 ${item.rollCount} 卷'
                          : '${consumable.model} · '
                              '${consumable.colorName ?? consumable.colorHex} · '
                              '原 ${item.rollCount} 卷'
                              '${item.voided ? ' · 已冲销：${item.voidReason ?? '未填写原因'}' : ''}';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: colorMetadata?.hasMultipleColors ==
                                      true
                                  ? BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          ColorUtils.fromHex(colorHex),
                                          ColorUtils.fromHex(
                                            colorMetadata!.secondaryColorHex!,
                                          ),
                                        ],
                                      ),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outlineVariant,
                                      ),
                                    )
                                  : BoxDecoration(
                                      color: ColorUtils.fromHex(colorHex),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outlineVariant,
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    subtitle,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Text('1000g / 卷'),
                            const SizedBox(width: 16),
                            if (item.voided)
                              const SizedBox(
                                width: 190,
                                child: Text(
                                  '已冲销（保留审计记录）',
                                  textAlign: TextAlign.right,
                                ),
                              )
                            else ...[
                              SizedBox(
                                width: 96,
                                child: TextField(
                                  controller: controllers[item.id],
                                  enabled: !saving,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: '新卷数',
                                    suffixText: '卷',
                                    isDense: true,
                                  ),
                                  onChanged: (_) => setState(() {}),
                                ),
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                onPressed: saving
                                    ? null
                                    : () async {
                                        final reason =
                                            await _showVoidBatchItemReasonDialog(
                                          context,
                                        );
                                        if (reason == null ||
                                            !context.mounted) {
                                          return;
                                        }
                                        setState(() => saving = true);
                                        try {
                                          await container
                                              .read(studioDaoProvider)
                                              .voidInventoryBatchItem(
                                                itemId: item.id,
                                                workspaceId:
                                                    studio.workspace.id,
                                                reason: reason,
                                                memberId: batch.memberId,
                                              );
                                          if (context.mounted) {
                                            Navigator.pop(context);
                                            showSnack(context, '该入库明细已冲销');
                                          }
                                        } catch (error) {
                                          if (context.mounted) {
                                            setState(() => saving = false);
                                            showSnack(
                                              context,
                                              '冲销失败：$error',
                                              error: true,
                                            );
                                          }
                                        }
                                      },
                                icon: const Icon(Icons.undo_rounded, size: 16),
                                label: const Text('冲销本条'),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  totalRolls == null
                      ? '每条明细请输入 1-500 卷'
                      : '调整后合计：$totalRolls 卷 · '
                          '${totalRolls * 1000}g（${totalRolls}kg）',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: valid
                        ? Theme.of(context).colorScheme.onSurface
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: saving || !valid
                  ? null
                  : () async {
                      setState(() => saving = true);
                      try {
                        await container
                            .read(studioDaoProvider)
                            .updateInventoryBatchRollCounts(
                              batchId: batch.id,
                              workspaceId: studio.workspace.id,
                              rollCountsByItem: {
                                for (final entry in parsedCounts.entries)
                                  entry.key: entry.value!,
                              },
                              memberId: batch.memberId,
                            );
                        if (context.mounted) {
                          Navigator.pop(context);
                          showSnack(context, '入库批次卷数已更新');
                        }
                      } catch (error) {
                        if (context.mounted) {
                          setState(() => saving = false);
                          showSnack(context, '调整失败：$error', error: true);
                        }
                      }
                    },
              child: Text(saving ? '保存中' : '保存卷数'),
            ),
          ],
        );
      },
    ),
  );
  for (final controller in controllers.values) {
    controller.dispose();
  }
}

Future<String?> _showVoidBatchItemReasonDialog(BuildContext context) async {
  final reason = TextEditingController();
  String? error;
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('冲销错误入库明细'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '冲销后该条明细仍会保留用于审计，关联库存会归档且可用余量清零。此操作不能直接撤销。',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reason,
                autofocus: true,
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: '冲销原因',
                  hintText: '例如：品牌录错、重复入库、到货数量错误',
                  errorText: error,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = reason.text.trim();
              if (value.isEmpty) {
                setState(() => error = '请填写冲销原因');
                return;
              }
              Navigator.pop(dialogContext, value);
            },
            child: const Text('确认冲销'),
          ),
        ],
      ),
    ),
  );
  Future<void>.delayed(kThemeAnimationDuration * 2, reason.dispose);
  return result;
}

Future<void> _showEditInventoryBatchDialog(
  BuildContext context,
  StudioInventoryBatch batch,
  StudioSnapshot studio,
) async {
  final container = ProviderScope.containerOf(context);
  final batchNo = TextEditingController(text: batch.batchNo);
  final supplier = TextEditingController(text: batch.supplier ?? '');
  final note = TextEditingController(text: batch.note ?? '');
  var receivedAt = batch.receivedAt;
  var memberId = batch.memberId ?? '';
  var saving = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('编辑入库批次'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: batchNo,
                      decoration: const InputDecoration(labelText: '批次号'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: supplier,
                      decoration: const InputDecoration(labelText: '供应商'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: saving
                          ? null
                          : () async {
                              final date = await showDatePicker(
                                context: context,
                                initialDate: receivedAt,
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2100),
                              );
                              if (date == null || !context.mounted) return;
                              final time = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.fromDateTime(receivedAt),
                              );
                              if (time == null) return;
                              setState(() {
                                receivedAt = DateTime(
                                  date.year,
                                  date.month,
                                  date.day,
                                  time.hour,
                                  time.minute,
                                );
                              });
                            },
                      icon: const Icon(Icons.schedule_outlined, size: 18),
                      label: Text(
                        DateFormat('yyyy-MM-dd HH:mm').format(receivedAt),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: memberId,
                      decoration: const InputDecoration(labelText: '经办人'),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('未指定')),
                        for (final member
                            in studio.members.where((item) => item.active))
                          DropdownMenuItem(
                            value: member.id,
                            child: Text(member.displayName),
                          ),
                      ],
                      onChanged: saving
                          ? null
                          : (value) => setState(() => memberId = value ?? ''),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: '整批备注'),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    if (batchNo.text.trim().isEmpty) {
                      showSnack(context, '请填写批次号', error: true);
                      return;
                    }
                    setState(() => saving = true);
                    try {
                      await container
                          .read(studioDaoProvider)
                          .updateInventoryBatch(
                            id: batch.id,
                            workspaceId: studio.workspace.id,
                            batchNo: batchNo.text,
                            supplier: supplier.text,
                            receivedAt: receivedAt,
                            note: note.text,
                            memberId: memberId.isEmpty ? null : memberId,
                          );
                      if (context.mounted) {
                        Navigator.pop(context);
                        showSnack(context, '入库批次已更新');
                      }
                    } catch (error) {
                      if (context.mounted) {
                        setState(() => saving = false);
                        showSnack(context, '保存失败：$error', error: true);
                      }
                    }
                  },
            child: Text(saving ? '保存中' : '保存'),
          ),
        ],
      ),
    ),
  );
  batchNo.dispose();
  supplier.dispose();
  note.dispose();
}

Future<void> _showFarmSingleReceiveDialog(
  BuildContext context,
  WidgetRef ref,
  StudioSnapshot studio,
) async {
  final modelCatalog = await ref.read(farmMaterialTypeCatalogProvider.future);
  final brandCatalog = await ref.read(farmBrandCatalogProvider.future);
  if (!context.mounted) return;
  final batchNo = TextEditingController(
    text: 'IN-${DateFormat('yyMMdd-HHmm').format(DateTime.now())}',
  );
  final supplier = TextEditingController();
  final note = TextEditingController();
  final line = _BatchLineDraft();
  var receivedAt = DateTime.now();
  String? memberId;
  var saving = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 700),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '农场耗材入库',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: saving ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                Text(
                  '这是独立的农场入库流程；按物料品种记录卷数，每卷固定 1000g。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: batchNo,
                        decoration: const InputDecoration(labelText: '到货批次号'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: supplier,
                        decoration: const InputDecoration(labelText: '供应商'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: memberId,
                        decoration: const InputDecoration(labelText: '经办成员'),
                        items: studio.members
                            .where((item) => item.active)
                            .map(
                              (item) => DropdownMenuItem(
                                value: item.id,
                                child: Text(item.displayName),
                              ),
                            )
                            .toList(),
                        onChanged: (value) => setState(() => memberId = value),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: saving
                            ? null
                            : () async {
                                final selected =
                                    await _pickFarmInventoryDateTime(
                                  context,
                                  receivedAt,
                                );
                                if (selected != null) {
                                  setState(() => receivedAt = selected);
                                }
                              },
                        icon: const Icon(Icons.schedule_outlined, size: 17),
                        label: Text(
                          '入库时间 ${DateFormat('yyyy-MM-dd HH:mm').format(receivedAt)}',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(FarmPalette.radius),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: FarmBrandPickerField(
                              value: line.manufacturer.text,
                              onTap: () async {
                                final selected = await showFarmBrandPicker(
                                  context: context,
                                  brands: brandCatalog,
                                  selectedCode: line.brandCode,
                                );
                                if (selected == null || !context.mounted)
                                  return;
                                setState(() {
                                  line.brandCode = selected.code;
                                  line.manufacturer.text = selected.label;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: MaterialPickerField(
                              key: const ValueKey(
                                'farm-single-model-picker',
                              ),
                              label: '耗材类型',
                              value: line.model.text.trim().isEmpty
                                  ? '请选择类型'
                                  : line.model.text.trim(),
                              onTap: () async {
                                final changed = await _pickFarmInventoryType(
                                  context: context,
                                  catalog: modelCatalog,
                                  model: line.model,
                                );
                                if (changed && context.mounted) {
                                  setState(() {});
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      FarmMaterialColorField(
                        hexController: line.colorHex,
                        nameController: line.colorName,
                        modeController: line.colorMode,
                        secondaryHexController: line.secondaryColorHex,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          SizedBox(
                            width: 150,
                            child: TextField(
                              controller: line.rolls,
                              keyboardType: TextInputType.number,
                              decoration:
                                  const InputDecoration(labelText: '入库卷数'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: InputDecorator(
                              decoration: InputDecoration(labelText: '单卷重量'),
                              child: Text(
                                '1000 g / 卷',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 180,
                            child: TextField(
                              controller: line.unitCost,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration:
                                  const InputDecoration(labelText: '采购价（元/卷）'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: '入库备注'),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: saving ? null : () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: saving
                          ? null
                          : () async {
                              final parsed = line.parse();
                              if (parsed == null ||
                                  batchNo.text.trim().isEmpty) {
                                showSnack(
                                  context,
                                  '请填写批次、品牌，选择耗材类型，并填写颜色和 1-500 的卷数',
                                  error: true,
                                );
                                return;
                              }
                              setState(() => saving = true);
                              try {
                                await ref
                                    .read(studioDaoProvider)
                                    .receiveInventoryBatch(
                                      workspaceId: studio.workspace.id,
                                      batchNo: batchNo.text,
                                      supplier: supplier.text,
                                      receivedAt: receivedAt,
                                      lines: [parsed],
                                      note: note.text,
                                      memberId: memberId,
                                    );
                                if (context.mounted) {
                                  Navigator.pop(context);
                                  showSnack(
                                    context,
                                    '耗材已入库 ${parsed.rolls} 卷',
                                  );
                                }
                              } catch (error) {
                                if (context.mounted) {
                                  setState(() => saving = false);
                                  showSnack(context, '入库失败：$error',
                                      error: true);
                                }
                              }
                            },
                      icon: saving
                          ? const SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.inventory_2_outlined, size: 17),
                      label: Text(saving ? '正在入库' : '确认入库'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  batchNo.dispose();
  supplier.dispose();
  note.dispose();
  line.dispose();
}

Future<DateTime?> _pickFarmInventoryDateTime(
  BuildContext context,
  DateTime initial,
) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(2020),
    lastDate: DateTime.now().add(const Duration(days: 365)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

Future<void> _showBatchReceiveDialog(
  BuildContext context,
  WidgetRef ref,
  StudioSnapshot studio,
) async {
  final modelCatalog = await ref.read(farmMaterialTypeCatalogProvider.future);
  final brandCatalog = await ref.read(farmBrandCatalogProvider.future);
  if (!context.mounted) return;
  final batchNo = TextEditingController(
    text: 'IN-${DateFormat('yyMMdd-HHmm').format(DateTime.now())}',
  );
  final supplier = TextEditingController();
  final note = TextEditingController();
  final lines = <_BatchLineDraft>[_BatchLineDraft()];
  var receivedAt = DateTime.now();
  String? memberId;
  var saving = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '批量入库',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: saving ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: batchNo,
                        decoration: const InputDecoration(labelText: '到货批次号'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: supplier,
                        decoration: const InputDecoration(labelText: '供应商'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: memberId,
                        decoration: const InputDecoration(labelText: '经办人'),
                        items: studio.members
                            .where((item) => item.active)
                            .map(
                              (item) => DropdownMenuItem(
                                value: item.id,
                                child: Text(item.displayName),
                              ),
                            )
                            .toList(),
                        onChanged: (value) => setState(() => memberId = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: saving
                        ? null
                        : () async {
                            final value = await _pickFarmInventoryDateTime(
                              context,
                              receivedAt,
                            );
                            if (value == null) return;
                            setState(() => receivedAt = value);
                          },
                    icon: const Icon(Icons.schedule_rounded, size: 17),
                    label: Text(
                      '入库时间：${DateFormat('yyyy-MM-dd HH:mm').format(receivedAt)}',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView.separated(
                    itemCount: lines.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _BatchLineEditor(
                      index: index,
                      draft: lines[index],
                      modelCatalog: modelCatalog,
                      brandCatalog: brandCatalog,
                      onModelChanged: () => setState(() {}),
                      canRemove: lines.length > 1,
                      onRemove: () => setState(() {
                        lines.removeAt(index).dispose();
                      }),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: saving
                          ? null
                          : () => setState(() => lines.add(_BatchLineDraft())),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('增加明细'),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 260,
                      child: TextField(
                        controller: note,
                        decoration: const InputDecoration(labelText: '整批备注'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: saving
                          ? null
                          : () async {
                              final parsed = <StudioBatchReceiveLine>[];
                              for (final line in lines) {
                                final value = line.parse();
                                if (value == null) {
                                  showSnack(
                                    context,
                                    '请完整填写每条明细并选择耗材类型；卷数必须在 1-500 卷',
                                    error: true,
                                  );
                                  return;
                                }
                                parsed.add(value);
                              }
                              if (batchNo.text.trim().isEmpty) {
                                showSnack(context, '请填写到货批次号', error: true);
                                return;
                              }
                              setState(() => saving = true);
                              try {
                                await ref
                                    .read(studioDaoProvider)
                                    .receiveInventoryBatch(
                                      workspaceId: studio.workspace.id,
                                      batchNo: batchNo.text,
                                      supplier: supplier.text,
                                      receivedAt: receivedAt,
                                      lines: parsed,
                                      note: note.text,
                                      memberId: memberId,
                                    );
                                if (context.mounted) {
                                  Navigator.pop(context);
                                  showSnack(
                                    context,
                                    '批量入库完成，共新增 ${parsed.fold<int>(0, (sum, item) => sum + item.rolls)} 卷',
                                  );
                                }
                              } catch (error) {
                                if (context.mounted) {
                                  setState(() => saving = false);
                                  showSnack(
                                    context,
                                    '批量入库失败：$error',
                                    error: true,
                                  );
                                }
                              }
                            },
                      icon: saving
                          ? const SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.inventory_2_outlined, size: 17),
                      label: Text(saving ? '正在入库' : '确认入库'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  batchNo.dispose();
  supplier.dispose();
  note.dispose();
  for (final line in lines) {
    line.dispose();
  }
}

class _BatchLineDraft {
  final manufacturer = TextEditingController();
  String? brandCode;
  final model = TextEditingController();
  final colorHex = TextEditingController(text: '#FFFFFF');
  final colorName = TextEditingController();
  final colorMode = TextEditingController(text: 'solid');
  final secondaryColorHex = TextEditingController();
  final rolls = TextEditingController(text: '1');
  final unitCost = TextEditingController(text: '0');

  StudioBatchReceiveLine? parse() {
    final rollCount = int.tryParse(rolls.text.trim());
    final cost = double.tryParse(unitCost.text.trim()) ?? 0;
    final hex = colorHex.text.trim().toUpperCase();
    final mode = colorMode.text.trim().toLowerCase();
    final secondary = secondaryColorHex.text.trim().toUpperCase();
    if (manufacturer.text.trim().isEmpty ||
        brandCode == null ||
        brandCode!.trim().isEmpty ||
        model.text.trim().isEmpty ||
        rollCount == null ||
        rollCount <= 0 ||
        rollCount > 500 ||
        !RegExp(r'^#[0-9A-F]{6}$').hasMatch(hex) ||
        !const {'solid', 'multi', 'gradient'}.contains(mode) ||
        (mode != 'solid' && !RegExp(r'^#[0-9A-F]{6}$').hasMatch(secondary))) {
      return null;
    }
    return StudioBatchReceiveLine(
      manufacturer: manufacturer.text.trim(),
      brandCode: brandCode,
      model: model.text.trim(),
      materialType: _farmInventoryMaterialFamily(model.text),
      colorHex: hex,
      colorName: colorName.text.trim().isEmpty ? null : colorName.text.trim(),
      colorMode: mode,
      secondaryColorHex: mode == 'solid' ? null : secondary,
      rolls: rollCount,
      gramsPerRoll: 1000,
      unitCost: cost,
    );
  }

  void dispose() {
    manufacturer.dispose();
    model.dispose();
    colorHex.dispose();
    colorName.dispose();
    colorMode.dispose();
    secondaryColorHex.dispose();
    rolls.dispose();
    unitCost.dispose();
  }
}

class _BatchLineEditor extends StatelessWidget {
  const _BatchLineEditor({
    required this.index,
    required this.draft,
    required this.modelCatalog,
    required this.brandCatalog,
    required this.onModelChanged,
    required this.canRemove,
    required this.onRemove,
  });

  final int index;
  final _BatchLineDraft draft;
  final List<String> modelCatalog;
  final List<FarmBrandOption> brandCatalog;
  final VoidCallback onModelChanged;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('${index + 1}', textAlign: TextAlign.center),
          ),
          Expanded(
            flex: 2,
            child: FarmBrandPickerField(
              dense: true,
              value: draft.manufacturer.text,
              onTap: () async {
                final selected = await showFarmBrandPicker(
                  context: context,
                  brands: brandCatalog,
                  selectedCode: draft.brandCode,
                );
                if (selected == null || !context.mounted) return;
                draft.brandCode = selected.code;
                draft.manufacturer.text = selected.label;
                onModelChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: MaterialPickerField(
              key: ValueKey('farm-batch-model-picker-$index'),
              label: '耗材类型',
              value: draft.model.text.trim().isEmpty
                  ? '请选择类型'
                  : draft.model.text.trim(),
              onTap: () async {
                final changed = await _pickFarmInventoryType(
                  context: context,
                  catalog: modelCatalog,
                  model: draft.model,
                );
                if (changed && context.mounted) onModelChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: FarmMaterialColorField(
              hexController: draft.colorHex,
              nameController: draft.colorName,
              modeController: draft.colorMode,
              secondaryHexController: draft.secondaryColorHex,
              dense: true,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 74,
            child: TextField(
              controller: draft.rolls,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '卷数', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          const SizedBox(
            width: 94,
            child: Text(
              '1000g / 卷',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 94,
            child: TextField(
              controller: draft.unitCost,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: '元/卷', isDense: true),
            ),
          ),
          IconButton(
            tooltip: '删除明细',
            onPressed: canRemove ? onRemove : null,
            icon: const Icon(Icons.delete_outline_rounded, size: 19),
          ),
        ],
      ),
    );
  }
}

class _FarmPage extends StatelessWidget {
  const _FarmPage({
    required this.title,
    required this.subtitle,
    required this.child,
    this.actions = const [],
  });

  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FarmPageHeader(
            title: title,
            subtitle: subtitle,
            actions: actions,
          ),
          const SizedBox(height: 16),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _FarmSummaryBar extends StatelessWidget {
  const _FarmSummaryBar({required this.items});

  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          for (var index = 0; index < items.length; index++) ...[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      items[index].$1,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      items[index].$2,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (index != items.length - 1)
              VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
          ],
        ],
      ),
    );
  }
}

class _FarmEmpty extends StatelessWidget {
  const _FarmEmpty({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 10),
          Text(
            text,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityStamp extends StatelessWidget {
  const _ActivityStamp({required this.event});

  final StudioActivityEvent? event;

  @override
  Widget build(BuildContext context) {
    final value = event;
    if (value == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_rounded,
            size: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              '${value.actorDisplayName} · '
              '${DateFormat('MM-dd HH:mm').format(value.createdAt)} · '
              '${value.summary}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

String _schedulerStatusLabel(SchedulerTaskStatus status) => switch (status) {
      SchedulerTaskStatus.pending => '等待调度',
      SchedulerTaskStatus.assigned => '已分配',
      SchedulerTaskStatus.printing => '打印中',
      SchedulerTaskStatus.completed => '已完成',
      SchedulerTaskStatus.failed => '失败',
      SchedulerTaskStatus.cancelled => '已取消',
      SchedulerTaskStatus.blocked => '受阻',
    };

Color _schedulerStatusColor(SchedulerTaskStatus status, ColorScheme scheme) =>
    switch (status) {
      SchedulerTaskStatus.completed => FarmVisual.primary,
      SchedulerTaskStatus.printing => scheme.primary,
      SchedulerTaskStatus.failed ||
      SchedulerTaskStatus.blocked =>
        FarmVisual.danger,
      SchedulerTaskStatus.cancelled => scheme.outline,
      _ => FarmVisual.warning,
    };
