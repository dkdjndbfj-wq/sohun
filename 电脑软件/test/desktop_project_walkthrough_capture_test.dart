import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/production_package_inspector.dart';
import 'package:consumable_tracker_desktop/features/project_orders/personal_project_orders_screen.dart';
import 'package:consumable_tracker_desktop/providers/studio_provider.dart';
// Test-only adapters for the already installed file_selector/path_provider.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/desktop_walkthrough_support.dart';

void main() {
  testWidgets(
    'desktop walkthrough 09 imports and saves a real local 3MF project',
    (tester) async {
      final scratch = await tester.runAsync(
        () => Directory.systemTemp.createTemp('sohun-guide-project-'),
      );
      final previousSelector = FileSelectorPlatform.instance;
      final previousPaths = PathProviderPlatform.instance;
      DesktopWalkthrough? guide;
      try {
        final source = await tester.runAsync(() => _writeProject(scratch!));
        final inspected = await tester.runAsync(
          () => ProductionPackageInspector.inspect(source!.path),
        );
        expect(inspected!.productionPlates, hasLength(1));
        expect(inspected.isSliced, isFalse);
        expect(inspected.productionPlates.single.parts.single.name, '桌面垫块');
        final selector = _LocalProjectSelector(source!.path);
        FileSelectorPlatform.instance = selector;
        PathProviderPlatform.instance = _TemporaryPaths(scratch!.path);
        guide = await DesktopWalkthrough.mount(
          tester,
          segment: '09-project-import',
        );
        final recording = guide;
        await recording.hold(10);
        await recording.click(
          find.byKey(const ValueKey('personal-nav-project_orders')),
          '侧栏 / 我的项目',
          linger: 12,
        );
        expect(find.byType(PersonalProjectsScreen), findsOneWidget);
        // Both the page header and empty state can offer import; use the header.
        await recording.click(find.text('导入项目').first, '我的项目 / 导入项目');
        expect(find.text('添加项目'), findsOneWidget);
        await recording.click(
          find.text('拖入 Bambu Studio 的 3MF，或点击选择文件'),
          '添加项目 / 选择桌面垫块.3mf',
          linger: 14,
        );
        await recording.settle();
        expect(selector.openCount, 1);
        expect(find.text('1 张可打印盘已识别'), findsOneWidget);
        await recording.hold(15);
        recording.mark('读取源文件并识别打印盘');
        await recording.type(walkthroughField('项目名称'), '桌面整理配件', '项目名称');
        await recording.click(
          find.text('保存到我的项目'),
          '添加项目 / 保存到我的项目',
          linger: 16,
        );
        await recording.settle();
        final saved = await tester.runAsync(
          () =>
              recording.container.read(studioDaoProvider).getDefaultSnapshot(),
        );
        expect(saved!.orders, hasLength(1));
        expect(saved.orders.single.title, '桌面整理配件');
        expect(saved.productionPackages, hasLength(1));
        expect(saved.productionPlates, hasLength(1));
        expect(
          saved.productionPlates.single.sliceStatus,
          StudioPlateSliceStatus.pending,
        );
        expect(saved.workOrders, isEmpty);
        final savedSource = saved.productionPackages.single.localPath!;
        expect(
          File(savedSource).absolute.path,
          startsWith('${scratch.absolute.path}${Platform.pathSeparator}'),
        );
        expect(await tester.runAsync(() => File(savedSource).exists()), isTrue);
        expect(find.text('添加项目'), findsNothing);
        expect(find.text('桌面整理配件'), findsOneWidget);
        expect(find.text('第 1 盘 · 桌面垫块'), findsOneWidget);
        await recording.hold(20);
        recording.mark('项目已保存并展示待切片打印盘');
        await recording.click(find.text('待准备').first, '项目筛选 / 待准备', linger: 12);
        expect(find.text('桌面整理配件'), findsOneWidget);
        await recording.click(find.text('桌面垫块'), '源文件 / 收起打印盘', linger: 10);
        expect(find.text('第 1 盘 · 桌面垫块'), findsNothing);
        await recording.click(find.text('桌面垫块'), '源文件 / 展开打印盘', linger: 20);
        expect(find.text('第 1 盘 · 桌面垫块'), findsOneWidget);
        await recording.finish(
          '导入 3MF 项目与查看打印盘',
          extra: {
            'fileSelection':
                'The real file_selector callback returns the isolated 3MF. The native operating-system picker is omitted, not recreated or depicted.',
            'sourceFixture':
                'Valid 3MF package with an 80 x 50 x 12 mm closed cuboid mesh, Bambu project/plate metadata and an authored matching thumbnail. No G-code or sliced results.',
            'verifiedLocalResult': {
              'title': saved.orders.single.title,
              'sourceFile': '桌面垫块.3mf',
              'plateCount': saved.productionPlates.length,
              'plateStatus': 'pending',
              'workOrderCount': saved.workOrders.length,
              'filePickerCalls': selector.openCount,
              'sourcePreservedInIsolatedDirectory': true,
            },
            'stoppedBefore': '开始切片 / 发送打印 / 启动 Bambu Studio',
          },
        );
      } finally {
        if (guide != null) await guide.dispose();
        FileSelectorPlatform.instance = previousSelector;
        PathProviderPlatform.instance = previousPaths;
        if (scratch != null) {
          await tester.runAsync(() async {
            final path = scratch.absolute.path;
            final temp = Directory.systemTemp.absolute.path;
            if (!path.startsWith('$temp${Platform.pathSeparator}') ||
                !scratch.uri.pathSegments
                    .where((part) => part.isNotEmpty)
                    .last
                    .startsWith('sohun-guide-project-')) {
              throw StateError(
                'Refusing to clean a directory outside this capture',
              );
            }
            if (await scratch.exists()) await scratch.delete(recursive: true);
          });
        }
      }
    },
    skip: !const bool.fromEnvironment('SOHUN_DESKTOP_GUIDE_CAPTURE'),
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

class _LocalProjectSelector extends FileSelectorPlatform {
  _LocalProjectSelector(this.path);
  final String path;
  int openCount = 0;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    expect(acceptedTypeGroups!.single.extensions, contains('3mf'));
    openCount++;
    return [XFile(path)];
  }
}

class _TemporaryPaths extends PathProviderPlatform {
  _TemporaryPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationCachePath() async => path;
}

ArchiveFile _textEntry(String path, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(path, bytes.length, bytes);
}

Future<File> _writeProject(Directory directory) async {
  final thumbnail = await _projectThumbnail();
  final archive = Archive()
    ..addFile(
      _textEntry('[Content_Types].xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
<Default Extension="png" ContentType="image/png"/>
<Default Extension="config" ContentType="application/octet-stream"/>
</Types>
'''),
    )
    ..addFile(
      _textEntry('_rels/.rels', '''
<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>
'''),
    )
    ..addFile(
      _textEntry('3D/3dmodel.model', '''
<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xml:lang="zh-CN" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
<metadata name="Application">BambuStudio-02.07.01.57</metadata>
<resources><object id="1" name="桌面垫块" type="model"><mesh>
<vertices>
<vertex x="0" y="0" z="0"/><vertex x="80" y="0" z="0"/><vertex x="80" y="50" z="0"/><vertex x="0" y="50" z="0"/>
<vertex x="0" y="0" z="12"/><vertex x="80" y="0" z="12"/><vertex x="80" y="50" z="12"/><vertex x="0" y="50" z="12"/>
</vertices><triangles>
<triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="3" v3="2"/>
<triangle v1="4" v2="5" v3="6"/><triangle v1="4" v2="6" v3="7"/>
<triangle v1="0" v2="1" v3="5"/><triangle v1="0" v2="5" v3="4"/>
<triangle v1="1" v2="2" v3="6"/><triangle v1="1" v2="6" v3="5"/>
<triangle v1="2" v2="3" v3="7"/><triangle v1="2" v2="7" v3="6"/>
<triangle v1="3" v2="0" v3="4"/><triangle v1="3" v2="4" v3="7"/>
</triangles></mesh></object></resources>
<build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 80 90 0"/></build>
</model>
'''),
    )
    ..addFile(
      _textEntry('Metadata/model_settings.config', '''
<?xml version="1.0" encoding="UTF-8"?>
<config>
<object id="1"><metadata key="name" value="桌面垫块"/><metadata key="extruder" value="1"/>
<part id="1" subtype="normal_part"><metadata key="name" value="桌面垫块"/><metadata key="source_file" value="桌面垫块.stl"/></part></object>
<plate><metadata key="plater_id" value="1"/><metadata key="plater_name" value="桌面垫块"/>
<model_instance><metadata key="object_id" value="1"/><metadata key="instance_id" value="0"/></model_instance></plate>
</config>
'''),
    )
    ..addFile(
      _textEntry(
        'Metadata/project_settings.config',
        jsonEncode({
          'printer_model': 'Bambu Lab P1S',
          'nozzle_diameter': ['0.4'],
          'print_settings_id': '0.20mm Standard @BBL P1S',
          'filament_settings_id': ['Bambu PLA Basic @BBL P1S'],
          'filament_vendor': ['Bambu Lab'],
          'filament_type': ['PLA'],
          'filament_colour': ['#75A998'],
          'version': '02.07.01.57',
        }),
      ),
    )
    ..addFile(ArchiveFile('Metadata/plate_1.png', thumbnail.length, thumbnail));
  return File(
    '${directory.path}${Platform.pathSeparator}桌面垫块.3mf',
  ).writeAsBytes(ZipEncoder().encode(archive)!);
}

/// Matching isometric preview for the valid cuboid mesh stored above. The
/// thumbnail is an authored project asset, not a fabricated slicer screenshot.
Future<Uint8List> _projectThumbnail() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFF2F5F3), BlendMode.src);
  Offset project(double x, double y, double z) =>
      Offset(260 + (x - y) * 2.6, 130 + (x + y) * 1.15 - z * 3.1);
  void polygon(List<Offset> points, Color color) {
    final path = Path()..addPolygon(points, true);
    canvas.drawPath(path, Paint()..color = color);
  }

  polygon([
    project(-18, -18, -1),
    project(110, -18, -1),
    project(110, 88, -1),
    project(-18, 88, -1),
  ], const Color(0xFFDFE6E2));
  final grid = Paint()
    ..color = const Color(0xFFC8D4CD)
    ..strokeWidth = .7;
  for (var x = -10; x <= 100; x += 10) {
    canvas.drawLine(
      project(x.toDouble(), -18, 0),
      project(x.toDouble(), 88, 0),
      grid,
    );
  }
  for (var y = -10; y <= 80; y += 10) {
    canvas.drawLine(
      project(-18, y.toDouble(), 0),
      project(110, y.toDouble(), 0),
      grid,
    );
  }
  polygon([
    project(0, 50, 0),
    project(80, 50, 0),
    project(80, 50, 12),
    project(0, 50, 12),
  ], const Color(0xFF487C69));
  polygon([
    project(80, 0, 0),
    project(80, 50, 0),
    project(80, 50, 12),
    project(80, 0, 12),
  ], const Color(0xFF639883));
  polygon([
    project(0, 0, 12),
    project(80, 0, 12),
    project(80, 50, 12),
    project(0, 50, 12),
  ], const Color(0xFF88B7A5));
  final picture = recorder.endRecording();
  final image = await picture.toImage(560, 400);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}
