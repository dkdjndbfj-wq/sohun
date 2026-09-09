import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../../../core/services/error_logger.dart';
import 'bambu_cloud_client.dart';
import 'bambu_cloud_models.dart';
import 'bambu_cloud_session_store.dart';
import 'bambu_ftp_uploader.dart';
import 'bambu_feed_telemetry.dart';
import 'bambu_printer_models.dart';
import 'bambu_print_feed.dart';
import 'printer_certificate_trust_store.dart';
import 'printer_connector.dart';
import '../slicer/slice_isolate_runner.dart';

Map<String, dynamic> buildPrintSpeedPayload({
  required int profileLevel,
  required String sequenceId,
}) {
  if (!BambuSpeedProfile.isValidLevel(profileLevel)) {
    throw ArgumentError.value(profileLevel, 'profileLevel', '必须是 1..4');
  }
  return {
    'print': {
      'sequence_id': sequenceId,
      'command': 'print_speed',
      'param': '$profileLevel',
    },
  };
}

/// 拓竹打印机 MQTT 连接器。
///
/// 支持两种连接模式：
/// - **LAN 模式**：直连打印机内置 MQTT broker（端口 8883 TLS）。
///   用户名固定 `bblp`，密码是 LAN Access Code。
/// - **Cloud 模式**：连拓竹云 MQTT（cn.mqtt.bambulab.com / us.mqtt.bambulab.com）。
///   用户名是 `u_xxx`（从 JWT 解析），密码是 accessToken。
///   云模式下电脑和打印机可在不同网络，适合"电脑在外、打印机在家"场景。
///
/// **两种模式的 MQTT 协议完全相同**：topic 结构、消息格式、gcode_state 字段都一样。
/// 所以状态解析逻辑（BambuPrinterStatus.fromMqttJson）完全复用。
///
/// **连接流程**：
/// 1. 根据 config.mode 决定 host/username/password
///    - Cloud 模式从 BambuCloudSessionStore 读 session（token 会过期）
/// 2. 创建 MqttServerClient，配置 TLS（自签证书需跳过验证）
/// 3. 认证连接，订阅 `device/{serial}/report`
/// 4. 发布 `device/{serial}/request` 请求 pushall
class BambuPrinterConnector implements PrinterConnector {
  static int _nextClientOrdinal = 0;

  final PrinterConnectionConfig config;

  /// Cloud 模式下注入的 session（必须是该设备归属账号的 session）。
  /// 云设备不允许隐式读取当前 active account，避免多账号切换后串线。
  final BambuCloudSession? cloudSession;

  /// MQTT broker 会踢掉使用相同 Client ID 的旧连接。工作台与后台舰队
  /// 可能同时监听同一打印机，因此每个 connector 实例必须使用不同 ID，
  /// 且该 ID 在本实例重连期间保持不变。
  final String mqttClientId;

  MqttServerClient? _client;
  final StreamController<BambuPrinterStatus> _statusController =
      StreamController<BambuPrinterStatus>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<PrinterConnectionState> _connectionStateController =
      StreamController<PrinterConnectionState>.broadcast();
  StreamSubscription? _updatesSub;
  BambuPrinterStatus? _lastStatus;
  final _feedTelemetry = BambuFeedTelemetryCache();
  bool _isConnected = false;

  /// L1 修复：标记是否已完成首次订阅，避免 autoReconnect 重连时重复订阅
  bool _subscribed = false;
  int _sequenceId = 0;

  // ===== P1-2: 自定义指数退避重连 =====
  /// 当前重连尝试次数
  int _reconnectAttempts = 0;

  /// 最大重连尝试次数（耗尽后转为 error 状态）
  static const int _maxReconnectAttempts = 10;

  /// 基础重连延迟（第一次重连延迟 2 秒）
  static const Duration _baseReconnectDelay = Duration(seconds: 2);

  /// 最大重连延迟（指数退避上限 60 秒）
  static const Duration _maxReconnectDelay = Duration(seconds: 60);

  /// 重连定时器（可取消）
  Timer? _reconnectTimer;

  /// 是否为主动断开（主动断开时不触发自动重连）
  bool _isExplicitDisconnect = false;

  /// 随机数生成器（用于重连抖动）
  final math.Random _random = math.Random();
  PrinterCertificateVerifier? _lanCertificateVerifier;

  BambuPrinterConnector(this.config, {this.cloudSession})
      : mqttClientId = _createClientId(config.serial);

  static String _createClientId(String serial) {
    final safeSerial = serial.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final serialTail = safeSerial.length > 18
        ? safeSerial.substring(safeSerial.length - 18)
        : safeSerial;
    final ordinal = (_nextClientOrdinal++).toRadixString(36);
    return 'sohun_${serialTail.isEmpty ? 'printer' : serialTail}_$ordinal';
  }

