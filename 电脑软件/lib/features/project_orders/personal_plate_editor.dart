import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

import '../../core/theme/app_colors.dart';
import '../../data/external/slicer/production_package_inspector.dart';
import '../../ui/aurora_design.dart';

/// A deliberately small editable representation of one printable object.
/// The mesh remains in the source 3MF; this document stores the transform
/// layer that the personal workspace owns and can restore without rewriting a
/// potentially multi-gigabyte archive.
class PersonalEditableModel {
  const PersonalEditableModel({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.z,
    required this.rotation,
    required this.scale,
    this.width = 34,
    this.depth = 34,
    this.height = 12,
  });

  final String id;
  final String name;
  final double x;
  final double y;
  final double z;
  final double rotation;
  final double scale;
  final double width;
  final double depth;
  final double height;

  PersonalEditableModel copyWith({
    double? x,
    double? y,
    double? z,
    double? rotation,
    double? scale,
  }) =>
      PersonalEditableModel(
        id: id,
        name: name,
        x: x ?? this.x,
        y: y ?? this.y,
        z: z ?? this.z,
        rotation: rotation ?? this.rotation,
        scale: scale ?? this.scale,
        width: width,
        depth: depth,
        height: height,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'x': x,
        'y': y,
        'z': z,
        'rotation': rotation,
        'scale': scale,
        'width': width,
        'depth': depth,
        'height': height,
      };

  factory PersonalEditableModel.fromJson(Map<String, dynamic> json) =>
      PersonalEditableModel(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? '模型'}',
        x: _number(json['x'], 128),
        y: _number(json['y'], 128),
        z: _number(json['z'], 0),
        rotation: _number(json['rotation'], 0),
        scale: _number(json['scale'], 1).clamp(.1, 5),
        width: _number(json['width'], 34),
        depth: _number(json['depth'], 34),
        height: _number(json['height'], 12),
      );
}

double _number(Object? value, double fallback) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? fallback;
}

class PersonalPlateEditorDocument {
  const PersonalPlateEditorDocument({
    required this.sourcePath,
    required this.plateIndex,
    required this.models,
    this.width = 256,
    this.depth = 256,
    this.restored = false,
  });

  final String? sourcePath;
  final int plateIndex;
  final List<PersonalEditableModel> models;
  final double width;
  final double depth;
  final bool restored;
}

