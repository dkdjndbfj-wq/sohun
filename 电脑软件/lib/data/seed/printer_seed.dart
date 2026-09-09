import 'package:flutter/foundation.dart';

import '../../core/services/printer_model_normalizer.dart';

import '../database/models/printer_feed_models.dart';
import '../external/printer/bambu_printer_models.dart';

/// 主流 3D 打印机预设型号库。用户添加打印机时从该清单选择，避免手输。
/// 图片对应 assets/images/printers/ 下的资源文件。
///
/// 供料布局把打印机本体外挂料位与 AMS/MMU/CFS/ACE 分开建模：
/// - externalInputCount 表示打印机本体的单/双外挂供料位
/// - maxAmsCount 表示该机型理论上能连接的多色系统数量
/// - 连接后以设备实时上报的系统代际、数量和槽位为准
@immutable
class PrinterPreset {
  final String brand;
  final String model;
  final String imageAsset;
  final int maxAmsCount; // 最大可外挂多色系统数量（0 表示不支持）
  final int channelsPerAms; // 每组多色系统的通道数（通常 4）
  final int externalInputCount; // 打印机本体外挂供料位数量（1 或 2）

  /// 按官方兼容性表拆开的 AMS 上限。maxAmsCount 保留为旧数据和非拓竹
  /// 自定义机型的兼容字段；拓竹预设使用这些精确上限做校验与提示。
  final int maxAms2ProCount;
  final int maxAmsHtCount;
  final int maxAmsLiteCount;
  final bool amsLiteCanCombineWithStandard;

  /// 双喷头机型可以在同一个任务里让 AMS 和外挂料同时供料。
  /// 单喷头机型仍保留外挂通道，但一个任务只能选择一种供料来源。
  final bool externalCanCoexistWithAms;

  /// 同一条进料路径上，AMS 与外挂只能选择其一。
  bool get externalExclusiveWithAms => !externalCanCoexistWithAms;

  const PrinterPreset({
    required this.brand,
    required this.model,
    required this.imageAsset,
    this.maxAmsCount = 0,
    this.channelsPerAms = 4,
    this.externalInputCount = 1,
    this.maxAms2ProCount = 0,
    this.maxAmsHtCount = 0,
    this.maxAmsLiteCount = 0,
    this.amsLiteCanCombineWithStandard = false,
    this.externalCanCoexistWithAms = false,
  });

  /// 官方单次打印颜色上限，不是“物理插口总数”。四槽 AMS 共用 4 台
  /// 上限，AMS HT 每台只有 1 槽；双挤出机最多再用另一条路径的 1 卷外挂。
  int get maxChannels {
    if (!isBambu) return externalInputCount + maxAmsCount * channelsPerAms;
    final fourSlot = maxAms2ProCount.clamp(0, maxAmsCount);
    final ht = maxAmsHtCount.clamp(0, maxAmsCount - fourSlot);
    final mixedLite = amsLiteCanCombineWithStandard ? 3 * maxAmsLiteCount : 0;
    final ams = fourSlot * 4 + ht + mixedLite;
    return ams > 0
        ? ams + (externalCanCoexistWithAms ? 1 : 0)
        : externalInputCount;
  }

  /// 添加打印机时允许选择的物理 AMS 单元数。A2L 的 1 台 AMS Lite
  /// 可以叠加在 4 台常规 AMS 之外，因此 UI 上限为 5；其余机型就是
  /// 官方表中的常规 AMS 上限。
  int get maxConfiguredAmsUnits =>
      maxAmsCount +
      (amsLiteCanCombineWithStandard && maxAmsLiteCount > 0 ? 1 : 0);

  /// 保存物理路径以及原来的耗材绑定；可用性由实时喷头路由决定，不能
  /// 用接入 AMS 的数量删除一个外挂通道。
  int externalInputsForAms(int amsCount) => externalInputCount;

