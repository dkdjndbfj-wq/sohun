import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/friendly_error.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../providers/printer_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/icon_action_button.dart';
import '../print_queue/print_queue_panel.dart';
import 'add_printer_sheet.dart';
import 'printer_card.dart';
import 'printer_camera_dialog.dart';

/// 打印机管理页。v5 Cockpit Tools 风格。
///
/// 顶部 TabBar 用 GlassCard L1 包裹，切换「设备列表」与「打印队列」。
/// 设备列表为响应式 GlassCard L2 卡片网格，空状态走
/// [EmptyState]（useGlass + bambuIconName: 'printer'）。
///
/// v5 视觉升级：
/// - TabBar 用 GlassCard L1 包裹
/// - 空状态用 EmptyState(useGlass: true, bambuIconName: 'printer')
/// - 添加打印机按钮用 BambuIcon(name: 'add_filament')
/// - AppSpacing / AppTypography 间距排版系统
///
/// Tab 化：顶部 TabBar 切换「设备列表」与「打印队列」两个视图，
/// 设备列表保留原 ConsumerWidget build 逻辑（提取为 [_DeviceListTab]），
/// 打印队列为 [PrintQueuePanel]。
class PrintersScreen extends ConsumerStatefulWidget {
  const PrintersScreen({super.key});

  @override
  ConsumerState<PrintersScreen> createState() => _PrintersScreenState();
}

class _PrintersScreenState extends ConsumerState<PrintersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // 顶部 TabBar：GlassCard L1 包裹
          GlassCard(
            level: GlassLevel.l1,
            margin: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              0,
            ),
            padding: const EdgeInsets.all(3),
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            child: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: '设备列表'),
                Tab(text: '打印队列'),
              ],
              labelColor: AppColors.primary,
              unselectedLabelColor: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
              indicatorColor: AppColors.primary,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(AppColors.radiusMd),
              ),
              dividerColor: Colors.transparent,
              labelStyle: AppTypography.body.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
              unselectedLabelStyle: AppTypography.body.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // TabBarView
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [_DeviceListTab(), PrintQueuePanel()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 设备列表 tab。保留原 [PrintersScreen] 的 ConsumerWidget build 逻辑。
class _DeviceListTab extends ConsumerStatefulWidget {
  const _DeviceListTab();

  @override
  ConsumerState<_DeviceListTab> createState() => _DeviceListTabState();
}

class _DeviceListTabState extends ConsumerState<_DeviceListTab> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(printersWithChannelsProvider);
    // 暗色模式判定，用于错误文案颜色适配
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: async.when(
        loading: () => const LoadingState(),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Text(
              '加载失败：${friendlyError(err)}',
              textAlign: TextAlign.center,
              style: AppTypography.body.copyWith(
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
            ),
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return EmptyState(
              bambuIconName: 'printer',
              useGlass: true,
              title: '还没有打印机',
              subtitle: '添加你的打印机并绑定耗材',
              actionLabel: '添加打印机',
              onAction: () => AddPrinterSheet.show(context),
            );
          }
          final safeIndex = _selectedIndex.clamp(0, list.length - 1);
          return _PrinterStudio(
            printers: list,
            selectedIndex: safeIndex,
            onSelect: (index) => setState(() => _selectedIndex = index),
            onAdd: () => AddPrinterSheet.show(context),
          );
        },
      ),
    );
  }
}

class _PrinterStudio extends StatelessWidget {
  const _PrinterStudio({
    required this.printers,
    required this.selectedIndex,
    required this.onSelect,
    required this.onAdd,
  });

