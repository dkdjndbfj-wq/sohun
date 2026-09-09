import 'dart:convert';

/// 耗材丝配置（Filament Preset）。
///
/// 对应 Bambu Studio 的 filament/*.json，完整覆盖官方 fdm_filament_common.json
/// 的全部 130 个字段。所有字段用 String 类型存储（与 Bambu Studio 一致）。
///
/// 6 个分类：
/// - [FilamentTempParams] 温度（喷嘴温度 + 5 种打印板温度 + 烘干塔等）
/// - [FilamentFlowParams] 流量（流量比、最大体积速度、换料、擦料塔等）
/// - [FilamentFanParams] 风扇（风扇速度、冷却逻辑、排风、悬垂速度等）
/// - [FilamentRetractionParams] 回抽（回抽长度、速度、Z跳高、斜拼接缝等）
/// - [FilamentDryingParams] 烘干（AMS 烘干、腔体烘干、软化温度等）
/// - [FilamentPropertyParams] 耗材属性（材料类型、密度、成本、安全认证、补偿系数等）
class FilamentPreset {
  final String id;
  final String name;
  final String? description;
  final String? author;
  final String
      material; // PLA/PETG/ABS/ASA/TPU/PC/PA/PVA/PPS/PPA/PE/PCTG/PHA/HIPS/EVA/BVOH/PP
  final String? vendor; // 厂商
  final String? scene;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String inherits; // 默认 'fdm_filament_common'

  final FilamentTempParams temp;
  final FilamentFlowParams flow;
  final FilamentFanParams fan;
  final FilamentRetractionParams retraction;
  final FilamentDryingParams drying;
  final FilamentPropertyParams properties;

  const FilamentPreset({
    required this.id,
    required this.name,
    this.description,
    this.author,
    required this.material,
    this.vendor,
    this.scene,
    required this.createdAt,
    required this.updatedAt,
    this.inherits = 'fdm_filament_common',
    required this.temp,
    required this.flow,
    required this.fan,
    required this.retraction,
    required this.drying,
    required this.properties,
  });

  /// 从 .bbsparam 格式的 JSON 字符串导入。
  factory FilamentPreset.fromBbsparamJson(String content) {
    final root = jsonDecode(content) as Map<String, dynamic>;
    final preset = root['preset'] as Map<String, dynamic>? ?? {};
    final params = preset['params'] as Map<String, dynamic>? ?? {};
    final now = DateTime.now();
    return FilamentPreset(
      id: preset['id'] as String? ?? '',
      name: preset['name'] as String? ?? '未命名耗材',
      description: preset['description'] as String?,
      author: preset['author'] as String?,
      material: preset['material'] as String? ?? 'PLA',
      vendor: preset['vendor'] as String?,
      scene: preset['scene'] as String?,
      createdAt: preset['createdAt'] != null
          ? DateTime.tryParse(preset['createdAt'] as String) ?? now
          : now,
      updatedAt: preset['updatedAt'] != null
          ? DateTime.tryParse(preset['updatedAt'] as String) ?? now
          : now,
      inherits: preset['inherits'] as String? ?? 'fdm_filament_common',
      temp: FilamentTempParams.fromMap(
        params['temp'] as Map<String, dynamic>? ?? {},
      ),
      flow: FilamentFlowParams.fromMap(
        params['flow'] as Map<String, dynamic>? ?? {},
      ),
      fan: FilamentFanParams.fromMap(
        params['fan'] as Map<String, dynamic>? ?? {},
      ),
      retraction: FilamentRetractionParams.fromMap(
        params['retraction'] as Map<String, dynamic>? ?? {},
      ),
      drying: FilamentDryingParams.fromMap(
        params['drying'] as Map<String, dynamic>? ?? {},
      ),
      properties: FilamentPropertyParams.fromMap(
        params['properties'] as Map<String, dynamic>? ?? {},
      ),
    );
  }

  FilamentPreset copyWith({
    String? id,
    String? name,
    String? description,
    String? author,
    String? material,
    String? vendor,
    String? scene,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? inherits,
    FilamentTempParams? temp,
    FilamentFlowParams? flow,
    FilamentFanParams? fan,
    FilamentRetractionParams? retraction,
    FilamentDryingParams? drying,
    FilamentPropertyParams? properties,
  }) {
    return FilamentPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      author: author ?? this.author,
      material: material ?? this.material,
      vendor: vendor ?? this.vendor,
      scene: scene ?? this.scene,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      inherits: inherits ?? this.inherits,
      temp: temp ?? this.temp,
      flow: flow ?? this.flow,
      fan: fan ?? this.fan,
      retraction: retraction ?? this.retraction,
      drying: drying ?? this.drying,
      properties: properties ?? this.properties,
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
        'description': description,
        'author': author,
        'material': material,
        'vendor': vendor,
        'scene': scene,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'inherits': inherits,
        'params': {
          'temp': temp.toMap(),
          'flow': flow.toMap(),
          'fan': fan.toMap(),
          'retraction': retraction.toMap(),
          'drying': drying.toMap(),
          'properties': properties.toMap(),
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
      ...temp.toMap(),
      ...flow.toMap(),
      ...fan.toMap(),
      ...retraction.toMap(),
      ...drying.toMap(),
      ...properties.toMap(),
    };
  }
}

// ===== 辅助函数 =====

/// 从动态值解析为字符串（兼容 Bambu Studio 的数组格式 ["0.2"] → "0.2"）。
String _parseStr(dynamic v) {
  if (v == null) return '';
  if (v is List && v.isNotEmpty) {
    return v.first?.toString() ?? '';
  }
  return v.toString();
}

/// 把 toMap() 结果（全 String）转为 Bambu Studio Filament JSON 格式。
/// Bambu Studio 的 filament JSON 中所有字段都是数组（每通道一个值）。
Map<String, dynamic> _toFilamentJson(Map<String, String> map) {
  return map.map((key, value) => MapEntry(key, [value]));
}

// ===== A. 温度参数（含 5 种打印板温度 + 烘干塔相关）=====

