import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:uuid/uuid.dart';

import '../../mobile/ams_tag_template.dart';
import 'desktop_serial_transport.dart';

class DesktopRfidException implements Exception {
  const DesktopRfidException(
    this.code,
    this.message, {
    this.mayHaveWritten = false,
  });
  final String code;
  final String message;
  final bool mayHaveWritten;
  @override
  String toString() => message;
}

class DesktopRfidScan {
  const DesktopRfidScan({required this.uid, required this.defaultKeyReadable});
  final String uid;
  final bool defaultKeyReadable;

  factory DesktopRfidScan.fromJson(Map<String, dynamic> value) {
    final uid = value['uid'];
    if (uid is! String ||
        !RegExp(r'^[0-9A-Fa-f]{8}$').hasMatch(uid) ||
        value['technology'] != 'mifare_classic' ||
        value['sizeBytes'] != 1024 ||
        value['blockCount'] != 64 ||
        value['uidLengthBytes'] != 4) {
      throw const DesktopRfidException(
        'unsupported_tag',
        '仅支持 4 字节 UID 的 MIFARE Classic 1K；不支持 NTAG 耗材标签',
      );
    }
    return DesktopRfidScan(
      uid: uid.toUpperCase(),
      defaultKeyReadable: value['defaultKeyReadable'] == true,
    );
  }
}

