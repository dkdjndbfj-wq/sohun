import 'dart:io';

import 'bambu_studio_detector.dart';

enum BambuStudioEditorLaunchStatus {
  opened,
  missingSource,
  missingExecutable,
  failed,
}

class BambuStudioEditorLaunchResult {
  const BambuStudioEditorLaunchResult({
    required this.status,
    this.executablePath,
    this.error,
  });

  final BambuStudioEditorLaunchStatus status;
  final String? executablePath;
  final Object? error;

  bool get opened => status == BambuStudioEditorLaunchStatus.opened;
}

/// Starts the official Bambu Studio GUI in its own native window.
///
/// Bambu Studio owns the wxWidgets/OpenGL model editor and libSlic3r
/// pipeline. Keeping that native surface as a separate process preserves the
/// same arrange, orient, cut, support and paint behavior users get in Bambu.
class BambuStudioEditorService {
  BambuStudioEditorService._();

  static Future<BambuStudioEditorLaunchResult> openProject(String sourcePath,
      [String? configuredExecutable]) async {
    final normalized = sourcePath.trim();
    final source = File(normalized);
    if (normalized.isEmpty ||
        !await source.exists() ||
        !normalized.toLowerCase().endsWith('.3mf')) {
      return const BambuStudioEditorLaunchResult(
        status: BambuStudioEditorLaunchStatus.missingSource,
      );
    }

    final configured = configuredExecutable?.trim();
    final executable = configured == null || configured.isEmpty
        ? await BambuStudioDetector().detectExecutable()
        : await _existingExecutable(configured);
    if (executable == null) {
      return const BambuStudioEditorLaunchResult(
        status: BambuStudioEditorLaunchStatus.missingExecutable,
      );
    }

    try {
      await Process.start(
        executable,
        <String>[source.path],
        workingDirectory: File(executable).parent.path,
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
      return BambuStudioEditorLaunchResult(
        status: BambuStudioEditorLaunchStatus.opened,
        executablePath: executable,
      );
    } catch (error) {
      return BambuStudioEditorLaunchResult(
        status: BambuStudioEditorLaunchStatus.failed,
        executablePath: executable,
        error: error,
      );
    }
  }

  static Future<String?> _existingExecutable(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    if (!path.toLowerCase().endsWith('.exe')) return null;
    return file.path;
  }
}
