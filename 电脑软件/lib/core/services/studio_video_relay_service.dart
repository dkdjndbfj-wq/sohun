import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/windows_runtime_libraries.dart';
import 'camera_diagnostics_telemetry.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/models/studio_models.dart';
import '../../data/external/community/studio_api_client.dart';
import '../../data/external/printer/bambu_cloud_client.dart';
import '../../data/external/printer/bambu_cloud_models.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_certificate_trust_store.dart';
import '../../data/external/slicer/bambu_studio_lan_config_writer.dart';
import '../../data/prefs/app_prefs.dart';
import '../../providers/app_auth_provider.dart';
import '../../providers/bambu_account_manager.dart';
import '../../providers/database_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../providers/studio_provider.dart';
import 'printer_fleet_connection_manager.dart';

const int _videoFrameMaxBytes = 600 * 1024;

class StudioVideoRelayState {
  const StudioVideoRelayState({
    this.activeStreams = 0,
    this.activePrinterSerials = const <String>{},
    this.lastError,
    this.updatedAt,
  });

  final int activeStreams;

  /// Serial numbers whose camera relay is currently serving at least one viewer.
  final Set<String> activePrinterSerials;
  final String? lastError;
  final DateTime? updatedAt;

  StudioVideoRelayState copyWith({
    int? activeStreams,
    Set<String>? activePrinterSerials,
    String? lastError,
    bool clearError = false,
    DateTime? updatedAt,
  }) {
    return StudioVideoRelayState(
      activeStreams: activeStreams ?? this.activeStreams,
      activePrinterSerials: activePrinterSerials ?? this.activePrinterSerials,
      lastError: clearError ? null : (lastError ?? this.lastError),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class StudioVideoRelayController extends StateNotifier<StudioVideoRelayState> {
  StudioVideoRelayController(this.ref, {required this.active})
      : super(const StudioVideoRelayState()) {
    if (!active) return;
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _reconcile());
    unawaited(_reconcile());
  }

  final Ref ref;
  final bool active;
  final Map<String, _StudioCameraRelayWorker> _workers = {};
  final Map<String, DateTime> _retryAfter = {};
  Timer? _timer;
  bool _reconciling = false;
  DateTime? _lastLiveSync;
  DateTime? _lastDemandSuccess;

  Future<void> _reconcile() async {
    if (!active || _reconciling) return;
    _reconciling = true;
    try {
      final farmPrefs = await SharedPreferences.getInstance();
      if (!(farmPrefs.getBool('farm_camera_portal_enabled') ?? true)) {
        await _stopAll();
        return;
      }
      final auth = ref.read(appAuthProvider);
      if (!auth.isSignedIn || auth.endpoint == null) {
        await _stopAll();
        return;
      }
      final studio = await ref.read(studioDaoProvider).getDefaultSnapshot();
      if (studio.workspace.remoteId == null) {
        ref
            .read(studioSyncControllerProvider.notifier)
            .requestNow(visible: false);
        return;
      }
      final printers =
          await ref.read(printerDaoProvider).getAllPrintersWithChannels();
      final printerById = {
        for (final item in printers) item.printer.id: item,
      };
      final configs = ref.read(mergedPrinterListProvider);
      final configBySerial = {
        for (final config in configs)
          if ((config.mode == BambuConnectionMode.lan &&
                  config.host.isNotEmpty &&
                  config.accessCode.isNotEmpty) ||
              config.mode == BambuConnectionMode.cloud)
            config.serial: config,
      };
      final ownerMap = ref.read(printerOwnerMapProvider);
      final accountState = ref.read(bambuAccountManagerProvider);
      final cloudDevices = ref.read(allCloudDevicesProvider).devices;
      final fleet = ref.read(printerFleetConnectionManagerProvider);
      final orderById = {for (final item in studio.orders) item.id: item};
      final printingByPrinter = <int, List<StudioWorkOrder>>{};
      for (final workOrder in studio.workOrders) {
        if (workOrder.status != StudioWorkOrderStatus.printing ||
            workOrder.printerId == null ||
            orderById[workOrder.orderId]?.portalVideoEnabled != true) {
          continue;
        }
        printingByPrinter
            .putIfAbsent(workOrder.printerId!, () => [])
            .add(workOrder);
      }

      final demandedWorkOrderIds = printingByPrinter.isEmpty
          ? const <String>{}
          : await _loadVideoDemand(studio.workspace.remoteId!);

      final desired = <String, _RelayCandidate>{};
      for (final entry in printingByPrinter.entries) {
        // Ambiguous assignment must never expose one printer to two customers.
        if (entry.value.length != 1) continue;
        final workOrder = entry.value.single;
        if (!demandedWorkOrderIds.contains(workOrder.id)) continue;
        final printer = printerById[entry.key];
        final serial = printer?.serial;
        if (printer == null || serial == null) continue;
        final config = configBySerial[serial];
        final live = fleet[serial];
        final gcode = live?.lastStatus?.gcodeState;
        final activePrint = gcode == BambuGcodeState.running ||
            gcode == BambuGcodeState.pause ||
            gcode == BambuGcodeState.prepare;
        if (config == null || !activePrint) continue;
        final cloudSession = config.mode == BambuConnectionMode.cloud
            ? _cloudSessionForSerial(
                serial: serial,
                ownerMap: ownerMap,
                accountState: accountState,
              )
            : null;
        if (config.mode == BambuConnectionMode.cloud && cloudSession == null) {
          continue;
        }
        String? firmwareVersion;
        for (final device in cloudDevices) {
          if (device.devId == serial) {
            firmwareVersion = device.swVer;
            break;
          }
        }
        final publicName = _publicPrinterName(printer, config, live);
        desired[workOrder.id] = _RelayCandidate(
          workspaceId: studio.workspace.remoteId!,
          orderId: workOrder.orderId,
          workOrderId: workOrder.id,
          config: config,
          model: config.devProductName ?? printer.printer.model,
          publicPrinterName: publicName,
          cloudSession: cloudSession,
          firmwareVersion: firmwareVersion,
        );
      }

      for (final key in _workers.keys.toList()) {
        final candidate = desired[key];
        final worker = _workers[key]!;
        if (candidate == null ||
            !worker.matches(candidate) ||
            !worker.isHealthy) {
          _workers.remove(key);
          await worker.dispose();
        }
      }

      if (desired.isNotEmpty &&
          (_lastLiveSync == null ||
              DateTime.now().difference(_lastLiveSync!) >
                  const Duration(seconds: 12))) {
        _lastLiveSync = DateTime.now();
        ref
            .read(studioSyncControllerProvider.notifier)
            .requestNow(visible: false);
      }

      final pending = desired.entries
          .where((entry) => !_workers.containsKey(entry.key))
          .where(
            (entry) => _retryAfter[entry.key]?.isBefore(DateTime.now()) ?? true,
          )
          .toList();
      if (pending.isNotEmpty) {
        // Upload current live facts before opening an order-bound video session.
        await ref.read(studioCloudServiceProvider).sync();
      }
      for (final entry in pending) {
        final worker = _StudioCameraRelayWorker(ref, entry.value);
        try {
          await worker.start();
          _workers[entry.key] = worker;
          _retryAfter.remove(entry.key);
        } catch (error) {
          await worker.dispose();
          _retryAfter[entry.key] =
              DateTime.now().add(const Duration(seconds: 30));
          state = state.copyWith(
            activeStreams: _workers.length,
            lastError: _friendlyVideoError(error),
            updatedAt: DateTime.now(),
          );
        }
      }
      state = state.copyWith(
        activeStreams: _workers.length,
        activePrinterSerials: _workers.values
            .map((worker) => worker.candidate.config.serial)
            .toSet(),
        clearError: _workers.isNotEmpty,
        updatedAt: DateTime.now(),
      );
    } catch (error, stackTrace) {
      debugPrint('[StudioVideoRelay] $error\n$stackTrace');
      final lastDemandSuccess = _lastDemandSuccess;
      if (lastDemandSuccess == null ||
          DateTime.now().difference(lastDemandSuccess) >
              const Duration(seconds: 24)) {
        await _stopAll();
      }
      state = state.copyWith(
        activeStreams: _workers.length,
        activePrinterSerials: _workers.values
            .map((worker) => worker.candidate.config.serial)
            .toSet(),
        lastError: _friendlyVideoError(error),
        updatedAt: DateTime.now(),
      );
    } finally {
      _reconciling = false;
    }
  }

  Future<Set<String>> _loadVideoDemand(String workspaceId) async {
    final auth = ref.read(appAuthProvider);
    final endpoint = auth.endpoint;
    if (endpoint == null) return const {};
    final login = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    final api = StudioApiClient(
      baseUri: endpoint,
      httpClient: ref.read(communityHttpClientProvider),
    );
    final demand = await api.listVideoDemand(
      accessToken: login.accessToken,
      workspaceId: workspaceId,
    );
    _lastDemandSuccess = DateTime.now();
    return {
      for (final item in demand)
        if (item.viewerCount > 0 && item.expiresAt.isAfter(DateTime.now()))
          item.workOrderId,
    };
  }

  Future<void> _stopAll() async {
    final workers = _workers.values.toList();
    _workers.clear();
    for (final worker in workers) {
      await worker.dispose();
    }
    state = state.copyWith(
      activeStreams: 0,
      activePrinterSerials: const <String>{},
      updatedAt: DateTime.now(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final worker in _workers.values) {
      unawaited(worker.dispose());
    }
    _workers.clear();
    super.dispose();
  }
}

final studioVideoRelayControllerProvider =
    StateNotifierProvider<StudioVideoRelayController, StudioVideoRelayState>(
        (ref) {
  final enabled = ref.watch(studioModeEnabledProvider);
  final signedIn =
      ref.watch(appAuthProvider.select((state) => state.isSignedIn));
  return StudioVideoRelayController(ref, active: enabled && signedIn);
});

class _RelayCandidate {
  const _RelayCandidate({
    required this.workspaceId,
    required this.orderId,
    required this.workOrderId,
    required this.config,
    required this.model,
    required this.publicPrinterName,
    this.cloudSession,
    this.firmwareVersion,
  });

  final String workspaceId;
  final String orderId;
  final String workOrderId;
  final PrinterConnectionConfig config;
  final String model;
  final String publicPrinterName;
  final BambuCloudSession? cloudSession;
  final String? firmwareVersion;
}

class _StudioCameraRelayWorker {
  _StudioCameraRelayWorker(this.ref, this.candidate);

  final Ref ref;
  final _RelayCandidate candidate;
  StudioApiClient? _api;
  StudioVideoUplinkSession? _session;
  _CameraFrameSource? _source;
  _FfmpegCameraPusher? _pusher;
  StreamSubscription<Uint8List>? _frameSubscription;
  bool _uploading = false;
  bool _disposed = false;

  bool matches(_RelayCandidate other) =>
      candidate.workspaceId == other.workspaceId &&
      candidate.orderId == other.orderId &&
      candidate.workOrderId == other.workOrderId &&
      candidate.config.host == other.config.host &&
      candidate.config.accessCode == other.config.accessCode &&
      candidate.config.mode == other.config.mode &&
      candidate.cloudSession?.accessToken == other.cloudSession?.accessToken &&
      candidate.firmwareVersion == other.firmwareVersion &&
      candidate.model == other.model;

  bool get isHealthy => _pusher?.isRunning ?? true;

  Future<void> start() async {
    final auth = ref.read(appAuthProvider);
    final endpoint = auth.endpoint;
    if (endpoint == null) throw StateError('未配置云服务地址');
    final login = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 3));
    final api = StudioApiClient(
      baseUri: endpoint,
      httpClient: ref.read(communityHttpClientProvider),
    );
    final session = await api.createVideoSession(
      accessToken: login.accessToken,
      workspaceId: candidate.workspaceId,
      orderId: candidate.orderId,
      workOrderId: candidate.workOrderId,
      publicPrinterName: candidate.publicPrinterName,
    );
    _api = api;
    _session = session;
    if (session.usesRtmp) {
      final pusher = _FfmpegCameraPusher(
        config: candidate.config,
        model: candidate.model,
        pushUri: session.pushUri!,
        cloudSession: candidate.cloudSession,
        firmwareVersion: candidate.firmwareVersion,
      );
      _pusher = pusher;
      await pusher.start();
      return;
    }
    final source = _cameraFrameSourceFor(
      config: candidate.config,
      model: candidate.model,
      cloudSession: candidate.cloudSession,
      firmwareVersion: candidate.firmwareVersion,
    );
    _source = source;
    _frameSubscription = source.frames.listen(_uploadFrame);
    await source.start();
  }

  Future<void> _uploadFrame(Uint8List jpeg) async {
    if (_disposed || _uploading || jpeg.isEmpty) return;
    final api = _api;
    final session = _session;
    if (api == null || session == null) return;
    _uploading = true;
    try {
      await api.uploadVideoFrame(session: session, jpeg: jpeg);
    } on StudioCloudException catch (error) {
      if (error.statusCode != 429) {
        debugPrint('[StudioVideoRelay] frame upload failed: ${error.message}');
      }
    } catch (error) {
      debugPrint('[StudioVideoRelay] frame upload failed: $error');
    } finally {
      _uploading = false;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _frameSubscription?.cancel();
    await _source?.dispose();
    await _pusher?.dispose();
    final session = _session;
    final api = _api;
    if (session != null && api != null) {
      try {
        final login = await ref
            .read(appAuthProvider.notifier)
            .ensureValidSession(minimumValidity: const Duration(seconds: 30));
        await api.stopVideoSession(
          accessToken: login.accessToken,
          workspaceId: candidate.workspaceId,
          sessionId: session.id,
        );
      } catch (_) {}
    }
  }
}

_CameraFrameSource _cameraFrameSourceFor({
  required PrinterConnectionConfig config,
  required String model,
  required BambuCloudSession? cloudSession,
  required String? firmwareVersion,
}) {
  if (config.mode == BambuConnectionMode.cloud) {
    final session = cloudSession;
    if (session == null) throw StateError('云端摄像头缺少拓竹账号会话');
    return _BambuCloudCameraFrameSource(
      session: session,
      serial: config.serial,
      firmwareVersion: firmwareVersion,
    );
  }
  return _usesRtsp(model)
      ? _RtspCameraFrameSource(config)
      : _Port6000CameraFrameSource(config);
}

class _FfmpegCameraPusher {
  _FfmpegCameraPusher({
    required this.config,
    required this.model,
    required this.pushUri,
    this.cloudSession,
    this.firmwareVersion,
  });

  final PrinterConnectionConfig config;
  final String model;
  final Uri pushUri;
  final BambuCloudSession? cloudSession;
  final String? firmwareVersion;
  Process? _process;
  _PinnedRtspProxy? _proxy;
  _Port6000CameraFrameSource? _mjpegSource;
  _CameraFrameSource? _source;
  StreamSubscription<Uint8List>? _frameSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _disposed = false;
  bool _running = false;

  bool get isRunning => _running && !_disposed;

  Future<void> start() async {
    final ffmpeg = await _findFfmpegExecutable();
    if (ffmpeg == null) {
      throw StateError(
        '未找到直播视频组件 ffmpeg.exe，请将它放到程序 tools/ffmpeg 目录',
      );
    }
    if (config.mode == BambuConnectionMode.cloud) {
      final session = cloudSession;
      if (session == null) throw StateError('云端摄像头缺少拓竹账号会话');
      await _startMjpeg(
        ffmpeg,
        source: _BambuCloudCameraFrameSource(
          session: session,
          serial: config.serial,
          firmwareVersion: firmwareVersion,
        ),
      );
    } else if (_usesRtsp(model)) {
      await _startRtsp(ffmpeg);
    } else {
      await _startMjpeg(ffmpeg);
    }
    _running = true;
    final process = _process!;
    unawaited(
      process.exitCode.then((code) {
        _running = false;
        if (!_disposed) {
          debugPrint('[StudioVideoRelay] ffmpeg exited with code $code');
        }
      }),
    );
    final earlyExit = await Future.any<int>([
      process.exitCode,
      Future<int>.delayed(const Duration(milliseconds: 800), () => -999),
    ]);
    if (earlyExit != -999) {
      throw StateError('直播推流组件启动失败，退出码 $earlyExit');
    }
  }

  Future<void> _startRtsp(String ffmpeg) async {
    if (!await PrinterCertificateTrustStore.hasTrust(
      serial: config.serial,
      host: config.host,
      service: PrinterTlsService.camera,
    )) {
      throw StateError('打印机证书尚未在本机确认，请先完成一次 LAN 连接');
    }
    final proxy = _PinnedRtspProxy(config);
    await proxy.start();
    _proxy = proxy;
    final accessCode = Uri.encodeComponent(config.accessCode);
    final sourceUrl =
        'rtsp://bblp:$accessCode@127.0.0.1:${proxy.port}/streaming/live/1';
    await _startProcess(ffmpeg, [
      '-nostdin',
      '-hide_banner',
      '-loglevel',
      'warning',
      '-rtsp_transport',
      'tcp',
      '-fflags',
      'nobuffer',
      '-flags',
      'low_delay',
      '-i',
      sourceUrl,
      '-map',
      '0:v:0',
      '-an',
      '-c:v',
      'copy',
      '-flvflags',
      'no_duration_filesize',
      '-f',
      'flv',
      pushUri.toString(),
    ]);
  }

  Future<void> _startMjpeg(
    String ffmpeg, {
    _CameraFrameSource? source,
  }) async {
    await _startProcess(ffmpeg, [
      '-nostdin',
      '-hide_banner',
      '-loglevel',
      'warning',
      '-use_wallclock_as_timestamps',
      '1',
      '-f',
      'mjpeg',
      '-i',
      'pipe:0',
      '-an',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-tune',
      'zerolatency',
      '-pix_fmt',
      'yuv420p',
      '-r',
      '5',
      '-g',
      '10',
      '-keyint_min',
      '10',
      '-sc_threshold',
      '0',
      '-flvflags',
      'no_duration_filesize',
      '-flush_packets',
      '1',
      '-f',
      'flv',
      pushUri.toString(),
    ]);
    final frameSource = source ?? _Port6000CameraFrameSource(config);
    if (frameSource is _Port6000CameraFrameSource) {
      _mjpegSource = frameSource;
    } else {
      _source = frameSource;
    }
    _frameSubscription = frameSource.frames.listen(
      (frame) {
        final process = _process;
        if (!_disposed && process != null) process.stdin.add(frame);
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[StudioVideoRelay] MJPEG camera stream failed: $error');
      },
    );
    await frameSource.start();
  }

  Future<void> _startProcess(String executable, List<String> arguments) async {
    final process = await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.normal,
      runInShell: false,
    );
    _process = process;
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final value = _sanitizeCloudBridgeDiagnostic(line.trim());
      if (value.isNotEmpty) {
        debugPrint('[StudioVideoRelay] ffmpeg: $value');
      }
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _running = false;
    await _frameSubscription?.cancel();
    await _mjpegSource?.dispose();
    await _source?.dispose();
    final process = _process;
    if (process != null) {
      try {
        await process.stdin.close();
      } catch (_) {}
      if (await _processStillRunning(process)) {
        process.kill();
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
      }
    }
    await _stderrSubscription?.cancel();
    await _proxy?.dispose();
  }
}

Future<bool> _processStillRunning(Process process) async {
  final marker = Object();
  final result = await Future.any<Object>([
    process.exitCode.then<Object>((_) => false),
    Future<Object>.delayed(const Duration(milliseconds: 20), () => marker),
  ]);
  return identical(result, marker);
}

Future<String?> _findFfmpegExecutable() async {
  final configured = Platform.environment['SOHUN_FFMPEG_PATH']?.trim();
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  final appData = Platform.environment['APPDATA']?.trim();
  final candidates = <String>[
    if (configured != null && configured.isNotEmpty) configured,
    '$executableDirectory\\tools\\ffmpeg\\ffmpeg.exe',
    '$executableDirectory\\ffmpeg.exe',
    if (appData != null && appData.isNotEmpty)
      '$appData\\BambuStudio\\cameratools\\ffmpeg.exe',
  ];
  for (final candidate in candidates) {
    if (await File(candidate).exists()) return candidate;
  }
  try {
    final result = await Process.run('where.exe', const ['ffmpeg.exe']);
    if (result.exitCode == 0) {
      for (final line in result.stdout.toString().split(RegExp(r'[\r\n]+'))) {
        final candidate = line.trim();
        if (candidate.isNotEmpty && await File(candidate).exists()) {
          return candidate;
        }
      }
    }
  } catch (_) {}
  return null;
}

abstract class FarmCameraPreviewSession {
  Stream<Uint8List> get frames;
  Future<void> dispose();
}

typedef FarmCameraPreviewConnector = Future<FarmCameraPreviewSession> Function({
  required PrinterConnectionConfig config,
  required String model,
});

final farmCameraPreviewConnectorProvider =
    Provider<FarmCameraPreviewConnector>((ref) {
  final ownerMap = ref.watch(printerOwnerMapProvider);
  final accountState = ref.watch(bambuAccountManagerProvider);
  final cloudDevices = ref.watch(allCloudDevicesProvider).devices;
  return ({
    required PrinterConnectionConfig config,
    required String model,
  }) {
    final cloudSession = _cloudSessionForSerial(
      serial: config.serial,
      ownerMap: ownerMap,
      accountState: accountState,
    );
    String? firmwareVersion;
    for (final device in cloudDevices) {
      if (device.devId == config.serial) {
        firmwareVersion = device.swVer;
        break;
      }
    }
    return connectFarmCameraPreview(
      config: config,
      model: model,
      cloudSession: cloudSession,
      firmwareVersion: firmwareVersion,
    );
  };
});

BambuCloudSession? _cloudSessionForSerial({
  required String serial,
  required Map<String, String> ownerMap,
  required BambuAccountManagerState accountState,
}) {
  final ownerKey = ownerMap[serial];
  if (ownerKey == null) return null;
  // 云端设备必须使用其归属账号的 session，不能因为当前 UI 切换了账号
  // 就把另一账号的 token 用到该设备上。
  return accountState.sessions[ownerKey];
}

class FarmCameraCertificateTrustRequired implements Exception {
  const FarmCameraCertificateTrustRequired({
    required this.config,
    required this.fingerprint,
    required this.subject,
    required this.issuer,
  });

