import 'dart:convert';

/// 打印机配置（Printer Preset）。
///
/// 对应 Bambu Studio 的 machine/*.json，完整覆盖官方 fdm_machine_common.json
/// 的全部 83 个字段。所有字段用 String 类型存储（与 Bambu Studio 一致）。
///
/// 4 个分类：
/// - [PrinterNozzleParams] 喷嘴（直径、高度、挤出机间隙、偏移等）
/// - [PrinterBedParams] 打印床（可打印区域、高度、层高范围、排除区等）
/// - [PrinterMechanicalParams] 机械限制（速度/加速度/Jerk/力/速率等）
/// - [PrinterFeatureParams] 功能开关（回抽、G-code、时间参数、加热、风扇等）
class PrinterPreset {
  final String id;
  final String name;
  final String printerModel; // Bambu Lab X1 Carbon / P1S / A1 等
  final String nozzleDiameter; // 0.2 / 0.4 / 0.6 / 0.8
  final String printerStructure; // corexy / i3
  final DateTime createdAt;
  final DateTime updatedAt;

  final PrinterNozzleParams nozzle;
  final PrinterBedParams bed;
  final PrinterMechanicalParams mechanical;
  final PrinterFeatureParams features;

  const PrinterPreset({
    required this.id,
    required this.name,
    required this.printerModel,
    required this.nozzleDiameter,
    required this.printerStructure,
    required this.createdAt,
    required this.updatedAt,
    required this.nozzle,
    required this.bed,
    required this.mechanical,
    required this.features,
  });

  /// 从 .bbsparam 格式的 JSON 字符串导入。
  factory PrinterPreset.fromBbsparamJson(String content) {
    final root = jsonDecode(content) as Map<String, dynamic>;
    final preset = root['preset'] as Map<String, dynamic>? ?? {};
    final params = preset['params'] as Map<String, dynamic>? ?? {};
    final now = DateTime.now();
    return PrinterPreset(
      id: preset['id'] as String? ?? '',
      name: preset['name'] as String? ?? '未命名打印机',
      printerModel: preset['printerModel'] as String? ?? 'Generic',
      nozzleDiameter: preset['nozzleDiameter'] as String? ?? '0.4',
      printerStructure: preset['printerStructure'] as String? ?? 'corexy',
      createdAt: preset['createdAt'] != null
          ? DateTime.tryParse(preset['createdAt'] as String) ?? now
          : now,
      updatedAt: preset['updatedAt'] != null
          ? DateTime.tryParse(preset['updatedAt'] as String) ?? now
          : now,
      nozzle: PrinterNozzleParams.fromMap(
        params['nozzle'] as Map<String, dynamic>? ?? {},
      ),
      bed: PrinterBedParams.fromMap(
        params['bed'] as Map<String, dynamic>? ?? {},
      ),
      mechanical: PrinterMechanicalParams.fromMap(
        params['mechanical'] as Map<String, dynamic>? ?? {},
      ),
      features: PrinterFeatureParams.fromMap(
        params['features'] as Map<String, dynamic>? ?? {},
      ),
    );
  }

  PrinterPreset copyWith({
    String? id,
    String? name,
    String? printerModel,
    String? nozzleDiameter,
    String? printerStructure,
    DateTime? createdAt,
    DateTime? updatedAt,
    PrinterNozzleParams? nozzle,
    PrinterBedParams? bed,
    PrinterMechanicalParams? mechanical,
    PrinterFeatureParams? features,
  }) {
    return PrinterPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      printerModel: printerModel ?? this.printerModel,
      nozzleDiameter: nozzleDiameter ?? this.nozzleDiameter,
      printerStructure: printerStructure ?? this.printerStructure,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      nozzle: nozzle ?? this.nozzle,
      bed: bed ?? this.bed,
      mechanical: mechanical ?? this.mechanical,
      features: features ?? this.features,
    );
  }

  /// 序列化为 .bbsparam 格式的 Map（含元信息）。
  Map<String, dynamic> toBbsparamMap() {
    return {
      'format': 'bbsparam',
      'version': '1.0',
      'preset': {
        'id': id,
        'name': name,
        'printerModel': printerModel,
        'nozzleDiameter': nozzleDiameter,
        'printerStructure': printerStructure,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'params': {
          'nozzle': nozzle.toMap(),
          'bed': bed.toMap(),
          'mechanical': mechanical.toMap(),
          'features': features.toMap(),
        },
      },
    };
  }

  /// 序列化为 .bbsparam JSON 字符串。
  String toBbsparamJson() {
    return const JsonEncoder.withIndent('  ').convert(toBbsparamMap());
  }

  /// 获取扁平的参数 Map（所有字段合并）。
  Map<String, String> toFlatMap() {
    return {
      ...nozzle.toMap(),
      ...bed.toMap(),
      ...mechanical.toMap(),
      ...features.toMap(),
    };
  }
}

