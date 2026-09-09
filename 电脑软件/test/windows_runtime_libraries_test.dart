import 'dart:io';

import 'package:consumable_tracker_desktop/core/utils/windows_runtime_libraries.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory scratch;
  late Directory source;
  late Directory target;

  Future<void> stage({bool required = true}) => stageWindowsRuntimeLibraries(
    targetDirectory: target,
    bundleDirectory: source,
    requireBundled: required,
  );

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('sohun_crt_test_');
    source = await Directory(p.join(scratch.path, 'bundle')).create();
    target = Directory(p.join(scratch.path, 'helper'));
    for (final name in windowsRuntimeRequiredFiles) {
      await File(p.join(source.path, name)).writeAsString('retail:$name');
    }
  });
  tearDown(() => scratch.delete(recursive: true));

  test('必需和可选 CRT 从安装目录释放，不复制无关 DLL', () async {
    await File(p.join(source.path, 'msvcp140_2.dll')).writeAsString('extra');
    await File(p.join(source.path, 'unrelated.dll')).writeAsString('unrelated');
    await stage();
    for (final name in windowsRuntimeRequiredFiles) {
      expect(
        await File(p.join(target.path, name)).readAsString(),
        'retail:$name',
      );
    }
    expect(
      await File(p.join(target.path, 'msvcp140_2.dll')).readAsString(),
      'extra',
    );
    expect(await File(p.join(target.path, 'unrelated.dll')).exists(), isFalse);
    expect(await target.list().length, 4);
  });

  test('已匹配 DLL 不重写，避免正在运行的组件锁冲突', () async {
    await stage();
    final file = File(p.join(target.path, windowsRuntimeRequiredFiles.first));
    await file.setLastModified(DateTime.utc(2020));
    final before = await file.lastModified();
    await stage();
    expect(await file.lastModified(), before);
  });

  test('损坏和旧版本 DLL 被安装包字节替换，临时文件清理', () async {
    await stage();
    final file = File(p.join(target.path, windowsRuntimeRequiredFiles.first));
    await file.writeAsString('corrupt');
    await stage();
    expect(
      await file.readAsString(),
      'retail:${windowsRuntimeRequiredFiles.first}',
    );
    expect(await target.list().length, windowsRuntimeRequiredFiles.length);
  });

  test('缺少必需库先拒绝，不留下半套运行目录，补齐后可重试', () async {
    final missing = File(p.join(source.path, windowsRuntimeRequiredFiles.last));
    await missing.delete();
    await expectLater(stage(), throwsStateError);
    expect(await target.exists(), isFalse);
    await missing.writeAsString('repaired');
    await stage();
    expect(
      await File(
        p.join(target.path, windowsRuntimeRequiredFiles.last),
      ).readAsString(),
      'repaired',
    );
  });

  test('空库文件不被当作有效的安装包', () async {
    await File(
      p.join(source.path, windowsRuntimeRequiredFiles.last),
    ).writeAsBytes([]);
    await expectLater(stage(), throwsStateError);
    expect(await target.exists(), isFalse);
  });

  test('开发环境无 app-local CRT 时不破坏已有运行目录', () async {
    await source.delete(recursive: true);
    await target.create();
    final file = File(p.join(target.path, 'keep.txt'));
    await file.writeAsString('keep');
    await stage(required: false);
    expect(await file.readAsString(), 'keep');
    expect(await target.list().length, 1);
  });

  test('并发释放串行复核，不互相删除临时文件', () async {
    await Future.wait(List.generate(12, (_) => stage()));
    expect(await target.list().length, windowsRuntimeRequiredFiles.length);
    for (final name in windowsRuntimeRequiredFiles) {
      expect(
        await File(p.join(target.path, name)).readAsString(),
        'retail:$name',
      );
    }
  });

  test('目标同名目录必须报错，不能递归删除或覆盖', () async {
    final obstruction = await Directory(
      p.join(target.path, windowsRuntimeRequiredFiles.first),
    ).create(recursive: true);
    final keep = File(p.join(obstruction.path, 'keep.txt'));
    await keep.writeAsString('user data');
    await expectLater(stage(), throwsStateError);
    expect(await keep.readAsString(), 'user data');
  });
}