  @override
  bool get isConnected => _isConnected;

  @override
  Stream<BambuPrinterStatus> get statusStream => _statusController.stream;

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  Stream<PrinterConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// 当前最后一次状态快照
  BambuPrinterStatus? get lastStatus => _lastStatus;

  /// 解析连接所需的 host/username/password。
  ///
  /// LAN 模式：直接从 config 取
  /// Cloud 模式：按注入 session 的 email+region 读取最新 session；
  ///   若 session 已过期，使用同一账号的凭据自动重新登录。
  ///
  Future<({String host, String username, String password})>
      _resolveConnectionParams() async {
    if (config.mode == BambuConnectionMode.lan) {
      return (
        host: config.host,
        username: 'bblp',
        password: config.accessCode,
      );
    }

    final ownerSession = cloudSession;
    if (ownerSession == null) {
      throw StateError('云连接缺少设备归属账号会话：请先同步拓竹云设备');
    }
    // 只按设备归属账号读取最新 token，绝不读取全局 active account。
    final latestSession = await BambuCloudSessionStore.loadSessionFor(
      ownerSession.email,
      ownerSession.region,
    );
    var session = latestSession ?? ownerSession;

    // token 过期则尝试用保存的账号密码重新登录
    if (session.isExpired) {
      final account = await BambuCloudSessionStore.loadAccountFor(
        session.email,
        session.region,
      );
      if (account == null) {
        throw StateError('云 session 已过期且无保存的账号密码，请重新登录');
      }
      // 自动重登无法处理验证码场景：若需要验证码则提示用户手动重新登录
      final result = await BambuCloudClient.loginWithPassword(
        region: account.region,
        account: account.email,
        password: account.password,
      );
      if (result.needsVerificationCode) {
        throw StateError('云 session 已过期，账号需要验证码登录，请重新打开设置登录');
      }
      // L2 修复：显式 null 检查，避免 result.session! 在异常情况下抛模糊错误
      if (result.session == null) {
        throw StateError('云 session 重新登录失败：未返回 session');
      }
      session = result.session!;
      await BambuCloudSessionStore.saveSession(session);
    }

    return (
      host: session.region.mqttHost,
      username: session.username,
      password: session.accessToken,
    );
  }

  @override
  Future<bool> connect() async {
    if (_isConnected) return true;

    // P1-2: 重置重连状态
    _isExplicitDisconnect = false;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _connectionStateController.add(PrinterConnectionState.connecting);

    late final String host;
    late final String username;
    late final String password;
    try {
      final params = await _resolveConnectionParams();
      host = params.host;
      username = params.username;
      password = params.password;
      await _loadLanCertificateVerifier();
    } catch (e, st) {
      _handleError('连接参数解析失败: $e', st, context: {'phase': 'resolve_params'});
      _isConnected = false;
      _connectionStateController.add(PrinterConnectionState.error);
      return false;
    }

    if (host.isEmpty) {
      _handleError('连接 host 为空：LAN 模式请填 IP，Cloud 模式请先登录', null);
      _connectionStateController.add(PrinterConnectionState.error);
      return false;
    }

    _setupClient(host, username, password);

    try {
      await _client!.connect();
      return true;
    } catch (e, st) {
      _handleError('连接失败: $e', st, context: {'phase': 'initial_connect'});
      // H4 修复：连接失败时清理 _client，避免残留半连接状态导致后续逻辑误判
      // P1 修复：disconnect 可能抛二次异常（半连接状态），包 try-catch 避免掩盖原始错误
      try {
        _client?.disconnect();
      } catch (_) {}
      _client = null;
      _isConnected = false;
      _connectionStateController.add(PrinterConnectionState.error);
      return false;
    }
  }