  /// 是否支持多色系统
  bool get supportsAms => maxAmsCount > 0;

  bool get isBambu => brand == '拓竹';

  /// AMS 2 Pro / AMS HT / AMS Lite 的精确能力检查。第一代 AMS 与
  /// AMS 2 Pro 共用四槽系统配额，不能当成额外可叠加的一组设备。
  bool supportsAmsType(AmsUnitType type) {
    return switch (type) {
      AmsUnitType.ams => maxAms2ProCount > 0,
      AmsUnitType.ams2Pro => maxAms2ProCount > 0,
      AmsUnitType.amsHt => maxAmsHtCount > 0,
      AmsUnitType.amsLite => maxAmsLiteCount > 0,
      AmsUnitType.unknown => !isBambu,
    };
  }

  bool validateAmsTypes(List<AmsUnitType> types) =>
      amsConfigurationError(types) == null;

  String? amsConfigurationError(List<AmsUnitType> types) {
    if (!isBambu) return types.length <= maxAmsCount ? null : '多色系统数量超过上限';
    final lite = types.where((type) => type == AmsUnitType.amsLite).length;
    final ht = types.where((type) => type == AmsUnitType.amsHt).length;
    final standard = types.where((type) {
      return type == AmsUnitType.ams || type == AmsUnitType.ams2Pro;
    }).length;
    if (!types.every(supportsAmsType)) return '$model 不支持所选 AMS 类型';
    if (lite > maxAmsLiteCount)
      return '$model 最多连接 $maxAmsLiteCount 台 AMS Lite';
    if (ht > maxAmsHtCount) return '$model 最多连接 $maxAmsHtCount 台 AMS HT';
    if (standard > maxAms2ProCount)
      return '$model 的 AMS / AMS 2 Pro 合计最多 $maxAms2ProCount 台';
    if (lite > 0 && (standard + ht) > 0 && !amsLiteCanCombineWithStandard) {
      return '$model 的 AMS Lite 不能与其他 AMS 混接';
    }
    final maxUnits = maxAmsCount +
        (lite > 0 && amsLiteCanCombineWithStandard ? maxAmsLiteCount : 0);
    if (types.length > maxUnits) return '$model 的常规 AMS 合计最多 $maxAmsCount 台';
    return null;
  }

  List<AmsUnitType> defaultAmsTypes(int count) {
    if (count <= 0) return const [];
    if (!isBambu) return List.filled(count, AmsUnitType.unknown);
    if (count == 1) return [defaultAmsType];
    return List.generate(count, (index) {
      if (amsLiteCanCombineWithStandard && index >= maxAmsCount)
        return AmsUnitType.amsLite;
      return index < maxAms2ProCount ? AmsUnitType.ams2Pro : AmsUnitType.amsHt;
    });
  }

  /// 返回用户在添加/发布流程中应看到的能力摘要。
  String get feedCapabilitySummary {
    if (!isBambu) {
      return '${externalInputCount} 个外挂料位 · 最多 $maxAmsCount 组多色系统';
    }
    final amsParts = <String>[];
    if (maxAms2ProCount > 0) amsParts.add('AMS / 2 Pro 合计 ≤ $maxAms2ProCount');
    if (maxAmsHtCount > 0) amsParts.add('AMS HT ≤ $maxAmsHtCount');
    if (maxAmsLiteCount > 0) amsParts.add('AMS Lite ≤ $maxAmsLiteCount');
    if (amsParts.isEmpty && maxAmsCount > 0) amsParts.add('AMS ≤ $maxAmsCount');
    if (amsLiteCanCombineWithStandard && maxAmsLiteCount > 0) {
      amsParts.add('可叠加 $maxAmsLiteCount 台 Lite');
    }
    final external = externalInputCount == 2 ? '双外挂' : '单外挂';
    final coexist = externalCanCoexistWithAms ? '可与 AMS 同时供料' : '与 AMS 任务内互斥';
    return '$external · ${amsParts.join('、')} · 常规 AMS 合计 ≤ $maxAmsCount · 最多 $maxChannels 色 · $coexist';
  }

