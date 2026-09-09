import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/external/slicer/bambu_system_preset_loader.dart';
import '../data/external/printer/bambu_cloud_client.dart';
import '../data/models/filament_preset.dart';
import '../data/models/print_parameter.dart';
import '../data/models/printer_preset.dart';
import '../features/parameters/builtin_presets.dart';
import 'bambu_cloud_provider.dart';

/// 把任意字符串清理为可用的 id 片段：非字母数字字符统一替换为 `_`。
///
/// 例如 "0.20mm Standard @BBL X1C" → "0_20mm_Standard_BBL_X1C"。
String _sanitizeId(String name) {
  return name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
}

/// 判断 id 是否为不可编辑/不可删除的预设（内置或系统预设）。
bool _isReadOnlyPreset(String id) =>
    id.startsWith('builtin_') || id.startsWith('system_');

/// 打印参数预设列表 Provider。
///
/// 管理「内置预设 + 用户自定义预设」的增删改查。
/// 用户自定义预设持久化到 SharedPreferences（JSON 序列化）。
/// 内置预设的下载次数单独持久化（key: [_kBuiltinDownloadsKey]），
/// 避免修改内置预设本体。
class ParameterPresetNotifier
    extends StateNotifier<List<PrintParameterPreset>> {
  static const _kPrefsKey = 'parameter_presets_user';
  static const _kBuiltinDownloadsKey = 'builtin_preset_downloads';

  bool _initialized = false;
  final List<Future<void> Function()> _pendingOps = [];
  Future<void>? _currentOp;

  /// 内置预设的下载次数缓存（id -> count）。
  Map<String, int> _builtinDownloads = {};

  ParameterPresetNotifier() : super([]) {
    _load();
  }

  /// 加载系统预设 + 用户自定义预设。
  ///
  /// 系统预设从拓竹官方 JSON 异步加载（[BambuSystemPresetLoader]），
  /// 加载失败时降级为空列表，不影响用户预设。
  Future<void> _load() async {
    final systemPresets = await _loadSystemProcessPresets();
    final userPresets = await _loadUserPresets();
    _builtinDownloads = await _loadBuiltinDownloads();
    // 把系统预设的下载次数叠加到内存对象上
    final systemWithCounts = systemPresets.map((p) {
      final count = _builtinDownloads[p.id] ?? 0;
      return count > 0 ? p.copyWith(downloads: count) : p;
    }).toList();
    state = [...systemWithCounts, ...userPresets];
    _initialized = true;
    // 初始化完成后，执行在加载期间排队的操作。
    for (final op in _pendingOps) {
      await op();
    }
    _pendingOps.clear();
  }

  /// 从拓竹官方系统预设加载工艺预设（0.4 喷嘴默认）。
  ///
  /// 每个预设的 id 以 `system_process_` 前缀开头，author 为 'Bambu Lab'，
  /// 不可编辑、不可删除。单个预设加载失败时跳过，不影响其他预设。
  Future<List<PrintParameterPreset>> _loadSystemProcessPresets() async {
    try {
      final presetNames =
          await BambuSystemPresetLoader.getAllProcessPresetNames();
      final result = <PrintParameterPreset>[];
      for (final name in presetNames) {
        try {
          final nozzleMatch =
              RegExp(r'([0-9]+(?:\.[0-9]+)?) nozzle').firstMatch(name);
          final nozzleDiameter = nozzleMatch?.group(1) ?? '0.4';
          final flatMap = await BambuSystemPresetLoader.loadProcessPreset(
            name,
            nozzleDiameter,
          );
          final metadata =
              await BambuSystemPresetLoader.loadProcessPresetMetadata(name);
          result.add(
            _buildProcessPresetFromFlatMap(
              flatMap: flatMap,
              name: name,
              id: 'system_process_${_sanitizeId(name)}',
              metadata: metadata,
            ),
          );
        } catch (_) {
          // 单个预设加载失败时跳过，继续加载其他预设
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  /// 从扁平参数 Map 构造 [PrintParameterPreset]。
  ///
  /// 各参数组（quality/strength/speed/support/other）的 fromMap 仅读取
  /// 属于该组的 key，缺失的 key 由 [_parseStr] 返回空字符串。
  PrintParameterPreset _buildProcessPresetFromFlatMap({
    required Map<String, String> flatMap,
    required String name,
    required String id,
    Map<String, dynamic> metadata = const {},
  }) {
    final now = DateTime.now();
    return PrintParameterPreset(
      id: id,
      name: name,
      description: metadata['description'] as String?,
      author: 'Bambu Lab',
      scene: _sceneFromProcessName(name),
      compatiblePrinters:
          (metadata['compatible_printers'] as List<String>?) ?? const [],
      createdAt: now,
      updatedAt: now,
      inherits: metadata['inherits'] as String? ?? 'fdm_process_common',
      quality: PrintQualityParams.fromMap(flatMap),
      strength: PrintStrengthParams.fromMap(flatMap),
      speed: PrintSpeedParams.fromMap(flatMap),
      support: PrintSupportParams.fromMap(flatMap),
      other: PrintOtherParams.fromMap(flatMap),
    );
  }

  static String _sceneFromProcessName(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('strength')) return '功能强度';
    if (lower.contains('draft')) return '快速草稿';
    if (lower.contains('extra fine') || lower.contains('high quality')) {
      return '高精度';
    }
    if (lower.contains('fine') || lower.contains('optimal')) return '精细打印';
    return '通用打印';
  }

  /// 加载内置预设下载次数计数。
  Future<Map<String, int>> _loadBuiltinDownloads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kBuiltinDownloadsKey);
      if (raw == null) return {};
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  /// 保存内置预设下载次数计数。
  Future<void> _saveBuiltinDownloads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kBuiltinDownloadsKey,
        jsonEncode(_builtinDownloads),
      );
    } catch (_) {
      // 忽略写入错误
    }
  }

  /// 串行执行异步操作，避免并发读写竞态。
  Future<void> _serialExecute(Future<void> Function() op) async {
    while (_currentOp != null) {
      await _currentOp;
    }
    final completer = Completer<void>();
    _currentOp = completer.future;
    try {
      await op();
    } finally {
      completer.complete();
      _currentOp = null;
    }
  }

  /// 从 SharedPreferences 加载用户自定义预设。
  Future<List<PrintParameterPreset>> _loadUserPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kPrefsKey);
      if (jsonStr == null) return [];
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map(
            (e) => PrintParameterPreset.fromBbsparamJson(jsonEncode(e)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 持久化用户自定义预设到 SharedPreferences。
  Future<void> _saveUserPresets(List<PrintParameterPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = presets.map((p) => p.toBbsparamMap()).toList();
    await prefs.setString(_kPrefsKey, jsonEncode(jsonList));
  }

  /// 获取所有用户自定义预设（排除内置和系统预设）。
  List<PrintParameterPreset> get _userPresets =>
      state.where((p) => !_isReadOnlyPreset(p.id)).toList();

  /// 添加新预设。
  Future<void> add(PrintParameterPreset preset) async {
    if (!_initialized) {
      _pendingOps.add(() => add(preset));
      return;
    }
    await _serialExecute(() async {
      final userPresets = [..._userPresets, preset];
      await _saveUserPresets(userPresets);
      await _load();
    });
  }

  /// 更新已有预设（按 id 匹配）。
  Future<void> update(PrintParameterPreset preset) async {
    if (!_initialized) {
      _pendingOps.add(() => update(preset));
      return;
    }
    await _serialExecute(() async {
      final userPresets = _userPresets.map((p) {
        if (p.id == preset.id) {
          return preset.copyWith(updatedAt: DateTime.now());
        }
        return p;
      }).toList();
      await _saveUserPresets(userPresets);
      await _load();
    });
  }

  /// 清除已删除社区发布在本地草稿上的关联信息，但保留草稿及其他字段。
  Future<void> clearCommunityPublication(String publicationId) async {
    if (publicationId.isEmpty) return;
    if (!_initialized) {
      _pendingOps.add(() => clearCommunityPublication(publicationId));
      return;
    }
    await _serialExecute(() async {
      var changed = false;
      final userPresets = _userPresets.map((preset) {
        if (preset.communityPublicationId != publicationId) return preset;
        changed = true;
        return preset.withoutCommunityPublication();
      }).toList();
      if (!changed) return;
      await _saveUserPresets(userPresets);
      await _load();
    });
  }

  /// 删除预设（仅用户自定义可删，内置/系统预设不可删）。
  ///
  /// [onDeleted] 回调用于通知外部清理与该预设相关的状态（如点赞记录）。
  Future<void> delete(String id, {void Function(String id)? onDeleted}) async {
    if (_isReadOnlyPreset(id)) return;
    if (!_initialized) {
      _pendingOps.add(() => delete(id, onDeleted: onDeleted));
      return;
    }
    await _serialExecute(() async {
      final userPresets = _userPresets.where((p) => p.id != id).toList();
      await _saveUserPresets(userPresets);
      await _load();
    });
    // 删除后通知外部清理相关状态
    onDeleted?.call(id);
  }

  /// 复制预设为新预设。
  ///
  /// 生成新 id（用户可编辑名称等）。
  /// 清空所有服务器字段（shareId / uploadedAt / serverVersion / likes / downloads），
  /// 因为副本是全新的本地预设，不应继承原预设的服务器状态。
  Future<PrintParameterPreset> duplicate(PrintParameterPreset preset) async {
    final now = DateTime.now();
    final newId = 'user_${now.millisecondsSinceEpoch}';
    final copy = preset.copyWith(
      id: newId,
      name: '${preset.name} 副本',
      createdAt: now,
      updatedAt: now,
      // 清空服务器字段
      shareId: null,
      uploadedAt: null,
      serverVersion: null,
      communityPublicationId: null,
      communityOwnerId: null,
      communityRevision: null,
      communityVisibility: null,
      likes: 0,
      downloads: 0,
    );
    await add(copy);
    return copy;
  }

  /// 按 id 查找预设。
  PrintParameterPreset? findById(String id) {
    for (final p in state) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 自增下载次数（应用预设到 Bambu Studio 时调用）。
  ///
  /// - 用户自定义预设：持久化到 SharedPreferences（随预设 JSON 一起保存）。
  /// - 内置/系统预设：单独持久化到 [_kBuiltinDownloadsKey]，不修改预设本体。
  Future<void> incrementDownloads(String id) async {
    if (!_initialized) {
      _pendingOps.add(() => incrementDownloads(id));
      return;
    }
    await _serialExecute(() async {
      if (_isReadOnlyPreset(id)) {
        // 内置/系统预设：单独计数
        _builtinDownloads[id] = (_builtinDownloads[id] ?? 0) + 1;
        await _saveBuiltinDownloads();
        // 更新内存中的预设对象
        state = state.map((p) {
          if (p.id == id) {
            return p.copyWith(downloads: _builtinDownloads[id]!);
          }
          return p;
        }).toList();
      } else {
        // 用户自定义预设：随预设 JSON 持久化
        final userPresets = _userPresets.map((p) {
          if (p.id == id) {
            return p.copyWith(
              downloads: p.downloads + 1,
              updatedAt: DateTime.now(),
            );
          }
          return p;
        }).toList();
        await _saveUserPresets(userPresets);
        await _load();
      }
    });
  }

  /// 重新加载（外部导入后调用）。
  Future<void> reload() async => _load();
}

/// 本地点赞状态 Notifier。
///
/// 维护用户点赞过的预设 id 集合，持久化到 SharedPreferences。
/// 与服务器无关，纯本地状态。
class LikedPresetsNotifier extends StateNotifier<Set<String>> {
  static const _kPrefsKey = 'liked_preset_ids';

  LikedPresetsNotifier() : super({}) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kPrefsKey) ?? [];
      state = list.toSet();
    } catch (_) {
      state = {};
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kPrefsKey, state.toList());
    } catch (_) {
      // 忽略写入错误
    }
  }

  /// 切换点赞状态。
  Future<void> toggle(String id) async {
    final next = {...state};
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }
    state = next;
    await _save();
  }

  /// 移除某个预设的点赞记录（预设被删除时调用，清理脏数据）。
  Future<void> remove(String id) async {
    if (!state.contains(id)) return;
    final next = {...state}..remove(id);
    state = next;
    await _save();
  }

  /// 是否已点赞。
  bool isLiked(String id) => state.contains(id);
}

