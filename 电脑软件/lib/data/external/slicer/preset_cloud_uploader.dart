import '../../models/print_parameter.dart';
import '../printer/bambu_cloud_client.dart';
import '../printer/bambu_cloud_models.dart';

/// 预设上传到拓竹云端的封装。
///
/// 把 [PrintParameterPreset] 转换为拓竹云端 API 要求的格式，
/// 调用 [BambuCloudClient.uploadPresetToCloud] 上传，并返回更新后的 preset
/// （含云端分配的 setting_id，保存到 `shareId` 字段）。
class PresetCloudUploader {
  /// 兜底 base_id（"0.20mm Standard @BBL X1C" 的 setting_id）。
  ///
  /// 仅在调用方未提供 base_id 时使用，覆盖最常见的 0.4 喷嘴 0.20mm 标准层高场景。
  /// 推荐通过 [BambuSystemPresetLoader.getProcessPresetSettingId] 获取真实 base_id。
  static const defaultBaseId = 'GP004';

  /// 上传预设到拓竹云端。
  ///
  /// - 已有 `shareId`（之前上传过）→ PATCH 更新
  /// - 无 `shareId`（首次上传）→ POST 新建，云端分配 setting_id
  ///
  /// [baseId]：云端系统预设 ID，用于标识"基于哪个系统预设"。
  ///   传 null 时使用 [defaultBaseId] 兜底。建议由调用方根据用户当前
  ///   选择的系统预设（`BambuSystemPresetLoader.getProcessPresetSettingId`）解析。
  ///
  /// 成功时返回更新后的 preset（shareId 已更新）。失败抛 [BambuCloudException]。
  static Future<PrintParameterPreset> upload({
    required BambuCloudSession session,
    required PrintParameterPreset preset,
    String? baseId,
  }) async {
    final settingId = preset.shareId;
    final effectiveBaseId =
        baseId?.isNotEmpty == true ? baseId! : defaultBaseId;

    // 构造 setting 字典：所有参数 + 必填的元字段
    final setting = <String, String>{
      ...preset.quality.toMap(),
      ...preset.strength.toMap(),
      ...preset.speed.toMap(),
      ...preset.support.toMap(),
      ...preset.other.toMap(),
      // 必填元字段（Bambu Studio 上传时会带这3个）
      'inherits': preset.inherits,
      'print_settings_id': preset.name,
      'updated_time':
          (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      if (preset.compatiblePrinters.isNotEmpty)
        'compatible_printers': preset.compatiblePrinters.join(','),
    };

    final newSettingId = await BambuCloudClient.uploadPresetToCloud(
      session: session,
      settingId: settingId,
      baseId: effectiveBaseId,
      name: preset.name,
      setting: setting,
    );

    // 更新 preset：保存 shareId 和 uploadedAt
    return preset.copyWith(
      shareId: newSettingId.isEmpty ? null : newSettingId,
      uploadedAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  /// 删除已上传到拓竹云端的预设。
  ///
  /// 调用拓竹云 DELETE `/v1/iot-service/api/slicer/setting/{settingId}` 接口，
  /// 成功无返回值，失败抛 [BambuCloudException]。
  ///
  /// 调用方应在删除成功后清空本地 preset 的 shareId 字段。
  static Future<void> delete({
    required BambuCloudSession session,
    required String settingId,
  }) async {
    await BambuCloudClient.deletePresetFromCloud(
      session: session,
      settingId: settingId,
    );
  }
}
