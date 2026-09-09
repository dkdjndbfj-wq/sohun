import 'package:shared_preferences/shared_preferences.dart';

/// 应用版本偏好管理。
///
/// 管理应用版本号和 SharedPreferences 层面的配置迁移。
/// 与 [MigrationManager]（数据库迁移审计）配合使用：
/// - AppDatabase 负责 SQLite 表结构迁移
/// - [MigrationManager] 记录已成功打开的 schema 版本
/// - [AppVersionPrefs] 负责 SharedPreferences 键值迁移和版本记录
class AppVersionPrefs {
  AppVersionPrefs._();

  static const _versionKey = 'app_version_code';
  static const _lastMigrationKey = 'last_prefs_migration';
  static const _lastDbSchemaVersionKey = 'last_db_schema_version';

  /// 获取当前应用版本号。
  static Future<int> getVersionCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_versionKey) ?? 0;
  }

  /// 设置当前应用版本号。
  static Future<void> setVersionCode(int version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_versionKey, version);
  }

  /// 检查并执行偏好配置迁移。
  ///
  /// 每次 SharedPreferences 结构变更时在此追加迁移逻辑：
  /// - v2：新增参数预设相关的偏好键默认值设置
  static Future<void> migrateIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final lastMigration = prefs.getInt(_lastMigrationKey) ?? 0;

    if (lastMigration < 2) {
      // v2 迁移：新增参数预设相关的偏好键
      // 当前参数预设数据已通过 ParameterPresetNotifier 持久化，
      // 此处仅设置默认标记，确保版本一致性。
      await prefs.setInt(_lastMigrationKey, 2);
    }
  }

  /// 获取上次偏好迁移版本号（供 UI 展示）。
  static Future<int> getLastMigrationVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_lastMigrationKey) ?? 0;
  }

  /// 上次成功打开并完成迁移的数据库 schema 版本。
  static Future<int> getLastDbSchemaVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_lastDbSchemaVersionKey) ?? 0;
  }

  static Future<void> setLastDbSchemaVersion(int version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastDbSchemaVersionKey, version);
  }
}
