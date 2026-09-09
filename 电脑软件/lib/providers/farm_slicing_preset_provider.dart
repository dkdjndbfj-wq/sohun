import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/services/printer_model_normalizer.dart';

class FarmSlicingPresetException implements Exception {
  const FarmSlicingPresetException(this.message);
  final String message;

  @override
  String toString() => message;
}

class FarmSlicingPresetCandidate {
  const FarmSlicingPresetCandidate({
    required this.machineSourcePath,
    required this.processSourcePath,
    required this.filamentSourcePaths,
    required this.displayModel,
    required this.modelKey,
    required this.nozzleDiameter,
    required this.machineConfigName,
    required this.processConfigName,
    required this.filamentConfigNames,
  });

  final String machineSourcePath;
  final String processSourcePath;
  final List<String> filamentSourcePaths;
  final String displayModel;
  final String modelKey;
  final double nozzleDiameter;
  final String machineConfigName;
  final String processConfigName;
  final List<String> filamentConfigNames;
}

class FarmSlicingPreset {
  const FarmSlicingPreset({
    required this.id,
    required this.name,
    required this.modelKey,
    required this.displayModel,
    required this.nozzleDiameter,
    required this.machineSettingsPath,
    required this.processSettingsPath,
    required this.filamentSettingsPaths,
    required this.machineConfigName,
    required this.processConfigName,
    required this.filamentConfigNames,
    required this.fingerprint,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String modelKey;
  final String displayModel;
  final double nozzleDiameter;
  final String machineSettingsPath;
  final String processSettingsPath;
  final List<String> filamentSettingsPaths;
  final String machineConfigName;
  final String processConfigName;
  final List<String> filamentConfigNames;
  final String fingerprint;
  final DateTime createdAt;

  List<String> get settingsPaths => [
        machineSettingsPath,
        processSettingsPath,
      ];

  bool compatibleWith(String model, double nozzle) =>
      modelKey == normalizeFarmSlicingModelKey(model) &&
      (nozzleDiameter - nozzle).abs() < .001;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'modelKey': modelKey,
        'displayModel': displayModel,
        'nozzleDiameter': nozzleDiameter,
        'machineSettingsPath': machineSettingsPath,
        'processSettingsPath': processSettingsPath,
        'filamentSettingsPaths': filamentSettingsPaths,
        'machineConfigName': machineConfigName,
        'processConfigName': processConfigName,
        'filamentConfigNames': filamentConfigNames,
        'fingerprint': fingerprint,
        'createdAt': createdAt.toIso8601String(),
      };

  factory FarmSlicingPreset.fromJson(Map<String, dynamic> json) {
    return FarmSlicingPreset(
      id: json['id'] as String,
      name: json['name'] as String,
      modelKey: json['modelKey'] as String,
      displayModel: json['displayModel'] as String,
      nozzleDiameter: (json['nozzleDiameter'] as num).toDouble(),
      machineSettingsPath: json['machineSettingsPath'] as String,
      processSettingsPath: json['processSettingsPath'] as String,
      filamentSettingsPaths: (json['filamentSettingsPaths'] as List)
          .whereType<String>()
          .toList(growable: false),
      machineConfigName: json['machineConfigName'] as String? ?? '机器参数',
      processConfigName: json['processConfigName'] as String? ?? '工艺参数',
      filamentConfigNames: (json['filamentConfigNames'] as List?)
              ?.whereType<String>()
              .toList(growable: false) ??
          const [],
      fingerprint: json['fingerprint'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

String normalizeFarmSlicingModelKey(String model) =>
    PrinterModelNormalizer.normalize(model).toLowerCase();

final farmSlicingPresetsProvider =
    StateNotifierProvider<FarmSlicingPresetsNotifier, List<FarmSlicingPreset>>(
  (ref) => FarmSlicingPresetsNotifier(),
);

class FarmSlicingPresetsNotifier
    extends StateNotifier<List<FarmSlicingPreset>> {
  FarmSlicingPresetsNotifier({
    Future<Directory> Function()? supportDirectory,
  })  : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        super(const []) {
    ready = _load();
  }

  static const _prefsKey = 'farm_slicing_presets_v1';
  static const _maxConfigBytes = 8 * 1024 * 1024;
  static const _uuid = Uuid();
  final Future<Directory> Function() _supportDirectory;
  late final Future<void> ready;

  List<FarmSlicingPreset> compatiblePresets(String model, double nozzle) {
    final result = state
        .where((item) => item.compatibleWith(model, nozzle))
        .toList(growable: false)
      ..sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  Future<void> validateManagedPreset(
    FarmSlicingPreset preset, {
    required String model,
    required double nozzleDiameter,
  }) async {
    if (!preset.compatibleWith(model, nozzleDiameter)) {
      throw FarmSlicingPresetException(
        '“${preset.name}”属于 ${preset.displayModel} '
        '${preset.nozzleDiameter.toStringAsFixed(1)} mm，不能用于 '
        '${PrinterModelNormalizer.normalize(model)} '
        '${nozzleDiameter.toStringAsFixed(1)} mm',
      );
    }
    final paths = [
      ...preset.settingsPaths,
      ...preset.filamentSettingsPaths,
    ];
    for (final path in paths) {
      if (!await File(path).exists()) {
        throw FarmSlicingPresetException(
          '“${preset.name}”的托管配置文件缺失，请删除后重新导入',
        );
      }
    }
    final currentFingerprint = await _fingerprint(paths);
    if (preset.fingerprint.isEmpty ||
        currentFingerprint != preset.fingerprint) {
      throw FarmSlicingPresetException(
        '“${preset.name}”的托管配置已被修改或损坏，请删除后重新导入',
      );
    }
    final inspected = await inspectImportFiles(paths);
    if (inspected.modelKey != preset.modelKey ||
        (inspected.nozzleDiameter - preset.nozzleDiameter).abs() >= .001 ||
        inspected.machineConfigName != preset.machineConfigName ||
        inspected.processConfigName != preset.processConfigName ||
        !_sameStrings(
          inspected.filamentConfigNames,
          preset.filamentConfigNames,
        )) {
      throw FarmSlicingPresetException(
        '“${preset.name}”的托管配置与导入记录不一致，请删除后重新导入',
      );
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    try {
      final decoded = jsonDecode(raw) as List;
      state = decoded
          .whereType<Map>()
          .map(
            (item) => FarmSlicingPreset.fromJson(
              Map<String, dynamic>.from(item),
            ),
          )
          .toList(growable: false);
    } catch (_) {
      // A damaged preference record must not make the farm workspace fail to
      // open. The next successful import rewrites the complete list.
    }
  }

  Future<FarmSlicingPresetCandidate> inspectImportFiles(
    Iterable<String> sourcePaths,
  ) async {
    final paths = sourcePaths
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (paths.length < 2) {
      throw const FarmSlicingPresetException(
        '至少需要选择完整的机器参数 JSON 和工艺参数 JSON',
      );
    }
    if (paths.length > 18) {
      throw const FarmSlicingPresetException('一次最多导入 16 个耗材参数');
    }

    String? machinePath;
    String? processPath;
    final filamentPaths = <String>[];
    Map<String, dynamic>? machine;
    Map<String, dynamic>? process;
    final filaments = <Map<String, dynamic>>[];

    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) {
        throw FarmSlicingPresetException('配置文件不存在：$path');
      }
      if (await file.length() > _maxConfigBytes) {
        throw FarmSlicingPresetException('配置文件超过 8 MB：$path');
      }
      final Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) throw const FormatException();
        json = Map<String, dynamic>.from(decoded);
      } catch (_) {
        throw FarmSlicingPresetException('不是有效的 Bambu Studio JSON：$path');
      }

      final type = (json['type'] as String?)?.trim().toLowerCase();
      final isMachine = type == 'machine' ||
          (json.containsKey('machine_start_gcode') &&
              json.containsKey('nozzle_diameter'));
      final isProcess = type == 'process';
      final isFilament = type == 'filament';
      if ([isMachine, isProcess, isFilament].where((item) => item).length !=
          1) {
        throw FarmSlicingPresetException('无法识别官方配置类型：$path');
      }
      if (isMachine) {
        if (machine != null) {
          throw const FarmSlicingPresetException('一个方案只能包含 1 个机器参数');
        }
        machine = json;
        machinePath = path;
      } else if (isProcess) {
        if (process != null) {
          throw const FarmSlicingPresetException('一个方案只能包含 1 个工艺参数');
        }
        process = json;
        processPath = path;
      } else {
        filaments.add(json);
        filamentPaths.add(path);
      }
    }

    if (machine == null || machinePath == null) {
      throw const FarmSlicingPresetException('没有找到完整的机器参数 JSON');
    }
    if (process == null || processPath == null) {
      throw const FarmSlicingPresetException('没有找到完整的工艺参数 JSON');
    }
    _requireKeys(
      machine,
      const [
        'name',
        'nozzle_diameter',
        'printable_area',
        'machine_start_gcode',
        'machine_end_gcode',
      ],
      '机器参数不是 Bambu Studio CLI 要求的完整配置',
    );
    _requireKeys(
      process,
      const ['type', 'name', 'layer_height', 'compatible_printers'],
      '工艺参数不是 Bambu Studio CLI 要求的完整配置',
    );
    for (final filament in filaments) {
      _requireKeys(
        filament,
        const [
          'type',
          'name',
          'filament_type',
          'filament_diameter',
          'compatible_printers',
        ],
        '耗材参数不是 Bambu Studio CLI 要求的完整配置',
      );
    }

    final machineName = _text(machine['name']);
    final rawModel = _text(machine['printer_model']);
    final displayModel = rawModel.isNotEmpty
        ? PrinterModelNormalizer.normalize(rawModel)
        : PrinterModelNormalizer.normalize(machineName);
    if (!PrinterModelNormalizer.isKnownBambuModel(displayModel)) {
      throw FarmSlicingPresetException('机器参数中的打印机型号无法识别：$machineName');
    }
    final nozzleValues = _numbers(machine['nozzle_diameter']).toSet();
    if (nozzleValues.length != 1 || nozzleValues.single <= 0) {
      throw const FarmSlicingPresetException('机器参数必须包含一个明确的喷嘴直径');
    }
    final nozzle = nozzleValues.single;
    _validateCompatiblePrinters(
      process,
      displayModel,
      nozzle,
      label: '工艺参数',
    );
    for (final filament in filaments) {
      _validateCompatiblePrinters(
        filament,
        displayModel,
        nozzle,
        label: '耗材参数 ${_text(filament['name'])}',
      );
    }

    return FarmSlicingPresetCandidate(
      machineSourcePath: machinePath,
      processSourcePath: processPath,
      filamentSourcePaths: filamentPaths,
      displayModel: displayModel,
      modelKey: normalizeFarmSlicingModelKey(displayModel),
      nozzleDiameter: nozzle,
      machineConfigName: machineName,
      processConfigName: _text(process['name']),
      filamentConfigNames: [
        for (final filament in filaments) _text(filament['name']),
      ],
    );
  }

  Future<FarmSlicingPreset> importCandidate({
    required FarmSlicingPresetCandidate candidate,
    required String name,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty || normalizedName.length > 40) {
      throw const FarmSlicingPresetException('方案名称必须是 1-40 个字符');
    }
    final duplicate = state.any(
      (item) =>
          item.modelKey == candidate.modelKey &&
          (item.nozzleDiameter - candidate.nozzleDiameter).abs() < .001 &&
          item.name.toLowerCase() == normalizedName.toLowerCase(),
    );
    if (duplicate) {
      throw FarmSlicingPresetException(
        '${candidate.displayModel} ${candidate.nozzleDiameter.toStringAsFixed(1)} mm 已有“$normalizedName”方案',
      );
    }

    final id = _uuid.v4();
    final support = await _supportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}farm_slicing_presets'
      '${Platform.pathSeparator}$id',
    );
    try {
      await directory.create(recursive: true);
      final machineTarget =
          '${directory.path}${Platform.pathSeparator}machine.json';
      final processTarget =
          '${directory.path}${Platform.pathSeparator}process.json';
      final filamentTargets = <String>[];
      await File(candidate.machineSourcePath).copy(machineTarget);
      await File(candidate.processSourcePath).copy(processTarget);
      for (var index = 0;
          index < candidate.filamentSourcePaths.length;
          index++) {
        final target = '${directory.path}${Platform.pathSeparator}'
            'filament_${index + 1}.json';
        await File(candidate.filamentSourcePaths[index]).copy(target);
        filamentTargets.add(target);
      }
      final fingerprint = await _fingerprint([
        machineTarget,
        processTarget,
        ...filamentTargets,
      ]);
      final preset = FarmSlicingPreset(
        id: id,
        name: normalizedName,
        modelKey: candidate.modelKey,
        displayModel: candidate.displayModel,
        nozzleDiameter: candidate.nozzleDiameter,
        machineSettingsPath: machineTarget,
        processSettingsPath: processTarget,
        filamentSettingsPaths: filamentTargets,
        machineConfigName: candidate.machineConfigName,
        processConfigName: candidate.processConfigName,
        filamentConfigNames: candidate.filamentConfigNames,
        fingerprint: fingerprint,
        createdAt: DateTime.now(),
      );
      final previous = state;
      state = [...state, preset];
      try {
        await _persist();
      } catch (_) {
        state = previous;
        rethrow;
      }
      return preset;
    } catch (_) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<void> remove(String id) async {
    final preset = state.where((item) => item.id == id).firstOrNull;
    if (preset == null) return;
    state = state.where((item) => item.id != id).toList(growable: false);
    await _persist();
    final directory = File(preset.machineSettingsPath).parent;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode([for (final item in state) item.toJson()]),
    );
  }

  static void _requireKeys(
    Map<String, dynamic> json,
    List<String> keys,
    String message,
  ) {
    final missing = keys.where((key) => !json.containsKey(key)).toList();
    if (missing.isNotEmpty) {
      throw FarmSlicingPresetException('$message，缺少：${missing.join('、')}');
    }
  }

  static void _validateCompatiblePrinters(
    Map<String, dynamic> json,
    String model,
    double nozzle, {
    required String label,
  }) {
    final compatible = (json['compatible_printers'] as List?)
            ?.whereType<String>()
            .toList(growable: false) ??
        const [];
    final matched = compatible.any((item) {
      if (!PrinterModelNormalizer.sameModel(item, model)) return false;
      final itemNozzle = _nozzleFromName(item);
      return itemNozzle == null || (itemNozzle - nozzle).abs() < .001;
    });
    if (!matched) {
      throw FarmSlicingPresetException(
        '$label不兼容 $model ${nozzle.toStringAsFixed(1)} mm',
      );
    }
  }

  static double? _nozzleFromName(String value) {
    final match = RegExp(
      r'([0-9]+(?:\.[0-9]+)?)\s*(?:mm\s*)?nozzle',
      caseSensitive: false,
    ).firstMatch(value);
    return double.tryParse(match?.group(1) ?? '');
  }

  static String _text(Object? value) => value is String ? value.trim() : '';

  static List<double> _numbers(Object? value) {
    final values = value is List ? value : [value];
    return values
        .map((item) => double.tryParse('$item'))
        .whereType<double>()
        .toList(growable: false);
  }

  static bool _sameStrings(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  static Future<String> _fingerprint(List<String> paths) async {
    final fileDigests = <int>[];
    for (final path in paths) {
      fileDigests.addAll(sha256.convert(await File(path).readAsBytes()).bytes);
    }
    return sha256.convert(fileDigests).toString();
  }
}
