/// 拓竹打印机 bind 流量嗅探器（跨设备绑定研究专用工具）。
///
/// **背景**：
/// 拓竹官方 bind（绑定打印机到账号）需要"双通道握手"：
/// - 云端 ticket（向 api.bambulab.cn 请求）
/// - LAN 端口 3000 握手（获取 sec_link）
/// - 打印机物理按键确认（用户按"绑定"按钮）
///
/// 没有任何开源项目成功逆向 bind 流程，全部封在闭源
/// `bambu_network_agent.dll` 中。本工具的目的是在用户**正常执行 PIN 码绑定**
/// 时，监听 LAN MQTT 的所有流量，抓取打印机固件在用户按下"绑定"按钮
/// 那一刻自己发布的 confirm 消息格式。
///
/// **使用场景**：
/// 1. 用户在打印机屏幕进入"设置 > 账号 > PIN 码绑定"，记下 PIN 码
/// 2. 启动本嗅探器（输入打印机 IP + access_code + 序列号）
/// 3. 在 Bambu Studio 里执行 PIN 码绑定流程
/// 4. **关键时刻**：在打印机屏幕上按下"绑定"按钮
/// 5. 嗅探器会捕获所有 MQTT 消息，并高亮包含 bind/ticket/pin/sec_link
///    等关键字的消息
/// 6. 导出消息日志，分析 confirm 消息格式
///
/// **协议覆盖**：
/// - 订阅通配符主题 `device/{serial}/#`（监听所有主题，不只 `report`）
/// - 同时支持 LAN 模式（直连打印机 8883）和 Cloud 模式（连云端 MQTT）
/// - LAN 模式能抓到打印机本地产生的消息
/// - Cloud 模式能抓到打印机向云端推送的消息
/// - 推荐两种模式同时启动（如果条件允许），对比消息差异
///
/// **过滤策略**：
/// - 心跳消息（空 payload 或仅 `{}`）标记为 heartbeat 但保留
/// - 包含关键字的消息标记为 `BindKeywordHit` 并高亮
/// - 所有消息都记录原始 JSON + 时间戳 + 主题
///
/// **数据导出**：
/// - JSONL 格式（每行一条消息）
/// - 字段：timestamp, topic, payload_raw, payload_json, keywords_hit, mode
/// - 导出路径由调用方指定
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// 嗅探模式。
enum BindSniffMode {
  /// LAN 直连打印机内置 MQTT broker（端口 8883 TLS）
  /// 用户名 bblp，密码是 LAN Access Code
  /// 能抓到打印机本地产生的所有消息
  lan,

  /// 云端 MQTT（cn.mqtt.bambulab.com / us.mqtt.bambulab.com）
  /// 用户名 u_xxx，密码是 accessToken
  /// 能抓到打印机向云端推送的消息
  cloud,
}

/// 单条嗅探到的 MQTT 消息。
class BindTrafficEvent {
  /// 接收到消息的时间戳（本地时间）
  final DateTime timestamp;

  /// MQTT 主题（如 `device/00M00A123456789/report`）
  final String topic;

  /// 原始 payload 字符串（UTF-8 解码后）
  final String payloadRaw;

  /// 解析后的 JSON（解析失败为 null）
  final Map<String, dynamic>? payloadJson;

  /// 嗅探模式（LAN / Cloud）
  final BindSniffMode mode;

  /// 命中的关键字列表（用于 UI 高亮）
  /// 可能的值：bind, ticket, pin, sec_link, link, user_id, confirm, approve
  final List<String> keywordsHit;

  /// 是否是心跳消息（payload 为空或仅 `{}`）
  final bool isHeartbeat;

  /// 是否可能是 bind 相关消息（命中任意关键字且非心跳）
  bool get isLikelyBindRelated => !isHeartbeat && keywordsHit.isNotEmpty;

  BindTrafficEvent({
    required this.timestamp,
    required this.topic,
    required this.payloadRaw,
    required this.payloadJson,
    required this.mode,
    required this.keywordsHit,
    required this.isHeartbeat,
  });

