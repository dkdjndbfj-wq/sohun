import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/filament_model_code.dart';

/// 空间紧凑处显示耗材型号代号；悬停可查看完整品牌与型号。
class FilamentModelBadge extends StatelessWidget {
  const FilamentModelBadge({
    super.key,
    required this.manufacturer,
    required this.model,
    this.materialType,
    this.compact = false,
  });

  final String manufacturer;
  final String model;
  final String? materialType;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final code = FilamentModelCode.of(
      model: model,
      materialType: materialType,
    );
    return Tooltip(
      message: FilamentModelCode.tooltip(
        manufacturer: manufacturer,
        model: model,
        materialType: materialType,
      ),
      waitDuration: const Duration(milliseconds: 320),
      child: Semantics(
        label: FilamentModelCode.description(
          manufacturer: manufacturer,
          model: model,
          materialType: materialType,
        ),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 5 : 7,
            vertical: compact ? 2 : 3,
          ),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.22),
            ),
          ),
          child: Text(
            code,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: scheme.primary,
              fontSize: compact ? 9 : 10,
              height: 1.05,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.15,
            ),
          ),
        ),
      ),
    );
  }
}