/// Reads only the metadata that describes object placement. It intentionally
/// avoids parsing the very large 3D object XML files on the UI isolate.
class PersonalPlateEditorStore {
  static Future<PersonalPlateEditorDocument> load({
    required String? sourcePath,
    required int plateIndex,
    required List<ProductionPartInspection> fallbackParts,
  }) async {
    final path = sourcePath?.trim();
    if (path == null || path.isEmpty) {
      return _fallback(path, plateIndex, fallbackParts);
    }
    final sidecar = File(_sidecarPath(path, plateIndex));
    if (await sidecar.exists()) {
      try {
        final decoded = jsonDecode(await sidecar.readAsString());
        if (decoded is Map) {
          final values = (decoded['models'] as List? ?? const [])
              .whereType<Map>()
              .map((item) => PersonalEditableModel.fromJson(
                    item.map((key, value) => MapEntry('$key', value)),
                  ))
              .toList(growable: false);
          if (values.isNotEmpty) {
            return PersonalPlateEditorDocument(
              sourcePath: path,
              plateIndex: plateIndex,
              models: values,
              restored: true,
            );
          }
        }
      } catch (_) {
        // A corrupt personal layout should never prevent opening the source.
      }
    }

    InputFileStream? input;
    try {
      // Keep the archive file-backed.  Bambu projects can contain gigabyte
      // object meshes; the editor only needs a few small metadata entries.
      input = InputFileStream(path);
      final archive = ZipDecoder().decodeBuffer(input);
      final settings = archive.findFile('Metadata/model_settings.config');
      final doc = settings == null
          ? null
          : XmlDocument.parse(utf8.decode(
              settings.content as List<int>,
              allowMalformed: true,
            ));
      final buildDoc = _xmlEntry(archive, '3D/3dmodel.model');
      final names = <String, String>{};
      XmlElement? plate;
      if (doc != null) {
        for (final object in doc.findAllElements('object')) {
          final id = object.getAttribute('id');
          if (id == null) continue;
          final metadata = _firstWhereOrNull(
            object.findElements('metadata'),
            (item) => item.getAttribute('key') == 'name',
          );
          names[id] = metadata?.getAttribute('value') ?? '模型 $id';
        }
        for (final candidate in doc.findAllElements('plate')) {
          final value = _firstWhereOrNull(
            candidate.findElements('metadata'),
            (item) => item.getAttribute('key') == 'plater_id',
          );
          if (int.tryParse(value?.getAttribute('value') ?? '') == plateIndex) {
            plate = candidate;
            break;
          }
        }
      }
      final transforms = <String, List<double>>{};
      if (doc != null) {
        for (final item in doc.findAllElements('assemble_item')) {
          final id = item.getAttribute('object_id');
          final values = _matrix(item.getAttribute('transform'));
          if (id != null && values.length >= 12) transforms[id] = values;
        }
      }
      // `assemble_item` is not the printable plate transform in many Bambu
      // projects (it may contain a shared assembly coordinate).  The build
      // item transform is the authoritative per-plate position.
      final buildTransforms = <String, List<double>>{};
      if (buildDoc != null) {
        for (final item in buildDoc.findAllElements('item')) {
          final id = item.getAttribute('objectid');
          final values = _matrix(item.getAttribute('transform'));
          if (id != null && values.length >= 12) buildTransforms[id] = values;
        }
      }
      final ids = <String>[];
      if (plate != null) {
        for (final instance in plate.findElements('model_instance')) {
          final metadata = _firstWhereOrNull(
            instance.findElements('metadata'),
            (item) => item.getAttribute('key') == 'object_id',
          );
          final id = metadata?.getAttribute('value');
          if (id != null && !ids.contains(id)) ids.add(id);
        }
      }
      if (ids.isNotEmpty) {
        final rawPositions = <Offset>[];
        final matrices = <List<double>?>[];
        for (final id in ids) {
          final matrix = buildTransforms[id] ?? transforms[id];
          matrices.add(matrix);
          rawPositions.add(Offset(
            matrix != null && matrix.length > 9 ? matrix[9] : double.nan,
            matrix != null && matrix.length > 10 ? matrix[10] : double.nan,
          ));
        }
        final finite = rawPositions
            .where((position) => position.dx.isFinite && position.dy.isFinite)
            .toList(growable: false);
        final minX = finite.isEmpty
            ? 0.0
            : finite.map((position) => position.dx).reduce(math.min);
        final maxX = finite.isEmpty
            ? 256.0
            : finite.map((position) => position.dx).reduce(math.max);
        final minY = finite.isEmpty
            ? 0.0
            : finite.map((position) => position.dy).reduce(math.min);
        final maxY = finite.isEmpty
            ? 256.0
            : finite.map((position) => position.dy).reduce(math.max);
        final needsNormalization = finite.any((position) =>
            position.dx < 0 ||
            position.dx > 256 ||
            position.dy < 0 ||
            position.dy > 256);
        double mapCoordinate(double value, double min, double max) {
          if (!needsNormalization || !value.isFinite) {
            return value.isFinite ? value.clamp(8, 248).toDouble() : 128;
          }
          final span = max - min;
          if (span.abs() < 0.001) return 128;
          return (16 + (value - min) / span * 224).clamp(8, 248).toDouble();
        }

        final models = <PersonalEditableModel>[];
        for (var i = 0; i < ids.length; i++) {
          final id = ids[i];
          final matrix = matrices[i];
          final fallbackX = 40 + (i % 4) * 58.0;
          final fallbackY = 40 + (i ~/ 4) * 58.0;
          final rawX = rawPositions[i].dx;
          final rawY = rawPositions[i].dy;
          final x = rawX.isFinite ? mapCoordinate(rawX, minX, maxX) : fallbackX;
          final y = rawY.isFinite ? mapCoordinate(rawY, minY, maxY) : fallbackY;
          final angle = matrix == null ? 0 : math.atan2(matrix[3], matrix[0]);
          models.add(PersonalEditableModel(
            id: id,
            name: names[id] ?? '模型 ${i + 1}',
            x: x.clamp(8, 248).toDouble(),
            y: y.clamp(8, 248).toDouble(),
            z: matrix != null && matrix.length > 11 ? matrix[11] : 0,
            scale: 1,
            rotation: angle.toDouble(),
          ));
        }
        return PersonalPlateEditorDocument(
          sourcePath: path,
          plateIndex: plateIndex,
          models: models,
        );
      }
    } catch (_) {
      // Fall back to the inspector's object list for malformed/non-Bambu 3MF.
    } finally {
      input?.closeSync();
    }
    return _fallback(path, plateIndex, fallbackParts);
  }

