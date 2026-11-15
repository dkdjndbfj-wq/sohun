import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 拓竹 SVG 图标统一组件。
///
/// 优先加载 `assets/images/bambu_icons/` 下的图标；公开核心版缺少该资源时，
/// 使用 Flutter 系统图标表达同一功能。
/// 支持动态颜色适配（亮色模式下将原版白色/深色填充改为目标色）。
///
/// 使用示例：
/// ```dart
/// BambuIcon(name: 'tab_home_active', size: 24, color: AppColors.primary, applyColorFilter: true)
/// ```
class BambuIcon extends StatelessWidget {
  static const _coreBuild = bool.fromEnvironment('SOHUN_CORE_BUILD');

  /// 图标文件名（不含扩展名）。
  ///
  /// 对应 `assets/images/bambu_icons/<name>.svg`。
  final String name;

  /// 图标尺寸（正方形）。默认 24。
  final double size;

  /// 目标颜色。当 [applyColorFilter] 为 true 时生效。
  ///
  /// 拓竹原版图标激活态为白色填充、非激活态为深色填充，亮色模式下需要
  /// 改为极光绿（选中）/灰色（未选中）等目标色。
  final Color? color;

  /// 是否应用颜色滤镜。
  ///
  /// - true：用 [BlendMode.srcIn] 将整个 SVG 填充改为 [color]，适合单色图标。
  /// - false（默认）：保留原 SVG 的多色配色，适合状态图标（绿/橙/灰/红）。
  final bool applyColorFilter;

  const BambuIcon({
    super.key,
    required this.name,
    this.size = 24,
    this.color,
    this.applyColorFilter = false,
  });

  /// Functional equivalents for controls whose optional SVG is unavailable.
  /// These are framework glyphs, not redistributed manufacturer artwork.
  static IconData fallbackIcon(String name) => switch (name) {
    'tab_home_active' => Icons.home_outlined,
    'printer' || 'monitor_item_print' => Icons.print_outlined,
    'tab_filament_active' => Icons.inventory_2_outlined,
    'filament' || 'spool' => Icons.circle_outlined,
    'add_filament' => Icons.add,
    'delete_filament' || 'tree_delete' => Icons.delete_outline,
    'monitor_item_cost' => Icons.payments_outlined,
    'monitor_item_prediction' => Icons.insights_outlined,
    'param_plate' => Icons.grid_view_outlined,
    'monitor' => Icons.monitor_heart_outlined,
    'tab_calibration_active' => Icons.tune,
    'tab_presets_active' => Icons.dashboard_customize_outlined,
    'firmware_management' => Icons.memory,
    'help' => Icons.help_outline,
    'info' => Icons.info_outline,
    'settings' || 'cog' || 'plate_settings' => Icons.settings_outlined,
    'warning' => Icons.warning_amber_rounded,
    'error' => Icons.error_outline,
    'completed' => Icons.task_alt,
    'confirm' => Icons.check,
    'cross' => Icons.close,
    'search' => Icons.search,
    'refresh_normal' => Icons.refresh,
    'save' || 'topbar_save' => Icons.save_outlined,
    'edit' => Icons.edit_outlined,
    'back' => Icons.arrow_back,
    'collapse_btn' => Icons.chevron_left,
    'expand_btn' => Icons.chevron_right,
    'drop_down' => Icons.expand_more,
    'more' => Icons.more_horiz,
    'favorite' => Icons.favorite_border,
    'favorite_filled' => Icons.favorite,
    'open' => Icons.folder_open,
    'open_in_browser' => Icons.open_in_new,
    'bar_publish' => Icons.publish,
    'tree_export' => Icons.file_download_outlined,
    'tree_copy' => Icons.content_copy,
    'topbar_undo' => Icons.undo,
    'topbar_redo' => Icons.redo,
    'compare' => Icons.compare_arrows,
    'fila_switch' => Icons.swap_horiz,
    'automatic_material_renewal' => Icons.autorenew,
    'scheduler' => Icons.event_note_outlined,
    'note' => Icons.notes,
    'ams_drying' => Icons.dry,
    'monitor_fan' => Icons.air,
    'monitor_nozzle_temp' => Icons.thermostat,
    'monitor_speed' => Icons.speed,
    'monitor_network_wired' => Icons.settings_ethernet,
    'monitor_signal_no' => Icons.wifi_off,
    'monitor_upgrade_online' => Icons.cloud_done_outlined,
    'monitor_upgrade_offline' => Icons.cloud_off_outlined,
    'param_flow' => Icons.water_drop_outlined,
    'param_mechanical' => Icons.build_outlined,
    'param_nozzle' => Icons.format_color_fill,
    'param_retraction' => Icons.unfold_less,
    'param_strength' => Icons.shield_outlined,
    'param_support' => Icons.foundation_outlined,
    'print_control_pause' => Icons.pause,
    'print_control_resume' => Icons.play_arrow,
    'print_control_stop' => Icons.stop,
    _ => Icons.widgets_outlined,
  };

  Widget _fallback(BuildContext context) => Icon(
    fallbackIcon(name),
    size: size,
    color: color ?? IconTheme.of(context).color,
  );

  @override
  Widget build(BuildContext context) {
    final assetName = 'assets/images/bambu_icons/$name.svg';
    Widget icon = _coreBuild
        ? _fallback(context)
        : SvgPicture.asset(
            assetName,
            width: size,
            height: size,
            // The public source intentionally omits unreviewed third-party assets.
            // Keep controls usable in source builds and if an installed asset is
            // missing or damaged, without raising an uncaught asset-load error.
            errorBuilder: (context, error, stackTrace) => _fallback(context),
            placeholderBuilder: _fallback,
          );

    // 颜色滤镜：将拓竹原版的白色/深色填充改为目标色（亮色模式适配）。
    if (applyColorFilter && color != null) {
      icon = ColorFiltered(
        colorFilter: ColorFilter.mode(color!, BlendMode.srcIn),
        child: icon,
      );
    }

    return icon;
  }
}
