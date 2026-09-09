import 'dart:convert';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

/// 拓竹官方系统预设加载器。
///
/// 从 assets/bambu_presets/ 加载 Bambu Studio 官方 JSON 预设文件，
/// 解析继承链（common → individual），返回完整的扁平参数 Map。
///
/// 继承链结构：
///   fdm_process_common（基础参数）
///     → fdm_process_single_0.XX（中间层，设置 layer_height）
///       → 0.XXmm XXX @BBL X1C（具体预设，覆盖速度等）
///
/// 由于中间层 JSON 未下载，layer_height 从预设名解析。
class BambuSystemPresetLoader {
  BambuSystemPresetLoader._();

  static const _processDir = 'assets/bambu_presets/process/';
  static const _filamentDir = 'assets/bambu_presets/filament/';
  static const _machineDir = 'assets/bambu_presets/machine/';

  /// 缓存的 common 工艺参数（避免重复加载）。
  static Map<String, String>? _processCommonCache;

  /// 缓存的 common 耗材参数。
  static Map<String, String>? _filamentCommonCache;

  /// 缓存的 common 打印机参数。
  static Map<String, String>? _machineCommonCache;

  /// 枚举应用中打包的全部官方工艺预设，而不是只返回某个示例机型的固定清单。
  static Future<List<String>> getAllProcessPresetNames() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final names = manifest
        .listAssets()
        .where(
          (path) =>
              path.startsWith(_processDir) &&
              path.endsWith('.json') &&
              !path.endsWith('fdm_process_common.json'),
        )
        .map((path) => path.substring(_processDir.length, path.length - 5))
        .toSet()
        .toList();
    names.sort();
    return names;
  }

  /// 读取工艺预设用于广场展示和筛选的官方元数据。
  static Future<Map<String, dynamic>> loadProcessPresetMetadata(
    String presetName,
  ) async {
    final raw = await rootBundle.loadString('$_processDir$presetName.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return {
      'name': json['name']?.toString() ?? presetName,
      'description': json['description']?.toString(),
      'inherits': json['inherits']?.toString(),
      'setting_id': json['setting_id']?.toString(),
      'compatible_printers': (json['compatible_printers'] as List?)
              ?.map((value) => value.toString())
              .toList() ??
          const <String>[],
    };
  }

  // ===== 工艺预设 =====

  /// 获取指定喷嘴直径可用的系统工艺预设名称列表。
  ///
  /// [nozzleDiameter]：喷嘴直径，如 "0.2", "0.4", "0.6", "0.8"。
  /// 返回格式：["0.08mm Extra Fine @BBL X1C", "0.12mm Fine @BBL X1C", ...]
  ///
  /// 修正：预设名带 "@BBL X1C" 后缀，与拓竹 Bambu Studio 显示名 100% 一致。
  ///
  /// 系统预设与喷嘴直径绑定：
  /// - 0.2 喷嘴：0.06~0.14mm 层高（带 "0.2 nozzle" 后缀）
  /// - 0.4 喷嘴：0.08~0.28mm 层高（无喷嘴后缀）
  /// - 0.6 喷嘴：0.18~0.42mm 层高（带 "0.6 nozzle" 后缀）
  /// - 0.8 喷嘴：0.24~0.56mm 层高（带 "0.8 nozzle" 后缀）
  static List<String> getAvailableProcessPresets(String nozzleDiameter) {
    switch (nozzleDiameter) {
      case '0.2':
        return const [
          '0.06mm High Quality @BBL X1C 0.2 nozzle',
          '0.06mm Standard @BBL X1C 0.2 nozzle',
          '0.08mm High Quality @BBL X1C 0.2 nozzle',
          '0.08mm Standard @BBL X1C 0.2 nozzle',
          '0.10mm High Quality @BBL X1C 0.2 nozzle',
          '0.10mm Standard @BBL X1C 0.2 nozzle',
          '0.12mm Standard @BBL X1C 0.2 nozzle',
          '0.14mm Standard @BBL X1C 0.2 nozzle',
        ];
      case '0.4':
        return const [
          '0.08mm Extra Fine @BBL X1C',
          '0.12mm Fine @BBL X1C',
          '0.12mm High Quality @BBL X1C',
          '0.16mm High Quality @BBL X1C',
          '0.16mm Optimal @BBL X1C',
          '0.20mm Standard @BBL X1C',
          '0.20mm Strength @BBL X1C',
          '0.24mm Draft @BBL X1C',
          '0.28mm Extra Draft @BBL X1C',
        ];
      case '0.6':
        return const [
          '0.18mm Standard @BBL X1C 0.6 nozzle',
          '0.24mm Standard @BBL X1C 0.6 nozzle',
          '0.30mm Standard @BBL X1C 0.6 nozzle',
          '0.30mm Strength @BBL X1C 0.6 nozzle',
          '0.36mm Standard @BBL X1C 0.6 nozzle',
          '0.42mm Standard @BBL X1C 0.6 nozzle',
        ];
      case '0.8':
        return const [
          '0.24mm Standard @BBL X1C 0.8 nozzle',
          '0.32mm Standard @BBL X1C 0.8 nozzle',
          '0.40mm Standard @BBL X1C 0.8 nozzle',
          '0.48mm Standard @BBL X1C 0.8 nozzle',
          '0.56mm Standard @BBL X1C 0.8 nozzle',
        ];
      default:
        return const [];
    }
  }

  /// 加载指定系统工艺预设的完整参数。
  ///
  /// [presetName]：完整预设名称，如 "0.20mm Standard @BBL X1C"。
  /// [nozzleDiameter]：喷嘴直径，如 "0.4"（仅用于推算首层层高）。
  /// 返回：扁平的 key→value 参数 Map，已合并 common 基础值 + 个体覆盖值。
  ///
  /// 修正：presetName 现在是完整名（带 @BBL X1C 后缀），文件名直接为 `$presetName.json`。
  static Future<Map<String, String>> loadProcessPreset(
    String presetName,
    String nozzleDiameter,
  ) async {
    // 1. 加载 common 基础参数
    final base = await _loadProcessCommon();

    // 2. 文件名 = 完整预设名 + .json
    final fileName = '$presetName.json';
    // 个体预设加载失败时抛异常，避免静默返回只有 common 的不完整数据
    final overrides = await _loadJsonAsFlatMap('$_processDir$fileName');

    // 3. 从预设名解析 layer_height（如 "0.20mm Standard @BBL X1C" → "0.2"）
    final layerHeight = _parseLayerHeightFromName(presetName);
    final initialLayerHeight =
        _getInitialLayerHeight(layerHeight, nozzleDiameter);

    // 4. 合并：基础 + 覆盖 + 解析的层高
    final result = Map<String, String>.from(base);
    result.addAll(overrides);
    if (layerHeight != null) {
      result['layer_height'] = layerHeight;
      result['initial_layer_print_height'] = initialLayerHeight;
    }

    // 移除元数据字段
    _removeMetaFields(result);

    return result;
  }

  /// 获取指定系统工艺预设的 setting_id（即云端的 base_id）。
  ///
  /// 上传预设到拓竹云端时，base_id 用于标识"基于哪个系统预设"，
  /// 让云端把自定义预设正确归类到对应层高/喷嘴的继承组下。
  ///
  /// [presetName]：完整预设名称，如 "0.20mm Standard @BBL X1C"。
  /// [nozzleDiameter]：喷嘴直径（保留参数，向后兼容）。
  /// 返回：setting_id 字符串（如 "GP004"）；文件不存在或无 setting_id 时返回 null。
  static Future<String?> getProcessPresetSettingId(
    String presetName,
    String nozzleDiameter,
  ) async {
    final fileName = '$presetName.json';
    try {
      final raw = await rootBundle.loadString('$_processDir$fileName');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final id = json['setting_id'];
      return id is String ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// 加载 fdm_process_common.json 作为基础工艺参数。
  static Future<Map<String, String>> _loadProcessCommon() async {
    if (_processCommonCache != null) return _processCommonCache!;
    _processCommonCache =
        await _loadJsonAsFlatMap('${_processDir}fdm_process_common.json');
    _removeMetaFields(_processCommonCache!);
    return _processCommonCache!;
  }

  /// 获取指定打印机兼容的系统工艺预设名称列表（按 compatible_printers 过滤）。
  ///
  /// [printerName]：完整打印机名称，如 "Bambu Lab X1 Carbon 0.4 nozzle"。
  /// [nozzleDiameter]：喷嘴直径，如 "0.4"。
  ///
  /// 先按喷嘴直径获取候选列表，再读取每个预设的 compatible_printers 字段，
  /// 只返回兼容当前打印机的预设。
  static Future<List<String>> getAvailableProcessPresetsForPrinter(
    String printerName,
    String nozzleDiameter,
  ) async {
    final candidates = getAvailableProcessPresets(nozzleDiameter);
    final result = <String>[];
    for (final presetName in candidates) {
      final compatiblePrinters = await _getCompatiblePrinters(presetName);
      // 如果 compatible_printers 为空或包含当前打印机，则兼容
      if (compatiblePrinters.isEmpty ||
          compatiblePrinters.contains(printerName)) {
        result.add(presetName);
      }
    }
    return result;
  }

  /// 读取指定工艺预设的 compatible_printers 列表。
  static Future<List<String>> _getCompatiblePrinters(String presetName) async {
    try {
      final fileName = '$presetName.json';
      final raw = await rootBundle.loadString('$_processDir$fileName');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final cp = json['compatible_printers'];
      if (cp is List) {
        return cp.map((e) => e.toString()).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // ===== 耗材预设 =====

  /// 获取所有可用的系统耗材材料类型列表。
  ///
  /// 返回拓竹官方 8 种基础材料：PLA、ABS、ASA、PA、PC、PETG、PVA、TPU。
  /// 这些是 Bambu Studio 中 "Generic XXX" 系列预设的基础材料名。
  static List<String> getAvailableFilamentMaterials() {
    return const ['PLA', 'ABS', 'ASA', 'PA', 'PC', 'PETG', 'PVA', 'TPU'];
  }

  /// 获取耗材材料的内部文件名标识（小写）。
  ///
  /// 'PLA' → 'pla'，'PETG' → 'pet'（拓竹文件名用 pet 而非 petg）。
  static String getFilamentMaterialKey(String material) {
    return material.toLowerCase() == 'petg' ? 'pet' : material.toLowerCase();
  }

  /// 获取指定打印机兼容的耗材预设显示名列表（材料 × 打印机组合实例化）。
  ///
  /// [printerModel]：打印机型号（不含喷嘴），如 "Bambu Lab X1 Carbon"。
  /// 返回格式：["Generic PLA @BBL X1C", "Generic ABS @BBL X1C", ...]
  ///
  /// 与拓竹 Bambu Studio 显示名一致：`Generic <材料> @BBL <型号缩写>`。
  static List<String> getAvailableFilamentPresetsForPrinter(
    String printerModel,
  ) {
    final printerSuffix = _getPrinterSuffix(printerModel);
    final materials = getAvailableFilamentMaterials();
    return materials.map((m) => 'Generic $m @BBL $printerSuffix').toList();
  }

  /// 从打印机型号名提取拓竹缩写后缀。
  ///
  /// "Bambu Lab X1 Carbon" → "X1C"
  /// "Bambu Lab X1" → "X1"
  /// "Bambu Lab X1E" → "X1E"
  /// "Bambu Lab P1S" → "P1S"
  /// "Bambu Lab P1P" → "P1P"
  /// "Bambu Lab A1" → "A1"
  /// "Bambu Lab A1 mini" → "A1 mini"
  /// "Bambu Lab H2D" → "H2D"
  /// "Bambu Lab H2D Pro" → "H2D"
  /// "Bambu Lab H2S" → "H2S"
  /// "Bambu Lab H2C" → "H2C"
  /// "Bambu Lab P2S" → "P2S"
  /// "Bambu Lab X2D" → "X2D"
  /// "Bambu Lab A2L" → "A2L"
  static String _getPrinterSuffix(String printerModel) {
    // X1 Carbon 特殊处理 → X1C
    if (printerModel.contains('X1 Carbon')) return 'X1C';
    // H2D Pro → H2D（耗材预设共用 H2D 系列）
    if (printerModel.contains('H2D Pro')) return 'H2D';
    // A1 mini 保持原样
    if (printerModel.contains('A1 mini')) return 'A1 mini';
    // 其他型号：取 "Bambu Lab " 后的部分
    final parts = printerModel.split('Bambu Lab ');
    if (parts.length > 1) return parts[1].trim();
    return printerModel;
  }

  /// 加载指定材料的耗材预设参数。
  ///
  /// [material]：材料类型小写，如 "pla", "pet", "abs", "tpu", "asa", "pc", "pa", "pva"。
  /// 返回：合并 common + 材料特定的参数 Map。
  static Future<Map<String, String>> loadFilamentPreset(String material) async {
    final base = await _loadFilamentCommon();
    final fileName = 'fdm_filament_$material.json';
    final overrides = await _loadJsonAsFlatMap('$_filamentDir$fileName');
    final result = Map<String, String>.from(base);
    result.addAll(overrides);
    _removeMetaFields(result);
    return result;
  }

  /// 加载 fdm_filament_common.json 作为基础耗材参数。
  static Future<Map<String, String>> _loadFilamentCommon() async {
    if (_filamentCommonCache != null) return _filamentCommonCache!;
    _filamentCommonCache =
        await _loadJsonAsFlatMap('${_filamentDir}fdm_filament_common.json');
    _removeMetaFields(_filamentCommonCache!);
    return _filamentCommonCache!;
  }

  // ===== 打印机预设 =====

  /// 加载指定打印机的预设参数。
  ///
  /// [printerName]：打印机名称，如 "Bambu Lab X1 Carbon 0.4 nozzle"。
  /// 返回：合并 common + 打印机特定的参数 Map。
  static Future<Map<String, String>> loadMachinePreset(
    String printerName,
  ) async {
    final base = await _loadMachineCommon();
    final fileName = '$printerName.json';
    final overrides = await _loadJsonAsFlatMap('$_machineDir$fileName');
    final result = Map<String, String>.from(base);
    result.addAll(overrides);
    _removeMetaFields(result);
    return result;
  }

  /// 加载 fdm_machine_common.json 作为基础打印机参数。
  static Future<Map<String, String>> _loadMachineCommon() async {
    if (_machineCommonCache != null) return _machineCommonCache!;
    _machineCommonCache =
        await _loadJsonAsFlatMap('${_machineDir}fdm_machine_common.json');
    _removeMetaFields(_machineCommonCache!);
    return _machineCommonCache!;
  }

  // ===== 辅助方法 =====

  /// 从 assets 加载 JSON 文件并转为扁平 key→value Map。
  ///
  /// 处理 Bambu Studio JSON 的两种值格式：
  /// - 标量字符串："value" → "value"
  /// - 数组：["v1", "v2"] → "v1"（取第一个元素，即标准挤出机值）
  ///
  /// 文件不存在或解析失败时抛异常，调用方需处理。
  static Future<Map<String, String>> _loadJsonAsFlatMap(
    String assetPath,
  ) async {
    final raw = await rootBundle.loadString(assetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return _flattenJson(json);
  }

  /// 将 JSON Map 扁平化为 key→String Map。
  ///
  /// 数组值处理规则：
  /// - compatible_printers：保留完整列表，用逗号分隔（用于兼容性过滤）
  /// - 其他数组：取第一个元素（标准挤出机值）
  static Map<String, String> _flattenJson(Map<String, dynamic> json) {
    final result = <String, String>{};
    json.forEach((key, value) {
      if (value is List) {
        if (key == 'compatible_printers') {
          // 保留完整兼容打印机列表，用逗号分隔
          result[key] = value.map((e) => e.toString()).join(',');
        } else {
          // 其他数组取第一个元素
          result[key] = value.isNotEmpty ? value.first.toString() : '';
        }
      } else if (value is String || value is num || value is bool) {
        result[key] = value.toString();
      }
      // 嵌套 Map 跳过（不用于参数字段）
    });
    return result;
  }

  /// 从预设名解析层高。
  ///
  /// "0.20mm Standard @BBL X1C" → "0.2"
  /// "0.08mm Extra Fine @BBL X1C" → "0.08"
  /// "0.06mm High Quality @BBL X1C 0.2 nozzle" → "0.06"
  static String? _parseLayerHeightFromName(String name) {
    final match = RegExp(r'^(\d+\.?\d*)mm').firstMatch(name);
    if (match == null) return null;
    final h = match.group(1)!;
    // 去除尾部多余的零：0.20 → 0.2，0.08 → 0.08
    if (h.contains('.')) {
      // 保留有效数字
      final d = double.tryParse(h);
      if (d != null) {
        // 格式化：0.2 → "0.2"，0.08 → "0.08"
        final s = d.toStringAsFixed(2);
        // 去除尾部零：0.20 → 0.2，0.08 → 0.08
        if (s.endsWith('0')) {
          return s.substring(0, s.length - 1);
        }
        return s;
      }
    }
    return h;
  }

  /// 根据层高和喷嘴直径获取首层层高（参考 Bambu Studio 官方值）。
  ///
  /// 0.2 喷嘴：首层层高 0.1mm
  /// 0.4 喷嘴：0.08→0.1，其余→0.2
  /// 0.6 喷嘴：首层层高 0.3mm
  /// 0.8 喷嘴：首层层高 0.3mm
  static String _getInitialLayerHeight(
    String? layerHeight,
    String nozzleDiameter,
  ) {
    if (layerHeight == null) {
      return switch (nozzleDiameter) {
        '0.2' => '0.1',
        '0.6' => '0.3',
        '0.8' => '0.3',
        _ => '0.2',
      };
    }
    switch (nozzleDiameter) {
      case '0.2':
        return '0.1';
      case '0.6':
        return '0.3';
      case '0.8':
        return '0.3';
      default: // 0.4
        if (layerHeight == '0.08') return '0.1';
        return '0.2';
    }
  }

  /// 移除 JSON 中的元数据字段（非参数字段）。
  /// 保留 compatible_printers 字段，用于打印机兼容性过滤。
  static void _removeMetaFields(Map<String, String> map) {
    const metaKeys = [
      'type',
      'name',
      'inherits',
      'from',
      'setting_id',
      'instantiation',
      'description',
      'compatible_printers_condition',
      'print_settings_id',
      'printer_settings_id',
      'filament_settings_id',
      'version',
      'printer_model',
      'printer_structure',
    ];
    for (final key in metaKeys) {
      map.remove(key);
    }
  }
}