  final PrinterConnectionConfig config;
  final String fingerprint;
  final String subject;
  final String issuer;

  @override
  String toString() => '需要确认打印机证书：$fingerprint';
}

Future<PrinterConnectionConfig> resolveFarmCameraConnectionConfig(
  PrinterConnectionConfig config,
) async {
  if (config.mode == BambuConnectionMode.lan) {
    if (config.host.trim().isEmpty || config.accessCode.trim().isEmpty) {
      throw StateError('局域网绑定缺少打印机地址或访问码，请重新配置设备连接');
    }
    return config;
  }

  // 云端模式只使用拓竹账号会话 + TTCode/TUTK P2P。它不需要 LAN IP、
  // LAN Access Code，也不应触发局域网发现或转换为 LAN 配置。
  if (config.serial.trim().isEmpty) {
    throw StateError('云端模式缺少打印机序列号，无法建立远程摄像头连接');
  }
  return config;
}

Future<FarmCameraPreviewSession> connectFarmCameraPreview({
  required PrinterConnectionConfig config,
  required String model,
  BambuCloudSession? cloudSession,
  String? firmwareVersion,
}) async {
  if (config.mode == BambuConnectionMode.cloud) {
    if (cloudSession == null) {
      throw StateError(
        '这台云端打印机没有可用的拓竹账号会话，无法建立远程视频。'
        '请点击“拓竹账号”重新登录并同步设备。',
      );
    }
    final source = _BambuCloudCameraFrameSource(
      session: cloudSession,
      serial: config.serial,
      firmwareVersion: firmwareVersion,
    );
    try {
      await source.start();
      return _FarmLanCameraPreviewSession(source);
    } catch (_) {
      await source.dispose();
      rethrow;
    }
  }

  final resolved = await resolveFarmCameraConnectionConfig(config);

  if (!await PrinterCertificateTrustStore.hasTrust(
    serial: resolved.serial,
    host: resolved.host,
    service: PrinterTlsService.camera,
  )) {
    throw await _probeFarmCameraCertificate(
      resolved,
      port: _usesRtsp(model) ? 322 : 6000,
    );
  }

  final source = _usesRtsp(model)
      ? _RtspCameraFrameSource(
          resolved,
          captureInterval: const Duration(milliseconds: 500),
        )
      : _Port6000CameraFrameSource(resolved);
  try {
    await source.start();
    return _FarmLanCameraPreviewSession(source);
  } catch (_) {
    await source.dispose();
    rethrow;
  }
}

Future<FarmCameraCertificateTrustRequired> _probeFarmCameraCertificate(
  PrinterConnectionConfig config, {
  required int port,
}) async {
  SecureSocket? socket;
  X509Certificate? certificate;
  try {
    socket = await SecureSocket.connect(
      config.host,
      port,
      timeout: const Duration(seconds: 10),
      onBadCertificate: (candidate) {
        certificate = candidate;
        return true;
      },
    );
    certificate ??= socket.peerCertificate;
    final peer = certificate;
    if (peer == null) throw const HandshakeException('打印机未提供 TLS 证书');
    return FarmCameraCertificateTrustRequired(
      config: config,
      fingerprint: PrinterCertificateTrustStore.fingerprintForDer(peer.der),
      subject: peer.subject,
      issuer: peer.issuer,
    );
  } finally {
    socket?.destroy();
  }
}

class _FarmLanCameraPreviewSession implements FarmCameraPreviewSession {
  _FarmLanCameraPreviewSession(this.source);

