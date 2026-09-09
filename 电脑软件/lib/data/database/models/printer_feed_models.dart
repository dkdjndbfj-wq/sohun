import '../../external/printer/bambu_printer_models.dart';

const int externalFeedRightChannel = 255;
const int externalFeedLeftChannel = 254;

class PrinterFeedSlotDefinition {
  const PrinterFeedSlotDefinition({
    required this.channelIndex,
    required this.label,
    required this.isExternal,
  });

  final int channelIndex;
  final String label;
  final bool isExternal;
}

/// Physical feed layout used when a printer is configured before telemetry is
/// available. Live MQTT facts remain authoritative and can relabel/add slots.
class PrinterFeedConfiguration {
  const PrinterFeedConfiguration({
    required this.externalInputCount,
    required this.amsTypes,
    this.channelsPerGenericSystem = 4,
    this.bambuLabels = true,
    this.amsLiteMixed = false,
    this.externalCanCoexistWithAms = false,
  });

  final int externalInputCount;
  final List<AmsUnitType> amsTypes;
  final int channelsPerGenericSystem;
  final bool bambuLabels;

  /// A2L 的 Lite 使用独立 24..27 编号。保留全部物理槽位；混接时
  /// 用户须让出任意一路给常规 AMS，不能假设固定是第四槽。
  final bool amsLiteMixed;

  /// Whether the printer can feed an external input and AMS in one print job
  /// (dual-extruder models).  This is metadata, not a slot-count override.
  final bool externalCanCoexistWithAms;

  int get amsChannelCount => amsTypes.fold<int>(
        0,
        (sum, type) =>
            sum + (type == AmsUnitType.amsHt ? 1 : channelsPerGenericSystem),
      );

  int get channelCount => externalInputCount.clamp(0, 2) + amsChannelCount;

  List<PrinterFeedSlotDefinition> get slots {
    final result = <PrinterFeedSlotDefinition>[
      ...externalFeedSlots(externalInputCount),
    ];
    var standardUnitIndex = 0;
    var htUnitIndex = 0;
    for (var ordinal = 0; ordinal < amsTypes.length; ordinal++) {
      final type = amsTypes[ordinal];
      final channelCount =
          type == AmsUnitType.amsHt ? 1 : channelsPerGenericSystem;
      final baseIndex = type == AmsUnitType.amsHt
          ? 16 + htUnitIndex++
          : type == AmsUnitType.amsLite && amsLiteMixed
              ? 24
              : standardUnitIndex++ * channelsPerGenericSystem;
      final sourceName =
          bambuLabels ? type.displayLabel : '多色系统 ${ordinal + 1}';
      for (var slot = 0; slot < channelCount; slot++) {
        result.add(
          PrinterFeedSlotDefinition(
            channelIndex: baseIndex + slot,
            label: bambuLabels
                ? '第 ${ordinal + 1} 台 $sourceName · 第 ${slot + 1} 通道'
                : '$sourceName · 第 ${slot + 1} 通道',
            isExternal: false,
          ),
        );
      }
    }
    result.sort((a, b) => a.channelIndex.compareTo(b.channelIndex));
    return result;
  }
}

List<PrinterFeedSlotDefinition> externalFeedSlots(int count) {
  final normalized = count.clamp(0, 2);
  if (normalized == 0) return const [];
  if (normalized == 1) {
    return const [
      PrinterFeedSlotDefinition(
        channelIndex: externalFeedRightChannel,
        label: '外挂料位',
        isExternal: true,
      ),
    ];
  }
  return const [
    PrinterFeedSlotDefinition(
      channelIndex: externalFeedLeftChannel,
      label: '外挂料位 L',
      isExternal: true,
    ),
    PrinterFeedSlotDefinition(
      channelIndex: externalFeedRightChannel,
      label: '外挂料位 R',
      isExternal: true,
    ),
  ];
}

bool isExternalFeedChannel(int channelIndex) {
  return channelIndex == externalFeedLeftChannel ||
      channelIndex == externalFeedRightChannel;
}