// ===== 辅助函数 =====

/// 从动态值解析为字符串（兼容 Bambu Studio 的数组格式）。
String _parseStr(dynamic v) {
  if (v == null) return '';
  if (v is List && v.isNotEmpty) {
    return v.first?.toString() ?? '';
  }
  return v.toString();
}

/// 解析字符串，缺失（null/空）时返回 [defaultValue]。
String _parseStrOrDefault(dynamic v, String defaultValue) {
  final s = _parseStr(v);
  return s.isEmpty ? defaultValue : s;
}

/// 判断字段 key 是否为速度/加速度字段（导出 Bambu Studio JSON 时需转为数组格式）。
/// 使用 contains 匹配：PrinterMechanicalParams 字段格式为 max_speed_x / max_accel_x /
/// max_jerk_x 等，后缀为 _x/_y/_z/_e/_extruding 等，endsWith 无法匹配。
///
/// 注意：print_parameter.dart 中也有一个同名的 file-private `_isSpeedField`，
/// 但两者逻辑不同（此处的用于 Machine 参数，使用 contains 匹配；
/// 彼处的用于 Process 参数，使用 endsWith 匹配 inner_wall_speed 等）。
/// 刻意保持独立，不抽取共享文件。
bool _isSpeedField(String key) {
  return key.contains('_speed') ||
      key.contains('_accel') ||
      key.contains('_jerk') ||
      key.contains('_rate') ||
      key.contains('_force_');
}

/// 把 toMap() 结果（全 String）转为 Bambu Studio Machine JSON 格式。
/// 1. key 转为 Bambu Studio 官方命名（如 max_accel_x → machine_max_acceleration_x）
/// 2. 速度/加速度/Jerk 字段转为数组格式 `["value"]`，其余为标量
Map<String, dynamic> _toMachineJson(Map<String, String> map) {
  return map.map((key, value) {
    final bblKey = _toBambuMachineKey(key);
    if (_isSpeedField(key)) {
      return MapEntry(bblKey, [value]);
    }
    return MapEntry(bblKey, value);
  });
}

/// 内部 key → Bambu Studio Machine JSON key 映射。
/// Bambu Studio 的机械限制字段使用 `machine_` 前缀和完整单词（acceleration/speed/jerk）。
String _toBambuMachineKey(String internalKey) {
  // max_accel_* → machine_max_acceleration_*
  if (internalKey.startsWith('max_accel_')) {
    return internalKey.replaceFirst('max_accel_', 'machine_max_acceleration_');
  }
  // max_speed_* → machine_max_speed_*
  if (internalKey.startsWith('max_speed_')) {
    return internalKey.replaceFirst('max_speed_', 'machine_max_speed_');
  }
  // max_jerk_* → machine_max_jerk_*
  if (internalKey.startsWith('max_jerk_')) {
    return internalKey.replaceFirst('max_jerk_', 'machine_max_jerk_');
  }
  return internalKey;
}

// ===== A. 喷嘴参数 =====

/// 喷嘴参数：直径、高度、挤出机间隙、偏移、颜色等（共 18 字段）。
///
/// 对照 fdm_machine_common.json 中以下 key：
/// nozzle_diameter, nozzle_height, nozzle_flush_dataset, printer_variant,
/// extruder_clearance_dist_to_rod, extruder_clearance_height_to_lid,
/// extruder_clearance_height_to_rod, extruder_clearance_max_radius,
/// extruder_colour, extruder_height_gap, extruder_max_nozzle_count,
/// extruder_offset, grab_length, master_extruder_id,
/// default_filament_profile, default_print_profile
class PrinterNozzleParams {
  // 基础喷嘴
  final String nozzleDiameter; // nozzle_diameter
  final String nozzleHeight; // nozzle_height
  final String nozzleFlushDataset; // nozzle_flush_dataset
  final String printerVariant; // printer_variant

