import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'mobile_rfid_writer_page.dart';
import 'rfid_native_bridge.dart';

/// Native Android shell for the already-authenticated mobile extension.
///
/// Authentication/session creation belongs to the host entrypoint. This
/// wrapper only supplies the desktop theme and the focused RFID writer page.
class MobileRfidWriterApp extends StatelessWidget {
  final RfidNativeBridge? nfc;
  final MobileInventorySync sync;
  final Future<List<String>> Function()? loadMaterials;
  final String? accountLabel;
  final ThemeMode themeMode;

  const MobileRfidWriterApp({
    super.key,
    this.nfc,
    this.sync = const NoopMobileInventorySync(),
    this.loadMaterials,
    this.accountLabel,
    this.themeMode = ThemeMode.system,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: MobileRfidWriterPage(
        nfc: nfc,
        sync: sync,
        loadMaterials: loadMaterials,
        accountLabel: accountLabel,
      ),
    );
  }
}
