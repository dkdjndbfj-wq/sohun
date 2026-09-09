import '../../data/models/parameter_compatibility.dart';
import '../../data/models/print_parameter.dart';
import 'material_identity_service.dart';
import 'printer_model_normalizer.dart';

export 'printer_model_normalizer.dart' show PrinterModelNormalizer;

/// 打印机能力描述。
class PrinterCapability {
  /// canonical 型号 ID（如 "X1C"）。
  final String model;

  /// 喷嘴直径（mm，如 0.4）。
  final double? nozzleDiameter;

  /// 喷嘴类型（hardened_steel / stainless_steel）。
  final String? nozzleType;

  /// 最大喷嘴温度（℃）。
  final int? maxNozzleTemp;

  /// 最大热床温度（℃）。
  final int? maxBedTemp;

  /// 构建板类型（textured_pei / smooth_pei / etc.）。
  final String? plateType;

  /// 构建尺寸（mm）：[x, y, z]。
  final List<double>? buildVolume;

  /// 是否支持 AMS（多色）。
  final bool supportsAms;

  /// 是否支持多材料（不同工具/AMS 通道）。
  final bool supportsMultiMaterial;

  const PrinterCapability({
    required this.model,
    this.nozzleDiameter,
    this.nozzleType,
    this.maxNozzleTemp,
    this.maxBedTemp,
    this.plateType,
    this.buildVolume,
    this.supportsAms = false,
    this.supportsMultiMaterial = false,
  });

  static const PrinterCapability unknown = PrinterCapability(
    model: '',
    supportsAms: false,
    supportsMultiMaterial: false,
  );
}

/// 材料能力描述（从 RFID 或库存读取）。
class MaterialCapability {
  /// 材料身份。
  final MaterialIdentity identity;

  /// 推荐喷嘴温度范围（℃）。
  final int? nozzleTempMin;
  final int? nozzleTempMax;

  /// 推荐喷嘴硬度 HRC。
  final int? requiredNozzleHrc;

  /// 推荐热床温度范围（℃）。
  final int? bedTempMin;
  final int? bedTempMax;

  /// 是否需要硬化钢喷嘴（磨蚀性材料）。
  final bool requiresHardenedNozzle;

  const MaterialCapability({
    required this.identity,
    this.nozzleTempMin,
    this.nozzleTempMax,
    this.requiredNozzleHrc,
    this.bedTempMin,
    this.bedTempMax,
    this.requiresHardenedNozzle = false,
  });

  static MaterialCapability unknown(String materialName) => MaterialCapability(
        identity: MaterialIdentityService.normalize(materialName),
      );
}

/// 参数兼容性评估上下文。
class CompatibilityContext {
  /// 参数预设。
  final PrintParameterPreset preset;

  /// 当前打印机能力（null 表示未知）。
  final PrinterCapability? printer;

  /// 当前材料能力（null 表示未知）。
  final MaterialCapability? material;

  /// 已切片 G-code 的目标机器预设（null 表示未切片或未解析）。
  final String? gcodeTargetPrinterModel;

  /// 已切片 G-code 的目标喷嘴直径（null 表示未解析）。
  final double? gcodeTargetNozzleDiameter;

  /// AMS 湿度（%，null 表示无数据）。
  final int? amsHumidity;

  /// AMS 湿度采样时间（null 表示无数据或过期）。
  final DateTime? amsHumiditySampledAt;

  /// 当前喷嘴目标温度（℃，从 MQTT 实时状态或 filament 预设读取，null 表示未知）。
  ///
  /// 注意：process 参数预设不含喷嘴温度字段，温度来自 filament 预设或打印机实时状态。
  final int? nozzleTargetTemp;

  const CompatibilityContext({
    required this.preset,
    this.printer,
    this.material,
    this.gcodeTargetPrinterModel,
    this.gcodeTargetNozzleDiameter,
    this.amsHumidity,
    this.amsHumiditySampledAt,
    this.nozzleTargetTemp,
  });
}

/// 参数兼容性评估服务。
///
/// 纯 Dart、可单元测试的评估服务。
///
/// 评分规则：
/// - 存在任一 hard blocker → status = incompatible，score = 0
/// - 无 blocker 但有 warning → status = caution
/// - 无 blocker 无 warning 且 confidence >= 60 → status = compatible
/// - confidence < 50 → status = unknown
///
/// 硬性阻断至少覆盖：
/// - 已切片 G-code 目标机器与真实打印机不一致
/// - 喷嘴直径或能力不满足参数/材料要求
/// - 参数明确排除当前打印机
/// - 参数温度超出已知设备安全能力
/// - 构建板或构建尺寸不兼容
///
/// 警告至少覆盖：
/// - 吸湿材料所在 AMS 湿度偏高或数据过期
/// - RFID 材料推荐温度与参数温度区间冲突
/// - 磨蚀性材料与喷嘴硬度/直径组合风险
/// - 参数数据不完整或缺少机器条件
class ParameterCompatibilityService {
  ParameterCompatibilityService._();

