import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/app_identity.dart';
import '../../core/app_variant.dart';
import '../../core/theme/app_colors.dart';
import '../updates/app_update_page.dart';
import '../../core/services/kill_switch_service.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/theme/glass_button_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/theme_color.dart';
import '../../core/utils/backup_manager.dart';
import '../../core/utils/public_image_url.dart';
import '../../core/services/anomaly_detection_service.dart';
import '../../core/services/drying_reminder_service.dart';
import '../../core/services/device_workbench_publisher.dart';
import '../../core/services/telemetry_service.dart';
import '../../data/database/migration_manager.dart';
import '../../data/external/print_task/gram_calculator.dart';
import '../../data/external/community/studio_api_client.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/bambu_lan_discovery.dart';
import '../../data/external/printer/bambu_cloud_client.dart'
    show BambuClientVersion;
import '../../data/models/app_auth.dart';
import '../../data/seed/printer_seed.dart';
import '../../data/external/slicer/bambu_studio_lan_config_writer.dart';
import '../../data/prefs/app_prefs.dart';
import '../../data/prefs/app_version_prefs.dart';
import '../../data/prefs/onboarding_prefs.dart';
import '../../data/prefs/slicer_prefs.dart';
import '../../providers/bambu_account_manager.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../../providers/app_auth_provider.dart';
import '../../providers/batch_recognition_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/print_queue_provider.dart'
    show printQueueEnabledProvider, unattendedModeProvider;
import '../../providers/printer_connection_provider.dart';
import '../../providers/print_task_provider.dart';
import '../../providers/scheduler_provider.dart';
import '../../providers/slicer_provider.dart';
import '../../providers/stock_alert_provider.dart';
import '../../providers/studio_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_brand_icon.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/app_input.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/app_select.dart';
import '../../widgets/app_switch.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filament_spool_icon.dart';
import '../../widgets/glass_card.dart';
import '../account/account_manager_screen.dart';
import '../printers/printer_certificate_trust_dialog.dart';
import '../updates/whats_new_dialog.dart';
import 'cloud_login_dialog.dart';

/// 设置面板（macOS Sonoma 风格偏好窗）。
///
/// 从顶部右侧的设置按钮触发，居中弹窗 + 左分类导航 + 右表单区。
/// 改造原则：只换皮不换骨——保留全部既有 7 大块设置功能，
/// 仅把 BottomSheet 换为居中偏好窗并做组件替换与暗色适配。
///
/// 6 大分类映射既有 7 大块：
/// 1. 外观（新）：深色模式 / 主题色 / 背景动效 / 开机自启
/// 2. 切片：切片软件配置 + 切片文件读取方式
/// 3. 连接：拓竹云连接 + 打印机 LAN 连接
/// 4. 耗材：克数计算模式
/// 5. 数据：数据版本 + 立即备份 + 备份列表
/// 6. 关于：重新初始化向导 + 版本信息
class SettingsSheet {
  static Future<void> show(BuildContext context) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭设置',
      barrierColor: const Color(0x4D000000),
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        // 修复：原 CurvedAnimation 未 dispose 造成累积泄漏，改用 AnimatedBuilder。
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final t = animation.value;
            final scale = Curves.easeOutBack.transform(t);
            return Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.scale(scale: scale, child: child),
            );
          },
          child: child,
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return const Center(child: SettingsWorkspace());
      },
    );
  }
}

/// Reuse the account login dialog from other account-linked surfaces (for
/// example the support-code redemption flow) without duplicating credentials
/// handling outside the settings feature.
Future<bool> promptSohunLogin(BuildContext context, WidgetRef ref) async {
  final payload = await showDialog<_AppLoginPayload>(
    context: context,
    builder: (_) => const _AppLoginDialog(),
  );
  if (payload == null || !context.mounted) return false;
  try {
    await ref
        .read(appAuthProvider.notifier)
        .login(
          AppLoginRequest(email: payload.email, password: payload.password),
        );
    if (context.mounted) showSnack(context, 'sohun 账号已登录');
    return true;
  } catch (error) {
    if (context.mounted) {
      showSnack(context, friendlyError(error), error: true);
    }
    return false;
  }
}

/// 可复用的完整设置工作区。
///
/// [embedded] 为 true 时填满当前页面，不显示关闭按钮；弹窗入口继续使用
/// 原有固定尺寸与关闭行为。两种入口共享完全相同的设置表单，避免页面只放几个
/// 快捷项、真正选项又要二次打开弹窗。
class SettingsWorkspace extends StatelessWidget {
  const SettingsWorkspace({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return _PreferencesWindow(embedded: embedded);
  }
}

/// 偏好窗分类。
enum _SettingsCategory {
  appearance,
  account,
  slicer,
  connection,
  consumable,
  studio,
  automation,
  notifications,
  dataPrivacy,
  about,
}

class _SettingsDestination {
  const _SettingsDestination({
    required this.category,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.group,
    this.keywords = '',
    this.bambuIconName,
  });

  final _SettingsCategory category;
  final IconData icon;
  final String title;
  final String subtitle;
  final String group;
  final String keywords;
  final String? bambuIconName;
}

/// 偏好窗主体：GlassCard L2 外壳 + 左导航 + 右表单。
class _PreferencesWindow extends ConsumerStatefulWidget {
  const _PreferencesWindow({required this.embedded});

  final bool embedded;

  @override
  ConsumerState<_PreferencesWindow> createState() => _PreferencesWindowState();
}

class _PreferencesWindowState extends ConsumerState<_PreferencesWindow> {
  _SettingsCategory _selectedCategory = _SettingsCategory.appearance;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  static const _destinations = [
    _SettingsDestination(
      category: _SettingsCategory.appearance,
      icon: Icons.tune_rounded,
      title: '外观与体验',
      subtitle: '主题、动效与窗口',
      group: '个性化',
      keywords: '颜色 深色 浅色 开机 自启 托盘 关闭',
    ),
    _SettingsDestination(
      category: _SettingsCategory.account,
      icon: Icons.person_rounded,
      title: 'sohun 账号',
      subtitle: '身份与云同步',
      group: '账号与设备',
      keywords: '登录 注册 邮箱 作者 参数广场',
    ),
    _SettingsDestination(
      category: _SettingsCategory.connection,
      icon: Icons.hub_outlined,
      title: '设备与连接',
      subtitle: '拓竹云、LAN 与证书',
      group: '账号与设备',
      keywords: '打印机 云端 账号 IP access code MQTT',
    ),
    _SettingsDestination(
      category: _SettingsCategory.slicer,
      icon: Icons.layers_outlined,
      title: '切片与文件',
      subtitle: 'BambuStudio 与解析',
      group: '打印工作流',
      keywords: '路径 输出 3mf gcode 版本',
    ),
    _SettingsDestination(
      category: _SettingsCategory.consumable,
      icon: Icons.circle_outlined,
      title: '耗材与库存',
      subtitle: '计算、阈值与提醒',
      group: '打印工作流',
      keywords: '库存 干燥 异常 换色 RFID 克数',
      bambuIconName: 'spool',
    ),
    _SettingsDestination(
      category: _SettingsCategory.studio,
      icon: Icons.factory_outlined,
      title: '打印农场模式',
      subtitle: '团队、订单与经营管理',
      group: '打印工作流',
      keywords: '工作室 农场 团队 客户 订单 工单 报价 利润 调度 共享库存',
    ),
    _SettingsDestination(
      category: _SettingsCategory.automation,
      icon: Icons.auto_awesome_motion_outlined,
      title: '自动化',
      subtitle: '调度、批次与队列',
      group: '打印工作流',
      keywords: '自动调度 无人值守 实验 入队 批次',
    ),
    _SettingsDestination(
      category: _SettingsCategory.notifications,
      icon: Icons.notifications_none_rounded,
      title: '通知',
      subtitle: '打印与耗材消息',
      group: '系统',
      keywords: '消息 提醒 完成 失败 系统通知',
    ),
    _SettingsDestination(
      category: _SettingsCategory.dataPrivacy,
      icon: Icons.shield_outlined,
      title: '数据与隐私',
      subtitle: '备份、分享与诊断',
      group: '系统',
      keywords: '恢复 备份 遥测 上传 社区 本地 数据目录',
    ),
    _SettingsDestination(
      category: _SettingsCategory.about,
      icon: Icons.info_outline_rounded,
      title: '关于与更新',
      subtitle: '版本、更新与初始化',
      group: '系统',
      keywords: '检查更新 版本 重置 初始化 作者',
      bambuIconName: 'info',
    ),
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 重新运行初始化向导：保留原有 OnboardingPrefs + provider 失效逻辑。
  Future<void> _rerunOnboarding() async {
    await OnboardingPrefs.setCompleted(false);
    ref.read(onboardingProvider.notifier).reset();
    ref.invalidate(onboardingCompletedProvider);
    if (mounted && !widget.embedded) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width - 48).clamp(420.0, 1040.0).toDouble();
    final dialogHeight = (size.height - 48).clamp(420.0, 720.0).toDouble();
    final content = GlassCard(
      level: GlassLevel.l2,
      borderRadius: BorderRadius.circular(AppColors.radiusXl),
      blur: 30,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _WindowHeader(isDark: isDark, showClose: !widget.embedded),
          Container(
            height: 1,
            color: isDark ? AppColors.dividerDark : AppColors.divider,
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 720) {
                  return Column(
                    children: [
                      _buildCompactNavigation(isDark),
                      Divider(
                        height: 1,
                        color: isDark
                            ? AppColors.dividerDark
                            : AppColors.divider,
                      ),
                      Expanded(child: _buildContent()),
                    ],
                  );
                }
                return Row(
                  children: [
                    _buildNavigationRail(isDark),
                    Container(
                      width: 1,
                      color: isDark ? AppColors.dividerDark : AppColors.divider,
                    ),
                    Expanded(child: _buildContent()),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
    if (widget.embedded) {
      return SizedBox.expand(child: content);
    }
    return SizedBox(width: dialogWidth, height: dialogHeight, child: content);
  }

  Iterable<_SettingsDestination> get _productDestinations {
    if (AppVariant.isFarm) return _destinations;
    return _destinations.where(
      (item) => item.category != _SettingsCategory.studio,
    );
  }

  List<_SettingsDestination> get _visibleDestinations {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _productDestinations.toList(growable: false);
    return _productDestinations
        .where((item) {
          return '${item.title} ${item.subtitle} ${item.keywords}'
              .toLowerCase()
              .contains(query);
        })
        .toList(growable: false);
  }

  Widget _buildNavigationRail(bool isDark) {
    final visible = _visibleDestinations;
    return Container(
      width: 224,
      color: (isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant)
          .withValues(alpha: 0.38),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: _SettingsSearchField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('没有找到相关设置'),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(9, 2, 9, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (
                          var index = 0;
                          index < visible.length;
                          index++
                        ) ...[
                          if (index == 0 ||
                              visible[index - 1].group != visible[index].group)
                            Padding(
                              padding: EdgeInsets.fromLTRB(
                                10,
                                index == 0 ? 5 : 8,
                                10,
                                3,
                              ),
                              child: Text(
                                visible[index].group,
                                style: AppTypography.label.copyWith(
                                  fontSize: 10,
                                  letterSpacing: 0.8,
                                  color: isDark
                                      ? AppColors.textTertiaryDark
                                      : AppColors.textTertiary,
                                ),
                              ),
                            ),
                          _buildNavItem(visible[index], isDark),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactNavigation(bool isDark) {
    final destinations = _productDestinations.toList(growable: false);
    return SizedBox(
      height: 58,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var index = 0; index < destinations.length; index++) ...[
              if (index > 0) const SizedBox(width: 7),
              Builder(
                builder: (context) {
                  final item = destinations[index];
                  final selected = item.category == _selectedCategory;
                  return ChoiceChip(
                    selected: selected,
                    showCheckmark: false,
                    avatar: Icon(
                      item.icon,
                      size: 16,
                      color: selected ? AppColors.primary : null,
                    ),
                    label: Text(item.title),
                    onSelected: (_) => setState(() {
                      _selectedCategory = item.category;
                      _searchQuery = '';
                      _searchController.clear();
                    }),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(_SettingsDestination item, bool isDark) {
    final selected = _selectedCategory == item.category;
    final iconColor = selected
        ? AppColors.primary
        : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondary);
    return Semantics(
      button: true,
      selected: selected,
      label: '${item.title}，${item.subtitle}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppColors.radiusLg),
          onTap: () => setState(() {
            _selectedCategory = item.category;
            _searchQuery = '';
            _searchController.clear();
          }),
          child: AnimatedContainer(
            duration: AppMotion.duration(
              context,
              const Duration(milliseconds: 170),
            ),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: const EdgeInsets.fromLTRB(8, 6, 9, 6),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.primary.withValues(alpha: isDark ? 0.16 : 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AppColors.radiusLg),
              border: Border.all(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.18)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: AppMotion.duration(
                    context,
                    const Duration(milliseconds: 170),
                  ),
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.primary.withValues(alpha: 0.12)
                        : (isDark
                              ? Colors.white.withValues(alpha: 0.045)
                              : Colors.black.withValues(alpha: 0.035)),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: item.bambuIconName == null
                      ? Icon(item.icon, size: 17, color: iconColor)
                      : BambuIcon(
                          name: item.bambuIconName!,
                          size: 16,
                          color: iconColor,
                          applyColorFilter: true,
                        ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.body.copyWith(
                          fontSize: 12.5,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.label.copyWith(fontSize: 9.5),
                      ),
                    ],
                  ),
                ),
                AnimatedOpacity(
                  opacity: selected ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    width: 3,
                    height: 22,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      key: PageStorageKey('settings-${_selectedCategory.name}'),
      padding: const EdgeInsets.fromLTRB(26, 24, 26, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: AnimatedSwitcher(
            duration: AppMotion.duration(
              context,
              const Duration(milliseconds: 190),
            ),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.012, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: KeyedSubtree(
              key: ValueKey(_selectedCategory),
              child: _buildForm(),
            ),
          ),
        ),
      ),
    );
  }

  /// 根据选中分类渲染右侧表单。
  Widget _buildForm() {
    switch (_selectedCategory) {
      case _SettingsCategory.appearance:
        return const _AppearanceSection();
      case _SettingsCategory.account:
        return const _AppAccountPanel();
      case _SettingsCategory.slicer:
        return const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SlicerSection(),
            SizedBox(height: 24),
            _SliceReadModeSection(),
          ],
        );
      case _SettingsCategory.connection:
        return const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AccountManagementEntry(),
            SizedBox(height: 24),
            _PrinterConnectionSection(),
            if (!AppVariant.isFarm) ...[
              SizedBox(height: 24),
              DeviceSharingSettingsTile(),
            ],
          ],
        );
      case _SettingsCategory.consumable:
        return const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CalculationModeSection(),
            SizedBox(height: 24),
            _InventoryDetailSection(),
            SizedBox(height: 24),
            _DryingReminderSection(),
            SizedBox(height: 24),
            _ExternalFilamentReminderSection(),
            SizedBox(height: 24),
            _AnomalyDetectionSection(),
            SizedBox(height: 24),
            _StockThresholdsSection(),
            SizedBox(height: 24),
            _MaterialSyncSection(),
          ],
        );
      case _SettingsCategory.studio:
        return const _StudioModeSection();
      case _SettingsCategory.automation:
        return const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AutomationPreferencesSection(),
            SizedBox(height: 24),
            _BatchRecognitionSection(),
            SizedBox(height: 24),
            _PrintQueueSettingsSection(),
          ],
        );
      case _SettingsCategory.notifications:
        return const _NotificationPreferencesSection();
      case _SettingsCategory.dataPrivacy:
        return const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DataManagementSection(),
            SizedBox(height: 28),
            _CloudSharingSection(),
            SizedBox(height: 28),
            _PrivacySection(),
          ],
        );
      case _SettingsCategory.about:
        return _AboutSection(onRerunOnboarding: _rerunOnboarding);
    }
  }
}

class _SettingsSearchField extends StatelessWidget {
  const _SettingsSearchField({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 12),
        decoration: InputDecoration(
          hintText: '搜索设置',
          prefixIcon: const Icon(Icons.search_rounded, size: 17),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空搜索',
                  icon: const Icon(Icons.close_rounded, size: 15),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          filled: true,
        ),
      ),
    );
  }
}

/// 偏好窗顶部标题栏。
class _WindowHeader extends StatelessWidget {
  final bool isDark;
  final bool showClose;
  const _WindowHeader({required this.isDark, required this.showClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.primary.withValues(alpha: 0.18),
                  AppColors.primary.withValues(alpha: 0.07),
                ],
              ),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.16),
              ),
            ),
            child: BambuIcon(
              name: 'settings',
              size: 20,
              color: AppColors.primary,
              applyColorFilter: true,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '设置中心',
                style: AppTypography.title.copyWith(
                  fontSize: 17,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '账号、设备与工作流统一管理',
                style: AppTypography.caption.copyWith(
                  fontSize: 10,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                ),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt_rounded, size: 13, color: AppColors.success),
                SizedBox(width: 4),
                Text(
                  '修改即时生效',
                  style: TextStyle(
                    color: AppColors.success,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (showClose) const SizedBox(width: 6),
          if (showClose)
            IconButton(
              tooltip: '关闭设置',
              icon: BambuIcon(
                name: 'cross',
                size: 18,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
                applyColorFilter: true,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
        ],
      ),
    );
  }
}