  // 挤出机间隙
  final String extruderClearanceDistToRod; // extruder_clearance_dist_to_rod
  final String extruderClearanceHeightToLid; // extruder_clearance_height_to_lid
  final String extruderClearanceHeightToRod; // extruder_clearance_height_to_rod
  final String extruderClearanceMaxRadius; // extruder_clearance_max_radius

  // 挤出机外观/配置
  final String extruderColour; // extruder_colour
  final String extruderHeightGap; // extruder_height_gap
  final String extruderMaxNozzleCount; // extruder_max_nozzle_count
  final String extruderOffset; // extruder_offset
  final String grabLength; // grab_length
  final String masterExtruderId; // master_extruder_id

  // 默认预设
  final String defaultFilamentProfile; // default_filament_profile
  final String defaultPrintProfile; // default_print_profile

  // 本软件扩展字段（不在官方 83 字段中，仅用于业务显示）
  final String nozzleType; // hardened_steel / stainless_steel
  final String nozzleVolume;
  final String extruderType; // Direct Drive
  final String extruderVariantList;

  const PrinterNozzleParams({
    this.nozzleDiameter = '0.4',
    this.nozzleHeight = '1.8',
    this.nozzleFlushDataset = '',
    this.printerVariant = '',
    this.extruderClearanceDistToRod = '0',
    this.extruderClearanceHeightToLid = '0',
    this.extruderClearanceHeightToRod = '0',
    this.extruderClearanceMaxRadius = '0',
    this.extruderColour = '',
    this.extruderHeightGap = '0',
    this.extruderMaxNozzleCount = '1',
    this.extruderOffset = '0x0',
    this.grabLength = '0',
    this.masterExtruderId = '0',
    this.defaultFilamentProfile = '',
    this.defaultPrintProfile = '',
    this.nozzleType = 'hardened_steel',
    this.nozzleVolume = '52',
    this.extruderType = 'Direct Drive',
    this.extruderVariantList = 'Direct Drive Standard,Direct Drive High Flow',
  });

  Map<String, String> toMap() => {
        'nozzle_diameter': nozzleDiameter,
        'nozzle_height': nozzleHeight,
        'nozzle_flush_dataset': nozzleFlushDataset,
        'printer_variant': printerVariant,
        'extruder_clearance_dist_to_rod': extruderClearanceDistToRod,
        'extruder_clearance_height_to_lid': extruderClearanceHeightToLid,
        'extruder_clearance_height_to_rod': extruderClearanceHeightToRod,
        'extruder_clearance_max_radius': extruderClearanceMaxRadius,
        'extruder_colour': extruderColour,
        'extruder_height_gap': extruderHeightGap,
        'extruder_max_nozzle_count': extruderMaxNozzleCount,
        'extruder_offset': extruderOffset,
        'grab_length': grabLength,
        'master_extruder_id': masterExtruderId,
        'default_filament_profile': defaultFilamentProfile,
        'default_print_profile': defaultPrintProfile,
        // 扩展字段（本地存储，不上传云端）
        'nozzle_type': nozzleType,
        'nozzle_volume': nozzleVolume,
        'extruder_type': extruderType,
        'extruder_variant_list': extruderVariantList,
      };

  Map<String, dynamic> toJson() => _toMachineJson(toMap());

