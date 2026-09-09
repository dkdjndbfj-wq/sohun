import 'dart:async';

import 'package:flutter/services.dart';

/// A device shortcut contains an opaque locator, never device credentials or
/// consumable data. Possessing this URI does not grant access to the device.
class DeviceTagUri {
  const DeviceTagUri._(this.token);

  final String token;
  String get uri => 'https://sohun.top/device/$token';
  String get appUri => 'sohun://device/$token';

  static final _tokenPattern = RegExp(r'^[0-9a-f]{32}$');
  static final _uriPattern = RegExp(
    r'^(?:https://sohun\.top/device/|sohun://device/)([0-9a-f]{32})$',
  );

  factory DeviceTagUri.forToken(String token) {
    if (token.length != 32 || !_tokenPattern.hasMatch(token)) {
      throw const FormatException('设备标签标识格式无效');
    }
    return DeviceTagUri._(token);
  }

  static DeviceTagUri? parse(String value) {
    final match = _uriPattern.firstMatch(value);
    // Checking the matched length also excludes a trailing line terminator.
    if (match == null || match.end != value.length) return null;
    return DeviceTagUri._(match.group(1)!);
  }
}

sealed class DeviceTagReadResult {
  const DeviceTagReadResult();
}

class DeviceTagReadSuccess extends DeviceTagReadResult {
  const DeviceTagReadSuccess({
    required this.deviceToken,
    required this.uri,
    required this.tagId,
  });
  final String deviceToken;
  final String uri;
  final String tagId;
}

class DeviceTagReadFailure extends DeviceTagReadResult {
  const DeviceTagReadFailure(this.code, this.message);
  final String code;
  final String message;
}

sealed class DeviceTagWriteResult {
  const DeviceTagWriteResult();
}

class DeviceTagWriteSuccess extends DeviceTagWriteResult {
  const DeviceTagWriteSuccess({
    required this.deviceToken,
    required this.uri,
    required this.tagId,
    required this.verified,
    required this.bytesWritten,
  });
  final String deviceToken;
  final String uri;
  final String tagId;
  final bool verified;
  final int bytesWritten;
}

class DeviceTagWriteFailure extends DeviceTagWriteResult {
  const DeviceTagWriteFailure(this.code, this.message);
  final String code;
  final String message;
}

/// Independent NTAG213 device entry boundary. No inventory models or RFID
/// template APIs participate in this contract.
abstract interface class DeviceTagNfc {
  Future<bool> isAvailable();
  Future<bool> isEnabled();
  Future<DeviceTagReadResult> read();
  Future<DeviceTagWriteResult> write(String deviceToken);
  Future<void> cancel();
  Future<String?> takePendingDeviceUri();
  Stream<String> get deviceUris;
  Future<void> dispose();
}

