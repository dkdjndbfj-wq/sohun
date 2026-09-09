import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_client.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_models.dart';
import 'package:consumable_tracker_desktop/data/external/calibration/bambu_studio_preset_writer.dart';
import 'package:consumable_tracker_desktop/providers/calibration_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('云端预设列表兼容 data list 返回结构', () {
    final result = BambuCloudClient.normalizePresetList({
      'message': 'success',
      'data': {
        'list': [
          {
            'setting_id': 'GP_USER_1',
            'name': '我的工艺',
            'setting': {'layer_height': '0.2'},
          },
        ],
      },
    });

    expect(result, hasLength(1));
    expect(result.single['setting_id'], 'GP_USER_1');
  });

  test('云端预设列表兼容 setting id 为键的返回结构', () {
    final result = BambuCloudClient.normalizePresetList({
      'GP_USER_2': {
        'name': '云端强度预设',
        'setting': {'wall_loops': '4'},
      },
    });

    expect(result, hasLength(1));
    expect(result.single['setting_id'], 'GP_USER_2');
  });

  test('云端预设列表兼容官方名称为键的扁平参数结构', () {
    final result = BambuCloudClient.normalizePresetList({
      '我的 0.16mm 工艺': {
        'type': 'print',
        'setting_id': 'GP_USER_NAME_KEY',
        'base_id': 'GP004',
        'layer_height': '0.16',
      },
    });

    expect(result, hasLength(1));
    expect(result.single['name'], '我的 0.16mm 工艺');
    expect(result.single['setting_id'], 'GP_USER_NAME_KEY');
  });

  test('云端预设列表会展开按类型分组的全部预设', () {
    final result = BambuCloudClient.normalizePresetList({
      'message': 'success',
      'result': {
        'process': [
          {
            'settingId': 'GP_USER_3',
            'name': '精细工艺',
            'setting': {'layer_height': '0.12'},
          },
          {
            'setting_id': 'GP_USER_4',
            'name': '强度工艺',
            'setting': {'wall_loops': '5'},
          },
        ],
        'machine': {
          'GM_USER_1': {
            'name': '我的打印机',
            'config': {'printer_model': 'A1'},
          },
        },
      },
    });

    expect(result, hasLength(3));
    expect(
      result.map((item) => item['setting_id']),
      containsAll(['GP_USER_3', 'GP_USER_4', 'GM_USER_1']),
    );
  });

  test('重复嵌套的云端预设按 setting id 去重', () {
    final preset = {
      'preset_id': 'GP_DUPLICATE',
      'name': '重复工艺',
      'values': {'layer_height': '0.2'},
    };
    final result = BambuCloudClient.normalizePresetList({
      'settings': [preset],
      'data': {
        'list': [preset],
      },
    });

    expect(result, hasLength(1));
  });

  test('云端预设请求会携带配置版本参数', () {
    final session = BambuCloudSession(
      region: BambuRegion.china,
      email: 'test@example.com',
      accessToken: 'token',
      username: 'u_1',
      loginAt: DateTime(2026, 7, 27),
    );

    final uri = BambuCloudClient.buildUserPresetsUri(session);

    expect(uri.path, '/v1/iot-service/api/slicer/setting');
    expect(uri.queryParameters['version'], '2.6.0.2');
  });

  test('我的预设只读取 private 分组并保留类型和基础预设名称', () {
    final result = BambuCloudClient.normalizePrivatePresetList({
      'print': {
        'public': [
          {'setting_id': 'GP_BASE', 'name': '0.20mm @BBL X1C'},
        ],
        'private': [
          {
            'setting_id': 'GP_USER',
            'name': '我的工艺',
            'base_id': 'GP_BASE',
          },
        ],
      },
      'filament': {
        'public': [
          {'setting_id': 'GF_BASE', 'name': 'Bambu PLA Silk @base'},
        ],
        'private': [
          {
            'setting_id': 'GF_USER',
            'name': '我的耗材',
            'base_id': 'GF_BASE',
          },
        ],
      },
      'printer': {'public': [], 'private': []},
    });

    expect(result, hasLength(2));
    expect(result.map((item) => item['setting_id']), ['GP_USER', 'GF_USER']);
    expect(result.first['preset_type'], 'print');
    expect(result.first['base_name'], '0.20mm @BBL X1C');
    expect(result.last['preset_type'], 'filament');
  });

  test('质量优化只接收云端耗材预设并保留完整写回信息', () {
    final presets = calibrationCloudPresetsFromPayload([
      {
        'setting_id': 'GF_USER',
        'preset_type': 'filament',
        'name': '我的 PLA',
        'base_id': 'GF_BASE',
        'version': '2.6.0.2',
        'setting': {
          'filament_type': ['PLA'],
          'filament_vendor': ['Bambu Lab'],
          'filament_flow_ratio': ['0.98'],
        },
      },
      {
        'setting_id': 'GP_USER',
        'preset_type': 'print',
        'name': '我的工艺',
        'base_id': 'GP_BASE',
        'setting': {'layer_height': '0.2'},
      },
    ]);

    expect(presets, hasLength(1));
    expect(presets.single.name, '我的 PLA');
    expect(presets.single.filamentType, 'PLA');
    expect(presets.single.cloudSettingId, 'GF_USER');
    expect(presets.single.cloudBaseId, 'GF_BASE');
    expect(presets.single.isCloudOnly, isTrue);
  });

  test('同名本地与云端耗材预设会合并为同一个同步目标', () {
    const local = PresetInfo(
      name: '我的 PLA',
      filamentType: 'PLA',
      filePath: r'C:\BambuStudio\user\filament\my-pla.json',
    );
    const cloud = PresetInfo(
      name: '我的 PLA',
      filamentType: 'PLA',
      filePath: 'cloud://GF_USER',
      cloudSettingId: 'GF_USER',
      cloudBaseId: 'GF_BASE',
      cloudSetting: {'filament_flow_ratio': '0.98'},
    );

    final merged = mergeCalibrationPresets([local], [cloud]);

    expect(merged, hasLength(1));
    expect(merged.single.filePath, local.filePath);
    expect(merged.single.isLocal, isTrue);
    expect(merged.single.isCloudBacked, isTrue);
  });
}
