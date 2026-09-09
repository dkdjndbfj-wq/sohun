import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/migration_manager.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('每个数据库分别完成迁移审计，并发调用共享结果', () async {
    final first = AppDatabase.forTesting(NativeDatabase.memory());
    final second = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(first.close);
    addTearDown(second.close);
    await Future.wait([
      MigrationManager.migrate(first),
      MigrationManager.migrate(first),
      MigrationManager.migrate(second),
    ]);
    for (final db in [first, second]) {
      expect(
        await MigrationManager.getAppliedVersion(db),
        AppDatabase.kSchemaVersion,
      );
    }
  });

  test('审计失败只向调用方抛出一次错误，修复后可以重试', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement(
      'CREATE TABLE schema_migrations (wrong_column INTEGER)',
    );
    await expectLater(MigrationManager.migrate(db), throwsA(anything));
    await db.customStatement('DROP TABLE schema_migrations');
    await MigrationManager.migrate(db);
    expect(
      await MigrationManager.getAppliedVersion(db),
      AppDatabase.kSchemaVersion,
    );
  });
}
