import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';

/// 局域网内发现的拓竹打印机。
///
/// 通过 mDNS 扫描 `_bambu._tcp` 服务获取。包含连接所需的 IP 地址，
/// 以及用于和云端设备列表匹配的序列号（若 TXT 记录包含 dev_id）。
class DiscoveredBambuPrinter {
  /// 打印机 IP 地址（局域网）
  final String ip;

  /// MQTT 端口（通常 8883）
  final int port;

  /// 完整序列号（15 位，如 03900D642930459）。
  /// 优先从 TXT 记录的 dev_id 字段读取，读不到则为 null。
  final String? serial;

  /// 设备实例名（如 "X1E-42930459"），从 mDNS PTR 记录获取。
  /// 仅 serial 为 null 时用于和云端设备做后缀匹配。
  final String instanceName;

  /// 设备名（从 TXT 记录 dev_name 读取，可能为空）
  final String deviceName;

  /// 发现方式：'mdns' 或 'portscan'
  final String source;

  const DiscoveredBambuPrinter({
    required this.ip,
    required this.port,
    this.serial,
    required this.instanceName,
    this.deviceName = '',
    this.source = 'mdns',
  });

  /// 提取序列号后 8 位用于和云端设备匹配。
  /// 拓竹序列号 15 位，实例名通常是 "<model>-<后8位>" 格式。
  String? get serialSuffix {
    if (serial != null && serial!.length >= 8) {
      return serial!.substring(serial!.length - 8);
    }
    // 从实例名解析：<model>-<后8位>
    final dashIndex = instanceName.lastIndexOf('-');
    if (dashIndex >= 0 && dashIndex + 1 < instanceName.length) {
      return instanceName.substring(dashIndex + 1);
    }
    return null;
  }

  /// 判断是否匹配给定序列号（先精确匹配，再后缀匹配）。
  bool matches(String cloudSerial) {
    if (serial != null && serial == cloudSerial) return true;
    final suffix = serialSuffix;
    if (suffix != null && cloudSerial.length >= 8) {
      return cloudSerial.substring(cloudSerial.length - 8) == suffix;
    }
    return false;
  }

  @override
  String toString() =>
      'DiscoveredBambuPrinter($ip:$port, serial=$serial, name=$instanceName, source=$source)';
}

/// 扫描取消令牌。
///
/// 调用 [cancel] 后，正在进行的扫描循环会在下一次检查点退出。
class LanScanCancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// 拓竹打印机局域网发现服务。
///
/// **双模式发现**：
/// 1. mDNS 协议扫描 `_bambu._tcp.local` 服务（首选，信息最全）
/// 2. IP 段端口扫描 8883（备用，解决 mDNS 多网卡/防火墙失效问题）
///
/// Windows 多网卡环境下 mDNS 可能失效（多播包发到错误接口），
/// 端口扫描作为兜底确保在 mDNS 不工作时仍能发现打印机。
///
/// 端口扫描会进一步用 MQTT TLS 握手验证，排除非 MQTT 服务误报。
class BambuLanDiscovery {
  BambuLanDiscovery._();

  /// 拓竹 mDNS 服务类型（含 .local 后缀）。
  static const _serviceType = '_bambu._tcp.local';

  /// 单次查询的超时（mDNS 响应通常在 1-2 秒内到达）。
  static const _queryTimeout = Duration(seconds: 3);

  /// 端口扫描并发数。
  static const _portScanConcurrency = 50;

  /// TCP 连接超时（毫秒）。
  static const _portScanTimeoutMs = 800;

  /// MQTT 握手验证超时（毫秒）。
  static const _mqttVerifyTimeoutMs = 1500;

  /// 拓竹 MQTT TLS 端口。
  static const _bambuPort = 8883;

  /// 缓存有效期（5 分钟）。
  static const _cacheTtl = Duration(minutes: 5);

  // 缓存：最近一次扫描的结果与时间。
  static List<DiscoveredBambuPrinter>? _cache;
  static DateTime? _cacheTime;

