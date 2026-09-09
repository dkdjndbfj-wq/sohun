import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/printer_model_normalizer.dart';

class FarmPrinterModelProfile {
  const FarmPrinterModelProfile({
    required this.modelKey,
    required this.displayName,
    this.machineSettingsPath,
    this.processSettingsPath,
    this.filamentSettingsPaths = const [],
    this.nozzleDiameter = 0.4,
    this.autoEjectEnabled = false,
    this.autoEjectGcode = '',
  });

  final String modelKey;
  final String displayName;
  final String? machineSettingsPath;
  final String? processSettingsPath;
  final List<String> filamentSettingsPaths;
  final double nozzleDiameter;

  /// Kept only so older saved preferences can still be decoded.
  ///
  /// Automatic ejection is now chosen for each continuous-production batch,
  /// never enabled globally for every job targeting this printer model.
  final bool autoEjectEnabled;
  final String autoEjectGcode;

  List<String> get settingsPaths => [
        if (machineSettingsPath?.trim().isNotEmpty == true)
          machineSettingsPath!.trim(),
        if (processSettingsPath?.trim().isNotEmpty == true)
          processSettingsPath!.trim(),
      ];

  bool get hasSlicingProfile => settingsPaths.isNotEmpty;
  bool get hasAutoEjectScript => autoEjectGcode.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'modelKey': modelKey,
        'displayName': displayName,
        'machineSettingsPath': machineSettingsPath,
        'processSettingsPath': processSettingsPath,
        'filamentSettingsPaths': filamentSettingsPaths,
        'nozzleDiameter': nozzleDiameter,
        // Rewrite the retired model-wide switch as disabled. Keeping the key
        // makes the preferences format backwards compatible with old builds.
        'autoEjectEnabled': false,
        'autoEjectGcode': autoEjectGcode,
      };

  factory FarmPrinterModelProfile.fromJson(Map<String, dynamic> json) {
    final displayName = (json['displayName'] as String?)?.trim() ?? '';
    final modelKey = (json['modelKey'] as String?)?.trim();
    return FarmPrinterModelProfile(
      modelKey: modelKey?.isNotEmpty == true
          ? modelKey!
          : normalizeFarmPrinterModelKey(displayName),
      displayName: displayName,
      machineSettingsPath: json['machineSettingsPath'] as String?,
      processSettingsPath: json['processSettingsPath'] as String?,
      filamentSettingsPaths: (json['filamentSettingsPaths'] as List?)
              ?.whereType<String>()
              .where((item) => item.trim().isNotEmpty)
              .toList(growable: false) ??
          const [],
      nozzleDiameter: (json['nozzleDiameter'] as num?)?.toDouble() ?? 0.4,
      // Never restore the retired model-wide switch. The script remains
      // available as a template for an explicit per-batch decision.
      autoEjectEnabled: false,
      autoEjectGcode: json['autoEjectGcode'] as String? ?? '',
    );
  }
}

String normalizeFarmPrinterModelKey(String model) =>
    PrinterModelNormalizer.normalize(model).toLowerCase();

final farmPrinterModelProfilesProvider = StateNotifierProvider<
    FarmPrinterModelProfilesNotifier, Map<String, FarmPrinterModelProfile>>(
  (ref) => FarmPrinterModelProfilesNotifier(),
);

class FarmPrinterModelProfilesNotifier
    extends StateNotifier<Map<String, FarmPrinterModelProfile>> {
  FarmPrinterModelProfilesNotifier() : super(const {}) {
    ready = _load();
  }

  static const _key = 'farm_printer_model_profiles_v1';
  late final Future<void> ready;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      state = {
        for (final entry in decoded.entries)
          entry.key: FarmPrinterModelProfile.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      };
    } catch (_) {
      // Ignore legacy or partially-written preferences. Saving any profile
      // rewrites the complete map in the current format.
    }
  }

  FarmPrinterModelProfile profileFor(String model) {
    final key = normalizeFarmPrinterModelKey(model);
    return state[key] ??
        FarmPrinterModelProfile(modelKey: key, displayName: model);
  }

  Future<void> save(FarmPrinterModelProfile profile) async {
    final next = {...state, profile.modelKey: profile};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(next.map((key, value) => MapEntry(key, value.toJson()))),
    );
    if (mounted) state = next;
  }
}
