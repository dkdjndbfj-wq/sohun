import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AutoEjectGcodeConfig {
  const AutoEjectGcodeConfig({
    required this.enabled,
    required this.gcode,
    required this.loaded,
  });

  const AutoEjectGcodeConfig.loading()
      : enabled = false,
        gcode = '',
        loaded = false;

  final bool enabled;
  final String gcode;
  final bool loaded;

  bool get canInject => enabled && gcode.trim().isNotEmpty;
}

class AutoEjectGcodeNotifier extends StateNotifier<AutoEjectGcodeConfig> {
  AutoEjectGcodeNotifier() : super(const AutoEjectGcodeConfig.loading()) {
    ready = _load();
  }

  static const _enabledKey = 'farm_auto_eject_gcode_enabled';
  static const _gcodeKey = 'farm_auto_eject_gcode';
  static const maxGcodeLength = 64 * 1024;

  late final Future<void> ready;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    state = AutoEjectGcodeConfig(
      enabled: prefs.getBool(_enabledKey) ?? false,
      gcode: prefs.getString(_gcodeKey) ?? '',
      loaded: true,
    );
  }

  Future<void> save({required bool enabled, required String gcode}) async {
    await ready;
    final normalized = gcode.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.length > maxGcodeLength) {
      throw StateError('自动取件 G-code 不能超过 64 KB');
    }
    if (normalized.contains('\u0000')) {
      throw StateError('自动取件 G-code 含有无效字符');
    }
    if (enabled && normalized.trim().isEmpty) {
      throw StateError('启用前必须填写自动取件 G-code');
    }
    final next = AutoEjectGcodeConfig(
      enabled: enabled,
      gcode: normalized.trim(),
      loaded: true,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, next.enabled);
    await prefs.setString(_gcodeKey, next.gcode);
    if (mounted) state = next;
  }
}

final autoEjectGcodeProvider =
    StateNotifierProvider<AutoEjectGcodeNotifier, AutoEjectGcodeConfig>(
  (ref) => AutoEjectGcodeNotifier(),
);