  /// 转为 JSONL 行（一行一个 JSON 对象，便于日志分析）
  String toJsonlLine() {
    return jsonEncode({
      'timestamp': timestamp.toIso8601String(),
      'topic': topic,
      'payload_raw': payloadRaw,
      'payload_json': payloadJson,
      'mode': mode.name,
      'keywords_hit': keywordsHit,
      'is_heartbeat': isHeartbeat,
      'is_likely_bind_related': isLikelyBindRelated,
    });
  }

  @override
  String toString() {
    final kw = keywordsHit.isEmpty ? '' : ' [${keywordsHit.join(',')}]';
    return '[${timestamp.toIso8601String()}] $topic$kw: '
        '${payloadRaw.length > 200 ? '${payloadRaw.substring(0, 200)}...' : payloadRaw}';
  }
}

/// 嗅探器状态。
enum BindSnifferState {
  /// 已停止
  idle,

  /// 连接中
  connecting,

  /// 已连接，正在监听
  listening,

  /// 发生错误
  error,

  /// 已停止（用户主动停止）
  stopped,
}

/// bind 流量嗅探器。
///
/// 使用示例：
/// ```dart
/// final sniffer = BambuBindTrafficSniffer(
///   mode: BindSniffMode.lan,
///   host: '192.168.1.100',
///   port: 8883,
///   username: 'bblp',
///   password: '<access_code>',
///   serial: '00M00A123456789',
/// );
/// sniffer.eventStream.listen((event) {
///   print(event);
///   if (event.isLikelyBindRelated) {
///     // 高亮显示，可能是 bind confirm 消息
///   }
/// });
/// await sniffer.start();
/// // ... 用户在打印机上执行绑定操作 ...
/// await sniffer.stop();
/// await sniffer.exportToFile('C:/bind_capture.jsonl');
/// ```
class BambuBindTrafficSniffer {
  /// 嗅探模式
  final BindSniffMode mode;

  /// MQTT host（LAN 模式为打印机 IP，Cloud 模式为 cn.mqtt.bambulab.com）
  final String host;

  /// MQTT 端口（LAN 8883，Cloud 8883）
  final int port;

  /// 用户名（LAN=bblp，Cloud=u_xxx）
  final String username;

  /// 密码（LAN=access_code，Cloud=accessToken）
  final String password;

  /// 打印机序列号（用于构造订阅主题）
  final String serial;

  BambuBindTrafficSniffer({
    required this.mode,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.serial,
  });

  MqttServerClient? _client;
  StreamController<BindTrafficEvent>? _eventController;
  StreamController<BindSnifferState>? _stateController;
  StreamController<String>? _errorController;
  StreamSubscription? _updatesSub;

  /// 是否已启动
  bool get isRunning => _client != null;

  /// 消息事件流（UI 订阅这个流实时显示消息）
  Stream<BindTrafficEvent> get eventStream =>
      _eventController?.stream ?? const Stream.empty();

  /// 状态变化流
  Stream<BindSnifferState> get stateStream =>
      _stateController?.stream ?? const Stream.empty();

  /// 错误流
  Stream<String> get errorStream =>
      _errorController?.stream ?? const Stream.empty();

  /// 所有已捕获的消息（用于导出）
  final List<BindTrafficEvent> _capturedEvents = [];

  List<BindTrafficEvent> get capturedEvents =>
      List.unmodifiable(_capturedEvents);

  /// bind 相关关键字列表（命中任意一个就高亮）
  ///
  /// 这些关键字基于 Bambu Studio 源码和拓竹错误码推测：
  /// - `bind` / `unbind`：绑定/解绑命令
  /// - `ticket`：云端绑定 ticket
  /// - `pin`：PIN 码
  /// - `sec_link` / `seclink`：安全链接令牌（打印机本地生成）
  /// - `link`：通用链接令牌（可能误命中，但宁错不漏）
  /// - `user_id` / `userid`：用户 ID
  /// - `confirm` / `approve`：确认消息（最关键！）
  /// - `login_report`：登录报告（错误码 -1090 等待的就是这个）
  /// - `device_bind` / `devicebind`：设备绑定
  static const List<String> bindKeywords = [
    'bind',
    'unbind',
    'ticket',
    'pin',
    'sec_link',
    'seclink',
    'user_id',
    'userid',
    'confirm',
    'approve',
    'login_report',
    'loginreport',
    'device_bind',
    'devicebind',
  ];

