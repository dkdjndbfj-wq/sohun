/// 耗材品牌规范化服务。
///
/// 桌面版、手机版和同步入口都应在保存或匹配品牌前调用 [normalize]，避免同一
/// 品牌因中英文名或大小写差异被拆成多组。规范名与
/// `assets/images/brands/` 的品牌图片文件名保持一致。
class FilamentBrandIdentityService {
  FilamentBrandIdentityService._();

  static const Map<String, String> _canonicalByAlias = {
    'bambu': '拓竹',
    'bambulab': '拓竹',
    'bbl': '拓竹',
    '拓竹': '拓竹',
    'esun': 'eSUN',
    '易生': 'eSUN',
  };

  /// 返回用于展示、持久化和品牌图片匹配的规范名。
  ///
  /// 未登记的自定义品牌只会去掉首尾空白，不改变用户输入的大小写或文字。
  static String normalize(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    return _canonicalByAlias[_aliasKey(trimmed)] ?? trimmed;
  }

  /// 判断两个品牌名在别名规范化后是否指向同一品牌。
  static bool sameBrand(String left, String right) {
    final normalizedLeft = normalize(left);
    final normalizedRight = normalize(right);
    if (normalizedLeft.isEmpty || normalizedRight.isEmpty) return false;
    return _aliasKey(normalizedLeft) == _aliasKey(normalizedRight);
  }

  static String _aliasKey(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');
}
