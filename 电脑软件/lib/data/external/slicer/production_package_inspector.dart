import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

import '../../../core/services/slice_artifact_hash_service.dart';
import '../../../core/utils/zip_safety.dart';
import 'bambu_slice_metadata.dart';

/// The unit that enters the farm workflow. A Bambu project can contain more
/// than one plate, so the project and each plate are kept separate.
enum ProductionArtifactKind { bambu3mf, gcode, unknown }

String? _meaningfulItemName(String? value) {
  final name = value?.trim() ?? '';
  if (name.isEmpty) return null;
  final generated = [
    RegExp(r'^(?:object|model)\s*[-_#]?\s*\d+$', caseSensitive: false),
    RegExp(r'^(?:对象|模型)\s*[-_#]?\s*\d+$'),
    RegExp(r'^default\s*[-_#]?\s*\d+$', caseSensitive: false),
  ];
  return generated.any((pattern) => pattern.hasMatch(name)) ? null : name;
}

String? _firstMeaningfulName(Iterable<String?> values) {
  for (final value in values) {
    final name = _meaningfulItemName(value);
    if (name != null) return name;
  }
  return null;
}

String _preferredItemName(String current, String other) =>
    _firstMeaningfulName([current, other]) ?? '未命名模型';

String? _sourceDisplayName(String? path) {
  final value = path?.trim() ?? '';
  if (value.isEmpty) return null;
  final fileName = value.split(RegExp(r'[/\\]')).last.trim();
  if (fileName.isEmpty) return null;
  final withoutExtension = fileName.replaceFirst(
    RegExp(r'\.(3mf|stl|step|stp|obj|amf)$', caseSensitive: false),
    '',
  );
  return _meaningfulItemName(withoutExtension);
}

String _bestObjectName({
  required String? objectName,
  required List<_PartInfo> parts,
  required String projectDisplayName,
}) {
  final original = _meaningfulItemName(objectName);
  if (original != null) return original;

  final sourceNames = <String>{
    for (final part in parts)
      if (_sourceDisplayName(part.sourceFile) case final name?) name,
  };
  if (sourceNames.length == 1) return sourceNames.single;

  final partNames = <String>{
    for (final part in parts)
      if (_meaningfulItemName(part.name) case final name?) name,
  };
  if (partNames.length == 1) return partNames.single;
  if (sourceNames.isNotEmpty) return sourceNames.first;

  return _meaningfulItemName(projectDisplayName) ?? '未命名模型';
}

class ProductionPackageInspection {
  const ProductionPackageInspection({
    required this.artifactPath,
    required this.displayName,
    required this.kind,
    required this.isSliced,
    required this.requiresReview,
    required this.plates,
    required this.detectedAt,
    this.correlationKey,
    this.projectPath,
    this.slicerName,
    this.slicerVersion,
    this.targetModel,
    this.nozzleDiameter,
    this.declaredFilamentCount = 0,
    this.hasEmbeddedSettings = false,
    this.warning,
    this.artifactSha256,
    this.artifactSize,
    this.artifactModifiedAt,
  });

  final String artifactPath;
  final String displayName;
  final ProductionArtifactKind kind;
  final bool isSliced;
  final bool requiresReview;
  final List<ProductionPlateInspection> plates;
  final DateTime detectedAt;
  final String? correlationKey;
  final String? projectPath;
  final String? slicerName;
  final String? slicerVersion;
  final String? targetModel;
  final double? nozzleDiameter;
  final int declaredFilamentCount;
  final bool hasEmbeddedSettings;
  final String? warning;
  final String? artifactSha256;
  final int? artifactSize;
  final DateTime? artifactModifiedAt;

  List<ProductionPlateInspection> get productionPlates =>
      plates.where((plate) => plate.hasProductionItems).toList(growable: false);

  List<ProductionPlateInspection> get incompletePlates => productionPlates
      .where((plate) => !plate.hasToolpath)
      .toList(growable: false);

  bool get isFullySliced =>
      productionPlates.isNotEmpty && incompletePlates.isEmpty;

  bool get hasAnySlicedPlate =>
      productionPlates.any((plate) => plate.hasToolpath);

  /// A partially sliced multi-plate project is still a useful artifact: each
  /// sliced plate can be scheduled independently while the other plates wait.
  bool get isUsable => hasAnySlicedPlate;