  final _CameraFrameSource source;
  bool _disposed = false;

  @override
  Stream<Uint8List> get frames => source.frames;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await source.dispose();
  }
}

abstract class _CameraFrameSource {
  Stream<Uint8List> get frames;
  Future<void> start();
  Future<void> dispose();
}

class _BridgeBinaryReader {
  _BridgeBinaryReader(Stream<List<int>> stream)
      : _iterator = StreamIterator<List<int>>(stream);

  final StreamIterator<List<int>> _iterator;
  List<int> _buffer = <int>[];
  int _offset = 0;

  Future<Uint8List> readExact(int length) async {
    if (length < 0 || length > 8 * 1024 * 1024) {
      throw StateError('远程摄像头返回了异常数据长度：$length');
    }
    while (_buffer.length - _offset < length) {
      if (!await _iterator.moveNext()) {
        throw StateError('远程摄像头数据流意外结束');
      }
      if (_offset > 0) {
        _buffer = _buffer.sublist(_offset);
        _offset = 0;
      }
      _buffer.addAll(_iterator.current);
    }
    final result = Uint8List.fromList(
      _buffer.sublist(_offset, _offset + length),
    );
    _offset += length;
    if (_offset == _buffer.length) {
      _buffer = <int>[];
      _offset = 0;
    }
    return result;
  }

