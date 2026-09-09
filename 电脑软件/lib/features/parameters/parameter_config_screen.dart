import 'dart:io';

import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import '../../widgets/glass_button_material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_util;

import '../../core/utils/friendly_error.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/utils/image_storage.dart';
import '../../data/external/slicer/bambu_studio_param_exporter.dart';
import '../../data/external/slicer/material_catalog_service.dart';
import '../../data/external/slicer/bambu_system_preset_loader.dart';
import '../../data/external/slicer/preset_cloud_uploader.dart';
import '../../data/database/daos/preset_result_dao.dart';
import '../../data/models/filament_preset.dart';
import '../../data/models/plate_type.dart';
import '../../data/models/print_parameter.dart';
import '../../data/models/printer_preset.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../../providers/app_auth_provider.dart';
import '../../providers/community_preset_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/material_catalog_provider.dart';
import '../../providers/parameter_preset_provider.dart';
import '../../providers/slicer_provider.dart';
import '../../ui/aurora_design.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/app_input.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/app_select.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/icon_action_button.dart';
import '../../widgets/material_picker.dart';
import '../../widgets/printer_image.dart';
import 'parameter_field_defs.dart';
import 'preset_compare_dialog.dart';

/// 参数配置页面（左侧分类树 + 右侧参数列表，对标 Bambu Studio）。
///
/// 左侧树分 3 大类：工艺 / 耗材 / 打印机。
/// 右侧显示当前选中分类的参数列表，支持搜索、模式切换、Section 折叠。
class ParameterConfigScreen extends ConsumerStatefulWidget {
  final PrintParameterPreset? preset; // 编辑已有预设，null 表示新建

  const ParameterConfigScreen({super.key, this.preset});

  @override
  ConsumerState<ParameterConfigScreen> createState() =>
      _ParameterConfigScreenState();
}

/// 分类树节点（顶层声明，避免在 State 类内部声明触发 class_in_class 错误）。
class _CategoryNode {
  final String key;
  final String label;
  final bool isGroup;
  final List<_CategoryNode> children;
  const _CategoryNode({
    required this.key,
    required this.label,
    this.isGroup = false,
    this.children = const [],
  });
}

class _ParameterConfigScreenState extends ConsumerState<ParameterConfigScreen> {
  final Map<String, TextEditingController> _controllers = {};
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _authorController = TextEditingController();
  final _searchController = TextEditingController();
  String? _avatarPath; // 作者头像本地相对路径
  String? _previewImagePath; // 预览图本地相对路径
  /// 缓存相对路径 → 绝对路径的 Future，避免每次 rebuild 重新解析导致闪烁。
  final Map<String, Future<String>> _pathFutures = {};
  String _material = 'Generic PLA';
  String _scene = sceneOptions.first;

  /// 标签（预设列表多选）
  Set<String> _selectedTags = {};
  bool _isExporting = false;

  // 顶部选择状态
  String _selectedNozzleDiameter = '0.4';
  PlateType _selectedPlate = PlateType.coolPlate;
  bool _plateWasExplicitlySelected = true;
  String? _selectedFilamentPresetId;
  // L-6 修复：跟踪用户选择的打印机预设 ID，使下拉框能持久化选择
  String? _selectedPrinterId;

  // 系统预设原始值（用于恢复原值按钮）
  Map<String, String> _systemPresetValues = {};
  // 当前选择的系统预设名称
  String? _selectedSystemPreset;
  // 耗材系统预设：当前选择的预设显示名
  String? _selectedFilamentSystemPreset;
  // 耗材系统预设：基于打印机型号的可用列表
  List<String> _filamentSystemPresets = const [];
  // 工艺系统预设：按打印机过滤的可用列表（异步加载，空时回退到按喷嘴直径的未过滤列表）
  List<String> _compatibleProcessPresets = const [];

  // A3 参数搜索
  String _searchQuery = '';
  bool _searchMode = false;
  // A2 普通/高级/开发者模式切换
  ParamLevel _currentLevel = ParamLevel.basic;
  // B1 Section 折叠/展开
  Set<String> _collapsedSections = {};
  // C6 未保存提示
  bool _dirty = false;
  bool _saving = false;
  late final String _workingPresetId;
  int _presetLoadGeneration = 0;
  int _systemPresetLoadGeneration = 0;

  /// 左侧分类树当前选中的叶子节点 key。
  String _selectedCategory = 'quality';

