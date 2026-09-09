import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_typography.dart';
import '../core/theme/glass_button_theme.dart';
import '../widgets/glass_card.dart';

Color mobileCanvasColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFF171A18)
    : const Color(0xFFF4F6F5);

Color mobileAccentTextColor(ThemeData theme) =>
    theme.brightness == Brightness.dark
    ? theme.colorScheme.primary
    : Color.lerp(theme.colorScheme.primary, Colors.black, 0.4)!;

/// An opaque canvas under translucent mobile surfaces. Its accent is the
/// desktop's selected accent; static gradients do not keep a ticker running.
class MobileGlassBackground extends StatelessWidget {
  const MobileGlassBackground({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ColoredBox(
      color: mobileCanvasColor(theme.brightness),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-1.1, -0.9),
                    radius: 1.35,
                    colors: [
                      theme.colorScheme.primary.withValues(
                        alpha: dark ? 0.16 : 0.13,
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(1.2, 0.45),
                    radius: 1.2,
                    colors: [
                      theme.colorScheme.secondary.withValues(
                        alpha: dark ? 0.12 : 0.10,
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Keep each route opaque during transitions; only surfaces inside it are
/// translucent. Standalone tools can opt in without changing their logic.
class MobileScaffold extends StatelessWidget {
  const MobileScaffold({
    super.key,
    this.appBar,
    this.body,
    this.bottomNavigationBar,
    this.resizeToAvoidBottomInset,
  });
  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Widget? bottomNavigationBar;
  final bool? resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) => MobileGlassBackground(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: appBar,
      body: body,
      bottomNavigationBar: bottomNavigationBar,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    ),
  );
}

/// A single blur for a toolbar, rather than a separate filter per control.
class MobileGlassBar extends StatelessWidget {
  const MobileGlassBar({super.key});
  @override
  Widget build(BuildContext context) => const MobileGlassSurface(
    radius: 0,
    opacity: 0.48,
    child: SizedBox.expand(),
  );
}

/// Reuses the desktop GlassCard's rim, translucent fill and typography.
/// Large surfaces blur once; densely repeated inventory rows pass blur: 0.
class MobileGlassSurface extends StatelessWidget {
  const MobileGlassSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.margin,
    this.radius = AppColors.radiusLg,
    this.blur = 16,
    this.opacity = 0.58,
    this.onTap,
    this.elevated = false,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final double blur;
  final double opacity;
  final VoidCallback? onTap;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);
    final surface = GlassCard(
      level: GlassLevel.l1,
      padding: padding,
      borderRadius: borderRadius,
      opacity: opacity,
      boxShadow: const [],
      enableHover: false,
      hoverEffect: GlassHoverEffect.none,
      onTap: onTap,
      child: child,
    );
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: elevated
            ? (dark ? AppColors.shadow2Dark : AppColors.shadow2)
            : (dark ? AppColors.shadow1Dark : AppColors.shadow1),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: blur == 0
            ? surface
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: surface,
              ),
      ),
    );
  }
}

/// Shared desktop-style modal glass, including a drag handle within the same
/// material. Flexible keeps long forms and 2x text inside the available height.
Future<T?> showMobileGlassBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool showDragHandle = false,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: isScrollControlled,
  useSafeArea: useSafeArea,
  showDragHandle: false,
  backgroundColor: Colors.transparent,
  elevation: 0,
  builder: (context) => MobileGlassSurface(
    radius: AppColors.radiusXl,
    opacity: Theme.of(context).brightness == Brightness.dark ? 0.88 : 0.8,
    blur: 24,
    elevated: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showDragHandle)
          ExcludeSemantics(
            child: Center(
              child: Container(
                width: 32,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        Flexible(child: builder(context)),
      ],
    ),
  ),
);

