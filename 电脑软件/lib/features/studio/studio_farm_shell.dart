import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_variant.dart';
import '../../core/services/printer_fleet_connection_manager.dart';
import '../../core/services/studio_video_relay_service.dart';
import '../../data/models/app_auth.dart';
import '../../data/prefs/app_prefs.dart';
import '../../data/external/community/studio_api_client.dart';
import '../../providers/app_auth_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/studio_provider.dart';
import '../../ui/workspace_navigation.dart';
import 'farm_ui/farm_account_flows.dart';
import 'farm_ui/farm_design.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_ui/farm_shell_chrome.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_lan_bulk_import_dialog.dart';
import 'farm_continuous_print_screen.dart';
import 'farm_auto_eject_gcode_screen.dart';
import 'farm_order_dispatch_screen.dart';
import 'farm_slicing_preset_screen.dart';
import 'studio_operations_screens.dart';
import 'studio_audit_log_screen.dart';
import 'studio_screens.dart';
import 'farm_printer_materials_screen.dart';
import 'farm_settings_screen.dart';

final farmOrganizationAccessProfileProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) {
      return ref.read(studioCloudServiceProvider).getFarmOrganizationProfile();
    });

final farmStaffWorkspaceAccessProvider = FutureProvider.autoDispose<void>((
  ref,
) {
  return ref.read(studioCloudServiceProvider).sync();
});

class StudioFarmWorkspace extends StatelessWidget {
  const StudioFarmWorkspace({super.key});

  @override
  Widget build(BuildContext context) {
    return const FarmThemeScope(
      child: FarmShellBackground(child: _StudioFarmWorkspaceBody()),
    );
  }
}

class _StudioFarmWorkspaceBody extends ConsumerStatefulWidget {
  const _StudioFarmWorkspaceBody();

  @override
  ConsumerState<_StudioFarmWorkspaceBody> createState() =>
      _StudioFarmWorkspaceState();
}

