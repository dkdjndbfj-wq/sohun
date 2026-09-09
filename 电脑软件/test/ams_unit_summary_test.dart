import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/database/models/printer_feed_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BambuPrinterStatus parseUnits(
    dynamic units, {
    dynamic amsExistBits = 'f',
    dynamic trayExistBits = '0',
  }) {
    final status = BambuPrinterStatus.fromMqttJson(
      <String, dynamic>{
        'print': <String, dynamic>{
          'ams': <String, dynamic>{
            'ams': units,
            'ams_exist_bits': amsExistBits,
            'tray_exist_bits': trayExistBits,
          },
        },
      },
      serial: 'TEST',
    );
    expect(status, isNotNull);
    return status!;
  }

  group('AMS info 协议类型', () {
    final cases = <(String, AmsUnitType)>[
      ('1', AmsUnitType.ams),
      ('2', AmsUnitType.amsLite),
      ('3', AmsUnitType.ams2Pro),
      ('4', AmsUnitType.amsHt),
      ('5', AmsUnitType.amsLite),
    ];

    for (final testCase in cases) {
      test('info 低四位 ${testCase.$1} 映射为 ${testCase.$2}', () {
        final status = parseUnits(
          [
            <String, dynamic>{'id': '0', 'info': testCase.$1},
          ],
          amsExistBits: '1',
        );

        expect(status.amsUnits, hasLength(1));
        expect(status.amsUnits!.single.type, testCase.$2);
        expect(
          status.amsUnits!.single.rawTypeCode,
          int.parse(testCase.$1),
        );
      });
    }

    test('info 的高位标志不影响低四位型号', () {
      final status = parseUnits(
        [
          <String, dynamic>{'id': '0', 'info': '0x12A3'},
        ],
        amsExistBits: '1',
      );

      expect(status.amsUnits!.single.type, AmsUnitType.ams2Pro);
      expect(status.amsUnits!.single.rawTypeCode, 3);
    });

    test('超长 info 标志串仍只解析低四位', () {
      final status = parseUnits(
        [
          <String, dynamic>{
            'id': '0',
            'info': 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF3',
          },
        ],
        amsExistBits: '1',
      );

      expect(status.amsUnits!.single.type, AmsUnitType.ams2Pro);
      expect(status.amsUnits!.single.rawTypeCode, 3);
    });

    test('有效 info 优先于冲突的兼容类型字段', () {
      final status = parseUnits(
        [
          <String, dynamic>{
            'id': '0',
            'info': '4',
            'ams_type': 'AMS Lite',
          },
        ],
        amsExistBits: '1',
      );

      expect(status.amsUnits!.single.type, AmsUnitType.amsHt);
    });
  });

  group('AMS 单元结构兼容', () {
    test('旧版顶层 ams 载荷继续兼容', () {
      final status = BambuPrinterStatus.fromMqttJson(
        <String, dynamic>{
          'ams': <String, dynamic>{
            'ams': <dynamic>[
              <String, dynamic>{'id': '0', 'info': '3'},
            ],
            'ams_exist_bits': '1',
          },
        },
        serial: 'TEST',
      );

      expect(status, isNotNull);
      expect(status!.amsSummary, 'AMS 2 Pro × 1');
    });

    test('ams.ams 数组按单元 id 解析', () {
      final status = parseUnits(
        [
          <String, dynamic>{'id': '0', 'info': '3'},
          <String, dynamic>{'id': '1', 'info': '4'},
        ],
        amsExistBits: '3',
      );

      expect(status.amsUnits!.map((unit) => unit.id), [0, 1]);
      expect(status.amsSummary, 'AMS 2 Pro × 1 · AMS HT × 1');
    });

    test('ams.ams 按 ID 建索引的 Map 也能解析并排序', () {
      final status = parseUnits(
        <String, dynamic>{
          '2': <String, dynamic>{'info': '4'},
          '0': <String, dynamic>{'info': '3'},
        },
        amsExistBits: '5',
      );

      expect(status.amsUnits!.map((unit) => unit.id), [0, 2]);
      expect(status.amsSummary, 'AMS 2 Pro × 1 · AMS HT × 1');
    });

    test('Map 结构中的槽位数据继续保留', () {
      final status = parseUnits(
        <String, dynamic>{
          '0': <String, dynamic>{
            'info': '1',
            'tray': <dynamic>[
              <String, dynamic>{'tray_type': 'PLA', 'remain': 50},
            ],
          },
        },
        amsExistBits: '1',
        trayExistBits: '1',
      );

      expect(status.amsTrays, hasLength(1));
      expect(status.amsTrays!.single.trayType, 'PLA');
      expect(status.amsTrays!.single.hasFilament, isTrue);
    });
  });

  group('明确类型字段兼容', () {
    test('ams_type / amsType 支持数字与规范化名称', () {
      final status = parseUnits([
        <String, dynamic>{'id': '0', 'info': 'invalid', 'ams_type': 1},
        <String, dynamic>{'id': '1', 'amsType': 'AMS Lite'},
        <String, dynamic>{'id': '2', 'ams_type': 'n3f'},
        <String, dynamic>{'id': '3', 'amsType': 'ams-ht'},
      ]);

      expect(
        status.amsUnits!.map((unit) => unit.type),
        [
          AmsUnitType.ams,
          AmsUnitType.amsLite,
          AmsUnitType.ams2Pro,
          AmsUnitType.amsHt,
        ],
      );
    });
  });

  group('get_version 模块类型补充', () {
    test('模块名前缀按物理 id 映射四类 AMS', () {
      final versionStatus = BambuPrinterStatus.fromMqttJson(
        <String, dynamic>{
          'info': <String, dynamic>{
            'module': <dynamic>[
              <String, dynamic>{'name': 'ota', 'sw_ver': '01.00.00.00'},
              <String, dynamic>{'name': 'ams/0'},
              <String, dynamic>{'name': 'ams_f1/1'},
              <String, dynamic>{'name': 'n3f/2'},
              <String, dynamic>{'name': 'n3s/128'},
            ],
          },
        },
        serial: 'TEST',
      );

      expect(versionStatus, isNotNull);
      expect(versionStatus!.amsModuleTypes, <int, AmsUnitType>{
        0: AmsUnitType.ams,
        1: AmsUnitType.amsLite,
        2: AmsUnitType.ams2Pro,
        128: AmsUnitType.amsHt,
      });
      expect(versionStatus.currentFirmwareVersion, '01.00.00.00');
      expect(versionStatus.amsSummary, isNull);
    });

    test('异步 get_version 可补全 info 缺失的已上报单元', () {
      final pushStatus = parseUnits(
        [
          <String, dynamic>{'id': '0'},
          <String, dynamic>{'id': '1'},
          <String, dynamic>{'id': '2'},
          <String, dynamic>{'id': '128'},
        ],
        amsExistBits: '17',
      );
      final versionStatus = BambuPrinterStatus.fromMqttJson(
        <String, dynamic>{
          'info': <String, dynamic>{
            'module': <dynamic>[
              <String, dynamic>{'name': 'ams/0'},
              <String, dynamic>{'name': 'ams_f1/1'},
              <String, dynamic>{'name': 'n3f/2'},
              <String, dynamic>{'name': 'n3s/128'},
            ],
          },
        },
        serial: 'TEST',
      )!;
      final merged = pushStatus.copyWith(
        amsModuleTypes: versionStatus.amsModuleTypes,
      );

      expect(
        merged.amsSummary,
        'AMS 1 × 1 · AMS 2 Pro × 1 · AMS HT × 1 · AMS Lite × 1',
      );
    });

    test('单元有效 info 不被冲突的模块前缀覆盖', () {
      final status = parseUnits(
        [
          <String, dynamic>{'id': '0', 'info': '4'},
        ],
        amsExistBits: '1',
      ).copyWith(amsModuleTypes: const {0: AmsUnitType.ams2Pro});

      expect(status.amsSummary, 'AMS HT × 1');
    });
  });

  group('AMS 汇总与未知类型', () {
    test('未知或缺失类型的已上报单元归入通用 AMS', () {
      final status = parseUnits(
        [
          <String, dynamic>{'id': '0', 'info': '3'},
          <String, dynamic>{'id': '1', 'info': '9'},
          <String, dynamic>{'id': '2'},
        ],
        amsExistBits: '7',
      );

      expect(status.amsUnits![1].type, AmsUnitType.unknown);
      expect(status.amsUnits![2].type, AmsUnitType.unknown);
      expect(status.amsSummary, 'AMS 2 Pro × 1 · AMS × 2');
    });

    test('没有 AMS 节点或显式空单元列表时不显示', () {
      final withoutAms = BambuPrinterStatus.fromMqttJson(
        <String, dynamic>{'print': <String, dynamic>{}},
        serial: 'TEST',
      );
      final empty = parseUnits(const <dynamic>[], amsExistBits: '0');

      expect(withoutAms!.amsUnits, isNull);
      expect(withoutAms.amsSummary, isNull);
      expect(empty.amsUnits, isEmpty);
      expect(empty.amsSummary, isNull);
      expect(detectedAmsState(withoutAms), AmsDetectionState.unknown);
      expect(detectedAmsState(empty), AmsDetectionState.absent);
      expect(detectedAmsSummary(empty), '未连接 AMS');
    });

    test('农场硬件识别保留一代、二代、Lite 和 HT 的真实类型', () {
      final status = BambuPrinterStatus(
        serial: 'MIXED',
        amsUnits: const [
          AmsUnit(
            id: 0,
            type: AmsUnitType.ams,
            isPresent: true,
            trays: [],
          ),
          AmsUnit(
            id: 1,
            type: AmsUnitType.ams2Pro,
            isPresent: true,
            trays: [],
          ),
          AmsUnit(
            id: 2,
            type: AmsUnitType.amsLite,
            isPresent: true,
            trays: [],
          ),
          AmsUnit(
            id: 128,
            type: AmsUnitType.amsHt,
            isPresent: true,
            trays: [],
          ),
        ],
      );

      expect(detectedAmsState(status), AmsDetectionState.present);
      expect(
        detectedAmsTypes(status),
        const [
          AmsUnitType.ams,
          AmsUnitType.ams2Pro,
          AmsUnitType.amsLite,
          AmsUnitType.amsHt,
        ],
      );
      expect(
        detectedAmsSummary(status),
        'AMS 1 × 1 · AMS 2 Pro × 1 · AMS HT × 1 · AMS Lite × 1',
      );
    });

    test('ams_exist_bits 明确为 0 时不显示残留单元', () {
      final status = parseUnits(
        [
          <String, dynamic>{'id': '0', 'info': '3'},
        ],
        amsExistBits: '0',
      );

      expect(status.amsUnits!.single.isPresent, isFalse);
      expect(status.amsSummary, isNull);
    });

    test('AMS HT 的 id=128 映射到 existBits bit4', () {
      final status = parseUnits(
        [
          <String, dynamic>{'id': '0', 'info': '1001'},
          <String, dynamic>{'id': '1', 'info': '1001'},
          <String, dynamic>{'id': '2', 'info': '142023'},
          <String, dynamic>{'id': '128', 'info': '2004'},
        ],
        amsExistBits: '17',
      );

      expect(
        status.amsUnits!.map((unit) => unit.isPresent),
        everyElement(isTrue),
      );
      expect(status.amsSummary, 'AMS 1 × 2 · AMS 2 Pro × 1 · AMS HT × 1');
    });

    test('id=128 的 HT 不会错误检查 bit128', () {
      final status = parseUnits(
        [
          <String, dynamic>{'id': '0', 'info': '1'},
          <String, dynamic>{'id': '1', 'info': '1'},
          <String, dynamic>{'id': '128', 'info': '4'},
        ],
        amsExistBits: '13',
      );

      expect(status.amsUnits!.last.isPresent, isTrue);
      expect(status.amsSummary, 'AMS 1 × 2 · AMS HT × 1');
    });

    test('AMS HT id=128 的槽位映射到 trayExistBits bit16', () {
      final status = parseUnits(
        [
          <String, dynamic>{
            'id': '128',
            'info': '2004',
            'tray': <dynamic>[
              <String, dynamic>{'tray_type': 'PLA'},
            ],
          },
        ],
        amsExistBits: '10',
        trayExistBits: '10000',
      );

      expect(status.amsTrays, hasLength(1));
      expect(status.amsTrays!.single.globalSlot, 16);
      expect(status.amsTrays!.single.hasFilament, isTrue);
    });

    test('不根据槽位、湿度、烘干能力、type 或 model 猜型号', () {
      final status = parseUnits(
        [
          <String, dynamic>{
            'id': '0',
            'humidity': 48,
            'drying': 1,
            'type': 'AMS Lite',
            'model': 'AMS HT',
            'tray': List<dynamic>.generate(
              4,
              (index) => <String, dynamic>{'id': '$index'},
            ),
          },
        ],
        amsExistBits: '1',
      );

      expect(status.amsUnits!.single.type, AmsUnitType.unknown);
      expect(status.amsSummary, 'AMS × 1');
    });
  });

  test('增量 copyWith 保留未上报单元，也允许显式空列表清除', () {
    final original = parseUnits(
      [
        <String, dynamic>{'id': '0', 'info': '3'},
      ],
      amsExistBits: '1',
    );

    final preserved = original.copyWith(mcPercent: 42);
    final cleared = original.copyWith(amsUnits: const [], amsTrays: const []);

    expect(preserved.amsSummary, 'AMS 2 Pro × 1');
    expect(cleared.amsSummary, isNull);
  });
}