/// Shares the desktop typography, glass tokens and controls. Unmigrated
/// third-party routes remain opaque; MobileScaffold supplies a glass canvas.
ThemeData buildMobileTheme(ThemeData desktop) {
  final dark = desktop.brightness == Brightness.dark;
  final scheme = desktop.colorScheme.copyWith(
    error: dark
        ? desktop.colorScheme.error
        : Color.lerp(desktop.colorScheme.error, Colors.black, 0.25),
  );
  final accentText = mobileAccentTextColor(desktop);
  final families = AppTypography.chineseFontFamily
      .split(',')
      .map((font) => font.trim())
      .toList();
  TextStyle style(TextStyle? base) => (base ?? AppTypography.body).copyWith(
    fontFamily: families.first,
    fontFamilyFallback: [
      ...families.skip(1),
      'Noto Sans CJK SC',
      'Noto Sans SC',
    ],
  );
  final text = TextTheme(
    displayLarge: style(desktop.textTheme.displayLarge),
    displayMedium: style(desktop.textTheme.displayMedium),
    displaySmall: style(desktop.textTheme.displaySmall),
    headlineLarge: style(desktop.textTheme.headlineLarge),
    headlineMedium: style(desktop.textTheme.headlineMedium),
    headlineSmall: style(desktop.textTheme.headlineSmall),
    titleLarge: style(desktop.textTheme.titleLarge),
    titleMedium: style(desktop.textTheme.titleMedium),
    titleSmall: style(desktop.textTheme.titleSmall),
    bodyLarge: style(desktop.textTheme.bodyLarge),
    bodyMedium: style(desktop.textTheme.bodyMedium),
    bodySmall: style(desktop.textTheme.bodySmall),
    labelLarge: style(desktop.textTheme.labelLarge),
    labelMedium: style(desktop.textTheme.labelMedium),
    labelSmall: style(desktop.textTheme.labelSmall),
  );
  final action = Color.lerp(
    scheme.primary,
    dark ? Colors.white : Colors.black,
    dark ? 0.16 : 0.25,
  )!;
  final outline = (dark
      ? AppColors.glassBorderDarkMode
      : AppColors.glassBorder);
  final fieldFill = (dark ? AppColors.glassFillL1Dark : AppColors.glassFillL1)
      .withValues(alpha: dark ? 0.4 : 0.5);
  return applyGlassButtonTheme(
    desktop.copyWith(
      colorScheme: scheme,
      textTheme: text,
      primaryTextTheme: text,
      scaffoldBackgroundColor: mobileCanvasColor(desktop.brightness),
      appBarTheme: desktop.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 16,
        toolbarHeight: 56,
        titleTextStyle: style(desktop.appBarTheme.titleTextStyle),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: action,
          foregroundColor: dark ? const Color(0xFF102019) : Colors.white,
          textStyle: text.labelLarge,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          backgroundColor: fieldFill,
          textStyle: text.labelLarge,
          minimumSize: const Size(0, 48),
          side: BorderSide(color: outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentText,
          textStyle: text.labelMedium,
          minimumSize: const Size(44, 44),
        ),
      ),
      inputDecorationTheme: desktop.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: fieldFill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        labelStyle: text.bodyMedium,
        hintStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
        errorMaxLines: 3,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppColors.radiusMd),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppColors.radiusMd),
          borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.7)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: scheme.primary.withValues(alpha: 0.12),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelSmall?.copyWith(
            color: states.contains(WidgetState.selected)
                ? accentText
                : scheme.onSurfaceVariant,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? accentText
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(text.labelLarge),
          side: WidgetStatePropertyAll(BorderSide(color: outline)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary.withValues(alpha: 0.13)
                : fieldFill,
          ),
          foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
        ),
      ),
      bottomSheetTheme: desktop.bottomSheetTheme.copyWith(
        backgroundColor: Color.alphaBlend(
          fieldFill,
          mobileCanvasColor(desktop.brightness),
        ),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppColors.radiusXl),
          ),
        ),
      ),
    ),
  );
}
