/// 耗材完整型号与紧凑代号之间的统一转换。
///
/// 完整型号仍然保存在数据库中，代号只用于空间紧张的界面。这样新型号
/// 不会因为 UI 放不下而丢失信息，鼠标悬停时也能始终还原完整名称。
class FilamentModelCode {
  FilamentModelCode._();

  static const _baseFamilies = <String>[
    'PA612',
    'PAHT',
    'PETG',
    'PCTG',
    'PA12',
    'PA6',
    'PLA',
    'ABS',
    'ASA',
    'TPU',
    'TPE',
    'PPA',
    'PPS',
    'PET',
    'PVA',
    'BVOH',
    'HIPS',
    'PC',
    'PA',
    'PP',
    'PE',
  ];

  static const _familyPrefixes = <String, String>{
    'PLA': 'P',
    'PETG': 'G',
    'PCTG': 'C',
    'ABS': 'A',
    'ASA': 'S',
    'TPU': 'T',
    'TPE': 'E',
    'PC': 'C',
    'PA': 'N',
    'PA6': 'N6',
    'PA12': 'N2',
    'PA612': 'N6',
    'PAHT': 'NH',
    'PPA': 'PA',
    'PPS': 'PS',
    'PET': 'E',
    'PVA': 'V',
    'BVOH': 'B',
    'HIPS': 'H',
    'PP': 'PP',
    'PE': 'PE',
  };

  /// 将完整型号压缩成稳定、可辨认的短代号。
  static String of({required String model, String? materialType}) {
    final preferred = _effectiveName(model, materialType);
    if (preferred.isEmpty) return '—';

    final cleaned = _stripBrand(preferred);
    final upper = cleaned
        .toUpperCase()
        .replaceAll('＋', '+')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final supportCode = _supportCode(upper);
    if (supportCode != null) return supportCode;

    final base = _baseFamilies.cast<String?>().firstWhere(
          (candidate) => _hasToken(upper, candidate!),
          orElse: () => null,
        );
    if (base == null) return _fallbackCode(upper);

    final prefix = _familyPrefixes[base] ?? base.substring(0, 1);
    if (_hasToken(upper, 'CF')) {
      return '${prefix}CF';
    }
    if (_hasToken(upper, 'GF')) {
      return '${prefix}GF';
    }

    final suffix = _variantSuffix(upper, base);
    return suffix == null ? base : '$prefix$suffix';
  }

  /// Tooltip 中使用的完整说明，避免品牌名重复。
  static String description({
    required String manufacturer,
    required String model,
    String? materialType,
  }) {
    final rawModel = model.trim();
    final material = materialType?.trim() ?? '';
    final effectiveName = _effectiveName(rawModel, material);
    final name = effectiveName.isEmpty ? '未标注型号' : effectiveName;
    final lower = name.toLowerCase();
    if (lower.startsWith('bambu ') ||
        lower.startsWith('bambu lab ') ||
        name.startsWith('拓竹')) {
      return name;
    }
    final brand = manufacturer.trim();
    final branded = brand.isEmpty ? name : '$brand $name';
    if (_looksLikeRfidSku(rawModel) &&
        material.isNotEmpty &&
        rawModel.toUpperCase() != material.toUpperCase()) {
      return '$branded（RFID ${rawModel.toUpperCase()}）';
    }
    return branded;
  }

  static String _effectiveName(String model, String? materialType) {
    final rawModel = model.trim();
    final material = materialType?.trim() ?? '';
    if (rawModel.isNotEmpty && !_looksLikeRfidSku(rawModel)) return rawModel;
    if (material.isNotEmpty) return material;
    return rawModel;
  }

  static bool _looksLikeRfidSku(String value) {
    return RegExp(r'^[A-Z]{2,5}\d{2,4}$').hasMatch(value.trim().toUpperCase());
  }