/// 温度参数：喷嘴温度 + 5 种打印板温度 + 预热/冲洗/塔温度（共 19 字段）。
///
/// 对照 fdm_filament_common.json 中以下 key：
/// nozzle_temperature, nozzle_temperature_initial_layer,
/// nozzle_temperature_range_high, nozzle_temperature_range_low,
/// temperature_vitrification, cool_plate_temp,
/// cool_plate_temp_initial_layer, eng_plate_temp,
/// eng_plate_temp_initial_layer, hot_plate_temp,
/// hot_plate_temp_initial_layer, textured_plate_temp,
/// textured_plate_temp_initial_layer, supertack_plate_temp,
/// supertack_plate_temp_initial_layer, chamber_temperatures,
/// filament_flush_temp, filament_flush_temp_fast,
/// filament_pre_cooling_temperature, filament_pre_cooling_temperature_nc,
/// filament_preheat_temperature_delta,
/// filament_tower_interface_print_temp
class FilamentTempParams {
  // 喷嘴温度
  final String nozzleTemperature; // nozzle_temperature
  final String
      nozzleTemperatureInitialLayer; // nozzle_temperature_initial_layer
  final String nozzleTemperatureRangeHigh; // nozzle_temperature_range_high
  final String nozzleTemperatureRangeLow; // nozzle_temperature_range_low
  final String temperatureVitrification; // temperature_vitrification

  // 5 种打印板温度（每种 2 个字段：首层 + 其他层）
  final String coolPlateTemp; // cool_plate_temp
  final String coolPlateTempInitialLayer; // cool_plate_temp_initial_layer
  final String engPlateTemp; // eng_plate_temp
  final String engPlateTempInitialLayer; // eng_plate_temp_initial_layer
  final String hotPlateTemp; // hot_plate_temp
  final String hotPlateTempInitialLayer; // hot_plate_temp_initial_layer
  final String texturedPlateTemp; // textured_plate_temp
  final String
      texturedPlateTempInitialLayer; // textured_plate_temp_initial_layer
  final String supertackPlateTemp; // supertack_plate_temp
  final String
      supertackPlateTempInitialLayer; // supertack_plate_temp_initial_layer

  final String chamberTemperatures; // chamber_temperatures

  // 冲洗温度（换料时）
  final String filamentFlushTemp; // filament_flush_temp
  final String filamentFlushTempFast; // filament_flush_temp_fast

  // 预冷温度
  final String
      filamentPreCoolingTemperature; // filament_pre_cooling_temperature
  final String
      filamentPreCoolingTemperatureNc; // filament_pre_cooling_temperature_nc

  // 预热温差
  final String
      filamentPreheatTemperatureDelta; // filament_preheat_temperature_delta

  // 塔接口打印温度
  final String
      filamentTowerInterfacePrintTemp; // filament_tower_interface_print_temp

  const FilamentTempParams({
    this.nozzleTemperature = '220',
    this.nozzleTemperatureInitialLayer = '220',
    this.nozzleTemperatureRangeHigh = '250',
    this.nozzleTemperatureRangeLow = '190',
    this.temperatureVitrification = '60',
    this.coolPlateTemp = '35',
    this.coolPlateTempInitialLayer = '35',
    this.engPlateTemp = '40',
    this.engPlateTempInitialLayer = '40',
    this.hotPlateTemp = '55',
    this.hotPlateTempInitialLayer = '55',
    this.texturedPlateTemp = '55',
    this.texturedPlateTempInitialLayer = '55',
    this.supertackPlateTemp = '40',
    this.supertackPlateTempInitialLayer = '40',
    this.chamberTemperatures = '0',
    this.filamentFlushTemp = '220',
    this.filamentFlushTempFast = '220',
    this.filamentPreCoolingTemperature = '220',
    this.filamentPreCoolingTemperatureNc = '220',
    this.filamentPreheatTemperatureDelta = '0',
    this.filamentTowerInterfacePrintTemp = '0',
  });

  Map<String, String> toMap() => {
        'nozzle_temperature': nozzleTemperature,
        'nozzle_temperature_initial_layer': nozzleTemperatureInitialLayer,
        'nozzle_temperature_range_high': nozzleTemperatureRangeHigh,
        'nozzle_temperature_range_low': nozzleTemperatureRangeLow,
        'temperature_vitrification': temperatureVitrification,
        'cool_plate_temp': coolPlateTemp,
        'cool_plate_temp_initial_layer': coolPlateTempInitialLayer,
        'eng_plate_temp': engPlateTemp,
        'eng_plate_temp_initial_layer': engPlateTempInitialLayer,
        'hot_plate_temp': hotPlateTemp,
        'hot_plate_temp_initial_layer': hotPlateTempInitialLayer,
        'textured_plate_temp': texturedPlateTemp,
        'textured_plate_temp_initial_layer': texturedPlateTempInitialLayer,
        'supertack_plate_temp': supertackPlateTemp,
        'supertack_plate_temp_initial_layer': supertackPlateTempInitialLayer,
        'chamber_temperatures': chamberTemperatures,
        'filament_flush_temp': filamentFlushTemp,
        'filament_flush_temp_fast': filamentFlushTempFast,
        'filament_pre_cooling_temperature': filamentPreCoolingTemperature,
        'filament_pre_cooling_temperature_nc': filamentPreCoolingTemperatureNc,
        'filament_preheat_temperature_delta': filamentPreheatTemperatureDelta,
        'filament_tower_interface_print_temp': filamentTowerInterfacePrintTemp,
      };

  Map<String, dynamic> toJson() => _toFilamentJson(toMap());