  /// 启动嗅探。
  ///
  /// 1. 创建 MQTT 客户端
  /// 2. 连接（TLS，跳过证书校验，因为拓竹用自签证书）
  /// 3. 订阅 `device/{serial}/#` 通配符主题（监听所有子主题）
  /// 4. 同时订阅 `$SYS/#`（部分 MQTT broker 会在这里发布内部事件）
  Future<bool> start() async {
    if (isRunning) {
      _emitError('嗅探器已在运行');
      return false;
    }

    _eventController = StreamController<BindTrafficEvent>.broadcast();
    _stateController = StreamController<BindSnifferState>.broadcast();
    _errorController = StreamController<String>.broadcast();
    _capturedEvents.clear();

    _emitState(BindSnifferState.connecting);

    final clientId =
        'bind_sniffer_${serial}_${DateTime.now().millisecondsSinceEpoch}';
    _client = MqttServerClient.withPort(host, clientId, port);

    // 云端必须使用系统 CA 严格校验，避免 accessToken 被中间人窃取。
    // LAN 诊断模式仍需兼容打印机自签证书。
    _client!.secure = true;
    final isCloudHost = host.toLowerCase().endsWith('.bambulab.com');
    _client!.onBadCertificate = (Object cert) => !isCloudHost;

    // MQTT 协议设置
    _client!.logging(on: false);
    _client!.keepAlivePeriod = 30;
    _client!.connectTimeoutPeriod = 5000;
    _client!.autoReconnect = false; // 嗅探器不自动重连，断了就停

    // 认证
    _client!.connectionMessage = MqttConnectMessage()
        .authenticateAs(username, password)
        .withClientIdentifier(clientId)
        .startClean();

    try {
      await _client!.connect();
    } catch (e) {
      _emitError('MQTT 连接失败: $e');
      _emitState(BindSnifferState.error);
      _cleanup();
      return false;
    }

    // 订阅通配符主题：监听所有 device/{serial}/# 子主题
    // 这是嗅探器与普通 connector 的关键差异：connector 只订阅 report，
    // 嗅探器订阅所有子主题，包括 request（命令下发）、event（事件）等
    final wildcardTopic = 'device/$serial/#';
    try {
      _client!.subscribe(wildcardTopic, MqttQos.atMostOnce);
    } catch (e) {
      _emitError('订阅主题失败 ($wildcardTopic): $e');
    }

    // 尝试订阅 SYS 主题（部分 broker 在这里发布客户端连接/断开事件）
    // 拓竹打印机可能不支持，订阅失败不影响主流程
    try {
      _client!.subscribe(r'$SYS/#', MqttQos.atMostOnce);
    } catch (_) {
      // 静默忽略，$SYS 可能被禁
    }

    // 监听消息
    _updatesSub = _client!.updates!.listen(_onMessage);

    _emitState(BindSnifferState.listening);

    // 记录启动事件（便于导出日志时知道起点）
    _captureEvent(
      topic: '_sniffer_started',
      payloadRaw: jsonEncode({
        'mode': mode.name,
        'host': host,
        'port': port,
        'serial': serial,
        'username': username,
        'started_at': DateTime.now().toIso8601String(),
      }),
      isHeartbeat: false,
    );

    return true;
  }

  /// 停止嗅探。
  Future<void> stop() async {
    if (!isRunning) return;
    _emitState(BindSnifferState.stopped);

    // 记录停止事件
    _captureEvent(
      topic: '_sniffer_stopped',
      payloadRaw: jsonEncode({
        'stopped_at': DateTime.now().toIso8601String(),
        'total_events': _capturedEvents.length,
      }),
      isHeartbeat: false,
    );

    await _updatesSub?.cancel();
    _updatesSub = null;
    _client?.disconnect();
    _client = null;
    _cleanup();
  }