  static String tooltip({
    required String manufacturer,
    required String model,
    String? materialType,
  }) {
    final code = of(model: model, materialType: materialType);
    return '$code = ${description(manufacturer: manufacturer, model: model, materialType: materialType)}';
  }

  static String _stripBrand(String input) {
    var value = input.trim();
    final lower = value.toLowerCase();
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
        return value.substring(prefix.length).trim();
      }
    }
    if (value.startsWith('拓竹')) {
      value = value.substring(2).trim();
    }
    return value;
  }

  static String? _supportCode(String upper) {
    if (!upper.contains('SUPPORT') && !upper.contains('支撑')) return null;
    if (upper.contains('PLA') && upper.contains('PETG')) {
      return 'SPG';
    }
    if (upper.contains('PA') && upper.contains('PET')) return 'SNP';
    if (_hasToken(upper, 'ABS')) return 'SAB';
    if (_hasToken(upper, 'PETG')) return 'SPG';
    if (_hasToken(upper, 'PLA')) return 'SPL';
    if (_hasToken(upper, 'PA')) return 'SNP';
    if (_hasToken(upper, 'G')) return 'SG';
    if (_hasToken(upper, 'W')) return 'SW';
    return 'SUP';
  }

  static String? _variantSuffix(String upper, String base) {
    if (base == 'TPU') {
      final hardness = RegExp(r'\b(\d{2,3}[AD])\b').firstMatch(upper)?.group(1);
      if (hardness != null) {
        final number = hardness.substring(0, hardness.length - 1);
        return upper.contains(' HF') || upper.endsWith('-HF')
            ? '${number}H'
            : number;
      }
      if (upper.contains('FOR AMS') || upper.contains('AMS 专用')) return 'AM';
    }
    if (upper.contains('SILK MULTI') || upper.contains('MULTI-COLOR')) {
      return 'SM';
    }
    if (upper.contains('SILK+')) return 'S+';
    if (_hasToken(upper, 'SILK')) return 'S';
    if (upper.contains('TOUGH+')) return 'T+';
    if (_hasToken(upper, 'TOUGH')) return 'T';
    if (_hasToken(upper, 'TRANSLUCENT')) return 'T';
    if (_hasToken(upper, 'BASIC')) return 'B';
    if (_hasToken(upper, 'MATTE')) return 'M';
    if (_hasToken(upper, 'GRADIENT')) return 'D';
    if (_hasToken(upper, 'GALAXY')) return 'X';
    if (_hasToken(upper, 'SPARKLE')) return 'K';
    if (_hasToken(upper, 'MARBLE')) return 'R';
    if (_hasToken(upper, 'METALLIC') || _hasToken(upper, 'METAL')) return 'E';
    if (_hasToken(upper, 'GLOW')) return 'GL';
    if (_hasToken(upper, 'WOOD')) return 'W';
    if (_hasToken(upper, 'AERO')) return 'AR';
    if (_hasToken(upper, 'DYNAMIC')) return 'DY';
    if (_hasToken(upper, 'LITE')) return 'L';
    if (_hasToken(upper, 'PURE')) return 'P';
    if (_hasToken(upper, 'HF')) return 'HF';
    if (_hasToken(upper, 'FR')) return 'FR';
    return null;
  }

  static bool _hasToken(String upper, String token) {
    return RegExp(
      r'(^|[^A-Z0-9])' + RegExp.escape(token) + r'([^A-Z0-9]|$)',
    ).hasMatch(upper);
  }

  static String _fallbackCode(String upper) {
    final compact = upper
        .replaceAll(RegExp(r'[^A-Z0-9+\-/]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (compact.isEmpty) return 'OTHER';
    if (compact.length <= 4) return compact;
    final words = compact.split('-').where((word) => word.isNotEmpty).toList();
    if (words.length > 1) {
      final acronym = words.map((word) => word[0]).join();
      if (acronym.length >= 2) {
        return acronym.length > 4 ? acronym.substring(0, 4) : acronym;
      }
    }
    return compact.substring(0, 4);
  }
}
