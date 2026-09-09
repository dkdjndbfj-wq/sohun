import 'dart:io';

import 'package:consumable_tracker_desktop/core/utils/sqlite_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory directory;
  late File legacy;
  late File target;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sohun_legacy_import_');
    legacy = File(p.join(directory.path, 'legacy.sqlite'));
    target = File(p.join(directory.path, 'personal', 'database.sqlite'));
  });
  tearDown(() => directory.delete(recursive: true));

  test('旧程序仍打开 WAL 时搬迁得到独立一致快照，保留原库', () async {
    final original = sqlite.sqlite3.open(legacy.path);
    try {
      original.execute('PRAGMA journal_mode = WAL');
      original.execute('PRAGMA wal_autocheckpoint = 0');
      original.execute('CREATE TABLE inventory (grams INTEGER NOT NULL)');
      original.execute('INSERT INTO inventory VALUES (750)');
      expect(await File('${legacy.path}-wal').length(), greaterThan(0));
      await importLegacyDatabaseIfNeeded(legacy: legacy, target: target);
      original.execute('UPDATE inventory SET grams = 500');
      expect(_grams(target), 750);
      expect(
        original.select('SELECT grams FROM inventory').single['grams'],
        500,
      );
      expect(await File('${target.path}-wal').exists(), isFalse);
      expect(await File('${target.path}-shm').exists(), isFalse);
    } finally {
      original.close();
    }
  });

  test('损坏旧库不会发布半成品目标，修复后可重新搬迁', () async {
    await legacy.writeAsString('not a database');
    await expectLater(
      importLegacyDatabaseIfNeeded(legacy: legacy, target: target),
      throwsA(isA<sqlite.SqliteException>()),
    );
    expect(await target.exists(), isFalse);
    expect(await legacy.readAsString(), 'not a database');
    expect(
      await target.parent.list().where((file) => file is Directory).length,
      0,
    );
    await legacy.delete();
    _createDatabase(legacy, 600);
    await importLegacyDatabaseIfNeeded(legacy: legacy, target: target);
    expect(_grams(target), 600);
  });

  test('已搬迁目标不会被旧库覆盖', () async {
    await target.parent.create(recursive: true);
    _createDatabase(target, 400);
    _createDatabase(legacy, 1000);
    await importLegacyDatabaseIfNeeded(legacy: legacy, target: target);
    expect(_grams(target), 400);
    expect(_grams(legacy), 1000);
  });

  test('同一目标的并发打开合并搬迁且无残留暂存目录', () async {
    _createDatabase(legacy, 700);
    final first = importLegacyDatabaseIfNeeded(legacy: legacy, target: target);
    final second = importLegacyDatabaseIfNeeded(legacy: legacy, target: target);
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(_grams(target), 700);
    expect(
      await target.parent.list().where((file) => file is Directory).length,
      0,
    );
  });

  test('不存在旧库时不创建空目标', () async {
    await importLegacyDatabaseIfNeeded(legacy: legacy, target: target);
    expect(await target.exists(), isFalse);
  });

  test('快照 API 拒绝覆盖已有文件', () async {
    await target.parent.create(recursive: true);
    _createDatabase(legacy, 1000);
    _createDatabase(target, 250);
    await expectLater(
      writeSqliteSnapshot(legacy.path, target.path),
      throwsStateError,
    );
    expect(_grams(target), 250);
  });
}

void _createDatabase(File file, int grams) {
  final db = sqlite.sqlite3.open(file.path);
  try {
    db.execute('CREATE TABLE inventory (grams INTEGER NOT NULL)');
    db.execute('INSERT INTO inventory VALUES (?)', [grams]);
  } finally {
    db.close();
  }
}

int _grams(File file) {
  final db = sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
  try {
    return db.select('SELECT grams FROM inventory').single['grams'] as int;
  } finally {
    db.close();
  }
}