  factory FilamentTempParams.fromMap(Map<String, dynamic> map) {
    return FilamentTempParams(
      nozzleTemperature: _parseStr(map['nozzle_temperature']),
      nozzleTemperatureInitialLayer:
          _parseStr(map['nozzle_temperature_initial_layer']),
      nozzleTemperatureRangeHigh:
          _parseStr(map['nozzle_temperature_range_high']),
      nozzleTemperatureRangeLow: _parseStr(map['nozzle_temperature_range_low']),
      temperatureVitrification: _parseStr(map['temperature_vitrification']),
      coolPlateTemp: _parseStr(map['cool_plate_temp']),
      coolPlateTempInitialLayer:
          _parseStr(map['cool_plate_temp_initial_layer']),
      engPlateTemp: _parseStr(map['eng_plate_temp']),
      engPlateTempInitialLayer: _parseStr(map['eng_plate_temp_initial_layer']),
      hotPlateTemp: _parseStr(map['hot_plate_temp']),
      hotPlateTempInitialLayer: _parseStr(map['hot_plate_temp_initial_layer']),
      texturedPlateTemp: _parseStr(map['textured_plate_temp']),
      texturedPlateTempInitialLayer:
          _parseStr(map['textured_plate_temp_initial_layer']),
      supertackPlateTemp: _parseStr(map['supertack_plate_temp']),
      supertackPlateTempInitialLayer:
          _parseStr(map['supertack_plate_temp_initial_layer']),
      chamberTemperatures: _parseStr(map['chamber_temperatures']),
      filamentFlushTemp: _parseStr(map['filament_flush_temp']),
      filamentFlushTempFast: _parseStr(map['filament_flush_temp_fast']),
      filamentPreCoolingTemperature:
          _parseStr(map['filament_pre_cooling_temperature']),
      filamentPreCoolingTemperatureNc:
          _parseStr(map['filament_pre_cooling_temperature_nc']),
      filamentPreheatTemperatureDelta:
          _parseStr(map['filament_preheat_temperature_delta']),
      filamentTowerInterfacePrintTemp:
          _parseStr(map['filament_tower_interface_print_temp']),
    );
  }
}

// ===== B. 流量参数 =====

/// 流量参数：流量比、最大体积速度、换料、擦料塔、顶出等（共 19 字段）。
///
/// 对照 fdm_filament_common.json 中以下 key：
/// filament_flow_ratio, filament_max_volumetric_speed,
/// filament_flush_volumetric_speed, filament_ramming_volumetric_speed,
/// filament_adaptive_volumetric_speed, filament_velocity_adaptation_factor,
/// filament_change_length, filament_cooling_before_tower,
/// filament_prime_volume, filament_prime_volume_nc,
/// filament_ramming_travel_time, filament_ramming_travel_time_nc,
/// filament_ramming_volumetric_speed_nc, filament_minimal_purge_on_wipe_tower,
/// filament_tower_interface_pre_extrusion_dist,
/// filament_tower_interface_pre_extrusion_length,
/// filament_tower_interface_purge_volume, filament_tower_ironing_area,
/// volumetric_speed_coefficients
class FilamentFlowParams {
  final String filamentFlowRatio; // filament_flow_ratio
  final String filamentMaxVolumetricSpeed; // filament_max_volumetric_speed
  final String filamentFlushVolumetricSpeed; // filament_flush_volumetric_speed
  final String
      filamentRammingVolumetricSpeed; // filament_ramming_volumetric_speed
  final String
      filamentAdaptiveVolumetricSpeed; // filament_adaptive_volumetric_speed
  final String
      filamentVelocityAdaptationFactor; // filament_velocity_adaptation_factor

  // 换料相关
  final String filamentChangeLength; // filament_change_length
  final String filamentCoolingBeforeTower; // filament_cooling_before_tower
  final String filamentPrimeVolume; // filament_prime_volume
  final String filamentPrimeVolumeNc; // filament_prime_volume_nc
  final String filamentRammingTravelTime; // filament_ramming_travel_time
  final String filamentRammingTravelTimeNc; // filament_ramming_travel_time_nc
  final String
      filamentRammingVolumetricSpeedNc; // filament_ramming_volumetric_speed_nc
  final String
      filamentMinimalPurgeOnWipeTower; // filament_minimal_purge_on_wipe_tower

  // 塔接口相关
  final String
      filamentTowerInterfacePreExtrusionDist; // filament_tower_interface_pre_extrusion_dist
  final String
      filamentTowerInterfacePreExtrusionLength; // filament_tower_interface_pre_extrusion_length
  final String
      filamentTowerInterfacePurgeVolume; // filament_tower_interface_purge_volume
  final String filamentTowerIroningArea; // filament_tower_ironing_area

  // 体积速度系数
  final String volumetricSpeedCoefficients; // volumetric_speed_coefficients

  const FilamentFlowParams({
    this.filamentFlowRatio = '0.98',
    this.filamentMaxVolumetricSpeed = '21',
    this.filamentFlushVolumetricSpeed = '0.8',
    this.filamentRammingVolumetricSpeed = '0.8',
    this.filamentAdaptiveVolumetricSpeed = '0.6',
    this.filamentVelocityAdaptationFactor = '2',
    this.filamentChangeLength = '0',
    this.filamentCoolingBeforeTower = '0',
    this.filamentPrimeVolume = '0',
    this.filamentPrimeVolumeNc = '0',
    this.filamentRammingTravelTime = '0',
    this.filamentRammingTravelTimeNc = '0',
    this.filamentRammingVolumetricSpeedNc = '0',
    this.filamentMinimalPurgeOnWipeTower = '0',
    this.filamentTowerInterfacePreExtrusionDist = '0',
    this.filamentTowerInterfacePreExtrusionLength = '0',
    this.filamentTowerInterfacePurgeVolume = '0',
    this.filamentTowerIroningArea = '0',
    this.volumetricSpeedCoefficients = '0',
  });

  Map<String, String> toMap() => {
        'filament_flow_ratio': filamentFlowRatio,
        'filament_max_volumetric_speed': filamentMaxVolumetricSpeed,
        'filament_flush_volumetric_speed': filamentFlushVolumetricSpeed,
        'filament_ramming_volumetric_speed': filamentRammingVolumetricSpeed,
        'filament_adaptive_volumetric_speed': filamentAdaptiveVolumetricSpeed,
        'filament_velocity_adaptation_factor': filamentVelocityAdaptationFactor,
        'filament_change_length': filamentChangeLength,
        'filament_cooling_before_tower': filamentCoolingBeforeTower,
        'filament_prime_volume': filamentPrimeVolume,
        'filament_prime_volume_nc': filamentPrimeVolumeNc,
        'filament_ramming_travel_time': filamentRammingTravelTime,
        'filament_ramming_travel_time_nc': filamentRammingTravelTimeNc,
        'filament_ramming_volumetric_speed_nc':
            filamentRammingVolumetricSpeedNc,
        'filament_minimal_purge_on_wipe_tower': filamentMinimalPurgeOnWipeTower,
        'filament_tower_interface_pre_extrusion_dist':
            filamentTowerInterfacePreExtrusionDist,
        'filament_tower_interface_pre_extrusion_length':
            filamentTowerInterfacePreExtrusionLength,
        'filament_tower_interface_purge_volume':
            filamentTowerInterfacePurgeVolume,
        'filament_tower_ironing_area': filamentTowerIroningArea,
        'volumetric_speed_coefficients': volumetricSpeedCoefficients,
      };

