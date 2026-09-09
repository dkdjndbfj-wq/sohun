import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/core/services/parameter_compatibility_service.dart';
import 'package:consumable_tracker_desktop/core/services/material_identity_service.dart';
import 'package:consumable_tracker_desktop/data/models/parameter_compatibility.dart';
import 'package:consumable_tracker_desktop/data/models/print_parameter.dart';

PrintParameterPreset _basePreset({
  List<String> compatiblePrinters = const ['X1C'],
  String material = 'Bambu PLA Basic',
}) {
  final now = DateTime.now();
  return PrintParameterPreset(
    id: 'test-preset',
    name: '测试预设',
    material: material,
    compatiblePrinters: compatiblePrinters,
    createdAt: now,
    updatedAt: now,
    quality: const PrintQualityParams(),
    strength: const PrintStrengthParams(),
    speed: const PrintSpeedParams(),
    support: const PrintSupportParams(),
    other: const PrintOtherParams(),
  );
}

void main() {
  group('PrinterModelNormalizer', () {
    test('X1 Carbon 和 X1C 归一化为同一 canonical ID', () {
      expect(PrinterModelNormalizer.normalize('X1 Carbon'), 'X1C');
      expect(PrinterModelNormalizer.normalize('X1C'), 'X1C');
      expect(PrinterModelNormalizer.sameModel('X1 Carbon', 'X1C'), isTrue);
    });

    test('P1S 和 P1P 不等价', () {
      expect(PrinterModelNormalizer.normalize('P1S'), 'P1S');
      expect(PrinterModelNormalizer.normalize('P1P'), 'P1P');
      expect(PrinterModelNormalizer.sameModel('P1S', 'P1P'), isFalse);
    });

    test('A1 mini 归一化为 A1mini（无空格）', () {
      expect(PrinterModelNormalizer.normalize('A1 mini'), 'A1mini');
    });

    test('去除喷嘴后缀', () {
      expect(PrinterModelNormalizer.normalize('P1S 0.4mm nozzle'), 'P1S');
      expect(PrinterModelNormalizer.normalize('X1C 0.2mm nozzle'), 'X1C');
    });

    test('含糊系列名保持未知，不冒充精确型号', () {
      expect(PrinterModelNormalizer.normalize('X1'), 'X1');
      expect(PrinterModelNormalizer.normalize('P1'), 'P1');
      expect(PrinterModelNormalizer.normalize('H2'), 'H2');
      expect(PrinterModelNormalizer.isKnownBambuModel('P1'), isFalse);
    });

    test('已知拓竹机型识别', () {
      expect(PrinterModelNormalizer.isKnownBambuModel('X1C'), isTrue);
      expect(PrinterModelNormalizer.isKnownBambuModel('A1 mini'), isTrue);
      expect(PrinterModelNormalizer.isKnownBambuModel('未知型号'), isFalse);
    });
  });

  group('MaterialIdentityService', () {
    test('PLA 不会与 PLA-CF 被视为相同材料', () {
      expect(
        MaterialIdentityService.sameMaterial(
          'Bambu PLA Basic',
          'Generic PLA-CF',
        ),
        isFalse,
      );
    });

    test('PETG 不会与 PETG-CF 被视为相同材料', () {
      expect(
        MaterialIdentityService.sameMaterial(
          'Bambu PETG Basic',
          'Generic PETG-CF',
        ),
        isFalse,
      );
    });

    test('PLA 和 PLA Basic 属于同族', () {
      expect(
        MaterialIdentityService.sameFamily('Bambu PLA Basic', 'Generic PLA'),
        isTrue,
      );
    });

    test('PLA 和 PLA-CF 不属于同族', () {
      expect(
        MaterialIdentityService.sameFamily('Bambu PLA Basic', 'Generic PLA-CF'),
        isFalse,
      );
    });

    test('去品牌前缀', () {
      final id = MaterialIdentityService.normalize('Bambu PLA Basic @BBL X1C');
      expect(id.canonicalId, 'pla');
      expect(id.family, 'PLA');
      expect(id.isCarbonFiber, isFalse);
      expect(id.isAbrasive, isFalse);
    });

    test('识别碳纤维材料', () {
      final id = MaterialIdentityService.normalize('Generic PETG-CF');
      expect(id.isCarbonFiber, isTrue);
      expect(id.isAbrasive, isTrue);
      expect(id.family, 'PETG-CF');
    });

    test('识别柔性材料', () {
      final id = MaterialIdentityService.normalize('Bambu TPU 95A HF');
      expect(id.isFlexible, isTrue);
      expect(id.isHygroscopic, isTrue);
    });

    test('识别支撑材料', () {
      final id = MaterialIdentityService.normalize('Bambu Support W');
      expect(id.isSupport, isTrue);
    });

    test('识别吸湿性材料', () {
      final petg = MaterialIdentityService.normalize('Bambu PETG Basic');
      expect(petg.isHygroscopic, isTrue);
      final pla = MaterialIdentityService.normalize('Bambu PLA Basic');
      expect(pla.isHygroscopic, isFalse);
    });

    test('PA612 不被错认为 PA6', () {
      final id = MaterialIdentityService.normalize('Fiberon PA612-CF');
      expect(id.canonicalId, 'pa612-cf');
      expect(id.family, 'PA612-CF');
    });
  });

  group('ParameterCompatibilityService', () {
    test('参数打印板与当前打印板不一致时硬性阻断', () {
      final preset = _basePreset().copyWith(plateType: 'texturedPei');
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(
          model: 'X1C',
          nozzleDiameter: 0.4,
          plateType: 'coolPlate',
        ),
        material: MaterialCapability.unknown('PLA'),
      );

      final result = ParameterCompatibilityService.assess(context);
      expect(result.status, CompatibilityStatus.incompatible);
      expect(
        result.blockers.any((r) => r.ruleId == 'plate_type_mismatch'),
        isTrue,
      );
    });

    test('完全兼容场景', () {
      final preset = _basePreset();
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(
          model: 'X1C',
          nozzleDiameter: 0.4,
          nozzleType: 'hardened_steel',
          maxNozzleTemp: 300,
          supportsAms: true,
        ),
        material: MaterialCapability(
          identity: MaterialIdentityService.normalize('Bambu PLA Basic'),
          nozzleTempMin: 190,
          nozzleTempMax: 220,
        ),
        nozzleTargetTemp: 210,
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(result.status, CompatibilityStatus.compatible);
      expect(result.score, 100);
      expect(result.confidence, 100);
      expect(result.blockers, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('G-code 目标机器不一致 → incompatible', () {
      final preset = _basePreset();
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(
          model: 'P1S',
          nozzleDiameter: 0.4,
        ),
        gcodeTargetPrinterModel: 'X1C',
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(result.status, CompatibilityStatus.incompatible);
      expect(result.isBlocked, isTrue);
      expect(
        result.blockers.any((b) => b.ruleId == 'gcode_target_mismatch'),
        isTrue,
      );
    });

    test('G-code 喷嘴不一致 → incompatible', () {
      final preset = _basePreset();
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(
          model: 'X1C',
          nozzleDiameter: 0.4,
        ),
        gcodeTargetNozzleDiameter: 0.6,
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(result.status, CompatibilityStatus.incompatible);
      expect(
        result.blockers.any((b) => b.ruleId == 'gcode_nozzle_mismatch'),
        isTrue,
      );
    });

    test('参数排除当前打印机 → incompatible', () {
      final preset = _basePreset(compatiblePrinters: ['P1S']);
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(model: 'X1C', nozzleDiameter: 0.4),
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(result.status, CompatibilityStatus.incompatible);
      expect(
        result.blockers.any((b) => b.ruleId == 'preset_excludes_printer'),
        isTrue,
      );
    });

    test('喷嘴温度超出设备能力 → incompatible', () {
      final preset = _basePreset();
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(
          model: 'X1C',
          nozzleDiameter: 0.4,
          maxNozzleTemp: 250,
        ),
        nozzleTargetTemp: 300,
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(result.status, CompatibilityStatus.incompatible);
      expect(
        result.blockers.any((b) => b.ruleId == 'nozzle_temp_exceeds_device'),
        isTrue,
      );
    });

    test('磨蚀性材料 + 不锈钢喷嘴 → incompatible', () {
      final preset = _basePreset(material: 'Bambu PETG-CF');
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(
          model: 'X1C',
          nozzleDiameter: 0.4,
          nozzleType: 'stainless_steel',
        ),
        material: MaterialCapability(
          identity: MaterialIdentityService.normalize('Bambu PETG-CF'),
          requiresHardenedNozzle: true,
        ),
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(result.status, CompatibilityStatus.incompatible);
      expect(
        result.blockers.any((b) => b.ruleId == 'abrasive_material_soft_nozzle'),
        isTrue,
      );
    });

    test('吸湿材料 + 高 AMS 湿度 → caution', () {
      final preset = _basePreset(material: 'Bambu PETG Basic');
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(
          model: 'X1C',
          nozzleDiameter: 0.4,
        ),
        material: MaterialCapability(
          identity: MaterialIdentityService.normalize('Bambu PETG Basic'),
        ),
        amsHumidity: 60,
        amsHumiditySampledAt: DateTime.now(),
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(result.status, CompatibilityStatus.caution);
      expect(
        result.warnings.any((w) => w.ruleId == 'hygroscopic_high_humidity'),
        isTrue,
      );
    });

    test('材料推荐温度与喷嘴温度冲突 → caution', () {
      final preset = _basePreset();
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(
          model: 'X1C',
          nozzleDiameter: 0.4,
        ),
        material: MaterialCapability(
          identity: MaterialIdentityService.normalize('Bambu PLA Basic'),
          nozzleTempMin: 190,
          nozzleTempMax: 220,
        ),
        nozzleTargetTemp: 250,
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(
        result.warnings.any((w) => w.ruleId == 'material_temp_conflict'),
        isTrue,
      );
    });

    test('缺少打印机和喷嘴数据 → unknown', () {
      final preset = _basePreset();
      final context = CompatibilityContext(preset: preset);
      final result = ParameterCompatibilityService.assess(context);
      expect(result.status, CompatibilityStatus.unknown);
      expect(result.confidence, lessThan(50));
      expect(result.missingFacts, contains('printer_model'));
      expect(result.missingFacts, contains('nozzle_diameter'));
    });

    test('更换喷嘴后评估会更新（无缓存）', () {
      final preset = _basePreset();
      final ctx040 = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(model: 'X1C', nozzleDiameter: 0.4),
        gcodeTargetNozzleDiameter: 0.4,
      );
      final r040 = ParameterCompatibilityService.assess(ctx040);
      expect(r040.status, CompatibilityStatus.compatible);

      final ctx060 = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(model: 'X1C', nozzleDiameter: 0.4),
        gcodeTargetNozzleDiameter: 0.6,
      );
      final r060 = ParameterCompatibilityService.assess(ctx060);
      expect(r060.status, CompatibilityStatus.incompatible);
    });

    test('磨蚀性材料 + 小直径喷嘴 → caution', () {
      final preset = _basePreset(material: 'Bambu PLA-CF');
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(
          model: 'X1C',
          nozzleDiameter: 0.2,
          nozzleType: 'hardened_steel',
        ),
        material: MaterialCapability(
          identity: MaterialIdentityService.normalize('Bambu PLA-CF'),
          requiresHardenedNozzle: true,
        ),
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(
        result.warnings.any((w) => w.ruleId == 'abrasive_small_nozzle'),
        isTrue,
      );
    });

    test('参数未指定兼容打印机 → caution', () {
      final preset = _basePreset(compatiblePrinters: const []);
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(model: 'X1C', nozzleDiameter: 0.4),
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(
        result.warnings.any((w) => w.ruleId == 'preset_no_compatible_printers'),
        isTrue,
      );
    });

    test('湿度数据过期 → caution', () {
      final preset = _basePreset(material: 'Bambu PETG Basic');
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(model: 'X1C', nozzleDiameter: 0.4),
        material: MaterialCapability(
          identity: MaterialIdentityService.normalize('Bambu PETG Basic'),
        ),
        amsHumidity: 40,
        amsHumiditySampledAt: DateTime.now().subtract(const Duration(hours: 3)),
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(
        result.warnings.any((w) => w.ruleId == 'humidity_data_stale'),
        isTrue,
      );
    });

    test('canSend 在 blocker 存在时为 false', () {
      final preset = _basePreset();
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(model: 'P1S', nozzleDiameter: 0.4),
        gcodeTargetPrinterModel: 'X1C',
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(result.canSend, isFalse);
    });

    test('canSend 在 caution 状态时为 true', () {
      final preset = _basePreset();
      final context = CompatibilityContext(
        preset: preset,
        printer: const PrinterCapability(model: 'X1C', nozzleDiameter: 0.4),
        material: MaterialCapability(
          identity: MaterialIdentityService.normalize('Bambu PETG Basic'),
        ),
        amsHumidity: 60,
        amsHumiditySampledAt: DateTime.now(),
      );
      final result = ParameterCompatibilityService.assess(context);
      expect(result.status, CompatibilityStatus.caution);
      expect(result.canSend, isTrue);
    });
  });
}