  static Future<String?> save(PersonalPlateEditorDocument document) async {
    final path = document.sourcePath?.trim();
    if (path == null || path.isEmpty || document.models.isEmpty) return null;
    final target = File(_sidecarPath(path, document.plateIndex));
    await target.writeAsString(jsonEncode({
      'version': 1,
      'sourcePath': path,
      'plateIndex': document.plateIndex,
      'savedAt': DateTime.now().toIso8601String(),
      'models': [for (final model in document.models) model.toJson()],
    }));
    return target.path;
  }

  static PersonalPlateEditorDocument _fallback(
    String? path,
    int plateIndex,
    List<ProductionPartInspection> parts,
  ) {
    final models = <PersonalEditableModel>[];
    var index = 0;
    for (final part in parts) {
      final count = math.max(1, part.instancesPerRun);
      for (var instance = 0; instance < count; instance++) {
        models.add(PersonalEditableModel(
          id: '${part.key}:$instance',
          name: part.name,
          x: 40 + (index % 4) * 58.0,
          y: 40 + (index ~/ 4) * 58.0,
          z: 0,
          rotation: 0,
          scale: 1,
        ));
        index++;
      }
    }
    if (models.isEmpty) {
      models.add(const PersonalEditableModel(
        id: 'model:1',
        name: '模型 1',
        x: 128,
        y: 128,
        z: 0,
        rotation: 0,
        scale: 1,
      ));
    }
    return PersonalPlateEditorDocument(
      sourcePath: path,
      plateIndex: plateIndex,
      models: models,
    );
  }

  static List<double> _matrix(String? value) => (value ?? '')
      .split(RegExp(r'[,\s]+'))
      .map((item) => double.tryParse(item))
      .whereType<double>()
      .toList(growable: false);

  static String _sidecarPath(String path, int plateIndex) =>
      '$path.sohun-plate-$plateIndex.json';

  static XmlDocument? _xmlEntry(Archive archive, String name) {
    final entry = archive.findFile(name);
    if (entry == null || entry.size > 8 * 1024 * 1024) return null;
    try {
      return XmlDocument.parse(
        utf8.decode(entry.content as List<int>, allowMalformed: true),
      );
    } catch (_) {
      return null;
    }
  }

  /// Reads the small per-plate PNG without decoding the rest of a 3MF.
  ///
  /// The result is keyed by plate index and is intentionally independent of
  /// [ProductionPackageInspector], whose full inspection has stricter archive
  /// limits intended for imported production artifacts.
  static Future<Map<int, Uint8List>> readPlateThumbnails(
    String sourcePath, {
    Iterable<int>? plateIndexes,
  }) async {
    final requested = plateIndexes?.toSet();
    final result = <int, Uint8List>{};
    InputFileStream? input;
    try {
      input = InputFileStream(sourcePath);
      final archive = ZipDecoder().decodeBuffer(input);
      for (final entry in archive) {
        final match = RegExp(
          r'^Metadata/plate_(\d+)(?:_small)?\.png$',
          caseSensitive: false,
        ).firstMatch(entry.name);
        if (match == null) continue;
        final index = int.tryParse(match.group(1)!);
        if (index == null || requested?.contains(index) == false) continue;
        // Never expand an unexpectedly large entry on the UI isolate.
        if (entry.size <= 0 || entry.size > 8 * 1024 * 1024) continue;
        // Prefer the full image over `_small` when both are present.
        if (entry.name.toLowerCase().contains('_small') &&
            result.containsKey(index)) {
          continue;
        }
        result[index] = Uint8List.fromList(entry.content as List<int>);
      }
    } catch (_) {
      return result;
    } finally {
      input?.closeSync();
    }
    return result;
  }
}

T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T value) test) {
  for (final value in values) {
    if (test(value)) return value;
  }
  return null;
}

class PersonalPlateEditorCanvas extends StatelessWidget {
  const PersonalPlateEditorCanvas({
    super.key,
    required this.models,
    required this.selectedId,
    required this.zoom,
    required this.onSelect,
    required this.onMove,
    required this.onPan,
    this.pan = Offset.zero,
    this.onMoveStart,
    this.onMoveEnd,
  });

  final List<PersonalEditableModel> models;
  final String? selectedId;
  final double zoom;
  final ValueChanged<String?> onSelect;
  final void Function(String id, Offset delta) onMove;
  final ValueChanged<Offset> onPan;
  final Offset pan;
  final VoidCallback? onMoveStart;
  final VoidCallback? onMoveEnd;