Future<void> showFarmOwnerLoginFlow(BuildContext context, WidgetRef ref) async {
  await const _AppAccountPanel()._loginFarmOwner(context, ref);
}

Future<void> showAppAccountRegistrationFlow(
  BuildContext context,
  WidgetRef ref,
) => const _AppAccountPanel()._register(context, ref);

Future<void> showDirectFarmOwnerRegistrationFlow(
  BuildContext context,
  WidgetRef ref,
) => const _AppAccountPanel()._registerFarmOwner(context, ref);

Future<void> showFarmStaffLoginFlow(BuildContext context, WidgetRef ref) =>
    const _AppAccountPanel()._loginFarmStaff(context, ref);

Future<void> showFarmStaffPasswordChangeFlow(
  BuildContext context,
  WidgetRef ref,
) => const _AppAccountPanel()._changeFarmStaffPassword(context, ref);

Future<void> showFarmEmailVerificationFlow(
  BuildContext context,
  WidgetRef ref,
) => const _AppAccountPanel()._verifyEmail(context, ref);

Future<void> showFarmAccountLogoutFlow(BuildContext context, WidgetRef ref) =>
    const _AppAccountPanel()._logout(context, ref);

Future<void> showFarmOnboardingFlow(BuildContext context, WidgetRef ref) =>
    _showFarmOnboardingDialog(context, ref);

class _AppAccountPanel extends ConsumerWidget {
  const _AppAccountPanel();

  Future<void> _loginFarmOwner(BuildContext context, WidgetRef ref) async {
    final payload = await showDialog<_AppLoginPayload>(
      context: context,
      builder: (_) => const _AppLoginDialog(),
    );
    if (payload == null || !context.mounted) return;
    try {
      final notifier = ref.read(appAuthProvider.notifier);
      final session = await notifier.login(
        AppLoginRequest(email: payload.email, password: payload.password),
      );
      if (session.user.emailVerified) {
        final hasFarm = await ref
            .read(studioCloudServiceProvider)
            .hasOwnedFarmOrganization();
        if (!hasFarm) {
          await ref.read(studioModeEnabledProvider.notifier).setEnabled(true);
          if (context.mounted) {
            showSnack(context, '软件账号已登录，请继续开通农场管理员身份');
          }
          return;
        }
      }
      await ref.read(studioModeEnabledProvider.notifier).setEnabled(true);
      if (context.mounted) showSnack(context, '农场管理员账号已登录');
    } catch (error) {
      if (context.mounted) {
        showSnack(context, friendlyError(error), error: true);
      }
    }
  }

  Future<void> _login(BuildContext context, WidgetRef ref) async {
    await promptSohunLogin(context, ref);
  }

  Future<void> _loginFarmStaff(BuildContext context, WidgetRef ref) async {
    final payload = await showDialog<_FarmStaffLoginPayload>(
      context: context,
      builder: (_) => const _FarmStaffLoginDialog(),
    );
    if (payload == null || !context.mounted) return;
    try {
      final notifier = ref.read(appAuthProvider.notifier);
      final session = await notifier.loginFarmStaff(
        FarmStaffLoginRequest(
          organizationCode: payload.organizationCode,
          loginName: payload.loginName,
          password: payload.password,
        ),
      );
      await ref.read(studioModeEnabledProvider.notifier).setEnabled(true);
      if (!context.mounted) return;
      showSnack(context, '已登录 ${session.farmOrganizationName ?? '打印农场'}');
      if (!session.mustChangePassword) return;
      final change = await showDialog<_FarmPasswordChangePayload>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _FarmInitialPasswordDialog(currentPassword: payload.password),
      );
      if (change == null) {
        await notifier.logout();
        if (context.mounted) {
          showSnack(context, '必须修改初始密码后才能使用农场功能', error: true);
        }
        return;
      }
      await notifier.changeFarmInitialPassword(
        FarmInitialPasswordChangeRequest(
          currentPassword: change.currentPassword,
          newPassword: change.newPassword,
        ),
      );
      if (context.mounted) showSnack(context, '初始密码已修改，成员账号可以正常使用');
    } catch (error) {
      if (context.mounted) {
        showSnack(context, friendlyError(error), error: true);
      }
    }
  }

  Future<void> _changeFarmStaffPassword(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final change = await showDialog<_FarmPasswordChangePayload>(
      context: context,
      builder: (_) => const _FarmInitialPasswordDialog(),
    );
    if (change == null || !context.mounted) return;
    try {
      await ref
          .read(appAuthProvider.notifier)
          .changeFarmInitialPassword(
            FarmInitialPasswordChangeRequest(
              currentPassword: change.currentPassword,
              newPassword: change.newPassword,
            ),
          );
      if (context.mounted) showSnack(context, '农场成员密码已修改');
    } catch (error) {
      if (context.mounted) {
        showSnack(context, friendlyError(error), error: true);
      }
    }
  }

  Future<void> _register(BuildContext context, WidgetRef ref) async {
    final payload = await showDialog<_AppRegisterPayload>(
      context: context,
      builder: (_) => _AppRegisterDialog(
        loadPolicy: ref.read(appAuthProvider.notifier).fetchAccountPolicy,
      ),
    );
    if (payload == null || !context.mounted) return;
    try {
      final result = await ref
          .read(appAuthProvider.notifier)
          .register(
            AppRegisterRequest(
              email: payload.email,
              handle: payload.handle,
              displayName: payload.displayName,
              password: payload.password,
              acceptTerms: payload.acceptTerms,
            ),
          );
      if (context.mounted) {
        final message = result.verificationRequired
            ? result.verificationEmailSent
                  ? '账号已创建，邮箱验证码已发送'
                  : '账号已创建，但验证码发送失败；请点击“验证邮箱”重新发送'
            : 'sohun 账号已创建并登录';
        showSnack(
          context,
          message,
          error: result.verificationRequired && !result.verificationEmailSent,
        );
      }
    } catch (error) {
      if (context.mounted) {
        showSnack(context, friendlyError(error), error: true);
      }
    }
  }

  Future<void> _applyForFarmOwner(BuildContext context, WidgetRef ref) async {
    try {
      final auth = ref.read(appAuthProvider);
      if (!auth.isSignedIn || auth.session?.authRealm == 'farm_staff') {
        throw const StudioCloudException('请先登录普通 sohun 软件账号');
      }
      if (auth.user?.emailVerified != true) {
        throw const StudioCloudException('请先验证软件账号邮箱，再开通管理员身份');
      }
      await ref.read(studioCloudServiceProvider).registerFarmOrganization();
      await ref.read(studioModeEnabledProvider.notifier).setEnabled(true);
      if (context.mounted) {
        showSnack(context, '申请已创建，请继续填写农场主体资料');
        await _showFarmOnboardingDialog(context, ref);
      }
    } catch (error) {
      if (context.mounted) {
        showSnack(context, friendlyError(error), error: true);
      }
    }
  }

  Future<void> _registerFarmOwner(BuildContext context, WidgetRef ref) async {
    final payload = await showDialog<_AppRegisterPayload>(
      context: context,
      builder: (_) => _AppRegisterDialog(
        loadPolicy: ref.read(appAuthProvider.notifier).fetchAccountPolicy,
      ),
    );
    if (payload == null || !context.mounted) return;
    try {
      final result = await ref
          .read(appAuthProvider.notifier)
          .register(
            AppRegisterRequest(
              email: payload.email,
              handle: payload.handle,
              displayName: payload.displayName,
              password: payload.password,
              acceptTerms: payload.acceptTerms,
            ),
          );
      await ref.read(studioCloudServiceProvider).registerFarmOrganization();
      await ref.read(studioModeEnabledProvider.notifier).setEnabled(true);
      if (result.verificationRequired) {
        if (context.mounted) {
          showSnack(context, '软件账号和农场申请已创建，请先完成邮箱验证');
        }
        return;
      }
      if (context.mounted) {
        showSnack(context, '软件账号和农场申请已创建，请继续填写农场资料');
        await _showFarmOnboardingDialog(context, ref);
      }
    } catch (error) {
      if (context.mounted) {
        showSnack(context, friendlyError(error), error: true);
      }
    }
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(appAuthProvider.notifier).logout();
      if (context.mounted) showSnack(context, '已退出 sohun 账号');
    } catch (error) {
      if (context.mounted) {
        showSnack(context, '本机会话已清除；${friendlyError(error)}', error: true);
      }
    }
  }

  Future<void> _editProfile(BuildContext context, WidgetRef ref) async {
    final current = ref.read(appAuthProvider).user;
    if (current == null) return;
    final payload = await showDialog<_ProfileEditPayload>(
      context: context,
      builder: (_) => _ProfileEditDialog(user: current),
    );
    if (payload == null || !context.mounted) return;
    try {
      await ref
          .read(appAuthProvider.notifier)
          .updateCurrentUser(
            AppUserUpdateRequest(
              handle: payload.handle,
              displayName: payload.displayName,
              avatarUrl: payload.avatarUrl,
              bio: payload.bio,
            ),
          );
      if (context.mounted) showSnack(context, '账号资料已更新');
    } catch (error) {
      if (context.mounted) {
        showSnack(context, friendlyError(error), error: true);
      }
    }
  }

  Future<void> _verifyEmail(BuildContext context, WidgetRef ref) async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) => _EmailVerificationDialog(
        onResend: ref.read(appAuthProvider.notifier).requestEmailVerification,
      ),
    );
    if (code == null || !context.mounted) return;
    try {
      await ref.read(appAuthProvider.notifier).confirmEmailVerification(code);
      if (context.mounted) showSnack(context, '邮箱验证成功');
    } catch (error) {
      if (context.mounted) {
        showSnack(context, friendlyError(error), error: true);
      }
    }
  }

  Future<void> _resetPassword(BuildContext context, WidgetRef ref) async {
    final email = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordResetEmailDialog(),
    );
    if (email == null || !context.mounted) return;
    try {
      await ref.read(appAuthProvider.notifier).requestPasswordReset(email);
      if (!context.mounted) return;
      showSnack(context, '如果该邮箱已注册，验证码已发送');
      final confirmation = await showDialog<_PasswordResetConfirmationPayload>(
        context: context,
        builder: (_) => _PasswordResetConfirmationDialog(email: email),
      );
      if (confirmation == null || !context.mounted) return;
      await ref
          .read(appAuthProvider.notifier)
          .confirmPasswordReset(
            email: email,
            code: confirmation.code,
            newPassword: confirmation.newPassword,
          );
      if (context.mounted) showSnack(context, '密码已重置，请使用新密码登录');
    } catch (error) {
      if (context.mounted) {
        showSnack(context, friendlyError(error), error: true);
      }
    }
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _DeleteAccountDialog(),
    );
    if (password == null || !context.mounted) return;
    try {
      await ref.read(appAuthProvider.notifier).deleteAccount(password);
      if (context.mounted) showSnack(context, 'sohun 账号及在线关联数据已注销');
    } catch (error) {
      if (context.mounted) {
        showSnack(context, friendlyError(error), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = ref.watch(appAuthProvider);
    final user = auth.user;
    final avatarUri = parsePublicHttpsImageUrl(
      user?.avatarUrl,
      trustedOrigin: auth.endpoint,
    );
    final primaryText = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final secondaryText = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.badge_outlined,
          title: 'sohun 账号',
          subtitle: '个人工作台与农场账号使用独立入口；同一农场的管理员和成员数据互通',
        ),
        const SizedBox(height: 14),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: user == null
                        ? Icon(
                            Icons.person_outline_rounded,
                            color: AppColors.primary,
                          )
                        : avatarUri != null
                        ? ClipOval(
                            child: Image.network(
                              avatarUri.toString(),
                              width: 44,
                              height: 44,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Text(
                                user.displayName.isEmpty
                                    ? '?'
                                    : String.fromCharCode(
                                        user.displayName.runes.first,
                                      ),
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          )
                        : Text(
                            user.displayName.isEmpty
                                ? '?'
                                : String.fromCharCode(
                                    user.displayName.runes.first,
                                  ),
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.displayName ?? 'sohun 云',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: primaryText,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          user == null
                              ? auth.status == AppAuthStatus.initializing
                                    ? '正在建立安全连接…'
                                    : '登录后在不同设备间保持参数与收藏一致'
                              : auth.session?.authRealm == 'farm_staff'
                              ? '${auth.session?.farmOrganizationName ?? '打印农场'} · ${auth.session?.farmStaffLoginName ?? user.displayName}'
                              : '@${user.handle} · ${user.email}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: secondaryText, fontSize: 11),
                        ),
                        if (user?.bio?.isNotEmpty == true) ...[
                          const SizedBox(height: 3),
                          Text(
                            user!.bio!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: secondaryText,
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (user != null)
                    _Tag(
                      text: user.emailVerified ? '已连接' : '待验证',
                      color: user.emailVerified
                          ? AppColors.primary
                          : AppColors.warning,
                      bg: user.emailVerified
                          ? AppColors.primaryContainer
                          : AppColors.warning.withValues(alpha: 0.12),
                    ),
                  if (user == null)
                    _Tag(
                      text: auth.status == AppAuthStatus.initializing
                          ? '连接中'
                          : auth.status == AppAuthStatus.error
                          ? '需重试'
                          : '未登录',
                      color: auth.status == AppAuthStatus.error
                          ? AppColors.warning
                          : secondaryText,
                      bg: auth.status == AppAuthStatus.error
                          ? AppColors.warning.withValues(alpha: 0.12)
                          : (isDark
                                ? AppColors.surfaceVariantDark
                                : AppColors.surfaceVariant),
                    ),
                ],
              ),
              if (auth.errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  auth.errorMessage!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.danger, fontSize: 11),
                ),
              ],
              const SizedBox(height: 12),
              if (auth.status == AppAuthStatus.initializing)
                const LinearProgressIndicator(minHeight: 3)
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (user == null) ...[
                      AppButton(
                        label: auth.isBusy ? '登录中' : '个人账号登录',
                        icon: const Icon(Icons.login_rounded, size: 16),
                        onPressed: auth.isBusy
                            ? null
                            : () => _login(context, ref),
                      ),
                      AppButton(
                        label: '农场成员登录',
                        icon: const Icon(Icons.factory_outlined, size: 16),
                        variant: AppButtonVariant.secondary,
                        onPressed: auth.isBusy
                            ? null
                            : () => _loginFarmStaff(context, ref),
                      ),
                      AppButton(
                        label: '个人注册',
                        icon: const Icon(
                          Icons.person_add_alt_outlined,
                          size: 16,
                        ),
                        variant: AppButtonVariant.secondary,
                        onPressed: auth.isBusy
                            ? null
                            : () => _register(context, ref),
                      ),
                      AppButton(
                        label: '开通农场管理员账号',
                        icon: const Icon(Icons.add_business_outlined, size: 16),
                        variant: AppButtonVariant.secondary,
                        onPressed: auth.isBusy
                            ? null
                            : () => _registerFarmOwner(context, ref),
                      ),
                      AppButton(
                        label: '找回密码',
                        icon: const Icon(Icons.key_outlined, size: 16),
                        variant: AppButtonVariant.ghost,
                        onPressed: auth.isBusy
                            ? null
                            : () => _resetPassword(context, ref),
                      ),
                    ],
                    if (user != null) ...[
                      if (auth.session?.authRealm != 'farm_staff')
                        AppButton(
                          label: '编辑资料',
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          onPressed: auth.isBusy
                              ? null
                              : () => _editProfile(context, ref),
                        ),
                      if (auth.session?.authRealm != 'farm_staff' &&
                          !user.emailVerified)
                        AppButton(
                          label: '验证邮箱',
                          icon: const Icon(
                            Icons.mark_email_unread_outlined,
                            size: 16,
                          ),
                          onPressed: auth.isBusy
                              ? null
                              : () => _verifyEmail(context, ref),
                        ),
                      if (auth.session?.authRealm != 'farm_staff')
                        AppButton(
                          label: '开通管理员身份',
                          icon: const Icon(
                            Icons.add_business_outlined,
                            size: 16,
                          ),
                          variant: AppButtonVariant.secondary,
                          onPressed: auth.isBusy || !user.emailVerified
                              ? null
                              : () => _applyForFarmOwner(context, ref),
                        ),
                      if (auth.session?.authRealm != 'farm_staff')
                        AppButton(
                          label: '刷新资料',
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          variant: AppButtonVariant.secondary,
                          onPressed: auth.isBusy
                              ? null
                              : () async {
                                  try {
                                    final notifier = ref.read(
                                      appAuthProvider.notifier,
                                    );
                                    await notifier.refreshCurrentUser();
                                    if (context.mounted) {
                                      showSnack(context, '账号资料已刷新');
                                    }
                                  } catch (error) {
                                    if (context.mounted) {
                                      showSnack(
                                        context,
                                        friendlyError(error),
                                        error: true,
                                      );
                                    }
                                  }
                                },
                        ),
                      if (auth.session?.authRealm == 'farm_staff')
                        AppButton(
                          label: auth.session?.mustChangePassword == true
                              ? '修改初始密码'
                              : '修改密码',
                          icon: const Icon(Icons.password_outlined, size: 16),
                          onPressed: auth.isBusy
                              ? null
                              : () => _changeFarmStaffPassword(context, ref),
                        ),
                      AppButton(
                        label: '退出登录',
                        variant: AppButtonVariant.ghost,
                        onPressed: auth.isBusy
                            ? null
                            : () => _logout(context, ref),
                      ),
                      if (auth.session?.authRealm != 'farm_staff')
                        AppButton(
                          label: '注销账号',
                          icon: const Icon(
                            Icons.person_remove_outlined,
                            size: 16,
                          ),
                          variant: AppButtonVariant.ghost,
                          onPressed: auth.isBusy
                              ? null
                              : () => _deleteAccount(context, ref),
                        ),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfileEditPayload {
  const _ProfileEditPayload({
    required this.handle,
    required this.displayName,
    required this.avatarUrl,
    required this.bio,
  });

  final String handle;
  final String displayName;
  final String avatarUrl;
  final String bio;
}

class _ProfileEditDialog extends StatefulWidget {
  const _ProfileEditDialog({required this.user});

  final AppUser user;

  @override
  State<_ProfileEditDialog> createState() => _ProfileEditDialogState();
}

class _ProfileEditDialogState extends State<_ProfileEditDialog> {
  late final TextEditingController _handle;
  late final TextEditingController _displayName;
  late final TextEditingController _avatarUrl;
  late final TextEditingController _bio;
  String? _error;

  @override
  void initState() {
    super.initState();
    _handle = TextEditingController(text: widget.user.handle);
    _displayName = TextEditingController(text: widget.user.displayName);
    _avatarUrl = TextEditingController(text: widget.user.avatarUrl ?? '');
    _bio = TextEditingController(text: widget.user.bio ?? '');
  }

  @override
  void dispose() {
    _handle.dispose();
    _displayName.dispose();
    _avatarUrl.dispose();
    _bio.dispose();
    super.dispose();
  }

  void _submit() {
    final handle = _handle.text.trim().toLowerCase();
    final displayName = _displayName.text.trim();
    final avatarUrl = _avatarUrl.text.trim();
    final bio = _bio.text.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9_.-]{2,29}$').hasMatch(handle)) {
      setState(() => _error = '用户名须为 3-30 位小写字母、数字、下划线、点或短横线');
      return;
    }
    if (displayName.isEmpty || displayName.length > 40) {
      setState(() => _error = '显示名须为 1-40 个字符');
      return;
    }
    if (avatarUrl.isNotEmpty && !avatarUrl.startsWith('https://')) {
      setState(() => _error = '头像地址必须是 HTTPS 公共图片链接');
      return;
    }
    if (bio.length > 300) {
      setState(() => _error = '个人简介最多 300 个字符');
      return;
    }
    Navigator.of(context).pop(
      _ProfileEditPayload(
        handle: handle,
        displayName: displayName,
        avatarUrl: avatarUrl,
        bio: bio,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑账号资料'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _displayName,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '显示名',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _handle,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '用户名',
                  prefixText: '@ ',
                  helperText: '3-30 位小写字母、数字、下划线、点或短横线',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _avatarUrl,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '头像链接（可选）',
                  hintText: 'https://…',
                  prefixIcon: Icon(Icons.link_rounded),
                  helperText: '需使用云服务允许的 HTTPS 公共图片地址；留空可移除',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _bio,
                maxLength: 300,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '个人简介（可选）',
                  hintText: '介绍一下自己或你的打印方向',
                  prefixIcon: Icon(Icons.notes_rounded),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: AppColors.danger,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.save_outlined, size: 17),
          label: const Text('保存资料'),
        ),
      ],
    );
  }
}

