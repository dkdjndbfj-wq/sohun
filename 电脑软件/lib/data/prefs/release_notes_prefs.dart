import 'package:shared_preferences/shared_preferences.dart';

class ReleaseNotesPrefs {
  ReleaseNotesPrefs._();

  static const _lastSeenVersionKey = 'last_seen_release_notes_version';

  static Future<bool> shouldShow(String currentVersion) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastSeenVersionKey) != currentVersion;
  }

  static Future<void> markSeen(String currentVersion) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSeenVersionKey, currentVersion);
  }
}
