/// 材料身份规范化服务。
///
/// 把"显示名称"或"型号字符串"归一化为稳定的 canonical ID 和材料族（family）。
/// 兼容性评分、实验平台和数字孪生共用此服务，禁止各模块自行做模糊匹配。
///
/// 核心规则：
/// - PLA 不会与 PLA-CF、PETG 不会与 PETG-CF 被粗暴视为相同材料。
/// - "Bambu PLA Basic @BBL X1C" → canonicalId = "pla", family = "PLA"。
/// - "Generic PETG-CF" → canonicalId = "petg-cf", family = "PETG-CF"（独立族，不并入 PETG）。
/// - 只有 base polymer（如 PLA、PETG、ABS、TPU）才形成宽泛族；
///   含 -CF / -GF / -Aero / -HT 等后缀的视为独立子族，不并入 base。
library;

/// 材料身份：包含 canonical ID、族和原始显示名。
class MaterialIdentity {
  /// 规范化后的稳定 ID（小写、去品牌、去后缀噪声），如 "pla"、"petg-cf"、"tpu-95a"。
  final String canonicalId;

  /// 材料族（大写），如 "PLA"、"PETG-CF"、"TPU"。
  /// 与 [canonicalId] 大小写不同但语义一致；用于 UI 展示。
  final String family;

  /// 原始显示名（去品牌前缀后）。
  final String displayName;

  /// 是否含碳纤维（CF）。
  final bool isCarbonFiber;

  /// 是否含玻璃纤维（GF）。
  final bool isGlassFiber;

  /// 是否为磨蚀性材料（CF / GF / 木基 / 金属基等）。
  final bool isAbrasive;

  /// 是否为柔性材料（TPU / TPE / EVA 等）。
  final bool isFlexible;

  /// 是否为支撑材料（Support / PVA / BVOH / HIPS 等）。
  final bool isSupport;

  /// 是否为吸湿性较强的材料（PETG / NYLON / PVA / TPU / PVA / BVOH 等）。
  final bool isHygroscopic;