class _AppLoginPayload {
  final String email;
  final String password;

  const _AppLoginPayload(this.email, this.password);
}

class _AppLoginDialog extends StatefulWidget {
  const _AppLoginDialog();

  @override
  State<_AppLoginDialog> createState() => _AppLoginDialogState();
}

class _AppLoginDialogState extends State<_AppLoginDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = '请填写邮箱和密码');
      return;
    }
    Navigator.of(
      context,
    ).pop(_AppLoginPayload(_email.text.trim(), _password.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('登录 sohun 账号'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppInput(
              controller: _email,
              label: '邮箱',
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            AppInput(
              controller: _password,
              label: '密码',
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 17,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('登录')),
      ],
    );
  }
}

class _FarmStaffLoginPayload {
  final String organizationCode;
  final String loginName;
  final String password;

  const _FarmStaffLoginPayload(
    this.organizationCode,
    this.loginName,
    this.password,
  );
}

class _FarmStaffLoginDialog extends StatefulWidget {
  const _FarmStaffLoginDialog();

  @override
  State<_FarmStaffLoginDialog> createState() => _FarmStaffLoginDialogState();
}

class _FarmStaffLoginDialogState extends State<_FarmStaffLoginDialog> {
  final _organizationCode = TextEditingController();
  final _loginName = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _organizationCode.dispose();
    _loginName.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_organizationCode.text.trim().isEmpty ||
        _loginName.text.trim().isEmpty ||
        _password.text.isEmpty) {
      setState(() => _error = '请填写农场编号、成员账号和密码');
      return;
    }
    Navigator.of(context).pop(
      _FarmStaffLoginPayload(
        _organizationCode.text.trim().toUpperCase(),
        _loginName.text.trim().toLowerCase(),
        _password.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('农场成员登录'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '成员账号由管理员创建，不与个人账号混用。',
                style: TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            AppInput(
              controller: _organizationCode,
              label: '农场编号',
              hint: '例如 F12AB34CD56',
            ),
            const SizedBox(height: 12),
            AppInput(
              controller: _loginName,
              label: '成员账号',
              hint: '例如 zhangsan',
            ),
            const SizedBox(height: 12),
            AppInput(
              controller: _password,
              label: '密码',
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 17,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('登录农场')),
      ],
    );
  }
}

class _FarmPasswordChangePayload {
  final String currentPassword;
  final String newPassword;

  const _FarmPasswordChangePayload(this.currentPassword, this.newPassword);
}

class _FarmInitialPasswordDialog extends StatefulWidget {
  const _FarmInitialPasswordDialog({this.currentPassword});

  final String? currentPassword;

  @override
  State<_FarmInitialPasswordDialog> createState() =>
      _FarmInitialPasswordDialogState();
}

class _FarmInitialPasswordDialogState
    extends State<_FarmInitialPasswordDialog> {
  late final TextEditingController _currentPassword;
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentPassword = TextEditingController(text: widget.currentPassword);
  }

  @override
  void dispose() {
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  void _submit() {
    final next = _newPassword.text;
    if (_currentPassword.text.isEmpty || next.isEmpty) {
      setState(() => _error = '请填写当前密码和新密码');
      return;
    }
    if (next != _confirmPassword.text) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }
    if (next.length < 12 ||
        !RegExp(r'[a-z]').hasMatch(next) ||
        !RegExp(r'[A-Z]').hasMatch(next) ||
        !RegExp(r'\d').hasMatch(next) ||
        !RegExp(r'[^A-Za-z0-9]').hasMatch(next)) {
      setState(() => _error = '新密码至少 12 位，并包含大小写字母、数字和符号');
      return;
    }
    Navigator.of(
      context,
    ).pop(_FarmPasswordChangePayload(_currentPassword.text, next));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.currentPassword == null ? '修改成员密码' : '首次登录必须改密'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppInput(
              controller: _currentPassword,
              label: '当前密码',
              obscureText: _obscure,
            ),
            const SizedBox(height: 12),
            AppInput(
              controller: _newPassword,
              label: '新密码',
              obscureText: _obscure,
            ),
            const SizedBox(height: 12),
            AppInput(
              controller: _confirmPassword,
              label: '确认新密码',
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 17,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确认修改')),
      ],
    );
  }
}

class _AppRegisterPayload {
  final String email;
  final String handle;
  final String displayName;
  final String password;
  final bool acceptTerms;

  const _AppRegisterPayload({
    required this.email,
    required this.handle,
    required this.displayName,
    required this.password,
    required this.acceptTerms,
  });
}

class _AppRegisterDialog extends StatefulWidget {
  final Future<AppAccountPolicyDocument> Function(AppAccountPolicyType type)
  loadPolicy;

  const _AppRegisterDialog({required this.loadPolicy});

  @override
  State<_AppRegisterDialog> createState() => _AppRegisterDialogState();
}

class _AppRegisterDialogState extends State<_AppRegisterDialog> {
  final _email = TextEditingController();
  final _handle = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _acceptTerms = false;
  bool _readTerms = false;
  bool _readPrivacy = false;
  bool _obscure = true;
  AppAccountPolicyType? _loadingPolicy;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _handle.dispose();
    _displayName.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  void _submit() {
    if (_email.text.trim().isEmpty ||
        _handle.text.trim().isEmpty ||
        _displayName.text.trim().isEmpty ||
        _password.text.isEmpty) {
      setState(() => _error = '请完整填写注册信息');
      return;
    }
    if (_password.text != _confirmPassword.text) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    if (!_readTerms || !_readPrivacy || !_acceptTerms) {
      setState(() => _error = '请先阅读并同意服务条款和隐私政策');
      return;
    }
    try {
      AppRegisterRequest(
        email: _email.text,
        handle: _handle.text,
        displayName: _displayName.text,
        password: _password.text,
        acceptTerms: _acceptTerms,
      );
    } catch (error) {
      setState(() => _error = friendlyError(error));
      return;
    }
    Navigator.of(context).pop(
      _AppRegisterPayload(
        email: _email.text.trim(),
        handle: _handle.text.trim(),
        displayName: _displayName.text.trim(),
        password: _password.text,
        acceptTerms: _acceptTerms,
      ),
    );
  }

  Future<void> _openPolicy(AppAccountPolicyType type) async {
    setState(() {
      _loadingPolicy = type;
      _error = null;
    });
    try {
      final document = await widget.loadPolicy(type);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('${document.title}（${document.version}）'),
          content: SizedBox(
            width: 680,
            height: 500,
            child: Scrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(right: 12),
                child: SelectableText(
                  document.content,
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
              ),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('已阅读'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      setState(() {
        if (type == AppAccountPolicyType.terms) {
          _readTerms = true;
        } else {
          _readPrivacy = true;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _loadingPolicy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('注册 sohun 账号'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: MediaQuery.sizeOf(context).height - 160,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppInput(
                controller: _email,
                label: '邮箱',
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 10),
              AppInput(controller: _handle, label: '唯一用户名', hint: 'maker_name'),
              const SizedBox(height: 10),
              AppInput(controller: _displayName, label: '显示名称'),
              const SizedBox(height: 10),
              AppInput(
                controller: _password,
                label: '密码',
                hint: '至少 10 位，含大小写字母和数字',
                obscureText: _obscure,
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示密码' : '隐藏密码',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 17,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              AppInput(
                controller: _confirmPassword,
                label: '确认密码',
                obscureText: _obscure,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  '注册时，邮箱、唯一用户名、显示名称和密码会通过 HTTPS 发送至 sohun 云。'
                  '云端仅保存密码哈希，'
                  '不会保存密码明文。登录令牌使用 Windows 加密保护后保存在本机。',
                  style: TextStyle(fontSize: 11, height: 1.45),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _loadingPolicy == null
                          ? () => _openPolicy(AppAccountPolicyType.terms)
                          : null,
                      icon: Icon(
                        _readTerms
                            ? Icons.check_circle_outline
                            : Icons.description_outlined,
                        size: 16,
                      ),
                      label: Text(_readTerms ? '服务条款（已阅读）' : '阅读服务条款'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _loadingPolicy == null
                          ? () => _openPolicy(AppAccountPolicyType.privacy)
                          : null,
                      icon: Icon(
                        _readPrivacy
                            ? Icons.check_circle_outline
                            : Icons.privacy_tip_outlined,
                        size: 16,
                      ),
                      label: Text(_readPrivacy ? '隐私政策（已阅读）' : '阅读隐私政策'),
                    ),
                  ),
                ],
              ),
              if (_loadingPolicy != null) ...[
                const SizedBox(height: 6),
                const LinearProgressIndicator(minHeight: 2),
              ],
              const SizedBox(height: 4),
              CheckboxListTile(
                value: _acceptTerms,
                onChanged: _readTerms && _readPrivacy
                    ? (value) => setState(() => _acceptTerms = value ?? false)
                    : null,
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  '我同意服务条款（${AppAccountAgreement.termsVersion}）与'
                  '隐私政策（${AppAccountAgreement.privacyVersion}）',
                  style: TextStyle(fontSize: 11),
                ),
              ),
              if (_error != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: AppColors.danger,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('注册并登录')),
      ],
    );
  }
}

class _EmailVerificationDialog extends StatefulWidget {
  final Future<void> Function() onResend;

  const _EmailVerificationDialog({required this.onResend});

  @override
  State<_EmailVerificationDialog> createState() =>
      _EmailVerificationDialogState();
}

class _EmailVerificationDialogState extends State<_EmailVerificationDialog> {
  final _code = TextEditingController();
  bool _sending = false;
  String? _message;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _resend() async {
    setState(() {
      _sending = true;
      _message = null;
      _error = null;
    });
    try {
      await widget.onResend();
      if (mounted) setState(() => _message = '新的 8 位验证码已发送');
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _submit() {
    final value = _code.text.trim();
    if (!RegExp(r'^\d{8}$').hasMatch(value)) {
      setState(() => _error = '请输入邮件中的 8 位数字验证码');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('验证邮箱'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '输入发送到注册邮箱的 8 位验证码。验证码 15 分钟内有效。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            AppInput(
              controller: _code,
              label: '邮箱验证码',
              keyboardType: TextInputType.number,
              onSubmitted: (_) => _submit(),
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(
                _message!,
                style: const TextStyle(color: AppColors.success, fontSize: 11),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: AppColors.danger, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : _resend,
          child: Text(_sending ? '发送中…' : '重新发送'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确认验证')),
      ],
    );
  }
}

class _PasswordResetEmailDialog extends StatefulWidget {
  const _PasswordResetEmailDialog();

  @override
  State<_PasswordResetEmailDialog> createState() =>
      _PasswordResetEmailDialogState();
}

class _PasswordResetEmailDialogState extends State<_PasswordResetEmailDialog> {
  final _email = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final request = AppPasswordResetRequest(_email.text);
      Navigator.of(context).pop(request.email);
    } catch (error) {
      setState(() => _error = friendlyError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('找回密码'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '填写注册邮箱。为保护账号隐私，无论邮箱是否存在，sohun 云都会返回相同提示。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            AppInput(
              controller: _email,
              label: '注册邮箱',
              keyboardType: TextInputType.emailAddress,
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: AppColors.danger, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('发送验证码')),
      ],
    );
  }
}

class _PasswordResetConfirmationPayload {
  final String code;
  final String newPassword;

  const _PasswordResetConfirmationPayload(this.code, this.newPassword);
}

class _PasswordResetConfirmationDialog extends StatefulWidget {
  final String email;

  const _PasswordResetConfirmationDialog({required this.email});

  @override
  State<_PasswordResetConfirmationDialog> createState() =>
      _PasswordResetConfirmationDialogState();
}

class _PasswordResetConfirmationDialogState
    extends State<_PasswordResetConfirmationDialog> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  void _submit() {
    if (_password.text != _confirmPassword.text) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }
    try {
      final confirmation = AppPasswordResetConfirmation(
        email: widget.email,
        code: _code.text,
        newPassword: _password.text,
      );
      Navigator.of(context).pop(
        _PasswordResetConfirmationPayload(
          confirmation.code,
          confirmation.newPassword,
        ),
      );
    } catch (error) {
      setState(() => _error = friendlyError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('输入验证码并设置新密码'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppInput(
              controller: _code,
              label: '8 位邮箱验证码',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 10),
            AppInput(
              controller: _password,
              label: '新密码',
              hint: '至少 10 位，含大小写字母和数字',
              obscureText: _obscure,
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 17,
                ),
              ),
            ),
            const SizedBox(height: 10),
            AppInput(
              controller: _confirmPassword,
              label: '确认新密码',
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: AppColors.danger, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('重置密码')),
      ],
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    if (_confirmation.text.trim() != 'DELETE') {
      setState(() => _error = '请输入大写 DELETE 确认注销');
      return;
    }
    try {
      final request = AppAccountDeletionRequest(_password.text);
      Navigator.of(context).pop(request.password);
    } catch (error) {
      setState(() => _error = friendlyError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('永久注销 sohun 账号'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '注销会立即删除在线账号、会话、发布内容、点赞、打印结果和举报记录。'
                '隔离备份会在保留期到期后自动清理，此操作不可撤销。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            AppInput(
              controller: _password,
              label: '当前密码',
              obscureText: _obscure,
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 17,
                ),
              ),
            ),
            const SizedBox(height: 10),
            AppInput(
              controller: _confirmation,
              label: '输入 DELETE 确认',
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: AppColors.danger, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          style: glassButtonStyle(
            context,
            FilledButton.styleFrom(backgroundColor: AppColors.danger),
          ),
          child: const Text('永久注销'),
        ),
      ],
    );
  }
}

