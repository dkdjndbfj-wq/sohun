import 'package:flutter/material.dart';

import 'filament_model_badge.dart';

class MaterialPickerResult {
  final String? value;

  const MaterialPickerResult(this.value);
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
    builder: (_) => _MaterialPickerDialog(
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
  final String label;
  final String value;
  final VoidCallback onTap;

  const MaterialPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
          ),
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}

class _MaterialPickerDialog extends StatefulWidget {
  final List<String> materials;
  final String? selected;
  final bool allowAll;
  final String title;
  final String searchHint;
  final String countUnit;
  final String emptyLabel;

  const _MaterialPickerDialog({
    required this.materials,
    required this.selected,
    required this.allowAll,
    required this.title,
    required this.searchHint,
    required this.countUnit,
    required this.emptyLabel,
  });

  @override
  State<_MaterialPickerDialog> createState() => _MaterialPickerDialogState();
}

class _MaterialPickerDialogState extends State<_MaterialPickerDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final query = _query.toLowerCase();
    final visible = widget.materials
        .where((value) => value.toLowerCase().contains(query))
        .toList();
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 620,
        height: 580,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.category_outlined,
                    color: colors.primary,
                    size: 21,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
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
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${visible.length} ${widget.countUnit}',
                  style:
                      TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: visible.isEmpty
                  ? Center(child: Text(widget.emptyLabel))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: visible.length + (widget.allowAll ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (widget.allowAll && index == 0) {
                          return _MaterialOption(
                            label: '全部材料',
                            selected: widget.selected == null,
                            icon: Icons.apps_rounded,
                            onTap: () => Navigator.of(context).pop(
                              const MaterialPickerResult(null),
                            ),
                          );
                        }
                        final value =
                            visible[index - (widget.allowAll ? 1 : 0)];
                        return _MaterialOption(
                          label: value,
                          selected: value == widget.selected,
                          showModelCode: true,
                          onTap: () => Navigator.of(context).pop(
                            MaterialPickerResult(value),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MaterialOption extends StatelessWidget {
  final String label;
  final bool selected;
  final IconData? icon;
  final bool showModelCode;
  final VoidCallback onTap;

  const _MaterialOption({
    required this.label,
    required this.selected,
    this.icon,
    this.showModelCode = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      selected: selected,
      selectedTileColor: colors.primaryContainer.withValues(alpha: 0.45),
      leading: showModelCode
          ? FilamentModelBadge(
              manufacturer: '',
              model: label,
              materialType: label,
              compact: true,
            )
          : Icon(icon, size: 19, color: selected ? colors.primary : null),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check_circle_rounded, color: colors.primary, size: 19)
          : null,
      onTap: onTap,
    );
  }
}
