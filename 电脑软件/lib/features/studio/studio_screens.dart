import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/database.dart';
import '../../data/database/models/filament_cost_config.dart';
import '../../data/database/models/studio_models.dart';
import '../../providers/app_auth_provider.dart';
import '../../providers/filament_cost_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/scheduler_provider.dart';
import '../../providers/studio_provider.dart';
import '../../ui/workspace_navigation.dart';
import 'farm_ui/farm_design.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_ui/farm_components.dart';
import 'studio_work_order_materials.dart';
import 'studio_quote_config_panel.dart';

final _currency = NumberFormat.currency(
  locale: 'zh_CN',
  symbol: '¥',
  decimalDigits: 2,
);

class StudioOverviewScreen extends ConsumerWidget {
  const StudioOverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final sync = ref.watch(studioSyncControllerProvider);
    final signedIn =
        ref.watch(appAuthProvider.select((state) => state.isSignedIn));
    final consumables =
        ref.watch(farmConsumablesProvider).valueOrNull ?? const [];
    final printers =
        ref.watch(printersWithChannelsProvider).valueOrNull ?? const [];
    final scheduler = ref.watch(schedulerTasksProvider).valueOrNull ?? const [];
    return _StudioPage(
      title: snapshot.valueOrNull?.workspace.name ?? '打印农场',
      description: '把设备、库存、订单、团队和利润放进同一条生产链，日常打印仍保持原来的轻量工作台。',
      actions: [
        AppButton(
          label: sync.isSyncing
              ? '正在同步'
              : signedIn
                  ? '同步工作室'
                  : '仅本地模式',
          variant: AppButtonVariant.secondary,
          icon: Icon(
            sync.isSyncing ? Icons.sync_rounded : Icons.cloud_sync_outlined,
            size: 16,
          ),
          onPressed: sync.isSyncing
              ? null
              : () {
                  if (!signedIn) {
                    showSnack(context, '登录 sohun 云后即可同步团队和客户进度页');
                    return;
                  }
                  ref.read(studioSyncControllerProvider.notifier).requestNow();
                },
        ),
      ],
      child: snapshot.when(
        loading: _loading,
        error: _error,
        data: (data) {
          final remaining = consumables.fold<double>(
            0,
            (sum, item) => sum + item.remainingGrams,
          );
          final activeTasks =
              scheduler.where((item) => !item.status.isTerminal);
          final upcoming = [...data.orders]
            ..removeWhere(
              (item) =>
                  item.status == StudioOrderStatus.cancelled ||
                  item.status == StudioOrderStatus.delivered,
            )
            ..sort((a, b) {
              if (a.dueAt == null) return 1;
              if (b.dueAt == null) return -1;
              return a.dueAt!.compareTo(b.dueAt!);
            });
          return ListView(
            children: [
              FarmPrinterSpatialCanvas(
                printers: printers,
                onPrinterTap: (_) {
                  ref.read(workspaceNavigationRequestProvider.notifier).state =
                      WorkspacePageIds.studioMaterials;
                },
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 1080
                      ? 4
                      : constraints.maxWidth >= 620
                          ? 2
                          : 1;
                  return GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: columns,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: columns == 1 ? 4.2 : 2.8,
                    children: [
                      MetricTile(
                        label: '在线生产设备',
                        value: '${printers.length}',
                        unit: '台已配置',
                        icon: 'printer',
                        color: FarmVisual.primary,
                      ),
                      MetricTile(
                        label: '待完成订单',
                        value: '${data.activeOrderCount}',
                        unit: '个订单',
                        icon: 'monitor_item_print',
                        color: FarmVisual.blue,
                      ),
                      MetricTile(
                        label: '批次完成率',
                        value:
                            (data.batchCompletionRate * 100).toStringAsFixed(0),
                        unit: '%',
                        icon: 'completed',
                        color: FarmVisual.primary,
                      ),
                      MetricTile(
                        label: '可用耗材',
                        value: (remaining / 1000).toStringAsFixed(1),
                        unit: 'kg',
                        icon: 'spool',
                        color: FarmVisual.warning,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 22),
              LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 840;
                  final queue = _OverviewSection(
                    title: '生产队列',
                    subtitle: '${activeTasks.length} 个任务正在等待或执行',
                    child: activeTasks.isEmpty
                        ? const _InlineEmpty('目前没有待调度任务')
                        : Column(
                            children: activeTasks.take(6).map((task) {
                              return _InfoRow(
                                title: task.gcodeFilename,
                                subtitle: task.assignedPrinterName ?? '等待分配打印机',
                                trailing: StatusPill(
                                  label: _schedulerStatusLabel(task.status),
                                  color: _schedulerStatusColor(task.status),
                                ),
                              );
                            }).toList(),
                          ),
                  );
                  final orders = _OverviewSection(
                    title: '最近交期',
                    subtitle: '优先展示仍需交付的客户订单',
                    child: upcoming.isEmpty
                        ? const _InlineEmpty('还没有客户订单')
                        : Column(
                            children: upcoming.take(6).map((order) {
                              return _InfoRow(
                                title: order.title,
                                subtitle: order.dueAt == null
                                    ? order.orderNo
                                    : '${order.orderNo} · ${DateFormat('MM-dd').format(order.dueAt!)}交付',
                                trailing: StatusPill(
                                  label: _orderStatusLabel(order.status),
                                  color: _orderStatusColor(order.status),
                                ),
                              );
                            }).toList(),
                          ),
                  );
                  if (!wide) {
                    return Column(
                      children: [queue, const SizedBox(height: 14), orders],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: queue),
                      const SizedBox(width: 14),
                      Expanded(child: orders),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              _OverviewSection(
                title: '经营快照',
                subtitle: '仅统计客户已接受的正式报价，不混入即时报价工具',
                child: Row(
                  children: [
                    Expanded(
                      child: _FinanceNumber(
                        label: '已接受报价收入',
                        value: _currency.format(data.acceptedRevenue),
                      ),
                    ),
                    Expanded(
                      child: _FinanceNumber(
                        label: '预计利润',
                        value: _currency.format(data.acceptedProfit),
                      ),
                    ),
                    Expanded(
                      child: _FinanceNumber(
                        label: '活跃成员',
                        value:
                            '${data.members.where((item) => item.active).length} 人',
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

class StudioSharedInventoryScreen extends ConsumerWidget {
  const StudioSharedInventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final inventory = ref.watch(farmConsumablesProvider);
    return _StudioPage(
      title: '共享库存',
      description: '所有成员围绕同一份真实库存协作；每次补货、领用、盘点和归还都会留下流水。',
      child: snapshot.when(
        loading: _loading,
        error: _error,
        data: (studio) => inventory.when(
          loading: _loading,
          error: _error,
          data: (items) {
            if (items.isEmpty) {
              return const EmptyState(
                icon: Icons.inventory_2_outlined,
                title: '库存还是空的',
                subtitle: '先在耗材库存中建立耗材，再由团队记录领用和补充。',
              );
            }
            final eventsByConsumable = <int, StudioInventoryEvent>{};
            for (final event in studio.inventoryEvents) {
              eventsByConsumable.putIfAbsent(event.consumableId, () => event);
            }
            return ListView(
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: items.map((item) {
                    final color = parseHexColor(item.colorHex);
                    final last = eventsByConsumable[item.id];
                    return SizedBox(
                      width: 330,
                      child: FrostPanel(
                        padding: const EdgeInsets.all(15),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outlineVariant,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${item.manufacturer} · ${item.materialType}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Text(
                                        item.colorName ?? item.colorHex,
                                        style: FarmVisual.label(context),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  formatGrams(item.remainingGrams),
                                  style: FarmVisual.mono.copyWith(fontSize: 17),
                                ),
                              ],
                            ),
                            if (last != null) ...[
                              const SizedBox(height: 11),
                              Text(
                                '最近：${last.deltaGrams >= 0 ? '+' : ''}${last.deltaGrams.toStringAsFixed(0)} g · ${last.reason}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: FarmVisual.label(context),
                              ),
                            ],
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                AppButton(
                                  label: '记录变动',
                                  variant: AppButtonVariant.secondary,
                                  icon: const Icon(
                                    Icons.swap_vert_rounded,
                                    size: 16,
                                  ),
                                  onPressed: () => _showInventoryDialog(
                                    context,
                                    ref,
                                    studio,
                                    item,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 24),
                const FarmSectionHeading(title: '库存流水 · 最近 200 条'),
                FrostPanel(
                  padding: EdgeInsets.zero,
                  child: studio.inventoryEvents.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: _InlineEmpty('还没有团队库存流水'),
                        )
                      : Column(
                          children:
                              studio.inventoryEvents.take(30).map((event) {
                            final item = items
                                .where(
                                  (value) => value.id == event.consumableId,
                                )
                                .firstOrNull;
                            final member = studio.members
                                .where((value) => value.id == event.memberId)
                                .firstOrNull;
                            return _InfoRow(
                              title: item == null
                                  ? '已删除耗材'
                                  : '${item.manufacturer} · ${item.materialType} · ${item.colorName ?? item.colorHex}',
                              subtitle:
                                  '${member?.displayName ?? '未指定成员'} · ${event.reason} · ${formatDate(event.createdAt)}',
                              trailing: Text(
                                '${event.deltaGrams >= 0 ? '+' : ''}${event.deltaGrams.toStringAsFixed(0)} g',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: event.deltaGrams >= 0
                                      ? FarmVisual.primary
                                      : FarmVisual.danger,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class StudioCustomersScreen extends ConsumerWidget {
  const StudioCustomersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final role = ref.watch(currentStudioRoleProvider);
    final canManage =
        role == StudioMemberRole.owner || role == StudioMemberRole.admin;
    return _StudioPage(
      title: '客户管理',
      description: '保存联系人和交付备注，订单、报价和客户进度页都从这里关联。',
      actions: [
        AppButton(
          label: '添加客户',
          icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
          onPressed: snapshot.valueOrNull == null || !canManage
              ? null
              : () => showStudioCustomerDialog(
                    context,
                    ref,
                    snapshot.value!.workspace,
                  ),
        ),
      ],
      child: snapshot.when(
        loading: _loading,
        error: _error,
        data: (data) {
          if (data.customers.isEmpty) {
            return const EmptyState(
              icon: Icons.groups_2_outlined,
              title: '还没有客户',
              subtitle: '建立客户后，就能把报价、订单和交付进度统一归档。',
            );
          }
          return ListView.separated(
            itemCount: data.customers.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final customer = data.customers[index];
              final orderCount = data.orders
                  .where((order) => order.customerId == customer.id)
                  .length;
              return FrostPanel(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor:
                          FarmVisual.primary.withValues(alpha: 0.12),
                      foregroundColor: FarmVisual.primary,
                      child: Text(
                        customer.name.characters.first.toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  customer.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                              if (customer.archived) ...[
                                const SizedBox(width: 8),
                                StatusPill(
                                    label: '已归档', color: FarmVisual.muted),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            [
                              customer.contactName,
                              customer.phone,
                              customer.email,
                              '$orderCount 个订单',
                            ]
                                .whereType<String>()
                                .where((e) => e.isNotEmpty)
                                .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: FarmVisual.label(context),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: !customer.archived,
                      onChanged: !canManage
                          ? null
                          : (active) => ref
                              .read(studioDaoProvider)
                              .setCustomerArchived(customer.id, !active),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class StudioOrdersScreen extends ConsumerWidget {
  const StudioOrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final role = ref.watch(currentStudioRoleProvider);
    final canManage =
        role == StudioMemberRole.owner || role == StudioMemberRole.admin;
    return _StudioPage(
      title: '订单与工单',
      description: '客户订单负责交付承诺，工单负责实际生产；一个订单可以拆成多个批次、设备和成员。',
      actions: [
        AppButton(
          label: '新建订单',
          icon: const Icon(Icons.add_rounded, size: 16),
          onPressed: snapshot.valueOrNull == null || !canManage
              ? null
              : () => showStudioOrderDialog(context, ref, snapshot.value!),
        ),
      ],
      child: snapshot.when(
        loading: _loading,
        error: _error,
        data: (data) {
          if (data.orders.isEmpty) {
            return const EmptyState(
              icon: Icons.assignment_outlined,
              title: '还没有订单',
              subtitle: '新建订单后可继续拆分工单，并关联现有调度任务和打印机。',
            );
          }
          return ListView.separated(
            itemCount: data.orders.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final order = data.orders[index];
              final customer = data.customers
                  .where((item) => item.id == order.customerId)
                  .firstOrNull;
              final workOrders = data.workOrders
                  .where((item) => item.orderId == order.id)
                  .toList();
              final shareLink = data.shareLinks
                  .where((item) => item.orderId == order.id && item.active)
                  .firstOrNull;
              final linkedQuote = data.quotes
                  .where((item) => item.orderId == order.id)
                  .firstOrNull;
              final quoteNeedsReview =
                  linkedQuote?.note?.startsWith('待核对') == true;
              final total = workOrders.fold<int>(
                0,
                (sum, item) => sum + item.quantity,
              );
              final completed = workOrders.fold<int>(
                0,
                (sum, item) => sum + item.completedQuantity,
              );
              return FrostPanel(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      order.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 9),
                                  StatusPill(
                                    label: _orderStatusLabel(order.status),
                                    color: _orderStatusColor(order.status),
                                  ),
                                  if (quoteNeedsReview) ...[
                                    const SizedBox(width: 7),
                                    const StatusPill(
                                      label: '报价待核对',
                                      color: FarmVisual.warning,
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 5),
                              Text(
                                [
                                  order.orderNo,
                                  customer?.name ?? '未关联客户',
                                  if (order.dueAt != null)
                                    '${DateFormat('yyyy-MM-dd').format(order.dueAt!)} 交付',
                                  _currency.format(order.totalPrice),
                                ].join(' · '),
                                style: FarmVisual.label(context),
                              ),
                            ],
                          ),
                        ),
                        AppButton(
                          label: '添加工单',
                          variant: AppButtonVariant.secondary,
                          icon: const Icon(Icons.add_task_rounded, size: 16),
                          onPressed: !canManage
                              ? null
                              : () => showStudioWorkOrderDialog(
                                    context,
                                    ref,
                                    data,
                                    order,
                                  ),
                        ),
                        const SizedBox(width: 8),
                        if (shareLink == null && canManage)
                          IconButton(
                            tooltip: '创建客户只读进度链接',
                            onPressed: () => createStudioCustomerShare(
                              context,
                              ref,
                              order,
                            ),
                            icon: const Icon(Icons.link_rounded),
                          )
                        else if (shareLink != null && canManage)
                          PopupMenuButton<String>(
                            tooltip: '客户进度链接',
                            onSelected: (action) => handleStudioShareAction(
                              context,
                              ref,
                              shareLink,
                              action,
                            ),
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'copy',
                                child: Text('复制客户进度链接'),
                              ),
                              PopupMenuItem(
                                value: 'revoke',
                                child: Text('撤销链接'),
                              ),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(
                                Icons.link_rounded,
                                color: FarmVisual.primary,
                              ),
                            ),
                          ),
                        if (canManage)
                          PopupMenuButton<StudioOrderStatus>(
                            tooltip: '更新订单状态',
                            onSelected: (status) => ref
                                .read(studioDaoProvider)
                                .updateOrderStatus(order.id, status),
                            itemBuilder: (_) => StudioOrderStatus.values
                                .map(
                                  (status) => PopupMenuItem(
                                    value: status,
                                    child: Text(_orderStatusLabel(status)),
                                  ),
                                )
                                .toList(),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 7,
                        value: total == 0 ? 0 : completed / total,
                        backgroundColor: FarmVisual.fill,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      total == 0 ? '尚未拆分工单' : '批次完成 $completed / $total',
                      style: FarmVisual.label(context),
                    ),
                    if (workOrders.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Divider(height: 1, color: FarmVisual.line),
                      for (final workOrder in workOrders)
                        _WorkOrderRow(
                          workOrder: workOrder,
                          materials: data.workOrderMaterials
                              .where(
                                (item) => item.workOrderId == workOrder.id,
                              )
                              .toList(),
                          member: data.members
                              .where(
                                (item) => item.id == workOrder.assignedMemberId,
                              )
                              .firstOrNull,
                          onManageMaterials: () =>
                              showStudioMaterialAllocationDialog(
                            context,
                            ref,
                            workOrder: workOrder,
                            materials: data.workOrderMaterials
                                .where(
                                  (item) => item.workOrderId == workOrder.id,
                                )
                                .toList(),
                          ),
                          onUpdate: (completedQuantity, status) =>
                              updateStudioWorkOrderProgressWithMaterials(
                            context,
                            ref,
                            studio: data,
                            workOrder: workOrder,
                            completedQuantity: completedQuantity,
                            status: status,
                          ),
                        ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class StudioFinanceScreen extends ConsumerWidget {
  const StudioFinanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final configs = ref.watch(filamentCostConfigsProvider);
    final canManage =
        ref.watch(currentFarmPermissionProvider('finance.manage'));
    return _StudioPage(
      title: '报价与利润',
      description: '统一维护人工、电费、风险、利润、机器损耗和耗材成本；新订单自动计算，历史报价保持冻结。',
      actions: [
        AppButton(
          label: '创建正式报价',
          icon: const Icon(Icons.request_quote_outlined, size: 16),
          onPressed: snapshot.valueOrNull == null || !canManage
              ? null
              : () => _showQuoteDialog(
                    context,
                    ref,
                    snapshot.value!,
                    configs.valueOrNull ?? const [],
                  ),
        ),
      ],
      child: snapshot.when(
        loading: _loading,
        error: _error,
        data: (data) => ListView(
          children: [
            StudioQuoteConfigPanel(
              workspaceId: data.workspace.id,
              canManage: canManage,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _OverviewSection(
                    title: '已接受收入',
                    child: _FinanceNumber(
                      label: '报价金额',
                      value: _currency.format(data.acceptedRevenue),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _OverviewSection(
                    title: '预计利润',
                    child: _FinanceNumber(
                      label: '收入减冻结成本',
                      value: _currency.format(data.acceptedProfit),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (data.quotes.isEmpty)
              const EmptyState(
                icon: Icons.request_quote_outlined,
                title: '还没有正式报价',
                subtitle: '新建订单或手动报价后会显示在这里；以后修改配置不会改变历史利润。',
              )
            else
              FrostPanel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: data.quotes.map((quote) {
                    final customer = data.customers
                        .where((item) => item.id == quote.customerId)
                        .firstOrNull;
                    final order = data.orders
                        .where((item) => item.id == quote.orderId)
                        .firstOrNull;
                    final needsReview = quote.note?.startsWith('待核对') == true;
                    return _InfoRow(
                      title: quote.title,
                      subtitle:
                          '${quote.quoteNo} · ${order?.orderNo ?? customer?.name ?? '未关联订单'} · ${quote.materialLabel} ${quote.estimatedGrams.toStringAsFixed(0)}g · 成本 ${_currency.format(quote.totalCost)}',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                _currency.format(quote.quotedPrice),
                                style: FarmVisual.mono.copyWith(fontSize: 16),
                              ),
                              Text(
                                '利润 ${_currency.format(quote.profit)}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: quote.profit >= 0
                                      ? FarmVisual.primary
                                      : FarmVisual.danger,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 12),
                          if (needsReview) ...[
                            const StatusPill(
                              label: '待核对',
                              color: FarmVisual.warning,
                            ),
                            const SizedBox(width: 8),
                          ],
                          PopupMenuButton<StudioQuoteStatus>(
                            tooltip: '更新报价状态',
                            enabled: canManage,
                            onSelected: !canManage
                                ? null
                                : (status) => ref
                                    .read(studioDaoProvider)
                                    .updateQuoteStatus(quote.id, status),
                            itemBuilder: (_) => StudioQuoteStatus.values
                                .map(
                                  (status) => PopupMenuItem(
                                    value: status,
                                    child: Text(_quoteStatusLabel(status)),
                                  ),
                                )
                                .toList(),
                            child: StatusPill(
                              label: _quoteStatusLabel(quote.status),
                              color: _quoteStatusColor(quote.status),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class StudioTeamScreen extends ConsumerWidget {
  const StudioTeamScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(studioSnapshotProvider);
    final canManage = ref.watch(currentFarmPermissionProvider('member.update'));
    return _StudioPage(
      title: '成员管理',
      description: '农场只区分管理员与成员，所有人使用同一套功能和数据；操作会记录操作者与时间。',
      actions: [
        AppButton(
          label: '添加成员',
          icon: const Icon(Icons.group_add_rounded, size: 16),
          onPressed: snapshot.valueOrNull == null || !canManage
              ? null
              : () => showStudioMemberDialog(
                    context,
                    ref,
                    snapshot.value!.workspace,
                  ),
        ),
      ],
      child: snapshot.when(
        loading: _loading,
        error: _error,
        data: (data) => ListView.separated(
          itemCount: data.members.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final member = data.members[index];
            final canEditMember =
                canManage && member.role != StudioMemberRole.owner;
            return FrostPanel(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor:
                        _memberRoleColor(member.role).withValues(alpha: 0.12),
                    foregroundColor: _memberRoleColor(member.role),
                    child: Icon(_memberRoleIcon(member.role), size: 20),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          member.displayName,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          member.email ?? '本地成员',
                          style: FarmVisual.label(context),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 150,
                    child: Text(
                      member.role == StudioMemberRole.owner ? '管理员' : '成员',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Switch(
                    value: member.active,
                    onChanged: !canEditMember
                        ? null
                        : (active) => ref
                            .read(studioDaoProvider)
                            .setMemberActive(member.id, active),
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

class _StudioPage extends StatelessWidget {
  const _StudioPage({
    required this.title,
    required this.description,
    required this.child,
    this.actions = const [],
  });

  final String title;
  final String description;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(FarmLayoutTokens.pageGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FarmPageHeader(
            title: title,
            subtitle: description,
            actions: actions,
          ),
          const SizedBox(height: 16),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _OverviewSection extends StatelessWidget {
  const _OverviewSection({
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FrostPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: FarmVisual.title(context)),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(subtitle!, style: FarmVisual.label(context)),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _FinanceNumber extends StatelessWidget {
  const _FinanceNumber({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: FarmVisual.mono.copyWith(fontSize: 24)),
          const SizedBox(height: 3),
          Text(label, style: FarmVisual.label(context)),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: FarmVisual.label(context),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(child: Text(message, style: FarmVisual.label(context))),
    );
  }
}

class _WorkOrderRow extends StatelessWidget {
  const _WorkOrderRow({
    required this.workOrder,
    required this.onUpdate,
    required this.materials,
    required this.onManageMaterials,
    this.member,
  });

  final StudioWorkOrder workOrder;
  final StudioMember? member;
  final List<StudioWorkOrderMaterial> materials;
  final VoidCallback onManageMaterials;
  final void Function(int completedQuantity, StudioWorkOrderStatus status)
      onUpdate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 11),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            height: 42,
            child: CircularProgressIndicator(
              value: workOrder.completion,
              strokeWidth: 5,
              backgroundColor: FarmVisual.fill,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  workOrder.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${member?.displayName ?? '未分配成员'} · ${workOrder.completedQuantity}/${workOrder.quantity} 件${workOrder.schedulerTaskId == null ? '' : ' · 已关联调度任务'}',
                  style: FarmVisual.label(context),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '完成一件',
            onPressed: workOrder.completedQuantity >= workOrder.quantity
                ? null
                : () {
                    final completed = workOrder.completedQuantity + 1;
                    onUpdate(
                      completed,
                      completed >= workOrder.quantity
                          ? StudioWorkOrderStatus.completed
                          : StudioWorkOrderStatus.printing,
                    );
                  },
            icon: const Icon(Icons.add_task_rounded),
          ),
          IconButton(
            key: const Key('studio-work-order-material-button'),
            tooltip:
                materials.every((item) => item.isSettled) ? '查看耗材结算' : '分配耗材卷',
            onPressed: materials.isEmpty ? null : onManageMaterials,
            icon: Icon(
              materials.every((item) => item.isSettled)
                  ? Icons.inventory_2_rounded
                  : Icons.inventory_2_outlined,
            ),
          ),
          PopupMenuButton<StudioWorkOrderStatus>(
            tooltip: '更新工单状态',
            onSelected: (status) => onUpdate(
              status == StudioWorkOrderStatus.completed
                  ? workOrder.quantity
                  : workOrder.completedQuantity,
              status,
            ),
            itemBuilder: (_) => StudioWorkOrderStatus.values
                .map(
                  (status) => PopupMenuItem(
                    value: status,
                    child: Text(_workOrderStatusLabel(status)),
                  ),
                )
                .toList(),
            child: StatusPill(
              label: _workOrderStatusLabel(workOrder.status),
              color: _workOrderStatusColor(workOrder.status),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _loading() => const Center(child: CircularProgressIndicator());
Widget _error(Object error, StackTrace stack) => Center(
      child: Text('加载失败：$error',
          style: const TextStyle(color: FarmPalette.danger)),
    );

Future<void> showStudioCustomerDialog(
  BuildContext context,
  WidgetRef ref,
  StudioWorkspace workspace,
) async {
  final name = TextEditingController();
  final contact = TextEditingController();
  final phone = TextEditingController();
  final email = TextEditingController();
  final note = TextEditingController();
  await AppDialog.show<void>(
    context: context,
    title: '添加客户',
    content: Column(
      children: [
        AppInput(label: '客户名称', controller: name, hint: '公司或个人名称'),
        const SizedBox(height: 12),
        AppInput(label: '联系人', controller: contact),
        const SizedBox(height: 12),
        AppInput(label: '电话', controller: phone),
        const SizedBox(height: 12),
        AppInput(label: '邮箱', controller: email),
        const SizedBox(height: 12),
        AppInput(label: '交付备注', controller: note),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () async {
          if (name.text.trim().isEmpty) {
            showSnack(context, '请填写客户名称', error: true);
            return;
          }
          await ref.read(studioDaoProvider).addCustomer(
                workspaceId: workspace.id,
                name: name.text,
                contactName: contact.text,
                phone: phone.text,
                email: email.text,
                note: note.text,
              );
          if (context.mounted) Navigator.of(context).pop();
        },
        child: const Text('保存'),
      ),
    ],
  );
  for (final controller in [name, contact, phone, email, note]) {
    controller.dispose();
  }
}

Future<void> createStudioCustomerShare(
  BuildContext context,
  WidgetRef ref,
  StudioOrder order,
) async {
  final password = TextEditingController();
  var expiresInDays = 30;
  final options = await AppDialog.show<({String password, int expiresInDays})>(
    context: context,
    title: '创建客户进度页',
    content: StatefulBuilder(
      builder: (context, setState) => Column(
        children: [
          AppInput(
            label: '访问密码',
            controller: password,
            hint: '至少 6 位，发送给该客户',
            obscureText: true,
          ),
          const SizedBox(height: 12),
          AppSelect<int>(
            value: expiresInDays,
            label: '链接有效期',
            items: const [
              DropdownMenuItem(value: 7, child: Text('7 天')),
              DropdownMenuItem(value: 30, child: Text('30 天')),
              DropdownMenuItem(value: 90, child: Text('90 天')),
              DropdownMenuItem(value: 365, child: Text('365 天')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => expiresInDays = value);
            },
          ),
          const SizedBox(height: 10),
          Text(
            '客户只能查看此订单的进度和正在打印的设备画面，不能浏览其他设备或发送控制指令。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final value = password.text;
          if (value.length < 6 || value.length > 64) {
            showSnack(context, '访问密码需为 6-64 位', error: true);
            return;
          }
          Navigator.of(context).pop(
            (
              password: value,
              expiresInDays: expiresInDays,
            ),
          );
        },
        child: const Text('创建并复制'),
      ),
    ],
  );
  password.dispose();
  if (options == null) return;
  try {
    final link = await ref.read(studioCloudServiceProvider).createShareLink(
          order,
          expiresInDays: options.expiresInDays,
          portalPassword: options.password,
        );
    await Clipboard.setData(
      ClipboardData(
        text: '订单进度：${link.publicUrl}\n访问密码：${options.password}',
      ),
    );
    if (context.mounted) {
      showSnack(
        context,
        '客户进度链接和密码已复制，有效期 ${options.expiresInDays} 天',
      );
    }
  } catch (error) {
    if (context.mounted) {
      showSnack(context, '创建进度链接失败：$error', error: true);
    }
  }
}

Future<void> handleStudioShareAction(
  BuildContext context,
  WidgetRef ref,
  StudioShareLink link,
  String action,
) async {
  try {
    if (action == 'copy') {
      final url = link.publicUrl;
      if (url == null || url.isEmpty) {
        throw StateError('本地没有保存完整链接，请撤销后重新创建');
      }
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) showSnack(context, '客户进度链接已复制');
      return;
    }
    if (action == 'revoke') {
      final confirmed = await AppDialog.confirm(
        context,
        '撤销客户进度链接',
        '撤销后客户将立即无法再打开此链接。',
        confirmText: '撤销',
        destructive: true,
      );
      if (!confirmed) return;
      await ref.read(studioCloudServiceProvider).revokeShareLink(link);
      if (context.mounted) showSnack(context, '客户进度链接已撤销');
    }
  } catch (error) {
    if (context.mounted) {
      showSnack(context, '处理进度链接失败：$error', error: true);
    }
  }
}

Future<void> showStudioMemberDialog(
  BuildContext context,
  WidgetRef ref,
  StudioWorkspace workspace,
) async {
  final name = TextEditingController();
  final loginName = TextEditingController();
  final employeeNo = TextEditingController();
  final phone = TextEditingController();
  final recoveryEmail = TextEditingController();
  var isSubmitting = false;
  StateSetter? updateDialog;
  Map<String, dynamic>? createdAccount;
  await AppDialog.show<void>(
    context: context,
    title: '创建农场成员账号',
    content: StatefulBuilder(
      builder: (dialogContext, setState) {
        updateDialog = setState;
        return Column(
          children: [
            AppInput(label: '成员姓名', controller: name),
            const SizedBox(height: 12),
            AppInput(
              label: '成员登录名',
              controller: loginName,
              hint: '例如 zhangsan，需与农场编号一起登录',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: AppInput(
                    label: '成员编号（可选）',
                    controller: employeeNo,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AppInput(
                    label: '手机号（可选）',
                    controller: phone,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AppInput(
              label: '找回邮箱（可选）',
              controller: recoveryEmail,
            ),
            const SizedBox(height: 12),
            const Text(
              '新账号身份固定为“成员”，可以使用全部农场功能并共享全部数据。系统会生成只显示一次的初始密码；成员首次登录必须修改密码。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        );
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () async {
          if (isSubmitting) return;
          if (name.text.trim().isEmpty) {
            showSnack(context, '请填写成员名称', error: true);
            return;
          }
          if (!RegExp(r'^[a-z0-9][a-z0-9._-]{2,31}$')
              .hasMatch(loginName.text.trim().toLowerCase())) {
            showSnack(
              context,
              '登录名需为 3-32 位小写字母、数字、点、下划线或短横线',
              error: true,
            );
            return;
          }
          updateDialog?.call(() => isSubmitting = true);
          try {
            createdAccount =
                await ref.read(studioCloudServiceProvider).createFarmStaff(
                      displayName: name.text.trim(),
                      loginName: loginName.text.trim().toLowerCase(),
                      roleCodes: const ['member'],
                      primaryRoleCode: 'member',
                      employeeNo: employeeNo.text,
                      phone: phone.text,
                      recoveryEmail: recoveryEmail.text,
                    );
            if (context.mounted) Navigator.of(context).pop();
          } catch (error) {
            if (context.mounted) {
              showSnack(context, '创建员工账号失败：$error', error: true);
              updateDialog?.call(() => isSubmitting = false);
            }
          }
        },
        child: const Text('创建账号'),
      ),
    ],
  );
  final createdLoginName = loginName.text.trim().toLowerCase();
  name.dispose();
  loginName.dispose();
  employeeNo.dispose();
  phone.dispose();
  recoveryEmail.dispose();
  if (createdAccount case final result?) {
    final organizationCode = result['organizationCode'] as String? ?? '';
    final initialPassword = result['initialPassword'] as String? ?? '';
    final credentials = '农场编号：$organizationCode\n'
        '成员账号：$createdLoginName\n'
        '初始密码：$initialPassword';
    if (!context.mounted) return;
    await AppDialog.show<void>(
      context: context,
      title: '成员账号已创建',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('请安全地交给成员。初始密码关闭后不能再次查看。'),
          const SizedBox(height: 12),
          SelectableText(credentials),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: credentials));
            if (context.mounted) showSnack(context, '登录信息已复制');
          },
          child: const Text('复制登录信息'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('我已保存'),
        ),
      ],
    );
  }
}

Future<void> showStudioOrderDialog(
  BuildContext context,
  WidgetRef ref,
  StudioSnapshot studio,
) async {
  final quoteSettings = await ref.read(studioQuoteSettingsProvider.future);
  if (!context.mounted) return;
  final title = TextEditingController();
  final orderNo = TextEditingController(
    text: 'SO-${DateFormat('yyMMdd-HHmm').format(DateTime.now())}',
  );
  final price = TextEditingController(text: '0');
  final note = TextEditingController();
  final publicNote = TextEditingController();
  String? customerId;
  DateTime? dueAt;
  var portalVideoEnabled = true;
  await AppDialog.show<void>(
    context: context,
    title: '新建客户订单',
    content: StatefulBuilder(
      builder: (context, setState) => Column(
        children: [
          AppInput(label: '订单名称', controller: title, hint: '例如：展示件小批量生产'),
          const SizedBox(height: 12),
          AppInput(label: '订单编号', controller: orderNo),
          const SizedBox(height: 12),
          AppSelect<String>(
            value: customerId,
            label: '关联客户',
            hint: '可稍后关联',
            items: studio.customers
                .where((item) => !item.archived)
                .map(
                  (item) => DropdownMenuItem(
                    value: item.id,
                    child: Text(item.name),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => customerId = value),
          ),
          const SizedBox(height: 12),
          AppInput(
            label: '订单金额',
            controller: price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('交付日期'),
            subtitle: Text(
              dueAt == null ? '未设置' : DateFormat('yyyy-MM-dd').format(dueAt!),
            ),
            trailing: const Icon(Icons.calendar_month_outlined),
            onTap: () async {
              final value = await showDatePicker(
                context: context,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 3650)),
              );
              if (value != null) setState(() => dueAt = value);
            },
          ),
          AppInput(label: '备注', controller: note),
          const SizedBox(height: 12),
          AppInput(
            label: '客户可见说明',
            controller: publicNote,
            hint: '只填写允许客户看到的项目说明',
          ),
          const SizedBox(height: 6),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许显示当前打印画面'),
            subtitle: const Text('仅在关联工单正在打印时转接，不提供回放和控制'),
            value: portalVideoEnabled,
            onChanged: (value) => setState(() => portalVideoEnabled = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () async {
          if (title.text.trim().isEmpty || orderNo.text.trim().isEmpty) {
            showSnack(context, '请填写订单名称和编号', error: true);
            return;
          }
          final dao = ref.read(studioDaoProvider);
          final amount = double.tryParse(price.text) ?? 0;
          final now = DateTime.now();
          final quote = StudioQuote(
            id: const Uuid().v4(),
            workspaceId: studio.workspace.id,
            customerId: customerId,
            quoteNo: 'QT-${orderNo.text.trim()}',
            title: title.text.trim(),
            status: StudioQuoteStatus.draft,
            materialLabel: '待添加生产数据',
            estimatedGrams: 0,
            materialCostPerKgSnapshot: 0,
            machineHours: 0,
            machineRatePerHour: 0,
            laborHours: 0,
            laborRatePerHour: quoteSettings.laborRatePerHour,
            electricityCost: 0,
            packagingCost: quoteSettings.packagingCost,
            riskPercent: quoteSettings.riskReservePercent,
            markupPercent: quoteSettings.markupPercent,
            totalCost: 0,
            quotedPrice: amount,
            note: '待核对：订单尚未包含切片、机型和耗材数据',
            createdAt: now,
            updatedAt: now,
          );
          await dao.addOrder(
            workspaceId: studio.workspace.id,
            orderNo: orderNo.text,
            title: title.text,
            customerId: customerId,
            dueAt: dueAt,
            totalPrice: amount,
            note: note.text,
            publicNote: publicNote.text,
            portalVideoEnabled: portalVideoEnabled,
            quote: quote,
          );
          if (context.mounted) Navigator.of(context).pop();
        },
        child: const Text('创建'),
      ),
    ],
  );
  for (final controller in [title, orderNo, price, note, publicNote]) {
    controller.dispose();
  }
}

Future<void> showStudioWorkOrderDialog(
  BuildContext context,
  WidgetRef ref,
  StudioSnapshot studio,
  StudioOrder order,
) async {
  final title = TextEditingController(text: order.title);
  final quantity = TextEditingController(text: '1');
  final materialCost = TextEditingController(text: '0');
  final quotedPrice = TextEditingController(text: '0');
  final tasks = ref.read(schedulerTasksProvider).valueOrNull ?? const [];
  final printers =
      ref.read(printersWithChannelsProvider).valueOrNull ?? const [];
  int? schedulerTaskId;
  int? printerId;
  String? memberId;
  await AppDialog.show<void>(
    context: context,
    title: '拆分生产工单',
    content: StatefulBuilder(
      builder: (context, setState) => Column(
        children: [
          AppInput(label: '工单名称', controller: title),
          const SizedBox(height: 12),
          AppInput(
            label: '生产数量',
            controller: quantity,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          AppSelect<String>(
            value: memberId,
            label: '成员',
            hint: '暂不分配',
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
          const SizedBox(height: 12),
          AppSelect<int>(
            value: printerId,
            label: '指定打印机',
            hint: '交给调度器决定',
            items: printers
                .map(
                  (item) => DropdownMenuItem(
                    value: item.printer.id,
                    child: Text(
                      item.printer.name ?? item.serial ?? item.printer.model,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => printerId = value),
          ),
          const SizedBox(height: 12),
          AppSelect<int>(
            value: schedulerTaskId,
            label: '关联调度任务',
            hint: '可稍后从生产调度处理',
            items: tasks
                .where((item) => item.id != null && !item.status.isTerminal)
                .map(
                  (item) => DropdownMenuItem(
                    value: item.id,
                    child: Text(item.gcodeFilename),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => schedulerTaskId = value),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AppInput(
                  label: '耗材成本快照',
                  controller: materialCost,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppInput(
                  label: '工单收入快照',
                  controller: quotedPrice,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () async {
          if (title.text.trim().isEmpty) {
            showSnack(context, '请填写工单名称', error: true);
            return;
          }
          await ref.read(studioDaoProvider).addWorkOrder(
                workspaceId: studio.workspace.id,
                orderId: order.id,
                title: title.text,
                quantity: int.tryParse(quantity.text) ?? 1,
                schedulerTaskId: schedulerTaskId,
                assignedMemberId: memberId,
                printerId: printerId,
                materialCostSnapshot: double.tryParse(materialCost.text) ?? 0,
                quotedPriceSnapshot: double.tryParse(quotedPrice.text) ?? 0,
              );
          if (context.mounted) Navigator.of(context).pop();
        },
        child: const Text('创建工单'),
      ),
    ],
  );
  for (final controller in [title, quantity, materialCost, quotedPrice]) {
    controller.dispose();
  }
}

Future<void> _showInventoryDialog(
  BuildContext context,
  WidgetRef ref,
  StudioSnapshot studio,
  Consumable consumable,
) async {
  final grams = TextEditingController(text: '1000');
  final reason = TextEditingController();
  var adding = true;
  String? memberId;
  await AppDialog.show<void>(
    context: context,
    title: '${consumable.manufacturer} · ${consumable.materialType}',
    content: StatefulBuilder(
      builder: (context, setState) => Column(
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                icon: Icon(Icons.add_rounded),
                label: Text('补充 / 归还'),
              ),
              ButtonSegment(
                value: false,
                icon: Icon(Icons.remove_rounded),
                label: Text('领用 / 盘亏'),
              ),
            ],
            selected: {adding},
            onSelectionChanged: (value) => setState(() => adding = value.first),
          ),
          const SizedBox(height: 14),
          AppInput(
            label: '变动克数',
            controller: grams,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 12),
          AppSelect<String>(
            value: memberId,
            label: '经手成员',
            hint: '未指定',
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
          const SizedBox(height: 12),
          AppInput(
            label: '原因',
            controller: reason,
            hint: adding ? '到货、退回、盘盈' : '领用、损耗、盘亏',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () async {
          final value = double.tryParse(grams.text);
          if (value == null || value <= 0 || reason.text.trim().isEmpty) {
            showSnack(context, '请填写有效克数和变动原因', error: true);
            return;
          }
          final actual = await ref.read(studioDaoProvider).adjustInventory(
                workspaceId: studio.workspace.id,
                consumableId: consumable.id,
                deltaGrams: adding ? value : -value,
                type: adding
                    ? StudioInventoryEventType.receive
                    : StudioInventoryEventType.consume,
                reason: reason.text,
                memberId: memberId,
              );
          if (context.mounted) {
            Navigator.of(context).pop();
            showSnack(
              context,
              '库存已${actual >= 0 ? '增加' : '扣减'} ${actual.abs().toStringAsFixed(0)} g',
            );
          }
        },
        child: const Text('记入流水'),
      ),
    ],
  );
  grams.dispose();
  reason.dispose();
}

Future<void> _showQuoteDialog(
  BuildContext context,
  WidgetRef ref,
  StudioSnapshot studio,
  List<FilamentCostConfig> configs,
) async {
  final settings = await ref.read(studioQuoteSettingsProvider.future);
  final machines = await ref.read(studioMachineCostConfigsProvider.future);
  if (!context.mounted) return;
  final title = TextEditingController();
  final quoteNo = TextEditingController(
    text: 'QT-${DateFormat('yyMMdd-HHmm').format(DateTime.now())}',
  );
  final grams = TextEditingController(text: '100');
  final materialRate = TextEditingController(text: '0');
  final machineHours = TextEditingController(text: '1');
  final machineRate = TextEditingController(text: '0');
  final laborHours = TextEditingController(text: '0.25');
  final laborRate = TextEditingController(
    text: settings.laborRatePerHour.toStringAsFixed(2),
  );
  final electricity = TextEditingController(
    text: settings.electricityRatePerHour.toStringAsFixed(2),
  );
  final packaging = TextEditingController(
    text: settings.packagingCost.toStringAsFixed(2),
  );
  final risk = TextEditingController(
    text: settings.riskReservePercent.toStringAsFixed(2),
  );
  final markup = TextEditingController(
    text: settings.markupPercent.toStringAsFixed(2),
  );
  String? customerId;
  int? costConfigId;
  int? machineConfigId;
  String materialLabel = '未选择库存成本';

  ({double cost, double price}) calculate() {
    double number(TextEditingController value) =>
        double.tryParse(value.text) ?? 0;
    final base = number(grams) / 1000 * number(materialRate) +
        number(machineHours) * number(machineRate) +
        number(laborHours) * settings.laborRatePerHour +
        number(machineHours) * settings.electricityRatePerHour +
        settings.packagingCost;
    final cost = base * (1 + settings.riskReservePercent / 100);
    final price = cost * (1 + settings.markupPercent / 100);
    return (
      cost: cost,
      price: price < settings.minimumOrderPrice
          ? settings.minimumOrderPrice
          : price,
    );
  }

  await AppDialog.show<void>(
    context: context,
    title: '创建正式报价',
    content: StatefulBuilder(
      builder: (context, setState) {
        final result = calculate();
        void changed(String _) => setState(() {});
        return Column(
          children: [
            AppInput(label: '报价标题', controller: title),
            const SizedBox(height: 10),
            AppInput(label: '报价编号', controller: quoteNo),
            const SizedBox(height: 10),
            AppSelect<String>(
              value: customerId,
              label: '客户',
              hint: '可稍后关联',
              items: studio.customers
                  .where((item) => !item.archived)
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.id,
                      child: Text(item.name),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => customerId = value),
            ),
            const SizedBox(height: 10),
            AppSelect<int>(
              value: costConfigId,
              label: '库存耗材成本配置',
              hint: configs.isEmpty ? '请先在耗材成本中配置单价' : '选择品牌 / 材质 / 颜色',
              enabled: configs.isNotEmpty,
              items: configs
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.id,
                      child: Text(
                        '${item.vendor.isEmpty ? '通用' : item.vendor} · ${item.materialType}${item.colorHex.isEmpty ? '' : ' · ${item.colorHex}'} · ¥${item.costPerKg.toStringAsFixed(2)}/kg',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                final config =
                    configs.where((item) => item.id == value).firstOrNull;
                setState(() {
                  costConfigId = value;
                  if (config != null) {
                    materialRate.text = config.costPerKg.toStringAsFixed(2);
                    materialLabel = [
                      if (config.vendor.isNotEmpty) config.vendor,
                      config.materialType,
                      if (config.colorHex.isNotEmpty) config.colorHex,
                    ].join(' · ');
                  }
                });
              },
            ),
            const SizedBox(height: 10),
            AppSelect<int>(
              value: machineConfigId,
              label: '机器型号损耗',
              hint: machines.isEmpty ? '请先在本页配置机器损耗' : '选择品牌和型号',
              enabled: machines.isNotEmpty,
              items: machines
                  .where((item) => item.active)
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.id,
                      child: Text(
                        '${item.isDefault ? '默认机器' : '${item.brand} ${item.model}'.trim()} · ¥${item.wearCostPerHour.toStringAsFixed(2)}/小时',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                final machine =
                    machines.where((item) => item.id == value).firstOrNull;
                setState(() {
                  machineConfigId = value;
                  machineRate.text =
                      (machine?.wearCostPerHour ?? 0).toStringAsFixed(2);
                });
              },
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: AppInput(
                    label: '预计耗材 g',
                    controller: grams,
                    onChanged: changed,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppInput(
                    label: '成本 ¥/kg',
                    controller: materialRate,
                    onChanged: changed,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: AppInput(
                    label: '机器小时',
                    controller: machineHours,
                    onChanged: changed,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppInput(
                    label: '机器 ¥/小时',
                    controller: machineRate,
                    enabled: false,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: AppInput(
                    label: '人工小时',
                    controller: laborHours,
                    onChanged: changed,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppInput(
                    label: '人工 ¥/小时',
                    controller: laborRate,
                    enabled: false,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: AppInput(
                    label: '电费 ¥/打印小时',
                    controller: electricity,
                    enabled: false,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppInput(
                    label: '包装/后处理 ¥/单',
                    controller: packaging,
                    enabled: false,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: AppInput(
                    label: '风险预留 %',
                    controller: risk,
                    enabled: false,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppInput(
                    label: '利润加成 %',
                    controller: markup,
                    enabled: false,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: FarmVisual.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _FinanceNumber(
                      label: '冻结总成本',
                      value: _currency.format(result.cost),
                    ),
                  ),
                  Expanded(
                    child: _FinanceNumber(
                      label: '建议报价',
                      value: _currency.format(result.price),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () async {
          if (title.text.trim().isEmpty ||
              costConfigId == null ||
              machineConfigId == null) {
            showSnack(context, '请填写标题，并选择耗材成本和机器型号', error: true);
            return;
          }
          double number(TextEditingController value) =>
              double.tryParse(value.text) ?? 0;
          final result = calculate();
          final now = DateTime.now();
          await ref.read(studioDaoProvider).addQuote(
                StudioQuote(
                  id: const Uuid().v4(),
                  workspaceId: studio.workspace.id,
                  customerId: customerId,
                  costConfigId: costConfigId,
                  quoteNo: quoteNo.text.trim(),
                  title: title.text.trim(),
                  status: StudioQuoteStatus.draft,
                  materialLabel: materialLabel,
                  estimatedGrams: number(grams),
                  materialCostPerKgSnapshot: number(materialRate),
                  machineHours: number(machineHours),
                  machineRatePerHour: number(machineRate),
                  laborHours: number(laborHours),
                  laborRatePerHour: settings.laborRatePerHour,
                  electricityCost:
                      number(machineHours) * settings.electricityRatePerHour,
                  packagingCost: settings.packagingCost,
                  riskPercent: settings.riskReservePercent,
                  markupPercent: settings.markupPercent,
                  totalCost: result.cost,
                  quotedPrice: result.price,
                  createdAt: now,
                  updatedAt: now,
                ),
              );
          if (context.mounted) Navigator.of(context).pop();
        },
        child: const Text('保存报价'),
      ),
    ],
  );
  for (final controller in [
    title,
    quoteNo,
    grams,
    materialRate,
    machineHours,
    machineRate,
    laborHours,
    laborRate,
    electricity,
    packaging,
    risk,
    markup,
  ]) {
    controller.dispose();
  }
}

String _orderStatusLabel(StudioOrderStatus status) => switch (status) {
      StudioOrderStatus.draft => '草稿',
      StudioOrderStatus.confirmed => '已确认',
      StudioOrderStatus.production => '生产中',
      StudioOrderStatus.completed => '已完成',
      StudioOrderStatus.delivered => '已交付',
      StudioOrderStatus.cancelled => '已取消',
    };

Color _orderStatusColor(StudioOrderStatus status) => switch (status) {
      StudioOrderStatus.draft => FarmVisual.muted,
      StudioOrderStatus.confirmed => FarmVisual.blue,
      StudioOrderStatus.production => FarmVisual.warning,
      StudioOrderStatus.completed ||
      StudioOrderStatus.delivered =>
        FarmVisual.primary,
      StudioOrderStatus.cancelled => FarmVisual.danger,
    };

String _workOrderStatusLabel(StudioWorkOrderStatus status) => switch (status) {
      StudioWorkOrderStatus.queued => '待生产',
      StudioWorkOrderStatus.assigned => '已分配',
      StudioWorkOrderStatus.printing => '打印中',
      StudioWorkOrderStatus.paused => '已暂停',
      StudioWorkOrderStatus.completed => '已完成',
      StudioWorkOrderStatus.failed => '失败',
      StudioWorkOrderStatus.cancelled => '已取消',
    };

Color _workOrderStatusColor(StudioWorkOrderStatus status) => switch (status) {
      StudioWorkOrderStatus.queued => FarmVisual.muted,
      StudioWorkOrderStatus.assigned => FarmVisual.blue,
      StudioWorkOrderStatus.printing ||
      StudioWorkOrderStatus.paused =>
        FarmVisual.warning,
      StudioWorkOrderStatus.completed => FarmVisual.primary,
      StudioWorkOrderStatus.failed ||
      StudioWorkOrderStatus.cancelled =>
        FarmVisual.danger,
    };

String _quoteStatusLabel(StudioQuoteStatus status) => switch (status) {
      StudioQuoteStatus.draft => '草稿',
      StudioQuoteStatus.sent => '已发送',
      StudioQuoteStatus.accepted => '已接受',
      StudioQuoteStatus.rejected => '已拒绝',
      StudioQuoteStatus.expired => '已过期',
    };

Color _quoteStatusColor(StudioQuoteStatus status) => switch (status) {
      StudioQuoteStatus.draft => FarmVisual.muted,
      StudioQuoteStatus.sent => FarmVisual.blue,
      StudioQuoteStatus.accepted => FarmVisual.primary,
      StudioQuoteStatus.rejected => FarmVisual.danger,
      StudioQuoteStatus.expired => FarmVisual.warning,
    };

Color _memberRoleColor(StudioMemberRole role) => switch (role) {
      StudioMemberRole.owner => FarmVisual.violet,
      StudioMemberRole.admin => FarmVisual.blue,
      StudioMemberRole.operator => FarmVisual.primary,
    };

IconData _memberRoleIcon(StudioMemberRole role) => switch (role) {
      StudioMemberRole.owner => Icons.workspace_premium_outlined,
      StudioMemberRole.admin => Icons.admin_panel_settings_outlined,
      StudioMemberRole.operator => Icons.engineering_outlined,
    };

String _schedulerStatusLabel(dynamic status) => switch (status.name as String) {
      'pending' => '待调度',
      'blocked' => '被阻塞',
      'assigned' => '已分配',
      'printing' => '打印中',
      'completed' => '已完成',
      'failed' => '失败',
      'cancelled' => '已取消',
      _ => status.name as String,
    };

Color _schedulerStatusColor(dynamic status) => switch (status.name as String) {
      'pending' => FarmVisual.muted,
      'assigned' => FarmVisual.blue,
      'printing' => FarmVisual.warning,
      'completed' => FarmVisual.primary,
      'blocked' || 'failed' || 'cancelled' => FarmVisual.danger,
      _ => FarmVisual.muted,
    };
