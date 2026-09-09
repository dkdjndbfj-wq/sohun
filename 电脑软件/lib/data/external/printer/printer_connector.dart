import 'dart:async';

/// 打印机连接抽象接口。
///
/// 抽象出"连接打印机、监听状态、发送控制指令"等能力，
/// 便于未来扩展非拓竹品牌（如创想三维的 Creality Cloud 协议）。
///
/// 实现类需要：
/// 1. 建立与打印机的长连接（拓竹用 MQTT，其他品牌可能用 HTTP/WebSocket）
/// 2. 实时推送打印机状态变化（打印进度、温度、层号等）
/// 3. 发送控制指令（暂停、恢复、停止、发送打印任务）
abstract class PrinterConnector {
  /// 连接打印机。返回是否连接成功。
  Future<bool> connect();

  /// 断开连接。
  Future<void> disconnect();

  /// 当前是否已连接。
  bool get isConnected;

  /// 打印机状态流。每次状态变化推送一个新快照。
  Stream<dynamic> get statusStream;

  /// 请求推送全部状态（pushall）。连接后主动调用一次。
  Future<void> requestStatus();

  /// 暂停打印。
  Future<bool> pause();

  /// 恢复打印。
  Future<bool> resume();

  /// 停止打印。
  Future<bool> stop();

  /// 发送打印任务（G-code / 3MF 文件路径）。
  /// 文件需先上传到打印机 SD 卡（拓竹通过 FTP）。
  Future<bool> sendPrintTask(String filePath,
      {List<int>? amsMapping, int plateIndex = 1});

  /// 调整打印速度（拓竹 print_speed 指令）。
  /// [profileLevel] 是协议档位 1/2/3/4，不是 spd_mag 显示倍率。
  Future<bool> setSpeed(int profileLevel);

  /// 连接错误流。
  Stream<String> get errorStream;

  /// 连接状态变化流。
  ///
  /// 实现必须在以下时机推送：
  /// - connect() 开始时推送 [PrinterConnectionState.connecting]
  /// - 连接成功时推送 [PrinterConnectionState.connected]
  /// - 连接断开（包括 autoReconnect 触发的临时断开）时推送 [PrinterConnectionState.disconnected]
  /// - 正在自动重连时推送 [PrinterConnectionState.reconnecting]
  /// - 连接出错时推送 [PrinterConnectionState.error]
  ///
  /// UI 层通过此流感知连接断开，避免任务状态卡在 printing。
  Stream<PrinterConnectionState> get connectionStateStream;

  /// 释放流控制器、定时器等长期资源。调用后连接器不可复用。
  Future<void> dispose();
}

/// 打印机连接状态
enum PrinterConnectionState {
  disconnected,
  connecting,
  connected,

  /// P1-2: 正在自动重连（指数退避重试中）
  reconnecting,
  error,
}
