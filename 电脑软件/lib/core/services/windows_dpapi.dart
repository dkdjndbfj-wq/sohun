import 'dart:io';

import 'package:flutter/services.dart';

/// Small injectable boundary around OS data protection.
abstract interface class DataProtector {
  Future<Uint8List> protect(Uint8List plaintext);

  Future<Uint8List> unprotect(Uint8List ciphertext);
}

/// Windows DPAPI implementation backed by the runner's existing security
/// method channel. There is deliberately no plaintext or weak-encryption
/// fallback.
class WindowsDpapiProtector implements DataProtector {
  static const MethodChannel _channel =
      MethodChannel('consumable_tracker/security');

  const WindowsDpapiProtector();

  @override
  Future<Uint8List> protect(Uint8List plaintext) async {
    _requireWindows();
    try {
      final result =
          await _channel.invokeMethod<Uint8List>('protect', plaintext);
      if (result == null || result.isEmpty) {
        throw const DpapiException('Windows DPAPI 未返回加密结果');
      }
      return result;
    } on DpapiException {
      rethrow;
    } on PlatformException catch (error) {
      throw DpapiException('Windows DPAPI 加密失败：${error.message ?? error.code}');
    } on MissingPluginException {
      throw const DpapiException('Windows DPAPI 安全通道不可用');
    }
  }

  @override
  Future<Uint8List> unprotect(Uint8List ciphertext) async {
    _requireWindows();
    try {
      final result =
          await _channel.invokeMethod<Uint8List>('unprotect', ciphertext);
      if (result == null || result.isEmpty) {
        throw const DpapiException('Windows DPAPI 未返回解密结果');
      }
      return result;
    } on DpapiException {
      rethrow;
    } on PlatformException catch (error) {
      throw DpapiException('Windows DPAPI 解密失败：${error.message ?? error.code}');
    } on MissingPluginException {
      throw const DpapiException('Windows DPAPI 安全通道不可用');
    }
  }

  static void _requireWindows() {
    if (!Platform.isWindows) {
      throw const DpapiException('应用账号安全存储仅支持 Windows DPAPI');
    }
  }
}

class DpapiException implements Exception {
  final String message;

  const DpapiException(this.message);

  @override
  String toString() => message;
}