  factory PrinterNozzleParams.fromMap(Map<String, dynamic> map) {
    return PrinterNozzleParams(
      nozzleDiameter: _parseStr(map['nozzle_diameter']),
      nozzleHeight: _parseStr(map['nozzle_height']),
      nozzleFlushDataset: _parseStr(map['nozzle_flush_dataset']),
      printerVariant: _parseStr(map['printer_variant']),
      extruderClearanceDistToRod:
          _parseStr(map['extruder_clearance_dist_to_rod']),
      extruderClearanceHeightToLid:
          _parseStr(map['extruder_clearance_height_to_lid']),
      extruderClearanceHeightToRod:
          _parseStr(map['extruder_clearance_height_to_rod']),
      extruderClearanceMaxRadius:
          _parseStr(map['extruder_clearance_max_radius']),
      extruderColour: _parseStr(map['extruder_colour']),
      extruderHeightGap: _parseStr(map['extruder_height_gap']),
      extruderMaxNozzleCount: _parseStr(map['extruder_max_nozzle_count']),
      extruderOffset: _parseStr(map['extruder_offset']),
      grabLength: _parseStr(map['grab_length']),
      masterExtruderId: _parseStr(map['master_extruder_id']),
      defaultFilamentProfile: _parseStr(map['default_filament_profile']),
      defaultPrintProfile: _parseStr(map['default_print_profile']),
      nozzleType: _parseStrOrDefault(map['nozzle_type'], 'hardened_steel'),
      nozzleVolume: _parseStrOrDefault(map['nozzle_volume'], '52'),
      extruderType: _parseStrOrDefault(map['extruder_type'], 'Direct Drive'),
      extruderVariantList: _parseStrOrDefault(
        map['extruder_variant_list'],
        'Direct Drive Standard,Direct Drive High Flow',
      ),
    );
  }
}

// ===== B. 打印床参数 =====

/// 打印床参数：可打印区域、高度、层高范围、排除区、绕包排除区等（共 8 字段）。
///
/// 对照 fdm_machine_common.json 中以下 key：
/// printable_area, printable_height, max_layer_height, min_layer_height,
/// bed_exclude_area, best_object_pos, wrapping_exclude_area
class PrinterBedParams {
  final String printableArea; // printable_area "0x0,256x0,256x256,0x256"
  final String printableHeight; // printable_height 250/256/325
  final String maxLayerHeight; // max_layer_height
  final String minLayerHeight; // min_layer_height
  final String bedExcludeArea; // bed_exclude_area
  final String bestObjectPos; // best_object_pos
  final String wrappingExcludeArea; // wrapping_exclude_area

  const PrinterBedParams({
    this.printableArea = '0x0,256x0,256x256,0x256',
    this.printableHeight = '256',
    this.maxLayerHeight = '0.28',
    this.minLayerHeight = '0.08',
    this.bedExcludeArea = '0x0,256x0,256x256,0x256',
    this.bestObjectPos = '128x128',
    this.wrappingExcludeArea = '',
  });

  Map<String, String> toMap() => {
        'printable_area': printableArea,
        'printable_height': printableHeight,
        'max_layer_height': maxLayerHeight,
        'min_layer_height': minLayerHeight,
        'bed_exclude_area': bedExcludeArea,
        'best_object_pos': bestObjectPos,
        'wrapping_exclude_area': wrappingExcludeArea,
      };

  Map<String, dynamic> toJson() => _toMachineJson(toMap());

  factory PrinterBedParams.fromMap(Map<String, dynamic> map) {
    return PrinterBedParams(
      printableArea: _parseStr(map['printable_area']),
      printableHeight: _parseStr(map['printable_height']),
      maxLayerHeight: _parseStr(map['max_layer_height']),
      minLayerHeight: _parseStr(map['min_layer_height']),
      bedExcludeArea: _parseStr(map['bed_exclude_area']),
      bestObjectPos: _parseStr(map['best_object_pos']),
      wrappingExcludeArea: _parseStr(map['wrapping_exclude_area']),
    );
  }
}

// ===== C. 机械限制参数 =====

/// 机械限制参数：最大速度/加速度/Jerk/力/速率（共 23 字段）。
///
/// 对照 fdm_machine_common.json 中以下 key：
/// machine_max_acceleration_e, machine_max_acceleration_extruding,
/// machine_max_acceleration_retracting, machine_max_acceleration_x,
/// machine_max_acceleration_y, machine_max_acceleration_z,
/// machine_max_force_Y, machine_max_jerk_e, machine_max_jerk_x,
/// machine_max_jerk_y, machine_max_jerk_z, machine_max_printed_mass,
/// machine_max_speed_e, machine_max_speed_x, machine_max_speed_y,
/// machine_max_speed_z, machine_min_extruding_rate, machine_min_travel_rate,
/// machine_bed_mass_Y
///
/// 注意：本类字段以 max_accel_/max_speed_/max_jerk_ 简写命名，
/// 通过 [_toBambuMachineKey] 自动加 `machine_` 前缀和完整单词。
class PrinterMechanicalParams {
  // 最大加速度
  final String maxAccelX; // machine_max_acceleration_x
  final String maxAccelY; // machine_max_acceleration_y
  final String maxAccelZ; // machine_max_acceleration_z
  final String maxAccelE; // machine_max_acceleration_e
  final String maxAccelExtruding; // machine_max_acceleration_extruding
  final String maxAccelRetracting; // machine_max_acceleration_retracting

