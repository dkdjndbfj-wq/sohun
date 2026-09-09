import 'dart:convert';
import 'dart:io';

/// BambuStudio 耗材预设信息（列出时用）。
class PresetInfo {
  final String name;
  final String? filamentType;
  final String? vendor;
  final String filePath;

  /// 拓竹云端 setting_id。为空表示仅存在于本地 BambuStudio。
  final String? cloudSettingId;

  /// 云端继承的官方预设 ID（filament 通常以 GF 开头）。
  final String? cloudBaseId;

  /// 云端返回的完整设置快照。写回云端时先保留原字段，再覆盖本次优化值。
  final Map<String, dynamic>? cloudSetting;

  final String? cloudVersion;

  /// 是否为系统预设（只读，不可写入）。
  /// true = system 目录下的官方预设
  /// false = user 目录下的用户自定义预设
  final bool isSystem;

  const PresetInfo({
    required this.name,
    this.filamentType,
    this.vendor,
    required this.filePath,
    this.isSystem = false,
    this.cloudSettingId,
    this.cloudBaseId,
    this.cloudSetting,
    this.cloudVersion,
  });

  bool get isCloudBacked => cloudSettingId?.isNotEmpty == true;
  bool get isCloudOnly => filePath.startsWith('cloud://');
  bool get isLocal => !isCloudOnly;

  PresetInfo withCloud({
    required String settingId,
    required String baseId,
    required Map<String, dynamic> setting,
    String? version,
  }) {
    return PresetInfo(
      name: name,
      filamentType: filamentType,
      vendor: vendor,
      filePath: filePath,
      isSystem: isSystem,
      cloudSettingId: settingId,
      cloudBaseId: baseId,
      cloudSetting: Map<String, dynamic>.unmodifiable(setting),
      cloudVersion: version,
    );
  }

  /// 按 filePath 判等（同一文件即同一预设），避免刷新后实例不匹配导致 DropdownButton 断言失败
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresetInfo && other.filePath == filePath;

  @override
  int get hashCode => filePath.hashCode;
}

/// 预设备份信息。
class BackupInfo {
  final String backupPath;
  final String presetName;
  final DateTime backupTime;

  /// 写入的新值（用于 UI 展示「原值 X，被改成 Y」）
  final double? oldValue;
  final double? newValue;
  final String? fieldName;

  const BackupInfo({
    required this.backupPath,
    required this.presetName,
    required this.backupTime,
    this.oldValue,
    this.newValue,
    this.fieldName,
  });
}

/// BambuStudio 耗材预设读写 + 备份 + 回滚。
///
/// **预设目录结构**（实际路径）：
/// - 用户预设：%APPDATA%\BambuStudio\user\<用户ID>\filament\*.json
///   用户 ID 是 BambuStudio 分配的数字串（如 1234567890），也可能有 default 目录
///   可读可写，写入前自动备份
/// - 系统预设：%APPDATA%\BambuStudio\system\BBL\filament\*.json
///   只读不可写（官方预设）
///
/// **字段值类型**：BambuStudio 预设里数值字段用数组表示，如
/// `"filament_flow_ratio": ["0.98"]`、`"nozzle_temperature": [210]`。
/// 读取时取数组第一个元素，写入时还原成数组格式。
///
/// **备份策略**：每次写入前复制原文件到用户预设目录下的 backup/ 子目录，
/// 命名 `<preset_basename>_<yyyyMMdd_HHmmss>.json`，
/// 每个预设保留最近 20 份，超过自动删最旧。
class BambuStudioPresetWriter {
  /// 扫描所有用户耗材预设目录。
  ///
  /// BambuStudio 的用户预设路径不是固定的 `user\BBL\filament`，
  /// 而是 `user\<用户ID>\filament`（用户 ID 是数字串或 "default"）。
  /// 所以要扫描 user 目录下所有子目录里的 filament 文件夹。
  ///
  /// 返回所有找到的用户预设目录列表（通常 1-2 个）。
  List<Directory> detectUserPresetDirs() {
    final appdata = Platform.environment['APPDATA'];
    if (appdata == null) return [];
    final userRoot = Directory('$appdata\\BambuStudio\\user');
    if (!userRoot.existsSync()) return [];

    final result = <Directory>[];
    for (final userDir in userRoot.listSync()) {
      if (userDir is! Directory) continue;
      final filamentDir = Directory('${userDir.path}\\filament');
      if (filamentDir.existsSync()) {
        result.add(filamentDir);
      }
    }
    return result;
  }

  /// 系统预设目录（只读）。
  /// 路径：%APPDATA%\BambuStudio\system\BBL\filament\
  Directory? detectSystemPresetDir() {
    final appdata = Platform.environment['APPDATA'];
    if (appdata == null) return null;
    final dir = Directory('$appdata\\BambuStudio\\system\\BBL\\filament');
    if (!dir.existsSync()) return null;
    return dir;
  }