  AmsUnitType get defaultAmsType {
    if (!isBambu) return AmsUnitType.unknown;
    final upper = model.toUpperCase();
    if (upper.startsWith('A1')) return AmsUnitType.amsLite;
    if (upper.startsWith('A2') ||
        upper.startsWith('P2') ||
        upper.startsWith('X2') ||
        upper.startsWith('H2')) {
      return AmsUnitType.ams2Pro;
    }
    return AmsUnitType.ams;
  }

  PrinterFeedConfiguration feedConfiguration({
    required int amsCount,
    List<AmsUnitType>? amsTypes,
  }) {
    final resolvedTypes = amsTypes ?? defaultAmsTypes(amsCount);
    final error = amsConfigurationError(resolvedTypes);
    if (error != null) throw ArgumentError(error);
    final mixedAmsLite = amsLiteCanCombineWithStandard;
    return PrinterFeedConfiguration(
      externalInputCount: externalInputsForAms(resolvedTypes.length),
      amsTypes: resolvedTypes,
      channelsPerGenericSystem: channelsPerAms,
      amsLiteMixed: mixedAmsLite,
      externalCanCoexistWithAms: externalCanCoexistWithAms,
      bambuLabels: isBambu,
    );
  }

  String get displayName => '$brand $model';
}

class PrinterPresets {
  PrinterPresets._();

