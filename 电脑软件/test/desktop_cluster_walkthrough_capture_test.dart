import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:consumable_tracker_desktop/core/constants/personal_spool_policy.dart';
import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/core/theme/personal_desktop_theme.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_screen.dart';
import 'package:consumable_tracker_desktop/features/dashboard/material_playground_hero.dart';
import 'package:consumable_tracker_desktop/providers/bambu_account_manager.dart';
import 'package:consumable_tracker_desktop/providers/bambu_cloud_provider.dart';
import 'package:consumable_tracker_desktop/providers/batch_recognition_provider.dart';
import 'package:consumable_tracker_desktop/providers/cluster_provider.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/mifu_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_queue_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:consumable_tracker_desktop/providers/slicer_provider.dart';
import 'package:consumable_tracker_desktop/providers/stock_alert_provider.dart';
import 'package:consumable_tracker_desktop/providers/usage_provider.dart';
import 'package:consumable_tracker_desktop/ui/aurora_design.dart';
import 'package:consumable_tracker_desktop/ui/aurora_shell.dart';
import 'package:consumable_tracker_desktop/widgets/personal_desktop_chrome.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _captureKey = ValueKey('native-cluster-walkthrough');
const _size = Size(1600, 1000);
const _modelVersion = 'Mifu 0.9';
const _output = '../output/sohun-walkthrough-20261113/frames';

/// Reusable in-memory scenario. Names on screen are natural, but provenance is
/// explicit in the external metadata. These observations are NOT operational
/// records, model measurements, hardware telemetry, or completed real prints.
class DesktopClusterWalkthroughScenario {
  DesktopClusterWalkthroughScenario() : observedAt = DateTime.now() {
    materials = [
      for (var index = 0; index < 24; index++)
        Consumable(
          id: index + 1,
          uid: 'walkthrough-spool-$index',
          manufacturer: index.isEven ? 'Bambu Lab' : 'eSUN',
          model: 'PLA Basic',
          materialType: 'PLA',
          colorHex: const [
            '#E8E6DF',
            '#4F83B8',
            '#84AC92',
            '#343D43',
          ][index % 4],
          colorName: const ['象牙白', '雾蓝', '鼠尾草绿', '曜石黑'][index % 4],
          totalGrams: personalSpoolCapacityGrams,
          remainingGrams: (920 - (index % 4) * 110 - (index ~/ 4) * 20)
              .toDouble(),
          createdAt: observedAt.subtract(const Duration(days: 6)),
          updatedAt: observedAt,
        ),
    ];
    final names = [
      'P1S-01',
      'P1S-02',
      'A1-01',
      'X1C-01',
      'P1S-03',
      'A1 mini-01',
    ];
    final models = ['P1S', 'P1S', 'A1', 'X1C', 'P1S', 'A1 mini'];
    printers = [
      for (var index = 0; index < names.length; index++)
        _printer(index, names[index], models[index]),
    ];
    final orders = <StudioOrder>[];
    final packages = <StudioProductionPackage>[];
    final tasks = <ClusterTaskGroup>[];
    final allPlates = <StudioProductionPlate>[];
    for (var task = 0; task < 3; task++) {
      final order = StudioOrder(
        id: 'order-${task + 1}',
        workspaceId: 'personal-workshop',
        orderNo: 'SH-1113-0${task + 1}',
        title: const ['桌面收纳盒', '模块化花盆', '相机配件架'][task],
        status: StudioOrderStatus.production,
        totalPrice: 0,
        createdAt: observedAt.subtract(const Duration(days: 1)),
        updatedAt: observedAt,
      );
      final package = StudioProductionPackage(
        id: 'package-${task + 1}',
        workspaceId: 'personal-workshop',
        orderId: order.id,
        sourceName: '${order.title}.3mf',
        artifactKind: 'bambu3mf',
        createdAt: order.createdAt,
      );
      final plans = <ClusterPlatePlan>[];
      for (var part = 0; part < 2; part++) {
        final plate = StudioProductionPlate(
          id: 'plate-$task-$part',
          workspaceId: 'personal-workshop',
          orderId: order.id,
          packageId: package.id,
          plateIndex: part + 1,
          name: const [
            ['底壳', '分隔板'],
            ['盆体', '底托'],
            ['支架', '连接座'],
          ][task][part],
          requiredRuns: task == 0 ? 3 : 2,
          estimatedSeconds: part == 0 ? 5400 : 2520,
          estimatedGrams: part == 0 ? 84.2 : 36.8,
          totalLayers: part == 0 ? 228 : 112,
          sliceStatus: StudioPlateSliceStatus.sliced,
          sliceTargetModel: 'P1S',
          sliceNozzleDiameter: .4,
          sliceArtifactSha256: List.filled(64, '${task + 1}').join(),
          autoEjectEnabled: false,
          filaments: [
            StudioPlateFilamentUsage(
              toolIndex: 0,
              grams: part == 0 ? 84.2 : 36.8,
              vendor: 'Bambu Lab',
              materialType: 'PLA',
              colorHex: '#E8E6DF',
              nozzleDiameter: .4,
            ),
          ],
          createdAt: order.createdAt,
        );
        plans.add(
          ClusterPlatePlan(
            plate: plate,
            remainingRuns: plate.requiredRuns,
            assignedRuns: 0,
            completedRuns: 0,
            dueAt: observedAt.add(const Duration(days: 1)),
            blockers: const [],
            rejections: const {
              3: ['切片机型不匹配'],
              4: ['切片机型不匹配'],
              5: ['活动队列已达上限'],
              6: ['切片机型不匹配'],
            },
            candidates: [
              for (var device = 0; device < 2; device++)
                ClusterPrinterCandidate(
                  printerId: device + 1,
                  printerSerial: printers[device].serial!,
                  printerName: names[device],
                  maxRuns: plate.requiredRuns,
                  queuedRuns: 0,
                  availableAfterSeconds: 0,
                  materialMatches: [
                    ClusterMaterialMatch(
                      toolIndex: 0,
                      consumableId: device * 4 + 1,
                      channelId: device * 4 + 1,
                      channelIndex: 0,
                      gramsPerRun: plate.estimatedGrams,
                      availableGrams: materials[device * 4].remainingGrams,
                    ),
                  ],
                ),
            ],
          ),
        );
        allPlates.add(plate);
      }
      orders.add(order);
      packages.add(package);
      tasks.add(
        ClusterTaskGroup(
          order: order,
          packages: [ClusterPackageGroup(package: package, plates: plans)],
        ),
      );
    }
    snapshot = ClusterPlanningSnapshot(
      studio: StudioSnapshot(
        workspace: StudioWorkspace(
          id: 'personal-workshop',
          name: '我的工作室',
          createdAt: observedAt,
          updatedAt: observedAt,
        ),
        members: const [],
        customers: const [],
        orders: orders,
        workOrders: const [],
        quotes: const [],
        inventoryEvents: const [],
        inventoryBatches: const [],
        shareLinks: const [],
        productionPackages: packages,
        productionPlates: allPlates,
      ),
      tasks: tasks,
      printers: printers,
      generatedAt: observedAt,
      visibleConsumableIds: materials.map((material) => material.id).toSet(),
    );
    client = MifuClient(client: MockClient(_respond));
  }

