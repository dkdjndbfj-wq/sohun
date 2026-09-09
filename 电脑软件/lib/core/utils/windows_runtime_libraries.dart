import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

const windowsRuntimeRequiredFiles = <String>[
  'msvcp140.dll',
  'vcruntime140.dll',
  'vcruntime140_1.dll',
];

const _optionalFiles = <String>[
  'concrt140.dll',
  'msvcp140_1.dll',
  'msvcp140_2.dll',
  'msvcp140_atomic_wait.dll',
  'msvcp140_codecvt_ids.dll',
  'vcruntime140_threads.dll',
  'vccorlib140.dll',
];

final _stagingOperations = <String, Future<void>>{};

/// Copies the app's compiler-provided CRT beside an extracted Windows helper.
///
/// The caller must restrict [targetDirectory]'s ACL before calling. No DLL is
/// taken from PATH/System32. Existing matching files are left untouched (they
/// may be loaded by a running helper); replacements are verified and renamed
/// into place. Release/profile builds reject incomplete installation bundles.
/// Explicit [bundleDirectory] also allows filesystem-only tests on other OSes.
Future<void> stageWindowsRuntimeLibraries({
  required Directory targetDirectory,
  Directory? bundleDirectory,
  bool requireBundled = !kDebugMode,
}) async {
  if (!Platform.isWindows && bundleDirectory == null) return;
  final source = bundleDirectory ?? File(Platform.resolvedExecutable).parent;
  final key = p.normalize(targetDirectory.absolute.path);
  final operationKey = Platform.isWindows ? key.toLowerCase() : key;
  // Serialize, then re-check the caller's own source and strictness. A debug
  // request must not accidentally satisfy a concurrent strict release request.
  while (_stagingOperations.containsKey(operationKey)) {
    try {
      await _stagingOperations[operationKey];
    } catch (_) {
      // This caller retries independently after a failed operation.
    }
  }
  final operation = _stage(source, targetDirectory, requireBundled);
  _stagingOperations[operationKey] = operation;
  try {
    await operation;
  } finally {
    _stagingOperations.remove(operationKey);
  }
}

Future<void> _stage(Directory source, Directory target, bool required) async {
  final contents = <String, List<int>>{};
  for (final name in [...windowsRuntimeRequiredFiles, ..._optionalFiles]) {
    final file = File(p.join(source.path, name));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file || await file.length() == 0) {
      if (windowsRuntimeRequiredFiles.contains(name)) {
        if (!required)
          return; // Flutter's debug/test runner uses installed CRT.
        throw StateError('安装包缺少 Windows 运行库 $name，请重新安装完整版本');
      }
      continue;
    }
    contents[name] = await file.readAsBytes();
  }

  await target.create(recursive: true);
  for (final entry in contents.entries) {
    final file = File(p.join(target.path, entry.key));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw StateError('Windows 运行库目标不是普通文件：${entry.key}');
    }
    final expected = sha256.convert(entry.value).toString();
    if (type == FileSystemEntityType.file &&
        (await sha256.bind(file.openRead()).first).toString() == expected) {
      continue;
    }

    final staging = await target.createTemp('.crt_staging_');
    try {
      final pending = File(p.join(staging.path, entry.key));
      await pending.writeAsBytes(entry.value, flush: true);
      if ((await sha256.bind(pending.openRead()).first).toString() !=
          expected) {
        throw StateError('Windows 运行库写入校验失败：${entry.key}');
      }
      // On Windows a loaded old DLL cannot be replaced. Propagate the failure
      // instead of continuing with an incompatible mixture of runtime versions.
      await pending.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
