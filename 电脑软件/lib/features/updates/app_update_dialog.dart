import 'package:flutter/material.dart';

import '../../core/app_identity.dart';
import '../../core/services/app_update_service.dart';
import '../../core/theme/interaction_effects.dart';
import '../../widgets/app_brand_icon.dart';
import '../../widgets/app_glass_button.dart';
import '../../widgets/glass_card.dart';

/// Manual prompts share the root gate's material and truthful browser handoff.
abstract final class AppUpdateDialog {
  static Future<void> show(
    BuildContext context,
    AppUpdateState update, {
    required Future<bool> Function() onDownload,
    Future<void> Function()? onRetry,
    VoidCallback? onSkipVersion,
  }) async {
    if (!update.hasUpdate) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: !update.isMandatory,
      barrierLabel: update.isMandatory ? '需要更新' : '稍后提醒',
      barrierColor: Colors.black.withValues(alpha: .34),
      pageBuilder: (dialogContext, _, __) => PopScope(
        canPop: !update.isMandatory,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: AppUpdatePanel(
                update: update,
                onDownload: onDownload,
                onRetry: onRetry,
                onLater: update.isMandatory
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                onSkipVersion: update.isMandatory || onSkipVersion == null
                    ? null
                    : () {
                        onSkipVersion();
                        Navigator.of(dialogContext).pop();
                      },
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (context, animation, _, child) {
        final curve = animation.drive(CurveTween(curve: Curves.easeOutCubic));
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(
            scale: curve.drive(Tween<double>(begin: .97, end: 1)),
            child: child,
          ),
        );
      },
      transitionDuration: AppMotion.duration(
        context,
        const Duration(milliseconds: 220),
      ),
    );
  }
}

/// Release notes scroll independently. Short windows and enlarged text use
/// one scroll view so the footer never consumes the entire available height.
class AppUpdatePanel extends StatefulWidget {
  const AppUpdatePanel({
    super.key,
    required this.update,
    required this.onDownload,
    this.onRetry,
    this.onLater,
    this.onSkipVersion,
  });
  final AppUpdateState update;
  final Future<bool> Function() onDownload;
  final Future<void> Function()? onRetry;
  final VoidCallback? onLater;
  final VoidCallback? onSkipVersion;

  @override
  State<AppUpdatePanel> createState() => _AppUpdatePanelState();
}

class _AppUpdatePanelState extends State<AppUpdatePanel> {
  bool _opening = false;
  bool _opened = false;
  bool _retrying = false;
  String? _error;

