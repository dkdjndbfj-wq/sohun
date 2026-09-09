import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/printer_fleet_connection_manager.dart';
import '../../core/services/printer_model_normalizer.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../providers/farm_slicing_preset_provider.dart';
import '../../ui/workspace_navigation.dart';
import 'farm_ui/farm_feedback.dart';

class FarmSlicingWorkflowException implements Exception {
  const FarmSlicingWorkflowException(this.message);

  final String message;

  @override
  String toString() => message;
}

class FarmSlicingPrinterCandidate {
  const FarmSlicingPrinterCandidate({
    required this.printer,
    required this.state,
  });

  final PrinterWithChannels printer;
  final FleetPrinterState state;

  String get label {
    final name = printer.printer.name?.trim() ?? '';
    return name.isEmpty ? printer.printer.model : name;
  }
}

class FarmSlicingTarget {
  const FarmSlicingTarget({
    required this.model,
    required this.nozzleDiameter,
    required this.printerLabels,
  });

  final String model;
  final double nozzleDiameter;
  final List<String> printerLabels;

  String get specification =>
      '$model · ${nozzleDiameter.toStringAsFixed(1)} mm 喷嘴';
}

/// Resolves the exact machine + nozzle shared by the physical printers chosen
/// before slicing. No configured default is used: a missing live/configured
/// nozzle is unsafe because it can silently produce an incompatible toolpath.
FarmSlicingTarget requireFarmSlicingTarget(
  Iterable<FarmSlicingPrinterCandidate> selections,
) {
  final selected = selections.toList(growable: false);
  if (selected.isEmpty) {
    throw const FarmSlicingWorkflowException('请先选择至少一台实体打印机，再进行切片');
  }

  String? model;
  double? nozzle;
  final labels = <String>[];
  for (final selection in selected) {
    final reported = selection.state.reportedModel?.trim() ?? '';
    if (!PrinterModelNormalizer.isKnownBambuModel(reported)) {
      throw FarmSlicingWorkflowException(
        '${selection.label} 的精确机型未知，请先在“设备与耗材”同步设备信息',
      );
    }
    if (!PrinterModelNormalizer.sameModel(
      reported,
      selection.printer.printer.model,
    )) {
      throw FarmSlicingWorkflowException(
        '${selection.label} 的登记机型 ${selection.printer.printer.model} '
        '与设备报告机型 $reported 不一致，请先修正设备信息',
      );
    }
    final installedNozzle = selection.state.installedNozzleDiameter;
    if (installedNozzle == null || installedNozzle <= 0) {
      throw FarmSlicingWorkflowException(
        '${selection.label} 的喷嘴直径未知，请先在“设备与耗材”确认当前喷嘴',
      );
    }
    final canonical = PrinterModelNormalizer.normalize(reported);
    if (model != null &&
        (!PrinterModelNormalizer.sameModel(model, canonical) ||
            (nozzle! - installedNozzle).abs() >= .001)) {
      throw FarmSlicingWorkflowException(
        '同一盘只能使用相同机型和喷嘴的打印机；当前选择中同时存在 '
        '$model ${nozzle!.toStringAsFixed(1)} mm 与 '
        '$canonical ${installedNozzle.toStringAsFixed(1)} mm',
      );
    }
    model ??= canonical;
    nozzle ??= installedNozzle;
    labels.add(selection.label);
  }

  return FarmSlicingTarget(
    model: model!,
    nozzleDiameter: nozzle!,
    printerLabels: labels,
  );
}

Future<FarmSlicingPrinterCandidate?> showFarmSlicingPrinterPicker(
  BuildContext context, {
  required List<PrinterWithChannels> printers,
  required List<FleetPrinterState> fleet,
}) {
  final candidates = <FarmSlicingPrinterCandidate>[];
  for (final printer in printers) {
    final serial = printer.serial;
    final state = serial == null
        ? null
        : fleet.where((item) => item.serial == serial).firstOrNull;
    if (state != null) {
      candidates.add(FarmSlicingPrinterCandidate(
        printer: printer,
        state: state,
      ));
    }
  }
  candidates.sort(
    (a, b) => a.label.compareTo(b.label),
  );

  return showDialog<FarmSlicingPrinterCandidate>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('先选择实体打印机'),
      content: SizedBox(
        width: 720,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '选定打印机后，系统会按该设备的精确机型和当前喷嘴，只显示兼容的切片方案。'
              '打印机是否空闲不影响这里只为切片确认机型。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: candidates.isEmpty
                  ? const Center(
                      child: Text('没有已连接且可识别的实体打印机，请先在“设备与耗材”添加并同步设备。'),
                    )
                  : ListView.separated(
                      itemCount: candidates.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final candidate = candidates[index];
                        FarmSlicingTarget? target;
                        String? issue;
                        try {
                          target = requireFarmSlicingTarget([candidate]);
                        } on FarmSlicingWorkflowException catch (error) {
                          issue = error.message;
                        }
                        return ListTile(
                          enabled: target != null,
                          leading: const Icon(Icons.print_outlined),
                          title: Text(candidate.label),
                          subtitle: Text(
                            target?.specification ?? issue ?? '设备信息不完整',
                          ),
                          trailing: target == null
                              ? const Icon(Icons.error_outline)
                              : const Icon(Icons.chevron_right_rounded),
                          onTap: target == null
                              ? null
                              : () => Navigator.pop(context, candidate),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

Future<FarmSlicingPreset?> showFarmSlicingPresetPicker(
  BuildContext context,
  WidgetRef ref, {
  required FarmSlicingTarget target,
}) async {
  final notifier = ref.read(farmSlicingPresetsProvider.notifier);
  await notifier.ready;
  if (!context.mounted) return null;
  final presets = notifier.compatiblePresets(
    target.model,
    target.nozzleDiameter,
  );

  final selected = await showDialog<FarmSlicingPreset>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('再选择切片方案'),
      content: SizedBox(
        width: 720,
        height: presets.isEmpty ? 250 : 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${target.printerLabels.join('、')} · ${target.specification}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '这里只列出机型和喷嘴都完全一致的方案。选择后才会调用 Bambu Studio 切片。',
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: presets.isEmpty
                  ? Center(
                      child: Text(
                        '还没有 ${target.specification} 的切片方案。\n'
                        '请先导入 Bambu Studio 导出的完整机器、工艺和耗材 JSON。',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: presets.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final preset = presets[index];
                        final filamentText = preset.filamentConfigNames.isEmpty
                            ? '沿用 3MF 内的耗材参数'
                            : '${preset.filamentConfigNames.length} 份耗材参数';
                        return ListTile(
                          leading: const Icon(Icons.tune_rounded),
                          title: Text(
                            preset.name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            '${preset.processConfigName} · $filamentText',
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.pop(context, preset),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (presets.isEmpty)
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              ref.read(workspaceNavigationRequestProvider.notifier).state =
                  WorkspacePageIds.studioSlicingPresets;
            },
            icon: const Icon(Icons.file_upload_outlined, size: 17),
            label: const Text('去导入方案'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
      ],
    ),
  );
  if (selected == null || !context.mounted) return null;
  try {
    await notifier.validateManagedPreset(
      selected,
      model: target.model,
      nozzleDiameter: target.nozzleDiameter,
    );
    return selected;
  } catch (error) {
    if (context.mounted) {
      showSnack(context, '切片方案复检失败：$error', error: true);
    }
    return null;
  }
}
