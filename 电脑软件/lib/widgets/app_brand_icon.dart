import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_identity.dart';
import '../core/theme/theme_brand_assets.dart';
import '../providers/theme_provider.dart';

class AppBrandIcon extends ConsumerWidget {
  final double size;
  final double radius;

  const AppBrandIcon({
    super.key,
    this.size = 32,
    this.radius = 8,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeColorProvider);
    final cacheSize =
        (size * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(1, 512);
    final asset = ThemeBrandAssets.png(
      themeColor,
      Brightness.light,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.asset(
        asset,
        width: size,
        height: size,
        cacheWidth: cacheSize,
        cacheHeight: cacheSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => Image.asset(
          AppIdentity.iconAsset,
          width: size,
          height: size,
          cacheWidth: cacheSize,
          cacheHeight: cacheSize,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => Container(
            width: size,
            height: size,
            color: Theme.of(context).colorScheme.primary,
            alignment: Alignment.center,
            child: Text(
              'S',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
                fontSize: size * 0.52,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
