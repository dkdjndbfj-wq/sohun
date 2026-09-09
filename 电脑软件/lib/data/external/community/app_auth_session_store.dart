import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/windows_dpapi.dart';
import '../../models/app_auth.dart';

abstract interface class AppAuthSessionStore {
  Future<AppAuthSession?> read();

  Future<void> write(AppAuthSession session);

  Future<void> clear();
}

typedef SharedPreferencesLoader = Future<SharedPreferences> Function();

/// Persists the complete application session as a DPAPI-protected blob.
///
/// No legacy plaintext format is accepted. Corrupt or non-DPAPI data fails
/// closed so credentials are never silently downgraded.
class DpapiAppAuthSessionStore implements AppAuthSessionStore {
  static const _storageKey = 'app_auth_session_dpapi_v1';
  static const _formatPrefix = 'dpapi:v1:';

  final DataProtector protector;
  final SharedPreferencesLoader preferencesLoader;

  DpapiAppAuthSessionStore({
    DataProtector? protector,
    SharedPreferencesLoader? preferencesLoader,
  })  : protector = protector ?? const WindowsDpapiProtector(),
        preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  @override
  Future<AppAuthSession?> read() async {
    final prefs = await preferencesLoader();
    final stored = prefs.getString(_storageKey);
    if (stored == null) return null;
    if (!stored.startsWith(_formatPrefix)) {
      throw const AppAuthSessionStoreException('检测到不安全的应用账号会话格式，已拒绝读取');
    }

    try {
      final encrypted = base64Decode(stored.substring(_formatPrefix.length));
      if (encrypted.isEmpty) {
        throw const FormatException('密文为空');
      }
      final plaintext = await protector.unprotect(
        Uint8List.fromList(encrypted),
      );
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map) throw const FormatException('会话不是 JSON 对象');
      return AppAuthSession.fromJson(Map<String, dynamic>.from(decoded));
    } catch (error) {
      if (error is AppAuthSessionStoreException) rethrow;
      throw AppAuthSessionStoreException('读取应用账号会话失败：$error');
    }
  }

  @override
  Future<void> write(AppAuthSession session) async {
    try {
      final plaintext = Uint8List.fromList(
        utf8.encode(jsonEncode(session.toJson())),
      );
      final encrypted = await protector.protect(plaintext);
      final prefs = await preferencesLoader();
      final saved = await prefs.setString(
        _storageKey,
        '$_formatPrefix${base64Encode(encrypted)}',
      );
      if (!saved) throw StateError('偏好存储拒绝写入');
    } catch (error) {
      if (error is AppAuthSessionStoreException) rethrow;
      throw AppAuthSessionStoreException('保存应用账号会话失败：$error');
    }
  }

  @override
  Future<void> clear() async {
    final prefs = await preferencesLoader();
    final removed = await prefs.remove(_storageKey);
    if (!removed && prefs.containsKey(_storageKey)) {
      throw const AppAuthSessionStoreException('清除应用账号会话失败');
    }
  }
}

class AppAuthSessionStoreException implements Exception {
  final String message;

  const AppAuthSessionStoreException(this.message);

  @override
  String toString() => message;
}