  ProductionPackageInspection merge(ProductionPackageInspection other) {
    if (correlationKey == null || correlationKey != other.correlationKey) {
      return this;
    }
    final byIndex = <int, ProductionPlateInspection>{
      for (final plate in plates) plate.plateIndex: plate,
    };
    for (final plate in other.plates) {
      final existing = byIndex[plate.plateIndex];
      byIndex[plate.plateIndex] =
          existing == null ? plate : existing.merge(plate);
    }
    final merged = byIndex.values.toList()
      ..sort((a, b) => a.plateIndex.compareTo(b.plateIndex));
    return ProductionPackageInspection(
      artifactPath: artifactPath,
      displayName: displayName,
      kind: kind,
      isSliced: merged.any((plate) => plate.hasToolpath),
      requiresReview: merged.any(
            (plate) =>
                plate.hasProductionItems &&
                (!plate.hasToolpath ||
                    plate.parts.any((part) => part.instancesPerRun <= 0)),
          ) ||
          (requiresReview && other.requiresReview),
      plates: merged,
      detectedAt:
          detectedAt.isBefore(other.detectedAt) ? detectedAt : other.detectedAt,
      correlationKey: correlationKey,
      projectPath: projectPath ?? other.projectPath,
      slicerName: slicerName ?? other.slicerName,
      slicerVersion: slicerVersion ?? other.slicerVersion,
      targetModel: targetModel ?? other.targetModel,
      nozzleDiameter: nozzleDiameter ?? other.nozzleDiameter,
      declaredFilamentCount:
          math.max(declaredFilamentCount, other.declaredFilamentCount),
      hasEmbeddedSettings: hasEmbeddedSettings || other.hasEmbeddedSettings,
      warning: warning ?? other.warning,
      artifactSha256: artifactSha256 ?? other.artifactSha256,
      artifactSize: artifactSize ?? other.artifactSize,
      artifactModifiedAt: artifactModifiedAt ?? other.artifactModifiedAt,
    );
  }
}

class ProductionPlateInspection {
  const ProductionPlateInspection({
    required this.plateIndex,
    required this.name,
    required this.hasToolpath,
    required this.estimatedSeconds,
    required this.totalLayers,
    required this.toolChangeCount,
    required this.estimatedGrams,
    required this.parts,
    required this.filaments,
    this.thumbnailBytes,
  });

  final int plateIndex;
  final String name;
  final bool hasToolpath;
  final int estimatedSeconds;
  final int totalLayers;
  final int toolChangeCount;
  final double estimatedGrams;
  final List<ProductionPartInspection> parts;
  final List<ProductionFilamentInspection> filaments;
  final Uint8List? thumbnailBytes;

  List<ProductionFilamentInspection> get activeFilaments {
    final byTool = <int, ProductionFilamentInspection>{};
    for (final item in filaments.where((item) => item.isActive)) {
      final existing = byTool[item.toolIndex];
      byTool[item.toolIndex] =
          existing == null ? item : existing.mergeUsage(item);
    }
    final result = byTool.values.toList()
      ..sort((a, b) => a.toolIndex.compareTo(b.toolIndex));
    return result;
  }

  bool get isMulticolor => activeFilaments.length > 1;

  bool get hasProductionItems => parts.any((part) => part.instancesPerRun > 0);

  int get instanceCount => parts.fold<int>(
        0,
        (sum, part) => sum + part.instancesPerRun,
      );

  String get displayName {
    final original = name.trim();
    return original.isEmpty ? '第 $plateIndex 盘' : original;
  }

  ProductionPlateInspection merge(ProductionPlateInspection other) {
    final partMap = <String, ProductionPartInspection>{
      for (final part in parts) part.key: part,
    };
    for (final part in other.parts) {
      final existing = partMap[part.key];
      partMap[part.key] = existing == null ? part : existing.merge(part);
    }
    return ProductionPlateInspection(
      plateIndex: plateIndex,
      name: name.isNotEmpty ? name : other.name,
      hasToolpath: hasToolpath || other.hasToolpath,
      estimatedSeconds:
          estimatedSeconds > 0 ? estimatedSeconds : other.estimatedSeconds,
      totalLayers: totalLayers > 0 ? totalLayers : other.totalLayers,
      toolChangeCount:
          toolChangeCount > 0 ? toolChangeCount : other.toolChangeCount,
      estimatedGrams:
          estimatedGrams > 0 ? estimatedGrams : other.estimatedGrams,
      parts: partMap.values.toList(),
      filaments: filaments.isNotEmpty ? filaments : other.filaments,
      thumbnailBytes: thumbnailBytes ?? other.thumbnailBytes,
    );
  }
}

class ProductionPartInspection {
  const ProductionPartInspection({
    required this.key,
    required this.name,
    required this.instancesPerRun,
    this.sourceFile,
    this.sourceObjectId,
    this.componentNames = const [],
  });