  final DateTime observedAt;
  late final List<Consumable> materials;
  late final List<ClusterPrinter> printers;
  late final ClusterPlanningSnapshot snapshot;
  late final MifuClient client;
  final requests = <Map<String, Object?>>[];
  int dispatchAttempts = 0;

  ClusterPrinter _printer(int index, String name, String model) {
    final serial = 'walkthrough-device-${index + 1}';
    final running = index >= 2;
    final trays = [
      for (var slot = 0; slot < 4; slot++)
        AmsTray(
          amsId: 0,
          slot: slot,
          trayType: 'PLA',
          trayColor: '${materials[index * 4 + slot].colorHex.substring(1)}FF',
          remain: (materials[index * 4 + slot].remainingGrams / 10).round(),
          hasFilament: true,
          trayWeight: 1000,
          traySubBrands: 'PLA Basic',
        ),
    ];
    return ClusterPrinter(
      source: PrinterWithChannels(
        Printer(
          id: index + 1,
          uid: serial,
          name: name,
          brand: 'Bambu',
          model: model,
          channelCount: 4,
          isCustomImage: false,
          createdAt: observedAt,
          updatedAt: observedAt,
        ),
        [
          for (var slot = 0; slot < 4; slot++)
            ChannelWithConsumable(
              PrinterChannel(
                id: index * 4 + slot + 1,
                printerId: index + 1,
                channelIndex: slot,
                label: 'A${slot + 1}',
                consumableId: index * 4 + slot + 1,
                loadedRemainingGrams:
                    materials[index * 4 + slot].remainingGrams,
                updatedAt: observedAt,
              ),
              materials[index * 4 + slot],
            ),
        ],
        serial: serial,
      ),
      state: FleetPrinterState(
        serial: serial,
        displayLabel: name,
        connectionState: PrinterConnectionState.connected,
        lastStatus: BambuPrinterStatus(
          serial: serial,
          gcodeState: running ? BambuGcodeState.running : BambuGcodeState.idle,
          mcPercent: running ? const [0, 0, 62, 38, 76, 24][index] : null,
          mcRemainingTime: running ? const [0, 0, 32, 54, 18, 68][index] : 0,
          currLayer: running ? 142 : null,
          totalLayers: running ? 228 : null,
          nozzleTemper: running ? 220 : 28,
          nozzleTargetTemper: running ? 220 : 0,
          bedTemper: running ? 55 : 27,
          bedTargetTemper: running ? 55 : 0,
          subtaskName: running ? '收纳配件' : null,
          amsUnits: [
            AmsUnit(
              id: 0,
              type: index == 2 || index == 5
                  ? AmsUnitType.amsLite
                  : AmsUnitType.ams,
              isPresent: true,
              trays: trays,
            ),
          ],
          amsTrays: trays,
          updatedAt: observedAt,
        ),
        statusUpdatedAt: observedAt,
        // No usable LAN endpoint or real connection is provided by this scenario.
        isLanCapable: true,
        mode: BambuConnectionMode.lan,
        reportedModel: model,
        installedNozzleDiameter: .4,
        isConnecting: false,
      ),
      activeQueueCount: index == 4
          ? 5
          : running
          ? 1
          : 0,
      availableAfterSeconds: running
          ? const [0, 0, 1920, 3240, 22680, 4080][index]
          : 0,
      blockers: index == 4 ? const ['活动队列已达上限'] : const [],
    );
  }