  /// 当前规则版本。
  static const String ruleVersion = '1.0.0';

  /// AMS 湿度数据过期阈值（小时）。
  static const int amsHumidityStaleHours = 1;

  /// AMS 湿度高阈值（%）。
  static const int amsHumidityHighThreshold = 50;

  /// 评估参数兼容性。
  static CompatibilityAssessment assess(CompatibilityContext context) {
    final blockers = <CompatibilityReason>[];
    final warnings = <CompatibilityReason>[];
    final matchedFacts = <CompatibilityReason>[];
    final missingFacts = <String>[];

    final preset = context.preset;
    final printer = context.printer;
    final material = context.material;

    // ===== 收集缺失数据 =====
    if (printer == null || printer.model.isEmpty) {
      missingFacts.add('printer_model');
    }
    if (printer == null || printer.nozzleDiameter == null) {
      missingFacts.add('nozzle_diameter');
    }
    if (material == null || material.identity.canonicalId.isEmpty) {
      missingFacts.add('material_profile');
    }

    // ===== 硬性阻断 1：已切片 G-code 目标机器不一致 =====
    if (context.gcodeTargetPrinterModel != null &&
        context.gcodeTargetPrinterModel!.isNotEmpty &&
        printer != null &&
        printer.model.isNotEmpty) {
      final gcodeModel =
          PrinterModelNormalizer.normalize(context.gcodeTargetPrinterModel!);
      final printerModel = PrinterModelNormalizer.normalize(printer.model);
      if (gcodeModel != printerModel) {
        blockers.add(
          CompatibilityReason(
            ruleId: 'gcode_target_mismatch',
            title: 'G-code 目标机器不一致',
            detail: '切片时指定的目标机器为 $gcodeModel，当前打印机为 $printerModel。'
                '不同机型的运动结构、构建尺寸和 G-code 指令不兼容，直接发送可能损坏打印或设备。',
            matchedValue: 'gcode=$gcodeModel, printer=$printerModel',
            ruleVersion: ruleVersion,
          ),
        );
      } else {
        matchedFacts.add(
          CompatibilityReason(
            ruleId: 'gcode_target_match',
            title: 'G-code 目标机器匹配',
            detail: '切片目标机器与当前打印机均为 $gcodeModel。',
            matchedValue: gcodeModel,
          ),
        );
      }
    }

    // ===== 硬性阻断 2：G-code 目标喷嘴不一致 =====
    if (context.gcodeTargetNozzleDiameter != null &&
        printer != null &&
        printer.nozzleDiameter != null) {
      if ((context.gcodeTargetNozzleDiameter! - printer.nozzleDiameter!).abs() >
          0.001) {
        blockers.add(
          CompatibilityReason(
            ruleId: 'gcode_nozzle_mismatch',
            title: '喷嘴直径不一致',
            detail: 'G-code 切片时使用 ${context.gcodeTargetNozzleDiameter}mm 喷嘴，'
                '当前打印机安装 ${printer.nozzleDiameter}mm 喷嘴。'
                '不同直径的线宽、挤出量和层高不匹配，直接打印会导致品质严重下降或堵头。',
            matchedValue:
                'gcode=${context.gcodeTargetNozzleDiameter}mm, printer=${printer.nozzleDiameter}mm',
            ruleVersion: ruleVersion,
          ),
        );
      }
    }

    // ===== 硬性阻断 3：参数明确排除当前打印机 =====
    if (printer != null &&
        printer.model.isNotEmpty &&
        preset.compatiblePrinters.isNotEmpty) {
      final printerModel = PrinterModelNormalizer.normalize(printer.model);
      final presetCompatible = preset.compatiblePrinters
          .map((p) => PrinterModelNormalizer.normalize(p))
          .where((p) => p.isNotEmpty)
          .toSet();
      if (presetCompatible.isNotEmpty &&
          !presetCompatible.contains(printerModel)) {
        blockers.add(
          CompatibilityReason(
            ruleId: 'preset_excludes_printer',
            title: '参数不兼容当前打印机',
            detail: '参数预设声明的兼容打印机为 ${preset.compatiblePrinters.join("、")}，'
                '当前打印机 $printerModel 不在列表中。',
            matchedValue:
                'printer=$printerModel, compatible=${presetCompatible.join(",")}',
            ruleVersion: ruleVersion,
          ),
        );
      } else if (presetCompatible.contains(printerModel)) {
        matchedFacts.add(
          CompatibilityReason(
            ruleId: 'preset_includes_printer',
            title: '打印机在参数兼容列表中',
            detail: '参数预设明确兼容 $printerModel。',
            matchedValue: printerModel,
          ),
        );
      }
    }

    // ===== 硬性阻断 4：喷嘴目标温度超出设备安全能力 =====
    if (printer != null && printer.maxNozzleTemp != null) {
      final targetTemp = context.nozzleTargetTemp;
      if (targetTemp != null && targetTemp > printer.maxNozzleTemp!) {
        blockers.add(
          CompatibilityReason(
            ruleId: 'nozzle_temp_exceeds_device',
            title: '喷嘴温度超出设备能力',
            detail: '当前喷嘴目标温度为 $targetTemp℃，'
                '打印机 ${printer.model} 最大喷嘴温度为 ${printer.maxNozzleTemp}℃。'
                '超温操作有起火风险。',
            matchedValue:
                'target=${targetTemp}C, max=${printer.maxNozzleTemp}C',
            ruleVersion: ruleVersion,
          ),
        );
      }
    }

    // ===== 硬性阻断 5：构建板不兼容 =====
    if (printer != null &&
        printer.plateType != null &&
        printer.plateType!.isNotEmpty &&
        preset.plateType != null &&
        preset.plateType!.isNotEmpty) {
      final requiredPlate = _normalizePlateType(preset.plateType!);
      final activePlate = _normalizePlateType(printer.plateType!);
      if (requiredPlate != activePlate) {
        blockers.add(
          CompatibilityReason(
            ruleId: 'plate_type_mismatch',
            title: '打印板类型不一致',
            detail: '参数预设要求 $requiredPlate，当前选择的是 $activePlate。'
                '不同打印板的表面和温度要求不同，请切换打印板或重新确认参数。',
            matchedValue: 'preset=$requiredPlate, printer=$activePlate',
            ruleVersion: ruleVersion,
          ),
        );
      } else {
        matchedFacts.add(
          CompatibilityReason(
            ruleId: 'plate_type_match',
            title: '打印板类型匹配',
            detail: '参数预设与当前打印板均为 $requiredPlate。',
            matchedValue: requiredPlate,
            ruleVersion: ruleVersion,
          ),
        );
      }
    }

    // ===== 硬性阻断 6：磨蚀性材料使用不锈钢喷嘴 =====
    if (material != null &&
        material.requiresHardenedNozzle &&
        printer != null &&
        printer.nozzleType != null &&
        printer.nozzleType == 'stainless_steel') {
      blockers.add(
        CompatibilityReason(
          ruleId: 'abrasive_material_soft_nozzle',
          title: '磨蚀性材料需硬化钢喷嘴',
          detail: '材料 ${material.identity.displayName} 含碳纤维/玻璃纤维等磨蚀性成分，'
              '使用不锈钢喷嘴会快速磨损喷嘴孔径，导致挤出异常和品质下降。'
              '请更换硬化钢喷嘴后再打印。',
          matchedValue:
              'material=${material.identity.family}, nozzle=${printer.nozzleType}',
          ruleVersion: ruleVersion,
        ),
      );
    }

    // ===== 警告 1：吸湿材料 AMS 湿度偏高 =====
    if (material != null && material.identity.isHygroscopic) {
      if (context.amsHumidity == null) {
        warnings.add(
          CompatibilityReason(
            ruleId: 'hygroscopic_no_humidity_data',
            title: '吸湿材料无湿度数据',
            detail: '材料 ${material.identity.displayName} 属于吸湿性较强的材料族，'
                '但未读取到 AMS 湿度数据。建议确认 AMS 湿度后再打印。',
            ruleVersion: ruleVersion,
          ),
        );
      } else if (context.amsHumidity! > amsHumidityHighThreshold) {
        warnings.add(
          CompatibilityReason(
            ruleId: 'hygroscopic_high_humidity',
            title: 'AMS 湿度偏高',
            detail: '材料 ${material.identity.displayName} 属于吸湿性材料，'
                '当前 AMS 湿度为 ${context.amsHumidity}%，超过 $amsHumidityHighThreshold% 阈值。'
                '建议先干燥耗材再打印，否则可能导致气泡、拉丝和强度下降。',
            matchedValue: 'humidity=${context.amsHumidity}%',
            ruleVersion: ruleVersion,
          ),
        );
      }

      // 湿度数据过期
      if (context.amsHumiditySampledAt != null) {
        final age = DateTime.now().difference(context.amsHumiditySampledAt!);
        if (age.inHours > amsHumidityStaleHours) {
          warnings.add(
            CompatibilityReason(
              ruleId: 'humidity_data_stale',
              title: '湿度数据已过期',
              detail: 'AMS 湿度数据采样于 ${age.inHours} 小时前，'
                  '可能已不准确。建议重新连接打印机获取最新数据。',
              matchedValue: 'age=${age.inHours}h',
              ruleVersion: ruleVersion,
            ),
          );
        }
      }
    }

    // ===== 警告 2：RFID 材料推荐温度与当前喷嘴温度冲突 =====
    if (material != null &&
        material.nozzleTempMin != null &&
        material.nozzleTempMax != null &&
        context.nozzleTargetTemp != null) {
      final targetTemp = context.nozzleTargetTemp!;
      if (targetTemp < material.nozzleTempMin! ||
          targetTemp > material.nozzleTempMax!) {
        warnings.add(
          CompatibilityReason(
            ruleId: 'material_temp_conflict',
            title: '喷嘴温度超出材料推荐范围',
            detail: '当前喷嘴目标温度为 $targetTemp℃，'
                '材料 ${material.identity.displayName} 的推荐温度范围为 '
                '${material.nozzleTempMin}-${material.nozzleTempMax}℃。'
                '超出推荐范围可能导致附着力差、流动性异常或材料降解。',
            matchedValue:
                'target=${targetTemp}C, material=${material.nozzleTempMin}-${material.nozzleTempMax}C',
            ruleVersion: ruleVersion,
          ),
        );
      } else {
        matchedFacts.add(
          CompatibilityReason(
            ruleId: 'material_temp_ok',
            title: '喷嘴温度在材料推荐范围内',
            detail: '当前喷嘴目标温度 $targetTemp℃ 在材料推荐范围 '
                '${material.nozzleTempMin}-${material.nozzleTempMax}℃ 内。',
            matchedValue: '${targetTemp}C',
          ),
        );
      }
    }

    // ===== 警告 3：磨蚀性材料 + 小直径喷嘴风险 =====
    if (material != null &&
        material.identity.isAbrasive &&
        printer != null &&
        printer.nozzleDiameter != null &&
        printer.nozzleDiameter! < 0.4) {
      warnings.add(
        CompatibilityReason(
          ruleId: 'abrasive_small_nozzle',
          title: '磨蚀性材料搭配小直径喷嘴',
          detail: '材料 ${material.identity.displayName} 含磨蚀性成分，'
              '搭配 ${printer.nozzleDiameter}mm 小直径喷嘴会加速磨损，'
              '建议使用 0.6mm 或更大直径的硬化钢喷嘴。',
          matchedValue: 'nozzle=${printer.nozzleDiameter}mm',
          ruleVersion: ruleVersion,
        ),
      );
    }

    // ===== 警告 4：参数数据不完整 =====
    if (preset.compatiblePrinters.isEmpty) {
      warnings.add(
        const CompatibilityReason(
          ruleId: 'preset_no_compatible_printers',
          title: '参数未指定兼容打印机',
          detail: '参数预设未声明兼容打印机型号，无法做精确匹配。'
              '建议在参数编辑页选择兼容打印机。',
          ruleVersion: ruleVersion,
        ),
      );
    }

    // ===== 计算 confidence =====
    int confidence = 100;
    for (final _ in missingFacts) {
      confidence -= 25;
    }
    confidence = confidence.clamp(0, 100);

    // ===== 计算 status 和 score =====
    CompatibilityStatus status;
    int score;

    if (blockers.isNotEmpty) {
      status = CompatibilityStatus.incompatible;
      score = 0;
    } else if (confidence < 50) {
      status = CompatibilityStatus.unknown;
      score = 50;
    } else if (warnings.isNotEmpty) {
      status = CompatibilityStatus.caution;
      // 每个 warning 扣 10 分，最低 40
      score = (100 - warnings.length * 10).clamp(40, 100);
    } else {
      status = CompatibilityStatus.compatible;
      score = 100;
    }

    return CompatibilityAssessment(
      status: status,
      score: score,
      confidence: confidence,
      blockers: blockers,
      warnings: warnings,
      matchedFacts: matchedFacts,
      missingFacts: missingFacts,
      ruleVersion: ruleVersion,
    );
  }

  static String _normalizePlateType(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }
}