  /// P1-2: 创建并配置 MQTT 客户端（初始连接和重连共用）。
  ///
  /// 提取为独立方法是因为重连时需要创建新客户端（旧客户端可能残留半连接状态）。
  /// 禁用 mqtt_client 内置 autoReconnect，改用自定义指数退避重连 [_scheduleReconnect]。
  void _setupClient(String host, String username, String password) {
    _client = MqttServerClient.withPort(
      host,
      mqttClientId,
      config.port,
    );

    // TLS 配置：
    // - LAN 模式：拓竹打印机使用自签名证书，无法走系统 CA 校验，保留绕过（仅限局域网）。
    // - Cloud 模式：公网链路必须严格校验，使用系统默认 CA 验证，onBadCertificate 返回 false。
    //   修复安全风险：原实现对 Cloud/LAN 一律绕过，公网中间人可劫持 token。
    // 注意：onBadCertificate 字段类型是 bool Function(X509Certificate)?，
    // 但 mqtt_client 内部会强转为 bool Function(Object)?。
    // 若 lambda 参数声明为 X509Certificate，运行时会因类型不匹配抛
    // "type '(X509Certificate) => bool is not a subtype of type '((Object)=> bool)?' in type cast"。
    // 修复：lambda 参数用 Object 接收，本身即为 bool Function(Object)，无需强转。
    _client!.secure = true;
    final isLan = config.mode == BambuConnectionMode.lan;
    // LAN 模式只接受用户事先确认并绑定到序列号+主机的证书指纹。
    // Cloud 模式：严格校验系统 CA，不绕过。
    _client!.onBadCertificate =
        isLan ? _verifyLanCertificate : (Object cert) => false;

    // MQTT 协议设置
    _client!.logging(on: false);
    _client!.keepAlivePeriod = 30;
    _client!.connectTimeoutPeriod = 5000;
    // P1-2: 禁用 mqtt_client 内置 autoReconnect，改用自定义指数退避重连
    // 原因：内置 autoReconnect 无退避策略（固定延迟）、无最大重试次数、无法精细控制状态
    _client!.autoReconnect = false;

    // 认证
    _client!.connectionMessage = MqttConnectMessage()
        .authenticateAs(username, password)
        .withClientIdentifier(mqttClientId)
        .startClean();

    // 状态回调
    _client!.onConnected = _onConnected;
    _client!.onDisconnected = _onDisconnected;
    _client!.onSubscribed = _onSubscribed;

    // P1-2: 新客户端未订阅，重置标志（重连时创建新客户端，旧订阅不保留）
    _subscribed = false;
  }

  Future<void> _loadLanCertificateVerifier() async {
    if (config.mode != BambuConnectionMode.lan) return;
    _lanCertificateVerifier = await PrinterCertificateTrustStore.loadVerifier(
      serial: config.serial,
      host: config.host,
      service: PrinterTlsService.mqtt,
    );
  }

  /// [cert] 参数类型为 Object（mqtt_client 内部强转要求）。未确认的首次
  /// 证书和发生变化的证书都会失败关闭。
  bool _verifyLanCertificate(Object cert) {
    return _lanCertificateVerifier?.verifyCertificate(cert) ?? false;
  }

  void _onConnected() {
    // 竞态保护：await connect() 期间用户可能调用 disconnect() 关闭 controller
    if (_connectionStateController.isClosed || _statusController.isClosed) {
      return;
    }
    _isConnected = true;
    _feedTelemetry.clear();
    _lastStatus = null;
    // P1-2: 重连成功时重置计数器
    _reconnectAttempts = 0;
    _connectionStateController.add(PrinterConnectionState.connected);
    // P1-2: 每次连接（含重连）都需订阅，因为 _setupClient 创建了新客户端
    // P1 修复：subscribe 可能抛异常（QoS 不支持/topic 非法），包 try-catch
    // 失败时回退到 error 状态，避免 _isConnected=true 但无订阅的"假连接"
    if (!_subscribed) {
      try {
        final topic = 'device/${config.serial}/report';
        _client!.subscribe(topic, MqttQos.atMostOnce);
        // 监听消息（保存 subscription，disconnect 时显式取消）
        _updatesSub?.cancel();
        _updatesSub = _client!.updates!.listen(_onMessage);
        _subscribed = true;
      } catch (e, st) {
        _handleError('订阅 topic 失败: $e', st, context: {'phase': 'subscribe'});
        _isConnected = false;
        try {
          _client?.disconnect();
        } catch (_) {}
        _client = null;
        _connectionStateController.add(PrinterConnectionState.error);
        return;
      }
    }
    // 主动请求一次 pushall（打印状态）
    requestStatus();
    // 主动请求固件版本信息（pushall 不一定包含 info.module 节点）
    _requestVersion();
  }

  /// 请求固件版本信息。
  /// 发送 get_version 命令，打印机返回 info.module 节点含 sw_ver/hw_ver/ota_new_ver。
  void _requestVersion() {
    _sendRequest({
      'info': {
        'sequence_id': _nextSeq(),
        'command': 'get_version',
      },
    });
  }

  void _onDisconnected() {
    // 竞态保护：disconnect() 可能已关闭 controller，此时不应再写入
    if (_connectionStateController.isClosed || _statusController.isClosed) {
      return;
    }
    // M3 修复：防止重复触发断连事件
    // P0 修复：将 _isConnected = false 提前到检查之前，确保原子性
    // mqtt_client 网络抖动时可能快速连续触发 onDisconnected，
    // 多个回调并发执行时若先检查后赋值会全部通过，导致重连风暴
    if (!_isConnected) return;
    _isConnected = false;
    // C4 修复：dispose 后不再向已关闭的 controller 添加事件
    if (_connectionStateController.isClosed) return;
    // 通知 UI：连接已断开
    _connectionStateController.add(PrinterConnectionState.disconnected);
    // P1-2: 非主动断开时触发指数退避重连
    if (!_isExplicitDisconnect) {
      _scheduleReconnect();
    }
  }

