// ===========================================================================
// parameter_field_defs.dart
//
// 3D 打印切片软件参数字段定义表。
//
// 本文件以拓竹（Bambu Studio）官方预设 JSON 为权威参考，覆盖：
//   - 工艺参数（fdm_process_common.json）：质量 / 强度 / 速度 / 支撑 / 其他
//   - 耗材参数（fdm_filament_common.json）：温度 / 流量 / 风扇 / 回抽 / 烘干 / 属性
//   - 打印机参数（fdm_machine_common.json）：喷嘴 / 打印床 / 机械限制 / 功能 / G-code
//
// 所有字段定义均可跨文件复用，FieldDef 与 ParamLevel 均为公开导出。
// ===========================================================================

/// 参数可见性等级。
enum ParamLevel {
  /// 普通模式：核心参数（层高、填充密度、速度等）
  basic,

  /// 高级模式：常用高级参数（线宽、加速度、悬垂速度等）
  advanced,

  /// 开发者模式：全部参数（含实验性参数）
  developer,
}

/// 参数字段定义。
///
/// 与原 parameter_config_screen.dart 中的 `_FieldDef` 保持一致，
/// 去掉下划线前缀以便跨文件复用。
class FieldDef {
  final String label; // 中文标签
  final String key; // 参数 key（snake_case，与官方 JSON 一致）
  final List<String>? options; // 非空时用下拉选择
  final bool isSwitch; // true 时用复选框
  final String? section; // 分组标题
  final String? unit; // 单位后缀（显式声明，如 mm/s, °C, mm）
  final List<String>? childKeys; // 开关的子参数 key 列表
  final String? tooltip; // 参数说明（hover 显示）
  final ParamLevel level; // 可见性等级
  final double? min; // 数值最小值
  final double? max; // 数值最大值
  final String? visibleCondition; // 值依赖条件，如 "support_type==tree(auto)"
  final bool isNumeric; // 是否数值输入（false 时允许任意字符）

  const FieldDef({
    required this.label,
    required this.key,
    this.options,
    this.isSwitch = false,
    this.section,
    this.unit,
    this.childKeys,
    this.tooltip,
    this.level = ParamLevel.advanced,
    this.min,
    this.max,
    this.visibleCondition,
    this.isNumeric = true,
  });

  /// 未显式配置范围时按领域语义提供保守边界，覆盖全部数值字段。
  double? get effectiveMin {
    if (min != null) return min;
    final normalized = '$key $label ${unit ?? ''}'.toLowerCase();
    if (normalized.contains('offset') || normalized.contains('补偿')) {
      return -1000;
    }
    if (normalized.contains('temperature') || normalized.contains('temp')) {
      return 0;
    }
    if (normalized.contains('speed') || normalized.contains('acceleration')) {
      return 0;
    }
    if (unit == '%' || normalized.contains('percent')) return 0;
    if (normalized.contains('length') ||
        normalized.contains('height') ||
        normalized.contains('width') ||
        normalized.contains('diameter') ||
        normalized.contains('distance')) {
      return 0;
    }
    return -1000000;
  }

  double? get effectiveMax {
    if (max != null) return max;
    final normalized = '$key $label ${unit ?? ''}'.toLowerCase();
    if (normalized.contains('temperature') || normalized.contains('temp')) {
      return 500;
    }
    if (normalized.contains('acceleration')) return 50000;
    if (normalized.contains('speed')) return 1000;
    if (unit == '%' || normalized.contains('percent')) return 100;
    if (normalized.contains('diameter') || normalized.contains('height')) {
      return 100;
    }
    if (normalized.contains('length') ||
        normalized.contains('width') ||
        normalized.contains('distance')) {
      return 10000;
    }
    return 1000000;
  }

  /// 根据当前所有控制器值判断此字段是否可见。
  bool isVisible(Map<String, String> currentValues) {
    if (visibleCondition == null) return true;
    // 解析 "key==value" 格式
    final parts = visibleCondition!.split('==');
    if (parts.length != 2) return true;
    final condKey = parts[0].trim();
    final condValue = parts[1].trim();
    return currentValues[condKey] == condValue;
  }
}

/// 选项值中文显示映射表。
///
/// 拓竹 Bambu Studio 的预设 JSON 中选项值用英文存储（用于跨语言兼容），
/// 但 UI 显示用中文。本表把英文选项值映射到拓竹官方中文界面的翻译。
///
/// 渲染下拉框时调用 [optionDisplayName]：有翻译则显示中文，无则显示原值。
/// 控制器存储的值始终是英文原值（保证导出 JSON 与官方兼容）。
const Map<String, String> optionLabelMap = {
  // ===== 稀疏填充图案（sparse_infill_pattern） =====
  'grid': '网格',
  'lines': '直线',
  'triangles': '三角形',
  'tri-hexagon': '三六边形',
  'gyroid': '螺旋',
  'cubic': '立方',
  'adaptive cubic': '自适应立方',
  'honeycomb': '蜂窝',
  '3d honeycomb': '3D 蜂窝',
  'concentric': '同心',
  'rectilinear': '直线填充',
  'rectilinear-grid': '直线网格',
  'aligned rectilinear': '对齐直线',
  'lightning': '闪电',
  // ===== 锁定填充图案（locked_skin/skeleton_infill_pattern） =====
  'crosszag': '交叉锯齿',
  'zigzag': '锯齿',
  'monotonic': '单调',
  'monotonicgapfill': '单调填缝',
  'monotonicline': '单调线',
  // ===== 支撑类型（support_type） =====
  'normal(auto)': '普通(自动)',
  'tree(auto)': '树形(自动)',
  // ===== 支撑风格（support_style） =====
  'default': '默认',
  'Snug': '贴合',
  // ===== 支撑主体图案（support_base_pattern） =====
  // 'default'/'rectilinear'/'honeycomb' 已在上面定义
  // ===== 支撑接触面图案（support_interface_pattern） =====
  'auto': '自动',
  // 'concentric'/'rectilinear'/'monotonic' 已在上面定义
  // ===== 支撑熨烫图案（support_ironing_pattern） =====
  // 'rectilinear'/'concentric' 已在上面定义
  'zig-zag': '锯齿',
  // ===== 接缝位置（seam_position） =====
  'nearest': '最近',
  'aligned': '对齐',
  'back': '后方',
  'random': '随机',
  // ===== 斜拼接缝类型（seam_slope_type） =====
  'none': '无',
  'scarf': '斜拼',
  'taper': '渐变',
  // ===== 墙生成器（wall_generator） =====
  'classic': '经典',
  'arachne': 'Arachne',
  // ===== 墙填充顺序（wall_infill_order） =====
  'inner wall/outer wall/infill': '内墙/外墙/填充',
  'inner-outer-inner wall/infill': '内-外-内墙/填充',
  'outer wall/inner wall/infill': '外墙/内墙/填充',
  'infill/inner wall/outer wall': '填充/内墙/外墙',
  // ===== Brim 类型（brim_type） =====
  'outer only': '仅外圈',
  'inner only': '仅内圈',
  'outer_and_inner': '内外圈',
  'no_brim': '无',
  // ===== 熨烫类型（ironing_type） =====
  'no ironing': '无熨烫',
  'top': '顶面',
  'top and bottom': '顶面和底面',
  // ===== 绒毛表面（fuzzy_skin / fuzzy_skin_mode） =====
  'surrounding': '外围',
  'all': '全部',
  // 'none' 已在上面定义
  'displacement': '位移',
  'normal': '正常',
  // ===== 绒毛噪声类型（fuzzy_skin_noise_type） =====
  // 'classic' 已在上面定义
  'perlin': '柏林',
  // ===== 顶/底面图案（top/bottom_surface_pattern） =====
  // 'monotonic'/'monotonicgapfill'/'concentric'/'rectilinear'/'monotonicline' 已在上面定义
  // ===== 挡风板（draft_shield） =====
  'disabled': '禁用',
  'limited': '有限',
  // 'all' 已在上面定义
  // ===== 减小填充回抽模式（reduce_infill_retraction_mode） =====
  'Auto': '自动',
  // 'all'/'none' 已在上面定义
  // ===== 冷却减速逻辑（cooling_slowdown_logic） =====
  'uniform_cooling': '均匀冷却',
  // 'default'/'top'/'none' 已在上面定义
  // ===== 打印顺序（print_sequence） =====
  'by layer': '按层',
  'by object': '按对象',
  // ===== Z跳高类型（filament_z_hop_types） =====
  'Auto Lift': '自动提升',
  'Normal Lift': '正常提升',
  // 'None' 等价于 'none'，但官方首字母大写，单独映射
  'None': '无',
  // ===== 耗材斜接缝类型（filament_scarf_seam_type） =====
  'contour': '轮廓',
  'hole': '孔',
  // 'none' 已在上面定义
  // ===== G-code 类型（gcode_flavor） =====
  'marlin': 'Marlin',
  'klipper': 'Klipper',
  'reprap': 'RepRap',
  // ===== 打印机结构（printer_structure） =====
  'corexy': 'CoreXY',
  'i3': 'I3',
  'other': '其他',
  // ===== nil 占位符（拓竹特殊值，表示"未设置/继承机器设置"） =====
  'nil': '默认/继承',
  // ===== 喷嘴类型（nozzle_type） =====
  'hardened_steel': '硬化钢',
  'stainless_steel': '不锈钢',
  // ===== 挤出机变体（printer_extruder_variant / filament_extruder_variant） =====
  'Direct Drive Standard': '直驱标准',
  'Direct Drive High Flow': '直驱高流量',
  'Direct Drive TPU High Flow': '直驱 TPU 高流量',
  // ===== 风扇方向（fan_direction） =====
  'undefine': '未定义',
  'left': '左侧',
  // ===== 金属粘性（filament_metal_stickiness） =====
  'High': '高',
  // ===== 启用长回抽换料三态值（enable_long_retraction_when_cut） =====
  // '0'/'1'/'2' 直接显示数字，无需中文映射
};

/// 获取选项的中文显示名称。
///
/// 优先返回 [optionLabelMap] 中的中文翻译；未匹配则返回原值。
/// 控制器存储的值不变（始终是英文原值），仅 UI 显示用中文。
String optionDisplayName(String option) {
  return optionLabelMap[option] ?? option;
}

// ===========================================================================
// 工艺参数 Tab1：质量（qualityFields）
// 对照 fdm_process_common.json
// ===========================================================================

const qualityFields = <FieldDef>[
  FieldDef(
    section: '层高',
    label: '层高',
    key: 'layer_height',
    unit: 'mm',
    level: ParamLevel.basic,
    tooltip: '每层打印的厚度，影响精度和速度（官方默认 0.2）',
    min: 0.01,
    max: 1.0,
  ),
  FieldDef(
    label: '首层层高',
    key: 'initial_layer_print_height',
    unit: 'mm',
    level: ParamLevel.basic,
    tooltip: '首层打印厚度，影响附着力（官方默认 0.2）',
    min: 0.01,
    max: 1.0,
  ),
  FieldDef(
    label: '自适应层高',
    key: 'adaptive_layer_height',
    isSwitch: true,
    level: ParamLevel.basic,
    tooltip: '根据曲率自动调整层高（官方默认 0）',
  ),
  FieldDef(
    section: '线宽',
    label: '线宽',
    key: 'line_width',
    unit: 'mm',
    level: ParamLevel.basic,
    tooltip: '挤出线宽，通常略大于喷嘴直径（官方默认 0.42）',
    min: 0.01,
    max: 2.0,
  ),
  FieldDef(
    label: '首层线宽',
    key: 'initial_layer_line_width',
    unit: 'mm',
    tooltip: '首层挤出线宽（官方默认 0.5）',
  ),
  FieldDef(
    label: '内墙线宽',
    key: 'inner_wall_line_width',
    unit: 'mm',
    tooltip: '内墙挤出线宽（官方默认 0.45）',
  ),
  FieldDef(
    label: '外墙线宽',
    key: 'outer_wall_line_width',
    unit: 'mm',
    tooltip: '外墙挤出线宽（官方默认 0.42）',
  ),
  FieldDef(
    label: '顶面线宽',
    key: 'top_surface_line_width',
    unit: 'mm',
    tooltip: '顶面挤出线宽（官方默认 0.42）',
  ),
  FieldDef(
    label: '稀疏填充线宽',
    key: 'sparse_infill_line_width',
    unit: 'mm',
    tooltip: '稀疏填充挤出线宽（官方默认 0.45）',
  ),
  FieldDef(
    label: '表皮线宽',
    key: 'skin_infill_line_width',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '表皮填充线宽（官方默认 0.45）',
  ),
  FieldDef(
    label: '骨架填充线宽',
    key: 'skeleton_infill_line_width',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '骨架填充线宽（官方默认 0.45）',
  ),
  FieldDef(
    label: '内部实心填充线宽',
    key: 'internal_solid_infill_line_width',
    unit: 'mm',
    tooltip: '内部实心填充挤出线宽（官方默认 0.42）',
  ),
  FieldDef(
    label: '支撑线宽',
    key: 'support_line_width',
    unit: 'mm',
    tooltip: '支撑挤出线宽（官方默认 0.42）',
  ),
  FieldDef(
    section: '分辨率',
    label: '分辨率',
    key: 'resolution',
    tooltip: 'G-code 分辨率，参考 Bambu Studio 文档（官方默认 0.012）',
  ),
];