  Future<int> readU32() async {
    final bytes = await readExact(4);
    return ByteData.sublistView(bytes).getUint32(0, Endian.little);
  }

  Future<void> cancel() => _iterator.cancel();
}

/// Cloud/WAN camera source.
///
/// The Bambu cloud only returns temporary P2P credentials. The installed
/// Bambu Studio BambuSource.dll establishes the TUTK connection; a tiny local
/// bridge reads its public C ABI and keeps credentials off the command line.
/// H.264 is exposed to media_kit through a loopback-only HTTP stream, then
/// sampled as JPEG so the existing customer relay remains unchanged.
class _BambuCloudCameraFrameSource implements _CameraFrameSource {
  _BambuCloudCameraFrameSource({
    required this.session,
    required this.serial,
    this.firmwareVersion,
  });

  final BambuCloudSession session;
  final String serial;
  final String? firmwareVersion;
  final Duration captureInterval = const Duration(milliseconds: 700);
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  Process? _bridge;
  StreamSubscription<String>? _bridgeErrors;
  _BridgeBinaryReader? _reader;
  HttpServer? _server;
  HttpResponse? _videoResponse;
  Player? _player;
  Timer? _captureTimer;
  bool _capturing = false;
  bool _disposed = false;
  String? _lastBridgeError;
  final Queue<String> _bridgeDiagnostics = Queue<String>();
  final List<String> _stickyBridgeFacts = <String>[];
  _BridgeDiagnosticStore? _diagnosticStore;
  String? _lastDllSha256;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> start() async {
    final sourceDll = await _prepareBambuSourceRuntime();
    if (sourceDll == null) {
      throw StateError(
        '无法导入拓竹远程视频组件。请先在官方 Bambu Studio 中安装网络插件，'
        '本软件会自动将它导入自己的私有运行目录。',
      );
    }
    final bridgeExe = await _extractCloudCameraBridge();
    final credentials = await BambuCloudClient.getCameraCredentials(
      session,
      serial,
      firmwareVersion: firmwareVersion,
    );
    if (credentials.type.toLowerCase() != 'tutk') {
      throw StateError('当前云端摄像头协议 ${credentials.type} 暂不受支持');
    }
    final clientId = await _farmCameraClientId();
    final fallbackCameraUrl = _buildCloudCameraUrl(
      credentials: credentials,
      serial: serial,
      firmwareVersion: firmwareVersion,
      session: session,
      clientId: clientId,
    );
    final loginInfo = _buildCloudCameraLoginInfo(session);

    final process = await Process.start(
      bridgeExe,
      [sourceDll],
      workingDirectory: File(sourceDll).parent.path,
      mode: ProcessStartMode.normal,
      runInShell: false,
    );
    _bridge = process;
    _diagnosticStore = await _BridgeDiagnosticStore.open();
    await _diagnosticStore?.trim();
    _bridgeErrors = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _recordBridgeDiagnostic(line);
    });
    process.stdin.writeln('SOHBCAM3');
    process.stdin.writeln(serial);
    process.stdin.writeln(session.region == BambuRegion.china ? 'CN' : 'US');
    process.stdin.writeln(BambuClientVersion.bambuStudio);
    process.stdin.writeln(clientId);
    process.stdin.writeln(loginInfo);
    process.stdin.writeln(fallbackCameraUrl);
    // Reserved protocol field kept for SOHBCAM3 compatibility.
    process.stdin.writeln('');
    await process.stdin.close();

    final reader = _BridgeBinaryReader(process.stdout);
    _reader = reader;
    try {
      final magic = utf8.decode(
        await reader.readExact(8).timeout(
              // A sleeping device waits for the user to open the camera once
              // in Bambu Studio / Bambu Handy (bridge polls up to 240 s and
              // then retries the TUTK open). 300 s keeps that flow alive.
              const Duration(seconds: 300),
              onTimeout: () => throw TimeoutException(
                '',
              ),
            ),
      );
      final version = await reader.readU32();
      final codec = await reader.readU32();
      await reader.readU32(); // Bambu format type, normalized by the bridge.
      final extraSize = await reader.readU32();
      final extra =
          extraSize == 0 ? Uint8List(0) : await reader.readExact(extraSize);
      if (magic != 'SOHBCAM1' || version != 1) {
        throw StateError('远程摄像头桥接组件版本不兼容');
      }
      if (codec == 2) {
        unawaited(_pumpJpeg(reader));
      } else if (codec == 1) {
        await _startH264(reader, extra);
      } else {
        throw StateError('远程摄像头返回了未知视频编码：$codec');
      }
      CameraDiagnosticsTelemetry.recordDetached(
        serial: serial,
        outcome: 'stream_started',
        stage: 'header_ok',
        dllSha256: _lastDllSha256,
      );
    } catch (error) {
      final detail = _bridgeDiagnosticSummary;
      CameraDiagnosticsTelemetry.recordDetached(
        serial: serial,
        outcome: 'failed',
        stage: 'start_failed',
        dllSha256: _lastDllSha256,
        bridgeTail: detail,
      );
      await _stopBridge();
      throw StateError(_cloudBridgeFailureMessage(error, detail));
    }

    unawaited(
      process.exitCode.then((code) {
        if (!_disposed && code != 0 && !_frames.isClosed) {
          CameraDiagnosticsTelemetry.recordDetached(
            serial: serial,
            outcome: 'bridge_exited',
            stage: 'exit_$code',
            dllSha256: _lastDllSha256,
            bridgeTail: _bridgeDiagnosticSummary,
          );
          _frames.addError(
            StateError(
              '远程摄像头连接已结束（$code）'
              '${_bridgeDiagnosticSummary == null ? '' : '：$_bridgeDiagnosticSummary'}',
            ),
          );
        }
      }),
    );
  }

  Future<void> _startH264(
    _BridgeBinaryReader reader,
    Uint8List extra,
  ) async {
    MediaKit.ensureInitialized();
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    _server = server;
    final responseReady = Completer<HttpResponse>();
    server.listen((request) {
      if (request.uri.path != '/camera.h264' || responseReady.isCompleted) {
        request.response.statusCode = HttpStatus.notFound;
        unawaited(request.response.close());
        return;
      }
      request.response.headers.contentType = ContentType('video', 'h264');
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      responseReady.complete(request.response);
    });

    final player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        title: 'sohun cloud camera relay',
      ),
    );
    _player = player;
    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('demuxer-lavf-format', 'h264');
      await platform.setProperty('cache', 'no');
    }
    final mediaUrl = 'http://127.0.0.1:${server.port}/camera.h264';
    unawaited(
      player.open(Media(mediaUrl)).catchError((Object error) {
        if (!_disposed && !_frames.isClosed) _frames.addError(error);
      }),
    );
    final response = await responseReady.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw StateError('本地视频解码器没有连接远程画面桥'),
    );
    _videoResponse = response;
    if (extra.isNotEmpty) response.add(extra);
    unawaited(_pumpH264(reader, response));
    _captureTimer = Timer.periodic(captureInterval, (_) {
      unawaited(_capture());
    });
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 500), _capture),
    );
  }

  Future<void> _pumpH264(
    _BridgeBinaryReader reader,
    HttpResponse response,
  ) async {
    var framesSinceFlush = 0;
    try {
      while (!_disposed) {
        final length = await reader.readU32();
        final sample = await reader.readExact(length);
        response.add(sample);
        framesSinceFlush++;
        if (framesSinceFlush >= 5) {
          framesSinceFlush = 0;
          await response.flush();
        }
      }
    } catch (error) {
      if (!_disposed && !_frames.isClosed) _frames.addError(error);
    }
  }

  Future<void> _pumpJpeg(_BridgeBinaryReader reader) async {
    try {
      while (!_disposed) {
        final length = await reader.readU32();
        final jpeg = await reader.readExact(length);
        if (jpeg.length >= 4 &&
            jpeg[0] == 0xff &&
            jpeg[1] == 0xd8 &&
            !_frames.isClosed) {
          _frames.add(jpeg);
        }
      }
    } catch (error) {
      if (!_disposed && !_frames.isClosed) _frames.addError(error);
    }
  }

  Future<void> _capture() async {
    if (_capturing || _disposed || _frames.isClosed) return;
    _capturing = true;
    try {
      final jpeg = await _player?.screenshot(format: 'image/jpeg');
      if (jpeg != null && jpeg.length >= 4 && !_frames.isClosed) {
        _frames.add(jpeg);
      }
    } catch (error) {
      debugPrint('[StudioVideoRelay] cloud camera screenshot failed: $error');
    } finally {
      _capturing = false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _captureTimer?.cancel();
    await _videoResponse?.close();
    await _server?.close(force: true);
    await _player?.dispose();
    await _reader?.cancel();
    await _stopBridge();
    await _bridgeErrors?.cancel();
    _diagnosticStore = null;
    await _frames.close();
  }

  Future<void> _stopBridge() async {
    final bridge = _bridge;
    _bridge = null;
    if (bridge == null) return;
    bridge.kill();
    try {
      await bridge.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      bridge.kill(ProcessSignal.sigkill);
    }
  }

  void _recordBridgeDiagnostic(String line) {
    final value = _sanitizeCloudBridgeDiagnostic(line.trim());
    if (value.isEmpty) return;
    final dllMarker = 'dll_sha256=';
    final dllAt = line.indexOf(dllMarker);
    if (dllAt >= 0) {
      final start = dllAt + dllMarker.length;
      final end = start + 64 <= line.length ? start + 64 : line.length;
      final candidate = line.substring(start, end);
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(candidate)) {
        _lastDllSha256 = candidate;
      }
    }
    _lastBridgeError = value;
    _bridgeDiagnostics.addLast(value);
    while (_bridgeDiagnostics.length > 40) {
      _bridgeDiagnostics.removeFirst();
    }
    final fact = extractBridgeTerminalFact(value);
    if (fact != null && !_stickyBridgeFacts.contains(fact)) {
      _stickyBridgeFacts.add(fact);
      while (_stickyBridgeFacts.length > 8) {
        _stickyBridgeFacts.removeAt(0);
      }
    }
    unawaited(_diagnosticStore?.append(value));
    debugPrint('[StudioVideoRelay] cloud camera bridge: $value');
  }

  String? get _bridgeDiagnosticSummary {
    // Sticky terminal facts (sleep detection, wake timeout, cloud rejection)
    // are reported first so later noisy retry lines can never push them out
    // of the summary. Recent lines follow for context.
    final parts = <String>[
      if (_stickyBridgeFacts.isNotEmpty) _stickyBridgeFacts.join(' | '),
      if (_bridgeDiagnostics.isNotEmpty)
        _bridgeDiagnostics
            .skip(
              _bridgeDiagnostics.length > 3 ? _bridgeDiagnostics.length - 3 : 0,
            )
            .join(' | ')
      else if (_lastBridgeError != null)
        _lastBridgeError!,
    ];
    if (parts.isEmpty) return _lastBridgeError;
    return parts.join(' | ');
  }
}