  /// 拓竹型号按 2026-09-05 官方 BBL.json 与 AMS 兼容指南核对。
  /// 能力表、来源与维护规则见 docs/bambu-feed-compatibility.md。
  /// 图片命名规则：
  /// - 拓竹机型：bambu_<型号小写>.<扩展名>，其中 P1P/H2D/H2S/H2C 为 .webp，
  ///   其余为 .png。已统一重命名为英文命名，存放在 assets/images/printers/。
  /// - 其他品牌：品牌+型号.png/.webp，已复制到 assets/images/printers/。
  static const List<PrinterPreset> all = [
    // ===== 拓竹 Bambu Lab =====
    // X1 系列（旗舰）
    PrinterPreset(
      brand: '拓竹',
      model: 'X1',
      imageAsset: 'assets/images/printers/bambu_x1.png',
      maxAmsCount: 4,
      maxAms2ProCount: 4,
      maxAmsHtCount: 4,
    ),
    PrinterPreset(
      brand: '拓竹',
      model: 'X1C',
      imageAsset: 'assets/images/printers/bambu_x1c.png',
      maxAmsCount: 4, // 支持 4 组多色系统 = 16 色
      maxAms2ProCount: 4,
      maxAmsHtCount: 4,
    ),
    PrinterPreset(
      brand: '拓竹',
      model: 'X1E',
      imageAsset: 'assets/images/printers/bambu_x1e.png',
      maxAmsCount: 4, // 支持 AMS HT 烘干
      maxAms2ProCount: 4,
      maxAmsHtCount: 4,
    ),
    PrinterPreset(
      brand: '拓竹',
      model: 'X2D',
      imageAsset: 'assets/images/printers/bambu_x2d.png',
      maxAmsCount: 12,
      externalInputCount: 2,
      maxAms2ProCount: 4,
      maxAmsHtCount: 8,
      externalCanCoexistWithAms: true,
    ),
    // P1 系列（CoreXY 中端）
    PrinterPreset(
      brand: '拓竹',
      model: 'P1P',
      imageAsset: 'assets/images/printers/bambu_p1p.webp',
      maxAmsCount: 4,
      maxAms2ProCount: 4,
      maxAmsHtCount: 4,
    ),
    PrinterPreset(
      brand: '拓竹',
      model: 'P1S',
      imageAsset: 'assets/images/printers/bambu_p1s.png',
      maxAmsCount: 4,
      maxAms2ProCount: 4,
      maxAmsHtCount: 4,
    ),
    PrinterPreset(
      brand: '拓竹',
      model: 'P2S',
      imageAsset: 'assets/images/printers/bambu_p2s.png',
      maxAmsCount: 8,
      maxAms2ProCount: 4,
      maxAmsHtCount: 4,
    ),
    // A1 系列（入门桌面级）
    PrinterPreset(
      brand: '拓竹',
      model: 'A1',
      imageAsset: 'assets/images/printers/bambu_a1.png',
      maxAmsCount: 4,
      maxAms2ProCount: 4,
      maxAmsHtCount: 4,
      maxAmsLiteCount: 1,
    ),
    PrinterPreset(
      brand: '拓竹',
      model: 'A1mini',
      imageAsset: 'assets/images/printers/bambu_a1_mini.png',
      maxAmsCount: 4,
      maxAms2ProCount: 4,
      maxAmsHtCount: 4,
      maxAmsLiteCount: 1,
    ),
    PrinterPreset(
      brand: '拓竹',
      model: 'A2L',
      imageAsset: 'assets/images/printers/bambu_a2l.png',
      maxAmsCount: 4,
      maxAms2ProCount: 4,
      maxAmsHtCount: 4,
      maxAmsLiteCount: 1,
      amsLiteCanCombineWithStandard: true,
    ),
    // H2 系列（旗舰智造中心）
    PrinterPreset(
      brand: '拓竹',
      model: 'H2D Pro',
      imageAsset: 'assets/images/printers/bambu_h2d_pro.webp',
      maxAmsCount: 12,
      externalInputCount: 2,
      maxAms2ProCount: 4,
      maxAmsHtCount: 8,
      externalCanCoexistWithAms: true,
    ),
    PrinterPreset(
      brand: '拓竹',
      model: 'H2D',
      imageAsset: 'assets/images/printers/bambu_h2d.webp',
      maxAmsCount: 12,
      externalInputCount: 2,
      maxAms2ProCount: 4,
      maxAmsHtCount: 8,
      externalCanCoexistWithAms: true,
    ),
    PrinterPreset(
      brand: '拓竹',
      model: 'H2S',
      imageAsset: 'assets/images/printers/bambu_h2s.webp',
      maxAmsCount: 12,
      maxAms2ProCount: 4,
      maxAmsHtCount: 8,
    ),
    PrinterPreset(
      brand: '拓竹',
      model: 'H2C',
      imageAsset: 'assets/images/printers/bambu_h2c.webp',
      maxAmsCount: 12,
      externalInputCount: 2,
      maxAms2ProCount: 4,
      maxAmsHtCount: 8,
      externalCanCoexistWithAms: true,
    ),

    // ===== 创想三维 Creality =====
    PrinterPreset(
      brand: '创想三维',
      model: 'K1 Max',
      imageAsset: 'assets/images/printers/创想三维K1 Max.png',
      maxAmsCount: 1, // 配合 CFS 多色系统（4 色）
    ),
    PrinterPreset(
      brand: '创想三维',
      model: 'K1C',
      imageAsset: 'assets/images/printers/创想三维K1C.png',
      maxAmsCount: 1,
    ),
    PrinterPreset(
      brand: '创想三维',
      model: 'K2',
      imageAsset: 'assets/images/printers/创想三维K2.png',
      maxAmsCount: 1,
    ),
    PrinterPreset(
      brand: '创想三维',
      model: 'K2 SE',
      imageAsset: 'assets/images/printers/创想三维K2 SE.png',
      maxAmsCount: 1,
    ),
    PrinterPreset(
      brand: '创想三维',
      model: 'Ender-3 V4',
      imageAsset: 'assets/images/printers/创想三维Ender-3 V4.png',
      maxAmsCount: 0, // 不支持多色系统
    ),
    PrinterPreset(
      brand: '创想三维',
      model: 'Ender-5 Max',
      imageAsset: 'assets/images/printers/创想三维Ender-5 Max.png',
      maxAmsCount: 0,
    ),
    PrinterPreset(
      brand: '创想三维',
      model: 'Hi',
      imageAsset: 'assets/images/printers/创想三维Creality Hi.png',
      maxAmsCount: 0,
    ),
    PrinterPreset(
      brand: '创想三维',
      model: 'SPARKX i7',
      imageAsset: 'assets/images/printers/创想三维SPARKX i7.png',
      maxAmsCount: 0,
    ),
    PrinterPreset(
      brand: '创想三维',
      model: 'Sermoon M300',
      imageAsset: 'assets/images/printers/创想三维Sermoon M300.png',
      maxAmsCount: 0,
    ),

    // ===== 纵维立方 Anycubic =====
    PrinterPreset(
      brand: '纵维立方',
      model: 'Kobra 3 V2 Combo',
      imageAsset: 'assets/images/printers/纵维立方Kobra 3 V2 Combo.png',
      maxAmsCount: 1, // 配合 ACE Pro 多色系统（4 色）
    ),
    PrinterPreset(
      brand: '纵维立方',
      model: 'Kobra S1 Combo',
      imageAsset: 'assets/images/printers/纵维立方Kobra S1 Combo.png',
      maxAmsCount: 1,
    ),
    PrinterPreset(
      brand: '纵维立方',
      model: 'Kobra S1 Max Combo',
      imageAsset: 'assets/images/printers/纵维立方Kobra S1 Max Combo.png',
      maxAmsCount: 1,
    ),
    PrinterPreset(
      brand: '纵维立方',
      model: 'Kobra X',
      imageAsset: 'assets/images/printers/纵维立方Kobra X.png',
      maxAmsCount: 0,
    ),
  ];

