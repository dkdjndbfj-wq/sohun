import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/models/filament_cost_config.dart';
import '../../data/database/models/studio_quote_config_models.dart';
import '../../providers/database_provider.dart';
import '../../providers/filament_cost_provider.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_components.dart';
import 'farm_ui/farm_design.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_ui/farm_theme.dart';

class StudioQuoteConfigPanel extends ConsumerWidget {
  const StudioQuoteConfigPanel({
    super.key,
    required this.workspaceId,
    required this.canManage,
  });

  final String workspaceId;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(studioQuoteSettingsProvider);
    final machines = ref.watch(studioMachineCostConfigsProvider);
    final materials = ref.watch(filamentCostConfigsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          key: const Key('quote-unified-settings'),
          icon: Icons.tune_rounded,
          title: '统一报价参数',
          subtitle: '所有新订单共用；修改后只影响之后创建的订单。',
          action: IconButton(
            tooltip: '编辑统一报价参数',
            onPressed: !canManage || settings.valueOrNull == null
                ? null
                : () => _editSettings(context, ref, settings.value!),
            icon: const Icon(Icons.edit_outlined, size: 19),
          ),
          child: settings.when(
            loading: () => const LinearProgressIndicator(minHeight: 2),
            error: (error, _) => Text('读取失败：$error'),
            data: (value) => LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth < 720
                    ? (constraints.maxWidth - 8) / 2
                    : (constraints.maxWidth - 24) / 4;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Metric(
                        width: width,
                        label: '人工',
                        value: '${_number(value.laborRatePerHour)} 元/小时'),
                    _Metric(
                        width: width,
                        label: '电费',
                        value:
                            '${_number(value.electricityRatePerHour)} 元/打印小时'),
                    _Metric(
                        width: width,
                        label: '风险预留',
                        value: '${_number(value.riskReservePercent)}%'),
                    _Metric(
                        width: width,
                        label: '利润加成',
                        value: '${_number(value.markupPercent)}%'),
                    _Metric(
                        width: width,
                        label: '包装/后处理',
                        value: '${_number(value.packagingCost)} 元/单'),
                    _Metric(
                        width: width,
                        label: '最低报价',
                        value: '${_number(value.minimumOrderPrice)} 元'),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        _Section(
          key: const Key('quote-machine-costs'),
          icon: Icons.precision_manufacturing_outlined,
          title: '机器型号损耗',
          subtitle: '折旧、维护、喷嘴和平台损耗的综合小时成本。',
          action: IconButton(
            tooltip: '添加机器损耗',
            onPressed: canManage
                ? () => _editMachine(context, ref, workspaceId, null)
                : null,
            icon: const Icon(Icons.add_rounded),
          ),
          child: machines.when(
            loading: () => const LinearProgressIndicator(minHeight: 2),
            error: (error, _) => Text('读取失败：$error'),
            data: (items) => items.isEmpty
                ? const _InlineEmpty(text: '还没有机器损耗配置，新订单会标记为待核对。')
                : Column(
                    children: [
                      for (final item in items)
                        _CompactRow(
                          title: item.isDefault
                              ? '默认机器'
                              : [item.brand, item.model]
                                  .where((value) => value.isNotEmpty)
                                  .join(' / '),
                          subtitle: item.note,
                          value: '${_number(item.wearCostPerHour)} 元/小时',
                          enabled: item.active,
                          onEdit: canManage
                              ? () =>
                                  _editMachine(context, ref, workspaceId, item)
                              : null,
                          onDelete: canManage
                              ? () => _confirmDeleteMachine(context, ref, item)
                              : null,
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 10),
        _Section(
          key: const Key('quote-material-costs'),
          icon: Icons.view_in_ar_outlined,
          title: '品牌与耗材成本',
          subtitle: '优先匹配品牌、材质和颜色；空颜色表示该品牌材质的通用价格。',
          action: IconButton(
            tooltip: '添加耗材成本',
            onPressed:
                canManage ? () => _editMaterial(context, ref, null) : null,
            icon: const Icon(Icons.add_rounded),
          ),
          child: materials.when(
            loading: () => const LinearProgressIndicator(minHeight: 2),
            error: (error, _) => Text('读取失败：$error'),
            data: (items) => items.isEmpty
                ? const _InlineEmpty(text: '还没有耗材价格，新订单会标记为待核对。')
                : Column(
                    children: [
                      for (final item in items)
                        _CompactRow(
                          title:
                              '${item.vendor.isEmpty ? '通用品牌' : item.vendor} / ${item.materialType}',
                          subtitle: item.colorHex.isEmpty
                              ? '全部颜色'
                              : '颜色覆盖 ${item.colorHex}',
                          value: '${_number(item.costPerKg)} 元/kg',
                          onEdit: canManage
                              ? () => _editMaterial(context, ref, item)
                              : null,
                          onDelete: canManage && item.id != null
                              ? () => _confirmDeleteMaterial(context, ref, item)
                              : null,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget action;
  final Widget child;

  @override
  Widget build(BuildContext context) => FrostPanel(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: FarmVisual.primary),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: FarmVisual.label(context)),
                    ],
                  ),
                ),
                action,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );
}

class _Metric extends StatelessWidget {
  const _Metric(
      {required this.width, required this.label, required this.value});
  final double width;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: Container(
          constraints: const BoxConstraints(minHeight: 54),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: FarmVisual.label(context)),
              const SizedBox(height: 3),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      );
}

class _CompactRow extends StatelessWidget {
  const _CompactRow({
    required this.title,
    required this.value,
    this.subtitle,
    this.enabled = true,
    this.onEdit,
    this.onDelete,
  });
  final String title;
  final String? subtitle;
  final String value;
  final bool enabled;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 46),
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(
          border:
              Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (subtitle?.trim().isNotEmpty == true)
                    Text(subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FarmVisual.label(context)),
                ],
              ),
            ),
            if (!enabled)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Text('停用', style: TextStyle(fontSize: 11)),
              ),
            SizedBox(
              width: 112,
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            IconButton(
                tooltip: '编辑',
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 17)),
            IconButton(
                tooltip: '删除',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 17)),
          ],
        ),
      );
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: FarmVisual.label(context)),
      );
}