  /// 备份目录（在第一个用户预设目录下的 backup/ 子目录）。
  /// 如果不存在则创建。
  Directory? _getOrCreateBackupDir() {
    final userDirs = detectUserPresetDirs();
    if (userDirs.isEmpty) return null;
    // 用第一个用户目录的 backup 子目录（所有备份集中存放）
    final backupDir = Directory('${userDirs.first.path}\\backup');
    if (!backupDir.existsSync()) {
      backupDir.createSync(recursive: true);
    }
    return backupDir;
  }

  /// 列出耗材预设。
  ///
  /// [includeSystem]：是否包含系统预设。默认 false（只加载用户预设）。
  /// 系统预设数量很多（1700+），每个都要读文件 + JSON 解析，
  /// 全部加载会卡 UI 几十秒，所以默认不加载。
  /// 用户写入目标只会是用户预设，系统预设只读不可写。
  Future<List<PresetInfo>> listUserPresets({bool includeSystem = false}) async {
    final result = <PresetInfo>[];

    // 1. 用户预设（可写）
    for (final dir in detectUserPresetDirs()) {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.json')) continue;
        try {
          final json =
              jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          final name = json['name'] as String?;
          if (name == null) continue;
          result.add(
            PresetInfo(
              name: name,
              filamentType: _parseStringField(json['filament_type']),
              vendor: _parseStringField(json['filament_vendor']),
              filePath: entity.path,
              isSystem: false,
            ),
          );
        } catch (_) {}
      }
    }

    // 2. 系统预设（只读，默认不加载）
    if (includeSystem) {
      final sysDir = detectSystemPresetDir();
      if (sysDir != null) {
        await for (final entity in sysDir.list()) {
          if (entity is! File) continue;
          if (!entity.path.endsWith('.json')) continue;
          try {
            final json =
                jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
            final name = json['name'] as String?;
            if (name == null) continue;
            if (name.endsWith('@base')) continue;
            if (json['instantiation'] == 'false') continue;
            result.add(
              PresetInfo(
                name: name,
                filamentType: _parseStringField(json['filament_type']),
                vendor: _parseStringField(json['filament_vendor']),
                filePath: entity.path,
                isSystem: true,
              ),
            );
          } catch (_) {}
        }
      }
    }