  /// 按品牌分组
  static Map<String, List<PrinterPreset>> groupedByBrand() {
    final map = <String, List<PrinterPreset>>{};
    for (final p in all) {
      map.putIfAbsent(p.brand, () => []).add(p);
    }
    return map;
  }

  static PrinterPreset? findByModel(String model, {String? brand}) {
    final normalized = PrinterModelNormalizer.normalize(model);
    for (final preset in all) {
      if (brand != null &&
          preset.brand != brand &&
          !(preset.isBambu &&
              ['bambulab', 'bambu']
                  .contains(brand.replaceAll(' ', '').toLowerCase()))) continue;
      if (PrinterModelNormalizer.normalize(preset.model) == normalized) {
        return preset;
      }
    }
    return null;
  }

  /// 常见耗材厂商（以国内热门品牌为主）
  static const List<String> commonManufacturers = [
    '拓竹',
    '创想三维',
    '纵维立方',
    '闪铸',
    '联泰',
    '极光尔沃',
    '易生',
    '三绿',
    '聚复',
    '爱乐酷',
    '智维',
    '天瑞',
    'Kexcelled',
    'Prusament',
    'Overture',
    'Hatchbox',
  ];

  /// 常见耗材材质（仅塑料 3D 打印耗材，型号即材质，新增耗材时直接选材质）
  static const List<String> commonMaterials = [
    'PLA',
    'PLA+',
    'PLA-Silk',
    'PLA-CF',
    'PLA-GF',
    'PLA-Marble',
    'PLA-wood',
    'PLA-Metallic',
    'PLA-Glow',
    'PLA-Tri-Color',
    'PETG',
    'PETG-CF',
    'PETG-HF',
    'ABS',
    'ABS-GF',
    'ASA',
    'ASA-CF',
    'TPU',
    'TPE',
    'PC',
    'PC-CF',
    'Nylon',
    'Nylon-CF',
    'Nylon-GF',
    'PVA',
    'HIPS',
    'PP',
  ];
}
