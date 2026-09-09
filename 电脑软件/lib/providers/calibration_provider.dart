import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/external/calibration/bambu_studio_preset_writer.dart';
import '../data/external/printer/bambu_cloud_client.dart';
import '../data/external/printer/bambu_cloud_models.dart';
import 'bambu_cloud_provider.dart';

/// 本机 BambuStudio 用户耗材预设。
///
/// 失效后会重新扫描 `%APPDATA%\BambuStudio\user\*\filament`，因此新同步到
/// 本机的预设无需重启应用即可出现。
final bambuStudioPresetsProvider = FutureProvider<List<PresetInfo>>((ref) {
  return BambuStudioPresetWriter().listUserPresets();
});

/// 当前拓竹账号云端的用户耗材预设。
///
/// 只保留 filament/private 项；工艺与打印机预设不能作为质量优化的耗材写入目标。
final bambuCloudFilamentPresetsProvider =
    FutureProvider<List<PresetInfo>>((ref) async {
  final session = ref.watch(
    bambuCloudProvider.select((state) => state.session),
  );
  if (session == null) return const [];
  final items = await BambuCloudClient.getUserPresets(session: session);
  return calibrationCloudPresetsFromPayload(items);
});

/// 把拓竹云端原始预设响应转换成质量优化可用的耗材目标。
@visibleForTesting
List<PresetInfo> calibrationCloudPresetsFromPayload(
  Iterable<Map<String, dynamic>> items,
) {
  final result = <PresetInfo>[];
  final seen = <String>{};
  for (final item in items) {
    dynamic rawSetting = item['setting'] ??
        item['values'] ??
        item['config'] ??
        item['content'] ??
        item['detail'];
    if (rawSetting is String) {
      try {
        rawSetting = jsonDecode(rawSetting);
      } catch (_) {
        rawSetting = null;
      }
    }
    final setting = rawSetting is Map
        ? Map<String, dynamic>.from(rawSetting)
        : Map<String, dynamic>.from(item);
    final settingId = (item['setting_id'] ??
            item['settingId'] ??
            item['preset_id'] ??
            item['config_id'] ??
            item['uuid'] ??
            item['id'] ??
            setting['setting_id'])
        ?.toString();
    if (settingId == null || settingId.isEmpty || !seen.add(settingId)) {
      continue;
    }
    final type = (item['preset_type'] ?? item['type'] ?? setting['type'] ?? '')
        .toString()
        .toLowerCase();
    if (type != 'filament' && !settingId.toUpperCase().startsWith('GF')) {
      continue;
    }
    final name = (item['name'] ??
            item['setting_name'] ??
            item['title'] ??
            setting['name'] ??
            setting['filament_settings_id'] ??
            '云端耗材预设')
        .toString();
    final baseId =
        (item['base_id'] ?? item['baseId'] ?? setting['base_id'] ?? '')
            .toString();
    result.add(
      PresetInfo(
        name: name,
        filamentType: _firstCloudString(setting['filament_type']),
        vendor: _firstCloudString(setting['filament_vendor']),
        filePath: 'cloud://$settingId',
        cloudSettingId: settingId,
        cloudBaseId: baseId,
        cloudSetting: Map<String, dynamic>.unmodifiable(setting),
        cloudVersion: item['version']?.toString(),
      ),
    );
  }
  result.sort((a, b) => a.name.compareTo(b.name));
  return result;
}

String? _firstCloudString(dynamic value) {
  if (value is List) {
    if (value.isEmpty) return null;
    return value.first?.toString();
  }
  final text = value?.toString();
  return text == null || text.isEmpty ? null : text;
}

