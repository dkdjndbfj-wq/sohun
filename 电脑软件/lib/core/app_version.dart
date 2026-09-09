/// 应用版本号集中定义。
///
/// 与 pubspec.yaml 的 version 字段保持同步。
/// 修改版本时同时更新此处和 pubspec.yaml。
class AppVersion {
  AppVersion._();

  /// 主版本号字符串，如 'v1.0.0'。
  static const String version = 'v1.0.1';

  /// 完整版本号（含构建号），如 'v1.0.0+1'。
  static const String fullVersion = 'v1.0.1+2';
}