  final String key;
  final String name;
  final int instancesPerRun;
  final String? sourceFile;
  final String? sourceObjectId;
  final List<String> componentNames;

  /// Combines metadata for the same production item from two inspections.
  /// Counts describe the same physical instances, so they must not be added.
  ProductionPartInspection merge(ProductionPartInspection other) {
    return ProductionPartInspection(
      key: key,
      name: _preferredItemName(name, other.name),
      instancesPerRun: instancesPerRun >= other.instancesPerRun
          ? instancesPerRun
          : other.instancesPerRun,
      sourceFile: sourceFile ?? other.sourceFile,
      sourceObjectId: sourceObjectId ?? other.sourceObjectId,
      componentNames: {...componentNames, ...other.componentNames}.toList(),
    );
  }

  /// Adds repeated model instances while parsing a single plate.
  ProductionPartInspection addInstances(ProductionPartInspection other) {
    return ProductionPartInspection(
      key: key,
      name: _preferredItemName(name, other.name),
      instancesPerRun: instancesPerRun + other.instancesPerRun,
      sourceFile: sourceFile ?? other.sourceFile,
      sourceObjectId: sourceObjectId ?? other.sourceObjectId,
      componentNames: {...componentNames, ...other.componentNames}.toList(),
    );
  }
}

class ProductionFilamentInspection {
  const ProductionFilamentInspection({
    required this.toolIndex,
    required this.grams,
    this.vendor,
    this.materialType,
    this.colorHex,
    this.trayId,
    this.sku,
    this.usedForObject,
    this.usedForSupport,
    this.groupId,
    this.nozzleDiameter,
    this.volumeType,
  });

  final int toolIndex;
  final double grams;
  final String? vendor;
  final String? materialType;
  final String? colorHex;
  final int? trayId;
  final String? sku;
  final bool? usedForObject;
  final bool? usedForSupport;
  final int? groupId;
  final double? nozzleDiameter;
  final String? volumeType;

  bool get isActive => grams > 0.01;

  ProductionFilamentInspection mergeUsage(
    ProductionFilamentInspection other,
  ) =>
      ProductionFilamentInspection(
        toolIndex: toolIndex,
        grams: grams + other.grams,
        vendor: vendor ?? other.vendor,
        materialType: materialType ?? other.materialType,
        colorHex: colorHex ?? other.colorHex,
        trayId: trayId ?? other.trayId,
        sku: sku ?? other.sku,
        usedForObject: _mergeInspectionFlag(
          usedForObject,
          other.usedForObject,
        ),
        usedForSupport: _mergeInspectionFlag(
          usedForSupport,
          other.usedForSupport,
        ),
        groupId: groupId ?? other.groupId,
        nozzleDiameter: nozzleDiameter ?? other.nozzleDiameter,
        volumeType: volumeType ?? other.volumeType,
      );
}

bool? _mergeInspectionFlag(bool? first, bool? second) {
  if (first == true || second == true) return true;
  if (first == false && second == false) return false;
  return first ?? second;
}

/// Reads Bambu Studio's project metadata without extracting the full archive.
/// It deliberately marks ambiguous/unsliced inputs for human confirmation.
class ProductionPackageInspector {
  ProductionPackageInspector._();

  static Future<ProductionPackageInspection?> inspect(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.3mf')) return _inspect3mf(file);
    if (lower.endsWith('.gcode') ||
        lower.endsWith('.g') ||
        lower.endsWith('.gc')) {
      return _inspectGcode(file);
    }
    return null;
  }

