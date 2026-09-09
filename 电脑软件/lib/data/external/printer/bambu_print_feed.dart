import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

import '../../../core/utils/zip_safety.dart';
import '../../database/models/printer_feed_models.dart';
import '../../seed/printer_seed.dart';
import 'bambu_printer_models.dart';

/// One conversion boundary for stored channel IDs, tray bit positions and
/// project_file wire IDs. See docs/bambu-feed-compatibility.md for sources.
Map<String, dynamic> buildBambuPrintFeedPayload(List<int> channels,
    {Iterable<int>? activeTools}) {
  final flat = <int>[];
  final addressed = <Map<String, int>>[];
  var useAms = false;
  final active = activeTools?.toSet();
  for (var tool = 0; tool < channels.length; tool++) {
    final channel =
        active == null || active.contains(tool) ? channels[tool] : -1;
    if (channel == -1) {
      flat.add(-1);
      addressed.add({'ams_id': 255, 'slot_id': 255});
      continue;
    }
    final address = bambuFeedAddress(channel);
    flat.add(address.trayId);
    addressed.add({'ams_id': address.amsId, 'slot_id': address.slotId});
    useAms |= !isExternalFeedChannel(channel);
  }
  return {'use_ams': useAms, 'ams_mapping': flat, 'ams_mapping2': addressed};
}

String? validateBambuPrintFeed({
  required String model,
  required List<int> mapping,
  required Iterable<int> activeTools,
  required BambuPrinterStatus? status,
  Map<int, int> toolExtruders = const {},
}) {
  final preset = PrinterPresets.findByModel(model, brand: '拓竹');
  if (preset == null) return '尚未确认 $model 的供料能力，请先选择准确机型';
  final tools = activeTools.toSet();
  if (tools.isEmpty) return '切片没有可确认的耗材用量，请重新切片';
  final channels = <int>{};
  for (final tool in tools) {
    if (tool < 0 || tool >= mapping.length || mapping[tool] < 0) {
      return '工具 ${tool + 1} 尚未指定供料槽位';
    }
    try {
      bambuFeedAddress(mapping[tool]);
    } on ArgumentError {
      return '工具 ${tool + 1} 使用了尚未确认的供料编号';
    }
    channels.add(mapping[tool]);
  }
  final usesAms = channels.any((channel) => !isExternalFeedChannel(channel));
  final usesExternal = channels.any(isExternalFeedChannel);
  for (final channel in channels.where(isExternalFeedChannel)) {
    if (tools.where((tool) => mapping[tool] == channel).length > 1) {
      return '多个切片工具共用了同一外挂料位，不能自动发送；请重新切片或在 Bambu Studio 中按人工换料流程打印';
    }
  }
  final standardAmsConnected = status?.amsUnits
          ?.any((unit) => unit.isPresent && unit.id != 16) ??
      status?.amsTrays?.any((tray) => tray.amsId >= 0 && !tray.mixedAmsLite) ??
      false;
  if (preset.amsLiteCanCombineWithStandard &&
      (standardAmsConnected ||
          channels.any((channel) => channel >= 0 && channel < 24)) &&
      channels.where((channel) => channel >= 24 && channel <= 27).length > 3) {
    return 'A2L 混接时 AMS Lite 须让出一路进料口，最多使用 3 个 Lite 槽位；请按实际接管重新映射';
  }
  if (usesExternal &&
      (status?.amsUnits
              ?.any((unit) => unit.isPresent && unit.usesFilamentTrackSwitch) ??
          false)) {
    return '当前连接使用共享进料附件 FTS；使用外挂前须移除 FTS 并刷新设备';
  }
  if (usesAms && usesExternal && !preset.externalCanCoexistWithAms) {
    return '${preset.model} 的 AMS 与外挂共用一条进料路径，同一任务不能混用';
  }
  final trays = status?.amsTrays ??
      status?.amsUnits
          ?.where((unit) => unit.isPresent)
          .expand((unit) => unit.trays)
          .toList() ??
      const <AmsTray>[];
  if (usesAms && detectedAmsState(status) != AmsDetectionState.present) {
    return '尚未确认实时 AMS 状态，请刷新设备后重新映射';
  }
  for (final tool in tools) {
    final channel = mapping[tool];
    final external = isExternalFeedChannel(channel);
    final tray = trays
        .where((tray) =>
            tray.globalSlot == channel || tray.protocolTrayId == channel)
        .firstOrNull;
    if (!external &&
        (tray == null || !tray.hasFilamentObservation || !tray.hasFilament)) {
      return '${printerFeedChannelLabel(channel)} 未连接或没有耗材，请刷新设备';
    }
    if (preset.externalInputCount == 1) {
      if (channel == externalFeedLeftChannel) return '${preset.model} 没有左外挂供料位';
      continue;
    }
    // A material/tool index is not a nozzle index. Dual-nozzle prints require
    // an explicit assignment read from the selected sliced plate.
    final target = toolExtruders[tool];
    if (target == null)
      return '切片缺少工具 ${tool + 1} 的喷头分配，请在 Bambu Studio 中重新保存已切片文件';
    final unit = status?.amsUnits
        ?.where((unit) => unit.isPresent && unit.id == tray?.amsId)
        .firstOrNull;
    final source = external
        ? (channel == externalFeedLeftChannel ? 1 : 0)
        : unit?.extruderId;
    if (source == null)
      return '尚未确认 AMS 与喷头的连接关系，请刷新设备；共享进料附件需在 Bambu Studio 中确认';
    if (source != target)
      return '工具 ${tool + 1} 的槽位与切片指定喷头不一致，请选择${target == 1 ? '左侧' : '右侧'}喷头的供料位';
    if (usesAms &&
        external &&
        externalFeedAvailability(channel,
                externalInputCount: preset.externalInputCount,
                amsState: detectedAmsState(status),
                units: status?.amsUnits) !=
            ExternalFeedAvailability.available) {
      return '${printerFeedChannelLabel(channel)} 所在路径已接 AMS 或路由尚未确认，不能同时使用';
    }
  }
  return null;
}