  @override
  Widget build(BuildContext context) {
    String? dragId;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => onSelect(_hitTest(
            details.localPosition,
            size,
            models,
            zoom,
            pan,
          )),
          onPanStart: (details) {
            dragId = _hitTest(details.localPosition, size, models, zoom, pan);
            if (dragId != null) {
              onSelect(dragId);
              onMoveStart?.call();
            }
          },
          onPanUpdate: (details) {
            if (dragId != null) {
              onMove(dragId!, details.delta / zoom);
            } else {
              onPan(details.delta);
            }
          },
          onPanEnd: (_) {
            if (dragId != null) onMoveEnd?.call();
            dragId = null;
          },
          child: CustomPaint(
            painter: _PersonalPlatePainter(
              models: models,
              selectedId: selectedId,
              zoom: zoom,
              pan: pan,
              dark: Theme.of(context).brightness == Brightness.dark,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

String? _hitTest(
    Offset point, Size size, List<PersonalEditableModel> models, double zoom,
    [Offset pan = Offset.zero]) {
  final center = Offset(size.width / 2, size.height / 2) + pan;
  for (final model in models.reversed) {
    final p = center + Offset((model.x - 128) * zoom, (model.y - 128) * zoom);
    final w = model.width * model.scale * zoom;
    final h = model.depth * model.scale * zoom;
    if ((point.dx - p.dx).abs() <= w / 2 && (point.dy - p.dy).abs() <= h / 2) {
      return model.id;
    }
  }
  return null;
}

class _PersonalPlatePainter extends CustomPainter {
  const _PersonalPlatePainter({
    required this.models,
    required this.selectedId,
    required this.zoom,
    required this.pan,
    required this.dark,
  });

  final List<PersonalEditableModel> models;
  final String? selectedId;
  final double zoom;
  final Offset pan;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2) + pan;
    final bedSize = math.min(size.width, size.height) * .82;
    final bed =
        Rect.fromCenter(center: center, width: bedSize, height: bedSize);
    final background = Paint()
      ..color = dark ? const Color(0xFF1B211E) : const Color(0xFFF7FAF8);
    canvas.drawRect(Offset.zero & size, background);
    final bedPaint = Paint()
      ..color = dark ? const Color(0xFF27312C) : const Color(0xFFEEF3F0)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
        RRect.fromRectAndRadius(bed, const Radius.circular(12)), bedPaint);
    final grid = Paint()
      ..color = dark ? const Color(0xFF39463F) : const Color(0xFFD9E2DC)
      ..strokeWidth = 1;
    for (var i = 0; i <= 8; i++) {
      final x = bed.left + bed.width * i / 8;
      final y = bed.top + bed.height * i / 8;
      canvas.drawLine(Offset(x, bed.top), Offset(x, bed.bottom), grid);
      canvas.drawLine(Offset(bed.left, y), Offset(bed.right, y), grid);
    }
    final axis = Paint()
      ..color = AppColors.primary.withValues(alpha: .5)
      ..strokeWidth = 1.5;
    canvas.drawLine(
        Offset(center.dx, bed.top), Offset(center.dx, bed.bottom), axis);
    canvas.drawLine(
        Offset(bed.left, center.dy), Offset(bed.right, center.dy), axis);

    for (final model in models) {
      final point =
          center + Offset((model.x - 128) * zoom, (model.y - 128) * zoom);
      final w = model.width * model.scale * zoom;
      final h = model.depth * model.scale * zoom;
      final selected = model.id == selectedId;
      canvas.save();
      canvas.translate(point.dx, point.dy);
      canvas.rotate(model.rotation);
      final rect = Rect.fromCenter(center: Offset.zero, width: w, height: h);
      final shadow = Paint()..color = Colors.black.withValues(alpha: .12);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              rect.shift(const Offset(0, 4)), const Radius.circular(6)),
          shadow);
      final fill = Paint()
        ..color = selected
            ? AppColors.primary.withValues(alpha: .34)
            : AppColors.primary.withValues(alpha: .16);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(6)), fill);
      final border = Paint()
        ..color = selected
            ? AppColors.primary
            : AppColors.primary.withValues(alpha: .7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.2 : 1.2;
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(6)), border);
      canvas.restore();
    }
    final text = TextPainter(
      text: TextSpan(
        text: '256 × 256 mm',
        style: TextStyle(
            color: dark ? Colors.white70 : Aurora.textSoft, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset(bed.left + 10, bed.bottom - 23));
  }

  @override
  bool shouldRepaint(covariant _PersonalPlatePainter oldDelegate) =>
      oldDelegate.models != models ||
      oldDelegate.selectedId != selectedId ||
      oldDelegate.zoom != zoom ||
      oldDelegate.pan != pan ||
      oldDelegate.dark != dark;
}
