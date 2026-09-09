import 'dart:io';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import '../../../core/utils/zip_safety.dart';

import '../../../core/services/slice_artifact_hash_service.dart';
import 'filament_change_point.dart';
import 'slice_result.dart';

/// G-code 解析器。流式读取 G-code 文件，提取切片软件写入的注释信息。
///
/// **BambuStudio 真实 G-code 头部格式**（2026/07 实测，版本 02.07.01.57）：
/// ```text
/// ; HEADER_BLOCK_START
/// ; BambuStudio 02.07.01.57
/// ; model printing time: 4h 25m 15s; total estimated time: 4h 31m 30s
/// ; total layer number: 651
/// ; total filament length [mm] : 30246.24
/// ; total filament volume [cm^3] : 72750.73
/// ; total filament weight [g] : 96.03
/// ; filament_density: 1.32,1.32,1.32
/// ; filament_diameter: 1.75,1.75,1.75
/// ; HEADER_BLOCK_END
/// ```
///
/// **注意**：早期版本曾按 PrusaSlicer 格式（`total filament used [g] = X`、
/// `total layer count = N`、等号分隔）写正则，与 BambuStudio 真实输出
/// （`total filament weight [g] : X`、`total layer number: N`、冒号分隔）
/// 完全不匹配，导致所有字段解析失败返回 null —— 已修正对齐真实格式。
///
/// **精细模式**：解析 G-code 行中的 `E` 字段（挤出量），
/// 按 `;LAYER_CHANGE` 注释分段，构建"层号→累计克数"映射表。
/// 挤出量换算：`grams = E_mm × π × (diameter/2)² × density`
/// 其中 density 优先从 G-code 头部 `filament_density` 读取，缺失时按材质默认值。
class GcodeParser {
  GcodeParser._();

  /// 默认耗材直径（mm）。3D 打印标准 1.75mm。
  static const double defaultFilamentDiameter = 1.75;

  /// 默认耗材密度（g/cm³）。PLA 默认值。
  /// 不同材质密度不同，精细模式需要按材质传入准确值。
  ///
  /// 密度参考值（来源：拓竹官方耗材规格书 + 3DPrintingGeek 材料数据库）：
  /// - PLA 系列：1.24-1.30（PLA-CF 因碳纤维增强略高）
  /// - PETG 系列：1.27
  /// - ABS/ASA：1.04-1.07
  /// - TPU/TPE：1.21
  /// - PC：1.20
  /// - PA 系列：1.02-1.19（PA6 较高，PA12 较低，PA-CF 因碳纤维略高）
  /// - PPS/PPA：1.22-1.35（高温工程材料，密度较高）
  /// - PE/PP：0.90-0.95（低密度聚烯烃，浮水）
  /// - PVA/BVOH/HIPS：1.04-1.23（水溶/支撑材料）
  /// - PHA/EVA：0.95-1.20（生物降解/弹性体）
  /// - PCTG：1.23（PETG 改性版）
  static const Map<String, double> materialDensity = {
    // ===== PLA 系列（拓竹官方 + 第三方细分型号） =====
    // 基础 PLA：1.24 g/cm³（拓竹官方 TDS）
    'PLA': 1.24,
    'PLA+': 1.24, // 高韧性 PLA，密度同基础
    'PLA-Basic': 1.24, // 拓竹 PLA Basic
    'PLA-Dynamic': 1.24, // 拓竹高韧性 PLA
    'PLA-HF': 1.24, // 高流速 PLA
    'PLA-HS': 1.24, // 高速 PLA
    // 美学 PLA（含填料，密度与基础 PLA 有差异）
    'PLA-Matte': 1.24, // 拓竹哑光 PLA
    'PLA-Silk': 1.27, // 拓竹丝绸 PLA（含润滑剂，略高）
    'PLA-Galaxy': 1.27, // 拓竹银河 PLA（含金属粉末）
    'PLA-Marble': 1.30, // 拓竹大理石 PLA（含矿物填料）
    'PLA-Metal': 1.35, // 拓竹金属色 PLA（含金属粉末，更重）
    'PLA-Glow': 1.25, // 拓竹夜光 PLA（含夜光粉）
    'PLA-Wood': 1.28, // 拓竹木质 PLA（含木粉）
    'PLA-Aero': 1.00, // 拓竹轻量化发泡 PLA（打印时可发泡到 0.8）
    // PLA 增强
    'PLA-CF': 1.30, // 碳纤维增强
    'PLA-GF': 1.31, // 玻璃纤维增强

    // ===== PETG / PET 系列 =====
    'PETG': 1.27,
    'PETG-Basic': 1.27, // 拓竹 PETG Basic
    'PETG-Translucent': 1.27, // 拓竹半透明 PETG
    'PETG-HF': 1.27, // 拓竹 PETG HF（高流速）
    'PETG-CF': 1.30, // 碳纤维增强
    'PCTG': 1.23, // PETG 改性版
    'PET': 1.33, // 基础 PET（结晶态，比 PETG 高）
    'PET-CF': 1.31, // 拓竹 PET-CF（工业级，超低吸湿）

    // ===== ABS / ASA =====
    'ABS': 1.04,
    'ABS-GF': 1.10, // 拓竹 ABS-GF
    'ABS-ESD': 1.05, // 防静电 ABS
    'ASA': 1.07, // 拓竹 ASA（耐候）
    'ASA-Aero': 1.00, // 拓竹轻量化 ASA

    // ===== TPU / TPE（弹性体） =====
    'TPU': 1.21,
    'TPU-95A': 1.21, // 拓竹 TPU 95A
    'TPU-95A-HF': 1.21, // 拓竹 TPU 95A HF
    'TPU-85A': 1.22, // 拓竹 TPU 85A（更软，密度略高）
    'TPE': 1.20,

    // ===== PC（聚碳酸酯） =====
    'PC': 1.20,
    'PC-FR': 1.20, // 阻燃 PC
    'PC-Abs': 1.15, // PC/ABS 合金

    // ===== PA 系列（Nylon，拓竹官方多款） =====
    'Nylon': 1.14,
    'Nylon-CF': 1.19,
    'PA': 1.14,
    'PA-CF': 1.19,
    'PA6': 1.13,
    'PA6-CF': 1.19, // 拓竹 PA6-CF
    'PA6-GF': 1.18, // 拓竹 PA6-GF（GF 增强比 CF 略低）
    'PA12': 1.02,
    'PA12-CF': 1.10,
    'PAHT-CF': 1.20, // 拓竹 PAHT-CF（高温尼龙，比 PA-CF 略高）

    // ===== 高温工程材料（拓竹官方 filament-guide） =====
    'PPS': 1.35,
    'PPS-CF': 1.42, // 拓竹 PPS-CF（CF 增强）
    'PPA': 1.22,
    'PPA-CF': 1.28, // 拓竹 PPA-CF
    'PPA-GF': 1.24, // PPA 玻璃纤维增强
    'PEEK': 1.32,
    'PEEK-CF': 1.40,
    'PEI': 1.27, // ULTEM

    // ===== 聚烯烃（低密度，浮水） =====
    'PE': 0.95,
    'PP': 0.90,

    // ===== 水溶 / 支撑材料 =====
    'PVA': 1.23, // 水溶支撑
    'BVOH': 1.20, // 水溶支撑
    'HIPS': 1.04, // 可溶支撑
    'Support': 1.04, // 通用支撑（按 HIPS 估算）
    'Support-G': 1.04, // 拓竹 Support G
    'Support-W': 1.23, // 拓竹 Support W（水溶，按 PVA）

    // ===== 生物降解 / 弹性体 =====
    'PHA': 1.20,
    'EVA': 0.95,
  };