class _StudioFarmWorkspaceState
    extends ConsumerState<_StudioFarmWorkspaceBody> {
  String _selectedId = WorkspacePageIds.studioOverview;
  final Set<String> _built = {WorkspacePageIds.studioOverview};
  PrinterFleetConnectionManager? _fleetManager;
  bool _monitoringStarted = false;
  bool _guestMode = false;
  // The farm opens as a clean canvas with a narrow tool rail. Labels remain
  // available through tooltips and the rail can be expanded when needed.
  bool _sidebarCollapsed = true;

  static const _items = <_FarmNavItem>[
    _FarmNavItem(
      id: WorkspacePageIds.studioOverview,
      label: '总控台',
      icon: FarmIcons.overview,
      group: '生产',
      page: StudioFarmOverviewScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioProduction,
      label: '生产调度',
      icon: FarmIcons.production,
      group: '生产',
      page: FarmOrderDispatchScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioContinuousPrint,
      label: '批量生产',
      icon: FarmIcons.batchProduction,
      group: '生产',
      page: FarmContinuousPrintScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioMaterials,
      label: '设备与耗材',
      icon: FarmIcons.devices,
      group: '设备与材料',
      page: FarmPrinterMaterialsScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioInventory,
      label: '批量库存',
      icon: FarmIcons.inventory,
      group: '设备与材料',
      page: StudioBatchInventoryScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioAutoEjectGcode,
      label: '自动取件',
      icon: FarmIcons.autoEject,
      group: '工艺',
      page: FarmAutoEjectGcodeScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioSlicingPresets,
      label: '切片参数',
      icon: FarmIcons.slicing,
      group: '工艺',
      page: FarmSlicingPresetScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioOrders,
      label: '项目订单',
      icon: FarmIcons.orders,
      group: '业务',
      page: StudioProjectOrdersScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioCustomers,
      label: '客户门户',
      icon: FarmIcons.customers,
      group: '业务',
      page: StudioCustomerPortalScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioFinance,
      label: '报价利润',
      icon: FarmIcons.finance,
      group: '业务',
      page: StudioFinanceScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioTeam,
      label: '成员管理',
      icon: FarmIcons.members,
      group: '管理',
      page: StudioTeamOperationsScreen(),
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioAudit,
      label: '操作记录',
      icon: FarmIcons.audit,
      group: '管理',
      page: StudioAuditLogScreen(),
      adminOnly: true,
    ),
    _FarmNavItem(
      id: WorkspacePageIds.studioSettings,
      label: '农场设置',
      icon: FarmIcons.settings,
      group: '管理',
      page: FarmSettingsScreen(),
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = ref.read(appAuthProvider);
      if (auth.isSignedIn && auth.session?.mustChangePassword != true) {
        _startBackgroundMonitoring();
      }
    });
  }

  @override
  void dispose() {
    if (_monitoringStarted) {
      unawaited(_fleetManager?.stopBackgroundMonitoring());
    }
    super.dispose();
  }

  void _startBackgroundMonitoring() {
    _fleetManager ??= ref.read(printerFleetConnectionManagerProvider.notifier);
    final manager = _fleetManager!;
    _monitoringStarted = true;
    unawaited(manager.monitorAllConfigured());
  }

  void _stopBackgroundMonitoring() {
    if (!_monitoringStarted) return;
    _monitoringStarted = false;
    unawaited(_fleetManager?.stopBackgroundMonitoring());
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(appAuthProvider);
    ref.listen<AppAuthSession?>(
      appAuthProvider.select((state) => state.session),
      (previous, next) {
        if (previous != null && next == null) {
          _stopBackgroundMonitoring();
        }
        if (next != null &&
            previous?.accessToken != next.accessToken &&
            !next.mustChangePassword) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _startBackgroundMonitoring();
          });
        }
      },
    );
    if (auth.status == AppAuthStatus.initializing) {
      return const _FarmLoadingGate();
    }
    if (!auth.isSignedIn && !_guestMode) {
      return _FarmAccountGateway(
        onContinueAsGuest: () {
          setState(() => _guestMode = true);
        },
      );
    }
    if (!auth.isSignedIn) {
      return _FarmGuestWorkspace(
        onBackToAccountGateway: () {
          _stopBackgroundMonitoring();
          setState(() => _guestMode = false);
        },
      );
    }
    if (auth.session?.authRealm != 'farm_staff' &&
        auth.user?.emailVerified != true) {
      return const _FarmEmailVerificationGate();
    }
    if (auth.session?.authRealm == 'farm_staff' &&
        auth.session?.mustChangePassword == true) {
      return const _FarmPasswordChangeGate();
    }
    final isStaff = auth.session?.authRealm == 'farm_staff';
    AsyncValue<Map<String, dynamic>> profile = const AsyncData(
      <String, dynamic>{},
    );
    if (isStaff) {
      final access = ref.watch(farmStaffWorkspaceAccessProvider);
      if (access.isLoading) return const _FarmLoadingGate();
      if (access.hasError) {
        return _FarmAccessErrorGate(
          error: access.error ?? StateError('农场数据连接失败'),
          isStaff: true,
        );
      }
    } else {
      profile = ref.watch(farmOrganizationAccessProfileProvider);
      if (profile.isLoading) return const _FarmLoadingGate();
      if (profile.hasError) {
        return _FarmAccessErrorGate(
          error: profile.error ?? StateError('农场账号读取失败'),
          isStaff: false,
        );
      }
    }
    final items = _itemsForSession(auth.session);
    final snapshot = ref.watch(studioSnapshotProvider).valueOrNull;
    final sync = ref.watch(studioSyncControllerProvider);
    final videoRelay = ref.watch(studioVideoRelayControllerProvider);
    final selectedIndex = items.indexWhere((item) => item.id == _selectedId);
    final index = selectedIndex < 0 ? 0 : selectedIndex;
    ref.listen<String?>(workspaceNavigationRequestProvider, (_, next) {
      if (next == null) return;
      final mapped = switch (next) {
        WorkspacePageIds.dashboard => WorkspacePageIds.studioOverview,
        WorkspacePageIds.printers => WorkspacePageIds.studioMaterials,
        WorkspacePageIds.inventory => WorkspacePageIds.studioInventory,
        _ => next,
      };
      final target = items.indexWhere((item) => item.id == mapped);
      if (target >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _selectItem(items[target]);
        });
      }
      ref.read(workspaceNavigationRequestProvider.notifier).state = null;
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final forceCompact = constraints.maxWidth < 1040;
        final collapsed = forceCompact || _sidebarCollapsed;
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Row(
            children: [
              _FarmSidebar(
                items: items,
                selectedIndex: index,
                collapsed: collapsed,
                onSelect: _selectItem,
                onToggle: forceCompact
                    ? null
                    : () => setState(
                        () => _sidebarCollapsed = !_sidebarCollapsed,
                      ),
                onReturnToPersonal: isStaff || AppVariant.isFarm
                    ? null
                    : () => ref
                          .read(studioModeEnabledProvider.notifier)
                          .setEnabled(false),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                  child: Column(
                    children: [
                      FarmShellChrome(
                        padding: EdgeInsets.zero,
                        child: _FarmTopBar(
                          farmName: snapshot?.workspace.name ?? '打印农场',
                          pageLabel: items[index].label,
                          sync: sync,
                          signedIn: auth.isSignedIn,
                          onSync: sync.isSyncing
                              ? null
                              : () => ref
                                    .read(
                                      studioSyncControllerProvider.notifier,
                                    )
                                    .requestNow(),
                          activeStreams: videoRelay.activeStreams,
                          accountMenu: _FarmAccountMenu(
                            session: auth.session!,
                            user: auth.user!,
                            profile: profile.valueOrNull,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _FarmTelemetryStrip(
                        signedIn: auth.isSignedIn,
                        syncing: sync.isSyncing,
                        activeStreams: videoRelay.activeStreams,
                        mode: isStaff ? '成员生产' : '管理员生产',
                      ),
                      if (_shouldShowVerificationBanner(auth.session, profile))
                        _FarmVerificationBanner(
                          status: _profileStatus(profile.valueOrNull),
                        ),
                      const SizedBox(height: 8),
                      Expanded(
                        // Keep the selected farm page painted independently of
                        // desktop window visibility. A route-wide opacity tween
                        // can be paused at zero while the window is occluded,
                        // leaving a functional farm shell with a blank body.
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            FarmPalette.radius,
                          ),
                          child: IndexedStack(
                            index: index,
                            children: [
                              for (final item in items)
                                _built.contains(item.id) ||
                                        item.id == items[index].id
                                    ? item.page
                                    : const SizedBox.shrink(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _selectItem(_FarmNavItem item) {
    if (item.id == _selectedId) return;
    setState(() {
      _selectedId = item.id;
      _built
        ..removeWhere(
          (id) => id != WorkspacePageIds.studioOverview && id != item.id,
        )
        ..add(item.id);
    });
  }
}

class _FarmSidebar extends StatelessWidget {
  const _FarmSidebar({
    required this.items,
    required this.selectedIndex,
    required this.collapsed,
    required this.onSelect,
    required this.onToggle,
    this.onReturnToPersonal,
  });

  final List<_FarmNavItem> items;
  final int selectedIndex;
  final bool collapsed;
  final ValueChanged<_FarmNavItem> onSelect;
  final VoidCallback? onToggle;
  final VoidCallback? onReturnToPersonal;

  @override
  Widget build(BuildContext context) => _FarmNavigationPanel(
    collapsed: collapsed,
    onToggle: onToggle,
    onReturnToPersonal: onReturnToPersonal,
    entries: [
      for (var i = 0; i < items.length; i++)
        _FarmNavigationEntry(
          label: items[i].label,
          icon: items[i].icon,
          group: items[i].group,
          selected: i == selectedIndex,
          onTap: () => onSelect(items[i]),
        ),
    ],
  );
}

class _FarmNavigationEntry {
  const _FarmNavigationEntry({
    required this.label,
    required this.icon,
    required this.group,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final String group;
  final bool selected;
  final VoidCallback onTap;
}

class _FarmNavigationPanel extends StatelessWidget {
  const _FarmNavigationPanel({
    required this.entries,
    required this.collapsed,
    required this.onToggle,
    this.onReturnToPersonal,
  });

  final List<_FarmNavigationEntry> entries;
  final bool collapsed;
  final VoidCallback? onToggle;
  final VoidCallback? onReturnToPersonal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: collapsed
          ? FarmPalette.sidebarCollapsedWidth
          : FarmPalette.sidebarWidth,
      padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
      child: FarmShellChrome(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Follow the actual animated width so labels never overflow while
            // expanding or collapsing the navigation.
            final compact = constraints.maxWidth < 170;
            return Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 0 : 6,
                    4,
                    compact ? 0 : 6,
                    18,
                  ),
                  child: Row(
                    mainAxisAlignment: compact
                        ? MainAxisAlignment.center
                        : MainAxisAlignment.start,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.14),
                          ),
                        ),
                        child: Icon(
                          FarmIcons.farm,
                          size: 21,
                          color: scheme.primary,
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Sohun Farm',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text('生产工作台', style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (var i = 0; i < entries.length; i++) ...[
                        if (i == 0 || entries[i - 1].group != entries[i].group)
                          compact
                              ? Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    8,
                                    i == 0 ? 0 : 8,
                                    8,
                                    8,
                                  ),
                                  child: Divider(
                                    height: 1,
                                    color: scheme.outlineVariant,
                                  ),
                                )
                              : Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    10,
                                    i == 0 ? 0 : 14,
                                    10,
                                    8,
                                  ),
                                  child: Text(
                                    entries[i].group,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                        _FarmSidebarNavTile(
                          label: entries[i].label,
                          icon: entries[i].icon,
                          selected: entries[i].selected,
                          collapsed: compact,
                          locked: false,
                          onTap: entries[i].onTap,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Divider(height: 1, color: scheme.outlineVariant),
                const SizedBox(height: 8),
                if (compact) ...[
                  if (onReturnToPersonal != null)
                    FarmIconButton(
                      icon: Icons.arrow_back_outlined,
                      tooltip: '返回个人工作台',
                      onPressed: onReturnToPersonal,
                    ),
                  FarmIconButton(
                    icon: Icons.keyboard_double_arrow_right_rounded,
                    tooltip: onToggle == null ? '窗口较窄' : '展开侧边栏',
                    onPressed: onToggle,
                  ),
                ] else
                  Row(
                    children: [
                      if (onReturnToPersonal != null)
                        Expanded(
                          child: TextButton.icon(
                            onPressed: onReturnToPersonal,
                            icon: const Icon(
                              Icons.arrow_back_outlined,
                              size: 16,
                            ),
                            label: const Text('个人工作台'),
                          ),
                        )
                      else
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(
                              '农场工作空间',
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                        ),
                      FarmIconButton(
                        icon: Icons.keyboard_double_arrow_left_rounded,
                        tooltip: '收起侧边栏',
                        onPressed: onToggle,
                      ),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FarmSidebarNavTile extends StatelessWidget {
  const _FarmSidebarNavTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.collapsed,
    required this.onTap,
    this.locked = false,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Tooltip(
        message: locked ? '$label（需要登录）' : label,
        child: Material(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(FarmPalette.radius),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(FarmPalette.radius),
            child: Container(
              height: 38,
              padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 10),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: selected ? scheme.primary : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: collapsed
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  Icon(icon, size: 19, color: foreground),
                  if (!collapsed) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? scheme.primary : scheme.onSurface,
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (locked)
                      Icon(Icons.lock_outline, size: 14, color: scheme.outline),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FarmTopBar extends StatelessWidget {
  const _FarmTopBar({
    required this.farmName,
    required this.pageLabel,
    required this.sync,
    required this.signedIn,
    required this.onSync,
    required this.activeStreams,
    required this.accountMenu,
  });

  final String farmName;
  final String pageLabel;
  final StudioSyncState sync;
  final bool signedIn;
  final VoidCallback? onSync;
  final int activeStreams;
  final Widget accountMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: FarmPalette.topBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
      color: Colors.transparent,
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    farmName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 17,
                  color: scheme.outline,
                ),
                const SizedBox(width: 9),
                Text(pageLabel, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          _SyncIndicator(sync: sync, signedIn: signedIn, onSync: onSync),
          if (activeStreams > 0) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: '仅转接正在打印且已关联客户订单的画面',
              child: StatusPill(
                label: '$activeStreams 路视频',
                color: FarmPalette.info,
              ),
            ),
          ],
          const SizedBox(width: 10),
          accountMenu,
        ],
      ),
    );
  }
}

class _FarmNavItem {
  const _FarmNavItem({
    required this.id,
    required this.label,
    required this.icon,
    required this.group,
    required this.page,
    this.adminOnly = false,
  });

  final String id;
  final String label;
  final IconData icon;
  final String group;
  final Widget page;
  final bool adminOnly;
}

class _FarmTelemetryStrip extends StatelessWidget {
  const _FarmTelemetryStrip({
    required this.signedIn,
    required this.syncing,
    required this.activeStreams,
    required this.mode,
  });

  final bool signedIn;
  final bool syncing;
  final int activeStreams;
  final String mode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.88),
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(FarmPalette.controlRadius),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _FarmTelemetryCell(
              icon: Icons.tune_rounded,
              label: '运行模式',
              value: mode,
              color: scheme.primary,
            ),
            const _FarmTelemetryDivider(),
            _FarmTelemetryCell(
              icon: Icons.cloud_done_outlined,
              label: '云端连接',
              value: signedIn ? '已认证' : '未登录',
              color: signedIn ? FarmPalette.success : FarmPalette.warning,
            ),
            const _FarmTelemetryDivider(),
            _FarmTelemetryCell(
              icon: syncing ? Icons.sync_rounded : Icons.sync_disabled_rounded,
              label: '数据同步',
              value: syncing ? '同步中' : signedIn ? '已就绪' : '仅本地',
              color: syncing ? FarmPalette.info : scheme.onSurfaceVariant,
            ),
            const _FarmTelemetryDivider(),
            _FarmTelemetryCell(
              icon: Icons.videocam_outlined,
              label: '实时画面',
              value: activeStreams == 0 ? '无活动' : '$activeStreams 路活动',
              color: activeStreams == 0
                  ? scheme.onSurfaceVariant
                  : FarmPalette.info,
            ),
          ],
        ),
      ),
    );
  }
}

class _FarmTelemetryCell extends StatelessWidget {
  const _FarmTelemetryCell({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 7),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _FarmTelemetryDivider extends StatelessWidget {
  const _FarmTelemetryDivider();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18),
    child: SizedBox(
      height: 20,
      child: VerticalDivider(
        width: 1,
        thickness: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    ),
  );
}

List<_FarmNavItem> _itemsForSession(AppAuthSession? session) {
  // 业务页面对管理员和成员一致；完整审计页只向管理员开放。
  if (session?.authRealm == 'farm_staff') {
    return _StudioFarmWorkspaceState._items
        .where((item) => !item.adminOnly)
        .toList(growable: false);
  }
  return _StudioFarmWorkspaceState._items;
}

class _FarmLoadingGate extends StatelessWidget {
  const _FarmLoadingGate();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _FarmAccountGateway extends ConsumerWidget {
  const _FarmAccountGateway({required this.onContinueAsGuest});

  final VoidCallback onContinueAsGuest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(appAuthProvider);
    return _FarmGateScaffold(
      icon: Icons.factory_outlined,
      title: '登录打印农场',
      description: '使用现有 sohun 软件账号开通或进入自己的打印农场；成员使用农场编号、成员账号和密码登录。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: auth.isBusy
                ? null
                : () => showFarmOwnerLoginFlow(context, ref),
            icon: const Icon(Icons.business_outlined),
            label: const Text('使用软件账号登录'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: auth.isBusy
                ? null
                : () => showAppAccountRegistrationFlow(context, ref),
            icon: const Icon(Icons.person_add_alt_outlined),
            label: const Text('注册软件账号'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: auth.isBusy
                ? null
                : () => showDirectFarmOwnerRegistrationFlow(context, ref),
            icon: const Icon(Icons.add_business_outlined),
            label: const Text('开通农场管理员账号'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: auth.isBusy
                ? null
                : () => showFarmStaffLoginFlow(context, ref),
            icon: const Icon(Icons.badge_outlined),
            label: const Text('农场成员登录'),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: auth.isBusy ? null : onContinueAsGuest,
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('以访客身份进入'),
          ),
          const SizedBox(height: 6),
          Text(
            '访客可扫描、批量添加并查看本机打印机；订单、库存、客户、财务、团队和云同步需要登录。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (auth.errorMessage case final message?) ...[
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (AppVariant.isPersonal) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => ref
                  .read(studioModeEnabledProvider.notifier)
                  .setEnabled(false),
              icon: const Icon(Icons.arrow_back_outlined),
              label: const Text('返回个人工作台'),
            ),
          ],
        ],
      ),
    );
  }
}

class _FarmGuestWorkspace extends ConsumerStatefulWidget {
  const _FarmGuestWorkspace({required this.onBackToAccountGateway});

  final VoidCallback onBackToAccountGateway;

  @override
  ConsumerState<_FarmGuestWorkspace> createState() =>
      _FarmGuestWorkspaceState();
}

class _FarmGuestWorkspaceState extends ConsumerState<_FarmGuestWorkspace> {
  String _selectedId = WorkspacePageIds.studioOverview;
  bool _sidebarCollapsed = false;

  static const _items = <_FarmGuestNavItem>[
    _FarmGuestNavItem(
      id: WorkspacePageIds.studioOverview,
      label: '访客总览',
      icon: FarmIcons.overview,
      group: '生产',
      available: true,
    ),
    _FarmGuestNavItem(
      id: WorkspacePageIds.studioProduction,
      label: '生产调度',
      icon: FarmIcons.production,
      group: '生产',
    ),
    _FarmGuestNavItem(
      id: WorkspacePageIds.studioMaterials,
      label: '设备与耗材',
      icon: FarmIcons.devices,
      group: '设备与材料',
      available: true,
    ),
    _FarmGuestNavItem(
      id: WorkspacePageIds.studioInventory,
      label: '批量库存',
      icon: FarmIcons.inventory,
      group: '设备与材料',
    ),
    _FarmGuestNavItem(
      id: WorkspacePageIds.studioOrders,
      label: '项目订单',
      icon: FarmIcons.orders,
      group: '业务',
    ),
    _FarmGuestNavItem(
      id: WorkspacePageIds.studioCustomers,
      label: '客户门户',
      icon: FarmIcons.customers,
      group: '业务',
    ),
    _FarmGuestNavItem(
      id: WorkspacePageIds.studioFinance,
      label: '报价利润',
      icon: FarmIcons.finance,
      group: '业务',
    ),
    _FarmGuestNavItem(
      id: WorkspacePageIds.studioTeam,
      label: '成员管理',
      icon: FarmIcons.members,
      group: '管理',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _items.where((item) => item.id == _selectedId).firstOrNull;
    final current = selected ?? _items.first;
    return LayoutBuilder(
      builder: (context, constraints) {
        final forceCompact = constraints.maxWidth < 1040;
        final collapsed = forceCompact || _sidebarCollapsed;
        return Scaffold(
          backgroundColor: scheme.surfaceContainerLowest,
          body: Row(
            children: [
              _FarmGuestSidebar(
                items: _items,
                selectedId: current.id,
                collapsed: collapsed,
                onSelect: (item) => setState(() => _selectedId = item.id),
                onSignIn: widget.onBackToAccountGateway,
                onReturnToPersonal: AppVariant.isPersonal
                    ? () => ref
                          .read(studioModeEnabledProvider.notifier)
                          .setEnabled(false)
                    : null,
                onToggle: forceCompact
                    ? null
                    : () => setState(
                        () => _sidebarCollapsed = !_sidebarCollapsed,
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                  child: Column(
                    children: [
                      FarmShellChrome(
                        padding: EdgeInsets.zero,
                        child: _FarmGuestTopBar(pageLabel: current.label),
                      ),
                      const SizedBox(height: 8),
                      const _FarmTelemetryStrip(
                        signedIn: false,
                        syncing: false,
                        activeStreams: 0,
                        mode: '访客设备',
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer.withValues(
                            alpha: 0.78,
                          ),
                          borderRadius: BorderRadius.circular(
                            FarmPalette.controlRadius,
                          ),
                          border: Border.all(
                            color: scheme.onSecondaryContainer.withValues(
                              alpha: 0.10,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 16,
                              color: scheme.onSecondaryContainer,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                '访客模式仅开放本机设备发现与查看；登录后可使用订单、库存、客户、财务、团队和云端生产数据。',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            FarmPalette.radius,
                          ),
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey(current.id),
                            tween: Tween(begin: 0, end: 1),
                            duration: const Duration(milliseconds: 160),
                            curve: Curves.easeOutCubic,
                            child: current.available
                                ? current.id == WorkspacePageIds.studioMaterials
                                      ? const FarmPrinterMaterialsScreen(
                                          allowGuestEnrollment: true,
                                        )
                                      : const _FarmGuestOverview()
                                : _FarmGuestLockedPage(
                                    featureName: current.label,
                                  ),
                            builder: (context, value, child) => Opacity(
                              opacity: value,
                              child: Transform.translate(
                                offset: Offset(8 * (1 - value), 0),
                                child: child,
                              ),
                            ),
                          ),
                        ),
                    ),
                  ],
                ),
              ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FarmGuestNavItem {
  const _FarmGuestNavItem({
    required this.id,
    required this.label,
    required this.icon,
    required this.group,
    this.available = false,
  });

  final String id;
  final String label;
  final IconData icon;
  final String group;
  final bool available;
}

class _FarmGuestSidebar extends StatelessWidget {
  const _FarmGuestSidebar({
    required this.items,
    required this.selectedId,
    required this.collapsed,
    required this.onSelect,
    required this.onSignIn,
    this.onReturnToPersonal,
    required this.onToggle,
  });

  final List<_FarmGuestNavItem> items;
  final String selectedId;
  final bool collapsed;
  final ValueChanged<_FarmGuestNavItem> onSelect;
  final VoidCallback onSignIn;
  final VoidCallback? onReturnToPersonal;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: collapsed
          ? FarmPalette.sidebarCollapsedWidth
          : FarmPalette.sidebarWidth,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: FarmPalette.topBarHeight,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: collapsed ? 12 : 14),
              child: Row(
                mainAxisAlignment: collapsed
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(FarmPalette.radius),
                    ),
                    child: Icon(
                      FarmIcons.farm,
                      size: 20,
                      color: scheme.primary,
                    ),
                  ),
                  if (!collapsed) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Sohun Farm',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.titleMedium?.copyWith(fontSize: 14),
                          ),
                          Text(
                            '访客工作台',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const StatusPill(label: '访客', color: FarmPalette.info),
                  ],
                ],
              ),
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              children: [
                for (
                  var itemIndex = 0;
                  itemIndex < items.length;
                  itemIndex++
                ) ...[
                  if (itemIndex == 0 ||
                      items[itemIndex - 1].group != items[itemIndex].group)
                    collapsed
                        ? Padding(
                            padding: EdgeInsets.only(
                              top: itemIndex == 0 ? 0 : 8,
                              bottom: 6,
                            ),
                            child: Divider(color: scheme.outlineVariant),
                          )
                        : Padding(
                            padding: EdgeInsets.fromLTRB(
                              10,
                              itemIndex == 0 ? 4 : 14,
                              10,
                              6,
                            ),
                            child: Text(
                              items[itemIndex].group,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 10,
                                  ),
                            ),
                          ),
                  _FarmSidebarNavTile(
                    label: items[itemIndex].label,
                    icon: items[itemIndex].icon,
                    selected: items[itemIndex].id == selectedId,
                    collapsed: collapsed,
                    locked: !items[itemIndex].available,
                    onTap: () => onSelect(items[itemIndex]),
                  ),
                ],
              ],
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(8),
            child: collapsed
                ? Column(
                    children: [
                      FarmIconButton(
                        icon: Icons.login_outlined,
                        tooltip: '登录或注册',
                        onPressed: onSignIn,
                      ),
                      const SizedBox(height: 4),
                      if (onReturnToPersonal != null) ...[
                        FarmIconButton(
                          icon: Icons.arrow_back_outlined,
                          tooltip: '返回个人工作台',
                          onPressed: onReturnToPersonal,
                        ),
                        const SizedBox(height: 4),
                      ],
                      FarmIconButton(
                        icon: Icons.keyboard_double_arrow_right_rounded,
                        tooltip: onToggle == null ? '窗口较窄' : '展开侧边栏',
                        onPressed: onToggle,
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        onPressed: onSignIn,
                        icon: const Icon(Icons.login_outlined, size: 17),
                        label: const Text('登录或注册'),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (onReturnToPersonal != null)
                            Expanded(
                              child: TextButton.icon(
                                onPressed: onReturnToPersonal,
                                icon: const Icon(
                                  Icons.arrow_back_outlined,
                                  size: 17,
                                ),
                                label: const Text('个人工作台'),
                              ),
                            )
                          else
                            const Spacer(),
                          if (onReturnToPersonal != null)
                            const SizedBox(width: 4),
                          FarmIconButton(
                            icon: Icons.keyboard_double_arrow_left_rounded,
                            tooltip: '收起侧边栏',
                            onPressed: onToggle,
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

enum _FarmGuestAccountAction { ownerLogin, staffLogin, registration }

class _FarmGuestTopBar extends ConsumerWidget {
  const _FarmGuestTopBar({required this.pageLabel});

  final String pageLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: FarmPalette.topBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: Colors.transparent,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          return Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Flexible(
                      child: Text(
                        '本机工作区',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 17,
                      color: scheme.outline,
                    ),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        pageLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const StatusPill(label: '仅本机', color: FarmPalette.info),
              const SizedBox(width: 8),
              if (compact)
                PopupMenuButton<_FarmGuestAccountAction>(
                  tooltip: '账户选项',
                  icon: const Icon(Icons.login_outlined, size: 19),
                  onSelected: (action) =>
                      _runGuestAccountAction(context, ref, action),
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _FarmGuestAccountAction.ownerLogin,
                      child: Text('软件账号登录'),
                    ),
                    PopupMenuItem(
                      value: _FarmGuestAccountAction.staffLogin,
                      child: Text('成员登录'),
                    ),
                    PopupMenuItem(
                      value: _FarmGuestAccountAction.registration,
                      child: Text('开通管理员账号'),
                    ),
                  ],
                )
              else ...[
                TextButton(
                  onPressed: () => showFarmOwnerLoginFlow(context, ref),
                  child: const Text('软件账号登录'),
                ),
                TextButton(
                  onPressed: () => showFarmStaffLoginFlow(context, ref),
                  child: const Text('成员登录'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () =>
                      showDirectFarmOwnerRegistrationFlow(context, ref),
                  icon: const Icon(Icons.add_business_outlined, size: 17),
                  label: const Text('开通管理员账号'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

Future<void> _runGuestAccountAction(
  BuildContext context,
  WidgetRef ref,
  _FarmGuestAccountAction action,
) => switch (action) {
  _FarmGuestAccountAction.ownerLogin => showFarmOwnerLoginFlow(context, ref),
  _FarmGuestAccountAction.staffLogin => showFarmStaffLoginFlow(context, ref),
  _FarmGuestAccountAction.registration => showDirectFarmOwnerRegistrationFlow(
    context,
    ref,
  ),
};

class _FarmGuestOverview extends ConsumerWidget {
  const _FarmGuestOverview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connections = ref.watch(printerConnectionListProvider);
    final localPrinters =
        ref.watch(printersWithChannelsProvider).valueOrNull ?? const [];
    final multicolorPrinters = localPrinters
        .where((item) => item.printer.channelCount > 1)
        .length;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        FarmPageHeader(
          title: '访客设备总览',
          subtitle: '无需农场账号即可发现并配置同一局域网中的拓竹打印机。',
          actions: [
            FilledButton.icon(
              onPressed: () => showFarmLanBulkImportDialog(context, ref),
              icon: const Icon(Icons.radar_outlined, size: 17),
              label: const Text('扫描并批量添加'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 800
                ? 3
                : constraints.maxWidth >= 500
                ? 2
                : 1;
            const gap = 10.0;
            final width =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            final metrics = [
              MetricTile(
                label: 'LAN 连接配置',
                value: '${connections.length}',
                unit: '台',
                icon: 'info',
                color: FarmPalette.info,
              ),
              MetricTile(
                label: '本机设备档案',
                value: '${localPrinters.length}',
                unit: '台',
                icon: 'printer',
                color: FarmPalette.primary,
              ),
              MetricTile(
                label: '多通道设备',
                value: '$multicolorPrinters',
                unit: '台',
                icon: 'filament',
                color: FarmPalette.warning,
              ),
            ];
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final metric in metrics)
                  SizedBox(width: width, child: metric),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, constraints) {
            const workflow = _FarmGuestInfoPanel(
              icon: Icons.router_outlined,
              title: '本地设备工作流',
              subtitle: '扫描结果仅保存在当前电脑，不会写入农场云端。',
              children: [
                _FarmGuestPermissionRow(allowed: true, label: '发现同一局域网内的可用打印机'),
                _FarmGuestPermissionRow(
                  allowed: true,
                  label: '核对序列号、Access Code、机型和喷嘴',
                ),
                _FarmGuestPermissionRow(
                  allowed: true,
                  label: '在设备与耗材页查看实时连接状态',
                ),
              ],
            );
            const permissions = _FarmGuestInfoPanel(
              icon: Icons.shield_outlined,
              title: '访客权限边界',
              subtitle: '业务数据和成员数据必须在身份验证后访问。',
              children: [
                _FarmGuestPermissionRow(
                  allowed: true,
                  label: '扫描、批量添加和查看本机打印机',
                ),
                _FarmGuestPermissionRow(
                  allowed: true,
                  label: '建立本机 LAN 连接并查看实时设备状态',
                ),
                _FarmGuestPermissionRow(
                  allowed: false,
                  label: '订单、生产调度、库存、客户和利润',
                ),
                _FarmGuestPermissionRow(allowed: false, label: '成员账号、操作记录和云同步'),
              ],
            );
            if (constraints.maxWidth < 760) {
              return const Column(
                children: [workflow, SizedBox(height: 10), permissions],
              );
            }
            return const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: workflow),
                SizedBox(width: 10),
                Expanded(child: permissions),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _FarmGuestInfoPanel extends StatelessWidget {
  const _FarmGuestInfoPanel({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FrostPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(FarmPalette.radius),
                ),
                child: Icon(icon, size: 19, color: scheme.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 5),
          ...children,
        ],
      ),
    );
  }
}

class _FarmGuestPermissionRow extends StatelessWidget {
  const _FarmGuestPermissionRow({required this.allowed, required this.label});

  final bool allowed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            allowed ? Icons.check_circle_outline : Icons.lock_outline,
            size: 18,
            color: allowed
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: 9),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _FarmGuestLockedPage extends ConsumerWidget {
  const _FarmGuestLockedPage({required this.featureName});

  final String featureName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 42),
                const SizedBox(height: 14),
                Text(
                  '$featureName 需要农场账号',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text(
                  '这里包含农场业务或成员数据。访客模式不会读取这些内容；请使用已开通农场的软件管理员账号或成员账号登录。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton(
                      onPressed: () => showFarmOwnerLoginFlow(context, ref),
                      child: const Text('软件账号登录'),
                    ),
                    OutlinedButton(
                      onPressed: () => showFarmStaffLoginFlow(context, ref),
                      child: const Text('成员登录'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          showDirectFarmOwnerRegistrationFlow(context, ref),
                      child: const Text('开通管理员账号'),
                    ),
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

class _FarmEmailVerificationGate extends ConsumerWidget {
  const _FarmEmailVerificationGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(appAuthProvider);
    return _FarmGateScaffold(
      icon: Icons.mark_email_unread_outlined,
      title: '先验证管理员邮箱',
      description:
          '验证完成后才能进入生产数据、成员管理和农场入驻资料。当前邮箱：${auth.user?.email ?? '未读取'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: auth.isBusy
                ? null
                : () => showFarmEmailVerificationFlow(context, ref),
            icon: const Icon(Icons.verified_outlined),
            label: const Text('验证邮箱'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: auth.isBusy
                ? null
                : () => showFarmAccountLogoutFlow(context, ref),
            icon: const Icon(Icons.switch_account_outlined),
            label: const Text('退出并切换账号'),
          ),
          if (AppVariant.isPersonal) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => ref
                  .read(studioModeEnabledProvider.notifier)
                  .setEnabled(false),
              icon: const Icon(Icons.arrow_back_outlined),
              label: const Text('返回个人工作台'),
            ),
          ],
        ],
      ),
    );
  }
}

class _FarmPasswordChangeGate extends ConsumerWidget {
  const _FarmPasswordChangeGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(appAuthProvider);
    final session = auth.session;
    return _FarmGateScaffold(
      icon: Icons.password_outlined,
      title: '修改成员初始密码',
      description:
          '${session?.farmOrganizationName ?? '打印农场'} · ${session?.farmStaffLoginName ?? '成员账号'}\n首次登录必须更换管理员分配的初始密码，完成后才能读取生产数据。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: auth.isBusy
                ? null
                : () => showFarmStaffPasswordChangeFlow(context, ref),
            icon: const Icon(Icons.lock_reset_outlined),
            label: const Text('修改初始密码'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: auth.isBusy
                ? null
                : () => showFarmAccountLogoutFlow(context, ref),
            icon: const Icon(Icons.switch_account_outlined),
            label: const Text('退出并切换账号'),
          ),
        ],
      ),
    );
  }
}

class _FarmAccessErrorGate extends ConsumerWidget {
  const _FarmAccessErrorGate({required this.error, required this.isStaff});

  final Object error;
  final bool isStaff;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notRegistered =
        error is StudioCloudException &&
        (error as StudioCloudException).code == 'farm_workspace_not_registered';
    return _FarmGateScaffold(
      icon: notRegistered
          ? Icons.add_business_outlined
          : Icons.cloud_off_outlined,
      title: notRegistered ? '此账号尚未开通打印农场' : '暂时无法读取农场账号',
      description: notRegistered
          ? '当前登录的是普通 sohun 软件账号。使用同一个账号开通并填写农场资料后，即可成为管理员；无需重新注册账号。'
          : '没有读取任何本地农场业务数据。请检查网络后重试，或切换到正确的农场账号。\n$error',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (notRegistered && !isStaff)
            FilledButton.icon(
              onPressed: () async {
                try {
                  await ref
                      .read(studioCloudServiceProvider)
                      .registerFarmOrganization();
                  ref.invalidate(farmOrganizationAccessProfileProvider);
                  if (context.mounted) {
                    showSnack(context, '申请已创建，请继续填写农场主体资料');
                    await showFarmOnboardingFlow(context, ref);
                  }
                } catch (activateError) {
                  if (context.mounted) {
                    showSnack(context, '开通打印农场失败：$activateError', error: true);
                  }
                }
              },
              icon: const Icon(Icons.add_business_outlined),
              label: const Text('开通管理员身份'),
            ),
          if (notRegistered && !isStaff) const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () {
              if (isStaff) {
                ref.invalidate(farmStaffWorkspaceAccessProvider);
              } else {
                ref.invalidate(farmOrganizationAccessProfileProvider);
              }
            },
            icon: const Icon(Icons.refresh_outlined),
            label: const Text('重新读取'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => showFarmAccountLogoutFlow(context, ref),
            icon: const Icon(Icons.switch_account_outlined),
            label: const Text('退出并切换账号'),
          ),
          const SizedBox(height: 8),
          if (!isStaff && AppVariant.isPersonal)
            TextButton.icon(
              onPressed: () => ref
                  .read(studioModeEnabledProvider.notifier)
                  .setEnabled(false),
              icon: const Icon(Icons.arrow_back_outlined),
              label: const Text('返回个人工作台'),
            ),
        ],
      ),
    );
  }
}

class _FarmGateScaffold extends StatelessWidget {
  const _FarmGateScaffold({
    required this.icon,
    required this.title,
    required this.description,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: FrostPanel(
              padding: EdgeInsets.zero,
              elevated: true,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 700;
                  final intro = Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(FarmPalette.radius),
                        bottomLeft: Radius.circular(wide ? FarmPalette.radius : 0),
                        topRight: Radius.circular(wide ? 0 : FarmPalette.radius),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(
                                  FarmPalette.controlRadius,
                                ),
                              ),
                              child: Icon(icon, color: scheme.onPrimary),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'SOHUN FARM',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    color: scheme.onPrimaryContainer,
                                    letterSpacing: 1.3,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        Text(
                          title,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          description,
                          style: TextStyle(
                            color: scheme.onPrimaryContainer,
                            height: 1.55,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _FarmGateSignal(
                          icon: Icons.hub_outlined,
                          label: '设备发现与状态',
                          value: 'LAN READY',
                        ),
                        const SizedBox(height: 8),
                        _FarmGateSignal(
                          icon: Icons.shield_outlined,
                          label: '业务数据访问',
                          value: 'ACCOUNT REQUIRED',
                        ),
                      ],
                    ),
                  );
                  final actions = Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '选择进入方式',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '管理员管理完整生产链，成员按权限参与排产。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 20),
                        child,
                      ],
                    ),
                  );
                  return wide
                      ? Row(
                          // The gate is hosted in a SingleChildScrollView, so
                          // its vertical constraints are unbounded. Stretching
                          // children here would pass an infinite height to the
                          // intro/actions panels and crash Flutter layout.
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: intro),
                            Expanded(child: actions),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [intro, actions],
                        );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FarmGateSignal extends StatelessWidget {
  const _FarmGateSignal({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 17, color: scheme.onPrimaryContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 12),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: scheme.primary,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}

class _FarmAccountMenu extends ConsumerWidget {
  const _FarmAccountMenu({
    required this.session,
    required this.user,
    required this.profile,
  });

  final AppAuthSession session;
  final AppUser user;
  final Map<String, dynamic>? profile;

  Future<void> _runAction(
    BuildContext context,
    WidgetRef ref,
    String value,
  ) async {
    switch (value) {
      case 'onboarding':
        await showFarmOnboardingFlow(context, ref);
        if (context.mounted) {
          ref.invalidate(farmOrganizationAccessProfileProvider);
        }
        break;
      case 'settings':
        ref.read(workspaceNavigationRequestProvider.notifier).state =
            WorkspacePageIds.studioSettings;
        break;
      case 'password':
        await showFarmStaffPasswordChangeFlow(context, ref);
        break;
      case 'logout':
        await showFarmAccountLogoutFlow(context, ref);
        break;
      case 'personal':
        await ref.read(studioModeEnabledProvider.notifier).setEnabled(false);
        break;
    }
  }

  Widget _menuItem({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return MenuItemButton(
      onPressed: onPressed,
      style: const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(280, 44)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isStaff = session.authRealm == 'farm_staff';
    final organization = _organization(profile);
    final farmName = isStaff
        ? session.farmOrganizationName ?? '打印农场'
        : organization['displayName']?.toString() ?? '打印农场';
    final secondary = isStaff
        ? [session.farmStaffLoginName ?? user.displayName, '成员'].join(' · ')
        : user.email;

    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        minimumSize: const WidgetStatePropertyAll(Size(280, 0)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        backgroundColor: WidgetStatePropertyAll(
          Theme.of(context).colorScheme.surfaceContainerHigh,
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(4),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      menuChildren: [
        SizedBox(
          width: 280,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  farmName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(
                  secondary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        if (!isStaff)
          _menuItem(
            icon: Icons.domain_verification_outlined,
            label: '完善入驻资料',
            onPressed: () => unawaited(_runAction(context, ref, 'onboarding')),
          ),
        if (!isStaff)
          _menuItem(
            icon: Icons.settings_outlined,
            label: '农场设置',
            onPressed: () => unawaited(_runAction(context, ref, 'settings')),
          ),
        if (isStaff)
          _menuItem(
            icon: Icons.password_outlined,
            label: '修改成员密码',
            onPressed: () => unawaited(_runAction(context, ref, 'password')),
          ),
        const Divider(height: 1),
        _menuItem(
          icon: Icons.switch_account_outlined,
          label: '退出并切换账号',
          onPressed: () => unawaited(_runAction(context, ref, 'logout')),
        ),
        if (!isStaff && AppVariant.isPersonal)
          _menuItem(
            icon: Icons.arrow_back_outlined,
            label: '返回个人工作台',
            onPressed: () => unawaited(_runAction(context, ref, 'personal')),
          ),
      ],
      builder: (context, controller, child) => Tooltip(
        message: '农场账号',
        child: InkWell(
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          borderRadius: BorderRadius.circular(6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.account_circle_outlined, size: 19),
                  const SizedBox(width: 7),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Text(
                      isStaff
                          ? session.farmStaffLoginName ?? user.displayName
                          : user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

bool _shouldShowVerificationBanner(
  AppAuthSession? session,
  AsyncValue<Map<String, dynamic>> profile,
) {
  if (session == null || session.authRealm == 'farm_staff') return false;
  final payload = profile.valueOrNull;
  return payload != null && _profileStatus(payload) != 'verified';
}

String _profileStatus(Map<String, dynamic>? profile) {
  return _organization(profile)['verificationStatus']?.toString() ?? 'draft';
}

Map<String, dynamic> _organization(Map<String, dynamic>? profile) {
  final raw = profile?['organization'];
  return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
}

class _FarmVerificationBanner extends ConsumerWidget {
  const _FarmVerificationBanner({required this.status});

  final String status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final message = switch (status) {
      'pending_submission' => '入驻资料有修改，请检查后重新提交审核。',
      'under_review' => '农场主体资料正在审核中，审核结果会保留在账号中。',
      'needs_information' => '审核需要补充资料，请完善后重新提交。',
      'rejected' => '本次入驻审核未通过，请核对资料后重新提交。',
      'suspended' => '农场主体当前已暂停，请核对账号和主体资料。',
      _ => '请完善负责人、经营主体、设备规模和服务范围后提交审核。',
    };
    return Material(
      color: status == 'under_review'
          ? scheme.secondaryContainer
          : scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
        child: Row(
          children: [
            Icon(
              status == 'under_review'
                  ? Icons.hourglass_top_outlined
                  : Icons.domain_verification_outlined,
              size: 18,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () async {
                await showFarmOnboardingFlow(context, ref);
                ref.invalidate(farmOrganizationAccessProfileProvider);
              },
              child: Text(status == 'under_review' ? '查看资料' : '完善资料'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncIndicator extends StatelessWidget {
  const _SyncIndicator({
    required this.sync,
    required this.signedIn,
    required this.onSync,
  });

  final StudioSyncState sync;
  final bool signedIn;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = !signedIn
        ? '仅本地'
        : sync.isSyncing
        ? '同步中'
        : sync.phase == StudioSyncPhase.error
        ? '同步异常'
        : '已同步';
    return TextButton.icon(
      onPressed: signedIn ? onSync : null,
      icon: sync.isSyncing
          ? const SizedBox.square(
              dimension: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              sync.phase == StudioSyncPhase.error
                  ? Icons.cloud_off_outlined
                  : Icons.cloud_done_outlined,
              size: 17,
              color: sync.phase == StudioSyncPhase.error
                  ? scheme.error
                  : scheme.primary,
            ),
      label: Text(label),
    );
  }
}