/// Filament maps are 1-based logical nozzle IDs, while MQTT IDs are physical
/// (0=right, 1=left; these are protocol IDs, not main/support roles). Never infer this relation from tool order,
/// color, or the fact that a material is used for support.
Map<int, int> parseBambuToolExtruders({
  String? modelSettingsXml,
  String? sliceInfoXml,
  String? projectSettingsJson,
  int plateIndex = 1,
}) {
  List<int> parseInts(Object? raw) =>
      (raw is List ? raw : raw?.toString().split(RegExp(r'[\s,;]+')) ?? [])
          .map((value) => int.tryParse(value.toString()) ?? -1)
          .toList();
  String? plateMap(String? xml, String indexKey) {
    if (xml == null) return null;
    final doc = XmlDocument.parse(xml);
    for (final plate in doc.findAllElements('plate')) {
      final metadata = {
        for (final entry in plate.findElements('metadata'))
          entry.getAttribute('key'): entry.getAttribute('value')
      };
      if (int.tryParse(metadata[indexKey] ?? '') == plateIndex)
        return metadata['filament_maps'];
    }
    return null;
  }

  try {
    final settings = projectSettingsJson == null
        ? <String, dynamic>{}
        : jsonDecode(projectSettingsJson) as Map<String, dynamic>;
    final maps = parseInts(plateMap(sliceInfoXml, 'index') ??
        plateMap(modelSettingsXml, 'plater_id'));
    // Only selected-plate assignments are accepted. A project-level auto map
    // can be stale for another plate, so it is not a safe fallback.
    final physical = parseInts(settings['physical_extruder_map']);
    return {
      for (var tool = 0; tool < maps.length; tool++)
        if (maps[tool] == 1 || maps[tool] == 2)
          if (physical.isEmpty ||
              (physical.length >= maps[tool] &&
                  (physical[maps[tool] - 1] == 0 ||
                      physical[maps[tool] - 1] == 1)))
            tool: physical.isEmpty
                ? (maps[tool] == 1 ? 1 : 0)
                : physical[maps[tool] - 1],
    };
  } catch (_) {
    return const {};
  }
}

Future<Map<int, int>> readBambuToolExtruders(String path,
    {int plateIndex = 1}) async {
  if (!path.toLowerCase().endsWith('.3mf')) return const {};
  InputFileStream? input;
  try {
    if (!await isSafe3mfFile(File(path))) return const {};
    input = InputFileStream(path);
    final archive = ZipDecoder().decodeBuffer(input);
    if (!isSafe3mfArchive(archive)) return const {};
    if (archive.findFile('Metadata/plate_$plateIndex.gcode') == null) {
      final plates = archive.files
          .where((file) =>
              file.isFile &&
              RegExp(r'^Metadata/plate_\d+\.gcode$').hasMatch(file.name))
          .toList();
      if (plates.length != 1) return const {};
      plateIndex = int.parse(
          RegExp(r'plate_(\d+)').firstMatch(plates.single.name)!.group(1)!);
    }
    String? read(String name) {
      final file = archive.findFile('Metadata/$name');
      return file == null
          ? null
          : utf8.decode(file.content as List<int>, allowMalformed: true);
    }

    return parseBambuToolExtruders(
        modelSettingsXml: read('model_settings.config'),
        sliceInfoXml: read('slice_info.config'),
        projectSettingsJson: read('project_settings.config'),
        plateIndex: plateIndex);
  } catch (_) {
    return const {};
  } finally {
    input?.closeSync();
  }
}
