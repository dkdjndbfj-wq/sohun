import 'app_variant.dart';

/// User-facing product identity.
///
/// Keep these values separate from package names and storage identifiers so
/// rebranding never changes existing user data locations.
abstract final class AppIdentity {
  static const name = AppVariant.productName;
  static const author = '生腌焦糖';
  static const description = '3D 打印耗材、参数与设备管理';
  static const iconAsset = 'assets/images/sohun.png';
  static const trayIconAsset =
      'assets/images/branding/themes/sohun_aurora_green_light.ico';
  static const trayTooltip = '$name · 左键打开软件，右键打开菜单';
}
