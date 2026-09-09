import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';

enum PrinterTlsService { mqtt, ftps, camera }

class PrinterCertificateVerifier {
  PrinterCertificateVerifier._({
    required this.currentFingerprint,
    required this.sharedFingerprints,
    required this.onSharedMatch,
  });

  final String? currentFingerprint;
  final Set<String> sharedFingerprints;
  final Future<void> Function(String fingerprint) onSharedMatch;

  bool verifyCertificate(Object certificate) {
    if (certificate is! X509Certificate) return false;
    return verifyFingerprint(
      PrinterCertificateTrustStore.fingerprintForDer(certificate.der),
    );
  }

  bool verifyFingerprint(String candidate) {
    final normalized = PrinterCertificateTrustStore.normalizeFingerprint(
      candidate,
    );
    if (normalized == null) return false;
    final current = currentFingerprint;
    if (current != null) return current == normalized;
    if (!sharedFingerprints.contains(normalized)) return false;
    // MQTT/FTPS 只有在实际看到同一张证书时才共享信任，并为当前服务落 pin。
    unawaited(onSharedMatch(normalized));
    return true;
  }
}

class PrinterCertificateTrustStore {
  const PrinterCertificateTrustStore._();

  static String fingerprintForDer(List<int> der) =>
      crypto.sha256.convert(der).toString();

  static String? normalizeFingerprint(String? value) {
    final normalized =
        value?.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
    if (normalized == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }

  static Future<bool> hasTrust({
    required String serial,
    required String host,
    PrinterTlsService? service,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyPins(prefs, serial: serial, host: host);
    if (service != null) {
      return _readPin(prefs, serial, host, service) != null;
    }
    // Keep the nullable form for old integrations, but all production call
    // sites should pass the exact TLS service.  A MQTT pin must not suppress
    // the first camera/FTPS certificate confirmation when those services use a
    // different certificate.
    return PrinterTlsService.values.any(
      (candidate) => _readPin(prefs, serial, host, candidate) != null,
    );
  }

  static Future<void> trustFingerprint({
    required String serial,
    required String host,
    required PrinterTlsService service,
    required String fingerprint,
  }) async {
    final normalized = normalizeFingerprint(fingerprint);
    if (normalized == null) {
      throw ArgumentError.value(
        fingerprint,
        'fingerprint',
        'must be a SHA-256 certificate fingerprint',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(serial, host, service), normalized);
  }

  static Future<PrinterCertificateVerifier> loadVerifier({
    required String serial,
    required String host,
    required PrinterTlsService service,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyPins(prefs, serial: serial, host: host);
    final current = _readPin(prefs, serial, host, service);
    final shared = <String>{};
    for (final candidateService in PrinterTlsService.values) {
      if (candidateService == service) continue;
      final pin = _readPin(prefs, serial, host, candidateService);
      if (pin != null) shared.add(pin);
    }
    return PrinterCertificateVerifier._(
      currentFingerprint: current,
      sharedFingerprints: Set<String>.unmodifiable(shared),
      onSharedMatch: (fingerprint) => trustFingerprint(
        serial: serial,
        host: host,
        service: service,
        fingerprint: fingerprint,
      ),
    );
  }

  static Future<void> forgetIdentity({
    required String serial,
    required String host,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    for (final service in PrinterTlsService.values) {
      await prefs.remove(_key(serial, host, service));
    }
  }

  static String _key(
    String serial,
    String host,
    PrinterTlsService service,
  ) {
    final identity = '${serial.trim()}|${host.trim().toLowerCase()}';
    final identityHash = crypto.sha256.convert(identity.codeUnits).toString();
    return 'printer_tls_v1_${identityHash}_${service.name}';
  }

  static String? _readPin(
    SharedPreferences prefs,
    String serial,
    String host,
    PrinterTlsService service,
  ) =>
      normalizeFingerprint(prefs.getString(_key(serial, host, service)));

  static Future<void> _migrateLegacyPins(
    SharedPreferences prefs, {
    required String serial,
    required String host,
  }) async {
    final legacyKeys = <PrinterTlsService, String>{
      PrinterTlsService.mqtt: 'lan_cert_sha256_$serial',
      PrinterTlsService.ftps: 'ftps_cert_sha256_$host',
    };
    for (final entry in legacyKeys.entries) {
      final legacyPin = normalizeFingerprint(prefs.getString(entry.value));
      if (legacyPin == null) continue;
      final targetKey = _key(serial, host, entry.key);
      if (normalizeFingerprint(prefs.getString(targetKey)) == null) {
        await prefs.setString(targetKey, legacyPin);
      }
      await prefs.remove(entry.value);
    }
  }
}