  /// 扫描局域网内的拓竹打印机（mDNS + 端口扫描双模式）。
  ///
  /// 先尝试 mDNS（3秒超时），再并行做 IP 段端口扫描。
  /// 两种方式结果合并去重，端口扫描发现的设备无序列号（serial=null）。
  ///
  /// [cancellationToken] 可用于取消正在进行的扫描。
  /// [forceRefresh] 为 true 时跳过缓存重新扫描。
  static Future<List<DiscoveredBambuPrinter>> discover({
    void Function(String phase, int progress, int total)? onProgress,
    LanScanCancellationToken? cancellationToken,
    bool forceRefresh = false,
  }) async {
    // 缓存命中检查
    if (!forceRefresh &&
        _cache != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < _cacheTtl) {
      return List.unmodifiable(_cache!);
    }

    // 并行执行 mDNS + 端口扫描
    // P1-7 修复：用 Future.wait 的错误隔离模式，避免 mDNS 失败导致端口扫描结果丢弃
    final mdnsFuture = _discoverByMdns(cancellationToken: cancellationToken)
        .catchError((Object _, StackTrace __) => <DiscoveredBambuPrinter>[]);
    final scanFuture = _discoverByPortScan(
      onProgress: onProgress,
      cancellationToken: cancellationToken,
    ).catchError((Object _, StackTrace __) => <DiscoveredBambuPrinter>[]);

    final results = await Future.wait([mdnsFuture, scanFuture]);

    // 若被取消，返回空列表（不写缓存）
    if (cancellationToken?.isCancelled ?? false) {
      return const [];
    }

    // 合并去重：mDNS 结果优先（有 serial），端口扫描补充（无 serial）
    final deduped = <String, DiscoveredBambuPrinter>{};
    // 先放 mDNS 结果（信息更全）
    for (final p in results[0]) {
      final key = p.ip;
      deduped[key] = p;
    }
    // 再放端口扫描结果（不覆盖 mDNS 已发现的）
    for (final p in results[1]) {
      deduped.putIfAbsent(p.ip, () => p);
    }

    final list = deduped.values.toList()
      ..sort((a, b) => a.instanceName.compareTo(b.instanceName));

    // 写缓存
    _cache = List.unmodifiable(list);
    _cacheTime = DateTime.now();

    return list;
  }

  /// 清除缓存（例如用户主动重新扫描时调用）。
  static void clearCache() {
    _cache = null;
    _cacheTime = null;
  }

  /// 仅 mDNS 扫描（向后兼容，discover() 的子步骤）。
  static Future<List<DiscoveredBambuPrinter>> _discoverByMdns({
    LanScanCancellationToken? cancellationToken,
  }) async {
    final client = MDnsClient();
    await client.start();

    final results = <DiscoveredBambuPrinter>[];
    final seenIps = <String>{};

    try {
      // 1. 查询 PTR 记录，获取所有 _bambu._tcp 服务实例名
      await for (final ptr in client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_serviceType),
          )
          .timeout(_queryTimeout, onTimeout: (sink) => sink.close())) {
        if (cancellationToken?.isCancelled ?? false) break;
        final instanceName = ptr.domainName;
        if (instanceName.isEmpty) continue;

        // 2. 查询 SRV 记录
        String? host;
        int port = _bambuPort;
        await for (final srv in client
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(instanceName),
            )
            .timeout(_queryTimeout, onTimeout: (sink) => sink.close())) {
          host = srv.target;
          port = srv.port;
          break;
        }
        if (host == null || host.isEmpty) continue;

