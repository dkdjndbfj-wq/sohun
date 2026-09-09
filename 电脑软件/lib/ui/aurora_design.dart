import 'package:flutter/material.dart';

import '../core/theme/glass_button_theme.dart';
import '../widgets/app_glass_button.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_typography.dart';
import '../core/theme/interaction_effects.dart';
import '../core/theme/personal_desktop_theme.dart';
import '../widgets/bambu_icon.dart';
import '../widgets/glass_card.dart';
import '../widgets/personal_desktop_chrome.dart';

class Aurora {
  Aurora._();

  static Color primary = const Color(0xFF00B42A);
  static Color primaryHover = const Color(0xFF00A426);
  static Color ink = const Color(0xFF121614);
  static Color text = const Color(0xFF1F2923);
  static Color textSoft = const Color(0xFF5B665F);
  static Color muted = const Color(0xFF8A938D);
  static Color line = AppColors.divider;
  static Color fill = AppColors.surfaceContainerHigh;
  static Color panel = const Color(0xDFFFFFFF);
  static Color panelStrong = const Color(0xF2FFFFFF);
  static const warning = Color(0xFFFF9F0A);
  static const danger = Color(0xFFE5484D);
  static const blue = Color(0xFF1677FF);
  static const violet = Color(0xFF7C3AED);

  static const radius = AppColors.radiusSm;
  static const sidebarWidth = 232.0;
  static const sidebarClosed = 64.0;

  static TextStyle get mono => TextStyle(
    fontFamily: AppTypography.monoFontFamily,
    fontWeight: FontWeight.w700,
    color: text,
  );

  static void applyTheme({required Color primaryColor, required bool dark}) {
    primary = primaryColor;
    primaryHover = Color.lerp(primaryColor, Colors.black, 0.12) ?? primaryColor;
    if (dark) {
      ink = const Color(0xFFF4F7F5);
      text = const Color(0xFFE8ECE9);
      textSoft = const Color(0xFFAFB8B2);
      muted = const Color(0xFF7E8982);
      line = AppColors.dividerDark;
      fill = AppColors.surfaceVariantDark;
      panel = const Color(0xD9242B27);
      panelStrong = const Color(0xF22A312D);
    } else {
      ink = const Color(0xFF121614);
      text = const Color(0xFF1F2923);
      textSoft = const Color(0xFF5B665F);
      muted = const Color(0xFF8A938D);
      line = AppColors.divider;
      fill = AppColors.surfaceContainerHigh;
      panel = const Color(0xDFFFFFFF);
      panelStrong = const Color(0xF2FFFFFF);
    }
  }

  static TextStyle title(BuildContext context) =>
      Theme.of(context).textTheme.titleLarge!.copyWith(
        fontFamily: PersonalDesktopTheme.of(context) == null
            ? AppTypography.chineseFontFamily
            : null,
        fontSize: 18,
        fontWeight: PersonalDesktopTheme.of(context) == null
            ? FontWeight.w700
            : FontWeight.w600,
        color: text,
        letterSpacing: 0,
      );

  static TextStyle label(BuildContext context) =>
      Theme.of(context).textTheme.bodySmall!.copyWith(
        fontFamily: PersonalDesktopTheme.of(context) == null
            ? AppTypography.chineseFontFamily
            : null,
        fontSize: 12,
        color: textSoft,
        letterSpacing: 0,
      );
}

class AuroraBackground extends StatelessWidget {
  final Widget child;
  const AuroraBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (PersonalDesktopTheme.of(context) != null) {
      return PersonalDesktopBackground(child: child);
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: isDark ? const Color(0xFF171A18) : const Color(0xFFF4F6F5),
      child: child,
    );
  }
}

class FrostPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final bool elevated;
  final VoidCallback? onTap;

  const FrostPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.color,
    this.elevated = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final personal = PersonalDesktopTheme.of(context);
    return GlassCard(
      padding: padding,
      margin: margin,
      borderRadius: BorderRadius.circular(personal?.radius ?? Aurora.radius),
      color: color ?? (personal == null ? Aurora.panel : null),
      level: elevated ? GlassLevel.l3 : GlassLevel.l2,
      boxShadow: elevated
          ? (isDark ? AppColors.shadow3Dark : AppColors.shadow3)
          : personal != null
          ? (isDark ? AppColors.shadow1Dark : AppColors.shadowCard)
          : (isDark ? AppColors.shadow2Dark : AppColors.shadow2),
      onTap: onTap,
      child: child,
    );
  }
}

