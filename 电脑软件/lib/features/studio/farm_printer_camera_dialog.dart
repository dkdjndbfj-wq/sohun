import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/printer_fleet_connection_manager.dart';
import '../../core/services/studio_video_relay_service.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_certificate_trust_store.dart';
import '../../providers/printer_connection_provider.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_theme.dart';

Future<void> showFarmPrinterCameraDialog(
  BuildContext context,
  WidgetRef ref, {
  required PrinterWithChannels printer,
  required FleetPrinterState? state,
}) async {
  final serial = printer.serial?.trim();
  PrinterConnectionConfig? config;
  if (serial != null && serial.isNotEmpty) {
    for (final candidate in ref.read(mergedPrinterListProvider)) {
      if (candidate.serial != serial) continue;
      // mergedPrinterListProvider 已按用户明确选择的连接模式解析配置。
      // 摄像头入口不再自行把云端改成 LAN 或优先 LAN。
      config = candidate;
      break;
    }
  }

  final printerName = printer.printer.name?.trim().isNotEmpty == true
      ? printer.printer.name!.trim()
      : printer.printer.model;
  final model = config?.devProductName?.trim().isNotEmpty == true
      ? config!.devProductName!.trim()
      : state?.reportedModel?.trim().isNotEmpty == true
          ? state!.reportedModel!.trim()
          : printer.printer.model;

  unawaited(
    recordCurrentFarmActivity(
      ref,
      actionCode: 'printer.camera_preview_opened',
      entityType: 'printer',
      entityId: '${printer.printer.id}',
      summary: '查看 $printerName 的实时画面',
    ).catchError((Object _) {}),
  );

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => FarmPrinterCameraDialog(
      printerName: printerName,
      serial: serial,
      model: model,
      config: config,
    ),
  );
}

class FarmPrinterCameraDialog extends ConsumerStatefulWidget {
  const FarmPrinterCameraDialog({
    super.key,
    required this.printerName,
    required this.serial,
    required this.model,
    required this.config,
    this.compact = false,
  });

  final String printerName;
  final String? serial;
  final String model;
  final PrinterConnectionConfig? config;
  final bool compact;

  @override
  ConsumerState<FarmPrinterCameraDialog> createState() =>
      _FarmPrinterCameraDialogState();
}

