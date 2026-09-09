import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Write a new, self-contained SQLite snapshot, including committed WAL data.
/// Callers must use a private staging path, then publish the completed file.
Future<void> writeSqliteSnapshot(String source, String target) =>
    Isolate.run(() async {
      if (await File(target).exists()) {
        throw StateError('拒绝覆盖已有数据库快照');
      }
      final sourceDb = sqlite.sqlite3.open(
        source,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        final targetDb = sqlite.sqlite3.open(target);
        try {
          sourceDb.execute('PRAGMA busy_timeout = 5000');
          await sourceDb.backup(targetDb, nPage: 128).drain<void>();
          // The backup may inherit a WAL-mode database header. Normalize the
          // completed standalone copy so reopening it does not create sidecars
          // or require write access beside an otherwise read-only backup.
          final journal = targetDb.select('PRAGMA journal_mode = DELETE');
          if (journal.single.values.single != 'delete') {
            throw const FormatException('数据库快照无法转换为独立文件');
          }
          final check = targetDb.select('PRAGMA quick_check');
          if (check.length != 1 || check.single.values.single != 'ok') {
            throw const FormatException('数据库备份完整性检查失败');
          }
        } finally {
          targetDb.close();
        }
      } finally {
        sourceDb.close();
      }
    });

final _legacyImports = <String, Future<void>>{};

/// Import the pre-product-separation database without modifying the original.
/// An interrupted copy remains only in a temporary directory: the target name
/// is installed atomically after verification, so next startup can retry.
Future<void> importLegacyDatabaseIfNeeded({
  required File legacy,
  required File target,
}) {
  final key = p.normalize(target.absolute.path);
  return _legacyImports[key] ??= _importLegacy(legacy, target).whenComplete(() {
    _legacyImports.remove(key);
  });
}

Future<void> _importLegacy(File legacy, File target) async {
  if (await target.exists() || !await legacy.exists()) return;
  await target.parent.create(recursive: true);
  // Keep the lock inode after closing; deleting it could allow a third process
  // to bypass a second process already waiting on the previous inode.
  final lock = await File(
    '${target.path}.migration.lock',
  ).open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.blockingExclusive);
    try {
      if (await target.exists()) return;
      final staging = await target.parent.createTemp('.legacy_import_');
      try {
        final snapshot = File(p.join(staging.path, 'database.sqlite'));
        await writeSqliteSnapshot(legacy.path, snapshot.path);
        if (await target.exists()) return;
        await snapshot.rename(target.path);
      } finally {
        if (await staging.exists()) await staging.delete(recursive: true);
      }
    } finally {
      await lock.unlock();
    }
  } finally {
    await lock.close();
  }
}