  Map<String, dynamic> toJson() => _toFilamentJson(toMap());

  factory FilamentFlowParams.fromMap(Map<String, dynamic> map) {
    return FilamentFlowParams(
      filamentFlowRatio: _parseStr(map['filament_flow_ratio']),
      filamentMaxVolumetricSpeed:
          _parseStr(map['filament_max_volumetric_speed']),
      filamentFlushVolumetricSpeed:
          _parseStr(map['filament_flush_volumetric_speed']),
      filamentRammingVolumetricSpeed:
          _parseStr(map['filament_ramming_volumetric_speed']),
      filamentAdaptiveVolumetricSpeed:
          _parseStr(map['filament_adaptive_volumetric_speed']),
      filamentVelocityAdaptationFactor:
          _parseStr(map['filament_velocity_adaptation_factor']),
      filamentChangeLength: _parseStr(map['filament_change_length']),
      filamentCoolingBeforeTower:
          _parseStr(map['filament_cooling_before_tower']),
      filamentPrimeVolume: _parseStr(map['filament_prime_volume']),
      filamentPrimeVolumeNc: _parseStr(map['filament_prime_volume_nc']),
      filamentRammingTravelTime: _parseStr(map['filament_ramming_travel_time']),
      filamentRammingTravelTimeNc:
          _parseStr(map['filament_ramming_travel_time_nc']),
      filamentRammingVolumetricSpeedNc:
          _parseStr(map['filament_ramming_volumetric_speed_nc']),
      filamentMinimalPurgeOnWipeTower:
          _parseStr(map['filament_minimal_purge_on_wipe_tower']),
      filamentTowerInterfacePreExtrusionDist:
          _parseStr(map['filament_tower_interface_pre_extrusion_dist']),
      filamentTowerInterfacePreExtrusionLength:
          _parseStr(map['filament_tower_interface_pre_extrusion_length']),
      filamentTowerInterfacePurgeVolume:
          _parseStr(map['filament_tower_interface_purge_volume']),
      filamentTowerIroningArea: _parseStr(map['filament_tower_ironing_area']),
      volumetricSpeedCoefficients:
          _parseStr(map['volumetric_speed_coefficients']),
    );
  }
}

// ===== C. 风扇参数 =====

/// 风扇参数：风扇速度、冷却逻辑、排风、悬垂速度等（共 30 字段）。
///
/// 对照 fdm_filament_common.json 中以下 key：
/// fan_max_speed, fan_min_speed, fan_cooling_layer_time,
/// close_fan_the_first_x_layers, full_fan_speed_layer,
/// overhang_fan_speed, overhang_fan_threshold,
/// additional_cooling_fan_speed, close_additional_fan_first_x_layers,
/// additional_fan_full_speed_layer, reduce_fan_stop_start_freq,
/// slow_down_for_layer_cooling, cooling_slowdown_logic,
/// slow_down_layer_time, slow_down_min_speed,
/// no_slow_down_for_cooling_on_outwalls, activate_air_filtration,
/// complete_print_exhaust_fan_speed, during_print_exhaust_fan_speed,
/// filament_enable_overhang_speed, override_process_overhang_speed,
/// filament_overhang_1_4_speed, filament_overhang_2_4_speed,
/// filament_overhang_3_4_speed, filament_overhang_4_4_speed,
/// filament_overhang_totally_speed, filament_bridge_speed,
/// cooling_perimeter_transition_distance
class FilamentFanParams {
  // 基础风扇
  final String fanMaxSpeed; // fan_max_speed
  final String fanMinSpeed; // fan_min_speed
  final String fanCoolingLayerTime; // fan_cooling_layer_time
  final String closeFanTheFirstXLayers; // close_fan_the_first_x_layers
  final String fullFanSpeedLayer; // full_fan_speed_layer
  final String overhangFanSpeed; // overhang_fan_speed
  final String overhangFanThreshold; // overhang_fan_threshold

  // 辅助风扇
  final String additionalCoolingFanSpeed; // additional_cooling_fan_speed
  final String
      closeAdditionalFanFirstXLayers; // close_additional_fan_first_x_layers
  final String additionalFanFullSpeedLayer; // additional_fan_full_speed_layer

  // 频率/冷却逻辑
  final String reduceFanStopStartFreq; // reduce_fan_stop_start_freq
  final String slowDownForLayerCooling; // slow_down_for_layer_cooling
  final String coolingSlowdownLogic; // cooling_slowdown_logic
  final String slowDownLayerTime; // slow_down_layer_time
  final String slowDownMinSpeed; // slow_down_min_speed
  final String
      noSlowDownForCoolingOnOutwalls; // no_slow_down_for_cooling_on_outwalls

  // 空气过滤/排风
  final String activateAirFiltration; // activate_air_filtration
  final String completePrintExhaustFanSpeed; // complete_print_exhaust_fan_speed
  final String duringPrintExhaustFanSpeed; // during_print_exhaust_fan_speed

  // 悬垂/桥接速度（耗材侧）
  final String filamentEnableOverhangSpeed; // filament_enable_overhang_speed
  final String overrideProcessOverhangSpeed; // override_process_overhang_speed
  final String filamentOverhang14Speed; // filament_overhang_1_4_speed
  final String filamentOverhang24Speed; // filament_overhang_2_4_speed
  final String filamentOverhang34Speed; // filament_overhang_3_4_speed
  final String filamentOverhang44Speed; // filament_overhang_4_4_speed
  final String filamentOverhangTotallySpeed; // filament_overhang_totally_speed
  final String filamentBridgeSpeed; // filament_bridge_speed

  // 冷却周长转换距离
  final String
      coolingPerimeterTransitionDistance; // cooling_perimeter_transition_distance