/// 小标签（当前 / 默认）。
class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  final Color bg;
  const _Tag({required this.text, required this.color, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 外观分类。
///
/// 主题模式 / 主题色 / 背景动效 / 开机自启。
/// 主题模式通过 [themeModeProvider] 持久化，切换后 MaterialApp 立即生效。
class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeMode = ref.watch(themeModeProvider);
    // P0-7 修复：接入持久化开关，原为空实现 onChanged: (_) {}
    final bgDecoration = ref.watch(bgDecorationEnabledProvider);
    final interactionEffects = ref.watch(interactionEffectsEnabledProvider);
    final autostart = ref.watch(autostartEnabledProvider);
    final closeToTray = ref.watch(closeToTrayProvider);
    // P1 修复：主题色真正生效，原为静态展示/空实现下拉。
    final themeColor = ref.watch(themeColorProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.palette_outlined,
          title: '外观',
          subtitle: '主题模式、主题色与动效',
        ),
        const SizedBox(height: 14),
        _SettingRow(
          label: '主题模式',
          description: '跟随系统 / 浅色 / 深色',
          trailing: _ThemeModeSegmented(
            value: themeMode,
            onChanged: (m) => ref.read(themeModeProvider.notifier).setMode(m),
          ),
        ),
        _Divider(isDark: isDark),
        // P1 修复：主题色下拉真正生效，切换后整棵树立即变色。
        _SettingRow(
          label: '主题色',
          description: '应用强调色',
          trailing: _ThemeColorSelector(
            current: themeColor,
            isDark: isDark,
            onChanged: (def) =>
                ref.read(themeColorProvider.notifier).setColor(def),
          ),
        ),
        _Divider(isDark: isDark),
        _SettingRow(
          label: '背景装饰',
          description: '显示桌面 mesh 光斑装饰',
          trailing: AppSwitch(
            value: bgDecoration,
            onChanged: (v) =>
                ref.read(bgDecorationEnabledProvider.notifier).setEnabled(v),
          ),
        ),
        _Divider(isDark: isDark),
        _SettingRow(
          label: '交互动效',
          description: '卡片悬浮、按钮回弹与页面过渡',
          trailing: AppSwitch(
            value: interactionEffects,
            onChanged: (value) => ref
                .read(interactionEffectsEnabledProvider.notifier)
                .setEnabled(value),
          ),
        ),
        _Divider(isDark: isDark),
        _SettingRow(
          label: '开机自启',
          description: '系统开机时自动启动应用',
          trailing: AppSwitch(
            value: autostart,
            // 写注册表可能被安全软件拦截，失败时必须明确告知，
            // 否则开关只是无声弹回，用户会以为界面坏了
            onChanged: (v) async {
              final ok = await ref
                  .read(autostartEnabledProvider.notifier)
                  .setEnabled(v);
              if (!ok && context.mounted) {
                showSnack(
                  context,
                  '开机自启设置失败：写入系统注册表被拒绝，请尝试以管理员身份运行，或检查安全软件拦截',
                  error: true,
                );
              }
            },
          ),
        ),
        _Divider(isDark: isDark),
        _SettingRow(
          label: '关闭到托盘',
          description: closeToTray
              ? '点击关闭按钮后继续在后台接收打印与耗材提醒'
              : '点击关闭按钮后完全退出 sohun',
          trailing: AppSwitch(
            value: closeToTray,
            onChanged: (value) =>
                ref.read(closeToTrayProvider.notifier).setEnabled(value),
          ),
        ),
      ],
    );
  }
}

/// 主题色选择器（P1 修复：点击弹出色板选择，切换后立即生效）。
class _ThemeColorSelector extends StatelessWidget {
  final ThemeColorDef current;
  final bool isDark;
  final ValueChanged<ThemeColorDef> onChanged;

  const _ThemeColorSelector({
    required this.current,
    required this.isDark,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppColors.radiusMd),
      onTap: () => _showPalette(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isDark
              ? AppColors.surfaceContainerHighDark
              : AppColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppColors.radiusMd),
          border: Border.all(
            color: isDark ? AppColors.outlineDark : AppColors.outline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: current.seed,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: current.seed.withValues(alpha: 0.4),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              current.name,
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 4),
            BambuIcon(
              name: 'drop_down',
              size: 16,
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiary,
              applyColorFilter: true,
            ),
          ],
        ),
      ),
    );
  }

  void _showPalette(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppColors.surfaceDark : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppColors.radiusLg),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        title: Text(
          '选择主题色',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: ThemeColorDef.all.map((def) {
            final selected = def.name == current.name;
            return InkWell(
              borderRadius: BorderRadius.circular(AppColors.radiusMd),
              onTap: () {
                onChanged(def);
                Navigator.pop(ctx);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? def.seed.withValues(alpha: 0.1)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppColors.radiusMd),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: def.seed,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? def.seed
                              : (isDark
                                    ? AppColors.outlineDark
                                    : AppColors.outline),
                          width: selected ? 2 : 1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      def.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: selected
                            ? def.seed
                            : (isDark
                                  ? AppColors.textPrimaryDark
                                  : AppColors.textPrimary),
                      ),
                    ),
                    const Spacer(),
                    if (selected)
                      Icon(Icons.check_rounded, size: 18, color: def.seed),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// 主题模式三段选择器：跟随系统 / 浅色 / 深色。
class _ThemeModeSegmented extends StatelessWidget {
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeModeSegmented({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // IntrinsicWidth：让 AppSegmented 内部的 Expanded 能获得有限宽度约束。
    // 否则 _SettingRow 的 Row → trailing 无宽度约束 → Expanded 报错。
    return IntrinsicWidth(
      child: AppSegmented<ThemeMode>(
        value: value,
        onChanged: onChanged,
        segments: const [
          AppSegment(label: '跟随系统', value: ThemeMode.system),
          AppSegment(label: '浅色', value: ThemeMode.light),
          AppSegment(label: '深色', value: ThemeMode.dark),
        ],
      ),
    );
  }
}

/// macOS 风格设置行：左侧标签+描述，右侧控件。
class _SettingRow extends StatefulWidget {
  final String label;
  final String description;
  final Widget trailing;
  const _SettingRow({
    required this.label,
    required this.description,
    required this.trailing,
  });

  @override
  State<_SettingRow> createState() => _SettingRowState();
}

class _SettingRowState extends State<_SettingRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 150),
        ),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        decoration: BoxDecoration(
          color: _hovering
              ? AppColors.primary.withValues(alpha: isDark ? 0.055 : 0.035)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? AppColors.textPrimaryDark
                          : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.description,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.35,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            widget.trailing,
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  final bool isDark;
  const _Divider({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: isDark ? AppColors.dividerDark : AppColors.divider,
    );
  }
}

/// 切片软件配置区。保留全部 provider 调用与文件指定逻辑。
class _SlicerSection extends ConsumerWidget {
  const _SlicerSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusAsync = ref.watch(activeSlicerStatusProvider);
    final detector = ref.watch(activeSlicerDetectorProvider);
    final overrideExe = ref.watch(slicerExecutableOverrideProvider);
    final overrideOut = ref.watch(slicerOutputOverrideProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.extension_rounded,
          title: '切片软件',
          subtitle: '自动识别安装位置与输出目录',
        ),
        const SizedBox(height: 14),
        statusAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('检测失败：${friendlyError(e)}'),
          data: (status) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StatusRow(
                  label: '当前切片软件',
                  value: detector?.displayName ?? '未选择',
                  isDark: isDark,
                ),
                const SizedBox(height: 8),
                _StatusRow(
                  label: '可执行文件',
                  value:
                      overrideExe ??
                      status?.executablePath ??
                      '未检测到（点击下方按钮手动指定）',
                  ok: (overrideExe ?? status?.executablePath) != null,
                  isDark: isDark,
                ),
                const SizedBox(height: 8),
                _StatusRow(
                  label: '输出目录',
                  value:
                      overrideOut ??
                      status?.outputDirectory ??
                      '未检测到（点击下方按钮手动指定）',
                  ok: (overrideOut ?? status?.outputDirectory) != null,
                  isDark: isDark,
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        label: '指定可执行文件',
                        icon: const Icon(Icons.folder_open_rounded),
                        variant: AppButtonVariant.secondary,
                        onPressed: () => _pickExecutable(context, ref),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: AppButton(
                        label: '指定输出目录',
                        icon: const Icon(Icons.folder_outlined),
                        variant: AppButtonVariant.secondary,
                        onPressed: () => _pickOutputDir(context, ref),
                      ),
                    ),
                  ],
                ),
                if (overrideExe != null || overrideOut != null) ...[
                  const SizedBox(height: 10),
                  AppButton(
                    label: '恢复自动检测',
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    variant: AppButtonVariant.ghost,
                    onPressed: () {
                      ref
                          .read(slicerExecutableOverrideProvider.notifier)
                          .setPath(null);
                      ref
                          .read(slicerOutputOverrideProvider.notifier)
                          .setPath(null);
                    },
                  ),
                ],
                const SizedBox(height: 18),
                _BambuStudioVersionCard(isDark: isDark),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 选择切片软件可执行文件。
  /// 使用系统文件对话框（file_selector），并校验路径确实存在后才写入配置，
  /// 避免把无效路径存进 prefs 导致后续启动切片静默失败。
  Future<void> _pickExecutable(BuildContext context, WidgetRef ref) async {
    const typeGroup = XTypeGroup(label: '可执行文件', extensions: <String>['exe']);
    try {
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      if (file == null) return;
      final path = file.path;
      if (!File(path).existsSync()) {
        if (context.mounted) showSnack(context, '所选文件不存在', error: true);
        return;
      }
      ref.read(slicerExecutableOverrideProvider.notifier).setPath(path);
      if (context.mounted) showSnack(context, '已设置切片软件路径');
    } catch (e) {
      if (context.mounted) {
        showSnack(context, '打开文件选择器失败：${friendlyError(e)}', error: true);
      }
    }
  }

  /// 选择切片软件输出目录（监听 G-code 的目录）。
  Future<void> _pickOutputDir(BuildContext context, WidgetRef ref) async {
    try {
      final dir = await getDirectoryPath(confirmButtonText: '选择此目录');
      if (dir == null) return;
      if (!Directory(dir).existsSync()) {
        if (context.mounted) showSnack(context, '所选目录不存在', error: true);
        return;
      }
      ref.read(slicerOutputOverrideProvider.notifier).setPath(dir);
      if (context.mounted) showSnack(context, '已设置输出目录');
    } catch (e) {
      if (context.mounted) {
        showSnack(context, '打开目录选择器失败：${friendlyError(e)}', error: true);
      }
    }
  }
}

/// BambuStudio 版本号覆盖卡片。
///
/// 上传预设到拓竹云端时需要模拟 BambuStudio 客户端版本号。拓竹更新协议后旧版本号
/// 可能导致 401，此卡片允许用户在不动代码的前提下自改版本号，重启后生效。
class _BambuStudioVersionCard extends StatefulWidget {
  final bool isDark;
  const _BambuStudioVersionCard({required this.isDark});

  @override
  State<_BambuStudioVersionCard> createState() =>
      _BambuStudioVersionCardState();
}

class _BambuStudioVersionCardState extends State<_BambuStudioVersionCard> {
  final _bsController = TextEditingController();
  final _naController = TextEditingController();
  bool _loading = true;
  bool _usingDefault = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _bsController.dispose();
    _naController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bs = await SlicerPrefs.getBambuStudioVersionOverride();
    final na = await SlicerPrefs.getNetworkAgentStudioVersionOverride();
    if (!mounted) return;
    setState(() {
      _bsController.text = bs ?? BambuClientVersion.defaultBambuStudio;
      _naController.text = na ?? BambuClientVersion.defaultNetworkAgentStudio;
      _usingDefault = bs == null && na == null;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final bs = _bsController.text.trim();
    final na = _naController.text.trim();
    final bsValid = bs == BambuClientVersion.defaultBambuStudio ? null : bs;
    final naValid = na == BambuClientVersion.defaultNetworkAgentStudio
        ? null
        : na;
    await SlicerPrefs.setBambuStudioVersionOverride(bsValid);
    await SlicerPrefs.setNetworkAgentStudioVersionOverride(naValid);
    BambuClientVersion.setBambuStudioOverride(bsValid);
    BambuClientVersion.setNetworkAgentStudioOverride(naValid);
    if (!mounted) return;
    setState(() => _usingDefault = bsValid == null && naValid == null);
    showSnack(context, '版本号已保存，已立即生效');
  }

  Future<void> _reset() async {
    await SlicerPrefs.setBambuStudioVersionOverride(null);
    await SlicerPrefs.setNetworkAgentStudioVersionOverride(null);
    BambuClientVersion.setBambuStudioOverride(null);
    BambuClientVersion.setNetworkAgentStudioOverride(null);
    if (!mounted) return;
    setState(() {
      _bsController.text = BambuClientVersion.defaultBambuStudio;
      _naController.text = BambuClientVersion.defaultNetworkAgentStudio;
      _usingDefault = true;
    });
    showSnack(context, '已恢复默认版本号');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return GlassCard(
      level: GlassLevel.l1,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BambuIcon(
                name: 'info',
                size: 18,
                color: AppColors.primary,
                applyColorFilter: true,
              ),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(
                child: Text(
                  'Bambu Studio 版本号',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              if (!_usingDefault)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '已覆盖',
                    style: TextStyle(fontSize: 10, color: AppColors.warning),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '上传预设到拓竹云端时模拟的 Bambu Studio 版本号。'
            '若上传报 401 或协议错误，可改为最新版本号后重试。',
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          _VersionField(
            label: 'X-BBL-Client-Version',
            controller: _bsController,
            hint: BambuClientVersion.defaultBambuStudio,
          ),
          const SizedBox(height: AppSpacing.sm),
          _VersionField(
            label: 'bambu_network_agent',
            controller: _naController,
            hint: BambuClientVersion.defaultNetworkAgentStudio,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: '保存',
                  icon: Builder(
                    builder: (context) => BambuIcon(
                      name: 'save',
                      size: 16,
                      color: GlassButtonsTheme.enabledOf(context)
                          ? IconTheme.of(context).color
                          : AppColors.onPrimary,
                      applyColorFilter: true,
                    ),
                  ),
                  variant: AppButtonVariant.primary,
                  onPressed: _save,
                ),
              ),
              if (!_usingDefault) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: AppButton(
                    label: '恢复默认',
                    icon: BambuIcon(
                      name: 'refresh_normal',
                      size: 16,
                      color: AppColors.primary,
                      applyColorFilter: true,
                    ),
                    variant: AppButtonVariant.ghost,
                    onPressed: _reset,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _VersionField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  const _VersionField({
    required this.label,
    required this.controller,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: AppColors.textSecondary,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: AppColors.textTertiary,
            ),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppColors.radiusSm),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppColors.radiusSm),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppColors.radiusSm),
              borderSide: BorderSide(color: AppColors.primary),
            ),
          ),
        ),
      ],
    );
  }
}

/// 切片文件读取方式切换区。保留 sliceReadModeProvider 调用。
class _SliceReadModeSection extends ConsumerWidget {
  const _SliceReadModeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(sliceReadModeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.file_download_done_outlined,
          title: '切片文件读取方式',
          subtitle: '何时解析切片文件获取克数和 AMS 映射',
        ),
        const SizedBox(height: 14),
        _ModeOption(
          label: '按需解析（推荐）',
          description: '打印开始时按文件名查找切片文件并解析，不持续监视目录，资源占用最低',
          selected: mode == SliceReadMode.onDemand,
          onTap: () => ref
              .read(sliceReadModeProvider.notifier)
              .setMode(SliceReadMode.onDemand),
        ),
        const SizedBox(height: 8),
        _ModeOption(
          label: '持续监视目录',
          description: '实时监听切片输出目录，切片完成即解析缓存，打印开始时零延迟',
          selected: mode == SliceReadMode.watch,
          onTap: () => ref
              .read(sliceReadModeProvider.notifier)
              .setMode(SliceReadMode.watch),
        ),
      ],
    );
  }
}