class _FarmPrinterCameraDialogState
    extends ConsumerState<FarmPrinterCameraDialog> {
  FarmCameraPreviewSession? _session;
  StreamSubscription<Uint8List>? _subscription;
  Timer? _waitingTimer;
  Uint8List? _frame;
  DateTime? _lastFrameAt;
  String? _error;
  FarmCameraCertificateTrustRequired? _certificateApproval;
  bool _connecting = true;
  bool _closing = false;
  int _attempt = 0;
  // 降级等待的后台自动重试：休眠/唤醒类失败后无需用户点击“重新连接”，
  // 定时自动重连，设备被唤醒后直接出画面。
  Timer? _autoRetryTimer;
  int _autoRetryCount = 0;
  bool _autoRetryStopped = false;
  static const int _maxAutoRetries = 10;
  static const Duration _autoRetryDelay = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  /// 休眠/唤醒待处理类错误：值得在后台自动重试（用户只需去官方客户端
  /// 唤醒设备，不需要回来点按钮）。
  static bool _wakePendingError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('need_official_wake') ||
        text.contains('wake wait timed out') ||
        text.contains('sign_rejected') ||
        text.contains('-90') ||
        text.contains('休眠') ||
        text.contains('未能唤醒') ||
        text.contains('唤醒请求');
  }

  void _scheduleAutoRetry() {
    if (_closing ||
        !mounted ||
        _connecting ||
        _frame != null ||
        _certificateApproval != null) {
      return;
    }
    _autoRetryTimer?.cancel();
    if (_autoRetryStopped || _autoRetryCount >= _maxAutoRetries) {
      _autoRetryStopped = true;
      setState(() {});
      return;
    }
    _autoRetryCount += 1;
    setState(() {});

    _autoRetryTimer = Timer(_autoRetryDelay, () {
      _autoRetryTimer = null;
      if (!mounted ||
          _closing ||
          _frame != null ||
          _certificateApproval != null) {
        return;
      }
      _connect(manual: false);
    });
  }

  void _stopAutoRetry() {
    _autoRetryTimer?.cancel();
    _autoRetryTimer = null;
    if (_autoRetryCount != 0 || _autoRetryStopped) {
      _autoRetryCount = 0;
      _autoRetryStopped = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _connect({bool manual = true}) async {
    final attempt = ++_attempt;
    _autoRetryTimer?.cancel();
    _autoRetryTimer = null;
    if (manual) {
      _autoRetryCount = 0;
      _autoRetryStopped = false;
    }

    await _releaseSession();
    if (!mounted || attempt != _attempt) {
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
      _certificateApproval = null;
      _frame = null;
      _lastFrameAt = null;
    });

    final config = widget.config;
    if (config == null) {
      setState(() {
        _connecting = false;
        _error = widget.serial == null || widget.serial!.isEmpty
            ? '该设备没有序列号，无法建立摄像头连接'
            : '该设备尚未选择有效的云端或局域网连接，请先在设备连接中完成配置';
      });
      return;
    }

    try {
      final connector = ref.read(farmCameraPreviewConnectorProvider);
      final session = await connector(config: config, model: widget.model);
      if (!mounted || attempt != _attempt) {
        await session.dispose();
        return;
      }
      _session = session;
      _subscription = session.frames.listen(
        (frame) {
          if (!mounted || attempt != _attempt || frame.isEmpty) return;
          _stopAutoRetry();
          setState(() {
            _frame = frame;
            _lastFrameAt = DateTime.now();
            _connecting = false;
            _error = null;
          });
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!mounted || attempt != _attempt) return;
          // 会话已失败：12 秒“尚无画面”定时器不再适用，避免它覆盖错误态。
          _waitingTimer?.cancel();
          _waitingTimer = null;
          setState(() {
            _connecting = false;
            _error = _friendlyFarmCameraError(error);
          });
          if (_wakePendingError(error)) {
            _scheduleAutoRetry();
          } else {
            _stopAutoRetry();
          }
        },
      );
      _waitingTimer = Timer(const Duration(seconds: 12), () {
        if (!mounted ||
            attempt != _attempt ||
            _frame != null ||
            _error != null) {
          return;
        }
        _stopAutoRetry();
        setState(() {
          _connecting = false;
          _error = '已经连接打印机，但暂未收到画面。请确认摄像头可用，并检查是否有其他程序占用直播连接。';
        });
      });
    } on FarmCameraCertificateTrustRequired catch (approval) {
      if (!mounted || attempt != _attempt) return;
      _waitingTimer?.cancel();
      _waitingTimer = null;
      _stopAutoRetry();
      setState(() {
        _connecting = false;
        _certificateApproval = approval;
      });
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      _waitingTimer?.cancel();
      _waitingTimer = null;
      setState(() {
        _connecting = false;
        _error = _friendlyFarmCameraError(error);
      });
      if (_wakePendingError(error)) {
        _scheduleAutoRetry();
      } else {
        _stopAutoRetry();
      }
    }
  }

  Future<void> _trustCertificateAndReconnect() async {
    final approval = _certificateApproval;
    if (approval == null) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await PrinterCertificateTrustStore.trustFingerprint(
        serial: approval.config.serial,
        host: approval.config.host,
        service: PrinterTlsService.camera,
        fingerprint: approval.fingerprint,
      );
      if (mounted) await _connect();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _certificateApproval = null;
        _error = _friendlyFarmCameraError(error);
      });
    }
  }

  Future<void> _releaseSession() async {
    _waitingTimer?.cancel();
    _waitingTimer = null;
    if (_autoRetryTimer != null) {
      _autoRetryTimer?.cancel();
    }
    _autoRetryTimer = null;
    final subscription = _subscription;
    _subscription = null;
    final session = _session;
    _session = null;
    // Start listener cancellation and session disposal together, then let the
    // detached route finish both in the background. This ensures the decoder
    // receives its stop signal immediately without letting a slow native
    // shutdown block the modal close animation.
    try {
      await Future.wait<void>([
        if (subscription != null) subscription.cancel(),
        if (session != null) session.dispose(),
      ]);
    } catch (_) {
      // Disposal remains best-effort after the route is detached.
    }
  }

  void _close() {
    if (_closing) return;
    setState(() => _closing = true);
    ++_attempt;
    unawaited(_releaseSession());
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    ++_attempt;
    _waitingTimer?.cancel();
    _autoRetryTimer?.cancel();
    _autoRetryTimer = null;
    final subscription = _subscription;
    final session = _session;
    _subscription = null;
    _session = null;
    unawaited(subscription?.cancel());
    if (session != null) unawaited(session.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final frame = _frame;
    final bindingLabel = widget.config?.mode == BambuConnectionMode.cloud
        ? (widget.compact ? '云端 · TUTK P2P' : '拓竹云端模式 · TUTK P2P 远程')
        : (widget.compact ? '局域网 · LAN' : '拓竹局域网绑定 · LAN 直连');
    final accent = widget.compact ? scheme.primary : FarmVisual.primary;
    final radius = widget.compact ? 16.0 : 8.0;
    return Dialog(
      key: ValueKey(
        widget.compact
            ? 'printer-camera-preview-dialog'
            : 'farm-camera-preview-dialog',
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.compact ? 720 : 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                widget.compact ? 16 : 18,
                widget.compact ? 12 : 14,
                10,
                widget.compact ? 10 : 12,
              ),
              child: Row(
                children: [
                  Container(
                    width: widget.compact ? 34 : 38,
                    height: widget.compact ? 34 : 38,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(
                        widget.compact ? 10 : FarmPalette.radius,
                      ),
                    ),
                    child: Icon(
                      Icons.videocam_outlined,
                      color: accent,
                      size: widget.compact ? 19 : 22,
                    ),
                  ),
                  SizedBox(width: widget.compact ? 10 : 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.compact
                              ? widget.printerName
                              : '${widget.printerName} · 实时画面',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: widget.compact ? 16 : 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '${widget.model} · ${widget.serial ?? '无序列号'} · $bindingLabel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭实时画面',
                    onPressed: _closing ? null : _close,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: Colors.white.withValues(alpha: .12)),
              ),
              clipBehavior: Clip.antiAlias,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (frame != null)
                      Image.memory(
                        frame,
                        key: ValueKey(_lastFrameAt?.microsecondsSinceEpoch),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    if (frame == null) const ColoredBox(color: Colors.black),
                    if (_connecting)
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(
                              color: Colors.white,
                            ),
                            const SizedBox(height: 14),
                            Text(
                              widget.compact ? '正在连接…' : '正在连接打印机摄像头…',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    if (_certificateApproval != null && !_connecting)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.verified_user_outlined,
                                color: Colors.white70,
                                size: 36,
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                '首次连接，请确认打印机证书',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${_certificateApproval!.config.host}:${_certificateApproval!.config.port}\n'
                                'SHA-256 ${_formatFarmCameraFingerprint(_certificateApproval!.fingerprint)}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                ),
                              ),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                key: ValueKey(
                                  widget.compact
                                      ? 'printer-camera-trust-certificate'
                                      : 'farm-camera-trust-certificate',
                                ),
                                onPressed: _trustCertificateAndReconnect,
                                icon: const Icon(Icons.shield_outlined),
                                label: const Text('信任并连接'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_error != null &&
                        !_connecting &&
                        _certificateApproval == null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.videocam_off_outlined,
                                color: Colors.white70,
                                size: 38,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70),
                              ),
                              if (_autoRetryCount > 0 &&
                                  !_autoRetryStopped) ...[
                                const SizedBox(height: 8),
                                Text(
                                  '后台自动重试中（第 $_autoRetryCount 次）…'
                                  '唤醒后会自动出画面，无需点击按钮。',
                                  key: ValueKey(
                                    widget.compact
                                        ? 'printer-camera-auto-retry-note'
                                        : 'farm-camera-auto-retry-note',
                                  ),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                              ] else if (_autoRetryStopped) ...[
                                const SizedBox(height: 8),
                                Text(
                                  '已自动重试 $_autoRetryCount 次仍未出画面，'
                                  '已停止自动重试；可点击下方按钮手动重试。',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 14),
                              OutlinedButton.icon(
                                key: ValueKey(
                                  widget.compact
                                      ? 'printer-camera-retry'
                                      : 'farm-camera-retry',
                                ),
                                onPressed: _connect,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(color: Colors.white54),
                                ),
                                icon: const Icon(Icons.refresh_rounded),
                                label: Text(widget.compact ? '重试' : '重新连接'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (frame != null) ...[
                      Positioned(
                        left: 12,
                        top: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .58),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _FarmLiveDot(),
                              SizedBox(width: 6),
                              Text(
                                'LIVE',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        top: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .58),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '最近画面 ${_formatFarmCameraClock(_lastFrameAt)}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (widget.compact)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.link_rounded,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      bindingLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _closing ? null : _close,
                      child: Text(_closing ? '正在关闭…' : '关闭'),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 11, 18, 14),
                child: Row(
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        widget.config?.mode == BambuConnectionMode.cloud
                            ? '云端模式只通过拓竹账号获取 TTCode，并使用 TUTK P2P 远程取流；不会扫描局域网或使用 LAN 地址。内部预览不会计入客户占用状态。'
                            : '局域网模式只连接当前配置的 IP 和 Access Code；不会使用拓竹云账号或 TTCode。内部预览不会计入客户摄像头占用状态。',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _closing ? null : _close,
                      child: Text(_closing ? '正在关闭…' : '关闭'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FarmLiveDot extends StatelessWidget {
  const _FarmLiveDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(
        color: Color(0xFFE5484D),
        shape: BoxShape.circle,
      ),
    );
  }
}

String _friendlyFarmCameraError(Object error) {
  var value = error.toString().trim();
  for (final prefix in const ['Bad state: ', 'StateError: ']) {
    if (value.startsWith(prefix)) value = value.substring(prefix.length);
  }
  final normalized = value.toLowerCase();
  if (normalized.contains('sign_rejected')) {
    return '云端拒绝了摄像头唤醒请求（签名可能已轮换）。请先更新 Bambu '
        'Studio 官方插件后重试；或先在拓竹 App 或 Bambu Studio 中打开一次'
        '该打印机的摄像头唤醒设备，等待画面出现后回到这里点击“重新连接”。';
  }
  if (normalized.contains('need_official_wake') ||
      normalized.contains('wake wait timed out')) {
    return '打印机摄像头处于休眠，等待官方客户端唤醒超时。请先在拓竹 App 或 Bambu Studio 中打开一次该打印机的摄像头，待官方画面出现后回到这里点击“重新连接”，本软件会自动接管视频。';
  }
  if (normalized.contains('official network component timed out') ||
      (normalized.contains('远程摄像头数据流意外结束') &&
          (normalized.contains('tutk') || normalized.contains('云端')))) {
    return '打印机摄像头当前处于休眠状态，拓竹云端未能唤醒。请先在拓竹 App 或 Bambu Studio 中打开一次该打印机的摄像头，等待画面出现后回到这里点击“重新连接”。';
  }
  return value.isEmpty ? '无法连接打印机摄像头' : value;
}

String _formatFarmCameraClock(DateTime? value) {
  if (value == null) return '--:--:--';
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

String _formatFarmCameraFingerprint(String value) {
  final normalized =
      value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  return RegExp(r'.{1,2}')
      .allMatches(normalized)
      .map((match) => match.group(0))
      .join(':');
}
