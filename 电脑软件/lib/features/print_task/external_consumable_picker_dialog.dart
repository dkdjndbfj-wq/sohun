import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_curves.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/utils/brand_logo_utils.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/gram_utils.dart';
import '../../data/database/database.dart';
import '../../data/external/slicer/slice_result.dart';
import '../../providers/consumable_provider.dart';
import '../../providers/database_provider.dart';
import '../../widgets/consumable_picker_layout.dart';
import '../../widgets/filament_spool_icon.dart';
import '../inventory/add_consumable_sheet.dart';
import '../inventory/consumable_card.dart';

typedef ConsumableShelfPredicate = bool Function(Consumable item);
typedef ConsumableShelfScore = int Function(Consumable item);
typedef ConsumableShelfRequiredGrams = double? Function(Consumable item);
typedef ConsumableShelfDisplayGrams = double Function(Consumable item);

/// Presentation and filtering rules for the shared inventory shelf picker.
///
/// External multi-colour planning and physical spool replacement intentionally
/// share the same inventory browsing surface. Their header, recommendations
/// and capacity rules remain independent through this descriptor.
class ConsumableShelfPickerSpec {
  const ConsumableShelfPickerSpec({
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.keyPrefix,
    this.selectedId,
    this.initialManufacturer,
    this.initialMaterial,
    this.initialColorHex,
    this.includeItem,
    this.matchScore,
    this.isRecommended,
    this.requiredGramsFor,
    this.displayGramsFor,
    this.emptyLabel = '库存中还没有耗材',
  });

  final String title;
  final String subtitle;
  final Color accentColor;
  final String keyPrefix;
  final int? selectedId;
  final String? initialManufacturer;
  final String? initialMaterial;
  final String? initialColorHex;
  final ConsumableShelfPredicate? includeItem;
  final ConsumableShelfScore? matchScore;
  final ConsumableShelfPredicate? isRecommended;
  final ConsumableShelfRequiredGrams? requiredGramsFor;
  final ConsumableShelfDisplayGrams? displayGramsFor;
  final String emptyLabel;
}

/// Compatibility entry point for the external multi-colour workflow.
class ExternalConsumablePickerDialog extends StatelessWidget {
  const ExternalConsumablePickerDialog({
    super.key,
    required this.filament,
    required this.assignedGramsByConsumable,
    this.selectedId,
  });

  final FilamentUsage filament;
  final int? selectedId;
  final Map<int, double> assignedGramsByConsumable;

  ConsumableShelfPickerSpec get _spec => ConsumableShelfPickerSpec(
    title: '为 T${filament.toolIndex} 选择耗材',
    subtitle:
        '${filament.materialType ?? '材质未知'} · '
        '${filament.colorHex ?? '颜色未知'} · '
        '预计 ${GramUtils.formatGrams(filament.grams)}',
    accentColor: ColorUtils.fromHex(filament.colorHex ?? '#8A8A8A'),
    keyPrefix: 'external',
    selectedId: selectedId,
    initialManufacturer: filament.vendor,
    initialMaterial: filament.materialType,
    initialColorHex: filament.colorHex,
    matchScore: (item) => externalConsumableMatchScore(item, filament),
    isRecommended: (item) => externalConsumableMatchScore(item, filament) >= 5,
    requiredGramsFor: (item) =>
        (assignedGramsByConsumable[item.id] ?? 0) + filament.grams,
  );

  static Future<Consumable?> show(
    BuildContext context, {
    required FilamentUsage filament,
    required Map<int, double> assignedGramsByConsumable,
    int? selectedId,
  }) {
    return ConsumableShelfPickerDialog.show(
      context,
      spec: ExternalConsumablePickerDialog(
        filament: filament,
        selectedId: selectedId,
        assignedGramsByConsumable: assignedGramsByConsumable,
      )._spec,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConsumableShelfPickerDialog(spec: _spec);
  }
}

class ConsumableShelfPickerDialog extends ConsumerStatefulWidget {
  const ConsumableShelfPickerDialog({super.key, required this.spec});

  final ConsumableShelfPickerSpec spec;