  const FilamentFanParams({
    this.fanMaxSpeed = '100',
    this.fanMinSpeed = '20',
    this.fanCoolingLayerTime = '5',
    this.closeFanTheFirstXLayers = '1',
    this.fullFanSpeedLayer = '0',
    this.overhangFanSpeed = '100',
    this.overhangFanThreshold = '50%',
    this.additionalCoolingFanSpeed = '0',
    this.closeAdditionalFanFirstXLayers = '0',
    this.additionalFanFullSpeedLayer = '0',
    this.reduceFanStopStartFreq = '1',
    this.slowDownForLayerCooling = '1',
    this.coolingSlowdownLogic = 'all',
    this.slowDownLayerTime = '3',
    this.slowDownMinSpeed = '20',
    this.noSlowDownForCoolingOnOutwalls = '0',
    this.activateAirFiltration = '0',
    this.completePrintExhaustFanSpeed = '80',
    this.duringPrintExhaustFanSpeed = '0',
    this.filamentEnableOverhangSpeed = '1',
    this.overrideProcessOverhangSpeed = '0',
    this.filamentOverhang14Speed = '0',
    this.filamentOverhang24Speed = '0',
    this.filamentOverhang34Speed = '0',
    this.filamentOverhang44Speed = '0',
    this.filamentOverhangTotallySpeed = '0',
    this.filamentBridgeSpeed = '0',
    this.coolingPerimeterTransitionDistance = '0',
  });

  Map<String, String> toMap() => {
        'fan_max_speed': fanMaxSpeed,
        'fan_min_speed': fanMinSpeed,
        'fan_cooling_layer_time': fanCoolingLayerTime,
        'close_fan_the_first_x_layers': closeFanTheFirstXLayers,
        'full_fan_speed_layer': fullFanSpeedLayer,
        'overhang_fan_speed': overhangFanSpeed,
        'overhang_fan_threshold': overhangFanThreshold,
        'additional_cooling_fan_speed': additionalCoolingFanSpeed,
        'close_additional_fan_first_x_layers': closeAdditionalFanFirstXLayers,
        'additional_fan_full_speed_layer': additionalFanFullSpeedLayer,
        'reduce_fan_stop_start_freq': reduceFanStopStartFreq,
        'slow_down_for_layer_cooling': slowDownForLayerCooling,
        'cooling_slowdown_logic': coolingSlowdownLogic,
        'slow_down_layer_time': slowDownLayerTime,
        'slow_down_min_speed': slowDownMinSpeed,
        'no_slow_down_for_cooling_on_outwalls': noSlowDownForCoolingOnOutwalls,
        'activate_air_filtration': activateAirFiltration,
        'complete_print_exhaust_fan_speed': completePrintExhaustFanSpeed,
        'during_print_exhaust_fan_speed': duringPrintExhaustFanSpeed,
        'filament_enable_overhang_speed': filamentEnableOverhangSpeed,
        'override_process_overhang_speed': overrideProcessOverhangSpeed,
        'filament_overhang_1_4_speed': filamentOverhang14Speed,
        'filament_overhang_2_4_speed': filamentOverhang24Speed,
        'filament_overhang_3_4_speed': filamentOverhang34Speed,
        'filament_overhang_4_4_speed': filamentOverhang44Speed,
        'filament_overhang_totally_speed': filamentOverhangTotallySpeed,
        'filament_bridge_speed': filamentBridgeSpeed,
        'cooling_perimeter_transition_distance':
            coolingPerimeterTransitionDistance,
      };

  Map<String, dynamic> toJson() => _toFilamentJson(toMap());

  factory FilamentFanParams.fromMap(Map<String, dynamic> map) {
    return FilamentFanParams(
      fanMaxSpeed: _parseStr(map['fan_max_speed']),
      fanMinSpeed: _parseStr(map['fan_min_speed']),
      fanCoolingLayerTime: _parseStr(map['fan_cooling_layer_time']),
      closeFanTheFirstXLayers: _parseStr(map['close_fan_the_first_x_layers']),
      fullFanSpeedLayer: _parseStr(map['full_fan_speed_layer']),
      overhangFanSpeed: _parseStr(map['overhang_fan_speed']),
      overhangFanThreshold: _parseStr(map['overhang_fan_threshold']),
      additionalCoolingFanSpeed: _parseStr(map['additional_cooling_fan_speed']),
      closeAdditionalFanFirstXLayers:
          _parseStr(map['close_additional_fan_first_x_layers']),
      additionalFanFullSpeedLayer:
          _parseStr(map['additional_fan_full_speed_layer']),
      reduceFanStopStartFreq: _parseStr(map['reduce_fan_stop_start_freq']),
      slowDownForLayerCooling: _parseStr(map['slow_down_for_layer_cooling']),
      coolingSlowdownLogic: _parseStr(map['cooling_slowdown_logic']),
      slowDownLayerTime: _parseStr(map['slow_down_layer_time']),
      slowDownMinSpeed: _parseStr(map['slow_down_min_speed']),
      noSlowDownForCoolingOnOutwalls:
          _parseStr(map['no_slow_down_for_cooling_on_outwalls']),
      activateAirFiltration: _parseStr(map['activate_air_filtration']),
      completePrintExhaustFanSpeed:
          _parseStr(map['complete_print_exhaust_fan_speed']),
      duringPrintExhaustFanSpeed:
          _parseStr(map['during_print_exhaust_fan_speed']),
      filamentEnableOverhangSpeed:
          _parseStr(map['filament_enable_overhang_speed']),
      overrideProcessOverhangSpeed:
          _parseStr(map['override_process_overhang_speed']),
      filamentOverhang14Speed: _parseStr(map['filament_overhang_1_4_speed']),
      filamentOverhang24Speed: _parseStr(map['filament_overhang_2_4_speed']),
      filamentOverhang34Speed: _parseStr(map['filament_overhang_3_4_speed']),
      filamentOverhang44Speed: _parseStr(map['filament_overhang_4_4_speed']),
      filamentOverhangTotallySpeed:
          _parseStr(map['filament_overhang_totally_speed']),
      filamentBridgeSpeed: _parseStr(map['filament_bridge_speed']),
      coolingPerimeterTransitionDistance:
          _parseStr(map['cooling_perimeter_transition_distance']),
    );
  }
}

// ===== D. 回抽参数 =====