  // 最大速度
  final String maxSpeedX; // machine_max_speed_x
  final String maxSpeedY; // machine_max_speed_y
  final String maxSpeedZ; // machine_max_speed_z
  final String maxSpeedE; // machine_max_speed_e

  // 最大 Jerk
  final String maxJerkX; // machine_max_jerk_x
  final String maxJerkY; // machine_max_jerk_y
  final String maxJerkZ; // machine_max_jerk_z
  final String maxJerkE; // machine_max_jerk_e

  // 力/质量限制
  final String machineMaxForceY; // machine_max_force_Y
  final String machineMaxPrintedMass; // machine_max_printed_mass
  final String machineBedMassY; // machine_bed_mass_Y

  // 最小速率
  final String machineMinExtrudingRate; // machine_min_extruding_rate
  final String machineMinTravelRate; // machine_min_travel_rate

  const PrinterMechanicalParams({
    this.maxAccelX = '10000',
    this.maxAccelY = '10000',
    this.maxAccelZ = '200',
    this.maxAccelE = '5000',
    this.maxAccelExtruding = '2000',
    this.maxAccelRetracting = '5000',
    this.maxSpeedX = '500',
    this.maxSpeedY = '500',
    this.maxSpeedZ = '12',
    this.maxSpeedE = '60',
    this.maxJerkX = '8',
    this.maxJerkY = '8',
    this.maxJerkZ = '0.4',
    this.maxJerkE = '5',
    this.machineMaxForceY = '0',
    this.machineMaxPrintedMass = '0',
    this.machineBedMassY = '0',
    this.machineMinExtrudingRate = '0',
    this.machineMinTravelRate = '0',
  });

  Map<String, String> toMap() => {
        'max_accel_x': maxAccelX,
        'max_accel_y': maxAccelY,
        'max_accel_z': maxAccelZ,
        'max_accel_e': maxAccelE,
        'max_accel_extruding': maxAccelExtruding,
        'max_accel_retracting': maxAccelRetracting,
        'max_speed_x': maxSpeedX,
        'max_speed_y': maxSpeedY,
        'max_speed_z': maxSpeedZ,
        'max_speed_e': maxSpeedE,
        'max_jerk_x': maxJerkX,
        'max_jerk_y': maxJerkY,
        'max_jerk_z': maxJerkZ,
        'max_jerk_e': maxJerkE,
        // 这些字段已在官方 key 命名，直接存
        'machine_max_force_Y': machineMaxForceY,
        'machine_max_printed_mass': machineMaxPrintedMass,
        'machine_bed_mass_Y': machineBedMassY,
        'machine_min_extruding_rate': machineMinExtrudingRate,
        'machine_min_travel_rate': machineMinTravelRate,
      };

  Map<String, dynamic> toJson() => _toMachineJson(toMap());

  factory PrinterMechanicalParams.fromMap(Map<String, dynamic> map) {
    // 兼容 Bambu Studio 官方 JSON 的 machine_ 前缀 key
    String val(String internalKey) {
      return _parseStr(
        map[internalKey] ?? map[_toBambuMachineKey(internalKey)],
      );
    }

    return PrinterMechanicalParams(
      maxAccelX: val('max_accel_x'),
      maxAccelY: val('max_accel_y'),
      maxAccelZ: val('max_accel_z'),
      maxAccelE: val('max_accel_e'),
      maxAccelExtruding: val('max_accel_extruding'),
      maxAccelRetracting: val('max_accel_retracting'),
      maxSpeedX: val('max_speed_x'),
      maxSpeedY: val('max_speed_y'),
      maxSpeedZ: val('max_speed_z'),
      maxSpeedE: val('max_speed_e'),
      maxJerkX: val('max_jerk_x'),
      maxJerkY: val('max_jerk_y'),
      maxJerkZ: val('max_jerk_z'),
      maxJerkE: val('max_jerk_e'),
      machineMaxForceY: _parseStr(map['machine_max_force_Y']),
      machineMaxPrintedMass: _parseStr(map['machine_max_printed_mass']),
      machineBedMassY: _parseStr(map['machine_bed_mass_Y']),
      machineMinExtrudingRate: _parseStr(map['machine_min_extruding_rate']),
      machineMinTravelRate: _parseStr(map['machine_min_travel_rate']),
    );
  }
}