  static Future<ProductionPackageInspection?> _inspectGcode(File file) async {
    final project = await _nearbyProject(file);
    if (project != null) {
      final projectInspection = await _inspect3mf(project);
      if (projectInspection != null) {
        final index = _plateIndexFromGcode(file.path);
        final plate = projectInspection.plates
            .where((item) => item.plateIndex == index)
            .firstOrNull;
        final selected = plate == null
            ? projectInspection.plates.take(1).toList()
            : <ProductionPlateInspection>[plate];
        return ProductionPackageInspection(
          artifactPath: file.path,
          displayName: _withoutExtension(file.path),
          kind: ProductionArtifactKind.gcode,
          isSliced: true,
          requiresReview: projectInspection.requiresReview,
          plates: selected
              .map(
                (item) => ProductionPlateInspection(
                  plateIndex: item.plateIndex,
                  name: item.name,
                  hasToolpath: true,
                  estimatedSeconds: item.estimatedSeconds,
                  totalLayers: item.totalLayers,
                  toolChangeCount: item.toolChangeCount,
                  estimatedGrams: item.estimatedGrams,
                  parts: item.parts,
                  filaments: item.filaments,
                ),
              )
              .toList(),
          detectedAt: DateTime.now(),
          correlationKey: await _readOrigin(file) ?? project.path,
          projectPath: project.path,
          slicerName: projectInspection.slicerName,
          slicerVersion: projectInspection.slicerVersion,
          targetModel: projectInspection.targetModel,
          nozzleDiameter: projectInspection.nozzleDiameter,
          hasEmbeddedSettings: projectInspection.hasEmbeddedSettings,
          warning: projectInspection.warning,
          artifactSize: await file.length(),
          artifactModifiedAt: (await file.stat()).modified,
        );
      }
    }

    final stat = await file.stat();
    return ProductionPackageInspection(
      artifactPath: file.path,
      displayName: _withoutExtension(file.path),
      kind: ProductionArtifactKind.gcode,
      isSliced: true,
      requiresReview: true,
      plates: [
        ProductionPlateInspection(
          plateIndex: _plateIndexFromGcode(file.path),
          name: _withoutExtension(file.path),
          hasToolpath: true,
          estimatedSeconds: 0,
          totalLayers: 0,
          toolChangeCount: 0,
          estimatedGrams: 0,
          parts: [
            ProductionPartInspection(
              key: 'gcode:${file.path}',
              name: _withoutExtension(file.path),
              instancesPerRun: 1,
            ),
          ],
          filaments: const [],
        ),
      ],
      detectedAt: DateTime.now(),
      correlationKey: await _readOrigin(file) ?? file.path,
      warning: '未找到项目元数据，只能识别为单盘 G-code，请确认零件数量。',
      artifactSize: await file.length(),
      artifactModifiedAt: stat.modified,
    );
  }

  static Future<ProductionPackageInspection?> _inspect3mf(File file) async {
    // Personal projects can legitimately contain high-resolution meshes. The
    // inspector uses lazy ZIP entries and only expands metadata, so permit a
    // larger container and model entries here while keeping all non-model
    // expansion limits in place.
    if (!await isSafe3mfFile(file, maxInputBytes: 512 * 1024 * 1024)) {
      return null;
    }
    InputFileStream? input;
    try {
      // Keep the ZIP file-backed.  Only the small metadata and thumbnail
      // entries are expanded; object meshes can be hundreds of megabytes.
      input = InputFileStream(file.path);
      final archive = ZipDecoder().decodeBuffer(input);
      if (!isSafe3mfArchive(archive, allowLargeModelEntries: true)) return null;
      return await _inspect3mfArchive(file, archive);
    } catch (_) {
      return null;
    } finally {
      input?.closeSync();
    }
  }

