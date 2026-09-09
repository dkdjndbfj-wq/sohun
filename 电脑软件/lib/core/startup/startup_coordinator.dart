import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../data/database/database.dart';
import '../../data/database/migration_manager.dart';
import '../../data/external/printer/bambu_cloud_client.dart';
import '../../data/prefs/app_version_prefs.dart';
import '../../data/prefs/slicer_prefs.dart';
import '../services/error_logger.dart';
import '../services/product_issue_collector.dart';
import '../utils/backup_manager.dart';

enum StartupPhase {
  preparing,
  checkingData,
  backingUp,
  openingDatabase,
  migrating,
  startingServices,
  ready,
}

class StartupProgress {
  const StartupProgress({
    required this.phase,
    required this.value,
    required this.label,
  });

  final StartupPhase phase;
  final double value;
  final String label;
}

class StartupResult {
  const StartupResult(this.database);

  final AppDatabase database;
}

class StartupFailure implements Exception {
  const StartupFailure({required this.title, required this.message});

  final String title;
  final String message;

  @override
  String toString() => '$title: $message';
}

typedef StartupProgressCallback = void Function(StartupProgress progress);

class StartupCoordinator {
  static RawReceivePort? _isolateErrorPort;

  Future<StartupResult> initialize({
    required StartupProgressCallback onProgress,
    AppDatabase? database,
  }) async {
    onProgress(
      const StartupProgress(
        phase: StartupPhase.preparing,
        value: 0.08,
        label: '正在准备工作台…',
      ),
    );
    await _loadSlicerOverrides();

    var lastSchema = 0;
    var hasExistingDatabase = false;
    var backupCreated = false;
    onProgress(
      const StartupProgress(
        phase: StartupPhase.checkingData,
        value: 0.2,
        label: '正在检查本地数据…',
      ),
    );
    try {
      lastSchema = await AppVersionPrefs.getLastDbSchemaVersion();
      hasExistingDatabase = await BackupManager.databaseExists;
      if (hasExistingDatabase &&
          (lastSchema == 0 || lastSchema < AppDatabase.kSchemaVersion)) {
        onProgress(
          const StartupProgress(
            phase: StartupPhase.backingUp,
            value: 0.34,
            label: '正在创建升级前备份…',
          ),
        );
        await BackupManager.createBackup(label: '升级前自动备份');
        backupCreated = true;
      }
    } catch (error, stackTrace) {
      debugPrint('升级前自动备份失败: $error\n$stackTrace');
      throw StartupFailure(
        title: '无法安全升级数据',
        message: '升级前备份失败。为避免数据损坏，应用已停止启动。\n\n$error',
      );
    }

    onProgress(
      const StartupProgress(
        phase: StartupPhase.openingDatabase,
        value: 0.48,
        label: '正在打开耗材数据库…',
      ),
    );
    final appDatabase = database ?? AppDatabase();
    final migrationStartedAt = DateTime.now();
    try {
      await appDatabase.customSelect('SELECT 1').get();
      onProgress(
        const StartupProgress(
          phase: StartupPhase.migrating,
          value: 0.68,
          label: '正在校验并升级数据…',
        ),
      );
      await MigrationManager.migrate(appDatabase);
      await AppVersionPrefs.migrateIfNeeded();
      await AppVersionPrefs.setLastDbSchemaVersion(
        AppDatabase.kSchemaVersion,
      );

      onProgress(
        const StartupProgress(
          phase: StartupPhase.startingServices,
          value: 0.86,
          label: '正在启动诊断与提醒服务…',
        ),
      );
      ErrorLogger.init(appDatabase);
      ProductIssueCollector.init(appDatabase);
      if (hasExistingDatabase &&
          (lastSchema == 0 || lastSchema < AppDatabase.kSchemaVersion)) {
        await ProductIssueCollector.record(
          category: ProductIssueCategory.upgrade,
          outcome: 'database_migration_succeeded',
          durationMs:
              DateTime.now().difference(migrationStartedAt).inMilliseconds,
          details: {
            'fromSchema': lastSchema,
            'toSchema': AppDatabase.kSchemaVersion,
            'backupCreated': backupCreated,
            'phase': 'database_migration',
          },
        );
      }
      await ProductIssueCollector.recordVersionTransition();
      await ProductIssueCollector.startSession();
      _installGlobalErrorHandlers();
    } catch (error, stackTrace) {
      debugPrint('数据库迁移失败: $error');
      try {
        ErrorLogger.init(appDatabase);
        ProductIssueCollector.init(appDatabase);
        await ProductIssueCollector.record(
          category: ProductIssueCategory.upgrade,
          outcome: 'database_migration_failed',
          level: ErrorLevel.error,
          durationMs:
              DateTime.now().difference(migrationStartedAt).inMilliseconds,
          details: {
            'fromSchema': lastSchema,
            'toSchema': AppDatabase.kSchemaVersion,
            'backupCreated': backupCreated,
            'phase': 'database_migration',
          },
        );
        ErrorLogger.log(
          error,
          stackTrace,
          source: 'database',
          context: {'phase': 'migration'},
        );
      } catch (_) {}
      await appDatabase.close();
      throw StartupFailure(
        title: '数据升级未完成',
        message: '数据库升级失败。应用未继续打开旧数据，请从自动备份恢复后重试。\n\n$error',
      );
    }

    onProgress(
      const StartupProgress(
        phase: StartupPhase.ready,
        value: 1,
        label: '准备完成',
      ),
    );
    return StartupResult(appDatabase);
  }

  Future<void> _loadSlicerOverrides() async {
    try {
      final studioVersion = await SlicerPrefs.getBambuStudioVersionOverride();
      BambuClientVersion.setBambuStudioOverride(studioVersion);
      final networkAgentVersion =
          await SlicerPrefs.getNetworkAgentStudioVersionOverride();
      BambuClientVersion.setNetworkAgentStudioOverride(networkAgentVersion);
    } catch (error) {
      debugPrint('加载 BambuStudio 版本号覆盖失败: $error');
    }
  }

  void _installGlobalErrorHandlers() {
    ErrorLogger.installGlobalHandler();
    if (_isolateErrorPort != null) return;
    _isolateErrorPort = RawReceivePort((dynamic raw) {
      try {
        final list = raw as List;
        final error = list[0];
        final stack = list[1] is String
            ? StackTrace.fromString(list[1] as String)
            : StackTrace.current;
        ErrorLogger.log(error, stack, source: 'isolate');
      } catch (_) {}
    });
    Isolate.current.addErrorListener(_isolateErrorPort!.sendPort);
  }
}
