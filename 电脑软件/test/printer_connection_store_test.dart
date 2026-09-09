import 'dart:convert';
import 'dart:typed_data';

import 'package:consumable_tracker_desktop/core/services/windows_dpapi.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connection_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('LAN access code 只以 DPAPI 密文保存并可完整读取', () async {
    final store = DpapiPrinterConnectionStore(protector: _XorProtector());
    const connection = PrinterConnectionConfig(
      serial: '01S09C123456789',
      host: '192.168.1.100',
      accessCode: 'sensitive-lan-code',
      devProductName: 'X1C',
      installedNozzleDiameter: 0.4,
    );

    await store.write(const [connection]);
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(DpapiPrinterConnectionStore.storageKey);
    expect(stored, startsWith('dpapi:v1:'));
    expect(stored, isNot(contains(connection.accessCode)));
    expect(
      prefs.containsKey(DpapiPrinterConnectionStore.legacyStorageKey),
      isFalse,
    );

    final restored = await store.read();
    expect(restored.single.serial, connection.serial);
    expect(restored.single.host, connection.host);
    expect(restored.single.accessCode, connection.accessCode);
  });

  test('首次读取会把旧明文连接配置迁移为 DPAPI 密文', () async {
    const connection = PrinterConnectionConfig(
      serial: 'LEGACY-PRINTER',
      host: '192.168.1.101',
      accessCode: 'legacy-secret',
      devProductName: 'P1S',
      installedNozzleDiameter: 0.4,
    );
    SharedPreferences.setMockInitialValues({
      DpapiPrinterConnectionStore.legacyStorageKey: jsonEncode([
        connection.toJson(),
      ]),
    });
    final store = DpapiPrinterConnectionStore(protector: _XorProtector());

    final restored = await store.read();
    final prefs = await SharedPreferences.getInstance();
    expect(restored.single.accessCode, connection.accessCode);
    expect(
      prefs.containsKey(DpapiPrinterConnectionStore.legacyStorageKey),
      isFalse,
    );
    expect(
      prefs.getString(DpapiPrinterConnectionStore.storageKey),
      startsWith('dpapi:v1:'),
    );
  });

  test('受保护键拒绝明文和未知格式', () async {
    SharedPreferences.setMockInitialValues({
      DpapiPrinterConnectionStore.storageKey: '[{"accessCode":"plaintext"}]',
    });
    final store = DpapiPrinterConnectionStore(protector: _XorProtector());

    expect(
      store.read,
      throwsA(isA<PrinterConnectionStoreException>()),
    );
  });
}

class _XorProtector implements DataProtector {
  @override
  Future<Uint8List> protect(Uint8List plaintext) async =>
      Uint8List.fromList(plaintext.map((byte) => byte ^ 0xA5).toList());

  @override
  Future<Uint8List> unprotect(Uint8List ciphertext) async =>
      Uint8List.fromList(ciphertext.map((byte) => byte ^ 0xA5).toList());
}
