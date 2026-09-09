import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/theme_color.dart';
import 'data/prefs/app_prefs.dart';
import 'data/prefs/community_server_settings.dart';
import 'data/prefs/theme_prefs.dart';
import 'mobile/android_secure_session_store.dart';
import 'mobile/mobile_rfid_account_app.dart';
import 'providers/app_auth_provider.dart';

const _mobileApiBaseUrl = String.fromEnvironment(
  'APP_API_BASE_URL',
  // A phone's 127.0.0.1 is the phone itself, so the mobile target must not
  // inherit the desktop debug default. Local development can still override
  // this with --dart-define=APP_API_BASE_URL=...
  defaultValue: 'https://api.sohun.top',
);

/// Native Android entrypoint for the personal desktop-app extension.
///
/// Keep this entrypoint independent from [main.dart]: the desktop bootstrap
/// owns Windows window/tray services that must never be initialized on Android.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final themeMode = await ThemePrefs.getMode();
  final themeColor = ThemeColorDef.byName(await ThemePrefs.getColorName());
  final interactionEffectsEnabled =
      await AppPrefs.getInteractionEffectsEnabled();
  runApp(
    ProviderScope(
      overrides: [
        communityServerSettingsProvider.overrideWith(
          (ref) => CommunityServerSettings(
            store: ref.watch(communityServerOverrideStoreProvider),
            compileTimeBaseUrl: _mobileApiBaseUrl,
            allowRuntimeOverride: false,
          ),
        ),
        appAuthSessionStoreProvider.overrideWith(
          (ref) => AndroidSecureSessionStore(),
        ),
      ],
      child: MobileRfidAccountApp(
        themeMode: themeMode,
        themeColor: themeColor,
        interactionEffectsEnabled: interactionEffectsEnabled,
      ),
    ),
  );
}
