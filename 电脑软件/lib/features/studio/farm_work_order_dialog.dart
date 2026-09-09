import 'dart:async';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/printer_model_normalizer.dart';
import '../../core/services/printer_fleet_connection_manager.dart';
import '../../core/services/studio_quote_calculator.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/models/studio_models.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../data/external/slicer/bambu_studio_slicing_service.dart';
import '../../data/external/slicer/production_package_inspector.dart';
import '../../data/external/slicer/slice_isolate_runner.dart';
import '../../providers/app_auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/farm_slice_intake_provider.dart';
import '../../providers/farm_slicing_preset_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/slicer_provider.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_ui/farm_feedback.dart';
import 'studio_plate_filament_summary.dart';
import 'farm_slicing_workflow.dart';

const _officialWebsite = 'https://sohun.top/';

Future<bool> showFarmWorkOrderDialog(
  BuildContext context, {
  List<ProductionPackageInspection> initialInspections = const [],
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(farmWorkOrderComposerActiveProvider.notifier).state = true;
  try {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FarmWorkOrderDialog(
        initialInspections: initialInspections.take(5).toList(),
      ),
    );
    return result == true;
  } finally {
    container.read(farmWorkOrderComposerActiveProvider.notifier).state = false;
  }
}

class _FarmWorkOrderDialog extends ConsumerStatefulWidget {
  const _FarmWorkOrderDialog({required this.initialInspections});

  final List<ProductionPackageInspection> initialInspections;

  @override
  ConsumerState<_FarmWorkOrderDialog> createState() =>
      _FarmWorkOrderDialogState();
}

class _FarmWorkOrderDialogState extends ConsumerState<_FarmWorkOrderDialog> {
  late final TextEditingController _title;
  late final TextEditingController _orderNo;
  late final TextEditingController _price;
  late final TextEditingController _laborHours;
  late final TextEditingController _note;
  late final TextEditingController _publicNote;
  late final List<_PackageDraftState> _packages;
  List<PrinterWithChannels> _printers = const [];
  DateTime? _dueAt;
  bool _portalVideo = true;
  bool _dragging = false;
  bool _readingFiles = false;
  bool _slicingFiles = false;
  bool _detailsVisible = false;
  bool _saving = false;
  bool _pricingLoading = false;
  bool _priceOverridden = false;
  StudioQuoteCalculation? _quoteCalculation;
  Timer? _quoteDebounce;
  String? _createdOrderId;
  String? _portalPassword;
  String? _portalUrl;

  @override
  void initState() {
    super.initState();
    _packages = [
      for (final inspection in widget.initialInspections)
        _PackageDraftState(inspection),
    ];
    _detailsVisible =
        _packages.isNotEmpty && _packages.every((item) => item.allPlatesSliced);
    _title = TextEditingController(
      text: _packages.isEmpty ? '' : _packages.first.inspection.displayName,
    );
    _orderNo = TextEditingController(
      text: 'SO-${DateFormat('yyMMdd-HHmm').format(DateTime.now())}',
    );
    _price = TextEditingController(text: '0');
    _laborHours = TextEditingController(text: '0.25');
    _note = TextEditingController();
    _publicNote = TextEditingController();
    _printers = ref.read(printersWithChannelsProvider).valueOrNull ?? const [];
    ref.listenManual<FarmSliceIntakeState>(
      farmSliceIntakeProvider,
      _onSliceIntakeChanged,
      fireImmediately: true,
    );
  }

  int get _pendingPlateCount => _packages.fold<int>(
        0,
        (sum, package) => sum + package.pendingPlateCount,
      );

  int get _selectedPendingPlateCount => _packages.fold<int>(
        0,
        (sum, package) => sum + package.selectedPendingPlateCount,
      );

  bool get _canAutoSlice =>
      _selectedPendingPlateCount > 0 &&
      _packages
          .where((package) => package.selectedPendingPlateCount > 0)
          .every((package) => package.inspection.hasEmbeddedSettings);

  void _onSliceIntakeChanged(
    FarmSliceIntakeState? previous,
    FarmSliceIntakeState next,
  ) {
    if (!mounted || next.pending.isEmpty || _packages.isEmpty) return;
    final consumedIds = <String>[];
    var changed = false;
    for (final request in next.pending) {
      if (!request.inspection.hasAnySlicedPlate) continue;
      for (final package in _packages) {
        if (!package.matches(request.inspection)) continue;
        final applied = package.applySlicedInspection(request.inspection);
        if (applied == 0) continue;
        consumedIds.add(request.id);
        changed = true;
        break;
      }
    }
    if (!changed) return;
    setState(() {});
    Future<void>.microtask(() {
      if (!mounted) return;
      final notifier = ref.read(farmSliceIntakeProvider.notifier);
      for (final id in consumedIds) {
        notifier.complete(id);
      }
      showSnack(context, '切片结果已按盘自动关联；未切片盘可以稍后继续处理');
    });
  }

