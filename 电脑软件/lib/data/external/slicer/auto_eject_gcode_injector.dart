import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../../core/utils/zip_safety.dart';

class AutoEjectGcodeInjectionException implements Exception {
  const AutoEjectGcodeInjectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AutoEjectGcodeInjector {
  AutoEjectGcodeInjector._();

  static const beginMarker = '; SOHUN_AUTO_EJECT_BEGIN';
  static const endMarker = '; SOHUN_AUTO_EJECT_END';

  static Future<String> inject({
    required String artifactPath,
    required int plateIndex,
    required String gcode,
    String? outputPath,
  }) async {
    final source = File(artifactPath);
    if (!await source.exists()) {
      throw const AutoEjectGcodeInjectionException('切片产物不存在，无法加入自动取件 G-code');
    }
    final script = _validateAndNormalize(gcode);
    if (artifactPath.toLowerCase().endsWith('.3mf')) {
      return _injectInto3mf(
        source,
        plateIndex: plateIndex,
        script: script,
        outputPath: outputPath,
      );
    }
    return _injectIntoPlainGcode(
      source,
      script: script,
      outputPath: outputPath,
    );
  }

  static String injectText(String source, String gcode) {
    final script = _validateAndNormalize(gcode);
    final withoutExisting = source.replaceAll(
      RegExp(
        '${RegExp.escape(beginMarker)}[\\s\\S]*?${RegExp.escape(endMarker)}\\s*',
      ),
      '',
    );
    final block = '$beginMarker\n$script\n$endMarker\n';
    final executableEnd = RegExp(
      r'^\s*;\s*EXECUTABLE_BLOCK_END\s*$',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(withoutExisting).lastOrNull;
    if (executableEnd != null) {
      return _insertAt(withoutExisting, executableEnd.start, block);
    }

    final shutdown = RegExp(
      r'^\s*M(?:18|84)(?:\s|$).*$',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(withoutExisting).lastOrNull;
    if (shutdown != null) {
      return _insertAt(withoutExisting, shutdown.start, block);
    }

    final separator =
        withoutExisting.isEmpty || withoutExisting.endsWith('\n') ? '' : '\n';
    return '$withoutExisting$separator$block';
  }

  static Future<String> _injectIntoPlainGcode(
    File source, {
    required String script,
    String? outputPath,
  }) async {
    final content = await source.readAsString();
    final output = File(outputPath ?? _outputPath(source.path));
    await output.writeAsString(injectText(content, script), flush: true);
    return output.path;
  }

  static Future<String> _injectInto3mf(
    File source, {
    required int plateIndex,
    required String script,
    String? outputPath,
  }) async {
    if (await source.length() > max3mfInputBytes) {
      throw const AutoEjectGcodeInjectionException('切片 3MF 过大，已阻止自动取件注入');
    }
    final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
    if (!isSafe3mfArchive(archive)) {
      throw const AutoEjectGcodeInjectionException('切片 3MF 未通过安全检查');
    }

    final preferred =
        plateIndex > 0 ? 'Metadata/plate_$plateIndex.gcode' : null;
    ArchiveFile? target =
        preferred == null ? null : archive.findFile(preferred);
    target ??= archive.findFile('Metadata/plate_1.gcode');
    target ??= archive.findFile('Metadata/plate.gcode');
    target ??= archive.files
        .where(
          (file) => file.isFile && file.name.toLowerCase().endsWith('.gcode'),
        )
        .firstOrNull;
    if (target == null) {
      throw const AutoEjectGcodeInjectionException('切片 3MF 内没有可注入的盘 G-code');
    }

    final rebuilt = Archive();
    for (final file in archive.files) {
      if (identical(file, target)) {
        final original = utf8.decode(
          List<int>.from(file.content as List<int>),
          allowMalformed: true,
        );
        final replacementBytes = utf8.encode(injectText(original, script));
        final replacement = ArchiveFile(
          file.name,
          replacementBytes.length,
          Uint8List.fromList(replacementBytes),
        );
        _copyMetadata(file, replacement);
        rebuilt.addFile(replacement);
      } else {
        final bytes = file.isFile
            ? Uint8List.fromList(List<int>.from(file.content as List<int>))
            : Uint8List(0);
        final copy = ArchiveFile(file.name, bytes.length, bytes)
          ..isFile = file.isFile;
        _copyMetadata(file, copy);
        rebuilt.addFile(copy);
      }
    }

    final encoded = ZipEncoder().encode(rebuilt);
    if (encoded == null) {
      throw const AutoEjectGcodeInjectionException('无法重新封装自动取件 3MF');
    }
    final output = File(outputPath ?? _outputPath(source.path));
    await output.writeAsBytes(encoded, flush: true);
    return output.path;
  }

  static void _copyMetadata(ArchiveFile source, ArchiveFile target) {
    target
      ..mode = source.mode
      ..ownerId = source.ownerId
      ..groupId = source.groupId
      ..lastModTime = source.lastModTime
      ..isFile = source.isFile
      ..isSymbolicLink = source.isSymbolicLink
      ..nameOfLinkedFile = source.nameOfLinkedFile
      ..comment = source.comment
      ..compress = source.compress;
  }

  static String _insertAt(String source, int index, String block) {
    final prefix = source.substring(0, index);
    final separator = prefix.isEmpty || prefix.endsWith('\n') ? '' : '\n';
    return '$prefix$separator$block${source.substring(index)}';
  }

  static String _validateAndNormalize(String value) {
    final normalized =
        value.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (normalized.isEmpty) {
      throw const AutoEjectGcodeInjectionException('自动取件 G-code 为空');
    }
    if (normalized.length > 64 * 1024 || normalized.contains('\u0000')) {
      throw const AutoEjectGcodeInjectionException('自动取件 G-code 无效或超过 64 KB');
    }
    return normalized;
  }

  static String _outputPath(String sourcePath) {
    final dot = sourcePath.lastIndexOf('.');
    if (dot <= 0) return '${sourcePath}_autoeject';
    return '${sourcePath.substring(0, dot)}_autoeject${sourcePath.substring(dot)}';
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
  T? get lastOrNull => isEmpty ? null : last;
}