/// 点赞状态 Provider。
final likedPresetsProvider =
    StateNotifierProvider<LikedPresetsNotifier, Set<String>>((ref) {
  return LikedPresetsNotifier();
});

/// 参数预设列表 Provider。
final parameterPresetProvider =
    StateNotifierProvider<ParameterPresetNotifier, List<PrintParameterPreset>>(
        (ref) {
  return ParameterPresetNotifier();
});

/// 当前登录账号的拓竹云端工艺预设。
///
/// 云端预设不直接写入本地列表，避免登录/退出时污染用户本地数据；参数广场
/// 展示时按 shareId 合并，编辑时再生成对应的本地镜像。
final cloudParameterPresetsProvider =
    FutureProvider<List<PrintParameterPreset>>((ref) async {
  final session = ref.watch(
    bambuCloudProvider.select((state) => state.session),
  );
  if (session == null) return const [];
  final items = await BambuCloudClient.getUserPresets(session: session);
  return items
      .map(_cloudProcessPresetFromMap)
      .whereType<PrintParameterPreset>()
      .toList();
});

PrintParameterPreset? _cloudProcessPresetFromMap(Map<String, dynamic> item) {
  dynamic rawSetting = item['setting'] ??
      item['values'] ??
      item['config'] ??
      item['content'] ??
      item['detail'];
  if (rawSetting is String) {
    try {
      rawSetting = jsonDecode(rawSetting);
    } catch (_) {
      rawSetting = null;
    }
  }
  final setting = rawSetting is Map
      ? Map<String, dynamic>.from(rawSetting)
      : Map<String, dynamic>.from(item);
  final settingId = (item['setting_id'] ??
          item['settingId'] ??
          item['preset_id'] ??
          item['config_id'] ??
          item['uuid'] ??
          item['id'] ??
          setting['setting_id'] ??
          setting['settingId'])
      ?.toString();
  if (settingId == null || settingId.isEmpty) return null;
  final name = (item['name'] ??
          item['setting_name'] ??
          item['title'] ??
          setting['print_settings_id'] ??
          setting['name'] ??
          '云端预设')
      .toString();
  final updatedAt = _cloudDate(
    item['updated_at'] ?? item['updated_time'] ?? setting['updated_time'],
  );
  final presetType =
      (item['preset_type'] ?? item['type'] ?? 'print').toString().toLowerCase();
  var compatible = _cloudStringList(
    item['compatible_printers'] ??
        item['compatible_prints'] ??
        setting['compatible_printers'] ??
        setting['compatible_prints'],
  );
  if (compatible.isEmpty) {
    compatible = _cloudPrinterFromMetadata(
      item['base_name'] ?? setting['inherits'] ?? item['inherits'] ?? name,
    );
  }
  final materialValue =
      item['material'] ?? item['filament_type'] ?? setting['filament_type'];
  final material = materialValue is List && materialValue.isNotEmpty
      ? materialValue.first.toString()
      : materialValue?.toString();
  final scene = switch (presetType) {
    'filament' => '耗材预设',
    'printer' || 'machine' => '打印机预设',
    _ => _processSceneFromName(name),
  };

  return PrintParameterPreset(
    id: 'cloud_$settingId',
    name: name,
    description: (item['description'] ?? setting['description'])?.toString(),
    author: '拓竹云端',
    material: material?.isEmpty == true ? null : material,
    scene: scene,
    compatiblePrinters: compatible,
    createdAt: _cloudDate(item['created_at']) ?? updatedAt ?? DateTime.now(),
    updatedAt: updatedAt ?? DateTime.now(),
    inherits: (setting['inherits'] ?? item['base_id'] ?? 'fdm_process_common')
        .toString(),
    quality: PrintQualityParams.fromMap(setting),
    strength: PrintStrengthParams.fromMap(setting),
    speed: PrintSpeedParams.fromMap(setting),
    support: PrintSupportParams.fromMap(setting),
    other: PrintOtherParams.fromMap(setting),
    shareId: settingId,
    uploadedAt: updatedAt,
    serverVersion: item['version']?.toString(),
    tags: ['云端', scene],
  );
}

