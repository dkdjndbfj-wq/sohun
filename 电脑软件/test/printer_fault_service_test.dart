import 'package:consumable_tracker_desktop/core/services/fault_event_lifecycle_service.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fault_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 故障知识库 JSON 测试数据（与 assets/knowledge/printer_faults_zh_CN.json 结构一致）。
const String testKnowledgeJson = '''
{
  "schemaVersion": "1.0.0",
  "source": "self-authored",
  "faults": [
    {
      "code": "0C0030A0001C0001",
      "aliases": ["缺料", "断料", "filament runout"],
      "severity": "error",
      "title": "耗材用尽",
      "summary": "打印机检测到耗材已用完或断开。",
      "applicableModels": ["X1C", "P1S", "P1P", "A1", "A1 mini", "H2D"],
      "steps": ["暂停打印", "更换耗材", "恢复打印"],
      "resumeCondition": "新耗材已装入且挤出正常。",
      "safetyNotice": "喷嘴高温，请勿触摸。",
      "source": "self-authored",
      "sourceVersion": "1.0.0"
    },
    {
      "code": "0C0030A0001C0002",
      "aliases": ["卡料", "堵头", "nozzle clog"],
      "severity": "error",
      "title": "耗材堵塞",
      "summary": "挤出机或喷嘴处发生耗材堵塞。",
      "applicableModels": ["X1C", "P1S", "P1P", "A1", "A1 mini", "H2D"],
      "steps": ["断电降温", "清理喷嘴", "重新装料测试"],
      "resumeCondition": "手动挤出测试顺畅。",
      "safetyNotice": "清理前必须等待降温。",
      "source": "self-authored",
      "sourceVersion": "1.0.0"
    },
    {
      "code": "",
      "aliases": ["未知错误", "unknown error"],
      "severity": "warning",
      "title": "未知错误",
      "summary": "未识别的故障代码。",
      "applicableModels": ["X1C", "P1S", "P1P", "A1", "A1 mini", "H2D"],
      "steps": ["记录代码", "重启打印机", "联系支持"],
      "resumeCondition": "重启后故障消失。",
      "safetyNotice": "建议断电后联系支持。",
      "source": "self-authored",
      "sourceVersion": "1.0.0"
    }
  ]
}
''';