  static Future<ProductionPackageInspection?> _inspect3mfArchive(
    File file,
    Archive archive,
  ) async {
    final settings =
        _parseXml(archive.findFile('Metadata/model_settings.config'));
    final sliceInfo = _parseXml(archive.findFile('Metadata/slice_info.config'));
    final projectSettings = _parseJsonObject(
      archive.findFile('Metadata/project_settings.config'),
    );
    final projectDisplayName = _withoutExtension(file.path);
    final objects = _readObjects(settings, projectDisplayName);
    final modelPlates = _readModelPlates(settings, objects);
    final slicePlates = _readSlicePlates(
      sliceInfo,
      archive,
      projectSettings,
    );
    final toolpathIndexes = <int>{};
    for (final entry in archive) {
      final match =
          RegExp(r'^Metadata/plate_(\d+)\.gcode$', caseSensitive: false)
              .firstMatch(entry.name);
      if (match != null) {
        toolpathIndexes.add(int.parse(match.group(1)!));
      }
    }
    if (archive.findFile('Metadata/plate.gcode') != null) {
      toolpathIndexes.add(1);
    }

    final indexes = <int>{
      ...modelPlates.keys,
      ...slicePlates.keys,
      ...toolpathIndexes,
    }.toList()
      ..sort();
    if (indexes.isEmpty) {
      final sourcePlate = _readStandard3mfPlate(
        archive,
        projectDisplayName,
      );
      if (sourcePlate == null) return null;
      modelPlates[sourcePlate.index] = sourcePlate;
      indexes.add(sourcePlate.index);
    }

    final plates = <ProductionPlateInspection>[];
    for (final index in indexes) {
      final model = modelPlates[index];
      final slice = slicePlates[index];
      final toolpath = toolpathIndexes.contains(index);
      final thumbnailPath = slice?.thumbnailPath ?? 'Metadata/plate_$index.png';
      final thumb = archive.findFile(thumbnailPath);
      final parts = model?.parts ??
          [
            ProductionPartInspection(
              key: 'plate:$index',
              name: _firstMeaningfulName([
                    slice?.name,
                    projectDisplayName,
                  ]) ??
                  '未命名模型',
              instancesPerRun: 1,
            ),
          ];
      plates.add(
        ProductionPlateInspection(
          plateIndex: index,
          name: _firstMeaningfulName([model?.name, slice?.name]) ?? '',
          hasToolpath: toolpath,
          estimatedSeconds: slice?.estimatedSeconds ?? 0,
          totalLayers: slice?.totalLayers ?? 0,
          toolChangeCount: slice?.toolChangeCount ?? 0,
          estimatedGrams: slice?.estimatedGrams ?? 0,
          parts: parts,
          filaments: slice?.filaments ?? const [],
          thumbnailBytes: thumb == null
              ? null
              : Uint8List.fromList(thumb.content as List<int>),
        ),
      );
    }
    final stat = await file.stat();
    final artifact = await SliceArtifactHashService.computeStable(file.path);
    final origin = await _readOrigin(file);
    final productionPlates =
        plates.where((plate) => plate.hasProductionItems).toList();
    final hasSlicedPlate = productionPlates.any((plate) => plate.hasToolpath);
    final isFullySliced = productionPlates.isNotEmpty &&
        productionPlates.every((plate) => plate.hasToolpath);
    final needsReview = !isFullySliced ||
        plates.any(
          (plate) =>
              (plate.hasProductionItems && !plate.hasToolpath) ||
              plate.parts.any((part) => part.instancesPerRun <= 0),
        );
    final hasBambuMetadata = settings != null || projectSettings != null;
    final embeddedSettingsComplete =
        _hasCompleteEmbeddedSettings(projectSettings);
    return ProductionPackageInspection(
      artifactPath: file.path,
      displayName: _withoutExtension(file.path),
      kind: ProductionArtifactKind.bambu3mf,
      isSliced: hasSlicedPlate,
      requiresReview: needsReview,
      plates: plates,
      detectedAt: DateTime.now(),
      correlationKey: origin ?? file.path,
      projectPath: origin ?? file.path,
      slicerName: _headerValue(sliceInfo, 'X-BBL-Application-Name') ??
          _metadataValue(_rootMetadata(settings, 'application')) ??
          (hasBambuMetadata ? 'Bambu Studio' : '3MF'),
      slicerVersion: _headerValue(sliceInfo, 'X-BBL-Client-Version') ??
          _metadataValue(_rootMetadata(settings, 'version')) ??
          _projectText(projectSettings, 'version'),
      targetModel: _projectText(projectSettings, 'printer_model'),
      nozzleDiameter: _projectDouble(projectSettings, 'nozzle_diameter') ??
          _projectDouble(projectSettings, 'printer_variant'),
      declaredFilamentCount: _declaredFilamentCount(projectSettings),
      hasEmbeddedSettings: embeddedSettingsComplete,
      warning: !isFullySliced ? '已读取 3MF 内的原始盘名、对象名和实例；仍有盘未完成切片。' : null,
      artifactSha256: artifact?.sha256Hex,
      artifactSize: artifact?.size ?? await file.length(),
      artifactModifiedAt: artifact?.modifiedAt ?? stat.modified,
    );
  }

  static Map<String, _ObjectInfo> _readObjects(
    XmlDocument? doc,
    String projectDisplayName,
  ) {
    final result = <String, _ObjectInfo>{};
    if (doc == null) return result;
    for (final object in doc.findAllElements('object')) {
      final id = object.getAttribute('id');
      if (id == null) continue;
      final rawObjectName = _elementMetadata(object, 'name');
      final parts = object.findElements('part').map((part) {
        return _PartInfo(
          name: _elementMetadata(part, 'name') ?? rawObjectName ?? '',
          sourceFile: _elementMetadata(part, 'source_file'),
          sourceObjectId: _elementMetadata(part, 'source_object_id'),
        );
      }).toList();
      final name = _bestObjectName(
        objectName: rawObjectName,
        parts: parts,
        projectDisplayName: projectDisplayName,
      );
      result[id] = _ObjectInfo(id: id, name: name, parts: parts);
    }
    return result;
  }

