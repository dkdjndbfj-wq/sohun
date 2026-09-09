/// 换色点信息。
///
/// 表示 G-code 中一处换料事件的位置和目标耗材信息。
/// 由 [GcodeParser.parseFilamentChangeLayers] 解析得到，
/// 供打印任务编排器在打印过程中触发换色提醒。
///
/// 字段说明：
/// - [layerNum]：换料发生的层号（0-based，与 G-code `;LAYER:N` 一致）
/// - [toolIndex]：换料后切换到的工具号（T0/T1/T2...）
/// - [colorHex]：目标耗材颜色 HEX（如 "#FF0000"），来自 G-code 头部 filament_colour
/// - [materialType]：目标耗材材质（如 "PLA"、"PETG"）
/// - [temperature]：目标耗材打印温度（℃），从 G-code 主体 M104/M109 指令解析
class FilamentChangePoint {
  /// 换料发生的层号（0-based）
  final int layerNum;

  /// 换料后切换到的工具号（T0/T1/T2...）
  final int toolIndex;

  /// Tool used before this change. Null means the source only emitted M600.
  final int? previousToolIndex;

  /// 目标耗材颜色 HEX（如 "#FF0000"）
  final String? colorHex;

  /// 目标耗材材质（如 "PLA"、"PETG"）
  final String? materialType;

  /// 目标耗材打印温度（℃）
  final int? temperature;

  const FilamentChangePoint({
    required this.layerNum,
    required this.toolIndex,
    this.previousToolIndex,
    this.colorHex,
    this.materialType,
    this.temperature,
  });

  @override
  String toString() =>
      'FilamentChangePoint(layer=$layerNum, T$toolIndex, color=$colorHex, '
      'material=$materialType, temp=$temperature℃)';

  /// 序列化为 JSON（用于缓存到 SharedPreferences）
  Map<String, dynamic> toJson() => {
        'layerNum': layerNum,
        'toolIndex': toolIndex,
        'previousToolIndex': previousToolIndex,
        'colorHex': colorHex,
        'materialType': materialType,
        'temperature': temperature,
      };

  /// 从 JSON 反序列化
  factory FilamentChangePoint.fromJson(Map<String, dynamic> json) {
    return FilamentChangePoint(
      layerNum: json['layerNum'] as int,
      toolIndex: json['toolIndex'] as int,
      previousToolIndex: json['previousToolIndex'] as int?,
      colorHex: json['colorHex'] as String?,
      materialType: json['materialType'] as String?,
      temperature: json['temperature'] as int?,
    );
  }
}
