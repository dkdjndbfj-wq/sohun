import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/app_typography.dart';
import '../core/theme/glass_button_theme.dart';
import '../core/theme/interaction_effects.dart';
import 'bambu_icon.dart';

/// 与工作台视觉一致的拓竹风格选择器。
class AppSelect<T> extends StatefulWidget {
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String? label;
  final String? hint;
  final Widget? leading;
  final bool enabled;
  final double menuMaxHeight;
  final double height;
  final FutureOr<void> Function()? onOpen;

  const AppSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.label,
    this.hint,
    this.leading,
    this.enabled = true,
    this.menuMaxHeight = 320,
    this.height = 42,
    this.onOpen,
  });

  @override
  State<AppSelect<T>> createState() => _AppSelectState<T>();
}

class _AppSelectState<T> extends State<AppSelect<T>> {
  final FocusNode _focusNode = FocusNode();
  final MenuController _menuController = MenuController();
  bool _focused = false;
  bool _hovered = false;
  bool _open = false;
  bool _opening = false;

  bool get _enabled => widget.enabled && widget.onChanged != null && !_opening;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocus);
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocus)
      ..dispose();
    super.dispose();
  }

  void _handleFocus() {
    if (_focused == _focusNode.hasFocus) return;
    setState(() => _focused = _focusNode.hasFocus);
  }

  DropdownMenuItem<T>? _selectedItem() {
    for (final item in widget.items) {
      if (item.value == widget.value) return item;
    }
    return null;
  }

  Future<void> _toggleMenu() async {
    if (!_enabled) return;
    if (_menuController.isOpen) {
      _menuController.close();
    } else {
      _focusNode.requestFocus();
      final onOpen = widget.onOpen;
      if (onOpen != null) {
        setState(() => _opening = true);
        try {
          await onOpen();
        } catch (_) {
          // 数据刷新失败时仍允许打开已有选项；具体错误由调用页面展示。
        } finally {
          if (mounted) setState(() => _opening = false);
        }
      }
      if (!mounted || !widget.enabled || widget.onChanged == null) return;
      _focusNode.requestFocus();
      _menuController.open();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selectedItem = _selectedItem();
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final hintColor = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;
    final lineColor = isDark ? AppColors.outlineDark : const Color(0xFFDCE5DF);
    final baseFill = isDark
        ? AppColors.surfaceContainerHighDark
        : const Color(0xFFF4F8F5);
    final active = _focused || _open || _opening;

    final select = LayoutBuilder(
      builder: (context, constraints) {
        final menuWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 240.0;
        return MenuAnchor(
          controller: _menuController,
          crossAxisUnconstrained: false,
          consumeOutsideTap: false,
          onOpen: () => setState(() => _open = true),
          onClose: () {
            _focusNode.unfocus();
            setState(() => _open = false);
          },
          alignmentOffset: const Offset(0, 5),
          style: MenuStyle(
            minimumSize: WidgetStatePropertyAll(Size(menuWidth, 0)),
            maximumSize: WidgetStatePropertyAll(
              Size(menuWidth, widget.menuMaxHeight),
            ),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 6),
            ),
            backgroundColor: WidgetStatePropertyAll(
              isDark ? AppColors.surfaceContainerHighDark : Colors.white,
            ),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(0),
            shadowColor: const WidgetStatePropertyAll(Colors.transparent),
            side: WidgetStatePropertyAll(BorderSide(color: lineColor)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          menuChildren: [
            for (final item in widget.items)
              _buildMenuItem(
                item: item,
                selected: selectedItem != null && item == selectedItem,
                isDark: isDark,
                textColor: textColor,
              ),
          ],
          builder: (context, controller, child) {
            return MouseRegion(
              cursor: _enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: Semantics(
                button: true,
                enabled: _enabled,
                expanded: _open,
                label: widget.label,
                value: selectedItem?.child is Text
                    ? ((selectedItem!.child as Text).data ?? '')
                    : null,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    focusNode: _focusNode,
                    onTap: _enabled ? _toggleMenu : null,
                    borderRadius: BorderRadius.circular(8),
                    hoverColor: Colors.transparent,
                    splashColor: AppColors.primary.withValues(alpha: 0.08),
                    highlightColor: Colors.transparent,
                    child: AnimatedContainer(
                      duration: AppMotion.duration(
                        context,
                        AppCurves.durationHover,
                      ),
                      curve: AppCurves.curveHover,
                      height: widget.height,
                      decoration: BoxDecoration(
                        color: !_enabled
                            ? baseFill.withValues(alpha: 0.55)
                            : (_hovered || active
                                  ? (isDark
                                        ? AppColors.surfaceVariantDark
                                        : Colors.white)
                                  : baseFill),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: active ? AppColors.primary : lineColor,
                          width: active ? 1.4 : 1,
                        ),
                        boxShadow: active
                            ? [
                                BoxShadow(
                                  color: AppColors.primary.withValues(
                                    alpha: 0.11,
                                  ),
                                  blurRadius: 0,
                                  spreadRadius: 3,
                                ),
                                const BoxShadow(
                                  color: Color(0x12000000),
                                  blurRadius: 12,
                                  offset: Offset(0, 4),
                                ),
                              ]
                            : (_hovered
                                  ? const [
                                      BoxShadow(
                                        color: Color(0x0F000000),
                                        blurRadius: 10,
                                        offset: Offset(0, 3),
                                      ),
                                    ]
                                  : const []),
                      ),
                      child: Row(
                        children: [
                          AnimatedContainer(
                            duration: AppMotion.duration(
                              context,
                              AppCurves.durationHover,
                            ),
                            width: 3,
                            height: active ? 24 : 18,
                            decoration: BoxDecoration(
                              color: active
                                  ? AppColors.primary
                                  : (selectedItem != null
                                        ? AppColors.primary.withValues(
                                            alpha: 0.36,
                                          )
                                        : Colors.transparent),
                              borderRadius: const BorderRadius.horizontal(
                                right: Radius.circular(3),
                              ),
                            ),
                          ),
                          if (widget.leading != null) ...[
                            const SizedBox(width: 9),
                            IconTheme(
                              data: IconThemeData(
                                size: 16,
                                color: active
                                    ? AppColors.primary
                                    : AppColors.textSecondary,
                              ),
                              child: widget.leading!,
                            ),
                          ],
                          const SizedBox(width: 10),
                          Expanded(
                            child: DefaultTextStyle(
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: AppTypography.chineseFontFamily,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _enabled ? textColor : hintColor,
                                letterSpacing: 0,
                              ),
                              child:
                                  selectedItem?.child ??
                                  Text(
                                    widget.hint ?? '请选择',
                                    style: TextStyle(
                                      color: hintColor,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 18,
                            color: lineColor.withValues(alpha: 0.8),
                          ),
                          SizedBox(
                            width: 34,
                            child: Center(
                              child: _opening
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : AnimatedRotation(
                                      turns: _open ? 0.5 : 0,
                                      duration: AppMotion.duration(
                                        context,
                                        AppCurves.durationHover,
                                      ),
                                      curve: AppCurves.curveHover,
                                      child: BambuIcon(
                                        name: 'drop_down',
                                        size: 14,
                                        color: active
                                            ? AppColors.primary
                                            : hintColor,
                                        applyColorFilter: true,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (widget.label == null) return select;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 3, bottom: 6),
          child: Row(
            children: [
              AnimatedContainer(
                duration: AppMotion.duration(context, AppCurves.durationHover),
                width: active ? 12 : 4,
                height: 2,
                decoration: BoxDecoration(
                  color: active ? AppColors.primary : lineColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.label!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTypography.chineseFontFamily,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: active
                        ? AppColors.primary
                        : (isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondary),
                    letterSpacing: 0,
                  ),
                ),
              ),
            ],
          ),
        ),
        select,
      ],
    );
  }

  Widget _buildMenuItem({
    required DropdownMenuItem<T> item,
    required bool selected,
    required bool isDark,
    required Color textColor,
  }) {
    final enabled = _enabled && item.enabled;
    return MenuItemButton(
      onPressed: enabled
          ? () {
              widget.onChanged?.call(item.value);
            }
          : null,
      closeOnActivate: true,
      style: glassButtonStyle(
        context,
        ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(double.infinity, 44)),
          maximumSize: const WidgetStatePropertyAll(Size(double.infinity, 44)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.only(left: 0, right: 10),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return AppColors.primary.withValues(alpha: isDark ? 0.16 : 0.08);
            }
            return selected
                ? AppColors.primary.withValues(alpha: isDark ? 0.2 : 0.1)
                : Colors.transparent;
          }),
          foregroundColor: WidgetStatePropertyAll(
            selected ? AppColors.primary : textColor,
          ),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
        variant: selected
            ? AppGlassButtonVariant.primary
            : AppGlassButtonVariant.quiet,
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: selected ? 24 : 0,
            decoration: BoxDecoration(
              color: selected ? AppColors.primary : Colors.transparent,
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(3),
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: DefaultTextStyle(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppTypography.chineseFontFamily,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: enabled
                    ? (selected ? AppColors.primary : textColor)
                    : (isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary),
                letterSpacing: 0,
              ),
              child: item.child,
            ),
          ),
          const SizedBox(width: 8),
          if (selected)
            BambuIcon(
              name: 'confirm',
              size: 15,
              color: AppColors.primary,
              applyColorFilter: true,
            )
          else
            const SizedBox(width: 15),
        ],
      ),
    );
  }
}
