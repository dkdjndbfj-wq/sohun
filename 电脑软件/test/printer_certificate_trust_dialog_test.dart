import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_certificate_trust_store.dart';
import 'package:consumable_tracker_desktop/features/printers/printer_certificate_trust_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const fingerprint =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const config = PrinterConnectionConfig(
    serial: 'SERIAL-1',
    host: '192.168.1.20',
    accessCode: 'secret-code',
  );
  final probeResult = PrinterCertificateProbe(
    fingerprint: fingerprint,
    subject: '/CN=Printer',
    issuer: '/CN=Printer CA',
    startValidity: DateTime.utc(2026),
    endValidity: DateTime.utc(2036),
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('explicit confirmation stores the MQTT certificate pin',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    final confirmation = confirmPrinterCertificateTrust(
      context,
      config,
      probe: (_, __) async => probeResult,
    );
    await tester.pumpAndSettle();

    expect(find.text('确认打印机证书'), findsOneWidget);
    expect(find.textContaining('01:23:45:67:89:AB'), findsOneWidget);
    expect(find.textContaining('secret-code'), findsNothing);
    await tester.tap(find.text('信任此证书'));
    await tester.pumpAndSettle();

    expect(await confirmation, isTrue);
    final verifier = await PrinterCertificateTrustStore.loadVerifier(
      serial: config.serial,
      host: config.host,
      service: PrinterTlsService.mqtt,
    );
    expect(verifier.verifyFingerprint(fingerprint), isTrue);
  });

  testWidgets('cancelling does not store a certificate pin', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    final confirmation = confirmPrinterCertificateTrust(
      context,
      config,
      probe: (_, __) async => probeResult,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await confirmation, isFalse);
    expect(
      await PrinterCertificateTrustStore.hasTrust(
        serial: config.serial,
        host: config.host,
      ),
      isFalse,
    );
  });

  testWidgets('batch confirmation pins every selected printer in one review',
      (tester) async {
    late BuildContext context;
    const second = PrinterConnectionConfig(
      serial: 'SERIAL-2',
      host: '192.168.1.21',
      accessCode: 'another-secret',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    final confirmation = confirmPrinterCertificatesTrust(
      context,
      const [config, second],
      probe: (host, _) async => PrinterCertificateProbe(
        fingerprint: host.endsWith('20')
            ? fingerprint
            : 'a123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        subject: '/CN=Printer',
        issuer: '/CN=Printer CA',
        startValidity: DateTime.utc(2026),
        endValidity: DateTime.utc(2036),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('确认 2 台打印机证书'), findsOneWidget);
    expect(find.textContaining('secret-code'), findsNothing);
    expect(find.textContaining('another-secret'), findsNothing);
    await tester.tap(find.text('信任并批量添加'));
    await tester.pumpAndSettle();

    expect(await confirmation, isTrue);
    expect(
      await PrinterCertificateTrustStore.hasTrust(
        serial: config.serial,
        host: config.host,
      ),
      isTrue,
    );
    expect(
      await PrinterCertificateTrustStore.hasTrust(
        serial: second.serial,
        host: second.host,
      ),
      isTrue,
    );
  });
}
