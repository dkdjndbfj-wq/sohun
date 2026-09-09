import 'dart:io';
import 'dart:convert';
import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

import '../../../core/services/slice_artifact_hash_service.dart';
import '../../../core/utils/zip_safety.dart';
import 'filament_change_point.dart';
import 'slice_result.dart';
import 'gcode_parser.dart';
import 'bambu_slice_metadata.dart';

/// 3MF 文件解析器（拓竹/Bambu Studio 项目包格式）。
///
/// 3MF 本质是 ZIP 包，拓竹在标准 3MF 基础上扩展了切片元信息：
/// - `Metadata/slice_info.config`：切片摘要（每卷耗材克数、时长、层数等）
/// - `Metadata/slice_3mf.xml`：详细切片配置
/// - `Metadata/plate_X.gcode`：每块打印板的 G-code（可选，含层级信息）
///
/// **slice_info.config 关键字段**：
/// ```xml
/// <config>
///   <plate>
///     <metadata key="index" value="1"/>
///     <metadata key="prediction" value="4350"/>
///     <obj_bbox max_x="..." min_x="..."/>
///     <filament id="1" tray_id="0" type="PLA" color="#FFFFFF" used_g="23.56" used_m="7.82"/>
///     <filament id="2" tray_id="1" type="PETG" color="#FF0000" used_g="0" used_m="0"/>
///   </plate>
/// </config>
/// ```
class ThreemfParser {
  ThreemfParser._();