// ===========================================================================
// 工艺参数 Tab2：强度（strengthFields）
// ===========================================================================

const strengthFields = <FieldDef>[
  FieldDef(
    section: '外壳',
    label: '墙层数',
    key: 'wall_loops',
    level: ParamLevel.basic,
    tooltip: '外墙层数，越多强度越高（官方默认 2）',
    min: 0,
    max: 10,
  ),
  FieldDef(
    label: '顶部壳体层数',
    key: 'top_shell_layers',
    level: ParamLevel.basic,
    tooltip: '顶部实心填充层数（官方默认 3）',
    min: 0,
    max: 20,
  ),
  FieldDef(
    label: '底部壳体层数',
    key: 'bottom_shell_layers',
    level: ParamLevel.basic,
    tooltip: '底部实心填充层数（官方默认 3）',
    min: 0,
    max: 20,
  ),
  FieldDef(
    label: '顶部壳体厚度',
    key: 'top_shell_thickness',
    unit: 'mm',
    tooltip: '顶部实心填充厚度（官方默认 0.8）',
  ),
  FieldDef(
    label: '底部壳体厚度',
    key: 'bottom_shell_thickness',
    unit: 'mm',
    tooltip: '底部实心填充厚度（官方默认 0）',
  ),
  FieldDef(
    label: '顶部涂色渗透层数',
    key: 'top_color_penetration_layers',
    tooltip: '顶部涂色渗透层数（官方默认 3）',
  ),
  FieldDef(
    label: '底部涂色渗透层数',
    key: 'bottom_color_penetration_layers',
    tooltip: '底部涂色渗透层数（官方默认 3）',
  ),
  FieldDef(
    section: '填充密度与图案',
    label: '稀疏填充密度',
    key: 'sparse_infill_density',
    level: ParamLevel.basic,
    tooltip: '内部填充密度，0-100%（官方默认 15%）',
    min: 0,
    max: 100,
  ),
  FieldDef(
    label: '骨架填充密度',
    key: 'skeleton_infill_density',
    level: ParamLevel.developer,
    tooltip: '骨架填充密度（官方默认 15%）',
  ),
  FieldDef(
    label: '表皮填充密度',
    key: 'skin_infill_density',
    level: ParamLevel.developer,
    tooltip: '表皮填充密度（官方默认 15%）',
  ),
  FieldDef(
    label: '表皮填充深度',
    key: 'skin_infill_depth',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '表皮填充深度（官方默认 2.0）',
  ),
  FieldDef(
    label: '稀疏填充图案',
    key: 'sparse_infill_pattern',
    level: ParamLevel.basic,
    tooltip: '内部填充图案（官方默认 grid）',
    options: [
      'grid',
      'lines',
      'triangles',
      'tri-hexagon',
      'gyroid',
      'cubic',
      'adaptive cubic',
      'honeycomb',
      '3d honeycomb',
      'concentric',
      'rectilinear',
      'rectilinear-grid',
      'aligned rectilinear',
    ],
  ),
  // 修正：locked_skin_infill_pattern 选项改为 ['crosszag','zigzag']
  FieldDef(
    label: '锁定表皮填充图案',
    key: 'locked_skin_infill_pattern',
    level: ParamLevel.developer,
    tooltip: '锁定表皮填充图案（官方默认 crosszag）',
    options: ['crosszag', 'zigzag'],
  ),
  // 修正：locked_skeleton_infill_pattern 选项改为 ['crosszag','zigzag']
  FieldDef(
    label: '锁定骨架填充图案',
    key: 'locked_skeleton_infill_pattern',
    level: ParamLevel.developer,
    tooltip: '锁定骨架填充图案（官方默认 zigzag）',
    options: ['crosszag', 'zigzag'],
  ),
  FieldDef(
    section: '填充高级',
    label: '合并填充',
    key: 'infill_combination',
    isSwitch: true,
    tooltip: '合并填充（官方默认 0）',
  ),
  FieldDef(
    label: '填充方向',
    key: 'infill_direction',
    tooltip: '填充方向（官方默认 45）',
  ),
  FieldDef(
    label: '填充墙重叠',
    key: 'infill_wall_overlap',
    tooltip: '填充与墙的重叠比例（官方默认 15%）',
  ),
  FieldDef(
    label: '填充互锁深度',
    key: 'infill_lock_depth',
    level: ParamLevel.developer,
    tooltip: '填充互锁深度（官方默认 1.0）',
  ),
  FieldDef(
    label: '填充移动步长',
    key: 'infill_shift_step',
    level: ParamLevel.developer,
    tooltip: '填充移动步长（官方默认 0.4）',
  ),
  FieldDef(
    label: '填充旋转步长',
    key: 'infill_rotate_step',
    level: ParamLevel.developer,
    tooltip: '填充旋转步长（官方默认 0）',
  ),
  FieldDef(
    label: '最小稀疏填充面积',
    key: 'minimum_sparse_infill_area',
    unit: 'mm²',
    tooltip: '最小稀疏填充面积（官方默认 15）',
  ),
  FieldDef(
    label: '填充替代顶底面',
    key: 'infill_instead_top_bottom_surfaces',
    isSwitch: true,
    tooltip: '使用填充替代顶底面（官方默认 0）',
  ),
  FieldDef(
    label: '填充多线',
    key: 'fill_multiline',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '填充多线（官方默认 1）',
  ),
  FieldDef(
    label: '晶格角度 1',
    key: 'sparse_infill_lattice_angle_1',
    unit: '°',
    level: ParamLevel.developer,
    tooltip: '晶格角度 1（官方默认 -45）',
  ),
  FieldDef(
    label: '晶格角度 2',
    key: 'sparse_infill_lattice_angle_2',
    unit: '°',
    level: ParamLevel.developer,
    tooltip: '晶格角度 2（官方默认 45）',
  ),
  FieldDef(
    label: '填充关于 Y 轴对称',
    key: 'symmetric_infill_y_axis',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '填充关于 Y 轴对称（官方默认 0）',
  ),
  FieldDef(
    section: '耗材分配',
    label: '稀疏填充耗材',
    key: 'sparse_infill_filament',
    tooltip: '稀疏填充耗材（官方默认 0）',
  ),
  FieldDef(
    label: '墙耗材',
    key: 'wall_filament',
    tooltip: '墙耗材（官方默认 0）',
  ),
  FieldDef(
    label: '实心填充耗材',
    key: 'solid_infill_filament',
    tooltip: '实心填充耗材（官方默认 0）',
  ),
  FieldDef(
    section: '高级检测',
    label: '接触面外壳',
    key: 'interface_shells',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '接触面外壳（官方默认 0）',
  ),
  FieldDef(
    label: '识别悬空实心填充',
    key: 'detect_floating_vertical_shell',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '识别悬空实心填充（官方默认 1）',
  ),
  FieldDef(
    label: '识别悬垂外墙',
    key: 'detect_overhang_wall',
    isSwitch: true,
    tooltip: '识别悬垂外墙（官方默认 1）',
  ),
  FieldDef(
    label: '检查薄壁',
    key: 'detect_thin_wall',
    isSwitch: true,
    tooltip: '检查薄壁（官方默认 0）',
  ),
  FieldDef(
    label: '顶面单层墙',
    key: 'only_one_wall_top',
    isSwitch: true,
    tooltip: '顶面单层墙（官方默认 1）',
  ),
];

// ===========================================================================
// 工艺参数 Tab3：速度（speedFields）
// ===========================================================================

const speedFields = <FieldDef>[
  FieldDef(
    section: '打印速度',
    label: '内墙速度',
    key: 'inner_wall_speed',
    unit: 'mm/s',
    level: ParamLevel.basic,
    tooltip: '内墙打印速度（官方默认 40）',
    min: 1,
    max: 500,
  ),
  FieldDef(
    label: '外墙速度',
    key: 'outer_wall_speed',
    unit: 'mm/s',
    level: ParamLevel.basic,
    tooltip: '外墙打印速度（官方默认 120）',
    min: 1,
    max: 500,
  ),
  FieldDef(
    label: '稀疏填充速度',
    key: 'sparse_infill_speed',
    unit: 'mm/s',
    level: ParamLevel.basic,
    tooltip: '稀疏填充速度（官方默认 50）',
  ),
  FieldDef(
    label: '内部实心填充速度',
    key: 'internal_solid_infill_speed',
    unit: 'mm/s',
    tooltip: '内部实心填充速度（官方默认 40）',
  ),
  FieldDef(
    label: '顶面实心填充速度',
    key: 'top_surface_speed',
    unit: 'mm/s',
    level: ParamLevel.basic,
    tooltip: '顶面打印速度（官方默认 30）',
  ),
  FieldDef(
    label: '首层速度',
    key: 'initial_layer_speed',
    unit: 'mm/s',
    level: ParamLevel.basic,
    tooltip: '首层打印速度（官方默认 20）',
  ),
  FieldDef(
    label: '首层填充速度',
    key: 'initial_layer_infill_speed',
    unit: 'mm/s',
    tooltip: '首层填充速度',
  ),
  FieldDef(
    label: '支撑速度',
    key: 'support_speed',
    unit: 'mm/s',
    tooltip: '支撑速度（官方默认 40）',
  ),
  FieldDef(
    label: '支撑面速度',
    key: 'support_interface_speed',
    unit: 'mm/s',
    tooltip: '支撑面速度（官方默认 80）',
  ),
  FieldDef(
    label: '桥接速度',
    key: 'bridge_speed',
    unit: 'mm/s',
    tooltip: '桥接速度（官方默认 25）',
  ),
  FieldDef(
    label: '填缝速度',
    key: 'gap_infill_speed',
    unit: 'mm/s',
    tooltip: '填缝速度（官方默认 30）',
  ),
  FieldDef(
    label: '空驶速度',
    key: 'travel_speed',
    unit: 'mm/s',
    level: ParamLevel.basic,
    tooltip: '空驶速度（官方默认 400）',
    min: 1,
    max: 1000,
  ),
  FieldDef(
    label: 'Z 轴空驶速度',
    key: 'travel_speed_z',
    unit: 'mm/s',
    tooltip: 'Z 轴空驶速度',
  ),
  FieldDef(
    section: '悬垂速度',
    label: '全悬垂速度',
    key: 'overhang_totally_speed',
    unit: 'mm/s',
    tooltip: '全悬垂速度（官方默认 10）',
  ),
  FieldDef(
    label: '1/4 悬垂速度',
    key: 'overhang_1_4_speed',
    unit: 'mm/s',
    tooltip: '1/4 悬垂速度',
  ),
  FieldDef(
    label: '2/4 悬垂速度',
    key: 'overhang_2_4_speed',
    unit: 'mm/s',
    tooltip: '2/4 悬垂速度',
  ),
  FieldDef(
    label: '3/4 悬垂速度',
    key: 'overhang_3_4_speed',
    unit: 'mm/s',
    tooltip: '3/4 悬垂速度',
  ),
  FieldDef(
    label: '4/4 悬垂速度',
    key: 'overhang_4_4_speed',
    unit: 'mm/s',
    tooltip: '4/4 悬垂速度',
  ),
  FieldDef(
    label: '启用悬垂速度',
    key: 'enable_overhang_speed',
    isSwitch: true,
    tooltip: '启用悬垂速度',
    childKeys: [
      'overhang_totally_speed',
      'overhang_1_4_speed',
      'overhang_2_4_speed',
      'overhang_3_4_speed',
      'overhang_4_4_speed',
    ],
  ),
  FieldDef(
    section: '小周长',
    label: '小轮廓速度',
    key: 'small_perimeter_speed',
    tooltip: '小轮廓速度（百分比）',
  ),
  FieldDef(
    label: '小轮廓阈值',
    key: 'small_perimeter_threshold',
    tooltip: '小轮廓阈值',
  ),
  FieldDef(
    label: '斜面填充速度',
    key: 'vertical_shell_speed',
    tooltip: '斜面填充速度（百分比）',
  ),
  FieldDef(
    section: '加速度',
    label: '默认加速度',
    key: 'default_acceleration',
    unit: 'mm/s²',
    level: ParamLevel.basic,
    tooltip: '默认打印加速度（官方默认 10000）',
    min: 100,
    max: 20000,
  ),
  FieldDef(
    label: '空驶加速度',
    key: 'travel_acceleration',
    unit: 'mm/s²',
    level: ParamLevel.basic,
    tooltip: '空驶加速度（官方默认 10000）',
  ),
  FieldDef(
    label: '短距空驶加速度',
    key: 'travel_short_distance_acceleration',
    unit: 'mm/s²',
    tooltip: '短距空驶加速度（官方默认 250）',
  ),
  FieldDef(
    label: '首层加速度',
    key: 'initial_layer_acceleration',
    unit: 'mm/s²',
    tooltip: '首层加速度',
  ),
  FieldDef(
    label: '首层空驶加速度',
    key: 'initial_layer_travel_acceleration',
    unit: 'mm/s²',
    tooltip: '首层空驶加速度（官方默认 6000）',
  ),
  FieldDef(
    label: '内墙加速度',
    key: 'inner_wall_acceleration',
    unit: 'mm/s²',
    tooltip: '内墙加速度',
  ),
  FieldDef(
    label: '外墙加速度',
    key: 'outer_wall_acceleration',
    unit: 'mm/s²',
    tooltip: '外墙加速度',
  ),
  FieldDef(
    label: '稀疏填充加速度',
    key: 'sparse_infill_acceleration',
    tooltip: '稀疏填充加速度（百分比）',
  ),
  FieldDef(
    label: '顶面填充加速度',
    key: 'top_surface_acceleration',
    unit: 'mm/s²',
    tooltip: '顶面填充加速度',
  ),
  FieldDef(
    section: '高度减速',
    label: '减速起始高度',
    key: 'slowdown_start_height',
    unit: 'mm',
    tooltip: '减速起始高度',
  ),
  FieldDef(
    label: '起始高度处速度',
    key: 'slowdown_start_speed',
    unit: 'mm/s',
    tooltip: '起始高度处速度',
  ),
  FieldDef(
    label: '起始高度处加速度',
    key: 'slowdown_start_acc',
    unit: 'mm/s²',
    tooltip: '起始高度处加速度',
  ),
  FieldDef(
    label: '减速结束高度',
    key: 'slowdown_end_height',
    unit: 'mm',
    tooltip: '减速结束高度',
  ),
  FieldDef(
    label: '结束高度处速度',
    key: 'slowdown_end_speed',
    unit: 'mm/s',
    tooltip: '结束高度处速度',
  ),
  FieldDef(
    label: '结束高度处加速度',
    key: 'slowdown_end_acc',
    unit: 'mm/s²',
    tooltip: '结束高度处加速度',
  ),
  FieldDef(
    label: '随高度降速',
    key: 'enable_height_slowdown',
    isSwitch: true,
    tooltip: '随高度降速',
    childKeys: [
      'slowdown_start_height',
      'slowdown_start_speed',
      'slowdown_start_acc',
      'slowdown_end_height',
      'slowdown_end_speed',
      'slowdown_end_acc',
    ],
  ),
  FieldDef(
    section: '平滑与温度',
    label: '平滑系数',
    key: 'smooth_coefficient',
    tooltip: '平滑系数（官方默认 80）',
  ),
  FieldDef(
    label: '层时间平滑',
    key: 'layer_time_smoothing',
    level: ParamLevel.developer,
    tooltip: '层时间平滑（官方默认 0）',
  ),
  FieldDef(
    label: '层时间平滑阈值',
    key: 'layer_time_smoothing_threshold',
    level: ParamLevel.developer,
    tooltip: '层时间平滑阈值（官方默认 30）',
  ),
  FieldDef(
    label: '待机温度差',
    key: 'standby_temperature_delta',
    unit: '°C',
    level: ParamLevel.developer,
    tooltip: '待机温度差（官方默认 -5）',
    min: -500,
    max: 500,
  ),
  FieldDef(
    label: '风扇预启动时间',
    key: 'pre_start_fan_time',
    unit: 's',
    level: ParamLevel.developer,
    tooltip: '风扇预启动时间（官方默认 0）',
  ),
];

