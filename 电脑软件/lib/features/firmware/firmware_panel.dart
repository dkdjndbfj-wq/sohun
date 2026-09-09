import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/external/printer/bambu_cloud_models.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/app_progress.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import '../settings/cloud_login_dialog.dart';

/// 固件版本管理面板。
///
/// 展示已绑定打印机的固件版本信息（当前版本 / 最新版本 / 各模块版本），
/// 支持对当前活跃打印机发起一键 OTA 升级，并实时显示升级进度。
///
/// 数据来源（LAN-only 也能用）：
/// - 云端设备列表（bambuCloudProvider）：sw_ver / hw_ver / module_versions
/// - 本地 LAN 配置（mergedPrinterListProvider）：LAN 直连设备
/// - 活跃打印机 MQTT 状态（activePrinterConnectionProvider）：info.module / upgrade_ams
///
/// 本面板不创建独立连接或定时重连，只复用应用级活跃打印机连接状态。
/// 设备列表仅在启动加载或用户主动刷新时从云端更新；实际升级命令仍走现有 MQTT 连接。
///
/// LAN-only 模式下，设备列表来自 mergedPrinterListProvider（仅 LAN 配置），
/// 版本信息从 MQTT 实时状态读取；升级指令走 MQTT，不依赖云 API。
///
/// v4 视觉升级：设备卡 → GlassCard，升级按钮 → AppButton danger，
/// AMS 升级 → AppButton secondary，进度条 → AppProgress，状态徽章 → AppChip，
/// 全量暗色模式适配。
class FirmwarePanel extends ConsumerWidget {
  const FirmwarePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cloudState = ref.watch(bambuCloudProvider);
    final allCloud = ref.watch(allCloudDevicesProvider);
    final ownerMap = ref.watch(printerOwnerMapProvider);
    final mergedList = ref.watch(mergedPrinterListProvider);
    final activeSerial = ref.watch(activePrinterSerialProvider);
    final activeState = ref.watch(activePrinterConnectionProvider);
    // 暗色模式判定
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 统一设备视图：合并云设备 + LAN 配置，按 serial 去重
    // 云设备有完整 sw_ver/hw_ver/module_versions；LAN 设备版本从 MQTT 读
    final cloudDeviceBySerial = <String, BambuCloudDevice>{};
    for (final d in allCloud.devices) {
      cloudDeviceBySerial[d.devId] = d;
    }
    final devices = <_FirmwareDeviceSource>[];
    final seenSerials = <String>{};
    for (final cfg in mergedList) {
      if (cfg.serial.isEmpty || seenSerials.contains(cfg.serial)) continue;
      seenSerials.add(cfg.serial);
      final cloud = cloudDeviceBySerial[cfg.serial];
      devices.add(
        _FirmwareDeviceSource(
          serial: cfg.serial,
          cloudDevice: cloud,
          lanConfig: cfg,
          ownerAccount: ownerMap[cfg.serial],
        ),
      );
    }

    if (devices.isEmpty) {
      // 区分"无设备"和"拉取失败"
      if (allCloud.allFailed) {
        return EmptyState(
          bambuIconName: 'monitor_signal_no',
          useGlass: true,
          title: '设备列表拉取失败',
          subtitle: '所有账号均拉取失败，可能是网络问题或 token 过期。\n点击下方按钮重试，或前往账号管理检查登录状态。',
          actionLabel: '重新拉取',
          onAction: () => ref
              .read(allCloudDevicesProvider.notifier)
              .refresh(forceRefresh: true),
        );
      }
      return EmptyState(
        bambuIconName: 'monitor_upgrade_offline',
        useGlass: true,
        title: '暂无已绑定设备',
        subtitle: cloudState.isLoggedIn
            ? '请在拓竹 App 中将打印机绑定到账号，或在打印机设置中添加 LAN 直连'
            : '未登录云账号时，请在打印机页面手动添加 LAN 直连设备',
        actionLabel: cloudState.isLoggedIn ? null : '去登录云账号',
        onAction: cloudState.isLoggedIn
            ? null
            : () => CloudLoginDialog.show(context),
      );
    }

