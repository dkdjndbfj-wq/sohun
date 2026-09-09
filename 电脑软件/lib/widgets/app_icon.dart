import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 自定义 SVG 图标集（Lucide 风格：2px 线条、圆角线帽）。
/// 所有图标使用 currentColor，可通过 [color] 参数或 [IconTheme] 着色。
enum AppIconData {
  dashboard,
  inventory,
  chart,
  history,
  printer,
  firmware,
  cost,
  restock,
  quality,
  params,
  diagnostics,
  support,
  schedule,
  settings,
  add,
  close,
  check,
  edit,
  delete,
  refresh,
  search,
  moreVert,
  chevronRight,
  play,
  pause,
  stop,
  error,
  info,
  warning,
  checkCircle,
  layers,
  cloud,
  download,
  swap,
  pin,
  arrowForward,
  person,
  brand;

  String get path {
    // camelCase → snake_case
    final name = toString().split('.').last;
    final snake = name.replaceAllMapped(
      RegExp(r'[A-Z]'),
      (m) => '_${m[0]!.toLowerCase()}',
    );
    return 'assets/images/icons/$snake.svg';
  }
}

/// 统一 SVG 图标组件。
///
/// 用法：
/// ```dart
/// AppIcon(AppIconData.dashboard, size: 20, color: AppColors.primary)
/// ```
class AppIcon extends StatelessWidget {
  final AppIconData icon;
  final double size;
  final Color? color;

  const AppIcon(this.icon, {super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ?? IconTheme.of(context).color ?? Colors.black;
    return SvgPicture.asset(
      icon.path,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(resolvedColor, BlendMode.srcIn),
    );
  }
}
