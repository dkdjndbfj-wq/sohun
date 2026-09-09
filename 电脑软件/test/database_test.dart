import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证 v1→v2 迁移：给 printers 表加 name 列。
/// 这是 s1（数据库迁移加固）的核心测试：模拟旧版本数据库结构、写入旧数据、
/// 再用新代码打开并触发 onUpgrade，验证 name 列被正确添加且旧数据完整保留。
void main() {
  group('数据库迁移 v1→v2', () {
    test('v1 旧库升级后 name 列存在且可写，旧数据完整保留', () async {
      // 1) 构造 v1 旧库（没有 name 列）
      // 使用 NativeDatabase.memory 的 setup 回调，在 drift 打开前用原生 sqlite3 建 v1 表
      // setup 回调接收 sqlite3 的 Database 对象，执行原生 SQL
      final fileDb = NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('''
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
        ''');
          rawDb.execute(
            "INSERT INTO printers(brand, model, channel_count, created_at, updated_at) VALUES('拓竹', 'X1C', 4, 0, 0)",
          );
          rawDb.execute(
            "INSERT INTO consumables(manufacturer, model, material_type, color_hex, total_grams, remaining_grams, created_at, updated_at) VALUES('Polymaker', 'PLA', 'PLA', '#FF0000', 3000.0, 3000.0, 0, 0)",
          );
          // 设置 user_version = 1，drift 打开时会触发 onUpgrade v1→v2
          rawDb.execute('PRAGMA user_version = 1');
        },
      );

      // 2) 用新 AppDatabase 打开（触发迁移 v1→v2）
      final db = AppDatabase.forTesting(fileDb);
      final printers = await db.printerDao.getAllPrinters();
      expect(printers.length, 1);
      expect(printers.first.brand, '拓竹');
      expect(printers.first.model, 'X1C');
      // name 列应存在且为 null（旧数据）
      expect(printers.first.name, isNull);

      // 3) 验证 name 列可写
      await db.printerDao.updatePrinterName(printers.first.id, '工位1');
      final updated = await db.printerDao.getById(printers.first.id);
      expect(updated?.name, '工位1');

      // 4) 耗材旧数据完整
      final consumables = await db.consumableDao.getAll();
      expect(consumables.length, 1);
      expect(consumables.first.manufacturer, 'Polymaker');
      expect(consumables.first.remainingGrams, 3000.0);

      await db.close();
    });
  });

  group('数据库迁移 v8→v16', () {
    test('owner_account 已存在时迁移可重复执行且保留数据', () async {
      final fileDb = NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('''
          CREATE TABLE printers(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uid TEXT NOT NULL DEFAULT '',
            name TEXT,
            brand TEXT NOT NULL,
            model TEXT NOT NULL,
            channel_count INTEGER NOT NULL DEFAULT 1,
            image_asset TEXT,
            is_custom_image INTEGER NOT NULL DEFAULT 0,
            note TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            serial TEXT,
            owner_account TEXT,
            queue_enabled INTEGER NOT NULL DEFAULT 0,
            batch_recognition INTEGER NOT NULL DEFAULT 0
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
            updated_at INTEGER NOT NULL,
            owner_account TEXT,
            density REAL,
            recommended_nozzle_temp REAL,
            hygroscopicity TEXT,
            tray_uuid TEXT,
            rfid_synced_at INTEGER
          );
          CREATE TABLE print_tasks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            updated_at INTEGER NOT NULL DEFAULT 0,
            batch_id TEXT
          );
          CREATE TABLE ams_change_events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            color_hex TEXT
          );
        ''');
          rawDb.execute(
            "INSERT INTO printers(brand, model, owner_account, created_at, updated_at) VALUES('拓竹', 'X1C', 'user@example.com|China', 0, 0)",
          );
          rawDb.execute('PRAGMA user_version = 8');
        },
      );

      final db = AppDatabase.forTesting(fileDb);
      final printers = await db.printerDao.getAllPrinters();

      expect(printers, hasLength(1));
      expect(printers.single.ownerAccount, 'user@example.com|China');
      await db.close();
    });
  });

  group('数据库迁移 v22→v23', () {
    test('新增结果 revision 列且保留旧参数版本事实', () async {
      final fileDb = NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('''
          CREATE TABLE preset_print_results(
            id TEXT PRIMARY KEY,
            community_publication_id TEXT,
            community_version_id TEXT,
            community_revision INTEGER
          );
          CREATE TABLE print_queue(
            id INTEGER PRIMARY KEY AUTOINCREMENT
          );
        ''');
          rawDb.execute(
            "INSERT INTO preset_print_results("
            "id, community_publication_id, community_version_id, community_revision"
            ") VALUES('result-1', 'publication-1', 'version-hash', 7)",
          );
          rawDb.execute('PRAGMA user_version = 22');
        },
      );

      // This deliberately minimal fixture covers only the v23 change. It is
      // not a complete historical database and must not run later migrations
      // which legitimately require the original inventory tables.
      final db = AppDatabase.forTestingAtVersion(fileDb, 23);
      addTearDown(db.close);
      final before = await db.customSelect('''
        SELECT community_publication_id, community_version_id,
               community_revision, community_result_revision
        FROM preset_print_results WHERE id = 'result-1'
      ''').getSingle();

      expect(before.read<String>('community_publication_id'), 'publication-1');
      expect(before.read<String>('community_version_id'), 'version-hash');
      expect(before.read<int>('community_revision'), 7);
      expect(before.readNullable<int>('community_result_revision'), isNull);
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        23,
      );

      await db.customStatement('''
        UPDATE preset_print_results
        SET community_result_revision = 4
        WHERE id = 'result-1'
      ''');
      final after = await db.customSelect('''
        SELECT community_revision, community_result_revision
        FROM preset_print_results WHERE id = 'result-1'
      ''').getSingle();

      expect(after.read<int>('community_revision'), 7);
      expect(after.read<int>('community_result_revision'), 4);
    });
  });

  group('数据库迁移 v23→v24', () {
    test('新增实验队列追踪字段并禁止同一运行重复入队', () async {
      final fileDb = NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('''
          CREATE TABLE print_queue(
            id INTEGER PRIMARY KEY AUTOINCREMENT
          );
        ''');
          rawDb.execute('PRAGMA user_version = 23');
        },
      );

      // Only print_queue is present because this test targets v24, not a
      // full upgrade of every subsystem to the current application schema.
      final db = AppDatabase.forTestingAtVersion(fileDb, 24);
      addTearDown(db.close);
      final columns = await db
          .customSelect('PRAGMA table_info(print_queue)')
          .get();
      final names = columns.map((row) => row.read<String>('name')).toSet();
      expect(
        names,
        containsAll(const [
          'experiment_run_id',
          'experiment_snapshot_id',
          'experiment_application_id',
          'experiment_attribution',
          'artifact_sha256',
        ]),
      );
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        24,
      );

      await db.customStatement(
        "INSERT INTO print_queue(experiment_run_id) VALUES ('run-1')",
      );
      await expectLater(
        db.customStatement(
          "INSERT INTO print_queue(experiment_run_id) VALUES ('run-1')",
        ),
        throwsA(anything),
      );
    });
  });

  test('v55 库缺失 consumables 时拒绝静默升级为 v56', () async {
    final db = AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA user_version = 55'),
      ),
    );
    addTearDown(db.close);
    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('no such table: consumables'),
        ),
      ),
    );
  });

  group('DAO 关键方法', () {
    late AppDatabase db;
    late PrinterDao printerDao;
    late ConsumableDao consumableDao;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      printerDao = db.printerDao;
      consumableDao = db.consumableDao;
    });

    tearDown(() async => db.close());

    test('LAN 连接会同步到工作台且重复保存不会重建通道', () async {
      const first = PrinterConnectionConfig(
        serial: '01S09C123456789',
        host: '192.168.1.100',
        accessCode: '12345678',
        devProductName: 'X1 Carbon',
        displayName: '工作室打印机',
      );

      await printerDao.upsertLanConnection(first);
      final printerId = await printerDao.getPrinterIdBySerial(first.serial);
      expect(printerId, isNotNull);

      final created = await printerDao.getByIdWithChannels(printerId!);
      expect(created?.printer.brand, '拓竹');
      expect(created?.printer.model, 'X1C');
      expect(created?.printer.name, '工作室打印机');
      expect(created?.channels, hasLength(1));
      expect(created?.channels.single.channel.channelIndex, 255);
      expect(created?.channels.single.channel.label, '外挂料位');

      await printerDao.upsertLanConnection(
        const PrinterConnectionConfig(
          serial: '01S09C123456789',
          host: '192.168.1.101',
          accessCode: '87654321',
          devProductName: 'X1 Carbon',
          displayName: '工作室 X1C',
        ),
      );

      final updated = await printerDao.getByIdWithChannels(printerId);
      expect(updated?.printer.name, '工作室 X1C');
      expect(updated?.channels, hasLength(1));
      expect(await printerDao.getAllPrinters(), hasLength(1));
    });

    test('X2D LAN 配置预建左右两个外挂料位', () async {
      await printerDao.upsertLanConnection(
        const PrinterConnectionConfig(
          serial: 'X2D00000000001',
          host: '192.168.1.102',
          accessCode: '12345678',
          devProductName: 'X2D',
        ),
      );

      final printerId = await printerDao.getPrinterIdBySerial('X2D00000000001');
      final created = await printerDao.getByIdWithChannels(printerId!);
      expect(created!.channels.map((item) => item.channel.channelIndex), [
        254,
        255,
      ]);
      expect(created.channels.map((item) => item.channel.label), [
        '外挂料位 L',
        '外挂料位 R',
      ]);
    });

    test('addOneRoll: 不修改 totalGrams，remainingGrams +1000', () async {
      final id = await consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'PLA',
          materialType: const Value('PLA'),
          colorHex: const Value('#FF0000'),
          totalGrams: const Value(3000.0),
          remainingGrams: const Value(1000.0),
        ),
      );
      final next = await consumableDao.addOneRoll(id);
      expect(next, 2000.0);
      final item = await consumableDao.getById(id);
      expect(item?.remainingGrams, 2000.0);
      expect(item?.totalGrams, 3000.0); // totalGrams 不变
    });

    test(
      'deductOneRoll: remainingGrams > totalGrams 时不截断到 totalGrams',
      () async {
        // 模拟补充后 remainingGrams 超过 totalGrams 的场景
        // C1 bug: 旧代码 clamp(0, totalGrams) 会把 3000g 截断回 1000g
        final id = await consumableDao.addConsumable(
          ConsumablesCompanion.insert(
            manufacturer: 'Test',
            model: 'PLA',
            materialType: const Value('PLA'),
            colorHex: const Value('#FF0000'),
            totalGrams: const Value(1000.0),
            remainingGrams: const Value(1000.0),
          ),
        );
        // 补充 2 卷 → remainingGrams = 3000（超过 totalGrams=1000）
        await consumableDao.addOneRoll(id);
        await consumableDao.addOneRoll(id);
        // 扣 1 卷 → 应剩 2000，不应被 clamp 回 1000
        final consumed = await consumableDao.deductOneRoll(id);
        expect(consumed, 1000.0);
        final item = await consumableDao.getById(id);
        expect(item?.remainingGrams, 2000.0); // 修复后应为 2000，旧 bug 会变 1000
      },
    );

    test('deductOneRoll: 剩余不足 1 卷时返回剩余量', () async {
      final id = await consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'PLA',
          materialType: const Value('PLA'),
          colorHex: const Value('#FF0000'),
          totalGrams: const Value(3000.0),
          remainingGrams: const Value(500.0),
        ),
      );
      final consumed = await consumableDao.deductOneRoll(id);
      expect(consumed, 500.0); // 不足 1 卷返回剩余量
      final item = await consumableDao.getById(id);
      expect(item?.remainingGrams, 0.0);
    });

    test('deductOneRoll: 已无库存返回 0', () async {
      final id = await consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'PLA',
          materialType: const Value('PLA'),
          colorHex: const Value('#FF0000'),
          totalGrams: const Value(3000.0),
          remainingGrams: const Value(0.0),
        ),
      );
      final consumed = await consumableDao.deductOneRoll(id);
      expect(consumed, 0.0);
    });

    test('finishChannel: 扣 1 卷 + 解绑通道 + 写日志', () async {
      // 准备：1 台打印机 4 通道 + 1 卷耗材 3 卷库存
      final printerId = await printerDao.addPrinter(
        brand: '拓竹',
        model: 'X1C',
        channelCount: 4,
      );
      final consId = await consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'PLA',
          materialType: const Value('PLA'),
          colorHex: const Value('#FF0000'),
          totalGrams: const Value(3000.0),
          remainingGrams: const Value(3000.0),
        ),
      );
      // 获取通道列表，给通道 0 绑定耗材
      final detail = await printerDao.getByIdWithChannels(printerId);
      expect(detail, isNotNull);
      final channelId = detail!.channels.first.channel.id;
      await printerDao.bindConsumable(channelId, consId);

      // 执行 finishChannel
      await printerDao.finishChannel(channelId);

      // 验证：耗材扣 1 卷
      final cons = await consumableDao.getById(consId);
      expect(cons?.remainingGrams, 2000.0);

      // 验证：通道已解绑
      final detail2 = await printerDao.getByIdWithChannels(printerId);
      final ch = detail2!.channels.firstWhere((c) => c.channel.id == channelId);
      expect(ch.channel.consumableId, isNull);

      // 验证：日志已写
      final logs = await db.usageLogDao.getAll();
      expect(logs.length, 1);
      expect(logs.first.consumableId, consId);
      expect(logs.first.consumedGrams, 1000.0);
      expect(logs.first.finished, true);
    });

    test('getBoundConsumableCounts: 跨打印机全局计数', () async {
      // 2 台打印机，各 4 通道
      final p1 = await printerDao.addPrinter(
        brand: 'A',
        model: 'X1',
        channelCount: 4,
      );
      final p2 = await printerDao.addPrinter(
        brand: 'B',
        model: 'X1',
        channelCount: 4,
      );
      // 1 卷耗材 3 卷库存
      final consId = await consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'PLA',
          materialType: const Value('PLA'),
          colorHex: const Value('#FF0000'),
          totalGrams: const Value(3000.0),
          remainingGrams: const Value(3000.0),
        ),
      );
      // 给 p1 的 2 个通道 + p2 的 1 个通道都绑定该耗材（共 3 个通道 = 3 卷）
      final d1 = await printerDao.getByIdWithChannels(p1);
      final d2 = await printerDao.getByIdWithChannels(p2);
      await printerDao.bindConsumable(d1!.channels[0].channel.id, consId);
      await printerDao.bindConsumable(d1.channels[1].channel.id, consId);
      await printerDao.bindConsumable(d2!.channels[0].channel.id, consId);

      final counts = await printerDao.getBoundConsumableCounts();
      expect(counts[consId], 3); // 跨打印机全局计数 = 3
    });

    test('卷数限额逻辑：3 卷库存绑 3 通道后第 4 个通道应被排除', () async {
      final p1 = await printerDao.addPrinter(
        brand: 'A',
        model: 'X1',
        channelCount: 4,
      );
      final consId = await consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'PLA',
          materialType: const Value('PLA'),
          colorHex: const Value('#FF0000'),
          totalGrams: const Value(3000.0),
          remainingGrams: const Value(3000.0),
        ),
      );
      final d1 = await printerDao.getByIdWithChannels(p1);
      // 绑 3 个通道
      await printerDao.bindConsumable(d1!.channels[0].channel.id, consId);
      await printerDao.bindConsumable(d1.channels[1].channel.id, consId);
      await printerDao.bindConsumable(d1.channels[2].channel.id, consId);

      final counts = await printerDao.getBoundConsumableCounts();
      final bound = counts[consId] ?? 0;
      final rolls = (3000.0 / 1000.0).round();
      expect(bound, 3);
      expect(rolls, 3);
      // 第 4 个通道：bound(3) < rolls(3) 为 false，应被排除
      expect(bound < rolls, false);
    });
  });
}
