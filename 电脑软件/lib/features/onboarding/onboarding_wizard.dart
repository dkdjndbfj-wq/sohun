import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_identity.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/interaction_effects.dart';
import '../../providers/onboarding_provider.dart';
import '../../widgets/app_brand_icon.dart';
import 'steps/cloud_login_step.dart';
import 'steps/complete_step.dart';
import 'steps/cost_params_step.dart';
import 'steps/lan_scan_step.dart';
import 'steps/printer_config_step.dart';
import 'steps/slicer_detect_step.dart';
import 'steps/welcome_step.dart';

/// 宽屏双栏设置册；窄窗口使用可滚动内容与固定操作区。
class OnboardingWizard extends ConsumerWidget {
  const OnboardingWizard({super.key});

  static const _steps = [
    ('欢迎', '选择适合你的库存视图', Icons.tune_rounded),
    ('拓竹账号', '连接云端设备 · 可选', Icons.cloud_outlined),
    ('局域网扫描', '发现同一网络中的设备 · 可选', Icons.wifi_tethering_rounded),
    ('打印机配置', '确认设备连接方式 · 可选', Icons.print_outlined),
    ('切片软件', '连接 Bambu Studio · 可选', Icons.content_cut_rounded),
    ('成本参数', '设置成本计算默认值 · 可选', Icons.calculate_outlined),
    ('准备就绪', '检查配置，开始使用', Icons.check_circle_outline_rounded),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingProvider);
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: dark ? AppColors.bgBaseDark : AppColors.bgBase,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, bounds) {
            final wide = bounds.maxWidth >= 980;
            final inset = wide && bounds.maxHeight >= 680 ? 28.0 : 0.0;
            return Padding(
              padding: EdgeInsets.all(inset),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 1260,
                    maxHeight: 900,
                  ),
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(inset > 0 ? 24 : 0),
                      border: Border.all(
                        color: colors.outlineVariant.withValues(alpha: 0.35),
                      ),
                      boxShadow: inset > 0
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: dark ? 0.18 : 0.035,
                                ),
                                blurRadius: 40,
                                offset: const Offset(0, 12),
                              ),
                            ]
                          : null,
                    ),
                    child: Row(
                      children: [
                        if (wide) _rail(context, ref, state),
                        Expanded(child: _workspace(context, ref, state, wide)),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _rail(BuildContext context, WidgetRef ref, OnboardingState state) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('onboarding-step-rail'),
      width: 264,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primary.withValues(alpha: 0.09),
            colors.primary.withValues(alpha: 0.025),
          ],
        ),
        border: Border(
          right: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const AppBrandIcon(size: 36, radius: 10),
                    const SizedBox(width: AppSpacing.md),
                    Text(
                      AppIdentity.name,
                      style: AppTypography.headline.copyWith(
                        color: colors.onSurface,
                        fontSize: 24,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xxl),
                Text(
                  '让每一次打印\n都心中有数。',
                  style: AppTypography.headline.copyWith(
                    color: colors.onSurface,
                    fontSize: 22,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _steps.length,
              separatorBuilder: (_, index) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final step = _steps[index];
                final current = index == state.stepIndex;
                final previous = index < state.stepIndex;
                return Semantics(
                  selected: current,
                  child: Material(
                    color: current ? colors.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 2,
                      ),
                      leading: Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: current
                              ? colors.primary
                              : colors.primary.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          '${index + 1}',
                          style: AppTypography.body.copyWith(
                            color: current
                                ? colors.onPrimary
                                : colors.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      title: Text(
                        step.$1,
                        style: AppTypography.body.copyWith(
                          color: colors.onSurface,
                          fontWeight: current
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                      subtitle: current
                          ? Text(
                              '正在设置',
                              style: AppTypography.body.copyWith(
                                fontSize: 11,
                                color: colors.primary,
                              ),
                            )
                          : null,
                      trailing: previous
                          ? Icon(
                              Icons.arrow_back_rounded,
                              size: 14,
                              color: colors.onSurfaceVariant,
                            )
                          : null,
                      onTap: previous && !state.isProcessing
                          ? () => ref
                                .read(onboardingProvider.notifier)
                                .returnToStep(index)
                          : null,
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(28),
            child: Text(
              '按自己的节奏开始。\n稍后可在完整设置中重新运行引导。',
              style: AppTypography.body.copyWith(
                fontSize: 12,
                height: 1.6,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _workspace(
    BuildContext context,
    WidgetRef ref,
    OnboardingState state,
    bool wide,
  ) {
    final colors = Theme.of(context).colorScheme;
    final step = _steps[state.stepIndex];
    return Column(
      children: [
        Padding(
          key: const ValueKey('onboarding-progress-header'),
          padding: EdgeInsets.fromLTRB(wide ? 40 : 20, 24, wide ? 40 : 20, 16),
          child: Column(
            children: [
              Row(
                children: [
                  if (!wide) ...[
                    const AppBrandIcon(size: 28, radius: 8),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      AppIdentity.name,
                      style: AppTypography.title.copyWith(
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                  ],
                  Expanded(
                    child: Text(
                      wide ? '首次设置  /  ${step.$1}' : step.$1,
                      style: AppTypography.body.copyWith(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    '${state.stepIndex + 1} / ${_steps.length}',
                    style: AppTypography.data.copyWith(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Semantics(
                label: '设置进度，第 ${state.stepIndex + 1} 步，共 ${_steps.length} 步',
                child: Row(
                  children: [
                    for (var i = 0; i < _steps.length; i++)
                      Expanded(
                        child: Container(
                          height: 3,
                          margin: EdgeInsets.only(
                            right: i == _steps.length - 1 ? 0 : 6,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            color: i <= state.stepIndex
                                ? colors.primary
                                : colors.primary.withValues(alpha: 0.1),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            key: ValueKey('onboarding-content-${state.stepIndex}'),
            padding: EdgeInsets.fromLTRB(
              wide ? 40 : 20,
              24,
              wide ? 40 : 20,
              32,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 700),
                child: AnimatedSwitcher(
                  duration: AppMotion.duration(
                    context,
                    const Duration(milliseconds: 180),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(state.stepIndex),
                    child: _buildStep(state.stepIndex),
                  ),
                ),
              ),
            ),
          ),
        ),
        _bottomBar(context, ref, state, wide),
      ],
    );
  }

  Widget _bottomBar(
    BuildContext context,
    WidgetRef ref,
    OnboardingState state,
    bool wide,
  ) {
    final colors = Theme.of(context).colorScheme;
    final notifier = ref.read(onboardingProvider.notifier);
    final first = state.stepIndex == 0;
    final last = state.stepIndex == _steps.length - 1;
    return Container(
      key: const ValueKey('onboarding-bottom-bar'),
      padding: EdgeInsets.symmetric(horizontal: wide ? 40 : 20, vertical: 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final actions = <Widget>[
            if (!first)
              TextButton.icon(
                onPressed: state.isProcessing ? null : notifier.back,
                icon: const Icon(Icons.arrow_back_rounded, size: 16),
                label: const Text('上一步'),
              ),
            if (first)
              TextButton(
                onPressed: state.isProcessing
                    ? null
                    : () => _finish(context, notifier.skipAll),
                child: const Text('稍后设置'),
              ),
            if (!first && !last)
              TextButton(
                onPressed: state.isProcessing
                    ? null
                    : () => _finish(context, notifier.complete),
                child: const Text('保存并退出'),
              ),
            FilledButton.icon(
              style: glassButtonStyle(
                context,
                FilledButton.styleFrom(textStyle: AppTypography.button),
                variant: AppGlassButtonVariant.primary,
              ),
              onPressed: state.isProcessing
                  ? null
                  : last
                  ? () => _finish(context, notifier.complete)
                  : notifier.next,
              icon: state.isProcessing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      last ? Icons.check_rounded : Icons.arrow_forward_rounded,
                      size: 17,
                    ),
              label: Text(
                last
                    ? '进入 ${AppIdentity.name}'
                    : first
                    ? '开始设置'
                    : _nextLabel(state),
              ),
            ),
          ];
          if (constraints.maxWidth < 500 ||
              MediaQuery.textScalerOf(context).scale(14) > 20) {
            return Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            );
          }
          return Row(
            children: [
              actions.first,
              const Spacer(),
              for (final action in actions.skip(1)) ...[
                const SizedBox(width: 8),
                action,
              ],
            ],
          );
        },
      ),
    );
  }

  String _nextLabel(OnboardingState state) {
    final configured = switch (state.stepIndex) {
      1 => state.cloudSession != null,
      2 => state.scannedPrinters.isNotEmpty,
      3 => state.configuredPrinters.isNotEmpty,
      4 => state.slicerExePath != null,
      5 => state.costParams != null,
      _ => true,
    };
    return configured ? '继续' : '跳过此步';
  }

  Future<void> _finish(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置未能保存，请重试。')));
      }
    }
  }

  Widget _buildStep(int index) => switch (index) {
    0 => const WelcomeStep(),
    1 => const CloudLoginStep(),
    2 => const LanScanStep(),
    3 => const PrinterConfigStep(),
    4 => const SlicerDetectStep(),
    5 => const CostParamsStep(),
    6 => const CompleteStep(),
    _ => const SizedBox.shrink(),
  };
}