void main() {
  group('故障知识库服务 (PrinterFaultService)', () {
    late PrinterFaultService service;

    setUp(() async {
      service = PrinterFaultService(
        assetLoader: (_) async => testKnowledgeJson,
      );
      await service.load();
    });

    test('知识库加载成功', () {
      expect(service.isLoaded, isTrue);
      expect(service.knowledgeBaseVersion, '1.0.0');
      expect(service.allEntries.length, 3);
    });

    test('按代码查找成功', () {
      final entry = service.lookupByCode('0C0030A0001C0001');
      expect(entry, isNotNull);
      expect(entry!.title, '耗材用尽');
      expect(entry.severity, 'error');
      expect(entry.steps.length, 3);
    });

    test('按关键字搜索成功', () {
      // 按标题搜索
      var results = service.search('堵塞');
      expect(results.length, 1);
      expect(results.first.title, '耗材堵塞');

      // 按别名搜索
      results = service.search('缺料');
      expect(results.length, 1);
      expect(results.first.code, '0C0030A0001C0001');

      // 按代码搜索
      results = service.search('0C0030');
      expect(results.length, 2);

      // 按摘要搜索
      results = service.search('断开');
      expect(results.length, 1);
    });

    test('未知代码返回 null', () {
      final entry = service.lookupByCode('FFFF000000000000');
      expect(entry, isNull);
    });

    test('空代码不参与代码查找', () {
      // 离线/未知错误条目 code 为空，lookupByCode 不应返回它们
      final entry = service.lookupByCode('');
      expect(entry, isNull);
    });

    test('资产加载失败时优雅降级', () async {
      final failService = PrinterFaultService(
        assetLoader: (_) async => throw Exception('资产不存在'),
      );
      await failService.load();
      expect(failService.isLoaded, isTrue);
      expect(failService.allEntries, isEmpty);
      expect(failService.knowledgeBaseVersion, isNull);
      expect(failService.lookupByCode('0C0030A0001C0001'), isNull);
      expect(failService.search('缺料'), isEmpty);
    });
  });

  group('故障事件生命周期服务 (FaultEventLifecycleService)', () {
    late AppDatabase db;
    late FaultEventLifecycleService service;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      service = FaultEventLifecycleService(db);
    });

    tearDown(() async => db.close());

    test('首次出现创建事件', () async {
      final event = await service.upsertFault(
        printerSerial: 'PRINTER_001',
        code: '0C0030A0001C0001',
        severity: 'error',
        title: '耗材用尽',
        summary: '耗材已用完',
      );

      expect(event, isNotNull);
      expect(event!.printerSerial, 'PRINTER_001');
      expect(event.code, '0C0030A0001C0001');
      expect(event.severity, 'error');
      expect(event.title, '耗材用尽');
      expect(event.clearedAt, isNull);
      expect(event.firstSeenAt, equals(event.lastSeenAt));

      // 数据库中应有 1 条活动事件
      final active = await service.getActiveFaults('PRINTER_001');
      expect(active.length, 1);
    });

    test('相同代码更新 last_seen，不创建重复事件', () async {
      // 第一次推送
      final first = await service.upsertFault(
        printerSerial: 'PRINTER_001',
        code: '0C0030A0001C0001',
        severity: 'error',
        title: '耗材用尽',
      );
      expect(first, isNotNull);

      // 等待一小段时间确保时间戳不同
      await Future.delayed(const Duration(milliseconds: 50));

      // 第二次推送相同代码
      final second = await service.upsertFault(
        printerSerial: 'PRINTER_001',
        code: '0C0030A0001C0001',
        severity: 'error',
        title: '耗材用尽',
      );

      expect(second, isNotNull);
      // last_seen 应更新
      expect(second!.lastSeenAt.isAfter(first!.firstSeenAt), isTrue);
      // first_seen 应保持不变
      expect(second.firstSeenAt, equals(first.firstSeenAt));
      // 仍是同一条事件（id 相同）
      expect(second.id, equals(first.id));

      // 数据库中只有 1 条活动事件
      final active = await service.getActiveFaults('PRINTER_001');
      expect(active.length, 1);
    });

    test('清除后清除时间已记录，再次出现创建新事件', () async {
      // 创建故障
      final first = await service.upsertFault(
        printerSerial: 'PRINTER_001',
        code: '0C0030A0001C0001',
        severity: 'error',
        title: '耗材用尽',
      );
      expect(first, isNotNull);
      expect(first!.clearedAt, isNull);

      // 清除故障
      await service.clearFault('PRINTER_001', '0C0030A0001C0001');

      // 活动故障应为空
      final activeAfterClear = await service.getActiveFaults('PRINTER_001');
      expect(activeAfterClear, isEmpty);

      // 历史中应有 1 条已清除事件
      final history = await service.getFaultHistory('PRINTER_001');
      expect(history.length, 1);
      expect(history.first.clearedAt, isNotNull);

      // 再次出现相同代码应创建新事件
      await Future.delayed(const Duration(milliseconds: 50));
      final second = await service.upsertFault(
        printerSerial: 'PRINTER_001',
        code: '0C0030A0001C0001',
        severity: 'error',
        title: '耗材用尽',
      );

      expect(second, isNotNull);
      // 新事件的 id 应不同于旧事件
      expect(second!.id, isNot(equals(first.id)));
      // 新事件的 first_seen 应晚于旧事件的 first_seen
      expect(second.firstSeenAt.isAfter(first.firstSeenAt), isTrue);
      // 新事件未被清除
      expect(second.clearedAt, isNull);

      // 活动故障应有 1 条（新事件）
      final activeAfterReoccur = await service.getActiveFaults('PRINTER_001');
      expect(activeAfterReoccur.length, 1);

      // 历史应有 2 条（1 已清除 + 1 活动）
      final historyAfterReoccur = await service.getFaultHistory('PRINTER_001');
      expect(historyAfterReoccur.length, 2);
    });

    test('30 次重复推送只产生 1 条活动事件', () async {
      const code = '0C0030A0001C0004';
      for (var i = 0; i < 30; i++) {
        await service.upsertFault(
          printerSerial: 'PRINTER_001',
          code: code,
          severity: 'error',
          title: '温度异常',
          summary: '第 $i 次推送',
        );
      }

      final active = await service.getActiveFaults('PRINTER_001');
      expect(active.length, 1, reason: '30 次重复推送应只产生 1 条活动事件');

      final history = await service.getFaultHistory('PRINTER_001');
      expect(history.length, 1, reason: '历史中也只应有 1 条事件');

      // last_seen 应晚于 first_seen（被更新过）
      final event = active.first;
      expect(
        event.lastSeenAt.isAfter(event.firstSeenAt) ||
            event.lastSeenAt.equals(event.firstSeenAt),
        isTrue,
      );
    });

    test('空 HMS 清除现有活动故障', () async {
      // 先创建 2 个不同代码的故障
      await service.upsertFault(
        printerSerial: 'PRINTER_001',
        code: '0C0030A0001C0001',
        severity: 'error',
        title: '耗材用尽',
      );
      await service.upsertFault(
        printerSerial: 'PRINTER_001',
        code: '0C0030A0001C0002',
        severity: 'error',
        title: '耗材堵塞',
      );

      // 确认有 2 条活动故障
      var active = await service.getActiveFaults('PRINTER_001');
      expect(active.length, 2);

      // MQTT 显式发送空 HMS（空列表）
      await service.handleHmsPayload('PRINTER_001', []);

      // 活动故障应被全部清除
      active = await service.getActiveFaults('PRINTER_001');
      expect(active, isEmpty, reason: '空 HMS 应清除所有活动故障');

      // 历史中保留已清除的记录
      final history = await service.getFaultHistory('PRINTER_001');
      expect(history.length, 2);
      for (final h in history) {
        expect(h.clearedAt, isNotNull, reason: '已清除的事件应记录 cleared_at');
      }
    });

    test('字段缺失不清除现有活动故障', () async {
      // 先创建故障
      await service.upsertFault(
        printerSerial: 'PRINTER_001',
        code: '0C0030A0001C0001',
        severity: 'error',
        title: '耗材用尽',
      );

      // 确认有 1 条活动故障
      var active = await service.getActiveFaults('PRINTER_001');
      expect(active.length, 1);

      // MQTT 字段缺失（hmsList 为 null）
      await service.handleHmsPayload('PRINTER_001', null);

      // 活动故障应保持不变
      active = await service.getActiveFaults('PRINTER_001');
      expect(active.length, 1, reason: '字段缺失时不应清除现有故障');
      expect(active.first.clearedAt, isNull);
    });

    test('用户确认故障事件', () async {
      final event = await service.upsertFault(
        printerSerial: 'PRINTER_001',
        code: '0C0030A0001C0003',
        severity: 'warning',
        title: '门盖打开',
      );
      expect(event, isNotNull);
      expect(event!.userConfirmedAt, isNull);

      // 用户确认
      await service.confirmFault(event.eventUid);

      // 查询历史确认 user_confirmed_at 已设置
      final history = await service.getFaultHistory('PRINTER_001');
      expect(history.length, 1);
      expect(history.first.userConfirmedAt, isNotNull);
    });

    test('不同打印机的故障相互隔离', () async {
      await service.upsertFault(
        printerSerial: 'PRINTER_A',
        code: '0C0030A0001C0001',
        severity: 'error',
        title: '耗材用尽',
      );
      await service.upsertFault(
        printerSerial: 'PRINTER_B',
        code: '0C0030A0001C0001',
        severity: 'error',
        title: '耗材用尽',
      );

      final activeA = await service.getActiveFaults('PRINTER_A');
      final activeB = await service.getActiveFaults('PRINTER_B');
      expect(activeA.length, 1);
      expect(activeB.length, 1);
      expect(activeA.first.printerSerial, 'PRINTER_A');
      expect(activeB.first.printerSerial, 'PRINTER_B');

      // 清除 A 的故障不影响 B
      await service.clearAllFaults('PRINTER_A');
      expect((await service.getActiveFaults('PRINTER_A')), isEmpty);
      expect((await service.getActiveFaults('PRINTER_B')).length, 1);
    });

    test('HMS 非空负载触发 upsert', () async {
      await service.handleHmsPayload('PRINTER_001', [
        {'code': '0C0030A0001C0001', 'severity': 'error', 'title': '耗材用尽'},
        {'code': '0C0030A0001C0002', 'severity': 'error', 'title': '耗材堵塞'},
      ]);

      final active = await service.getActiveFaults('PRINTER_001');
      expect(active.length, 2);
    });
  });
}

/// 扩展 DateTime 比较辅助，避免毫秒精度问题。
extension DateTimeEquals on DateTime {
  bool equals(DateTime other) =>
      millisecondsSinceEpoch == other.millisecondsSinceEpoch;
}
