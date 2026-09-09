import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/windows_dpapi.dart';
import 'bambu_printer_models.dart';

abstract interface class PrinterConnectionStore {
  Future<List<PrinterConnectionConfig>> read();

  Future<void> write(List<PrinterConnectionConfig> connections);
}

/// Stores LAN access codes in a Windows DPAPI-protected blob.
///
/// The legacy `printer_connections` plaintext value is accepted exactly once,
/// protected, and removed after a successful migration. There is deliberately
/// no plaintext fallback when DPAPI is unavailable.
class DpapiPrinterConnectionStore implements PrinterConnectionStore {
  static const storageKey = 'printer_connections_dpapi_v1';
  static const legacyStorageKey = 'printer_connections';
  static const legacyCorruptBackupKey = 'printer_connections_corrupt_backup';
  static const _formatPrefix = 'dpapi:v1:';

  final DataProtector protector;
  final Future<SharedPreferences> Function() preferencesLoader;

  DpapiPrinterConnectionStore({
    DataProtector? protector,
    Future<SharedPreferences> Function()? preferencesLoader,
  })  : protector = protector ?? const WindowsDpapiProtector(),
        preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  @override
  Future<List<PrinterConnectionConfig>> read() async {
    final prefs = await preferencesLoader();
    final protectedValue = prefs.getString(storageKey);
    final legacyValue =
        protectedValue == null ? prefs.getString(legacyStorageKey) : null;
    if (protectedValue == null && legacyValue == null) return const [];

    try {
      final json = protectedValue != null
          ? await _unprotect(protectedValue)
          : legacyValue!;
      final decoded = jsonDecode(json);
      if (decoded is! List) {
        throw const FormatException('连接配置不是 JSON 数组');
      }
      final connections = decoded
          .map(
            (item) => PrinterConnectionConfig.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false);

      if (legacyValue != null) {
        await write(connections);
        await prefs.remove(legacyStorageKey);
        await prefs.remove(legacyCorruptBackupKey);
      }
      return connections;
    } catch (error) {
      throw PrinterConnectionStoreException('读取打印机连接配置失败：$error');
    }
  }

  @override
  Future<void> write(List<PrinterConnectionConfig> connections) async {
    try {
      final json = jsonEncode(
        connections.map((connection) => connection.toJson()).toList(),
      );
      final encrypted = await protector.protect(
        Uint8List.fromList(utf8.encode(json)),
      );
      if (encrypted.isEmpty) {
        throw const DpapiException('Windows DPAPI 未返回加密结果');
      }
      final prefs = await preferencesLoader();
      final saved = await prefs.setString(
        storageKey,
        '$_formatPrefix${base64Encode(encrypted)}',
      );
      if (!saved) {
        throw StateError('偏好存储拒绝写入');
      }
      await prefs.remove(legacyStorageKey);
      await prefs.remove(legacyCorruptBackupKey);
    } catch (error) {
      if (error is PrinterConnectionStoreException) rethrow;
      throw PrinterConnectionStoreException('保存打印机连接配置失败：$error');
    }
  }

  Future<String> _unprotect(String stored) async {
    if (!stored.startsWith(_formatPrefix)) {
      throw const FormatException('检测到未知或不安全的打印机连接配置格式');
    }
    final encoded = stored.substring(_formatPrefix.length);
    final encrypted = base64Decode(encoded);
    if (encrypted.isEmpty) throw const FormatException('打印机连接配置密文为空');
    final plaintext = await protector.unprotect(
      Uint8List.fromList(encrypted),
    );
    return utf8.decode(plaintext);
  }
}

class PrinterConnectionStoreException implements Exception {
  final String message;

  const PrinterConnectionStoreException(this.message);

  @override
  String toString() => message;
}
