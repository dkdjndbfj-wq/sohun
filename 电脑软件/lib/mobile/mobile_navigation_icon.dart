import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum MobileNavigationSymbol {
  tags('tags'),
  inventory('inventory'),
  printAlerts('print-alerts'),
  account('account');

  const MobileNavigationSymbol(this.assetName);
  final String assetName;
}

/// The mobile navigation's dedicated 32-unit, two-state SVG family.
///
/// Color follows NavigationBar's IconTheme; the destination label owns its
/// semantics. A fixed optical size keeps the thin lines clear in the glass bar.
class MobileNavigationIcon extends StatelessWidget {
  const MobileNavigationIcon(
    this.symbol, {
    super.key,
    this.selected = false,
    this.size = 26,
  }) : assert(size > 0);

  final MobileNavigationSymbol symbol;
  final bool selected;
  final double size;

  String get assetPath =>
      'assets/images/icons/mobile_nav/${symbol.assetName}-'
      '${selected ? 'selected' : 'outline'}.svg';

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final color = iconTheme.color ?? Theme.of(context).colorScheme.onSurface;
    final opacity = iconTheme.opacity ?? 1;
    return SvgPicture.asset(
      assetPath,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(
        color.withValues(alpha: color.a * opacity),
        BlendMode.srcIn,
      ),
      excludeFromSemantics: true,
    );
  }
}