/// 合并本地与云端预设。同名同材料项合并为“本地 + 云端”，避免下拉框重复。
List<PresetInfo> mergeCalibrationPresets(
  Iterable<PresetInfo> local,
  Iterable<PresetInfo> cloud,
) {
  String key(PresetInfo preset) =>
      '${preset.name.trim().toLowerCase()}|${(preset.filamentType ?? '').trim().toLowerCase()}';

  final cloudByKey = <String, List<PresetInfo>>{};
  for (final preset in cloud) {
    cloudByKey.putIfAbsent(key(preset), () => []).add(preset);
  }
  final merged = <PresetInfo>[];
  final usedCloudIds = <String>{};
  for (final preset in local) {
    final matches = cloudByKey[key(preset)] ?? const <PresetInfo>[];
    final match = matches.isEmpty ? null : matches.first;
    if (match == null || match.cloudSettingId == null) {
      merged.add(preset);
      continue;
    }
    usedCloudIds.add(match.cloudSettingId!);
    merged.add(
      preset.withCloud(
        settingId: match.cloudSettingId!,
        baseId: match.cloudBaseId ?? '',
        setting: match.cloudSetting ?? const {},
        version: match.cloudVersion,
      ),
    );
  }
  merged.addAll(
    cloud.where(
      (preset) => !usedCloudIds.contains(preset.cloudSettingId),
    ),
  );
  merged.sort((a, b) => a.name.compareTo(b.name));
  return merged;
}

class CalibrationPresetWriteResult {
  const CalibrationPresetWriteResult({
    required this.localWritten,
    required this.cloudWritten,
    this.cloudError,
  });

  final bool localWritten;
  final bool cloudWritten;
  final Object? cloudError;
}

/// 写入质量优化字段：本地目标先自动备份；带云端身份的目标随后同步到拓竹云。
Future<CalibrationPresetWriteResult> writeCalibrationPresetFields({
  required PresetInfo preset,
  required Map<String, double> fields,
  required BambuCloudSession? session,
}) async {
  var localWritten = false;
  var cloudWritten = false;
  Object? cloudError;

  if (preset.isLocal) {
    await BambuStudioPresetWriter().writeFields(
      presetPath: preset.filePath,
      fields: fields,
    );
    localWritten = true;
  }

  if (preset.isCloudBacked) {
    try {
      if (session == null) throw StateError('拓竹云账号未登录，无法同步云端预设');
      final settingId = preset.cloudSettingId!;
      final baseId = preset.cloudBaseId;
      if (baseId == null || baseId.isEmpty) {
        throw StateError('云端预设缺少基础预设 ID，无法安全写回');
      }
      final setting = <String, String>{};
      for (final entry in (preset.cloudSetting ?? const {}).entries) {
        final encoded = _cloudSettingValue(entry.value);
        if (encoded != null) setting[entry.key] = encoded;
      }
      for (final entry in fields.entries) {
        setting[entry.key] = _formatCloudNumber(entry.value);
      }
      setting['filament_settings_id'] = preset.name;
      setting['updated_time'] =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
      await BambuCloudClient.uploadPresetToCloud(
        session: session,
        settingId: settingId,
        baseId: baseId,
        name: preset.name,
        setting: setting,
        version: preset.cloudVersion ?? '2.6.0.2',
      );
      cloudWritten = true;
    } catch (error) {
      if (!localWritten) rethrow;
      cloudError = error;
    }
  }

  return CalibrationPresetWriteResult(
    localWritten: localWritten,
    cloudWritten: cloudWritten,
    cloudError: cloudError,
  );
}

String? _cloudSettingValue(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is List) {
    if (value.isEmpty) return '';
    if (value.length == 1) return value.first?.toString() ?? '';
    return jsonEncode(value);
  }
  if (value is Map) return jsonEncode(value);
  return value.toString();
}

String _formatCloudNumber(double value) {
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}

/// 当前选中的 BambuStudio / 拓竹云预设。
final selectedPresetProvider = StateProvider<PresetInfo?>((ref) => null);

/// 单个本地预设的备份列表（key = preset filePath）。
final presetBackupsProvider = FutureProvider.family<List<BackupInfo>, String>(
  (ref, presetFilePath) {
    return BambuStudioPresetWriter().listBackups(presetFilePath);
  },
);