Future<void> _editSettings(
  BuildContext context,
  WidgetRef ref,
  StudioQuoteSettings value,
) async {
  final labor = TextEditingController(text: _number(value.laborRatePerHour));
  final electricity =
      TextEditingController(text: _number(value.electricityRatePerHour));
  final risk = TextEditingController(text: _number(value.riskReservePercent));
  final markup = TextEditingController(text: _number(value.markupPercent));
  final packaging = TextEditingController(text: _number(value.packagingCost));
  final minimum = TextEditingController(text: _number(value.minimumOrderPrice));
  await AppDialog.show<void>(
    context: context,
    title: '统一报价参数',
    content: Column(
      children: [
        Row(children: [
          Expanded(child: AppInput(label: '人工 元/小时', controller: labor)),
          const SizedBox(width: 8),
          Expanded(child: AppInput(label: '电费 元/打印小时', controller: electricity))
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: AppInput(label: '风险预留 %', controller: risk)),
          const SizedBox(width: 8),
          Expanded(child: AppInput(label: '利润加成 %', controller: markup))
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: AppInput(label: '包装/后处理 元/单', controller: packaging)),
          const SizedBox(width: 8),
          Expanded(child: AppInput(label: '最低报价 元', controller: minimum))
        ]),
      ],
    ),
    actions: [
      TextButton(
          onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(
        onPressed: () async {
          double number(TextEditingController controller) =>
              double.tryParse(controller.text.trim()) ?? 0;
          await ref.read(studioQuoteConfigDaoProvider).saveSettings(
                StudioQuoteSettings(
                  id: value.id,
                  workspaceId: value.workspaceId,
                  laborRatePerHour: number(labor),
                  electricityRatePerHour: number(electricity),
                  riskReservePercent: number(risk),
                  markupPercent: number(markup),
                  packagingCost: number(packaging),
                  minimumOrderPrice: number(minimum),
                  updatedAt: DateTime.now(),
                ),
              );
          if (context.mounted) Navigator.pop(context);
        },
        child: const Text('保存'),
      ),
    ],
  );
  for (final controller in [
    labor,
    electricity,
    risk,
    markup,
    packaging,
    minimum
  ]) {
    controller.dispose();
  }
}

