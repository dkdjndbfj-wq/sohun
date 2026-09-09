import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/filament_model_code.dart';
import 'farm_design.dart';
import 'farm_theme.dart';

enum AppButtonVariant { primary, secondary, ghost, danger, disabled }

abstract final class FarmLayoutTokens {
  static const double pageGutter = 24;
}

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.onPressed,
    this.capsule = false,
    this.compact = false,
  });

  final String label;
  final AppButtonVariant variant;
  final Widget? icon;
  final VoidCallback? onPressed;
  final bool capsule;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null || variant == AppButtonVariant.disabled;
    final effective = disabled ? AppButtonVariant.disabled : variant;
    final radius = BorderRadius.circular(capsule ? 999 : FarmPalette.radius);
    final height = compact ? 32.0 : FarmPalette.controlHeight;
    final padding = EdgeInsets.symmetric(horizontal: compact ? 10 : 14);
    final scheme = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(borderRadius: radius);

    final child = icon == null
        ? Text(label)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconTheme(data: const IconThemeData(size: 17), child: icon!),
              const SizedBox(width: 7),
              Text(label),
            ],
          );
    final textStyle = TextStyle(
      fontSize: compact ? 12 : 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    );
    final common = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, height)),
      padding: WidgetStatePropertyAll(padding),
      shape: WidgetStatePropertyAll(shape),
      textStyle: WidgetStatePropertyAll(textStyle),
    );
    return switch (effective) {
      AppButtonVariant.primary => FilledButton(
          onPressed: onPressed,
          style: common,
          child: child,
        ),
      AppButtonVariant.danger => FilledButton(
          onPressed: onPressed,
          style: common.copyWith(
            backgroundColor: const WidgetStatePropertyAll(FarmPalette.danger),
            foregroundColor: const WidgetStatePropertyAll(Colors.white),
          ),
          child: child,
        ),
      AppButtonVariant.secondary => OutlinedButton(
          onPressed: onPressed,
          style: common.copyWith(
            foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
            side: WidgetStatePropertyAll(
              BorderSide(color: scheme.outlineVariant),
            ),
          ),
          child: child,
        ),
      AppButtonVariant.ghost => TextButton(
          onPressed: onPressed,
          style: common,
          child: child,
        ),
      AppButtonVariant.disabled => FilledButton(
          onPressed: null,
          style: common,
          child: child,
        ),
    };
  }
}

class AppInput extends StatelessWidget {
  const AppInput({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.search = false,
    this.errorText,
    this.obscureText = false,
    this.keyboardType,
    this.prefixIcon,
    this.suffixIcon,
    this.onChanged,
    this.onSubmitted,
    this.inputFormatters,
    this.enabled = true,
  });

  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final bool search;
  final String? errorText;
  final bool obscureText;
  final TextInputType? keyboardType;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      enabled: enabled,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: const TextStyle(fontSize: 13, height: 1.35),
      decoration: InputDecoration(
        hintText: hint,
        errorText: errorText,
        prefixIcon: prefixIcon ??
            (search ? const Icon(Icons.search_rounded, size: 18) : null),
        suffixIcon: suffixIcon,
      ),
    );
    if (label == null || label!.isEmpty) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label!, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        field,
      ],
    );
  }
}

class AppSelect<T> extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final dropdown = SizedBox(
      height: height,
      child: DropdownButtonFormField<T>(
        initialValue: value,
        items: items,
        onChanged: enabled ? onChanged : null,
        onTap: onOpen == null ? null : () => onOpen!(),
        menuMaxHeight: menuMaxHeight,
        isExpanded: true,
        icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 19),
        hint: hint == null ? null : Text(hint!),
        decoration: InputDecoration(
          prefixIcon: leading,
          contentPadding: const EdgeInsets.symmetric(horizontal: 11),
        ),
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 13,
        ),
      ),
    );
    if (label == null || label!.isEmpty) return dropdown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label!, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        dropdown,
      ],
    );
  }
}

