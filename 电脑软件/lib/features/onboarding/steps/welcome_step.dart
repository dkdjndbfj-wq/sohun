import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_identity.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/prefs/app_prefs.dart';

/// 首次使用先选择信息密度，与设置页共用偏好，不改变库存结构。
class WelcomeStep extends ConsumerWidget {
  const WelcomeStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final fine = ref.watch(inventoryFineDetailProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '从一卷材料，开始有序打印',
          style: AppTypography.label.copyWith(color: colors.primary),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          '欢迎使用 ${AppIdentity.name}',
          style: AppTypography.headline
              .copyWith(color: colors.onSurface, fontSize: 32, height: 1.25),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '把材料、设备和打印记录放在一起。\n先选择你习惯的库存视图，其余设置可以慢慢来。',
          style: AppTypography.body
              .copyWith(color: colors.onSurfaceVariant, height: 1.7),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        Text(
          '你希望看到多少库存细节？',
          style: AppTypography.title.copyWith(color: colors.onSurface),
        ),
        const SizedBox(height: AppSpacing.md),
        LayoutBuilder(
          builder: (context, constraints) {
            final choices = [
              _ViewChoice(
                key: const ValueKey('inventory-simple-choice'),
                title: '简洁视图',
                subtitle: '轻松开始',
                description: '按款管理材料，优先显示余量、数量与成本。',
                icon: Icons.view_agenda_outlined,
                selected: !fine,
                onTap: () => _select(context, ref, false),
              ),
              _ViewChoice(
                key: const ValueKey('inventory-fine-choice'),
                title: '精细视图',
                subtitle: '更多追溯信息',
                description: '在库存卡片上额外显示批次、备注等详情。',
                icon: Icons.format_list_bulleted_rounded,
                selected: fine,
                onTap: () => _select(context, ref, true),
              ),
            ];
            if (constraints.maxWidth < 500 ||
                MediaQuery.textScalerOf(context).scale(14) > 20) {
              return Column(
                children: [
                  choices[0],
                  const SizedBox(height: AppSpacing.md),
                  choices[1],
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: choices[0]),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(child: choices[1]),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '两种视图都保留按款汇总；单卷生命周期可从详情中查看。随时可在设置中切换。',
          style: AppTypography.body
              .copyWith(fontSize: 12, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        Divider(color: colors.outlineVariant.withValues(alpha: 0.5)),
        const SizedBox(height: AppSpacing.lg),
        Text(
          '接下来，按需连接你的工作区',
          style: AppTypography.label.copyWith(color: colors.onSurface),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: 20,
          runSpacing: 12,
          children: [
            for (final item in [
              (Icons.print_outlined, '账号与打印机'),
              (Icons.content_cut_rounded, '切片软件'),
              (Icons.calculate_outlined, '成本参数'),
            ])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(item.$1, size: 17, color: colors.onSurfaceVariant),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    item.$2,
                    style: AppTypography.body
                        .copyWith(fontSize: 12, color: colors.onSurfaceVariant),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _select(BuildContext context, WidgetRef ref, bool value) async {
    try {
      await ref.read(inventoryFineDetailProvider.notifier).setEnabled(value);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('库存视图未能保存，请重新选择。')));
      }
    }
  }
}

class _ViewChoice extends StatelessWidget {
  const _ViewChoice({
    super.key,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title, subtitle, description;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: Material(
        color:
            selected ? colors.primary.withValues(alpha: 0.07) : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppColors.radiusLg),
          side: BorderSide(
            color: selected
                ? colors.primary
                : colors.outlineVariant.withValues(alpha: 0.6),
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      icon,
                      size: 25,
                      color:
                          selected ? colors.primary : colors.onSurfaceVariant,
                    ),
                    const Spacer(),
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 20,
                      color:
                          selected ? colors.primary : colors.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  title,
                  style: AppTypography.title.copyWith(color: colors.onSurface),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  subtitle,
                  style: AppTypography.body.copyWith(
                    fontSize: 12,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  description,
                  style: AppTypography.body
                      .copyWith(fontSize: 13, color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
