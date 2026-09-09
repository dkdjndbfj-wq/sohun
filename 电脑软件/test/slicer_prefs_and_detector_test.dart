import 'dart:io';

import 'package:consumable_tracker_desktop/data/external/slicer/bambu_studio_detector.dart';
import 'package:consumable_tracker_desktop/data/prefs/slicer_prefs.dart';
import 'package:consumable_tracker_desktop/providers/slicer_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('活跃切片器 ID 可持久化并支持清除', () async {
    expect(await SlicerPrefs.getActiveSlicerId(), isNull);

    await SlicerPrefs.setActiveSlicerId('bambu_studio');
    expect(await SlicerPrefs.getActiveSlicerId(), 'bambu_studio');

    await SlicerPrefs.setActiveSlicerId(null);
    expect(await SlicerPrefs.getActiveSlicerId(), isNull);
  });

  test('活跃切片器 notifier 重启后恢复已注册 ID，未知 ID 回退默认值', () async {
    SharedPreferences.setMockInitialValues({
      'slicer_active_id': 'bambu_studio',
    });
    final restored = ActiveSlicerIdNotifier();
    addTearDown(restored.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(restored.state, 'bambu_studio');

    SharedPreferences.setMockInitialValues(
      {'slicer_active_id': 'future_slicer'},
    );
    final fallback = ActiveSlicerIdNotifier();
    addTearDown(fallback.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(fallback.state, ActiveSlicerIdNotifier.defaultId);
  });

  test('活跃切片器 notifier 拒绝未注册 ID并持久化有效选择', () async {
    final notifier = ActiveSlicerIdNotifier();
    addTearDown(notifier.dispose);

    await notifier.setId('unknown_slicer');
    expect(notifier.state, ActiveSlicerIdNotifier.defaultId);
    expect(await SlicerPrefs.getActiveSlicerId(), isNull);

    await notifier.setId('bambu_studio');
    expect(notifier.state, 'bambu_studio');
    expect(await SlicerPrefs.getActiveSlicerId(), 'bambu_studio');
  });

  test('Bambu Studio 检测器会从 App Paths 注册表兜底查找自定义安装目录', () async {
    final tempDir = await Directory.systemTemp.createTemp('bambu-detector-');
    addTearDown(() => tempDir.delete(recursive: true));
    final executable =
        await File('${tempDir.path}${Platform.pathSeparator}bambu-studio.exe')
            .create();
    final registryPath = executable.path;
    var registryCalls = 0;

    final detector = BambuStudioDetector(
      isWindows: true,
      environment: const <String, String>{},
      registryQuery: (executableName, arguments) async {
        registryCalls++;
        if (arguments.length >= 2 &&
            arguments[1].toString().contains('App Paths')) {
          return ProcessResult(
            1,
            0,
            'HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\bambu-studio.exe\n'
                '    (Default)    REG_SZ    "$registryPath"\n',
            '',
          );
        }
        return ProcessResult(1, 1, '', 'not found');
      },
    );

    expect(await detector.detectExecutable(), registryPath);
    expect(registryCalls, greaterThan(0));
  });

  test('注册表卸载项解析 DisplayIcon 参数和 InstallLocation', () {
    const output =
        '''HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Bambu Studio_is1
    DisplayName    REG_SZ    Bambu Studio
    DisplayIcon    REG_SZ    "C:\\Custom Bambu\\bambu-studio.exe,0"
    InstallLocation    REG_SZ    C:\\Custom Bambu\\
''';
    final paths = BambuStudioDetector.registryPathsFromOutput(output);
    expect(paths, hasLength(2));
    expect(paths, everyElement(r'C:\Custom Bambu\bambu-studio.exe'));
  });

  test('非 Windows 环境不会执行注册表查询', () async {
    var calls = 0;
    final detector = BambuStudioDetector(
      isWindows: false,
      environment: const <String, String>{},
      registryQuery: (executable, arguments) async {
        calls++;
        return ProcessResult(1, 1, '', '');
      },
    );

    expect(await detector.detectExecutable(), isNull);
    expect(calls, 0);
  });
}
