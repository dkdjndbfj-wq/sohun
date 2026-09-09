import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:consumable_tracker_desktop/core/utils/zip_safety.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/bambu_studio_slicing_service.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/production_package_inspector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  final enabled = Platform.environment['RUN_BAMBU_PLATE_E2E'] == '1';

  test(
    'real Bambu Studio slices only the requested plate',
    () async {
      final executable = Platform.environment['BAMBU_STUDIO_EXE']!;
      final source = Platform.environment['BAMBU_MULTI_PLATE_3MF']!;
      final plateIndex =
          int.parse(Platform.environment['BAMBU_TEST_PLATE'] ?? '1');
      final outputRoot = Directory(
        '${Directory.current.path}${Platform.pathSeparator}build'
        '${Platform.pathSeparator}bambu_plate_e2e',
      );

      final sourceInspection = await ProductionPackageInspector.inspect(source);
      final archive = ZipDecoder().decodeBytes(
        await File(source).readAsBytes(),
      );
      Object? xmlError;
      var xmlPlates = -1;
      try {
        final modelSettings = archive.findFile(
          'Metadata/model_settings.config',
        )!;
        final xml = XmlDocument.parse(
          utf8.decode(
            modelSettings.content as List<int>,
            allowMalformed: true,
          ),
        );
        xmlPlates = xml.findAllElements('plate').length;
      } catch (error) {
        xmlError = error;
      }
      // ignore: avoid_print
      print(
        'source inspection: ${sourceInspection == null ? 'null' : '${sourceInspection.kind}, plates=${sourceInspection.plates.length}, production=${sourceInspection.productionPlates.length}, settings=${sourceInspection.hasEmbeddedSettings}'}; '
        'archive=${archive.length}, safe=${isSafe3mfArchive(archive)}, '
        'modelSettings=${archive.findFile('Metadata/model_settings.config') != null}, '
        'xmlPlates=$xmlPlates, xmlError=$xmlError',
      );
      expect(sourceInspection, isNotNull);

      final result = await BambuStudioSlicingService.sliceProject(
        executablePath: executable,
        sourcePath: source,
        plateIndex: plateIndex,
        outputRoot: outputRoot,
      );

      expect(result.slicedPlateIndexes, [plateIndex]);
      final selected = result.inspection.plates.singleWhere(
        (plate) => plate.plateIndex == plateIndex,
      );
      expect(selected.hasToolpath, isTrue);
      expect(selected.estimatedSeconds, greaterThan(0));
      expect(selected.estimatedGrams, greaterThan(0));
      expect(selected.totalLayers, greaterThan(0));
      expect(selected.parts, isNotEmpty);
      expect(
        selected.parts.every((part) => part.name.trim().isNotEmpty),
        isTrue,
      );
      if (plateIndex == 8) {
        expect(selected.isMulticolor, isTrue);
        expect(selected.activeFilaments.map((item) => item.toolIndex), [0, 2]);
        expect(selected.activeFilaments[0].grams, closeTo(22.73, 0.02));
        expect(selected.activeFilaments[1].grams, closeTo(16.24, 0.02));
        expect(selected.estimatedGrams, closeTo(38.97, 0.02));
        expect(selected.totalLayers, 327);
        expect(selected.toolChangeCount, 4);
      }
      expect(
        result.inspection.plates
            .where((plate) => plate.plateIndex != plateIndex)
            .every((plate) => !plate.hasToolpath),
        isTrue,
      );
      expect(File(result.outputPath).existsSync(), isTrue);
    },
    skip:
        enabled ? false : 'Set RUN_BAMBU_PLATE_E2E=1 and provide Bambu paths.',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
