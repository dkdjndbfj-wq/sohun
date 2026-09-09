import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/services/printer_fleet_connection_manager.dart';
import '../../core/services/printer_model_normalizer.dart';
import '../../data/external/printer/printer_connector.dart';
import '../../providers/farm_slicing_preset_provider.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_design.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_ui/farm_components.dart';

class FarmSlicingPresetScreen extends ConsumerStatefulWidget {
  const FarmSlicingPresetScreen({super.key});

  @override
  ConsumerState<FarmSlicingPresetScreen> createState() =>
      _FarmSlicingPresetScreenState();
}

class _FarmSlicingPresetScreenState
    extends ConsumerState<FarmSlicingPresetScreen> {
  String? _importingKey;

  @override
  Widget build(BuildContext context) {
    final presets = ref.watch(farmSlicingPresetsProvider);
    final canMaintain =
        ref.watch(currentFarmPermissionProvider('printer.maintain'));
    final groups = _connectedPrinterGroups(
      ref.watch(fleetPrinterStatesProvider),
      presets,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FarmPageHeader(
            title: '切片参数库',
            subtitle: '按已连接打印机的精确机型和喷嘴管理可复检的生产方案。',
          ),
          const SizedBox(height: 14),
          _OfficialRulesPanel(
            connectedSpecCount: groups.length,
            presetCount: groups.fold<int>(
              0,
              (sum, group) => sum + group.presets.length,
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: groups.isEmpty
                ? const _NoConnectedPrinterState()
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 900 ? 2 : 1;
                      const spacing = 14.0;
                      final width =
                          (constraints.maxWidth - spacing * (columns - 1)) /
                              columns;
                      return SingleChildScrollView(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Wrap(
                          spacing: spacing,
                          runSpacing: spacing,
                          children: [
                            for (final group in groups)
                              SizedBox(
                                width: width,
                                height: 390,
                                child: _PrinterPresetCard(
                                  group: group,
                                  canImport: canMaintain,
                                  canDelete: canMaintain,
                                  importing: _importingKey == group.key,
                                  onImport: () => _importPreset(group),
                                  onDelete: _removePreset,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _importPreset(_ConnectedPrinterGroup group) async {
    const jsonGroup = XTypeGroup(
      label: 'Bambu Studio 完整配置 JSON',
      extensions: ['json'],
    );
    final files = await openFiles(acceptedTypeGroups: const [jsonGroup]);
    if (files.isEmpty || !mounted) return;

    setState(() => _importingKey = group.key);
    try {
      final notifier = ref.read(farmSlicingPresetsProvider.notifier);
      await notifier.ready;
      final candidate = await notifier.inspectImportFiles(
        files.map((file) => file.path),
      );
      if (!PrinterModelNormalizer.sameModel(
            candidate.displayModel,
            group.displayModel,
          ) ||
          (candidate.nozzleDiameter - group.nozzleDiameter).abs() >= .001) {
        throw FarmSlicingPresetException(
          '这组参数属于 ${candidate.displayModel} '
          '${candidate.nozzleDiameter.toStringAsFixed(1)} mm，不能导入到 '
          '${group.displayModel} ${group.nozzleDiameter.toStringAsFixed(1)} mm 卡片',
        );
      }
      if (!mounted) return;
      final name = await _askPresetName(candidate);
      if (name == null || !mounted) return;
      final preset = await notifier.importCandidate(
        candidate: candidate,
        name: name,
      );
      await recordCurrentFarmActivity(
        ref,
        actionCode: 'farm_slicing_preset.imported',
        entityType: 'slicing_preset',
        entityId: preset.id,
        summary:
            '导入 ${preset.displayModel} ${preset.nozzleDiameter.toStringAsFixed(1)}mm 切片方案“${preset.name}”',
      );
      if (mounted) {
        showSnack(
          context,
          '已导入 ${preset.displayModel} ${preset.nozzleDiameter.toStringAsFixed(1)} mm 的“${preset.name}”方案',
        );
      }
    } catch (error) {
      if (mounted) showSnack(context, '导入失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _importingKey = null);
    }
  }

  Future<String?> _askPresetName(FarmSlicingPresetCandidate candidate) async {
    final controller = TextEditingController();
    String? errorText;
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('给方案命名'),
            content: SizedBox(
              width: 620,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${candidate.displayModel} · '
                    '${candidate.nozzleDiameter.toStringAsFixed(1)} mm 喷嘴',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text('官方机器参数：${candidate.machineConfigName}'),
                  Text('官方工艺参数：${candidate.processConfigName}'),
                  Text(
                    candidate.filamentConfigNames.isEmpty
                        ? '耗材参数：未导入，将沿用 3MF 内嵌参数'
                        : '耗材参数：${candidate.filamentConfigNames.join('、')}',
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 40,
                    decoration: InputDecoration(
                      labelText: '自定义方案名',
                      hintText: '例如：高质量、有支撑、快速打样',
                      errorText: errorText,
                    ),
                    onSubmitted: (_) {
                      final value = controller.text.trim();
                      if (value.isEmpty) {
                        setDialogState(() => errorText = '请输入方案名');
                      } else {
                        Navigator.pop(context, value);
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final value = controller.text.trim();
                  if (value.isEmpty) {
                    setDialogState(() => errorText = '请输入方案名');
                    return;
                  }
                  Navigator.pop(context, value);
                },
                child: const Text('导入并保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _removePreset(FarmSlicingPreset preset) async {
    final confirmed = await AppDialog.confirm(
      context,
      '删除切片方案',
      '确定删除 ${preset.displayModel} ${preset.nozzleDiameter.toStringAsFixed(1)} mm 的“${preset.name}”吗？'
          '应用管理目录内复制的机器、工艺和耗材配置也会一起删除。',
      confirmText: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(farmSlicingPresetsProvider.notifier).remove(preset.id);
      await recordCurrentFarmActivity(
        ref,
        actionCode: 'farm_slicing_preset.deleted',
        entityType: 'slicing_preset',
        entityId: preset.id,
        summary:
            '删除 ${preset.displayModel} ${preset.nozzleDiameter.toStringAsFixed(1)}mm 切片方案“${preset.name}”',
      );
      if (mounted) showSnack(context, '“${preset.name}”已删除');
    } catch (error) {
      if (mounted) showSnack(context, '删除失败：$error', error: true);
    }
  }
}

class _OfficialRulesPanel extends StatelessWidget {
  const _OfficialRulesPanel({
    required this.connectedSpecCount,
    required this.presetCount,
  });

  final int connectedSpecCount;
  final int presetCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: FarmVisual.primary.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        border: Border.all(color: FarmVisual.primary.withValues(alpha: .22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_outlined, color: FarmVisual.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '导入时会逐份检查机器、工艺和耗材 JSON，并核对它们是否与卡片的机型、喷嘴一一对应。'
              '切片前还会复检托管副本和文件指纹，确认无误后才传给 Bambu Studio。',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '$connectedSpecCount 种已连接设备 · $presetCount 个方案',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _NoConnectedPrinterState extends StatelessWidget {
  const _NoConnectedPrinterState();

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.tune_rounded,
                size: 44,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              const Text(
                '当前没有规格完整的已连接打印机',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                '请先在“设备与耗材”连接打印机并确认当前喷嘴。连接成功后，这里会自动出现对应卡片。',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}

class _ConnectedPrinterGroup {
  const _ConnectedPrinterGroup({
    required this.key,
    required this.displayModel,
    required this.nozzleDiameter,
    required this.connectedCount,
    required this.presets,
  });

  final String key;
  final String displayModel;
  final double nozzleDiameter;
  final int connectedCount;
  final List<FarmSlicingPreset> presets;
}

List<_ConnectedPrinterGroup> _connectedPrinterGroups(
  List<FleetPrinterState> fleet,
  List<FarmSlicingPreset> presets,
) {
  final connected = <String, List<FleetPrinterState>>{};
  for (final state in fleet) {
    final model = state.reportedModel?.trim() ?? '';
    final nozzle = state.installedNozzleDiameter;
    if (state.connectionState != PrinterConnectionState.connected ||
        !PrinterModelNormalizer.isKnownBambuModel(model) ||
        nozzle == null ||
        nozzle <= 0) {
      continue;
    }
    final key =
        '${normalizeFarmSlicingModelKey(model)}:${nozzle.toStringAsFixed(3)}';
    connected.putIfAbsent(key, () => []).add(state);
  }
  final result = [
    for (final entry in connected.entries)
      _ConnectedPrinterGroup(
        key: entry.key,
        displayModel: PrinterModelNormalizer.normalize(
          entry.value.first.reportedModel!,
        ),
        nozzleDiameter: entry.value.first.installedNozzleDiameter!,
        connectedCount: entry.value.length,
        presets: presets
            .where(
              (preset) =>
                  '${preset.modelKey}:${preset.nozzleDiameter.toStringAsFixed(3)}' ==
                  entry.key,
            )
            .toList(growable: false)
          ..sort((a, b) {
            final time = a.createdAt.compareTo(b.createdAt);
            return time != 0 ? time : a.name.compareTo(b.name);
          }),
      ),
  ];
  result.sort((a, b) {
    final model = a.displayModel.compareTo(b.displayModel);
    return model != 0 ? model : a.nozzleDiameter.compareTo(b.nozzleDiameter);
  });
  return result;
}

class _PrinterPresetCard extends StatelessWidget {
  const _PrinterPresetCard({
    required this.group,
    required this.canImport,
    required this.canDelete,
    required this.importing,
    required this.onImport,
    required this.onDelete,
  });

  final _ConnectedPrinterGroup group;
  final bool canImport;
  final bool canDelete;
  final bool importing;
  final VoidCallback onImport;
  final ValueChanged<FarmSlicingPreset> onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 13),
            color: scheme.surfaceContainerLow,
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: FarmVisual.primary.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(FarmPalette.radius),
                  ),
                  child: Icon(
                    Icons.precision_manufacturing_outlined,
                    color: FarmVisual.primary,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.displayModel,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '${group.nozzleDiameter.toStringAsFixed(1)} mm 喷嘴 · '
                        '${group.connectedCount} 台已连接',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: !canImport || importing ? null : onImport,
                  icon: importing
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.file_upload_outlined, size: 16),
                  label: Text(importing ? '检查中' : '导入'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(82, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 9, 12, 7),
            child: Row(
              children: [
                Text(
                  '已导入参数',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  '${group.presets.length} 条 · 按导入时间',
                  style: TextStyle(fontSize: 10, color: scheme.outline),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: group.presets.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Text(
                        '还没有参数方案\n点击右上角“导入”添加完整配置',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : Scrollbar(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      itemCount: group.presets.length,
                      separatorBuilder: (_, __) => const Divider(
                        height: 1,
                        indent: 46,
                      ),
                      itemBuilder: (context, index) => _PresetRow(
                        index: index,
                        preset: group.presets[index],
                        canDelete: canDelete,
                        onDelete: onDelete,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.index,
    required this.preset,
    required this.canDelete,
    required this.onDelete,
  });

  final int index;
  final FarmSlicingPreset preset;
  final bool canDelete;
  final ValueChanged<FarmSlicingPreset> onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 57,
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              '${index + 1}.',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preset.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  '${preset.processConfigName} · '
                  '${DateFormat('MM-dd HH:mm').format(preset.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Tooltip(
            message: '导入时已逐项校验，切片前会再次复检',
            child: Icon(
              Icons.verified_rounded,
              size: 16,
              color: Colors.green.shade600,
            ),
          ),
          IconButton(
            tooltip: '删除方案',
            onPressed: canDelete ? () => onDelete(preset) : null,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline_rounded, size: 17),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
