import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:consumable_tracker_desktop/core/services/studio_video_relay_service.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_printer_camera_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeFarmCameraSession implements FarmCameraPreviewSession {
  final StreamController<Uint8List> controller =
      StreamController<Uint8List>.broadcast();
  int disposeCount = 0;

  @override
  Stream<Uint8List> get frames => controller.stream;

  void addFrame(Uint8List frame) => controller.add(frame);

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    // 测试假时钟下 await controller.close() 的完成依赖真实事件循环，
    // 这里不等待，保证对话框释放链在 pump 内即可完成。
    if (!controller.isClosed) {
      // ignore: unawaited_futures
      controller.close();
    }
  }
}

const _cameraConfig = PrinterConnectionConfig(
  serial: 'A1-CAMERA-001',
  host: '192.168.1.25',
  accessCode: '12345678',
  devProductName: 'A1',
);

void main() {
  test('拓竹云绑定保持云端模式，不触发局域网发现', () async {
    final cloud = PrinterConnectionConfig.cloud(
      serial: 'A1-CAMERA-001',
      devProductName: 'A1',
    );
    final resolved = await resolveFarmCameraConnectionConfig(cloud);

    expect(resolved.mode, BambuConnectionMode.cloud);
    expect(resolved.host, isEmpty);
    expect(resolved.accessCode, isEmpty);
    expect(resolved.serial, 'A1-CAMERA-001');
  });

  test('拓竹云绑定在异地网络不依赖局域网发现', () async {
    final cloud = PrinterConnectionConfig.cloud(
      serial: 'A1-CAMERA-001',
      devProductName: 'A1',
    );

    final resolved = await resolveFarmCameraConnectionConfig(cloud);
    expect(resolved.mode, BambuConnectionMode.cloud);
    expect(resolved.host, isEmpty);
  });

  testWidgets('农场实时画面显示直播帧并在关闭时释放连接', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = _FakeFarmCameraSession();
    final connector = ({
      required PrinterConnectionConfig config,
      required String model,
    }) async {
      expect(config.serial, 'A1-CAMERA-001');
      expect(model, 'A1');
      return session;
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          farmCameraPreviewConnectorProvider.overrideWithValue(connector),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const FarmPrinterCameraDialog(
                      printerName: 'A1 一号机',
                      serial: 'A1-CAMERA-001',
                      model: 'A1',
                      config: _cameraConfig,
                    ),
                  ),
                  child: const Text('打开画面'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开画面'));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('farm-camera-preview-dialog')),
      findsOneWidget,
    );
    expect(find.text('正在连接打印机摄像头…'), findsOneWidget);

    session.addFrame(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.textContaining('最近画面'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭实时画面'));
    await tester.pumpAndSettle();
    expect(session.disposeCount, 1);
    expect(
      find.byKey(const ValueKey('farm-camera-preview-dialog')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('农场实时画面连接失败时提供明确错误和重试入口', (tester) async {
    var attempts = 0;
    final connector = ({
      required PrinterConnectionConfig config,
      required String model,
    }) async {
      attempts += 1;
      throw StateError('摄像头连接被占用');
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          farmCameraPreviewConnectorProvider.overrideWithValue(connector),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: FarmPrinterCameraDialog(
              printerName: 'A1 一号机',
              serial: 'A1-CAMERA-001',
              model: 'A1',
              config: _cameraConfig,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('摄像头连接被占用'), findsOneWidget);
    expect(find.byKey(const ValueKey('farm-camera-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('farm-camera-retry')));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('云端摄像头休眠唤醒失败时提示先从拓竹端唤醒', (tester) async {
    final connector = ({
      required PrinterConnectionConfig config,
      required String model,
    }) async {
      throw StateError(
        '远程摄像头数据流意外结束 (official network component timed out while URL)',
      );
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          farmCameraPreviewConnectorProvider.overrideWithValue(connector),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: FarmPrinterCameraDialog(
              printerName: 'A1 一号机',
              serial: 'A1-CAMERA-001',
              model: 'A1',
              config: _cameraConfig,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('当前处于休眠状态'), findsOneWidget);
    expect(find.textContaining('Bambu Studio'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('云端签名被拒绝时提示从拓竹端唤醒', (tester) async {
    final connector = ({
      required PrinterConnectionConfig config,
      required String model,
    }) async {
      throw StateError(
        'SIGN_REJECTED: cloud rejected the attached device security sign',
      );
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          farmCameraPreviewConnectorProvider.overrideWithValue(connector),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: FarmPrinterCameraDialog(
              printerName: 'A1 一号机',
              serial: 'A1-CAMERA-001',
              model: 'A1',
              config: _cameraConfig,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('云端拒绝了摄像头唤醒请求'), findsOneWidget);
    expect(find.textContaining('Bambu Studio'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('局域网绑定首次预览会确认设备证书后重新连接', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = _FakeFarmCameraSession();
    var attempts = 0;
    final connector = ({
      required PrinterConnectionConfig config,
      required String model,
    }) async {
      attempts += 1;
      if (attempts == 1) {
        throw const FarmCameraCertificateTrustRequired(
          config: _cameraConfig,
          fingerprint:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          subject: 'CN=Bambu Lab Printer',
          issuer: 'CN=Bambu Lab Printer',
        );
      }
      return session;
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          farmCameraPreviewConnectorProvider.overrideWithValue(connector),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: FarmPrinterCameraDialog(
              printerName: 'A1 一号机',
              serial: 'A1-CAMERA-001',
              model: 'A1',
              config: _cameraConfig,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('首次连接，请确认打印机证书'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('farm-camera-trust-certificate')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('farm-camera-trust-certificate')),
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(attempts, 2);
    await tester.pump();
    await tester.pump();

    session.addFrame(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('LIVE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('休眠唤醒类失败后后台自动重试，无需点击重新连接', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessionA = _FakeFarmCameraSession();
    final sessionB = _FakeFarmCameraSession();
    final sessions = [sessionA, sessionB];
    var calls = 0;
    final connector = ({
      required PrinterConnectionConfig config,
      required String model,
    }) async {
      calls += 1;
      return sessions[calls - 1];
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          farmCameraPreviewConnectorProvider.overrideWithValue(connector),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: FarmPrinterCameraDialog(
              printerName: 'A1 一号机',
              serial: 'A1-CAMERA-001',
              model: 'A1',
              config: _cameraConfig,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(calls, 1);

    // 桥接报“设备休眠，需要官方客户端唤醒”类错误 → 触发后台自动重试。
    sessionA.controller.addError(
      StateError(
        'NEED_OFFICIAL_WAKE: printer camera is asleep (tutk_server=disable); '
        'wake it once from Bambu Studio or Bambu Handy',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('farm-camera-auto-retry-note')),
      findsOneWidget,
    );
    expect(find.textContaining('第 1 次'), findsOneWidget);

    // 20 秒后自动重连（未点击任何按钮）。
    for (var tick = 0; tick < 21; tick++) {
      await tester.pump(const Duration(seconds: 1));
    }
    // 定时器回调内启动的异步链依赖真实事件循环完成 cancel/dispose，
    // 用 runAsync 短暂放行真实循环后再回到假时钟。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(calls, 2);
    expect(find.text('正在连接打印机摄像头…'), findsOneWidget);

    // 第二次连接成功出画面后不再自动重试。
    sessionB.addFrame(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('LIVE'), findsOneWidget);
    await tester.pump(const Duration(seconds: 25));
    expect(calls, 2);
    expect(
      find.byKey(const ValueKey('farm-camera-auto-retry-note')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动重试达到上限后停止并提示手动重试', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = List.generate(12, (_) => _FakeFarmCameraSession());
    var calls = 0;
    final connector = ({
      required PrinterConnectionConfig config,
      required String model,
    }) async {
      calls += 1;
      return sessions[calls - 1];
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          farmCameraPreviewConnectorProvider.overrideWithValue(connector),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: FarmPrinterCameraDialog(
              printerName: 'A1 一号机',
              serial: 'A1-CAMERA-001',
              model: 'A1',
              config: _cameraConfig,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 10 轮：每轮一次失败 + 21 秒后自动重连（初次 + 10 次自动重试）。
    for (var round = 0; round < 10; round++) {
      sessions[round].controller.addError(
        StateError('stage: NEED_OFFICIAL_WAKE (tutk_server=disable)'),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 21));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
    expect(calls, 11);
    // 第 11 次失败到达上限：停止自动重试并提示。
    sessions[10].controller.addError(
      StateError('stage: NEED_OFFICIAL_WAKE (tutk_server=disable)'),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(find.textContaining('已停止自动重试'), findsOneWidget);
    await tester.pump(const Duration(seconds: 25));
    expect(calls, 11); // 达到上限后不再自动重连
    expect(tester.takeException(), isNull);
  });
}
