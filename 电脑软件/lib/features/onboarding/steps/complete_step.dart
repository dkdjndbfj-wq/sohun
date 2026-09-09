import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/prefs/app_prefs.dart';
import '../../../providers/onboarding_provider.dart';

/// 配置摘要以实际配置为准，不把经过或跳过步骤显示成已完成。
class CompleteStep extends ConsumerWidget {
  const CompleteStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingProvider);
    final fine = ref.watch(inventoryFineDetailProvider);
    final colors = Theme.of(context).colorScheme;
    final summary = [
      (Icons.tune_rounded, '库存视图', fine ? '精细视图' : '简洁视图', 0),
      (
        Icons.cloud_outlined,
        '拓竹账号',
        state.cloudSession != null ? '已登录' : '暂未连接',
        1
      ),
      (
        Icons.print_outlined,
        '打印机',
        state.configuredPrinters.isNotEmpty
            ? '${state.configuredPrinters.length} 台已配置'
            : '暂未添加',
        3
      ),
      (
        Icons.content_cut_rounded,
        '切片软件',
        state.slicerExePath != null ? '已配置' : '稍后设置',
        4
      ),
      (
        Icons.calculate_outlined,
        '成本参数',
        state.costParams != null ? '已配置' : '使用默认值',
        5
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(Icons.check_rounded, color: colors.primary, size: 28),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Text(
          '准备好，开始你的下一次打印',
          style: AppTypography.headline
              .copyWith(color: colors.onSurface, fontSize: 28, height: 1.3),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '确认以下设置，或点击任意一项返回修改。\n暂未配置的项目，也可以在使用时再补充。',
          style: AppTypography.body
              .copyWith(color: colors.onSurfaceVariant, height: 1.7),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Material(
          color: colors.primary.withValues(alpha: 0.025),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < summary.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    indent: 20,
                    endIndent: 20,
                    color: colors.outlineVariant.withValues(alpha: 0.4),
                  ),
                ListTile(
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                  leading: Icon(summary[i].$1,
                      color: colors.onSurfaceVariant, size: 22,),
                  title: Text(
                    summary[i].$2,
                    style: AppTypography.body.copyWith(color: colors.onSurface),
                  ),
                  subtitle: Text(
                    summary[i].$3,
                    style: AppTypography.body
                        .copyWith(color: colors.onSurfaceVariant, fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                  onTap: state.isProcessing
                      ? null
                      : () => ref
                          .read(onboardingProvider.notifier)
                          .returnToStep(summary[i].$4),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          '点击“进入 sohun”保存本次配置。',
          style: AppTypography.body
              .copyWith(fontSize: 12, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}
