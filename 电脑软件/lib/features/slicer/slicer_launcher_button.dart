import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../providers/slicer_provider.dart';
import '../../widgets/confirm_dialog.dart';

/// 切片软件启动按钮。
///
/// 显示当前选中的切片软件图标 + 名称，点击启动对应切片软件。
/// 检测不到时按钮变灰，点击提示用户去设置手动指定路径。
///
/// 图标资源来自 [SlicerDetector.iconAsset]（如 assets/images/brands/拓竹.png）。
class SlicerLauncherButton extends ConsumerWidget {
  final bool compact;

  const SlicerLauncherButton({super.key, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slicerStatusAsync = ref.watch(activeSlicerStatusProvider);
    final detector = ref.watch(activeSlicerDetectorProvider);

    return slicerStatusAsync.when(
      loading: () => _buildButton(
        context: context,
        icon: null,
        label: '检测中…',
        enabled: false,
        onTap: null,
      ),
      error: (e, _) => _buildButton(
        context: context,
        icon: null,
        label: '检测失败',
        enabled: false,
        onTap: null,
      ),
      data: (status) {
        final isInstalled = status?.isInstalled ?? false;
        final displayName = detector?.displayName ?? '切片软件';
        return _buildButton(
          context: context,
          icon: detector?.iconAsset,
          label: compact
              ? (isInstalled ? '启动' : '未安装')
              : (isInstalled ? '启动 $displayName' : '$displayName 未安装'),
          enabled: isInstalled,
          onTap: isInstalled
              ? () => _launch(context, ref, status!.executablePath!)
              : () => _showNotInstalledHint(context, displayName),
        );
      },
    );
  }

  Widget _buildButton({
    required BuildContext context,
    required String? icon,
    required String label,
    required bool enabled,
    required VoidCallback? onTap,
  }) {
    if (GlassButtonsTheme.enabledOf(context)) {
      return AppGlassButton(
        label: label,
        onPressed: onTap,
        variant: enabled
            ? AppGlassButtonVariant.secondary
            : AppGlassButtonVariant.quiet,
        compact: true,
        minimumSize: Size(0, compact ? 30 : 36),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 6 : 8,
        ),
        icon: icon != null
            ? _SlicerIcon(iconAsset: icon, size: compact ? 16 : 20)
            : Icon(Icons.extension_outlined, size: compact ? 16 : 20),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppColors.radiusLg),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 14,
            vertical: compact ? 6 : 8,
          ),
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.primaryContainer
                : AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(AppColors.radiusLg),
            border: Border.all(
              color: enabled
                  ? AppColors.primary.withValues(alpha: 0.3)
                  : AppColors.border.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null)
                _SlicerIcon(iconAsset: icon, size: compact ? 16 : 20)
              else
                Icon(
                  Icons.extension_outlined,
                  size: compact ? 16 : 20,
                  color: enabled ? AppColors.primary : AppColors.textTertiary,
                ),
              SizedBox(width: compact ? 6 : 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: compact ? 12 : 13,
                  fontWeight: FontWeight.w600,
                  color: enabled ? AppColors.primary : AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _launch(
    BuildContext context,
    WidgetRef ref,
    String executablePath,
  ) async {
    final detector = ref.read(activeSlicerDetectorProvider);
    if (detector == null) return;

    final ok = await detector.launch(executablePath: executablePath);
    if (!context.mounted) return;

    showSnack(
      context,
      ok ? '已启动 ${detector.displayName}' : '启动失败，请检查路径',
      error: !ok,
      duration: const Duration(seconds: 2),
    );
  }

  void _showNotInstalledHint(BuildContext context, String name) {
    showSnack(
      context,
      '未检测到 $name，请到设置页手动指定路径',
      error: true,
      duration: const Duration(seconds: 3),
    );
  }
}

/// 切片软件图标。优先加载 iconAsset，加载失败回退到默认图标。
class _SlicerIcon extends StatelessWidget {
  final String iconAsset;
  final double size;

  const _SlicerIcon({required this.iconAsset, required this.size});

  @override
  Widget build(BuildContext context) {
    final cacheSize = (size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 256);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Image.asset(
        iconAsset,
        width: size,
        height: size,
        cacheWidth: cacheSize,
        cacheHeight: cacheSize,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Icon(
          Icons.extension_outlined,
          size: size,
          color: AppColors.primary,
        ),
      ),
    );
  }
}