  final List<PrinterWithChannels> printers;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final selected = printers[selectedIndex];
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              ExperienceTokens.pageGutter,
              AppSpacing.md,
              ExperienceTokens.pageGutter,
              AppSpacing.lg,
            ),
            child: ExperiencePageHeader(
              title: '实时打印工作室',
              description: '把设备、通道和正在使用的耗材放在同一个空间里。选择设备即可拉近查看。',
              actions: [
                AppButton(
                  label: '添加打印机',
                  icon: Builder(
                    builder: (context) => BambuIcon(
                      name: 'add_filament',
                      size: 18,
                      color: GlassButtonsTheme.enabledOf(context)
                          ? IconTheme.of(context).color
                          : AppColors.onPrimary,
                      applyColorFilter: true,
                    ),
                  ),
                  onPressed: onAdd,
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              ExperienceTokens.pageGutter,
              0,
              ExperienceTokens.pageGutter,
              80,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 820;
                final mainPrinter = TactileLift(
                  key: ValueKey('studio-printer-${selected.printer.id}'),
                  // Keep the printer card hit region stable while the pointer
                  // rests over a channel tile. Tilting/lifting this large
                  // surface makes its boundary move under the cursor and can
                  // repeatedly trigger enter/exit on desktop.
                  enabled: false,
                  maxTilt: 0.008,
                  child: SizedBox(
                    width: double.infinity,
                    height: 470,
                    child: PrinterCard(
                      key: ValueKey(selected.printer.id),
                      data: selected,
                    ),
                  ),
                );
                final printerStage = AnimatedSwitcher(
                  duration: ExperienceTokens.contentDuration,
                  switchInCurve: ExperienceTokens.motionCurve,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: 0.985,
                        end: 1,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: mainPrinter,
                );

                if (compact) {
                  return OpenStage(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        printerStage,
                        const SizedBox(height: AppSpacing.lg),
                        SizedBox(
                          height: 76,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: printers.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: AppSpacing.sm),
                            itemBuilder: (context, index) => SizedBox(
                              width: 190,
                              child: _PrinterDockTile(
                                data: printers[index],
                                selected: index == selectedIndex,
                                onTap: () => onSelect(index),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return OpenStage(
                  // The printer is the primary object on this screen. Keep
                  // the stage breathing, but avoid a large empty frame around
                  // a narrow, centered card on ordinary desktop widths.
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: SizedBox(
                    height: 470,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: SizedBox.expand(child: printerStage)),
                        const SizedBox(width: AppSpacing.lg),
                        SizedBox(
                          width: 250,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ExperienceSectionHeading(
                                title: '设备台',
                                trailing: Text(
                                  '${printers.length} 台',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.md),
                              Expanded(
                                child: ListView.separated(
                                  itemCount: printers.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: AppSpacing.sm),
                                  itemBuilder: (context, index) =>
                                      _PrinterDockTile(
                                        data: printers[index],
                                        selected: index == selectedIndex,
                                        onTap: () => onSelect(index),
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _PrinterDockTile extends ConsumerWidget {
  const _PrinterDockTile({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  final PrinterWithChannels data;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final printer = data.printer;
    final hasSerial = data.serial?.trim().isNotEmpty == true;
    final title = printer.name?.trim().isNotEmpty == true
        ? printer.name!.trim()
        : printer.model;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.11)
          : scheme.surface.withValues(alpha: 0.58),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: ExperienceTokens.hoverDuration,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.42)
                  : scheme.outlineVariant.withValues(alpha: 0.52),
            ),
          ),
          child: Row(
            children: [
              BambuIcon(
                name: 'printer',
                size: 24,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                applyColorFilter: true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${printer.brand} ${printer.model}  ·  ${data.channels.length} 通道',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                    if (data.channels.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _PrinterMaterialRail(channels: data.channels),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconActionButton(
                icon: Icons.videocam_outlined,
                size: 28,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                background: selected
                    ? scheme.primary.withValues(alpha: .12)
                    : scheme.surfaceContainerHighest.withValues(alpha: .52),
                tooltip: hasSerial ? '查看摄像头' : '该打印机没有序列号',
                onTap: hasSerial
                    ? () => showPrinterCameraDialog(context, ref, printer: data)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrinterMaterialRail extends StatelessWidget {
  const _PrinterMaterialRail({required this.channels});

  final List<ChannelWithConsumable> channels;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loaded = channels.where((channel) => channel.isActive).length;
    return Tooltip(
      message: '已装载 $loaded / ${channels.length} 个通道',
      child: SizedBox(
        height: 5,
        child: Row(
          children: [
            for (var index = 0; index < channels.length; index++) ...[
              Expanded(
                child: DecoratedBox(
                  key: ValueKey(
                    'printer-channel-rail-${channels[index].channel.id}',
                  ),
                  decoration: BoxDecoration(
                    color: channels[index].consumable == null
                        ? scheme.outlineVariant.withValues(alpha: 0.55)
                        : ColorUtils.fromHex(
                            channels[index].consumable!.colorHex,
                          ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              if (index != channels.length - 1) const SizedBox(width: 3),
            ],
          ],
        ),
      ),
    );
  }
}