  static Map<int, _ModelPlateInfo> _readModelPlates(
    XmlDocument? doc,
    Map<String, _ObjectInfo> objects,
  ) {
    final result = <int, _ModelPlateInfo>{};
    if (doc == null) return result;
    for (final plate in doc.findAllElements('plate')) {
      final index = int.tryParse(
            _elementMetadata(plate, 'plater_id') ??
                _elementMetadata(plate, 'index') ??
                '',
          ) ??
          1;
      final groups = <String, ProductionPartInspection>{};
      for (final instance in plate.findElements('model_instance')) {
        final objectId = _elementMetadata(instance, 'object_id');
        if (objectId == null) continue;
        final object = objects[objectId];
        if (object == null) continue;
        // A Bambu object can contain several material parts. Those parts are
        // components of one produced object, not separate customer items.
        final source = object.parts.firstOrNull;
        // Keep different Bambu objects separate even if they came from the
        // same STL. They can have different scales or object-level settings.
        final sourceKey = 'object:$objectId';
        final current = groups[sourceKey];
        final item = ProductionPartInspection(
          key: sourceKey,
          name: object.name,
          instancesPerRun: 1,
          sourceFile: source?.sourceFile,
          sourceObjectId: source?.sourceObjectId,
          componentNames: object.parts.map((part) => part.name).toList(),
        );
        groups[sourceKey] = current == null ? item : current.addInstances(item);
      }
      result[index] = _ModelPlateInfo(
        index: index,
        name: _elementMetadata(plate, 'plater_name') ?? '',
        parts: groups.values.toList(),
      );
    }
    return result;
  }

  static _ModelPlateInfo? _readStandard3mfPlate(
    Archive archive,
    String projectDisplayName,
  ) {
    final modelFile = archive.files
        .where(
          (file) => file.name.toLowerCase().endsWith('3dmodel.model'),
        )
        .firstOrNull;
    final doc = _parseXml(modelFile);
    if (doc == null) return null;

    final objectNames = <String, String>{};
    for (final object in doc.descendants.whereType<XmlElement>()) {
      if (object.name.local != 'object') continue;
      final id = object.getAttribute('id');
      if (id == null) continue;
      objectNames[id] = _firstMeaningfulName([
            object.getAttribute('name'),
            projectDisplayName,
          ]) ??
          '未命名模型';
    }
    if (objectNames.isEmpty) return null;

    final instanceCounts = <String, int>{};
    for (final item in doc.descendants.whereType<XmlElement>()) {
      if (item.name.local != 'item') continue;
      final objectId = item.getAttribute('objectid');
      if (objectId == null || !objectNames.containsKey(objectId)) continue;
      instanceCounts[objectId] = (instanceCounts[objectId] ?? 0) + 1;
    }
    if (instanceCounts.isEmpty) {
      for (final objectId in objectNames.keys) {
        instanceCounts[objectId] = 1;
      }
    }

    return _ModelPlateInfo(
      index: 1,
      name: '待在 Bambu Studio 中排版',
      parts: [
        for (final entry in instanceCounts.entries)
          ProductionPartInspection(
            key: 'object:${entry.key}',
            name: objectNames[entry.key]!,
            instancesPerRun: entry.value,
            sourceObjectId: entry.key,
          ),
      ],
    );
  }

