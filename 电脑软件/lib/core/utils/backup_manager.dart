import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_variant.dart';
import '../app_version.dart';
import 'sqlite_snapshot.dart';

/// 备份信息。
class BackupInfo {
  /// 备份目录名（如 backup_2026-07-11T10-30-00.000）
  final String name;

  /// 备份完整路径
  final String path;

  /// 备份时间
  final DateTime createdAt;

  /// 可选标签（如"手动备份"、"升级前自动备份"）
  final String? label;

  /// 备份大小（字节）
  final int sizeBytes;

  BackupInfo({
    required this.name,
    required this.path,
    required this.createdAt,
    this.label,
    required this.sizeBytes,
  });

  /// 格式化大小。
  String get sizeFormatted {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 数据备份管理器。
///
/// 在应用升级时自动备份用户数据，支持手动备份和恢复。
/// 备份内容包括：
/// 1. SQLite 数据库文件（consumable_tracker.sqlite）
/// 2. SharedPreferences 导出（prefs.json）
/// 3. 备份元信息（meta.json）
///
/// 备份目录结构：
/// ```
/// {appDocDir}/backups/
///   backup_2026-07-11T10-30-00.000/
///     consumable_tracker.sqlite
///     prefs.json
///     meta.json
/// ```
class BackupManager {
  BackupManager._();

  /// 数据库文件名。
  static const _dbName = 'consumable_tracker.sqlite';

  /// 这些值只属于当前 Windows 用户/设备，备份既不导出，恢复时也不覆盖或清除。
  static const _sensitivePreferencePrefixes = [
    'bambu_cloud_',
    'bambu_kdf_',
    'app_auth_session_',
    'printer_connection',
  ];

  @visibleForTesting
  static Directory? debugApplicationDocumentsDirectory;

  static Future<Directory> _applicationDocumentsDirectory() async {
    final override = debugApplicationDocumentsDirectory;
    if (override != null) return override;
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      p.join(documents.path, AppVariant.dataNamespace),
    );
    await directory.create(recursive: true);
    return directory;
  }

  /// 是否已有用户数据库。用于首次引入 schema 版本记录时识别存量用户。
  static Future<bool> get databaseExists async {
    final appDir = await _applicationDocumentsDirectory();
    return File(p.join(appDir.path, _dbName)).exists();
  }

  /// 应用数据库、图片与备份所在的本地数据目录。
  static Future<String> get applicationDataDirPath async {
    final appDir = await _applicationDocumentsDirectory();
    return appDir.path;
  }

  /// 备份目录路径。
  static Future<String> get backupDirPath async {
    final appDir = await _applicationDocumentsDirectory();
    final backupDir = Directory(p.join(appDir.path, 'backups'));
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    return backupDir.path;
  }

  /// 创建完整备份（数据库 + SharedPreferences）。
  ///
  /// [label] 可选标签，用于区分手动/自动备份。
  /// 返回备份目录路径。
  static Future<String> createBackup({
    String? label,
    Future<void> Function()? preCopyHook,
    bool pruneOldBackups = true,
  }) async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final safeLabel = label?.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    final baseName = safeLabel != null
        ? 'backup_${safeLabel}_$timestamp'
        : 'backup_$timestamp';
    final backupRoot = await backupDirPath;
    // L-2 修复：毫秒级时间戳可能冲突，检查目录是否存在并追加后缀
    var backupName = baseName;
    var backupPath = p.join(backupRoot, backupName);
    var backupDir = Directory(backupPath);
    var counter = 2;
    while (await backupDir.exists()) {
      backupName = '${baseName}_$counter';
      backupPath = p.join(backupRoot, backupName);
      backupDir = Directory(backupPath);
      counter++;
    }
    final pending = await Directory(backupRoot).createTemp('pending_');
    try {
      if (preCopyHook != null) await preCopyHook();
      await _copyDatabase(pending);
      await _exportSharedPreferences(pending);
      await _writeBackupMeta(pending, label);
      await pending.rename(backupPath);
    } catch (_) {
      if (await pending.exists()) await pending.delete(recursive: true);
      rethrow;
    }

    // Only completed snapshots participate in retention. A safety backup made
    // before restore must not prune the backup the user is about to restore.
    if (pruneOldBackups) await _cleanOldBackups();

    return backupPath;
  }