  @override
  void initState() {
    super.initState();
    _workingPresetId = widget.preset?.id ?? 'user_${const Uuid().v4()}';
    _initControllers();
    // 新建预设使用 sohun 账号署名；离线时保持可编辑的空白作者字段。
    if (widget.preset == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final appUser = ref.read(appAuthProvider).user;
        if (mounted && appUser != null) {
          setState(() {
            _authorController.text = appUser.displayName;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _authorController.dispose();
    _searchController.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Mark editor state dirty and rebuild PopScope immediately.  TextField
  /// callbacks do not rebuild their parent by themselves; assigning `_dirty`
  /// directly there used to let the back button close the page without the
  /// unsaved-changes prompt.
  void _markDirty() {
    if (!mounted || _dirty) return;
    setState(() => _dirty = true);
  }

  /// 初始化所有参数控制器。
  void _initControllers() {
    final preset = widget.preset;
    final qualityMap =
        preset?.quality.toMap() ?? const PrintQualityParams().toMap();
    final strengthMap =
        preset?.strength.toMap() ?? const PrintStrengthParams().toMap();
    final speedMap = preset?.speed.toMap() ?? const PrintSpeedParams().toMap();
    final supportMap =
        preset?.support.toMap() ?? const PrintSupportParams().toMap();
    final otherMap = preset?.other.toMap() ?? const PrintOtherParams().toMap();
    final allValues = <String, String>{
      ...qualityMap,
      ...strengthMap,
      ...speedMap,
      ...supportMap,
      ...otherMap,
    };

    for (final field in allProcessFields) {
      _controllers[field.key] = TextEditingController(
        text: allValues[field.key] ?? '',
      );
    }

    // 初始化耗材丝参数控制器（默认 PLA 通用值）
    final filamentMap = <String, String>{
      ...const FilamentTempParams().toMap(),
      ...const FilamentFlowParams().toMap(),
      ...const FilamentFanParams().toMap(),
      ...const FilamentRetractionParams().toMap(),
      ...const FilamentDryingParams().toMap(),
      ...const FilamentPropertyParams().toMap(),
    };
    for (final field in filamentFields) {
      _controllers[field.key] = TextEditingController(
        text: filamentMap[field.key] ?? '',
      );
    }

    // 初始化打印机参数控制器（默认空，选择打印机预设后填充）
    for (final field in machineFields) {
      _controllers[field.key] = TextEditingController(text: '');
    }

    _nameController.text = preset?.name ?? '';
    _descController.text = preset?.description ?? '';
    _authorController.text = preset?.author ?? '';
    _avatarPath = preset?.avatarUrl; // 复用 avatarUrl 字段存本地相对路径
    _previewImagePath = preset?.previewImageUrl; // 复用 previewImageUrl 字段存本地相对路径
    _material = preset?.material ?? defaultMaterialOptions.first;
    _scene = preset?.scene ?? sceneOptions.first;
    _selectedTags = {...?preset?.tags};
    _plateWasExplicitlySelected = preset == null || preset.plateType != null;
    if (preset?.plateType != null) {
      _selectedPlate = PlateType.values.firstWhere(
        (plate) => plate.name == preset!.plateType,
        orElse: () => PlateType.coolPlate,
      );
    }
  }

  /// 从所有控制器收集值，构造 PrintParameterPreset。
  PrintParameterPreset _buildPreset() {
    final values = <String, String>{};
    for (final entry in _controllers.entries) {
      values[entry.key] = entry.value.text.trim();
    }

    // 按分类拆分
    final qualityMap = <String, dynamic>{};
    final strengthMap = <String, dynamic>{};
    final speedMap = <String, dynamic>{};
    final supportMap = <String, dynamic>{};
    final otherMap = <String, dynamic>{};

    for (final field in qualityFields) {
      qualityMap[field.key] = values[field.key] ?? '';
    }
    for (final field in strengthFields) {
      strengthMap[field.key] = values[field.key] ?? '';
    }
    for (final field in speedFields) {
      speedMap[field.key] = values[field.key] ?? '';
    }
    for (final field in supportFields) {
      supportMap[field.key] = values[field.key] ?? '';
    }
    for (final field in otherFields) {
      otherMap[field.key] = values[field.key] ?? '';
    }

    final now = DateTime.now();
    final preset = widget.preset;
    final selectedPrinter = _getSelectedPrinterPreset();
    return PrintParameterPreset(
      id: _workingPresetId,
      name: _nameController.text.trim().isEmpty
          ? '未命名预设'
          : _nameController.text.trim(),
      description: _descController.text.trim().isEmpty
          ? null
          : _descController.text.trim(),
      author: _authorController.text.trim().isEmpty
          ? null
          : _authorController.text.trim(),
      avatarUrl: _avatarPath,
      previewImageUrl: _previewImagePath,
      tags: _selectedTags.toList(),
      material: _material,
      scene: _scene,
      plateType: _plateWasExplicitlySelected ? _selectedPlate.name : null,
      compatiblePrinters: selectedPrinter != null
          ? ['${selectedPrinter.printerModel} $_selectedNozzleDiameter nozzle']
          : (preset?.compatiblePrinters ?? const []),
      createdAt: preset?.createdAt ?? now,
      updatedAt: now,
      inherits: preset?.inherits ?? 'fdm_process_common',
      quality: PrintQualityParams.fromMap(qualityMap),
      strength: PrintStrengthParams.fromMap(strengthMap),
      speed: PrintSpeedParams.fromMap(speedMap),
      support: PrintSupportParams.fromMap(supportMap),
      other: PrintOtherParams.fromMap(otherMap),
      shareId: preset?.shareId,
      likes: preset?.likes ?? 0,
      downloads: preset?.downloads ?? 0,
      uploadedAt: preset?.uploadedAt,
      serverVersion: preset?.serverVersion,
      communityPublicationId: preset?.communityPublicationId,
      communityOwnerId: preset?.communityOwnerId,
      communityRevision: preset?.communityRevision,
      communityVisibility: preset?.communityVisibility,
    );
  }

  /// 从控制器收集耗材丝参数，构造 FilamentPreset。
  FilamentPreset _buildFilamentPreset() {
    final values = <String, String>{};
    for (final field in filamentFields) {
      values[field.key] = _controllers[field.key]?.text.trim() ?? '';
    }

    final tempMap = <String, dynamic>{};
    final flowMap = <String, dynamic>{};
    final fanMap = <String, dynamic>{};
    final retractionMap = <String, dynamic>{};
    final dryingMap = <String, dynamic>{};
    final propertiesMap = <String, dynamic>{};

    // 按 FilamentTempParams 的 key 分组
    for (final key in const FilamentTempParams().toMap().keys) {
      tempMap[key] = values[key] ?? '';
    }
    for (final key in const FilamentFlowParams().toMap().keys) {
      flowMap[key] = values[key] ?? '';
    }
    for (final key in const FilamentFanParams().toMap().keys) {
      fanMap[key] = values[key] ?? '';
    }
    for (final key in const FilamentRetractionParams().toMap().keys) {
      retractionMap[key] = values[key] ?? '';
    }
    for (final key in const FilamentDryingParams().toMap().keys) {
      dryingMap[key] = values[key] ?? '';
    }
    for (final key in const FilamentPropertyParams().toMap().keys) {
      propertiesMap[key] = values[key] ?? '';
    }

    final now = DateTime.now();
    return FilamentPreset(
      id: _selectedFilamentPresetId ?? 'user_${const Uuid().v4()}',
      name: '$_material 耗材配置',
      material: _material,
      createdAt: now,
      updatedAt: now,
      temp: FilamentTempParams.fromMap(tempMap),
      flow: FilamentFlowParams.fromMap(flowMap),
      fan: FilamentFanParams.fromMap(fanMap),
      retraction: FilamentRetractionParams.fromMap(retractionMap),
      drying: FilamentDryingParams.fromMap(dryingMap),
      properties: FilamentPropertyParams.fromMap(propertiesMap),
    );
  }

  /// 从控制器收集打印机参数，构造 PrinterPreset。
  ///
  /// 若未选择打印机预设，返回 null。
  PrinterPreset? _buildMachinePreset() {
    final existing = _getSelectedPrinterPreset();
    if (existing == null) return null;
    final values = <String, String>{};
    for (final field in machineFields) {
      values[field.key] = _controllers[field.key]?.text.trim() ?? '';
    }
    final now = DateTime.now();
    return PrinterPreset(
      id: existing.id,
      name: existing.name,
      printerModel: existing.printerModel,
      nozzleDiameter: _selectedNozzleDiameter,
      printerStructure: existing.printerStructure,
      createdAt: existing.createdAt,
      updatedAt: now,
      nozzle: PrinterNozzleParams.fromMap(values),
      bed: PrinterBedParams.fromMap(values),
      mechanical: PrinterMechanicalParams.fromMap(values),
      features: PrinterFeatureParams.fromMap(values),
    );
  }

  /// 获取当前选择的打印机预设。
  PrinterPreset? _getSelectedPrinterPreset() {
    if (_selectedPrinterId == null) return null;
    final printers = ref.read(printerPresetProvider);
    return printers.where((p) => p.id == _selectedPrinterId).firstOrNull;
  }

  /// 加载系统预设并填充所有控制器。
  Future<void> _loadSystemPreset(
    String presetName, {
    bool confirmOverwrite = true,
  }) async {
    final generation = ++_systemPresetLoadGeneration;
    if (_dirty && confirmOverwrite) {
      final confirmed = await AppDialog.confirm(
        context,
        '覆盖当前修改',
        '加载系统预设会覆盖当前手工修改，是否继续？',
        confirmText: '继续加载',
        destructive: true,
      );
      if (!confirmed) return;
    }
    try {
      final values = await BambuSystemPresetLoader.loadProcessPreset(
        presetName,
        _selectedNozzleDiameter,
      );
      if (!mounted || generation != _systemPresetLoadGeneration) return;
      if (values.isEmpty) {
        if (mounted) showSnack(context, '系统预设加载失败', error: true);
        return;
      }
      setState(() {
        _systemPresetValues = values;
        _selectedSystemPreset = presetName;
        for (final entry in values.entries) {
          _controllers[entry.key]?.text = entry.value;
        }
        _dirty = true;
      });
    } catch (e) {
      if (mounted && generation == _systemPresetLoadGeneration) {
        showSnack(context, '系统预设加载失败: ${friendlyError(e)}', error: true);
      }
    }
  }

  /// 加载打印机预设到控制器。
  ///
  /// B6 修复：加载打印机预设后，自动加载当前喷嘴直径下的第一个系统预设，
  /// 实现 Header 联动（选择打印机 → 自动填充工艺参数）。
  /// 同时从打印机预设填充机器参数控制器。
  ///
  /// 任务扩展：
  /// - 调用 [BambuSystemPresetLoader.loadMachinePreset] 异步加载官方 JSON 打印机预设，
  ///   覆盖机器参数控制器（失败静默忽略）。
  /// - 调用 [BambuSystemPresetLoader.getAvailableProcessPresetsForPrinter] 按打印机过滤工艺预设，
  ///   并自动加载第一个兼容预设。
  /// - 刷新耗材系统预设列表（基于打印机型号）。
  void _loadPrinterPreset(PrinterPreset? preset) {
    if (preset == null) return;
    final generation = ++_presetLoadGeneration;
    ++_systemPresetLoadGeneration;
    setState(() {
      _selectedNozzleDiameter = preset.nozzleDiameter;
      // 喷嘴直径改变后，系统预设列表变化，重置已选预设
      _selectedSystemPreset = null;
      // 从打印机预设填充机器参数控制器
      final machineMap = <String, String>{
        ...preset.nozzle.toMap(),
        ...preset.bed.toMap(),
        ...preset.mechanical.toMap(),
        ...preset.features.toMap(),
      };
      for (final entry in machineMap.entries) {
        _controllers[entry.key]?.text = entry.value;
      }
    });
    // 刷新耗材系统预设列表（基于打印机型号）
    _refreshFilamentSystemPresets(preset.printerModel);
    // 异步加载官方 JSON 打印机预设（覆盖现有值，加载失败静默忽略）
    _loadMachinePresetFromBambu(preset, generation);
    // 异步刷新按打印机过滤的工艺预设列表，并自动加载第一个兼容预设
    _refreshCompatibleProcessPresetsAndAutoLoad(
      preset.name,
      preset.nozzleDiameter,
      generation,
    );
  }

  /// 异步加载官方 JSON 打印机预设，覆盖机器参数控制器。
  ///
  /// 失败时静默忽略，不影响现有逻辑（数据库预设已填充）。
  Future<void> _loadMachinePresetFromBambu(
    PrinterPreset printer,
    int generation,
  ) async {
    try {
      final values = await BambuSystemPresetLoader.loadMachinePreset(
        printer.name,
      );
      if (!mounted || generation != _presetLoadGeneration) return;
      setState(() {
        for (final entry in values.entries) {
          _controllers[entry.key]?.text = entry.value;
        }
      });
    } catch (_) {
      // 静默忽略：加载失败不影响现有逻辑
    }
  }

  /// 异步刷新按打印机过滤的工艺预设列表，并自动加载第一个兼容预设。
  Future<void> _refreshCompatibleProcessPresetsAndAutoLoad(
    String printerName,
    String nozzleDiameter,
    int generation,
  ) async {
    try {
      final presets =
          await BambuSystemPresetLoader.getAvailableProcessPresetsForPrinter(
            printerName,
            nozzleDiameter,
          );
      if (!mounted || generation != _presetLoadGeneration) return;
      setState(() {
        _compatibleProcessPresets = presets;
      });
      if (presets.isNotEmpty) {
        if (generation == _presetLoadGeneration) {
          _loadSystemPreset(presets.first, confirmOverwrite: false);
        }
      }
    } catch (_) {
      // 静默忽略：过滤失败时下拉框回退到按喷嘴直径的未过滤列表
    }
  }

  /// 刷新耗材系统预设列表（基于打印机型号）。
  void _refreshFilamentSystemPresets(String? printerModel) {
    setState(() {
      if (printerModel == null || printerModel.isEmpty) {
        _filamentSystemPresets = const [];
      } else {
        _filamentSystemPresets =
            BambuSystemPresetLoader.getAvailableFilamentPresetsForPrinter(
              printerModel,
            );
      }
      _selectedFilamentSystemPreset = null;
    });
  }

  /// 加载耗材系统预设并填充到耗材参数控制器。
  ///
  /// 从显示名提取材料名（如 'Generic PLA @BBL X1C' → 'PLA'），
  /// 再通过 [BambuSystemPresetLoader.getFilamentMaterialKey] 转为文件名 key（如 'pla'），
  /// 最后调用 [BambuSystemPresetLoader.loadFilamentPreset] 加载参数。
  Future<void> _loadFilamentSystemPreset(String presetDisplayName) async {
    if (_dirty) {
      final confirmed = await AppDialog.confirm(
        context,
        '覆盖当前修改',
        '加载耗材预设会覆盖当前手工修改，是否继续？',
        confirmText: '继续加载',
        destructive: true,
      );
      if (!confirmed) return;
    }
    try {
      // 从显示名提取材料名：'Generic PLA @BBL X1C' → 'PLA'
      final match = RegExp(r'Generic (\w+) @BBL').firstMatch(presetDisplayName);
      if (match == null) return;
      final material = match.group(1)!;
      final materialKey = BambuSystemPresetLoader.getFilamentMaterialKey(
        material,
      );
      final values = await BambuSystemPresetLoader.loadFilamentPreset(
        materialKey,
      );
      if (!mounted) return;
      setState(() {
        _selectedFilamentSystemPreset = presetDisplayName;
        for (final entry in values.entries) {
          _controllers[entry.key]?.text = entry.value;
        }
        _dirty = true;
      });
    } catch (_) {
      // 静默忽略：加载失败不重置已选状态
    }
  }

  /// 导出 Bambu Studio JSON。
  Future<void> _exportBambuJson() async {
    final preset = _buildPreset();
    final content = BambuStudioParamExporter.exportToBambuStudioJson(preset);
    final safeName = preset.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final location = await getSaveLocation(
      suggestedName: '$safeName.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null) return;
    await File(location.path).writeAsString(content);
    if (mounted) showSnack(context, '已导出 Bambu Studio JSON');
  }

  /// 导出 .bbsparam。
  Future<void> _exportBbsparam() async {
    final preset = _buildPreset();
    final content = BambuStudioParamExporter.exportToBbsparam(preset);
    final safeName = preset.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final location = await getSaveLocation(
      suggestedName: '$safeName.bbsparam',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'BBS Param', extensions: ['bbsparam']),
      ],
    );
    if (location == null) return;
    await File(location.path).writeAsString(content);
    if (mounted) showSnack(context, '已导出 .bbsparam 文件');
  }

  /// 写入 Bambu Studio 用户目录。
  /// H-4 修复：同时写入 Process + Filament + Printer 三种预设。
  Future<void> _writeToBambuStudio() async {
    setState(() => _isExporting = true);
    String? writtenProcessPath;
    try {
      var preset = _buildPreset();
      final path = await BambuStudioParamExporter.writeToBambuStudioUserDir(
        preset,
      );
      writtenProcessPath = path;

      // H-4 修复：同时写入耗材丝和打印机预设（非致命，失败不影响 Process 写入）
      final messages = <String>['工艺参数: $path'];
      try {
        final filament = _buildFilamentPreset();
        final fPath =
            await BambuStudioParamExporter.writeFilamentToBambuStudioUserDir(
              filament,
            );
        messages.add('耗材丝: $fPath');
      } catch (e) {
        // 耗材丝写入失败不阻塞，仅记录
      }
      try {
        // 优先使用编辑后的机器预设，否则用已选打印机预设
        final printer = _buildMachinePreset() ?? _getSelectedPrinterPreset();
        if (printer != null) {
          final pPath =
              await BambuStudioParamExporter.writePrinterToBambuStudioUserDir(
                printer,
              );
          messages.add('打印机: $pPath');
        }
      } catch (e) {
        // 打印机写入失败不阻塞，仅记录
      }

      final resultDao = PresetResultDao(ref.read(databaseProvider));
      try {
        final snapshotId = await resultDao.getOrCreateSnapshot(preset);
        await resultDao.recordApplication(
          snapshotId: snapshotId,
          displayName: preset.name,
          localPresetId: preset.id,
          communityPublicationId: preset.communityPublicationId,
          communityRevision: preset.communityRevision,
          slicerProcessSettingsId: path_util.basenameWithoutExtension(path),
        );
      } finally {
        resultDao.dispose();
      }

      if (mounted) {
        showSnack(context, '已写入 Bambu Studio（${messages.length} 项）');
      }
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          writtenProcessPath == null
              ? '写入失败: ${friendlyError(e)}'
              : '参数已写入，但应用记录保存失败: ${friendlyError(e)}',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// 上传当前编辑中的预设到拓竹云端。
  Future<void> _uploadToBambuCloud() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    // 1. 名称不能为空
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showSnack(context, '请先输入预设名称', error: true);
      return;
    }

    // 2. 检查登录状态
    final cloudState = ref.read(bambuCloudProvider);
    final session = cloudState.session;
    if (session == null) {
      await AppDialog.show(
        context: context,
        title: '未登录拓竹云账号',
        content: Text(
          '上传预设到拓竹云端需要先登录拓竹云账号。\n请在"打印机"页面登录拓竹云账号后再试。',
          style: TextStyle(fontSize: 13, height: 1.5, color: textSecondary),
        ),
        actions: [
          AppButton(
            label: '知道了',
            variant: AppButtonVariant.primary,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );
      return;
    }

    // 3. 确认上传
    final preset = _buildPreset();
    final isUpdate = preset.shareId != null && preset.shareId!.isNotEmpty;
    final confirmed = await AppDialog.show<bool>(
      context: context,
      title: isUpdate ? '更新云端预设' : '上传到拓竹云端',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isUpdate
                ? '将更新云端已有的预设「${preset.name}」。'
                : '将上传预设「${preset.name}」到拓竹云端，所有登录同账号的设备在 Bambu Studio 中都能使用。',
            style: TextStyle(fontSize: 13, height: 1.5, color: textSecondary),
          ),
          const SizedBox(height: 8),
          const Text(
            '提示：此功能通过逆向 Bambu Studio 的上传接口实现，拓竹可能随时修改协议或加入签名校验，届时可能失效。',
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: AppColors.textTertiary,
            ),
          ),
        ],
      ),
      actions: [
        AppButton(
          label: '取消',
          variant: AppButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        AppButton(
          label: isUpdate ? '更新' : '上传',
          variant: AppButtonVariant.primary,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (confirmed != true) return;

    // 4. 调用上传 API
    setState(() => _isExporting = true);
    try {
      // 根据当前选择的系统预设解析真实 base_id
      // 没有选择系统预设时由 PresetCloudUploader 用默认值兜底
      String? baseId;
      if (_selectedSystemPreset != null) {
        baseId = await BambuSystemPresetLoader.getProcessPresetSettingId(
          _selectedSystemPreset!,
          _selectedNozzleDiameter,
        );
      }

      final updated = await PresetCloudUploader.upload(
        session: session,
        preset: preset,
        baseId: baseId,
      );
      // 保存 shareId 到本地数据库
      final notifier = ref.read(parameterPresetProvider.notifier);
      // 如果是编辑已有预设，直接 update；否则 add 新预设
      if (widget.preset != null) {
        await notifier.update(updated);
      } else {
        await notifier.add(updated);
      }
      ref.invalidate(cloudParameterPresetsProvider);
      if (mounted) {
        await AppDialog.show(
          context: context,
          title: isUpdate ? '更新成功' : '上传成功',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isUpdate
                    ? '预设「${preset.name}」已更新到拓竹云端。'
                    : '预设「${preset.name}」已上传到拓竹云端。',
                style: TextStyle(fontSize: 13, color: textSecondary),
              ),
              if (!isUpdate && updated.shareId != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(AppColors.radiusSm),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.tag, size: 14, color: AppColors.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '云端 ID: ${updated.shareId}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                '请重启 Bambu Studio，在"工艺参数"预设列表中即可看到并使用此预设。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            AppButton(
              label: '完成',
              variant: AppButtonVariant.secondary,
              onPressed: () => Navigator.of(context).pop(),
            ),
            AppButton(
              label: '打开 Bambu Studio',
              variant: AppButtonVariant.primary,
              onPressed: () {
                Navigator.of(context).pop();
                _launchBambuStudio();
              },
            ),
          ],
        );
      }
    } catch (e) {
      if (mounted) {
        await AppDialog.show(
          context: context,
          title: '上传失败',
          content: Text(
            friendlyError(e),
            style: const TextStyle(fontSize: 13, color: AppColors.danger),
          ),
          actions: [
            AppButton(
              label: '知道了',
              variant: AppButtonVariant.primary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// 启动 Bambu Studio（如已检测到安装路径）。
  Future<void> _launchBambuStudio() async {
    try {
      final status = await ref.read(activeSlicerStatusProvider.future);
      final exe = status?.executablePath;
      if (exe == null || exe.isEmpty) {
        if (mounted) {
          showSnack(context, '未检测到 Bambu Studio 安装路径，请手动启动', error: true);
        }
        return;
      }
      // Windows 用 Process.start 启动；非 Windows 兜底用 explorer
      if (Platform.isWindows) {
        await Process.start(exe, [], mode: ProcessStartMode.detached);
      } else {
        await Process.run('explorer.exe', [exe]);
      }
      if (mounted) showSnack(context, '已启动 Bambu Studio');
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          '启动 Bambu Studio 失败：${friendlyError(e)}',
          error: true,
        );
      }
    }
  }

  /// 删除当前预设在拓竹云端的副本。
  ///
  /// 仅在预设已上传（shareId 非空）时可用。删除成功后清空本地 shareId。
  Future<void> _deleteFromBambuCloud() async {
    final preset = widget.preset ?? _buildPreset();
    final shareId = preset.shareId;
    if (shareId == null || shareId.isEmpty) {
      showSnack(context, '该预设未上传到云端', error: true);
      return;
    }

    final cloudState = ref.read(bambuCloudProvider);
    final session = cloudState.session;
    if (session == null) {
      showSnack(context, '请先登录拓竹云账号', error: true);
      return;
    }

    final confirmed = await AppDialog.show<bool>(
      context: context,
      title: '删除云端预设',
      content: Text(
        '将从拓竹云端删除预设「${preset.name}」。\n'
        '本地预设保留，但 Bambu Studio 中将不再显示此预设。\n'
        '此操作不可撤销。',
        style: const TextStyle(
          fontSize: 13,
          height: 1.5,
          color: AppColors.textSecondary,
        ),
      ),
      actions: [
        AppButton(
          label: '取消',
          variant: AppButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        AppButton(
          label: '删除',
          variant: AppButtonVariant.primary,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (confirmed != true) return;

    setState(() => _isExporting = true);
    try {
      await PresetCloudUploader.delete(session: session, settingId: shareId);
      // 清空本地 shareId
      final cleared = preset.copyWith(
        shareId: null,
        uploadedAt: null,
        updatedAt: DateTime.now(),
      );
      final notifier = ref.read(parameterPresetProvider.notifier);
      await notifier.update(cleared);
      if (mounted) {
        await AppDialog.show(
          context: context,
          title: '删除成功',
          content: Text(
            '预设「${preset.name}」已从拓竹云端删除。\n'
            '请重启 Bambu Studio 以同步预设列表。',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            AppButton(
              label: '完成',
              variant: AppButtonVariant.primary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      }
    } catch (e) {
      if (mounted) {
        await AppDialog.show(
          context: context,
          title: '删除失败',
          content: Text(
            friendlyError(e),
            style: const TextStyle(fontSize: 13, color: AppColors.danger),
          ),
          actions: [
            AppButton(
              label: '知道了',
              variant: AppButtonVariant.primary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// 导出完整配置包（Process + Filament + Printer）。
  Future<void> _exportBundle() async {
    final process = _buildPreset();
    final filament = _buildFilamentPreset();
    // 优先使用编辑后的机器预设，否则用已选打印机预设
    final printer = _buildMachinePreset() ?? _getSelectedPrinterPreset();
    if (printer == null) {
      if (mounted) showSnack(context, '请先选择打印机', error: true);
      return;
    }
    final content = BambuStudioParamExporter.exportToBambuStudioBundle(
      process: process,
      filament: filament,
      printer: printer,
      plate: _selectedPlate,
    );
    final safeName = process.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final location = await getSaveLocation(
      suggestedName: '${safeName}_bundle.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null) return;
    await File(location.path).writeAsString(content);
    if (mounted) showSnack(context, '已导出完整配置包');
  }

  /// 保存为预设（用户自定义）。
  String? _validateParameters() {
    final fields = <FieldDef>[
      ...allProcessFields,
      ...filamentFields,
      ...machineFields,
    ];
    final numericPattern = RegExp(r'^-?(?:\d+\.?\d*|\.\d+)%?$');
    for (final field in fields) {
      if (!field.isNumeric || field.isSwitch || field.options != null) continue;
      final raw = _controllers[field.key]?.text.trim() ?? '';
      if (raw.isEmpty) continue;
      if (!numericPattern.hasMatch(raw)) return '“${field.label}”不是有效数字';
      final value = double.parse(raw.replaceAll('%', ''));
      if (value < field.effectiveMin! || value > field.effectiveMax!) {
        return '“${field.label}”应在 ${field.effectiveMin} 到 ${field.effectiveMax} 之间';
      }
    }
    return null;
  }

  Future<bool> _saveAsPreset() async {
    if (_saving) return false;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showSnack(context, '请输入预设名称', error: true);
      return false;
    }
    final validationError = _validateParameters();
    if (validationError != null) {
      showSnack(context, validationError, error: true);
      return false;
    }
    setState(() => _saving = true);
    try {
      var preset = _buildPreset();
      final notifier = ref.read(parameterPresetProvider.notifier);
      final exists = ref
          .read(parameterPresetProvider)
          .any((p) => p.id == preset.id);
      if (exists) {
        await notifier.update(preset);
      } else {
        await notifier.add(preset);
      }

      var cloudSynced = false;
      String? cloudSyncError;
      if (preset.shareId?.isNotEmpty == true) {
        final session = ref.read(bambuCloudProvider).session;
        if (session != null) {
          try {
            preset = await PresetCloudUploader.upload(
              session: session,
              preset: preset,
            );
            await notifier.update(preset);
            ref.invalidate(cloudParameterPresetsProvider);
            cloudSynced = true;
          } catch (error) {
            cloudSyncError = friendlyError(error);
          }
        } else {
          cloudSyncError = '未登录拓竹云账号';
        }
      }

      _selectedFilamentPresetId ??= 'user_${const Uuid().v4()}';
      final filament = _buildFilamentPreset();
      final filamentNotifier = ref.read(filamentPresetProvider.notifier);
      final filamentExists = ref
          .read(filamentPresetProvider)
          .any((p) => p.id == filament.id);
      if (filamentExists) {
        await filamentNotifier.update(filament);
      } else {
        await filamentNotifier.add(filament);
      }
      if (!mounted) return true;
      setState(() => _dirty = false);
      if (cloudSyncError != null) {
        showSnack(context, '本地已保存，但云端覆盖失败：$cloudSyncError', error: true);
      } else {
        showSnack(
          context,
          cloudSynced ? '已保存并覆盖云端预设「${preset.name}」' : '已保存预设「${preset.name}」',
        );
      }
      return true;
    } catch (e) {
      if (mounted) showSnack(context, '预设保存失败，请检查输入或磁盘空间', error: true);
      debugPrint('[ParameterConfig] 预设保存失败: $e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _publishToCommunity() async {
    final auth = ref.read(appAuthProvider);
    if (auth.endpoint == null) {
      showSnack(context, 'sohun 云暂时不可用，请稍后重试', error: true);
      return;
    }
    if (auth.session == null) {
      showSnack(context, '请先登录工作台账号', error: true);
      return;
    }
    if (_dirty ||
        !ref
            .read(parameterPresetProvider)
            .any((preset) => preset.id == _workingPresetId)) {
      if (!await _saveAsPreset()) return;
    }
    if (!mounted) return;
    var preset =
        ref.read(parameterPresetProvider.notifier).findById(_workingPresetId) ??
        _buildPreset();
    final isUpdate = preset.communityPublicationId?.isNotEmpty == true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isUpdate ? '更新广场参数' : '发布到参数广场'),
        content: Text(
          isUpdate
              ? '用当前参数覆盖已发布的「${preset.name}」。'
              : '公开发布「${preset.name}」，其他用户可以搜索并应用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isUpdate ? '更新' : '发布'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final validSession = await ref
          .read(appAuthProvider.notifier)
          .ensureValidSession();
      final publication = isUpdate
          ? await ref
                .read(communityPresetApiProvider)!
                .updatePublishedPreset(
                  accessToken: validSession.accessToken,
                  publicationId: preset.communityPublicationId!,
                  revision: preset.communityRevision ?? 1,
                  preset: preset,
                  visibility: preset.communityVisibility ?? 'public',
                )
          : await ref
                .read(communityPresetFeedProvider.notifier)
                .publish(preset);
      preset = preset.copyWith(
        communityPublicationId: publication.publicationId,
        communityOwnerId: publication.owner.id,
        communityRevision: publication.revision,
        communityVisibility: publication.visibility,
      );
      await ref.read(parameterPresetProvider.notifier).update(preset);
      await ref
          .read(myCommunityPresetFeedProvider.notifier)
          .refresh(force: true);
      await ref.read(communityPresetFeedProvider.notifier).refresh(force: true);
      if (mounted) {
        showSnack(context, isUpdate ? '广场参数已更新' : '已发布到参数广场');
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, '发布失败：${friendlyError(error)}', error: true);
      }
    }
  }

  /// B5 导入预设（.json 或 .bbsparam）。
  Future<void> _importPreset() async {
    final result = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '预设文件', extensions: ['json', 'bbsparam']),
      ],
    );
    if (result == null) return;
    try {
      final preset = await BambuStudioParamExporter.importFromBbsparamFile(
        File(result.path),
      );
      final qualityMap = preset.quality.toMap();
      final strengthMap = preset.strength.toMap();
      final speedMap = preset.speed.toMap();
      final supportMap = preset.support.toMap();
      final otherMap = preset.other.toMap();
      final allValues = <String, String>{
        ...qualityMap,
        ...strengthMap,
        ...speedMap,
        ...supportMap,
        ...otherMap,
      };
      setState(() {
        for (final entry in allValues.entries) {
          _controllers[entry.key]?.text = entry.value;
        }
        _nameController.text = preset.name;
        _descController.text = preset.description ?? '';
        if (preset.material != null && preset.material!.isNotEmpty) {
          _material = preset.material!;
        }
        if (preset.scene != null && preset.scene!.isNotEmpty) {
          _scene = preset.scene!;
        }
        _dirty = true;
      });
      if (mounted) showSnack(context, '已导入预设「${preset.name}」');
    } catch (e) {
      if (mounted) {
        showSnack(context, '导入失败: ${friendlyError(e)}', error: true);
      }
    }
  }

  /// A4 比较当前编辑值与系统预设。
  Future<void> _showCompareDialog() async {
    final presets = BambuSystemPresetLoader.getAvailableProcessPresets(
      _selectedNozzleDiameter,
    );
    if (presets.isEmpty) {
      showSnack(context, '当前喷嘴直径无可用系统预设', error: true);
      return;
    }
    String? target = presets.first;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        String? selected = target;
        return StatefulBuilder(
          builder: (ctx, setSt) => AlertDialog(
            title: const Text('选择要比较的目标预设'),
            content: AppSelect<String>(
              value: selected,
              label: '目标系统预设',
              items: presets
                  .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  setSt(() => selected = v);
                  target = v;
                }
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  if (target != null) {
                    final currentValues = <String, String>{
                      for (final e in _controllers.entries) e.key: e.value.text,
                    };
                    PresetCompareDialog.showCompareWithCurrent(
                      context,
                      presetName: target!,
                      nozzleDiameter: _selectedNozzleDiameter,
                      currentValues: currentValues,
                    );
                  }
                },
                child: const Text('比较'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// C6 未保存提示：检查 _dirty，若脏则弹确认对话框。
  Future<bool> _confirmExit() async {
    if (!_dirty) return true;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('有未保存的修改'),
        content: const Text('是否保存当前修改？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('不保存'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (action == 'save') {
      return _saveAsPreset();
    }
    if (action == 'discard') return true;
    return false;
  }

  /// 选择作者头像图片。
  Future<void> _pickAvatar() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '图片',
          extensions: ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'],
        ),
      ],
    );
    if (file == null) return;
    try {
      final relPath = await ImageStorage.saveImage(
        sourcePath: file.path,
        subDir: 'presets',
      );
      setState(() {
        _avatarPath = relPath;
        _dirty = true;
      });
    } catch (e) {
      if (mounted) {
        showSnack(context, '图片保存失败: ${friendlyError(e)}', error: true);
      }
    }
  }

  /// 选择预览图图片。
  Future<void> _pickPreviewImage() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '图片',
          extensions: ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'],
        ),
      ],
    );
    if (file == null) return;
    try {
      final relPath = await ImageStorage.saveImage(
        sourcePath: file.path,
        subDir: 'presets',
      );
      setState(() {
        _previewImagePath = relPath;
        _dirty = true;
      });
    } catch (e) {
      if (mounted) {
        showSnack(context, '图片保存失败: ${friendlyError(e)}', error: true);
      }
    }
  }

  /// 构建图片选择器卡片。
  Widget _buildImagePickerCard({
    required String? path,
    required String label,
    required bool circular,
    required VoidCallback onTap,
    required VoidCallback onRemove,
  }) {
    final borderRadius = circular
        ? BorderRadius.circular(999)
        : BorderRadius.circular(AppColors.radiusMd);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppTypography.caption.copyWith(
            fontSize: 11,
            color: AppColors.textTertiary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm - 2),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: SizedBox(
              width: 80,
              height: 80,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 预览区
                  path == null
                      ? _buildEmptyPicker(borderRadius)
                      : _buildImagePreview(path, borderRadius),
                  // 右上角删除按钮
                  if (path != null)
                    Positioned(
                      top: -4,
                      right: -4,
                      child: GlassButtonsTheme.enabledOf(context)
                          ? SizedBox.square(
                              dimension: 20,
                              child: AppGlassButton(
                                tooltip: '移除图片',
                                onPressed: onRemove,
                                variant: AppGlassButtonVariant.danger,
                                compact: true,
                                minimumSize: const Size.square(20),
                                padding: EdgeInsets.zero,
                                borderRadius: BorderRadius.circular(10),
                                child: const Icon(
                                  Icons.close_rounded,
                                  size: 12,
                                ),
                              ),
                            )
                          : GestureDetector(
                              onTap: onRemove,
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: const BoxDecoration(
                                  color: AppColors.danger,
                                  shape: BoxShape.circle,
                                  boxShadow: AppColors.shadow1,
                                ),
                                child: const BambuIcon(
                                  name: 'cross',
                                  size: 12,
                                  color: Colors.white,
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
      ],
    );
  }

  /// 构建空态选择器（虚线边框 + + 图标 + 提示文字）。
  Widget _buildEmptyPicker(BorderRadius borderRadius) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.4),
        borderRadius: borderRadius,
      ),
      child: CustomPaint(
        painter: _DashedBorderPainter(
          color: AppColors.textMuted,
          borderRadius: borderRadius,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            BambuIcon(
              name: 'open',
              size: 22,
              color: Aurora.textSoft,
              applyColorFilter: true,
            ),
            const SizedBox(height: 2),
            const Text(
              '选择图片',
              style: TextStyle(fontSize: 9, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建图片缩略图预览。
  Widget _buildImagePreview(String path, BorderRadius borderRadius) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: FutureBuilder<String>(
        future: _pathFutures.putIfAbsent(
          path,
          () => ImageStorage.getFullPath(path),
        ),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return Image.file(
              File(snapshot.data!),
              fit: BoxFit.cover,
              width: 80,
              height: 80,
              errorBuilder: (_, __, ___) => Container(
                width: 80,
                height: 80,
                color: AppColors.surfaceVariant,
                child: const BambuIcon(
                  name: 'error',
                  size: 22,
                  color: Aurora.danger,
                  applyColorFilter: true,
                ),
              ),
            );
          }
          return const SizedBox(
            width: 80,
            height: 80,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // 分类树定义
  // ===========================================================================

  late final _categoryTree = const <_CategoryNode>[
    _CategoryNode(
      key: 'process',
      label: '工艺',
      isGroup: true,
      children: [
        _CategoryNode(key: 'quality', label: '质量'),
        _CategoryNode(key: 'strength', label: '强度'),
        _CategoryNode(key: 'speed', label: '速度'),
        _CategoryNode(key: 'support', label: '支撑'),
        _CategoryNode(key: 'other', label: '其他'),
      ],
    ),
    _CategoryNode(
      key: 'filament',
      label: '耗材',
      isGroup: true,
      children: [
        _CategoryNode(key: 'filament_temp', label: '温度'),
        _CategoryNode(key: 'filament_flow', label: '流量'),
        _CategoryNode(key: 'filament_fan', label: '风扇'),
        _CategoryNode(key: 'filament_retraction', label: '回抽'),
        _CategoryNode(key: 'filament_drying', label: '烘干'),
        _CategoryNode(key: 'filament_properties', label: '属性'),
        _CategoryNode(key: 'filament_plate', label: '打印板'),
      ],
    ),
    _CategoryNode(
      key: 'machine',
      label: '打印机',
      isGroup: true,
      children: [
        _CategoryNode(key: 'machine_nozzle', label: '喷嘴'),
        _CategoryNode(key: 'machine_mechanical', label: '机械'),
        _CategoryNode(key: 'machine_features', label: '功能'),
        _CategoryNode(key: 'machine_gcode', label: 'G-code'),
      ],
    ),
  ];

  /// 获取分类对应的字段列表。
  List<FieldDef> _fieldsForCategory(String category) {
    switch (category) {
      case 'quality':
        return qualityFields;
      case 'strength':
        return strengthFields;
      case 'speed':
        return speedFields;
      case 'support':
        return supportFields;
      case 'other':
        return otherFields;
      case 'filament_temp':
        return filamentFields
            .where((f) => f.section != null && f.section!.contains('温度'))
            .toList();
      case 'filament_flow':
        return filamentFields.where((f) => f.section == '流量').toList();
      case 'filament_fan':
        return filamentFields
            .where((f) => f.section == '风扇' || f.section == '悬垂速度')
            .toList();
      case 'filament_retraction':
        return filamentFields.where((f) => f.section == '回抽').toList();
      case 'filament_drying':
        return filamentFields.where((f) => f.section == '烘干').toList();
      case 'filament_properties':
        return filamentFields
            .where(
              (f) =>
                  f.section == '耗材属性' ||
                  f.section == '斜拼接缝' ||
                  f.section == '擦料塔' ||
                  f.section == '预冷却',
            )
            .toList();
      case 'machine_nozzle':
        return machineFields
            .where((f) => f.section == '喷嘴参数' || f.section == '打印床尺寸')
            .toList();
      case 'machine_mechanical':
        return machineFields
            .where(
              (f) =>
                  (f.section != null && f.section!.startsWith('机械限制')) ||
                  f.section == '回抽' ||
                  f.section == '挤出机间隙' ||
                  f.section == '加热冷却' ||
                  f.section == '时间参数',
            )
            .toList();
      case 'machine_features':
        return machineFields.where((f) => f.section == '功能开关').toList();
      case 'machine_gcode':
        return machineFields.where((f) => f.section == 'G-code').toList();
      default:
        return const [];
    }
  }

  /// 判断该分类是否为工艺类（应用 level 过滤）。
  bool _isProcessCategory(String category) {
    return const {
      'quality',
      'strength',
      'speed',
      'support',
      'other',
    }.contains(category);
  }

  /// 判断该分类是否为耗材类（顶部显示耗材系统预设下拉框）。
  bool _isFilamentCategory(String category) {
    return const {
      'filament_temp',
      'filament_flow',
      'filament_fan',
      'filament_retraction',
      'filament_drying',
      'filament_properties',
    }.contains(category);
  }

  // ===========================================================================
  // build 方法
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || !await _confirmExit()) return;
        if (!context.mounted) return;
        Navigator.of(context).pop(result);
      },
      child: Scaffold(
        backgroundColor: Aurora.fill,
        body: AuroraBackground(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showInspector = constraints.maxWidth >= 1040;
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    _buildEditorHeader(showInspector: showInspector),
                    const SizedBox(height: 10),
                    _buildContextBar(),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildCategoryTree(),
                          const SizedBox(width: 10),
                          Expanded(child: _buildRightPanel()),
                          if (showInspector) ...[
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 286,
                              child: _buildPresetInspector(),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildBottomBar(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildEditorHeader({required bool showInspector}) {
    return FrostPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      color: Aurora.panelStrong,
      child: Row(
        children: [
          BambuGlyphButton(
            icon: 'back',
            tooltip: '返回参数广场',
            onPressed: () async {
              if (await _confirmExit() && mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          const SizedBox(width: 6),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Aurora.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Aurora.radius),
            ),
            child: Center(
              child: BambuIcon(
                name: 'tab_presets_active',
                size: 19,
                color: Aurora.primary,
                applyColorFilter: true,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.preset == null ? '新建参数预设' : '编辑参数预设',
                style: Aurora.title(context).copyWith(fontSize: 16),
              ),
              Text(
                _dirty ? '有未保存的修改' : '所有更改已保存',
                style: Aurora.label(context).copyWith(
                  fontSize: 11,
                  color: _dirty ? Aurora.warning : Aurora.textSoft,
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Container(width: 1, height: 28, color: Aurora.line),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              _nameController.text.trim().isEmpty
                  ? '未命名预设'
                  : _nameController.text.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Aurora.mono.copyWith(fontSize: 13),
            ),
          ),
          if (!showInspector)
            BambuGlyphButton(
              icon: 'edit',
              tooltip: '编辑预设信息',
              onPressed: _showPresetInfoDialog,
            ),
          BambuGlyphButton(
            icon: 'compare',
            tooltip: '与系统预设比较',
            onPressed: _showCompareDialog,
          ),
          const SizedBox(width: 4),
          AuroraButton(
            label: '保存预设',
            icon: 'save',
            onPressed: _saving ? null : _saveAsPreset,
          ),
        ],
      ),
    );
  }

  Widget _buildContextBar() {
    final printers = ref.watch(printerPresetProvider);
    final selectedPrinter = _selectedPrinterId == null
        ? null
        : printers.where((p) => p.id == _selectedPrinterId).firstOrNull;
    final availablePresets = _compatibleProcessPresets.isEmpty
        ? BambuSystemPresetLoader.getAvailableProcessPresets(
            _selectedNozzleDiameter,
          )
        : _compatibleProcessPresets;
    final effectivePreset = availablePresets.contains(_selectedSystemPreset)
        ? _selectedSystemPreset
        : null;

    return FrostPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: InkWell(
              onTap: () => _selectPrinter(printers),
              borderRadius: BorderRadius.circular(Aurora.radius),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Aurora.fill,
                  borderRadius: BorderRadius.circular(Aurora.radius),
                  border: Border.all(color: Aurora.line),
                ),
                child: Row(
                  children: [
                    BambuIcon(
                      name: 'printer',
                      size: 20,
                      color: Aurora.primary,
                      applyColorFilter: true,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('打印机', style: Aurora.label(context)),
                          Text(
                            selectedPrinter?.name ?? '选择打印机预设',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Aurora.text,
                            ),
                          ),
                        ],
                      ),
                    ),
                    BambuIcon(
                      name: 'drop_down',
                      size: 14,
                      color: Aurora.textSoft,
                      applyColorFilter: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 142,
            child: AppSelect<String>(
              value: _selectedNozzleDiameter,
              label: '喷嘴直径',
              items: nozzleDiameterOptions
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text('$value mm', overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() {
                _selectedNozzleDiameter = value ?? '0.4';
                _selectedSystemPreset = null;
                _compatibleProcessPresets = const [];
                _dirty = true;
              }),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: AppSelect<String>(
              value: effectivePreset,
              label: '工艺系统预设',
              hint: '选择系统预设',
              items: availablePresets
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(value, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) _loadSystemPreset(value);
              },
            ),
          ),
          const SizedBox(width: 6),
          BambuGlyphButton(
            icon: 'compare',
            tooltip: '比较系统预设',
            onPressed: _showCompareDialog,
            background: Aurora.primary.withValues(alpha: 0.08),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 178,
            child: AppSelect<PlateType>(
              value: _selectedPlate,
              label: '打印板',
              items: PlateType.values
                  .map(
                    (plate) => DropdownMenuItem(
                      value: plate,
                      child: Text(plate.label, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() {
                _selectedPlate = value ?? PlateType.coolPlate;
                _plateWasExplicitlySelected = true;
                _dirty = true;
              }),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _editorDecoration(String label) {
    return InputDecoration(
      labelText: label,
      isDense: true,
      filled: true,
      fillColor: Aurora.fill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Aurora.radius),
        borderSide: BorderSide(color: Aurora.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Aurora.radius),
        borderSide: BorderSide(color: Aurora.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Aurora.radius),
        borderSide: BorderSide(color: Aurora.primary, width: 1.4),
      ),
    );
  }

  Future<void> _selectPrinter(List<PrinterPreset> printers) async {
    final selected = await showDialog<PrinterPreset>(
      context: context,
      builder: (_) => _PrinterSelectorDialog(
        printers: printers,
        selectedId: _selectedPrinterId,
      ),
    );
    if (selected == null) return;
    if (!mounted) return;
    if (_dirty) {
      final confirmed = await AppDialog.confirm(
        context,
        '切换打印机',
        '切换打印机会覆盖当前手工修改，是否继续？',
        confirmText: '继续切换',
        destructive: true,
      );
      if (!confirmed) return;
      if (!mounted) return;
    }
    setState(() {
      _selectedPrinterId = selected.id;
      _dirty = true;
    });
    _loadPrinterPreset(selected);
  }

  Widget _buildPresetInspector({VoidCallback? refresh}) {
    return FrostPanel(
      padding: EdgeInsets.zero,
      color: Aurora.panelStrong,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 10, 11),
            child: Row(
              children: [
                BambuIcon(
                  name: 'edit',
                  size: 17,
                  color: Aurora.primary,
                  applyColorFilter: true,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '预设信息',
                    style: Aurora.title(context).copyWith(fontSize: 14),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _dirty
                        ? Aurora.warning.withValues(alpha: 0.1)
                        : Aurora.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(Aurora.radius),
                  ),
                  child: Text(
                    _dirty ? '未保存' : '已保存',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: _dirty ? Aurora.warning : Aurora.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Aurora.line),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: _buildPresetInspectorContent(refresh: refresh),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetInspectorContent({VoidCallback? refresh}) {
    final catalog =
        ref.watch(materialCatalogProvider).valueOrNull ??
        MaterialCatalogService.fallbackMaterials;
    final materialOptions = <String>{...catalog, _material}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final effectiveMaterial = _material;

    void update(VoidCallback change) {
      setState(() {
        change();
        _dirty = true;
      });
      refresh?.call();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _nameController,
          decoration: _editorDecoration('预设名称'),
          onChanged: (_) => update(() {}),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _descController,
          minLines: 2,
          maxLines: 4,
          decoration: _editorDecoration('描述'),
          onChanged: (_) => update(() {}),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _authorController,
          decoration: _editorDecoration('作者'),
          onChanged: (_) => update(() {}),
        ),
        const SizedBox(height: 10),
        MaterialPickerField(
          value: effectiveMaterial,
          label: '材料',
          onTap: () async {
            final result = await showMaterialPicker(
              context: context,
              materials: materialOptions,
              selected: effectiveMaterial,
            );
            if (result?.value != null) {
              update(() => _material = result!.value!);
            }
          },
        ),
        const SizedBox(height: 10),
        AppSelect<String>(
          value: _scene,
          label: '应用场景',
          items: sceneOptions
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text(value, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: (value) => update(() {
            _scene = value ?? _scene;
          }),
        ),
        const SizedBox(height: 14),
        Text('参数标签', style: Aurora.label(context)),
        const SizedBox(height: 7),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: [
            for (final tag in presetTagOptions)
              FilterChip(
                label: Text(tag, style: const TextStyle(fontSize: 10)),
                selected: _selectedTags.contains(tag),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                selectedColor: Aurora.primary.withValues(alpha: 0.13),
                checkmarkColor: Aurora.primary,
                side: BorderSide(
                  color: _selectedTags.contains(tag)
                      ? Aurora.primary
                      : Aurora.line,
                ),
                onSelected: (selected) => update(() {
                  if (selected) {
                    _selectedTags.add(tag);
                  } else {
                    _selectedTags.remove(tag);
                  }
                }),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildImagePickerCard(
              path: _avatarPath,
              label: '作者头像',
              circular: true,
              onTap: () async {
                await _pickAvatar();
                refresh?.call();
              },
              onRemove: () => update(() => _avatarPath = null),
            ),
            const SizedBox(width: 18),
            _buildImagePickerCard(
              path: _previewImagePath,
              label: '预览图',
              circular: false,
              onTap: () async {
                await _pickPreviewImage();
                refresh?.call();
              },
              onRemove: () => update(() => _previewImagePath = null),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showPresetInfoDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => Dialog(
          child: SizedBox(
            width: (MediaQuery.sizeOf(context).width - 48)
                .clamp(320.0, 520.0)
                .toDouble(),
            height: (MediaQuery.sizeOf(context).height - 48)
                .clamp(320.0, 650.0)
                .toDouble(),
            child: Column(
              children: [
                Expanded(
                  child: _buildPresetInspector(refresh: () => refresh(() {})),
                ),
                Divider(height: 1, color: Aurora.line),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      AuroraButton(
                        label: '完成',
                        icon: 'confirm',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 顶部返回栏。
  // ignore: unused_element
  Widget _buildTopBar(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GlassCard(
      level: GlassLevel.l1,
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        0,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      borderRadius: BorderRadius.circular(AppColors.radiusMd),
      child: Row(
        children: [
          IconActionButton(
            icon: Icons.arrow_back_rounded,
            onTap: () async {
              if (await _confirmExit()) {
                if (context.mounted) Navigator.of(context).pop();
              }
            },
            tooltip: '返回',
            size: 36,
            color: isDark
                ? AppColors.textSecondaryDark
                : AppColors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.xs),
          BambuIcon(
            name: 'tab_presets_active',
            size: 18,
            color: AppColors.primary,
            applyColorFilter: true,
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            widget.preset != null ? '编辑参数预设' : '新建参数预设',
            style: AppTypography.title.copyWith(
              fontSize: 14,
              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部预设信息区。
  // ignore: unused_element
  Widget _buildHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textTertiary = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;
    return GlassCard(
      level: GlassLevel.l1,
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      borderRadius: BorderRadius.circular(AppColors.radiusLg),
      child: Theme(
        data: Theme.of(
          context,
        ).copyWith(inputDecorationTheme: appFieldTheme(isDark)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                BambuIcon(
                  name: 'tab_presets_active',
                  size: 18,
                  color: AppColors.primary,
                  applyColorFilter: true,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  widget.preset != null ? '编辑预设' : '新建预设',
                  style: AppTypography.title.copyWith(
                    fontSize: 15,
                    color: textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            // 预设名称
            AppInput(
              controller: _nameController,
              label: '预设名称',
              onChanged: (_) => _markDirty(),
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            // 描述
            AppInput(
              controller: _descController,
              label: '描述（可选）',
              onChanged: (_) => _markDirty(),
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            // 标签（多选 FilterChip）
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '标签（用于参数广场筛选）',
                style: AppTypography.caption.copyWith(color: textTertiary),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final tag in presetTagOptions)
                  FilterChip(
                    label: Text(tag, style: const TextStyle(fontSize: 11)),
                    selected: _selectedTags.contains(tag),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _selectedTags.add(tag);
                      } else {
                        _selectedTags.remove(tag);
                      }
                      _dirty = true;
                    }),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            // 作者名（新建预设时自动填充当前用户名）
            AppInput(
              controller: _authorController,
              label: '作者',
              onChanged: (_) => _markDirty(),
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            // 作者头像 + 预览图（本地图片选择器）
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildImagePickerCard(
                  path: _avatarPath,
                  label: '作者头像',
                  circular: true,
                  onTap: _pickAvatar,
                  onRemove: () => setState(() {
                    _avatarPath = null;
                    _dirty = true;
                  }),
                ),
                const SizedBox(width: AppSpacing.lg),
                _buildImagePickerCard(
                  path: _previewImagePath,
                  label: '预览图',
                  circular: false,
                  onTap: _pickPreviewImage,
                  onRemove: () => setState(() {
                    _previewImagePath = null;
                    _dirty = true;
                  }),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            // 材料 + 场景（B7：材料选项从耗材库读取）
            Builder(
              builder: (context) {
                final catalog =
                    ref.watch(materialCatalogProvider).valueOrNull ??
                    MaterialCatalogService.fallbackMaterials;
                final materialOptions = <String>{...catalog, _material}.toList()
                  ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                final effectiveMaterial = _material;
                return Row(
                  children: [
                    Expanded(
                      child: MaterialPickerField(
                        value: effectiveMaterial,
                        label: '材料',
                        onTap: () async {
                          final result = await showMaterialPicker(
                            context: context,
                            materials: materialOptions,
                            selected: effectiveMaterial,
                          );
                          if (result?.value == null || !mounted) return;
                          setState(() {
                            _material = result!.value!;
                            _dirty = true;
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: AppSelect<String>(
                        value: _scene,
                        label: '场景',
                        items: sceneOptions
                            .map(
                              (s) => DropdownMenuItem(
                                value: s,
                                child: Text(
                                  s,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() {
                          _scene = v ?? _scene;
                          _dirty = true;
                        }),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            // 打印机选择卡片（带图片，点击弹出选择器）
            Consumer(
              builder: (context, ref, _) {
                final printers = ref.watch(printerPresetProvider);
                final selectedPrinter = _selectedPrinterId == null
                    ? null
                    : printers
                          .where((p) => p.id == _selectedPrinterId)
                          .firstOrNull;
                return _PrinterSelectorCard(
                  printer: selectedPrinter,
                  onTap: () async {
                    final selected = await showDialog<PrinterPreset>(
                      context: context,
                      builder: (_) => _PrinterSelectorDialog(
                        printers: printers,
                        selectedId: _selectedPrinterId,
                      ),
                    );
                    if (selected == null) return;
                    if (!context.mounted) return;
                    if (_dirty) {
                      final confirmed = await AppDialog.confirm(
                        context,
                        '切换打印机',
                        '切换打印机会覆盖当前手工修改，是否继续？',
                        confirmText: '继续切换',
                        destructive: true,
                      );
                      if (!confirmed || !context.mounted) return;
                    }
                    setState(() {
                      _selectedPrinterId = selected.id;
                      _dirty = true;
                    });
                    _loadPrinterPreset(selected);
                  },
                );
              },
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            // 喷嘴直径
            AppSelect<String>(
              value: _selectedNozzleDiameter,
              label: '喷嘴直径',
              items: nozzleDiameterOptions
                  .map(
                    (n) => DropdownMenuItem(
                      value: n,
                      child: Text(n, style: const TextStyle(fontSize: 13)),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() {
                _selectedNozzleDiameter = v ?? '0.4';
                // 喷嘴直径改变后，系统预设列表变化，重置已选预设
                _selectedSystemPreset = null;
                // 清空按打印机过滤的工艺预设列表，回退到按喷嘴直径的未过滤列表
                _compatibleProcessPresets = const [];
              }),
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            // 系统预设 + 比较按钮 + 打印板选择
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: AppSelect<String>(
                    value: _selectedSystemPreset,
                    label: '系统预设',
                    hint: '选择系统预设',
                    items:
                        (_compatibleProcessPresets.isEmpty
                                ? BambuSystemPresetLoader.getAvailableProcessPresets(
                                    _selectedNozzleDiameter,
                                  )
                                : _compatibleProcessPresets)
                            .map(
                              (p) => DropdownMenuItem(
                                value: p,
                                child: Text(
                                  p,
                                  style: const TextStyle(fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                    onChanged: (v) {
                      if (v != null) _loadSystemPreset(v);
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                // A4 预设比较按钮
                IconActionButton(
                  icon: Icons.compare_arrows,
                  onTap: _showCompareDialog,
                  tooltip: '与系统预设比较',
                  size: 36,
                  color: AppColors.primary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  flex: 2,
                  child: AppSelect<PlateType>(
                    value: _selectedPlate,
                    label: '打印板',
                    items: PlateType.values
                        .map(
                          (p) => DropdownMenuItem(
                            value: p,
                            child: Row(
                              children: [
                                // 缩略图（拓竹官方 bed_*.png）
                                Image.asset(
                                  p.imageAsset,
                                  width: 20,
                                  height: 20,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => const Icon(
                                    Icons.grid_on_rounded,
                                    size: 16,
                                    color: AppColors.textTertiary,
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Text(
                                  p.label,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() {
                      _selectedPlate = v ?? PlateType.coolPlate;
                      _plateWasExplicitlySelected = true;
                      _dirty = true;
                    }),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 左侧分类树
  // ===========================================================================

  /// 构建左侧分类树。
  Widget _buildCategoryTree() {
    return SizedBox(
      width: 190,
      child: FrostPanel(
        padding: const EdgeInsets.symmetric(vertical: 10),
        color: Aurora.panelStrong,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            for (final group in _categoryTree) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 12, 6),
                child: Row(
                  children: [
                    BambuIcon(
                      name: _categoryIcon(group.key),
                      size: 15,
                      color: Aurora.textSoft,
                      applyColorFilter: true,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      group.label,
                      style: Aurora.label(
                        context,
                      ).copyWith(fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              for (final node in group.children) _buildEditorCategoryItem(node),
              if (group != _categoryTree.last)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  child: Divider(height: 1, color: Aurora.line),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEditorCategoryItem(_CategoryNode node) {
    final selected = _selectedCategory == node.key && !_searchMode;
    final fields = _fieldsForCategory(node.key);
    final count = _isProcessCategory(node.key)
        ? fields
              .where((field) => field.level.index <= _currentLevel.index)
              .length
        : fields.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? Aurora.primary.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(Aurora.radius),
        child: InkWell(
          onTap: () => setState(() {
            _selectedCategory = node.key;
            _searchMode = false;
            _searchQuery = '';
          }),
          borderRadius: BorderRadius.circular(Aurora.radius),
          child: SizedBox(
            height: 36,
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 20,
                  decoration: BoxDecoration(
                    color: selected ? Aurora.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 9),
                AnimatedContainer(
                  duration: AppMotion.duration(
                    context,
                    const Duration(milliseconds: 160),
                  ),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: selected
                        ? Aurora.primary.withValues(alpha: 0.1)
                        : Aurora.fill,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: selected
                          ? Aurora.primary.withValues(alpha: 0.24)
                          : Aurora.line,
                    ),
                  ),
                  child: Center(
                    child: BambuIcon(
                      name: _categoryIcon(node.key),
                      size: 14,
                      color: selected ? Aurora.primary : Aurora.textSoft,
                      applyColorFilter: true,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    node.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? Aurora.primary : Aurora.text,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: Aurora.mono.copyWith(
                    fontSize: 10,
                    color: selected ? Aurora.primary : Aurora.muted,
                  ),
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _categoryIcon(String key) => switch (key) {
    'process' => 'tab_presets_active',
    'quality' => 'tab_calibration_active',
    'strength' => 'param_strength',
    'speed' => 'monitor_speed',
    'support' => 'param_support',
    'other' => 'more',
    'filament' => 'tab_filament_active',
    'filament_temp' => 'monitor_nozzle_temp',
    'filament_flow' => 'param_flow',
    'filament_fan' => 'monitor_fan',
    'filament_retraction' => 'param_retraction',
    'filament_drying' => 'ams_drying',
    'filament_properties' => 'info',
    'filament_plate' => 'param_plate',
    'machine' => 'printer',
    'machine_nozzle' => 'param_nozzle',
    'machine_mechanical' => 'param_mechanical',
    'machine_features' => 'cog',
    'machine_gcode' => 'open',
    _ => 'settings',
  };

  /// 构建分组标题（工艺 / 耗材 / 打印机）。
  // ignore: unused_element
  Widget _buildGroupHeader(_CategoryNode group) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          BambuIcon(
            name: 'drop_down',
            size: 16,
            color: textSecondary,
            applyColorFilter: true,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            group.label,
            style: AppTypography.label.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: textSecondary,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建叶子节点（质量、强度、温度等）。
  // ignore: unused_element
  Widget _buildCategoryLeaf(_CategoryNode node) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = _selectedCategory == node.key && !_searchMode;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() {
          _selectedCategory = node.key;
          // 切换分类时退出搜索模式
          _searchMode = false;
          _searchQuery = '';
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primaryContainer.withValues(alpha: 0.6)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            border: Border(
              left: BorderSide(
                color: selected ? AppColors.primary : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  node.label,
                  style: AppTypography.body.copyWith(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? AppColors.primary : textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // 右侧参数列表
  // ===========================================================================

  /// 构建右侧面板（搜索栏 + 模式切换 + 参数列表）。
  Widget _buildRightPanel() {
    return Column(
      children: [
        _buildSearchAndModeBar(),
        const SizedBox(height: 8),
        Expanded(
          child: _searchMode
              ? _buildSearchResults()
              : (_selectedCategory == 'filament_plate'
                    ? _buildPlateTab()
                    : _buildCategoryFieldList()),
        ),
      ],
    );
  }

  /// 构建当前选中分类的字段列表。
  Widget _buildCategoryFieldList() {
    final fields = _fieldsForCategory(_selectedCategory);
    final isProcess = _isProcessCategory(_selectedCategory);
    final isFilament = _isFilamentCategory(_selectedCategory);
    // 温度分类高亮当前选中打印板的温度字段
    Set<String>? highlightKeys;
    if (_selectedCategory == 'filament_temp') {
      highlightKeys = _selectedPlate.tempFieldKeys.toSet();
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        // 耗材分类顶部：耗材系统预设下拉框（section 标题之前）
        if (isFilament) ...[
          _buildFilamentPresetBar(),
          const SizedBox(height: 10),
        ],
        ..._buildSectionCards(
          fields,
          highlightKeys,
          false,
          applyLevelFilter: isProcess,
        ),
      ],
    );
  }

  /// 构建耗材系统预设选择栏（显示在耗材分类顶部，section 标题之前）。
  ///
  /// 数据源基于当前选中打印机的型号，调用
  /// [BambuSystemPresetLoader.getAvailableFilamentPresetsForPrinter]。
  /// 选择后调用 [_loadFilamentSystemPreset] 加载参数并填充到耗材参数控制器。
  Widget _buildFilamentPresetBar() {
    final effectiveValue =
        _filamentSystemPresets.contains(_selectedFilamentSystemPreset)
        ? _selectedFilamentSystemPreset
        : null;
    return FrostPanel(
      padding: const EdgeInsets.all(12),
      color: Aurora.primary.withValues(alpha: 0.045),
      child: Row(
        children: [
          BambuIcon(
            name: 'filament',
            size: 18,
            color: Aurora.primary,
            applyColorFilter: true,
          ),
          const SizedBox(width: 9),
          Text('耗材系统预设', style: Aurora.title(context).copyWith(fontSize: 13)),
          const SizedBox(width: 12),
          Expanded(
            child: AppSelect<String>(
              value: effectiveValue,
              label: '系统耗材',
              hint: _filamentSystemPresets.isEmpty
                  ? '当前打印机暂无可用耗材预设'
                  : '选择耗材系统预设',
              items: _filamentSystemPresets
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(value, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) _loadFilamentSystemPreset(value);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// A3/A2/B1 搜索框 + 模式切换 + 折叠/展开按钮。
  Widget _buildSearchAndModeBar() {
    final currentNode = _categoryTree
        .expand((group) => group.children)
        .where((node) => node.key == _selectedCategory)
        .firstOrNull;
    final visibleCount = _searchMode
        ? null
        : (_isProcessCategory(_selectedCategory)
              ? _fieldsForCategory(_selectedCategory)
                    .where((field) => field.level.index <= _currentLevel.index)
                    .length
              : _fieldsForCategory(_selectedCategory).length);
    return FrostPanel(
      padding: const EdgeInsets.fromLTRB(14, 11, 10, 10),
      color: Aurora.panelStrong,
      child: Column(
        children: [
          Row(
            children: [
              BambuIcon(
                name: _searchMode ? 'search' : _categoryIcon(_selectedCategory),
                size: 18,
                color: Aurora.primary,
                applyColorFilter: true,
              ),
              const SizedBox(width: 8),
              Text(
                _searchMode ? '搜索结果' : (currentNode?.label ?? '参数'),
                style: Aurora.title(context).copyWith(fontSize: 14),
              ),
              if (visibleCount != null) ...[
                const SizedBox(width: 7),
                Text(
                  '$visibleCount 项',
                  style: Aurora.mono.copyWith(
                    fontSize: 10,
                    color: Aurora.muted,
                  ),
                ),
              ],
              const Spacer(),
              BambuGlyphButton(
                icon: 'collapse_btn',
                tooltip: '全部折叠',
                size: 30,
                onPressed: () => setState(() {
                  _collapsedSections = _allSectionTitles().toSet();
                }),
              ),
              BambuGlyphButton(
                icon: 'expand_btn',
                tooltip: '全部展开',
                size: 30,
                onPressed: () => setState(_collapsedSections.clear),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _searchController,
                    onChanged: (value) => setState(() {
                      _searchQuery = value;
                      _searchMode = value.trim().isNotEmpty;
                    }),
                    decoration: InputDecoration(
                      hintText: '搜索参数名称、拓竹参数键或说明',
                      isDense: true,
                      filled: true,
                      fillColor: Aurora.fill,
                      prefixIcon: Padding(
                        padding: const EdgeInsets.all(10),
                        child: BambuIcon(
                          name: 'search',
                          size: 16,
                          color: Aurora.textSoft,
                          applyColorFilter: true,
                        ),
                      ),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : BambuGlyphButton(
                              icon: 'cross',
                              tooltip: '清空搜索',
                              size: 28,
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _searchQuery = '';
                                  _searchMode = false;
                                });
                              },
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Aurora.radius),
                        borderSide: BorderSide(color: Aurora.line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Aurora.radius),
                        borderSide: BorderSide(color: Aurora.line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Aurora.radius),
                        borderSide: BorderSide(
                          color: Aurora.primary,
                          width: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 224,
                child: AppSegmented<ParamLevel>(
                  value: _currentLevel,
                  onChanged: (value) => setState(() => _currentLevel = value),
                  segments: const [
                    AppSegment(label: '普通', value: ParamLevel.basic),
                    AppSegment(label: '高级', value: ParamLevel.advanced),
                    AppSegment(label: '开发者', value: ParamLevel.developer),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 收集所有 section 标题（用于"全部折叠"）。
  Set<String> _allSectionTitles() {
    final set = <String>{};
    for (final f in [
      ...allProcessFields,
      ...filamentFields,
      ...machineFields,
    ]) {
      if (f.section != null) set.add(f.section!);
    }
    return set;
  }

  /// A3 搜索结果列表。
  ///
  /// 遍历所有字段（工艺 + 耗材 + 打印机），过滤出 label 或 key 包含搜索词的字段。
  Widget _buildSearchResults() {
    final q = _searchQuery.toLowerCase();
    final allFields = <FieldDef>[
      ...allProcessFields,
      ...filamentFields,
      ...machineFields,
    ];
    final sectionByField = <String, String?>{};
    String? currentSection;
    for (final f in allFields) {
      if (f.section != null) currentSection = f.section;
      sectionByField[f.key] = currentSection;
    }
    // level 过滤：工艺字段应用 level 过滤，耗材/打印机不过滤
    final visibleFields = allFields.where((f) {
      // 判断是否为工艺字段
      final isProcess = allProcessFields.any((p) => p.key == f.key);
      if (isProcess && f.level.index > _currentLevel.index) return false;
      return true;
    }).toList();
    final matched = visibleFields.where((f) {
      return f.label.toLowerCase().contains(q) ||
          f.key.toLowerCase().contains(q) ||
          (f.tooltip?.toLowerCase().contains(q) ?? false);
    }).toList();
    if (matched.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, size: 40, color: AppColors.textMuted),
            const SizedBox(height: 8),
            Text(
              '未找到匹配 "$_searchQuery" 的参数',
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: matched.length,
      separatorBuilder: (_, __) => const Divider(
        height: 1,
        thickness: 0.5,
        color: AppColors.divider,
        indent: 12,
        endIndent: 12,
      ),
      itemBuilder: (_, i) {
        final f = matched[i];
        final section = sectionByField[f.key] ?? '';
        final controller = _controllers[f.key];
        if (controller == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              '${f.label}（控制器未初始化）',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textTertiary,
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 分组标签 + key（小字）
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 4),
                child: Text(
                  '$section · ${f.key}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
              // 内联可编辑字段
              _ParamField(
                field: f,
                controller: controller,
                systemPresetValues: _systemPresetValues,
                onDirty: _markDirty,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 构建 section 卡片列表（共享逻辑）。
  ///
  /// 跳过作为子参数的字段，按 section 分组后构建卡片列表。
  /// [applyLevelFilter] 为 false 时跳过等级过滤（用于耗材/打印机分类）。
  List<Widget> _buildSectionCards(
    List<FieldDef> fields,
    Set<String>? highlightKeys,
    bool compact, {
    bool applyLevelFilter = true,
  }) {
    // 0. level 过滤：只保留 level <= _currentLevel 的字段
    final levelFiltered = applyLevelFilter
        ? fields.where((f) => f.level.index <= _currentLevel.index).toList()
        : fields;

    // 1. 收集所有开关的 childKeys（用于跳过子参数的独立渲染）
    final childKeySet = <String>{};
    for (final f in levelFiltered) {
      if (f.isSwitch && f.childKeys != null) {
        childKeySet.addAll(f.childKeys!);
      }
    }

    // 2. 建立子参数 key → FieldDef 的映射
    final fieldByKey = <String, FieldDef>{};
    for (final f in levelFiltered) {
      fieldByKey[f.key] = f;
    }

    // 3. 按 section 分组（跳过子参数）
    final sectionTitles = <String?>[];
    final sectionFieldLists = <List<FieldDef>>[];
    String? currentSection;
    for (final field in levelFiltered) {
      if (childKeySet.contains(field.key)) continue;
      if (field.section != null && field.section != currentSection) {
        currentSection = field.section;
        sectionTitles.add(currentSection);
        sectionFieldLists.add(<FieldDef>[]);
      } else if (sectionFieldLists.isEmpty) {
        sectionTitles.add(null);
        sectionFieldLists.add(<FieldDef>[]);
      }
      sectionFieldLists.last.add(field);
    }

    // 4. 构建卡片
    final cards = <Widget>[];
    for (int gi = 0; gi < sectionTitles.length; gi++) {
      final sectionFields = sectionFieldLists[gi];
      if (sectionFields.isEmpty) continue;
      cards.add(
        _buildSectionCard(
          sectionTitles[gi],
          sectionFields,
          highlightKeys,
          fieldByKey,
          compact,
        ),
      );
      if (gi < sectionTitles.length - 1) {
        cards.add(const SizedBox(height: 10));
      }
    }
    return cards;
  }

  /// 构建分组卡片（一个 section 对应一张卡片）。
  Widget _buildSectionCard(
    String? title,
    List<FieldDef> fields,
    Set<String>? highlightKeys,
    Map<String, FieldDef> fieldByKey,
    bool compact,
  ) {
    final collapsed = title != null && _collapsedSections.contains(title);
    return FrostPanel(
      padding: EdgeInsets.zero,
      color: Aurora.panelStrong,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) _buildSectionHeader(title, collapsed),
          // 卡片内字段列表（用细分隔线隔开）
          if (!collapsed)
            ..._buildCardFields(fields, highlightKeys, fieldByKey, compact),
        ],
      ),
    );
  }

  /// 构建卡片内的字段行列表（带分隔线）。
  List<Widget> _buildCardFields(
    List<FieldDef> fields,
    Set<String>? highlightKeys,
    Map<String, FieldDef> fieldByKey,
    bool compact,
  ) {
    void markDirty() {
      if (!_dirty) setState(() => _dirty = true);
    }

    final result = <Widget>[];
    for (int i = 0; i < fields.length; i++) {
      final field = fields[i];
      final isHighlighted = highlightKeys?.contains(field.key) ?? false;

      // 获取子参数（如果是开关且有 childKeys）
      List<FieldDef>? childFields;
      if (field.isSwitch &&
          field.childKeys != null &&
          field.childKeys!.isNotEmpty) {
        childFields = field.childKeys!
            .map((k) => fieldByKey[k])
            .whereType<FieldDef>()
            .toList();
      }

      result.add(
        _ParamField(
          field: field,
          controller: _controllers[field.key]!,
          highlight: isHighlighted,
          childFields: childFields,
          childControllers: childFields != null
              ? Map.fromEntries(
                  childFields
                      .where((f) => _controllers.containsKey(f.key))
                      .map((f) => MapEntry(f.key, _controllers[f.key]!)),
                )
              : null,
          systemPresetValues: _systemPresetValues,
          compact: compact,
          onDirty: markDirty,
        ),
      );

      // 字段间加细分隔线（最后一个不加）
      if (i < fields.length - 1) {
        result.add(
          const Divider(
            height: 1,
            thickness: 0.5,
            color: AppColors.divider,
            indent: 12,
            endIndent: 12,
          ),
        );
      }
    }
    return result;
  }

  /// 构建卡片分组标题（左侧极光绿色竖条 + 标题文字）。
  Widget _buildSectionHeader(String title, bool collapsed) {
    return InkWell(
      onTap: () => setState(() {
        if (collapsed) {
          _collapsedSections.remove(title);
        } else {
          _collapsedSections.add(title);
        }
      }),
      borderRadius: BorderRadius.circular(Aurora.radius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Aurora.line)),
        ),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 16,
              decoration: BoxDecoration(
                color: Aurora.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Aurora.text,
                ),
              ),
            ),
            BambuIcon(
              name: collapsed ? 'expand_btn' : 'collapse_btn',
              size: 16,
              color: Aurora.textSoft,
              applyColorFilter: true,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建打印板配置面板（耗材 → 打印板子项）。
  Widget _buildPlateTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        // 打印板选择卡片（带实物图片，对标拓竹切片软件打印板选择 UI）
        FrostPanel(
          padding: const EdgeInsets.all(16),
          color: Aurora.panelStrong,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '打印板选择',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              // 带图片的打印板卡片网格（对标拓竹切片软件）
              LayoutBuilder(
                builder: (context, constraints) {
                  // 响应式列数：每张卡片约 110px 宽
                  final crossAxisCount = (constraints.maxWidth / 110)
                      .floor()
                      .clamp(2, 5);
                  return GridView.count(
                    crossAxisCount: crossAxisCount,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.85, // 卡片宽高比
                    children: PlateType.values.map((p) {
                      final selected = p == _selectedPlate;
                      return _PlateSelectorCard(
                        plate: p,
                        selected: selected,
                        onTap: () => setState(() {
                          _selectedPlate = p;
                          _plateWasExplicitlySelected = true;
                          _dirty = true;
                        }),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 当前打印板的温度配置
        FrostPanel(
          padding: const EdgeInsets.all(16),
          color: Aurora.panelStrong,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_selectedPlate.label} 温度配置',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              _ParamField(
                field: FieldDef(label: '常规层温度', key: _selectedPlate.tempKey),
                controller: _controllers[_selectedPlate.tempKey]!,
                systemPresetValues: _systemPresetValues,
                onDirty: () {
                  if (!_dirty) setState(() => _dirty = true);
                },
              ),
              const SizedBox(height: 8),
              _ParamField(
                field: FieldDef(
                  label: '首层温度',
                  key: _selectedPlate.initialLayerTempKey,
                ),
                controller: _controllers[_selectedPlate.initialLayerTempKey]!,
                systemPresetValues: _systemPresetValues,
                onDirty: () {
                  if (!_dirty) setState(() => _dirty = true);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 所有打印板温度对比
        FrostPanel(
          padding: const EdgeInsets.all(16),
          color: Aurora.panelStrong,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '所有打印板温度对比',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              for (final p in PlateType.values) ...[
                _PlateTempRow(
                  plate: p,
                  tempController: _controllers[p.tempKey],
                  initialTempController: _controllers[p.initialLayerTempKey],
                  isSelected: p == _selectedPlate,
                  onChanged: () {
                    if (!_dirty) setState(() => _dirty = true);
                  },
                ),
                if (p != PlateType.values.last) const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 底部操作栏。
  Widget _buildBottomBar() {
    final savedPreset = ref
        .watch(parameterPresetProvider)
        .where((preset) => preset.id == _workingPresetId)
        .firstOrNull;
    return FrostPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      color: Aurora.panelStrong,
      child: Row(
        children: [
          AuroraButton(
            label: '导入预设',
            icon: 'open',
            filled: false,
            onPressed: _importPreset,
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: '导出',
            itemBuilder: (_) => [
              _editorMenuItem('json', '导出 JSON', 'tree_export'),
              _editorMenuItem('bbsparam', '导出 .bbsparam', 'save'),
              _editorMenuItem('bundle', '导出完整配置包', 'tree_copy'),
            ],
            onSelected: _handleEditorMenuAction,
            child: _editorMenuButton(
              label: _isExporting ? '正在导出' : '导出',
              icon: 'tree_export',
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: '拓竹云端',
            itemBuilder: (_) => [
              _editorMenuItem('upload_cloud', '上传到拓竹云端', 'bar_publish'),
              _editorMenuItem(
                'delete_cloud',
                '删除云端预设',
                'tree_delete',
                danger: true,
              ),
            ],
            onSelected: _handleEditorMenuAction,
            child: _editorMenuButton(label: '云端', icon: 'bar_publish'),
          ),
          const SizedBox(width: 8),
          AuroraButton(
            label: savedPreset?.communityPublicationId?.isNotEmpty == true
                ? '更新广场'
                : '发布到广场',
            icon: 'tab_presets_active',
            filled: false,
            onPressed: _publishToCommunity,
          ),
          const Spacer(),
          Text(
            '${_material.replaceFirst('Generic ', '通用 ')} · ${_selectedPlate.label}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Aurora.label(context),
          ),
          const SizedBox(width: 12),
          AuroraButton(
            label: '写入拓竹切片',
            icon: 'open_in_browser',
            filled: false,
            onPressed: _writeToBambuStudio,
          ),
          const SizedBox(width: 8),
          AuroraButton(label: '保存为预设', icon: 'save', onPressed: _saveAsPreset),
        ],
      ),
    );
  }

  PopupMenuItem<String> _editorMenuItem(
    String value,
    String label,
    String icon, {
    bool danger = false,
  }) {
    final color = danger ? Aurora.danger : Aurora.textSoft;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          BambuIcon(name: icon, size: 16, color: color, applyColorFilter: true),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }

  Widget _editorMenuButton({required String label, required String icon}) {
    final glass = GlassButtonsTheme.enabledOf(context);
    final foreground = glass
        ? GlassButtonPalette.resolve(
            Theme.of(context),
            variant: AppGlassButtonVariant.secondary,
            tint: Aurora.primary,
          ).foreground
        : Aurora.primary;
    final content = Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: glass ? null : Aurora.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Aurora.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BambuIcon(
            name: icon,
            size: 16,
            color: foreground,
            applyColorFilter: true,
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
          const SizedBox(width: 4),
          BambuIcon(
            name: 'drop_down',
            size: 12,
            color: foreground,
            applyColorFilter: true,
          ),
        ],
      ),
    );
    return glass
        ? GlassButtonMaterial(
            variant: AppGlassButtonVariant.secondary,
            tint: Aurora.primary,
            child: content,
          )
        : content;
  }

  void _handleEditorMenuAction(String value) {
    switch (value) {
      case 'json':
        _exportBambuJson();
      case 'bbsparam':
        _exportBbsparam();
      case 'bundle':
        _exportBundle();
      case 'upload_cloud':
        _uploadToBambuCloud();
      case 'delete_cloud':
        _deleteFromBambuCloud();
    }
  }
}

/// 统一参数输入控件。
///
/// 根据 [field] 的 options 和 isSwitch 属性构建不同输入控件：
/// - isSwitch=true: 复选框（0/1），勾选后展开子参数
/// - options 非空: 下拉选择 + 恢复原值按钮
/// - 其他: 文本输入框 + 恢复原值按钮
///
/// 修改过的参数（值 != 系统预设原值）标签变蓝色高亮。
class _ParamField extends StatefulWidget {
  final FieldDef field;
  final TextEditingController controller;

  /// 子参数字段列表（仅当 field 是开关且有子参数时使用）。
  final List<FieldDef>? childFields;

  /// 子参数控制器（key → controller）。
  final Map<String, TextEditingController>? childControllers;

  /// 系统预设值（用于恢复原值按钮 + 修改高亮）。
  final Map<String, String>? systemPresetValues;

  /// 是否高亮显示（如选中打印板时高亮对应温度字段）。
  final bool highlight;

  /// 紧凑模式（5 列布局时使用，标签更窄）。
  final bool compact;

  /// C6 修改时的回调（用于标记未保存）。
  final VoidCallback? onDirty;

  const _ParamField({
    required this.field,
    required this.controller,
    this.childFields,
    this.childControllers,
    this.systemPresetValues,
    this.highlight = false,
    this.compact = false,
    this.onDirty,
  });

  @override
  State<_ParamField> createState() => _ParamFieldState();
}

class _ParamFieldState extends State<_ParamField> {
  /// 获取有效单位（使用字段定义的 unit）。
  String? get _effectiveUnit {
    if (widget.field.isSwitch || widget.field.options != null) return null;
    return widget.field.unit;
  }

  /// 高亮时的背景色。
  Color get _highlightBg => Aurora.primary.withValues(alpha: 0.06);

  /// 标签宽度（紧凑模式更窄）。
  double get _labelWidth => widget.compact ? 120 : 168;

  /// 检查当前输入值是否超出 min/max 范围。
  bool _isOutOfRange() {
    final text = widget.controller.text.trim();
    if (text.isEmpty) return false;
    // 去除 % 后缀后解析数值
    final value = double.tryParse(text.replaceAll('%', ''));
    if (value == null) return false;
    if (value < widget.field.effectiveMin!) return true;
    if (value > widget.field.effectiveMax!) return true;
    return false;
  }

  /// 判断当前值是否与系统预设值不同（用于标签蓝色高亮）。
  bool _isModified() {
    final presetValue = widget.systemPresetValues?[widget.field.key];
    if (presetValue == null) return false;
    return !_valuesEqual(presetValue, widget.controller.text.trim());
  }

  /// 构建标签（如果有 tooltip 则包裹 Tooltip）。
  /// 修改过的参数标签用蓝色（AppColors.primary），未修改用 textPrimary。
  Widget _buildLabel() {
    final modified = _isModified();
    final labelWidget = Text(
      widget.field.label,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: modified ? Aurora.primary : Aurora.text,
      ),
    );
    if (widget.field.tooltip == null || widget.field.tooltip!.isEmpty) {
      return labelWidget;
    }
    return Tooltip(
      message: widget.field.tooltip!,
      waitDuration: const Duration(milliseconds: 500),
      child: labelWidget,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.field.isSwitch) {
      return _buildCheckbox();
    }
    if (widget.field.options != null) {
      return _buildDropdown();
    }
    return _buildTextField();
  }

  /// 开关控件。
  /// 如果有子参数，勾选后展开显示（缩进）。
  Widget _buildCheckbox() {
    final isOn = widget.controller.text == '1';
    final hasChildren =
        widget.childFields != null && widget.childFields!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          color: widget.highlight ? _highlightBg : Colors.transparent,
          child: Row(
            children: [
              Expanded(child: _buildLabel()),
              const SizedBox(width: 12),
              Switch(
                value: isOn,
                onChanged: (val) {
                  setState(() {
                    widget.controller.text = val ? '1' : '0';
                  });
                  widget.onDirty?.call();
                },
                activeTrackColor: Aurora.primary,
                inactiveTrackColor: Aurora.line,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ),
        // 展开子参数（勾选时显示）
        if (hasChildren && isOn) ...[
          for (final childField in widget.childFields!)
            _buildChildField(childField),
        ],
      ],
    );
  }

  /// 渲染子参数（缩进显示，递归调用 _ParamField）。
  Widget _buildChildField(FieldDef childField) {
    final controller = widget.childControllers?[childField.key];
    if (controller == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 20),
      child: _ParamField(
        field: childField,
        controller: controller,
        systemPresetValues: widget.systemPresetValues,
        compact: widget.compact,
        onDirty: widget.onDirty,
      ),
    );
  }

  /// 下拉选择控件 — 横向布局：标签在左，下拉框在右 + 恢复原值按钮。
  Widget _buildDropdown() {
    String? value = widget.controller.text;
    if (value.isEmpty || !widget.field.options!.contains(value)) {
      value = widget.field.options!.first;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: widget.highlight ? _highlightBg : Colors.transparent,
      child: Row(
        children: [
          SizedBox(width: _labelWidth, child: _buildLabel()),
          const SizedBox(width: 8),
          Expanded(
            child: AppSelect<String>(
              key: ValueKey('${widget.field.key}:$value'),
              value: value,
              items: widget.field.options!
                  .map(
                    (o) => DropdownMenuItem(
                      value: o,
                      child: Text(
                        optionDisplayName(o),
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    widget.controller.text = v;
                  });
                  widget.onDirty?.call();
                }
              },
            ),
          ),
          const SizedBox(width: 4),
          _buildRestoreButton(),
        ],
      ),
    );
  }

  /// 文本输入控件 — 横向布局：标签在左，输入框在右（带单位后缀）+ 恢复原值按钮。
  Widget _buildTextField() {
    final unit = _effectiveUnit;
    final isNonNumeric = !widget.field.isNumeric;
    final isCode =
        widget.field.section == 'G-code' ||
        widget.field.key.toLowerCase().contains('gcode');
    final outOfRange = _isOutOfRange();
    final borderSide = outOfRange
        ? const BorderSide(color: Aurora.danger, width: 1.5)
        : BorderSide(color: Aurora.line);
    final input = TextField(
      controller: widget.controller,
      keyboardType: isCode
          ? TextInputType.multiline
          : (isNonNumeric
                ? TextInputType.text
                : const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  )),
      minLines: isCode ? 3 : 1,
      maxLines: isCode ? 8 : 1,
      inputFormatters: isNonNumeric
          ? null
          : [
              TextInputFormatter.withFunction((oldValue, newValue) {
                if (RegExp(r'^-?\d*(?:\.\d*)?%?$').hasMatch(newValue.text)) {
                  return newValue;
                }
                return oldValue;
              }),
            ],
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: Aurora.fill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        suffixText: unit,
        suffixStyle: TextStyle(fontSize: 11, color: Aurora.textSoft),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Aurora.radius),
          borderSide: borderSide,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Aurora.radius),
          borderSide: borderSide,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Aurora.radius),
          borderSide: outOfRange
              ? const BorderSide(color: Aurora.danger, width: 1.5)
              : BorderSide(color: Aurora.primary, width: 1.4),
        ),
      ),
      style: Aurora.mono.copyWith(fontSize: 12, fontWeight: FontWeight.w500),
      onChanged: (_) {
        setState(() {});
        widget.onDirty?.call();
      },
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: widget.highlight ? _highlightBg : Colors.transparent,
      child: isCode
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: _buildLabel()),
                    _buildRestoreButton(),
                  ],
                ),
                const SizedBox(height: 7),
                input,
              ],
            )
          : Row(
              children: [
                SizedBox(width: _labelWidth, child: _buildLabel()),
                const SizedBox(width: 8),
                Expanded(child: input),
                const SizedBox(width: 4),
                _buildRestoreButton(),
              ],
            ),
    );
  }

  /// 恢复原值按钮。
  Widget _buildRestoreButton() {
    final presetValue = widget.systemPresetValues?[widget.field.key];
    final currentValue = widget.controller.text.trim();

    // 无系统预设值时禁用，tooltip 提示用户先选择系统预设
    if (presetValue == null) {
      return const SizedBox.shrink();
    }

    // 数值归一化比较：去除 % 后 double.tryParse，避免格式差异误判
    final isDefault = _valuesEqual(presetValue, currentValue);
    final tooltipMsg = isDefault ? '与系统预设一致' : '恢复为 $presetValue（系统预设值）';
    return BambuGlyphButton(
      icon: 'topbar_undo',
      tooltip: tooltipMsg,
      size: 28,
      color: Aurora.primary,
      onPressed: isDefault
          ? null
          : () {
              setState(() => widget.controller.text = presetValue);
              widget.onDirty?.call();
            },
    );
  }

  /// 比较两个参数值是否等价。
  static bool _valuesEqual(String a, String b) {
    final aNum = double.tryParse(a.replaceAll('%', ''));
    final bNum = double.tryParse(b.replaceAll('%', ''));
    if (aNum != null && bNum != null) {
      return (aNum - bNum).abs() < 0.0001;
    }
    return a == b;
  }
}

/// 打印板温度对比行（用于打印板配置面板显示所有打印板的温度对比）。
class _PlateTempRow extends StatelessWidget {
  final PlateType plate;

  /// 常规层温度控制器（可空，打印板未配置时为 null）
  final TextEditingController? tempController;

  /// 首层温度控制器
  final TextEditingController? initialTempController;
  final bool isSelected;

  /// 编辑回调（用于标记未保存）
  final VoidCallback? onChanged;

  const _PlateTempRow({
    required this.plate,
    required this.tempController,
    required this.initialTempController,
    required this.isSelected,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isSelected
            ? AppColors.primaryContainer.withValues(alpha: 0.5)
            : AppColors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border: Border.all(
          color: isSelected
              ? AppColors.primary
              : AppColors.border.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          // 打印板名称
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primary : AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppColors.radiusSm),
            ),
            child: Text(
              plate.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: isSelected ? Colors.white : AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // C7 常规层温度（可编辑）
          Expanded(
            child: _TempTextField(
              controller: tempController,
              label: '常规层',
              onChanged: onChanged,
            ),
          ),
          const SizedBox(width: 8),
          // C7 首层温度（可编辑）
          Expanded(
            child: _TempTextField(
              controller: initialTempController,
              label: '首层',
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

/// C7 温度输入框（带标签和 °C 后缀）。
class _TempTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String label;
  final VoidCallback? onChanged;

  const _TempTextField({
    required this.controller,
    required this.label,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          '$label: ',
          style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
            ],
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              suffixText: '°C',
              suffixStyle: const TextStyle(
                fontSize: 11,
                color: AppColors.textTertiary,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppColors.radiusSm),
                borderSide: BorderSide(
                  color: AppColors.border.withValues(alpha: 0.3),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppColors.radiusSm),
                borderSide: BorderSide(
                  color: AppColors.border.withValues(alpha: 0.3),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppColors.radiusSm),
                borderSide: BorderSide(color: AppColors.primary, width: 1.5),
              ),
            ),
            style: const TextStyle(fontSize: 12),
            onChanged: (_) => onChanged?.call(),
          ),
        ),
      ],
    );
  }
}

/// 虚线边框绘制器（用于图片选择器空态）。
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final BorderRadius borderRadius;

  const _DashedBorderPainter({required this.color, required this.borderRadius});

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 1.2;
    const dashSize = 4.0;
    const gapSize = 3.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path()..addRRect(borderRadius.toRRect(Offset.zero & size));
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final end = (distance + dashSize).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dashSize + gapSize;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      color != oldDelegate.color || borderRadius != oldDelegate.borderRadius;
}

// ===========================================================================
// 打印板选择卡片（带实物图片，对标拓竹切片软件打印板选择 UI）
// ===========================================================================

/// 打印板选择卡片：显示打印板实物图 + 中英文名 + 选中态高亮。
///
/// 对标 BambuStudio 打印板选择 UI，使用拓竹官方 `bed_*.png` 图片资源。
/// 选中时卡片有 aurora green 边框 + 浅绿背景；未选中时为浅灰边框。
class _PlateSelectorCard extends StatelessWidget {
  final PlateType plate;
  final bool selected;
  final VoidCallback onTap;

  const _PlateSelectorCard({
    required this.plate,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    final borderColor = selected
        ? AppColors.primary
        : AppColors.divider.withValues(alpha: 0.5);
    final bgColor = selected
        ? AppColors.primary.withValues(alpha: 0.08)
        : (isDark ? Colors.white.withValues(alpha: 0.03) : Colors.transparent);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: AppMotion.duration(
            context,
            const Duration(milliseconds: 150),
          ),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: selected ? 2 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 打印板实物图（拓竹官方 bed_*.png）
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.grey.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: Image.asset(
                    plate.imageAsset,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (context, error, stack) => const Icon(
                      Icons.grid_on_rounded,
                      size: 32,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // 中文名
              Text(
                plate.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? AppColors.primary : textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              // 英文名
              Text(
                plate.englishName,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 9,
                  color: textSecondary,
                  height: 1.1,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// 打印机选择器（带图片，对标拓竹切片软件打印机库页面）
// ===========================================================================

/// 将 [printerModel]（如 "Bambu Lab X1 Carbon"）解析为本地图片资源路径。
///
/// 映射来源：assets/images/printers/ 目录下的拓竹机型图片，统一英文命名
/// `bambu_<型号小写>.<扩展名>`。其中 P1P/H2D/H2S/H2C/H2D Pro 为 .webp 格式，
/// 其余为 .png 格式。H2D Pro 无独立图片，复用 H2D 的图片。
String? _resolvePrinterImageAsset(String? printerModel) {
  if (printerModel == null || printerModel.isEmpty) return null;
  const modelMap = <String, String>{
    'Bambu Lab X1 Carbon': 'assets/images/printers/bambu_x1c.png',
    'Bambu Lab X1': 'assets/images/printers/bambu_x1.png',
    'Bambu Lab X1E': 'assets/images/printers/bambu_x1e.png',
    'Bambu Lab X2D': 'assets/images/printers/bambu_x2d.png',
    'Bambu Lab P1P': 'assets/images/printers/bambu_p1p.webp',
    'Bambu Lab P1S': 'assets/images/printers/bambu_p1s.png',
    'Bambu Lab P2S': 'assets/images/printers/bambu_p2s.png',
    'Bambu Lab A1': 'assets/images/printers/bambu_a1.png',
    'Bambu Lab A1 mini': 'assets/images/printers/bambu_a1_mini.png',
    'Bambu Lab A2L': 'assets/images/printers/bambu_a2l.png',
    'Bambu Lab H2D': 'assets/images/printers/bambu_h2d.webp',
    'Bambu Lab H2D Pro': 'assets/images/printers/bambu_h2d_pro.webp',
    'Bambu Lab H2S': 'assets/images/printers/bambu_h2s.webp',
    'Bambu Lab H2C': 'assets/images/printers/bambu_h2c.webp',
  };
  return modelMap[printerModel];
}

/// 从 [printerModel]（如 "Bambu Lab X1 Carbon"）提取简短显示名（"X1 Carbon"）。
String _shortPrinterName(String printerModel) {
  const prefix = 'Bambu Lab ';
  if (printerModel.startsWith(prefix)) {
    return printerModel.substring(prefix.length);
  }
  return printerModel;
}

/// 打印机选择卡片：横向布局，显示当前选中打印机的图片、名称、喷嘴与结构信息。
///
/// 未选中时显示提示文案与图标。点击触发 [onTap] 回调，
/// 通常弹出 [_PrinterSelectorDialog] 供用户选择。
class _PrinterSelectorCard extends StatelessWidget {
  final PrinterPreset? printer;
  final VoidCallback onTap;

  const _PrinterSelectorCard({required this.printer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    final borderColor = printer != null
        ? AppColors.primary.withValues(alpha: 0.6)
        : (isDark ? AppColors.outlineDark : AppColors.outline);
    final bgColor = printer != null
        ? AppColors.primaryContainer.withValues(alpha: 0.25)
        : (isDark ? AppColors.surfaceDark : AppColors.surface);

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor, width: 1.2),
          ),
          child: Row(
            children: [
              if (printer != null) ...[
                PrinterImage(
                  assetPath: _resolvePrinterImageAsset(printer!.printerModel),
                  brand: '拓竹',
                  size: 56,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        printer!.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '喷嘴 ${printer!.nozzleDiameter}mm · '
                        '${printer!.printerStructure == 'corexy' ? 'CoreXY' : 'i3'}',
                        style: TextStyle(fontSize: 11, color: textSecondary),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_right,
                  color: textSecondary,
                  size: 20,
                ),
              ] else ...[
                Icon(Icons.print_rounded, color: textSecondary, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '点击选择打印机',
                    style: TextStyle(fontSize: 13, color: textSecondary),
                  ),
                ),
                Icon(Icons.add, color: textSecondary, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 打印机选择对话框：使用 GridView 展示所有打印机带图片卡片。
///
/// 对标拓竹切片软件「打印机库」页面：响应式网格、图片为主、
/// 选中态高亮（边框 + 右上角对勾）。点击卡片即选中并关闭对话框。
class _PrinterSelectorDialog extends StatelessWidget {
  final List<PrinterPreset> printers;
  final String? selectedId;

  const _PrinterSelectorDialog({
    required this.printers,
    required this.selectedId,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;

    return Dialog(
      backgroundColor: isDark ? AppColors.surfaceDark : AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: double.maxFinite,
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题栏
            Row(
              children: [
                Icon(Icons.print_rounded, size: 20, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  '选择打印机',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 打印机网格
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 160,
                  childAspectRatio: 0.82,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                ),
                itemCount: printers.length,
                itemBuilder: (context, i) => _PrinterGridTile(
                  printer: printers[i],
                  selected: printers[i].id == selectedId,
                  onTap: () => Navigator.of(context).pop(printers[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 打印机网格卡片：图片为主 + 型号名 + 喷嘴直径，选中态高亮。
class _PrinterGridTile extends StatelessWidget {
  final PrinterPreset printer;
  final bool selected;
  final VoidCallback onTap;

  const _PrinterGridTile({
    required this.printer,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = selected
        ? AppColors.primaryContainer
        : (isDark ? AppColors.surfaceDark : AppColors.surface);
    final borderColor = selected
        ? AppColors.primary
        : (isDark ? AppColors.outlineDark : AppColors.outline);
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return Material(
      color: bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor, width: selected ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 打印机图片（占主要空间）
                  Expanded(
                    child: Center(
                      child: PrinterImage(
                        assetPath: _resolvePrinterImageAsset(
                          printer.printerModel,
                        ),
                        brand: '拓竹',
                        size: 80,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 型号简短名（如 "X1 Carbon"）
                  Text(
                    _shortPrinterName(printer.printerModel),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 2),
                  // 喷嘴直径
                  Text(
                    '${printer.nozzleDiameter}mm 喷嘴',
                    style: TextStyle(fontSize: 10, color: textSecondary),
                  ),
                ],
              ),
            ),
            // 选中标记：右上角对勾
            if (selected)
              Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.primary,
                  size: 18,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
