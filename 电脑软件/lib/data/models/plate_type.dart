/// 打印板类型。
///
/// 对应 Bambu Studio 的 5 种打印板，每种打印板有独立的温度字段：
/// - [tempKey]：常规层温度字段名
/// - [initialLayerTempKey]：首层温度字段名
///
/// 选择打印板后，耗材 Tab 会高亮显示对应温度字段。
///
/// **图片资源**：[imageAsset] 对应 BambuStudio `resources/images/bed_*.png`，
/// 已下载到 `assets/images/plates/` 目录，UI 选择卡片会显示打印板实物图。
enum PlateType {
  /// 冷板（Cool Plate）
  coolPlate(
    '冷板',
    'cool_plate_temp',
    'cool_plate_temp_initial_layer',
    'assets/images/plates/cool_plate.png',
    'Cool Plate',
  ),

  /// 工程板（Engineering Plate）
  engPlate(
    '工程板',
    'eng_plate_temp',
    'eng_plate_temp_initial_layer',
    'assets/images/plates/engineering_plate.png',
    'Engineering Plate',
  ),

  /// 高温板（High Temp Plate）
  hotPlate(
    '高温板',
    'hot_plate_temp',
    'hot_plate_temp_initial_layer',
    'assets/images/plates/high_temp_plate.png',
    'High Temp Plate',
  ),

  /// 纹理 PEI 板（Textured PEI Plate）
  texturedPei(
    '纹理PEI板',
    'textured_plate_temp',
    'textured_plate_temp_initial_layer',
    'assets/images/plates/textured_pei_plate.png',
    'Textured PEI Plate',
  ),

  /// 超粘板（SuperTack Plate）
  superTack(
    '超粘板',
    'supertack_plate_temp',
    'supertack_plate_temp_initial_layer',
    'assets/images/plates/supertack_plate.png',
    'SuperTack Plate',
  );

  /// 中文标签。
  final String label;

  /// 常规层温度字段名（snake_case）。
  final String tempKey;

  /// 首层温度字段名（snake_case）。
  final String initialLayerTempKey;

  /// 打印板实物图片资源路径（对标 BambuStudio `bed_*.png`）。
  final String imageAsset;

  /// 英文名（与拓竹切片软件显示一致）。
  final String englishName;

  const PlateType(
    this.label,
    this.tempKey,
    this.initialLayerTempKey,
    this.imageAsset,
    this.englishName,
  );

  /// 获取该打印板对应的两个温度字段 key。
  List<String> get tempFieldKeys => [tempKey, initialLayerTempKey];
}
