import '../../data/external/slicer/material_catalog_service.dart';

/// 农场入库专用的耗材类型目录。
///
/// 数据源只采用拓竹官方类型名称，并把品牌前缀从展示值中移除；农场库存
/// 中已经存在的自定义类型也会保留，但同样不会把品牌混进类型字段。
class FarmMaterialTypeCatalogService {
  FarmMaterialTypeCatalogService._();

  static Future<List<String>> load({
    Iterable<String> additionalTypes = const [],
  }) async {
    final catalog = await MaterialCatalogService.load();
    return compose(
      officialCatalog: catalog,
      additionalTypes: additionalTypes,
    );
  }

  static List<String> compose({
    required Iterable<String> officialCatalog,
    Iterable<String> additionalTypes = const [],
  }) {
    final valuesByKey = <String, String>{};

    void add(String raw, {String? manufacturer}) {
      final value = stripBrandPrefix(raw, manufacturer: manufacturer);
      if (value.isEmpty) return;
      valuesByKey.putIfAbsent(value.toLowerCase(), () => value);
    }

    for (final entry in officialCatalog) {
      if (!_isOfficialBambuEntry(entry)) continue;
      add(entry);
    }
    for (final entry in additionalTypes) {
      add(entry);
    }

    final result = valuesByKey.values.toList();
    result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  static String stripBrandPrefix(String value, {String? manufacturer}) {
    var trimmed = value.trim();
    if (trimmed.isEmpty) return '';

    final explicitBrand = manufacturer?.trim() ?? '';
    if (explicitBrand.isNotEmpty) {
      final prefix = '$explicitBrand ';
      if (trimmed.toLowerCase().startsWith(prefix.toLowerCase())) {
        trimmed = trimmed.substring(prefix.length).trim();
      }
    }

    final lower = trimmed.toLowerCase();
    const prefixes = <String>[
      'bambu lab ',
      'bambu ',
      'generic ',
      'esun ',
      'fiberon ',
      'overture ',
      'polylite ',
      'polyterra ',
      'sunlu ',
    ];
    for (final prefix in prefixes) {
      if (lower.startsWith(prefix)) {
        return trimmed.substring(prefix.length).trim();
      }
    }
    if (trimmed.startsWith('拓竹')) return trimmed.substring(2).trim();
    return trimmed;
  }

  static bool _isOfficialBambuEntry(String value) {
    final lower = value.trim().toLowerCase();
    return lower.startsWith('bambu ') || lower.startsWith('bambu lab ');
  }
}