        // 3. 查询 A 记录
        String? ip;
        await for (final a in client
            .lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(host),
            )
            .timeout(_queryTimeout, onTimeout: (sink) => sink.close())) {
          ip = a.address.address;
          break;
        }
        ip ??= host;

        if (ip.isEmpty || seenIps.contains(ip)) continue;
        seenIps.add(ip);

        // 4. 查询 TXT 记录
        String? serial;
        String deviceName = '';
        await for (final txt in client
            .lookup<TxtResourceRecord>(
              ResourceRecordQuery.text(instanceName),
            )
            .timeout(_queryTimeout, onTimeout: (sink) => sink.close())) {
          final parsed = _parseTxtRecord(txt.text);
          if (parsed['dev_id'] != null && parsed['dev_id']!.isNotEmpty) {
            serial = parsed['dev_id'];
          }
          if (parsed['dev_name'] != null && parsed['dev_name']!.isNotEmpty) {
            deviceName = parsed['dev_name']!;
          }
          break;
        }

        final cleanName = instanceName.replaceAll('._bambu._tcp.local.', '');

        results.add(
          DiscoveredBambuPrinter(
            ip: ip,
            port: port,
            serial: serial,
            instanceName: cleanName,
            deviceName: deviceName,
            source: 'mdns',
          ),
        );
      }
    } finally {
      client.stop();
    }

    // 按 IP 去重
    final deduped = <String, DiscoveredBambuPrinter>{};
    for (final p in results) {
      deduped.putIfAbsent(p.ip, () => p);
    }
    return deduped.values.toList();
  }

  /// IP 段端口扫描发现打印机（mDNS 的备用方案）。
  ///
  /// 获取本机所有真实网卡的 IPv4 地址，推导网段，
  /// 并发扫描 8883 端口。TCP 连接成功后进一步做 MQTT TLS 握手验证，
  /// 仅保留确认为 MQTT broker 的设备，排除非 MQTT 服务的误报。
  static Future<List<DiscoveredBambuPrinter>> _discoverByPortScan({
    void Function(String phase, int progress, int total)? onProgress,
    LanScanCancellationToken? cancellationToken,
  }) async {
    final subnets = await _getLocalSubnets();
    if (subnets.isEmpty) return [];

    final allIps = <String>[];
    for (final subnet in subnets) {
      for (var i = 1; i <= 254; i++) {
        allIps.add('$subnet.$i');
      }
    }

    final found = <DiscoveredBambuPrinter>[];
    var completed = 0;
    final total = allIps.length;

    // 信号量并发控制：限制同时进行的连接数
    var active = 0;
    final allDone = Completer<void>();
    var cancelled = false;
    // P1-8 修复：用 Completer 队列替代 busy-wait 轮询，
    // 避免 254 IP 扫描时 ~50000 次空轮询浪费 CPU
    final waitQueue = <Completer<void>>[];

    Future<void> scanOne(String ip) async {
      if (cancellationToken?.isCancelled ?? false) {
        cancelled = true;
        // P1-9 修复：active--/completed++/notify/maybeComplete 移到 finally
        // 避免异常时 active 永久不递减导致扫描死锁
        return;
      }
      try {
        final socket = await Socket.connect(
          ip,
          _bambuPort,
          timeout: const Duration(milliseconds: _portScanTimeoutMs),
        );
        // TCP 连接成功，进一步用 MQTT TLS 握手验证
        final isMqtt = await _verifyMqttTls(socket);
        if (isMqtt) {
          found.add(
            DiscoveredBambuPrinter(
              ip: ip,
              port: _bambuPort,
              instanceName: ip,
              deviceName: '',
              source: 'portscan',
            ),
          );
        }
      } catch (_) {
      } finally {
        // P1-9 修复：无论成功/失败/取消，都必须递减 active 和递增 completed
        completed++;
        active--;
        _notifyProgress(onProgress, completed, total);
        _maybeComplete(allDone, completed, total);
        // P1-8: 唤醒等待中的下一个扫描任务
        if (waitQueue.isNotEmpty) {
          final next = waitQueue.removeAt(0);
          if (!next.isCompleted) next.complete();
        }
      }
    }

    for (final ip in allIps) {
      if (cancellationToken?.isCancelled ?? false) {
        break;
      }
      // P1-8 修复：用 Completer 等待可用并发槽，避免 busy-wait
      if (active >= _portScanConcurrency) {
        final waiter = Completer<void>();
        waitQueue.add(waiter);
        await waiter.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        );
        if (cancellationToken?.isCancelled ?? false) break;
      }
      if (cancellationToken?.isCancelled ?? false) break;
      active++;
      scanOne(ip);
    }

    // 等待所有扫描完成
    while (!allDone.isCompleted) {
      await Future.delayed(const Duration(milliseconds: 20));
      if ((cancellationToken?.isCancelled ?? false) && !allDone.isCompleted) {
        // 给一点时间让进行中的任务收尾
        await Future.delayed(const Duration(milliseconds: 200));
        if (!allDone.isCompleted) allDone.complete();
      }
    }

    // 返回前再次检查取消状态
    if (cancelled || (cancellationToken?.isCancelled ?? false)) {
      return const [];
    }
    return found;
  }

  static void _notifyProgress(
    void Function(String, int, int)? onProgress,
    int p,
    int total,
  ) {
    onProgress?.call('portscan', p, total);
  }

  static void _maybeComplete(Completer<void> c, int completed, int total) {
    if (completed >= total && !c.isCompleted) c.complete();
  }

  /// 通过 MQTT TLS 握手验证目标是否为拓竹 MQTT broker。
  ///
  /// 拓竹 8883 端口为 MQTT over TLS。流程：
  /// 1. 将 socket 升级为 SecureSocket（不验证证书）
  /// 2. 发送 MQTT 3.1.1 CONNECT 包
  /// 3. 等待响应首字节，0x20 (CONNACK) 即确认为 MQTT broker
  ///
  /// 任何步骤失败或超时均视为非 MQTT 服务，返回 false。
  static Future<bool> _verifyMqttTls(Socket socket) async {
    SecureSocket? secure;
    try {
      secure = await SecureSocket.secure(
        socket,
        onBadCertificate: (_) => true,
      );
      // 构造并发送 MQTT 3.1.1 CONNECT 包
      secure.add(_buildMqttConnectPacket());
      // 等待响应，首字节 0x20 = CONNACK
      final data = await secure.first
          .timeout(const Duration(milliseconds: _mqttVerifyTimeoutMs));
      if (data.isNotEmpty) {
        return data[0] == 0x20;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      // P0 修复：SecureSocket.close() 不会关闭底层原始 socket，
      // 254 IP 扫描场景下需同时关闭两者，避免端口资源耗尽
      try {
        await secure?.close();
      } catch (_) {}
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  /// 构造一个最小的 MQTT 3.1.1 CONNECT 包。
  ///
  /// 拓竹 MQTT 会返回 CONNACK（即便密码错误也会返回 0x20 + return code 5），
  /// 非 MQTT 服务不会返回 0x20 字节，因此可用于协议指纹识别。
  static Uint8List _buildMqttConnectPacket() {
    // 协议名 "MQTT" + level 4 + flags 0x02 (clean session) + keepalive 60
    final body = <int>[
      0x00, 0x04, // protocol name length
      ...utf8.encode('MQTT'), // protocol name
      0x04, // protocol level (3.1.1)
      0x02, // connect flags: clean session
      0x00, 0x3C, // keep alive: 60s
      0x00, 0x04, // client id length
      ...utf8.encode('scan'), // client id "scan"
    ];
    // Fixed header: 0x10 (CONNECT) + remaining length
    return Uint8List.fromList([0x10, body.length, ...body]);
  }

  /// 获取本机所有真实网卡的 IPv4 网段（如 192.168.31）。
  ///
  /// 排除回环(127)、链路本地(169.254)、虚拟网卡
  /// (WSL/Hyper-V/Docker/vEthernet/VMware/VirtualBox/TAP/Hamachi/Loopback Pseudo-Interface)。
  static Future<Set<String>> _getLocalSubnets() async {
    final subnets = <String>{};
    // 容错修复：NetworkInterface.list 可能抛 SocketException（无网络/权限），
    // 包裹后返回空集合而非让整个 discover 失败。
    List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    } catch (e) {
      // 网络接口列举失败，返回空子网集合
      return subnets;
    }
    for (final interface in interfaces) {
      // 排除虚拟网卡
      final name = interface.name.toLowerCase();
      if (_isVirtualInterface(name)) continue;
      for (final addr in interface.addresses) {
        final ip = addr.address;
        // 排除回环和链路本地
        if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
        // 排除 CGNAT 网段（100.64.0.0/10，即 100.64.0.0 ~ 100.127.255.255）。
        // 修复：原实现只覆盖 100.64-69 + 100.7/8/9（后三者不在 CGNAT 范围），
        // 且漏掉 100.70-100.127。改为精确第二段范围判断。
        if (_isCgnatIp(ip)) continue;
        // 提取前三段作为网段
        final parts = ip.split('.');
        if (parts.length == 4) {
          subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
        }
      }
    }
    return subnets;
  }

  /// 判断网卡名称是否为虚拟网卡。
  ///
  /// 覆盖常见虚拟化/VPN/容器场景，避免 mDNS 多播和端口扫描误入虚拟网段。
  /// 判断 IPv4 是否属于 CGNAT 网段 100.64.0.0/10（100.64.0.0 ~ 100.127.255.255）。
  static bool _isCgnatIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final second = int.tryParse(parts[1]);
    if (second == null) return false;
    return parts[0] == '100' && second >= 64 && second <= 127;
  }

  static bool _isVirtualInterface(String name) {
    // 虚拟机/容器
    if (name.contains('wsl') ||
        name.contains('hyper-v') ||
        name.contains('docker') ||
        name.contains('vmware') ||
        name.contains('virtualbox') ||
        name.contains('vethernet') ||
        name.contains('vbox')) {
      return true;
    }
    // VPN / 隧道
    if (name.contains('tap') || // TAP-Windows / OpenVPN TAP
        name.contains('tun') || // TUN 隧道
        name.contains('hamachi') || // LogMeIn Hamachi
        name.contains('openvpn') ||
        name.contains('wireguard') ||
        name.contains('tailscale') ||
        name.contains('zerotier') ||
        name.contains('cisco') || // Cisco AnyConnect
        name.contains('vpn')) {
      return true;
    }
    // 软件桥 / loopback 伪接口
    if (name.contains('loopback') ||
        name.contains('pseudo') ||
        name.contains('isatap') ||
        name.contains('teredo')) {
      return true;
    }
    return false;
  }

  /// 解析 mDNS TXT 记录文本为 key-value map。
  static Map<String, String> _parseTxtRecord(String text) {
    final result = <String, String>{};
    if (text.isEmpty) return result;

    List<String> parts;
    if (text.contains('\n')) {
      parts = text.split('\n');
    } else if (text.contains(' ')) {
      parts = text.split(' ');
    } else {
      parts = [text];
    }

    for (final part in parts) {
      final eqIndex = part.indexOf('=');
      if (eqIndex > 0) {
        final key = part.substring(0, eqIndex).trim();
        final value = part.substring(eqIndex + 1).trim();
        if (key.isNotEmpty) {
          result[key] = value;
        }
      }
    }
    return result;
  }
}