class BambuGlyphButton extends StatelessWidget {
  final String icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final Color? background;
  final double size;

  const BambuGlyphButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
    this.background,
    this.size = 34,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Aurora.textSoft;
    if (GlassButtonsTheme.enabledOf(context)) {
      return Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 450),
        child: SizedBox.square(
          dimension: size,
          child: AppGlassButton(
            label: tooltip,
            onPressed: onPressed,
            variant: AppGlassButtonVariant.quiet,
            tint: color,
            compact: true,
            minimumSize: Size.square(size),
            padding: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(12),
            child: Builder(
              builder: (context) => BambuIcon(
                name: icon,
                size: 18,
                color: IconTheme.of(context).color,
                applyColorFilter: true,
              ),
            ),
          ),
        ),
      );
    }
    return AppInteractionSurface(
      enabled: onPressed != null,
      hoverScale: 1.045,
      pressedScale: 0.92,
      hoverOffset: const Offset(0, -0.025),
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 450),
        child: SizedBox.square(
          dimension: size,
          child: Material(
            color: background ?? Colors.transparent,
            borderRadius: BorderRadius.circular(Aurora.radius),
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(Aurora.radius),
              child: Center(
                child: BambuIcon(
                  name: icon,
                  size: 18,
                  color: onPressed == null ? Aurora.muted : effectiveColor,
                  applyColorFilter: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuroraButton extends StatelessWidget {
  final String label;
  final String icon;
  final VoidCallback? onPressed;
  final bool filled;
  final Color? color;

  const AuroraButton({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.filled = true,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Aurora.primary;
    final fg = filled ? Colors.white : effectiveColor;
    if (GlassButtonsTheme.enabledOf(context)) {
      return SizedBox(
        height: 36,
        child: AppGlassButton(
          label: label,
          onPressed: onPressed,
          variant: filled
              ? AppGlassButtonVariant.primary
              : AppGlassButtonVariant.secondary,
          tint: effectiveColor,
          compact: true,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          icon: Builder(
            builder: (context) => BambuIcon(
              name: icon,
              size: 16,
              color: IconTheme.of(context).color,
              applyColorFilter: true,
            ),
          ),
        ),
      );
    }
    return AppInteractionSurface(
      enabled: onPressed != null,
      child: SizedBox(
        height: 36,
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: BambuIcon(
            name: icon,
            size: 16,
            color: fg,
            applyColorFilter: true,
          ),
          label: Text(label),
          style: FilledButton.styleFrom(
            backgroundColor: filled
                ? effectiveColor
                : effectiveColor.withValues(alpha: 0.09),
            foregroundColor: fg,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Aurora.radius),
            ),
            textStyle: const TextStyle(
              fontFamily: AppTypography.chineseFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ),
      ),
    );
  }
}

class MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final String icon;
  final Color color;

  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return FrostPanel(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(Aurora.radius),
            ),
            child: Center(
              child: BambuIcon(
                name: icon,
                size: 20,
                color: color,
                applyColorFilter: true,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Aurora.label(context)),
                const SizedBox(height: 3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Aurora.mono.copyWith(fontSize: 23),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        unit,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Aurora.label(context),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const SectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Aurora.title(context)),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: Aurora.label(context)),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const StatusPill({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(Aurora.radius),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

String formatGrams(double grams) {
  if (grams >= 1000) return '${(grams / 1000).toStringAsFixed(2)} kg';
  return '${grams.toStringAsFixed(0)} g';
}

String formatDate(DateTime? value) {
  if (value == null) return '-';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}

Color parseHexColor(String hex) {
  final cleaned = hex.replaceAll('#', '').trim();
  if (cleaned.length != 6) return AppColors.primary;
  final value = int.tryParse(cleaned, radix: 16);
  if (value == null) return AppColors.primary;
  return Color(0xFF000000 | value);
}