    return result;
  }

  /// 读取预设中某个字段的当前值。
  ///
  /// BambuStudio 预设字段值是数组格式，如 `"nozzle_temperature": [210]`，
  /// 这里取数组第一个元素。
  /// 字段不存在或格式异常返回 null。
  Future<double?> readField(String presetPath, String field) async {
    final file = File(presetPath);
    if (!file.existsSync()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return _parseNumField(json[field]);
  }

  /// 写入字段值（自动备份原文件）。
  ///
  /// **仅用户预设可写**，系统预设抛异常。
  ///
  /// 流程：
  /// 1. 校验非系统预设
  /// 2. 备份原文件到 backup/<preset_basename>_<timestamp>.json
  /// 3. 读取原 JSON
  /// 4. 修改目标字段（保留其他字段不动，保持数组格式）
  /// 5. 写回原文件
  /// 6. 清理旧备份（保留最近 20 份）
  ///
  /// 返回备份信息（含备份路径和原值，用于回滚）。
  Future<BackupInfo> writeField({
    required String presetPath,
    required String field,
    required double value,
  }) async {
    // 校验非系统预设
    if (_isSystemPreset(presetPath)) {
      throw StateError('系统预设只读，不能写入：$presetPath');
    }

    final file = File(presetPath);
    if (!file.existsSync()) {
      throw FileSystemException('预设文件不存在', presetPath);
    }

    // 1. 读取原值（用于备份信息）
    final originalJson =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final oldValue = _parseNumField(originalJson[field]);

    // 2. 备份原文件
    final backupDir = _getOrCreateBackupDir();
    if (backupDir == null) {
      throw StateError('无法创建备份目录（未找到用户预设目录）');
    }
    final presetBasename =
        presetPath.split(RegExp(r'[/\\]')).last.replaceAll('.json', '');
    final timestamp = _formatTimestamp(DateTime.now());
    final backupPath = '${backupDir.path}\\${presetBasename}_$timestamp.json';
    await file.copy(backupPath);

    // 3. 修改目标字段（统一用数组格式写入）
    // BambuStudio 预设里数值字段都是数组格式：[210] / ["0.98"]
    // 即使原字段不存在，也用数组格式写入，避免类型不匹配被忽略
    originalJson[field] = [_formatNum(value)];

    // 4. 写回原文件
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(originalJson),
    );

    // 5. 清理旧备份（保留最近 20 份）
    _cleanupOldBackups(backupDir, presetBasename);

    return BackupInfo(
      backupPath: backupPath,
      presetName: presetBasename,
      backupTime: DateTime.now(),
      oldValue: oldValue,
      newValue: value,
      fieldName: field,
    );
  }

  /// 批量写入多个字段（一次备份，多字段同时修改）。
  ///
  /// 比 `writeField` 更高效：只备份一次原文件，然后一次性修改所有字段。
  /// 适合质量优化场景：用户一次调多个参数（温度+流量+回抽等）。
  ///
  /// [fields] 是字段名 → 值的映射，只写入提供的字段，其他字段不动。
  /// 空的 fields 不会触发写入。
  ///
  /// 返回备份信息（fieldName 为 "多字段"，oldValue/newValue 为 null，
  /// 具体改动在 UI 侧从 fields 参数展示）。
  Future<BackupInfo> writeFields({
    required String presetPath,
    required Map<String, double> fields,
  }) async {
    if (fields.isEmpty) {
      throw ArgumentError('fields 不能为空');
    }
    if (_isSystemPreset(presetPath)) {
      throw StateError('系统预设只读，不能写入：$presetPath');
    }

    final file = File(presetPath);
    if (!file.existsSync()) {
      throw FileSystemException('预设文件不存在', presetPath);
    }

    // 1. 读取原 JSON
    final originalJson =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;

    // 2. 备份原文件（一次备份）
    final backupDir = _getOrCreateBackupDir();
    if (backupDir == null) {
      throw StateError('无法创建备份目录（未找到用户预设目录）');
    }
    final presetBasename =
        presetPath.split(RegExp(r'[/\\]')).last.replaceAll('.json', '');
    final timestamp = _formatTimestamp(DateTime.now());
    final backupPath = '${backupDir.path}\\${presetBasename}_$timestamp.json';
    await file.copy(backupPath);

    // 3. 修改所有目标字段（统一用数组格式写入）
    // BambuStudio 预设里数值字段都是数组格式：[210] / ["0.98"]
    // 即使原字段不存在，也用数组格式写入，避免类型不匹配被忽略
    for (final entry in fields.entries) {
      originalJson[entry.key] = [_formatNum(entry.value)];
    }

    // 4. 写回原文件
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(originalJson),
    );

    // 5. 清理旧备份
    _cleanupOldBackups(backupDir, presetBasename);

    return BackupInfo(
      backupPath: backupPath,
      presetName: presetBasename,
      backupTime: DateTime.now(),
      fieldName: '多字段(${fields.length})',
    );
  }

  /// 回滚：从备份恢复预设。
  Future<void> restore(String backupPath, String presetPath) async {
    final backupFile = File(backupPath);
    if (!backupFile.existsSync()) {
      throw FileSystemException('备份文件不存在', backupPath);
    }
    await backupFile.copy(presetPath);
  }

  /// 列出某个预设的所有备份（按时间倒序）。
  Future<List<BackupInfo>> listBackups(String presetFilePath) async {
    final backupDir = _getOrCreateBackupDir();
    if (backupDir == null) return [];
    final presetBasename =
        presetFilePath.split(RegExp(r'[/\\]')).last.replaceAll('.json', '');
    final result = <BackupInfo>[];
    await for (final entity in backupDir.list()) {
      if (entity is! File) continue;
      final name = entity.path.split(RegExp(r'[/\\]')).last;
      if (!name.startsWith(presetBasename)) continue;
      final stat = await entity.stat();
      result.add(
        BackupInfo(
          backupPath: entity.path,
          presetName: presetBasename,
          backupTime: stat.modified,
        ),
      );
    }
    result.sort((a, b) => b.backupTime.compareTo(a.backupTime));
    return result;
  }

  /// 判断路径是否为系统预设。
  bool _isSystemPreset(String path) {
    return path.contains('\\system\\BBL\\filament\\') ||
        path.contains('/system/BBL/filament/');
  }

  /// 清理旧备份，每个预设保留最近 20 份。
  void _cleanupOldBackups(Directory backupDir, String presetBasename) {
    final files = backupDir
        .listSync()
        .whereType<File>()
        .where(
          (f) => f.path.split(RegExp(r'[/\\]')).last.startsWith(presetBasename),
        )
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (int i = 20; i < files.length; i++) {
      try {
        files[i].deleteSync();
      } catch (_) {}
    }
  }

  /// 格式化时间戳为文件名安全字符串：yyyyMMdd_HHmmss
  String _formatTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// 把动态值转成 double（用于读取预设字段原值）。
  /// 支持 BambuStudio 的数组格式：["0.98"] → 0.98
  /// 也兼容裸值格式：0.98 → 0.98
  double? _parseNumField(dynamic v) {
    if (v == null) return null;
    // 数组格式：取第一个元素
    if (v is List && v.isNotEmpty) {
      return _parseNumValue(v.first);
    }
    return _parseNumValue(v);
  }

  double? _parseNumValue(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// 把字符串/数组字段解析成单字符串（用于 filament_type 等）。
  /// BambuStudio 的 filament_type 也是数组格式：["PLA"]
  String? _parseStringField(dynamic v) {
    if (v == null) return null;
    if (v is List && v.isNotEmpty) {
      final first = v.first;
      if (first is String) return first;
      return first?.toString();
    }
    if (v is String) return v;
    return null;
  }

  /// 格式化数字为字符串（BambuStudio 预设里数字用字符串表示）。
  /// 210.0 → "210"（整数）
  /// 0.98 → "0.98"（小数）
  /// 1.0 → "1"（整数）
  String _formatNum(double v) {
    if (v == v.toInt()) {
      return v.toInt().toString();
    }
    return v.toString();
  }
}