  @override
  void didUpdateWidget(covariant AppUpdatePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.update.latestVersion != widget.update.latestVersion ||
        oldWidget.update.downloadUri != widget.update.downloadUri) {
      _opened = false;
      _error = null;
    }
  }

  Future<void> _download() async {
    if (_opening || widget.update.downloadUri == null) return;
    final uri = widget.update.downloadUri;
    setState(() {
      _opening = true;
      _error = null;
    });
    var opened = false;
    try {
      opened = await widget.onDownload();
    } catch (_) {
      // Platform launcher failures must never dismiss the mandatory gate.
    }
    if (!mounted) return;
    setState(() {
      _opening = false;
      if (uri != widget.update.downloadUri) return;
      _opened = opened;
      _error = opened ? null : '未能打开下载页面，请重试或重新检查更新。';
    });
  }

  Future<void> _retry() async {
    if (_retrying || widget.update.isChecking || widget.onRetry == null) return;
    setState(() {
      _retrying = true;
      _error = null;
    });
    try {
      await widget.onRetry!();
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法连接更新服务，请稍后重试。');
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final update = widget.update;
    final dark = theme.brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final availableHeight =
        (media.size.height -
                media.padding.vertical -
                media.viewInsets.vertical -
                32)
            .clamp(120.0, double.infinity);
    final checking = _retrying || update.isChecking;
    final accent = updateAccentColor(theme);
    final notes = update.releaseNotes?.trim();
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppBrandIcon(size: 44, radius: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  AppIdentity.name,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              if (!update.isMandatory && widget.onLater != null)
                IconButton(
                  key: const ValueKey('update-close'),
                  tooltip: '稍后提醒',
                  onPressed: widget.onLater,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: .09),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              update.isMandatory ? '必要更新' : '有新版本可用',
              style: theme.textTheme.labelMedium?.copyWith(color: accent),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            update.isMandatory ? '更新后继续使用' : '发现新版本',
            key: const ValueKey('update-heading'),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontSize: 25,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            update.isMandatory
                ? '当前版本已不再受支持，请安装新版后继续使用。'
                : '新版本已经准备好，你可以现在更新，也可以稍后继续。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 20),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: .035),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.colorScheme.onSurface.withValues(alpha: .05),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 10,
                children: [
                  _VersionLabel(label: '当前版本', version: update.currentVersion),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  _VersionLabel(
                    label: '新版本',
                    version: update.latestVersion ?? '—',
                    accent: accent,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            '这次更新',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            notes?.isNotEmpty == true ? notes! : '发布方暂未提供详细说明。你可以在下载页面查看版本信息。',
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.6,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (update.isMandatory) ...[
            const SizedBox(height: 16),
            Text(
              '请保留现有应用数据，完成安装后重新打开 sohun。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ],
        ],
      ),
    );
    final footer = Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null)
            UpdateMessage(message: _error!, error: true)
          else if (update.message != null &&
              update.phase == AppUpdatePhase.failed)
            UpdateMessage(message: update.message!, error: true)
          else if (_opened)
            const UpdateMessage(
              message: '下载页面已打开。请在浏览器中完成下载与安装，然后重新打开 sohun。',
              icon: Icons.open_in_new_rounded,
            )
          else if (update.downloadUri == null)
            const UpdateMessage(
              message: '暂未获取到可用下载地址，请重新检查。',
              icon: Icons.link_off_rounded,
            ),
          if (checking) ...[
            Semantics(
              liveRegion: true,
              child: Text('正在重新检查更新…', style: theme.textTheme.bodySmall),
            ),
            const SizedBox(height: 8),
            if (AppMotion.enabled(context))
              const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 12),
          ],
          AppGlassButton(
            key: const ValueKey('update-download'),
            onPressed: _opening || update.downloadUri == null
                ? null
                : _download,
            icon: _opening && AppMotion.enabled(context)
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    _opened
                        ? Icons.open_in_new_rounded
                        : Icons.download_rounded,
                    size: 19,
                  ),
            label: _opening
                ? '正在打开下载页…'
                : _opened
                ? '再次打开下载页'
                : '立即更新',
          ),
          const SizedBox(height: 8),
          if (!update.isMandatory && widget.onLater != null)
            AppGlassButton(
              key: const ValueKey('update-later'),
              onPressed: widget.onLater,
              variant: AppGlassButtonVariant.secondary,
              label: '稍后提醒',
            ),
          if (widget.onRetry != null ||
              (!update.isMandatory && widget.onSkipVersion != null))
            const SizedBox(height: 12),
          if (widget.onRetry != null ||
              (!update.isMandatory && widget.onSkipVersion != null))
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                if (widget.onRetry != null)
                  AppGlassButton(
                    key: const ValueKey('update-retry'),
                    compact: true,
                    variant: AppGlassButtonVariant.quiet,
                    onPressed: checking ? null : _retry,
                    label: '重新检查',
                  ),
                if (!update.isMandatory && widget.onSkipVersion != null)
                  AppGlassButton(
                    key: const ValueKey('update-skip'),
                    compact: true,
                    variant: AppGlassButtonVariant.quiet,
                    onPressed: widget.onSkipVersion,
                    label: '跳过此版本',
                  ),
              ],
            ),
          if (!_opened && !_opening) ...[
            const SizedBox(height: 12),
            Text(
              '将使用浏览器打开下载页面',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ],
        ],
      ),
    );
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      namesRoute: true,
      label: update.isMandatory ? '必须更新' : '软件更新',
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: availableHeight,
          ),
          child: GlassCard(
            level: GlassLevel.l3,
            opacity: dark ? .80 : .70,
            blur: 22,
            enableHover: false,
            padding: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(26),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxHeight < 540 ||
                    media.textScaler.scale(14) > 19) {
                  return SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [body, footer],
                    ),
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(child: SingleChildScrollView(child: body)),
                    footer,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

Color updateAccentColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? theme.colorScheme.primary
    : Color.lerp(theme.colorScheme.primary, Colors.black, .4)!;

class _VersionLabel extends StatelessWidget {
  const _VersionLabel({
    required this.label,
    required this.version,
    this.accent,
  });
  final String label;
  final String version;
  final Color? accent;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 4),
      Text(
        version,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: accent,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );
}

class UpdateMessage extends StatelessWidget {
  const UpdateMessage({
    super.key,
    required this.message,
    this.error = false,
    this.icon = Icons.info_outline_rounded,
  });
  final String message;
  final bool error;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = error ? theme.colorScheme.error : updateAccentColor(theme);
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error ? Icons.error_outline_rounded : icon,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
