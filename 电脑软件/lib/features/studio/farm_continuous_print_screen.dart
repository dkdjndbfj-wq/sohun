import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/printer_fleet_connection_manager.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/models/print_queue_item.dart';
import '../../data/database/models/scheduler_models.dart';
import '../../data/external/slicer/autoclear_detector.dart';
import '../../data/external/slicer/auto_eject_gcode_injector.dart';
import '../../data/external/slicer/production_package_inspector.dart';
import '../../data/external/slicer/slice_isolate_runner.dart';
import '../../data/external/slicer/slice_result.dart';
import '../../providers/farm_printer_model_profile_provider.dart';
import '../../providers/print_queue_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_design.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_auto_eject_policy.dart';

class FarmContinuousPrintScreen extends ConsumerStatefulWidget {
  const FarmContinuousPrintScreen({super.key});

  @override
  ConsumerState<FarmContinuousPrintScreen> createState() =>
      _FarmContinuousPrintScreenState();
}

class _FarmContinuousPrintScreenState
    extends ConsumerState<FarmContinuousPrintScreen> {
  final _targetQuantity = TextEditingController(text: '100');
  final _perPrinterRuns = TextEditingController(text: '1');
  final _gcodeObjectCount = TextEditingController(text: '1');

  String? _sourcePath;
  String? _sourceName;
  int _plateIndex = 1;
  String? _plateName;
  SliceResult? _slice;
  int? _objectsPerPlate;
  bool _autoEject = false;
  bool _loadingFile = false;
  bool _publishing = false;
  String? _error;
  String? _batchId;
  int _publishedRuns = 0;
  String? _autoArtifactPath;

  @override
  void initState() {
    super.initState();
    _targetQuantity.addListener(_refreshPlan);
    _perPrinterRuns.addListener(_refreshPlan);
    _gcodeObjectCount.addListener(_refreshPlan);
  }

  @override
  void dispose() {
    _targetQuantity.dispose();
    _perPrinterRuns.dispose();
    _gcodeObjectCount.dispose();
    super.dispose();
  }

  void _refreshPlan() {
    if (mounted) setState(() {});
  }

  int get _objectCount =>
      _objectsPerPlate ?? int.tryParse(_gcodeObjectCount.text.trim()) ?? 0;

  int get _targetCount => int.tryParse(_targetQuantity.text.trim()) ?? 0;

  int get _requiredRuns {
    return requiredBatchRuns(
      targetQuantity: _targetCount,
      objectsPerPlate: _objectCount,
    );
  }

  int get _remainingRuns => math.max(0, _requiredRuns - _publishedRuns);

  List<PrinterWithChannels> _matchingPrinters(
    List<PrinterWithChannels> printers,
    List<FleetPrinterState> fleet,
  ) {
    final targetModel = _slice?.printerSettingsId?.trim();
    final targetNozzle = _slice?.nozzleDiameter;
    if (targetModel == null || targetModel.isEmpty || targetNozzle == null) {
      return const [];
    }
    return printers
        .where(
          (item) => isBatchPrinterCompatible(
            targetModel: targetModel,
            targetNozzle: targetNozzle,
            printerModel: item.printer.model,
            installedNozzle: _fleetFor(item, fleet)?.installedNozzleDiameter,
          ),
        )
        .where((item) => item.serial?.trim().isNotEmpty == true)
        .toList(growable: false);
  }

  FleetPrinterState? _fleetFor(
    PrinterWithChannels printer,
    List<FleetPrinterState> fleet,
  ) {
    final serial = printer.serial;
    if (serial == null) return null;
    return fleet.where((item) => item.serial == serial).firstOrNull;
  }

  bool _sameNozzle(FleetPrinterState? state) {
    final target = _slice?.nozzleDiameter;
    final installed = state?.installedNozzleDiameter;
    return target != null &&
        installed != null &&
        (target - installed).abs() < .001;
  }

  bool _canStartNow(
    PrinterWithChannels printer,
    List<FleetPrinterState> fleet,
  ) {
    final state = _fleetFor(printer, fleet);
    return state != null &&
        _sameNozzle(state) &&
        state.canAutoDispatch(SchedulingConfig.defaults);
  }

  Future<void> _pickFile() async {
    const group = XTypeGroup(
      label: '已切片打印文件',
      extensions: ['3mf', 'gcode', 'g', 'gc', 'ngc'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return;
    await _loadFile(file.path);
  }

  Future<void> _loadFile(String path) async {
    setState(() {
      _loadingFile = true;
      _error = null;
      _sourcePath = null;
      _slice = null;
      _publishedRuns = 0;
      _batchId = null;
      _autoArtifactPath = null;
      _autoEject = false;
    });
    try {
      final inspection = await ProductionPackageInspector.inspect(path);
      var plateIndex = 1;
      ProductionPlateInspection? selectedPlate;
      final plates = inspection?.productionPlates
          .where((item) => item.hasToolpath && item.hasProductionItems)
          .toList(growable: false);
      if (plates != null && plates.isNotEmpty) {
        selectedPlate =
            plates.length == 1 ? plates.single : await _choosePlate(plates);
        if (selectedPlate == null) return;
        plateIndex = selectedPlate.plateIndex;
      }
      final slice = await SliceIsolateRunner.parseAuto(
        path,
        plateIndex: plateIndex,
      );
      if (slice == null) {
        throw StateError('文件不是有效的已切片产物，或无法读取机型/喷嘴参数');
      }
      if (slice.printerSettingsId?.trim().isEmpty != false ||
          slice.nozzleDiameter == null ||
          slice.nozzleDiameter! <= 0) {
        throw StateError('文件缺少精确机型或喷嘴信息，不能安全匹配打印机池');
      }
      final autoClear = await AutoClearDetector.detect(path);
      if (autoClear.hasAutoClear) {
        throw StateError('所选文件已经包含自动清件动作。请改选未注入脚本的基础切片文件，再由本批开关决定是否启用');
      }
      final sourceName = path.split(RegExp(r'[/\\]')).last;
      setState(() {
        _sourcePath = path;
        _sourceName = sourceName;
        _plateIndex = plateIndex;
        _plateName = selectedPlate?.displayName ?? 'G-code 盘';
        _slice = slice;
        _objectsPerPlate = selectedPlate?.instanceCount;
        if (selectedPlate != null) {
          _gcodeObjectCount.text = '${selectedPlate.instanceCount}';
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loadingFile = false);
    }
  }

  Future<ProductionPlateInspection?> _choosePlate(
    List<ProductionPlateInspection> plates,
  ) {
    return showDialog<ProductionPlateInspection>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择要批量生产的盘'),
        children: [
          for (final plate in plates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, plate),
              child: Text(
                '${plate.displayName} · ${plate.instanceCount} 个/盘',
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _setAutoEject(bool value) async {
    if (!value) {
      setState(() => _autoEject = false);
      return;
    }
    final targetModel = _slice?.printerSettingsId;
    if (targetModel == null) return;
    await ref.read(farmPrinterModelProfilesProvider.notifier).ready;
    final profile = ref
        .read(farmPrinterModelProfilesProvider.notifier)
        .profileFor(targetModel);
    if (!profile.hasAutoEjectScript) {
      if (mounted) {
        setState(() {
          _autoEject = false;
          _error = '该机型尚未保存自动取件脚本，请先到“自动取件”页面配置脚本模板';
        });
      }
      return;
    }
    final accepted = await _confirmAutoEject(
      model: targetModel,
      nozzle: _slice?.nozzleDiameter,
      objectsPerPlate: _objectCount,
    );
    if (mounted) setState(() => _autoEject = accepted);
  }

  Future<bool> _confirmAutoEject({
    required String model,
    required double? nozzle,
    required int objectsPerPlate,
  }) async {
    var sample = false;
    var path = false;
    var batch = false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) {
              final ready = sample && path && batch;
              return AlertDialog(
                title: const Text('确认本批启用自动取件'),
                content: SizedBox(
                  width: 620,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '$model · 喷嘴 ${nozzle?.toStringAsFixed(1) ?? '?'} mm · $objectsPerPlate 个/盘',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: sample,
                        onChanged: (value) =>
                            setState(() => sample = value == true),
                        title: const Text('已人工试打一份，模型冷却后能安全推离热床'),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: path,
                        onChanged: (value) =>
                            setState(() => path = value == true),
                        title: const Text('清件路径无遮挡，脚本已在同型号同喷嘴上验证'),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: batch,
                        onChanged: (value) =>
                            setState(() => batch = value == true),
                        title: const Text('本批只生产这个文件，不中途更换模型'),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed:
                        ready ? () => Navigator.pop(context, true) : null,
                    child: const Text('确认开启'),
                  ),
                ],
              );
            },
          ),
        ) ??
        false;
  }

  Future<void> _publishNextRound(
    List<PrinterWithChannels> printers,
    List<FleetPrinterState> fleet,
  ) async {
    if (_sourcePath == null || _slice == null) {
      setState(() => _error = '请先选择一个已切片文件');
      return;
    }
    if (_requiredRuns <= 0) {
      setState(() => _error = '请填写有效的单盘数量和目标总数量');
      return;
    }
    if (_remainingRuns <= 0) {
      setState(() => _error = '目标数量已经全部发布');
      return;
    }
    final matching = _matchingPrinters(printers, fleet);
    final idle = <PrinterWithChannels>[];
    for (final printer in matching) {
      if (!_canStartNow(printer, fleet)) continue;
      final active =
          await ref.read(printQueueDaoProvider).getActiveCount(printer.serial!);
      if (active == 0) idle.add(printer);
    }
    if (idle.isEmpty) {
      setState(() => _error = '当前没有空闲的同型号同喷嘴打印机；它们完成当前任务后再点“继续发布下一轮”');
      return;
    }
    setState(() {
      _publishing = true;
      _error = null;
    });
    try {
      await ref.read(farmPrinterModelProfilesProvider.notifier).ready;
      var artifactPath = _sourcePath!;
      final batchId = _batchId ?? const Uuid().v4();
      if (_autoEject) {
        final profile = ref
            .read(farmPrinterModelProfilesProvider.notifier)
            .profileFor(_slice!.printerSettingsId!);
        if (!profile.hasAutoEjectScript) {
          throw StateError('自动取件脚本为空，已停止发布');
        }
        _autoArtifactPath ??= await AutoEjectGcodeInjector.inject(
          artifactPath: _sourcePath!,
          plateIndex: _plateIndex,
          gcode: profile.autoEjectGcode,
          outputPath: _batchVariantPath(_sourcePath!, batchId),
        );
        artifactPath = _autoArtifactPath!;
      }
      final perPrinter = math.max(1, int.tryParse(_perPrinterRuns.text) ?? 1);
      final assignments = allocateBatchRound(
        remainingRuns: _remainingRuns,
        idlePrinterCount: idle.length,
        maxRunsPerPrinter: perPrinter,
      );
      var published = 0;
      _batchId = batchId;
      for (var printerIndex = 0;
          printerIndex < assignments.length;
          printerIndex++) {
        final printer = idle[printerIndex];
        for (var i = 0; i < assignments[printerIndex]; i++) {
          final globalIndex = _publishedRuns + 1;
          await ref.read(printQueueProvider(printer.serial!).notifier).enqueue(
                gcodePath: artifactPath,
                filename: '$_sourceName · 批量 $globalIndex/$_requiredRuns',
                autoContinue: _autoEject,
                batchId: batchId,
                batchIndex: globalIndex,
                batchTotal: _requiredRuns,
              );
          _publishedRuns++;
          published++;
        }
      }
      if (mounted) {
        setState(() {
          _error = published == 0 ? '本轮没有成功发布任务' : null;
        });
        showSnack(
          context,
          '本轮已向 ${idle.length} 台空闲打印机发布 $published 盘，剩余 $_remainingRuns 盘',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '发布失败：$error');
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  String _batchVariantPath(String sourcePath, String batchId) {
    final file = File(sourcePath);
    final name = sourcePath.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    return '${file.parent.path}${Platform.pathSeparator}${stem}_batch_$batchId$extension';
  }

  @override
  Widget build(BuildContext context) {
    final printers =
        ref.watch(printersWithChannelsProvider).valueOrNull ?? const [];
    final fleet = ref.watch(fleetPrinterStatesProvider);
    final matching = _matchingPrinters(printers, fleet);
    final queueBusySerials = <String>{
      for (final printer in matching)
        if (printer.serial case final serial?)
          if (ref.watch(printQueueProvider(serial)).any(
                (item) =>
                    item.status == PrintQueueStatus.queued ||
                    item.status == PrintQueueStatus.printing ||
                    item.status == PrintQueueStatus.waitingRemoval,
              ))
            serial,
    };
    final targetModel = _slice?.printerSettingsId;
    final targetNozzle = _slice?.nozzleDiameter;
    final profile = targetModel == null
        ? null
        : ref.watch(farmPrinterModelProfilesProvider)[
            normalizeFarmPrinterModelKey(targetModel)];
    final canAuto = profile?.hasAutoEjectScript == true;
    final batchItems = _batchId == null
        ? const <PrintQueueItem>[]
        : ref.watch(printBatchQueueItemsProvider(_batchId!)).valueOrNull ??
            const <PrintQueueItem>[];
    final completedRuns = batchItems
        .where(
          (item) =>
              item.status == PrintQueueStatus.completed ||
              item.status == PrintQueueStatus.waitingRemoval,
        )
        .length;
    final printingRuns = batchItems
        .where((item) => item.status == PrintQueueStatus.printing)
        .length;
    final queuedRuns = batchItems
        .where((item) => item.status == PrintQueueStatus.queued)
        .length;
    final failedRuns = batchItems
        .where((item) => item.status == PrintQueueStatus.failed)
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FarmPageHeader(
            title: '批量连续生产',
            subtitle: '按同型号同喷嘴设备池分批发布；忙机不动，空闲机先开始。',
            actions: [
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _FarmContinuousPolicyDialog(),
                ),
                icon: const Icon(Icons.tune_outlined, size: 17),
                label: const Text('队列策略'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 18),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.file_present_outlined),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _sourceName ?? '尚未选择已切片文件',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (_loadingFile)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        const SizedBox(width: 10),
                        FilledButton.tonalIcon(
                          onPressed: _loadingFile ? null : _pickFile,
                          icon: const Icon(Icons.folder_open_outlined),
                          label: const Text('选择文件'),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                if (_slice != null) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(label: Text('盘：${_plateName ?? 'G-code 盘'}')),
                      Chip(label: Text('机型：${targetModel ?? '未知'}')),
                      Chip(
                          label: Text(
                              '喷嘴：${targetNozzle?.toStringAsFixed(1)} mm')),
                      Chip(label: Text('预计：${_slice!.formattedDuration}')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _targetQuantity,
                          readOnly: _publishedRuns > 0,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: const InputDecoration(
                            labelText: '目标总数量（个）',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _gcodeObjectCount,
                          readOnly:
                              _objectsPerPlate != null || _publishedRuns > 0,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: InputDecoration(
                            labelText: '单盘数量（个）',
                            helperText: _objectsPerPlate == null
                                ? 'G-code 无对象清单，请手动填写'
                                : '来自 3MF 盘内对象统计',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _perPrinterRuns,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: const InputDecoration(
                            labelText: '每台本轮发布盘数',
                            helperText: '忙机不发布，后续可继续发布',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('本批启用自动取件'),
                    subtitle: Text(
                      canAuto
                          ? '只对本批文件生效；普通订单和其他文件仍按各自策略处理。'
                          : '当前机型没有保存脚本模板，暂不能启用。',
                    ),
                    value: _autoEject,
                    onChanged: canAuto && !_publishing && _publishedRuns == 0
                        ? _setAutoEject
                        : null,
                  ),
                  if (_publishedRuns > 0)
                    const Text(
                      '批次已开始，目标数量和取件方式已锁定；重新选择文件会建立新批次，不会取消已发布任务。',
                      style: TextStyle(fontSize: 12),
                    ),
                  const SizedBox(height: 8),
                  Card(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Wrap(
                        spacing: 24,
                        runSpacing: 10,
                        children: [
                          Text('单盘 $_objectCount 个'),
                          Text('目标 $_targetCount 个'),
                          Text('计划 $_requiredRuns 盘'),
                          Text('已发布 $_publishedRuns 盘'),
                          Text(
                            '剩余 $_remainingRuns 盘',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          if (_requiredRuns > 0 && _objectCount > 0)
                            Text('预计完成 ${_requiredRuns * _objectCount} 个'),
                          if (_batchId != null) ...[
                            Text('实际完成 ${completedRuns * _objectCount} 个'),
                            Text('打印中 $printingRuns 盘'),
                            Text('排队 $queuedRuns 盘'),
                            if (failedRuns > 0)
                              Text(
                                '失败 $failedRuns 盘',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '同型号同喷嘴打印机池（${matching.length} 台）',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 74,
                    child: matching.isEmpty
                        ? const Align(
                            alignment: Alignment.centerLeft,
                            child: Text('没有找到同型号同喷嘴且带序列号的打印机'),
                          )
                        : ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: matching.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, index) {
                              final printer = matching[index];
                              final ready = _canStartNow(printer, fleet) &&
                                  !queueBusySerials.contains(printer.serial);
                              return Chip(
                                avatar: Icon(
                                  ready
                                      ? Icons.play_circle_outline
                                      : Icons.pause_circle_outline,
                                  size: 18,
                                ),
                                label: Text(
                                  '${printer.printer.name ?? printer.printer.model} · ${ready ? '空闲' : '忙碌/离线'}',
                                ),
                                side: BorderSide(
                                  color: ready
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context)
                                          .colorScheme
                                          .outlineVariant,
                                ),
                              );
                            },
                          ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed:
                          _publishing || _loadingFile || _sourcePath == null
                              ? null
                              : () => _publishNextRound(printers, fleet),
                      icon: Icon(
                        _publishedRuns == 0
                            ? Icons.play_arrow_rounded
                            : Icons.skip_next_rounded,
                      ),
                      label: Text(
                        _publishedRuns == 0 ? '开始发布本轮' : '继续发布下一轮',
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FarmContinuousPolicyDialog extends ConsumerStatefulWidget {
  const _FarmContinuousPolicyDialog();

  @override
  ConsumerState<_FarmContinuousPolicyDialog> createState() =>
      _FarmContinuousPolicyDialogState();
}

class _FarmContinuousPolicyDialogState
    extends ConsumerState<_FarmContinuousPolicyDialog> {
  @override
  Widget build(BuildContext context) {
    final queueEnabled = ref.watch(printQueueEnabledProvider);
    final unattended = ref.watch(unattendedModeProvider);
    return AlertDialog(
      title: const Text('连续生产策略'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用打印队列'),
              subtitle: const Text('打印中可直接预排后续任务；人工取件确认后按顺序继续'),
              value: queueEnabled,
              onChanged: (value) async {
                await ref
                    .read(printQueueEnabledProvider.notifier)
                    .setEnabled(value);
                await recordCurrentFarmActivity(
                  ref,
                  actionCode: 'continuous_print.queue_toggled',
                  entityType: 'workspace',
                  entityId: 'continuous_print',
                  summary: '${value ? '启用' : '关闭'}打印队列',
                );
              },
            ),
            const Divider(height: 1),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('无人值守连续打印'),
              subtitle: Text(
                unattended
                    ? '作为旧队列和普通手动入队的默认值；批量页的本批开关优先'
                    : '默认等待成员取件；批量页仍可为单独批次开启',
              ),
              value: unattended,
              onChanged: _setUnattended,
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }

  Future<void> _setUnattended(bool enabled) async {
    if (enabled) {
      final accepted = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('启用无人值守连续打印'),
              content: const Text(
                '只有已通过自动取件检测的订单任务才会继续发送。请确认对应机型、喷嘴和热床的取件脚本已经实机验证。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('确认启用'),
                ),
              ],
            ),
          ) ??
          false;
      if (!accepted) return;
    }
    await ref.read(unattendedModeProvider.notifier).setEnabled(enabled);
    await recordCurrentFarmActivity(
      ref,
      actionCode: 'continuous_print.unattended_toggled',
      entityType: 'workspace',
      entityId: 'continuous_print',
      summary: '${enabled ? '启用' : '关闭'}无人值守连续打印',
    );
  }
}