/// 一个物理挤出机的传感器同时会看见 AMS 与外挂的料。被 AMS 占用、
/// 路由未上报时返回 null，防止把 AMS 进退料误当成外挂装卸而修改库存。
List<bool?> externalFeedSensorReadings({
  List<bool?>? sensors,
  int? hwSwitchState,
  String? trayNow,
  List<AmsUnit>? units,
  List<AmsTray>? trays,
}) {
  final raw =
      sensors ?? (hwSwitchState == null ? <bool>[] : [hwSwitchState == 1]);
  // Legacy single-extruder tray_now=254 explicitly selects the external spool.
  // It is not the dual-extruder external slot ID, despite the same number.
  if (raw.length == 1 && trayNow == '254') return [...raw];
  final presentUnits = units?.where((unit) => unit.isPresent).toList();
  final hasAms =
      presentUnits?.isNotEmpty ?? trays?.any((tray) => tray.amsId >= 0);
  if (hasAms == false) return [...raw];
  if (hasAms == null ||
      raw.length <= 1 ||
      presentUnits == null ||
      presentUnits.any((unit) => unit.extruderId == null)) {
    return List<bool?>.filled(raw.length, null);
  }
  final occupied = presentUnits.map((unit) => unit.extruderId).toSet();
  return [
    for (var i = 0; i < raw.length; i++) occupied.contains(i) ? null : raw[i]
  ];
}

enum ExternalFeedAvailability { available, switchRequired, routingUnknown }

String externalFeedSummary({
  required int externalInputCount,
  required BambuPrinterStatus? status,
}) {
  final counts = <ExternalFeedAvailability, int>{};
  for (final slot in externalFeedSlots(externalInputCount)) {
    final availability = externalFeedAvailability(slot.channelIndex,
        externalInputCount: externalInputCount,
        amsState: detectedAmsState(status),
        units: status?.amsUnits);
    counts[availability] = (counts[availability] ?? 0) + 1;
  }
  return [
    if (counts[ExternalFeedAvailability.available] case final count?)
      '外挂可用 $count 路',
    if (counts[ExternalFeedAvailability.switchRequired] case final count?)
      '外挂需切换 $count 路',
    if (counts[ExternalFeedAvailability.routingUnknown] case final count?)
      '外挂待确认 $count 路',
  ].join(' · ');
}

/// 单喷头接 AMS 后不增加独立外挂；双喷头按实际 AMS→挤出机路由判断。
ExternalFeedAvailability externalFeedAvailability(
  int channelIndex, {
  required int externalInputCount,
  required AmsDetectionState amsState,
  List<AmsUnit>? units,
}) {
  if (amsState == AmsDetectionState.absent)
    return ExternalFeedAvailability.available;
  if (amsState == AmsDetectionState.unknown)
    return ExternalFeedAvailability.routingUnknown;
  if (externalInputCount <= 1) return ExternalFeedAvailability.switchRequired;
  final present = units?.where((unit) => unit.isPresent).toList();
  if (present == null ||
      present.isEmpty ||
      present.any((unit) => unit.extruderId == null)) {
    return ExternalFeedAvailability.routingUnknown;
  }
  final extruder = channelIndex == externalFeedLeftChannel ? 1 : 0;
  return present.any((unit) => unit.extruderId == extruder)
      ? ExternalFeedAvailability.switchRequired
      : ExternalFeedAvailability.available;
}

/// 数据库保留旧版紧凑通道编号，只有发送边界转换到拓竹协议。
({int amsId, int slotId, int trayId}) bambuFeedAddress(int channel) {
  if (isExternalFeedChannel(channel))
    return (amsId: channel, slotId: 0, trayId: -1);
  if (channel >= 16 && channel <= 23) {
    return (amsId: 128 + channel - 16, slotId: 0, trayId: 128 + channel - 16);
  }
  if (channel >= 24 && channel <= 27)
    return (amsId: 16, slotId: channel - 24, trayId: channel);
  if (channel >= 128 && channel <= 135)
    return (amsId: channel, slotId: 0, trayId: channel);
  if (channel >= 0 && channel <= 15)
    return (amsId: channel ~/ 4, slotId: channel % 4, trayId: channel);
  throw ArgumentError.value(channel, 'channel', '尚未确认的拓竹供料编号');
}