/// 克数计算模式切换区。保留 printTaskCalculationModeProvider 调用。
class _CalculationModeSection extends ConsumerWidget {
  const _CalculationModeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(printTaskCalculationModeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.calculate_outlined,
          title: '克数计算模式',
          subtitle: '实时消耗克数的估算方式',
        ),
        const SizedBox(height: 14),
        _ModeOption(
          label: '粗略模式',
          description: '按打印机 mc_percent 进度比例估算（适用于所有 G-code）',
          selected: mode == CalculationMode.coarse,
          onTap: () => ref
              .read(printTaskCalculationModeProvider.notifier)
              .set(CalculationMode.coarse),
        ),
        const SizedBox(height: 8),
        _ModeOption(
          label: '精细模式',
          description: '按 G-code 层号查表得出真实挤出量（更准确，需解析整个 G-code）',
          selected: mode == CalculationMode.precise,
          onTap: () => ref
              .read(printTaskCalculationModeProvider.notifier)
              .set(CalculationMode.precise),
        ),
      ],
    );
  }
}

/// 库存卡片详情级别。简洁模式保留核心库存信息，精细模式额外展示
/// 批次、备注等追溯字段；该偏好只影响展示，不改变库存数据。
class _InventoryDetailSection extends ConsumerWidget {
  const _InventoryDetailSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFine = ref.watch(inventoryFineDetailProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.inventory_2_outlined,
          title: '库存详情',
          subtitle: '控制库存卡片显示的追溯字段',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: _SettingRow(
            label: '显示精细库存详情',
            description: isFine ? '库存卡片会显示批次号、备注等追溯信息' : '库存卡片仅显示核心库存信息，界面更紧凑',
            trailing: AppSwitch(
              value: isFine,
              onChanged: (value) => ref
                  .read(inventoryFineDetailProvider.notifier)
                  .setEnabled(value),
            ),
          ),
        ),
      ],
    );
  }
}