  Future<http.Response> _respond(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    requests.add({'path': request.url.path, 'body': body});
    Map<String, dynamic> result;
    switch (request.url.path) {
      case '/v1/decisions/check':
        result = {
          'requestId': body['requestId'],
          'inputContract': 'mifu-decision-v4',
          'evidenceStatus': 'passed',
          'tokenAudit': {'status': 'passed'},
          'modelReady': true,
          'canInfer': true,
          'issues': [],
          'advisoryOnly': true,
          'automaticExecutionAuthorized': false,
        };
      case '/v1/decisions':
        result = {
          'requestId': body['requestId'],
          'inputContract': 'mifu-decision-v4',
          'trainingState': 'ready',
          'choice': '2',
          'probabilities': {'1': .32, '2': .68},
          'elapsedMs': 86,
          'model': {
            'name': 'Mifu',
            'version': _modelVersion,
            'checkpointConfigured': true,
            'inputContract': 'mifu-decision-v4',
          },
        };
      case '/v1/records':
        result = {'recordId': 'selection-current', 'trainingEligible': false};
      case '/v1/records/query':
        final plate = body['plateId'];
        String ago(Duration duration) =>
            observedAt.subtract(duration).toUtc().toIso8601String();
        result = {
          'trainingEligible': false,
          'attemptsTruncated': false,
          'records': [
            {
              'recordId': 'selection-previous',
              'plateId': plate,
              'candidateId': '1',
              'createdAt': ago(const Duration(hours: 5)),
              'plateIndex': 1,
            },
          ],
          'attempts': [
            {
              'attemptId': 'print-previous',
              'recordId': 'selection-previous',
              'plateId': plate,
              'candidateId': '1',
              'executionEventId': 'execution-previous',
              'execution': {
                'status': 'completed',
                'startedAt': ago(const Duration(hours: 4)),
                'endedAt': ago(const Duration(hours: 2, minutes: 30)),
                'actualDurationSeconds': 5238,
                'materialUsedGrams': 82.6,
                'completionPercent': 100,
                'failureCategory': null,
                'failureEvidence': null,
              },
              'qualityEventId': 'quality-previous',
              'quality': {
                'status': 'pass',
                'inspectedAt': ago(const Duration(hours: 2, minutes: 20)),
                'inspectorId': 'operator-lin',
                'qualityScore': 96,
                'defectCodes': [],
                'notes': '底面平整，卡扣配合正常。',
              },
              'lastOccurredAt': ago(const Duration(hours: 2, minutes: 20)),
              'snapshotCapturedAfterStart': false,
              'trainingEligible': false,
            },
          ],
        };
      default:
        throw StateError(
          'Walkthrough forbids all other HTTP operations: ${request.url.path}',
        );
    }
    return http.Response(
      jsonEncode(result),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

class _PointerState {
  const _PointerState(this.position, [this.ripple]);
  final Offset position;
  final double? ripple;
}

class _PointerPainter extends CustomPainter {
  _PointerPainter(this.pointer) : super(repaint: pointer);
  final ValueNotifier<_PointerState> pointer;
  @override
  void paint(Canvas canvas, Size size) {
    final state = pointer.value;
    if (state.ripple case final double progress) {
      final ring = Paint()
        ..color = const Color(
          0xFF00AE62,
        ).withValues(alpha: .55 * (1 - progress))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(state.position, 5 + 22 * progress, ring);
      canvas.drawCircle(
        state.position,
        5 + 12 * progress,
        Paint()
          ..color = const Color(
            0xFF00AE62,
          ).withValues(alpha: .15 * (1 - progress)),
      );
    }
    canvas.save();
    canvas.translate(state.position.dx, state.position.dy);
    final arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 25)
      ..lineTo(6, 19)
      ..lineTo(11, 30)
      ..lineTo(15, 28)
      ..lineTo(10, 17)
      ..lineTo(21, 17)
      ..close();
    canvas.drawShadow(arrow, Colors.black.withValues(alpha: .25), 2, false);
    canvas.drawPath(arrow, Paint()..color = Colors.white);
    canvas.drawPath(
      arrow,
      Paint()
        ..color = const Color(0xFF263830)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PointerPainter oldDelegate) =>
      pointer != oldDelegate.pointer;
}

class _Sequence {
  _Sequence(this.tester, this.pointer, this.directory, this.scenario);
  final WidgetTester tester;
  final ValueNotifier<_PointerState> pointer;
  final Directory directory;
  final DesktopClusterWalkthroughScenario scenario;
  final frames = <Map<String, Object>>[];
  final actions = <Map<String, Object>>[];
  final keyFrames = <Map<String, Object>>[];
  int elapsedMs = 0;
  late TestGesture mouse;

  Future<void> begin() async {
    await tester.runAsync(() => directory.create(recursive: true));
    mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: pointer.value.position);
  }

  Future<void> frame({int durationMs = 100}) async {
    await tester.pump(Duration(milliseconds: durationMs));
    expect(tester.takeException(), isNull);
    final name = 'frame_${frames.length.toString().padLeft(4, '0')}.png';
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${directory.path}/$name',
        ).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      } finally {
        image.dispose();
      }
    });
    frames.add({'file': name, 'durationMs': durationMs});
    elapsedMs += durationMs;
  }

  Future<void> hold(int count) async {
    if (count > 0) await frame(durationMs: count * 100);
  }

  void mark(String control) {
    keyFrames.add({
      'control': control,
      'frameIndex': frames.length - 1,
      'file': frames.last['file']!,
      'endMs': elapsedMs,
    });
  }

  Future<void> moveTo(Offset target, {int count = 7}) async {
    final start = pointer.value.position;
    for (var i = 1; i <= count; i++) {
      final point = Offset.lerp(
        start,
        target,
        Curves.easeInOutCubic.transform(i / count),
      )!;
      pointer.value = _PointerState(point);
      await mouse.moveTo(point);
      await frame();
    }
  }

  Future<void> click(
    Finder finder,
    String control, {
    int linger = 10,
    int moveFrames = 7,
  }) async {
    final target = finder.hitTestable();
    expect(
      target,
      findsOneWidget,
      reason: 'Actual visible control required: $control',
    );
    final position = tester.getCenter(target);
    actions.add({
      'atMs': elapsedMs,
      'action': 'click',
      'control': control,
      'finder': finder.toString(),
      'x': position.dx,
      'y': position.dy,
    });
    await moveTo(position, count: moveFrames);
    pointer.value = _PointerState(position, 0);
    await mouse.down(position);
    await frame();
    await mouse.up();
    for (var i = 1; i <= 3; i++) {
      pointer.value = _PointerState(position, i / 4);
      await frame();
    }
    pointer.value = _PointerState(position);
    await hold(linger);
    mark(control);
  }

  Future<void> type(Finder field, String value, String label) async {
    await click(field, label, linger: 1, moveFrames: 6);
    actions.add({
      'atMs': elapsedMs,
      'action': 'type',
      'control': label,
      'value': value,
    });
    for (var i = 1; i <= value.length; i++) {
      await tester.enterText(field, value.substring(0, i));
      await frame();
    }
    await hold(2);
    mark('$label / 已填写');
  }

  Future<void> scroll(Finder viewport, double delta, {int linger = 14}) async {
    final rectangle = tester.getRect(viewport);
    final point = Offset(rectangle.right - 50, rectangle.center.dy);
    await moveTo(point, count: 6);
    actions.add({
      'atMs': elapsedMs,
      'action': 'mouse-wheel',
      'control': viewport.toString(),
      'deltaY': delta,
    });
    for (var i = 0; i < 6; i++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: Offset(0, delta / 6)),
      );
      await frame();
    }
    await hold(linger);
    mark('滚动后内容');
  }

  Future<void> finish(String title, List<String> prelude) async {
    expect(scenario.dispatchAttempts, 0);
    expect(
      scenario.requests.any((request) => request['path'] == '/v1/outcomes'),
      isFalse,
    );
    // Nothing in the video is an operations log. Keep provenance outside the
    // captured UI as requested, attached to every standalone frame sequence.
    final metadata = {
      'title': title,
      'source': 'isolated_widget_fixture',
      'renderedApplication': 'AuroraWorkspace / ClusterScreen',
      'dataOrigin':
          'In-memory authored scenario; all Mifu HTTP replies are mocked for UI traversal only.',
      'modelMetricsAreReal': false,
      'realDeviceConnections': 0,
      'realInventoryWrites': 0,
      'realPrintsStarted': 0,
      'trainingEligible': false,
      'outcomeHistory':
          'Pre-existing authored batch, independent of the newly recorded selection.',
      'width': _size.width.toInt(),
      'height': _size.height.toInt(),
      'fps': 10,
      'frameCount': frames.length,
      'durationMs': elapsedMs,
      'preludeControls': prelude,
      'actions': actions,
      'keyFrames': keyFrames,
      'mockHttpRequests': scenario.requests,
      'stoppedBefore': '检查并排产 / 最终确认 / 实际打印',
    };
    await tester.runAsync(() async {
      await File(
        '${directory.path}/frames.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(frames));
      await File(
        '${directory.path}/metadata.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(metadata));
    });
    await mouse.removePointer();
  }
}

Future<void> _loadFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final regular = await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes();
    final bold = await File(r'C:\Windows\Fonts\msyhbd.ttc').readAsBytes();
    for (final family in [
      AppTypography.chineseFontFamily,
      'Microsoft YaHei UI',
      'Roboto',
      'Ahem',
      AppTypography.monoFontFamily,
    ]) {
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.sublistView(regular)))
            ..addFont(Future.value(ByteData.sublistView(bold))))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
}