  /// 从备份恢复。
  ///
  /// 恢复数据库文件和 SharedPreferences。
  /// [ensureDbClosed]：可选回调，调用方传入关闭数据库的函数，restore 会先执行它
  /// 再覆盖 db 文件，避免覆盖正在使用的 sqlite 导致数据损坏。
  /// 若不传，则仅依赖调用方自行提前关闭（旧行为，不推荐）。
  static Future<bool> restore(
    String backupPath, {
    Future<void> Function()? ensureDbClosed,
  }) async {
    final stagedFiles = <_StagedRestoreFile>[];
    final movedOriginals = <_MovedRestoreFile>[];
    Map<String, Object?>? preferenceSnapshot;
    var preferencesMutated = false;
    try {
      final backupDir = Directory(backupPath);
      if (!await backupDir.exists()) return false;

      final appDir = await _applicationDocumentsDirectory();
      final dbBackup = File(p.join(backupPath, _dbName));
      final prefsBackup = File(p.join(backupPath, 'prefs.json'));
      final hasDatabase = await dbBackup.exists();
      final hasPreferences = await prefsBackup.exists();
      if (!hasDatabase && !hasPreferences) return false;

      // 所有可能失败的读取与格式校验均在关闭当前数据库之前完成。
      Map<String, dynamic>? preferenceData;
      if (hasPreferences) {
        preferenceData = await _readSharedPreferencesBackup(prefsBackup);
      }

      final operationId =
          '${DateTime.now().microsecondsSinceEpoch}_${pid.toString()}';
      if (hasDatabase) {
        await _validateSqliteBackup(dbBackup);
        final target = File(p.join(appDir.path, _dbName));
        final staged = File('${target.path}.restore_tmp_$operationId');
        stagedFiles.add(_StagedRestoreFile(target: target, staged: staged));
        // SQLite's backup API includes committed WAL pages in one consistent
        // file and checks database integrity before closing the live database.
        await _writeSqliteSnapshot(dbBackup.path, staged.path);

        // 覆盖前先关闭数据库，防止文件锁冲突与页损坏。
        if (ensureDbClosed != null) await ensureDbClosed();

        // 主库、WAL、SHM 一起移出目标位置。备份未携带的旧 sidecar
        // 在成功恢复后会被删除，失败时则完整移回。
        for (final suffix in ['', '-wal', '-shm']) {
          final target = File(p.join(appDir.path, '$_dbName$suffix'));
          if (!await target.exists()) continue;
          final rollback = File('${target.path}.pre_restore_$operationId');
          await target.rename(rollback.path);
          movedOriginals.add(
            _MovedRestoreFile(target: target, rollback: rollback),
          );
        }

        for (final staged in stagedFiles) {
          await staged.staged.rename(staged.target.path);
          staged.installed = true;
        }
      }

      if (preferenceData != null) {
        preferenceSnapshot = await _snapshotSharedPreferences();
        preferencesMutated = true;
        await _importSharedPreferencesData(preferenceData);
      }

      for (final moved in movedOriginals) {
        await _safeDelete(moved.rollback);
      }
      for (final staged in stagedFiles) {
        await _safeDelete(staged.staged);
      }
      return true;
    } catch (error, stackTrace) {
      final rollbackErrors = <Object>[];
      if (preferencesMutated && preferenceSnapshot != null) {
        try {
          await _replaceSharedPreferences(preferenceSnapshot);
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      try {
        await _rollbackDatabase(stagedFiles, movedOriginals);
      } catch (rollbackError) {
        rollbackErrors.add(rollbackError);
      }
      debugPrint('BackupManager.restore 失败: $error');
      if (rollbackErrors.isNotEmpty) {
        Error.throwWithStackTrace(
          StateError('恢复失败且回滚不完整: $error; 回滚错误: $rollbackErrors'),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// 列出所有备份。
  static Future<List<BackupInfo>> listBackups() async {
    final root = await backupDirPath;
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return [];

    final backups = <BackupInfo>[];
    await for (final entry in rootDir.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith('backup_')) continue;

      // 读取元信息
      BackupMeta? meta;
      final metaFile = File(p.join(entry.path, 'meta.json'));
      if (await metaFile.exists()) {
        try {
          final json = jsonDecode(await metaFile.readAsString());
          meta = BackupMeta.fromJson(json);
        } catch (_) {
          meta = null;
        }
      }
      // Do not offer or automatically prune unrelated/incomplete directories.
      if (meta == null) continue;

      // 计算目录大小
      int size = 0;
      await for (final f in entry.list(recursive: true, followLinks: false)) {
        if (f is File) {
          size += await f.length();
        }
      }

      backups.add(
        BackupInfo(
          name: name,
          path: entry.path,
          createdAt: meta.createdAt,
          label: meta.label,
          sizeBytes: size,
        ),
      );
    }

    // 按时间倒序排列（最新的在前）
    backups.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return backups;
  }

  /// 删除指定备份。
  static Future<void> deleteBackup(String backupPath) async {
    final root = p.normalize(p.absolute(await backupDirPath));
    final target = p.normalize(p.absolute(backupPath));
    if (p.dirname(target) != root ||
        !p.basename(target).startsWith('backup_')) {
      throw ArgumentError.value(backupPath, 'backupPath', '不是应用备份目录');
    }
    final dir = Directory(target);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 复制数据库文件到备份目录。
  static Future<void> _copyDatabase(Directory backupDir) async {
    final appDir = await _applicationDocumentsDirectory();
    final dbFile = File(p.join(appDir.path, _dbName));
    if (await dbFile.exists()) {
      await _writeSqliteSnapshot(dbFile.path, p.join(backupDir.path, _dbName));
    }
  }

  static Future<void> _writeSqliteSnapshot(String source, String target) =>
      writeSqliteSnapshot(source, target);

  /// 导出 SharedPreferences 为 JSON 文件。
  ///
  /// **安全**：跳过含敏感凭据的 key（拓竹账号密码、token、加密 salt），
  /// 防止用户分享备份文件时泄露拓竹账号信息。
  static Future<void> _exportSharedPreferences(Directory backupDir) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final data = <String, dynamic>{};

    for (final key in keys) {
      // 跳过敏感 key
      if (_isSensitivePreferenceKey(key)) continue;
      final value = prefs.get(key);
      if (value != null) {
        data[key] = value;
      }
    }

    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    await File(p.join(backupDir.path, 'prefs.json')).writeAsString(jsonStr);
  }

  static bool _isSensitivePreferenceKey(String key) {
    return _sensitivePreferencePrefixes.any(key.startsWith);
  }

  static Future<Map<String, dynamic>> _readSharedPreferencesBackup(
    File backupFile,
  ) async {
    final jsonStr = await backupFile.readAsString();
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('prefs.json 根节点必须是 JSON 对象');
    }
    return decoded;
  }

  /// 导入普通偏好设置。框架键和当前设备的凭据始终保留，旧备份中即使
  /// 含有敏感键也会忽略，避免把另一台设备的密文或历史明文写回本机。
  static Future<void> _importSharedPreferencesData(
    Map<String, dynamic> data,
  ) async {
    final prefs = await SharedPreferences.getInstance();

    final existingKeys = prefs.getKeys();
    for (final key in existingKeys) {
      if (!key.startsWith('flutter.') && !_isSensitivePreferenceKey(key)) {
        await prefs.remove(key);
      }
    }

    for (final entry in data.entries) {
      final key = entry.key;
      if (_isSensitivePreferenceKey(key)) continue;
      await _setPreferenceValue(prefs, key, entry.value);
    }
  }

  static Future<Map<String, Object?>> _snapshotSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    return {for (final key in prefs.getKeys()) key: prefs.get(key)};
  }

  static Future<void> _replaceSharedPreferences(
    Map<String, Object?> snapshot,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      await prefs.remove(key);
    }
    for (final entry in snapshot.entries) {
      await _setPreferenceValue(prefs, entry.key, entry.value);
    }
  }

  static Future<void> _setPreferenceValue(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) async {
    if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    } else if (value is List) {
      try {
        await prefs.setStringList(key, value.cast<String>());
      } on TypeError {
        // 非字符串列表不是 SharedPreferences 支持的类型，忽略该项。
      }
    }
  }

  static Future<void> _validateSqliteBackup(File backup) async {
    if (await backup.length() < 16) {
      throw const FormatException('数据库备份文件过短');
    }
    final handle = await backup.open();
    try {
      final header = await handle.read(16);
      const expected = <int>[
        0x53,
        0x51,
        0x4c,
        0x69,
        0x74,
        0x65,
        0x20,
        0x66,
        0x6f,
        0x72,
        0x6d,
        0x61,
        0x74,
        0x20,
        0x33,
        0x00,
      ];
      if (!listEquals(header, expected)) {
        throw const FormatException('数据库备份不是有效的 SQLite 文件');
      }
    } finally {
      await handle.close();
    }
  }

  static Future<void> _rollbackDatabase(
    List<_StagedRestoreFile> stagedFiles,
    List<_MovedRestoreFile> movedOriginals,
  ) async {
    Object? firstError;
    for (final staged in stagedFiles) {
      try {
        // Before install this path is still the user's original database.
        // A staging or close failure must never delete it during rollback.
        if (staged.installed && await staged.target.exists()) {
          await staged.target.delete();
        }
        await _safeDelete(staged.staged);
      } catch (error) {
        firstError ??= error;
      }
    }
    for (final moved in movedOriginals.reversed) {
      try {
        if (await moved.target.exists()) await moved.target.delete();
        if (await moved.rollback.exists()) {
          await moved.rollback.rename(moved.target.path);
        }
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) throw firstError;
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('清理恢复临时文件失败 (${file.path}): $error');
    }
  }

  /// 写入备份元信息。
  static Future<void> _writeBackupMeta(
    Directory backupDir,
    String? label,
  ) async {
    final meta = BackupMeta(
      createdAt: DateTime.now(),
      label: label,
      version: AppVersion.version.replaceFirst('v', ''),
    );
    final jsonStr = const JsonEncoder.withIndent('  ').convert(meta.toJson());
    await File(p.join(backupDir.path, 'meta.json')).writeAsString(jsonStr);
  }

  /// 清理旧备份（保留最近 N 个）。
  static Future<void> _cleanOldBackups({int keepCount = 5}) async {
    final backups = await listBackups();
    if (backups.length <= keepCount) return;

    // listBackups 已按时间倒序排列，删除超出 keepCount 的旧备份
    for (var i = keepCount; i < backups.length; i++) {
      await deleteBackup(backups[i].path);
    }
  }
}

/// 备份元信息。
class BackupMeta {
  /// 备份创建时间
  final DateTime createdAt;

  /// 可选标签
  final String? label;

  /// 应用版本号
  final String version;

  BackupMeta({required this.createdAt, this.label, required this.version});

  Map<String, dynamic> toJson() => {
    'createdAt': createdAt.toIso8601String(),
    'label': label,
    'version': version,
  };

  factory BackupMeta.fromJson(Map<String, dynamic> json) {
    return BackupMeta(
      createdAt: DateTime.parse(json['createdAt'] as String),
      label: json['label'] as String?,
      version: json['version'] as String? ?? 'unknown',
    );
  }
}

class _StagedRestoreFile {
  final File target;
  final File staged;
  bool installed = false;

  _StagedRestoreFile({required this.target, required this.staged});
}

class _MovedRestoreFile {
  final File target;
  final File rollback;

  const _MovedRestoreFile({required this.target, required this.rollback});
}