  static Map<int, _SlicePlateInfo> _readSlicePlates(
    XmlDocument? doc,
    Archive archive,
    Map<String, dynamic>? projectSettings,
  ) {
    final result = <int, _SlicePlateInfo>{};
    if (doc == null) return result;
    final configuredVendors = _projectStrings(
      projectSettings,
      'filament_vendor',
    );
    final configuredTypes = _projectStrings(
      projectSettings,
      'filament_type',
    );
    final configuredPresetIds = _projectStrings(
      projectSettings,
      'filament_settings_id',
    );
    for (final plate in doc.findAllElements('plate')) {
      final index = int.tryParse(_elementMetadata(plate, 'index') ?? '') ?? 1;
      final metadata = <String, String>{};
      for (final item in plate.findElements('metadata')) {
        final key = item.getAttribute('key');
        final value = item.getAttribute('value');
        if (key != null && value != null) metadata[key] = value;
      }
      final filaments = <ProductionFilamentInspection>[];
      for (final item in plate.findAllElements('filament')) {
        final toolIndex = bambuToolIndex(item);
        filaments.add(
          ProductionFilamentInspection(
            toolIndex: toolIndex,
            grams: double.tryParse(item.getAttribute('used_g') ?? '') ?? 0,
            vendor: item.getAttribute('vendor') ??
                item.getAttribute('filament_vendor') ??
                item.getAttribute('brand') ??
                (toolIndex < configuredVendors.length
                    ? configuredVendors[toolIndex]
                    : null),
            materialType: _filamentProductType(
              item.getAttribute('type') ??
                  (toolIndex < configuredTypes.length
                      ? configuredTypes[toolIndex]
                      : null),
              toolIndex < configuredPresetIds.length
                  ? configuredPresetIds[toolIndex]
                  : null,
              toolIndex < configuredVendors.length
                  ? configuredVendors[toolIndex]
                  : null,
            ),
            colorHex: item.getAttribute('color'),
            trayId: int.tryParse(item.getAttribute('tray_id') ?? ''),
            sku: item.getAttribute('tray_info_idx'),
            usedForObject: bambuBoolAttribute(item, 'used_for_object'),
            usedForSupport: bambuBoolAttribute(item, 'used_for_support'),
            groupId: int.tryParse(item.getAttribute('group_id') ?? ''),
            nozzleDiameter:
                double.tryParse(item.getAttribute('nozzle_diameter') ?? ''),
            volumeType: item.getAttribute('volume_type'),
          ),
        );
      }
      final activeTools = filaments
          .where((item) => item.isActive)
          .map((item) => item.toolIndex)
          .toSet();
      final metadataToolChanges =
          int.tryParse(metadata['toolchange'] ?? '') ?? 0;
      final rangeToolChanges = toolChangesFromBambuFilamentRanges(
        plate,
        activeTools: activeTools,
      );
      var gcodeToolChanges = 0;
      if (activeTools.length > 1) {
        final gcode = archive.findFile('Metadata/plate_$index.gcode') ??
            (index == 1 ? archive.findFile('Metadata/plate.gcode') : null);
        if (gcode != null) {
          gcodeToolChanges = toolChangesFromBambuGcode(
            gcode.content as List<int>,
            activeTools: activeTools,
          );
        }
      }
      result[index] = _SlicePlateInfo(
        name: metadata['plater_name'] ?? '',
        estimatedSeconds: int.tryParse(metadata['prediction'] ?? '') ?? 0,
        totalLayers: _positiveInt(metadata['layer_num']) ??
            totalLayersFromBambuFilamentRanges(plate),
        toolChangeCount: [
          metadataToolChanges,
          rangeToolChanges,
          gcodeToolChanges,
        ].reduce((current, next) => current > next ? current : next),
        estimatedGrams: filaments.fold(0, (sum, item) => sum + item.grams),
        filaments: filaments,
        thumbnailPath: metadata['thumbnail_file'],
      );
    }
    return result;
  }

