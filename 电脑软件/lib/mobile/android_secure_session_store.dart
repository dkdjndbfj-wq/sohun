import 'dart:convert';

import 'package:flutter/services.dart';

import '../data/external/community/app_auth_session_store.dart';
import '../data/models/app_auth.dart';

/// Android Keystore-backed account session store.
///
/// The desktop DPAPI store remains the default for Windows. This adapter is
/// only wired into the mobile entrypoint, so an Android build never attempts
/// to call the Windows security channel.
class AndroidSecureSessionStore implements AppAuthSessionStore {
  AndroidSecureSessionStore({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'top.sohun/secure_session';
  final MethodChannel _channel;

  @override
  Future<AppAuthSession?> read() async {
    try {
      final value = await _channel.invokeMethod<String?>('read');
      if (value == null || value.isEmpty) return null;
      final decoded = jsonDecode(value);
      if (decoded is! Map) throw const FormatException('会话不是 JSON 对象');
      return AppAuthSession.fromJson(Map<String, dynamic>.from(decoded));
    } catch (error) {
      if (error is AppAuthSessionStoreException) rethrow;
      throw AppAuthSessionStoreException('读取 Android 账号会话失败：$error');
    }
  }

  @override
  Future<void> write(AppAuthSession session) async {
    try {
      await _channel.invokeMethod<void>(
        'write',
        <String, Object>{'value': jsonEncode(session.toJson())},
      );
    } catch (error) {
      throw AppAuthSessionStoreException('保存 Android 账号会话失败：$error');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } catch (error) {
      throw AppAuthSessionStoreException('清除 Android 账号会话失败：$error');
    }
  }
}
