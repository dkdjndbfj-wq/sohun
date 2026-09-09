import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 拓竹 SVG 图标统一组件。
///
/// 直接加载 `assets/images/bambu_icons/` 下的拓竹切片软件原版图标。
/// 支持动态颜色适配（亮色模式下将原版白色/深色填充改为目标色）。
///
/// 使用示例：
/// ```dart
/// BambuIcon(name: 'tab_home_active', size: 24, color: AppColors.primary, applyColorFilter: true)
/// ```
class BambuIcon extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final assetName = 'assets/images/bambu_icons/$name.svg';
    Widget icon = SvgPicture.asset(
      assetName,
      width: size,
      height: size,
      // The public source intentionally omits unreviewed third-party assets.
      // Keep controls usable in source builds and if an installed asset is
      // missing or damaged, without raising an uncaught asset-load error.
      errorBuilder: (context, error, stackTrace) => Icon(
        Icons.image_not_supported_outlined,
        size: size,
        color: color ?? IconTheme.of(context).color,
      ),
      placeholderBuilder: (context) => Icon(
        Icons.image_not_supported_outlined,
        size: size,
        color: Colors.grey.shade400,
      ),
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
