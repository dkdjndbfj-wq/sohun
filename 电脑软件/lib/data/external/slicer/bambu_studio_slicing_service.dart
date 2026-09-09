import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'auto_eject_gcode_injector.dart';
import 'production_package_inspector.dart';

class BambuStudioSliceResult {
  const BambuStudioSliceResult({
    required this.outputPath,
    required this.inspection,
    required this.slicedPlateIndexes,
    required this.stdout,
    required this.stderr,
  });

  final String outputPath;
  final ProductionPackageInspection inspection;
  final List<int> slicedPlateIndexes;
  final String stdout;
  final String stderr;
}

class BambuStudioSliceException implements Exception {
  const BambuStudioSliceException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => details == null ? message : '$message：$details';
}

/// Runs the installed Bambu Studio as a separate, headless slicing engine.
///
/// The source 3MF remains untouched. The sliced 3MF is written into Sohun's
/// application-support directory so it remains available to the work order.
class BambuStudioSlicingService {
  BambuStudioSlicingService._();

  static const defaultTimeout = Duration(minutes: 30);

  /// Removes only old/surplus managed slice job directories that are no
  /// longer referenced by an order or any queue-history row.
  static Future<int> cleanupUnreferencedArtifacts({
    Set<String> protectedPaths = const {},
    Directory? outputRoot,
    Duration maxAge = const Duration(days: 90),
    int maxDirectories = 200,
    DateTime? now,
  }) async {
    final root = outputRoot ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}farm_slices',
        );
    if (!await root.exists()) return 0;
    final rootKey = _normalizedAbsolutePath(root.path);
    final protected = protectedPaths
        .where((path) => path.trim().isNotEmpty)
        .map(_normalizedAbsolutePath)
        .toSet();
    final directories = <({Directory directory, DateTime modified})>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final directoryKey = _normalizedAbsolutePath(entity.path);
      if (directoryKey == rootKey || !directoryKey.startsWith('$rootKey/')) {
        continue;
      }
      final isProtected = protected.any(
        (path) => path == directoryKey || path.startsWith('$directoryKey/'),
      );
      if (isProtected) continue;
      try {
        directories.add(
          (directory: entity, modified: (await entity.stat()).modified),
        );
      } on FileSystemException {
        // A concurrently removed or locked folder is harmless here.
      }
    }
    directories.sort((a, b) => b.modified.compareTo(a.modified));
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    var removed = 0;
    for (var index = 0; index < directories.length; index++) {
      final candidate = directories[index];
      if (index < maxDirectories && !candidate.modified.isBefore(cutoff)) {
        continue;
      }
      try {
        await candidate.directory.delete(recursive: true);
        removed++;
      } on FileSystemException {
        // Retention must never interrupt slicing or dispatch.
      }
    }
    return removed;
  }

  static String _normalizedAbsolutePath(String value) => File(value)
      .absolute
      .path
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+$'), '')
      .toLowerCase();

  /// Keeps a durable project copy for plates that will be sliced later.
  static Future<String> preserveSourceProject(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists() || !sourcePath.toLowerCase().endsWith('.3mf')) {
      throw const BambuStudioSliceException('源 3MF 已被移动或删除，无法保存待切片盘');
    }
    final inspection = await ProductionPackageInspector.inspect(sourcePath);
    if (inspection == null || inspection.productionPlates.isEmpty) {
      throw const BambuStudioSliceException('源 3MF 无法读取，不能保存到订单');
    }
    final support = await getApplicationSupportDirectory();
    final root = Directory(
      '${support.path}${Platform.pathSeparator}farm_projects',
    );
    await root.create(recursive: true);
    final hashKey = inspection.artifactSha256?.substring(0, 16) ??
        '${DateTime.now().microsecondsSinceEpoch}';
    final target = File(
      '${root.path}${Platform.pathSeparator}'
      '$hashKey-${_safeName(source.uri.pathSegments.last)}.3mf',
    );
    if (await target.exists() &&
        await target.length() == await source.length()) {
      return target.path;
    }
    await source.copy(target.path);
    return target.path;
  }

  static List<String> buildArguments({
    required String sourcePath,
    required String outputPath,
    int plateIndex = 0,
    List<String> settingsPaths = const [],
    List<String> filamentSettingsPaths = const [],
  }) {
    return [
      if (settingsPaths.isNotEmpty) ...[
        '--load-settings',
        settingsPaths.join(';'),
      ],
      if (filamentSettingsPaths.isNotEmpty) ...[
        '--load-filaments',
        filamentSettingsPaths.join(';'),
      ],
      '--slice',
      '$plateIndex',
      '--debug',
      '2',
      '--export-3mf',
      outputPath,
      sourcePath,
    ];
  }

  static List<ProductionPlateInspection> findIncompleteSourcePlates({
    required ProductionPackageInspection source,
    required ProductionPackageInspection output,
    Set<int>? expectedPlateIndexes,
  }) {
    final outputByIndex = <int, ProductionPlateInspection>{
      for (final plate in output.plates) plate.plateIndex: plate,
    };
    return source.productionPlates.where((sourcePlate) {
      if (expectedPlateIndexes != null &&
          !expectedPlateIndexes.contains(sourcePlate.plateIndex)) {
        return false;
      }
      final outputPlate = outputByIndex[sourcePlate.plateIndex];
      return outputPlate == null || !outputPlate.hasToolpath;
    }).toList(growable: false);
  }

  /// Slicing does not change which customer objects are on a plate. Keep the
  /// exact source names and quantities, while taking toolpath statistics from
  /// Bambu Studio's exported result.
  static ProductionPackageInspection applySourcePlateMetadata({
    required ProductionPackageInspection source,
    required ProductionPackageInspection output,
  }) {
    final sourceByIndex = <int, ProductionPlateInspection>{
      for (final plate in source.plates) plate.plateIndex: plate,
    };
    final plates = [
      for (final outputPlate in output.plates)
        if (sourceByIndex[outputPlate.plateIndex] case final sourcePlate?)
          ProductionPlateInspection(
            plateIndex: outputPlate.plateIndex,
            name: sourcePlate.name.trim().isNotEmpty
                ? sourcePlate.name
                : outputPlate.name,
            hasToolpath: outputPlate.hasToolpath,
            estimatedSeconds: outputPlate.estimatedSeconds,
            totalLayers: outputPlate.totalLayers,
            toolChangeCount: outputPlate.toolChangeCount,
            estimatedGrams: outputPlate.estimatedGrams,
            parts: sourcePlate.parts.isNotEmpty
                ? sourcePlate.parts
                : outputPlate.parts,
            filaments: outputPlate.filaments,
            thumbnailBytes:
                outputPlate.thumbnailBytes ?? sourcePlate.thumbnailBytes,
          )
        else
          outputPlate,
    ];
    return ProductionPackageInspection(
      artifactPath: output.artifactPath,
      displayName: source.displayName,
      kind: output.kind,
      isSliced: plates.any((plate) => plate.hasToolpath),
      requiresReview: plates.any(
        (plate) => plate.hasProductionItems && !plate.hasToolpath,
      ),
      plates: plates,
      detectedAt: output.detectedAt,
      correlationKey: source.correlationKey ?? source.artifactPath,
      projectPath: source.projectPath ?? source.artifactPath,
      slicerName: output.slicerName ?? source.slicerName,
      slicerVersion: output.slicerVersion ?? source.slicerVersion,
      targetModel: output.targetModel ?? source.targetModel,
      nozzleDiameter: output.nozzleDiameter ?? source.nozzleDiameter,
      declaredFilamentCount: source.declaredFilamentCount > 0
          ? source.declaredFilamentCount
          : output.declaredFilamentCount,
      hasEmbeddedSettings:
          output.hasEmbeddedSettings || source.hasEmbeddedSettings,
      warning: null,
      artifactSha256: output.artifactSha256,
      artifactSize: output.artifactSize,
      artifactModifiedAt: output.artifactModifiedAt,
    );
  }

  static Future<BambuStudioSliceResult> sliceProject({
    required String executablePath,
    required String sourcePath,
    int plateIndex = 0,
    Directory? outputRoot,
    String? autoEjectGcode,
    List<String> settingsPaths = const [],
    List<String> filamentSettingsPaths = const [],
    Duration timeout = defaultTimeout,
  }) async {
    final executable = File(executablePath);
    final source = File(sourcePath);
    if (!await executable.exists()) {
      throw const BambuStudioSliceException('未找到 Bambu Studio 可执行文件');
    }
    if (!await source.exists() || !sourcePath.toLowerCase().endsWith('.3mf')) {
      throw const BambuStudioSliceException('自动切片只接受已摆盘并保存参数的 3MF');
    }
    await _validateOfficialConfigurationFiles(
      settingsPaths: settingsPaths,
      filamentSettingsPaths: filamentSettingsPaths,
    );

    final sourceInspection =
        await ProductionPackageInspector.inspect(sourcePath);
    if (sourceInspection == null ||
        sourceInspection.kind != ProductionArtifactKind.bambu3mf ||
        sourceInspection.productionPlates.isEmpty) {
      throw const BambuStudioSliceException('3MF 中没有可切片的生产盘或对象');
    }
    if (!sourceInspection.hasEmbeddedSettings) {
      throw const BambuStudioSliceException(
        '3MF 缺少完整的机型、喷嘴、工艺或耗材参数，请先在 Bambu Studio 中保存',
      );
    }
    final expectedPlates = plateIndex == 0
        ? sourceInspection.productionPlates
        : sourceInspection.productionPlates
            .where((plate) => plate.plateIndex == plateIndex)
            .toList(growable: false);
    if (expectedPlates.isEmpty) {
      throw BambuStudioSliceException(
        '3MF 中不存在第 $plateIndex 盘或该盘没有生产对象',
      );
    }
    final usedFilamentTools = <int>{
      for (final plate in expectedPlates)
        for (final filament in plate.activeFilaments) filament.toolIndex,
    };
    final availableFilamentCount = sourceInspection.declaredFilamentCount > 0
        ? sourceInspection.declaredFilamentCount
        : usedFilamentTools.length;
    if (filamentSettingsPaths.length > availableFilamentCount) {
      throw BambuStudioSliceException(
        '耗材参数数量超过所选生产盘实际使用的耗材数量',
        details: 'Bambu Studio 官方 --load-filaments 要求配置数量不能超过 3MF '
            '使用的耗材数；当前导入 ${filamentSettingsPaths.length} 份，'
            '3MF 声明 $availableFilamentCount 种耗材',
      );
    }
    final expectedPlateIndexes = {
      for (final plate in expectedPlates) plate.plateIndex,
    };

    final root = outputRoot ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}farm_slices',
        );
    await root.create(recursive: true);
    final sourceName = _safeName(source.uri.pathSegments.last);
    final jobDirectory = Directory(
      '${root.path}${Platform.pathSeparator}'
      '${DateTime.now().microsecondsSinceEpoch}-$sourceName',
    );
    await jobDirectory.create(recursive: true);
    final outputLabel = plateIndex == 0 ? 'all_plates' : 'plate_$plateIndex';
    final outputPath = '${jobDirectory.path}${Platform.pathSeparator}'
        '${sourceName}_${outputLabel}_sliced.3mf';
    await File(
      '${jobDirectory.path}${Platform.pathSeparator}origin.txt',
    ).writeAsString(source.path, flush: true);

    final process = await Process.start(
      executablePath,
      buildArguments(
        sourcePath: sourcePath,
        outputPath: outputPath,
        plateIndex: plateIndex,
        settingsPaths: settingsPaths,
        filamentSettingsPaths: filamentSettingsPaths,
      ),
      workingDirectory: executable.parent.path,
      mode: ProcessStartMode.normal,
      runInShell: false,
    );
    final stdoutFuture = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderrFuture = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      throw const BambuStudioSliceException('Bambu Studio 自动切片超时');
    }
    final stdout = await stdoutFuture;
    final stderr = await stderrFuture;
    if (exitCode != 0) {
      throw BambuStudioSliceException(
        'Bambu Studio 自动切片失败（退出码 $exitCode）',
        details: _lastUsefulLine(stderr, stdout),
      );
    }

    var finalOutputPath = outputPath;
    if (autoEjectGcode?.trim().isNotEmpty == true) {
      finalOutputPath = await AutoEjectGcodeInjector.inject(
        artifactPath: outputPath,
        plateIndex: plateIndex,
        gcode: autoEjectGcode!,
      );
    }
    final rawInspection =
        await ProductionPackageInspector.inspect(finalOutputPath);
    if (rawInspection == null) {
      throw BambuStudioSliceException(
        '切片进程已结束，但没有生成可用的生产 3MF',
        details: _lastUsefulLine(stderr, stdout),
      );
    }
    final incomplete = findIncompleteSourcePlates(
      source: sourceInspection,
      output: rawInspection,
      expectedPlateIndexes: expectedPlateIndexes,
    );
    if (incomplete.isNotEmpty) {
      final names = incomplete
          .map(
            (plate) =>
                '第 ${plate.plateIndex} 盘${plate.name.trim().isEmpty ? '' : '（${plate.name.trim()}）'}',
          )
          .join('、');
      throw BambuStudioSliceException(
        plateIndex == 0
            ? 'Bambu Studio 未完成全部生产盘的切片'
            : 'Bambu Studio 未完成所选生产盘的切片',
        details: '缺少刀路：$names',
      );
    }
    final inspection = applySourcePlateMetadata(
      source: sourceInspection,
      output: rawInspection,
    );
    final slicedIndexes = inspection.plates
        .where(
          (plate) =>
              expectedPlateIndexes.contains(plate.plateIndex) &&
              plate.hasToolpath,
        )
        .map((plate) => plate.plateIndex)
        .toList(growable: false);
    if (slicedIndexes.length != expectedPlateIndexes.length) {
      throw BambuStudioSliceException(
        '切片进程已结束，但切片结果仍不完整',
        details: _lastUsefulLine(stderr, stdout),
      );
    }
    return BambuStudioSliceResult(
      outputPath: finalOutputPath,
      inspection: inspection,
      slicedPlateIndexes: slicedIndexes,
      stdout: stdout,
      stderr: stderr,
    );
  }

  static Future<void> _validateOfficialConfigurationFiles({
    required List<String> settingsPaths,
    required List<String> filamentSettingsPaths,
  }) async {
    if (settingsPaths.isNotEmpty && settingsPaths.length != 2) {
      throw const BambuStudioSliceException(
        '切片方案必须同时包含 1 份机器参数和 1 份工艺参数',
        details: 'Bambu Studio 官方 --load-settings 只接受完整 machine JSON '
            '与完整 process JSON，顺序为机器参数、工艺参数',
      );
    }

    Future<Map<String, dynamic>> readJson(String path, String label) async {
      final normalized = path.trim();
      final file = File(normalized);
      if (normalized.isEmpty || !await file.exists()) {
        throw BambuStudioSliceException('$label文件不存在', details: path);
      }
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) throw const FormatException();
        return Map<String, dynamic>.from(decoded);
      } catch (_) {
        throw BambuStudioSliceException(
          '$label不是有效的完整 JSON',
          details: path,
        );
      }
    }

    if (settingsPaths.length == 2) {
      final machine = await readJson(settingsPaths[0], '机器参数');
      final machineType = (machine['type'] as String?)?.toLowerCase();
      final isMachine = machineType == 'machine' ||
          (machine.containsKey('machine_start_gcode') &&
              machine.containsKey('nozzle_diameter'));
      if (!isMachine) {
        throw const BambuStudioSliceException(
          '--load-settings 的第 1 份配置不是完整机器参数',
          details: '请从 Bambu Studio 导出完整 machine JSON',
        );
      }
      final process = await readJson(settingsPaths[1], '工艺参数');
      if ((process['type'] as String?)?.toLowerCase() != 'process') {
        throw const BambuStudioSliceException(
          '--load-settings 的第 2 份配置不是完整工艺参数',
          details: '请从 Bambu Studio 导出完整 process JSON',
        );
      }
    }

    for (final path in filamentSettingsPaths) {
      final filament = await readJson(path, '耗材参数');
      if ((filament['type'] as String?)?.toLowerCase() != 'filament') {
        throw BambuStudioSliceException(
          '--load-filaments 中包含非耗材配置',
          details: path,
        );
      }
    }
  }

  static String _safeName(String value) {
    final withoutExtension = value.replaceFirst(
      RegExp(r'\.3mf$', caseSensitive: false),
      '',
    );
    final safe =
        withoutExtension.replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]+'), '_');
    return safe.isEmpty ? 'project' : safe;
  }

  static String? _lastUsefulLine(String stderr, String stdout) {
    final lines = '$stderr\n$stdout'
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return lines.isEmpty ? null : lines.last;
  }
}