  /// 解析 G-code 文件，提取切片信息。
  ///
  /// [enableLayerMapping] = true 时启用精细模式，构建层号→累计克数映射。
  /// 大文件（>100MB）解析较慢，建议在后台 isolate 执行。
  ///
  /// 返回 null 表示解析失败（文件不存在或不是有效 G-code）。
  static Future<SliceResult?> parseFile(
    String filePath, {
    bool enableLayerMapping = false,
    String materialType = 'PLA',
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return null;

    final fileName = filePath.split(RegExp(r'[/\\]')).last;
    // 任务名：去掉扩展名 + PID 前缀（BambuStudio 临时 G-code 形如 .43208.0.gcode）
    final taskName = fileName
        .replaceAll(RegExp(r'^\.\d+\.\d+\.'), '')
        .replaceAll(RegExp(r'\.(gcode|g|gc|ngc)$'), '');

    // 第一阶段：读头部注释（HEADER_BLOCK_START 到 HEADER_BLOCK_END，
    // 外加 CONFIG_BLOCK 里的 filament_density/diameter）
    final headerLines = <String>[];
    bool sawHeaderEnd = false;
    var headerLineCount = 0;
    await for (final line in _readLines(file)) {
      if (headerLineCount++ >= 2000) break;
      headerLines.add(line);
      // HEADER_BLOCK_END 后还有 CONFIG_BLOCK，里面也有 filament_density
      if (line.contains('HEADER_BLOCK_END')) sawHeaderEnd = true;
      // CONFIG_BLOCK 里的 filament_density 行也要读到
      if (sawHeaderEnd && line.contains('filament_density')) {
        // 继续读一点
      }
      // PLATER_BLOCK_START 之后是 G-code 主体，不再有元信息
      if (line.contains('PLATER_BLOCK_START')) break;
    }
    String? slicerName;
    String? slicerVersion;
    String? printSettingsId;
    String? printerSettingsId;
    double? nozzleDiameter;
    String? plateType;
    // 多色任务：BambuStudio 头部用逗号分隔每色的克数/长度/密度
    // 例如 `; total filament weight [g] : 104.04,13.23` 表示 T0=104.04g, T1=13.23g
    List<double> gramsPerTool = [];
    List<double> lengthMmPerTool = [];
    int? totalLayers;
    int? estimatedSeconds;
    int? toolChangeCount;
    // 从 G-code 头部读取的真实密度（多色任务逗号分隔）
    // 直径目前未直接使用（_lengthToGrams 用默认 1.75），保留解析以备扩展
    List<double> densities = [];
    // CONFIG_BLOCK 里的耗材元信息（分号分隔多色）
    // ; filament_type = PLA;PLA
    // ; filament_colour = #FFFF00;#008080
    // ; filament_vendor = "Bambu Lab";"Bambu Lab"
    List<String> materialTypes = [];
    List<String> colorHexes = [];
    List<String> vendors = [];
    // 完整型号名（如 "Bambu PLA Silk @BBL X1C"）和 SKU（如 "GFA05"）
    List<String> filamentSettingsIds = [];
    List<String> filamentSkus = [];
    // AMS 映射：T→AMS 全局槽位号。`; ams_mapping = [1,3,0,2]`
    List<int>? amsMapping;
    // PrusaSlicer 格式的每工具克数（BambuStudio 通常不给，但兼容解析）
    final perToolGrams = <int, double>{};
    final perToolLengthMm = <int, double>{};

    for (final line in headerLines) {
      final trimmed = line.trim();

      printSettingsId ??= _configValue(trimmed, 'print_settings_id');
      printerSettingsId ??= _configValue(trimmed, 'printer_settings_id');
      nozzleDiameter ??= double.tryParse(
        _configValue(trimmed, 'nozzle_diameter') ?? '',
      );
      plateType ??= _configValue(trimmed, 'curr_bed_type') ??
          _configValue(trimmed, 'plate_type') ??
          _configValue(trimmed, 'bed_type');

      // 切片软件标识：`; BambuStudio 02.07.01.57`
      final bslMatch = RegExp(
        r';\s*BambuStudio\s+([\d.]+)',
      ).firstMatch(trimmed);
      if (bslMatch != null) {
        slicerName = 'BambuStudio';
        slicerVersion = bslMatch.group(1);
        continue;
      }
      // 兼容 PrusaSlicer：`; generated by PrusaSlicer 2.5.0`
      final genMatch = RegExp(
        r';\s*generated by (\S+)\s+(\d+\.\d+\.\d+)',
      ).firstMatch(trimmed);
      if (genMatch != null) {
        slicerName = genMatch.group(1);
        slicerVersion = genMatch.group(2);
        continue;
      }

      // 每色耗材克数（BambuStudio 格式）：
      // 单色 `; total filament weight [g] : 96.03`
      // 多色 `; total filament weight [g] : 104.04,13.23`（T0,T1）
      final gMatch = RegExp(
        r';\s*total filament weight \[g\]\s*:\s*([\d.,]+)',
      ).firstMatch(trimmed);
      if (gMatch != null) {
        gramsPerTool = _parseDoubleList(gMatch.group(1)!);
        continue;
      }
      // 兼容 PrusaSlicer 格式：`; total filament used [g] = 23.56`
      final gMatch2 = RegExp(
        r';\s*total filament used \[g\]\s*=\s*([\d.,]+)',
      ).firstMatch(trimmed);
      if (gMatch2 != null && gramsPerTool.isEmpty) {
        gramsPerTool = _parseDoubleList(gMatch2.group(1)!);
        continue;
      }

      // 每色耗材长度（BambuStudio）：
      // 单色 `; total filament length [mm] : 30246.24`
      // 多色 `; total filament length [mm] : 32769.17,4166.38`
      final mmMatch = RegExp(
        r';\s*total filament length \[mm\]\s*:\s*([\d.,]+)',
      ).firstMatch(trimmed);
      if (mmMatch != null) {
        lengthMmPerTool = _parseDoubleList(mmMatch.group(1)!);
        continue;
      }
      // 兼容 PrusaSlicer
      final mmMatch2 = RegExp(
        r';\s*total filament used \[mm\]\s*=\s*([\d.,]+)',
      ).firstMatch(trimmed);
      if (mmMatch2 != null && lengthMmPerTool.isEmpty) {
        lengthMmPerTool = _parseDoubleList(mmMatch2.group(1)!);
        continue;
      }

      // 总层数（BambuStudio）：`; total layer number: 651`
      final layerMatch = RegExp(
        r';\s*total layer number\s*:\s*(\d+)',
      ).firstMatch(trimmed);
      if (layerMatch != null) {
        totalLayers = int.tryParse(layerMatch.group(1)!);
        continue;
      }
      // 兼容 PrusaSlicer
      final layerMatch2 = RegExp(
        r';\s*total layer count\s*=\s*(\d+)',
      ).firstMatch(trimmed);
      if (layerMatch2 != null && totalLayers == null) {
        totalLayers = int.tryParse(layerMatch2.group(1)!);
        continue;
      }

      // 预计时长（BambuStudio）：`; model printing time: 4h 25m 15s; total estimated time: 4h 31m 30s`
      // 取 total estimated time（更准确，含准备时间）
      final timeMatch = RegExp(
        r';\s*total estimated time\s*:\s*([^;]+)',
      ).firstMatch(trimmed);
      if (timeMatch != null) {
        estimatedSeconds = _parseDuration(timeMatch.group(1)!);
        continue;
      }
      // 兼容 PrusaSlicer
      final timeMatch2 = RegExp(
        r';\s*estimated printing time.*?=\s*(.+)',
      ).firstMatch(trimmed);
      if (timeMatch2 != null && estimatedSeconds == null) {
        estimatedSeconds = _parseDuration(timeMatch2.group(1)!);
        continue;
      }

      // 换料次数（兼容两种格式）
      final tcMatch = RegExp(
        r';\s*toolchange count\s*[=:]\s*(\d+)',
      ).firstMatch(trimmed);
      if (tcMatch != null) {
        toolChangeCount = int.tryParse(tcMatch.group(1)!);
        continue;
      }

      // 耗材密度：`; filament_density: 1.32,1.32,1.32`
      final densityMatch = RegExp(
        r';\s*filament_density\s*:\s*([\d.,]+)',
      ).firstMatch(trimmed);
      if (densityMatch != null) {
        densities = densityMatch
            .group(1)!
            .split(',')
            .map((s) => double.tryParse(s.trim()) ?? 0)
            .where((d) => d > 0)
            .toList();
        continue;
      }

      // 耗材直径（已解析但暂未使用，保留以备多色精细计算扩展）
      // ; filament_diameter: 1.75,1.75,1.75

      // 耗材材质：`; filament_type = PLA;PLA`（分号分隔多色，注意是 = 不是 :）
      // 用分号分割，因为颜色 HEX 和材质名里都没有分号
      final typeMatch = RegExp(
        r';\s*filament_type\s*=\s*(.+)',
      ).firstMatch(trimmed);
      if (typeMatch != null) {
        materialTypes = _parseSemicolonList(typeMatch.group(1)!);
        continue;
      }

      // 耗材颜色 HEX：`; filament_colour = #FFFF00;#008080`
      final colorMatch = RegExp(
        r';\s*filament_colour\s*=\s*(.+)',
      ).firstMatch(trimmed);
      if (colorMatch != null) {
        colorHexes = _parseSemicolonList(colorMatch.group(1)!);
        continue;
      }

      // 耗材厂家：`; filament_vendor = "Bambu Lab";"Bambu Lab"`
      // 去掉引号后分割
      final vendorMatch = RegExp(
        r';\s*filament_vendor\s*=\s*(.+)',
      ).firstMatch(trimmed);
      if (vendorMatch != null) {
        vendors = _parseSemicolonList(vendorMatch.group(1)!)
            .map((s) => s.replaceAll('"', '').trim())
            .where((s) => s.isNotEmpty)
            .toList();
        continue;
      }

      // 耗材完整型号名：`; filament_settings_id = "Bambu PLA Silk @BBL X1C"`
      // 这是最准确的型号标识，含品牌+系列+配置（如 Bambu PLA Silk、Bambu PETG HF）
      // 去掉 @BBL xxx 后缀得到纯型号名（如 "Bambu PLA Silk"）
      final settingsIdMatch = RegExp(
        r';\s*filament_settings_id\s*=\s*(.+)',
      ).firstMatch(trimmed);
      if (settingsIdMatch != null) {
        filamentSettingsIds = _parseSemicolonList(settingsIdMatch.group(1)!)
            .map((s) => s.replaceAll('"', '').trim())
            .where((s) => s.isNotEmpty)
            .toList();
        continue;
      }

      // 耗材 SKU 编码：`; filament_ids = GFA05;GFA05`
      // 拓竹耗材的官方产品编号（GFA05=PLA Silk、GFL00=PLA Basic 等）
      final filamentIdMatch = RegExp(
        r';\s*filament_ids\s*=\s*(.+)',
      ).firstMatch(trimmed);
      if (filamentIdMatch != null) {
        filamentSkus = _parseSemicolonList(filamentIdMatch.group(1)!)
            .map((s) => s.replaceAll('"', '').trim())
            .where((s) => s.isNotEmpty)
            .toList();
        continue;
      }

      // AMS 映射：`; ams_mapping = [1,3,0,2]`（可能含负数，如 TPU 直通 -1）
      // T→AMS 全局槽位映射，多色任务按此映射扣减对应通道耗材
      // C2 修复：用 [^\]]* 匹配方括号内所有内容（含负号），
      // 再用 int.tryParse 解析（int.tryParse 天然支持负数）
      final amsMappingMatch = RegExp(
        r';\s*ams_mapping\s*=\s*\[([^\]]*)\]',
      ).firstMatch(trimmed);
      if (amsMappingMatch != null) {
        final numsStr = amsMappingMatch.group(1)!;
        amsMapping = numsStr
            .split(',')
            .map((s) => int.tryParse(s.trim()))
            .whereType<int>()
            .toList();
        // 空数组也保留（表示无 AMS 映射）
        continue;
      }

      // 每工具耗材克数（PrusaSlicer 格式，BambuStudio 通常不给）
      final ptGMatch = RegExp(
        r';\s*filament used \[g\]\s*T(\d+)\s*=\s*([\d.]+)',
      ).firstMatch(trimmed);
      if (ptGMatch != null) {
        final tool = int.parse(ptGMatch.group(1)!);
        final g = double.tryParse(ptGMatch.group(2)!) ?? 0;
        perToolGrams[tool] = g;
        continue;
      }
      final ptMmMatch = RegExp(
        r';\s*filament used \[mm\]\s*T(\d+)\s*=\s*([\d.]+)',
      ).firstMatch(trimmed);
      if (ptMmMatch != null) {
        final tool = int.parse(ptMmMatch.group(1)!);
        final mm = double.tryParse(ptMmMatch.group(2)!) ?? 0;
        perToolLengthMm[tool] = mm;
        continue;
      }
    }

    // 如果克数列表为空但长度列表非空，用长度反推每色克数（每色用各自密度）
    // 修复：原实现循环内对整个列表 map 用单一密度 d，导致多色任务每色克数
    // 全部用最后一个 i 的密度计算。改为按索引逐色取密度。
    if (gramsPerTool.isEmpty && lengthMmPerTool.isNotEmpty) {
      gramsPerTool = <double>[];
      for (int i = 0; i < lengthMmPerTool.length; i++) {
        final d = i < densities.length ? densities[i] : null;
        gramsPerTool.add(_lengthToGrams(lengthMmPerTool[i], materialType, d));
      }
    }
    if (gramsPerTool.isEmpty) {
      // 既无克数也无长度，无法用
      return null;
    }

    // 构建 filaments 列表
    // BambuStudio 多色任务：gramsPerTool/lengthMmPerTool 已是按工具分隔的列表
    // PrusaSlicer 格式：perToolGrams/perToolLengthMm 按 Tn= 解析（优先级更高）
    final filaments = <FilamentUsage>[];
    if (perToolGrams.isNotEmpty || perToolLengthMm.isNotEmpty) {
      final allTools = <int>{
        ...perToolGrams.keys,
        ...perToolLengthMm.keys,
      }.toList()
        ..sort();
      for (final tool in allTools) {
        final d = tool < densities.length ? densities[tool] : null;
        final g = perToolGrams[tool] ??
            _lengthToGrams(perToolLengthMm[tool] ?? 0, materialType, d);
        filaments.add(
          FilamentUsage(
            toolIndex: tool,
            grams: g,
            lengthMm: perToolLengthMm[tool] ?? 0,
            colorHex: tool < colorHexes.length ? colorHexes[tool] : null,
            materialType:
                tool < materialTypes.length ? materialTypes[tool] : null,
            vendor: tool < vendors.length ? vendors[tool] : null,
            settingsId: tool < filamentSettingsIds.length
                ? filamentSettingsIds[tool]
                : null,
            sku: tool < filamentSkus.length ? filamentSkus[tool] : null,
          ),
        );
      }
    } else {
      // BambuStudio 格式：按逗号分隔的列表构建每色 FilamentUsage
      for (int i = 0; i < gramsPerTool.length; i++) {
        if (gramsPerTool[i] <= 0.01) continue;
        filaments.add(
          FilamentUsage(
            toolIndex: i,
            grams: gramsPerTool[i],
            lengthMm: i < lengthMmPerTool.length ? lengthMmPerTool[i] : 0,
            colorHex: i < colorHexes.length ? colorHexes[i] : null,
            materialType: i < materialTypes.length ? materialTypes[i] : null,
            vendor: i < vendors.length ? vendors[i] : null,
            settingsId:
                i < filamentSettingsIds.length ? filamentSettingsIds[i] : null,
            sku: i < filamentSkus.length ? filamentSkus[i] : null,
          ),
        );
      }
    }

    // Scan the full file only when more than one tool has positive usage.
    // Header color lists alone are not evidence of an external multicolor job.
    final activeToolIndices =
        filaments.where((f) => f.grams > 0.01).map((f) => f.toolIndex).toSet();
    final filamentChangePoints = activeToolIndices.length > 1
        ? await parseFilamentChangeLayers(
            filePath,
            colorHexes: colorHexes,
            materialTypes: materialTypes,
            validToolIndices: activeToolIndices,
          )
        : const <FilamentChangePoint>[];

    // 精细模式：解析层级累计克数映射
    // 用真实密度（优先）或材质默认密度
    Map<int, double>? layerMap;
    if (enableLayerMapping) {
      final density = densities.isNotEmpty ? densities.first : null;
      layerMap = await _parseLayerMapping(file, materialType, density);
    }

    // 尝试读取同目录的 origin.txt 获取原始文件名。
    // BambuStudio 缓存的 G-code 文件名形如 `.43208.0.gcode`（PID.plate），
    // 不可读；同目录的 origin.txt 记录了源模型文件名（如 `悟空.3mf`）。
    final originName = await _readOriginName(filePath);
    final finalTaskName = originName ?? taskName;
    final artifact = await SliceArtifactHashService.computeStable(filePath);

    return SliceResult(
      filePath: filePath,
      taskName: finalTaskName,
      filaments: filaments,
      filamentChangePoints: filamentChangePoints,
      estimatedSeconds: estimatedSeconds ?? 0,
      toolChangeCount: (toolChangeCount ?? 0) > filamentChangePoints.length
          ? toolChangeCount!
          : filamentChangePoints.length,
      totalLayers: totalLayers ?? 0,
      slicerName: slicerName ?? 'Unknown',
      slicerVersion: slicerVersion,
      printSettingsId: printSettingsId,
      printerSettingsId: printerSettingsId,
      nozzleDiameter: nozzleDiameter,
      plateType: plateType,
      artifactSha256: artifact?.sha256Hex,
      artifactSize: artifact?.size,
      artifactModifiedAt: artifact?.modifiedAt,
      layerCumulativeGrams: layerMap,
      amsMapping: amsMapping,
    );
  }

  static String? _configValue(String line, String key) {
    final match = RegExp(
      '^;\\s*${RegExp.escape(key)}\\s*[=:]\\s*(.+)\\s*\$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return null;
    var value = match.group(1)!.trim();
    if (value.startsWith('[') && value.endsWith(']')) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.contains(',')) value = value.split(',').first.trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    return value.isEmpty ? null : value;
  }

  /// 精细模式核心：流式扫描整个 G-code，
  /// 按 `;LAYER_CHANGE` 或 `;LAYER:0` 注释切层，
  /// 累加每层的 E 字段挤出量，构建层号→累计克数映射。
  ///
  /// G-code 挤出量 E 字段是累计值（绝对挤出模式），
  /// 所以相邻两层的 E 差值 = 该层消耗的耗材长度。
  static Future<Map<int, double>> _parseLayerMapping(
    File file,
    String materialType,
    double? overrideDensity,
  ) async {
    final result = <int, double>{};
    int currentLayer = -1;
    double lastE = 0.0;
    double cumulativeGrams = 0.0;
    bool hasSeenE = false;

    await for (final line in _readLines(file)) {
      // 层切换标记（BambuStudio 格式：`;LAYER_CHANGE` 后跟 `;Z_HEIGHT` 或 `;LAYER:N`）
      final layerChangeMatch = RegExp(
        r';\s*LAYER:(\d+)',
      ).firstMatch(line);
      if (layerChangeMatch != null) {
        final newLayer = int.tryParse(layerChangeMatch.group(1)!) ?? 0;
        if (currentLayer >= 0) {
          result[currentLayer] = cumulativeGrams;
        }
        currentLayer = newLayer;
        continue;
      }
      if (line.contains(';LAYER_CHANGE')) {
        if (currentLayer >= 0) {
          result[currentLayer] = cumulativeGrams;
        }
        currentLayer++;
        continue;
      }

      // 解析 G1/G0 移动指令的 E 字段：`G1 X10 Y20 E1.234` 或紧凑格式 `G1X10Y20E1.234`
      // E 是累计挤出量（mm）。修复：原正则要求 G0/G1 后必须有空格，部分切片软件
      // 输出紧凑格式（无空格）会漏解析挤出量。放宽为 G[01] 后可有可无空格。
      final gMatch = RegExp(r'^G[01]\s?.*E([\d.]+)').firstMatch(line);
      if (gMatch != null) {
        final e = double.tryParse(gMatch.group(1)!) ?? 0;
        if (hasSeenE && e > lastE) {
          final delta = e - lastE;
          cumulativeGrams +=
              _lengthToGrams(delta, materialType, overrideDensity);
        }
        lastE = e;
        hasSeenE = true;
      }
    }
    // 最后一层
    if (currentLayer >= 0) {
      result[currentLayer] = cumulativeGrams;
    }
    return result;
  }

  /// 解析逗号分隔的数字列表，如 `"104.04,13.23"` → `[104.04, 13.23]`。
  /// 单个值 `"96.03"` → `[96.03]`。空值/无效返回空列表。
  /// 用于 BambuStudio G-code 头部的多色 filament weight/length/density 字段。
  static List<double> _parseDoubleList(String raw) {
    return raw
        .split(',')
        .map((s) => double.tryParse(s.trim()))
        .whereType<double>()
        .toList();
  }

  /// 解析分号分隔的字符串列表，如 `"PLA;PLA"` → `["PLA", "PLA"]`，
  /// `"#FFFF00;#008080"` → `["#FFFF00", "#008080"]`。
  /// 用于 BambuStudio G-code CONFIG_BLOCK 的多色元信息字段：
  /// `; filament_type = PLA;PLA`
  /// `; filament_colour = #FFFF00;#008080`
  /// `; filament_vendor = "Bambu Lab";"Bambu Lab"`
  /// （用分号分隔是因为颜色 HEX 和材质名里都不含分号）
  static List<String> _parseSemicolonList(String raw) {
    return raw
        .split(';')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 获取原始模型文件名（替代不可读的 `.PID.plate.gcode`）。
  ///
  /// BambuStudio 切片缓存的 G-code 文件名形如 `.43208.2.gcode`（PID.plate），
  /// 对用户不可读。原始模型名有两个来源，按优先级尝试：
  ///
  /// 1. **祖父目录 `origin.txt`**：BambuStudio 在 plate 目录（G-code 的祖父目录）
  ///    生成 `origin.txt`，内容为源模型的完整路径（如
  ///    `%USERPROFILE%\Downloads\World_Cup_FIFA_Trophy.3mf`）
  /// 2. **祖父目录 `.3mf` 文件**：某些版本不生成 origin.txt，但在 plate 目录
  ///    生成 `.3mf` 文件，其内 `Metadata/model_settings.config` XML 的
  ///    `<metadata key="source_file" value="小醒狮.3mf"/>` 记录原始模型名。
  ///
  /// 目录结构：`<时间>#<PID>#<plate>\Metadata\.PID.plate.gcode`
  ///         `<时间>#<PID>#<plate>\origin.txt`（祖父目录）
  ///         `<时间>#<PID>#<plate>\.3mf`（祖父目录）
  ///
  /// 返回去除路径和扩展名后的纯名字（如 `小醒狮`）；读取失败或为空返回 null。
  static Future<String?> _readOriginName(String gcodePath) async {
    // 策略 1：祖父目录 origin.txt
    final fromOrigin = await _readOriginTxt(gcodePath);
    if (fromOrigin != null) return fromOrigin;

    // 策略 2：祖父目录 .3mf 内的 model_settings.config
    final from3mf = await _readSourceFileFrom3mf(gcodePath);
    if (from3mf != null) return from3mf;

    return null;
  }

  /// 读取祖父目录 `origin.txt`。
  /// G-code 在 `<plate>\Metadata\xxx.gcode`，origin.txt 在 `<plate>\origin.txt`。
  static Future<String?> _readOriginTxt(String gcodePath) async {
    try {
      // G-code 的父目录是 Metadata，再上一级是 plate 目录
      final metadataDir = File(gcodePath).parent;
      final plateDir = metadataDir.parent;
      final originFile =
          File('${plateDir.path}${Platform.pathSeparator}origin.txt');
      if (!await originFile.exists()) return null;

      final bytes = await originFile.readAsBytes();
      final raw = decodeOriginText(bytes);
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;

      // origin.txt 内容是完整路径（如 %USERPROFILE%\小醒狮.3mf），取 basename
      final basename = trimmed.split(RegExp(r'[/\\]')).last;
      final nameWithoutExt = basename.replaceAll(
        RegExp(r'\.(3mf|stl|obj|step|stp)$', caseSensitive: false),
        '',
      );
      return nameWithoutExt.isEmpty ? null : nameWithoutExt;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static String decodeOriginText(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // Bambu Studio on Chinese Windows may write origin.txt using GBK.
      return const GbkCodec(allowMalformed: true).decode(bytes);
    }
  }

  /// 读取祖父目录 `.3mf` 文件内的 `model_settings.config`，
  /// 提取 `<metadata key="source_file" value="xxx"/>` 的 value 字段。
  ///
  /// G-code 在 `<plate>\Metadata\.PID.plate.gcode`，
  /// .3mf 在 `<plate>\.3mf`（即 Metadata 的父目录）。
  static Future<String?> _readSourceFileFrom3mf(String gcodePath) async {
    try {
      // Metadata 目录 → 上一级就是 .3mf 所在目录
      final metadataDir = File(gcodePath).parent;
      final plateDir = metadataDir.parent;
      final threemfFile = File('${plateDir.path}${Platform.pathSeparator}.3mf');
      if (!await threemfFile.exists()) return null;
      if (!await isSafe3mfFile(threemfFile)) return null;

      final bytes = await threemfFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      if (!isSafe3mfArchive(archive)) return null;
      final configFile = archive.findFile('Metadata/model_settings.config');
      if (configFile == null) return null;

      final xmlContent = utf8.decode(configFile.content as List<int>);
      final doc = XmlDocument.parse(xmlContent);

      // 找所有 source_file metadata，取第一个非空
      for (final node in doc.findAllElements('metadata')) {
        final key = node.getAttribute('key');
        if (key == 'source_file') {
          final value = node.getAttribute('value');
          if (value != null && value.isNotEmpty) {
            final basename = value.split(RegExp(r'[/\\]')).last;
            final nameWithoutExt = basename.replaceAll(
              RegExp(r'\.(3mf|stl|obj|step|stp)$', caseSensitive: false),
              '',
            );
            if (nameWithoutExt.isNotEmpty) return nameWithoutExt;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 长度（mm）→ 克数（g）换算。
  /// `grams = length_mm × π × (diameter/2)² × density / 1000`
  /// （/1000 是 mm³→cm³）
  /// [overrideDensity] 优先用 G-code 头部读到的真实密度。
  ///
  /// 密度查找优先级：
  /// 1. G-code 头部 filament_density（最准）
  /// 2. 精确匹配 materialDensity 表（如 'PLA-CF'）
  /// 3. 前缀模糊匹配（如 'PLA-Matte-New' → 'PLA' 系列，取 PLA 密度）
  /// 4. 回退 PLA 1.24（最常见材质默认值）
  static double _lengthToGrams(
    double lengthMm,
    String materialType,
    double? overrideDensity,
  ) {
    final density = overrideDensity ??
        materialDensity[materialType] ??
        _lookupDensityByPrefix(materialType) ??
        1.24;
    const radius = defaultFilamentDiameter / 2;
    final volumeMm3 = lengthMm * 3.141592653589793 * radius * radius;
    return volumeMm3 * density / 1000.0;
  }

  /// 按材质名前缀模糊查找密度（处理未在 materialDensity 表中精确命中的衍生材质）。
  ///
  /// 例：'PLA-Matte-New' → 命中 'PLA-Matte' → 1.24
  ///     'PETG-HF-New' → 命中 'PETG-HF' → 1.27
  ///     'PA6-GF' → 命中 'PA6' → 1.13
  ///
  /// 策略：从最长前缀开始匹配，逐步缩短到 3 字符（避免误匹配）。
  /// 返回 null 表示无任何前缀匹配，调用方回退到 PLA 默认值。
  static double? _lookupDensityByPrefix(String materialType) {
    if (materialType.isEmpty) return null;
    // 按 '-' 分段，从最长前缀开始尝试
    final segments = materialType.split('-');
    for (int len = segments.length; len >= 1; len--) {
      final prefix = segments.take(len).join('-');
      if (materialDensity.containsKey(prefix)) {
        return materialDensity[prefix];
      }
    }
    return null;
  }

  /// 解析 PrusaSlicer/BambuStudio 的时间格式：
  /// `1h 12m 30s` / `1d 2h 30m` / `45m` / `30s`
  static int _parseDuration(String s) {
    int seconds = 0;
    final dMatch = RegExp(r'(\d+)\s*d').firstMatch(s);
    final hMatch = RegExp(r'(\d+)\s*h').firstMatch(s);
    final mMatch = RegExp(r'(\d+)\s*m').firstMatch(s);
    final sMatch = RegExp(r'(\d+)\s*s').firstMatch(s);
    if (dMatch != null) seconds += int.parse(dMatch.group(1)!) * 86400;
    if (hMatch != null) seconds += int.parse(hMatch.group(1)!) * 3600;
    if (mMatch != null) seconds += int.parse(mMatch.group(1)!) * 60;
    if (sMatch != null) seconds += int.parse(sMatch.group(1)!);
    return seconds;
  }

  /// 分块流式逐行读取。单行超过 64KB 视为非文本/损坏文件并终止解析，
  /// 避免无换行的二进制文件把整个内容装箱进 List<int> 导致 OOM。
  static Stream<String> _readLines(File file) async* {
    const maxLineBytes = 64 * 1024;
    final lineBytes = <int>[];
    await for (final chunk in file.openRead()) {
      for (final byte in chunk) {
        if (byte == 0x0A) {
          yield utf8.decode(lineBytes, allowMalformed: true);
          lineBytes.clear();
          continue;
        }
        if (byte == 0x0D) continue;
        if (lineBytes.length >= maxLineBytes) {
          throw const FormatException('G-code 单行超过 64KB，文件可能不是文本或尚未写完');
        }
        lineBytes.add(byte);
      }
    }
    if (lineBytes.isNotEmpty) {
      yield utf8.decode(lineBytes, allowMalformed: true);
    }
  }

  // ===========================================================================
  // 换色点解析（外挂料多色打印支持）
  // ===========================================================================

  /// 解析 G-code 中的换料点列表。
  ///
  /// 扫描整个 G-code 主体，按 `;LAYER:N` 切层，识别层内的工具切换指令：
  /// - `T0`/`T1`/`T2`/`T3`：工具切换（拓竹 AMS 自动换料 / 外挂料手动换料）
  /// - `M600`：Marlin 标准换料指令（第三方打印机兼容）
  /// - `M620 S{n}`：拓竹 AMS 换料起始指令
  /// - `M400 U1`：拓竹手动换料暂停指令（外挂料多色的关键标记）
  ///
  /// 结合头部 `filament_colour`/`filament_type` 列表，给每个换料点填充
  /// 目标颜色和材质信息。同时扫描 M104/M109 指令获取目标温度。
  ///
  /// 返回按层号升序排列的换色点列表；G-code 不含换料指令时返回空列表。
  ///
  /// 自动判断用户是否在切片软件勾选了换色：
  /// - 用户在 Bambu Studio "准备"界面右键对象 → "Change filament at layer"
  ///   会在 G-code 中插入 `T{n}` 切换指令
  /// - 用户没勾选 → G-code 无 T/M600/M400 U1 指令 → 返回空列表
  /// - 用户加载多色耗材但全用 T0 → G-code 无切换指令 → 返回空列表
  static Future<List<FilamentChangePoint>> parseFilamentChangeLayers(
    String gcodePath, {
    List<String>? colorHexes,
    List<String>? materialTypes,
    Set<int>? validToolIndices,
  }) async {
    final file = File(gcodePath);
    if (!await file.exists()) return const [];

    // 先读头部 filament_colour / filament_type（如果调用方未提供）
    List<String> colors = colorHexes ?? const [];
    List<String> materials = materialTypes ?? const [];
    if (colors.isEmpty || materials.isEmpty) {
      final headerInfo = await _readHeaderColorsAndTypes(gcodePath);
      if (colors.isEmpty) colors = headerInfo.$1;
      if (materials.isEmpty) materials = headerInfo.$2;
    }

    final result = <FilamentChangePoint>[];
    int currentLayer = -1;
    int currentTool = 0;
    int? pendingTemp;
    int? pendingManualLayer;
    int? pendingManualFromTool;
    // 跟踪已记录的 (layer, tool) 组合，避免同一层重复记录
    final recorded = <String>{};

    void addPoint({
      required int layer,
      required int tool,
      required int? previousTool,
      String? key,
    }) {
      // T254/T255/T1000 are printer-reserved commands, not user colors.
      if (tool >= 254 || tool == 1000) return;
      if (validToolIndices != null &&
          tool >= 0 &&
          !validToolIndices.contains(tool)) {
        return;
      }
      if (!recorded.add(key ?? '$layer:$tool')) return;
      result.add(
        FilamentChangePoint(
          layerNum: layer,
          toolIndex: tool,
          previousToolIndex: previousTool,
          colorHex: tool >= 0 && tool < colors.length ? colors[tool] : null,
          materialType:
              tool >= 0 && tool < materials.length ? materials[tool] : null,
          temperature: pendingTemp,
        ),
      );
    }

    await for (final line in _readLines(file)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // 层切换标记
      final layerMatch = RegExp(r';\s*LAYER:(\d+)').firstMatch(trimmed);
      if (layerMatch != null) {
        currentLayer = int.tryParse(layerMatch.group(1)!) ?? 0;
        continue;
      }
      if (trimmed.contains(';LAYER_CHANGE')) {
        currentLayer++;
        continue;
      }

      // 工具切换指令 T0/T1/T2/T3...（行首或独立行）
      final tMatch = RegExp(r'^T(\d+)(?:\s|;|$)').firstMatch(trimmed);
      if (tMatch != null) {
        final newTool = int.tryParse(tMatch.group(1)!) ?? 0;
        if (newTool >= 254 || newTool == 1000) continue;
        if (pendingManualLayer != null) {
          addPoint(
            layer: pendingManualLayer,
            tool: newTool,
            previousTool: pendingManualFromTool,
            key: 'M600:$pendingManualLayer:$newTool',
          );
          pendingManualLayer = null;
          pendingManualFromTool = null;
        } else if (newTool != currentTool && currentLayer >= 0) {
          addPoint(
            layer: currentLayer,
            tool: newTool,
            previousTool: currentTool,
          );
        }
        currentTool = newTool;
        pendingTemp = null;
        continue;
      }

      // M600 Marlin 标准换料指令
      if (trimmed.startsWith('M600')) {
        if (currentLayer >= 0) {
          if (pendingManualLayer != null) {
            addPoint(
              layer: pendingManualLayer,
              tool: -1,
              previousTool: pendingManualFromTool,
              key: 'M600:$pendingManualLayer:unknown',
            );
          }
          pendingManualLayer = currentLayer;
          pendingManualFromTool = currentTool;
        }
        continue;
      }

      // M620 S{n} 拓竹 AMS 换料起始（n 为目标挤出机号）
      final m620Match = RegExp(r'^M620\s+S(\d+)').firstMatch(trimmed);
      if (m620Match != null) {
        final newTool = int.tryParse(m620Match.group(1)!) ?? 0;
        if (currentLayer >= 0 && newTool != currentTool) {
          addPoint(
            layer: currentLayer,
            tool: newTool,
            previousTool: currentTool,
          );
          currentTool = newTool;
          pendingTemp = null;
        }
        continue;
      }

      // M400 U1 is the Bambu manual-feed pause. Treat it as an unresolved
      // change only when no explicit tool change was already recorded here.
      if (RegExp(r'^M400\s+U1(?:\s|;|$)').hasMatch(trimmed) &&
          currentLayer >= 0 &&
          pendingManualLayer == null &&
          !recorded.any((key) => key.startsWith('$currentLayer:'))) {
        pendingManualLayer = currentLayer;
        pendingManualFromTool = currentTool;
        continue;
      }

      // M104 S{temp} / M109 S{temp} 设置/等待喷嘴温度
      // 记录最近一次温度，用于下一次换料点的温度信息
      final tempMatch = RegExp(r'^M10[49]\s+S(\d+)').firstMatch(trimmed);
      if (tempMatch != null) {
        pendingTemp = int.tryParse(tempMatch.group(1)!);
        continue;
      }
    }

    if (pendingManualLayer != null) {
      // Keep the event visible, but do not guess the target as currentTool + 1.
      addPoint(
        layer: pendingManualLayer,
        tool: -1,
        previousTool: pendingManualFromTool,
        key: 'M600:$pendingManualLayer:unknown',
      );
    }

    // 按层号升序排序，保持同层源文件顺序
    result.sort((a, b) => a.layerNum.compareTo(b.layerNum));
    return result;
  }

  /// 仅读取 G-code 头部的 filament_colour 和 filament_type 字段。
  ///
  /// 用于 [parseFilamentChangeLayers] 在调用方未提供颜色/材质列表时，
  /// 快速从头注释中提取这两个字段，避免重复解析整个文件。
  /// 返回 (colors, materials) 元组。
  static Future<(List<String>, List<String>)> _readHeaderColorsAndTypes(
    String gcodePath,
  ) async {
    final file = File(gcodePath);
    if (!await file.exists()) {
      return (<String>[], <String>[]);
    }

    List<String> colors = const [];
    List<String> materials = const [];
    int emptyLines = 0;
    await for (final line in _readLines(file)) {
      final trimmed = line.trim();

      if (trimmed.contains('HEADER_BLOCK_END')) break;
      // 兜底：连续 50 行空行后停止
      if (trimmed.isEmpty) {
        emptyLines++;
        if (emptyLines > 50) break;
        continue;
      }
      emptyLines = 0;

      if (colors.isEmpty) {
        final m = RegExp(r';\s*filament_colour\s*=\s*(.+)').firstMatch(trimmed);
        if (m != null) {
          colors = _parseSemicolonList(m.group(1)!);
          continue;
        }
      }
      if (materials.isEmpty) {
        final m = RegExp(r';\s*filament_type\s*=\s*(.+)').firstMatch(trimmed);
        if (m != null) {
          materials = _parseSemicolonList(m.group(1)!);
          continue;
        }
      }
      // 两字段都解析到即可退出
      if (colors.isNotEmpty && materials.isNotEmpty) break;
    }
    return (<String>[...colors], <String>[...materials]);
  }
}