  /// 解析 3MF 文件。
  ///
  /// [enableLayerMapping] = true 时从 3MF 内嵌的 G-code 提取层级映射。
  /// [plateIndex] 指定解析哪块打印板（默认 1，第一块）。
  static Future<SliceResult?> parseFile(
    String filePath, {
    bool enableLayerMapping = false,
    int plateIndex = 1,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    if (!await isSafe3mfFile(file)) return null;

    Archive archive;
    try {
      // archive 4 lazily reads file-backed entries. Use the already bounded
      // compressed bytes so XML/G-code remains readable after decoding.
      archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      if (!isSafe3mfArchive(archive)) return null;
    } catch (_) {
      return null; // 不是有效 ZIP
    }

    // 1) 解析 slice_info.config
    final sliceInfoFile = archive.findFile('Metadata/slice_info.config');
    if (sliceInfoFile == null) return null;

    XmlDocument doc;
    try {
      final sliceInfoXml = utf8.decode(
        sliceInfoFile.content as List<int>,
        allowMalformed: true,
      );
      doc = XmlDocument.parse(sliceInfoXml);
    } catch (_) {
      return null;
    }

    final fileName = filePath.split(RegExp(r'[/\\]')).last;
    final taskName = fileName.replaceAll(RegExp(r'\.3mf$'), '');

    // 找到指定 plate
    final plates = doc.findAllElements('plate').toList();
    if (plates.isEmpty) return null;
    XmlElement? plate;
    for (final p in plates) {
      final idxMeta = p.findElements('metadata').firstWhere(
            (m) => m.getAttribute('key') == 'index',
            orElse: () => XmlElement(XmlName(''), []),
          );
      final idx = int.tryParse(idxMeta.getAttribute('value') ?? '') ?? 1;
      if (idx == plateIndex) {
        plate = p;
        break;
      }
    }
    if (plate == null) {
      if (plates.length != 1) return null;
      plate = plates.single;
    }

    // 提取 plate 级 metadata
    int? estimatedSeconds;
    int? totalLayers;
    int toolChangeCount = 0;
    for (final meta in plate.findElements('metadata')) {
      final key = meta.getAttribute('key') ?? '';
      final value = meta.getAttribute('value') ?? '';
      switch (key) {
        case 'prediction':
          // prediction 是秒数
          estimatedSeconds = int.tryParse(value);
          break;
        case 'layer_num':
          totalLayers = int.tryParse(value);
          break;
        case 'toolchange':
          toolChangeCount = int.tryParse(value) ?? 0;
          break;
      }
    }
    if (totalLayers == null || totalLayers <= 0) {
      totalLayers = _totalLayersFromFilamentRanges(plate);
    }

    // 提取每个 filament 的克数
    final filaments = <FilamentUsage>[];
    final trayIdsByTool = <int, int>{};
    for (final f in plate.findAllElements('filament')) {
      final id = bambuToolIndex(f);
      final usedG = double.tryParse(f.getAttribute('used_g') ?? '') ?? 0;
      final usedM = double.tryParse(f.getAttribute('used_m') ?? '') ?? 0;
      final type = f.getAttribute('type');
      final color = f.getAttribute('color');
      // tray_id：该挤出机对应的 AMS 槽位号（0-based 全局索引）
      final trayIdStr = f.getAttribute('tray_id');
      final trayId = trayIdStr != null ? int.tryParse(trayIdStr) : null;
      if (trayId != null && trayId >= 0) trayIdsByTool[id] = trayId;
      filaments.add(
        FilamentUsage(
          toolIndex: id,
          grams: usedG,
          lengthMm: usedM * 1000, // used_m 是米，转成毫米
          colorHex: color,
          materialType: type,
          sku: f.getAttribute('tray_info_idx'),
          usedForObject: bambuBoolAttribute(f, 'used_for_object'),
          usedForSupport: bambuBoolAttribute(f, 'used_for_support'),
          groupId: int.tryParse(f.getAttribute('group_id') ?? ''),
          nozzleDiameter:
              double.tryParse(f.getAttribute('nozzle_diameter') ?? ''),
          volumeType: f.getAttribute('volume_type'),
        ),
      );
    }

    if (filaments.isEmpty) {
      // 无 filament 信息，3MF 可能不是切片后的产物
      return null;
    }

    // 从 filament 的 tray_id 构建 amsMapping
    // 仅当所有 filament 都有有效 tray_id（>=0）时才构建映射
    List<int>? amsMapping;
    final activeTools = filaments
        .where((item) => item.grams > 0.01)
        .map((item) => item.toolIndex)
        .toSet();
    if (activeTools.isNotEmpty &&
        activeTools.every(trayIdsByTool.containsKey)) {
      final highestTool = activeTools.reduce((a, b) => a > b ? a : b);
      amsMapping = List<int>.filled(highestTool + 1, -1);
      for (final tool in activeTools) {
        amsMapping[tool] = trayIdsByTool[tool]!;
      }
    }

    final rangeToolChanges = toolChangesFromBambuFilamentRanges(
      plate,
      activeTools: activeTools,
    );
    if (rangeToolChanges > toolChangeCount) {
      toolChangeCount = rangeToolChanges;
    }

    // 提取切片软件版本（从 model 块）
    String? slicerName = 'BambuStudio';
    String? slicerVersion;
    final appNode = doc.findAllElements('app').firstOrNull;
    if (appNode != null) {
      slicerName = appNode.getAttribute('name') ?? slicerName;
      slicerVersion = appNode.getAttribute('version');
    }

    // 从内嵌 G-code 提取切片预设/喷嘴/打印板元数据；精细模式再提取层级映射。
    Map<int, double>? layerMap;
    var filamentChangePoints = const <FilamentChangePoint>[];
    String? printSettingsId;
    String? printerSettingsId;
    double? nozzleDiameter;
    String? plateType;
    final gcodeFile = archive.findFile('Metadata/plate_$plateIndex.gcode') ??
        archive.findFile('Metadata/plate.gcode');
    if (gcodeFile != null) {
      final tempDir = await Directory.systemTemp.createTemp('ct_3mf_');
      final tempGcode = File('${tempDir.path}/plate.gcode');
      await tempGcode.writeAsBytes(gcodeFile.content as List<int>);
      try {
        final innerResult = await GcodeParser.parseFile(
          tempGcode.path,
          enableLayerMapping: enableLayerMapping,
          materialType: filaments.first.materialType ?? 'PLA',
        );
        estimatedSeconds ??= innerResult?.estimatedSeconds;
        if (totalLayers == null || totalLayers <= 0) {
          totalLayers = innerResult?.totalLayers;
        }
        if (toolChangeCount <= 0) {
          toolChangeCount = innerResult?.toolChangeCount ?? 0;
        }
        layerMap = innerResult?.layerCumulativeGrams;
        filamentChangePoints = innerResult?.filamentChangePoints ?? const [];
        printSettingsId = innerResult?.printSettingsId;
        printerSettingsId = innerResult?.printerSettingsId;
        nozzleDiameter = innerResult?.nozzleDiameter;
        plateType = innerResult?.plateType;
      } finally {
        await tempDir.delete(recursive: true);
      }
    }

    final artifact = await SliceArtifactHashService.computeStable(filePath);

    return SliceResult(
      filePath: filePath,
      taskName: taskName,
      filaments: filaments,
      filamentChangePoints: filamentChangePoints,
      estimatedSeconds: estimatedSeconds ?? 0,
      toolChangeCount: toolChangeCount,
      totalLayers: totalLayers ?? 0,
      slicerName: slicerName,
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
}

/// XmlElement 扩展：firstOrNull 兼容（旧版 xml 包没有）
int? _totalLayersFromFilamentRanges(XmlElement plate) {
  final result = totalLayersFromBambuFilamentRanges(plate);
  return result <= 0 ? null : result;
}

extension FirstOrNullExt on Iterable<XmlElement> {
  XmlElement? get firstOrNull => isEmpty ? null : first;
}
