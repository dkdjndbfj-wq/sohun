import 'package:flutter/material.dart';
import '../core/theme/interaction_effects.dart';
import 'glass_button_material.dart';
export 'glass_button_material.dart' show AppGlassButtonVariant;

/// Explicit glass action, sharing its palette with standard themed buttons.
class AppGlassButton extends StatelessWidget {
  const AppGlassButton({
    super.key,
    this.label,
    required this.onPressed,
    this.icon,
    this.child,
    this.variant = AppGlassButtonVariant.primary,
    this.compact = false,
    this.tint,
    this.padding,
    this.minimumSize,
    this.borderRadius,
    this.tooltip,
    this.onLongPress,
  }) : assert(label != null || child != null);
  final String? label;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final Widget? icon;
  final Widget? child;
  final AppGlassButtonVariant variant;
  final bool compact;
  final Color? tint;
  final EdgeInsetsGeometry? padding;
  final Size? minimumSize;
  final BorderRadius? borderRadius;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null || onLongPress != null;
    final primary =
        variant == AppGlassButtonVariant.primary ||
        variant == AppGlassButtonVariant.danger;
    final radius =
        borderRadius ??
        BorderRadius.circular(variant == AppGlassButtonVariant.quiet ? 12 : 15);
    final shape = RoundedRectangleBorder(borderRadius: radius);
    final palette = GlassButtonPalette.resolve(
      theme,
      variant: variant,
      enabled: enabled,
      tint: tint,
    );
    final button = AppInteractionSurface(
      enabled: enabled,
      hoverScale: 1.008,
      pressedScale: .98,
      hoverOffset: const Offset(0, -.018),
      child: GlassButtonMaterial(
        variant: variant,
        enabled: enabled,
        tint: tint,
        shape: shape,
        child: TextButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          style: ButtonStyle(
            backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            foregroundColor: WidgetStatePropertyAll(palette.foreground),
            iconColor: WidgetStatePropertyAll(palette.foreground),
            elevation: const WidgetStatePropertyAll(0),
            shadowColor: const WidgetStatePropertyAll(Colors.transparent),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            // This control already owns its glass layer. Do not inherit another.
            backgroundBuilder: (context, states, child) =>
                child ?? const SizedBox.shrink(),
            textStyle: WidgetStatePropertyAll(
              theme.textTheme.labelLarge?.copyWith(
                fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
                height: 1.3,
              ),
            ),
            minimumSize: WidgetStatePropertyAll(
              minimumSize ?? Size(0, compact ? 36 : 46),
            ),
            padding: WidgetStatePropertyAll(
              padding ??
                  EdgeInsets.symmetric(
                    horizontal: compact ? 12 : 16,
                    vertical: compact ? 9 : 13,
                  ),
            ),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: WidgetStatePropertyAll(shape),
            side: WidgetStateProperty.resolveWith(
              (states) => BorderSide(
                color: states.contains(WidgetState.focused) && enabled
                    ? palette.foreground.withValues(alpha: .85)
                    : palette.rim,
                width: states.contains(WidgetState.focused) && enabled
                    ? 1.6
                    : 1,
              ),
            ),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return (tint ?? theme.colorScheme.primary).withValues(
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
            animationDuration: AppMotion.duration(
              context,
              const Duration(milliseconds: 160),
            ),
          ),
          child:
              child ??
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    IconTheme(
                      data: IconThemeData(
                        color: palette.foreground,
                        size: compact ? 17 : 19,
                      ),
                      child: icon!,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(child: Text(label!, textAlign: TextAlign.center)),
                ],
              ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