// ===========================================================================
// 工艺参数 Tab4：支撑（supportFields）
// ===========================================================================

const supportFields = <FieldDef>[
  FieldDef(
    section: '支撑基础',
    label: '开启支撑',
    key: 'enable_support',
    isSwitch: true,
    level: ParamLevel.basic,
    tooltip: '为悬空部分生成支撑结构（官方默认 0）',
    childKeys: [
      'support_type',
      'support_style',
      'support_threshold_angle',
      'support_on_build_plate_only',
      'support_base_pattern',
      'support_base_pattern_spacing',
      'support_expansion',
      'support_filament',
      'support_interface_filament',
      'support_interface_pattern',
      'support_interface_spacing',
      'support_interface_loop_pattern',
      'support_interface_top_layers',
      'support_interface_bottom_layers',
      'support_top_z_distance',
      'support_bottom_z_distance',
      'support_object_xy_distance',
      'tree_support_branch_angle',
      'tree_support_branch_diameter',
      'tree_support_wall_count',
    ],
  ),
  FieldDef(
    label: '支撑类型',
    key: 'support_type',
    level: ParamLevel.basic,
    tooltip: '支撑类型：normal 普通 / tree 树形（官方默认 tree(auto)）',
    options: ['normal(auto)', 'tree(auto)'],
  ),
  FieldDef(
    label: '支撑风格',
    key: 'support_style',
    tooltip: '支撑风格（官方默认 default）',
    options: ['default', 'grid', 'Snug'],
  ),
  FieldDef(
    label: '支撑阈值角度',
    key: 'support_threshold_angle',
    unit: '°',
    level: ParamLevel.basic,
    tooltip: '生成支撑的最小悬垂角度（官方默认 30）',
  ),
  FieldDef(
    label: '仅在打印板生成',
    key: 'support_on_build_plate_only',
    isSwitch: true,
    level: ParamLevel.basic,
    tooltip: '仅在打印板上生成支撑（官方默认 0）',
  ),
  FieldDef(
    label: '支撑主体图案',
    key: 'support_base_pattern',
    tooltip: '支撑主体图案（官方默认 default）',
    options: ['default', 'rectilinear', 'honeycomb'],
  ),
  FieldDef(
    label: '主体图案线距',
    key: 'support_base_pattern_spacing',
    unit: 'mm',
    tooltip: '主体图案线距（官方默认 2.5）',
  ),
  FieldDef(
    label: '普通支撑拓展',
    key: 'support_expansion',
    tooltip: '普通支撑拓展（官方默认 0）',
  ),
  FieldDef(
    section: '耗材分配',
    label: '支撑耗材',
    key: 'support_filament',
    tooltip: '支撑耗材（官方默认 0）',
  ),
  FieldDef(
    label: '支撑接触面耗材',
    key: 'support_interface_filament',
    tooltip: '支撑接触面耗材（官方默认 0）',
  ),
  FieldDef(
    section: '接触面',
    label: '支撑接触面图案',
    key: 'support_interface_pattern',
    tooltip: '支撑接触面图案（官方默认 auto）',
    // 修正：增加 'auto' 选项
    options: ['auto', 'concentric', 'rectilinear', 'monotonic'],
  ),
  FieldDef(
    label: '支撑接触面线距',
    key: 'support_interface_spacing',
    unit: 'mm',
    tooltip: '支撑接触面线距（官方默认 0.5）',
  ),
  FieldDef(
    label: '支撑接触面循环图案',
    key: 'support_interface_loop_pattern',
    isSwitch: true,
    tooltip: '支撑接触面循环图案（官方默认 0）',
  ),
  FieldDef(
    label: '顶部接触面层数',
    key: 'support_interface_top_layers',
    tooltip: '顶部接触面层数（官方默认 2）',
  ),
  FieldDef(
    label: '底部接触面层数',
    key: 'support_interface_bottom_layers',
    tooltip: '底部接触面层数（官方默认 2）',
  ),
  FieldDef(
    section: '距离',
    label: '支撑顶部 Z 距离',
    key: 'support_top_z_distance',
    unit: 'mm',
    tooltip: '支撑顶部 Z 距离（官方默认 0.2）',
  ),
  FieldDef(
    label: '支撑底部 Z 距离',
    key: 'support_bottom_z_distance',
    unit: 'mm',
    tooltip: '支撑底部 Z 距离（官方默认 0.2）',
  ),
  FieldDef(
    label: '支撑/模型 XY 间距',
    key: 'support_object_xy_distance',
    unit: 'mm',
    tooltip: '支撑与模型的 XY 间距（官方默认 0.35）',
  ),
  FieldDef(
    section: '树支撑',
    label: '树支撑分支角度',
    key: 'tree_support_branch_angle',
    unit: '°',
    visibleCondition: 'support_type==tree(auto)',
    tooltip: '树支撑分支角度（官方默认 45）',
  ),
  FieldDef(
    label: '树支撑分支直径',
    key: 'tree_support_branch_diameter',
    unit: 'mm',
    visibleCondition: 'support_type==tree(auto)',
    tooltip: '树支撑分支直径（官方默认 2）',
  ),
  FieldDef(
    label: '支撑外墙层数',
    key: 'tree_support_wall_count',
    visibleCondition: 'support_type==tree(auto)',
    tooltip: '树支撑外墙层数（官方默认 -1）',
  ),
  FieldDef(
    section: '其他',
    label: '筏层',
    key: 'raft_layers',
    tooltip: '筏层数（官方默认 0）',
  ),
  FieldDef(
    label: '桥接无支撑',
    key: 'bridge_no_support',
    isSwitch: true,
    tooltip: '桥接不生成支撑（官方默认 0）',
  ),
  FieldDef(
    label: '最大桥接长度',
    key: 'max_bridge_length',
    unit: 'mm',
    tooltip: '最大桥接长度（官方默认 0）',
  ),
  FieldDef(
    label: '内部桥接支撑厚度',
    key: 'internal_bridge_support_thickness',
    unit: 'mm',
    tooltip: '内部桥接支撑厚度（官方默认 0.8）',
  ),
  FieldDef(
    section: '支撑熨烫',
    label: '启用支撑接触面熨烫',
    key: 'enable_support_ironing',
    isSwitch: true,
    tooltip: '启用支撑接触面熨烫（官方默认 0）',
    childKeys: [
      'support_ironing_pattern',
      'support_ironing_speed',
      'support_ironing_flow',
      'support_ironing_spacing',
      'support_ironing_inset',
      'support_ironing_direction',
    ],
  ),
  FieldDef(
    label: '支撑熨烫模式',
    key: 'support_ironing_pattern',
    tooltip: '支撑熨烫模式（官方默认 zig-zag）',
    options: ['rectilinear', 'concentric', 'zig-zag'],
  ),
  FieldDef(
    label: '支撑熨烫速度',
    key: 'support_ironing_speed',
    unit: 'mm/s',
    tooltip: '支撑熨烫速度（官方默认 30）',
  ),
  FieldDef(
    label: '支撑熨烫流量',
    key: 'support_ironing_flow',
    tooltip: '支撑熨烫流量（官方默认 10%）',
  ),
  FieldDef(
    label: '支撑熨烫间距',
    key: 'support_ironing_spacing',
    unit: 'mm',
    tooltip: '支撑熨烫间距（官方默认 0.15）',
  ),
  FieldDef(
    label: '支撑熨烫内缩',
    key: 'support_ironing_inset',
    unit: 'mm',
    tooltip: '支撑熨烫内缩（官方默认 0.0）',
  ),
  FieldDef(
    label: '支撑熨烫方向',
    key: 'support_ironing_direction',
    tooltip: '支撑熨烫方向（官方默认 0）',
  ),
];

// ===========================================================================
// 工艺参数 Tab5：其他（otherFields）
// ===========================================================================