// ===== D. 功能开关参数 =====

/// 功能开关：回抽、G-code、时间参数、加热、风扇、辅助功能等（共 42 字段）。
///
/// 对照 fdm_machine_common.json 中以下 key：
/// auxiliary_fan, scan_first_layer, silent_mode, support_air_filtration,
/// support_chamber_temp_control, support_cooling_filter,
/// support_fast_purge_mode, support_object_skip_flush,
/// cooling_filter_enabled, enable_long_retraction_when_cut,
/// enable_pre_heating, fan_direction, group_algo_with_time,
/// hotend_cooling_rate, hotend_heating_rate, machine_hotend_change_time,
/// machine_load_filament_time, machine_switch_extruder_time,
/// machine_unload_filament_time, machine_prepare_compensation_time,
/// print_in_clockwise, printer_technology, single_extruder_multi_material,
/// upward_compatible_machine, change_filament_gcode, machine_end_gcode,
/// machine_start_gcode, time_lapse_gcode, wrapping_detection_gcode,
/// gcode_flavor, deretraction_speed, long_retractions_when_cut,
/// retraction_distances_when_cut, retract_before_wipe,
/// retract_length_toolchange, retract_restart_extra,
/// retract_restart_extra_toolchange, retract_when_changing_layer,
/// retraction_distances_when_cut, retraction_length,
/// retraction_minimum_travel, retraction_speed, wipe, z_hop
class PrinterFeatureParams {
  // 基础功能开关
  final String auxiliaryFan; // auxiliary_fan
  final String scanFirstLayer; // scan_first_layer
  final String silentMode; // silent_mode
  final String supportAirFiltration; // support_air_filtration
  final String supportChamberTempControl; // support_chamber_temp_control
  final String supportCoolingFilter; // support_cooling_filter
  final String supportFastPurgeMode; // support_fast_purge_mode
  final String supportObjectSkipFlush; // support_object_skip_flush
  final String coolingFilterEnabled; // cooling_filter_enabled
  final String enableLongRetractionWhenCut; // enable_long_retraction_when_cut
  final String enablePreHeating; // enable_pre_heating
  final String fanDirection; // fan_direction
  final String groupAlgoWithTime; // group_algo_with_time
  final String printInClockwise; // print_in_clockwise
  final String printerTechnology; // printer_technology
  final String singleExtruderMultiMaterial; // single_extruder_multi_material
  final String upwardCompatibleMachine; // upward_compatible_machine

  // 加热/温度变化率
  final String hotendCoolingRate; // hotend_cooling_rate
  final String hotendHeatingRate; // hotend_heating_rate

  // 时间参数
  final String machineHotendChangeTime; // machine_hotend_change_time
  final String machineLoadFilamentTime; // machine_load_filament_time
  final String machineSwitchExtruderTime; // machine_switch_extruder_time
  final String machineUnloadFilamentTime; // machine_unload_filament_time
  final String
      machinePrepareCompensationTime; // machine_prepare_compensation_time

  // G-code
  final String changeFilamentGcode; // change_filament_gcode
  final String machineEndGcode; // machine_end_gcode
  final String machineStartGcode; // machine_start_gcode
  final String timeLapseGcode; // time_lapse_gcode
  final String wrappingDetectionGcode; // wrapping_detection_gcode
  final String gcodeFlavor; // gcode_flavor