Future<void> _editMachine(
  BuildContext context,
  WidgetRef ref,
  String workspaceId,
  StudioMachineCostConfig? value,
) async {
  final brand = TextEditingController(text: value?.brand ?? '拓竹');
  final model = TextEditingController(text: value?.model ?? '');
  final rate = TextEditingController(
      text: value == null ? '' : _number(value.wearCostPerHour));
  final note = TextEditingController(text: value?.note ?? '');
  var active = value?.active ?? true;
  await AppDialog.show<void>(
    context: context,
    title: value == null ? '添加机器损耗' : '编辑机器损耗',
    content: StatefulBuilder(
      builder: (context, setState) => Column(
        children: [
          Row(children: [
            Expanded(
                child:
                    AppInput(label: '品牌', controller: brand, hint: '留空表示默认机器')),
            const SizedBox(width: 8),
            Expanded(
                child:
                    AppInput(label: '型号', controller: model, hint: '例如 A1、P1S'))
          ]),
          const SizedBox(height: 10),
          AppInput(label: '综合损耗 元/小时', controller: rate),
          const SizedBox(height: 10),
          AppInput(label: '备注', controller: note, hint: '可记录折旧、维护、易损件口径'),
          SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用此配置'),
              value: active,
              onChanged: (next) => setState(() => active = next)),
        ],
      ),
    ),
    actions: [
      TextButton(
          onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(
        onPressed: () async {
          final parsed = double.tryParse(rate.text.trim());
          if (parsed == null || parsed < 0) {
            showSnack(context, '请填写有效的机器小时损耗', error: true);
            return;
          }
          await ref.read(studioQuoteConfigDaoProvider).saveMachine(
                StudioMachineCostConfig(
                  id: value?.id ?? 0,
                  workspaceId: workspaceId,
                  brand: brand.text,
                  model: model.text,
                  wearCostPerHour: parsed,
                  active: active,
                  note: note.text,
                  updatedAt: DateTime.now(),
                ),
              );
          if (context.mounted) Navigator.pop(context);
        },
        child: const Text('保存'),
      ),
    ],
  );
  for (final controller in [brand, model, rate, note]) {
    controller.dispose();
  }
}

Future<void> _editMaterial(
  BuildContext context,
  WidgetRef ref,
  FilamentCostConfig? value,
) async {
  final vendor = TextEditingController(text: value?.vendor ?? '拓竹');
  final material =
      TextEditingController(text: value?.materialType ?? 'PETG Basic');
  final color = TextEditingController(text: value?.colorHex ?? '');
  final rate = TextEditingController(
      text: value == null ? '' : _number(value.costPerKg));
  final note = TextEditingController(text: value?.note ?? '');
  await AppDialog.show<void>(
    context: context,
    title: value == null ? '添加耗材成本' : '编辑耗材成本',
    content: Column(
      children: [
        Row(children: [
          Expanded(
              child:
                  AppInput(label: '品牌', controller: vendor, hint: '留空表示通用品牌')),
          const SizedBox(width: 8),
          Expanded(
              child: AppInput(
                  label: '材质类型', controller: material, hint: '例如 PETG Basic'))
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child:
                  AppInput(label: '颜色覆盖', controller: color, hint: '留空表示全部颜色')),
          const SizedBox(width: 8),
          Expanded(child: AppInput(label: '成本 元/kg', controller: rate))
        ]),
        const SizedBox(height: 10),
        AppInput(label: '备注', controller: note),
      ],
    ),
    actions: [
      TextButton(
          onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(
        onPressed: () async {
          final parsed = double.tryParse(rate.text.trim());
          if (material.text.trim().isEmpty || parsed == null || parsed < 0) {
            showSnack(context, '请填写材质类型和有效成本', error: true);
            return;
          }
          final next = FilamentCostConfig(
            id: value?.id,
            vendor: vendor.text.trim(),
            materialType: material.text.trim(),
            colorHex: _normalizedColor(color.text),
            costPerKg: parsed,
            note: note.text.trim(),
            createdAt: value?.createdAt ?? DateTime.now(),
            updatedAt: DateTime.now(),
          );
          final dao = ref.read(filamentCostConfigDaoProvider);
          if (value?.id == null) {
            await dao.create(next);
          } else {
            await dao.updateConfig(next);
          }
          if (context.mounted) Navigator.pop(context);
        },
        child: const Text('保存'),
      ),
    ],
  );
  for (final controller in [vendor, material, color, rate, note]) {
    controller.dispose();
  }
}

Future<void> _confirmDeleteMachine(
    BuildContext context, WidgetRef ref, StudioMachineCostConfig item) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除机器损耗'),
      content: const Text('历史报价不会变化；之后的新订单可能进入待核对。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'))
      ],
    ),
  );
  if (confirmed == true)
    await ref.read(studioQuoteConfigDaoProvider).deleteMachine(item.id);
}

Future<void> _confirmDeleteMaterial(
    BuildContext context, WidgetRef ref, FilamentCostConfig item) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除耗材成本'),
      content: const Text('历史报价不会变化；之后匹配不到该耗材的新订单会进入待核对。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'))
      ],
    ),
  );
  if (confirmed == true && item.id != null) {
    await ref.read(filamentCostConfigDaoProvider).deleteConfig(item.id!);
  }
}

String _number(double value) {
  final fixed = value.toStringAsFixed(2);
  return fixed
      .replaceFirst(RegExp(r'\.00$'), '')
      .replaceFirst(RegExp(r'(\.\d)0$'), r'$1');
}

String _normalizedColor(String value) {
  final raw = value.trim().toUpperCase().replaceFirst('#', '');
  return raw.isEmpty ? '' : '#$raw';
}