const otherFields = <FieldDef>[
  FieldDef(
    section: '接缝',
    label: '接缝位置',
    key: 'seam_position',
    level: ParamLevel.basic,
    tooltip: '接缝位置：nearest 最近 / aligned 对齐 / back 后方 / random 随机（官方默认 aligned）',
    options: ['nearest', 'aligned', 'back', 'random'],
  ),
  FieldDef(
    label: '接缝远离悬垂点放置',
    key: 'seam_placement_away_from_overhangs',
    isSwitch: true,
    tooltip: '接缝远离悬垂点放置（官方默认 0）',
  ),
  // 修正：seam_slope_type 选项保持 ['none','scarf','taper']
  FieldDef(
    label: '斜拼接缝类型',
    key: 'seam_slope_type',
    tooltip: '斜拼接缝类型（官方默认 none）',
    options: ['none', 'scarf', 'taper'],
  ),
  FieldDef(
    label: '斜拼接缝起始高度',
    key: 'seam_slope_start_height',
    unit: 'mm',
    tooltip: '斜拼接缝起始高度（官方默认 10%）',
  ),
  FieldDef(
    label: '斜拼接缝间隔',
    key: 'seam_slope_gap',
    unit: 'mm',
    tooltip: '斜拼接缝间隔（官方默认 0）',
  ),
  FieldDef(
    label: '斜拼接缝最小长度',
    key: 'seam_slope_min_length',
    unit: 'mm',
    tooltip: '斜拼接缝最小长度（官方默认 10）',
  ),
  FieldDef(
    label: '斜拼角度阈值',
    key: 'scarf_angle_threshold',
    unit: '°',
    tooltip: '斜拼角度阈值（官方默认 155）',
  ),
  FieldDef(
    label: '覆盖耗材的斜拼接缝参数',
    key: 'override_filament_scarf_seam_setting',
    isSwitch: true,
    tooltip: '覆盖耗材的斜拼接缝参数（官方默认 0）',
  ),
  FieldDef(
    section: '墙生成器',
    label: '墙生成器',
    key: 'wall_generator',
    tooltip: '墙生成器：classic / arachne（官方默认 classic）',
    options: ['classic', 'arachne'],
  ),
  // 修正：wall_infill_order 改为下拉选项
  FieldDef(
    label: '内圈墙/外圈墙的打印顺序',
    key: 'wall_infill_order',
    isNumeric: false,
    tooltip: '内圈墙/外圈墙的打印顺序（官方默认 inner wall/outer wall/infill）',
    options: [
      'inner wall/outer wall/infill',
      'inner-outer-inner wall/infill',
      'outer wall/inner wall/infill',
      'infill/inner wall/outer wall',
    ],
  ),
  FieldDef(
    label: 'Z 方向速度平滑',
    key: 'z_direction_outwall_speed_continuous',
    isSwitch: true,
    tooltip: 'Z 方向速度平滑（官方默认 0）',
  ),
  FieldDef(
    section: '裙边/边缘',
    label: 'Brim 宽度',
    key: 'brim_width',
    unit: 'mm',
    level: ParamLevel.basic,
    tooltip: 'Brim 宽度（官方默认 5）',
  ),
  FieldDef(
    label: 'Brim 与模型的间隙',
    key: 'brim_object_gap',
    unit: 'mm',
    tooltip: 'Brim 与模型的间隙（官方默认 0.1）',
  ),
  FieldDef(
    label: 'Brim 类型',
    key: 'brim_type',
    level: ParamLevel.basic,
    tooltip: 'Brim 类型',
    options: ['outer only', 'inner only', 'outer_and_inner', 'no_brim'],
  ),
  FieldDef(
    label: 'Skirt 距离',
    key: 'skirt_distance',
    unit: 'mm',
    tooltip: 'Skirt 距离（官方默认 2）',
  ),
  FieldDef(
    label: 'Skirt 高度',
    key: 'skirt_height',
    unit: 'mm',
    tooltip: 'Skirt 高度（官方默认 1）',
  ),
  FieldDef(
    label: 'Skirt 圈数',
    key: 'skirt_loops',
    tooltip: 'Skirt 圈数（官方默认 0）',
  ),
  FieldDef(
    label: 'Skirt 逐对象',
    key: 'skirt_per_object',
    isSwitch: true,
    tooltip: 'Skirt 逐对象（官方默认 1）',
  ),
  FieldDef(
    section: '熨烫',
    label: '熨烫内缩',
    key: 'ironing_inset',
    unit: 'mm',
    tooltip: '熨烫内缩（官方默认 0.21）',
  ),
  FieldDef(
    label: '熨烫线距',
    key: 'ironing_spacing',
    unit: 'mm',
    tooltip: '熨烫线距（官方默认 0.15）',
  ),
  FieldDef(
    label: '熨烫速度',
    key: 'ironing_speed',
    unit: 'mm/s',
    tooltip: '熨烫速度（官方默认 30）',
  ),
  FieldDef(
    label: '熨烫类型',
    key: 'ironing_type',
    level: ParamLevel.basic,
    tooltip: '熨烫类型（官方默认 no ironing）',
    options: ['no ironing', 'top', 'top and bottom'],
  ),
  FieldDef(
    label: '熨烫流量',
    key: 'ironing_flow',
    tooltip: '熨烫流量（官方默认 10%）',
  ),
  FieldDef(
    section: '擦料塔',
    label: '启用擦料塔',
    key: 'enable_prime_tower',
    isSwitch: true,
    level: ParamLevel.basic,
    tooltip: '启用擦料塔（官方默认 1）',
    childKeys: [
      'prime_tower_width',
      'prime_tower_brim_width',
      'prime_tower_enable_framework',
      'prime_tower_lift_speed',
      'prime_tower_lift_height',
      'prime_tower_max_speed',
      'prime_tower_flat_ironing',
      'prime_tower_infill_gap',
      'prime_tower_rib_wall',
      'wipe_tower_no_sparse_layers',
      'enable_tower_interface_features',
    ],
  ),
  FieldDef(
    label: '擦料塔宽度',
    key: 'prime_tower_width',
    unit: 'mm',
    tooltip: '擦料塔宽度（官方默认 35）',
  ),
  FieldDef(
    label: '擦料塔 Brim 宽度',
    key: 'prime_tower_brim_width',
    unit: 'mm',
    tooltip: '擦料塔 Brim 宽度（官方默认 3）',
  ),
  FieldDef(
    label: '启用内支撑肋',
    key: 'prime_tower_enable_framework',
    isSwitch: true,
    tooltip: '启用内支撑肋（官方默认 0）',
  ),
  FieldDef(
    label: '擦料塔提升速度',
    key: 'prime_tower_lift_speed',
    unit: 'mm/s',
    tooltip: '擦料塔提升速度（官方默认 90）',
  ),
  FieldDef(
    label: '擦料塔提升高度',
    key: 'prime_tower_lift_height',
    unit: 'mm',
    tooltip: '擦料塔提升高度（官方默认 -1）',
  ),
  FieldDef(
    label: '擦料塔最大速度',
    key: 'prime_tower_max_speed',
    unit: 'mm/s',
    tooltip: '擦料塔最大速度（官方默认 90）',
  ),
  FieldDef(
    label: '擦料塔平面熨烫',
    key: 'prime_tower_flat_ironing',
    isSwitch: true,
    tooltip: '擦料塔平面熨烫（官方默认 0）',
  ),
  FieldDef(
    label: '擦料塔填充间隙',
    key: 'prime_tower_infill_gap',
    level: ParamLevel.developer,
    tooltip: '擦料塔填充间隙',
  ),
  FieldDef(
    label: '斜肋外墙',
    key: 'prime_tower_rib_wall',
    level: ParamLevel.developer,
    tooltip: '斜肋外墙',
  ),
  FieldDef(
    label: '擦料塔无稀疏层',
    key: 'wipe_tower_no_sparse_layers',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '擦料塔无稀疏层（官方默认 0）',
  ),
  FieldDef(
    label: '启用料塔接触层优化',
    key: 'enable_tower_interface_features',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '启用料塔接触层优化（官方默认 0）',
  ),
  FieldDef(
    section: '绒毛表面',
    label: '绒毛表面',
    key: 'fuzzy_skin',
    tooltip: '绒毛表面（官方默认 none）',
    options: ['none', 'surrounding', 'all'],
  ),
  FieldDef(
    label: '绒毛表面厚度',
    key: 'fuzzy_skin_thickness',
    unit: 'mm',
    tooltip: '绒毛表面厚度（官方默认 0.3）',
  ),
  FieldDef(
    label: '绒毛表面点间距',
    key: 'fuzzy_skin_point_distance',
    unit: 'mm',
    tooltip: '绒毛表面点间距（官方默认 0.8）',
  ),
  FieldDef(
    label: '绒毛表面应用至首层',
    key: 'fuzzy_skin_first_layer',
    isSwitch: true,
    tooltip: '绒毛表面应用至首层（官方默认 0）',
  ),
  FieldDef(
    label: '绒毛噪声类型',
    key: 'fuzzy_skin_noise_type',
    tooltip: '绒毛噪声类型（官方默认 classic）',
    options: ['classic', 'perlin'],
  ),
  // 修正：fuzzy_skin_mode 选项改为 ['none','displacement','normal']
  FieldDef(
    label: '绒毛表面模式',
    key: 'fuzzy_skin_mode',
    tooltip: '绒毛表面模式（官方默认 displacement）',
    options: ['none', 'displacement', 'normal'],
  ),
  FieldDef(
    label: '绒毛表面缩放',
    key: 'fuzzy_skin_scale',
    level: ParamLevel.developer,
    tooltip: '绒毛表面缩放（官方默认 1.0）',
  ),
  FieldDef(
    label: '绒毛表面噪声八度数',
    key: 'fuzzy_skin_octaves',
    level: ParamLevel.developer,
    tooltip: '绒毛表面噪声八度数（官方默认 4）',
  ),
  FieldDef(
    label: '绒毛表面噪声持续度',
    key: 'fuzzy_skin_persistence',
    level: ParamLevel.developer,
    tooltip: '绒毛表面噪声持续度（官方默认 0.5）',
  ),
  FieldDef(
    section: '顶底面',
    label: '顶面图案',
    key: 'top_surface_pattern',
    tooltip: '顶面图案（官方默认 monotonicline）',
    // 修正：top_surface_pattern 加 'monotonicline' 选项
    options: [
      'monotonic',
      'monotonicline',
      'monotonicgapfill',
      'concentric',
      'rectilinear',
    ],
  ),
  FieldDef(
    label: '顶面密度',
    key: 'top_surface_density',
    tooltip: '顶面密度（官方默认 100）',
  ),
  FieldDef(
    label: '底面图案',
    key: 'bottom_surface_pattern',
    tooltip: '底面图案（官方默认 monotonic）',
    // 修正：bottom_surface_pattern 加 'monotonicline' 选项
    options: [
      'monotonic',
      'monotonicline',
      'monotonicgapfill',
      'concentric',
      'rectilinear',
    ],
  ),
  FieldDef(
    label: '底面密度',
    key: 'bottom_surface_density',
    tooltip: '底面密度（官方默认 100）',
  ),
  FieldDef(
    section: '高级',
    label: '旋转模式',
    key: 'spiral_mode',
    isSwitch: true,
    level: ParamLevel.basic,
    tooltip: '旋转模式（vase mode 花瓶模式，官方默认 0）',
  ),
  // 修正：draft_shield 选项改为 ['disabled','limited','all']
  FieldDef(
    label: '挡风板',
    key: 'draft_shield',
    tooltip: '挡风板（官方默认 disabled）',
    options: ['disabled', 'limited', 'all'],
  ),
  FieldDef(
    label: '象脚补偿',
    key: 'elefant_foot_compensation',
    unit: 'mm',
    level: ParamLevel.basic,
    tooltip: '象脚补偿（官方默认 0）',
  ),
  FieldDef(
    label: 'X-Y 外轮廓尺寸补偿',
    key: 'xy_contour_compensation',
    unit: 'mm',
    tooltip: 'X-Y 外轮廓尺寸补偿（官方默认 0）',
  ),
  FieldDef(
    label: 'X-Y 内轮廓尺寸补偿',
    key: 'xy_hole_compensation',
    unit: 'mm',
    tooltip: 'X-Y 内轮廓尺寸补偿（官方默认 0）',
  ),
  FieldDef(
    label: '圆补偿手动偏移',
    key: 'circle_compensation_manual_offset',
    level: ParamLevel.developer,
    isNumeric: false,
    tooltip: '圆补偿手动偏移（官方默认 0）',
  ),
  FieldDef(
    label: '自动圆形轴孔补偿',
    key: 'enable_circle_compensation',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '自动圆形轴孔补偿（官方默认 0）',
  ),
  // 新增：圆补偿系数（developer 级），对照 fdm_filament_common.json
  FieldDef(
    label: '圆补偿系数 1',
    key: 'counter_coef_1',
    level: ParamLevel.developer,
    tooltip: '圆补偿系数 1（官方默认 0）',
  ),
  FieldDef(
    label: '圆补偿系数 2',
    key: 'counter_coef_2',
    level: ParamLevel.developer,
    tooltip: '圆补偿系数 2（官方默认 0.008）',
  ),
  FieldDef(
    label: '圆补偿系数 3',
    key: 'counter_coef_3',
    level: ParamLevel.developer,
    tooltip: '圆补偿系数 3（官方默认 -0.041）',
  ),
  FieldDef(
    label: '圆补偿上限',
    key: 'counter_limit_max',
    level: ParamLevel.developer,
    tooltip: '圆补偿上限（官方默认 0.033）',
  ),
  FieldDef(
    label: '圆补偿下限',
    key: 'counter_limit_min',
    level: ParamLevel.developer,
    tooltip: '圆补偿下限（官方默认 -0.035）',
  ),
  FieldDef(
    label: '孔补偿系数 1',
    key: 'hole_coef_1',
    level: ParamLevel.developer,
    tooltip: '孔补偿系数 1（官方默认 0）',
  ),
  FieldDef(
    label: '孔补偿系数 2',
    key: 'hole_coef_2',
    level: ParamLevel.developer,
    tooltip: '孔补偿系数 2（官方默认 -0.008）',
  ),
  FieldDef(
    label: '孔补偿系数 3',
    key: 'hole_coef_3',
    level: ParamLevel.developer,
    tooltip: '孔补偿系数 3（官方默认 0.23415）',
  ),
  FieldDef(
    label: '孔补偿上限',
    key: 'hole_limit_max',
    level: ParamLevel.developer,
    tooltip: '孔补偿上限（官方默认 0.22）',
  ),
  FieldDef(
    label: '孔补偿下限',
    key: 'hole_limit_min',
    level: ParamLevel.developer,
    tooltip: '孔补偿下限（官方默认 0.088）',
  ),
  FieldDef(
    label: '直径限制',
    key: 'diameter_limit',
    level: ParamLevel.developer,
    tooltip: '直径限制（官方默认 50）',
  ),
  FieldDef(
    label: '启用包裹检测',
    key: 'enable_wrapping_detection',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '启用包裹检测（官方默认 0）',
  ),
  FieldDef(
    label: '启用圆弧拟合',
    key: 'enable_arc_fitting',
    isSwitch: true,
    level: ParamLevel.basic,
    tooltip: '启用圆弧拟合（官方默认 1）',
  ),
  FieldDef(
    label: '避免跨越外墙',
    key: 'reduce_crossing_wall',
    isSwitch: true,
    tooltip: '避免跨越外墙（官方默认 0）',
  ),
  FieldDef(
    label: '避免跨越外墙-包含支撑',
    key: 'avoid_crossing_wall_includes_support',
    isSwitch: true,
    tooltip: '避免跨越外墙-包含支撑（官方默认 0）',
  ),
  // 修正：reduce_infill_retraction_mode 选项改为 ['Auto','all','none']
  FieldDef(
    label: '减小填充回抽模式',
    key: 'reduce_infill_retraction_mode',
    tooltip: '减小填充回抽模式（官方默认 Auto）',
    options: ['Auto', 'all', 'none'],
  ),
  FieldDef(
    label: '避免跨越外墙-最大绕行长度',
    key: 'max_travel_detour_distance',
    unit: 'mm',
    tooltip: '避免跨越外墙-最大绕行长度（官方默认 0）',
  ),
  FieldDef(
    label: '桥接流量',
    key: 'bridge_flow',
    tooltip: '桥接流量（官方默认 0.95）',
  ),
  FieldDef(
    label: '顶部表面流量比例',
    key: 'top_solid_infill_flow_ratio',
    tooltip: '顶部表面流量比例（官方默认 1）',
  ),
  FieldDef(
    label: '文件名格式',
    key: 'filename_format',
    level: ParamLevel.developer,
    isNumeric: false,
    tooltip:
        '文件名格式（官方默认 {input_filename_base}_{filament_type[0]}_{print_time}.gcode）',
  ),
  // 修正：print_sequence 选项改为 ['by layer','by object']
  FieldDef(
    label: '打印顺序',
    key: 'print_sequence',
    tooltip: '打印顺序（官方默认 by layer）',
    options: ['by layer', 'by object'],
  ),
  FieldDef(
    label: '打印挤出机 ID',
    key: 'print_extruder_id',
    level: ParamLevel.developer,
    isNumeric: false,
    tooltip: '打印挤出机 ID',
  ),
  FieldDef(
    label: '打印挤出机变体',
    key: 'print_extruder_variant',
    level: ParamLevel.developer,
    isNumeric: false,
    tooltip: '打印挤出机变体',
  ),
  FieldDef(
    label: '单调空驶入墙',
    key: 'monotonic_travel_into_wall',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '单调空驶入墙（官方默认 0.0）',
  ),
  FieldDef(
    label: '兼容打印机条件',
    key: 'compatible_printers_condition',
    level: ParamLevel.developer,
    isNumeric: false,
    tooltip: '兼容打印机条件（官方默认空）',
  ),
];