/// 回抽参数：回抽长度、速度、Z跳高、斜拼接缝、剪料/换料回抽等（共 19 字段）。
///
/// 对照 fdm_filament_common.json 中以下 key：
/// filament_retraction_length, filament_retraction_speed,
/// filament_deretraction_speed, filament_retract_before_wipe,
/// filament_retract_restart_extra, filament_retract_when_changing_layer,
/// filament_retraction_minimum_travel, filament_wipe,
/// filament_wipe_distance, filament_z_hop, filament_z_hop_types,
/// filament_retract_length_nc, filament_long_retractions_when_cut,
/// filament_retraction_distances_when_cut, filament_long_retractions_when_ec,
/// filament_retraction_distances_when_ec, filament_scarf_seam_type,
/// filament_scarf_gap, filament_scarf_height, filament_scarf_length,
/// long_retractions_when_ec, retraction_distances_when_ec
class FilamentRetractionParams {
  // 基础回抽
  final String filamentRetractionLength; // filament_retraction_length
  final String filamentRetractionSpeed; // filament_retraction_speed
  final String filamentDeretractionSpeed; // filament_deretraction_speed
  final String filamentRetractBeforeWipe; // filament_retract_before_wipe
  final String filamentRetractRestartExtra; // filament_retract_restart_extra
  final String
      filamentRetractWhenChangingLayer; // filament_retract_when_changing_layer
  final String
      filamentRetractionMinimumTravel; // filament_retraction_minimum_travel
  final String filamentWipe; // filament_wipe
  final String filamentWipeDistance; // filament_wipe_distance
  final String filamentZHop; // filament_z_hop
  final String filamentZHopTypes; // filament_z_hop_types

  // 剪料/换料（AMS）回抽
  final String filamentRetractLengthNc; // filament_retract_length_nc
  final String
      filamentLongRetractionsWhenCut; // filament_long_retractions_when_cut
  final String
      filamentRetractionDistancesWhenCut; // filament_retraction_distances_when_cut
  final String
      filamentLongRetractionsWhenEc; // filament_long_retractions_when_ec
  final String
      filamentRetractionDistancesWhenEc; // filament_retraction_distances_when_ec

  // 外部回抽（独立字段，无 filament_ 前缀）
  final String longRetractionsWhenEc; // long_retractions_when_ec
  final String retractionDistancesWhenEc; // retraction_distances_when_ec

  // 斜拼接缝
  final String filamentScarfSeamType; // filament_scarf_seam_type
  final String filamentScarfGap; // filament_scarf_gap
  final String filamentScarfHeight; // filament_scarf_height
  final String filamentScarfLength; // filament_scarf_length

  const FilamentRetractionParams({
    this.filamentRetractionLength = '0.8',
    this.filamentRetractionSpeed = '30',
    this.filamentDeretractionSpeed = '30',
    this.filamentRetractBeforeWipe = '70%',
    this.filamentRetractRestartExtra = '0',
    this.filamentRetractWhenChangingLayer = '1',
    this.filamentRetractionMinimumTravel = '0.6',
    this.filamentWipe = '0',
    this.filamentWipeDistance = '0',
    this.filamentZHop = '0',
    this.filamentZHopTypes = 'Auto Lift',
    this.filamentRetractLengthNc = '0',
    this.filamentLongRetractionsWhenCut = '0',
    this.filamentRetractionDistancesWhenCut = '0',
    this.filamentLongRetractionsWhenEc = '0',
    this.filamentRetractionDistancesWhenEc = '0',
    this.longRetractionsWhenEc = '0',
    this.retractionDistancesWhenEc = '0',
    this.filamentScarfSeamType = 'none',
    this.filamentScarfGap = '0',
    this.filamentScarfHeight = '0',
    this.filamentScarfLength = '0',
  });

  Map<String, String> toMap() => {
        'filament_retraction_length': filamentRetractionLength,
        'filament_retraction_speed': filamentRetractionSpeed,
        'filament_deretraction_speed': filamentDeretractionSpeed,
        'filament_retract_before_wipe': filamentRetractBeforeWipe,
        'filament_retract_restart_extra': filamentRetractRestartExtra,
        'filament_retract_when_changing_layer':
            filamentRetractWhenChangingLayer,
        'filament_retraction_minimum_travel': filamentRetractionMinimumTravel,
        'filament_wipe': filamentWipe,
        'filament_wipe_distance': filamentWipeDistance,
        'filament_z_hop': filamentZHop,
        'filament_z_hop_types': filamentZHopTypes,
        'filament_retract_length_nc': filamentRetractLengthNc,
        'filament_long_retractions_when_cut': filamentLongRetractionsWhenCut,
        'filament_retraction_distances_when_cut':
            filamentRetractionDistancesWhenCut,
        'filament_long_retractions_when_ec': filamentLongRetractionsWhenEc,
        'filament_retraction_distances_when_ec':
            filamentRetractionDistancesWhenEc,
        'long_retractions_when_ec': longRetractionsWhenEc,
        'retraction_distances_when_ec': retractionDistancesWhenEc,
        'filament_scarf_seam_type': filamentScarfSeamType,
        'filament_scarf_gap': filamentScarfGap,
        'filament_scarf_height': filamentScarfHeight,
        'filament_scarf_length': filamentScarfLength,
      };

  Map<String, dynamic> toJson() => _toFilamentJson(toMap());

  factory FilamentRetractionParams.fromMap(Map<String, dynamic> map) {
    return FilamentRetractionParams(
      filamentRetractionLength: _parseStr(map['filament_retraction_length']),
      filamentRetractionSpeed: _parseStr(map['filament_retraction_speed']),
      filamentDeretractionSpeed: _parseStr(map['filament_deretraction_speed']),
      filamentRetractBeforeWipe: _parseStr(map['filament_retract_before_wipe']),
      filamentRetractRestartExtra:
          _parseStr(map['filament_retract_restart_extra']),
      filamentRetractWhenChangingLayer:
          _parseStr(map['filament_retract_when_changing_layer']),
      filamentRetractionMinimumTravel:
          _parseStr(map['filament_retraction_minimum_travel']),
      filamentWipe: _parseStr(map['filament_wipe']),
      filamentWipeDistance: _parseStr(map['filament_wipe_distance']),
      filamentZHop: _parseStr(map['filament_z_hop']),
      filamentZHopTypes: _parseStr(map['filament_z_hop_types']),
      filamentRetractLengthNc: _parseStr(map['filament_retract_length_nc']),
      filamentLongRetractionsWhenCut:
          _parseStr(map['filament_long_retractions_when_cut']),
      filamentRetractionDistancesWhenCut:
          _parseStr(map['filament_retraction_distances_when_cut']),
      filamentLongRetractionsWhenEc:
          _parseStr(map['filament_long_retractions_when_ec']),
      filamentRetractionDistancesWhenEc:
          _parseStr(map['filament_retraction_distances_when_ec']),
      longRetractionsWhenEc: _parseStr(map['long_retractions_when_ec']),
      retractionDistancesWhenEc: _parseStr(map['retraction_distances_when_ec']),
      filamentScarfSeamType: _parseStr(map['filament_scarf_seam_type']),
      filamentScarfGap: _parseStr(map['filament_scarf_gap']),
      filamentScarfHeight: _parseStr(map['filament_scarf_height']),
      filamentScarfLength: _parseStr(map['filament_scarf_length']),
    );
  }
}