/// Fail-closed, bounded NDJSON protocol. No dumps/keys in logs or cloud records.
/// One request at a time; request UUIDs fence late results and USB reconnects.
class DesktopRfidBridge extends ChangeNotifier {
  DesktopRfidBridge({
    required this.transport,
    this.handshakeTimeout = const Duration(seconds: 8),
    this.operationTimeout = const Duration(seconds: 90),
    this.restoreTimeout = const Duration(minutes: 3),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _subscription = transport.bytes.listen(
      _receive,
      onError: (_) {
        unawaited(disconnect(reason: 'USB 连接中断，请重新连接并检查标签'));
      },
    );
  }

  final DesktopSerialTransport transport;
  final Duration handshakeTimeout;
  final Duration operationTimeout;
  final Duration restoreTimeout;
  final DateTime Function() _now;
  late final StreamSubscription<Uint8List> _subscription;
  final List<int> _buffer = [];
  Completer<Map<String, dynamic>>? _pending;
  String? _requestId;
  String? _command;
  String? _cancelId;
  Completer<void>? _cancelAck;
  bool _disposed = false;
  int _generation = 0;
  Timer? _heartbeat;
  DateTime? _lastHeartbeat;
  String? _heartbeatId;
  bool connected = false;
  bool connecting = false;
  bool readerReady = false;
  String? port;
  String? firmware;
  String? deviceId;
  String state = 'disconnected';
  int completed = 0;
  String? connectionMessage;
  Set<String> _capabilities = {};

  bool get busy => _pending != null || _cancelId != null || connecting;
  bool supports(String command) =>
      connected && readerReady && _capabilities.contains(command);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> connect(String selectedPort) async {
    if (busy || connected) throw const DesktopRfidException('busy', '请先结束当前连接');
    final generation = ++_generation;
    connecting = true;
    state = 'connecting';
    connectionMessage = null;
    _buffer.clear();
    _notify();
    try {
      await transport.open(selectedPort);
      if (generation != _generation) {
        throw const DesktopRfidException('cancelled', '连接已取消');
      }
      final hello = await _request('hello', timeout: handshakeTimeout);
      if (generation != _generation) {
        throw const DesktopRfidException('cancelled', '连接已取消');
      }
      if (hello['device'] != 'sohun-rfid-bridge' ||
          hello['protocol'] != 1 ||
          hello['capabilities'] is! List ||
          hello['firmware'] is! String ||
          hello['deviceId'] is! String) {
        throw const DesktopRfidException(
          'protocol_mismatch',
          '设备不是兼容的 Sohun RFID 固件，请先烧录配套固件',
        );
      }
      connected = true;
      port = selectedPort;
      firmware = hello['firmware'] as String;
      deviceId = hello['deviceId'] as String;
      _capabilities = (hello['capabilities'] as List)
          .whereType<String>()
          .toSet();
      readerReady = hello['readerReady'] == true;
      state = readerReady ? 'ready' : 'reader_missing';
      connectionMessage = readerReady
          ? null
          : 'ESP32 已连接，但 RC522 未就绪。请断电检查 3.3V 和 SPI 接线后重连';
      _lastHeartbeat = _now();
      _heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!connected) return;
        if (_now().difference(_lastHeartbeat!) > const Duration(seconds: 7)) {
          unawaited(disconnect(reason: '设备心跳中断，请重连后检查标签；不会自动重写'));
          return;
        }
        _heartbeatId = const Uuid().v4();
        unawaited(
          _send({'v': 1, 'id': _heartbeatId!, 'cmd': 'hello'}).catchError((
            Object _,
          ) {
            unawaited(disconnect(reason: '设备心跳发送失败，请重新连接'));
          }),
        );
      });
    } catch (error) {
      final failure = error is DesktopRfidException
          ? error
          : _connectionFailure(error);
      await disconnect(reason: failure.message);
      throw failure;
    } finally {
      connecting = false;
      _notify();
    }
  }

  static DesktopRfidException _connectionFailure(Object error) {
    final code = error is PlatformException ? error.code : 'connection_failed';
    return DesktopRfidException(code, switch (code) {
      'port_busy' => '此设备正在被其他软件使用。请关闭串口助手、烧录工具或另一份 Sohun 后重试',
      'serial_unavailable' ||
      'disconnected' => '设备已移除或串口不可用。请检查 USB 数据线与 CH340 驱动，然后刷新设备列表',
      'serial_configuration_failed' =>
        'Windows 无法配置串口。请检查 CH340 官方驱动和 USB 连接后重试',
      'busy' => '当前已有设备连接，请先断开再切换套件',
      'invalid_arguments' => '请选择设备列表中的有效串口',
      _ => 'Windows 内置串口组件不可用或连接失败，请检查应用安装、CH340 驱动及 USB 数据线',
    });
  }

  Future<DesktopRfidScan> scan() async =>
      DesktopRfidScan.fromJson(await _operation('scan'));

  Future<AmsTagTemplate> readTemplate() async {
    final result = await _operation('read_template');
    try {
      return AmsTagTemplate.fromJson(
        Map<String, dynamic>.from(result['template'] as Map),
      );
    } catch (_) {
      throw const DesktopRfidException('invalid_template', '源标签数据不完整，未保存模板');
    }
  }

  Future<void> restore(
    AmsTagTemplate template, {
    required String targetKind,
    required String expectedUid,
    required bool confirmed,
  }) async {
    if (!confirmed ||
        !const ['cuid', 'fuid'].contains(targetKind) ||
        !RegExp(r'^[0-9A-Fa-f]{8}$').hasMatch(expectedUid)) {
      throw const DesktopRfidException(
        'confirmation_required',
        '请读取目标卡，并明确确认卡型和 UID 覆盖风险',
      );
    }
    final result = await _operation(
      'restore',
      fields: {
        'template': template.toJson(),
        'targetKind': targetKind,
        'expectedUid': expectedUid.toUpperCase(),
        'allowUidChange': true,
      },
      timeout: restoreTimeout,
    );
    if (result['verified'] != true ||
        result['blocksVerified'] != 64 ||
        result['uid'] != template.uid ||
        result['templateId'] != template.id ||
        result['tagType'] != targetKind ||
        result['amsCompatibility'] != 'template_restored_unverified') {
      throw const DesktopRfidException(
        'verification_incomplete',
        '完整模板或真实 UID 校验未通过，禁止入库；请单独检查标签',
        mayHaveWritten: true,
      );
    }
  }

  Future<Map<String, dynamic>> _operation(
    String command, {
    Map<String, Object> fields = const {},
    Duration? timeout,
  }) {
    if (!supports(command)) {
      throw const DesktopRfidException('not_ready', '设备尚未就绪或固件不支持此操作');
    }
    return _request(
      command,
      fields: fields,
      timeout: timeout ?? operationTimeout,
    );
  }

  Future<Map<String, dynamic>> _request(
    String command, {
    Map<String, Object> fields = const {},
    required Duration timeout,
  }) async {
    if (_pending != null || _cancelId != null) {
      throw const DesktopRfidException('busy', '已有标签操作正在进行');
    }
    final id = const Uuid().v4();
    final completer = Completer<Map<String, dynamic>>();
    _pending = completer;
    _requestId = id;
    _command = command;
    state = command == 'hello' ? 'connecting' : 'waiting';
    completed = 0;
    _notify();
    // Install the timeout/error listener before any asynchronous transport work.
    final response = completer.future.timeout(
      timeout,
      onTimeout: () {
        unawaited(disconnect(reason: '设备响应超时，请重连后检查标签；不会自动重写'));
        throw DesktopRfidException(
          'timeout',
          '设备响应超时；未加入库存，请检查标签后重连',
          mayHaveWritten: command == 'restore',
        );
      },
    );
    unawaited(
      _send({'v': 1, 'id': id, 'cmd': command, ...fields}).catchError((
        Object _,
      ) {
        if (!completer.isCompleted) {
          completer.completeError(
            DesktopRfidException(
              'disconnected',
              'USB 发送失败，请重连后检查标签',
              mayHaveWritten: command == 'restore',
            ),
          );
        }
        unawaited(disconnect());
      }),
    );
    try {
      return await response;
    } finally {
      if (_requestId == id) {
        _pending = null;
        _requestId = null;
        _command = null;
        state = !connected
            ? 'disconnected'
            : readerReady
            ? 'ready'
            : 'reader_missing';
        _notify();
      }
    }
  }

  Future<void> _send(Map<String, Object> value) => transport.write(
    Uint8List.fromList(utf8.encode('${jsonEncode(value)}\n')),
  );

  void _receive(Uint8List bytes) {
    for (final byte in bytes) {
      if (byte != 10) {
        _buffer.add(byte);
        if (_buffer.length >= 8192) {
          _buffer.clear();
          unawaited(disconnect(reason: '设备协议数据超长，连接已关闭'));
          return;
        }
        continue;
      }
      final line = Uint8List.fromList(_buffer);
      _buffer.clear();
      Map<String, dynamic> event;
      try {
        final text = utf8.decode(line).trim();
        if (!text.startsWith('{')) continue; // ESP32 ROM boot messages only.
        final value = jsonDecode(text);
        if (value is! Map<String, dynamic>) continue;
        event = value;
      } catch (_) {
        unawaited(disconnect(reason: '设备协议校验失败，未接受读写结果'));
        return;
      }
      if (event['v'] != 1) {
        unawaited(disconnect(reason: '固件协议版本不兼容'));
        return;
      }
      if (event['id'] == _heartbeatId && _heartbeatId != null) {
        if (event['event'] == 'result' &&
            event['device'] == 'sohun-rfid-bridge' &&
            event['protocol'] == 1 &&
            event['deviceId'] == deviceId &&
            event['firmware'] == firmware &&
            event['readerReady'] is bool) {
          _lastHeartbeat = _now();
          final ready = event['readerReady'] == true;
          if (ready != readerReady) {
            readerReady = ready;
            if (!ready && _pending != null) {
              // A live USB link does not imply a live RF reader. Discard the
              // active operation and any late success if SPI/power is lost.
              unawaited(
                disconnect(reason: 'RC522 通信中断，本次结果未接受；请断电检查接线，写入可能未完成'),
              );
            } else {
              state = ready ? 'ready' : 'reader_missing';
              connectionMessage = ready
                  ? null
                  : 'ESP32 已连接，但 RC522 未就绪。请断电检查 3.3V 和 SPI 接线后重连';
              _notify();
            }
          }
        } else {
          unawaited(disconnect(reason: '套件身份或固件发生变化，请重新连接'));
        }
        continue;
      }
      if (event['id'] == _cancelId && _cancelId != null) {
        if (event['event'] == 'result' && !(_cancelAck?.isCompleted ?? true)) {
          _cancelAck!.complete();
        }
        continue;
      }
      if (event['id'] != _requestId ||
          _pending == null ||
          _pending!.isCompleted) {
        continue;
      }
      if (_cancelId != null) {
        continue; // A late success cannot become inventory.
      }
      if (event['event'] == 'progress') {
        const states = {
          'waiting',
          'preflight',
          'writing',
          'awaiting_reselect',
          'verifying',
        };
        if (states.contains(event['state'])) state = event['state'] as String;
        final count = event['completed'];
        completed = count is int ? count.clamp(0, 64) : 0;
        _notify();
      } else if (event['event'] == 'result') {
        _pending!.complete(event);
      } else if (event['event'] == 'error') {
        final code = event['code'] is String
            ? event['code'] as String
            : 'device_error';
        _pending!.completeError(
          DesktopRfidException(
            code,
            _errorMessage(code),
            mayHaveWritten:
                event['mayHaveWritten'] == true || _command == 'restore',
          ),
        );
      }
    }
  }

  static String _errorMessage(String raw) {
    final code = raw.toLowerCase();
    if (code.contains('cancel')) return '操作已取消；写入不等于回滚，请检查标签';
    if (code.contains('timeout')) return '等待标签超时，请保持一张标签靠近读卡器后重试';
    if (code.contains('uid') &&
        (code.contains('mismatch') || code.contains('changed'))) {
      return '目标标签已改变，已停止写入，请重新读取目标卡';
    }
    if (code == 'target_changed') return '目标标签已改变，已停止写入，请重新读取目标卡';
    if (code.contains('auth') || code.contains('key')) {
      return '标签认证失败或密钥不完整，不会猜测密钥；请使用可读取的源标签或完整模板';
    }
    if (code.contains('access') || code.contains('unsafe')) {
      return '标签访问权限不支持安全完整写入，请更换合适的 CUID/FUID 测试卡';
    }
    if (code.contains('reader')) return 'RC522 未就绪，请断电检查接线';
    if (code.contains('unsupported')) {
      return '此标签不支持当前操作；普通 S50 不代表可改 UID 的 CUID/FUID';
    }
    if (code.contains('busy')) return '设备仍有操作进行中，请取消并重连';
    return '读写未完成，请检查标签和接线后重试；未校验的标签不能用于 AMS';
  }

  Future<void> cancel() async {
    final target = _requestId;
    if (target == null || _cancelId != null) return;
    _cancelId = const Uuid().v4();
    _cancelAck = Completer<void>();
    state = 'cancelling';
    _notify();
    try {
      await _send({
        'v': 1,
        'id': _cancelId!,
        'cmd': 'cancel',
        'targetId': target,
      });
      await _cancelAck!.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      // An uncertain device operation never permits another write on this link.
    } finally {
      await disconnect(reason: '操作已取消并断开；可能部分写入，请先检查标签再重连');
    }
  }

  Future<void> disconnect({String? reason}) async {
    ++_generation;
    _heartbeat?.cancel();
    _heartbeat = null;
    _heartbeatId = null;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        DesktopRfidException(
          'disconnected',
          reason ?? '设备已断开，未接受本次结果',
          mayHaveWritten: _command == 'restore',
        ),
      );
    }
    connected = false;
    readerReady = false;
    connecting = false;
    _capabilities = {};
    _cancelId = null;
    _cancelAck = null;
    state = 'disconnected';
    port = null;
    firmware = null;
    deviceId = null;
    connectionMessage = reason;
    _buffer.clear();
    await transport.close();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    unawaited(disconnect());
    super.dispose();
  }
}