// ===========================================================================
// 耗材参数（filamentFields）
// 对照 fdm_filament_common.json
// ===========================================================================

const filamentFields = <FieldDef>[
  // ===== 喷嘴温度 =====
  FieldDef(
    section: '喷嘴温度',
    label: '喷嘴温度',
    key: 'nozzle_temperature',
    unit: '°C',
    tooltip: '喷嘴温度（官方默认 200）',
    min: 0,
    max: 400,
  ),
  FieldDef(
    label: '首层喷嘴温度',
    key: 'nozzle_temperature_initial_layer',
    unit: '°C',
    tooltip: '首层喷嘴温度（官方默认 200）',
  ),
  FieldDef(
    label: '喷嘴温度上限',
    key: 'nozzle_temperature_range_high',
    unit: '°C',
    tooltip: '喷嘴温度上限（官方默认 240）',
  ),
  FieldDef(
    label: '喷嘴温度下限',
    key: 'nozzle_temperature_range_low',
    unit: '°C',
    tooltip: '喷嘴温度下限（官方默认 190）',
  ),
  FieldDef(
    label: '玻璃化温度',
    key: 'temperature_vitrification',
    unit: '°C',
    tooltip: '玻璃化温度（官方默认 100）',
  ),
  // ===== 冷板温度 =====
  FieldDef(
    section: '冷板温度',
    label: '冷板温度',
    key: 'cool_plate_temp',
    unit: '°C',
    tooltip: '冷板温度（官方默认 60）',
  ),
  FieldDef(
    label: '冷板首层温度',
    key: 'cool_plate_temp_initial_layer',
    unit: '°C',
    tooltip: '冷板首层温度（官方默认 60）',
  ),
  // ===== 工程板温度 =====
  FieldDef(
    section: '工程板温度',
    label: '工程板温度',
    key: 'eng_plate_temp',
    unit: '°C',
    tooltip: '工程板温度（官方默认 60）',
  ),
  FieldDef(
    label: '工程板首层温度',
    key: 'eng_plate_temp_initial_layer',
    unit: '°C',
    tooltip: '工程板首层温度（官方默认 60）',
  ),
  // ===== 高温板温度 =====
  FieldDef(
    section: '高温板温度',
    label: '高温板温度',
    key: 'hot_plate_temp',
    unit: '°C',
    tooltip: '高温板温度（官方默认 60）',
  ),
  FieldDef(
    label: '高温板首层温度',
    key: 'hot_plate_temp_initial_layer',
    unit: '°C',
    tooltip: '高温板首层温度（官方默认 60）',
  ),
  // ===== 纹理 PEI 板温度 =====
  FieldDef(
    section: '纹理 PEI 板温度',
    label: '纹理 PEI 板温度',
    key: 'textured_plate_temp',
    unit: '°C',
    tooltip: '纹理 PEI 板温度（官方默认 60）',
  ),
  FieldDef(
    label: '纹理 PEI 板首层温度',
    key: 'textured_plate_temp_initial_layer',
    unit: '°C',
    tooltip: '纹理 PEI 板首层温度（官方默认 60）',
  ),
  // ===== 超粘板温度 =====
  FieldDef(
    section: '超粘板温度',
    label: '超粘板温度',
    key: 'supertack_plate_temp',
    unit: '°C',
    tooltip: '超粘板温度（官方默认 45）',
  ),
  FieldDef(
    label: '超粘板首层温度',
    key: 'supertack_plate_temp_initial_layer',
    unit: '°C',
    tooltip: '超粘板首层温度（官方默认 45）',
  ),
  FieldDef(
    label: '腔体温度',
    key: 'chamber_temperatures',
    unit: '°C',
    tooltip: '腔体温度（官方默认 0）',
  ),
  // ===== 流量 =====
  FieldDef(
    section: '流量',
    label: '流量比',
    key: 'filament_flow_ratio',
    tooltip: '流量比（官方默认 1）',
  ),
  FieldDef(
    label: '最大体积速度',
    key: 'filament_max_volumetric_speed',
    unit: 'mm³/s',
    tooltip: '最大体积速度（官方默认 0）',
  ),
  FieldDef(
    label: '换料冲洗体积速度',
    key: 'filament_flush_volumetric_speed',
    unit: 'mm³/s',
    tooltip: '换料冲洗体积速度（官方默认 0）',
  ),
  FieldDef(
    label: '换料顶出体积速度',
    key: 'filament_ramming_volumetric_speed',
    unit: 'mm³/s',
    tooltip: '换料顶出体积速度（官方默认 -1）',
  ),
  FieldDef(
    label: '换料顶出体积速度（NC）',
    key: 'filament_ramming_volumetric_speed_nc',
    unit: 'mm³/s',
    level: ParamLevel.developer,
    tooltip: '换料顶出体积速度 NC（官方默认 -1）',
  ),
  FieldDef(
    label: '自适应体积速度',
    key: 'filament_adaptive_volumetric_speed',
    unit: 'mm³/s',
    tooltip: '自适应体积速度（官方默认 0）',
  ),
  FieldDef(
    label: '速度自适应系数',
    key: 'filament_velocity_adaptation_factor',
    tooltip: '速度自适应系数（官方默认 1）',
  ),
  FieldDef(
    label: '体积速度系数',
    key: 'volumetric_speed_coefficients',
    level: ParamLevel.developer,
    isNumeric: false,
    tooltip: '体积速度系数（官方默认 0 0 0 0 0 0）',
  ),
  // 新增：耗材顶出体积相关
  FieldDef(
    label: '耗材顶出体积',
    key: 'filament_prime_volume',
    unit: 'mm³',
    tooltip: '耗材顶出体积（官方默认 45）',
  ),
  FieldDef(
    label: '耗材顶出体积（NC）',
    key: 'filament_prime_volume_nc',
    unit: 'mm³',
    level: ParamLevel.developer,
    tooltip: '耗材顶出体积 NC（官方默认 60）',
  ),
  FieldDef(
    label: '换料长度',
    key: 'filament_change_length',
    unit: 'mm',
    tooltip: '换料长度（官方默认 10）',
  ),
  FieldDef(
    label: '擦料塔最小冲洗体积',
    key: 'filament_minimal_purge_on_wipe_tower',
    unit: 'mm³',
    tooltip: '擦料塔最小冲洗体积（官方默认 15）',
  ),
  // ===== 风扇 =====
  FieldDef(
    section: '风扇',
    label: '风扇最大速度',
    key: 'fan_max_speed',
    unit: '%',
    tooltip: '风扇最大速度（官方默认 100）',
  ),
  FieldDef(
    label: '风扇最小速度',
    key: 'fan_min_speed',
    unit: '%',
    tooltip: '风扇最小速度（官方默认 35）',
  ),
  FieldDef(
    label: '风扇冷却层时间',
    key: 'fan_cooling_layer_time',
    unit: 's',
    tooltip: '风扇冷却层时间（官方默认 60）',
  ),
  FieldDef(
    label: '前 X 层关闭风扇',
    key: 'close_fan_the_first_x_layers',
    tooltip: '前 X 层关闭风扇（官方默认 3）',
  ),
  FieldDef(
    label: '全速风扇层',
    key: 'full_fan_speed_layer',
    tooltip: '全速风扇层（官方默认 0）',
  ),
  FieldDef(
    label: '悬垂风扇速度',
    key: 'overhang_fan_speed',
    unit: '%',
    tooltip: '悬垂风扇速度（官方默认 100）',
  ),
  FieldDef(
    label: '悬垂风扇阈值',
    key: 'overhang_fan_threshold',
    tooltip: '悬垂风扇阈值（官方默认 95%）',
  ),
  FieldDef(
    label: '辅助冷却风扇速度',
    key: 'additional_cooling_fan_speed',
    unit: '%',
    tooltip: '辅助冷却风扇速度（官方默认 0）',
  ),
  FieldDef(
    label: '前 X 层关闭辅助风扇',
    key: 'close_additional_fan_first_x_layers',
    tooltip: '前 X 层关闭辅助风扇（官方默认 3）',
  ),
  FieldDef(
    label: '辅助风扇全速层',
    key: 'additional_fan_full_speed_layer',
    tooltip: '辅助风扇全速层（官方默认 0）',
  ),
  FieldDef(
    label: '减少风扇启停频率',
    key: 'reduce_fan_stop_start_freq',
    isSwitch: true,
    tooltip: '减少风扇启停频率（官方默认 0）',
  ),
  FieldDef(
    label: '层冷却减速',
    key: 'slow_down_for_layer_cooling',
    isSwitch: true,
    tooltip: '层冷却减速（官方默认 1）',
  ),
  // 修正：cooling_slowdown_logic 选项改为 ['uniform_cooling','default','top','none']
  FieldDef(
    label: '冷却减速逻辑',
    key: 'cooling_slowdown_logic',
    tooltip: '冷却减速逻辑（官方默认 uniform_cooling）',
    options: ['uniform_cooling', 'default', 'top', 'none'],
  ),
  FieldDef(
    label: '冷却周长过渡距离',
    key: 'cooling_perimeter_transition_distance',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '冷却周长过渡距离（官方默认 10）',
  ),
  FieldDef(
    label: '减速层时间',
    key: 'slow_down_layer_time',
    unit: 's',
    tooltip: '减速层时间（官方默认 8）',
  ),
  FieldDef(
    label: '减速最小速度',
    key: 'slow_down_min_speed',
    unit: 'mm/s',
    tooltip: '减速最小速度（官方默认 10）',
  ),
  FieldDef(
    label: '外墙不冷却减速',
    key: 'no_slow_down_for_cooling_on_outwalls',
    isSwitch: true,
    tooltip: '外墙不冷却减速（官方默认 0）',
  ),
  FieldDef(
    label: '启用空气过滤',
    key: 'activate_air_filtration',
    isSwitch: true,
    tooltip: '启用空气过滤（官方默认 0）',
  ),
  FieldDef(
    label: '完成打印排风扇速度',
    key: 'complete_print_exhaust_fan_speed',
    unit: '%',
    tooltip: '完成打印排风扇速度（官方默认 70）',
  ),
  FieldDef(
    label: '打印中排风扇速度',
    key: 'during_print_exhaust_fan_speed',
    unit: '%',
    tooltip: '打印中排风扇速度（官方默认 70）',
  ),
  // ===== 悬垂速度（耗材侧覆盖） =====
  FieldDef(
    section: '悬垂速度',
    label: '覆盖工艺悬垂速度',
    key: 'override_process_overhang_speed',
    isSwitch: true,
    tooltip: '覆盖工艺悬垂速度（官方默认 0）',
  ),
  FieldDef(
    label: '启用耗材悬垂速度',
    key: 'filament_enable_overhang_speed',
    isSwitch: true,
    tooltip: '启用耗材悬垂速度（官方默认 1）',
  ),
  FieldDef(
    label: '耗材 1/4 悬垂速度',
    key: 'filament_overhang_1_4_speed',
    unit: 'mm/s',
    tooltip: '耗材 1/4 悬垂速度（官方默认 0）',
  ),
  FieldDef(
    label: '耗材 2/4 悬垂速度',
    key: 'filament_overhang_2_4_speed',
    unit: 'mm/s',
    tooltip: '耗材 2/4 悬垂速度（官方默认 50）',
  ),
  FieldDef(
    label: '耗材 3/4 悬垂速度',
    key: 'filament_overhang_3_4_speed',
    unit: 'mm/s',
    tooltip: '耗材 3/4 悬垂速度（官方默认 30）',
  ),
  FieldDef(
    label: '耗材 4/4 悬垂速度',
    key: 'filament_overhang_4_4_speed',
    unit: 'mm/s',
    tooltip: '耗材 4/4 悬垂速度（官方默认 10）',
  ),
  FieldDef(
    label: '耗材全悬垂速度',
    key: 'filament_overhang_totally_speed',
    unit: 'mm/s',
    tooltip: '耗材全悬垂速度（官方默认 10）',
  ),
  FieldDef(
    label: '耗材桥接速度',
    key: 'filament_bridge_speed',
    unit: 'mm/s',
    tooltip: '耗材桥接速度（官方默认 25）',
  ),
  // ===== 回抽 =====
  FieldDef(
    section: '回抽',
    label: '回抽长度',
    key: 'filament_retraction_length',
    unit: 'mm',
    tooltip: '回抽长度（官方默认 nil）',
  ),
  FieldDef(
    label: '回抽速度',
    key: 'filament_retraction_speed',
    unit: 'mm/s',
    tooltip: '回抽速度（官方默认 nil）',
  ),
  FieldDef(
    label: '回退速度',
    key: 'filament_deretraction_speed',
    unit: 'mm/s',
    tooltip: '回退速度（官方默认 nil）',
  ),
  FieldDef(
    label: '擦拭前回抽',
    key: 'filament_retract_before_wipe',
    tooltip: '擦拭前回抽（官方默认 nil）',
  ),
  FieldDef(
    label: '回抽重启额外量',
    key: 'filament_retract_restart_extra',
    unit: 'mm',
    tooltip: '回抽重启额外量（官方默认 nil）',
  ),
  FieldDef(
    label: '换层回抽',
    key: 'filament_retract_when_changing_layer',
    isSwitch: true,
    tooltip: '换层回抽（官方默认 nil）',
  ),
  FieldDef(
    label: '最小回抽行程',
    key: 'filament_retraction_minimum_travel',
    unit: 'mm',
    tooltip: '最小回抽行程（官方默认 nil）',
  ),
  // 新增：filament_retract_length_nc
  FieldDef(
    label: '回抽长度（NC）',
    key: 'filament_retract_length_nc',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '回抽长度 NC（官方默认 14）',
  ),
  FieldDef(
    label: '擦拭',
    key: 'filament_wipe',
    isSwitch: true,
    tooltip: '擦拭（官方默认 nil）',
  ),
  FieldDef(
    label: '擦拭距离',
    key: 'filament_wipe_distance',
    unit: 'mm',
    tooltip: '擦拭距离（官方默认 nil）',
  ),
  FieldDef(
    label: 'Z 跳高',
    key: 'filament_z_hop',
    unit: 'mm',
    tooltip: 'Z 跳高（官方默认 nil）',
  ),
  FieldDef(
    label: 'Z 跳高类型',
    key: 'filament_z_hop_types',
    tooltip: 'Z 跳高类型（官方默认 nil，表示继承机器设置）',
    // 修正：加入 'nil' 选项以匹配官方 JSON 默认值
    options: ['nil', 'Auto Lift', 'None', 'Normal Lift'],
  ),
  FieldDef(
    label: '换料回抽距离',
    key: 'filament_retraction_distances_when_cut',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '换料回抽距离（官方默认 nil）',
  ),
  FieldDef(
    label: '换料回抽距离（EC）',
    key: 'filament_retraction_distances_when_ec',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '换料回抽距离 EC（官方默认 nil）',
  ),
  FieldDef(
    label: '长回抽换料',
    key: 'filament_long_retractions_when_cut',
    level: ParamLevel.developer,
    tooltip: '长回抽换料（官方默认 nil）',
  ),
  FieldDef(
    label: '长回抽（EC）',
    key: 'filament_long_retractions_when_ec',
    level: ParamLevel.developer,
    tooltip: '长回抽 EC（官方默认 nil）',
  ),
  FieldDef(
    label: '长回抽外部（EC）',
    key: 'long_retractions_when_ec',
    level: ParamLevel.developer,
    tooltip: '长回抽外部 EC（独立字段，无 filament_ 前缀，官方默认 nil）',
  ),
  FieldDef(
    label: '回抽距离外部（EC）',
    key: 'retraction_distances_when_ec',
    level: ParamLevel.developer,
    tooltip: '回抽距离外部 EC（独立字段，无 filament_ 前缀，官方默认 nil）',
  ),
  // ===== 斜拼接缝 =====
  FieldDef(
    section: '斜拼接缝',
    label: '耗材斜拼接缝类型',
    key: 'filament_scarf_seam_type',
    tooltip: '耗材斜拼接缝类型（官方默认 none）',
    options: ['none', 'contour', 'hole'],
  ),
  FieldDef(
    label: '耗材斜拼高度',
    key: 'filament_scarf_height',
    tooltip: '耗材斜拼高度（官方默认 10%）',
  ),
  FieldDef(
    label: '耗材斜拼间隔',
    key: 'filament_scarf_gap',
    tooltip: '耗材斜拼间隔（官方默认 0%）',
  ),
  FieldDef(
    label: '耗材斜拼长度',
    key: 'filament_scarf_length',
    unit: 'mm',
    tooltip: '耗材斜拼长度（官方默认 10）',
  ),
  // ===== 擦料塔相关（耗材侧） =====
  FieldDef(
    section: '擦料塔',
    label: '擦料塔前冷却',
    key: 'filament_cooling_before_tower',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '擦料塔前冷却（官方默认 0）',
  ),
  FieldDef(
    label: '擦料塔预加热温差',
    key: 'filament_preheat_temperature_delta',
    unit: '°C',
    level: ParamLevel.developer,
    tooltip: '擦料塔预加热温差（官方默认 0）',
  ),
  FieldDef(
    label: '擦料塔接触面预挤出距离',
    key: 'filament_tower_interface_pre_extrusion_dist',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '擦料塔接触面预挤出距离（官方默认 10）',
  ),
  FieldDef(
    label: '擦料塔接触面预挤出长度',
    key: 'filament_tower_interface_pre_extrusion_length',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '擦料塔接触面预挤出长度（官方默认 0）',
  ),
  FieldDef(
    label: '擦料塔熨烫区域',
    key: 'filament_tower_ironing_area',
    unit: 'mm²',
    level: ParamLevel.developer,
    tooltip: '擦料塔熨烫区域（官方默认 4）',
  ),
  FieldDef(
    label: '擦料塔接触面冲洗体积',
    key: 'filament_tower_interface_purge_volume',
    unit: 'mm³',
    level: ParamLevel.developer,
    tooltip: '擦料塔接触面冲洗体积（官方默认 20）',
  ),
  FieldDef(
    label: '擦料塔接触面打印温度',
    key: 'filament_tower_interface_print_temp',
    unit: '°C',
    level: ParamLevel.developer,
    tooltip: '擦料塔接触面打印温度（官方默认 -1）',
  ),
  FieldDef(
    label: '换料顶出移动时间',
    key: 'filament_ramming_travel_time',
    unit: 's',
    level: ParamLevel.developer,
    tooltip: '换料顶出移动时间（官方默认 0）',
  ),
  FieldDef(
    label: '换料顶出移动时间（NC）',
    key: 'filament_ramming_travel_time_nc',
    unit: 's',
    level: ParamLevel.developer,
    tooltip: '换料顶出移动时间 NC（官方默认 0）',
  ),
  // ===== 预冷却 =====
  FieldDef(
    section: '预冷却',
    label: '预冷却温度',
    key: 'filament_pre_cooling_temperature',
    unit: '°C',
    level: ParamLevel.developer,
    tooltip: '预冷却温度（官方默认 0）',
  ),
  FieldDef(
    label: '预冷却温度（NC）',
    key: 'filament_pre_cooling_temperature_nc',
    unit: '°C',
    level: ParamLevel.developer,
    tooltip: '预冷却温度 NC（官方默认 0）',
  ),
  FieldDef(
    label: '耗材冲洗温度',
    key: 'filament_flush_temp',
    unit: '°C',
    level: ParamLevel.developer,
    tooltip: '耗材冲洗温度（官方默认 0）',
  ),
  FieldDef(
    label: '耗材冲洗温度（快速）',
    key: 'filament_flush_temp_fast',
    unit: '°C',
    level: ParamLevel.developer,
    tooltip: '耗材冲洗温度-快速（官方默认 0）',
  ),
  // ===== 烘干 =====
  FieldDef(
    section: '烘干',
    label: 'AMS 烘干限制',
    key: 'filament_dev_ams_drying_ams_limitations',
    level: ParamLevel.developer,
    tooltip: 'AMS 烘干限制（官方默认 1）',
  ),
  FieldDef(
    label: '热变形温度',
    key: 'filament_dev_ams_drying_heat_distortion_temperature',
    unit: '°C',
    tooltip: '热变形温度（官方默认 45.0）',
  ),
  FieldDef(
    label: 'AMS 烘干温度',
    key: 'filament_dev_ams_drying_temperature',
    unit: '°C',
    tooltip: 'AMS 烘干温度（官方默认 40.0）',
  ),
  FieldDef(
    label: 'AMS 烘干时间',
    key: 'filament_dev_ams_drying_time',
    unit: 'h',
    tooltip: 'AMS 烘干时间（官方默认 8.0）',
  ),
  FieldDef(
    label: '腔体烘干床温',
    key: 'filament_dev_chamber_drying_bed_temperature',
    unit: '°C',
    tooltip: '腔体烘干床温（官方默认 90.0）',
  ),
  FieldDef(
    label: '腔体烘干时间',
    key: 'filament_dev_chamber_drying_time',
    unit: 'h',
    tooltip: '腔体烘干时间（官方默认 12.0）',
  ),
  FieldDef(
    label: '烘干冷却温度',
    key: 'filament_dev_drying_cooling_temperature',
    unit: '°C',
    tooltip: '烘干冷却温度（官方默认 35.0）',
  ),
  FieldDef(
    label: '软化温度',
    key: 'filament_dev_drying_softening_temperature',
    unit: '°C',
    tooltip: '软化温度（官方默认 40.0）',
  ),
  // ===== 耗材属性 =====
  FieldDef(
    section: '耗材属性',
    label: '耗材类型',
    key: 'filament_type',
    isNumeric: false,
    tooltip: '耗材类型（官方默认 PLA）',
  ),
  FieldDef(
    label: '耗材厂商',
    key: 'filament_vendor',
    isNumeric: false,
    tooltip: '耗材厂商（官方默认 Generic）',
  ),
  FieldDef(
    label: '耗材密度',
    key: 'filament_density',
    unit: 'g/cm³',
    tooltip: '耗材密度（官方默认 0）',
  ),
  FieldDef(
    label: '耗材成本',
    key: 'filament_cost',
    tooltip: '耗材成本（官方默认 0）',
  ),
  FieldDef(
    label: '耗材直径',
    key: 'filament_diameter',
    unit: 'mm',
    tooltip: '耗材直径（官方默认 1.75）',
  ),
  FieldDef(
    label: '收缩率',
    key: 'filament_shrink',
    tooltip: '收缩率（官方默认 100%）',
  ),
  FieldDef(
    label: '可溶性',
    key: 'filament_soluble',
    isSwitch: true,
    tooltip: '可溶性（官方默认 0）',
  ),
  FieldDef(
    label: '支撑材料',
    key: 'filament_is_support',
    isSwitch: true,
    tooltip: '支撑材料（官方默认 0）',
  ),
  FieldDef(
    label: '可打印',
    key: 'filament_printable',
    tooltip: '可打印（官方默认 3）',
  ),
  FieldDef(
    label: '需要喷嘴硬度',
    key: 'required_nozzle_HRC',
    tooltip: '需要喷嘴硬度 HRC（官方默认 3）',
  ),
  FieldDef(
    label: '挤出机兼容性',
    key: 'filament_extruder_compatibility',
    level: ParamLevel.developer,
    tooltip: '挤出机兼容性（官方默认 0）',
  ),
  FieldDef(
    label: '挤出机变体',
    key: 'filament_extruder_variant',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '挤出机变体（官方默认 Direct Drive Standard）',
  ),
  FieldDef(
    label: '金属粘性',
    key: 'filament_metal_stickiness',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '金属粘性（官方默认 None）',
    // 补充 options：JSON 中出现 None/High 两种值
    options: ['None', 'High'],
  ),
  // 新增：耗材粘性分类码（filament_adhesiveness_category）
  // 该字段在 fdm_filament_common.json 中不存在，但出现在全部 8 个具体耗材预设中
  // 值为数字字符串编码：PLA=100, ABS/ASA=200, PETG=300, PA=400, PC=500, TPU=600, PVA=704
  FieldDef(
    label: '耗材粘性分类',
    key: 'filament_adhesiveness_category',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip:
        '耗材粘性分类码（PLA=100/ABS·ASA=200/PETG=300/PA=400/PC=500/TPU=600/PVA=704）',
  ),
  FieldDef(
    label: 'Z 向冲击强度',
    key: 'impact_strength_z',
    level: ParamLevel.developer,
    tooltip: 'Z 向冲击强度（官方默认 10）',
  ),
  FieldDef(
    label: '圆补偿速度',
    key: 'circle_compensation_speed',
    unit: 'mm/s',
    level: ParamLevel.developer,
    tooltip: '圆补偿速度（官方默认 200）',
  ),
  // 新增：圆补偿/孔补偿系数系列（A+B 全做，耗材侧也支持配置）
  // 这些字段来自 fdm_filament_common.json，原本只在 otherFields 中定义，
  // 为满足"耗材参数 100% 覆盖"要求，此处补充到 filamentFields。
  FieldDef(
    label: '圆补偿系数 1（耗材）',
    key: 'counter_coef_1',
    level: ParamLevel.developer,
    tooltip: '圆补偿系数 1（耗材侧，官方默认 0）',
  ),
  FieldDef(
    label: '圆补偿系数 2（耗材）',
    key: 'counter_coef_2',
    level: ParamLevel.developer,
    tooltip: '圆补偿系数 2（耗材侧，官方默认 0.008）',
  ),
  FieldDef(
    label: '圆补偿系数 3（耗材）',
    key: 'counter_coef_3',
    level: ParamLevel.developer,
    tooltip: '圆补偿系数 3（耗材侧，官方默认 -0.041）',
  ),
  FieldDef(
    label: '圆补偿上限（耗材）',
    key: 'counter_limit_max',
    level: ParamLevel.developer,
    tooltip: '圆补偿上限（耗材侧，官方默认 0.033）',
  ),
  FieldDef(
    label: '圆补偿下限（耗材）',
    key: 'counter_limit_min',
    level: ParamLevel.developer,
    tooltip: '圆补偿下限（耗材侧，官方默认 -0.035）',
  ),
  FieldDef(
    label: '孔补偿系数 1（耗材）',
    key: 'hole_coef_1',
    level: ParamLevel.developer,
    tooltip: '孔补偿系数 1（耗材侧，官方默认 0）',
  ),
  FieldDef(
    label: '孔补偿系数 2（耗材）',
    key: 'hole_coef_2',
    level: ParamLevel.developer,
    tooltip: '孔补偿系数 2（耗材侧，官方默认 -0.008）',
  ),
  FieldDef(
    label: '孔补偿系数 3（耗材）',
    key: 'hole_coef_3',
    level: ParamLevel.developer,
    tooltip: '孔补偿系数 3（耗材侧，官方默认 0.23415）',
  ),
  FieldDef(
    label: '孔补偿上限（耗材）',
    key: 'hole_limit_max',
    level: ParamLevel.developer,
    tooltip: '孔补偿上限（耗材侧，官方默认 0.22）',
  ),
  FieldDef(
    label: '孔补偿下限（耗材）',
    key: 'hole_limit_min',
    level: ParamLevel.developer,
    tooltip: '孔补偿下限（耗材侧，官方默认 0.088）',
  ),
  FieldDef(
    label: '直径限制（耗材）',
    key: 'diameter_limit',
    level: ParamLevel.developer,
    tooltip: '直径限制（耗材侧，官方默认 50）',
  ),
  FieldDef(
    label: '原料安全',
    key: 'filament_ingredients_safe',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '原料安全（官方默认 1）',
  ),
  FieldDef(
    label: '排放安全',
    key: 'filament_emission_safe',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '排放安全（官方默认 1）',
  ),
  FieldDef(
    label: '接触安全',
    key: 'filament_contact_safe',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '接触安全（官方默认 1）',
  ),
  FieldDef(
    label: '耗材起始 G-code',
    key: 'filament_start_gcode',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '耗材起始 G-code',
  ),
  FieldDef(
    label: '耗材结束 G-code',
    key: 'filament_end_gcode',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '耗材结束 G-code',
  ),
];

