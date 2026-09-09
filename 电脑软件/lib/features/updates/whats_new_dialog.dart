import 'package:flutter/material.dart';

import '../../core/releases/app_release_notes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/interaction_effects.dart';
import '../../widgets/app_brand_icon.dart';
import '../../widgets/app_button.dart';
import '../../widgets/glass_card.dart';

abstract final class WhatsNewDialog {
  static Future<void> show(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭本次更新',
      barrierColor: Colors.black.withValues(alpha: 0.30),
      transitionDuration: AppMotion.duration(
        context,
        const Duration(milliseconds: 260),
      ),
      pageBuilder: (context, _, __) => const Center(
        child: _WhatsNewPanel(notes: AppReleaseNotes.current),
      ),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.975, end: 1).animate(curved),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.018),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _WhatsNewPanel extends StatelessWidget {
  const _WhatsNewPanel({required this.notes});

  final AppReleaseNotes notes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.sizeOf(context);
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          maxHeight: (size.height - 56).clamp(420, 720),
        ),
        child: GlassCard(
          level: GlassLevel.l3,
          borderRadius: BorderRadius.circular(AppColors.radiusXl),
          padding: EdgeInsets.zero,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        scheme.primary.withValues(alpha: isDark ? 0.18 : 0.11),
                        scheme.secondary
                            .withValues(alpha: isDark ? 0.10 : 0.05),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const AppBrandIcon(size: 58, radius: 15),
                      const SizedBox(width: AppSpacing.lg),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                _Badge(text: notes.version),
                                const _Badge(text: '本次更新'),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              notes.title,
                              style: AppTypography.headline.copyWith(
                                fontSize: 24,
                                height: 1.12,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              notes.summary,
                              style: AppTypography.body.copyWith(
                                color: scheme.onSurfaceVariant,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    AppSpacing.lg,
                    AppSpacing.xl,
                    AppSpacing.md,
                  ),
                  child: Column(
                    children: [
                      for (var index = 0;
                          index < notes.items.length;
                          index++) ...[
                        _ReleaseNoteTile(note: notes.items[index]),
                        if (index != notes.items.length - 1)
                          const SizedBox(height: AppSpacing.sm),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    AppSpacing.sm,
                    AppSpacing.xl,
                    AppSpacing.xl,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '自动弹层每个版本只出现一次，之后可在“关于与更新”中回看。',
                          style: AppTypography.label.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      AppButton(
                        label: '开始使用',
                        icon: const Icon(Icons.arrow_forward_rounded, size: 17),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
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

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: AppTypography.label.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ReleaseNoteTile extends StatefulWidget {
  const _ReleaseNoteTile({required this.note});

  final AppReleaseNote note;

  @override
  State<_ReleaseNoteTile> createState() => _ReleaseNoteTileState();
}

class _ReleaseNoteTileState extends State<_ReleaseNoteTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (widget.note.kind) {
      AppReleaseNoteKind.appearance => Icons.tune_rounded,
      AppReleaseNoteKind.account => Icons.person_outline_rounded,
      AppReleaseNoteKind.workflow => Icons.auto_awesome_motion_rounded,
      AppReleaseNoteKind.performance => Icons.bolt_rounded,
    };
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 170),
        ),
        curve: Curves.easeOutCubic,
        transform: _hovering && AppMotion.enabled(context)
            ? Matrix4.translationValues(2, 0, 0)
            : Matrix4.identity(),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: _hovering ? 0.07 : 0.035),
          borderRadius: BorderRadius.circular(AppColors.radiusLg),
          border: Border.all(
            color: scheme.primary.withValues(alpha: _hovering ? 0.16 : 0.08),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: scheme.primary, size: 19),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.note.title,
                    style: AppTypography.title.copyWith(fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.note.description,
                    style: AppTypography.label.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
