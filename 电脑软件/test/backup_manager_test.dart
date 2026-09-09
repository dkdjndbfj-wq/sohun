import 'dart:convert';
import 'dart:io';

import 'package:consumable_tracker_desktop/core/utils/backup_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    appDirectory = await Directory.systemTemp.createTemp('backup_restore_');
    BackupManager.debugApplicationDocumentsDirectory = appDirectory;
  });

  tearDown(() async {
    BackupManager.debugApplicationDocumentsDirectory = null;
    if (await appDirectory.exists()) {
      await appDirectory.delete(recursive: true);
    }
  });

  test('恢复普通偏好时保留当前设备凭据并忽略备份中的敏感键', () async {
    SharedPreferences.setMockInitialValues({
      'obsolete_key': 'remove-me',
      'app_auth_session_primary': 'dpapi:current-session',
      'printer_connections_dpapi_v1': 'dpapi:current-printers',
      'bambu_cloud_accounts': 'encrypted-current-cloud',
    });
    final backup = await Directory('${appDirectory.path}/source').create();
    await File('${backup.path}/prefs.json').writeAsString(
      jsonEncode({
        'restored_key': 'restored-value',
        'app_auth_session_primary': 'foreign-session',
        'printer_connections_dpapi_v1': 'foreign-printers',
        'bambu_cloud_accounts': 'foreign-cloud',
      }),
    );

    expect(await BackupManager.restore(backup.path), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.get('obsolete_key'), isNull);
    expect(prefs.getString('restored_key'), 'restored-value');
    expect(
      prefs.getString('app_auth_session_primary'),
      'dpapi:current-session',
    );
    expect(
      prefs.getString('printer_connections_dpapi_v1'),
      'dpapi:current-printers',
    );
    expect(prefs.getString('bambu_cloud_accounts'), 'encrypted-current-cloud');
  });

  test('无效数据库备份在关闭当前数据库之前被拒绝', () async {
    final target = File('${appDirectory.path}/consumable_tracker.sqlite');
    await target.writeAsString('original-database');
    final backup = await Directory('${appDirectory.path}/invalid').create();
    await File(
      '${backup.path}/consumable_tracker.sqlite',
    ).writeAsString('not-a-sqlite-database');
    var closeCalls = 0;

    await expectLater(
      BackupManager.restore(
        backup.path,
        ensureDbClosed: () async => closeCalls++,
      ),
      throwsA(isA<FormatException>()),
    );

    expect(closeCalls, 0);
    expect(await target.readAsString(), 'original-database');
  });

  test('数据库文件替换中途失败会把原数据库移回目标位置', () async {
    final target = File('${appDirectory.path}/consumable_tracker.sqlite');
    await target.writeAsString('original-database');
    final backup = await Directory('${appDirectory.path}/rollback').create();
    _createDatabase('${backup.path}/consumable_tracker.sqlite');
    var closed = false;

    await expectLater(
      BackupManager.restore(
        backup.path,
        ensureDbClosed: () async {
          closed = true;
          // Simulate antivirus removing the staged file before replacement.
          final staged = await appDirectory.list().firstWhere(
            (file) => file.path.contains('.restore_tmp_'),
          );
          await staged.delete();
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(closed, isTrue);
    expect(await target.readAsString(), 'original-database');
    final leftovers = await appDirectory
        .list()
        .map((entry) => entry.path)
        .where(
          (path) =>
              path.contains('.pre_restore_') || path.contains('.restore_tmp_'),
        )
        .toList();
    expect(leftovers, isEmpty);
  });

  test('关闭数据库失败时保留尚未替换的原数据库及 WAL', () async {
    final target = File('${appDirectory.path}/consumable_tracker.sqlite');
    final wal = File('${target.path}-wal');
    await target.writeAsString('original-database');
    await wal.writeAsString('original-wal');
    final backup = await Directory(
      '${appDirectory.path}/close_failure',
    ).create();
    _createDatabase('${backup.path}/consumable_tracker.sqlite');

    await expectLater(
      BackupManager.restore(
        backup.path,
        ensureDbClosed: () async => throw StateError('cannot close database'),
      ),
      throwsStateError,
    );

    expect(await target.readAsString(), 'original-database');
    expect(await wal.readAsString(), 'original-wal');
  });

  test('只有 SQLite 文件头但内容损坏的备份也在关闭数据库前被拒绝', () async {
    final target = File('${appDirectory.path}/consumable_tracker.sqlite');
    await target.writeAsString('original-database');
    final backup = await Directory('${appDirectory.path}/corrupt').create();
    await File('${backup.path}/consumable_tracker.sqlite').writeAsBytes([
      ...utf8.encode('SQLite format 3\u0000'),
      ...List<int>.filled(128, 0),
    ]);
    var closed = false;
    await expectLater(
      BackupManager.restore(
        backup.path,
        ensureDbClosed: () async => closed = true,
      ),
      throwsA(isA<sqlite.SqliteException>()),
    );
    expect(closed, isFalse);
    expect(await target.readAsString(), 'original-database');
  });

  test('在线备份包含尚未 checkpoint 的 WAL 数据并能独立恢复', () async {
    final target = File('${appDirectory.path}/consumable_tracker.sqlite');
    final live = sqlite.sqlite3.open(target.path);
    var closed = false;
    addTearDown(() {
      if (!closed) live.close();
    });
    live.execute('PRAGMA journal_mode = WAL');
    live.execute('PRAGMA wal_autocheckpoint = 0');
    live.execute('CREATE TABLE inventory (grams INTEGER NOT NULL)');
    live.execute('INSERT INTO inventory VALUES (750)');
    expect(await File('${target.path}-wal').length(), greaterThan(0));

    final backup = await BackupManager.createBackup(label: '在线');
    expect(
      await File('$backup/consumable_tracker.sqlite-wal').exists(),
      isFalse,
    );
    live.execute('UPDATE inventory SET grams = 500');

    expect(
      await BackupManager.restore(
        backup,
        ensureDbClosed: () async {
          live.close();
          closed = true;
        },
      ),
      isTrue,
    );
    final restored = sqlite.sqlite3.open(target.path);
    try {
      expect(
        restored.select('SELECT grams FROM inventory').single['grams'],
        750,
      );
      expect(restored.select('PRAGMA quick_check').single.values.single, 'ok');
    } finally {
      restored.close();
    }
  });

  test('失败的备份不进入列表，安全备份不会删除选中的最旧备份', () async {
    await expectLater(
      BackupManager.createBackup(
        preCopyHook: () async => throw StateError('busy'),
      ),
      throwsStateError,
    );
    expect(await BackupManager.listBackups(), isEmpty);
    final unrelated = await Directory(
      '${await BackupManager.backupDirPath}/notes',
    ).create();
    final first = await BackupManager.createBackup(label: 'oldest');
    for (var i = 0; i < 4; i++) {
      await BackupManager.createBackup(label: '$i');
    }
    await BackupManager.createBackup(label: '恢复前', pruneOldBackups: false);
    expect(await Directory(first).exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    expect(await BackupManager.listBackups(), hasLength(6));
  });
}

void _createDatabase(String path) {
  final db = sqlite.sqlite3.open(path);
  try {
    db.execute('CREATE TABLE inventory (grams INTEGER NOT NULL)');
    db.execute('INSERT INTO inventory VALUES (750)');
  } finally {
    db.close();
  }
}
