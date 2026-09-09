import 'dart:async';
import '../../core/theme/glass_button_theme.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/utils/friendly_error.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/services/printer_fault_service.dart';
import '../../core/services/spool_change_detector.dart';
import '../diagnostics/printer_fault_center.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/filament_model_code.dart';
import '../../core/utils/gram_utils.dart';
import '../../core/utils/printer_image_utils.dart';
import '../../data/database/database.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../data/database/daos/print_task_consumable_dao.dart';
import '../../data/database/daos/print_task_dao.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_alerts.dart';
import '../../data/external/printer/printer_connector.dart';
import '../../providers/consumable_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/filament_cost_provider.dart';
import '../../providers/print_task_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/spool_change_provider.dart';
import '../../providers/usage_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/app_progress.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/app_stat_box.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/printer_image.dart';
import '../printers/channel_slot.dart';
import '../printers/personal_spool_removal_dialog.dart';
import 'batch_progress_card.dart';
import 'material_playground_hero.dart';

final _dashboardConsumableByIdProvider = FutureProvider.autoDispose
    .family<Consumable?, int>((ref, id) async {
      final dao = ref.watch(consumableDaoProvider);
      final scope = ref.watch(personalInventoryAccountScopeProvider);
      final item = await dao.getById(id);
      if (item == null || !scope.enforce) return item;
      final storedOwner = await dao.getOwnerAccount(id);
      return scope.allowsStoredOwner(storedOwner) ? item : null;
    });

/// 3D 打印耗材工作台。CRMEB 风格：白底卡片 + Indigo 强调 + 紧凑层次。
/// 顶部 4 个数据卡片；左右双栏：左打印机列表（仅选择）+ 右耗材操作面板。
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  int? _selectedPrinterId;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _workspaceAnchorKey = GlobalKey(
    debugLabel: 'dashboard-workspace-anchor',
  );

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _enterWorkspace() {
    final anchorContext = _workspaceAnchorKey.currentContext;
    if (anchorContext == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _enterWorkspace();
      });
      return;
    }
    unawaited(
      Scrollable.ensureVisible(
        anchorContext,
        alignment: 0,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 620),
        ),
        curve: const Cubic(0.16, 1, 0.3, 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final size = Breakpoints.of(width);
    final padding = size.isPhone ? AppSpacing.lg : AppSpacing.xxl;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        final minimumHeroHeight = size.isPhone ? 420.0 : 520.0;
        final availableHeroHeight = viewportHeight - AppSpacing.lg * 2;
        final firstScreenHeight = availableHeroHeight < minimumHeroHeight
            ? minimumHeroHeight
            : availableHeroHeight;

        return ListView(
          key: const PageStorageKey('dashboard-scroll'),
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(
            padding,
            AppSpacing.lg,
            padding,
            AppSpacing.xxxl,
          ),
          children: [
            MaterialPlaygroundHero(
              height: firstScreenHeight,
              onEnterWorkspace: _enterWorkspace,
            ),
            const SizedBox(height: AppSpacing.lg),
            KeyedSubtree(key: _workspaceAnchorKey, child: const _StatsRow()),
            const SizedBox(height: AppSpacing.lg),
            // 活跃打印机实时状态面板（进度条/时间/层数/温度/控制按钮）
            const RepaintBoundary(child: LivePrinterPanel()),
            // 批次进度卡（活跃任务属于批次时显示，否则隐藏）
            const RepaintBoundary(child: BatchProgressCard()),
            const SizedBox(height: AppSpacing.lg),
            _MasterDetail(
              selectedPrinterId: _selectedPrinterId,
              onSelect: (id) => setState(() => _selectedPrinterId = id),
            ),
          ],
        );
      },
    );
  }
}

/// 4 个数据卡片。每个含彩色图标方块 + 大号数字 + 副标题。
class _StatsRow extends ConsumerWidget {
  const _StatsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final isPhone = width < 600;

    final consumables = ref.watch(consumablesProvider);
    final usage = ref.watch(usageLogsProvider);

    final stats = consumables.when(
      data: (list) {
        final inStockRecords = list.where((c) => c.remainingGrams > 0).length;
        // 总剩余克数：所有在库耗材的剩余克数之和（精确值，非卷数换算）
        final totalRemainingGrams = list
            .where((c) => c.remainingGrams > 0)
            .fold(0.0, (sum, c) => sum + c.remainingGrams);
        // 总库存卷数：先汇总克数再换算，与 GramUtils 全局口径一致。
        // 不可逐条 round() 后再求和——3 卷各剩 600g 会被算成 3 卷（实际 1.8kg），
        // 各剩 400g 又会被算成 0 卷，与其他页面显示的数字对不上。
        final inStockRolls = GramUtils.gramsToRolls(totalRemainingGrams);
        // 总入库克数：所有耗材初始入库总克数
        final totalInboundGrams = list
            .where((c) => c.totalGrams > 0)
            .fold(0.0, (sum, c) => sum + c.totalGrams);
        final thisMonthOut = usage.maybeWhen(
          data: (logs) => logs.where((l) {
            final now = DateTime.now();
            return l.loggedAt.year == now.year && l.loggedAt.month == now.month;
          }).length,
          orElse: () => 0,
        );
        final totalConsumedGrams = usage.maybeWhen(
          data: (logs) =>
              logs.fold<double>(0.0, (sum, l) => sum + l.consumedGrams),
          orElse: () => 0.0,
        );
        // 本月消耗克数
        final thisMonthConsumedGrams = usage.maybeWhen(
          data: (logs) => logs
              .where((l) {
                final now = DateTime.now();
                return l.loggedAt.year == now.year &&
                    l.loggedAt.month == now.month;
              })
              .fold<double>(0.0, (sum, l) => sum + l.consumedGrams),
          orElse: () => 0.0,
        );
        return [
          AppStatBox(
            label: '总库存',
            value: '$inStockRolls',
            unit: '卷 · ${GramUtils.formatGrams(totalRemainingGrams)}',
            bambuIconName: 'spool',
            color: AppColors.primary,
          ),
          AppStatBox(
            label: '总入库',
            value: GramUtils.formatGrams(totalInboundGrams),
            unit: '$inStockRecords 条',
            bambuIconName: 'add_filament',
            color: AppColors.success,
          ),
          AppStatBox(
            // thisMonthOut 是用量「记录条数」而非卷数（同一卷可能分多次记录），
            // 主数值改用真实消耗克数，条数作为副信息，与「累计消耗」口径一致。
            label: '本月消耗',
            value: GramUtils.formatGrams(thisMonthConsumedGrams),
            unit: '$thisMonthOut 次记录',
            bambuIconName: 'monitor_item_print',
            color: AppColors.warning,
          ),
          AppStatBox(
            label: '累计消耗',
            value: GramUtils.formatGrams(totalConsumedGrams),
            unit: '${(totalConsumedGrams / 1000).toStringAsFixed(1)}kg',
            bambuIconName: 'monitor_item_cost',
            color: AppColors.info,
          ),
        ];
      },
      loading: () => List.generate(4, (_) => const AppStatBox.loading()),
      error: (_, __) => List.generate(4, (_) => const AppStatBox.error()),
    );

    // 强制一行四个（手机端 2x2），自适应高度
    return LayoutBuilder(
      builder: (context, c) {
        final cols = isPhone ? 2 : 4;
        final cardW = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            for (final stat in stats)
              SizedBox(
                width: cardW,
                child: DashboardHoverPlane(tint: stat.color, child: stat),
              ),
          ],
        );
      },
    );
  }
}

/// 左右双栏布局。手机单列，平板/桌面双列等宽居中分布。
class _MasterDetail extends StatelessWidget {
  final int? selectedPrinterId;
  final ValueChanged<int> onSelect;

