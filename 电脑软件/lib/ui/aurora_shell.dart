import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/printer_fault_service.dart';
import '../core/app_variant.dart';
import '../core/theme/interaction_effects.dart';
import '../core/theme/personal_desktop_theme.dart';
import '../widgets/personal_desktop_chrome.dart';
import '../widgets/app_brand_icon.dart';
import '../providers/printer_connection_provider.dart';
import '../providers/slicer_provider.dart';
import '../providers/bambu_account_manager.dart';
import '../providers/bambu_cloud_provider.dart';
import '../providers/print_queue_provider.dart';
import '../providers/community_preset_provider.dart';
import '../providers/batch_recognition_provider.dart';
import '../providers/autoclear_provider.dart';
import '../providers/stock_alert_provider.dart';
import '../data/prefs/app_prefs.dart';
import '../features/calibration/calibration_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/diagnostics/diagnostics_screen.dart';
import '../features/filament_cost/filament_cost_screen.dart';
import '../features/firmware/firmware_panel.dart';
import '../features/inventory/inventory_screen.dart';
import '../features/print_history/print_history_screen.dart';
import '../features/project_orders/personal_project_orders_screen.dart';
import '../features/printers/printers_screen.dart';
import '../features/restock/restock_screen.dart';
import '../features/support/support_screen.dart';
import '../features/usage/usage_log_screen.dart';
import '../widgets/bambu_icon.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/account_quick_switcher.dart';
import '../features/slicer/slicer_launcher_button.dart';
import '../features/settings/settings_sheet.dart';
import '../features/studio/studio_farm_shell.dart';
import 'aurora_design.dart';
import 'aurora_settings_page.dart';
import 'aurora_parameter_plaza.dart';
import 'workspace_navigation.dart';

class AuroraWorkspace extends ConsumerStatefulWidget {
  const AuroraWorkspace({super.key});

  @override
  ConsumerState<AuroraWorkspace> createState() => _AuroraWorkspaceState();
}

class _AuroraWorkspaceState extends ConsumerState<AuroraWorkspace> {
  String _selectedPageId = WorkspacePageIds.dashboard;
  bool _collapsed = false;
  bool _sidebarMotionReady = false;
  final Set<String> _builtPages = {WorkspacePageIds.dashboard};

  static const _prefKey = 'aurora_sidebar_collapsed';

