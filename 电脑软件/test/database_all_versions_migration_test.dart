@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';

import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('released schema migrations', () {
    Directory? tempDirectory;
    late Map<int, File> snapshots;
    final snapshotsFinished = Completer<void>();
    final migrationsFinished = <Future<void>>[];

    setUpAll(() async {
      try {
        final directory = await Directory.systemTemp.createTemp(
          'consumable_schema_migrations_',
        );
        tempDirectory = directory;
        snapshots = await _createHistoricalSnapshots(directory);
      } finally {
        snapshotsFinished.complete();
      }
    });
    tearDownAll(() async {
      // Timing out a setup does not cancel its Future. Let it close any open
      // database before removing the shared historical snapshots.
      await snapshotsFinished.future;
      await Future.wait(migrationsFinished);
      final directory = tempDirectory;
      if (directory != null) await directory.delete(recursive: true);
    });

    for (var version = 1; version <= AppDatabase.kSchemaVersion; version++) {
      final sourceVersion = version;
      test('schema v$sourceVersion upgrades to the current schema', () async {
        final migrationFinished = Completer<void>();
        migrationsFinished.add(migrationFinished.future);
        File? upgradeFile;
        addTearDown(() async {
          // Each independent case owns its copy. A timeout does not cancel its
          // migration, so never remove the file until the database is closed.
          await migrationFinished.future;
          final file = upgradeFile;
          if (file != null) await file.delete();
        });
        try {
          final file = await snapshots[sourceVersion]!.copy(
            '${tempDirectory!.path}/upgrade_v$sourceVersion.sqlite',
          );
          upgradeFile = file;
          await _verifyUpgrade(file, sourceVersion);
        } finally {
          migrationFinished.complete();
        }
      });
    }
  });
}

Future<Map<int, File>> _createHistoricalSnapshots(
  Directory tempDirectory,
) async {
  final opened = <AppDatabase>[];
  try {
    final evolvingFile = File('${tempDirectory.path}/evolving.sqlite');
    final snapshots = <int, File>{};

    final v1 = AppDatabase.forTestingAtVersion(
      NativeDatabase(
        evolvingFile,
        setup: (rawDb) {
          rawDb.execute(_v1Schema);
          rawDb.execute(
            "INSERT INTO printers(brand, model, channel_count, created_at, updated_at) "
            "VALUES('Test Brand', 'Test Model', 4, 1, 1)",
          );
          rawDb.execute(
            "INSERT INTO consumables(manufacturer, model, material_type, color_hex, "
            "total_grams, remaining_grams, created_at, updated_at) "
            "VALUES('Test Maker', 'PLA', 'PLA', '#112233', 1000, 750, 1, 1)",
          );
          rawDb.execute('PRAGMA user_version = 1');
        },
      ),
      1,
    );
    opened.add(v1);
    await v1.customSelect('SELECT 1').getSingle();
    await v1.close();
    opened.remove(v1);
    snapshots[1] = await evolvingFile.copy(
      '${tempDirectory.path}/schema_v1.sqlite',
    );

    for (var target = 2; target <= AppDatabase.kSchemaVersion; target++) {
      final staged = AppDatabase.forTestingAtVersion(
        NativeDatabase(evolvingFile),
        target,
      );
      opened.add(staged);
      final integrity = await staged
          .customSelect('PRAGMA integrity_check')
          .getSingle();
      expect(integrity.data.values.single, 'ok', reason: 'schema v$target');
      final count = await staged
          .customSelect('SELECT COUNT(*) AS c FROM printers')
          .getSingle();
      expect(count.read<int>('c'), 1);
      if (target == 35) {
        await staged.customInsert(
          'INSERT INTO consumables '
          '(uid, manufacturer, model, material_type, color_hex, total_grams, '
          'remaining_grams, created_at, updated_at, inventory_scope, farm_workspace_id) '
          "VALUES ('farm-migrate', 'Farm', 'PLA', 'PLA', '#FFFFFF', 2000, "
          "1400, 1, 1, 'farm', 'farm-migration')",
        );
        final farmConsumable = await staged
            .customSelect(
              "SELECT id FROM consumables WHERE uid = 'farm-migrate'",
            )
            .getSingle();
        await staged.customInsert(
          'INSERT INTO printer_channels '
          '(printer_id, channel_index, label, consumable_id, '
          'loaded_remaining_grams, updated_at) '
          'VALUES (1, 0, ?, ?, 400, 1)',
          variables: [
            const Variable('AMS 1-1'),
            Variable(farmConsumable.read<int>('id')),
          ],
        );
      }
      await staged.close();
      opened.remove(staged);
      snapshots[target] = await evolvingFile.copy(
        '${tempDirectory.path}/schema_v$target.sqlite',
      );
    }
    return snapshots;
  } finally {
    for (final database in opened) {
      await database.close();
    }
  }
}