  // ===== P1-2: 自定义指数退避重连 =====

  /// 调度下一次重连尝试（指数退避 + 抖动）。
  ///
  /// 退避策略：delay = min(baseDelay * 2^attempts, maxDelay) ± 25% 抖动
  /// - 第 1 次：~2s（±0.5s）
  /// - 第 2 次：~4s（±1s）
  /// - 第 3 次：~8s（±2s）
  /// - 第 4 次：~16s（±4s）
  /// - 第 5 次：~32s（±8s）
  /// - 第 6+ 次：~60s（±15s，已封顶）
  ///
  /// 抖动避免多台打印机同时重连造成服务端压力（thundering herd 问题）。
  void _scheduleReconnect() {
    if (_isExplicitDisconnect) return;
    if (_connectionStateController.isClosed) return;

    // 达到最大重试次数，转为 error 状态
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _handleError(
        'MQTT 重连失败：已达最大重试次数 ($_maxReconnectAttempts 次)',
        null,
        level: ErrorLevel.error,
        context: {
          'phase': 'reconnect_exhausted',
          'attempts': _reconnectAttempts,
        },
      );
      _connectionStateController.add(PrinterConnectionState.error);
      return;
    }

    // 指数退避：delay = base * 2^attempts
    final exponentialMs =
        _baseReconnectDelay.inMilliseconds * (1 << _reconnectAttempts);
    final clampedMs = exponentialMs > _maxReconnectDelay.inMilliseconds
        ? _maxReconnectDelay.inMilliseconds
        : exponentialMs;
    // ±25% 抖动
    final jitterRange = (clampedMs * 0.25).round();
    final jitter = _random.nextInt(jitterRange * 2 + 1) - jitterRange;
    final delayMs = clampedMs + jitter;
    final delay = Duration(milliseconds: delayMs);

    _reconnectAttempts++;

    ErrorLogger.log(
      'MQTT 重连中（第 $_reconnectAttempts/$_maxReconnectAttempts 次，'
      '延迟 ${(delayMs / 1000).toStringAsFixed(1)}s）',
      null,
      source: 'mqtt',
      level: ErrorLevel.info,
      context: {
        'serial': config.serial,
        'attempt': _reconnectAttempts,
        'delay_ms': delayMs,
      },
    );