  static int? _positiveInt(String? value) {
    final parsed = int.tryParse(value ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static XmlDocument? _parseXml(ArchiveFile? file) {
    if (file == null) return null;
    try {
      return XmlDocument.parse(
        utf8.decode(file.content as List<int>, allowMalformed: true),
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _parseJsonObject(ArchiveFile? file) {
    if (file == null) return null;
    try {
      final decoded = jsonDecode(
        utf8.decode(file.content as List<int>, allowMalformed: true),
      );
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {}
    return null;
  }

  static String? _projectText(Map<String, dynamic>? settings, String key) {
    final value = settings?[key];
    if (value is List && value.isNotEmpty) return '${value.first}'.trim();
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static List<String> _projectStrings(
    Map<String, dynamic>? settings,
    String key,
  ) {
    final value = settings?[key];
    if (value is List) {
      return value.map((item) => '$item'.trim()).toList(growable: false);
    }
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? const [] : [text];
  }

  static String? _filamentProductType(
    String? rawType,
    String? presetId,
    String? vendor,
  ) {
    final type = rawType?.trim();
    var preset = presetId?.split('@').first.trim() ?? '';
    if (preset.isEmpty || type == null || type.isEmpty) return type;
    final vendorText = vendor?.trim() ?? '';
    if (vendorText.isNotEmpty &&
        preset.toLowerCase().startsWith(vendorText.toLowerCase())) {
      preset = preset.substring(vendorText.length).trim();
    }
    preset = preset.replaceFirst(
      RegExp(r'^(bambu\s*lab|bambu|拓竹|generic)\s+', caseSensitive: false),
      '',
    );
    return preset.toLowerCase().contains(type.toLowerCase()) &&
            preset.length > type.length
        ? preset
        : type;
  }

  static double? _projectDouble(Map<String, dynamic>? settings, String key) =>
      double.tryParse(_projectText(settings, key) ?? '');

  static int _declaredFilamentCount(Map<String, dynamic>? settings) {
    int countFor(String key) {
      final value = settings?[key];
      if (value is List) {
        return value.where((item) => '$item'.trim().isNotEmpty).length;
      }
      return value == null || '$value'.trim().isEmpty ? 0 : 1;
    }

    return [
      countFor('filament_settings_id'),
      countFor('filament_type'),
      countFor('filament_diameter'),
    ].fold<int>(0, math.max);
  }

  static bool _hasCompleteEmbeddedSettings(
    Map<String, dynamic>? settings,
  ) {
    if (settings == null || settings.isEmpty) return false;
    final hasMachine = _firstMeaningfulName([
          _projectText(settings, 'printer_settings_id'),
          _projectText(settings, 'printer_model'),
        ]) !=
        null;
    final hasNozzle = _projectDouble(settings, 'nozzle_diameter') != null ||
        _projectDouble(settings, 'printer_variant') != null;
    final hasProcess = _firstMeaningfulName([
          _projectText(settings, 'print_settings_id'),
          _projectText(settings, 'layer_height'),
        ]) !=
        null;
    final hasFilament = _firstMeaningfulName([
          _projectText(settings, 'filament_settings_id'),
          _projectText(settings, 'filament_type'),
          _projectText(settings, 'filament_diameter'),
        ]) !=
        null;
    return hasMachine && hasNozzle && hasProcess && hasFilament;
  }

  static String? _elementMetadata(XmlElement element, String key) {
    for (final metadata in element.findElements('metadata')) {
      if (metadata.getAttribute('key') == key) {
        return metadata.getAttribute('value');
      }
    }
    return null;
  }

  static XmlElement? _rootMetadata(XmlDocument? doc, String key) {
    if (doc == null) return null;
    for (final metadata in doc.findAllElements('metadata')) {
      if (metadata.getAttribute('name') == key) return metadata;
    }
    return null;
  }

  static String? _metadataValue(XmlElement? element) =>
      element?.getAttribute('value');

  static String? _headerValue(XmlDocument? doc, String key) {
    if (doc == null) return null;
    for (final item in doc.findAllElements('header_item')) {
      if (item.getAttribute('key') == key) return item.getAttribute('value');
    }
    return null;
  }

  static Future<File?> _nearbyProject(File file) async {
    final parent = file.parent;
    final candidates = <String>[
      '${parent.path}${Platform.pathSeparator}.3mf',
      '${parent.parent.path}${Platform.pathSeparator}.3mf',
    ];
    for (final path in candidates) {
      final candidate = File(path);
      if (await candidate.exists()) return candidate;
    }
    return null;
  }

  static Future<String?> _readOrigin(File file) async {
    try {
      final candidates = <File>[
        File('${file.parent.path}${Platform.pathSeparator}origin.txt'),
        File('${file.parent.parent.path}${Platform.pathSeparator}origin.txt'),
      ];
      for (final candidate in candidates) {
        if (!await candidate.exists()) continue;
        final text = utf8
            .decode(await candidate.readAsBytes(), allowMalformed: true)
            .trim();
        if (text.isNotEmpty) return text;
      }
    } catch (_) {}
    return null;
  }

  static int _plateIndexFromGcode(String path) {
    final name = path.split(RegExp(r'[/\\]')).last.toLowerCase();
    final direct = RegExp(r'plate_(\d+)\.gcode').firstMatch(name);
    if (direct != null) return int.parse(direct.group(1)!);
    final hidden = RegExp(r'^\.\d+\.(\d+)\.gcode$').firstMatch(name);
    if (hidden != null) return int.parse(hidden.group(1)!) + 1;
    return 1;
  }

  static String _withoutExtension(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    return name.replaceFirst(
      RegExp(r'\.(3mf|gcode|g|gc)$', caseSensitive: false),
      '',
    );
  }
}

class _ObjectInfo {
  const _ObjectInfo({
    required this.id,
    required this.name,
    required this.parts,
  });
  final String id;
  final String name;
  final List<_PartInfo> parts;
}

class _PartInfo {
  const _PartInfo({required this.name, this.sourceFile, this.sourceObjectId});
  final String name;
  final String? sourceFile;
  final String? sourceObjectId;
}

class _ModelPlateInfo {
  const _ModelPlateInfo({
    required this.index,
    required this.name,
    required this.parts,
  });
  final int index;
  final String name;
  final List<ProductionPartInspection> parts;
}

class _SlicePlateInfo {
  const _SlicePlateInfo({
    required this.name,
    required this.estimatedSeconds,
    required this.totalLayers,
    required this.toolChangeCount,
    required this.estimatedGrams,
    required this.filaments,
    this.thumbnailPath,
  });
  final String name;
  final int estimatedSeconds;
  final int totalLayers;
  final int toolChangeCount;
  final double estimatedGrams;
  final List<ProductionFilamentInspection> filaments;
  final String? thumbnailPath;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