/// P1-创新1: 耗材干燥提醒开关区。
///
/// 按材质吸湿性分三档提醒：
/// - 高吸湿（TPU/Nylon/PC/PVA）：3 天未用
/// - 中吸湿（PETG/ABS/ASA）：7 天未用
/// - 低吸湿（PLA 系列）：14 天未用
///
/// 开启后应用启动 30 秒检查一次，之后每 6 小时检查一次。
/// 同一卷耗材 24 小时内只提醒一次。
class _DryingReminderSection extends ConsumerWidget {
  const _DryingReminderSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = ref.watch(dryingReminderEnabledProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.bolt_outlined,
          title: '耗材干燥提醒',
          subtitle: '按材质吸湿性提醒干燥（TPU 3天 / PETG 7天 / PLA 14天）',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              _SettingRow(
                label: '启用干燥提醒',
                description: '耗材超过材质吸湿周期未使用时推送通知',
                trailing: AppSwitch(
                  value: enabled,
                  onChanged: (v) => ref
                      .read(dryingReminderEnabledProvider.notifier)
                      .setEnabled(v),
                ),
              ),
              _Divider(isDark: isDark),
              _SettingRow(
                label: '立即检查',
                description: '手动触发一次干燥检查（忽略 24 小时去重）',
                trailing: _CheckNowButton(isDark: isDark, ref: ref),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "立即检查"按钮
class _CheckNowButton extends StatelessWidget {
  final bool isDark;
  final WidgetRef ref;
  const _CheckNowButton({required this.isDark, required this.ref});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        // 清除去重记录，强制重新检查
        ref.read(dryingReminderServiceProvider).clearNotifiedHistory();
        await ref.read(dryingReminderServiceProvider).checkNow();
        if (context.mounted) {
          showSnack(context, '干燥检查已完成', duration: const Duration(seconds: 2));
        }
      },
      child: Text(
        '检查',
        style: TextStyle(
          fontSize: 12,
          color: AppColors.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 外挂料换色提醒开关区。
///
/// 针对没有 AMS 的用户使用外挂料多色打印场景：
/// - 软件自动识别 G-code 是否含换料指令（T/M600/M620/M400 U1）
/// - 仅在含换料指令的任务中触发提醒，无换料指令 = 用户没启用换色 = 不打扰
/// - AMS 模式自动跳过（AMS 自动换料无需手动提醒）
///
/// **两种提醒**：
/// 1. 预告提醒：接近换色层时 Toast 通知，提前准备目标颜色耗材
/// 2. 即时提醒：打印机暂停换料时弹窗强提醒，显示拓竹风格耗材卷图标（动态颜色）+ 操作步骤
///
/// **自动检测用户是否启用换色**：G-code 无换料指令时即使开关开启也不打扰。
class _ExternalFilamentReminderSection extends ConsumerWidget {
  const _ExternalFilamentReminderSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = ref.watch(externalFilamentColorReminderProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.palette_outlined,
          title: '外挂料换色提醒',
          subtitle: '无 AMS 多色打印时，提前提示下一卷颜色（学习拓竹切片）',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              _SettingRow(
                label: '启用换色提醒',
                description: '外挂料多色打印时，换色前提示目标颜色',
                trailing: AppSwitch(
                  value: enabled,
                  onChanged: (v) => ref
                      .read(externalFilamentColorReminderProvider.notifier)
                      .setEnabled(v),
                ),
              ),
              _Divider(isDark: isDark),
              const _SettingRow(
                label: '工作方式',
                description:
                    '自动识别 G-code 换料指令 · AMS 模式跳过 · 接近换色层 Toast 预告 · 暂停时弹窗强提醒',
                trailing: BambuIcon(
                  name: 'info',
                  size: 18,
                  color: AppColors.textTertiary,
                  applyColorFilter: true,
                ),
              ),
              _Divider(isDark: isDark),
              // 弹窗预览：显示拓竹风格耗材卷图标（多色示例）
              const _SettingRow(
                label: '弹窗预览',
                description: '换色时弹窗会显示耗材卷图标 + HEX 码 + 耗材类型 + 推荐温度',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilamentSpoolIcon(
                      color: Color(0xFFFFD700),
                      size: 20,
                      showCenterHole: false,
                    ),
                    SizedBox(width: AppSpacing.xs),
                    FilamentSpoolIcon(
                      color: Color(0xFF008080),
                      size: 20,
                      showCenterHole: false,
                    ),
                    SizedBox(width: AppSpacing.xs),
                    FilamentSpoolIcon(
                      color: Color(0xFFFF0000),
                      size: 20,
                      showCenterHole: false,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 创新2: 耗材消耗异常检测设置区。
///
/// 开启后，实时扣减和任务结算时会自动检测异常（单次扣减过大/结算远超预估/
/// 偏离历史均值 Z-score），发现异常时通过 Toast 通知 + 错误日志双通道告警。
class _AnomalyDetectionSection extends ConsumerWidget {
  const _AnomalyDetectionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = ref.watch(anomalyDetectionEnabledProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.troubleshoot_outlined,
          title: '耗材消耗异常检测',
          subtitle: '扣减过大 / 远偏离预估 / 偏离历史均值时告警（Z-score）',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              _SettingRow(
                label: '启用异常检测',
                description: '实时扣减与结算时自动检测耗材消耗异常',
                trailing: AppSwitch(
                  value: enabled,
                  onChanged: (v) => ref
                      .read(anomalyDetectionEnabledProvider.notifier)
                      .setEnabled(v),
                ),
              ),
              _Divider(isDark: isDark),
              _SettingRow(
                label: '清除告警去重记录',
                description: '清除已告警记录缓存，允许同卷下次异常再次告警',
                trailing: _ClearAnomalyButton(isDark: isDark, ref: ref),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "清除告警去重记录"按钮
class _ClearAnomalyButton extends StatelessWidget {
  final bool isDark;
  final WidgetRef ref;
  const _ClearAnomalyButton({required this.isDark, required this.ref});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () {
        ref.read(anomalyDetectionServiceProvider).clearAlertedHistory();
        if (context.mounted) {
          showSnack(
            context,
            '已清除异常告警去重记录',
            duration: const Duration(seconds: 2),
          );
        }
      },
      child: Text(
        '清除',
        style: TextStyle(
          fontSize: 12,
          color: AppColors.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 库存预警阈值设置区。
///
/// 6 个可调参数：
/// - 临界剩余克数 / 低库存剩余克数（按总剩余克数判定等级）
/// - 临界天数 / 低库存天数（按预计可用天数判定等级）
/// - 低库存卷阈值（单卷剩余克数低于此值计入 lowRollCount）
/// - 消耗回看天数（计算月均消耗速率的统计窗口）
///
/// 所有值持久化到 SharedPreferences，stockAlertsProvider 读取后实时生效。
class _StockThresholdsSection extends ConsumerStatefulWidget {
  const _StockThresholdsSection();

  @override
  ConsumerState<_StockThresholdsSection> createState() =>
      _StockThresholdsSectionState();
}

class _StockThresholdsSectionState
    extends ConsumerState<_StockThresholdsSection> {
  final _criticalGrams = TextEditingController();
  final _lowGrams = TextEditingController();
  final _criticalDays = TextEditingController();
  final _lowDays = TextEditingController();
  final _lowRollGrams = TextEditingController();
  final _lookbackDays = TextEditingController();
  bool _loaded = false;
  Timer? _saveTimer;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _criticalGrams.dispose();
    _lowGrams.dispose();
    _criticalDays.dispose();
    _lowDays.dispose();
    _lowRollGrams.dispose();
    _lookbackDays.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final t = await StockThresholds.load();
    if (!mounted) return;
    setState(() {
      _criticalGrams.text = t.criticalRemainingGrams.toStringAsFixed(0);
      _lowGrams.text = t.lowRemainingGrams.toStringAsFixed(0);
      _criticalDays.text = t.criticalDaysLeft.toString();
      _lowDays.text = t.lowDaysLeft.toString();
      _lowRollGrams.text = t.lowRollRemainingGrams.toStringAsFixed(0);
      _lookbackDays.text = t.consumptionLookbackDays.toString();
      _loaded = true;
    });
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    final criticalGrams = double.tryParse(_criticalGrams.text);
    final lowGrams = double.tryParse(_lowGrams.text);
    final criticalDays = int.tryParse(_criticalDays.text);
    final lowDays = int.tryParse(_lowDays.text);
    final lowRollGrams = double.tryParse(_lowRollGrams.text);
    final lookbackDays = int.tryParse(_lookbackDays.text);
    String? error;
    if ([
      criticalGrams,
      lowGrams,
      criticalDays,
      lowDays,
      lowRollGrams,
      lookbackDays,
    ].any((value) => value == null)) {
      error = '请输入有效数字';
    } else if (criticalGrams! < 0 ||
        lowGrams! <= 0 ||
        criticalDays! < 0 ||
        lowDays! <= 0 ||
        lowRollGrams! < 0 ||
        lookbackDays! <= 0) {
      error = '阈值必须为非负数，低库存与回看天数必须大于 0';
    } else if (criticalGrams > lowGrams) {
      error = '临界剩余克数不能高于低库存剩余克数';
    } else if (criticalDays > lowDays) {
      error = '临界可用天数不能高于低库存可用天数';
    } else if (lowGrams > 100000 ||
        lowRollGrams > 100000 ||
        lowDays > 3650 ||
        lookbackDays > 3650) {
      error = '克数不能超过 100000，天数不能超过 3650';
    }
    if (mounted) setState(() => _validationError = error);
    if (error != null) return;
    await StockThresholds.save(
      criticalRemainingGrams: criticalGrams,
      lowRemainingGrams: lowGrams,
      criticalDaysLeft: criticalDays,
      lowDaysLeft: lowDays,
      lowRollRemainingGrams: lowRollGrams,
      consumptionLookbackDays: lookbackDays,
    );
    if (mounted) {
      ref.read(stockThresholdsRevisionProvider.notifier).bump();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (!_loaded) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.inventory_2_outlined,
          title: '库存预警阈值',
          subtitle: '自定义临界/低库存的克数与天数阈值（自动保存）',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              _ThresholdRow(
                label: '临界剩余克数',
                description: '单规格总剩余低于此值 → 临界（红）',
                controller: _criticalGrams,
                unit: 'g',
                onChanged: _scheduleSave,
              ),
              _Divider(isDark: isDark),
              _ThresholdRow(
                label: '低库存剩余克数',
                description: '单规格总剩余低于此值 → 低库存（橙）',
                controller: _lowGrams,
                unit: 'g',
                onChanged: _scheduleSave,
              ),
              _Divider(isDark: isDark),
              _ThresholdRow(
                label: '临界可用天数',
                description: '按消耗速率预计剩余天数低于此值 → 临界',
                controller: _criticalDays,
                unit: '天',
                onChanged: _scheduleSave,
              ),
              _Divider(isDark: isDark),
              _ThresholdRow(
                label: '低库存可用天数',
                description: '按消耗速率预计剩余天数低于此值 → 低库存',
                controller: _lowDays,
                unit: '天',
                onChanged: _scheduleSave,
              ),
              _Divider(isDark: isDark),
              _ThresholdRow(
                label: '低库存卷阈值',
                description: '单卷剩余低于此值计入"低库存卷数"',
                controller: _lowRollGrams,
                unit: 'g',
                onChanged: _scheduleSave,
              ),
              _Divider(isDark: isDark),
              _ThresholdRow(
                label: '消耗统计回看天数',
                description: '计算月均消耗速率的统计窗口',
                controller: _lookbackDays,
                unit: '天',
                onChanged: _scheduleSave,
              ),
            ],
          ),
        ),
        if (_validationError != null) ...[
          const SizedBox(height: 8),
          Text(
            _validationError!,
            style: const TextStyle(color: AppColors.danger, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

/// 阈值输入行：左侧标签+描述，右侧带单位的数字输入框。
class _ThresholdRow extends StatelessWidget {
  final String label;
  final String description;
  final TextEditingController controller;
  final String unit;
  final VoidCallback onChanged;

  const _ThresholdRow({
    required this.label,
    required this.description,
    required this.controller,
    required this.unit,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? AppColors.textPrimaryDark
                        : AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
              ],
              onChanged: (_) => onChanged(),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                suffixText: unit,
                suffixStyle: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppColors.radiusSm),
                  borderSide: BorderSide(
                    color: isDark ? AppColors.dividerDark : AppColors.divider,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppColors.radiusSm),
                  borderSide: BorderSide(
                    color: isDark ? AppColors.dividerDark : AppColors.divider,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppColors.radiusSm),
                  borderSide: BorderSide(color: AppColors.primary, width: 1.5),
                ),
                filled: true,
                fillColor: isDark ? AppColors.surfaceDark : AppColors.surface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 批次识别窗口设置区。
///
/// 同一 G-code 发送到多台打印机，在 N 分钟窗口内视为同一批次。
/// 窗口越大越容易把不相关任务误判为同批次，越小越容易漏判。
/// 默认 10 分钟，范围 [1, 60]。
class _BatchRecognitionSection extends StatefulWidget {
  const _BatchRecognitionSection();

  @override
  State<_BatchRecognitionSection> createState() =>
      _BatchRecognitionSectionState();
}

class _BatchRecognitionSectionState extends State<_BatchRecognitionSection> {
  final _windowController = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _windowController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final minutes = await getBatchWindowMinutes();
    if (!mounted) return;
    setState(() {
      _windowController.text = minutes.toString();
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final minutes = int.tryParse(_windowController.text) ?? 10;
    await setBatchWindowMinutes(minutes);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.copy_all_outlined,
          title: '批次识别窗口',
          subtitle: '同一 G-code 在 N 分钟内发到多台打印机视为同批次（自动保存）',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: _ThresholdRow(
            label: '识别窗口时长',
            description: '范围 1~60 分钟，默认 10 分钟。过大会误判，过小会漏判',
            controller: _windowController,
            unit: '分钟',
            onChanged: _save,
          ),
        ),
      ],
    );
  }
}

/// 单选式模式选项卡片。暗色适配。
class _ModeOption extends StatelessWidget {
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  const _ModeOption({
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primaryContainer
                : (isDark
                      ? AppColors.surfaceVariantDark
                      : AppColors.surfaceVariant),
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            border: Border.all(
              color: selected
                  ? AppColors.primary.withValues(alpha: 0.4)
                  : Colors.transparent,
              width: 1.2,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected
                    ? AppColors.primary
                    : (isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary),
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? AppColors.primary
                            : (isDark
                                  ? AppColors.textPrimaryDark
                                  : AppColors.textPrimary),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MaterialSyncSection extends ConsumerWidget {
  const _MaterialSyncSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(rfidAutoAdoptEnabledProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.sync_rounded,
          title: 'AMS 与库存同步',
          subtitle: '控制真实料盘观测如何写回本地库存',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: _SettingRow(
            label: '自动采用 RFID 余量',
            description: '拓竹原装料盘上报有效余量时，自动同步对应库存；第三方耗材不会被覆盖',
            trailing: AppSwitch(
              value: enabled,
              onChanged: (value) => ref
                  .read(rfidAutoAdoptEnabledProvider.notifier)
                  .setEnabled(value),
            ),
          ),
        ),
      ],
    );
  }
}

class _StudioModeSection extends ConsumerWidget {
  const _StudioModeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lockedToFarmProduct = AppVariant.isFarm;
    final enabled = lockedToFarmProduct || ref.watch(studioModeEnabledProvider);
    final isStaff = ref.watch(
      appAuthProvider.select(
        (state) => state.session?.authRealm == 'farm_staff',
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.factory_outlined,
          title: lockedToFarmProduct ? '农场工作台' : '打印农场与工作室模式',
          subtitle: lockedToFarmProduct
              ? '此软件固定使用农场工作台，团队、订单和经营数据与个人版完全隔离'
              : '适合小型打印农场、工作室和多人协作；关闭时不会占用侧栏空间',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              _SettingRow(
                label: lockedToFarmProduct
                    ? '农场软件'
                    : isStaff
                    ? '农场成员模式'
                    : '启用打印农场模式',
                description: lockedToFarmProduct
                    ? '农场版始终停留在农场工作台；个人版的账号、偏好和本地数据不会被读取'
                    : isStaff
                    ? '成员账号固定使用农场工作台，不能进入个人工作台'
                    : enabled
                    ? '侧栏显示农场工作台；个人账号与农场数据使用独立的数据空间'
                    : '隐藏农场工作台并保持个人界面精简；农场组织、成员和业务数据完整保留',
                trailing: AppSwitch(
                  value: enabled,
                  onChanged: lockedToFarmProduct || isStaff
                      ? null
                      : (value) async {
                          await ref
                              .read(studioModeEnabledProvider.notifier)
                              .setEnabled(value);
                          if (!value && ref.read(autoScheduleEnabledProvider)) {
                            await ref
                                .read(autoScheduleEnabledProvider.notifier)
                                .setEnabled(false);
                          }
                        },
                ),
              ),
              _Divider(isDark: isDark),
              _SettingRow(
                label: '农场主体与入驻认证',
                description: '填写负责人、经营主体、设备规模和服务范围；成员账号由管理员统一管理',
                trailing: OutlinedButton.icon(
                  onPressed: enabled
                      ? () => _showFarmOnboardingDialog(context, ref)
                      : null,
                  icon: const Icon(
                    Icons.domain_verification_outlined,
                    size: 17,
                  ),
                  label: const Text('完善资料'),
                ),
              ),
              _Divider(isDark: isDark),
              const _SettingRow(
                label: '本地优先',
                description: '订单、成本和库存先保存在本机；登录云服务后才会同步团队与客户只读页面',
                trailing: Icon(Icons.cloud_done_outlined),
              ),
              _Divider(isDark: isDark),
              const _SettingRow(
                label: '权限边界',
                description: '管理员与成员共享全部农场功能；停用账号后立即停止访问',
                trailing: Icon(Icons.admin_panel_settings_outlined),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _showFarmOnboardingDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  Map<String, dynamic> payload;
  try {
    payload = await ref
        .read(studioCloudServiceProvider)
        .getFarmOrganizationProfile();
  } catch (error) {
    if (context.mounted) {
      showSnack(context, '读取农场入驻资料失败：$error', error: true);
    }
    return;
  }
  if (!context.mounted) return;
  final organization = payload['organization'] is Map
      ? Map<String, dynamic>.from(payload['organization'] as Map)
      : <String, dynamic>{};
  String text(String key) => organization[key]?.toString() ?? '';
  String joined(String key) =>
      organization[key] is List ? (organization[key] as List).join('、') : '';
  final displayName = TextEditingController(text: text('displayName'));
  final legalName = TextEditingController(text: text('legalName'));
  final registrationNumber = TextEditingController(
    text: text('registrationNumber'),
  );
  final contactName = TextEditingController(text: text('contactName'));
  final contactPhone = TextEditingController(text: text('contactPhone'));
  final contactEmail = TextEditingController(text: text('contactEmail'));
  final region = TextEditingController(text: text('region'));
  final businessAddress = TextEditingController(text: text('businessAddress'));
  final serviceArea = TextEditingController(text: text('serviceArea'));
  final printerCount = TextEditingController(
    text: text('printerCount').isEmpty ? '0' : text('printerCount'),
  );
  final staffCount = TextEditingController(
    text: text('staffCount').isEmpty ? '0' : text('staffCount'),
  );
  final locationCount = TextEditingController(
    text: text('locationCount').isEmpty ? '1' : text('locationCount'),
  );
  final printerModels = TextEditingController(text: joined('printerModels'));
  final materials = TextEditingController(text: joined('materials'));
  final orderTypes = TextEditingController(text: joined('orderTypes'));
  var subjectType = text('subjectType').isEmpty
      ? 'unregistered_studio'
      : text('subjectType');
  var invoiceCapability = organization['invoiceCapability'] == true;
  var isSaving = false;
  StateSetter? updateDialog;

  List<String> splitList(String value) => value
      .split(RegExp(r'[,，、\n]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);

  Future<void> save({required bool submit}) async {
    if (isSaving) return;
    updateDialog?.call(() => isSaving = true);
    try {
      await ref.read(studioCloudServiceProvider).saveFarmOrganizationProfile({
        'displayName': displayName.text.trim(),
        'legalName': legalName.text.trim(),
        'subjectType': subjectType,
        'registrationNumber': registrationNumber.text.trim(),
        'contactName': contactName.text.trim(),
        'contactPhone': contactPhone.text.trim(),
        'contactEmail': contactEmail.text.trim(),
        'region': region.text.trim(),
        'businessAddress': businessAddress.text.trim(),
        'serviceArea': serviceArea.text.trim(),
        'printerCount': int.tryParse(printerCount.text.trim()) ?? 0,
        'staffCount': int.tryParse(staffCount.text.trim()) ?? 0,
        'locationCount': int.tryParse(locationCount.text.trim()) ?? 1,
        'printerModels': splitList(printerModels.text),
        'materials': splitList(materials.text),
        'orderTypes': splitList(orderTypes.text),
        'invoiceCapability': invoiceCapability,
      }, submitForVerification: submit);
      if (context.mounted) {
        Navigator.of(context).pop();
        showSnack(context, submit ? '农场资料已提交审核' : '农场资料草稿已保存');
      }
    } catch (error) {
      if (context.mounted) {
        showSnack(context, '${submit ? '提交' : '保存'}失败：$error', error: true);
        updateDialog?.call(() => isSaving = false);
      }
    }
  }

  await AppDialog.show<void>(
    context: context,
    title: '农场主体与入驻认证',
    barrierDismissible: !isSaving,
    content: StatefulBuilder(
      builder: (dialogContext, setState) {
        updateDialog = setState;
        return Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '农场编号：${text('organizationCode')} · 当前状态：${_farmVerificationStatusLabel(text('verificationStatus'))}',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 12),
            AppInput(label: '农场展示名称', controller: displayName),
            const SizedBox(height: 12),
            AppSelect<String>(
              value: subjectType,
              label: '经营主体类型',
              items: const [
                DropdownMenuItem(value: 'company', child: Text('企业')),
                DropdownMenuItem(
                  value: 'sole_proprietor',
                  child: Text('个体工商户'),
                ),
                DropdownMenuItem(value: 'studio', child: Text('工作室')),
                DropdownMenuItem(
                  value: 'individual_operator',
                  child: Text('个人经营者'),
                ),
                DropdownMenuItem(
                  value: 'unregistered_studio',
                  child: Text('未注册工作室'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => subjectType = value);
              },
            ),
            const SizedBox(height: 12),
            AppInput(label: '主体法定名称', controller: legalName),
            const SizedBox(height: 12),
            AppInput(label: '统一社会信用代码 / 登记编号', controller: registrationNumber),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: AppInput(label: '负责人姓名', controller: contactName),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AppInput(label: '负责人电话', controller: contactPhone),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AppInput(label: '负责人邮箱', controller: contactEmail),
            const SizedBox(height: 12),
            AppInput(label: '经营地区', controller: region),
            const SizedBox(height: 12),
            AppInput(label: '经营地址', controller: businessAddress),
            const SizedBox(height: 12),
            AppInput(label: '服务区域', controller: serviceArea),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: AppInput(
                    label: '打印机数量',
                    controller: printerCount,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AppInput(
                    label: '成员数量',
                    controller: staffCount,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AppInput(
                    label: '生产地点',
                    controller: locationCount,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AppInput(label: '主要打印机型号（用顿号分隔）', controller: printerModels),
            const SizedBox(height: 12),
            AppInput(label: '主要材料（用顿号分隔）', controller: materials),
            const SizedBox(height: 12),
            AppInput(label: '主要接单类型（用顿号分隔）', controller: orderTypes),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('支持开票'),
              value: invoiceCapability,
              onChanged: (value) => setState(() => invoiceCapability = value),
            ),
            const Text(
              '银行、结算和身份证明等敏感资料会在启用收款或公开接单时按需补充，不在首次入驻无差别收集。',
              style: TextStyle(fontSize: 11),
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
      TextButton(
        onPressed: () => save(submit: false),
        child: const Text('保存草稿'),
      ),
      FilledButton(
        onPressed: () => save(submit: true),
        child: const Text('提交审核'),
      ),
    ],
  );

  for (final controller in [
    displayName,
    legalName,
    registrationNumber,
    contactName,
    contactPhone,
    contactEmail,
    region,
    businessAddress,
    serviceArea,
    printerCount,
    staffCount,
    locationCount,
    printerModels,
    materials,
    orderTypes,
  ]) {
    controller.dispose();
  }
}

String _farmVerificationStatusLabel(String status) => switch (status) {
  'draft' => '草稿',
  'pending_submission' => '待重新提交',
  'under_review' => '审核中',
  'needs_information' => '需要补充资料',
  'verified' => '已认证',
  'rejected' => '未通过',
  'suspended' => '已暂停',
  _ => '未开始',
};

class _AutomationPreferencesSection extends ConsumerWidget {
  const _AutomationPreferencesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final autoSchedule = ref.watch(autoScheduleEnabledProvider);
    final experimentAutoEnqueue = ref.watch(
      experimentAutoEnqueueEnabledProvider,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.auto_awesome_motion_outlined,
          title: '自动化规则',
          subtitle: '让调度和参数实验自动进入下一步，同时保留人工关闭权',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              _SettingRow(
                label: '自动调度',
                description: '待分配任务出现时，根据设备状态、材料和队列负载自动选择打印机',
                trailing: AppSwitch(
                  value: autoSchedule,
                  onChanged: (value) => ref
                      .read(autoScheduleEnabledProvider.notifier)
                      .setEnabled(value),
                ),
              ),
              _Divider(isDark: isDark),
              _SettingRow(
                label: '实验结果自动入队',
                description: '参数实验草案确认后自动加入打印队列；默认关闭，避免误打印',
                trailing: AppSwitch(
                  value: experimentAutoEnqueue,
                  onChanged: (value) => ref
                      .read(experimentAutoEnqueueEnabledProvider.notifier)
                      .setEnabled(value),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NotificationPreferencesSection extends ConsumerWidget {
  const _NotificationPreferencesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = ref.watch(notificationsEnabledProvider);
    final printEnabled = ref.watch(printNotificationsEnabledProvider);
    final materialEnabled = ref.watch(materialNotificationsEnabledProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.notifications_none_rounded,
          title: '通知',
          subtitle: '只保留真正需要离开软件也能看到的消息',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              _SettingRow(
                label: '系统通知',
                description: enabled ? '允许 sohun 发送 Windows 通知' : '所有系统通知已暂停',
                trailing: AppSwitch(
                  value: enabled,
                  onChanged: (value) => ref
                      .read(notificationsEnabledProvider.notifier)
                      .setEnabled(value),
                ),
              ),
              _Divider(isDark: isDark),
              _SettingRow(
                label: '打印任务',
                description: '打印机故障、打印完成、失败、离线及无人值守阻塞',
                trailing: AppSwitch(
                  value: printEnabled,
                  onChanged: enabled
                      ? (value) => ref
                            .read(printNotificationsEnabledProvider.notifier)
                            .setEnabled(value)
                      : null,
                ),
              ),
              _Divider(isDark: isDark),
              _SettingRow(
                label: '耗材与库存',
                description: '低库存、AMS 变化、干燥、换色及消耗异常',
                trailing: AppSwitch(
                  value: materialEnabled,
                  onChanged: enabled
                      ? (value) => ref
                            .read(materialNotificationsEnabledProvider.notifier)
                            .setEnabled(value)
                      : null,
                ),
              ),
              _Divider(isDark: isDark),
              _SettingRow(
                label: '打印机故障弹窗',
                description: '新故障主动提示；关闭后仍在故障中心保留记录',
                trailing: AppSwitch(
                  value: ref.watch(printerFaultPopupsEnabledProvider),
                  onChanged: (value) => ref
                      .read(printerFaultPopupsEnabledProvider.notifier)
                      .setEnabled(value),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '工作台中的低频气泡提醒不属于系统通知，仍会在需要时显示。',
          style: AppTypography.label.copyWith(
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
        ),
      ],
    );
  }
}

class _CloudSharingSection extends ConsumerWidget {
  const _CloudSharingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(communityShareEnabledProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.ios_share_rounded,
          title: '社区结果分享',
          subtitle: '决定打印结果是否参与参数广场的可信度统计',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: _SettingRow(
            label: '分享脱敏打印结果',
            description: '默认关闭；开启后仅上传材料、参数指纹和结果评分，不上传设备序列号、路径或备注',
            trailing: AppSwitch(
              value: enabled,
              onChanged: (value) => ref
                  .read(communityShareEnabledProvider.notifier)
                  .setEnabled(value),
            ),
          ),
        ),
      ],
    );
  }
}

/// 账号管理入口。
///
/// 显示当前登录账号 + 多账号徽章，点击"管理账号"打开账号管理面板。
/// 未登录时显示"添加账号"按钮（打开云登录弹窗）。
class _AccountManagementEntry extends ConsumerWidget {
  const _AccountManagementEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accountState = ref.watch(bambuAccountManagerProvider);
    final cloudState = ref.watch(bambuCloudProvider);
    final isLoggedIn = cloudState.isLoggedIn;
    final session = cloudState.session;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.manage_accounts_outlined,
          title: '账号管理',
          subtitle: accountState.hasMultipleAccounts
              ? '已添加 ${accountState.accounts.length} 个账号，可切换与管理'
              : '管理拓竹云账号',
        ),
        const SizedBox(height: 12),
        if (isLoggedIn && session != null)
          GlassCard(
            level: GlassLevel.l1,
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(
                  Icons.cloud_done_rounded,
                  color: AppColors.success,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              session.email,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? AppColors.textPrimaryDark
                                    : AppColors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (accountState.hasMultipleAccounts) ...[
                            const SizedBox(width: 6),
                            _Tag(
                              text: '+${accountState.accounts.length - 1}',
                              color: AppColors.primary,
                              bg: AppColors.primaryContainer,
                            ),
                          ],
                        ],
                      ),
                      if (accountState.hasMultipleAccounts) ...[
                        const SizedBox(height: 2),
                        Text(
                          '共 ${accountState.accounts.length} 个账号，点击管理可切换',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark
                                ? AppColors.textTertiaryDark
                                : AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                AppButton(
                  label: '管理账号',
                  variant: AppButtonVariant.secondary,
                  onPressed: () => AccountManagerScreen.show(context),
                ),
              ],
            ),
          )
        else
          AppButton(
            label: '添加账号',
            icon: const Icon(Icons.add_rounded, size: 16),
            variant: AppButtonVariant.primary,
            onPressed: () => CloudLoginDialog.show(context),
          ),
      ],
    );
  }
}

/// 打印队列 / 批次识别 / 无人值守模式设置区。
///
/// - 批次识别开关：多台打印机同文件名任务合并为同一批次（10 分钟窗口）。
/// - 打印队列开关：按队列顺序自动发送多个 G-code 任务到打印机。
/// - 无人值守模式开关：仅在队列开关开启时显示。打完跳过取件确认直接发下一个，
///   前提是 G-code 尾部脚本含自动清件动作（挤出机推件），否则喷嘴会撞到上一件。
///
/// 三个开关都持久化保存，重启应用后继续保持用户选择。
/// 开启无人值守模式前弹 AlertDialog 警告，用户确认后才真正开启。
class _PrintQueueSettingsSection extends ConsumerStatefulWidget {
  const _PrintQueueSettingsSection();

  @override
  ConsumerState<_PrintQueueSettingsSection> createState() =>
      _PrintQueueSettingsSectionState();
}

class _PrintQueueSettingsSectionState
    extends ConsumerState<_PrintQueueSettingsSection> {
  Future<void> _setQueue(bool value) async {
    await ref.read(printQueueEnabledProvider.notifier).setEnabled(value);
    // 关闭队列时同步关闭无人值守模式，避免遗留危险状态。
    if (!value && ref.read(unattendedModeProvider)) {
      await ref.read(unattendedModeProvider.notifier).setEnabled(false);
    }
  }

  Future<void> _confirmUnattended(BuildContext context, bool value) async {
    if (!value) {
      // 关闭无需警告
      await ref.read(unattendedModeProvider.notifier).setEnabled(false);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开启无人值守模式'),
        content: const Text(
          '无人值守模式会跳过取件确认，打完直接发下一个。\n\n'
          '软件会自动识别 G-code 尾部是否含自动清件脚本（挤出机推件），'
          '未识别到的任务会阻塞并提醒你手动标记或跳过，避免喷嘴撞件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: glassButtonStyle(
              ctx,
              TextButton.styleFrom(foregroundColor: AppColors.danger),
              variant: AppGlassButtonVariant.quiet,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('我已了解，开启'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(unattendedModeProvider.notifier).setEnabled(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unattended = ref.watch(unattendedModeProvider);
    final queueEnabled = ref.watch(printQueueEnabledProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.playlist_play_rounded,
          title: '打印队列',
          subtitle: '连续任务与无人值守安全策略',
        ),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              _SettingRow(
                label: '打印队列',
                description: '按顺序自动打印多个任务（队首发完后等待取件）',
                trailing: AppSwitch(value: queueEnabled, onChanged: _setQueue),
              ),
              if (queueEnabled) ...[
                _Divider(isDark: isDark),
                _SettingRow(
                  label: '无人值守模式',
                  description: '打完自动开始下一个，跳过取件确认（需 G-code 含自动清件）',
                  trailing: AppSwitch(
                    value: unattended,
                    onChanged: (v) => _confirmUnattended(context, v),
                  ),
                ),
                if (unattended) ...[
                  _Divider(isDark: isDark),
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warningContainer,
                      borderRadius: BorderRadius.circular(AppColors.radiusSm),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        BambuIcon(
                          name: 'warning',
                          size: 14,
                          color: AppColors.warning,
                          applyColorFilter: true,
                        ),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '无人值守模式已开启：每个 G-code 入队时会自动识别尾部是否含自动清件脚本，'
                            '未识别到的队首不会自动发送，会提醒你手动标记或跳过，避免喷嘴撞件。',
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.5,
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 打印机 LAN 连接配置区。保留全部 LAN 增删/激活逻辑。
class _PrinterConnectionSection extends ConsumerStatefulWidget {
  const _PrinterConnectionSection();

  @override
  ConsumerState<_PrinterConnectionSection> createState() =>
      _PrinterConnectionSectionState();
}

class _PrinterConnectionSectionState
    extends ConsumerState<_PrinterConnectionSection> {
  bool _scanning = false;
  String _scanStatus = '';
  LanScanCancellationToken? _scanToken;

  static final List<PrinterPreset> _bambuModels = PrinterPresets.all
      .where((preset) => preset.brand == '拓竹')
      .toList(growable: false);

  @override
  void dispose() {
    _scanToken?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final connections = ref.watch(printerConnectionListProvider);
    final loadError = ref.watch(printerConnectionLoadErrorProvider);
    final activeSerial = ref.watch(activePrinterSerialProvider);
    final activeConfig = ref.watch(activePrinterConfigProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            BambuIcon(
              name: 'printer',
              size: 18,
              color: AppColors.primary,
              applyColorFilter: true,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '打印机 LAN 连接',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
            ),
            AppButton(
              label: _scanning ? '扫描中' : '扫描局域网',
              icon: _scanning
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 16),
              variant: AppButtonVariant.secondary,
              onPressed: _scanning ? null : () => _scanLan(context, ref),
            ),
            const SizedBox(width: AppSpacing.sm),
            AppButton(
              label: '添加',
              icon: const Icon(Icons.add_rounded, size: 16),
              variant: AppButtonVariant.primary,
              onPressed: () => _showAddDialog(context, ref),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _scanning
              ? (_scanStatus.isEmpty ? '正在扫描局域网中的拓竹打印机…' : _scanStatus)
              : '通过 LAN 直连拓竹打印机（需 IP + Access Code）',
          style: TextStyle(
            fontSize: 11,
            color: isDark
                ? AppColors.textSecondaryDark
                : AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (loadError != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.dangerContainer,
              borderRadius: BorderRadius.circular(AppColors.radiusSm),
              border: Border.all(
                color: AppColors.danger.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: AppColors.danger,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    loadError,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: AppColors.danger,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭提示',
                  onPressed: () =>
                      ref
                              .read(printerConnectionLoadErrorProvider.notifier)
                              .state =
                          null,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: AppColors.danger,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (connections.isEmpty)
          const EmptyState(
            bambuIconName: 'printer',
            useGlass: true,
            title: '还没有添加打印机连接',
            subtitle: '通过 LAN 直连拓竹打印机（需 IP + Access Code）',
          )
        else
          for (final c in connections) ...[
            _ConnectionTile(
              config: c,
              isActive:
                  c.serial == activeSerial &&
                  activeConfig?.mode == BambuConnectionMode.lan,
              onTap: () {
                unawaited(
                  ref
                      .read(printerConnectionModeSelectionProvider.notifier)
                      .select(c.serial, BambuConnectionMode.lan),
                );
                ref
                    .read(activePrinterSerialProvider.notifier)
                    .set(
                      c.serial == activeSerial &&
                              activeConfig?.mode == BambuConnectionMode.lan
                          ? null
                          : c.serial,
                    );
              },
              // 删除连接会丢失用户手抄的 Access Code，需二次确认（与本文件
              // 删除用户 / 删除备份的交互保持一致）
              onDelete: () async {
                final ok = await AppDialog.confirm(
                  context,
                  '删除打印机连接',
                  '将删除「${c.serial}」的 LAN 连接配置，包括已保存的 IP 与 Access Code。\n\n'
                      '删除后需要重新到打印机屏幕上查看 Access Code 才能再次添加。',
                  confirmText: '删除',
                  destructive: true,
                );
                if (!ok) return;
                ref
                    .read(printerConnectionListProvider.notifier)
                    .remove(c.serial);
                if (c.serial == activeSerial &&
                    activeConfig?.mode == BambuConnectionMode.lan) {
                  ref.read(activePrinterSerialProvider.notifier).set(null);
                }
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        const SizedBox(height: AppSpacing.sm),
        Text(
          '提示：电脑和打印机在同一局域网时用 LAN 直连更快；\n不在同一网络时请用上方「拓竹云连接」远程读取。',
          style: TextStyle(
            fontSize: 10,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  Future<void> _scanLan(BuildContext context, WidgetRef ref) async {
    final token = LanScanCancellationToken();
    _scanToken = token;
    setState(() {
      _scanning = true;
      _scanStatus = '正在发现打印机…';
    });
    try {
      final printers = await BambuLanDiscovery.discover(
        forceRefresh: true,
        cancellationToken: token,
        onProgress: (phase, progress, total) {
          if (!mounted || token.isCancelled) return;
          setState(() {
            _scanStatus = total > 0 ? '$phase · $progress/$total' : phase;
          });
        },
      );
      if (!context.mounted || token.isCancelled) return;
      await _showScanResults(context, ref, printers);
    } catch (error) {
      if (context.mounted) {
        showSnack(context, '局域网扫描失败：${friendlyError(error)}', error: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
          _scanStatus = '';
        });
      }
      if (identical(_scanToken, token)) _scanToken = null;
    }
  }

  Future<void> _showScanResults(
    BuildContext context,
    WidgetRef ref,
    List<DiscoveredBambuPrinter> printers,
  ) async {
    final configured = ref.read(printerConnectionListProvider);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('局域网打印机'),
        content: SizedBox(
          width: 520,
          child: printers.isEmpty
              ? const EmptyState(
                  bambuIconName: 'printer',
                  title: '没有发现打印机',
                  subtitle: '请确认电脑与打印机在同一网络，并已开启局域网访问模式。',
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: printers.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final printer = printers[index];
                    final existing = configured.any(
                      (config) =>
                          config.host == printer.ip ||
                          (printer.serial != null &&
                              config.serial == printer.serial),
                    );
                    final model = _inferModel(printer);
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: BambuIcon(
                        name: 'printer',
                        size: 22,
                        color: AppColors.primary,
                        applyColorFilter: true,
                      ),
                      title: Text(
                        printer.deviceName.isNotEmpty
                            ? printer.deviceName
                            : (model ?? printer.instanceName),
                      ),
                      subtitle: Text(
                        '${printer.ip}:${printer.port}'
                        '${printer.serial == null ? ' · 需补充序列号' : ' · ${printer.serial}'}',
                      ),
                      trailing: existing
                          ? const Text('已添加')
                          : FilledButton(
                              onPressed: () {
                                Navigator.of(dialogContext).pop();
                                _showAddDialog(
                                  context,
                                  ref,
                                  discovered: printer,
                                );
                              },
                              child: const Text('添加'),
                            ),
                    );
                  },
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

  Future<void> _showAddDialog(
    BuildContext context,
    WidgetRef ref, {
    DiscoveredBambuPrinter? discovered,
  }) async {
    final serialCtrl = TextEditingController(text: discovered?.serial ?? '');
    final hostCtrl = TextEditingController(text: discovered?.ip ?? '');
    final accessCtrl = TextEditingController();
    final nameCtrl = TextEditingController(text: discovered?.deviceName ?? '');
    String? selectedModel = discovered == null ? null : _inferModel(discovered);
    double selectedNozzleDiameter = 0.4;
    try {
      final isDark = Theme.of(context).brightness == Brightness.dark;

      final result = await showDialog<PrinterConnectionConfig>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text(discovered == null ? '添加拓竹打印机' : '添加扫描到的打印机'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppSelect<String>(
                    value: selectedModel,
                    label: '打印机型号',
                    hint: '请选择机型',
                    items: _bambuModels
                        .map(
                          (preset) => DropdownMenuItem(
                            value: preset.model,
                            child: Text(preset.model),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setDialogState(() => selectedModel = value),
                  ),
                  const SizedBox(height: 10),
                  AppSelect<double>(
                    value: selectedNozzleDiameter,
                    label: '当前安装喷嘴',
                    items: const [0.2, 0.4, 0.6, 0.8]
                        .map(
                          (diameter) => DropdownMenuItem(
                            value: diameter,
                            child: Text('${diameter.toStringAsFixed(1)} mm'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => selectedNozzleDiameter = value);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  AppInput(
                    label: '设备名称（可选）',
                    hint: '例如：工作室 X1C',
                    controller: nameCtrl,
                  ),
                  const SizedBox(height: 10),
                  AppInput(
                    label: '序列号 SN',
                    hint: '01S09C123456789',
                    controller: serialCtrl,
                  ),
                  const SizedBox(height: 10),
                  AppInput(
                    label: 'IP 地址',
                    hint: '打印机局域网 IP，例如 192.168.1.100',
                    controller: hostCtrl,
                  ),
                  const SizedBox(height: 10),
                  AppInput(
                    label: 'Access Code',
                    hint: '8 位字母数字',
                    controller: accessCtrl,
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.info.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(AppColors.radiusSm),
                      border: Border.all(
                        color: AppColors.info.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 14,
                              color: AppColors.info,
                            ),
                            SizedBox(width: 6),
                            Text(
                              '如何获取 Access Code？',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.info,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '方法1：打印机屏幕 → 设置 → 网络 → LAN Access Code\n'
                          '方法2：登录拓竹账号后从云端自动获取\n'
                          '方法3：拓竹 Handy App → 设置 → 局域网访问码',
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.5,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  if (selectedModel == null ||
                      serialCtrl.text.trim().isEmpty ||
                      hostCtrl.text.trim().isEmpty ||
                      accessCtrl.text.trim().isEmpty) {
                    showSnack(ctx, '请填写机型、序列号、IP 地址和 Access Code', error: true);
                    return;
                  }
                  Navigator.pop(
                    ctx,
                    PrinterConnectionConfig(
                      serial: serialCtrl.text.trim(),
                      host: hostCtrl.text.trim(),
                      accessCode: accessCtrl.text.trim(),
                      port: discovered?.port ?? 8883,
                      devProductName: selectedModel,
                      installedNozzleDiameter: selectedNozzleDiameter,
                      displayName: nameCtrl.text.trim().isEmpty
                          ? null
                          : nameCtrl.text.trim(),
                    ),
                  );
                },
                child: const Text('添加'),
              ),
            ],
          ),
        ),
      );

      if (result != null) {
        if (!context.mounted) return;
        if (!await confirmPrinterCertificateTrust(context, result)) return;
        if (!context.mounted) return;
        await ref.read(printerConnectionListProvider.notifier).add(result);
      }
    } finally {
      serialCtrl.dispose();
      hostCtrl.dispose();
      accessCtrl.dispose();
      nameCtrl.dispose();
    }
  }

  static String? _inferModel(DiscoveredBambuPrinter printer) {
    final source = '${printer.deviceName} ${printer.instanceName}'
        .toUpperCase();
    final ordered = _bambuModels.toList()
      ..sort((a, b) => b.model.length.compareTo(a.model.length));
    for (final preset in ordered) {
      final aliases = <String>{preset.model.toUpperCase()};
      if (preset.model == 'A1mini') aliases.addAll({'A1 MINI', 'A1MINI'});
      if (aliases.any(source.contains)) return preset.model;
    }
    return null;
  }
}

/// LAN 连接项。暗色适配。
class _ConnectionTile extends StatelessWidget {
  final PrinterConnectionConfig config;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ConnectionTile({
    required this.config,
    required this.isActive,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isActive
                ? AppColors.primaryContainer
                : (isDark
                      ? AppColors.surfaceVariantDark
                      : AppColors.surfaceVariant),
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            border: Border.all(
              color: isActive
                  ? AppColors.primary.withValues(alpha: 0.4)
                  : Colors.transparent,
              width: 1.2,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isActive ? Icons.link_rounded : Icons.link_off_rounded,
                color: isActive
                    ? AppColors.primary
                    : (isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary),
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      config.displayLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${config.devProductName ?? '未知机型'} · '
                      '${config.installedNozzleDiameter?.toStringAsFixed(1) ?? '未知'}mm 喷嘴 · '
                      '${config.serial} · ${config.host}:${config.port}',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.send_to_mobile_outlined,
                  size: 18,
                  color: isDark
                      ? AppColors.info.withValues(alpha: 0.85)
                      : AppColors.info,
                ),
                onPressed: () => _writeToBambuStudio(context, config),
                tooltip: '写入 Bambu Studio（LAN 直连）',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                ),
                onPressed: onDelete,
                tooltip: '删除',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 将该打印机的 LAN Access Code 写入 Bambu Studio 配置文件。
  ///
  /// 写入后用户打开 Bambu Studio，设备会通过 mDNS 自动发现并连接，
  /// 不需要手动输入 IP 和 Access Code。
  static Future<void> _writeToBambuStudio(
    BuildContext context,
    PrinterConnectionConfig config,
  ) async {
    // 检查 Bambu Studio 是否安装
    if (!BambuStudioLanConfigWriter.isInstalled()) {
      if (!context.mounted) return;
      await AppDialog.confirm(
        context,
        '未检测到 Bambu Studio',
        '请先安装 Bambu Studio 切片软件，并至少启动一次以生成配置文件。',
        confirmText: '知道了',
        cancelText: '取消',
      );
      return;
    }

    // 检查 Access Code 是否有效
    if (config.accessCode.isEmpty) {
      if (!context.mounted) return;
      showSnack(context, '该打印机没有 Access Code，无法写入', error: true);
      return;
    }

    // 确认弹窗
    final confirmed = await AppDialog.confirm(
      context,
      '写入 Bambu Studio',
      '将该打印机的 Access Code 写入 Bambu Studio 配置文件。\n\n'
          '序列号：${config.serial}\n'
          'Access Code：${config.accessCode}\n\n'
          '写入后请关闭并重新打开 Bambu Studio，设备会通过局域网 mDNS 自动发现。\n\n'
          '注意：请先关闭 Bambu Studio，否则写入会被覆盖。',
      confirmText: '写入',
    );
    if (!confirmed) return;

    // 检查 Bambu Studio 是否在运行
    final isRunning = await BambuStudioLanConfigWriter.isRunning();
    if (isRunning) {
      if (!context.mounted) return;
      showSnack(context, '请先关闭 Bambu Studio，再重试', error: true);
      return;
    }

    // 写入
    try {
      final ok = await BambuStudioLanConfigWriter.writeLanAccessCode(
        serial: config.serial,
        accessCode: config.accessCode,
      );
      if (!context.mounted) return;
      if (ok) {
        showSnack(context, '已写入 Bambu Studio，请重新打开 Bambu Studio 查看');
      } else {
        showSnack(context, '写入失败，请先关闭 Bambu Studio', error: true);
      }
    } catch (e) {
      if (!context.mounted) return;
      showSnack(context, '写入失败：${friendlyError(e)}', error: true);
    }
  }
}

/// 区块标题。暗色适配。
///
/// v5：支持 [bambuIconName]，非空时优先使用拓竹 SVG 图标替代 [icon]。
class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String? bambuIconName;
  final String title;
  final String subtitle;

  const _SectionTitle({
    required this.icon,
    this.bambuIconName,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final leading = bambuIconName != null
        ? BambuIcon(
            name: bambuIconName!,
            size: 18,
            color: AppColors.primary,
            applyColorFilter: true,
          )
        : Icon(icon, color: AppColors.primary, size: 18);
    return Row(
      children: [
        leading,
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 状态键值行。暗色适配。
class _StatusRow extends StatelessWidget {
  final String label;
  final String value;
  final bool ok;
  final bool isDark;

  const _StatusRow({
    required this.label,
    required this.value,
    this.ok = true,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: ok
                  ? (isDark ? AppColors.textPrimaryDark : AppColors.textPrimary)
                  : AppColors.warning,
              fontWeight: FontWeight.w500,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// 数据管理区。保留全部备份/恢复/删除逻辑与数据库版本读取。
class _DataManagementSection extends ConsumerStatefulWidget {
  const _DataManagementSection();

  @override
  ConsumerState<_DataManagementSection> createState() =>
      _DataManagementSectionState();
}

class _DataManagementSectionState
    extends ConsumerState<_DataManagementSection> {
  int _dbVersion = 0;
  int _prefsVersion = 0;
  List<BackupInfo> _backups = [];
  bool _loading = true;
  bool _backing = false;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    final db = ref.read(databaseProvider);
    final dbV = await MigrationManager.getAppliedVersion(db);
    final prefsV = await AppVersionPrefs.getLastMigrationVersion();
    final backups = await BackupManager.listBackups();
    if (!mounted) return;
    setState(() {
      _dbVersion = dbV;
      _prefsVersion = prefsV;
      _backups = backups;
      _loading = false;
    });
  }

  Future<void> _createBackup() async {
    setState(() => _backing = true);
    try {
      final db = ref.read(databaseProvider);
      // H-8 修复：备份前执行 WAL checkpoint，确保数据写入主数据库文件
      await BackupManager.createBackup(
        label: '手动',
        preCopyHook: () => db.customStatement('PRAGMA wal_checkpoint(FULL);'),
      );
      await _loadInfo();
      if (mounted) showSnack(context, '备份成功');
    } catch (e) {
      if (mounted) {
        showSnack(context, '备份失败: ${friendlyError(e)}', error: true);
      }
    } finally {
      if (mounted) setState(() => _backing = false);
    }
  }

  Future<void> _openBackupFolder() async {
    try {
      final path = await BackupManager.backupDirPath;
      await Process.start('explorer.exe', [
        path,
      ], mode: ProcessStartMode.detached);
    } catch (error) {
      if (mounted) {
        showSnack(context, '无法打开备份目录：${friendlyError(error)}', error: true);
      }
    }
  }

  Future<void> _openDataFolder() async {
    try {
      final path = await BackupManager.applicationDataDirPath;
      await Process.start('explorer.exe', [
        path,
      ], mode: ProcessStartMode.detached);
    } catch (error) {
      if (mounted) {
        showSnack(context, '无法打开数据目录：${friendlyError(error)}', error: true);
      }
    }
  }

  Future<void> _restoreBackup(BackupInfo info) async {
    final confirmed = await AppDialog.confirm(
      context,
      '恢复数据',
      '将从备份恢复数据，当前数据会被覆盖。恢复后需重启应用生效。是否继续？',
      confirmText: '恢复',
      destructive: true,
    );
    if (!confirmed) return;

    try {
      final db = ref.read(databaseProvider);

      // H-6 修复：关闭数据库前创建安全备份快照，防止恢复失败导致数据丢失
      try {
        await BackupManager.createBackup(
          label: '恢复前自动备份',
          pruneOldBackups: false,
          preCopyHook: () => db.customStatement('PRAGMA wal_checkpoint(FULL);'),
        );
      } catch (e) {
        debugPrint('恢复前安全备份失败: $e');
        if (mounted) {
          showSnack(
            context,
            '恢复前安全备份失败，已取消恢复: ${friendlyError(e)}',
            error: true,
          );
        }
        return;
      }

      // BackupManager 会先校验并暂存备份，确认可恢复后才关闭当前数据库。
      final ok = await BackupManager.restore(
        info.path,
        ensureDbClosed: () async {
          await db.close();
          // 等待 isolate 文件句柄释放，避免恢复时文件仍被占用。
          await Future.delayed(const Duration(milliseconds: 200));
        },
      );
      if (ok) {
        // L-4 修复：用对话框替代固定延迟，让用户主动点击重启
        if (mounted) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              content: const Text('恢复成功，应用需要重启以加载恢复的数据'),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    windowManager.destroy();
                  },
                  child: const Text('立即重启'),
                ),
              ],
            ),
          );
        } else {
          await windowManager.destroy();
        }
      } else {
        if (mounted) {
          showSnack(context, '恢复失败，应用将退出', error: true);
        }
        await Future.delayed(const Duration(seconds: 2));
        await windowManager.destroy();
      }
    } catch (e) {
      // C-2 修复：恢复过程中抛异常，DB 已关闭，应用处于死状态，强制退出
      // M-3 修复：包含具体错误信息
      if (mounted) {
        showSnack(context, '恢复失败: ${friendlyError(e)}，应用将退出', error: true);
      }
      await Future.delayed(const Duration(seconds: 2));
      await windowManager.destroy();
    }
  }

  Future<void> _deleteBackup(BackupInfo info) async {
    final confirmed = await AppDialog.confirm(
      context,
      '删除备份',
      '确定删除此备份？删除后无法恢复。',
      confirmText: '删除',
      destructive: true,
    );
    if (!confirmed) return;

    await BackupManager.deleteBackup(info.path);
    await _loadInfo();
    if (mounted) showSnack(context, '已删除备份');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.backup_outlined,
          title: '数据管理',
          subtitle: '备份、恢复和历史版本管理',
        ),
        const SizedBox(height: 14),
        // 版本信息
        _StatusRow(
          label: '数据版本',
          value: _loading ? '加载中…' : 'v$_dbVersion / prefs v$_prefsVersion',
          isDark: isDark,
        ),
        const SizedBox(height: 12),
        // 立即备份按钮
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            AppButton(
              label: _backing ? '备份中…' : '立即备份',
              icon: BambuIcon(
                name: 'save',
                size: 18,
                color: AppColors.primary,
                applyColorFilter: true,
              ),
              variant: AppButtonVariant.secondary,
              onPressed: _backing ? null : _createBackup,
            ),
            AppButton(
              label: '打开备份目录',
              icon: const Icon(Icons.folder_open_rounded, size: 17),
              variant: AppButtonVariant.ghost,
              onPressed: _openBackupFolder,
            ),
            AppButton(
              label: '打开数据目录',
              icon: const Icon(Icons.storage_rounded, size: 17),
              variant: AppButtonVariant.ghost,
              onPressed: _openDataFolder,
            ),
          ],
        ),
        const SizedBox(height: 14),
        // 备份列表
        if (_backups.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: Text(
                '暂无备份记录',
                style: TextStyle(
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                  fontSize: 12,
                ),
              ),
            ),
          )
        else
          for (final backup in _backups) ...[
            _BackupTile(
              backup: backup,
              onRestore: () => _restoreBackup(backup),
              onDelete: () => _deleteBackup(backup),
            ),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 4),
        Text(
          '提示：升级前会自动备份，备份最多保留最近 5 个',
          style: TextStyle(
            fontSize: 10,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }
}

/// 备份列表项。暗色适配。
class _BackupTile extends StatelessWidget {
  final BackupInfo backup;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  const _BackupTile({
    required this.backup,
    required this.onRestore,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final timeStr =
        '${backup.createdAt.month.toString().padLeft(2, '0')}-'
        '${backup.createdAt.day.toString().padLeft(2, '0')} '
        '${backup.createdAt.hour.toString().padLeft(2, '0')}:'
        '${backup.createdAt.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
      ),
      child: Row(
        children: [
          Icon(
            Icons.archive_outlined,
            size: 16,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      timeStr,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    if (backup.label != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primaryContainer,
                          borderRadius: BorderRadius.circular(
                            AppColors.radiusSm,
                          ),
                        ),
                        child: Text(
                          backup.label!,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  backup.sizeFormatted,
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.restore_outlined,
              size: 16,
              color: AppColors.primary,
            ),
            onPressed: onRestore,
            tooltip: '恢复',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 16,
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiary,
            ),
            onPressed: onDelete,
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// 关于分类：重新运行初始化向导 + 版本信息。
class _AboutSection extends StatelessWidget {
  final Future<void> Function() onRerunOnboarding;
  const _AboutSection({required this.onRerunOnboarding});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.info_outline_rounded,
          bambuIconName: 'info',
          title: '关于与更新',
          subtitle: '应用版本、更新通道与初始化工具',
        ),
        const SizedBox(height: AppSpacing.xxl),
        Center(
          child: Column(
            children: [
              const AppBrandIcon(size: 64, radius: AppColors.radiusLg),
              const SizedBox(height: AppSpacing.md),
              Text(
                AppIdentity.name,
                textAlign: TextAlign.center,
                style: AppTypography.headline.copyWith(
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                AppIdentity.description,
                textAlign: TextAlign.center,
                style: AppTypography.caption.copyWith(
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        const _AppUpdateCard(),
        const SizedBox(height: AppSpacing.md),
        GlassCard(
          level: GlassLevel.l1,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  children: [
                    _AboutInfoRow(
                      label: '应用名称',
                      value: AppIdentity.name,
                      isDark: isDark,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.md,
                      ),
                      child: Divider(
                        height: 1,
                        color: isDark
                            ? AppColors.dividerDark
                            : AppColors.divider,
                      ),
                    ),
                    _AboutInfoRow(
                      label: '作者',
                      value: AppIdentity.author,
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: isDark ? AppColors.dividerDark : AppColors.divider,
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 360;
                    final details = _AboutResetDetails(isDark: isDark);
                    final button = AppButton(
                      label: '重新运行',
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      variant: AppButtonVariant.secondary,
                      onPressed: () => onRerunOnboarding(),
                    );
                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          details,
                          const SizedBox(height: AppSpacing.md),
                          Align(
                            alignment: Alignment.centerRight,
                            child: button,
                          ),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: details),
                        const SizedBox(width: AppSpacing.lg),
                        button,
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AppUpdateCard extends StatelessWidget {
  const _AppUpdateCard();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const AppUpdateEntryCard(),
      const SizedBox(height: 12),
      const AppUpdateReminderSetting(),
      const SizedBox(height: 12),
      GlassCard(
        level: GlassLevel.l1,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: _SettingRow(
          label: '本次更新内容',
          description: '回看当前版本第一次启动时显示的改动摘要',
          trailing: AppButton(
            label: '查看',
            icon: const Icon(Icons.article_outlined, size: 16),
            variant: AppButtonVariant.ghost,
            onPressed: () => WhatsNewDialog.show(context),
          ),
        ),
      ),
    ],
  );
}

class _AboutInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;

  const _AboutInfoRow({
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: AppTypography.label.copyWith(
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: AppTypography.body.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _AboutResetDetails extends StatelessWidget {
  final bool isDark;

  const _AboutResetDetails({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '重新初始化',
          style: AppTypography.title.copyWith(
            fontSize: 13,
            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '重新配置账号、打印机和切片软件',
          style: AppTypography.label.copyWith(
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// 隐私分类：匿名诊断开关 + 待上传摘要 + 清空待发送数据（任务书 11.5）。
///
/// 与诊断中心的"隐私与导出"页签互补：
/// - 诊断中心：完整诊断包导出、敏感字段清单、隐私说明。
/// - 设置-隐私：快捷开关、待发送摘要、清空待发送队列。
/// 两处共享同一持久化 key（`TelemetryService.kUploadEnabledKey`）。
class _PrivacySection extends ConsumerStatefulWidget {
  const _PrivacySection();

  @override
  ConsumerState<_PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends ConsumerState<_PrivacySection> {
  bool _uploadEnabled = false;
  int _pendingCount = 0;
  bool _loading = true;
  bool _clearing = false;
  bool _toggling = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await ref.read(telemetryEventDaoProvider).countPending();
      if (!mounted) return;
      setState(() {
        _uploadEnabled =
            prefs.getBool(TelemetryService.kUploadEnabledKey) ?? false;
        _pendingCount = pending;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  /// 切换匿名诊断上传开关。
  ///
  /// 任务书 11.5：关闭开关后停止上传并清空未发送队列，
  /// 但不删除用户主动保留的本地错误日志（error_logs 表），
  /// 也不删除已 synced/failed 的遥测历史聚合数据。
  Future<void> _toggleUpload(bool value) async {
    if (_toggling) return;
    setState(() => _toggling = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(TelemetryService.kUploadEnabledKey, value);
      if (!value) {
        try {
          await ref.read(telemetryEventDaoProvider).clearPending();
        } catch (e) {
          debugPrint('[SettingsPrivacy] 清空待发送队列失败: $e');
        }
      }
      final pending = value
          ? _pendingCount
          : await ref.read(telemetryEventDaoProvider).countPending();
      if (!mounted) return;
      setState(() {
        _uploadEnabled = value;
        _pendingCount = pending;
        _toggling = false;
      });
      showSnack(
        context,
        value ? '已开启匿名诊断上传' : '已关闭匿名诊断上传，待发送队列已清空（本地错误日志与已上传历史保留）',
      );
    } catch (e) {
      if (mounted) {
        setState(() => _toggling = false);
        showSnack(context, '操作失败: ${friendlyError(e)}', error: true);
      }
    }
  }

  Future<void> _clearPending() async {
    if (_clearing || _pendingCount == 0) return;
    final confirmed = await AppDialog.confirm(
      context,
      '清空待发送队列',
      '此操作不可恢复，确定清空所有待上传的匿名诊断数据？'
          '本地错误日志和已上传的遥测历史不受影响，可继续在诊断中心查看。',
      confirmText: '清空',
      destructive: true,
    );
    if (!confirmed) return;
    setState(() => _clearing = true);
    try {
      await ref.read(telemetryEventDaoProvider).clearPending();
      await _load();
      if (mounted) showSnack(context, '已清空待发送队列');
    } catch (e) {
      if (mounted) {
        showSnack(context, '清空失败: ${friendlyError(e)}', error: true);
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(
            icon: Icons.shield_outlined,
            title: '隐私',
            subtitle: '匿名诊断与本地数据',
          ),
          const SizedBox(height: AppSpacing.md),
          GlassCard(
            level: GlassLevel.l1,
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                Text(
                  '加载失败: $_error',
                  style: AppTypography.body.copyWith(color: AppColors.danger),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: '重试',
                  variant: AppButtonVariant.secondary,
                  onPressed: _load,
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.shield_outlined,
          title: '隐私',
          subtitle: '匿名诊断与本地数据',
        ),
        const SizedBox(height: AppSpacing.md),
        // 说明卡片
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  BambuIcon(
                    name: 'info',
                    size: 16,
                    color: AppColors.primary,
                    applyColorFilter: true,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '本地优先与隐私边界',
                    style: AppTypography.title.copyWith(fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '错误日志、运行指标、打印结果、耗材轨迹和故障记录默认仅保存在本地，'
                '不会自动上传。匿名诊断数据默认关闭，需要你明确开启后才向 sohun 云'
                '上传脱敏后的指标事件。匿名安装 ID 随机生成，不绑定 sohun 账号、'
                '机器名或硬件 ID；登录状态不会附加到匿名诊断事件。',
                style: AppTypography.label.copyWith(height: 1.5),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '以下字段不会进入诊断包或匿名诊断上传（账号注册按账号页说明单独处理）：'
                'access token / refresh token / '
                '密码 / LAN access code / IP 地址 / 邮箱 / 打印机序列号 / '
                'trayUuid / 完整文件路径 / G-code 内容 / 用户本地备注。',
                style: AppTypography.label.copyWith(
                  height: 1.5,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // 匿名诊断开关 + 待发送摘要
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('匿名诊断数据', style: AppTypography.title.copyWith(fontSize: 13)),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '开启后将向 sohun 云上传脱敏后的崩溃、升级结果、设备兼容、'
                '首次使用、同步成功率和接口延迟事件。关闭开关后停止上传并清空未发送'
                '队列，但不删除用户主动保留的本地错误日志。',
                style: AppTypography.label.copyWith(height: 1.5),
              ),
              const SizedBox(height: AppSpacing.sm),
              SwitchListTile(
                value: _uploadEnabled,
                onChanged: _toggling ? null : _toggleUpload,
                title: Text(
                  '允许匿名诊断数据上传',
                  style: AppTypography.body.copyWith(fontSize: 13),
                ),
                subtitle: Text(
                  _uploadEnabled ? '已开启' : '默认关闭',
                  style: AppTypography.label,
                ),
                activeThumbColor: AppColors.primary,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: AppSpacing.sm),
              _StatusRow(
                label: '待发送',
                value: '$_pendingCount 条',
                isDark: isDark,
                ok: _pendingCount == 0,
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AppButton(
                    label: _clearing ? '清空中…' : '清空待发送数据',
                    variant: AppButtonVariant.secondary,
                    onPressed: (_clearing || _pendingCount == 0)
                        ? null
                        : _clearPending,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // 提示：完整诊断包导出位于诊断中心
        GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 16,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '如需导出完整诊断包（应用版本、数据库 schema、功能开关、指标汇总、'
                  '脱敏错误日志），请前往诊断中心的"隐私与导出"页签。',
                  style: AppTypography.label.copyWith(height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
