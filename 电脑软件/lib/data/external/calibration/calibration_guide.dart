/// 多功能测试模型说明 + 测试维度数据。
///
/// 基于项目内 `校准文件/测试模型.txt` 的说明：
/// 这是一款多功能测试模型，一个模型覆盖几乎所有重要打印属性。
/// 用户用 BambuStudio 打开内置的 3mf 文件 → 切片 → 打印 → 观察 → 调参。
library;

/// 测试模型整体描述。
const String kModelDescription = '''
这款多功能测试模型旨在快速、清晰地检查 3D 打印机的几乎所有重要打印属性，无需进行多次单独测试。非常适合初始校准、测试新材料或比较不同的打印配置文件（例如质量与速度）。

无论您是刚刚重建打印机，插入新的打印材料，还是只想优化它——此测试块都能可靠地向您显示设置中的弱点。''';

/// 内置 3mf 文件的 assets 路径。
const String kModelAssetPath = 'assets/calibration/test_model.3mf';

/// 7 个测试维度。
class TestDimension {
  final String name;
  final String description;

  /// 观察到问题时，应该调整的 BambuStudio 预设字段名。
  /// 一个维度可能关联多个字段（用户可同时调多个）。
  final List<PresetField> relatedFields;

  const TestDimension({
    required this.name,
    required this.description,
    required this.relatedFields,
  });
}

/// BambuStudio 预设字段元数据。
class PresetField {
  /// BambuStudio 预设 JSON 里的字段名
  final String key;

  /// 显示名
  final String label;

  /// 单位（°C / mm / mm³/s / mm/s / 无）
  final String unit;

  /// 简要说明（调这个字段能改善什么）
  final String hint;

  const PresetField({
    required this.key,
    required this.label,
    required this.unit,
    required this.hint,
  });
}

/// 所有可调参数（去重后，UI 里作为一个表单列出）。
/// 用户填了哪个就写哪个，留空的不写。
///
/// 注意：这里只包含 filament 预设的字段（耗材相关）。
/// outer_wall_speed 等打印过程参数属于 process 预设（user\<id>\process\），
/// 不在 filament 预设里，写入 filament 预设会被 BambuStudio 忽略，故不列出。
const List<PresetField> kAllPresetFields = [
  PresetField(
    key: 'nozzle_temperature',
    label: '喷嘴温度',
    unit: '°C',
    hint: '层间附着力差/温度过低：提高；表面糊化/过热：降低',
  ),
  PresetField(
    key: 'filament_flow_ratio',
    label: '流量比例',
    unit: '',
    hint: '表面凸起/过挤：降低（<1.0）；表面凹陷/欠料：提高（>1.0）',
  ),
  PresetField(
    key: 'filament_retraction_length',
    label: '回抽距离',
    unit: 'mm',
    hint: '拉丝严重：增大；拉料断料/孔洞：减小',
  ),
  PresetField(
    key: 'pressure_advance',
    label: '压力提前(PA)',
    unit: '',
    hint: '转角堆料：增大；转角欠料/圆角：减小',
  ),
  PresetField(
    key: 'filament_max_volumetric_speed',
    label: '最大流速',
    unit: 'mm³/s',
    hint: '高速欠料：降低；想提速：找到上限后填入',
  ),
];

/// 7 个测试维度（对应测试模型.txt 的说明）。
const List<TestDimension> kTestDimensions = [
  TestDimension(
    name: '悬垂测试（30°至90°）',
    description: '侧面向上延伸的斜坡显示打印机在不使用支撑的情况下打印错误或停滞的角度。适合调整冷却和打印速度。',
    relatedFields: [
      PresetField(
        key: 'nozzle_temperature',
        label: '喷嘴温度',
        unit: '°C',
        hint: '',
      ),
    ],
  ),
  TestDimension(
    name: '拉丝测试',
    description: '如果回缩设置不佳，独立的垂直柱会显示清晰可见的拉丝。这是测试回缩、温度和移动速度设置是否正确的理想方法。',
    relatedFields: [
      PresetField(
        key: 'filament_retraction_length',
        label: '回抽距离',
        unit: 'mm',
        hint: '',
      ),
      PresetField(
        key: 'nozzle_temperature',
        label: '喷嘴温度',
        unit: '°C',
        hint: '',
      ),
    ],
  ),
  TestDimension(
    name: '公差测试（0.05-0.30mm 间隙）',
    description: '六个间隙逐渐变窄的小型测试立方体检查打印机的精度。立方体能够移动表示高精度——立方体粘连则表明存在优化空间。',
    relatedFields: [
      PresetField(
        key: 'filament_flow_ratio',
        label: '流量比例',
        unit: '',
        hint: '',
      ),
    ],
  ),
  TestDimension(
    name: '桥接测试（50/75/90mm）',
    description: '背面的三个悬臂桥测试打印机桥接水平间隙的能力——不会下垂或拉丝。适合评估冷却和进料。',
    relatedFields: [
      PresetField(
        key: 'nozzle_temperature',
        label: '喷嘴温度',
        unit: '°C',
        hint: '',
      ),
      PresetField(
        key: 'filament_retraction_length',
        label: '回抽距离',
        unit: 'mm',
        hint: '',
      ),
    ],
  ),
  TestDimension(
    name: '球形杆（细节水平+悬垂）',
    description: '顶部带有半球形的小型杆检查打印机如何处理小型、复杂的几何形状和轻微的悬垂。适合微型模型的微调。',
    relatedFields: [],
  ),
  TestDimension(
    name: '垂直字体+Z轴分辨率',
    description: '"Z"形雕刻（20毫米深）提供有关水平细节再现的信息。侧面文字和线条有助于评估边缘锐度和层粘合。',
    relatedFields: [
      PresetField(
        key: 'nozzle_temperature',
        label: '喷嘴温度',
        unit: '°C',
        hint: '',
      ),
      PresetField(
        key: 'filament_flow_ratio',
        label: '流量比例',
        unit: '',
        hint: '',
      ),
    ],
  ),
  TestDimension(
    name: '凹槽、台阶和斜坡',
    description: '精细的水平台阶和倾斜表面显示层粘合和 Z 轴精度。Z 轴抖动或层高误差在这里变得可见。',
    relatedFields: [
      PresetField(
        key: 'nozzle_temperature',
        label: '喷嘴温度',
        unit: '°C',
        hint: '',
      ),
    ],
  ),
];