  // 回抽参数（machine 侧）
  final String deretractionSpeed; // deretraction_speed
  final String longRetractionsWhenCut; // long_retractions_when_cut
  final String retractionDistancesWhenCut; // retraction_distances_when_cut
  final String retractBeforeWipe; // retract_before_wipe
  final String retractLengthToolchange; // retract_length_toolchange
  final String retractRestartExtra; // retract_restart_extra
  final String
      retractRestartExtraToolchange; // retract_restart_extra_toolchange
  final String retractWhenChangingLayer; // retract_when_changing_layer
  final String retractionLength; // retraction_length
  final String retractionMinimumTravel; // retraction_minimum_travel
  final String retractionSpeed; // retraction_speed
  final String wipe; // wipe
  final String zHop; // z_hop

  const PrinterFeatureParams({
    this.auxiliaryFan = '1',
    this.scanFirstLayer = '0',
    this.silentMode = '0',
    this.supportAirFiltration = '0',
    this.supportChamberTempControl = '0',
    this.supportCoolingFilter = '0',
    this.supportFastPurgeMode = '0',
    this.supportObjectSkipFlush = '0',
    this.coolingFilterEnabled = '0',
    this.enableLongRetractionWhenCut = '0',
    this.enablePreHeating = '0',
    this.fanDirection = '',
    this.groupAlgoWithTime = '0',
    this.printInClockwise = '0',
    this.printerTechnology = 'FFF',
    this.singleExtruderMultiMaterial = '0',
    this.upwardCompatibleMachine = '',
    this.hotendCoolingRate = '0',
    this.hotendHeatingRate = '0',
    this.machineHotendChangeTime = '0',
    this.machineLoadFilamentTime = '0',
    this.machineSwitchExtruderTime = '0',
    this.machineUnloadFilamentTime = '0',
    this.machinePrepareCompensationTime = '0',
    this.changeFilamentGcode = '',
    this.machineEndGcode = '',
    this.machineStartGcode = '',
    this.timeLapseGcode = '',
    this.wrappingDetectionGcode = '',
    this.gcodeFlavor = 'marlin',
    this.deretractionSpeed = '0',
    this.longRetractionsWhenCut = '0',
    this.retractionDistancesWhenCut = '0',
    this.retractBeforeWipe = '0',
    this.retractLengthToolchange = '0',
    this.retractRestartExtra = '0',
    this.retractRestartExtraToolchange = '0',
    this.retractWhenChangingLayer = '0',
    this.retractionLength = '0',
    this.retractionMinimumTravel = '0',
    this.retractionSpeed = '0',
    this.wipe = '0',
    this.zHop = '0',
  });

  Map<String, String> toMap() => {
        'auxiliary_fan': auxiliaryFan,
        'scan_first_layer': scanFirstLayer,
        'silent_mode': silentMode,
        'support_air_filtration': supportAirFiltration,
        'support_chamber_temp_control': supportChamberTempControl,
        'support_cooling_filter': supportCoolingFilter,
        'support_fast_purge_mode': supportFastPurgeMode,
        'support_object_skip_flush': supportObjectSkipFlush,
        'cooling_filter_enabled': coolingFilterEnabled,
        'enable_long_retraction_when_cut': enableLongRetractionWhenCut,
        'enable_pre_heating': enablePreHeating,
        'fan_direction': fanDirection,
        'group_algo_with_time': groupAlgoWithTime,
        'print_in_clockwise': printInClockwise,
        'printer_technology': printerTechnology,
        'single_extruder_multi_material': singleExtruderMultiMaterial,
        'upward_compatible_machine': upwardCompatibleMachine,
        'hotend_cooling_rate': hotendCoolingRate,
        'hotend_heating_rate': hotendHeatingRate,
        'machine_hotend_change_time': machineHotendChangeTime,
        'machine_load_filament_time': machineLoadFilamentTime,
        'machine_switch_extruder_time': machineSwitchExtruderTime,
        'machine_unload_filament_time': machineUnloadFilamentTime,
        'machine_prepare_compensation_time': machinePrepareCompensationTime,
        'change_filament_gcode': changeFilamentGcode,
        'machine_end_gcode': machineEndGcode,
        'machine_start_gcode': machineStartGcode,
        'time_lapse_gcode': timeLapseGcode,
        'wrapping_detection_gcode': wrappingDetectionGcode,
        'gcode_flavor': gcodeFlavor,
        'deretraction_speed': deretractionSpeed,
        'long_retractions_when_cut': longRetractionsWhenCut,
        'retraction_distances_when_cut': retractionDistancesWhenCut,
        'retract_before_wipe': retractBeforeWipe,
        'retract_length_toolchange': retractLengthToolchange,
        'retract_restart_extra': retractRestartExtra,
        'retract_restart_extra_toolchange': retractRestartExtraToolchange,
        'retract_when_changing_layer': retractWhenChangingLayer,
        'retraction_length': retractionLength,
        'retraction_minimum_travel': retractionMinimumTravel,
        'retraction_speed': retractionSpeed,
        'wipe': wipe,
        'z_hop': zHop,
      };