int printerFeedGroupKey(int channel) => channel >= 24 && channel <= 27
    ? 24
    : channel >= 16
        ? 1000 + channel
        : channel ~/ 4;

/// Whether the printer has reported an attached AMS.
///
/// `unknown` is intentionally different from `absent`: MQTT status messages
/// are incremental, so a message without AMS fields must never be interpreted
/// as "the AMS was unplugged". Only an explicit empty unit/tray report is
/// authoritative absence.
enum AmsDetectionState { unknown, absent, present }

AmsDetectionState detectedAmsState(BambuPrinterStatus? status) {
  if (status == null) return AmsDetectionState.unknown;
  final units = status.amsUnits;
  if (units != null) {
    return units.any((unit) => unit.isPresent)
        ? AmsDetectionState.present
        : AmsDetectionState.absent;
  }
  final trays = status.amsTrays;
  if (trays != null) {
    return trays.any((tray) => tray.amsId >= 0)
        ? AmsDetectionState.present
        : AmsDetectionState.absent;
  }
  return AmsDetectionState.unknown;
}

/// Returns the physical AMS generations reported by the printer, preserving
/// unit order. Module names are used only when the unit itself reports an
/// unknown generation.
List<AmsUnitType> detectedAmsTypes(BambuPrinterStatus? status) {
  if (status == null) return const [];
  return [
    for (final unit in status.amsUnits ?? const <AmsUnit>[])
      if (unit.isPresent)
        unit.type == AmsUnitType.unknown
            ? (status.amsModuleTypes?[unit.id] ?? AmsUnitType.unknown)
            : unit.type,
  ];
}

String detectedAmsSummary(BambuPrinterStatus? status) {
  final types = detectedAmsTypes(status);
  if (types.isEmpty) {
    return switch (detectedAmsState(status)) {
      AmsDetectionState.absent => '未连接 AMS',
      AmsDetectionState.unknown => '等待识别 AMS',
      AmsDetectionState.present => '已连接 AMS',
    };
  }
  final counts = <AmsUnitType, int>{};
  for (final type in types) {
    counts[type] = (counts[type] ?? 0) + 1;
  }
  const order = [
    AmsUnitType.ams,
    AmsUnitType.ams2Pro,
    AmsUnitType.amsHt,
    AmsUnitType.amsLite,
    AmsUnitType.unknown,
  ];
  return [
    for (final type in order)
      if ((counts[type] ?? 0) > 0) '${type.displayLabel} × ${counts[type]}',
  ].join(' · ');
}

String printerFeedChannelLabel(
  int channelIndex, {
  String? storedLabel,
  bool compact = false,
  bool legacySingleExternal = false,
}) {
  if (channelIndex < 0) return compact ? '外挂' : '外挂料位';
  if (channelIndex == externalFeedLeftChannel) {
    return compact ? '外挂 L' : '外挂料位 L';
  }
  if (channelIndex == externalFeedRightChannel) {
    final singleExternal =
        legacySingleExternal || (storedLabel?.trim() == '外挂料位');
    if (singleExternal) return compact ? '外挂' : '外挂料位';
    return compact ? '外挂 R' : '外挂料位 R';
  }
  if (legacySingleExternal && channelIndex == 0) {
    return compact ? '外挂' : '外挂料位';
  }
  final saved = storedLabel?.trim() ?? '';
  if (saved.isNotEmpty && !RegExp(r'^[A-Z]$').hasMatch(saved)) return saved;
  if (channelIndex >= 24 && channelIndex <= 27) {
    return compact
        ? 'Lite-${channelIndex - 23}'
        : 'AMS Lite · 第 ${channelIndex - 23} 通道';
  }
  if (channelIndex >= 16 && channelIndex <= 23) {
    return compact
        ? 'AMS HT-${channelIndex - 15}'
        : 'AMS HT · 第 ${channelIndex - 15} 通道';
  }
  final unit = channelIndex ~/ 4 + 1;
  final slot = channelIndex % 4 + 1;
  return compact ? 'AMS$unit-$slot' : 'AMS $unit · 第 $slot 通道';
}
