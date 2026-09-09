// 耗材成本配置模型。
//
// 业务规则：同一品牌 + 材质 + 颜色 统一一个每公斤成本价。
// 切片时按 G-code 读到的 (vendor, materialType, colorHex) 三元组匹配，
// 找不到精确匹配时按 (vendor, materialType) 退化匹配，再找不到按 materialType 兜底。
//
// 数据库表结构事实来源：[AppDatabase._createFilamentCostConfigsTable] 的 raw SQL
// （见 lib/data/database/database.dart）。本文件字段与该 SQL 保持一致。

/// 耗材成本配置（每公斤单价）。
///
/// 匹配键：vendor + materialType + colorHex。
/// 任一字段为空表示通配（如 colorHex='' 表示该品牌该材质所有颜色共用一个价）。
class FilamentCostConfig {
  final int? id;
  final String vendor; // 厂家，如 "Bambu Lab"、"第三方"
  final String materialType; // 材质，如 "PLA"、"PETG"、"PLA-Silk"
  final String colorHex; // 颜色 HEX，如 "#FFFF00"；空串表示该材质所有颜色
  final double costPerKg; // 每公斤成本（元/kg）
  final String? note; // 备注（如"促销价"）
  final DateTime createdAt;
  final DateTime updatedAt;

  const FilamentCostConfig({
    this.id,
    required this.vendor,
    required this.materialType,
    required this.colorHex,
    required this.costPerKg,
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  FilamentCostConfig copyWith({
    int? id,
    String? vendor,
    String? materialType,
    String? colorHex,
    double? costPerKg,
    String? note,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return FilamentCostConfig(
      id: id ?? this.id,
      vendor: vendor ?? this.vendor,
      materialType: materialType ?? this.materialType,
      colorHex: colorHex ?? this.colorHex,
      costPerKg: costPerKg ?? this.costPerKg,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 估算成本（元）= grams / 1000 × costPerKg
  double costForGrams(double grams) => grams / 1000.0 * costPerKg;

  @override
  String toString() =>
      'FilamentCostConfig($vendor/$materialType/$colorHex: ¥$costPerKg/kg)';
}
