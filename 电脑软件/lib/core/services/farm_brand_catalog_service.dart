class FarmBrandOption {
  const FarmBrandOption({required this.code, required this.label});

  final String code;
  final String label;
}

class FarmBrandCatalogService {
  FarmBrandCatalogService._();

  static const known = <FarmBrandOption>[
    FarmBrandOption(code: 'bambu_lab', label: '拓竹'),
    FarmBrandOption(code: 'generic', label: 'Generic'),
    FarmBrandOption(code: 'esun', label: 'eSUN'),
    FarmBrandOption(code: 'fiberon', label: 'Fiberon'),
    FarmBrandOption(code: 'overture', label: 'Overture'),
    FarmBrandOption(code: 'polylite', label: 'PolyLite'),
    FarmBrandOption(code: 'polyterra', label: 'PolyTerra'),
    FarmBrandOption(code: 'sunlu', label: 'SUNLU'),
  ];

  static FarmBrandOption normalize(String value) {
    final raw = value.trim();
    final lower =
        raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');
    if (lower == '拓竹' ||
        lower == 'bambu' ||
        lower == 'bambulab' ||
        lower == 'bbl') {
      return known.first;
    }
    for (final option in known.skip(1)) {
      final normalizedLabel =
          option.label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (lower == option.code || lower == normalizedLabel) return option;
    }
    final label = raw.isEmpty ? '其他品牌' : raw;
    final slug = lower.isEmpty ? 'other' : lower;
    return FarmBrandOption(code: 'custom:$slug', label: label);
  }

  static List<FarmBrandOption> merge(Iterable<String> existingBrands) {
    final byCode = <String, FarmBrandOption>{
      for (final option in known) option.code: option,
    };
    for (final brand in existingBrands) {
      final option = normalize(brand);
      byCode.putIfAbsent(option.code, () => option);
    }
    final result = byCode.values.toList();
    result.sort((a, b) {
      if (a.code == 'bambu_lab') return -1;
      if (b.code == 'bambu_lab') return 1;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return result;
  }

  static bool isBambu(String value) => normalize(value).code == 'bambu_lab';
}
