import '../../data/models/filament_preset.dart';
import '../../data/models/print_parameter.dart';
import '../../data/models/printer_preset.dart';

/// 内置打印参数预设。
///
/// 工艺预设与耗材丝预设已改为从拓竹官方系统预设加载
/// （见 [BambuSystemPresetLoader]），此处仅保留打印机预设。
/// 打印机预设保留应用自有定义，覆盖拓竹官方 JSON 未提供的型号
/// （H2S/H2C/P2S/X2D/A2L 等）。
class BuiltinPresets {
  BuiltinPresets._();

  /// 获取所有内置工艺预设。
  ///
  /// 已迁移至拓竹官方系统预设，此处返回空列表。
  /// 系统预设由 [ParameterPresetNotifier] 通过
  /// [BambuSystemPresetLoader] 异步加载。
  static List<PrintParameterPreset> getAll() => [];

  // ===== 耗材丝内置预设 =====

  /// 获取所有内置耗材丝预设。
  ///
  /// 已迁移至拓竹官方系统预设，此处返回空列表。
  /// 系统预设由 [FilamentPresetNotifier] 通过
  /// [BambuSystemPresetLoader] 异步加载。
  static List<FilamentPreset> getAllFilaments() => [];

  // ===== 打印机内置预设 =====

  /// 获取所有内置打印机预设。
  static List<PrinterPreset> getAllPrinters() {
    return [
      // 单喷头系列（256×256）
      _printerX1C040,
      _printerX1040,
      _printerX1E040,
      _printerP1P040,
      _printerP1S040,
      _printerA1040,
      _printerA1Mini040,
      // 双喷头系列（350×320）
      _printerH2D040,
      _printerH2DPro040,
      _printerH2S040,
      _printerH2C040,
      _printerP2S040,
      _printerX2D040,
      _printerA2L040,
    ];
  }

