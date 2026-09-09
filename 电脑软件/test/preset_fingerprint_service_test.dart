import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/core/services/preset_fingerprint_service.dart';
import 'package:consumable_tracker_desktop/data/models/print_parameter.dart';

void main() {
  group('PresetFingerprintService', () {
    PrintParameterPreset makePreset({
      String name = '测试预设',
      String author = '测试作者',
      int likes = 0,
      int downloads = 0,
      String? shareId,
      String? communityPublicationId,
      String? plateType,
    }) {
      return PrintParameterPreset(
        id: 'test-id',
        name: name,
        author: author,
        likes: likes,
        downloads: downloads,
        shareId: shareId,
        communityPublicationId: communityPublicationId,
        plateType: plateType,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        quality: const PrintQualityParams(),
        strength: const PrintStrengthParams(),
        speed: const PrintSpeedParams(),
        support: const PrintSupportParams(),
        other: const PrintOtherParams(),
      );
    }

    test('Map 键顺序不同指纹相同', () {
      // 两个预设参数内容完全相同，但 compatiblePrinters 顺序不同
      final presetA = makePreset().copyWith(
        compatiblePrinters: ['X1C', 'P1S', 'A1'],
      );
      final presetB = makePreset().copyWith(
        compatiblePrinters: ['A1', 'X1C', 'P1S'],
      );
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(
        fpA.contentHash,
        equals(fpB.contentHash),
        reason: 'compatiblePrinters 顺序不同不应改变指纹',
      );
    });

    test('修改任一真实参数后指纹不同', () {
      final presetA = makePreset();
      final presetB = presetA.copyWith(
        quality: const PrintQualityParams(layerHeight: '0.3'),
      );
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(
        fpA.contentHash,
        isNot(equals(fpB.contentHash)),
        reason: '修改 layer_height 应改变指纹',
      );
    });

    test('修改速度参数后指纹不同', () {
      final presetA = makePreset();
      final presetB = presetA.copyWith(
        speed: const PrintSpeedParams(innerWallSpeed: '200'),
      );
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, isNot(equals(fpB.contentHash)));
    });

    test('修改支撑参数后指纹不同', () {
      final presetA = makePreset();
      final presetB = presetA.copyWith(
        support: const PrintSupportParams(enableSupport: '0'),
      );
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, isNot(equals(fpB.contentHash)));
    });

    test('修改其他参数后指纹不同', () {
      final presetA = makePreset();
      final presetB = presetA.copyWith(
        other: const PrintOtherParams(seamPosition: 'aligned'),
      );
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, isNot(equals(fpB.contentHash)));
    });

    test('同内容不同名称仍共享内容指纹', () {
      final presetA = makePreset(name: '预设A');
      final presetB = makePreset(name: '预设B');
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, equals(fpB.contentHash), reason: '仅改名称不应改变指纹');
    });

    test('修改作者不影响指纹', () {
      final presetA = makePreset(author: '作者A');
      final presetB = makePreset(author: '作者B');
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, equals(fpB.contentHash), reason: '仅改作者不应改变指纹');
    });

    test('修改点赞数不影响指纹', () {
      final presetA = makePreset(likes: 10);
      final presetB = makePreset(likes: 999);
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, equals(fpB.contentHash), reason: '社交计数不应改变指纹');
    });

    test('修改下载次数不影响指纹', () {
      final presetA = makePreset(downloads: 5);
      final presetB = makePreset(downloads: 100);
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, equals(fpB.contentHash));
    });

    test('修改 shareId 不影响指纹', () {
      final presetA = makePreset(shareId: 'share-1');
      final presetB = makePreset(shareId: 'share-2');
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, equals(fpB.contentHash));
    });

    test('修改 communityPublicationId 不影响指纹', () {
      final presetA = makePreset(communityPublicationId: 'pub-1');
      final presetB = makePreset(communityPublicationId: 'pub-2');
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, equals(fpB.contentHash));
    });

    test('修改 material 影响指纹', () {
      final presetA = makePreset().copyWith(material: 'PLA');
      final presetB = makePreset().copyWith(material: 'PETG');
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(
        fpA.contentHash,
        isNot(equals(fpB.contentHash)),
        reason: '修改材料应改变指纹',
      );
    });

    test('修改打印板类型影响指纹', () {
      final presetA = makePreset(plateType: 'coolPlate');
      final presetB = makePreset(plateType: 'texturedPei');
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, isNot(equals(fpB.contentHash)));
    });

    test('旧 JSON 缺少打印板字段仍可读取为未知', () {
      final map = makePreset().toBbsparamMap();
      (map['preset'] as Map<String, dynamic>).remove('plateType');
      final restored = PrintParameterPreset.fromBbsparamJson(
        const JsonEncoder().convert(map),
      );
      expect(restored.plateType, isNull);
    });

    test('修改 inherits 影响指纹', () {
      final presetA = makePreset().copyWith(inherits: 'fdm_process_common');
      final presetB = makePreset().copyWith(inherits: 'fdm_process_bbl_0.2');
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, isNot(equals(fpB.contentHash)));
    });

    test('指纹包含 schema 版本', () {
      final preset = makePreset();
      final fp = PresetFingerprintService.compute(preset);
      expect(
        fp.schemaVersion,
        equals(PresetFingerprintService.currentSchemaVersion),
      );
      expect(fp.schemaVersion, greaterThan(0));
    });

    test('指纹为 64 字符 SHA-256 hex', () {
      final preset = makePreset();
      final fp = PresetFingerprintService.compute(preset);
      expect(fp.contentHash.length, equals(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(fp.contentHash), isTrue);
    });

    test('数值格式规范化：0.20 和 0.2 指纹相同', () {
      final presetA = makePreset().copyWith(
        quality: const PrintQualityParams(layerHeight: '0.20'),
      );
      final presetB = makePreset().copyWith(
        quality: const PrintQualityParams(layerHeight: '0.2'),
      );
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(
        fpA.contentHash,
        equals(fpB.contentHash),
        reason: '数值 0.20 和 0.2 应规范化为相同值',
      );
    });

    test('compatiblePrinters 去重不影响指纹', () {
      final presetA = makePreset().copyWith(
        compatiblePrinters: ['X1C', 'X1C', 'P1S'],
      );
      final presetB = makePreset().copyWith(
        compatiblePrinters: ['X1C', 'P1S'],
      );
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(
        fpA.contentHash,
        equals(fpB.contentHash),
        reason: '重复的 compatiblePrinters 应去重后相同',
      );
    });

    test('空 compatiblePrinters 和 null 列表指纹相同', () {
      final presetA = makePreset().copyWith(compatiblePrinters: []);
      final presetB = makePreset().copyWith(compatiblePrinters: []);
      final fpA = PresetFingerprintService.compute(presetA);
      final fpB = PresetFingerprintService.compute(presetB);
      expect(fpA.contentHash, equals(fpB.contentHash));
    });

    test('computeFromParamMaps 与 compute 结果一致', () {
      final preset = makePreset();
      final fp1 = PresetFingerprintService.compute(preset);
      final fp2 = PresetFingerprintService.computeFromParamMaps(
        params: {
          'quality': preset.quality.toMap(),
          'strength': preset.strength.toMap(),
          'speed': preset.speed.toMap(),
          'support': preset.support.toMap(),
          'other': preset.other.toMap(),
        },
        inherits: preset.inherits,
        compatiblePrinters: preset.compatiblePrinters,
        material: preset.material,
        scene: preset.scene,
        plateType: preset.plateType,
      );
      expect(
        fp1.contentHash,
        equals(fp2.contentHash),
        reason: 'compute 和 computeFromParamMaps 应生成相同指纹',
      );
    });

    test('旧 fingerprint schema 不被新版本覆盖', () {
      // 模拟旧版本指纹
      const oldFp = PresetFingerprint(
        schemaVersion: 0,
        contentHash: 'old-hash-value',
      );
      // 当前版本指纹
      final preset = makePreset();
      final newFp = PresetFingerprintService.compute(preset);
      // 旧版本和新版本不应相同
      expect(oldFp.schemaVersion, isNot(equals(newFp.schemaVersion)));
      // 旧指纹的 schema 版本应保留，不被新版本覆盖
      expect(oldFp.schemaVersion, equals(0));
      expect(newFp.schemaVersion, equals(2));
    });

    test('Dart schema-v2 与 Node 固定 fixture 字节级一致', () {
      final fingerprint = PresetFingerprintService.computeFromParamMaps(
        params: const {
          'quality': {
            'layer_height': '0.20',
            'line_width': '0.400',
          },
          'speed': {'inner_wall_speed': '100'},
          'support': {'enable_support': '0'},
        },
        inherits: 'fdm_process_common',
        compatiblePrinters: const ['X1C', 'P1S', 'X1C'],
        material: 'Bambu PLA Basic',
        scene: 'quality',
        plateType: 'textured_pei',
      );

      expect(
        fingerprint.contentHash,
        '5df269c466451776bd26542535612d40cbbc76dc08fe453f9ec9e2bb15530edd',
      );
    });

    test('PresetFingerprint 相等性', () {
      const fp1 = PresetFingerprint(schemaVersion: 1, contentHash: 'abc');
      const fp2 = PresetFingerprint(schemaVersion: 1, contentHash: 'abc');
      const fp3 = PresetFingerprint(schemaVersion: 1, contentHash: 'xyz');
      const fp4 = PresetFingerprint(schemaVersion: 2, contentHash: 'abc');
      expect(fp1 == fp2, isTrue);
      expect(fp1 == fp3, isFalse);
      expect(fp1 == fp4, isFalse);
      expect(fp1.hashCode, equals(fp2.hashCode));
    });
  });
}
