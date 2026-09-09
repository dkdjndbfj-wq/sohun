import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/external/printer/bambu_fault_codes.dart';

/// 故障知识库条目模型。
///
/// 每个条目描述一种打印机故障的代码、标题、原因、处理步骤和安全提示。
/// 官方条目的 summary 保留官方原文；应用标签与原文分开。
class FaultKnowledgeEntry {
  /// 故障代码（HMS 16 位十六进制字符串），关键字匹配的条目此字段为空。
  final String code;

  /// 别名/关键词列表，用于模糊搜索和关键字匹配。
  final List<String> aliases;

  /// 严重级别：warning / error / info。
  final String severity;

  /// 中文标题。
  final String title;

  /// 中文简短原因说明。
  final String summary;

  /// 适用机型列表。
  final List<String> applicableModels;

  /// 处理步骤列表。
  final List<String> steps;

  /// 恢复条件说明。
  final String resumeCondition;

  /// 安全提示。
  final String safetyNotice;

  /// 知识库来源标识。
  final String source;

  /// 知识库来源版本。
  final String sourceVersion;
  final String kind;
  final List<String> deviceTypes;
  bool get isOfficial => source == 'bambu-official';
  bool get isInternal => isOfficial && summary.trim().isEmpty;

  const FaultKnowledgeEntry({
    required this.code,
    required this.aliases,
    required this.severity,
    required this.title,
    required this.summary,
    required this.applicableModels,
    required this.steps,
    required this.resumeCondition,
    required this.safetyNotice,
    required this.source,
    required this.sourceVersion,
    this.kind = 'hms',
    this.deviceTypes = const [],
  });

  /// 从 JSON Map 构造条目。
  factory FaultKnowledgeEntry.fromJson(Map<String, dynamic> json) {
    return FaultKnowledgeEntry(
      code: normalizeBambuFaultCode(json['code'] as String? ?? ''),
      kind: json['kind'] as String? ?? 'hms',
      deviceTypes:
          (json['deviceTypes'] as List?)?.whereType<String>().toList() ??
          const [],
      aliases:
          (json['aliases'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      severity:
          json['severity'] as String? ??
          (json['kind'] == 'print_error'
              ? 'error'
              : bambuHmsSeverity(json['code'] as String? ?? '')),
      title:
          json['title'] as String? ??
          (json['kind'] == 'print_error' ? '打印任务异常' : '打印机设备提醒'),
      summary: json['summary'] as String? ?? '',
      applicableModels:
          (json['applicableModels'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      steps:
          (json['steps'] as List<dynamic>?)?.map((e) => e as String).toList() ??
          const [],
      resumeCondition: json['resumeCondition'] as String? ?? '',
      safetyNotice: json['safetyNotice'] as String? ?? '',
      source: json['source'] as String? ?? 'self-authored',
      sourceVersion: json['sourceVersion'] as String? ?? '1.0.0',
    );
  }
}

/// 打印机故障知识库服务。
///
/// 负责从 JSON 资产加载故障知识库，提供按代码查找和关键字搜索能力。
/// 加载结果缓存在内存中，后续查询直接读缓存。
/// 资产加载失败时优雅降级：返回 null / 空列表，不抛异常。
class PrinterFaultService {
  /// 资产路径。
  static const String assetPath = 'assets/knowledge/printer_faults_zh_CN.json';

  /// 资产加载器（可注入用于测试）。
  final Future<String> Function(String) _assetLoader;

  /// 内存缓存的故障条目列表。
  List<FaultKnowledgeEntry> _cache = const [];

  /// 知识库 schema 版本。
  String? _version;

  /// 是否已尝试加载。
  bool _loaded = false;
  Future<void>? _loading;
  final bool _online;
  final Future<String> Function(Uri)? _fetch;
  final Map<String, Map<String, FaultKnowledgeEntry>> _devices = {};
  final Map<String, String> _deviceVersions = {};
  final Map<String, Future<void>> _deviceLoads = {};
  final Map<String, DateTime> _lastAttempts = {};
  final Set<String> _packagedDeviceTypes = {};

  PrinterFaultService({
    Future<String> Function(String)? assetLoader,
    Future<String> Function(Uri)? fetch,
    bool? online,
  }) : _assetLoader = assetLoader ?? rootBundle.loadString,
       _fetch = fetch,
       _online = online ?? (assetLoader == null || fetch != null);

  /// 加载知识库到内存缓存。重复调用不会重新加载。
  ///
  /// 加载失败时缓存置空，不抛异常，仅输出调试日志。
  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    if (_loaded) return;
    try {
      final jsonStr = await _assetLoader(assetPath);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      _version = (data['sourceVersion'] ?? data['schemaVersion']) as String?;
      for (final source in data['sources'] as List? ?? const []) {
        final prefix = source['deviceType'];
        if (prefix is String && prefix != 'default')
          _packagedDeviceTypes.add(prefix);
      }
      final faultsList = data['faults'] as List<dynamic>? ?? [];
      _cache = faultsList
          .map(
            (e) => FaultKnowledgeEntry.fromJson({
              ...e as Map<String, dynamic>,
              'sourceVersion':
                  (e['sourceVersion'] ??
                          data['sourceVersion'] ??
                          data['schemaVersion'])
                      as String?,
            }),
          )
          .toList();
    } catch (e) {
      debugPrint('[PrinterFaultService] 加载故障知识库失败: $e');
      _cache = const [];
      _version = null;
    }
    _loaded = true;
  }

  /// 官方数据版本（旧资产回退到 schema 版本）。未加载时返回 null。
  String? get knowledgeBaseVersion => _version;

  /// 是否已加载完成。
  bool get isLoaded => _loaded;

  static String? deviceTypeFor(String serial) =>
      RegExp(r'^[A-Za-z0-9]{3}').stringMatch(serial.trim())?.toUpperCase();
  String? versionFor(String serial) =>
      _deviceVersions[deviceTypeFor(serial)] ?? _version;

  /// Bambu Studio selects text by the first three SN characters. Never send
  /// the full serial, LAN access code or account credentials to the catalog.
  Future<void> loadForDevice(String serial) async {
    await load();
    final prefix = deviceTypeFor(serial);
    if (!_online || prefix == null) return;
    final pending = _deviceLoads[prefix];
    if (pending != null) return pending;
    final last = _lastAttempts[prefix];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(hours: 1))
      return;
    final operation = _loadDevice(prefix);
    _deviceLoads[prefix] = operation;
    try {
      await operation;
    } finally {
      _deviceLoads.remove(prefix);
    }
  }

  Future<void> _loadDevice(String prefix) async {
    _lastAttempts[prefix] = DateTime.now();
    final key = 'bambu_hms_zh_v2_$prefix';
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(key);
      if (cached != null) {
        try {
          final envelope = jsonDecode(cached) as Map<String, dynamic>;
          _installDevice(prefix, envelope['payload'] as Map<String, dynamic>);
          final saved = DateTime.tryParse(envelope['savedAt'] as String? ?? '');
          if (saved != null &&
              DateTime.now().difference(saved) < const Duration(days: 1))
            return;
        } catch (_) {
          /* Use the packaged catalog if cache is corrupt. */
        }
      }
      final uri = Uri.https('e.bambulab.com', '/query.php', {
        'lang': 'zh-cn',
        'v': '0',
        'd': prefix,
      });
      final String body;
      if (_fetch != null) {
        body = await _fetch(uri).timeout(const Duration(seconds: 8));
      } else {
        final response = await http
            .get(
              uri,
              headers: {
                'Accept': 'application/json',
                'User-Agent': 'Mozilla/5.0',
              },
            )
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) return;
        body = utf8.decode(response.bodyBytes);
      }
      if (body.length > 8 * 1024 * 1024) return;
      final payload = jsonDecode(body) as Map<String, dynamic>;
      _installDevice(prefix, payload);
      await prefs.setString(
        key,
        jsonEncode({
          'savedAt': DateTime.now().toIso8601String(),
          'payload': payload,
        }),
      );
    } catch (_) {
      /* Offline diagnostics remain available. */
    }
  }

