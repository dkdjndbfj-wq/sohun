/// 耗材厂商商标工具。根据厂商名查找 assets/images/brands/ 下的商标图。
/// 支持精确匹配 + 包含匹配；找不到返回 null（调用方用文字代替）。
class BrandLogoUtils {
  BrandLogoUtils._();

  /// 商标图文件名 → 厂商关键词列表（用于模糊匹配）。
  /// 文件名去掉扩展名后作为匹配关键词。
  static const Map<String, List<String>> _brandMap = {
    'eSUN': ['esun', '易生'],
    'JAYO': ['jayo'],
    'Kaaber': ['kaaber'],
    'Kexcelled': ['kexcelled'],
    'Polymaker': ['polymaker'],
    'R3D': ['r3d'],
    '三绿': ['三绿'],
    '兰博': ['兰博'],
    '创想三维': ['创想三维', 'creality'],
    '拓竹': ['拓竹', 'bambu'],
    '爱丽兹': ['爱丽兹'],
    '爱乐酷': ['爱乐酷', 'anycubic', '纵维立方'],
    '纵维立方': ['纵维立方', 'anycubic'],
  };

  /// 查找厂商商标。返回 asset 路径，找不到返回 null。
  /// 匹配规则：厂商名（小写）包含任一关键词即命中。
  static String? resolveAsset(String manufacturer) {
    final name = manufacturer.trim().toLowerCase();
    if (name.isEmpty) return null;
    for (final entry in _brandMap.entries) {
      for (final keyword in entry.value) {
        if (name.contains(keyword.toLowerCase())) {
          return 'assets/images/brands/${entry.key}.png';
        }
      }
    }
    return null;
  }

  /// 是否有该厂商的商标图。
  static bool hasLogo(String manufacturer) =>
      resolveAsset(manufacturer) != null;
}
