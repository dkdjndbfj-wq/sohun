import 'package:consumable_tracker_desktop/data/external/printer/printer_certificate_trust_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const fingerprintA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const fingerprintB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('首次证书没有明确 pin 时失败关闭', () async {
    final verifier = await PrinterCertificateTrustStore.loadVerifier(
      serial: 'SERIAL-1',
      host: '192.168.1.20',
      service: PrinterTlsService.mqtt,
    );

    expect(verifier.verifyFingerprint(fingerprintA), isFalse);
    expect(
      await PrinterCertificateTrustStore.hasTrust(
        serial: 'SERIAL-1',
        host: '192.168.1.20',
      ),
      isFalse,
    );
  });

  test('pin 绑定序列号和主机，证书变化或主机变化都拒绝', () async {
    await PrinterCertificateTrustStore.trustFingerprint(
      serial: 'SERIAL-1',
      host: '192.168.1.20',
      service: PrinterTlsService.mqtt,
      fingerprint: fingerprintA,
    );
    final verifier = await PrinterCertificateTrustStore.loadVerifier(
      serial: 'SERIAL-1',
      host: '192.168.1.20',
      service: PrinterTlsService.mqtt,
    );
    final otherHostVerifier = await PrinterCertificateTrustStore.loadVerifier(
      serial: 'SERIAL-1',
      host: '192.168.1.21',
      service: PrinterTlsService.mqtt,
    );

    expect(verifier.verifyFingerprint(fingerprintA), isTrue);
    expect(verifier.verifyFingerprint(fingerprintB), isFalse);
    expect(otherHostVerifier.verifyFingerprint(fingerprintA), isFalse);
  });

  test('MQTT 与 FTPS 只在实际指纹相同时共享信任', () async {
    await PrinterCertificateTrustStore.trustFingerprint(
      serial: 'SERIAL-1',
      host: '192.168.1.20',
      service: PrinterTlsService.mqtt,
      fingerprint: fingerprintA,
    );
    final ftpsVerifier = await PrinterCertificateTrustStore.loadVerifier(
      serial: 'SERIAL-1',
      host: '192.168.1.20',
      service: PrinterTlsService.ftps,
    );

    expect(ftpsVerifier.verifyFingerprint(fingerprintB), isFalse);
    expect(ftpsVerifier.verifyFingerprint(fingerprintA), isTrue);
    await Future<void>.delayed(Duration.zero);

    final promoted = await PrinterCertificateTrustStore.loadVerifier(
      serial: 'SERIAL-1',
      host: '192.168.1.20',
      service: PrinterTlsService.ftps,
    );
    expect(promoted.currentFingerprint, fingerprintA);
  });

  test('旧 MQTT/FTPS pin 一次性迁移到序列号加主机身份', () async {
    SharedPreferences.setMockInitialValues({
      'lan_cert_sha256_SERIAL-1': fingerprintA,
      'ftps_cert_sha256_192.168.1.20': fingerprintA,
    });

    final mqtt = await PrinterCertificateTrustStore.loadVerifier(
      serial: 'SERIAL-1',
      host: '192.168.1.20',
      service: PrinterTlsService.mqtt,
    );
    final ftps = await PrinterCertificateTrustStore.loadVerifier(
      serial: 'SERIAL-1',
      host: '192.168.1.20',
      service: PrinterTlsService.ftps,
    );

    expect(mqtt.currentFingerprint, fingerprintA);
    expect(ftps.currentFingerprint, fingerprintA);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('lan_cert_sha256_SERIAL-1'), isFalse);
    expect(prefs.containsKey('ftps_cert_sha256_192.168.1.20'), isFalse);
  });
}