  const _MasterDetail({
    required this.selectedPrinterId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final size = Breakpoints.of(width);

    if (size.isPhone) {
      // 手机：垂直堆叠
      return Column(
        children: [
          _PrinterList(selectedId: selectedPrinterId, onSelect: onSelect),
          if (selectedPrinterId != null) ...[
            const SizedBox(height: AppSpacing.lg),
            _DetailPanel(printerId: selectedPrinterId!),
          ],
        ],
      );
    }

    // 桌面：左右固定等宽分布，两列顶部对齐、高度独立滚动
    final panelHeight = (MediaQuery.sizeOf(context).height - 320).clamp(
      360.0,
      720.0,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 1,
          child: SizedBox(
            height: panelHeight,
            child: GlassCard(
              level: GlassLevel.l2,
              padding: EdgeInsets.zero,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: _PrinterList(
                  selectedId: selectedPrinterId,
                  onSelect: onSelect,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          flex: 1,
          child: SizedBox(
            height: panelHeight,
            child: GlassCard(
              level: GlassLevel.l2,
              padding: EdgeInsets.zero,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: selectedPrinterId == null
                    ? const _EmptyDetail()
                    : _DetailPanel(printerId: selectedPrinterId!),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 左侧打印机列表（仅用于选择，不含耗材操作）。
class _PrinterList extends ConsumerWidget {
  final int? selectedId;
  final ValueChanged<int> onSelect;

  const _PrinterList({required this.selectedId, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `select` uses DashboardPrinterListState equality, so exact gram changes
    // do not rebuild the printer cards or the adjacent detail pane.
    final state = ref.watch(
      dashboardPrinterListProvider.select((value) => value),
    );
    switch (state.phase) {
      case DashboardPrinterListPhase.loading:
        return const GlassCard(child: LoadingState());
      case DashboardPrinterListPhase.error:
        return GlassCard(
          child: Center(child: Text('加载失败: ${friendlyError(state.error!)}')),
        );
      case DashboardPrinterListPhase.data:
        final list = state.printers;
        if (list.isEmpty) {
          return const GlassCard(
            child: EmptyState(
              bambuIconName: 'printer',
              title: '还没有打印机',
              subtitle: '到「打印机」标签添加设备并绑定耗材',
            ),
          );
        }
        return Column(
          children: [
            for (final printer in list)
              Padding(
                key: ValueKey('dashboard-printer-${printer.id}'),
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: RepaintBoundary(
                  child: _PrinterTile(
                    data: printer,
                    selected: printer.id == selectedId,
                    onTap: () => onSelect(printer.id),
                  ),
                ),
              ),
          ],
        );
    }
  }
}

/// 左侧单条打印机卡片：展示与选择。
/// 显示：图片 + 命名(上位) + 品牌+型号(下位) + 通道数 + 实时状态 + 当前任务。
///
/// 实时状态来源：
/// - 活跃打印机（serial == activePrinterSerial）：从 MQTT 实时状态读取
/// - 非活跃但有云端设备：从云端 online 字段读取
/// - 无 serial 的本地打印机：不显示状态
class _PrinterTile extends ConsumerWidget {
  final DashboardPrinterSummary data;
  final bool selected;
  final VoidCallback onTap;

  const _PrinterTile({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serial = data.serial;
    final activeChannels = data.activeChannelCount;
    final imageAsset = PrinterImageUtils.resolveAsset(
      imageAsset: data.imageAsset,
      brand: data.brand,
      model: data.model,
    );
    final displayName = data.name?.isNotEmpty == true ? data.name! : data.model;

    // 读取实时状态
    final activeSerial = ref.watch(activePrinterSerialProvider);
    final isActivePrinter = serial != null && serial == activeSerial;
    final printerFacts = ref.watch(
      activePrinterConnectionProvider.select(
        (state) => isActivePrinter
            ? _PrinterTileLiveFacts.fromState(state)
            : const _PrinterTileLiveFacts(),
      ),
    );
    final cloudFacts = ref.watch(
      allCloudDevicesProvider.select((state) {
        if (serial == null) return (owner: null, online: null);
        bool? online;
        for (final device in state.devices) {
          if (device.devId == serial) {
            online = device.online;
            break;
          }
        }
        return (owner: state.ownerMap[serial], online: online);
      }),
    );
    final isLan = ref.watch(
      printerConnectionListProvider.select(
        (connections) =>
            serial != null &&
            connections.any(
              (connection) =>
                  connection.mode == BambuConnectionMode.lan &&
                  connection.serial == serial,
            ),
      ),
    );
    final ownerAccount = cloudFacts.owner;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 计算状态显示
    final statusInfo = _resolveStatusInfo(
      isActivePrinter: isActivePrinter,
      printerFacts: printerFacts,
      cloudOnline: cloudFacts.online,
      hasSerial: serial != null,
      isDark: isDark,
    );
    final amsSummary = isActivePrinter && printerFacts.isConnected
        ? printerFacts.amsSummary
        : null;
    return GlassCard(
      level: GlassLevel.l1,
      color: isDark ? AppColors.glassFillL2Dark : AppColors.glassFillL2,
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 打印机图片 + 状态指示灯叠加
          Stack(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: isDark
                      ? AppColors.surfaceVariantDark
                      : AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(AppColors.radiusLg),
                ),
                child: PrinterImage(
                  assetPath: imageAsset,
                  isCustomImage: data.isCustomImage,
                  brand: data.brand,
                  size: 56,
                ),
              ),
              // 右下角状态指示灯
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: statusInfo.color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isDark ? AppColors.surfaceDark : AppColors.surface,
                      width: 2,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        displayName,
                        style: AppTypography.title.copyWith(
                          fontSize: 15,
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 归属账号标识（多账号聚合：显示所属账号或 LAN 直连）
                    if (serial != null && (isLan || ownerAccount != null)) ...[
                      _OwnerBadge(ownerAccount: ownerAccount, isLan: isLan),
                      const SizedBox(width: AppSpacing.xs),
                    ],
                    if (selected)
                      BambuIcon(
                        name: 'completed',
                        size: 18,
                        applyColorFilter: true,
                        color: AppColors.primary,
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${data.brand} ${data.model}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (amsSummary != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    '已连接：$amsSummary',
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                // 实时状态 + 当前任务
                if (statusInfo.hasInfo) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: statusInfo.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          statusInfo.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: statusInfo.color,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (statusInfo.taskName != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      statusInfo.taskName!,
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ] else ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: AppSpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      AppChip(
                        label: '${data.channelCount} 个供料位',
                        variant: data.channelCount > 1
                            ? AppChipVariant.selected
                            : AppChipVariant.default_,
                      ),
                      Text(
                        '$activeChannels/${data.channelCount} 在用',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? AppColors.textTertiaryDark
                              : AppColors.textTertiary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 解析打印机实时状态信息。
  ///
  /// 显示规则（用户要求）：
  /// - 活跃打印机（已连接云端/局域网搜索到的）：
  ///   - idle → "已连接"
  ///   - running → "正在打印" + 任务名+进度
  ///   - pause → "已暂停" + 任务名+进度
  ///   - 其他过渡态 → 对应 label
  ///   - 未连接 → "已断开"
  /// - 非活跃但有云端设备：在线/离线
  /// - 手动添加的本地打印机（无 serial）：不显示状态
  _StatusInfo _resolveStatusInfo({
    required bool isActivePrinter,
    required _PrinterTileLiveFacts printerFacts,
    required bool? cloudOnline,
    required bool hasSerial,
    required bool isDark,
  }) {
    // 活跃打印机：从 MQTT 实时状态读取
    if (isActivePrinter) {
      if (!printerFacts.isConnected) {
        return _StatusInfo(
          label: printerFacts.errorMessage ?? '已断开',
          color: AppColors.danger,
          hasInfo: true,
        );
      }
      final gcodeState = printerFacts.gcodeState;
      // 未上报 gcodeState 或为 idle → "休息中"
      if (gcodeState == null ||
          gcodeState == BambuGcodeState.idle ||
          gcodeState == BambuGcodeState.unknown) {
        return _StatusInfo(
          label: '休息中',
          color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          hasInfo: true,
        );
      }
      // running → 红色"工作中"；pause → 显示任务名
      String? taskName;
      if (gcodeState == BambuGcodeState.running ||
          gcodeState == BambuGcodeState.pause) {
        final sub = printerFacts.subtaskName;
        final file = printerFacts.gcodeFile;
        if (sub != null && sub.isNotEmpty) {
          taskName = sub;
        } else if (file != null && file.isNotEmpty) {
          taskName = file.split(RegExp(r'[/\\]')).last;
        }
        if (taskName != null && printerFacts.mcPercent != null) {
          taskName = '$taskName · ${printerFacts.mcPercent}%';
        }
      }
      return _StatusInfo(
        label: gcodeState == BambuGcodeState.running
            ? '工作中'
            : (gcodeState == BambuGcodeState.finish ? '休息中' : gcodeState.label),
        color: gcodeState == BambuGcodeState.running
            ? AppColors.danger
            : _gcodeStateColor(gcodeState, isDark),
        hasInfo: true,
        taskName: taskName,
      );
    }

    // 非活跃但有云端设备：显示在线/离线
    if (cloudOnline != null) {
      return _StatusInfo(
        label: cloudOnline ? '在线' : '离线',
        color: cloudOnline
            ? AppColors.success
            : (isDark ? AppColors.textTertiaryDark : AppColors.textTertiary),
        hasInfo: true,
      );
    }

    // 无 serial 的本地打印机（手动添加）：不显示状态
    return const _StatusInfo(
      label: '',
      color: Colors.transparent,
      hasInfo: false,
    );
  }

  Color _gcodeStateColor(BambuGcodeState state, bool isDark) {
    switch (state) {
      case BambuGcodeState.running:
        return AppColors.primary;
      case BambuGcodeState.pause:
        return AppColors.warning;
      case BambuGcodeState.finish:
        return AppColors.success;
      case BambuGcodeState.failed:
        return AppColors.danger;
      case BambuGcodeState.idle:
        return isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;
      default:
        return AppColors.info;
    }
  }
}

/// Narrow projection for the dashboard printer tile. Temperature, fan and
/// other high-frequency telemetry are intentionally omitted because the tile
/// does not render them.
class _PrinterTileLiveFacts {
  const _PrinterTileLiveFacts({
    this.connectionState = PrinterConnectionState.disconnected,
    this.errorMessage,
    this.gcodeState,
    this.subtaskName,
    this.gcodeFile,
    this.mcPercent,
    this.amsSummary,
  });

  factory _PrinterTileLiveFacts.fromState(ActivePrinterState state) {
    final status = state.status;
    return _PrinterTileLiveFacts(
      connectionState: state.connectionState,
      errorMessage: state.errorMessage,
      gcodeState: status?.gcodeState,
      subtaskName: status?.subtaskName,
      gcodeFile: status?.gcodeFile,
      mcPercent: status?.mcPercent,
      amsSummary: status?.amsSummary,
    );
  }

  final PrinterConnectionState connectionState;
  final String? errorMessage;
  final BambuGcodeState? gcodeState;
  final String? subtaskName;
  final String? gcodeFile;
  final int? mcPercent;
  final String? amsSummary;

  bool get isConnected => connectionState == PrinterConnectionState.connected;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _PrinterTileLiveFacts &&
            connectionState == other.connectionState &&
            errorMessage == other.errorMessage &&
            gcodeState == other.gcodeState &&
            subtaskName == other.subtaskName &&
            gcodeFile == other.gcodeFile &&
            mcPercent == other.mcPercent &&
            amsSummary == other.amsSummary;
  }

  @override
  int get hashCode => Object.hash(
    connectionState,
    errorMessage,
    gcodeState,
    subtaskName,
    gcodeFile,
    mcPercent,
    amsSummary,
  );
}

/// 打印机状态显示信息。
class _StatusInfo {
  final String label;
  final Color color;
  final bool hasInfo;
  final String? taskName;
  const _StatusInfo({
    required this.label,
    required this.color,
    required this.hasInfo,
    this.taskName,
  });
}

/// 活跃打印机实时状态面板。
///
/// 类似拓竹切片软件/Bambu Handy 的实时打印面板：
/// - 顶部：打印机名 + 连接状态 + 当前任务名
/// - 中间：环形进度（百分比）+ 剩余时间
/// - 底部：当前层/总层数 + 喷头温度 + 热床温度 + 速度
/// - 控制按钮：暂停/恢复 + 停止
///
/// 数据来源：[activePrinterConnectionProvider]（MQTT 实时推送）。
/// 没有活跃打印机或未连接时不显示。
class LivePrinterPanel extends ConsumerStatefulWidget {
  const LivePrinterPanel({super.key});

  @override
  ConsumerState<LivePrinterPanel> createState() => _LivePrinterPanelState();
}

class _LivePrinterPanelState extends ConsumerState<LivePrinterPanel> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final printerState = ref.watch(activePrinterConnectionProvider);
    final activeSerial = ref.watch(activePrinterSerialProvider);
    final activeConfig = ref.watch(activePrinterConfigProvider);
    final trackedTask = ref.watch(activePrintTaskProvider);

    // 没有活跃打印机 → 不显示
    if (activeSerial == null) return const SizedBox.shrink();

    final status = printerState.status;
    final faultKnowledge = ref.watch(printerFaultServiceProvider).asData?.value;
    final printerName = activeConfig?.displayLabel ?? activeSerial;
    final isPrinting = status?.gcodeState == BambuGcodeState.running;
    final isPaused = status?.gcodeState == BambuGcodeState.pause;
    final hasPrinterTask =
        status != null &&
        <BambuGcodeState?>{
          BambuGcodeState.running,
          BambuGcodeState.pause,
          BambuGcodeState.failed,
          BambuGcodeState.offline,
        }.contains(status.gcodeState);

    // 没有打印任务时（idle/unknown/finish/未连接/无状态）→ 不显示进度卡片
    // 只在 running/pause 时显示；finish 已算"无任务"，mcPercent 残留不作为判据
    final hasTask = hasPrinterTask;
    if (!hasTask) return const SizedBox.shrink();
    final liveStatus = status;
    final printerAlerts = buildPrinterAlerts(
      liveStatus,
      knowledgeBase: faultKnowledge,
    );
    final percent = (liveStatus.mcPercent ?? 0).clamp(0, 100).toInt();
    final taskName = liveStatus.subtaskName?.trim().isNotEmpty == true
        ? liveStatus.subtaskName!.trim()
        : liveStatus.gcodeFile?.trim().isNotEmpty == true
        ? liveStatus.gcodeFile!.trim()
        : '未命名打印任务';
    final accent = isPaused
        ? AppColors.warning
        : liveStatus.gcodeState == BambuGcodeState.failed
        ? AppColors.danger
        : AppColors.primary;
    final motionEnabled = AppMotion.enabled(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        key: const ValueKey('dashboard-live-task-card'),
        duration: AppMotion.duration(context, ExperienceTokens.hoverDuration),
        curve: ExperienceTokens.motionCurve,
        transform: Matrix4.translationValues(
          0,
          _hovering && motionEnabled ? -2 : 0,
          0,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppColors.radiusLg),
          boxShadow: _hovering && motionEnabled
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.10),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ]
              : const [],
        ),
        child: GlassCard(
          // Preserve the L2 color without a live BackdropFilter. The panel
          // receives frequent MQTT updates and Windows can flash blur layers
          // while they are recomposited.
          level: GlassLevel.l1,
          color: isDark ? AppColors.glassFillL2Dark : AppColors.glassFillL2,
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppColors.radiusLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedContainer(
                  duration: AppMotion.duration(
                    context,
                    ExperienceTokens.hoverDuration,
                  ),
                  height: 3,
                  color: accent,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 11, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildHeader(
                        context,
                        printerName,
                        printerState,
                        isPrinting,
                        isPaused,
                      ),
                      if (printerAlerts.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.sm),
                        _buildPrinterAlerts(context, printerAlerts),
                      ],
                      if (!printerState.isConnected) ...[
                        const SizedBox(height: AppSpacing.sm),
                        _buildConnectionStatus(context, printerState),
                      ] else ...[
                        const SizedBox(height: AppSpacing.sm),
                        Row(
                          children: [
                            Expanded(
                              child: _buildTaskOverview(
                                context,
                                status: liveStatus,
                                taskName: taskName,
                                percent: percent,
                                accent: accent,
                              ),
                            ),
                            if (trackedTask?.id != null) ...[
                              const SizedBox(width: AppSpacing.md),
                              _TaskConsumableCostSummary(status: liveStatus),
                            ],
                            const SizedBox(width: AppSpacing.md),
                            _buildControlButtons(
                              context,
                              ref,
                              isPaused,
                              liveStatus,
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        _buildMetricGrid(
                          context,
                          liveStatus,
                          ref,
                          fallbackCurrentLayer: trackedTask?.lastLayer,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTaskOverview(
    BuildContext context, {
    required BambuPrinterStatus status,
    required String taskName,
    required int percent,
    required Color accent,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final remaining = status.mcRemainingTime ?? 0;
    final timing = status.gcodeState == BambuGcodeState.failed
        ? '任务异常，处理设备提醒后可继续检查'
        : remaining > 0
        ? '剩余 ${_formatDuration(remaining)} · 预计 ${DateFormat('HH:mm').format(DateTime.now().add(Duration(minutes: remaining)))} 完成'
        : status.gcodeState == BambuGcodeState.pause
        ? '等待恢复打印'
        : '正在计算剩余时间';

    return Row(
      children: [
        SizedBox(
          width: 52,
          height: 52,
          child: Stack(
            fit: StackFit.expand,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: percent / 100),
                duration: AppMotion.duration(
                  context,
                  const Duration(milliseconds: 320),
                ),
                curve: ExperienceTokens.motionCurve,
                builder: (context, value, _) => CircularProgressIndicator(
                  value: value,
                  strokeWidth: 5,
                  strokeCap: StrokeCap.round,
                  color: accent,
                  backgroundColor: accent.withValues(alpha: 0.10),
                ),
              ),
              Center(
                child: AnimatedSwitcher(
                  duration: AppMotion.duration(
                    context,
                    ExperienceTokens.hoverDuration,
                  ),
                  child: Text(
                    '$percent%',
                    key: ValueKey(percent),
                    style: AppTypography.dataLarge.copyWith(
                      fontSize: 15,
                      color: accent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                taskName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      timing,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetricGrid(
    BuildContext context,
    BambuPrinterStatus status,
    WidgetRef ref, {
    int? fallbackCurrentLayer,
  }) {
    final currentLayer = status.currLayer ?? fallbackCurrentLayer;
    final hasTotalLayers =
        status.totalLayers != null && status.totalLayers! > 0;
    final layer = hasTotalLayers
        ? '${currentLayer ?? 0} / ${status.totalLayers}'
        : '${currentLayer ?? '--'}';
    String temperature(double? current, double? target) {
      if (current == null) return '--';
      final now = current.toStringAsFixed(0);
      return target != null && target > 0
          ? '$now → ${target.toStringAsFixed(0)}°'
          : '$now°';
    }

    final metrics = <Widget>[
      _TaskMetric(
        icon: Icons.layers_outlined,
        label: '打印层数',
        value: layer,
        accent: AppColors.info,
        tooltip: hasTotalLayers ? '当前层 / 总层数' : '打印机尚未上报总层数',
      ),
      _TaskMetric(
        icon: Icons.local_fire_department_outlined,
        label: '喷头',
        value: temperature(status.nozzleTemper, status.nozzleTargetTemper),
        accent: AppColors.danger,
        tooltip: '当前温度 → 目标温度',
      ),
      _TaskMetric(
        icon: Icons.grid_on_rounded,
        label: '热床',
        value: temperature(status.bedTemper, status.bedTargetTemper),
        accent: AppColors.warning,
        tooltip: '当前温度 → 目标温度',
      ),
      status.spdMag == null
          ? _TaskMetric(
              icon: Icons.speed_rounded,
              label: '速度',
              value: '--',
              accent: AppColors.primary,
              tooltip: '打印机尚未上报速度倍率',
            )
          : _SpeedChip(
              currentMultiplier: status.spdMag!,
              currentLevel: status.spdLvl,
              onProfileChanged: (profileLevel) => _sendControlCommand(
                context,
                ref,
                () => ref
                    .read(activePrinterConnectionProvider.notifier)
                    .setSpeed(profileLevel),
                '调速',
              ),
            ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 560 ? 2 : 4;
        const spacing = 7.0;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final metric in metrics) SizedBox(width: width, child: metric),
          ],
        );
      },
    );
  }

  Widget _buildPrinterAlerts(BuildContext context, List<PrinterAlert> alerts) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final visibleAlerts = alerts.take(3).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final alert in visibleAlerts)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: _alertColor(
                alert.severity,
              ).withValues(alpha: isDark ? 0.18 : 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _alertColor(alert.severity).withValues(alpha: 0.32),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _alertIcon(alert.severity),
                  size: 18,
                  color: _alertColor(alert.severity),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        alert.code?.isNotEmpty == true
                            ? '${alert.title} · ${alert.code}'
                            : alert.title,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        alert.message,
                        softWrap: true,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondary,
                        ),
                      ),
                      if (alert.steps.isNotEmpty || alert.helpUrl != null) ...[
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => showPrinterFaultCenter(context),
                            icon: const Icon(Icons.build_outlined, size: 14),
                            label: const Text('查看处理办法'),
                            style: glassButtonStyle(
                              context,
                              TextButton.styleFrom(
                                minimumSize: const Size(0, 28),
                                padding: EdgeInsets.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              variant: AppGlassButtonVariant.quiet,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (alerts.length > visibleAlerts.length)
          Padding(
            padding: const EdgeInsets.only(left: 3, top: 2),
            child: Text(
              '另有 ${alerts.length - visibleAlerts.length} 项设备提醒，请查看打印机屏幕或诊断中心。',
              style: TextStyle(
                fontSize: 11,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }

  Color _alertColor(PrinterAlertSeverity severity) {
    switch (severity) {
      case PrinterAlertSeverity.error:
        return AppColors.danger;
      case PrinterAlertSeverity.warning:
        return AppColors.warning;
      case PrinterAlertSeverity.info:
        return AppColors.info;
    }
  }

  IconData _alertIcon(PrinterAlertSeverity severity) {
    switch (severity) {
      case PrinterAlertSeverity.error:
        return Icons.error_outline;
      case PrinterAlertSeverity.warning:
        return Icons.warning_amber_outlined;
      case PrinterAlertSeverity.info:
        return Icons.info_outline;
    }
  }

  Widget _buildHeader(
    BuildContext context,
    String name,
    ActivePrinterState state,
    bool isPrinting,
    bool isPaused,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Color stateColor;
    String stateLabel;
    final gcodeState = state.status?.gcodeState;
    if (!state.isConnected) {
      stateColor = AppColors.danger;
      stateLabel = state.errorMessage ?? '未连接';
    } else if (isPrinting) {
      // 工作中：红色提醒
      stateColor = AppColors.danger;
      stateLabel = '工作中';
    } else if (isPaused) {
      stateColor = AppColors.warning;
      stateLabel = '已暂停';
    } else if (gcodeState == BambuGcodeState.failed) {
      stateColor = AppColors.danger;
      stateLabel = '打印失败';
    } else if (gcodeState == BambuGcodeState.offline) {
      stateColor = AppColors.warning;
      stateLabel = '打印机离线';
    } else if (gcodeState == BambuGcodeState.finish) {
      // finish 已算"无任务"，显示休息中
      stateColor = isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;
      stateLabel = '休息中';
    } else {
      // 休息中（idle/unknown 无任务）
      stateColor = isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;
      stateLabel = '休息中';
    }

    // 状态标签 chip 变体：根据状态色映射到 AppChipVariant
    final AppChipVariant stateVariant;
    if (stateColor == AppColors.danger) {
      stateVariant = AppChipVariant.danger;
    } else if (stateColor == AppColors.warning) {
      stateVariant = AppChipVariant.warn;
    } else {
      stateVariant = AppChipVariant.default_;
    }

    return Row(
      children: [
        // 状态指示灯
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: stateColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: stateColor.withValues(alpha: 0.4),
                blurRadius: 6,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.title.copyWith(
              fontSize: 14,
              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        // 状态标签 → AppChip
        AppChip(label: stateLabel, variant: stateVariant),
      ],
    );
  }

  Widget _buildConnectionStatus(
    BuildContext context,
    ActivePrinterState state,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // P1-2: connecting 和 reconnecting 都显示加载动画
    final isPending =
        state.connectionState == PrinterConnectionState.connecting ||
        state.connectionState == PrinterConnectionState.reconnecting;
    return Row(
      children: [
        if (isPending)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          const BambuIcon(
            name: 'error',
            size: 16,
            applyColorFilter: true,
            color: AppColors.danger,
          ),
        const SizedBox(width: 8),
        Text(
          state.errorMessage ??
              (state.connectionState == PrinterConnectionState.connecting
                  ? '正在连接...'
                  : state.connectionState == PrinterConnectionState.reconnecting
                  ? '正在重连...'
                  : '连接异常'),
          style: TextStyle(
            fontSize: 12,
            color: isPending
                ? (isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary)
                : AppColors.danger,
          ),
        ),
      ],
    );
  }

  Widget _buildControlButtons(
    BuildContext context,
    WidgetRef ref,
    bool isPaused,
    BambuPrinterStatus status,
  ) {
    // idle/unknown 状态下没有任务可控制，按钮禁用
    final gcodeState = status.gcodeState;
    final canControl =
        gcodeState == BambuGcodeState.running ||
        gcodeState == BambuGcodeState.pause;

    return Row(
      children: [
        // 暂停/恢复按钮 → AppButton（恢复用 primary，暂停用 secondary）
        if (isPaused)
          AppButton(
            label: '恢复',
            icon: Builder(
              builder: (context) => BambuIcon(
                name: 'print_control_resume',
                size: 16,
                applyColorFilter: true,
                color: GlassButtonsTheme.enabledOf(context)
                    ? IconTheme.of(context).color
                    : Colors.white,
              ),
            ),
            variant: AppButtonVariant.primary,
            compact: true,
            onPressed: canControl
                ? () => _sendControlCommand(
                    context,
                    ref,
                    () => ref
                        .read(activePrinterConnectionProvider.notifier)
                        .resume(),
                    '恢复',
                  )
                : null,
          )
        else
          AppButton(
            label: '暂停',
            icon: BambuIcon(
              name: 'print_control_pause',
              size: 16,
              applyColorFilter: true,
              color: AppColors.primary,
            ),
            variant: AppButtonVariant.secondary,
            compact: true,
            onPressed: canControl
                ? () => _sendControlCommand(
                    context,
                    ref,
                    () => ref
                        .read(activePrinterConnectionProvider.notifier)
                        .pause(),
                    '暂停',
                  )
                : null,
          ),
        const SizedBox(width: AppSpacing.xs),
        // 停止按钮 → AppButton（danger 变体）
        AppButton(
          label: '停止',
          icon: Builder(
            builder: (context) => BambuIcon(
              name: 'print_control_stop',
              size: 16,
              applyColorFilter: true,
              color: GlassButtonsTheme.enabledOf(context)
                  ? IconTheme.of(context).color
                  : Colors.white,
            ),
          ),
          variant: AppButtonVariant.danger,
          compact: true,
          onPressed: canControl ? () => _confirmStop(context, ref) : null,
        ),
      ],
    );
  }

  /// 停止打印是不可撤销的破坏性操作，必须二次确认。
  Future<void> _confirmStop(BuildContext context, WidgetRef ref) async {
    final ok = await AppDialog.confirm(
      context,
      '停止打印',
      '将中止打印机上正在进行的任务，已打印的部分无法恢复，耗材也无法回收。\n\n确定要停止吗？',
      confirmText: '停止打印',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await _sendControlCommand(
      context,
      ref,
      () => ref.read(activePrinterConnectionProvider.notifier).stop(),
      '停止',
    );
  }

  /// 统一下发打印控制指令：失败时明确提示，不再静默吞掉返回值。
  Future<void> _sendControlCommand(
    BuildContext context,
    WidgetRef ref,
    Future<bool> Function() action,
    String actionName,
  ) async {
    bool ok;
    try {
      ok = await action();
    } catch (_) {
      ok = false;
    }
    if (!context.mounted) return;
    if (!ok) {
      showSnack(context, '$actionName指令下发失败，请检查打印机连接状态', error: true);
    }
  }

  String _formatDuration(int minutes) {
    if (minutes <= 0) return '--';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h > 0) return '${h}h${m}m';
    return '${m}m';
  }
}

/// 任务指标块。静态指标在悬停时解释口径，可操作指标会额外显示进入箭头。
class _TaskMetric extends StatefulWidget {
  const _TaskMetric({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  State<_TaskMetric> createState() => _TaskMetricState();
}

class _TaskMetricState extends State<_TaskMetric> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            child: AnimatedContainer(
              duration: AppMotion.duration(
                context,
                ExperienceTokens.hoverDuration,
              ),
              curve: ExperienceTokens.motionCurve,
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: _hovering
                    ? widget.accent.withValues(alpha: 0.09)
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.48),
                borderRadius: BorderRadius.circular(AppColors.radiusMd),
                border: Border.all(
                  color: _hovering
                      ? widget.accent.withValues(alpha: 0.30)
                      : scheme.outlineVariant.withValues(alpha: 0.62),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: widget.accent.withValues(alpha: 0.11),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(widget.icon, size: 14, color: widget.accent),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 8.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [
                              ui.FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (enabled)
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: _hovering
                          ? widget.accent
                          : scheme.onSurfaceVariant,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 速度调节指标（点击弹出速度选择菜单）。
/// 拓竹常用速度档位：50(静音) / 100(正常) / 125(运动) / 150(疾速)
/// 内部使用任务指标块渲染，保留真实的 MQTT 调速逻辑。
class _SpeedChip extends StatelessWidget {
  final int currentMultiplier;
  final int? currentLevel;
  final ValueChanged<int> onProfileChanged;
  const _SpeedChip({
    required this.currentMultiplier,
    required this.currentLevel,
    required this.onProfileChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = BambuSpeedProfile.fromTelemetry(
      level: currentLevel,
      multiplier: currentMultiplier,
    );
    return _TaskMetric(
      icon: Icons.speed_rounded,
      label: '速度 · ${current.label}',
      value: '$currentMultiplier%',
      accent: AppColors.primary,
      tooltip: '点击切换打印速度档位',
      onTap: () => _showSpeedMenu(context, current),
    );
  }

  void _showSpeedMenu(BuildContext context, BambuSpeedProfile current) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final RenderBox button = context.findRenderObject() as RenderBox;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final selected = await showMenu<int>(
      context: context,
      position: position,
      items: BambuSpeedProfile.values.map((profile) {
        return PopupMenuItem<int>(
          value: profile.level,
          child: Row(
            children: [
              if (profile == current)
                BambuIcon(
                  name: 'confirm',
                  size: 16,
                  color: AppColors.primary,
                  applyColorFilter: true,
                )
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(
                profile.label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Text(
                '约 ${profile.nominalPercent}%',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );

    if (selected != null && selected != current.level) {
      onProfileChanged(selected);
    }
  }
}

/// 右侧详情面板：耗材完整信息 + 每通道更换/已用完操作。
class _DetailPanel extends ConsumerWidget {
  final int printerId;

  const _DetailPanel({required this.printerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final detail = ref.watch(printerDetailProvider(printerId));

    return detail.when(
      loading: () => const GlassCard(child: LoadingState()),
      error: (e, _) =>
          GlassCard(child: Center(child: Text('加载失败: ${friendlyError(e)}'))),
      data: (data) {
        if (data == null) return const _EmptyDetail();
        final p = data.printer;
        final channels = data.channels;
        final externalFeedCount = channels
            .where((item) => isExternalFeedChannel(item.channel.channelIndex))
            .length;
        final imageAsset = PrinterImageUtils.resolveAsset(
          imageAsset: p.imageAsset,
          brand: p.brand,
          model: p.model,
        );
        final displayName = p.name?.isNotEmpty == true ? p.name! : p.model;

        return GlassCard(
          level: GlassLevel.l2,
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 打印机标题
              Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: isDark
                          ? AppColors.surfaceVariantDark
                          : AppColors.surfaceVariant,
                      borderRadius: BorderRadius.circular(AppColors.radiusLg),
                    ),
                    child: PrinterImage(
                      assetPath: imageAsset,
                      isCustomImage: p.isCustomImage,
                      brand: p.brand,
                      size: 56,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          style: AppTypography.title.copyWith(
                            fontSize: 17,
                            color: isDark
                                ? AppColors.textPrimaryDark
                                : AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: AppSpacing.xs - 2),
                        Text(
                          '${p.brand} ${p.model} · ${p.channelCount} 个物理供料位',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Divider(
                color: isDark ? AppColors.dividerDark : AppColors.divider,
              ),
              const SizedBox(height: AppSpacing.md),
              const _SectionLabel('供料位耗材'),
              const SizedBox(height: AppSpacing.md - 2),
              // 全部通道列表（含空通道，便于直接操作）
              for (final ch in channels)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md - 2),
                  child: _ChannelActionTile(
                    channel: ch,
                    printerId: printerId,
                    externalFeedCount: externalFeedCount,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 分区 eyebrow 小标题。
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      text,
      style: AppTypography.label.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
        letterSpacing: 0.8,
      ),
    );
  }
}

/// 通道耗材操作条目：色块 + 厂商/HEX + 更换耗材 + 已用完 按钮。
class _ChannelActionTile extends ConsumerWidget {
  final ChannelWithConsumable channel;
  final int printerId;
  final int externalFeedCount;

  const _ChannelActionTile({
    required this.channel,
    required this.printerId,
    required this.externalFeedCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ch = channel.channel;
    final rawConsumable = channel.consumable;
    final accountScope = ref.watch(personalInventoryAccountScopeProvider);
    final inventory = ref.watch(consumablesProvider);
    final visibleIds = inventory is AsyncData<List<Consumable>>
        ? inventory.value.map((item) => item.id).toSet()
        : const <int>{};
    final accountProtected =
        accountScope.enforce &&
        rawConsumable != null &&
        !visibleIds.contains(rawConsumable.id);
    final c = accountProtected ? null : rawConsumable;
    final label = printerFeedChannelLabel(
      ch.channelIndex,
      storedLabel: ch.label,
      legacySingleExternal: externalFeedCount == 1,
    );

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color:
            (isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant)
                .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(
          color: isDark ? AppColors.dividerDark : AppColors.divider,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          // 通道标识
          Container(
            width: 120,
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c == null
                  ? (isDark
                        ? AppColors.surfaceVariantDark
                        : AppColors.surfaceVariant)
                  : AppColors.primaryContainer,
              borderRadius: BorderRadius.circular(AppColors.radiusSm),
            ),
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: c == null
                    ? (isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary)
                    : AppColors.primary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 耗材信息
          Expanded(
            child: accountProtected
                ? const Text(
                    '其他 Sohun 账号的耗材 · 切回原账号后可查看和操作',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  )
                : c == null
                ? Text(
                    '无耗材',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        c.manufacturer,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: ColorUtils.fromHex(c.colorHex),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isDark
                                    ? AppColors.outlineDark
                                    : AppColors.outline,
                                width: 0.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            channel.awaitingSpoolSelection
                                ? '待确认装入 · 保留 ${GramUtils.formatGrams(c.remainingGrams)}'
                                : channel.farmRollPaused
                                ? '维修暂取 · 保留 ${GramUtils.formatGrams(c.remainingGrams)}'
                                : '${c.colorHex} · ${c.materialType}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: channel.farmRollPaused
                                  ? FontWeight.w700
                                  : FontWeight.normal,
                              color: channel.farmRollPaused
                                  ? AppColors.warning
                                  : isDark
                                  ? AppColors.textSecondaryDark
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
          // 操作按钮 → AppButton
          if (accountProtected)
            Icon(Icons.lock_outline_rounded, color: AppColors.textSecondary)
          else if (c != null && channel.farmRollPaused) ...[
            AppButton(
              label: '继续使用',
              icon: const Icon(Icons.build_circle_outlined, size: 16),
              variant: AppButtonVariant.primary,
              onPressed: () => _resumeAfterMaintenance(context, ref),
            ),
          ] else if (c != null) ...[
            AppButton(
              label: '更换',
              icon: BambuIcon(
                name: 'fila_switch',
                size: 16,
                applyColorFilter: true,
                color: AppColors.primary,
              ),
              variant: AppButtonVariant.secondary,
              onPressed: () => _changeConsumable(context, ref),
            ),
            const SizedBox(width: 6),
            AppButton(
              label: '已用完',
              icon: Builder(
                builder: (context) => BambuIcon(
                  name: 'delete_filament',
                  size: 16,
                  applyColorFilter: true,
                  color: GlassButtonsTheme.enabledOf(context)
                      ? IconTheme.of(context).color
                      : Colors.white,
                ),
              ),
              variant: AppButtonVariant.danger,
              onPressed: () => _finish(context, ref),
            ),
          ] else
            AppButton(
              label: '装载耗材',
              icon: Builder(
                builder: (context) => BambuIcon(
                  name: 'add_filament',
                  size: 16,
                  applyColorFilter: true,
                  color: GlassButtonsTheme.enabledOf(context)
                      ? IconTheme.of(context).color
                      : Colors.white,
                ),
              ),
              variant: AppButtonVariant.primary,
              onPressed: () => _changeConsumable(context, ref),
            ),
        ],
      ),
    );
  }

  /// 更换/装载耗材：直接弹出该通道的耗材选择面板。
  /// 非拓竹打印机换卷时会先弹窗询问旧卷剩余克数。
  Future<void> _changeConsumable(BuildContext context, WidgetRef ref) async {
    // 查询打印机品牌，判断是否为拓竹
    final printer = await ref
        .read(printerDaoProvider)
        .getByIdWithChannels(printerId);
    final currentChannel = printer?.channels
        .where((item) => item.channel.id == channel.channel.id)
        .firstOrNull;
    final currentConsumable = currentChannel?.consumable;
    if (currentConsumable != null &&
        !await _canUseDashboardPersonalConsumable(ref, currentConsumable.id)) {
      if (context.mounted) _showDashboardAccountProtected(context);
      return;
    }
    final isBambu = printer?.printer.brand.contains('拓竹') ?? false;
    if (!context.mounted) return;
    await showConsumablePickerForChannel(
      context,
      channel.channel.id,
      isBambu: isBambu,
      oldConsumable: currentConsumable,
    );
  }

  /// 个人模式取下前先区分“确实用完”和“堵头/维修暂取”。
  Future<void> _finish(BuildContext context, WidgetRef ref) async {
    try {
      final printer = await ref
          .read(printerDaoProvider)
          .getByIdWithChannels(printerId);
      final currentChannel = printer?.channels
          .where((item) => item.channel.id == channel.channel.id)
          .firstOrNull;
      final c = currentChannel?.consumable;
      if (c == null) return;
      if (!await _canUseDashboardPersonalConsumable(ref, c.id)) {
        if (context.mounted) _showDashboardAccountProtected(context);
        return;
      }
      final channelLabel = printerFeedChannelLabel(
        channel.channel.channelIndex,
        storedLabel: channel.channel.label,
        legacySingleExternal: externalFeedCount == 1,
      );
      final isFarm = await ref
          .read(consumableDaoProvider)
          .isFarmConsumable(c.id);
      if (!context.mounted) return;

      if (isFarm) {
        final ok = await AppDialog.confirm(
          context,
          '标记通道耗材已用完',
          '$channelLabel 的「${c.manufacturer}」将被标记为用完并清空该供料位。',
          confirmText: '已用完',
          destructive: true,
        );
        if (!ok || !context.mounted) return;
        await ref.read(printerDaoProvider).finishChannel(channel.channel.id);
        if (context.mounted) {
          showSnack(context, '已标记用完并清空通道');
        }
        return;
      }

      final decision = await PersonalSpoolRemovalDialog.show(
        context: context,
        channelLabel: channelLabel,
        spoolLabel:
            '${c.manufacturer} · ${c.colorName ?? c.colorHex} · ${c.materialType}',
        remainingGrams: c.remainingGrams,
        normalDecision: PersonalSpoolRemovalDecision.usedUp,
      );
      if (decision == null || !context.mounted) return;
      final accountScope = ref.read(personalInventoryAccountScopeProvider);

      if (decision == PersonalSpoolRemovalDecision.maintenance) {
        await ref
            .read(printerDaoProvider)
            .pauseChannelRollForMaintenance(
              channel.channel.id,
              enforcePersonalOwner: accountScope.enforce,
              personalOwnerAccount: accountScope.ownerAccount,
            );
        if (context.mounted) {
          showSnack(context, '已保留当前克数；维修完成后点击“继续使用”');
        }
        return;
      }

      if (decision == PersonalSpoolRemovalDecision.takeOff) {
        await ref
            .read(printerDaoProvider)
            .unbindChannel(
              channel.channel.id,
              expectedConsumableId: c.id,
              enforcePersonalOwner: accountScope.enforce,
              personalOwnerAccount: accountScope.ownerAccount,
            );
        if (context.mounted) showSnack(context, '余料已回库；重新装机时选择原卷即可继续使用');
        return;
      }

      await ref
          .read(printerDaoProvider)
          .finishChannel(
            channel.channel.id,
            expectedConsumableId: c.id,
            enforcePersonalOwner: accountScope.enforce,
            personalOwnerAccount: accountScope.ownerAccount,
          );
      if (context.mounted) {
        showSnack(context, '已标记用完并清空通道');
      }
    } catch (error) {
      if (context.mounted) showSnack(context, '未完成：$error', error: true);
    }
  }

  Future<void> _resumeAfterMaintenance(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final printer = await ref
        .read(printerDaoProvider)
        .getByIdWithChannels(printerId);
    final currentChannel = printer?.channels
        .where((item) => item.channel.id == channel.channel.id)
        .firstOrNull;
    final c = currentChannel?.consumable;
    if (c == null) return;
    if (!await _canUseDashboardPersonalConsumable(ref, c.id)) {
      if (context.mounted) _showDashboardAccountProtected(context);
      return;
    }
    final accountScope = ref.read(personalInventoryAccountScopeProvider);
    if (currentChannel!.awaitingSpoolSelection) {
      ref
          .read(spoolChangeQueueProvider.notifier)
          .enqueue(
            SpoolChangeObservation.manualEvent(
              printerSerial: printer?.serial ?? 'local-printer-$printerId',
              printerLabel: printer?.printer.name ?? '打印机 #$printerId',
              printerId: printerId,
              channelIndex: currentChannel.channel.channelIndex,
              isExternal: isExternalFeedChannel(
                currentChannel.channel.channelIndex,
              ),
              externalInputCount: printer!.channels
                  .where(
                    (item) => isExternalFeedChannel(item.channel.channelIndex),
                  )
                  .length,
              externalInputIndex:
                  currentChannel.channel.channelIndex == externalFeedLeftChannel
                  ? 1
                  : 0,
            ),
            personalOwnerAccount: accountScope.enforce
                ? accountScope.ownerAccount
                : null,
          );
      return;
    }
    await ref
        .read(printerDaoProvider)
        .resumeChannelRollAfterMaintenance(
          channel.channel.id,
          enforcePersonalOwner: accountScope.enforce,
          personalOwnerAccount: accountScope.ownerAccount,
        );
    if (context.mounted) {
      showSnack(
        context,
        '已重新装回，从 ${GramUtils.formatGrams(c.remainingGrams)} 继续计算',
      );
    }
  }
}

Future<bool> _canUseDashboardPersonalConsumable(
  WidgetRef ref,
  int consumableId,
) {
  final scope = ref.read(personalInventoryAccountScopeProvider);
  if (!scope.enforce) return Future.value(true);
  return ref
      .read(consumableDaoProvider)
      .ensurePersonalConsumableAccess(
        consumableId,
        ownerAccount: scope.ownerAccount,
      );
}

void _showDashboardAccountProtected(BuildContext context) {
  showSnack(context, '该料位属于其他 Sohun 账号，请切回原账号后操作', error: true);
}

/// 宽屏实时任务行内的耗材与成本摘要。
///
/// 固定放在打印控制按钮左侧，利用原本的横向空位展示最重要的两个值，
/// 不再额外占用卡片底部空间。
class _TaskConsumableCostSummary extends ConsumerWidget {
  const _TaskConsumableCostSummary({required this.status});

  final BambuPrinterStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(activePrintTaskProvider);
    if (task == null || task.id == null) return const SizedBox.shrink();
    final entriesAsync = ref.watch(taskConsumablesProvider(task.id!));

    return SizedBox(
      width: 238,
      child: entriesAsync.when(
        loading: () => Row(
          children: [
            Expanded(
              child: _InlineTaskStat(
                icon: Icons.data_usage_rounded,
                label: '耗材',
                value: '--',
                accent: AppColors.primary,
                tooltip: '正在读取耗材消耗',
              ),
            ),
            const SizedBox(width: 6),
            Expanded(child: _InlineTaskCost(task: task, filamentCost: 0)),
          ],
        ),
        error: (_, __) => Row(
          children: [
            const Expanded(
              child: _InlineTaskStat(
                icon: Icons.data_usage_rounded,
                label: '耗材',
                value: '--',
                accent: AppColors.warning,
                tooltip: '耗材消耗暂不可用',
              ),
            ),
            const SizedBox(width: 6),
            Expanded(child: _InlineTaskCost(task: task, filamentCost: 0)),
          ],
        ),
        data: (entries) {
          final mcPercent = status.mcPercent ?? task.lastMcPercent;
          final isCalibrating = mcPercent == 0;
          double consumed = 0;
          double estimated = 0;
          double synced = 0;
          double filamentCost = 0;
          var unboundCount = 0;
          for (final entry in entries) {
            final current = isCalibrating
                ? 0.0
                : entry.estimatedConsumedAt(mcPercent);
            consumed += current;
            estimated += entry.estimatedGrams;
            synced += entry.lastDeductedGrams;
            if (entry.consumableId == null) unboundCount++;
            final price = entry.costPerKgSnapshot;
            if (price != null && price > 0) {
              filamentCost += current / 1000 * price;
            }
          }
          final activeChannel = int.tryParse(status.trayNow ?? '');
          var visibleEntry = entries.isEmpty ? null : entries.first;
          if (activeChannel != null) {
            for (final entry in entries) {
              if (entry.channelIndex == activeChannel) {
                visibleEntry = entry;
                break;
              }
            }
          }
          final visibleConsumableId = visibleEntry?.consumableId;
          final visibleConsumableAsync = visibleConsumableId == null
              ? null
              : ref.watch(
                  _dashboardConsumableByIdProvider(visibleConsumableId),
                );
          final visibleConsumable =
              visibleConsumableAsync is AsyncData<Consumable?>
              ? visibleConsumableAsync.value
              : null;
          final modelCode = visibleConsumable == null
              ? null
              : FilamentModelCode.of(
                  model: visibleConsumable.model,
                  materialType: visibleConsumable.materialType,
                );
          final modelLegend = visibleConsumable == null
              ? null
              : FilamentModelCode.tooltip(
                  manufacturer: visibleConsumable.manufacturer,
                  model: visibleConsumable.model,
                  materialType: visibleConsumable.materialType,
                );
          final value = isCalibrating
              ? '校准中'
              : estimated <= 0
              ? '--'
              : '${consumed.toStringAsFixed(1)}/${estimated.toStringAsFixed(0)}g';
          final tooltip = entries.isEmpty
              ? '当前任务暂无耗材重量数据'
              : '库存已同步 ${synced.toStringAsFixed(1)}g'
                    '${unboundCount > 0 ? ' · $unboundCount 路未绑定' : ''}'
                    '${modelLegend == null ? '' : '\n$modelLegend'}';
          return Row(
            children: [
              Expanded(
                child: _InlineTaskStat(
                  key: const ValueKey('dashboard-inline-filament'),
                  icon: Icons.data_usage_rounded,
                  label: '耗材',
                  code: modelCode,
                  value: value,
                  accent: unboundCount > 0
                      ? AppColors.warning
                      : AppColors.primary,
                  tooltip: tooltip,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _InlineTaskCost(
                  key: const ValueKey('dashboard-inline-cost'),
                  task: task,
                  filamentCost: filamentCost,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _InlineTaskStat extends StatelessWidget {
  const _InlineTaskStat({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    required this.tooltip,
    this.code,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  final String tooltip;
  final String? code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.48),
          borderRadius: BorderRadius.circular(AppColors.radiusMd),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.62),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: accent),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (code != null) ...[
                        const SizedBox(width: 3),
                        Text(
                          code!,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            color: accent,
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.1,
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
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

/// 耗材实时估算 + 库存同步状态 + 任务成本。
///
/// 显示当前活跃打印任务关联的每卷耗材的实时消耗 + 本任务总成本：
/// - 耗材费 = 各卷消耗克数 × 成本快照单价
/// - 电费 = 功率(kW) × 时长(h) × 电费单价
/// - 机器损耗 = 时长(h) × 损耗率
/// - 人工费 = 时长(h) × 人工费率
/// - 总成本 = 耗材费 + 电费 + 机器损耗 + 人工费
///
/// 校准阶段(mcPercent=0)：显示「校准中，尚未消耗」
// TODO: Remove after the compact live-card migration has shipped. Kept only
// as a short-lived rollback reference; the live card no longer renders it.
// ignore: unused_element
class _FilamentConsumptionRow extends ConsumerWidget {
  final BambuPrinterStatus? status;

  const _FilamentConsumptionRow({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final task = ref.watch(activePrintTaskProvider);
    if (task == null || task.id == null) return const SizedBox.shrink();

    // 用 StreamProvider 缓存流，避免每次 rebuild 新建 async* 生成器导致 DB 查询风暴
    final entriesAsync = ref.watch(taskConsumablesProvider(task.id!));

    return entriesAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (entries) {
        // N8 修复：优先使用实时 status.mcPercent，回退到 task.lastMcPercent
        final mcPercent = status?.mcPercent ?? task.lastMcPercent;
        final isCalibrating = mcPercent == 0;

        if (entries.isEmpty) {
          return _UntrackedConsumptionIndicator(
            mcPercent: mcPercent,
            isCalibrating: isCalibrating,
          );
        }

        // 实时估算用于视觉反馈；lastDeductedGrams 是库存层已确认同步的数值。
        double filamentCost = 0;
        double totalEstimatedConsumed = 0;
        double totalEstimatedGrams = 0;
        double totalSynced = 0;
        var unboundCount = 0;
        for (final e in entries) {
          final estimatedConsumed = isCalibrating
              ? 0.0
              : e.estimatedConsumedAt(mcPercent);
          totalEstimatedConsumed += estimatedConsumed;
          totalEstimatedGrams += e.estimatedGrams;
          totalSynced += e.lastDeductedGrams;
          if (e.consumableId == null) unboundCount++;
          if (e.costPerKgSnapshot != null && e.costPerKgSnapshot! > 0) {
            filamentCost += estimatedConsumed / 1000 * e.costPerKgSnapshot!;
          }
        }

        return Container(
          key: const ValueKey('dashboard-filament-consumption'),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color:
                (isDark
                        ? AppColors.surfaceVariantDark
                        : AppColors.surfaceVariant)
                    .withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  BambuIcon(
                    name: 'spool',
                    size: 13,
                    applyColorFilter: true,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '耗材消耗',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                  if (isCalibrating)
                    Text(
                      '校准中',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiary,
                      ),
                    )
                  else
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        begin: 0,
                        end: totalEstimatedConsumed,
                      ),
                      duration: AppMotion.duration(
                        context,
                        const Duration(milliseconds: 420),
                      ),
                      curve: ExperienceTokens.motionCurve,
                      builder: (context, value, _) => Text(
                        '${value.toStringAsFixed(1)} / ${totalEstimatedGrams.toStringAsFixed(1)}g',
                        style: TextStyle(
                          fontSize: 10,
                          color: isDark
                              ? AppColors.textTertiaryDark
                              : AppColors.textTertiary,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Icon(
                    unboundCount > 0
                        ? Icons.link_off_rounded
                        : Icons.inventory_2_outlined,
                    size: 12,
                    color: unboundCount > 0
                        ? AppColors.warning
                        : AppColors.primary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      unboundCount > 0
                          ? '库存已同步 ${totalSynced.toStringAsFixed(1)}g · $unboundCount 路未绑定'
                          : '库存已同步 ${totalSynced.toStringAsFixed(1)}g',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9,
                        color: unboundCount > 0
                            ? AppColors.warning
                            : (isDark
                                  ? AppColors.textTertiaryDark
                                  : AppColors.textTertiary),
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ...entries.map(
                (entry) => _FilamentLine(
                  entry: entry,
                  estimatedConsumed: isCalibrating
                      ? 0
                      : entry.estimatedConsumedAt(mcPercent),
                  isCalibrating: isCalibrating,
                  hasAms:
                      (status?.amsUnits?.isNotEmpty ?? false) ||
                      (status?.amsTrays?.isNotEmpty ?? false),
                ),
              ),
              if (!isCalibrating) ...[
                const SizedBox(height: 6),
                _TaskCostRow(task: task, filamentCost: filamentCost),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _UntrackedConsumptionIndicator extends StatelessWidget {
  final int mcPercent;
  final bool isCalibrating;

  const _UntrackedConsumptionIndicator({
    required this.mcPercent,
    required this.isCalibrating,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final tertiary = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    return Container(
      key: const ValueKey('dashboard-untracked-consumption'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color:
            (isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant)
                .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BambuIcon(
                name: 'spool',
                size: 13,
                applyColorFilter: true,
                color: tertiary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '耗材消耗',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: secondary,
                  ),
                ),
              ),
              Text(
                isCalibrating ? '校准中' : '等待耗材重量',
                style: TextStyle(fontSize: 10, color: tertiary),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isCalibrating ? '校准阶段暂不计算耗材消耗' : '当前任务暂无可用耗材重量，打印进度为 $mcPercent%',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9,
              color: tertiary,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 单卷耗材估算行。
class _FilamentLine extends StatelessWidget {
  final PrintTaskConsumable entry;
  final double estimatedConsumed;
  final bool isCalibrating;
  final bool hasAms;

  const _FilamentLine({
    required this.entry,
    required this.estimatedConsumed,
    required this.isCalibrating,
    required this.hasAms,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final progress = entry.estimatedGrams > 0
        ? (estimatedConsumed / entry.estimatedGrams).clamp(0.0, 1.0)
        : 0.0;
    final channelLabel = _channelLabel(entry.channelIndex, hasAms: hasAms);

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Row(
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Center(
                    child: Text(
                      'T${entry.toolIndex}',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    channelLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: AppProgress(
              value: progress,
              thickness: 6,
              showGlow: false,
              animate: !isCalibrating,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 84,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: estimatedConsumed),
              duration: AppMotion.duration(
                context,
                const Duration(milliseconds: 420),
              ),
              curve: ExperienceTokens.motionCurve,
              builder: (context, value, _) => Text(
                '${value.toStringAsFixed(1)}/${entry.estimatedGrams.toStringAsFixed(0)}g',
                textAlign: TextAlign.right,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 10,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: entry.consumableId == null
                ? '该通道尚未绑定库存耗材，当前仅展示估算'
                : '库存已同步 ${entry.lastDeductedGrams.toStringAsFixed(1)}g',
            child: Icon(
              entry.consumableId == null
                  ? Icons.link_off_rounded
                  : Icons.check_circle_outline_rounded,
              size: 13,
              color: entry.consumableId == null
                  ? AppColors.warning
                  : AppColors.success,
            ),
          ),
        ],
      ),
    );
  }

  static String _channelLabel(int index, {required bool hasAms}) {
    return printerFeedChannelLabel(
      index,
      compact: true,
      legacySingleExternal: !hasAms,
    );
  }
}

/// 任务成本行。显示单个打印任务的总成本（耗材费 + 电费 + 机器损耗 + 人工费）。
///
/// 成本参数从 SharedPreferences 读取（与「耗材成本」页设置同步）：
/// - cost_elec_price: 电费单价（元/度）
/// - cost_printer_power: 打印机功率（W）
/// - cost_wear_rate: 机器损耗率（元/小时）
/// - cost_labor_rate: 每小时人工费（元/小时）
///
/// 计算公式：
/// - 时长(h) = elapsedSeconds / 3600
/// - 电费 = 功率(kW) × 时长 × 电费单价
///   功率按任务状态区分：printing 用满功率，paused/planned 用待机功率
/// - 机器损耗 = 时长 × 损耗率
/// - 人工费 = 时长 × 人工费率
/// - 总成本 = 耗材费 + 电费 + 机器损耗 + 人工费
class _TaskCostRow extends StatefulWidget {
  final PrintTask task;
  final double filamentCost; // 耗材费（已由父级 _FilamentConsumptionRow 计算好）

  const _TaskCostRow({required this.task, required this.filamentCost});

  @override
  State<_TaskCostRow> createState() => _TaskCostRowState();
}

/// 成本参数静态缓存。
///
/// 多个任务成本摘要实例共享同一份缓存，
/// 避免每个实例都重复读取 SharedPreferences。缓存有效期 30 秒，
/// 与 [_InlineTaskCostState._timer] 刷新周期一致，保证设置页修改后能及时反映。
class _CostParamsCache {
  static _CostParamsCache? _instance;
  static _CostParamsCache get instance {
    final i = _instance;
    if (i != null && !i._isExpired) return i;
    _instance = _CostParamsCache._();
    return _instance!;
  }

  double elecPrice = 0.6; // 元/度
  double printerPower = 150; // W（打印中满功率）
  double idlePower = 30; // W（待机/预热/暂停功率，默认 30W）
  double wearRate = 0.5; // 元/小时
  double laborRate = 0; // 元/小时
  DateTime _loadedAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _isExpired =>
      DateTime.now().difference(_loadedAt) > const Duration(seconds: 30);

  _CostParamsCache._();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    elecPrice = prefs.getDouble(_kElecPrice) ?? 0.6;
    printerPower = prefs.getDouble(_kPrinterPower) ?? 150;
    idlePower = prefs.getDouble(_kIdlePower) ?? 30;
    wearRate = prefs.getDouble(_kWearRate) ?? 0.5;
    laborRate = prefs.getDouble(_kLaborRate) ?? 0;
    _loadedAt = DateTime.now();
  }

  // 成本参数持久化键（与 filament_cost_screen.dart 保持一致）
  static const _kElecPrice = 'cost_elec_price';
  static const _kPrinterPower = 'cost_printer_power';
  static const _kIdlePower = 'cost_idle_power'; // 新增：待机功率
  static const _kWearRate = 'cost_wear_rate';
  static const _kLaborRate = 'cost_labor_rate';
}

class _InlineTaskCost extends StatefulWidget {
  const _InlineTaskCost({
    super.key,
    required this.task,
    required this.filamentCost,
  });

  final PrintTask task;
  final double filamentCost;

  @override
  State<_InlineTaskCost> createState() => _InlineTaskCostState();
}

class _InlineTaskCostState extends State<_InlineTaskCost> {
  bool _loaded = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    await _CostParamsCache.instance.load();
    if (mounted) setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return _InlineTaskStat(
        icon: Icons.payments_outlined,
        label: '成本',
        value: '--',
        accent: AppColors.primary,
        tooltip: '正在计算任务成本',
      );
    }
    final cache = _CostParamsCache.instance;
    final elapsedHours = widget.task.elapsedSeconds / 3600.0;
    final isPrinting = widget.task.status == PrintTaskStatus.printing;
    final effectivePower = isPrinting ? cache.printerPower : cache.idlePower;
    final elecCost = (effectivePower / 1000) * elapsedHours * cache.elecPrice;
    final wearCost = elapsedHours * cache.wearRate;
    final laborCost = elapsedHours * cache.laborRate;
    final total = widget.filamentCost + elecCost + wearCost + laborCost;
    return _InlineTaskStat(
      icon: Icons.payments_outlined,
      label: '成本',
      value: '¥${total.toStringAsFixed(2)}',
      accent: AppColors.primary,
      tooltip:
          '耗材 ¥${widget.filamentCost.toStringAsFixed(2)} · '
          '电费 ¥${elecCost.toStringAsFixed(2)} · '
          '损耗 ¥${wearCost.toStringAsFixed(2)} · '
          '人工 ¥${laborCost.toStringAsFixed(2)}',
    );
  }
}

class _TaskCostRowState extends State<_TaskCostRow> {
  bool _loaded = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    // 每 30 秒刷新一次，让时长相关的成本（电费/损耗/人工）随时间增长
    // 同时刷新缓存（用户可能在设置页改了参数）
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    await _CostParamsCache.instance.load();
    if (mounted) {
      setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cache = _CostParamsCache.instance;

    final elapsedHours = widget.task.elapsedSeconds / 3600.0;
    // 功率按任务状态区分：printing 用满功率，paused/planned 用待机功率
    // 减少暂停期间电费高估问题（实际暂停后打印机仅维持待机功耗）
    final isPrinting = widget.task.status == PrintTaskStatus.printing;
    final effectivePower = isPrinting ? cache.printerPower : cache.idlePower;
    final elecCost = (effectivePower / 1000.0) * elapsedHours * cache.elecPrice;
    final wearCost = elapsedHours * cache.wearRate;
    final laborCost = elapsedHours * cache.laborRate;
    final total = widget.filamentCost + elecCost + wearCost + laborCost;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.2),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 主行：任务成本 + 总金额（强调色）
          Row(
            children: [
              Icon(Icons.payments_rounded, size: 13, color: AppColors.primary),
              const SizedBox(width: 4),
              Text(
                '成本',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                '¥${total.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          // 明细：耗材 / 电费 / 损耗 / 人工 / 时长
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: [
              _costChip('耗材', widget.filamentCost, isDark),
              _costChip('电费', elecCost, isDark),
              _costChip('损耗', wearCost, isDark),
              _costChip('人工', laborCost, isDark),
              _durationChip(elapsedHours, isDark),
            ],
          ),
        ],
      ),
    );
  }

  Widget _costChip(String label, double value, bool isDark) {
    return Text(
      '$label ¥${value.toStringAsFixed(1)}',
      style: TextStyle(
        fontSize: 10,
        color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _durationChip(double hours, bool isDark) {
    final h = hours.floor();
    final m = ((hours - h) * 60).round();
    return Text(
      '时长 ${h}h${m}m',
      style: TextStyle(
        fontSize: 10,
        color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      ),
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GlassCard(
      level: GlassLevel.l1,
      color: isDark ? AppColors.glassFillL2Dark : AppColors.glassFillL2,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 240),
        child: const EmptyState(
          bambuIconName: 'printer',
          title: '从左侧选择打印机',
          subtitle: '选择一台设备查看与操作通道耗材',
        ),
      ),
    );
  }
}

/// 打印机归属账号标签。
///
/// 多账号聚合显示：云设备显示所属账号 email，LAN 直连设备显示「LAN」。
/// ownerAccount 为 null 时表示 LAN 直连或未知归属。
class _OwnerBadge extends StatelessWidget {
  /// 云端归属使用 "email|region_code" 格式；LAN 由 [isLan] 明确标记。
  final String? ownerAccount;
  final bool isLan;

  const _OwnerBadge({this.ownerAccount, required this.isLan});

  @override
  Widget build(BuildContext context) {
    final label = isLan
        ? 'LAN'
        : (ownerAccount!.contains('|')
              ? ownerAccount!.split('|')[0]
              : ownerAccount!);
    return Container(
      constraints: const BoxConstraints(maxWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: isLan ? AppColors.successContainer : AppColors.primaryContainer,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isLan ? AppColors.success : AppColors.onPrimaryContainer,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
