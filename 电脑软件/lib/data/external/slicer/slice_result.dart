import 'filament_change_point.dart';

/// 切片结果数据类。G-code / 3MF 解析后产出的统一结构。
///
/// 包含切片软件算出的预计消耗信息：
/// - 每卷耗材的预计克数（多色任务有多条）
/// - 预计打印时长
/// - 换料次数（多色任务有）
/// - 层级挤出映射（精细模式实时计算用）
class SliceResult {
  /// 源文件路径（.gcode 或 .3mf）
  final String filePath;

  /// 任务名（文件名，不含扩展名）
  final String taskName;

  /// 每个挤出机/槽位的预计耗材克数。
  /// 单色任务只有 1 项；多色 AMS 任务可能有 4–16 项。
  /// 索引对应 G-code 的 T0/T1/T2... 工具号。
  final List<FilamentUsage> filaments;

  /// Confirmed tool-change sequence from the G-code. Loading multiple colors
  /// without actual tool changes leaves this list empty.
  final List<FilamentChangePoint> filamentChangePoints;

  /// 总预计克数（所有 filaments 之和）
  double get totalGrams => filaments.fold(0.0, (sum, f) => sum + f.grams);

  /// 总预计耗材长度（毫米）
  double get totalLengthMm => filaments.fold(0.0, (sum, f) => sum + f.lengthMm);

  /// 预计打印时长（秒）
  final int estimatedSeconds;

  /// 换料次数（多色任务的 toolchange 次数）
  final int toolChangeCount;

  /// 总层数（精细模式按层查表用）
  final int totalLayers;

  /// 切片软件名称（如 "BambuStudio"）
  final String slicerName;

  /// 切片软件版本（如 "1.9.0"）
  final String? slicerVersion;

  /// 切片时使用的工艺预设 ID。文件未提供时保持 null。
  final String? printSettingsId;

  /// 切片时使用的打印机预设 ID。文件未提供时保持 null。
  final String? printerSettingsId;

  /// 切片时使用的喷嘴直径。文件未提供时保持 null。
  final double? nozzleDiameter;

  /// 切片时使用的打印板类型。文件未提供时保持 null。
  final String? plateType;

  /// 稳定文件的完整内容 SHA-256。文件变化时保持 null。
  final String? artifactSha256;

  final int? artifactSize;
  final DateTime? artifactModifiedAt;

  /// 层级累计克数映射（精细模式用）。
  /// key = 层号（0-based），value = 到该层为止（含）累计消耗的克数。
  /// 由 GcodeParser 精细解析填充；粗略模式为 null。
  final Map<int, double>? layerCumulativeGrams;

  /// AMS 映射表。T→AMS 全局槽位映射。
  /// 来自 G-code 的 `; ams_mapping = [1,3,0,2]` 或 3MF 的 slice_info.config。
  /// - 非空时：amsMapping[toolIndex] = 该 T 对应的全局 AMS 槽位号（0-based）
  ///   例如 [1,3,0,2] 表示 T0→槽1, T1→槽3, T2→槽0, T3→槽2
  /// - 空数组 []：切片未指定 AMS 映射（单色或老版本切片软件），用 trayNow 兜底
  /// - null：未解析到该字段（非 BambuStudio 切片或格式不支持）
  final List<int>? amsMapping;

  /// 解析时间戳
  final DateTime parsedAt;

  SliceResult({
    required this.filePath,
    required this.taskName,
    required this.filaments,
    this.filamentChangePoints = const [],
    required this.estimatedSeconds,
    required this.toolChangeCount,
    required this.totalLayers,
    required this.slicerName,
    this.slicerVersion,
    this.printSettingsId,
    this.printerSettingsId,
    this.nozzleDiameter,
    this.plateType,
    this.artifactSha256,
    this.artifactSize,
    this.artifactModifiedAt,
    this.layerCumulativeGrams,
    this.amsMapping,
    DateTime? parsedAt,
  }) : parsedAt = parsedAt ?? DateTime.now();

  /// 格式化预计时长为 `1h 12m` 或 `45m 30s`
  String get formattedDuration {
    final h = estimatedSeconds ~/ 3600;
    final m = (estimatedSeconds % 3600) ~/ 60;
    final s = estimatedSeconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  @override
  String toString() =>
      'SliceResult($taskName: ${totalGrams.toStringAsFixed(1)}g, $formattedDuration, ${filaments.length} filament(s))';
}

/// 单个挤出机/槽位的耗材使用量。
class FilamentUsage {
  /// 工具号（0-based，对应 T0/T1/T2... 和 AMS 槽位）
  final int toolIndex;

  /// 预计消耗克数
  final double grams;

  /// 预计消耗长度（毫米）
  final double lengthMm;

  /// 耗材颜色 HEX（如 "#FFFF00"）。BambuStudio G-code 的
  /// `; filament_colour = #FFFF00;#008080` 字段提供（分号分隔多色）。
  final String? colorHex;

  /// 耗材材质（如 "PLA"、"PETG"）。BambuStudio G-code 的
  /// `; filament_type = PLA;PLA` 字段提供。
  final String? materialType;

  /// 耗材品牌/厂家（如 "Bambu Lab"）。BambuStudio G-code 的
  /// `; filament_vendor = "Bambu Lab";"Bambu Lab"` 字段提供。
  final String? vendor;

  /// 完整型号名（如 "Bambu PLA Silk @BBL X1C"）。
  /// 来自 `; filament_settings_id`，含品牌+系列+机器配置，
  /// 是最准确的型号标识（filament_type 只写粗类 "PLA"，不区分 Silk/Matte 等）。
  final String? settingsId;

  /// 耗材 SKU 编码（如 "GFA05"）。来自 `; filament_ids`，
  /// 拓竹官方耗材的产品编号，可用于精确查表。
  final String? sku;

  /// 该通道是否用于成品模型或支撑。二者可以同时为 true。
  final bool? usedForObject;
  final bool? usedForSupport;

  /// Bambu 多喷头/喷嘴元数据。
  final int? groupId;
  final double? nozzleDiameter;
  final String? volumeType;

  FilamentUsage({
    required this.toolIndex,
    required this.grams,
    required this.lengthMm,
    this.colorHex,
    this.materialType,
    this.vendor,
    this.settingsId,
    this.sku,
    this.usedForObject,
    this.usedForSupport,
    this.groupId,
    this.nozzleDiameter,
    this.volumeType,
  });

  @override
  String toString() =>
      'FilamentUsage(T$toolIndex: ${grams.toStringAsFixed(1)}g, ${lengthMm.toStringAsFixed(0)}mm)';
}
