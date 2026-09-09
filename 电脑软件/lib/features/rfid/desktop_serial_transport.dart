import 'dart:async';

import 'package:flutter/services.dart';

class DesktopSerialPort {
  const DesktopSerialPort(this.port, this.label, {this.hardwareId = ''});
  final String port;
  final String label;
  final String hardwareId;
  bool get isKitCandidate => RegExp(
    'CH34[01]|VID_1A86',
    caseSensitive: false,
  ).hasMatch('$label $hardwareId');
}

/// Local USB only. The host never opens a port until the user chooses Connect.
abstract interface class DesktopSerialTransport {
  Stream<Uint8List> get bytes;
  Future<List<DesktopSerialPort>> listPorts();
  Future<void> open(String port);
  Future<void> write(Uint8List bytes);
  Future<void> close();
}

class MethodChannelDesktopSerialTransport implements DesktopSerialTransport {
  MethodChannelDesktopSerialTransport({
    this.channel = const MethodChannel('top.sohun/desktop_rfid_serial'),
  });

  final MethodChannel channel;
  final _bytes = StreamController<Uint8List>.broadcast();
  String? _connectionId;
  int _generation = 0;

  @override
  Stream<Uint8List> get bytes => _bytes.stream;

  @override
  Future<List<DesktopSerialPort>> listPorts() async {
    final values = await channel.invokeMethod<List<Object?>>('listPorts');
    return [
      for (final value in values ?? const [])
        if (value is Map &&
            value['port'] is String &&
            RegExp(r'^COM[1-9][0-9]{0,4}$').hasMatch(value['port'] as String))
          DesktopSerialPort(
            value['port'] as String,
            (value['label'] as String?) ?? value['port'] as String,
            hardwareId: (value['hardwareId'] as String?) ?? '',
          ),
    ];
  }

  @override
  Future<void> open(String port) async {
    if (_connectionId != null) throw StateError('串口已连接');
    final generation = ++_generation;
    final value = await channel.invokeMapMethod<String, Object?>('open', {
      'port': port,
    });
    final id = value?['connectionId'];
    if (id is! String || id.isEmpty) throw StateError('串口连接失败');
    if (generation != _generation) {
      await channel.invokeMethod<void>('close', {'connectionId': id});
      throw StateError('连接已取消');
    }
    _connectionId = id;
    unawaited(_poll(id, generation));
  }

  Future<void> _poll(String id, int generation) async {
    while (_connectionId == id && generation == _generation) {
      try {
        final chunk = await channel.invokeMethod<Uint8List>('read', {
          'connectionId': id,
        });
        if (_connectionId != id || generation != _generation) return;
        if (chunk != null && chunk.isNotEmpty) _bytes.add(chunk);
      } catch (_) {
        if (_connectionId == id && generation == _generation) {
          _bytes.addError(StateError('串口已断开'));
          await close();
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final id = _connectionId;
    if (id == null) throw StateError('串口未连接');
    if (bytes.length > 8192) throw StateError('协议消息过长');
    await channel.invokeMethod<void>('write', {
      'connectionId': id,
      'bytes': bytes,
    });
    if (_connectionId != id) throw StateError('串口连接已更改');
  }

  @override
  Future<void> close() async {
    ++_generation;
    final id = _connectionId;
    _connectionId = null;
    if (id == null) return;
    try {
      await channel.invokeMethod<void>('close', {'connectionId': id});
    } catch (_) {
      // The native host invalidates handles on unplug/write failure as well.
    }
  }
}