    // 部分账号拉取失败的提示横幅
    final hasPartialFailure =
        allCloud.failedAccounts.isNotEmpty && !allCloud.allFailed;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          // 部分账号拉取失败的提示横幅
          if (hasPartialFailure)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  0,
                ),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.warningContainer,
                    borderRadius: BorderRadius.circular(AppColors.radiusMd),
                  ),
                  child: Row(
                    children: [
                      const BambuIcon(
                        name: 'warning',
                        size: 16,
                        color: AppColors.warning,
                        applyColorFilter: true,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          '${allCloud.failedAccounts.length} 个账号设备拉取失败：'
                          '${allCloud.failedAccounts.values.join("、")}',
                          style: AppTypography.caption.copyWith(
                            fontSize: 11,
                            color: AppColors.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                ExperienceTokens.pageGutter,
                ExperienceTokens.pageGutter,
                ExperienceTokens.pageGutter,
                AppSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ExperiencePageHeader(
                    title: '固件星图',
                    description:
                        '从更新源出发，查看打印机与 AMS 模块的真实连接关系。版本与升级操作仍保留在下方设备明细中。',
                    actions: [
                      if (cloudState.isLoggedIn && cloudState.isLoading)
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      if (cloudState.isLoggedIn)
                        TextButton.icon(
                          onPressed: allCloud.isLoading
                              ? null
                              : () => ref
                                    .read(allCloudDevicesProvider.notifier)
                                    .refresh(forceRefresh: true),
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('刷新设备'),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _FirmwareTopologyStage(
                    devices: devices,
                    activeSerial: activeSerial,
                    activeStatus: activeState.status,
                    cloudMode: cloudState.isLoggedIn,
                    onSelectDevice: (serial) => unawaited(
                      ref
                          .read(activePrinterSerialProvider.notifier)
                          .set(serial),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  ExperienceSectionHeading(
                    title: '设备版本明细',
                    trailing: Text(
                      '共 ${devices.length} 台${cloudState.isLoggedIn ? '' : ' · LAN 模式'}',
                      style: TextStyle(
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
              child: LayoutBuilder(
                builder: (context, c) {
                  const spacing = 12.0;
                  final cols = c.maxWidth >= 900 ? 2 : 1;
                  final cardW = (c.maxWidth - spacing * (cols - 1)) / cols;
                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final d in devices)
                        SizedBox(
                          width: cardW,
                          child: _FirmwareDeviceCard(
                            device: d,
                            isActive: d.serial == activeSerial,
                            activeStatus:
                                (d.serial == activeSerial &&
                                    activeState.isConnected)
                                ? activeState.status
                                : null,
                            activeErrorMessage: d.serial == activeSerial
                                ? activeState.errorMessage
                                : null,
                            isPrinterConnected:
                                d.serial == activeSerial &&
                                activeState.isConnected,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FirmwareTopologyStage extends StatelessWidget {
  const _FirmwareTopologyStage({
    required this.devices,
    required this.activeSerial,
    required this.activeStatus,
    required this.cloudMode,
    required this.onSelectDevice,
  });

  final List<_FirmwareDeviceSource> devices;
  final String? activeSerial;
  final BambuPrinterStatus? activeStatus;
  final bool cloudMode;
  final ValueChanged<String> onSelectDevice;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final units =
        activeStatus?.amsUnits
            ?.where((unit) => unit.isPresent)
            .toList(growable: false) ??
        const <AmsUnit>[];
    final activeDevice = devices.cast<_FirmwareDeviceSource?>().firstWhere(
      (device) => device?.serial == activeSerial,
      orElse: () => null,
    );

    return OpenStage(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExperienceSectionHeading(
            title: '更新拓扑',
            trailing: Text(
              activeDevice == null
                  ? '选择一台活跃设备可读取实时模块'
                  : '正在读取 ${activeDevice.displayName}',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            height: 116,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _TopologyNode(
                    icon: cloudMode
                        ? Icons.cloud_done_rounded
                        : Icons.lan_rounded,
                    title: cloudMode ? '拓竹云更新源' : '本地 LAN 更新源',
                    subtitle: cloudMode ? '账号设备快照' : 'MQTT 实时版本',
                    accent: scheme.primary,
                    emphasized: true,
                  ),
                  const _TopologyConnector(),
                  for (var index = 0; index < devices.length; index++) ...[
                    _TopologyNode(
                      key: ValueKey(
                        'firmware-topology-device-${devices[index].serial}',
                      ),
                      icon: Icons.print_rounded,
                      title: devices[index].displayName,
                      subtitle: _deviceVersion(
                        devices[index],
                        devices[index].serial == activeSerial
                            ? activeStatus
                            : null,
                      ),
                      accent: devices[index].online
                          ? AppColors.success
                          : scheme.outline,
                      emphasized: devices[index].serial == activeSerial,
                      onTap: () => onSelectDevice(devices[index].serial),
                    ),
                    if (index != devices.length - 1)
                      const _TopologyConnector(short: true),
                  ],
                ],
              ),
            ),
          ),
          if (activeDevice != null) ...[
            Divider(height: AppSpacing.xl, color: scheme.outlineVariant),
            Row(
              children: [
                Icon(
                  Icons.account_tree_rounded,
                  size: 16,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    units.isEmpty
                        ? '当前没有上报 AMS 模块'
                        : '${activeDevice.displayName} 已连接 ${units.length} 个 AMS 模块',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final unit in units)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: _AmsModuleNode(unit: unit),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _deviceVersion(
    _FirmwareDeviceSource device,
    BambuPrinterStatus? status,
  ) {
    final version = status?.currentFirmwareVersion ?? device.cloudDevice?.swVer;
    if (version == null || version.isEmpty) {
      return device.online ? '等待版本上报' : '设备离线';
    }
    return '固件 $version';
  }
}

class _TopologyNode extends StatelessWidget {
  const _TopologyNode({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.emphasized,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final bool emphasized;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final node = TactileLift(
      enabled: onTap != null,
      maxTilt: 0.008,
      lift: 1.5,
      onTap: onTap,
      child: AnimatedContainer(
        duration: ExperienceTokens.contentDuration,
        width: 176,
        height: 104,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: emphasized ? accent.withValues(alpha: 0.1) : scheme.surface,
          borderRadius: BorderRadius.circular(ExperienceTokens.objectRadius),
          border: Border.all(
            color: emphasized ? accent : scheme.outlineVariant,
            width: emphasized ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: accent, size: 22),
            const Spacer(),
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
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) return node;
    return Tooltip(message: emphasized ? '当前实时设备' : '点击切换并读取实时版本', child: node);
  }
}

class _TopologyConnector extends StatelessWidget {
  const _TopologyConnector({this.short = false});

  final bool short;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return SizedBox(
      width: short ? 28 : 52,
      child: Row(
        children: [
          Expanded(child: Divider(color: color, thickness: 1.5)),
          Icon(Icons.chevron_right_rounded, size: 16, color: color),
        ],
      ),
    );
  }
}

class _AmsModuleNode extends StatelessWidget {
  const _AmsModuleNode({required this.unit});

  final AmsUnit unit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '${unit.type.displayLabel} · ${unit.trays.length} 个槽位',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.layers_rounded, size: 15, color: scheme.primary),
            const SizedBox(width: 5),
            Text(
              '${unit.type.displayLabel} ${unit.id + 1}',
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 固件面板的统一设备数据源：合并云设备 + LAN 配置。
///
/// LAN-only 模式下 cloudDevice 为 null，版本信息从 MQTT activeStatus 读取；
/// 云端模式 cloudDevice 提供版本快照，MQTT 实时数据优先覆盖。
class _FirmwareDeviceSource {
  final String serial;
  final BambuCloudDevice? cloudDevice;
  final PrinterConnectionConfig lanConfig;

  /// 归属账号 "email|region_code"，LAN 直连为 null
  final String? ownerAccount;

  const _FirmwareDeviceSource({
    required this.serial,
    required this.cloudDevice,
    required this.lanConfig,
    this.ownerAccount,
  });

  String get displayName => (cloudDevice?.name.isNotEmpty ?? false)
      ? cloudDevice!.name
      : (lanConfig.displayName?.isNotEmpty ?? false)
      ? lanConfig.displayName!
      : (cloudDevice?.devProductName.isNotEmpty ?? false)
      ? cloudDevice!.devProductName
      : lanConfig.serial;

  String get devProductName =>
      cloudDevice?.devProductName ?? lanConfig.devProductName ?? '';

  bool get online => cloudDevice?.online ?? true;

  /// 归属标签文案："账号A" 或 "LAN直连"
  String get ownerLabel {
    if (ownerAccount == null) return 'LAN直连';
    final parts = ownerAccount!.split('|');
    return parts.isNotEmpty ? parts[0] : 'LAN直连';
  }
}

/// 单台设备的固件信息卡片。
class _FirmwareDeviceCard extends ConsumerWidget {
  final _FirmwareDeviceSource device;
  final bool isActive;
  final BambuPrinterStatus? activeStatus;

  /// M7 修复：活跃打印机的错误信息（连接失败等）
  final String? activeErrorMessage;

  /// M7 修复：活跃打印机是否已连接（未连接时禁用升级按钮）
  final bool isPrinterConnected;

  const _FirmwareDeviceCard({
    required this.device,
    required this.isActive,
    required this.activeStatus,
    required this.activeErrorMessage,
    required this.isPrinterConnected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cloud = device.cloudDevice;
    // 优先用活跃打印机的 MQTT 实时数据，其次用云端拉取的快照
    final currentVer =
        activeStatus?.currentFirmwareVersion ?? _nonEmpty(cloud?.swVer ?? '');
    // 最新固件：MQTT get_version 响应中的 ota_new_ver。
    // - 有值：显示最新版本号 + "有更新"
    // - 空/null 但 MQTT 已响应版本查询（otaModule 有值）：说明已是最新，回退到当前版本 + "已是最新"
    // - 未响应或非活跃设备：null，显示"等待推送..."/"连接后查看"
    final rawLatest = activeStatus?.latestFirmwareVersion;
    final bool versionInfoReceived = activeStatus?.otaModule != null;
    final latestVer =
        (rawLatest != null && rawLatest.isNotEmpty && rawLatest != 'null')
        ? rawLatest
        : (versionInfoReceived ? currentVer : null);
    final hwVer = activeStatus?.hwVersion ?? _nonEmpty(cloud?.hwVer ?? '');
    final hasUpdate = activeStatus?.hasFirmwareUpdate ?? false;
    final isUpgrading = activeStatus?.isUpgrading ?? false;
    // L3 修复：缓存模块列表，避免 build 中多次调用 getter 重复计算
    final moduleEntries = _moduleEntries;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(ExperienceTokens.objectRadius),
        border: Border.all(
          color: isActive
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outlineVariant,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部：设备名 + SN + 状态标签
          _CardHeader(
            name: device.displayName,
            sn: device.serial,
            online: device.online,
            isActive: isActive,
            ownerLabel: device.ownerLabel,
            isLan: device.ownerAccount == null,
          ),
          const SizedBox(height: 14),
          // 版本信息行
          _VersionRow(
            label: '当前固件',
            value: currentVer,
            isActiveDevice: isActive,
          ),
          const SizedBox(height: 8),
          _VersionRow(
            label: '最新固件',
            value: latestVer,
            isActiveDevice: isActive,
            trailing: hasUpdate
                ? const AppChip(label: '有更新', variant: AppChipVariant.warn)
                : (latestVer != null && latestVer.isNotEmpty
                      ? const AppChip(
                          label: '已是最新',
                          variant: AppChipVariant.info,
                        )
                      : null),
          ),
          const SizedBox(height: 8),
          _VersionRow(label: '硬件版本', value: hwVer, isActiveDevice: isActive),
          if (cloud?.deviceOemType != null &&
              cloud!.deviceOemType!.isNotEmpty) ...[
            const SizedBox(height: 8),
            _VersionRow(label: '设备类型', value: cloud.deviceOemType),
          ],
          // 各模块版本
          if (moduleEntries.isNotEmpty) ...[
            const SizedBox(height: 14),
            const _SectionTitle(text: '各模块版本'),
            const SizedBox(height: 6),
            ...moduleEntries.map(
              (e) => _ModuleRow(name: e.key, version: e.value),
            ),
          ],
          // M7 修复：显示错误信息（连接失败等）
          if (activeErrorMessage != null && activeErrorMessage!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: BorderRadius.circular(AppColors.radiusSm),
              ),
              child: Row(
                children: [
                  const BambuIcon(
                    name: 'error',
                    size: 12,
                    color: AppColors.danger,
                    applyColorFilter: true,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      activeErrorMessage!,
                      style: AppTypography.caption.copyWith(
                        fontSize: 11,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          // 升级进度（升级中显示）
          if (isUpgrading && activeStatus != null) ...[
            const SizedBox(height: 14),
            _UpgradeProgress(status: activeStatus!),
          ],
          // 升级按钮 + AMS 升级
          if (isActive) ...[
            const SizedBox(height: 14),
            _UpgradeActions(
              hasUpdate: hasUpdate,
              isUpgrading: isUpgrading,
              isConnected: isPrinterConnected,
              amsCount: _amsCount,
              onUpgrade: () => _confirmUpgrade(context, ref),
              onAmsUpgrade: (id) => _confirmAmsUpgrade(context, ref, id),
            ),
          ] else ...[
            const SizedBox(height: 14),
            _HintBar(text: device.online ? '设为当前打印机后可发起升级' : '设备离线，无法升级'),
          ],
        ],
      ),
    );
  }

  /// 取首个非空字符串
  String? _nonEmpty(String s) => s.isEmpty ? null : s;

  /// 模块版本条目（合并云端 module_versions 与 MQTT otaModule）
  List<_ModuleEntry> get _moduleEntries {
    final result = <_ModuleEntry>[];
    final seen = <String>{};
    // 云端 module_versions
    final cloudMods = device.cloudDevice?.moduleVersions;
    if (cloudMods != null) {
      cloudMods.forEach((key, value) {
        if (key.isNotEmpty && value.isNotEmpty && !seen.contains(key)) {
          result.add(_ModuleEntry(key, value));
          seen.add(key);
        }
      });
    }
    // MQTT otaModule 的 sw_ver / hw_ver（补充云端缺失时）
    final module = activeStatus?.otaModule;
    if (module != null) {
      final name = module['name']?.toString() ?? '';
      final swVer = module['sw_ver']?.toString() ?? '';
      if (name.isNotEmpty && swVer.isNotEmpty && !seen.contains(name)) {
        result.add(_ModuleEntry(name, swVer));
        seen.add(name);
      }
    }
    return result;
  }

  /// AMS 数量（用于 AMS 单独升级入口）
  int get _amsCount {
    final trays = activeStatus?.amsTrays;
    if (trays == null || trays.isEmpty) return 0;
    final ids = <int>{};
    for (final t in trays) {
      ids.add(t.amsId);
    }
    return ids.length;
  }

  /// 主固件升级确认
  Future<void> _confirmUpgrade(BuildContext context, WidgetRef ref) async {
    final ok = await AppDialog.confirm(
      context,
      '确认升级固件？',
      '升级期间请勿断电或关闭打印机，可能导致设备损坏。升级过程约需 3-10 分钟，完成后打印机会自动重启。',
      confirmText: '开始升级',
      destructive: true,
    );
    if (!ok) return;
    final success = await ref
        .read(activePrinterConnectionProvider.notifier)
        .sendFirmwareUpgrade();
    if (context.mounted) {
      showSnack(
        context,
        success ? '升级指令已发送，请勿断电' : '升级指令发送失败',
        error: !success,
      );
    }
  }

  /// AMS 固件升级确认
  Future<void> _confirmAmsUpgrade(
    BuildContext context,
    WidgetRef ref,
    int amsId,
  ) async {
    final ok = await AppDialog.confirm(
      context,
      '升级 AMS$amsId 固件？',
      '升级期间请勿断电或拔出 AMS，可能导致 AMS 损坏。',
      confirmText: '开始升级',
      destructive: true,
    );
    if (!ok) return;
    final success = await ref
        .read(activePrinterConnectionProvider.notifier)
        .sendAmsFirmwareUpgrade(amsId);
    if (context.mounted) {
      showSnack(
        context,
        success ? 'AMS$amsId 升级指令已发送' : '升级指令发送失败',
        error: !success,
      );
    }
  }
}

/// 卡片顶部标题区：设备名 + SN + 在线/活跃标签 + 归属账号。
class _CardHeader extends StatelessWidget {
  final String name;
  final String sn;
  final bool online;
  final bool isActive;

  /// 归属标签："email" 或 "LAN直连"
  final String? ownerLabel;

  /// 是否为 LAN 直连设备
  final bool isLan;

  const _CardHeader({
    required this.name,
    required this.sn,
    required this.online,
    required this.isActive,
    this.ownerLabel,
    this.isLan = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primaryContainer,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
          ),
          alignment: Alignment.center,
          child: BambuIcon(
            name: 'printer',
            size: 18,
            color: AppColors.primary,
            applyColorFilter: true,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: AppTypography.title.copyWith(
                  fontSize: 15,
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
                  Text(
                    'SN: $sn',
                    style: AppTypography.data.copyWith(
                      fontSize: 12,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (ownerLabel != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: isLan
                            ? AppColors.successContainer
                            : AppColors.primaryContainer,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        ownerLabel!,
                        style: AppTypography.label.copyWith(
                          fontSize: 10,
                          color: isLan
                              ? AppColors.success
                              : AppColors.onPrimaryContainer,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        // v4：状态徽章改用 AppChip（自动暗色 + 胶囊形态）
        if (isActive)
          const Padding(
            padding: EdgeInsets.only(left: 6),
            child: AppChip(label: '当前', variant: AppChipVariant.selected),
          )
        else if (online)
          const Padding(
            padding: EdgeInsets.only(left: 6),
            child: AppChip(
              label: '在线',
              variant: AppChipVariant.dot,
              dotColor: AppColors.success,
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.only(left: 6),
            child: AppChip(label: '离线', variant: AppChipVariant.default_),
          ),
      ],
    );
  }
}

/// 版本信息行：左侧标签 + 右侧值 + 可选尾部标签。
class _VersionRow extends StatelessWidget {
  final String label;
  final String? value;
  final Widget? trailing;
  final bool isActiveDevice;

  const _VersionRow({
    required this.label,
    required this.value,
    this.trailing,
    this.isActiveDevice = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final displayValue = value ?? (isActiveDevice ? '等待推送...' : '连接后查看');
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: AppTypography.body.copyWith(
              fontSize: 12,
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            displayValue,
            style: AppTypography.data.copyWith(
              fontSize: 13,
              color: value != null
                  ? (isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary)
                  : (isDark ? AppColors.textTertiaryDark : AppColors.textMuted),
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// 小节标题。
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle({required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      text,
      style: AppTypography.label.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
        letterSpacing: 0.2,
      ),
    );
  }
}

/// 单个模块版本行。
class _ModuleRow extends StatelessWidget {
  final String name;
  final String version;
  const _ModuleRow({required this.name, required this.version});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 模块名归一化展示
    final label = _moduleLabel(name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: AppTypography.body.copyWith(
                fontSize: 12,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              version,
              style: AppTypography.data.copyWith(
                fontSize: 12,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 模块 key 转中文标签
  static String _moduleLabel(String key) {
    const map = {'ota': 'OTA', 'mc': 'MC', 'th': 'TH', 'ams': 'AMS'};
    return map[key.toLowerCase()] ?? key.toUpperCase();
  }
}

/// 升级进度展示。
class _UpgradeProgress extends StatelessWidget {
  final BambuPrinterStatus status;
  const _UpgradeProgress({required this.status});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pct = double.tryParse(status.upgradeProgress ?? '') ?? 0;
    final pctClamped = pct.clamp(0, 100);
    final isSuccess = status.upgradeStatus == 'UPGRADE_SUCCESS';
    final isFailed = status.upgradeStatus == 'UPGRADE_FAILED';
    // 状态色保留：用于图标和文字颜色（进度条本身用 AppProgress 的 primary 渐变）
    final statusColor = isFailed
        ? AppColors.danger
        : (isSuccess ? AppColors.success : AppColors.primary);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BambuIcon(
                name: isFailed
                    ? 'error'
                    : (isSuccess ? 'confirm' : 'monitor_upgrade_online'),
                size: 16,
                color: statusColor,
                applyColorFilter: true,
              ),
              const SizedBox(width: 6),
              Text(
                _statusLabel(status.upgradeStatus),
                style: AppTypography.body.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
              const Spacer(),
              Text(
                '${pctClamped.toStringAsFixed(0)}%',
                style: AppTypography.data.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // v4：进度条改用 AppProgress（光流动效 + 外发光 + 自动暗色）
          AppProgress(value: pctClamped / 100, thickness: 8, showGlow: true),
          if (status.upgradeMessage != null &&
              status.upgradeMessage!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              status.upgradeMessage!,
              style: AppTypography.caption.copyWith(
                fontSize: 11,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _statusLabel(String? status) {
    switch (status) {
      case 'UPGRADING':
        return '升级中…';
      case 'UPGRADE_SUCCESS':
        return '升级成功';
      case 'UPGRADE_FAILED':
        return '升级失败';
      default:
        return '升级中…';
    }
  }
}

/// 升级操作区：主固件升级按钮 + AMS 升级入口。
class _UpgradeActions extends StatelessWidget {
  final bool hasUpdate;
  final bool isUpgrading;

  /// M7 修复：打印机是否已连接，未连接时禁用升级按钮
  final bool isConnected;
  final int amsCount;
  final VoidCallback onUpgrade;
  final ValueChanged<int> onAmsUpgrade;

  const _UpgradeActions({
    required this.hasUpdate,
    required this.isUpgrading,
    required this.isConnected,
    required this.amsCount,
    required this.onUpgrade,
    required this.onAmsUpgrade,
  });

  @override
  Widget build(BuildContext context) {
    // M7 修复：升级中或未连接时禁用按钮
    final upgradeDisabled = isUpgrading || !isConnected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // v4：一键升级按钮改用 AppButton danger（红色渐变 + 高光 + 外发光）
        if (hasUpdate || isUpgrading)
          AppButton(
            label: isUpgrading ? '升级进行中' : '一键升级',
            variant: AppButtonVariant.danger,
            icon: isUpgrading
                ? const Icon(Icons.hourglass_top_rounded, size: 16)
                : Builder(
                    builder: (context) => BambuIcon(
                      name: 'monitor_upgrade_online',
                      size: 16,
                      color: GlassButtonsTheme.enabledOf(context)
                          ? IconTheme.of(context).color
                          : AppColors.onPrimary,
                      applyColorFilter: true,
                    ),
                  ),
            onPressed: upgradeDisabled ? null : onUpgrade,
          ),
        // AMS 单独升级入口：改用 AppButton secondary（玻璃描边）
        if (amsCount > 0 && !isUpgrading) ...[
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (int i = 0; i < amsCount; i++)
                AppButton(
                  label: 'AMS$i 升级',
                  variant: AppButtonVariant.secondary,
                  icon: BambuIcon(
                    name: 'ams_drying',
                    size: 14,
                    color: AppColors.primary,
                    applyColorFilter: true,
                  ),
                  onPressed: () => onAmsUpgrade(i),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 提示条（非活跃设备）。
class _HintBar extends StatelessWidget {
  final String text;
  const _HintBar({required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
      ),
      child: Row(
        children: [
          BambuIcon(
            name: 'info',
            size: 14,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
            applyColorFilter: true,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: AppTypography.body.copyWith(
                fontSize: 12,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 模块版本条目内部结构。
class _ModuleEntry {
  final String key;
  final String value;
  const _ModuleEntry(this.key, this.value);
}