  /// Bambu Lab X1 Carbon 0.4 喷嘴
  static final PrinterPreset _printerX1C040 = PrinterPreset(
    id: 'builtin_printer_x1c_040',
    name: 'Bambu Lab X1 Carbon 0.4 nozzle',
    printerModel: 'Bambu Lab X1 Carbon',
    nozzleDiameter: '0.4',
    printerStructure: 'corexy',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '1.8',
      nozzleType: 'hardened_steel',
      nozzleVolume: '52',
      extruderMaxNozzleCount: '1',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,256x0,256x256,0x256',
      printableHeight: '256',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '128x128',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '20000',
      maxAccelY: '20000',
      maxAccelZ: '500',
      maxAccelE: '5000',
      maxSpeedX: '500',
      maxSpeedY: '500',
      maxSpeedZ: '12',
      maxSpeedE: '60',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '1',
      scanFirstLayer: '1',
      silentMode: '1',
      supportAirFiltration: '1',
      supportChamberTempControl: '1',
    ),
  );

  /// Bambu Lab P1S 0.4 喷嘴
  static final PrinterPreset _printerP1S040 = PrinterPreset(
    id: 'builtin_printer_p1s_040',
    name: 'Bambu Lab P1S 0.4 nozzle',
    printerModel: 'Bambu Lab P1S',
    nozzleDiameter: '0.4',
    printerStructure: 'corexy',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '1.8',
      nozzleType: 'hardened_steel',
      nozzleVolume: '52',
      extruderMaxNozzleCount: '1',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,256x0,256x256,0x256',
      printableHeight: '256',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '128x128',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '10000',
      maxAccelY: '10000',
      maxAccelZ: '200',
      maxAccelE: '5000',
      maxSpeedX: '500',
      maxSpeedY: '500',
      maxSpeedZ: '12',
      maxSpeedE: '60',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '1',
      scanFirstLayer: '0',
      silentMode: '1',
      supportAirFiltration: '0',
      supportChamberTempControl: '0',
    ),
  );

  /// Bambu Lab A1 0.4 喷嘴
  static final PrinterPreset _printerA1040 = PrinterPreset(
    id: 'builtin_printer_a1_040',
    name: 'Bambu Lab A1 0.4 nozzle',
    printerModel: 'Bambu Lab A1',
    nozzleDiameter: '0.4',
    printerStructure: 'i3',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '1.8',
      nozzleType: 'stainless_steel',
      nozzleVolume: '52',
      extruderMaxNozzleCount: '1',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,256x0,256x256,0x256',
      printableHeight: '256',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '128x128',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '5000',
      maxAccelY: '5000',
      maxAccelZ: '200',
      maxAccelE: '5000',
      maxSpeedX: '500',
      maxSpeedY: '500',
      maxSpeedZ: '12',
      maxSpeedE: '60',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '0',
      scanFirstLayer: '0',
      silentMode: '1',
      supportAirFiltration: '0',
      supportChamberTempControl: '0',
    ),
  );

  /// Bambu Lab X1 0.4 喷嘴
  static final PrinterPreset _printerX1040 = PrinterPreset(
    id: 'builtin_printer_x1_040',
    name: 'Bambu Lab X1 0.4 nozzle',
    printerModel: 'Bambu Lab X1',
    nozzleDiameter: '0.4',
    printerStructure: 'corexy',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '1.8',
      nozzleType: 'stainless_steel',
      nozzleVolume: '92',
      extruderMaxNozzleCount: '1',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,256x0,256x256,0x256',
      printableHeight: '256',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '128x128',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '10000',
      maxAccelY: '10000',
      maxAccelZ: '200',
      maxAccelE: '5000',
      maxSpeedX: '500',
      maxSpeedY: '500',
      maxSpeedZ: '12',
      maxSpeedE: '60',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '1',
      scanFirstLayer: '0',
      silentMode: '1',
      supportAirFiltration: '1',
      supportChamberTempControl: '1',
    ),
  );

  /// Bambu Lab X1E 0.4 喷嘴
  static final PrinterPreset _printerX1E040 = PrinterPreset(
    id: 'builtin_printer_x1e_040',
    name: 'Bambu Lab X1E 0.4 nozzle',
    printerModel: 'Bambu Lab X1E',
    nozzleDiameter: '0.4',
    printerStructure: 'corexy',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '1.8',
      nozzleType: 'hardened_steel',
      nozzleVolume: '52',
      extruderMaxNozzleCount: '1',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,256x0,256x256,0x256',
      printableHeight: '256',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '128x128',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '20000',
      maxAccelY: '20000',
      maxAccelZ: '500',
      maxAccelE: '5000',
      maxSpeedX: '500',
      maxSpeedY: '500',
      maxSpeedZ: '12',
      maxSpeedE: '60',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '1',
      scanFirstLayer: '1',
      silentMode: '1',
      supportAirFiltration: '1',
      supportChamberTempControl: '1',
    ),
  );

  /// Bambu Lab P1P 0.4 喷嘴
  static final PrinterPreset _printerP1P040 = PrinterPreset(
    id: 'builtin_printer_p1p_040',
    name: 'Bambu Lab P1P 0.4 nozzle',
    printerModel: 'Bambu Lab P1P',
    nozzleDiameter: '0.4',
    printerStructure: 'corexy',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '1.8',
      nozzleType: 'stainless_steel',
      nozzleVolume: '52',
      extruderMaxNozzleCount: '1',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,256x0,256x256,0x256',
      printableHeight: '256',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '128x128',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '10000',
      maxAccelY: '10000',
      maxAccelZ: '200',
      maxAccelE: '5000',
      maxSpeedX: '500',
      maxSpeedY: '500',
      maxSpeedZ: '12',
      maxSpeedE: '60',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '0',
      scanFirstLayer: '0',
      silentMode: '0',
      supportAirFiltration: '0',
      supportChamberTempControl: '0',
    ),
  );

  /// Bambu Lab A1 mini 0.4 喷嘴
  static final PrinterPreset _printerA1Mini040 = PrinterPreset(
    id: 'builtin_printer_a1_mini_040',
    name: 'Bambu Lab A1 mini 0.4 nozzle',
    printerModel: 'Bambu Lab A1 mini',
    nozzleDiameter: '0.4',
    printerStructure: 'i3',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '1.8',
      nozzleType: 'stainless_steel',
      nozzleVolume: '92',
      extruderMaxNozzleCount: '1',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,180x0,180x180,0x180',
      printableHeight: '180',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '90x90',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '5000',
      maxAccelY: '5000',
      maxAccelZ: '200',
      maxAccelE: '5000',
      maxSpeedX: '500',
      maxSpeedY: '500',
      maxSpeedZ: '12',
      maxSpeedE: '60',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '0',
      scanFirstLayer: '0',
      silentMode: '1',
      supportAirFiltration: '0',
      supportChamberTempControl: '0',
    ),
  );

  /// Bambu Lab H2D 0.4 喷嘴
  ///
  /// 规格（来源：拓竹 Bambu Studio 官方 JSON，setting_id: GM033）：
  /// - 结构：corexy（继承 fdm_bbl_3dp_002_common）
  /// - 双挤出机 Direct Drive，5 个喷嘴变体
  /// - 打印面积 350x320，打印高度 325mm
  /// - 加速度：X/Y=20000, Z=500
  /// - 速度：X/Y=1000, Z=30
  /// - nozzle_type=hardened_steel, nozzle_volume=130~148
  /// - enable_long_retraction_when_cut=2
  /// - support_chamber_temp_control=1, support_cooling_filter=1
  /// - fan_direction=left, enable_pre_heating=1
  static final PrinterPreset _printerH2D040 = PrinterPreset(
    id: 'builtin_printer_h2d_040',
    name: 'Bambu Lab H2D 0.4 nozzle',
    printerModel: 'Bambu Lab H2D',
    nozzleDiameter: '0.4',
    printerStructure: 'corexy',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '2.0',
      nozzleType: 'hardened_steel',
      nozzleVolume: '130',
      extruderMaxNozzleCount: '2',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,350x0,350x320,0x320',
      printableHeight: '325',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '175x160',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '20000',
      maxAccelY: '20000',
      maxAccelZ: '500',
      maxAccelE: '5000',
      maxSpeedX: '1000',
      maxSpeedY: '1000',
      maxSpeedZ: '30',
      maxSpeedE: '30',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '1',
      scanFirstLayer: '1',
      silentMode: '1',
      supportAirFiltration: '1',
      supportChamberTempControl: '1',
      supportCoolingFilter: '1',
      enableLongRetractionWhenCut: '2',
      enablePreHeating: '1',
      fanDirection: 'left',
    ),
  );

  /// Bambu Lab H2D Pro 0.4 喷嘴
  ///
  /// 规格（来源：拓竹 Bambu Studio 官方 JSON，setting_id: GM051）：
  /// - 与 H2D 相同的硬件规格（结构/喷嘴/打印面积/速度/加速度）
  /// - 区别：默认工艺/耗材预设带 H2DP 后缀
  static final PrinterPreset _printerH2DPro040 = PrinterPreset(
    id: 'builtin_printer_h2d_pro_040',
    name: 'Bambu Lab H2D Pro 0.4 nozzle',
    printerModel: 'Bambu Lab H2D Pro',
    nozzleDiameter: '0.4',
    printerStructure: 'corexy',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '2.0',
      nozzleType: 'hardened_steel',
      nozzleVolume: '130',
      extruderMaxNozzleCount: '2',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,350x0,350x320,0x320',
      printableHeight: '325',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '175x160',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '20000',
      maxAccelY: '20000',
      maxAccelZ: '500',
      maxAccelE: '5000',
      maxSpeedX: '1000',
      maxSpeedY: '1000',
      maxSpeedZ: '30',
      maxSpeedE: '30',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '1',
      scanFirstLayer: '1',
      silentMode: '1',
      supportAirFiltration: '1',
      supportChamberTempControl: '1',
      supportCoolingFilter: '1',
      enableLongRetractionWhenCut: '2',
      enablePreHeating: '1',
      fanDirection: 'left',
    ),
  );

  /// Bambu Lab H2S 0.4 喷嘴
  ///
  /// 规格（来源：拓竹 Bambu Studio 官方 JSON，setting_id: GM037）：
  /// - 结构：i3（继承 fdm_bbl_3dp_001_common）
  /// - 单挤出机 Direct Drive，3 个喷嘴变体
  /// - 打印面积 340x320，打印高度 340mm
  /// - 加速度：X/Y=20000, Z=500
  /// - 速度：X/Y=1000, Z=30
  /// - nozzle_type=hardened_steel, nozzle_volume=32
  /// - support_chamber_temp_control=1, support_cooling_filter=1
  /// - fan_direction=left
  static final PrinterPreset _printerH2S040 = PrinterPreset(
    id: 'builtin_printer_h2s_040',
    name: 'Bambu Lab H2S 0.4 nozzle',
    printerModel: 'Bambu Lab H2S',
    nozzleDiameter: '0.4',
    printerStructure: 'i3',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '2.0',
      nozzleType: 'hardened_steel',
      nozzleVolume: '32',
      extruderMaxNozzleCount: '1',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,340x0,340x320,0x320',
      printableHeight: '340',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '170x160',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '20000',
      maxAccelY: '20000',
      maxAccelZ: '500',
      maxAccelE: '5000',
      maxSpeedX: '1000',
      maxSpeedY: '1000',
      maxSpeedZ: '30',
      maxSpeedE: '30',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '1',
      scanFirstLayer: '1',
      silentMode: '1',
      supportAirFiltration: '1',
      supportChamberTempControl: '1',
      supportCoolingFilter: '1',
      supportObjectSkipFlush: '1',
      fanDirection: 'left',
    ),
  );

  /// Bambu Lab H2C 0.4 喷嘴
  ///
  /// 规格（来源：拓竹 Bambu Studio 官方 JSON，setting_id: GM041）：
  /// - 结构：corexy（继承 fdm_bbl_3dp_002_common）
  /// - 双挤出机 Direct Drive，5 个喷嘴变体（3+2）
  /// - 打印面积 330x320（继承 common 的 printable_height=325）
  /// - 加速度：X/Y=20000, Z=500
  /// - 速度：X/Y=1000, Z=30
  /// - nozzle_type=hardened_steel, nozzle_volume=130~148
  /// - enable_long_retraction_when_cut=2, master_extruder_id=2
  /// - support_chamber_temp_control=1, support_cooling_filter=1
  /// - 不支持 TPU/PPS-CF/PPA-CF（unprintable_filament_types）
  static final PrinterPreset _printerH2C040 = PrinterPreset(
    id: 'builtin_printer_h2c_040',
    name: 'Bambu Lab H2C 0.4 nozzle',
    printerModel: 'Bambu Lab H2C',
    nozzleDiameter: '0.4',
    printerStructure: 'corexy',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '2.0',
      nozzleType: 'hardened_steel',
      nozzleVolume: '130',
      extruderMaxNozzleCount: '2',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,330x0,330x320,0x320',
      printableHeight: '325',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '165x160',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '20000',
      maxAccelY: '20000',
      maxAccelZ: '500',
      maxAccelE: '5000',
      maxSpeedX: '1000',
      maxSpeedY: '1000',
      maxSpeedZ: '30',
      maxSpeedE: '50',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '1',
      scanFirstLayer: '1',
      silentMode: '1',
      supportAirFiltration: '1',
      supportChamberTempControl: '1',
      supportCoolingFilter: '1',
      supportObjectSkipFlush: '0',
      enableLongRetractionWhenCut: '2',
      fanDirection: 'left',
    ),
  );

  /// Bambu Lab P2S 0.4 喷嘴
  ///
  /// 规格（来源：拓竹 Bambu Studio 官方 JSON，setting_id: GM049）：
  /// - 结构：i3（继承 fdm_bbl_3dp_001_common，printable_area 继承 256x256）
  /// - 单挤出机 Direct Drive，3 个喷嘴变体
  /// - 打印面积 256x256，打印高度 256mm
  /// - 加速度：X/Y=20000, Z=500
  /// - 速度：X/Y=600, Z=20
  /// - nozzle_type=hardened_steel, nozzle_volume=110, nozzle_height=4.2
  /// - support_object_skip_flush=1
  /// - fan_direction=right
  /// - 向上兼容：A1/H2S/H2D/H2D Pro/H2C/X2D/A2L
  static final PrinterPreset _printerP2S040 = PrinterPreset(
    id: 'builtin_printer_p2s_040',
    name: 'Bambu Lab P2S 0.4 nozzle',
    printerModel: 'Bambu Lab P2S',
    nozzleDiameter: '0.4',
    printerStructure: 'i3',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '4.2',
      nozzleType: 'hardened_steel',
      nozzleVolume: '110',
      extruderMaxNozzleCount: '1',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,256x0,256x256,0x256',
      printableHeight: '256',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '128x128',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '20000',
      maxAccelY: '20000',
      maxAccelZ: '500',
      maxAccelE: '5000',
      maxSpeedX: '600',
      maxSpeedY: '600',
      maxSpeedZ: '20',
      maxSpeedE: '30',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '1',
      scanFirstLayer: '1',
      silentMode: '1',
      supportAirFiltration: '1',
      supportChamberTempControl: '0',
      supportObjectSkipFlush: '1',
      fanDirection: 'right',
    ),
  );

  /// Bambu Lab X2D 0.4 喷嘴
  ///
  /// 规格（来源：拓竹 Bambu Studio 官方 JSON，setting_id: GM045）：
  /// - 结构：corexy（继承 fdm_bbl_3dp_002_common）
  /// - 双挤出机：Direct Drive（挤出机1）+ Bowden（挤出机2）
  /// - 6 个喷嘴变体（3 个 DD + 3 个 Bowden）
  /// - 打印面积 256x256，打印高度 261mm
  /// - 加速度：X/Y=20000, Z=500
  /// - 速度：X/Y=1000
  /// - enable_long_retraction_when_cut=2（双喷头切换需要长回抽）
  /// - support_chamber_temp_control=1
  /// - 向上兼容：A1/P2S/H2S/H2D/H2D Pro/H2C/A2L
  static final PrinterPreset _printerX2D040 = PrinterPreset(
    id: 'builtin_printer_x2d_040',
    name: 'Bambu Lab X2D 0.4 nozzle',
    printerModel: 'Bambu Lab X2D',
    nozzleDiameter: '0.4',
    printerStructure: 'corexy',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '2.0',
      nozzleType: 'hardened_steel',
      nozzleVolume: '107',
      extruderMaxNozzleCount: '2',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,256x0,256x256,0x256',
      printableHeight: '261',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '128x128',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '20000',
      maxAccelY: '20000',
      maxAccelZ: '500',
      maxAccelE: '5000',
      maxSpeedX: '1000',
      maxSpeedY: '1000',
      maxSpeedZ: '30',
      maxSpeedE: '30',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '1',
      scanFirstLayer: '1',
      silentMode: '1',
      supportAirFiltration: '1',
      supportChamberTempControl: '1',
      enableLongRetractionWhenCut: '2',
    ),
  );

  /// Bambu Lab A2L 0.4 喷嘴
  ///
  /// 规格（来源：拓竹 Bambu Studio 官方 JSON，setting_id: GM056）：
  /// - 结构：i3（继承 fdm_bbl_3dp_001_common）
  /// - 单挤出机 Direct Drive
  /// - 打印面积 330x320，打印高度 325mm
  /// - 加速度：X=12000, Y=8000, Z=1500
  /// - 速度：X/Y=500
  /// - 喷嘴：stainless_steel，体积 92，高度 4.76
  /// - auxiliary_fan=0（无辅助风扇）
  /// - 向上兼容：H2S
  static final PrinterPreset _printerA2L040 = PrinterPreset(
    id: 'builtin_printer_a2l_040',
    name: 'Bambu Lab A2L 0.4 nozzle',
    printerModel: 'Bambu Lab A2L',
    nozzleDiameter: '0.4',
    printerStructure: 'i3',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    nozzle: const PrinterNozzleParams(
      nozzleDiameter: '0.4',
      nozzleHeight: '4.76',
      nozzleType: 'stainless_steel',
      nozzleVolume: '92',
      extruderMaxNozzleCount: '1',
    ),
    bed: const PrinterBedParams(
      printableArea: '0x0,330x0,330x320,0x320',
      printableHeight: '325',
      maxLayerHeight: '0.28',
      minLayerHeight: '0.08',
      bestObjectPos: '165x160',
    ),
    mechanical: const PrinterMechanicalParams(
      maxAccelX: '12000',
      maxAccelY: '8000',
      maxAccelZ: '1500',
      maxAccelE: '5000',
      maxSpeedX: '500',
      maxSpeedY: '500',
      maxSpeedZ: '30',
      maxSpeedE: '30',
      machineMaxPrintedMass: '2000',
    ),
    features: const PrinterFeatureParams(
      auxiliaryFan: '0',
      scanFirstLayer: '0',
      silentMode: '0',
      supportAirFiltration: '0',
      supportChamberTempControl: '0',
      supportFastPurgeMode: '1',
      supportObjectSkipFlush: '1',
    ),
  );
}
