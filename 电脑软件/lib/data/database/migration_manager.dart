import 'database.dart';

/// Records the latest Drift schema that opened successfully.
///
/// [AppDatabase.migration] is the only authority that changes SQLite tables,
/// columns, indexes, or data. This coordinator runs after Drift has completed
/// that work and keeps an operational audit record for diagnostics.
class MigrationManager {
  MigrationManager._();

  static const int currentVersion = AppDatabase.kSchemaVersion;
  // The app normally owns one database, but restore/import and tests can open
  // another AppDatabase in the same process.  A single global completer made
  // the second database skip its schema audit entirely.  Key the in-flight
  // operation by database identity instead.
  static Expando<Future<void>> _migrations = Expando<Future<void>>();

  /// Restores replace the database under the running process, so the audit
  /// coordinator must be allowed to inspect the newly opened database again.
  static void resetForDatabaseReopen() {
    _migrations = Expando<Future<void>>();
  }

  static Future<void> migrate(AppDatabase db) =>
      _migrations[db] ??= _migrate(db);

  static Future<void> _migrate(AppDatabase db) async {
    try {
      final appliedVersion = await _getAppliedVersion(db);
      if (appliedVersion < currentVersion) {
        await db.transaction(() => _recordMigration(db, currentVersion));
      }
    } catch (_) {
      // All callers observe the same future. Completing a separate, unobserved
      // completer with an error used to raise an uncaught asynchronous error.
      _migrations[db] = null;
      rethrow;
    }
  }

  static Future<void> _ensureAuditTable(AppDatabase db) async {
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at INTEGER NOT NULL,
        description TEXT
      );
    ''');
  }

  static Future<int> _getAppliedVersion(AppDatabase db) async {
    await _ensureAuditTable(db);
    final result = await db
        .customSelect(
          'SELECT MAX(version) AS max_version FROM schema_migrations',
        )
        .getSingle();
    return result.readNullable<int>('max_version') ?? 0;
  }

  static Future<void> _recordMigration(AppDatabase db, int version) async {
    await db.customStatement(
      'INSERT OR REPLACE INTO schema_migrations '
      '(version, applied_at, description) VALUES (?, ?, ?)',
      [
        version,
        DateTime.now().millisecondsSinceEpoch,
        'Drift schema v$version opened successfully',
      ],
    );
  }

  static Future<int> getAppliedVersion(AppDatabase db) =>
      _getAppliedVersion(db);
}
