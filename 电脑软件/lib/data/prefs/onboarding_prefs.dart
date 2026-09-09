import 'package:shared_preferences/shared_preferences.dart';

/// 首次启动引导完成标志持久化。
class OnboardingPrefs {
  OnboardingPrefs._();

  static const _key = 'onboarding_completed';

  static Future<bool> isCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  static Future<void> setCompleted(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}