  Map<String, dynamic> toJson() => _toMachineJson(toMap());

  factory PrinterFeatureParams.fromMap(Map<String, dynamic> map) {
    return PrinterFeatureParams(
      auxiliaryFan: _parseStr(map['auxiliary_fan']),
      scanFirstLayer: _parseStr(map['scan_first_layer']),
      silentMode: _parseStr(map['silent_mode']),
      supportAirFiltration: _parseStr(map['support_air_filtration']),
      supportChamberTempControl: _parseStr(map['support_chamber_temp_control']),
      supportCoolingFilter: _parseStr(map['support_cooling_filter']),
      supportFastPurgeMode: _parseStr(map['support_fast_purge_mode']),
      supportObjectSkipFlush: _parseStr(map['support_object_skip_flush']),
      coolingFilterEnabled: _parseStr(map['cooling_filter_enabled']),
      enableLongRetractionWhenCut:
          _parseStr(map['enable_long_retraction_when_cut']),
      enablePreHeating: _parseStr(map['enable_pre_heating']),
      fanDirection: _parseStr(map['fan_direction']),
      groupAlgoWithTime: _parseStr(map['group_algo_with_time']),
      printInClockwise: _parseStr(map['print_in_clockwise']),
      printerTechnology: _parseStr(map['printer_technology']),
      singleExtruderMultiMaterial:
          _parseStr(map['single_extruder_multi_material']),
      upwardCompatibleMachine: _parseStr(map['upward_compatible_machine']),
      hotendCoolingRate: _parseStr(map['hotend_cooling_rate']),
      hotendHeatingRate: _parseStr(map['hotend_heating_rate']),
      machineHotendChangeTime: _parseStr(map['machine_hotend_change_time']),
      machineLoadFilamentTime: _parseStr(map['machine_load_filament_time']),
      machineSwitchExtruderTime: _parseStr(map['machine_switch_extruder_time']),
      machineUnloadFilamentTime: _parseStr(map['machine_unload_filament_time']),
      machinePrepareCompensationTime:
          _parseStr(map['machine_prepare_compensation_time']),
      changeFilamentGcode: _parseStr(map['change_filament_gcode']),
      machineEndGcode: _parseStr(map['machine_end_gcode']),
      machineStartGcode: _parseStr(map['machine_start_gcode']),
      timeLapseGcode: _parseStr(map['time_lapse_gcode']),
      wrappingDetectionGcode: _parseStr(map['wrapping_detection_gcode']),
      gcodeFlavor: _parseStr(map['gcode_flavor']),
      deretractionSpeed: _parseStr(map['deretraction_speed']),
      longRetractionsWhenCut: _parseStr(map['long_retractions_when_cut']),
      retractionDistancesWhenCut:
          _parseStr(map['retraction_distances_when_cut']),
      retractBeforeWipe: _parseStr(map['retract_before_wipe']),
      retractLengthToolchange: _parseStr(map['retract_length_toolchange']),
      retractRestartExtra: _parseStr(map['retract_restart_extra']),
      retractRestartExtraToolchange:
          _parseStr(map['retract_restart_extra_toolchange']),
      retractWhenChangingLayer: _parseStr(map['retract_when_changing_layer']),
      retractionLength: _parseStr(map['retraction_length']),
      retractionMinimumTravel: _parseStr(map['retraction_minimum_travel']),
      retractionSpeed: _parseStr(map['retraction_speed']),
      wipe: _parseStr(map['wipe']),
      zHop: _parseStr(map['z_hop']),
    );
  }
}