// ===== E. 烘干参数 =====

/// 烘干参数：AMS 烘干、腔体烘干、软化温度等（共 8 字段）。
///
/// 对照 fdm_filament_common.json 中以下 key（全部带 filament_dev_ 前缀）：
/// filament_dev_ams_drying_ams_limitations,
/// filament_dev_ams_drying_heat_distortion_temperature,
/// filament_dev_ams_drying_temperature, filament_dev_ams_drying_time,
/// filament_dev_chamber_drying_bed_temperature,
/// filament_dev_chamber_drying_time,
/// filament_dev_drying_cooling_temperature,
/// filament_dev_drying_softening_temperature
class FilamentDryingParams {
  final String
      filamentDevAmsDryingAmsLimitations; // filament_dev_ams_drying_ams_limitations
  final String
      filamentDevAmsDryingHeatDistortionTemperature; // filament_dev_ams_drying_heat_distortion_temperature
  final String
      filamentDevAmsDryingTemperature; // filament_dev_ams_drying_temperature
  final String filamentDevAmsDryingTime; // filament_dev_ams_drying_time
  final String
      filamentDevChamberDryingBedTemperature; // filament_dev_chamber_drying_bed_temperature
  final String filamentDevChamberDryingTime; // filament_dev_chamber_drying_time
  final String
      filamentDevDryingCoolingTemperature; // filament_dev_drying_cooling_temperature
  final String
      filamentDevDryingSofteningTemperature; // filament_dev_drying_softening_temperature

  const FilamentDryingParams({
    this.filamentDevAmsDryingAmsLimitations = '0',
    this.filamentDevAmsDryingHeatDistortionTemperature = '55',
    this.filamentDevAmsDryingTemperature = '50',
    this.filamentDevAmsDryingTime = '8',
    this.filamentDevChamberDryingBedTemperature = '60',
    this.filamentDevChamberDryingTime = '8',
    this.filamentDevDryingCoolingTemperature = '40',
    this.filamentDevDryingSofteningTemperature = '50',
  });

  Map<String, String> toMap() => {
        'filament_dev_ams_drying_ams_limitations':
            filamentDevAmsDryingAmsLimitations,
        'filament_dev_ams_drying_heat_distortion_temperature':
            filamentDevAmsDryingHeatDistortionTemperature,
        'filament_dev_ams_drying_temperature': filamentDevAmsDryingTemperature,
        'filament_dev_ams_drying_time': filamentDevAmsDryingTime,
        'filament_dev_chamber_drying_bed_temperature':
            filamentDevChamberDryingBedTemperature,
        'filament_dev_chamber_drying_time': filamentDevChamberDryingTime,
        'filament_dev_drying_cooling_temperature':
            filamentDevDryingCoolingTemperature,
        'filament_dev_drying_softening_temperature':
            filamentDevDryingSofteningTemperature,
      };

  Map<String, dynamic> toJson() => _toFilamentJson(toMap());

  factory FilamentDryingParams.fromMap(Map<String, dynamic> map) {
    return FilamentDryingParams(
      filamentDevAmsDryingAmsLimitations:
          _parseStr(map['filament_dev_ams_drying_ams_limitations']),
      filamentDevAmsDryingHeatDistortionTemperature:
          _parseStr(map['filament_dev_ams_drying_heat_distortion_temperature']),
      filamentDevAmsDryingTemperature:
          _parseStr(map['filament_dev_ams_drying_temperature']),
      filamentDevAmsDryingTime: _parseStr(map['filament_dev_ams_drying_time']),
      filamentDevChamberDryingBedTemperature:
          _parseStr(map['filament_dev_chamber_drying_bed_temperature']),
      filamentDevChamberDryingTime:
          _parseStr(map['filament_dev_chamber_drying_time']),
      filamentDevDryingCoolingTemperature:
          _parseStr(map['filament_dev_drying_cooling_temperature']),
      filamentDevDryingSofteningTemperature:
          _parseStr(map['filament_dev_drying_softening_temperature']),
    );
  }
}

// ===== F. 耗材属性 =====

/// 耗材属性：材料类型、密度、成本、安全认证、补偿系数、G-code 等（共 35 字段）。
///
/// 对照 fdm_filament_common.json 中以下 key：
/// filament_type, filament_vendor, filament_density, filament_cost,
/// filament_diameter, filament_shrink, filament_soluble,
/// filament_is_support, filament_printable, required_nozzle_HRC,
/// filament_contact_safe, filament_emission_safe, filament_ingredients_safe,
/// filament_extruder_compatibility, filament_extruder_variant,
/// filament_metal_stickiness, filament_start_gcode, filament_end_gcode,
/// circle_compensation_speed, counter_coef_1, counter_coef_2, counter_coef_3,
/// counter_limit_max, counter_limit_min, diameter_limit, hole_coef_1,
/// hole_coef_2, hole_coef_3, hole_limit_max, hole_limit_min, impact_strength_z
class FilamentPropertyParams {
  // 基础属性
  final String filamentType; // filament_type
  final String filamentVendor; // filament_vendor
  final String filamentDensity; // filament_density
  final String filamentCost; // filament_cost
  final String filamentDiameter; // filament_diameter
  final String filamentShrink; // filament_shrink
  final String filamentSoluble; // filament_soluble
  final String filamentIsSupport; // filament_is_support
  final String filamentPrintable; // filament_printable
  final String requiredNozzleHRC; // required_nozzle_HRC