String _sanitizeCloudBridgeDiagnostic(String input) {
  var value = input.replaceAll(
    RegExp(r'bambu:///[^\s]+', caseSensitive: false),
    '[camera-url-redacted]',
  );
  // Bearer / Authorization headers before the generic key=value pass so the
  // scheme word itself cannot leak.
  value = value.replaceAllMapped(
    RegExp(
      r'bearer\s+[A-Za-z0-9_\-.]+',
      caseSensitive: false,
    ),
    (match) => 'Bearer [redacted]',
  );
  value = value.replaceAllMapped(
    RegExp(
      r'(authorization|x-bbl-device-security-sign)\s*:\s*\S+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}: [redacted]',
  );
  value = value.replaceAllMapped(
    RegExp(
      r'(access_code|authkey|passwd|refresh_token|token|uid|ttcode|'
      r'device_security_sign|device-security-sign|security_sign|'
      r'security-sign|login_info|loginInfo)\s*[=:]\s*[^\s,;)}\]]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=[redacted]',
  );
  return value;
}

/// Extracts a stable, redacted terminal fact from a bridge stderr line.
///
/// Sticky facts survive the 40-entry diagnostic ring so a decisive event
/// (device asleep, wake timeout, cloud rejection, tunnel established) is
/// never pushed out of the failure summary by later noisy retry lines.
String? extractBridgeTerminalFact(String line) {
  final lower = line.toLowerCase();
  if (lower.contains('need_official_wake')) {
    return 'NEED_OFFICIAL_WAKE: printer camera is asleep (tutk_server=disable); '
        'wake it once from Bambu Studio or Bambu Handy';
  }
  if (lower.contains('device woke up via signed')) {
    return 'DEVICE_WOKE_UP: signed cloud wake request woke the camera';
  }
  if (lower.contains('device woke up via official client')) {
    return 'DEVICE_WOKE_UP: official client woke the camera';
  }
  if (lower.contains('sign_rejected')) {
    return 'SIGN_REJECTED: cloud rejected the device security sign';
  }
  if (lower.contains('wake wait timed out')) {
    return 'OFFICIAL_WAKE_WAIT_TIMEOUT: the official client did not wake '
        'the camera within the wait window';
  }
  if (lower.contains('bambu_open failed after retry')) {
    return line;
  }
  if (lower.contains('http 403')) {
    return 'CLOUD_HTTP_403: cloud refused the camera credential request';
  }
  if (lower.contains('camera tunnel open returned 0')) {
    return 'TUNNEL_CONNECTED: camera tunnel established';
  }
  return null;
}

/// Persists sanitized bridge stderr lines as JSON lines under the app's
/// support directory so the latest bridge state survives app restarts and
/// can be reviewed from the diagnostics screen. Only sanitized text ever
/// reaches this file.
class _BridgeDiagnosticStore {
  _BridgeDiagnosticStore._(this._file, this.enabled);

  final File _file;
  final bool enabled;

  static const int maxLines = 200;

  static Future<_BridgeDiagnosticStore> open() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final diagnosticsDir = Directory('${dir.path}\\diagnostics');
      if (!await diagnosticsDir.exists()) {
        await diagnosticsDir.create(recursive: true);
      }
      return _BridgeDiagnosticStore._(
        File('${diagnosticsDir.path}\\cloud_bridge_diagnostics.jsonl'),
        true,
      );
    } catch (_) {
      return _BridgeDiagnosticStore._(File(''), false);
    }
  }

  /// Keeps the most recent [maxLines] entries; called once per session.
  Future<void> trim() async {
    if (!enabled) return;
    try {
      if (!await _file.exists()) return;
      final lines = await _file.readAsLines();
      if (lines.length <= maxLines) return;
      await _file.writeAsString(
        '${lines.sublist(lines.length - maxLines).join('\n')}\n',
      );
    } catch (_) {}
  }

  Future<void> append(String sanitizedLine) async {
    if (!enabled) return;
    try {
      final entry = jsonEncode(<String, String>{
        'ts': DateTime.now().toIso8601String(),
        'line': sanitizedLine,
      });
      await _file.writeAsString(
        '$entry\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {}
  }
}

String _cloudBridgeFailureMessage(Object error, String? detail) {
  final sanitizedDetail =
      detail == null ? null : _sanitizeCloudBridgeDiagnostic(detail);
  final combined = '$error ${sanitizedDetail ?? ''}'.toLowerCase();
  if (combined.contains('sign_rejected')) {
    return '云端拒绝了摄像头的唤醒签名（签名可能已轮换）。'
        '请先更新 Bambu Studio 官方插件（桥接会自动跟随新版组件重新捕获），'
        '再回来重试；若仍失败，请在 Bambu Studio 或 Handy 中打开一次'
        '打印机摄像头唤醒设备。';
  }
  if (combined.contains('need_official_wake') ||
      combined.contains('wake wait timed out')) {
    return '打印机摄像头处于休眠，等待官方客户端唤醒超时。'
        '请先在 Bambu Studio 或拓竹 Handy App 中打开一次该打印机的摄像头，'
        '待官方画面出现后回到这里点击“重新连接”，本软件会自动接管视频。';
  }
  if (error is TimeoutException) {
    return '连接远程摄像头超时，请稍后重试'
        '${sanitizedDetail == null ? '' : '（$sanitizedDetail）'}';
  }
  if (combined.contains('-90')) {
    return '打印机摄像头仍在休眠，本次自动唤醒未能成功。请稍后重试，'
        '或先在 Bambu Studio/Handy 中打开一次摄像头唤醒设备。';
  }
  if (combined.contains('bambu_startstream') ||
      combined.contains('no video track')) {
    return '已连接到远程摄像头，但暂时没有收到视频画面，请稍后重试。';
  }
  return sanitizedDetail == null ? '$error' : '$error（$sanitizedDetail）';
}

Future<String?> _prepareBambuSourceRuntime() async {
  final configured = Platform.environment['SOHUN_BAMBU_SOURCE_PATH']?.trim();
  final appData = Platform.environment['APPDATA']?.trim();
  final programFiles = Platform.environment['ProgramFiles']?.trim();
  final programFilesX86 = Platform.environment['ProgramFiles(x86)']?.trim();
  final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
  final sourceCandidates = <String>[
    if (configured != null && configured.isNotEmpty)
      File(configured).parent.path,
    if (appData != null && appData.isNotEmpty) '$appData\\BambuStudio\\plugins',
    if (programFiles != null && programFiles.isNotEmpty)
      '$programFiles\\Bambu Studio\\resources\\plugins',
    if (programFilesX86 != null && programFilesX86.isNotEmpty)
      '$programFilesX86\\Bambu Studio\\resources\\plugins',
    // Bambu Studio also supports a per-user Windows installation. Keep this
    // candidate after the machine-wide locations so an explicit/configured
    // installation wins, while still using the user's current official DLLs
    // when no APPDATA plugin copy exists.
    if (localAppData != null && localAppData.isNotEmpty)
      '$localAppData\\Programs\\Bambu Studio\\resources\\plugins',
  ];

  final support = await getApplicationSupportDirectory();
  final runtime = Directory(
    '${support.path}\\secure_runtime\\bbl_cloud_camera\\plugins',
  );
  await runtime.create(recursive: true);
  await _restrictCloudCameraRuntimeAcl(runtime.path);
  final runtimeSource = File('${runtime.path}\\BambuSource.dll');

  Directory? official;
  for (final candidate in sourceCandidates) {
    final directory = Directory(candidate);
    if (await File('${directory.path}\\BambuSource.dll').exists()) {
      official = directory;
      break;
    }
  }
  if (official == null) {
    return await runtimeSource.exists() ? runtimeSource.path : null;
  }

  const componentNames = [
    'BambuSource.dll',
    'bambu_networking.dll',
    'agora_rtc_sdk.dll',
    'libagora-ffmpeg.dll',
    'libagora-soundtouch.dll',
    'libaosl.dll',
    'live555.dll',
  ];
  for (final name in componentNames) {
    final source = File('${official.path}\\$name');
    if (!await source.exists()) continue;
    final target = File('${runtime.path}\\$name');
    await _copyCloudCameraRuntimeFile(source: source, target: target);
  }

  if (!await runtimeSource.exists()) return null;

  final networkingTarget = File('${runtime.path}\\bambu_networking.dll');
  if (!await networkingTarget.exists()) {
    await _extractVerifiedCloudCameraAsset(
      assetPath: 'assets/bin/bambu_networking.dll',
      hashAssetPath: 'assets/bin/bambu_networking.dll.sha256',
      target: networkingTarget,
    );
  }

  final certificateCandidates = <String>[
    if (programFiles != null && programFiles.isNotEmpty)
      '$programFiles\\Bambu Studio\\resources\\cert\\slicer_base64.cer',
    if (programFilesX86 != null && programFilesX86.isNotEmpty)
      '$programFilesX86\\Bambu Studio\\resources\\cert\\slicer_base64.cer',
    if (localAppData != null && localAppData.isNotEmpty)
      '$localAppData\\Programs\\Bambu Studio\\resources\\cert\\slicer_base64.cer',
  ];
  final certificateTarget = File('${runtime.path}\\slicer_base64.cer');
  for (final candidate in certificateCandidates) {
    final source = File(candidate);
    if (!await source.exists()) continue;
    await _copyCloudCameraRuntimeFile(
      source: source,
      target: certificateTarget,
    );
    break;
  }
  if (!await certificateTarget.exists()) {
    await _extractVerifiedCloudCameraAsset(
      assetPath: 'assets/bin/slicer_base64.cer',
      hashAssetPath: 'assets/bin/slicer_base64.cer.sha256',
      target: certificateTarget,
    );
  }

  if (!await networkingTarget.exists() || !await certificateTarget.exists()) {
    return null;
  }
  return runtimeSource.path;
}

Future<void> _extractVerifiedCloudCameraAsset({
  required String assetPath,
  required String hashAssetPath,
  required File target,
}) async {
  final bytes = (await rootBundle.load(assetPath)).buffer.asUint8List();
  final expected = (await rootBundle.loadString(hashAssetPath))
      .trim()
      .split(RegExp(r'\s+'))
      .first
      .toLowerCase();
  final actual = crypto.sha256.convert(bytes).toString().toLowerCase();
  if (actual != expected) {
    throw StateError(
      '内置远程视频组件 ${target.uri.pathSegments.last} 完整性校验失败',
    );
  }

  final temporary = File('${target.path}.new');
  if (await temporary.exists()) await temporary.delete();
  await temporary.writeAsBytes(bytes, flush: true);
  if (await target.exists()) await target.delete();
  await temporary.rename(target.path);
  debugPrint(
    '[StudioVideoRelay] installed bundled camera component: '
    '${target.uri.pathSegments.last}',
  );
}

Future<void> _copyCloudCameraRuntimeFile({
  required File source,
  required File target,
}) async {
  final sourceHash = await _sha256File(source);
  final targetHash = await target.exists() ? await _sha256File(target) : null;
  if (sourceHash == targetHash) return;
  final temporary = File('${target.path}.new');
  if (await temporary.exists()) await temporary.delete();
  await source.openRead().pipe(temporary.openWrite());
  if (await _sha256File(temporary) != sourceHash) {
    await temporary.delete();
    throw StateError('导入远程视频组件 ${source.uri.pathSegments.last} 时完整性校验失败');
  }
  if (await target.exists()) await target.delete();
  await temporary.rename(target.path);
  debugPrint(
    '[StudioVideoRelay] imported Bambu camera component: '
    '${source.uri.pathSegments.last}',
  );
}

Future<String> _sha256File(File file) async {
  final digest = await crypto.sha256.bind(file.openRead()).first;
  return digest.toString();
}

Future<void> _restrictCloudCameraRuntimeAcl(String directoryPath) async {
  if (!Platform.isWindows) return;
  final user = Platform.environment['USERNAME']?.trim();
  if (user == null || user.isEmpty) return;
  try {
    final result = await Process.run('icacls', [
      directoryPath,
      '/inheritance:r',
      '/grant:r',
      '$user:(OI)(CI)F',
    ]);
    if (result.exitCode != 0) {
      debugPrint(
        '[StudioVideoRelay] camera runtime ACL failed: ${result.stderr}',
      );
    }
  } catch (error) {
    debugPrint('[StudioVideoRelay] camera runtime ACL unavailable: $error');
  }
}

Future<String> _extractCloudCameraBridge() async {
  const assetPath = 'assets/bin/cloud_camera_bridge.exe';
  const hashAssetPath = 'assets/bin/cloud_camera_bridge.exe.sha256';
  final support = await getApplicationSupportDirectory();
  final directory = Directory(
    '${support.path}\\secure_runtime\\bbl_cloud_camera',
  );
  await directory.create(recursive: true);
  await _restrictCloudCameraRuntimeAcl(directory.path);
  await stageWindowsRuntimeLibraries(targetDirectory: directory);
  final bytes = (await rootBundle.load(assetPath)).buffer.asUint8List();
  final expected = (await rootBundle.loadString(hashAssetPath))
      .trim()
      .split(RegExp(r'\s+'))
      .first
      .toLowerCase();
  final actual = crypto.sha256.convert(bytes).toString().toLowerCase();
  if (actual != expected) {
    throw StateError('远程摄像头桥接组件完整性校验失败');
  }
  final path = '${directory.path}\\cloud_camera_bridge.exe';
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

String _buildCloudCameraUrl({
  required BambuCloudCameraCredentials credentials,
  required String serial,
  required String? firmwareVersion,
  required BambuCloudSession session,
  required String clientId,
}) {
  final query = Uri(
    queryParameters: {
      'uid': credentials.uid,
      'authkey': credentials.authKey,
      'passwd': credentials.password,
      'region': credentials.region.isEmpty
          ? (session.region == BambuRegion.china ? 'cn' : 'us')
          : credentials.region,
      'device': serial,
      'net_ver': BambuClientVersion.networkAgentStudio,
      'dev_ver': firmwareVersion?.trim().isNotEmpty == true
          ? firmwareVersion!.trim()
          : 'unknown',
      'cli_id': clientId,
      'cli_ver': BambuClientVersion.bambuStudio,
    },
  ).query;
  return 'bambu:///tutk?$query';
}

Future<String> _farmCameraClientId() async {
  final studioId = BambuStudioLanConfigWriter.getSlicerUuid();
  if (studioId != null && studioId.isNotEmpty) return studioId;
  const key = 'farm_camera_client_uuid';
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(key)?.trim();
  if (existing != null && existing.isNotEmpty) return existing;
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final value = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20, 32)}';
  await prefs.setString(key, value);
  return value;
}

String _buildCloudCameraLoginInfo(BambuCloudSession session) {
  int remainingSeconds(DateTime? expiresAt) {
    if (expiresAt == null) return 31536000;
    final seconds = expiresAt.difference(DateTime.now()).inSeconds;
    if (seconds < 60) return 60;
    if (seconds > 31536000) return 31536000;
    return seconds;
  }

  var uid = session.username.trim();
  if (uid.startsWith('u_')) uid = uid.substring(2);
  return jsonEncode({
    'data': {
      'refresh_token': session.refreshToken ?? session.accessToken,
      'token': session.accessToken,
      'expires_in': remainingSeconds(session.expiresAt).toString(),
      'refresh_expires_in':
          remainingSeconds(session.refreshExpiresAt).toString(),
      'user': {
        'uid': uid,
        'name': session.email,
        'account': session.email,
        'avatar': '',
      },
    },
  });
}

class _RtspCameraFrameSource implements _CameraFrameSource {
  _RtspCameraFrameSource(
    this.config, {
    this.captureInterval = const Duration(milliseconds: 1500),
  });

  final PrinterConnectionConfig config;
  final Duration captureInterval;
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  Player? _player;
  _PinnedRtspProxy? _proxy;
  Timer? _timer;
  bool _capturing = false;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> start() async {
    if (!await PrinterCertificateTrustStore.hasTrust(
      serial: config.serial,
      host: config.host,
      service: PrinterTlsService.camera,
    )) {
      throw StateError('打印机证书尚未在本机确认，先在设备页完成一次 LAN 连接');
    }
    MediaKit.ensureInitialized();
    final proxy = _PinnedRtspProxy(config);
    await proxy.start();
    _proxy = proxy;
    final player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        title: 'sohun farm camera relay',
      ),
    );
    _player = player;
    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty(
        'demuxer-lavf-o',
        'rtsp_transport=tcp',
      );
    }
    final accessCode = Uri.encodeComponent(config.accessCode);
    final url =
        'rtsp://bblp:$accessCode@127.0.0.1:${proxy.port}/streaming/live/1';
    await player.open(Media(url));
    _timer = Timer.periodic(captureInterval, (_) {
      unawaited(_capture());
    });
  }

  Future<void> _capture() async {
    if (_capturing || _frames.isClosed) return;
    _capturing = true;
    try {
      final bytes = await _player?.screenshot(format: 'image/jpeg');
      if (bytes != null && bytes.length >= 4 && !_frames.isClosed) {
        _frames.add(bytes);
      }
    } catch (error) {
      debugPrint('[StudioVideoRelay] RTSP screenshot failed: $error');
    } finally {
      _capturing = false;
    }
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _player?.dispose();
    await _proxy?.dispose();
    await _frames.close();
  }
}