DateTime? _cloudDate(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final millis = value > 100000000000 ? value.toInt() : value.toInt() * 1000;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }
  final text = value.toString();
  final number = int.tryParse(text);
  if (number != null) return _cloudDate(number);
  return DateTime.tryParse(text);
}

List<String> _cloudStringList(dynamic value) {
  if (value is List) return value.map((item) => item.toString()).toList();
  if (value is String && value.trim().isNotEmpty) {
    return value
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
  return const [];
}

List<String> _cloudPrinterFromMetadata(dynamic value) {
  final text = value?.toString() ?? '';
  final match =
      RegExp(r'@BBL\s+([^@]+)$', caseSensitive: false).firstMatch(text);
  if (match == null) return const [];
  var code = match.group(1)!.trim();
  code = code.replaceFirst(
    RegExp(r'\s+[0-9.]+\s*(?:mm\s*)?nozzle.*$', caseSensitive: false),
    '',
  );
  const models = <String, String>{
    'X1C': 'Bambu Lab X1 Carbon',
    'X1': 'Bambu Lab X1',
    'X1E': 'Bambu Lab X1E',
    'X2D': 'Bambu Lab X2D',
    'P1P': 'Bambu Lab P1P',
    'P1S': 'Bambu Lab P1S',
    'P2S': 'Bambu Lab P2S',
    'A1': 'Bambu Lab A1',
    'A1M': 'Bambu Lab A1 mini',
    'A2L': 'Bambu Lab A2L',
    'H2D': 'Bambu Lab H2D',
    'H2DP': 'Bambu Lab H2D Pro',
    'H2S': 'Bambu Lab H2S',
    'H2C': 'Bambu Lab H2C',
  };
  return [models[code.toUpperCase()] ?? 'Bambu Lab $code'];
}

String _processSceneFromName(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('strength')) return '功能强度';
  if (lower.contains('draft')) return '快速草稿';
  if (lower.contains('extra fine') || lower.contains('high quality')) {
    return '高精度';
  }
  if (lower.contains('fine') || lower.contains('optimal')) return '精细打印';
  return '通用打印';
}