abstract final class AppDialog {
  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    required Widget content,
    required List<Widget> actions,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 780),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 10, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(dialogContext).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded, size: 19),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: content,
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<bool> confirm(
    BuildContext context,
    String title,
    String content, {
    VoidCallback? onConfirm,
    String confirmText = '确认',
    String cancelText = '取消',
    bool destructive = false,
  }) async {
    final result = await show<bool>(
      context: context,
      title: title,
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelText),
        ),
        const SizedBox(width: 8),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: FarmPalette.danger)
              : null,
          onPressed: () {
            Navigator.of(context).pop(true);
            onConfirm?.call();
          },
          child: Text(confirmText),
        ),
      ],
    );
    return result ?? false;
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon,
    this.bambuIconName,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.useGlass = false,
  }) : assert(icon != null || bambuIconName != null);

  final IconData? icon;
  final String? bambuIconName;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool useGlass;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(FarmPalette.radius),
            ),
            child: Icon(
              icon ?? FarmIcons.fromLegacyName(bambuIconName!),
              size: 24,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 7),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add_rounded, size: 17),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: useGlass ? FrostPanel(child: content) : content,
      ),
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label = '正在加载...'});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 2.5),
          if (label != null) ...[
            const SizedBox(height: 12),
            Text(label!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class FarmSectionHeading extends StatelessWidget {
  const FarmSectionHeading({
    super.key,
    required this.title,
    this.trailing,
    this.color,
  });

  final String title;
  final Widget? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 3, height: 15, color: color ?? FarmPalette.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class MaterialPickerResult {
  const MaterialPickerResult(this.value);

  final String? value;
}

Future<MaterialPickerResult?> showMaterialPicker({
  required BuildContext context,
  required List<String> materials,
  required String? selected,
  bool allowAll = false,
  String title = '选择材料',
  String searchHint = '搜索材料型号，例如 PLA Silk、PETG Basic',
  String countUnit = '种材料',
  String emptyLabel = '没有匹配的材料',
}) {
  return showDialog<MaterialPickerResult>(
    context: context,
    builder: (_) => _FarmMaterialPickerDialog(
      materials: materials,
      selected: selected,
      allowAll: allowAll,
      title: title,
      searchHint: searchHint,
      countUnit: countUnit,
      emptyLabel: emptyLabel,
    ),
  );
}

class MaterialPickerField extends StatelessWidget {
  const MaterialPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(FarmPalette.radius),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded, size: 19),
        ),
        child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _FarmMaterialPickerDialog extends StatefulWidget {
  const _FarmMaterialPickerDialog({
    required this.materials,
    required this.selected,
    required this.allowAll,
    required this.title,
    required this.searchHint,
    required this.countUnit,
    required this.emptyLabel,
  });

  final List<String> materials;
  final String? selected;
  final bool allowAll;
  final String title;
  final String searchHint;
  final String countUnit;
  final String emptyLabel;

  @override
  State<_FarmMaterialPickerDialog> createState() =>
      _FarmMaterialPickerDialogState();
}

class _FarmMaterialPickerDialogState extends State<_FarmMaterialPickerDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.materials
        .where((item) => item.toLowerCase().contains(_query.toLowerCase()))
        .toList(growable: false);
    return Dialog(
      child: SizedBox(
        width: 620,
        height: 580,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
              child: Row(
                children: [
                  const Icon(Icons.category_outlined, size: 20),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 19),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: InputDecoration(
                  hintText: widget.searchHint,
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close_rounded, size: 17),
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 9, 18, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${visible.length} ${widget.countUnit}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            const Divider(),
            Expanded(
              child: visible.isEmpty
                  ? Center(child: Text(widget.emptyLabel))
                  : ListView(
                      padding: const EdgeInsets.all(10),
                      children: [
                        if (widget.allowAll)
                          _materialRow(context, null, '全部材料'),
                        for (final material in visible)
                          _materialRow(context, material, material),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _materialRow(BuildContext context, String? value, String label) {
    final selected = widget.selected == value;
    return ListTile(
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FarmPalette.radius),
      ),
      leading: value == null
          ? Icon(
              selected ? Icons.radio_button_checked : Icons.apps_outlined,
              size: 18,
            )
          : _FarmMaterialCodeBadge(label: label),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      trailing: selected
          ? Icon(
              Icons.check_circle_outline,
              color: Theme.of(context).colorScheme.primary,
              size: 19,
            )
          : null,
      onTap: () => Navigator.of(context).pop(MaterialPickerResult(value)),
    );
  }
}

class _FarmMaterialCodeBadge extends StatelessWidget {
  const _FarmMaterialCodeBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final code = FilamentModelCode.of(model: label, materialType: label);
    return Tooltip(
      message: label,
      child: Container(
        constraints: const BoxConstraints(minWidth: 28),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: FarmPalette.primary.withValues(alpha: 0.24),
          ),
        ),
        child: Text(
          code,
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
          style: const TextStyle(
            color: FarmPalette.primary,
            fontSize: 10,
            height: 1.05,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}