  @override
  void dispose() {
    _quoteDebounce?.cancel();
    for (final controller in [
      _title,
      _orderNo,
      _price,
      _laborHours,
      _note,
      _publicNote,
    ]) {
      controller.dispose();
    }
    for (final package in _packages) {
      package.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120, maxHeight: 820),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '新建生产工单',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    '${_packages.length} / 5 个打印文件',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed:
                        _saving ? null : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _buildFileArea(),
              const SizedBox(height: 12),
              if (!_detailsVisible)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _slicingFiles
                            ? 'Sohun 正在按盘调用 Bambu Studio 引擎；其他盘不会被一起切片。'
                            : _pendingPlateCount == 0
                                ? '所有生产盘都已有切片数据，可以继续填写生产信息。'
                                : '按当前产能勾选要先切的盘；未勾选的盘会随订单保存，之后再切。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (_pendingPlateCount > 0) ...[
                      OutlinedButton.icon(
                        onPressed: _readingFiles || _slicingFiles
                            ? null
                            : _refreshPackages,
                        icon: const Icon(Icons.refresh_rounded, size: 17),
                        label: const Text('重新读取'),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _readingFiles || _slicingFiles
                            ? null
                            : _launchPendingInBambuStudio,
                        icon: const Icon(Icons.open_in_new_rounded, size: 17),
                        label: const Text('用 Bambu Studio 打开'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed:
                            _readingFiles || _slicingFiles || !_canAutoSlice
                                ? null
                                : _slicePendingInsideSohun,
                        icon: _slicingFiles
                            ? const SizedBox.square(
                                dimension: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.content_cut_rounded, size: 17),
                        label: Text(
                          _slicingFiles
                              ? '后台切片中'
                              : _canAutoSlice
                                  ? '切片已选 $_selectedPendingPlateCount 盘'
                                  : _selectedPendingPlateCount == 0
                                      ? '请先勾选要切的盘'
                                      : '参数不完整，先在 Bambu Studio 保存',
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    FilledButton.icon(
                      onPressed:
                          _packages.isEmpty || _readingFiles || _slicingFiles
                              ? null
                              : () => setState(() => _detailsVisible = true),
                      icon: const Icon(Icons.add_task_rounded, size: 17),
                      label: const Text('新建工单'),
                    ),
                  ],
                )
              else ...[
                Expanded(child: _buildDetails()),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '创建后会同步到服务器，并一次复制订单号、随机密码、专属链接和官网入口。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed:
                          _saving ? null : () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _saving ? null : _saveAndCreateAccess,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.copy_all_rounded, size: 17),
                      label: Text(
                        _saving
                            ? '正在创建'
                            : _createdOrderId == null
                                ? '创建并复制访问资料'
                                : '重试生成访问资料',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileArea() {
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        _addFiles(detail.files.map((file) => file.path));
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        constraints: const BoxConstraints(minHeight: 132),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _dragging
              ? FarmVisual.primary.withValues(alpha: 0.10)
              : scheme.surfaceContainerLow,
          border: Border.all(
            color:
                _dragging ? FarmVisual.primary : Theme.of(context).dividerColor,
            width: _dragging ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(7),
        ),
        child: _packages.isEmpty
            ? InkWell(
                onTap: _readingFiles ? null : _pickFiles,
                child: SizedBox(
                  height: 102,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _readingFiles
                            ? Icons.hourglass_top_rounded
                            : Icons.file_upload_outlined,
                        color: FarmVisual.primary,
                        size: 30,
                      ),
                      const SizedBox(height: 7),
                      Text(
                        _readingFiles ? '正在读取 3MF 项目内容' : '把源 3MF 拖到这里，或点击选择',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Sohun 会按原盘读取对象；每盘可独立切片、分配和排队，最多 5 个文件',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var index = 0; index < _packages.length; index++)
                        _FileChip(
                          package: _packages[index],
                          onRemove: _createdOrderId != null
                              ? null
                              : () => _removePackage(index),
                        ),
                    ],
                  ),
                  if (_pendingPlateCount > 0) ...[
                    const SizedBox(height: 8),
                    Divider(height: 1, color: Theme.of(context).dividerColor),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 230),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final package in _packages.where(
                            (item) => item.pendingPlateCount > 0,
                          ))
                            _SourceProjectSummary(
                              package: package,
                              onChanged: () => setState(() {}),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        _pendingPlateCount == 0
                            ? '共 ${_packages.fold<int>(0, (sum, item) => sum + item.plates.length)} 张已切片生产盘'
                            : '共 ${_packages.fold<int>(0, (sum, item) => sum + item.plates.length)} 盘 · $_pendingPlateCount 盘待切 · 已选 $_selectedPendingPlateCount 盘先切',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _packages.length >= 5 ||
                                _readingFiles ||
                                _createdOrderId != null
                            ? null
                            : _pickFiles,
                        icon: _readingFiles
                            ? const SizedBox.square(
                                dimension: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.add_rounded, size: 17),
                        label: const Text('继续添加'),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildDetails() {
    return ListView(
      padding: const EdgeInsets.only(right: 3),
      children: [
        _sectionTitle('订单信息', Icons.assignment_outlined),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _field('订单名称', _title)),
            const SizedBox(width: 10),
            Expanded(child: _field('订单编号', _orderNo)),
            const SizedBox(width: 10),
            SizedBox(
              width: 150,
              child: _field(
                '订单金额',
                _price,
                decimal: true,
                onChanged: (_) {
                  _priceOverridden = true;
                  setState(() {});
                },
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 180,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('交付日期'),
                subtitle: Text(
                  _dueAt == null
                      ? '未设置'
                      : DateFormat('yyyy-MM-dd').format(_dueAt!),
                ),
                trailing: const Icon(Icons.calendar_month_outlined, size: 19),
                onTap: _pickDueDate,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildQuoteSummary(),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _field('客户可见说明', _publicNote)),
            const SizedBox(width: 10),
            Expanded(child: _field('内部备注', _note)),
          ],
        ),
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('允许客户查看当前打印画面'),
          subtitle: const Text('只转接这个订单正在打印的设备，不提供回放和控制'),
          value: _portalVideo,
          onChanged: (value) => setState(() => _portalVideo = value),
        ),
        const SizedBox(height: 12),
        _sectionTitle('生产清单与设备', Icons.view_module_outlined),
        const SizedBox(height: 8),
        for (final package in _packages)
          _PackageEditor(
            package: package,
            printers: _printers,
            enabled: _createdOrderId == null,
            onChanged: () {
              setState(() {});
            },
          ),
      ],
    );
  }

  Widget _buildQuoteSummary() {
    final result = _quoteCalculation;
    final scheme = Theme.of(context).colorScheme;
    final warning = result?.needsReview == true;
    return Container(
      key: const Key('production-order-auto-quote'),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: warning
            ? FarmVisual.warning.withValues(alpha: 0.08)
            : FarmVisual.primary.withValues(alpha: 0.07),
        border: Border.all(
          color: warning
              ? FarmVisual.warning.withValues(alpha: 0.35)
              : FarmVisual.primary.withValues(alpha: 0.22),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(
            warning ? Icons.warning_amber_rounded : Icons.calculate_outlined,
            size: 18,
            color: warning ? FarmVisual.warning : FarmVisual.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _pricingLoading
                      ? '正在按当前配置计算报价'
                      : result == null
                          ? '报价将在读取切片数据后自动计算'
                          : warning
                              ? '建议报价 ${result.quotedPrice.toStringAsFixed(2)} 元 · 待核对'
                              : '建议报价 ${result.quotedPrice.toStringAsFixed(2)} 元 · 成本 ${result.totalCost.toStringAsFixed(2)} 元',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                if (result != null)
                  Text(
                    warning
                        ? [
                            if (result.missingMachines.isNotEmpty)
                              '缺机器：${result.missingMachines.join('、')}',
                            if (result.missingMaterials.isNotEmpty)
                              '缺耗材：${result.missingMaterials.join('、')}',
                          ].join(' · ')
                        : '耗材 ${result.materialCost.toStringAsFixed(2)} · 机器 ${result.machineWearCost.toStringAsFixed(2)} · 人工 ${result.laborCost.toStringAsFixed(2)} · 电费 ${result.electricityCost.toStringAsFixed(2)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                  ),
                if (_priceOverridden)
                  const Text(
                    '订单金额已手动覆盖，保存前需在内部备注填写原因。',
                    style: TextStyle(fontSize: 10, color: FarmVisual.warning),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
            child: _field(
              '人工小时',
              _laborHours,
              decimal: true,
              onChanged: (_) => _queueQuoteRefresh(),
            ),
          ),
          IconButton(
            tooltip: '重新计算报价',
            onPressed: _pricingLoading || _createdOrderId != null
                ? null
                : _refreshAutoQuote,
            icon: _pricingLoading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded, size: 19),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, IconData icon) => Row(
        children: [
          Icon(icon, size: 18, color: FarmVisual.primary),
          const SizedBox(width: 7),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      );

  Widget _field(
    String label,
    TextEditingController controller, {
    bool decimal = false,
    ValueChanged<String>? onChanged,
  }) =>
      TextField(
        enabled: _createdOrderId == null,
        controller: controller,
        keyboardType: decimal
            ? const TextInputType.numberWithOptions(decimal: true)
            : null,
        onChanged: onChanged,
        decoration: InputDecoration(labelText: label, isDense: true),
      );

  void _queueQuoteRefresh() {
    _quoteDebounce?.cancel();
    _quoteDebounce = Timer(
      const Duration(milliseconds: 220),
      () => unawaited(_refreshAutoQuote()),
    );
  }

  Future<StudioQuoteCalculation> _calculateAutoQuote() async {
    final workspace =
        (await ref.read(studioDaoProvider).getDefaultSnapshot()).workspace;
    final configDao = ref.read(studioQuoteConfigDaoProvider);
    final settings = await configDao.getSettings(workspace.id);
    final machines = await configDao.getMachines(workspace.id);
    final drafts = [for (final package in _packages) package.toDraft()];
    return StudioQuoteCalculator(
      ref.read(filamentCostConfigDaoProvider),
    ).calculateProductionOrder(
      settings: settings,
      machines: machines,
      packages: drafts,
      laborHours: double.tryParse(_laborHours.text.trim()) ?? 0,
    );
  }

  Future<void> _refreshAutoQuote() async {
    if (!mounted || _packages.isEmpty || _pricingLoading) return;
    setState(() => _pricingLoading = true);
    try {
      final result = await _calculateAutoQuote();
      if (!mounted) return;
      setState(() {
        _quoteCalculation = result;
        _pricingLoading = false;
        if (!_priceOverridden) {
          _price.text = result.quotedPrice.toStringAsFixed(2);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _pricingLoading = false);
    }
  }

  Future<void> _pickFiles() async {
    final remaining = 5 - _packages.length;
    if (remaining <= 0) return;
    const group = XTypeGroup(
      label: '拓竹打印文件',
      extensions: ['3mf', 'gcode', 'g', 'gc'],
    );
    final files = await openFiles(acceptedTypeGroups: const [group]);
    await _addFiles(files.take(remaining).map((file) => file.path));
  }

  Future<void> _slicePendingInsideSohun() async {
    final selected = [
      for (final package in _packages)
        for (final plate in package.plates)
          if (!plate.isSliced && plate.selectedForSlicing) (package, plate),
    ];
    if (selected.isEmpty) {
      showSnack(context, '请先勾选当前要切片的盘', error: true);
      return;
    }
    final missingSettings = selected
        .map((item) => item.$1)
        .where((package) => !package.inspection.hasEmbeddedSettings)
        .map((package) => package.sourceDisplayName)
        .toSet()
        .toList();
    if (missingSettings.isNotEmpty) {
      showSnack(
        context,
        '这些 3MF 没有完整的机型/工艺/耗材参数，请先用 Bambu Studio 打开并保存：'
        '${missingSettings.join('、')}',
        error: true,
      );
      return;
    }

    final availablePrinters =
        await ref.read(printersWithChannelsProvider.future);
    if (!mounted) return;
    _printers = availablePrinters;
    final fleet = ref.read(fleetPrinterStatesProvider);
    final plans = <({
      _PackageDraftState package,
      _PlateDraftState plate,
      FarmSlicingTarget target,
      FarmSlicingPreset preset,
    })>[];
    final chosenPresets = <String, FarmSlicingPreset>{};
    try {
      for (final item in selected) {
        final package = item.$1;
        final plate = item.$2;
        if (plate.printerIds.isEmpty) {
          final printer = await showFarmSlicingPrinterPicker(
            context,
            printers: availablePrinters,
            fleet: fleet,
          );
          if (printer == null || !mounted) return;
          plate.printerIds.add(printer.printer.printer.id);
        }

        final printerSelections = <FarmSlicingPrinterCandidate>[];
        for (final printer in availablePrinters.where(
          (item) => plate.printerIds.contains(item.printer.id),
        )) {
          final serial = printer.serial;
          final state = serial == null
              ? null
              : fleet.where((item) => item.serial == serial).firstOrNull;
          if (state == null) {
            throw FarmSlicingWorkflowException(
              '${printer.printer.name ?? printer.printer.model} 没有可用的设备状态，'
              '请先同步设备后再切片',
            );
          }
          printerSelections.add(
            FarmSlicingPrinterCandidate(printer: printer, state: state),
          );
        }
        final target = requireFarmSlicingTarget(printerSelections);
        final targetKey =
            '${target.model}:${target.nozzleDiameter.toStringAsFixed(3)}';
        var preset = chosenPresets[targetKey];
        if (preset == null) {
          preset = await showFarmSlicingPresetPicker(
            context,
            ref,
            target: target,
          );
          if (preset == null || !mounted) return;
          chosenPresets[targetKey] = preset;
        }
        plans.add((
          package: package,
          plate: plate,
          target: target,
          preset: preset,
        ));
      }
    } on FarmSlicingWorkflowException catch (error) {
      if (mounted) {
        showSnack(context, error.message, error: true);
      }
      return;
    }

    final status = await ref.read(activeSlicerStatusProvider.future);
    if (!mounted) return;
    final executable = status?.executablePath;
    if (executable == null) {
      showSnack(context, '未找到 Bambu Studio，请先在切片设置中配置程序路径', error: true);
      return;
    }

    setState(() => _slicingFiles = true);
    final failures = <String>[];
    try {
      for (final plan in plans) {
        final package = plan.package;
        final plate = plan.plate;
        if (!mounted) return;
        setState(() {
          package.isSlicing = true;
          plate.isSlicing = true;
          plate.sliceError = null;
        });
        try {
          await ref
              .read(farmSlicingPresetsProvider.notifier)
              .validateManagedPreset(
                plan.preset,
                model: plan.target.model,
                nozzleDiameter: plan.target.nozzleDiameter,
              );
          final result =
              await ref.read(farmSliceIntakeProvider.notifier).runManagedSlice(
                    () => BambuStudioSlicingService.sliceProject(
                      executablePath: executable,
                      sourcePath: package.sourcePath,
                      plateIndex: plate.source.plateIndex,
                      settingsPaths: plan.preset.settingsPaths,
                      filamentSettingsPaths: plan.preset.filamentSettingsPaths,
                    ),
                    inspectionOf: (result) => result.inspection,
                    sourcePath: package.sourcePath,
                  );
          if (!mounted) return;
          setState(() {
            package.applySlicedInspection(
              result.inspection,
              artifactPath: result.outputPath,
              onlyPlateIndex: plate.source.plateIndex,
              autoEjectEnabled: false,
              targetModel: plan.target.model,
              nozzleDiameter: plan.target.nozzleDiameter,
            );
          });
        } catch (error) {
          failures.add(
            '${package.sourceDisplayName} / ${plate.source.displayName}',
          );
          if (mounted) {
            setState(() => plate.sliceError = '$error');
          }
        } finally {
          if (mounted) {
            setState(() {
              plate.isSlicing = false;
              package.isSlicing = package.plates.any((item) => item.isSlicing);
            });
          }
        }
      }
    } finally {
      if (mounted) setState(() => _slicingFiles = false);
    }
    if (!mounted) return;
    if (failures.isEmpty) {
      showSnack(context, '所选 ${selected.length} 个盘已切片，其他盘仍保留为待切片');
    } else {
      showSnack(
        context,
        '${failures.join('、')} 自动切片失败，可用 Bambu Studio 打开后继续',
        error: true,
      );
    }
  }

  Future<void> _launchPendingInBambuStudio() async {
    final selectedPackages = _packages
        .where((package) => package.selectedPendingPlateCount > 0)
        .toList();
    final pending = selectedPackages.isNotEmpty
        ? selectedPackages
        : _packages.where((package) => package.pendingPlateCount > 0).toList();
    if (pending.isEmpty) return;
    final status = await ref.read(activeSlicerStatusProvider.future);
    if (!mounted) return;
    final executable = status?.executablePath;
    if (status == null || executable == null) {
      showSnack(context, '未找到 Bambu Studio，请先在切片设置中配置程序路径', error: true);
      return;
    }
    if (status.outputDirectory case final directory?) {
      final watcher = ref.read(slicerWatcherProvider);
      if (!watcher.isWatching || watcher.watchDirectory != directory) {
        unawaited(
          ref.read(slicerWatcherProvider.notifier).startWatching(directory),
        );
      }
    }
    final launched = await status.detector.launch(
      executablePath: executable,
      arguments: [for (final package in pending) package.sourcePath],
    );
    if (!mounted) return;
    if (!launched) {
      showSnack(context, 'Bambu Studio 启动失败，请检查程序路径', error: true);
      return;
    }
    setState(() {
      for (final package in pending) {
        package.markSlicerLaunched();
      }
    });
    showSnack(
      context,
      '源 3MF 已交给 Bambu Studio；完成切片并保存或发送后，Sohun 会自动读取结果',
    );
  }

  Future<void> _refreshPackages() async {
    if (_readingFiles) return;
    setState(() => _readingFiles = true);
    var upgraded = 0;
    try {
      for (final package in _packages.where(
        (item) => item.pendingPlateCount > 0,
      )) {
        final inspection = await SliceIsolateRunner.inspectProductionPackage(
          package.sourcePath,
        );
        if (!mounted) return;
        if (inspection?.hasAnySlicedPlate == true) {
          upgraded += package.applySlicedInspection(inspection!);
        }
      }
    } finally {
      if (mounted) setState(() => _readingFiles = false);
    }
    if (!mounted) return;
    showSnack(
      context,
      upgraded > 0 ? '已按盘读取 $upgraded 个切片结果' : '暂未发现新的单盘切片结果；未切片盘会继续保留',
    );
  }

  Future<void> _addFiles(Iterable<String> paths) async {
    if (_readingFiles || _createdOrderId != null) return;
    final normalizedExisting = {
      for (final package in _packages)
        package.inspection.artifactPath.toLowerCase(),
    };
    final seen = {...normalizedExisting};
    final unique = <String>[];
    for (final path in paths) {
      if (seen.add(path.toLowerCase())) unique.add(path);
    }
    if (unique.isEmpty) return;
    setState(() => _readingFiles = true);
    final rejected = <String>[];
    var skippedAtLimit = 0;
    try {
      for (final path in unique) {
        if (_packages.length >= 5) {
          skippedAtLimit++;
          continue;
        }
        final inspection = await SliceIsolateRunner.inspectProductionPackage(
          path,
        );
        final readableSource3mf = inspection != null &&
            inspection.kind == ProductionArtifactKind.bambu3mf &&
            inspection.plates.isNotEmpty;
        if (inspection == null ||
            (!inspection.isUsable && !readableSource3mf)) {
          rejected.add(path.split(RegExp(r'[/\\]')).last);
          continue;
        }
        if (!mounted) return;
        setState(() {
          _packages.add(_PackageDraftState(inspection));
          if (_title.text.trim().isEmpty) {
            _title.text = inspection.displayName;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _readingFiles = false);
    }
    if (mounted && rejected.isNotEmpty) {
      showSnack(
        context,
        '以下文件不是可读取的 3MF 或切片 G-code：${rejected.join('、')}',
        error: true,
      );
    }
    if (mounted && skippedAtLimit > 0) {
      showSnack(context, '每个工单最多 5 个打印文件，另有 $skippedAtLimit 个文件未加入');
    }
  }

  void _removePackage(int index) {
    setState(() {
      _packages.removeAt(index).dispose();
      if (_packages.isEmpty) _detailsVisible = false;
    });
  }

  Future<void> _pickDueDate() async {
    if (_createdOrderId != null) return;
    final value = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: _dueAt ?? DateTime.now(),
    );
    if (value != null) setState(() => _dueAt = value);
  }

  Future<void> _saveAndCreateAccess() async {
    if (_title.text.trim().isEmpty || _orderNo.text.trim().isEmpty) {
      showSnack(context, '请填写订单名称和订单编号', error: true);
      return;
    }
    if (_packages.isEmpty || _packages.length > 5) {
      showSnack(context, '请添加 1-5 个已摆盘的 3MF 项目', error: true);
      return;
    }
    if (_priceOverridden && _note.text.trim().isEmpty) {
      showSnack(context, '手动修改订单金额后，请在内部备注填写覆盖原因', error: true);
      return;
    }
    final auth = ref.read(appAuthProvider);
    if (!auth.isSignedIn || auth.endpoint == null) {
      showSnack(context, '请先登录 sohun 云服务，才能生成客户密码和专属链接', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final dao = ref.read(studioDaoProvider);
      if (_createdOrderId == null) {
        final drafts = <StudioProductionPackageDraft>[];
        for (final package in _packages) {
          final durablePath =
              package.inspection.kind == ProductionArtifactKind.bambu3mf
                  ? await BambuStudioSlicingService.preserveSourceProject(
                      package.sourcePath,
                    )
                  : package.sourcePath;
          drafts.add(package.toDraft(localPathOverride: durablePath));
        }
        final calculation = await _calculateAutoQuote();
        final settings = await ref
            .read(studioQuoteConfigDaoProvider)
            .getSettings((await dao.getDefaultSnapshot()).workspace.id);
        final estimatedGrams = drafts.fold<double>(
          0,
          (sum, package) =>
              sum +
              package.plates.fold<double>(
                0,
                (plateSum, plate) => plateSum + plate.totalRequiredGrams,
              ),
        );
        final machineHours = drafts.fold<double>(
          0,
          (sum, package) =>
              sum +
              package.plates.fold<double>(
                0,
                (plateSum, plate) =>
                    plateSum +
                    plate.estimatedSeconds * plate.requiredRuns / 3600,
              ),
        );
        final materialLabels = <String>{
          for (final package in drafts)
            for (final plate in package.plates)
              for (final filament in plate.activeFilaments)
                [
                  if (filament.vendor?.trim().isNotEmpty == true)
                    filament.vendor!.trim(),
                  filament.materialType?.trim().isNotEmpty == true
                      ? filament.materialType!.trim()
                      : '未知材质',
                  if (filament.colorHex?.trim().isNotEmpty == true)
                    filament.colorHex!.trim(),
                ].join(' / '),
        };
        final quotePrice = _priceOverridden
            ? (double.tryParse(_price.text.trim()) ?? calculation.quotedPrice)
            : calculation.quotedPrice;
        final reviewReasons = <String>[
          if (calculation.missingMachines.isNotEmpty)
            '缺少机器损耗：${calculation.missingMachines.join('、')}',
          if (calculation.missingMaterials.isNotEmpty)
            '缺少耗材成本：${calculation.missingMaterials.join('、')}',
          if (_priceOverridden) '手动覆盖：${_note.text.trim()}',
        ];
        final now = DateTime.now();
        final quote = StudioQuote(
          id: const Uuid().v4(),
          workspaceId: (await dao.getDefaultSnapshot()).workspace.id,
          orderId: null,
          quoteNo: 'QT-${_orderNo.text.trim()}',
          title: _title.text.trim(),
          status: StudioQuoteStatus.draft,
          materialLabel:
              materialLabels.isEmpty ? '待核对耗材' : materialLabels.join('；'),
          estimatedGrams: estimatedGrams,
          materialCostPerKgSnapshot: estimatedGrams <= 0
              ? 0
              : calculation.materialCost / estimatedGrams * 1000,
          machineHours: machineHours,
          machineRatePerHour: machineHours <= 0
              ? 0
              : calculation.machineWearCost / machineHours,
          laborHours: double.tryParse(_laborHours.text.trim()) ?? 0,
          laborRatePerHour: settings.laborRatePerHour,
          electricityCost: calculation.electricityCost,
          packagingCost: settings.packagingCost,
          riskPercent: settings.riskReservePercent,
          markupPercent: settings.markupPercent,
          totalCost: calculation.totalCost,
          quotedPrice: quotePrice,
          note:
              reviewReasons.isEmpty ? '自动报价' : '待核对：${reviewReasons.join('；')}',
          createdAt: now,
          updatedAt: now,
        );
        _createdOrderId = await dao.addProductionOrder(
          workspaceId: quote.workspaceId,
          orderNo: _orderNo.text,
          title: _title.text,
          dueAt: _dueAt,
          totalPrice: quotePrice,
          note: _note.text,
          publicNote: _publicNote.text,
          portalVideoEnabled: _portalVideo,
          packages: drafts,
          quote: quote,
        );
      }
      final snapshot = await dao.getDefaultSnapshot();
      final order = snapshot.orders.singleWhere(
        (item) => item.id == _createdOrderId,
      );
      _portalPassword ??= _randomPassword();
      _portalUrl ??=
          (await ref.read(studioCloudServiceProvider).createShareLink(
                    order,
                    portalPassword: _portalPassword!,
                  ))
              .publicUrl
              .toString();
      final copyText = _accessText(
        orderNo: order.orderNo,
        password: _portalPassword!,
        dedicatedUrl: _portalUrl!,
      );
      await Clipboard.setData(ClipboardData(text: copyText));
      if (!mounted) return;
      await _showCreated(
        orderNo: order.orderNo,
        password: _portalPassword!,
        dedicatedUrl: _portalUrl!,
        copyText: copyText,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(
          context,
          _createdOrderId == null
              ? '创建工单失败：$error'
              : '工单已建立，但访问资料生成失败；可直接重试：$error',
          error: true,
        );
      }
    }
  }

  Future<void> _showCreated({
    required String orderNo,
    required String password,
    required String dedicatedUrl,
    required String copyText,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: FarmVisual.primary),
            const SizedBox(width: 8),
            const Text('工单与客户入口已创建'),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SelectionArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AccessRow(label: '订单号', value: orderNo),
                _AccessRow(label: '随机密码', value: password),
                _AccessRow(label: '专属链接', value: dedicatedUrl),
                const _AccessRow(label: '官网入口', value: _officialWebsite),
                const SizedBox(height: 10),
                Text(
                  '以上内容已复制。密码不会以明文保存在本机或服务器快照中。',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: copyText));
              if (dialogContext.mounted) {
                showSnack(dialogContext, '访问资料已重新复制');
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 17),
            label: const Text('再次复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}

String _randomPassword() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  final random = math.Random.secure();
  return List.generate(10, (_) => chars[random.nextInt(chars.length)]).join();
}

String _accessText({
  required String orderNo,
  required String password,
  required String dedicatedUrl,
}) =>
    'sohun 客户订单\n'
    '订单号：$orderNo\n'
    '访问密码：$password\n'
    '专属链接：$dedicatedUrl\n'
    '官网入口：$_officialWebsite';

class _PackageDraftState {
  _PackageDraftState(this.inspection)
      : sourcePath = inspection.artifactPath,
        sourceDisplayName = inspection.displayName,
        copies = TextEditingController(text: '1'),
        plates = [] {
    final productionPlates = inspection.productionPlates;
    for (final plate in productionPlates) {
      plates.add(
        _PlateDraftState(
          plate,
          targetModel: inspection.targetModel,
          nozzleDiameter: inspection.nozzleDiameter,
          artifactPath: plate.hasToolpath ? inspection.artifactPath : null,
          artifactSha256: plate.hasToolpath ? inspection.artifactSha256 : null,
          selectedForSlicing:
              productionPlates.length == 1 && !plate.hasToolpath,
        ),
      );
    }
  }

  ProductionPackageInspection inspection;
  final String sourcePath;
  final String sourceDisplayName;
  final TextEditingController copies;
  final List<_PlateDraftState> plates;
  DateTime? slicerLaunchedAt;
  bool isSlicing = false;

  bool get allPlatesSliced =>
      plates.isNotEmpty && plates.every((plate) => plate.isSliced);

  int get pendingPlateCount => plates.where((plate) => !plate.isSliced).length;

  int get selectedPendingPlateCount => plates
      .where((plate) => !plate.isSliced && plate.selectedForSlicing)
      .length;

  int get slicedPlateCount => plates.where((plate) => plate.isSliced).length;

  String? get firstSliceError =>
      plates.map((plate) => plate.sliceError).whereType<String>().firstOrNull;

  int get sourceInstanceCount => inspection.plates.fold<int>(
        0,
        (sum, plate) =>
            sum +
            plate.parts.fold<int>(
              0,
              (partSum, part) => partSum + part.instancesPerRun,
            ),
      );

  void markSlicerLaunched() => slicerLaunchedAt = DateTime.now();

  bool matches(ProductionPackageInspection candidate) {
    final currentKeys = {
      ..._inspectionKeys(inspection),
      _normalizedInspectionPath(sourcePath),
    };
    final candidateKeys = _inspectionKeys(candidate);
    return currentKeys.any(candidateKeys.contains);
  }

  int applySlicedInspection(
    ProductionPackageInspection next, {
    String? artifactPath,
    int? onlyPlateIndex,
    bool? autoEjectEnabled,
    String? targetModel,
    double? nozzleDiameter,
  }) {
    final nextByIndex = <int, ProductionPlateInspection>{
      for (final plate in next.plates) plate.plateIndex: plate,
    };
    var applied = 0;
    for (final plate in plates) {
      if (onlyPlateIndex != null && plate.source.plateIndex != onlyPlateIndex) {
        continue;
      }
      final sliced = nextByIndex[plate.source.plateIndex];
      if (sliced == null || !sliced.hasToolpath) continue;
      plate.applySlice(
        sliced,
        artifactPath: artifactPath ?? next.artifactPath,
        artifactSha256: next.artifactSha256,
        autoEjectEnabled: autoEjectEnabled,
        targetModel: targetModel,
        nozzleDiameter: nozzleDiameter,
      );
      applied++;
    }
    isSlicing = false;
    return applied;
  }

  void applyCopies() {
    final multiplier = _positive(copies.text);
    for (final plate in plates) {
      plate.applyCopies(multiplier);
    }
  }

  StudioProductionPackageDraft toDraft({String? localPathOverride}) =>
      StudioProductionPackageDraft(
        sourceName: sourceDisplayName,
        localPath: localPathOverride ?? sourcePath,
        artifactSha256: inspection.artifactSha256,
        artifactKind: inspection.kind.name,
        slicerName: inspection.slicerName,
        slicerVersion: inspection.slicerVersion,
        targetModel: inspection.targetModel,
        nozzleDiameter: inspection.nozzleDiameter,
        plates: [for (final plate in plates) plate.toDraft()],
      );

  void dispose() {
    copies.dispose();
    for (final plate in plates) {
      plate.dispose();
    }
  }
}

Set<String> _inspectionKeys(ProductionPackageInspection inspection) {
  final values = <String?>[
    inspection.artifactPath,
    inspection.projectPath,
    inspection.correlationKey,
  ];
  return {
    for (final value in values)
      if (value != null && value.trim().isNotEmpty)
        _normalizedInspectionPath(value),
  };
}

String _normalizedInspectionPath(String value) =>
    value.trim().replaceAll('\\', '/').replaceAll('"', '').toLowerCase();

class _PlateDraftState {
  _PlateDraftState(
    this.source, {
    this.targetModel,
    this.nozzleDiameter,
    this.artifactPath,
    this.artifactSha256,
    this.selectedForSlicing = false,
  }) : items = [for (final item in source.parts) _ItemDraftState(item)];

  ProductionPlateInspection source;
  String? targetModel;
  double? nozzleDiameter;
  final List<_ItemDraftState> items;
  final Set<int> printerIds = {};
  String? artifactPath;
  String? artifactSha256;
  bool? autoEjectEnabled;
  bool selectedForSlicing;
  bool isSlicing = false;
  String? sliceError;

  bool get isSliced => source.hasToolpath && artifactPath != null;

  List<StudioPlateFilamentUsage> get filamentUsage => [
        for (final item in source.filaments)
          StudioPlateFilamentUsage(
            toolIndex: item.toolIndex,
            grams: item.grams,
            vendor: item.vendor,
            materialType: item.materialType,
            colorHex: item.colorHex,
            trayId: item.trayId,
            sku: item.sku,
            usedForObject: item.usedForObject,
            usedForSupport: item.usedForSupport,
            groupId: item.groupId,
            nozzleDiameter: item.nozzleDiameter,
            volumeType: item.volumeType,
          ),
      ];

  int get activeFilamentCount => source.activeFilaments.length;

  bool supportsAutomaticMulticolor(PrinterWithChannels printer) {
    if (!source.isMulticolor) return true;
    final amsSlots = printer.channels.where(
      (item) => !isExternalFeedChannel(item.channel.channelIndex),
    );
    return amsSlots.length >= activeFilamentCount;
  }

  void applySlice(
    ProductionPlateInspection sliced, {
    required String artifactPath,
    String? artifactSha256,
    bool? autoEjectEnabled,
    String? targetModel,
    double? nozzleDiameter,
  }) {
    source = ProductionPlateInspection(
      plateIndex: source.plateIndex,
      name: source.name.trim().isNotEmpty ? source.name : sliced.name,
      hasToolpath: true,
      estimatedSeconds: sliced.estimatedSeconds,
      totalLayers: sliced.totalLayers,
      toolChangeCount: sliced.toolChangeCount,
      estimatedGrams: sliced.estimatedGrams,
      parts: source.parts,
      filaments: sliced.filaments,
      thumbnailBytes: sliced.thumbnailBytes ?? source.thumbnailBytes,
    );
    this.artifactPath = artifactPath;
    this.artifactSha256 = artifactSha256;
    this.autoEjectEnabled = autoEjectEnabled;
    this.targetModel = targetModel ?? this.targetModel;
    this.nozzleDiameter = nozzleDiameter ?? this.nozzleDiameter;
    selectedForSlicing = false;
    sliceError = null;
  }

  void applyCopies(int multiplier) {
    for (final item in items) {
      item.applyCopies(multiplier);
    }
  }

  int get requiredRuns {
    var runs = 1;
    for (final item in items) {
      runs = math.max(runs, item.requiredRuns);
    }
    return runs;
  }

  bool compatible(PrinterWithChannels printer) =>
      targetModel == null ||
      targetModel!.trim().isEmpty ||
      PrinterModelNormalizer.sameModel(targetModel!, printer.printer.model);

  StudioProductionPlateDraft toDraft() => StudioProductionPlateDraft(
        plateIndex: source.plateIndex,
        name: source.displayName,
        requiredRuns: requiredRuns,
        estimatedSeconds: source.estimatedSeconds,
        estimatedGrams: source.estimatedGrams,
        sliceStatus: isSliced
            ? StudioPlateSliceStatus.sliced
            : StudioPlateSliceStatus.pending,
        sliceArtifactPath: artifactPath,
        sliceArtifactSha256: artifactSha256,
        sliceTargetModel: targetModel,
        sliceNozzleDiameter: nozzleDiameter ??
            source.activeFilaments
                .map((item) => item.nozzleDiameter)
                .whereType<double>()
                .firstOrNull,
        autoEjectEnabled: autoEjectEnabled,
        thumbnailBytes: source.thumbnailBytes,
        totalLayers: source.totalLayers,
        toolChangeCount: source.toolChangeCount,
        filaments: filamentUsage,
        assignedPrinterIds: printerIds.toList(),
        items: [for (final item in items) item.toDraft()],
      );

  void dispose() {
    for (final item in items) {
      item.dispose();
    }
  }
}

class _ItemDraftState {
  _ItemDraftState(this.source)
      : name = TextEditingController(text: source.name),
        perRun = TextEditingController(text: '${source.instancesPerRun}'),
        required = TextEditingController(text: '${source.instancesPerRun}');

  final ProductionPartInspection source;
  final TextEditingController name;
  final TextEditingController perRun;
  final TextEditingController required;

  int get perRunValue => _positive(perRun.text);
  int get requiredValue => _positive(required.text);
  int get requiredRuns => (requiredValue / perRunValue).ceil();

  void applyCopies(int multiplier) {
    required.text = '${perRunValue * math.max(1, multiplier)}';
  }

  StudioOrderItemDraft toDraft() => StudioOrderItemDraft(
        sourceKey: source.key,
        name: name.text.trim().isEmpty ? source.name : name.text.trim(),
        perRunQuantity: perRunValue,
        requiredQuantity: requiredValue,
      );

  void dispose() {
    name.dispose();
    perRun.dispose();
    required.dispose();
  }
}

int _positive(String value) {
  final parsed = int.tryParse(value.trim());
  return parsed == null || parsed < 1 ? 1 : parsed;
}

String _formatSliceDuration(int seconds) {
  final safe = math.max(0, seconds);
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  if (hours > 0) return '$hours 小时 $minutes 分';
  return '$minutes 分钟';
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.package, required this.onRemove});

  final _PackageDraftState package;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 350),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              package.allPlatesSliced
                  ? Icons.check_circle_outline_rounded
                  : Icons.view_in_ar_outlined,
              size: 18,
              color: package.allPlatesSliced
                  ? Colors.green.shade600
                  : FarmVisual.warning,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    package.sourceDisplayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '${package.plates.length} 个生产盘 · '
                    '${package.slicedPlateCount} 已切 / ${package.pendingPlateCount} 待切 · '
                    '${package.inspection.targetModel ?? '机型待确认'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (package.isSlicing)
                    const Text(
                      'Sohun 后台切片中…',
                      style: TextStyle(fontSize: 9, color: FarmVisual.warning),
                    )
                  else if (package.firstSliceError != null)
                    Text(
                      package.firstSliceError!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9, color: Colors.red),
                    )
                  else if (!package.allPlatesSliced &&
                      package.slicerLaunchedAt != null)
                    const Text(
                      'Bambu Studio 已启动，等待切片结果',
                      style: TextStyle(fontSize: 9, color: FarmVisual.warning),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: '移除文件',
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 16),
            ),
          ],
        ),
      );
}

class _SourceProjectSummary extends StatelessWidget {
  const _SourceProjectSummary({
    required this.package,
    required this.onChanged,
  });

  final _PackageDraftState package;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 5),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            package.sourceDisplayName,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          for (final plate in package.plates)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 30,
                    height: 24,
                    child: Checkbox(
                      value: plate.isSliced || plate.selectedForSlicing,
                      onChanged: plate.isSliced || plate.isSlicing
                          ? null
                          : (value) {
                              plate.selectedForSlicing = value == true;
                              onChanged();
                            },
                    ),
                  ),
                  const SizedBox(width: 3),
                  SizedBox(
                    width: 170,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '第 ${plate.source.plateIndex} 盘 · ${plate.source.displayName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          plate.isSliced
                              ? '已切片，可独立安排'
                              : plate.isSlicing
                                  ? '正在切这一盘'
                                  : '待切片，可留到以后',
                          style: TextStyle(
                            fontSize: 9,
                            color: plate.isSliced
                                ? Colors.green.shade700
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: [
                        for (final part in plate.source.parts)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '${part.name} × ${part.instancesPerRun}',
                              style: const TextStyle(fontSize: 9),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PackageEditor extends StatelessWidget {
  const _PackageEditor({
    required this.package,
    required this.printers,
    required this.enabled,
    required this.onChanged,
  });

  final _PackageDraftState package;
  final List<PrinterWithChannels> printers;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          package.inspection.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          '整套份数会同步到这个文件里的每一盘，仍可单独修改成品数量',
                          style: TextStyle(
                            fontSize: 9,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      enabled: enabled,
                      controller: package.copies,
                      keyboardType: TextInputType.number,
                      onChanged: (_) {
                        package.applyCopies();
                        onChanged();
                      },
                      decoration: const InputDecoration(
                        labelText: '整套份数',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${package.inspection.targetModel ?? '机型待确认'} · ${package.inspection.nozzleDiameter?.toStringAsFixed(1) ?? '未知'} mm',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            for (final plate in package.plates)
              _PlateEditor(
                plate: plate,
                printers: printers,
                enabled: enabled,
                onChanged: onChanged,
              ),
          ],
        ),
      );
}

class _PlateEditor extends StatelessWidget {
  const _PlateEditor({
    required this.plate,
    required this.printers,
    required this.enabled,
    required this.onChanged,
  });

  final _PlateDraftState plate;
  final List<PrinterWithChannels> printers;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final compatiblePrinters =
        printers.where(plate.compatible).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '第 ${plate.source.plateIndex} 盘',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  plate.source.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Container(
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: (plate.isSliced ? Colors.green : FarmVisual.warning)
                      .withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  plate.isSliced ? '已切片' : '待切片',
                  style: TextStyle(
                    fontSize: 9,
                    color: plate.isSliced
                        ? Colors.green.shade700
                        : FarmVisual.warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${plate.requiredRuns} 次运行',
                style: TextStyle(
                  fontSize: 11,
                  color: FarmVisual.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (plate.isSliced) ...[
            const SizedBox(height: 4),
            Text(
              '${_formatSliceDuration(plate.source.estimatedSeconds)} · '
              '${plate.source.estimatedGrams.toStringAsFixed(1)} g · '
              '${plate.source.totalLayers} 层 · '
              '${plate.source.toolChangeCount} 次换料',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            StudioPlateFilamentSummary(
              filaments: plate.filamentUsage,
              toolChangeCount: plate.source.toolChangeCount,
              requiredRuns: plate.requiredRuns,
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              '可先分配产能并保存；真正准备打印这一盘时再切片。',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 7),
          for (final item in plate.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      enabled: enabled,
                      controller: item.name,
                      onChanged: (_) => onChanged(),
                      decoration: const InputDecoration(
                        labelText: '成品项',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 98,
                    child: TextField(
                      enabled: enabled,
                      controller: item.perRun,
                      onChanged: (_) => onChanged(),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '一盘数量',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 98,
                    child: TextField(
                      enabled: enabled,
                      controller: item.required,
                      onChanged: (_) => onChanged(),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '订单数量',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 68,
                    child: Text(
                      '超产 ${item.requiredRuns * item.perRunValue - item.requiredValue}',
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          if (compatiblePrinters.isEmpty)
            Text(
              '没有已配置的匹配机型，保存后进入待分配队列。',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final printer in compatiblePrinters)
                  FilterChip(
                    selected: plate.printerIds.contains(printer.printer.id),
                    onSelected: !enabled
                        ? null
                        : (selected) {
                            if (selected) {
                              plate.printerIds.add(printer.printer.id);
                            } else {
                              plate.printerIds.remove(printer.printer.id);
                            }
                            onChanged();
                          },
                    avatar: const Icon(Icons.print_outlined, size: 15),
                    label: Text(
                      '${printer.printer.name?.trim().isNotEmpty == true ? printer.printer.name! : printer.printer.model}'
                      '${plate.supportsAutomaticMulticolor(printer) ? '' : '（需手动换料）'}',
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _AccessRow extends StatelessWidget {
  const _AccessRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
}