Future<void> _verifyUpgrade(File upgradeFile, int sourceVersion) async {
  final upgraded = AppDatabase.forTesting(NativeDatabase(upgradeFile));
  try {
    final version = await upgraded
        .customSelect('PRAGMA user_version')
        .getSingle();
    final integrity = await upgraded
        .customSelect('PRAGMA integrity_check')
        .getSingle();
    final printer = await upgraded
        .customSelect('SELECT brand, model FROM printers')
        .getSingle();
    final consumable = await upgraded
        .customSelect(
          'SELECT uid, manufacturer, remaining_grams FROM consumables '
          'WHERE id = 1',
        )
        .getSingle();
    final queueColumns = await upgraded
        .customSelect('PRAGMA table_info(print_queue)')
        .get();
    final queueColumnNames = queueColumns
        .map((row) => row.read<String>('name'))
        .toSet();
    final channelColumns = await upgraded
        .customSelect('PRAGMA table_info(printer_channels)')
        .get();
    final channelColumnNames = channelColumns
        .map((row) => row.read<String>('name'))
        .toSet();
    final plateColumns = await upgraded
        .customSelect('PRAGMA table_info(studio_production_plates)')
        .get();
    final plateColumnNames = plateColumns
        .map((row) => row.read<String>('name'))
        .toSet();

    expect(
      version.read<int>('user_version'),
      AppDatabase.kSchemaVersion,
      reason: 'upgrade from v$sourceVersion',
    );
    expect(integrity.data.values.single, 'ok');
    expect(printer.read<String>('brand'), 'Test Brand');
    expect(printer.read<String>('model'), 'Test Model');
    expect(consumable.read<String>('manufacturer'), 'Test Maker');
    expect(consumable.read<double>('remaining_grams'), 750);
    expect(
      consumable.read<String>('uid'),
      isNotEmpty,
      reason: 'legacy inventory needs a stable cloud mapping id',
    );
    expect(queueColumnNames, contains('ams_mapping_json'));
    expect(queueColumnNames, contains('studio_work_order_id'));
    expect(queueColumnNames, contains('auto_continue'));
    expect(queueColumnNames, contains('batch_id'));
    expect(queueColumnNames, contains('batch_index'));
    expect(queueColumnNames, contains('batch_total'));
    expect(channelColumnNames, contains('farm_roll_paused'));
    expect(plateColumnNames, contains('auto_eject_enabled'));
    if (sourceVersion >= 35) {
      final farmInventory = await upgraded
          .customSelect(
            "SELECT remaining_grams FROM consumables WHERE uid = 'farm-migrate'",
          )
          .getSingle();
      expect(
        farmInventory.read<double>('remaining_grams'),
        1000,
        reason: 'loaded 400g roll must be removed from old aggregate stock',
      );
    }
  } finally {
    await upgraded.close();
  }
}

const _v1Schema = '''
CREATE TABLE printers(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uid TEXT NOT NULL DEFAULT '',
  brand TEXT NOT NULL,
  model TEXT NOT NULL,
  channel_count INTEGER NOT NULL DEFAULT 1,
  image_asset TEXT,
  is_custom_image INTEGER NOT NULL DEFAULT 0,
  note TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE printer_channels(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  printer_id INTEGER NOT NULL,
  channel_index INTEGER NOT NULL,
  label TEXT NOT NULL DEFAULT 'A',
  consumable_id INTEGER,
  updated_at INTEGER NOT NULL
);
CREATE TABLE consumables(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uid TEXT NOT NULL DEFAULT '',
  manufacturer TEXT NOT NULL,
  model TEXT NOT NULL,
  material_type TEXT NOT NULL DEFAULT 'PLA',
  color_hex TEXT NOT NULL DEFAULT '#FFFFFF',
  color_name TEXT,
  total_grams REAL NOT NULL DEFAULT 1000.0,
  remaining_grams REAL NOT NULL DEFAULT 1000.0,
  batch_no TEXT,
  purchase_date INTEGER,
  note TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE usage_logs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  printer_id INTEGER,
  channel_index INTEGER NOT NULL DEFAULT 0,
  consumable_id INTEGER,
  consumed_grams REAL NOT NULL DEFAULT 0,
  finished INTEGER NOT NULL DEFAULT 1,
  note TEXT,
  logged_at INTEGER NOT NULL
);
''';
