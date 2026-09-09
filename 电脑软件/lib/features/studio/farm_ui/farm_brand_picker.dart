import 'package:flutter/material.dart';

import '../../../core/services/farm_brand_catalog_service.dart';
import 'farm_theme.dart';

Future<FarmBrandOption?> showFarmBrandPicker({
  required BuildContext context,
  required List<FarmBrandOption> brands,
  required String? selectedCode,
}) {
  return showDialog<FarmBrandOption>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox(
        width: 440,
        height: 500,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.factory_outlined,
                    color: Theme.of(context).colorScheme.primary,
                    size: 21,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '选择耗材品牌',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 19),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: brands.length + 1,
                itemBuilder: (context, index) {
                  if (index == brands.length) {
                    return ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(FarmPalette.radius),
                      ),
                      leading: const Icon(Icons.add_circle_outline, size: 19),
                      title: const Text('添加其他品牌'),
                      subtitle: const Text('仅在标准品牌列表中没有时使用'),
                      onTap: () async {
                        final label = await _showCustomBrandDialog(context);
                        if (label == null || !context.mounted) return;
                        Navigator.pop(
                          context,
                          FarmBrandCatalogService.normalize(label),
                        );
                      },
                    );
                  }
                  final brand = brands[index];
                  final selected = brand.code == selectedCode;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    selectedTileColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(FarmPalette.radius),
                    ),
                    leading: Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(FarmPalette.radius),
                      ),
                      child: Text(
                        brand.label.characters.first.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    title: Text(brand.label),
                    trailing: selected
                        ? Icon(
                            Icons.check_circle_outline,
                            color: Theme.of(context).colorScheme.primary,
                            size: 19,
                          )
                        : null,
                    onTap: () => Navigator.pop(context, brand),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<String?> _showCustomBrandDialog(BuildContext context) async {
  final controller = TextEditingController();
  String? error;
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('添加其他耗材品牌'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 40,
            decoration: InputDecoration(
              labelText: '品牌名称',
              hintText: '例如 Polymaker',
              errorText: error,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.length < 2) {
                setState(() => error = '请输入完整品牌名称');
                return;
              }
              Navigator.pop(dialogContext, value);
            },
            child: const Text('添加并使用'),
          ),
        ],
      ),
    ),
  );
  Future<void>.delayed(kThemeAnimationDuration * 2, controller.dispose);
  return result;
}

class FarmBrandPickerField extends StatelessWidget {
  const FarmBrandPickerField({
    super.key,
    required this.value,
    required this.onTap,
    this.dense = false,
  });

  final String value;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: '品牌 / 厂商',
            isDense: dense,
            suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded, size: 19),
          ),
          child: Text(
            value.isEmpty ? '请选择品牌' : value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