  const MaterialIdentity({
    required this.canonicalId,
    required this.family,
    required this.displayName,
    this.isCarbonFiber = false,
    this.isGlassFiber = false,
    this.isAbrasive = false,
    this.isFlexible = false,
    this.isSupport = false,
    this.isHygroscopic = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MaterialIdentity && canonicalId == other.canonicalId;

  @override
  int get hashCode => canonicalId.hashCode;

  @override
  String toString() =>
      'MaterialIdentity($canonicalId, family=$family, abrasive=$isAbrasive)';
}

/// 材料身份规范化服务。
class MaterialIdentityService {
  MaterialIdentityService._();

  /// 已知 base polymer 族（不含后缀变体）。
  static const Map<String, String> _basePolymers = {
    'pla': 'PLA',
    'petg': 'PETG',
    'pctg': 'PCTG',
    'abs': 'ABS',
    'asa': 'ASA',
    'tpu': 'TPU',
    'tpe': 'TPE',
    'pc': 'PC',
    'pa': 'PA',
    'pa6': 'PA6',
    'pa12': 'PA12',
    'pa612': 'PA612',
    'pp': 'PP',
    'pe': 'PE',
    'pps': 'PPS',
    'ppa': 'PPA',
    'peek': 'PEEK',
    'pei': 'PEI',
    'pva': 'PVA',
    'bvoh': 'BVOH',
    'hips': 'HIPS',
    'pha': 'PHA',
    'eva': 'EVA',
    'pet': 'PET',
  };

  /// 吸湿性较强的材料族（需要干燥提醒）。
  static const Set<String> _hygroscopicFamilies = {
    'PETG',
    'PCTG',
    'PA',
    'PA6',
    'PA12',
    'PA612',
    'PVA',
    'BVOH',
    'TPU',
    'TPE',
    'PEEK',
    'PEI',
    'PPA',
    'PPS',
  };

  /// 柔性材料族。
  static const Set<String> _flexibleFamilies = {'TPU', 'TPE', 'EVA'};

  /// 支撑材料关键字。
  static const Set<String> _supportKeywords = {
    'support',
    'pva',
    'bvoh',
    'hips',
  };

  /// 把任意材料字符串规范化为 [MaterialIdentity]。
  ///
  /// 输入示例：
  /// - "Bambu PLA Basic @BBL X1C"
  /// - "Generic PETG-CF"
  /// - "Bambu TPU 95A HF"
  /// - "PolyLite ABS"
  /// - "SUNLU PLA+ 2.0"
  static MaterialIdentity normalize(String input) {
    if (input.trim().isEmpty) {
      return const MaterialIdentity(
        canonicalId: '',
        family: '',
        displayName: '',
      );
    }

    // 1. 去品牌前缀
    var cleaned = _stripBrandPrefix(input);

    // 2. 去 @BBL 后缀
    final atIdx = cleaned.indexOf(' @');
    if (atIdx > 0) {
      cleaned = cleaned.substring(0, atIdx).trim();
    }

    // 3. 提取 base polymer + 后缀
    final lower = cleaned.toLowerCase();
    final isCF = _hasToken(lower, 'cf') || _hasToken(lower, 'carbon');
    final isGF = _hasToken(lower, 'gf') || _hasToken(lower, 'glass');
    final isWood = _hasToken(lower, 'wood');
    final isMetal = _hasToken(lower, 'metal');
    final isMarble = _hasToken(lower, 'marble');
    final isAero = _hasToken(lower, 'aero');
    final isHt = _hasToken(lower, ' ht') || lower.endsWith(' ht');

    // 4. 识别 base polymer
    final basePolymer = _identifyBasePolymer(lower);

    // 5. 构造 canonical ID 和 family
    String canonicalId;
    String family;

    if (basePolymer == null) {
      // 未知材料：用去噪后的字符串作 ID
      canonicalId = _sanitizeUnknown(lower);
      family = _toTitleCase(cleaned);
    } else {
      final baseId = basePolymer.toLowerCase();
      final baseFamily = _basePolymers[baseId]!;

      // 含 CF/GF 等后缀的视为独立子族（不并入 base）
      final suffixes = <String>[];
      if (isCF) suffixes.add('cf');
      if (isGF) suffixes.add('gf');
      if (isWood) suffixes.add('wood');
      if (isMetal) suffixes.add('metal');
      if (isMarble) suffixes.add('marble');
      if (isAero) suffixes.add('aero');
      if (isHt) suffixes.add('ht');

      if (suffixes.isEmpty) {
        canonicalId = baseId;
        family = baseFamily;
      } else {
        canonicalId = '$baseId-${suffixes.join('-')}';
        family = '$baseFamily-${suffixes.join('-').toUpperCase()}';
      }
    }

    // 显式 Support 型号必须拥有独立材料族，不能回落成普通 PLA/ABS。
    if (lower.contains('support')) {
      family = _supportFamily(lower);
      canonicalId = family.toLowerCase();
    }

    // 6. 派生属性
    final isSupport = _supportKeywords.any((k) => lower.contains(k));
    final isFlexible = _flexibleFamilies.contains(family) ||
        _flexibleFamilies.any((f) => family.startsWith(f));
    final isHygroscopic = _hygroscopicFamilies.any((f) => family.startsWith(f));
    final isAbrasive = isCF || isGF || isWood || isMetal || isMarble;

    return MaterialIdentity(
      canonicalId: canonicalId,
      family: family,
      displayName: cleaned,
      isCarbonFiber: isCF,
      isGlassFiber: isGF,
      isAbrasive: isAbrasive,
      isFlexible: isFlexible,
      isSupport: isSupport,
      isHygroscopic: isHygroscopic,
    );
  }

  /// 去除已知品牌前缀（Bambu / Generic / eSUN / Fiberon / Overture / PolyLite / PolyTerra / SUNLU）。
  static String _stripBrandPrefix(String input) {
    final trimmed = input.trim();
    final lower = trimmed.toLowerCase();
    const brands = [
      'bambu ',
      'generic ',
      'esun ',
      'fiberon ',
      'overture ',
      'polylite ',
      'polyterra ',
      'sunlu ',
    ];
    for (final brand in brands) {
      if (lower.startsWith(brand)) {
        return trimmed.substring(brand.length).trim();
      }
    }
    return trimmed;
  }

  /// 判断字符串中是否包含某个 token（以非字母数字边界分隔）。
  static bool _hasToken(String lower, String token) {
    final pattern = RegExp(r'(^|[^a-z0-9])' + token + r'([^a-z0-9]|$)');
    return pattern.hasMatch(lower);
  }

  static String _supportFamily(String lower) {
    final hasPla = _hasToken(lower, 'pla');
    final hasPetg = _hasToken(lower, 'petg');
    final hasPa = _hasToken(lower, 'pa');
    final hasPet = _hasToken(lower, 'pet');
    if (hasPla && hasPetg) return 'SUPPORT-PLA-PETG';
    if (hasPa && hasPet) return 'SUPPORT-PA-PET';
    if (_hasToken(lower, 'abs')) return 'SUPPORT-ABS';
    if (hasPla) return 'SUPPORT-PLA';
    if (hasPetg) return 'SUPPORT-PETG';
    if (hasPa) return 'SUPPORT-PA';
    if (_hasToken(lower, 'g')) return 'SUPPORT-G';
    if (_hasToken(lower, 'w')) return 'SUPPORT-W';
    return 'SUPPORT';
  }

  /// 识别 base polymer。
  ///
  /// 优先匹配最长 token（避免 "PA612" 被错认为 "PA6"）。
  static String? _identifyBasePolymer(String lower) {
    // 按长度降序检查，确保 PA612 > PA6 > PA
    final candidates = _basePolymers.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final id in candidates) {
      if (_hasToken(lower, id)) return id;
    }
    return null;
  }

  /// 对未知材料做基本去噪。
  static String _sanitizeUnknown(String lower) {
    return lower
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'[^a-z0-9\-]'), '')
        .trim();
  }

  /// 转为 Title Case。
  static String _toTitleCase(String input) {
    if (input.isEmpty) return input;
    final words = input.split(RegExp(r'\s+'));
    return words.map((w) {
      if (w.isEmpty) return w;
      return w[0].toUpperCase() + w.substring(1).toLowerCase();
    }).join(' ');
  }

  /// 判断两个材料字符串是否属于同一族（family 相同）。
  ///
  /// 注意：PLA 和 PLA-CF 不是同族（一个是 PLA，一个是 PLA-CF）。
  static bool sameFamily(String a, String b) {
    final idA = normalize(a);
    final idB = normalize(b);
    return idA.family == idB.family && idA.family.isNotEmpty;
  }

  /// 判断两个材料字符串是否完全相同（canonicalId 相同）。
  static bool sameMaterial(String a, String b) {
    final idA = normalize(a);
    final idB = normalize(b);
    return idA.canonicalId == idB.canonicalId && idA.canonicalId.isNotEmpty;
  }
}
