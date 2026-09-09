import 'package:flutter/material.dart';

/// Shared outer metrics for personal-mode consumable selection dialogs.
///
/// The printer channel picker and the inventory shelf picker expose different
/// content, but they are the same user action. Keeping their frame dimensions
/// together prevents the window from jumping between entry points.
abstract final class ConsumablePickerLayout {
  static const maxWidth = 760.0;
  static const maxHeight = 820.0;
  static const minWidth = 280.0;
  static const minHeight = 320.0;
  static const insetPadding = EdgeInsets.symmetric(
    horizontal: 24,
    vertical: 24,
  );

  static Size size(BuildContext context) {
    final mediaSize = MediaQuery.sizeOf(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final width = (mediaSize.width - insetPadding.horizontal)
        .clamp(minWidth, maxWidth)
        .toDouble();
    final availableHeight =
        (mediaSize.height - viewInsets.vertical - insetPadding.vertical)
            .clamp(minHeight, mediaSize.height)
            .toDouble();
    final height = availableHeight.clamp(minHeight, maxHeight).toDouble();
    return Size(width, height);
  }
}