  static Future<Consumable?> show(
    BuildContext context, {
    required ConsumableShelfPickerSpec spec,
  }) {
    return showGeneralDialog<Consumable>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择库存耗材',
      barrierColor: Colors.black.withValues(alpha: 0.46),
      transitionDuration: AppCurves.durationModal,
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        if (!AppMotion.enabled(context)) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppCurves.curveModal,
        );
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
            child: child,
          ),
        );
      },
      pageBuilder: (_, __, ___) => ConsumableShelfPickerDialog(spec: spec),
    );
  }

  @override
  ConsumerState<ConsumableShelfPickerDialog> createState() =>
      _ConsumableShelfPickerDialogState();
}

class _ConsumableShelfPickerDialogState
    extends ConsumerState<ConsumableShelfPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _creating = false;

  ConsumableShelfPickerSpec get spec => widget.spec;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inventoryAsync = ref.watch(consumablesProvider);
    final panelSize = ConsumablePickerLayout.size(context);

    return Dialog(
      insetPadding: ConsumablePickerLayout.insetPadding,
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: SizedBox(
        width: panelSize.width,
        height: panelSize.height,
        child: Material(
          key: ValueKey('${spec.keyPrefix}-consumable-picker'),
          color: isDark ? AppColors.surfaceDark : AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PickerHeader(
                spec: spec,
                onClose: () => Navigator.of(context).pop(),
              ),
              Divider(
                height: 1,
                color: isDark ? AppColors.dividerDark : AppColors.divider,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('${spec.keyPrefix}-picker-search'),
                        controller: _searchController,
                        onChanged: (value) => setState(() => _query = value),
                        decoration: InputDecoration(
                          hintText: '搜索品牌、型号、材质、颜色',
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 19,
                          ),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清除搜索',
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _query = '');
                                  },
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                ),
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      key: ValueKey('${spec.keyPrefix}-picker-create'),
                      onPressed: _creating ? null : _createConsumable,
                      icon: _creating
                          ? Builder(
                              builder: (context) => SizedBox.square(
                                dimension: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: GlassButtonsTheme.enabledOf(context)
                                      ? IconTheme.of(context).color
                                      : Colors.white,
                                ),
                              ),
                            )
                          : const Icon(Icons.add_rounded, size: 18),
                      label: const Text('新增耗材'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: inventoryAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, stackTrace) =>
                      Center(child: Text('库存读取失败：$error')),
                  data: _buildInventory,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInventory(List<Consumable> inventory) {
    final query = _query.trim().toLowerCase();
    final filtered = inventory.where((item) {
      if (spec.includeItem?.call(item) == false) return false;
      if (query.isEmpty) return true;
      final text =
          '${item.manufacturer} ${item.model} ${item.materialType} '
                  '${item.colorName ?? ''} ${item.colorHex} ${item.note ?? ''}'
              .toLowerCase();
      return text.contains(query);
    }).toList();
    final grouped = _groupByBrand(filtered);
    if (grouped.isEmpty) {
      return _PickerEmptyState(
        hasQuery: query.isNotEmpty,
        emptyLabel: spec.emptyLabel,
      );
    }

    return CustomScrollView(
      key: ValueKey('${spec.keyPrefix}-picker-brand-list'),
      slivers: [
        for (final entry in grouped.entries) ...[
          SliverToBoxAdapter(
            child: _PickerBrandHeader(brand: entry.key, items: entry.value),
          ),
          SliverToBoxAdapter(
            child: _PickerBrandShelf(
              items: entry.value,
              spec: spec,
              onSelected: (item) => Navigator.of(context).pop(item),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
      ],
    );
  }

  Map<String, List<Consumable>> _groupByBrand(List<Consumable> items) {
    final groups = <String, List<Consumable>>{};
    for (final item in items) {
      final brand = item.manufacturer.trim().isEmpty
          ? '其他品牌'
          : item.manufacturer.trim();
      groups.putIfAbsent(brand, () => []).add(item);
    }
    final brands = groups.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    for (final brand in brands) {
      groups[brand]!.sort((a, b) {
        final score =
            (spec.matchScore?.call(b) ?? 0) - (spec.matchScore?.call(a) ?? 0);
        if (score != 0) return score;
        if ((a.remainingGrams > 0) != (b.remainingGrams > 0)) {
          return a.remainingGrams > 0 ? -1 : 1;
        }
        return (a.colorName ?? a.colorHex).compareTo(b.colorName ?? b.colorHex);
      });
    }
    return {for (final brand in brands) brand: groups[brand]!};
  }

  Future<void> _createConsumable() async {
    setState(() => _creating = true);
    try {
      final id = await AddConsumableSheet.show(
        context,
        initialManufacturer: spec.initialManufacturer,
        initialMaterial: spec.initialMaterial,
        initialColorHex: spec.initialColorHex,
      );
      if (id == null || !mounted) return;
      final item = await ref.read(consumableDaoProvider).getById(id);
      if (item != null && mounted) Navigator.of(context).pop(item);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }
}

class _PickerHeader extends StatelessWidget {
  const _PickerHeader({required this.spec, required this.onClose});

  final ConsumableShelfPickerSpec spec;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 14, 14),
      child: Row(
        children: [
          FilamentSpoolIcon(
            color: spec.accentColor,
            size: 38,
            dimensional: true,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  spec.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  spec.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _PickerBrandHeader extends StatelessWidget {
  const _PickerBrandHeader({required this.brand, required this.items});

  final String brand;
  final List<Consumable> items;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final logo = BrandLogoUtils.resolveAsset(brand);
    final remaining = items.fold<double>(
      0,
      (sum, item) => sum + item.remainingGrams,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 20, 5),
      child: Row(
        children: [
          if (logo != null)
            Image.asset(
              logo,
              width: 22,
              height: 22,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            )
          else
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                brand.isEmpty ? '?' : brand.substring(0, 1).toUpperCase(),
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              brand,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
          ),
          Text(
            '${items.length} 款 · ${GramUtils.formatGrams(remaining)}',
            style: TextStyle(
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiary,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PickerBrandShelf extends StatelessWidget {
  const _PickerBrandShelf({
    required this.items,
    required this.spec,
    required this.onSelected,
  });

  final List<Consumable> items;
  final ConsumableShelfPickerSpec spec;
  final ValueChanged<Consumable> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 286,
      child: Stack(
        children: [
          Positioned(
            left: 20,
            right: 20,
            bottom: 14,
            child: Container(
              height: 9,
              decoration: BoxDecoration(
                color: scheme.outlineVariant.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(99),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 7),
                  ),
                ],
              ),
            ),
          ),
          ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.md),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                key: ValueKey('${spec.keyPrefix}-picker-consumable-${item.id}'),
                width: 236,
                child: MaterialShelfCard(
                  item: item,
                  selectionMode: true,
                  selected: item.id == spec.selectedId,
                  recommended: spec.isRecommended?.call(item) == true,
                  selectionRequiredGrams: spec.requiredGramsFor?.call(item),
                  selectionDisplayGrams: spec.displayGramsFor?.call(item),
                  onEdit: () => onSelected(item),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PickerEmptyState extends StatelessWidget {
  const _PickerEmptyState({required this.hasQuery, required this.emptyLabel});

  final bool hasQuery;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasQuery ? Icons.search_off_rounded : Icons.inventory_2_outlined,
            size: 34,
            color: AppColors.textTertiary,
          ),
          const SizedBox(height: 9),
          Text(
            hasQuery ? '没有匹配的耗材' : emptyLabel,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

int externalConsumableMatchScore(Consumable item, FilamentUsage filament) {
  var score = 0;
  if (item.materialType.trim().toLowerCase() ==
      filament.materialType?.trim().toLowerCase()) {
    score += 2;
  }
  if (item.colorHex.trim().toLowerCase() ==
      filament.colorHex?.trim().toLowerCase()) {
    score += 3;
  }
  if (item.manufacturer.trim().toLowerCase() ==
      filament.vendor?.trim().toLowerCase()) {
    score += 1;
  }
  return score;
}