class _PinnedRtspProxy {
  _PinnedRtspProxy(this.config);

  final PrinterConnectionConfig config;
  final Set<Socket> _localSockets = {};
  final Set<SecureSocket> _remoteSockets = {};
  ServerSocket? _server;
  PrinterCertificateVerifier? _verifier;
  bool _disposed = false;

  int get port {
    final server = _server;
    if (server == null) throw StateError('RTSP 本地桥尚未启动');
    return server.port;
  }

  Future<void> start() async {
    _verifier = await PrinterCertificateTrustStore.loadVerifier(
      serial: config.serial,
      host: config.host,
      service: PrinterTlsService.camera,
    );
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    if (_disposed) {
      await server.close();
      return;
    }
    _server = server;
    server.listen(
      (socket) => unawaited(_bridge(socket)),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[StudioVideoRelay] RTSP proxy listener failed: $error');
      },
    );
  }

  Future<void> _bridge(Socket local) async {
    if (_disposed) {
      local.destroy();
      return;
    }
    _localSockets.add(local);
    SecureSocket? remote;
    try {
      final verifier = _verifier;
      if (verifier == null) throw StateError('RTSP 证书校验器未初始化');
      remote = await SecureSocket.connect(
        config.host,
        322,
        timeout: const Duration(seconds: 8),
        onBadCertificate: verifier.verifyCertificate,
      );
      if (_disposed) return;
      _remoteSockets.add(remote);
      final localToRemote = local.listen(
        remote.add,
        onDone: remote.destroy,
        onError: (_, __) => remote?.destroy(),
        cancelOnError: true,
      );
      final remoteToLocal = remote.listen(
        local.add,
        onDone: local.destroy,
        onError: (_, __) => local.destroy(),
        cancelOnError: true,
      );
      await Future.any<void>([
        localToRemote.asFuture<void>(),
        remoteToLocal.asFuture<void>(),
      ]);
      await localToRemote.cancel();
      await remoteToLocal.cancel();
    } catch (error) {
      if (!_disposed) {
        debugPrint('[StudioVideoRelay] RTSP proxy connection failed: $error');
      }
    } finally {
      local.destroy();
      remote?.destroy();
      _localSockets.remove(local);
      if (remote != null) _remoteSockets.remove(remote);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _server?.close();
    for (final socket in _localSockets) {
      socket.destroy();
    }
    for (final socket in _remoteSockets) {
      socket.destroy();
    }
    _localSockets.clear();
    _remoteSockets.clear();
  }
}