  void _installDevice(String prefix, Map<String, dynamic> payload) {
    if (payload['result'] != 0)
      throw const FormatException('Invalid official HMS catalog');
    final entries = <String, FaultKnowledgeEntry>{};
    for (final section in ['device_hms', 'device_error']) {
      final rows = payload['data']?[section]?['zh-cn'];
      if (rows is! List || rows.isEmpty)
        throw const FormatException('Incomplete HMS catalog');
      for (final row in rows) {
        final entry = FaultKnowledgeEntry.fromJson({
          'code': row['ecode'],
          'summary': row['intro'],
          'kind': section == 'device_hms' ? 'hms' : 'print_error',
          'source': 'bambu-official',
          'sourceVersion': '${payload['ver']}',
          'deviceTypes': [prefix],
        });
        if (!RegExp(r'^(?:[0-9A-F]{8}|[0-9A-F]{16})$').hasMatch(entry.code)) {
          throw const FormatException('Invalid HMS code');
        }
        entries[entry.code] = entry;
      }
    }
    _devices[prefix] = entries;
    _deviceVersions[prefix] = '${payload['ver']}';
  }

  /// 按故障代码精确查找。
  ///
  /// 仅匹配 code 字段非空且完全一致的条目。
  /// 未加载或未找到时返回 null。
  FaultKnowledgeEntry? lookupByCode(String code, {String? serial}) {
    if (!_loaded || code.isEmpty) return null;
    final normalized = normalizeBambuFaultCode(code);
    final prefix = serial == null ? null : deviceTypeFor(serial);
    if (_devices.containsKey(prefix)) return _devices[prefix]![normalized];
    FaultKnowledgeEntry? fallback;
    for (final entry in _cache) {
      if (entry.code.isNotEmpty && entry.code.toUpperCase() == normalized) {
        if (prefix != null && entry.deviceTypes.contains(prefix)) return entry;
        if (entry.deviceTypes.isEmpty || entry.deviceTypes.contains('default'))
          fallback = entry;
      }
    }
    return _packagedDeviceTypes.contains(prefix) ? null : fallback;
  }

  /// 按关键字搜索故障条目。
  ///
  /// 搜索范围包括：代码、标题、摘要、别名。
  /// 不区分大小写。未加载时返回空列表。
  List<FaultKnowledgeEntry> search(String query) {
    if (!_loaded || query.isEmpty) return const [];
    final q = query.toLowerCase();
    return _cache.where((entry) {
      if (entry.code.toLowerCase().contains(q)) return true;
      if (entry.title.toLowerCase().contains(q)) return true;
      if (entry.summary.toLowerCase().contains(q)) return true;
      for (final alias in entry.aliases) {
        if (alias.toLowerCase().contains(q)) return true;
      }
      return false;
    }).toList();
  }

  /// 获取所有故障条目（只读视图）。
  List<FaultKnowledgeEntry> get allEntries => List.unmodifiable(_cache);
}

/// 共享故障知识库。加载失败时服务仍可用，调用方会回退到原始错误码。
final printerFaultServiceProvider = FutureProvider<PrinterFaultService>((
  ref,
) async {
  final service = PrinterFaultService();
  await service.load();
  return service;
});
