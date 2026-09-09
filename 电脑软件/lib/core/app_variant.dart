/// The two distributable Sohun desktop products.
///
/// A build selects its product with `--dart-define=SOHUN_APP_VARIANT=farm`.
/// Omitting the define intentionally produces the personal application.
enum SohunAppVariant { personal, farm }

abstract final class AppVariant {
  static const _raw = String.fromEnvironment(
    'SOHUN_APP_VARIANT',
    defaultValue: 'personal',
  );

  static const SohunAppVariant current =
      _raw == 'farm' ? SohunAppVariant.farm : SohunAppVariant.personal;

  static const bool isFarm = current == SohunAppVariant.farm;
  static const bool isPersonal = current == SohunAppVariant.personal;

  /// Human-readable product name used in window, tray, notifications and
  /// onboarding copy.
  static const String productName = isFarm ? 'sohun 农场' : 'sohun';

  /// Stable ASCII identifier used by native Windows version resources.
  static const String executableName = isFarm ? 'sohun-farm' : 'sohun';

  /// Namespace used by files that are stored in the shared Documents folder.
  static const String dataNamespace = isFarm ? 'sohun-farm' : 'sohun-personal';
}