class _Port6000CameraFrameSource implements _CameraFrameSource {
  _Port6000CameraFrameSource(this.config);

  final PrinterConnectionConfig config;
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  SecureSocket? _socket;
  bool _stopped = false;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> start() async {
    _stopped = false;
    unawaited(_connectionLoop());
  }

  Future<void> _connectionLoop() async {
    while (!_stopped) {
      try {
        final verifier = await PrinterCertificateTrustStore.loadVerifier(
          serial: config.serial,
          host: config.host,
          service: PrinterTlsService.camera,
        );
        final socket = await SecureSocket.connect(
          config.host,
          6000,
          timeout: const Duration(seconds: 8),
          onBadCertificate: verifier.verifyCertificate,
        );
        if (_stopped) {
          socket.destroy();
          return;
        }
        _socket = socket;
        socket.add(_cameraAuthPacket(config.accessCode));
        await _consume(socket);
      } catch (error) {
        if (!_stopped) {
          debugPrint('[StudioVideoRelay] port 6000 reconnect: $error');
        }
      } finally {
        _socket?.destroy();
        _socket = null;
      }
      if (!_stopped) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
  }

  Future<void> _consume(SecureSocket socket) async {
    var buffer = Uint8List(0);
    int? payloadSize;
    await for (final chunk in socket) {
      if (_stopped) return;
      final combined = Uint8List(buffer.length + chunk.length)
        ..setRange(0, buffer.length, buffer)
        ..setRange(buffer.length, buffer.length + chunk.length, chunk);
      buffer = combined;
      while (true) {
        if (payloadSize == null) {
          if (buffer.length < 16) break;
          payloadSize = buffer[0] | (buffer[1] << 8) | (buffer[2] << 16);
          if (payloadSize <= 0 || payloadSize > _videoFrameMaxBytes) {
            throw const FormatException('打印机返回了无效的画面帧长度');
          }
          buffer = Uint8List.sublistView(buffer, 16);
        }
        if (buffer.length < payloadSize) break;
        final frame = Uint8List.fromList(buffer.sublist(0, payloadSize));
        buffer = Uint8List.fromList(buffer.sublist(payloadSize));
        payloadSize = null;
        if (_isJpeg(frame) && !_frames.isClosed) {
          _frames.add(frame);
        }
      }
    }
  }

  @override
  Future<void> dispose() async {
    _stopped = true;
    _socket?.destroy();
    await _frames.close();
  }
}

Uint8List _cameraAuthPacket(String accessCode) {
  final bytes = Uint8List(80);
  ByteData.sublistView(bytes)
    ..setUint32(0, 0x40, Endian.little)
    ..setUint32(4, 0x3000, Endian.little);
  final user = Uint8List.fromList('bblp'.codeUnits);
  bytes.setRange(16, 16 + user.length, user);
  final code = Uint8List.fromList(accessCode.codeUnits.take(32).toList());
  bytes.setRange(48, 48 + code.length, code);
  return bytes;
}

bool _isJpeg(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0xff &&
    bytes[1] == 0xd8 &&
    bytes[bytes.length - 2] == 0xff &&
    bytes[bytes.length - 1] == 0xd9;

bool _usesRtsp(String model) {
  final value = model.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return value.contains('X1') ||
      value.contains('X2D') ||
      value.contains('H2') ||
      value.contains('P2S');
}

String _publicPrinterName(
  PrinterWithChannels printer,
  PrinterConnectionConfig config,
  FleetPrinterState? live,
) {
  final custom = printer.printer.name?.trim();
  if (custom != null && custom.isNotEmpty) return custom;
  final model = config.devProductName?.trim();
  if (model != null && model.isNotEmpty) return model;
  final reported = live?.reportedModel?.trim();
  if (reported != null && reported.isNotEmpty) return reported;
  final localModel = printer.printer.model.trim();
  return localModel.isEmpty ? '生产设备' : localModel;
}

String _friendlyVideoError(Object error) {
  final text = error.toString();
  if (text.length <= 180) return text;
  return '${text.substring(0, 177)}...';
}
