import 'package:flutter/material.dart';
import '../../widgets/glass_button_material.dart';
import 'interaction_effects.dart';

export '../../widgets/glass_button_material.dart' show AppGlassButtonVariant;

/// Installed only in the personal desktop and mobile themes.
@immutable
class GlassButtonsTheme extends ThemeExtension<GlassButtonsTheme> {
  const GlassButtonsTheme();
  static bool enabledOf(BuildContext context) =>
      Theme.of(context).extension<GlassButtonsTheme>() != null;
  @override
  GlassButtonsTheme copyWith() => this;
  @override
  GlassButtonsTheme lerp(covariant GlassButtonsTheme? other, double t) => this;
}

/// Flutter's SegmentedButton reconstructs its internal TextButton styles and
/// drops layer builders. One shared glass surface preserves native selection,
/// keyboard behavior and the original segment geometry.
class GlassSegmentedSurface extends StatelessWidget {
  const GlassSegmentedSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (!GlassButtonsTheme.enabledOf(context)) return child;
    return GlassButtonMaterial(
      variant: AppGlassButtonVariant.secondary,
      showShadow: false,
      shape:
          Theme.of(context).segmentedButtonTheme.style?.shape?.resolve({}) ??
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: child,
    );
  }
}

/// Wrap explicit per-page styles without changing their sizing or callbacks.
ButtonStyle glassButtonStyle(
  BuildContext context,
  ButtonStyle original, {
  AppGlassButtonVariant variant = AppGlassButtonVariant.primary,
}) => GlassButtonsTheme.enabledOf(context)
    ? _glassStyle(Theme.of(context), original, variant: variant)
    : original;

Color? _styleTint(
  ButtonStyle original,
  Set<WidgetState> states,
  AppGlassButtonVariant variant,
) {
  final background = original.backgroundColor?.resolve(states);
  final foreground = original.foregroundColor?.resolve(states);
  bool chromatic(Color? color) =>
      color != null &&
      color.a > .05 &&
      HSLColor.fromColor(color).saturation > .16;
  if (chromatic(background)) return background;
  if (chromatic(foreground)) return foreground;
  return null;
}

ButtonStyle _glassStyle(
  ThemeData theme,
  ButtonStyle original, {
  required AppGlassButtonVariant variant,
  bool useExplicitTint = true,
  OutlinedBorder? fallbackShape,
}) {
  Color? tint(Set<WidgetState> states) =>
      useExplicitTint ? _styleTint(original, states, variant) : null;
  GlassButtonPalette palette(Set<WidgetState> states) =>
      GlassButtonPalette.resolve(
        theme,
        variant: variant,
        enabled: !states.contains(WidgetState.disabled),
        selected: states.contains(WidgetState.selected),
        tint: tint(states),
      );
  final shape =
      original.shape ??
      WidgetStatePropertyAll<OutlinedBorder>(
        fallbackShape ??
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                variant == AppGlassButtonVariant.quiet ? 12 : 15,
              ),
            ),
      );
  return original.copyWith(
    backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
    animationDuration: Duration.zero,
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => palette(states).foreground,
    ),
    iconColor: WidgetStateProperty.resolveWith(
      (states) => palette(states).foreground,
    ),
    shape: shape,
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.focused)
            ? palette(states).foreground.withValues(alpha: .85)
            : palette(states).rim,
        width: states.contains(WidgetState.focused) ? 1.6 : 1,
      ),
    ),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return (tint(states) ?? theme.colorScheme.primary).withValues(
          alpha: .15,
        );
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return Colors.white.withValues(
          alpha: theme.brightness == Brightness.dark ? .09 : .20,
        );
      }
      return Colors.transparent;
    }),
    backgroundBuilder: (context, states, child) => AppInteractionSurface(
      enabled: !states.contains(WidgetState.disabled),
      hoverScale: 1.008,
      pressedScale: .98,
      hoverOffset: const Offset(0, -.018),
      child: GlassButtonMaterial(
        variant: variant,
        enabled: !states.contains(WidgetState.disabled),
        selected: states.contains(WidgetState.selected),
        tint: tint(states),
        shape: shape.resolve(states),
        showShadow: false,
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}

ThemeData applyGlassButtonTheme(ThemeData base) => base.copyWith(
  extensions: [
    ...base.extensions.values.where((value) => value is! GlassButtonsTheme),
    const GlassButtonsTheme(),
  ],
  filledButtonTheme: FilledButtonThemeData(
    style: _glassStyle(
      base,
      base.filledButtonTheme.style ?? const ButtonStyle(),
      variant: AppGlassButtonVariant.primary,
      useExplicitTint: false,
    ),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: _glassStyle(
      base,
      base.elevatedButtonTheme.style ??
          base.filledButtonTheme.style ??
          const ButtonStyle(),
      variant: AppGlassButtonVariant.primary,
      useExplicitTint: false,
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: _glassStyle(
      base,
      base.outlinedButtonTheme.style ?? const ButtonStyle(),
      variant: AppGlassButtonVariant.secondary,
      useExplicitTint: false,
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: _glassStyle(
      base,
      base.textButtonTheme.style ?? const ButtonStyle(),
      variant: AppGlassButtonVariant.quiet,
      useExplicitTint: false,
    ),
  ),
  iconButtonTheme: IconButtonThemeData(
    style: _glassStyle(
      base,
      base.iconButtonTheme.style ?? const ButtonStyle(),
      variant: AppGlassButtonVariant.quiet,
      useExplicitTint: false,
      fallbackShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
  ),
  segmentedButtonTheme: SegmentedButtonThemeData(
    style:
        _glassStyle(
          base,
          base.segmentedButtonTheme.style ?? const ButtonStyle(),
          variant: AppGlassButtonVariant.secondary,
          useExplicitTint: false,
        ).copyWith(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? base.colorScheme.primary.withValues(alpha: .18)
                : Colors.transparent,
          ),
        ),
  ),
  menuButtonTheme: MenuButtonThemeData(
    style: _glassStyle(
      base,
      base.menuButtonTheme.style ?? const ButtonStyle(),
      variant: AppGlassButtonVariant.quiet,
      useExplicitTint: false,
    ),
  ),
);