// ===========================================================================
// 打印机参数（machineFields）—— 新增
// 对照 fdm_machine_common.json
// ===========================================================================

const machineFields = <FieldDef>[
  // ===== 喷嘴参数 =====
  FieldDef(
    section: '喷嘴参数',
    label: '喷嘴直径',
    key: 'nozzle_diameter',
    unit: 'mm',
    level: ParamLevel.basic,
    tooltip: '喷嘴直径（官方默认 0.4）',
  ),
  FieldDef(
    label: '打印机变体',
    key: 'printer_variant',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '打印机变体（官方默认 0.4）',
  ),
  FieldDef(
    label: '喷嘴高度',
    key: 'nozzle_height',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '喷嘴高度（官方默认 4）',
  ),
  FieldDef(
    label: '最大层高',
    key: 'max_layer_height',
    unit: 'mm',
    tooltip: '最大层高（官方默认 0.28）',
  ),
  FieldDef(
    label: '最小层高',
    key: 'min_layer_height',
    unit: 'mm',
    tooltip: '最小层高（官方默认 0.08）',
  ),
  FieldDef(
    label: '挤出机最大喷嘴数',
    key: 'extruder_max_nozzle_count',
    tooltip: '挤出机最大喷嘴数（官方默认 1）',
  ),
  FieldDef(
    label: '喷嘴冲洗数据集',
    key: 'nozzle_flush_dataset',
    level: ParamLevel.developer,
    tooltip: '喷嘴冲洗数据集（官方默认 0）',
  ),
  // 新增：喷嘴类型（nozzle_type），出现在全部 9 个具体打印机预设
  FieldDef(
    label: '喷嘴类型',
    key: 'nozzle_type',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '喷嘴类型（hardened_steel 硬化钢 / stainless_steel 不锈钢）',
    options: ['hardened_steel', 'stainless_steel'],
  ),
  // 新增：喷嘴容量（nozzle_volume），出现在全部 9 个具体打印机预设
  FieldDef(
    label: '喷嘴容量',
    key: 'nozzle_volume',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '喷嘴容量（数组，如 ["107","107"]，H2D 多挤出机为 5 元素数组）',
  ),
  // ===== 打印床尺寸 =====
  FieldDef(
    section: '打印床尺寸',
    label: '可打印高度',
    key: 'printable_height',
    unit: 'mm',
    level: ParamLevel.basic,
    tooltip: '可打印高度（官方默认 250）',
  ),
  FieldDef(
    label: '最佳对象位置',
    key: 'best_object_pos',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '最佳对象位置（官方默认 0.5x0.5）',
  ),
  FieldDef(
    label: '挤出机偏移',
    key: 'extruder_offset',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '挤出机偏移（官方默认 0x0）',
  ),
  FieldDef(
    label: '挤出机颜色',
    key: 'extruder_colour',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '挤出机颜色（官方默认 #FCE94F）',
  ),
  FieldDef(
    label: '包裹排除区域',
    key: 'wrapping_exclude_area',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '包裹排除区域',
  ),
  // 新增：可打印区域（printable_area），出现在 A1 mini/H2D/H2D Pro 等预设
  FieldDef(
    label: '可打印区域',
    key: 'printable_area',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '可打印区域（多边形坐标点列表，如 ["0x0","180x0","180x180","0x180"]）',
  ),
  // 新增：打印床排除区域（bed_exclude_area），出现在 X1C/P1S/A1 等预设
  FieldDef(
    label: '打印床排除区域',
    key: 'bed_exclude_area',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '打印床排除区域（不可打印区域坐标点列表）',
  ),
  // 新增：挤出机可打印区域（extruder_printable_area），H2D/H2D Pro 多挤出机场景
  FieldDef(
    label: '挤出机可打印区域',
    key: 'extruder_printable_area',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '挤出机可打印区域（多挤出机各自的可打印范围）',
  ),
  // 新增：抬头检测区域（head_wrap_detect_zone），A1/A1 mini 专用
  FieldDef(
    label: '抬头检测区域',
    key: 'head_wrap_detect_zone',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '抬头检测区域（A1/A1 mini 专用，防止撞机）',
  ),
  // ===== 机械限制 - 最大速度 =====
  FieldDef(
    section: '机械限制-最大速度',
    label: 'X 轴最大速度',
    key: 'machine_max_speed_x',
    unit: 'mm/s',
    tooltip: 'X 轴最大速度（官方默认 500）',
  ),
  FieldDef(
    label: 'Y 轴最大速度',
    key: 'machine_max_speed_y',
    unit: 'mm/s',
    tooltip: 'Y 轴最大速度（官方默认 500）',
  ),
  FieldDef(
    label: 'Z 轴最大速度',
    key: 'machine_max_speed_z',
    unit: 'mm/s',
    tooltip: 'Z 轴最大速度（官方默认 10）',
  ),
  FieldDef(
    label: 'E 轴最大速度',
    key: 'machine_max_speed_e',
    unit: 'mm/s',
    tooltip: 'E 轴最大速度（官方默认 60）',
  ),
  // ===== 机械限制 - 最大加速度 =====
  FieldDef(
    section: '机械限制-最大加速度',
    label: 'X 轴最大加速度',
    key: 'machine_max_acceleration_x',
    unit: 'mm/s²',
    tooltip: 'X 轴最大加速度（官方默认 10000）',
  ),
  FieldDef(
    label: 'Y 轴最大加速度',
    key: 'machine_max_acceleration_y',
    unit: 'mm/s²',
    tooltip: 'Y 轴最大加速度（官方默认 10000）',
  ),
  FieldDef(
    label: 'Z 轴最大加速度',
    key: 'machine_max_acceleration_z',
    unit: 'mm/s²',
    tooltip: 'Z 轴最大加速度（官方默认 100）',
  ),
  FieldDef(
    label: 'E 轴最大加速度',
    key: 'machine_max_acceleration_e',
    unit: 'mm/s²',
    tooltip: 'E 轴最大加速度（官方默认 5000）',
  ),
  FieldDef(
    label: '挤出时最大加速度',
    key: 'machine_max_acceleration_extruding',
    unit: 'mm/s²',
    tooltip: '挤出时最大加速度（官方默认 10000）',
  ),
  FieldDef(
    label: '回抽时最大加速度',
    key: 'machine_max_acceleration_retracting',
    unit: 'mm/s²',
    tooltip: '回抽时最大加速度（官方默认 1000）',
  ),
  // 新增：空驶最大加速度（machine_max_acceleration_travel）
  FieldDef(
    label: '空驶最大加速度',
    key: 'machine_max_acceleration_travel',
    unit: 'mm/s²',
    level: ParamLevel.developer,
    tooltip: '空驶最大加速度（官方默认 9000）',
  ),
  // ===== 机械限制 - 抖动（Jerk） =====
  FieldDef(
    section: '机械限制-抖动',
    label: 'X 轴最大抖动',
    key: 'machine_max_jerk_x',
    unit: 'mm/s',
    tooltip: 'X 轴最大抖动（官方默认 8）',
  ),
  FieldDef(
    label: 'Y 轴最大抖动',
    key: 'machine_max_jerk_y',
    unit: 'mm/s',
    tooltip: 'Y 轴最大抖动（官方默认 8）',
  ),
  FieldDef(
    label: 'Z 轴最大抖动',
    key: 'machine_max_jerk_z',
    unit: 'mm/s',
    tooltip: 'Z 轴最大抖动（官方默认 3）',
  ),
  FieldDef(
    label: 'E 轴最大抖动',
    key: 'machine_max_jerk_e',
    unit: 'mm/s',
    tooltip: 'E 轴最大抖动（官方默认 5）',
  ),
  // ===== 机械限制 - 力与质量 =====
  FieldDef(
    section: '机械限制-力与质量',
    label: 'Y 轴最大力',
    key: 'machine_max_force_Y',
    level: ParamLevel.developer,
    tooltip: 'Y 轴最大力（官方默认 0）',
  ),
  FieldDef(
    label: '床质量 Y',
    key: 'machine_bed_mass_Y',
    level: ParamLevel.developer,
    tooltip: '床质量 Y（官方默认 0）',
  ),
  FieldDef(
    label: '最大打印质量',
    key: 'machine_max_printed_mass',
    unit: 'g',
    level: ParamLevel.developer,
    tooltip: '最大打印质量（官方默认 0）',
  ),
  FieldDef(
    label: '最小挤出速率',
    key: 'machine_min_extruding_rate',
    level: ParamLevel.developer,
    tooltip: '最小挤出速率（官方默认 0）',
  ),
  FieldDef(
    label: '最小空驶速率',
    key: 'machine_min_travel_rate',
    level: ParamLevel.developer,
    tooltip: '最小空驶速率（官方默认 0）',
  ),
  // ===== 回抽（打印机侧全局） =====
  FieldDef(
    section: '回抽',
    label: '回抽长度',
    key: 'retraction_length',
    unit: 'mm',
    tooltip: '打印机回抽长度（官方默认 5）',
  ),
  FieldDef(
    label: '回抽速度',
    key: 'retraction_speed',
    unit: 'mm/s',
    tooltip: '打印机回抽速度（官方默认 60）',
  ),
  FieldDef(
    label: '回退速度',
    key: 'deretraction_speed',
    unit: 'mm/s',
    tooltip: '回退速度（官方默认 40）',
  ),
  FieldDef(
    label: '最小回抽行程',
    key: 'retraction_minimum_travel',
    unit: 'mm',
    tooltip: '最小回抽行程（官方默认 2）',
  ),
  FieldDef(
    label: '擦拭前回抽',
    key: 'retract_before_wipe',
    tooltip: '擦拭前回抽（官方默认 70%）',
  ),
  FieldDef(
    label: '换层回抽',
    key: 'retract_when_changing_layer',
    isSwitch: true,
    tooltip: '换层回抽（官方默认 1）',
  ),
  FieldDef(
    label: 'Z 跳高',
    key: 'z_hop',
    unit: 'mm',
    tooltip: 'Z 跳高（官方默认 0）',
  ),
  FieldDef(
    label: '擦拭',
    key: 'wipe',
    isSwitch: true,
    tooltip: '擦拭（官方默认 1）',
  ),
  FieldDef(
    label: '回抽重启额外量',
    key: 'retract_restart_extra',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '回抽重启额外量（官方默认 0）',
  ),
  FieldDef(
    label: '换工具回抽长度',
    key: 'retract_length_toolchange',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '换工具回抽长度（官方默认 1）',
  ),
  FieldDef(
    label: '换工具回抽重启额外量',
    key: 'retract_restart_extra_toolchange',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '换工具回抽重启额外量（官方默认 0）',
  ),
  FieldDef(
    label: '换料回抽距离',
    key: 'retraction_distances_when_cut',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '换料回抽距离（官方默认 18）',
  ),
  FieldDef(
    label: '抓取长度',
    key: 'grab_length',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '抓取长度（官方默认 0）',
  ),
  // 新增：回抽提升下限（retract_lift_below）
  FieldDef(
    label: '回抽提升下限',
    key: 'retract_lift_below',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '回抽提升下限（仅在此高度以下执行回抽提升，X1C 默认 249）',
  ),
  // 新增：回抽提升上限（retract_lift_above）
  FieldDef(
    label: '回抽提升上限',
    key: 'retract_lift_above',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '回抽提升上限（仅在此高度以上执行回抽提升，官方默认 0）',
  ),
  // 新增：擦拭距离（wipe_distance）
  FieldDef(
    label: '擦拭距离',
    key: 'wipe_distance',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '擦拭距离（官方默认 2）',
  ),
  // 新增：Z 跳高类型（z_hop_types）
  FieldDef(
    label: 'Z 跳高类型',
    key: 'z_hop_types',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: 'Z 跳高类型（官方默认 Auto Lift）',
    options: ['Auto Lift', 'Normal Lift', 'None'],
  ),
  // ===== 挤出机间隙 =====
  FieldDef(
    section: '挤出机间隙',
    label: '挤出机到顶盖间隙高度',
    key: 'extruder_clearance_height_to_lid',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '挤出机到顶盖间隙高度（官方默认 140）',
  ),
  FieldDef(
    label: '挤出机到导杆间隙高度',
    key: 'extruder_clearance_height_to_rod',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '挤出机到导杆间隙高度（官方默认 34）',
  ),
  FieldDef(
    label: '挤出机最大半径',
    key: 'extruder_clearance_max_radius',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '挤出机最大半径（官方默认 65）',
  ),
  FieldDef(
    label: '挤出机到导杆距离',
    key: 'extruder_clearance_dist_to_rod',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '挤出机到导杆距离（官方默认 33）',
  ),
  FieldDef(
    label: '挤出机高度间隙',
    key: 'extruder_height_gap',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '挤出机高度间隙（官方默认 0）',
  ),
  // 新增：挤出机间隙半径（extruder_clearance_radius），H2D/H2D Pro 专用
  FieldDef(
    label: '挤出机间隙半径',
    key: 'extruder_clearance_radius',
    unit: 'mm',
    level: ParamLevel.developer,
    tooltip: '挤出机间隙半径（H2D/H2D Pro 专用，官方默认 49）',
  ),
  // ===== 挤出机变体（新增 section） =====
  FieldDef(
    section: '挤出机变体',
    label: '挤出机变体列表',
    key: 'extruder_variant_list',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '挤出机变体列表（逗号分隔，如 Direct Drive Standard,Direct Drive High Flow）',
  ),
  // 新增：打印机挤出机 ID（printer_extruder_id）
  FieldDef(
    label: '打印机挤出机 ID',
    key: 'printer_extruder_id',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '打印机挤出机 ID（数组，如 ["1","1"]，H2D 多挤出机为 5 元素）',
  ),
  // 新增：打印机挤出机变体（printer_extruder_variant）
  FieldDef(
    label: '打印机挤出机变体',
    key: 'printer_extruder_variant',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '打印机挤出机变体（Direct Drive Standard/High Flow/TPU High Flow）',
    options: [
      'Direct Drive Standard',
      'Direct Drive High Flow',
      'Direct Drive TPU High Flow',
    ],
  ),
  // ===== 功能开关 =====
  FieldDef(
    section: '功能开关',
    label: '辅助风扇',
    key: 'auxiliary_fan',
    isSwitch: true,
    tooltip: '辅助风扇（官方默认 1）',
  ),
  FieldDef(
    label: '顺时针打印',
    key: 'print_in_clockwise',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '顺时针打印（官方默认 0）',
  ),
  FieldDef(
    label: '静音模式',
    key: 'silent_mode',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '静音模式（官方默认 0）',
  ),
  FieldDef(
    label: '单挤出机多材料',
    key: 'single_extruder_multi_material',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '单挤出机多材料（官方默认 1）',
  ),
  FieldDef(
    label: '首层扫描',
    key: 'scan_first_layer',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '首层扫描（官方默认 0）',
  ),
  FieldDef(
    label: '启用长回抽换料',
    key: 'enable_long_retraction_when_cut',
    // 修正：JSON 中实际有 "0"/"1"/"2" 三态值，isSwitch 无法表达第三态，改为下拉选项
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '启用长回抽换料（0=禁用/1=启用/2=自动，X1C/P1S 默认 2，X1E 默认 1）',
    options: ['0', '1', '2'],
  ),
  FieldDef(
    label: '长回抽换料',
    key: 'long_retractions_when_cut',
    level: ParamLevel.developer,
    tooltip: '长回抽换料（官方默认 0）',
  ),
  FieldDef(
    label: '启用预加热',
    key: 'enable_pre_heating',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '启用预加热（官方默认 0）',
  ),
  FieldDef(
    label: '支持空气过滤',
    key: 'support_air_filtration',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '支持空气过滤（官方默认 0）',
  ),
  FieldDef(
    label: '支持冷却过滤',
    key: 'support_cooling_filter',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '支持冷却过滤（官方默认 0）',
  ),
  FieldDef(
    label: '冷却过滤启用',
    key: 'cooling_filter_enabled',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '冷却过滤启用（官方默认 0）',
  ),
  FieldDef(
    label: '支持快速冲洗模式',
    key: 'support_fast_purge_mode',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '支持快速冲洗模式（官方默认 0）',
  ),
  FieldDef(
    label: '支持腔体温度控制',
    key: 'support_chamber_temp_control',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '支持腔体温度控制（官方默认 0）',
  ),
  FieldDef(
    label: '支持对象跳过冲洗',
    key: 'support_object_skip_flush',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '支持对象跳过冲洗（官方默认 0）',
  ),
  FieldDef(
    label: '按时间分组算法',
    key: 'group_algo_with_time',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '按时间分组算法（官方默认 0）',
  ),
  // 新增：最远点延时摄影（farthest_point_timelapse）
  FieldDef(
    label: '最远点延时摄影',
    key: 'farthest_point_timelapse',
    isSwitch: true,
    level: ParamLevel.developer,
    tooltip: '最远点延时摄影（X1C/P1S/H2D 等支持，A1/A1 mini 不支持，官方默认 1）',
  ),
  // ===== 加热/冷却速率 =====
  FieldDef(
    section: '加热冷却',
    label: '热端冷却速率',
    key: 'hotend_cooling_rate',
    level: ParamLevel.developer,
    tooltip: '热端冷却速率（官方默认 2）',
  ),
  FieldDef(
    label: '热端加热速率',
    key: 'hotend_heating_rate',
    level: ParamLevel.developer,
    tooltip: '热端加热速率（官方默认 2）',
  ),
  // ===== 时间参数 =====
  FieldDef(
    section: '时间参数',
    label: '机器换料时间',
    key: 'machine_load_filament_time',
    unit: 's',
    level: ParamLevel.developer,
    tooltip: '机器换料时间（官方默认 29）',
  ),
  FieldDef(
    label: '机器退料时间',
    key: 'machine_unload_filament_time',
    unit: 's',
    level: ParamLevel.developer,
    tooltip: '机器退料时间（官方默认 29）',
  ),
  FieldDef(
    label: '机器换挤出机时间',
    key: 'machine_switch_extruder_time',
    unit: 's',
    level: ParamLevel.developer,
    tooltip: '机器换挤出机时间（官方默认 0）',
  ),
  FieldDef(
    label: '机器热端更换时间',
    key: 'machine_hotend_change_time',
    unit: 's',
    level: ParamLevel.developer,
    tooltip: '机器热端更换时间（官方默认 0）',
  ),
  FieldDef(
    label: '机器准备补偿时间',
    key: 'machine_prepare_compensation_time',
    unit: 's',
    level: ParamLevel.developer,
    tooltip: '机器准备补偿时间（官方默认 260）',
  ),
  // 新增：换挤出机回退速度（deretract_speed_extruder_change），仅 H2D
  FieldDef(
    label: '换挤出机回退速度',
    key: 'deretract_speed_extruder_change',
    unit: 'mm/s',
    level: ParamLevel.developer,
    tooltip: '换挤出机回退速度（H2D 多挤出机专用，官方默认 15）',
  ),
  FieldDef(
    label: '主挤出机 ID',
    key: 'master_extruder_id',
    level: ParamLevel.developer,
    tooltip: '主挤出机 ID（官方默认 1）',
  ),
  // ===== G-code 与机器类型 =====
  FieldDef(
    section: 'G-code',
    label: 'G-code 类型',
    key: 'gcode_flavor',
    isNumeric: false,
    level: ParamLevel.basic,
    tooltip: 'G-code 类型（官方默认 marlin）',
    options: ['marlin', 'klipper', 'reprap'],
  ),
  FieldDef(
    label: '打印机结构',
    key: 'printer_structure',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '打印机结构（官方默认 corexy）',
    options: ['corexy', 'i3', 'other'],
  ),
  FieldDef(
    label: '打印机技术',
    key: 'printer_technology',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '打印机技术（官方默认 FFF）',
  ),
  FieldDef(
    label: '风扇方向',
    key: 'fan_direction',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '风扇方向（官方默认 undefine，X1C/P1S/H2D 等为 left）',
    // 修正：JSON 中只有 undefine/left 两种值，改为下拉选项
    options: ['undefine', 'left'],
  ),
  FieldDef(
    label: '默认打印配置',
    key: 'default_print_profile',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '默认打印配置（官方默认 0.16mm Optimal @BBL X1C）',
  ),
  FieldDef(
    label: '默认耗材配置',
    key: 'default_filament_profile',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '默认耗材配置（官方默认 Generic PLA @BBL X1C）',
  ),
  FieldDef(
    label: '向上兼容机器',
    key: 'upward_compatible_machine',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '向上兼容机器',
  ),
  FieldDef(
    label: '机器起始 G-code',
    key: 'machine_start_gcode',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '机器起始 G-code',
  ),
  FieldDef(
    label: '机器结束 G-code',
    key: 'machine_end_gcode',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '机器结束 G-code',
  ),
  FieldDef(
    label: '延时摄影 G-code',
    key: 'time_lapse_gcode',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '延时摄影 G-code（官方默认空）',
  ),
  FieldDef(
    label: '包裹检测 G-code',
    key: 'wrapping_detection_gcode',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '包裹检测 G-code（官方默认空）',
  ),
  FieldDef(
    label: '换料 G-code',
    key: 'change_filament_gcode',
    isNumeric: false,
    level: ParamLevel.developer,
    tooltip: '换料 G-code（官方默认空）',
  ),
];

// ===========================================================================
// 聚合导出
// ===========================================================================

/// 工艺参数全部字段（5 组合并），用于遍历控制器与导出。
final allProcessFields = <FieldDef>[
  ...qualityFields,
  ...strengthFields,
  ...speedFields,
  ...supportFields,
  ...otherFields,
];

/// 默认材料选项（耗材库加载失败时的兜底）。
const defaultMaterialOptions = ['Generic PLA'];

/// 场景选项。
const sceneOptions = ['手办', '功能件', '柔性件', '快速打印', '超高精度', '高温', '其他'];

/// 预设标签候选列表（用户可多选，用于参数广场筛选与展示）。
const presetTagOptions = [
  '手办',
  '功能件',
  '快速',
  '高精度',
  '高温',
  '柔性',
  '低耗',
  '静音',
  '高强度',
  '大尺寸',
  '小模型',
  '推荐',
];

/// 喷嘴直径选项。
const nozzleDiameterOptions = ['0.2', '0.4', '0.6', '0.8'];