    _connectionStateController.add(PrinterConnectionState.reconnecting);

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _attemptReconnect);
  }

  /// 执行重连尝试。
  ///
  /// 重新解析连接参数（Cloud 模式 token 可能已过期需要重新登录），
  /// 创建新客户端并尝试连接。失败时调度下一次重连。
  Future<void> _attemptReconnect() async {
    if (_isConnected) return;
    if (_isExplicitDisconnect) return;
    if (_connectionStateController.isClosed) return;

    // 重新解析连接参数（token 可能已过期）
    late final String host;
    late final String username;
    late final String password;
    try {
      final params = await _resolveConnectionParams();
      host = params.host;
      username = params.username;
      password = params.password;
      await _loadLanCertificateVerifier();
    } catch (e, st) {
      _handleError(
        '重连参数解析失败（第 $_reconnectAttempts 次）: $e',
        st,
        level: ErrorLevel.warning,
        context: {
          'phase': 'reconnect_resolve_params',
          'attempt': _reconnectAttempts,
        },
      );
      // 继续调度下一次重连
      _scheduleReconnect();
      return;
    }

    // 创建新客户端（避免旧客户端残留状态）
    // P0 修复：disconnect() 内部会触发 _onDisconnected 回调，可能误调度重连
    // 临时标记为主动断开，避免回调中的重连逻辑干扰当前重连流程
    final wasExplicit = _isExplicitDisconnect;
    _isExplicitDisconnect = true;
    try {
      _client?.disconnect();
    } catch (_) {}
    _isExplicitDisconnect = wasExplicit;
    _setupClient(host, username, password);

    try {
      await _client!.connect();
      // 成功时 _onConnected 会被 mqtt_client 回调，重置计数器
    } catch (e, st) {
      _handleError(
        '重连失败（第 $_reconnectAttempts 次）: $e',
        st,
        level: ErrorLevel.warning,
        context: {
          'phase': 'reconnect_attempt',
          'attempt': _reconnectAttempts,
        },
      );
      // 调度下一次重连
      _scheduleReconnect();
    }
  }

  /// P1-2: 统一错误处理（ErrorLogger + errorStream）。
  ///
  /// 所有错误同时推送到两个通道：
  /// 1. [_errorController]：UI 层通过 [errorStream] 实时显示错误信息
  /// 2. [ErrorLogger.log]：持久化到数据库，供诊断中心查询和导出
  void _handleError(
    String message,
    StackTrace? st, {
    ErrorLevel level = ErrorLevel.error,
    Map<String, dynamic>? context,
  }) {
    _errorController.add(message);
    ErrorLogger.log(
      message,
      st,
      source: 'mqtt',
      level: level,
      context: {
        'serial': config.serial,
        'mode': config.mode.name,
        ...?context,
      },
    );
  }

  void _onSubscribed(String topic) {
    // 订阅成功
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final msg in messages) {
      if (msg.payload is! MqttPublishMessage) continue;
      final pubMsg = msg.payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(
        pubMsg.payload.message,
      );
      _handleMessage(payload);
    }
  }

  void _handleMessage(String payload) {
    // 竞态保护：disconnect() 可能已关闭 controller，此时不应再写入
    if (_connectionStateController.isClosed || _statusController.isClosed) {
      return;
    }
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final status = BambuPrinterStatus.fromMqttJson(
        _feedTelemetry.merge(json),
        serial: config.serial,
      );
      if (status != null) {
        // M5 修复：消息去重，关键字段完全相同则跳过广播
        // 固件升级进度也纳入比较，避免升级中的进度推送被误去重丢弃
        // P1 修复：增加 trayNow/gcodeFile/subtaskName/amsStatus/totalLayers 比较
        // 否则换料时 trayNow 变化但其他字段未变，消息被去重丢弃，换料事件丢失
        //
        // Phase B 修复（任务书 3.5）：去重比较必须包含 failReason、printError、
        // HMS 内容、AMS trays 的插拔/RFID/remain、AMS 湿度/温度/烘干状态。
        // 只改变这些字段的消息也必须向下游发布，否则故障和数字孪生收不到更新。
        if (_lastStatus != null &&
            status.gcodeState == _lastStatus!.gcodeState &&
            status.mcPercent == _lastStatus!.mcPercent &&
            status.currLayer == _lastStatus!.currLayer &&
            status.nozzleTemper == _lastStatus!.nozzleTemper &&
            status.bedTemper == _lastStatus!.bedTemper &&
            status.spdMag == _lastStatus!.spdMag &&
            status.spdLvl == _lastStatus!.spdLvl &&
            status.upgradeStatus == _lastStatus!.upgradeStatus &&
            status.upgradeProgress == _lastStatus!.upgradeProgress &&
            status.trayNow == _lastStatus!.trayNow &&
            status.gcodeFile == _lastStatus!.gcodeFile &&
            status.subtaskName == _lastStatus!.subtaskName &&
            status.amsStatus == _lastStatus!.amsStatus &&
            status.mcPrintStage == _lastStatus!.mcPrintStage &&
            status.hwSwitchState == _lastStatus!.hwSwitchState &&
            listEquals(
              status.extruderFilamentPresent,
              _lastStatus!.extruderFilamentPresent,
            ) &&
            _amsTraysEqual(status.externalTrays, _lastStatus!.externalTrays) &&
            status.totalLayers == _lastStatus!.totalLayers &&
            // Phase B 新增：故障相关字段
            status.failReason == _lastStatus!.failReason &&
            status.printError == _lastStatus!.printError &&
            _hmsAlertsEqual(status.hmsAlerts, _lastStatus!.hmsAlerts) &&
            // Phase B 新增：AMS 环境数据
            status.amsHumidity == _lastStatus!.amsHumidity &&
            status.amsTemp == _lastStatus!.amsTemp &&
            status.amsDrying == _lastStatus!.amsDrying &&
            _amsModuleTypesEqual(
              status.amsModuleTypes,
              _lastStatus!.amsModuleTypes,
            ) &&
            // AMS 单元类型/插拔变化必须向工作台广播。
            _amsUnitsEqual(status.amsUnits, _lastStatus!.amsUnits) &&
            // Phase B 新增：AMS trays（含 RFID/remain/插拔变化）
            _amsTraysEqual(status.amsTrays, _lastStatus!.amsTrays)) {
          return;
        }
        // 增量更新：pushing 消息可能只含部分字段，merge 到 lastStatus
        if (_lastStatus != null) {
          // N3 修复：状态转为 idle/finish 时，重置进度相关字段防止残留过期数据
          final prevState = _lastStatus!.gcodeState;
          final newState = status.gcodeState ?? prevState;
          final isResetting = (newState == BambuGcodeState.idle ||
                  newState == BambuGcodeState.finish ||
                  newState == BambuGcodeState.unknown) &&
              prevState != BambuGcodeState.idle &&
              prevState != BambuGcodeState.finish &&
              prevState != BambuGcodeState.unknown;

          // Phase B 修复：明确清除语义。
          // MQTT 显式给出空值（如 failReason="" / hms=[] / print_error=0）时，
          // 用 clearXxx 标志清除旧值；字段缺失（null）时保留旧值。
          // fromMqttJson 已保证：字段缺失返回 null，明确空值返回 "" / [] / 等。
          final bool clearFailReason =
              status.failReason != null && status.failReason!.isEmpty;
          final bool clearPrintError =
              status.printError != null && status.printError!.isEmpty;
          final bool clearHmsAlerts =
              status.hmsAlerts != null && status.hmsAlerts!.isEmpty;
          final bool clearGcodeFile =
              isResetting || (status.gcodeFile == '' ? true : false);
          final bool clearSubtaskName =
              isResetting || (status.subtaskName == '' ? true : false);
          final bool clearTaskId = isResetting;
          final bool clearSubtaskId = isResetting;

          _lastStatus = _lastStatus!.copyWith(
            gcodeState: status.gcodeState,
            mcPercent: isResetting ? 0 : status.mcPercent,
            mcRemainingTime: isResetting ? 0 : status.mcRemainingTime,
            currLayer: isResetting ? 0 : status.currLayer,
            totalLayers: isResetting ? 0 : status.totalLayers,
            trayNow: status.trayNow,
            nozzleTemper: status.nozzleTemper,
            nozzleTargetTemper: status.nozzleTargetTemper,
            bedTemper: status.bedTemper,
            bedTargetTemper: status.bedTargetTemper,
            fanGear: status.fanGear,
            spdMag: status.spdMag,
            spdLvl: status.spdLvl,
            amsStatus: status.amsStatus,
            mcPrintStage: status.mcPrintStage,
            hwSwitchState: status.hwSwitchState,
            extruderFilamentPresent: status.extruderFilamentPresent,
            externalTrays: status.externalTrays,
            gcodeFile: status.gcodeFile,
            subtaskName: status.subtaskName,
            failReason: status.failReason,
            printError: status.printError,
            hmsAlerts: status.hmsAlerts,
            amsTrays: status.amsTrays,
            amsUnits: status.amsUnits,
            amsModuleTypes: status.amsModuleTypes,
            printType: status.printType,
            taskId: status.taskId,
            subtaskId: status.subtaskId,
            // 固件版本 & 升级状态（缺失时保留旧值，pushall/upgrade_ams 推送时更新）
            fwVersion: status.fwVersion,
            hwVersion: status.hwVersion,
            otaNewVersion: status.otaNewVersion,
            moduleName: status.moduleName,
            otaModule: status.otaModule,
            upgradeStatus: status.upgradeStatus,
            upgradeProgress: status.upgradeProgress,
            upgradeMessage: status.upgradeMessage,
            // P2 修复：AMS 环境数据（湿度/温度/干燥状态）增量推送也需 merge
            amsHumidity: status.amsHumidity,
            amsTemp: status.amsTemp,
            amsDrying: status.amsDrying,
            // Phase B：显式清除标志
            clearFailReason: clearFailReason,
            clearPrintError: clearPrintError,
            clearHmsAlerts: clearHmsAlerts,
            clearGcodeFile: clearGcodeFile,
            clearSubtaskName: clearSubtaskName,
            clearTaskId: clearTaskId,
            clearSubtaskId: clearSubtaskId,
          );
        } else {
          _lastStatus = status;
        }
        _statusController.add(_lastStatus!);
      }
    } catch (e, st) {
      _handleError('解析消息失败: $e', st, context: {'phase': 'parse_message'});
    }
  }

  /// Phase B：比较两份 HMS 故障列表是否等价（按 code+severity 顺序比较）。
  /// null 与 null 视为等价；null 与非 null 不等价（视为变化）。
  static bool _hmsAlertsEqual(
    List<PrinterHmsAlert>? a,
    List<PrinterHmsAlert>? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].code != b[i].code || a[i].severity != b[i].severity) {
        return false;
      }
    }
    return true;
  }

  /// Phase B：比较两份 AMS trays 列表是否等价。
  /// 检查槽位插拔、RFID UUID、remain、trayInfoIdx、trayColor 等关键字段。
  /// null 与 null 视为等价；null 与非 null 不等价。
  static bool _amsTraysEqual(List<AmsTray>? a, List<AmsTray>? b) {
    if (identical(a, b)) return true;
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final ta = a[i];
      final tb = b[i];
      if (ta.amsId != tb.amsId ||
          ta.slot != tb.slot ||
          ta.hasFilament != tb.hasFilament ||
          ta.hasFilamentObservation != tb.hasFilamentObservation ||
          ta.mixedAmsLite != tb.mixedAmsLite ||
          ta.tagUid != tb.tagUid ||
          ta.remain != tb.remain ||
          ta.trayUuid != tb.trayUuid ||
          ta.trayInfoIdx != tb.trayInfoIdx ||
          ta.trayColor != tb.trayColor ||
          ta.traySubBrands != tb.traySubBrands ||
          ta.trayWeight != tb.trayWeight ||
          ta.trayTag != tb.trayTag) {
        return false;
      }
    }
    return true;
  }

  static bool _amsUnitsEqual(List<AmsUnit>? a, List<AmsUnit>? b) {
    if (identical(a, b)) return true;
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final ua = a[i];
      final ub = b[i];
      if (ua.id != ub.id ||
          ua.type != ub.type ||
          ua.rawTypeCode != ub.rawTypeCode ||
          ua.rawInfo != ub.rawInfo ||
          ua.extruderId != ub.extruderId ||
          ua.isPresent != ub.isPresent) {
        return false;
      }
    }
    return true;
  }

  static bool _amsModuleTypesEqual(
    Map<int, AmsUnitType>? a,
    Map<int, AmsUnitType>? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null && b == null) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  Future<void> disconnect() async {
    // P1-2: 标记主动断开，取消重连定时器
    _isExplicitDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    await _updatesSub?.cancel();
    _updatesSub = null;
    _client?.disconnect();
    _client = null;
    _isConnected = false;
    _subscribed = false;
    _connectionStateController.add(PrinterConnectionState.disconnected);
  }

  @override
  Future<void> requestStatus() async {
    _sendRequest({
      'pushing': {'sequence_id': _nextSeq(), 'command': 'pushall'},
    });
  }

  @override
  Future<bool> pause() async {
    return _sendPrintCommand('pause');
  }

  @override
  Future<bool> resume() async {
    return _sendPrintCommand('resume');
  }

  @override
  Future<bool> stop() async {
    return _sendPrintCommand('stop');
  }

  @override
  Future<bool> setSpeed(int profileLevel) async {
    if (!BambuSpeedProfile.isValidLevel(profileLevel)) {
      _handleError(
        '无效的打印速度档位：$profileLevel',
        null,
        level: ErrorLevel.warning,
        context: {'phase': 'set_speed'},
      );
      return false;
    }
    return _sendRequest(
      buildPrintSpeedPayload(
        profileLevel: profileLevel,
        sequenceId: _nextSeq(),
      ),
    );
  }

  @override
  Future<bool> sendPrintTask(String filePath,
      {List<int>? amsMapping, int plateIndex = 1}) async {
    // 完整打印任务下发流程（FTP 上传 + MQTT project_file 指令）。
    //
    // **协议来源**：逆向 ha-bambulab / pybambu 项目。
    //
    // **流程**：
    // 1. 仅 LAN 模式支持（Cloud 模式打印机 FTP 不暴露公网）
    // 2. FTPS 上传 .3mf 到打印机 SD 卡（用户名 bblp，密码 accessCode，端口 990）
    // 3. MQTT 发 project_file 指令：
    //    - url：FTP 上传后的路径（老款 file:///sdcard/X.3mf，新款 ftp:///X.3mf）
    //    - param：3MF 内 G-code 路径（如 "Metadata/plate_1.gcode"）
    //
    // **URL 格式**（来源：ha-bambulab const.py LEGACY_SDCARD_PRINTERS）：
    // - 老款（X1/X1C/X1E/P1P/P1S/A1/A1MINI）：file:///sdcard/X.3mf
    // - 新款（A2L/P2S/H2C/H2D/H2DPRO/H2S/X2D）：ftp:///X.3mf

    // Cloud 模式不支持 FTP 上传
    if (config.mode == BambuConnectionMode.cloud) {
      _handleError(
        '云模式不支持直接下发打印任务，请切换到 LAN 模式',
        null,
        level: ErrorLevel.warning,
        context: {'phase': 'send_print_task'},
      );
      return false;
    }

    // LAN 模式必须有 IP 和 accessCode
    if (config.host.isEmpty || config.accessCode.isEmpty) {
      _handleError(
        'LAN 配置不完整：缺少 IP 或 Access Code',
        null,
        level: ErrorLevel.warning,
        context: {'phase': 'send_print_task'},
      );
      return false;
    }

    try {
      final gcodeParam = filePath.toLowerCase().endsWith('.3mf')
          ? await BambuGcodePathResolver.resolveFrom3mf(filePath,
              plateIndex: plateIndex)
          : '';
      final resolvedPlateIndex = int.tryParse(
              RegExp(r'plate_(\d+)\.gcode').firstMatch(gcodeParam)?.group(1) ??
                  '') ??
          plateIndex;
      final slice = await SliceIsolateRunner.parseAuto(filePath,
          plateIndex: resolvedPlateIndex);
      final activeTools = slice?.filaments
              .where((item) => item.grams > .01)
              .map((item) => item.toolIndex)
              .toList() ??
          <int>[];
      final resolvedMapping = amsMapping ?? slice?.amsMapping ?? const <int>[];
      final toolExtruders = await readBambuToolExtruders(filePath,
          plateIndex: resolvedPlateIndex);
      final mappingError = validateBambuPrintFeed(
          model: config.devProductName ?? '',
          mapping: resolvedMapping,
          activeTools: activeTools,
          status: _lastStatus,
          toolExtruders: toolExtruders);
      if (mappingError != null) {
        _handleError(mappingError, null,
            level: ErrorLevel.warning,
            context: {'phase': 'validate_print_feed'});
        return false;
      }
      final feedPayload =
          buildBambuPrintFeedPayload(resolvedMapping, activeTools: activeTools);
      // 1. FTP 上传 3MF 文件
      final modelName = config.devProductName ?? '';
      final ftpUrl = await BambuFtpUploader.uploadFile(
        serial: config.serial,
        host: config.host,
        accessCode: config.accessCode,
        filePath: filePath,
        modelName: modelName,
      );

      // 3. MQTT 发送 project_file 指令。HT、Lite、外挂与空闲工具编号
      // 统一在 buildBambuPrintFeedPayload 转换，不复用传感器位序。
      return _sendRequest({
        'print': {
          'sequence_id': _nextSeq(),
          'command': 'project_file',
          'param': gcodeParam,
          'url': ftpUrl,
          'bed_type': 'auto',
          'timelapse': false,
          'bed_leveling': true,
          'flow_cali': true,
          'vibration_cali': true,
          'layer_inspect': true,
          ...feedPayload,
          'subtask_name': '',
          'profile_id': '0',
          'project_id': '0',
          'subtask_id': '0',
          'task_id': '0',
        },
      });
    } on BambuFtpException catch (e, st) {
      _handleError(
        'FTP 上传失败：${e.message}',
        st,
        context: {'phase': 'ftp_upload', 'filePath': filePath},
      );
      return false;
    } catch (e, st) {
      _handleError(
        '发送打印任务失败: $e',
        st,
        context: {'phase': 'send_print_task', 'filePath': filePath},
      );
      return false;
    }
  }

  Future<bool> _sendPrintCommand(String command) async {
    return _sendRequest({
      'print': {
        'sequence_id': _nextSeq(),
        'command': command,
      },
    });
  }

  /// 发送固件升级指令（OTA 升级打印机主固件）。
  /// 升级期间打印机会推送 upgrade_ams 节点的进度信息。
  Future<bool> sendFirmwareUpgrade() async {
    return _sendRequest({
      'info': {
        'sequence_id': _nextSeq(),
        'command': 'upgrade_command',
      },
    });
  }

  /// 发送 AMS 固件升级指令。
  /// [amsId] AMS 编号（0/1/2/3）。
  Future<bool> sendAmsFirmwareUpgrade(int amsId) async {
    return _sendRequest({
      'upgrade_ams': {
        'sequence_id': _nextSeq(),
        'command': 'upgrade_command',
        'ams_id': amsId,
      },
    });
  }

  Future<bool> _sendRequest(Map<String, dynamic> payload) async {
    if (!_isConnected || _client == null) {
      _handleError(
        '未连接打印机',
        null,
        level: ErrorLevel.warning,
        context: {'phase': 'send_request'},
      );
      return false;
    }
    try {
      final builder = MqttClientPayloadBuilder();
      builder.addString(jsonEncode(payload));
      final topic = 'device/${config.serial}/request';
      // 控制指令用 atLeastOnce（QoS 1）保证送达，状态订阅用 atMostOnce（QoS 0）
      _client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
      return true;
    } catch (e, st) {
      _handleError('发送指令失败: $e', st, context: {'phase': 'send_request'});
      return false;
    }
  }

  String _nextSeq() {
    _sequenceId++;
    return '$_sequenceId';
  }

  @override
  Future<void> dispose() async {
    // P1-2: 确保重连定时器被取消
    _isExplicitDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await disconnect();
    _statusController.close();
    _errorController.close();
    _connectionStateController.close();
  }
}