  final _baseItems = const [
    _NavSpec(
      WorkspacePageIds.dashboard,
      '工作台',
      'tab_home_active',
      DashboardScreen(),
      group: '工作',
    ),
    _NavSpec(
      WorkspacePageIds.printers,
      '打印机',
      'printer',
      PrintersScreen(),
      group: '工作',
    ),
    _NavSpec(
      WorkspacePageIds.inventory,
      '库存',
      'tab_filament_active',
      InventoryScreen(),
      group: '材料',
    ),
    _NavSpec(
      WorkspacePageIds.cost,
      '耗材成本',
      'monitor_item_cost',
      FilamentCostScreen(),
      group: '材料',
    ),
    _NavSpec(
      WorkspacePageIds.restock,
      '采购清单',
      'add_filament',
      RestockScreen(),
      group: '材料',
    ),
    _NavSpec(
      WorkspacePageIds.statistics,
      '统计',
      'monitor_item_prediction',
      UsageLogScreen(),
      group: '洞察',
    ),
    _NavSpec(
      WorkspacePageIds.history,
      '打印历史',
      'monitor_item_print',
      PrintHistoryScreen(),
      group: '洞察',
    ),
    _NavSpec(
      WorkspacePageIds.projects,
      '项目',
      'param_plate',
      PersonalProjectsScreen(),
      group: '工作',
    ),
    _NavSpec(
      WorkspacePageIds.diagnostics,
      '诊断中心',
      'monitor',
      DiagnosticsScreen(),
      group: '洞察',
    ),
    _NavSpec(
      WorkspacePageIds.calibration,
      '质量优化',
      'tab_calibration_active',
      CalibrationScreen(),
      group: '调校',
    ),
    _NavSpec(
      WorkspacePageIds.plaza,
      '参数广场',
      'tab_presets_active',
      AuroraParameterPlazaPage(),
      group: '调校',
    ),
    _NavSpec(
      WorkspacePageIds.firmware,
      '固件管理',
      'firmware_management',
      FirmwarePanel(),
      group: '调校',
    ),
    _NavSpec(
      WorkspacePageIds.support,
      '共创致谢',
      'help',
      SupportScreen(),
      group: '其他',
    ),
    _NavSpec(
      WorkspacePageIds.settings,
      '设置',
      'settings',
      AuroraSettingsPage(),
      group: '其他',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _loadCollapsed();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(autoclearServiceProvider).loadAll();
    });
  }

  Future<void> _loadCollapsed() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _collapsed = prefs.getBool(_prefKey) ?? false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _sidebarMotionReady = true);
    });
  }

  Future<void> _toggleCollapsed() async {
    setState(() {
      _sidebarMotionReady = true;
      _collapsed = !_collapsed;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, _collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final studioEnabled =
        AppVariant.isFarm || ref.watch(studioModeEnabledProvider);
    // The farm slice inbox must stay alive before the farm-only early return.
    ref.watch(slicerWatcherProvider);
    if (studioEnabled) {
      return const StudioFarmWorkspace();
    }
    final items = _baseItems;
    final selectedIndex = items.indexWhere(
      (item) => item.id == _selectedPageId,
    );
    final index = selectedIndex < 0 ? 0 : selectedIndex;
    ref.listen<String?>(workspaceNavigationRequestProvider, (_, next) {
      if (next == null) return;
      final targetIndex = items.indexWhere((item) => item.id == next);
      if (targetIndex < 0) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _selectPage(items, targetIndex);
        ref.read(workspaceNavigationRequestProvider.notifier).state = null;
      });
    });
    ref.listen<BambuCloudState>(bambuCloudProvider, (previous, next) {
      final previousError = previous?.errorMessage;
      final nextError = next.errorMessage;
      if (previousError == null && nextError != null && nextError.isNotEmpty) {
        showSnack(
          context,
          nextError,
          error: true,
          duration: const Duration(seconds: 8),
          actionLabel: '重新登录',
          onAction: () => SettingsSheet.show(context),
        );
      }
    });
    // Keep the personal printer connector alive without rebuilding the entire
    // application shell for every MQTT telemetry packet. Printer pages watch
    // the detailed status themselves; the shell only needs connection changes.
    ref.watch(
      activePrinterConnectionProvider.select((value) => value.connectionState),
    );
    ref.watch(printQueueStateMachineProvider);
    ref.watch(batchRecognitionProvider);

    return Focus(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          // Ctrl+1~9：切换到第 N 个页面（符合浏览器/IDE 的通用心智）
          for (var i = 0; i < items.length && i < 9; i++)
            SingleActivator(
              LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i),
              control: true,
            ): () {
              _selectPage(items, i);
            },
          // Alt+1~9：切换到第 N 个拓竹账号
          // 不用 Ctrl+Shift+数字：Windows 中文输入法（微软拼音/搜狗）默认占用该组合切换输入法
          for (var i = 0; i < 9; i++)
            SingleActivator(
              LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i),
              alt: true,
            ): () {
              _switchAccountByIndex(i);
            },
        },
        child: AuroraBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Row(
              children: [
                _AuroraSidebar(
                  items: items,
                  index: index,
                  collapsed: _collapsed,
                  animate: _sidebarMotionReady,
                  onSelect: (target) => _selectPage(items, target),
                  onToggle: _toggleCollapsed,
                ),
                Expanded(
                  child: Column(
                    children: [
                      _AuroraTopBar(
                        current: items[index],
                        items: items,
                        onNavigate: (target) => _selectPage(items, target),
                      ),
                      Expanded(
                        child: _WorkspacePageViewport(
                          index: index,
                          children: [
                            for (final item in items)
                              _builtPages.contains(item.id)
                                  ? item.page
                                  : const SizedBox.shrink(),
                          ],
                        ),
                      ),
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

  void _selectPage(List<_NavSpec> items, int index) {
    if (index < 0 || index >= items.length) return;
    final target = items[index];
    if (target.id == _selectedPageId) return;
    final previousId = _selectedPageId;
    final activatesParameterPlaza = target.page is AuroraParameterPlazaPage;
    setState(() {
      _selectedPageId = target.id;
      _builtPages
        ..removeWhere(
          (builtId) =>
              builtId != WorkspacePageIds.dashboard &&
              builtId != previousId &&
              builtId != target.id,
        )
        ..add(target.id);
    });
    if (activatesParameterPlaza) {
      ref.read(parameterPlazaActivationProvider.notifier).state++;
    }
  }

  Future<void> _switchAccountByIndex(int index) async {
    final managerState = ref.read(bambuAccountManagerProvider);
    final accounts = managerState.accounts;
    if (index >= accounts.length) return;

    final target = accounts[index];
    if (managerState.activeAccountEmail == target.email &&
        managerState.activeRegion == target.region) {
      return;
    }

    final ok = await ref
        .read(bambuAccountManagerProvider.notifier)
        .switchAccount(target.email, target.region);
    if (!mounted) return;
    showSnack(
      context,
      ok ? '已切换到 ${target.displayName}' : '账号切换失败',
      error: !ok,
    );
  }
}

class _WorkspacePageViewport extends StatelessWidget {
  const _WorkspacePageViewport({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Page content must remain visible even when the desktop window is
    // occluded during a navigation transition. A persistent opacity ticker
    // can otherwise be left at zero after reactivation and produce a white
    // workspace with an otherwise healthy accessibility tree.
    return IndexedStack(index: index, children: children);
  }
}

class _NavSpec {
  final String id;
  final String label;
  final String icon;
  final Widget page;
  final String group;

  const _NavSpec(
    this.id,
    this.label,
    this.icon,
    this.page, {
    required this.group,
  });
}

class _AuroraSidebar extends StatelessWidget {
  final List<_NavSpec> items;
  final int index;
  final bool collapsed;
  final bool animate;
  final ValueChanged<int> onSelect;
  final VoidCallback onToggle;

  const _AuroraSidebar({
    required this.items,
    required this.index,
    required this.collapsed,
    required this.animate,
    required this.onSelect,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: animate
          ? AppMotion.duration(context, const Duration(milliseconds: 180))
          : Duration.zero,
      curve: Curves.easeOutCubic,
      width: collapsed ? Aurora.sidebarClosed : Aurora.sidebarWidth,
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      child: PersonalDesktopChrome(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Drive the compact layout from the animated width itself. Switching
            // immediately on the target state used to overflow during transitions.
            final compact = constraints.maxWidth < 96;
            return Column(
              children: [
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 14),
                    child: Row(
                      children: [
                        const AppBrandIcon(size: 32, radius: 9),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'sohun',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Text(
                                '个人工作空间',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, i) => const SizedBox(height: 4),
                    itemBuilder: (context, i) {
                      final item = items[i];
                      final beginsGroup =
                          i == 0 || items[i - 1].group != item.group;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (beginsGroup)
                            compact
                                ? Padding(
                                    padding: EdgeInsets.only(
                                      top: i == 0 ? 0 : 8,
                                      bottom: 6,
                                    ),
                                    child: Divider(
                                      height: 1,
                                      color: Aurora.line,
                                    ),
                                  )
                                : Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      10,
                                      i == 0 ? 2 : 14,
                                      10,
                                      7,
                                    ),
                                    child: Text(
                                      item.group,
                                      style: TextStyle(
                                        color: Aurora.muted,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        letterSpacing: 0,
                                      ),
                                    ),
                                  ),
                          _NavTile(
                            item: item,
                            selected: i == index,
                            collapsed: compact,
                            onTap: () => onSelect(i),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                BambuGlyphButton(
                  icon: collapsed ? 'expand_btn' : 'collapse_btn',
                  tooltip: collapsed ? '展开侧边栏' : '收起侧边栏',
                  background: Aurora.fill,
                  color: Aurora.textSoft,
                  size: compact ? 32 : 34,
                  onPressed: onToggle,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final _NavSpec item;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  const _NavTile({
    required this.item,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? personalDesktopAccentText(Theme.of(context))
        : Aurora.textSoft;
    return Tooltip(
      key: ValueKey('personal-nav-${item.id}'),
      message: item.label,
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppMotion.duration(
              context,
              const Duration(milliseconds: 180),
            ),
            curve: Curves.easeOutCubic,
            height: 42,
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 10),
            decoration: BoxDecoration(
              color: selected
                  ? Aurora.primary.withValues(alpha: 0.1)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? Aurora.primary.withValues(alpha: 0.18)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisAlignment: collapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                AnimatedScale(
                  duration: AppMotion.duration(
                    context,
                    const Duration(milliseconds: 180),
                  ),
                  curve: Curves.easeOutCubic,
                  scale: selected ? 1 : 0.94,
                  child: BambuIcon(
                    name: item.icon,
                    size: 20,
                    color: color,
                    applyColorFilter: true,
                  ),
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: AnimatedDefaultTextStyle(
                      duration: AppMotion.duration(
                        context,
                        const Duration(milliseconds: 180),
                      ),
                      curve: Curves.easeOutCubic,
                      style: Theme.of(context).textTheme.titleMedium!.copyWith(
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: color,
                        letterSpacing: 0,
                      ),
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuroraTopBar extends ConsumerWidget {
  final _NavSpec current;
  final List<_NavSpec> items;
  final ValueChanged<int> onNavigate;

  const _AuroraTopBar({
    required this.current,
    required this.items,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cloud = ref.watch(bambuCloudProvider);
    final allCloud = ref.watch(allCloudDevicesProvider);
    final refreshing = cloud.isLoading || allCloud.isLoading;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 12, 0),
      child: PersonalDesktopChrome(
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showLauncher = constraints.maxWidth >= 700;
              return Row(
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: AppMotion.duration(
                        context,
                        const Duration(milliseconds: 220),
                      ),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(-0.025, 0),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        );
                      },
                      child: Row(
                        key: ValueKey(current.label),
                        children: [
                          BambuIcon(
                            name: current.icon,
                            size: 22,
                            color: Aurora.primary,
                            applyColorFilter: true,
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              current.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Aurora.title(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      BambuGlyphButton(
                        icon: 'refresh_normal',
                        tooltip: refreshing ? '正在刷新云设备' : '刷新云设备',
                        background: Aurora.fill,
                        color: Aurora.textSoft,
                        onPressed: refreshing
                            ? null
                            : () => _refreshCloudDevices(context, ref),
                      ),
                      const SizedBox(width: 4),
                      BambuGlyphButton(
                        icon: 'search',
                        tooltip: '功能说明与常见问题',
                        background: Aurora.fill,
                        color: Aurora.textSoft,
                        onPressed: () => _openSearch(context),
                      ),
                      const SizedBox(width: 4),
                      _NotificationButton(
                        onNavigate: (pageId) {
                          final target = items.indexWhere(
                            (item) => item.id == pageId,
                          );
                          if (target >= 0) onNavigate(target);
                        },
                      ),
                      const SizedBox(width: 6),
                      const AccountQuickSwitcher(),
                      if (showLauncher) ...[
                        const SizedBox(width: 6),
                        const SlicerLauncherButton(compact: true),
                      ],
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openSearch(BuildContext context) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (_) => _HelpSearchDialog(items: items),
    );
    if (selected != null) onNavigate(selected);
  }

  Future<void> _refreshCloudDevices(BuildContext context, WidgetRef ref) async {
    final before = ref.read(allCloudDevicesProvider).devices.length;
    final hasActiveSession = ref.read(bambuCloudProvider).session != null;

    try {
      if (hasActiveSession) {
        await ref.read(bambuCloudProvider.notifier).refreshDevices();
      }
      await ref
          .read(allCloudDevicesProvider.notifier)
          .refresh(forceRefresh: true);
      if (!context.mounted) return;

      final result = ref.read(allCloudDevicesProvider);
      final currentError = ref.read(bambuCloudProvider).errorMessage;
      final failed = result.failedAccounts.length;
      final after = result.devices.length;
      final message =
          currentError ??
          (failed > 0
              ? '已刷新 $after 台云设备，$failed 个账号刷新失败'
              : after == before
              ? '云设备已刷新，共 $after 台（无变化）'
              : '云设备已刷新：$before 台 → $after 台');
      showSnack(
        context,
        message,
        tone: currentError != null || failed > 0
            ? AppNoticeTone.warning
            : AppNoticeTone.success,
      );
    } catch (error) {
      if (!context.mounted) return;
      showSnack(context, '刷新云设备失败：$error', error: true);
    }
  }
}

/// 顶栏通知按钮。
///
/// 接入真实的库存预警数据（[stockAlertsProvider]）：
/// - 有告警时按钮右上角显示数量徽标（紧急=红色，低库存=橙色）
/// - 点击弹出通知面板，列出具体告警项，可一键跳转到「库存」或「采购清单」
class _NotificationButton extends ConsumerWidget {
  final ValueChanged<String> onNavigate;

  const _NotificationButton({required this.onNavigate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alertsAsync = ref.watch(stockAlertsProvider);
    final alerts = alertsAsync.maybeWhen(
      data: (list) =>
          list.where((a) => a.level != StockLevel.healthy).toList()
            ..sort((a, b) => a.level.index.compareTo(b.level.index)),
      orElse: () => const <StockAlertItem>[],
    );
    final criticalCount = alerts
        .where((a) => a.level == StockLevel.critical)
        .length;
    final badgeColor = criticalCount > 0 ? Aurora.danger : Aurora.warning;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        BambuGlyphButton(
          icon: 'info',
          tooltip: alerts.isEmpty ? '通知' : '通知（${alerts.length} 条库存预警）',
          background: Aurora.fill,
          color: alerts.isEmpty ? Aurora.textSoft : badgeColor,
          onPressed: () => _openPanel(context, alerts),
        ),
        if (alerts.isNotEmpty)
          Positioned(
            right: -2,
            top: -2,
            child: IgnorePointer(
              child: Container(
                constraints: const BoxConstraints(minWidth: 16),
                height: 16,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Aurora.panelStrong, width: 1.5),
                ),
                child: Center(
                  child: Text(
                    alerts.length > 99 ? '99+' : '${alerts.length}',
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _openPanel(
    BuildContext context,
    List<StockAlertItem> alerts,
  ) async {
    final target = await showDialog<String>(
      context: context,
      builder: (_) => _NotificationPanel(alerts: alerts),
    );
    if (target != null) onNavigate(target);
  }
}

class _NotificationPanel extends StatelessWidget {
  final List<StockAlertItem> alerts;

  const _NotificationPanel({required this.alerts});

  static const _inventoryPage = WorkspacePageIds.inventory;
  static const _restockPage = WorkspacePageIds.restock;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text('通知', style: Aurora.title(context)),
                  const SizedBox(width: 8),
                  if (alerts.isNotEmpty)
                    Text(
                      '${alerts.length} 条库存预警',
                      style: Aurora.label(context),
                    ),
                  const Spacer(),
                  BambuGlyphButton(
                    icon: 'cross',
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (alerts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 36),
                  child: Column(
                    children: [
                      BambuIcon(
                        name: 'completed',
                        size: 34,
                        color: Aurora.muted,
                        applyColorFilter: true,
                      ),
                      const SizedBox(height: 10),
                      Text('库存充足，暂无预警', style: Aurora.label(context)),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: alerts.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: Aurora.line),
                    itemBuilder: (context, i) {
                      final a = alerts[i];
                      final critical = a.level == StockLevel.critical;
                      final color = critical ? Aurora.danger : Aurora.warning;
                      final name = [
                        a.manufacturer,
                        a.materialType,
                        if (a.colorName != null && a.colorName!.isNotEmpty)
                          a.colorName,
                      ].where((e) => e != null && e.isNotEmpty).join(' · ');
                      final days = a.estimatedDaysLeft;
                      final subtitle = StringBuffer()
                        ..write(
                          '剩余 ${a.totalRemainingGrams.toStringAsFixed(0)} g',
                        )
                        ..write(' · ${a.rollCount} 卷');
                      if (days == 0) {
                        subtitle.write(' · 已耗尽');
                      } else if (days > 0) {
                        subtitle.write(' · 预计可用 $days 天');
                      }
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        leading: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(Aurora.radius),
                          ),
                          child: Center(
                            child: BambuIcon(
                              name: critical ? 'error' : 'warning',
                              size: 18,
                              color: color,
                              applyColorFilter: true,
                            ),
                          ),
                        ),
                        title: Text(
                          name.isEmpty ? '未命名耗材' : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          subtitle.toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: Aurora.textSoft,
                          ),
                        ),
                        trailing: Text(
                          critical ? '紧急' : '偏低',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: color,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(_inventoryPage),
                      );
                    },
                  ),
                ),
              if (alerts.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            Navigator.of(context).pop(_inventoryPage),
                        child: const Text('查看库存'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () =>
                            Navigator.of(context).pop(_restockPage),
                        child: const Text('去采购清单'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HelpEntry {
  final String category;
  final String title;
  final String answer;
  final String keywords;
  final String? targetPage;

  const _HelpEntry({
    required this.category,
    required this.title,
    required this.answer,
    required this.keywords,
    this.targetPage,
  });

  bool matches(String query) {
    if (query.isEmpty) return true;
    final text = '$category$title$answer$keywords'.toLowerCase();
    return query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .every(text.contains);
  }
}

const _helpEntries = <_HelpEntry>[
  _HelpEntry(
    category: '快速开始',
    title: '如何添加耗材并调整卷数？',
    answer: '进入“库存”，点击“新增耗材”。卡片底部的减号和加号可按整卷调整库存，点击卡片可编辑详细信息。',
    keywords: '库存 新增 耗材 卷数 加减 编辑',
    targetPage: '库存',
  ),
  _HelpEntry(
    category: '账号与云设备',
    title: '如何添加或切换拓竹账号？',
    answer: '点击顶部账号入口后选择“管理账号”，再点“添加账号”。完成密码和验证码登录后，可从同一入口快速切换。',
    keywords: '登录 添加账号 验证码 切换 多账号',
    targetPage: '设置',
  ),
  _HelpEntry(
    category: '账号与云设备',
    title: '为什么账号显示即将过期？',
    answer: '软件采用服务端返回的真实有效期，并在失效时用 Windows 加密保存的凭据自动续登。若服务端再次要求验证码，会提示手动验证。',
    keywords: '六天 6天 过期 永久 token 会话 自动登录',
    targetPage: '设置',
  ),
  _HelpEntry(
    category: '账号与云设备',
    title: '刷新云设备后看不到变化怎么办？',
    answer: '确认账号已登录且设备已绑定到该账号，再点击顶部刷新按钮。刷新结果会提示设备数量、无变化或失败账号。',
    keywords: '刷新 云设备 没反应 打印机 绑定',
    targetPage: '打印机',
  ),
  _HelpEntry(
    category: '打印机连接',
    title: '云连接和局域网连接有什么区别？',
    answer:
        '云连接通过拓竹账号和远程 P2P 访问；局域网连接通过 IP 与 Access Code 直连。两种模式相互独立，软件不会在断线时自动切换，需从对应入口明确选择。',
    keywords: 'LAN 局域网 云连接 远程 延迟',
    targetPage: '打印机',
  ),
  _HelpEntry(
    category: '切片软件',
    title: '如何启动拓竹切片软件？',
    answer: '点击顶部最右侧的启动按钮。若未找到安装路径，请在设置中检查切片软件路径或重新检测。',
    keywords: 'Bambu Studio 拓竹切片 启动 路径',
    targetPage: '设置',
  ),
  _HelpEntry(
    category: '打印记录',
    title: '为什么打印记录没有自动出现？',
    answer: '先检查打印机连接状态和诊断中心；云连接需要有效登录，局域网连接需要正确的序列号与访问码。',
    keywords: '打印历史 记录 没有 同步 任务',
    targetPage: '诊断中心',
  ),
  _HelpEntry(
    category: '库存计算',
    title: '卡片上的进度线表示什么？',
    answer: '进度线表示当前剩余克数占该耗材总克数的比例；颜色会随库存水平变化，不是连接状态。',
    keywords: '绿线 进度条 剩余克数 比例',
    targetPage: '库存',
  ),
  _HelpEntry(
    category: '成本与采购',
    title: '如何查看耗材成本和低库存提醒？',
    answer: '在“耗材成本”维护单价，在“采购清单”查看低库存项目；顶部通知也会汇总库存预警。',
    keywords: '成本 单价 低库存 采购 预警',
    targetPage: '耗材成本',
  ),
  _HelpEntry(
    category: '外观设置',
    title: '如何切换主题色或深色模式？',
    answer: '进入“设置”的外观区域选择主题模式和主题色，修改后会立即应用到全部界面。',
    keywords: '主题 粉色 绿色 深色 外观',
    targetPage: '设置',
  ),
  _HelpEntry(
    category: '故障排查',
    title: '软件出现异常时先检查哪里？',
    answer: '打开“诊断中心”查看数据库、监听目录、切片软件和打印机连接状态，并按失败项给出的说明处理。',
    keywords: '故障 问题 错误 检查 日志 诊断',
    targetPage: '诊断中心',
  ),
  _HelpEntry(
    category: '数据安全',
    title: '账号密码和本地数据如何保存？',
    answer: 'Windows 下账号凭据由 DPAPI 按当前系统用户加密；业务数据保存在本地数据库，建议定期使用备份功能。',
    keywords: '安全 密码 DPAPI 数据库 备份 隐私',
    targetPage: '设置',
  ),
];

class _HelpSearchDialog extends ConsumerStatefulWidget {
  final List<_NavSpec> items;

  const _HelpSearchDialog({required this.items});

  @override
  ConsumerState<_HelpSearchDialog> createState() => _HelpSearchDialogState();
}

class _HelpSearchDialogState extends ConsumerState<_HelpSearchDialog> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _helpEntries.where((entry) => entry.matches(_query)).toList();
    final navMatches = widget.items
        .where(
          (item) =>
              _query.isNotEmpty &&
              '${item.label} ${item.group}'.toLowerCase().contains(
                _query.toLowerCase(),
              ),
        )
        .toList(growable: false);
    final knowledge = ref.watch(printerFaultServiceProvider).asData?.value;
    final faults = knowledge == null
        ? const <FaultKnowledgeEntry>[]
        : _query.isEmpty
        ? knowledge.allEntries
        : knowledge.search(_query);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Text('功能说明与问题解决库', style: Aurora.title(context)),
                  const Spacer(),
                  BambuGlyphButton(
                    icon: 'cross',
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _controller,
                autofocus: true,
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: InputDecoration(
                  hintText: '搜索功能、现象或解决方法',
                  prefixIcon: Padding(
                    padding: const EdgeInsets.all(12),
                    child: BambuIcon(
                      name: 'search',
                      size: 17,
                      color: Aurora.textSoft,
                      applyColorFilter: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: shown.isEmpty && faults.isEmpty && navMatches.isEmpty
                    ? Center(
                        child: Text('没有找到相关说明', style: Aurora.label(context)),
                      )
                    : ListView.separated(
                        itemCount:
                            navMatches.length + shown.length + faults.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: Aurora.line),
                        itemBuilder: (context, index) {
                          if (index < navMatches.length) {
                            final item = navMatches[index];
                            final target = widget.items.indexOf(item);
                            return ListTile(
                              leading: BambuIcon(
                                name: item.icon,
                                size: 20,
                                color: Aurora.primary,
                                applyColorFilter: true,
                              ),
                              title: Text(item.label),
                              subtitle: Text('打开${item.group}'),
                              onTap: () => Navigator.of(context).pop(target),
                            );
                          }
                          final contentIndex = index - navMatches.length;
                          if (contentIndex >= shown.length) {
                            final fault = faults[contentIndex - shown.length];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 5,
                              ),
                              leading: Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: Aurora.danger.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(
                                    Aurora.radius,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.build_outlined,
                                  size: 18,
                                  color: Aurora.danger,
                                ),
                              ),
                              title: Text(
                                fault.code.isEmpty
                                    ? fault.title
                                    : '${fault.title} · ${fault.code}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '打印机故障 · ${fault.summary}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    height: 1.45,
                                    color: Aurora.textSoft,
                                  ),
                                ),
                              ),
                              trailing: const Icon(
                                Icons.arrow_forward_rounded,
                                size: 16,
                              ),
                              onTap: () => _showFaultDetails(fault),
                            );
                          }
                          final entry = shown[index];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 5,
                            ),
                            leading: Container(
                              width: 36,
                              height: 36,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Aurora.primary.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(
                                  Aurora.radius,
                                ),
                              ),
                              child: BambuIcon(
                                name: 'help',
                                size: 18,
                                color: Aurora.primary,
                                applyColorFilter: true,
                              ),
                            ),
                            title: Text(
                              entry.title,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${entry.category} · ${entry.answer}',
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.45,
                                  color: Aurora.textSoft,
                                ),
                              ),
                            ),
                            trailing: entry.targetPage == null
                                ? null
                                : const Icon(
                                    Icons.arrow_forward_rounded,
                                    size: 16,
                                  ),
                            onTap: entry.targetPage == null
                                ? null
                                : () {
                                    final target = widget.items.indexWhere(
                                      (item) => item.label == entry.targetPage,
                                    );
                                    if (target >= 0) {
                                      Navigator.of(context).pop(target);
                                    }
                                  },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showFaultDetails(FaultKnowledgeEntry fault) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(fault.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (fault.code.isNotEmpty) ...[
                  SelectableText(
                    '错误码：${fault.code}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                ],
                Text(fault.summary),
                const SizedBox(height: 14),
                for (var i = 0; i < fault.steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('${i + 1}. ${fault.steps[i]}'),
                  ),
                if (fault.resumeCondition.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('恢复条件：${fault.resumeCondition}'),
                ],
                if (fault.safetyNotice.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    '安全提示：${fault.safetyNotice}',
                    style: const TextStyle(
                      color: Aurora.danger,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