ThemeData _captureTheme() {
  final theme = buildPersonalDesktopTheme(
    AppTheme.light(),
    personalProduct: true,
    studioMode: false,
  );
  // The capture engine has no Windows font fallback. SnackBar replaces the
  // inherited text style, so give its otherwise unchanged style a loaded font.
  return theme.copyWith(
    snackBarTheme: theme.snackBarTheme.copyWith(
      contentTextStyle: theme.snackBarTheme.contentTextStyle!.copyWith(
        fontFamily: AppTypography.chineseFontFamily,
        fontFamilyFallback: AppTypography.chineseFontFamilyFallback,
      ),
    ),
  );
}

Future<void> _mount(
  WidgetTester tester,
  DesktopClusterWalkthroughScenario scenario,
  ValueNotifier<_PointerState> pointer,
) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.binding.setSurfaceSize(_size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  Aurora.applyTheme(primaryColor: const Color(0xFF00B42A), dark: false);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clusterPlanningSnapshotProvider.overrideWith(
          (_) async => scenario.snapshot,
        ),
        clusterDispatchValidatorProvider.overrideWithValue((
          _,
          _,
          _,
          _,
          _,
        ) async {
          scenario.dispatchAttempts++;
          throw StateError('Real dispatch is forbidden in capture');
        }),
        mifuClientProvider.overrideWith((_) => scenario.client),
        mifuHealthProvider.overrideWith(
          (_) => Stream.value(
            const MifuHealth(
              trainingState: 'ready',
              version: _modelVersion,
              device: 'cuda',
              inputContract: 'mifu-decision-v4',
              supportedInputContracts: ['mifu-decision-v4'],
              supportedObjectives: ['earliest_known_finish'],
            ),
          ),
        ),
        bambuAccountManagerProvider.overrideWith((_) => _QuietAccounts()),
        bambuCloudProvider.overrideWith((_) => _QuietCloud()),
        allCloudDevicesProvider.overrideWith((_) => _QuietDevices()),
        activePrinterConnectionProvider.overrideWith((_) => _QuietConnection()),
        activePrinterConfigProvider.overrideWithValue(null),
        mergedPrinterListProvider.overrideWithValue(const []),
        slicerWatcherProvider.overrideWith((_) => _QuietSlicer()),
        activeSlicerStatusProvider.overrideWith((_) async => null),
        activeSlicerDetectorProvider.overrideWithValue(null),
        printQueueStateMachineProvider.overrideWith((_) {}),
        batchRecognitionProvider.overrideWith((_) {}),
        activeBatchProgressProvider.overrideWith((_) async => null),
        consumablesProvider.overrideWith(
          (_) => Stream.value(scenario.materials),
        ),
        personalRfidSpoolBindingsProvider.overrideWith(
          (_) async => <int, RfidSpoolBinding>{},
        ),
        printersWithChannelsProvider.overrideWith(
          (_) => Stream.value(scenario.printers.map((p) => p.source).toList()),
        ),
        usageLogsProvider.overrideWith((_) => Stream.value(const [])),
        stockAlertsProvider.overrideWith((_) async => []),
        materialHeroPrinterStatusProvider.overrideWithValue(null),
      ],
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _captureTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.noScaling),
            child: Stack(
              fit: StackFit.expand,
              children: [
                child!,
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _PointerPainter(pointer)),
                  ),
                ),
              ],
            ),
          ),
          home: const InteractionEffectsScope(
            enabled: false,
            child: AuroraWorkspace(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final images = find.byType(Image).evaluate().toList();
  await tester.runAsync(
    () => Future.wait([
      for (final element in images)
        precacheImage((element.widget as Image).image, element),
    ]),
  );
  await tester.pumpAndSettle();
  expect(find.byType(AuroraWorkspace), findsOneWidget);
  expect(find.byType(PersonalDesktopChrome), findsNWidgets(2));
}

void main() {
  for (final segment in [1, 2, 3]) {
    testWidgets(
      'native desktop cluster walkthrough $segment',
      (tester) async {
        final originalShadows = debugDisableShadows;
        try {
          debugDisableShadows = false;
          await _loadFonts(tester);
          final scenario = DesktopClusterWalkthroughScenario();
          addTearDown(scenario.client.close);
          final pointer = ValueNotifier(const _PointerState(Offset(1310, 870)));
          addTearDown(pointer.dispose);
          await _mount(tester, scenario, pointer);
          final prelude = <String>[];
          if (segment > 1) {
            await tester.tap(
              find.byKey(const ValueKey('personal-nav-cluster')),
            );
            await tester.pumpAndSettle();
            prelude.add('personal-nav-cluster');
          }
          if (segment == 3) {
            await tester.tap(find.text('P01  底壳'));
            await tester.pumpAndSettle();
            prelude.add('P01  底壳');
          }
          final sequence = _Sequence(
            tester,
            pointer,
            Directory(
              '$_output/${const ['01-cluster-device', '02-mifu-selection', '03-print-outcome'][segment - 1]}',
            ),
            scenario,
          );
          await sequence.begin();
          await sequence.hold(10);
          if (segment == 1) {
            await sequence.click(
              find.byKey(const ValueKey('personal-nav-cluster')),
              '侧栏 / 集群管理',
              linger: 12,
            );
            expect(find.byType(ClusterScreen), findsOneWidget);
            await sequence.click(
              find.text('P01  底壳'),
              '任务阵列 / P01 底壳',
              linger: 12,
            );
            await sequence.click(
              find.byTooltip('查看P1S-01档案'),
              '打印机阵列 / P1S-01 / 查看档案',
              linger: 17,
            );
            expect(find.text('状态与材料'), findsOneWidget);
            await sequence.scroll(
              find.byKey(const ValueKey('cluster-device-tab-0')),
              290,
              linger: 17,
            );
            await sequence.click(
              find.widgetWithText(TextButton, '关闭'),
              '设备档案 / 关闭',
              linger: 12,
            );
            expect(scenario.requests, isEmpty);
          } else if (segment == 2) {
            await sequence.click(
              find.text('P01  底壳'),
              '任务阵列 / P01 底壳',
              linger: 8,
              moveFrames: 6,
            );
            await sequence.click(
              find.widgetWithText(OutlinedButton, '重新决策'),
              'Mifu / 重新决策',
              linger: 8,
            );
            await sequence.type(
              find.byKey(const ValueKey('preparation-1')),
              '90',
              'P1S-01 / 预计准备秒数',
            );
            await sequence.type(
              find.byKey(const ValueKey('preparation-2')),
              '30',
              'P1S-02 / 预计准备秒数',
            );
            await sequence.click(
              find.widgetWithText(FilledButton, '开始比较'),
              '准备耗时 / 开始比较',
              linger: 14,
              moveFrames: 6,
            );
            expect(find.text('68.0%'), findsOneWidget);
            final panel = find.byKey(const ValueKey('mifu-decision-panel'));
            await sequence.click(
              find.descendant(of: panel, matching: find.text('P1S-01')),
              'Mifu候选 / 人工改选 P1S-01',
              linger: 10,
            );
            await sequence.click(
              find.widgetWithText(OutlinedButton, '记录选择'),
              'Mifu / 记录选择',
              linger: 16,
            );
            expect(find.text('已记录'), findsOneWidget);
            final recordedNotice = find.text('选择已记录，复核后才会进入训练集');
            expect(recordedNotice, findsOneWidget);
            expect(
              DefaultTextStyle.of(
                tester.element(recordedNotice),
              ).style.fontFamily,
              AppTypography.chineseFontFamily,
            );
            expect(scenario.requests.map((r) => r['path']), [
              '/v1/decisions/check',
              '/v1/decisions',
              '/v1/records',
            ]);
            expect(
              (scenario.requests.last['body'] as Map)['feedback'],
              'corrected',
            );
          } else {
            await sequence.click(
              find.widgetWithText(OutlinedButton, '打印结果'),
              'Mifu / 打印结果',
              linger: 12,
            );
            await sequence.click(
              find.text('新增一次打印 / 重打'),
              '打印结果 / 打印批次下拉框',
              linger: 4,
              moveFrames: 6,
            );
            await sequence.click(
              find.text('第 1 次 · 已完成 · 合格').last,
              '打印结果 / 已有第1次打印',
              linger: 17,
              moveFrames: 6,
            );
            expect(find.text('5238'), findsOneWidget);
            await sequence.click(
              find.widgetWithText(ChoiceChip, '人工质检'),
              '打印结果 / 人工质检',
              linger: 14,
            );
            final form = find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(ListView),
            );
            await sequence.scroll(form, 210, linger: 17);
            expect(find.text('底面平整，卡扣配合正常。'), findsOneWidget);
            await sequence.click(
              find.widgetWithText(TextButton, '关闭'),
              '打印结果 / 关闭（不保存、不派发）',
              linger: 14,
            );
            expect(scenario.requests.map((r) => r['path']), [
              '/v1/records/query',
            ]);
          }
          expect(tester.takeException(), isNull);
          await sequence.finish(
            const ['进入集群与设备档案', 'Mifu比较与人工改选', '查看打印结果与人工质检'][segment - 1],
            prelude,
          );
        } finally {
          debugDisableShadows = originalShadows;
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
      skip: !const bool.fromEnvironment('SOHUN_WALKTHROUGH_CAPTURE'),
      timeout: const Timeout(Duration(minutes: 12)),
    );
  }
}

class _QuietAccounts extends StateNotifier<BambuAccountManagerState>
    implements BambuAccountManagerNotifier {
  _QuietAccounts() : super(const BambuAccountManagerState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietCloud extends StateNotifier<BambuCloudState>
    implements BambuCloudNotifier {
  _QuietCloud() : super(const BambuCloudState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietDevices extends StateNotifier<AllCloudDevicesState>
    implements AllCloudDevicesNotifier {
  _QuietDevices() : super(const AllCloudDevicesState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietConnection extends StateNotifier<ActivePrinterState>
    implements ActivePrinterConnectionNotifier {
  _QuietConnection() : super(const ActivePrinterState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietSlicer extends StateNotifier<SlicerWatcherState>
    implements SlicerWatcherNotifier {
  _QuietSlicer() : super(const SlicerWatcherState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