  /// 处理收到的 MQTT 消息。
  ///
  /// mqtt_client 的 updates 流会推送 `List<MqttReceivedMessage<MqttMessage>>`，
  /// 每条消息含 topic 和 payload。
  void _onMessage(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final msg in messages) {
      final topic = msg.topic;
      final payload = msg.payload;

      // 解析 payload（MQTT 5 的 MqttPublishMessage 才有 payload）
      String payloadStr;
      if (payload is MqttPublishMessage) {
        final bytes = payload.payload.message;
        payloadStr = utf8.decode(bytes, allowMalformed: true);
      } else {
        // 兜底：尝试 toString
        payloadStr = payload.toString();
      }

      _processMessage(topic, payloadStr);
    }
  }

  /// 处理单条消息：解析 JSON + 命中关键字检测 + 推送事件。
  void _processMessage(String topic, String payloadStr) {
    Map<String, dynamic>? payloadJson;
    try {
      final parsed = jsonDecode(payloadStr);
      if (parsed is Map<String, dynamic>) {
        payloadJson = parsed;
      }
    } catch (_) {
      // 非 JSON payload，保留原始字符串
    }

    // 心跳检测：空 payload 或仅 `{}`
    final isHeartbeat = payloadStr.isEmpty ||
        payloadStr.trim() == '{}' ||
        payloadStr.trim() == 'null';

    // 关键字命中检测（在 topic + 原始 payload 中查找）
    final keywordsHit = <String>[];
    final haystack = '${topic.toLowerCase()}|${payloadStr.toLowerCase()}';
    for (final kw in bindKeywords) {
      if (haystack.contains(kw.toLowerCase())) {
        keywordsHit.add(kw);
      }
    }

    _captureEvent(
      topic: topic,
      payloadRaw: payloadStr,
      payloadJson: payloadJson,
      isHeartbeat: isHeartbeat,
      keywordsHit: keywordsHit,
    );
  }

  /// 捕获事件并推送到流。
  void _captureEvent({
    required String topic,
    required String payloadRaw,
    Map<String, dynamic>? payloadJson,
    required bool isHeartbeat,
    List<String>? keywordsHit,
  }) {
    final event = BindTrafficEvent(
      timestamp: DateTime.now(),
      topic: topic,
      payloadRaw: payloadRaw,
      payloadJson: payloadJson,
      mode: mode,
      keywordsHit: keywordsHit ?? const [],
      isHeartbeat: isHeartbeat,
    );
    _capturedEvents.add(event);
    _eventController?.add(event);
  }

  /// 导出所有捕获的消息到 JSONL 文件。
  ///
  /// 每行一个 JSON 对象，字段见 [BindTrafficEvent.toJsonlLine]。
  /// 返回写入的文件路径。
  Future<String> exportToFile(String path) async {
    final file = File(path);
    final sink = file.openWrite();
    try {
      for (final event in _capturedEvents) {
        sink.writeln(event.toJsonlLine());
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return path;
  }

  /// 释放资源（不发送 stopped 状态）。
  void _cleanup() {
    _updatesSub?.cancel();
    _updatesSub = null;
    _client = null;
  }

  void _emitState(BindSnifferState s) {
    if (!_stateController!.isClosed) {
      _stateController!.add(s);
    }
  }

  void _emitError(String msg) {
    if (!_errorController!.isClosed) {
      _errorController!.add(msg);
    }
  }

  /// 释放所有资源（销毁嗅探器时调用）。
  Future<void> dispose() async {
    await stop();
    await _eventController?.close();
    await _stateController?.close();
    await _errorController?.close();
    _eventController = null;
    _stateController = null;
    _errorController = null;
  }
}

/// 嗅探器工厂方法：从 PrinterConnectionConfig 创建 LAN 模式嗅探器。
///
/// 复用项目的 PrinterConnectionConfig（已含 IP/access_code/serial 等），
/// 避免重复输入。
// ignore: unused_element
BambuBindTrafficSniffer _createLanSniffer({
  required String printerIp,
  required String accessCode,
  required String serial,
  int port = 8883,
}) {
  return BambuBindTrafficSniffer(
    mode: BindSniffMode.lan,
    host: printerIp,
    port: port,
    username: 'bblp',
    password: accessCode,
    serial: serial,
  );
}
