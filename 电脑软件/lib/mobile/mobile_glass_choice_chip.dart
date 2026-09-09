import 'package:flutter/material.dart';

import '../core/theme/glass_button_theme.dart' show GlassButtonsTheme;
import '../widgets/glass_button_material.dart';

/// Keeps ChoiceChip selection, focus, checkmark and hit-target semantics while
/// sharing the personal action-button material. Other themes keep the flat chip.
class MobileGlassChoiceChip extends StatelessWidget {
  const MobileGlassChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.showCheckmark,
    this.labelStyle,
    this.selectedColor,
    this.side,
    this.padding,
  });

  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final bool? showCheckmark;
  final TextStyle? labelStyle;
  final Color? selectedColor;
  final BorderSide? side;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final glass = GlassButtonsTheme.enabledOf(context);
    final theme = Theme.of(context);
    final variant = selected
        ? AppGlassButtonVariant.primary
        : AppGlassButtonVariant.quiet;
    final enabled = onSelected != null;
    final palette = GlassButtonPalette.resolve(
      theme,
      variant: variant,
      enabled: enabled,
      selected: selected,
    );
    final shape = theme.chipTheme.shape ?? const StadiumBorder();
    final baseLabel =
        labelStyle ??
        (selected ? theme.chipTheme.secondaryLabelStyle : null) ??
        theme.chipTheme.labelStyle ??
        theme.textTheme.labelLarge;
    final chip = ChoiceChip(
      label: label,
      selected: selected,
      onSelected: onSelected,
      showCheckmark: showCheckmark,
      labelStyle: glass
          ? baseLabel?.copyWith(color: palette.foreground)
          : labelStyle,
      selectedColor: glass ? Colors.transparent : selectedColor,
      color: glass ? const WidgetStatePropertyAll(Colors.transparent) : null,
      backgroundColor: glass ? Colors.transparent : null,
      disabledColor: glass ? Colors.transparent : null,
      surfaceTintColor: glass ? Colors.transparent : null,
      checkmarkColor: glass ? palette.foreground : null,
      side: glass ? BorderSide.none : side,
      shape: glass ? shape : null,
      elevation: glass ? 0 : null,
      pressElevation: glass ? 0 : null,
      padding: padding,
    );
    if (!glass) return chip;
    return GlassButtonMaterial(
      variant: variant,
      enabled: enabled,
      selected: selected,
      shape: shape,
      showShadow: false,
      child: chip,
    );
  }
}