/// 耗材丝预设列表 Provider。
///
/// 管理「内置耗材丝预设 + 用户自定义耗材丝预设」的增删改查。
/// 用户自定义预设持久化到 SharedPreferences。
class FilamentPresetNotifier extends StateNotifier<List<FilamentPreset>> {
  static const _kPrefsKey = 'filament_presets_user';

  bool _initialized = false;
  final List<Future<void> Function()> _pendingOps = [];
  Future<void>? _currentOp;

  FilamentPresetNotifier() : super([]) {
    _load();
  }

  Future<void> _load() async {
    final systemPresets = await _loadSystemFilamentPresets();
    final userPresets = await _loadUserPresets();
    state = [...systemPresets, ...userPresets];
    _initialized = true;
    // 初始化完成后，执行在加载期间排队的操作。
    for (final op in _pendingOps) {
      await op();
    }
    _pendingOps.clear();
  }

  /// 从拓竹官方系统预设加载耗材丝预设。
  ///
  /// 每个预设的 id 以 `system_filament_` 前缀开头，author 为 'Bambu Lab'，
  /// 不可编辑、不可删除。单个材料加载失败时跳过，不影响其他材料。
  Future<List<FilamentPreset>> _loadSystemFilamentPresets() async {
    try {
      final materials = BambuSystemPresetLoader.getAvailableFilamentMaterials();
      final result = <FilamentPreset>[];
      for (final material in materials) {
        try {
          final materialKey =
              BambuSystemPresetLoader.getFilamentMaterialKey(material);
          final flatMap =
              await BambuSystemPresetLoader.loadFilamentPreset(materialKey);
          final now = DateTime.now();
          result.add(
            FilamentPreset(
              id: 'system_filament_$material',
              name: 'Generic $material',
              author: 'Bambu Lab',
              material: material,
              vendor: 'Generic',
              createdAt: now,
              updatedAt: now,
              inherits: 'fdm_filament_common',
              temp: FilamentTempParams.fromMap(flatMap),
              flow: FilamentFlowParams.fromMap(flatMap),
              fan: FilamentFanParams.fromMap(flatMap),
              retraction: FilamentRetractionParams.fromMap(flatMap),
              drying: FilamentDryingParams.fromMap(flatMap),
              properties: FilamentPropertyParams.fromMap(flatMap),
            ),
          );
        } catch (_) {
          // 单个材料加载失败时跳过，继续加载其他材料
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  /// 串行执行异步操作，避免并发读写竞态。
  Future<void> _serialExecute(Future<void> Function() op) async {
    while (_currentOp != null) {
      await _currentOp;
    }
    final completer = Completer<void>();
    _currentOp = completer.future;
    try {
      await op();
    } finally {
      completer.complete();
      _currentOp = null;
    }
  }

  Future<List<FilamentPreset>> _loadUserPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kPrefsKey);
      if (jsonStr == null) return [];
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((e) => FilamentPreset.fromBbsparamJson(jsonEncode(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveUserPresets(List<FilamentPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = presets.map((p) => p.toBbsparamMap()).toList();
    await prefs.setString(_kPrefsKey, jsonEncode(jsonList));
  }

  List<FilamentPreset> get _userPresets =>
      state.where((p) => !_isReadOnlyPreset(p.id)).toList();

  /// 添加耗材丝预设。
  Future<void> add(FilamentPreset preset) async {
    if (!_initialized) {
      _pendingOps.add(() => add(preset));
      return;
    }
    await _serialExecute(() async {
      final userPresets = [..._userPresets, preset];
      await _saveUserPresets(userPresets);
      await _load();
    });
  }

  /// 更新耗材丝预设（按 id 匹配）。
  Future<void> update(FilamentPreset preset) async {
    if (!_initialized) {
      _pendingOps.add(() => update(preset));
      return;
    }
    await _serialExecute(() async {
      final userPresets = _userPresets.map((p) {
        if (p.id == preset.id) {
          return preset.copyWith(updatedAt: DateTime.now());
        }
        return p;
      }).toList();
      await _saveUserPresets(userPresets);
      await _load();
    });
  }

  /// 删除耗材丝预设（仅用户自定义可删，内置/系统预设不可删）。
  Future<void> delete(String id) async {
    if (_isReadOnlyPreset(id)) return;
    if (!_initialized) {
      _pendingOps.add(() => delete(id));
      return;
    }
    await _serialExecute(() async {
      final userPresets = _userPresets.where((p) => p.id != id).toList();
      await _saveUserPresets(userPresets);
      await _load();
    });
  }

  /// 按 id 查找耗材丝预设。
  FilamentPreset? findById(String id) {
    for (final p in state) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 重新加载。
  Future<void> reload() async => _load();
}

/// 耗材丝预设列表 Provider。
final filamentPresetProvider =
    StateNotifierProvider<FilamentPresetNotifier, List<FilamentPreset>>((ref) {
  return FilamentPresetNotifier();
});

/// 打印机预设列表 Provider。
///
/// 管理「内置打印机预设 + 用户自定义打印机预设」的增删改查。
/// 用户自定义预设持久化到 SharedPreferences。
class PrinterPresetNotifier extends StateNotifier<List<PrinterPreset>> {
  static const _kPrefsKey = 'printer_presets_user';

  bool _initialized = false;
  final List<Future<void> Function()> _pendingOps = [];
  Future<void>? _currentOp;

  PrinterPresetNotifier() : super([]) {
    _load();
  }

  Future<void> _load() async {
    final builtins = BuiltinPresets.getAllPrinters();
    final userPresets = await _loadUserPresets();
    state = [...builtins, ...userPresets];
    _initialized = true;
    // 初始化完成后，执行在加载期间排队的操作。
    for (final op in _pendingOps) {
      await op();
    }
    _pendingOps.clear();
  }

  /// 串行执行异步操作，避免并发读写竞态。
  Future<void> _serialExecute(Future<void> Function() op) async {
    while (_currentOp != null) {
      await _currentOp;
    }
    final completer = Completer<void>();
    _currentOp = completer.future;
    try {
      await op();
    } finally {
      completer.complete();
      _currentOp = null;
    }
  }

  Future<List<PrinterPreset>> _loadUserPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kPrefsKey);
      if (jsonStr == null) return [];
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((e) => PrinterPreset.fromBbsparamJson(jsonEncode(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveUserPresets(List<PrinterPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = presets.map((p) => p.toBbsparamMap()).toList();
    await prefs.setString(_kPrefsKey, jsonEncode(jsonList));
  }

  List<PrinterPreset> get _userPresets =>
      state.where((p) => !p.id.startsWith('builtin_')).toList();

  /// 添加打印机预设。
  Future<void> add(PrinterPreset preset) async {
    if (!_initialized) {
      _pendingOps.add(() => add(preset));
      return;
    }
    await _serialExecute(() async {
      final userPresets = [..._userPresets, preset];
      await _saveUserPresets(userPresets);
      await _load();
    });
  }

  /// 更新打印机预设（按 id 匹配）。
  Future<void> update(PrinterPreset preset) async {
    if (!_initialized) {
      _pendingOps.add(() => update(preset));
      return;
    }
    await _serialExecute(() async {
      final userPresets = _userPresets.map((p) {
        if (p.id == preset.id) {
          return preset.copyWith(updatedAt: DateTime.now());
        }
        return p;
      }).toList();
      await _saveUserPresets(userPresets);
      await _load();
    });
  }

  /// 删除打印机预设（仅用户自定义可删）。
  Future<void> delete(String id) async {
    if (id.startsWith('builtin_')) return;
    if (!_initialized) {
      _pendingOps.add(() => delete(id));
      return;
    }
    await _serialExecute(() async {
      final userPresets = _userPresets.where((p) => p.id != id).toList();
      await _saveUserPresets(userPresets);
      await _load();
    });
  }

  /// 按 id 查找打印机预设。
  PrinterPreset? findById(String id) {
    for (final p in state) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 重新加载。
  Future<void> reload() async => _load();
}

/// 打印机预设列表 Provider。
final printerPresetProvider =
    StateNotifierProvider<PrinterPresetNotifier, List<PrinterPreset>>((ref) {
  return PrinterPresetNotifier();
});