  // 安全/兼容性
  final String filamentContactSafe; // filament_contact_safe
  final String filamentEmissionSafe; // filament_emission_safe
  final String filamentIngredientsSafe; // filament_ingredients_safe
  final String filamentExtruderCompatibility; // filament_extruder_compatibility
  final String filamentExtruderVariant; // filament_extruder_variant
  final String filamentMetalStickiness; // filament_metal_stickiness

  // G-code
  final String filamentStartGcode; // filament_start_gcode
  final String filamentEndGcode; // filament_end_gcode

  // 圆/孔补偿
  final String circleCompensationSpeed; // circle_compensation_speed
  final String counterCoef1; // counter_coef_1
  final String counterCoef2; // counter_coef_2
  final String counterCoef3; // counter_coef_3
  final String counterLimitMax; // counter_limit_max
  final String counterLimitMin; // counter_limit_min
  final String diameterLimit; // diameter_limit
  final String holeCoef1; // hole_coef_1
  final String holeCoef2; // hole_coef_2
  final String holeCoef3; // hole_coef_3
  final String holeLimitMax; // hole_limit_max
  final String holeLimitMin; // hole_limit_min

  // Z 向冲击强度
  final String impactStrengthZ; // impact_strength_z

  const FilamentPropertyParams({
    this.filamentType = 'PLA',
    this.filamentVendor = '',
    this.filamentDensity = '1.24',
    this.filamentCost = '20',
    this.filamentDiameter = '1.75',
    this.filamentShrink = '0',
    this.filamentSoluble = '0',
    this.filamentIsSupport = '0',
    this.filamentPrintable = '1',
    this.requiredNozzleHRC = '3',
    this.filamentContactSafe = '0',
    this.filamentEmissionSafe = '0',
    this.filamentIngredientsSafe = '0',
    this.filamentExtruderCompatibility = '',
    this.filamentExtruderVariant = '',
    this.filamentMetalStickiness = '0',
    this.filamentStartGcode = '',
    this.filamentEndGcode = '',
    this.circleCompensationSpeed = '0',
    this.counterCoef1 = '0',
    this.counterCoef2 = '0',
    this.counterCoef3 = '0',
    this.counterLimitMax = '0',
    this.counterLimitMin = '0',
    this.diameterLimit = '0',
    this.holeCoef1 = '0',
    this.holeCoef2 = '0',
    this.holeCoef3 = '0',
    this.holeLimitMax = '0',
    this.holeLimitMin = '0',
    this.impactStrengthZ = '0',
  });

  Map<String, String> toMap() => {
        'filament_type': filamentType,
        'filament_vendor': filamentVendor,
        'filament_density': filamentDensity,
        'filament_cost': filamentCost,
        'filament_diameter': filamentDiameter,
        'filament_shrink': filamentShrink,
        'filament_soluble': filamentSoluble,
        'filament_is_support': filamentIsSupport,
        'filament_printable': filamentPrintable,
        'required_nozzle_HRC': requiredNozzleHRC,
        'filament_contact_safe': filamentContactSafe,
        'filament_emission_safe': filamentEmissionSafe,
        'filament_ingredients_safe': filamentIngredientsSafe,
        'filament_extruder_compatibility': filamentExtruderCompatibility,
        'filament_extruder_variant': filamentExtruderVariant,
        'filament_metal_stickiness': filamentMetalStickiness,
        'filament_start_gcode': filamentStartGcode,
        'filament_end_gcode': filamentEndGcode,
        'circle_compensation_speed': circleCompensationSpeed,
        'counter_coef_1': counterCoef1,
        'counter_coef_2': counterCoef2,
        'counter_coef_3': counterCoef3,
        'counter_limit_max': counterLimitMax,
        'counter_limit_min': counterLimitMin,
        'diameter_limit': diameterLimit,
        'hole_coef_1': holeCoef1,
        'hole_coef_2': holeCoef2,
        'hole_coef_3': holeCoef3,
        'hole_limit_max': holeLimitMax,
        'hole_limit_min': holeLimitMin,
        'impact_strength_z': impactStrengthZ,
      };

  Map<String, dynamic> toJson() => _toFilamentJson(toMap());

  factory FilamentPropertyParams.fromMap(Map<String, dynamic> map) {
    return FilamentPropertyParams(
      filamentType: _parseStr(map['filament_type']),
      filamentVendor: _parseStr(map['filament_vendor']),
      filamentDensity: _parseStr(map['filament_density']),
      filamentCost: _parseStr(map['filament_cost']),
      filamentDiameter: _parseStr(map['filament_diameter']),
      filamentShrink: _parseStr(map['filament_shrink']),
      filamentSoluble: _parseStr(map['filament_soluble']),
      filamentIsSupport: _parseStr(map['filament_is_support']),
      filamentPrintable: _parseStr(map['filament_printable']),
      requiredNozzleHRC: _parseStr(map['required_nozzle_HRC']),
      filamentContactSafe: _parseStr(map['filament_contact_safe']),
      filamentEmissionSafe: _parseStr(map['filament_emission_safe']),
      filamentIngredientsSafe: _parseStr(map['filament_ingredients_safe']),
      filamentExtruderCompatibility:
          _parseStr(map['filament_extruder_compatibility']),
      filamentExtruderVariant: _parseStr(map['filament_extruder_variant']),
      filamentMetalStickiness: _parseStr(map['filament_metal_stickiness']),
      filamentStartGcode: _parseStr(map['filament_start_gcode']),
      filamentEndGcode: _parseStr(map['filament_end_gcode']),
      circleCompensationSpeed: _parseStr(map['circle_compensation_speed']),
      counterCoef1: _parseStr(map['counter_coef_1']),
      counterCoef2: _parseStr(map['counter_coef_2']),
      counterCoef3: _parseStr(map['counter_coef_3']),
      counterLimitMax: _parseStr(map['counter_limit_max']),
      counterLimitMin: _parseStr(map['counter_limit_min']),
      diameterLimit: _parseStr(map['diameter_limit']),
      holeCoef1: _parseStr(map['hole_coef_1']),
      holeCoef2: _parseStr(map['hole_coef_2']),
      holeCoef3: _parseStr(map['hole_coef_3']),
      holeLimitMax: _parseStr(map['hole_limit_max']),
      holeLimitMin: _parseStr(map['hole_limit_min']),
      impactStrengthZ: _parseStr(map['impact_strength_z']),
    );
  }
}
