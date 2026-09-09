import 'package:flutter/material.dart';

import '../core/theme/interaction_effects.dart';
import '../core/utils/brand_logo_utils.dart';
import '../core/utils/color_utils.dart';
import '../data/database/database.dart';
import '../widgets/filament_spool_icon.dart';
import 'mobile_visual_theme.dart';

/// Presentation grouping never merges database rows or their physical UIDs.
class MobileInventoryCategory {
  MobileInventoryCategory({
    required this.brand,
    required this.model,
    required this.material,
  });
  final String brand;
  final String model;
  final String material;
  final List<Consumable> items = [];
  (String, String, String) get id =>
      (brand.toLowerCase(), model.toLowerCase(), material.toLowerCase());
  double get remaining => items.fold(
    0,
    (sum, item) => sum + item.remainingGrams.clamp(0, double.infinity),
  );
  List<String> get colors =>
      items.map((item) => item.colorHex.toUpperCase()).toSet().toList();
}

Map<String, List<MobileInventoryCategory>> groupMobileInventory(
  List<Consumable> items,
) {
  final categories = <(String, String, String), MobileInventoryCategory>{};
  final brandNames = <String, String>{};
  for (final item in items) {
    final rawBrand = item.manufacturer.trim().isEmpty
        ? '未分类品牌'
        : item.manufacturer.trim();
    final brand = brandNames.putIfAbsent(
      rawBrand.toLowerCase(),
      () => rawBrand,
    );
    final model = item.model.trim().isEmpty ? '未命名型号' : item.model.trim();
    final material = item.materialType.trim();
    final key = (
      brand.toLowerCase(),
      model.toLowerCase(),
      material.toLowerCase(),
    );
    categories
        .putIfAbsent(
          key,
          () => MobileInventoryCategory(
            brand: brand,
            model: model,
            material: material,
          ),
        )
        .items
        .add(item);
  }
  final grouped = <String, List<MobileInventoryCategory>>{};
  for (final category in categories.values) {
    grouped.putIfAbsent(category.brand, () => []).add(category);
  }
  final brands = grouped.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return {for (final brand in brands) brand: grouped[brand]!};
}

class MobileInventoryBrandHeader extends StatelessWidget {
  const MobileInventoryBrandHeader({
    super.key,
    required this.brand,
    required this.count,
    required this.expanded,
    required this.onTap,
  });
  final String brand;
  final int count;
  final bool expanded;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asset = BrandLogoUtils.resolveAsset(brand);
    return Semantics(
      expanded: expanded,
      child: MobileGlassSurface(
        blur: 0,
        opacity: 0.25,
        radius: 12,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  if (asset != null) ...[
                    Container(
                      width: 32,
                      height: 26,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Image.asset(
                        asset,
                        fit: BoxFit.contain,
                        cacheWidth: 96,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.business_outlined,
                          size: 18,
                          color: Colors.black54,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      brand,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('$count 卷', style: theme.textTheme.bodySmall),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: AppMotion.duration(
                      context,
                      const Duration(milliseconds: 180),
                    ),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MobileInventoryCategoryRow extends StatelessWidget {
  const MobileInventoryCategoryRow({
    super.key,
    required this.category,
    required this.expanded,
    required this.onTap,
  });
  final MobileInventoryCategory category;
  final bool expanded;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = category.colors;
    final color = colors.length == 1 ? ColorUtils.fromHex(colors.first) : null;
    final weight = category.remaining >= 1000
        ? '${(category.remaining / 1000).toStringAsFixed(1)} kg'
        : '${category.remaining.toStringAsFixed(0)} g';
    final low = category.items
        .where(
          (item) =>
              item.totalGrams <= 0 ||
              item.remainingGrams / item.totalGrams <= 0.2,
        )
        .length;
    final single = category.items.length == 1;
    return Semantics(
      expanded: single ? null : expanded,
      child: MobileGlassSurface(
        blur: 0,
        opacity: 0.56,
        radius: 12,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                FilamentSpoolIcon(color: color, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category.model,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 6,
                        runSpacing: 3,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          ExcludeSemantics(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final hex in colors.take(5))
                                  Container(
                                    width: 9,
                                    height: 9,
                                    margin: const EdgeInsets.only(right: 3),
                                    decoration: BoxDecoration(
                                      color: ColorUtils.fromHex(hex),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: theme.colorScheme.outline
                                            .withValues(alpha: 0.3),
                                        width: 0.5,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            '${colors.length} 色 · $weight',
                            style: theme.textTheme.bodySmall,
                          ),
                          if (low > 0)
                            Text(
                              '低余量 $low',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          if (category.material.isNotEmpty &&
                              category.material.toLowerCase() !=
                                  category.model.toLowerCase())
                            Text(
                              category.material,
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${category.items.length}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(' 卷', style: theme.textTheme.bodySmall),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: !single && expanded ? 0.25 : 0,
                  duration: AppMotion.duration(
                    context,
                    const Duration(milliseconds: 180),
                  ),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                    size: 19,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