class MethodChannelDeviceTagNfc implements DeviceTagNfc {
  MethodChannelDeviceTagNfc({
    MethodChannel? methodChannel,
    this.operationTimeout = const Duration(seconds: 65),
  }) : channel = methodChannel ?? const MethodChannel(channelName) {
    channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'top.sohun/device_tag';
  static int _nextOperation = 0;
  final MethodChannel channel;
  final Duration operationTimeout;
  final _uris = StreamController<String>.broadcast();
  String? _activeId;
  Completer<Map<Object?, Object?>>? _completion;
  bool _disposed = false;

  @override
  Stream<String> get deviceUris => _uris.stream;

  @override
  Future<bool> isAvailable() => _statusFlag('available');
  @override
  Future<bool> isEnabled() => _statusFlag('enabled');

  Future<bool> _statusFlag(String key) async {
    if (_disposed) return false;
    try {
      final status = await channel.invokeMethod<Object?>('getStatus');
      return status is Map && status[key] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> takePendingDeviceUri() async {
    if (_disposed) return null;
    try {
      final value = await channel.invokeMethod<Object?>('takePendingDeviceUri');
      return value is String ? DeviceTagUri.parse(value)?.uri : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<DeviceTagReadResult> read() async {
    final result = await _run('beginRead');
    final identity = _validSuccess(result, 'read_success');
    if (identity == null) {
      return DeviceTagReadFailure(
        result['code']?.toString() ?? 'INVALID_DEVICE_TAG',
        result['message']?.toString() ?? '未读取到有效设备标签',
      );
    }
    return DeviceTagReadSuccess(
      deviceToken: identity.token,
      uri: identity.uri,
      tagId: result['tagId'] as String,
    );
  }

  @override
  Future<DeviceTagWriteResult> write(String deviceToken) async {
    try {
      DeviceTagUri.forToken(deviceToken);
    } on FormatException {
      return const DeviceTagWriteFailure('INVALID_PAYLOAD', '设备标签标识格式无效');
    }
    final result = await _run('beginWrite', {'deviceToken': deviceToken});
    final identity = _validSuccess(result, 'write_success');
    if (identity == null ||
        identity.token != deviceToken ||
        result['verified'] != true ||
        result['bytesWritten'] is! int ||
        (result['bytesWritten'] as int) <= 0) {
      return DeviceTagWriteFailure(
        result['code']?.toString() ?? 'VERIFY_FAILED',
        result['message']?.toString() ?? '设备标签尚未完成回读校验，请重新制作',
      );
    }
    return DeviceTagWriteSuccess(
      deviceToken: identity.token,
      uri: identity.uri,
      tagId: result['tagId'] as String,
      verified: true,
      bytesWritten: result['bytesWritten'] as int,
    );
  }

  DeviceTagUri? _validSuccess(Map<Object?, Object?> result, String state) {
    if (result['state'] != state ||
        result['tagType'] != 'NTAG213' ||
        result['uri'] is! String ||
        result['tagId'] is! String ||
        (result['tagId'] as String).length != 14 ||
        !RegExp(r'^[0-9A-Fa-f]{14}$').hasMatch(result['tagId'] as String)) {
      return null;
    }
    final identity = DeviceTagUri.parse(result['uri'] as String);
    return identity?.token == result['deviceToken'] ? identity : null;
  }

  Future<Map<Object?, Object?>> _run(
    String method, [
    Map<String, Object> arguments = const {},
  ]) async {
    if (_disposed) return _failure('OPERATION_CANCELLED', '设备标签工具已关闭');
    if (_activeId != null) return _failure('NFC_BUSY', '已有 NFC 操作进行中');
    final id =
        'device-${DateTime.now().microsecondsSinceEpoch}-${_nextOperation++}';
    final completion = Completer<Map<Object?, Object?>>();
    _activeId = id;
    _completion = completion;
    try {
      final started = await channel
          .invokeMethod<Object?>(method, {'operationId': id, ...arguments})
          .timeout(operationTimeout);
      if (started is Map) _acceptEvent(Map<Object?, Object?>.from(started));
      return await completion.future.timeout(
        operationTimeout,
        onTimeout: () async {
          final terminal = await _cancelNative(id);
          if (terminal != null && _terminal(terminal)) return terminal;
          return _failure('OPERATION_TIMEOUT', 'NFC 操作超时，请重新开始');
        },
      );
    } on MissingPluginException {
      return _failure('NFC_UNAVAILABLE', '此平台不支持 NFC 设备标签');
    } on PlatformException catch (error) {
      return _failure(error.code, error.message ?? '设备标签操作失败，请重试');
    } on TimeoutException {
      final terminal = await _cancelNative(id);
      return terminal != null && _terminal(terminal)
          ? terminal
          : _failure('OPERATION_TIMEOUT', 'NFC 操作超时，请重新开始');
    } finally {
      if (_activeId == id) {
        _activeId = null;
        _completion = null;
      }
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (_disposed) return;
    if (call.method == 'deviceUri' && call.arguments is String) {
      final uri = DeviceTagUri.parse(call.arguments as String);
      if (uri != null) _uris.add(uri.uri);
    } else if (call.method == 'deviceTagEvent' && call.arguments is Map) {
      _acceptEvent(Map<Object?, Object?>.from(call.arguments as Map));
    }
  }

  bool _terminal(Map<Object?, Object?> value) => const {
    'read_success',
    'write_success',
    'failed',
    'cancelled',
  }.contains(value['state']);

  void _acceptEvent(Map<Object?, Object?> event) {
    final completion = _completion;
    if (event['operationId'] == _activeId &&
        completion != null &&
        !completion.isCompleted &&
        _terminal(event)) {
      completion.complete(event);
    }
  }

  Future<Map<Object?, Object?>?> _cancelNative(String id) async {
    try {
      final value = await channel
          .invokeMethod<Object?>('cancel', {'operationId': id})
          .timeout(const Duration(seconds: 3));
      if (value is Map && value['operationId'] == id) {
        return Map<Object?, Object?>.from(value);
      }
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on TimeoutException {
      return null;
    }
    return null;
  }

  @override
  Future<void> cancel() async {
    final id = _activeId;
    final completion = _completion;
    if (id == null || completion == null) return;
    final terminal = await _cancelNative(id);
    if (!completion.isCompleted) {
      completion.complete(
        terminal != null && _terminal(terminal)
            ? terminal
            : _failure('OPERATION_CANCELLED', 'NFC 操作已取消'),
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
    channel.setMethodCallHandler(null);
    await _uris.close();
  }

  Map<Object?, Object?> _failure(String code, String message) => {
    'state': 'failed',
    'code': code,
    'message': message,
  };
}
