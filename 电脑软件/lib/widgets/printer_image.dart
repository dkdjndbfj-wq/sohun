import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme/app_colors.dart';

/// 打印机图片显示组件。
/// 优先级：用户自定义图片路径 > 内置 asset > 品色轮廓 fallback。
/// 资源缺失时通过 errorBuilder 兜底，不会崩溃。
class PrinterImage extends StatelessWidget {
  final String? assetPath;
  final bool isCustomImage;
  final String brand;
  final double size;

  const PrinterImage({
    super.key,
    this.assetPath,
    this.isCustomImage = false,
    required this.brand,
    this.size = 96,
  });

  @override
  Widget build(BuildContext context) {
    final cacheSize =
        (size * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(1, 1024);
    if (assetPath == null || assetPath!.isEmpty) {
      return _fallback();
    }
    if (isCustomImage) {
      return Image.file(
        File(assetPath!),
        width: size,
        height: size,
        cacheWidth: cacheSize,
        cacheHeight: cacheSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => _fallback(),
      );
    }
    if (assetPath!.endsWith('.svg')) {
      return SvgPicture.asset(
        assetPath!,
        width: size,
        height: size,
        placeholderBuilder: (_) => _fallback(),
      );
    }
    return Image.asset(
      assetPath!,
      width: size,
      height: size,
      cacheWidth: cacheSize,
      cacheHeight: cacheSize,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => _fallback(),
    );
  }

  Widget _fallback() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.print_rounded, size: size * 0.4, color: AppColors.primary),
          const SizedBox(height: 4),
          Text(
            brand,
            style: TextStyle(
              fontSize: 10,
              color: AppColors.onPrimaryContainer,
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
