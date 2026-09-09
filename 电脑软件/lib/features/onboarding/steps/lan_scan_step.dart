import 'package:flutter/material.dart';
import '../../../core/theme/glass_button_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/external/printer/bambu_lan_discovery.dart';
import '../../../providers/onboarding_provider.dart';

/// 步骤3：扫描局域网拓竹打印机。复用 BambuLanDiscovery.discover()。
///
/// 双模式发现：mDNS（首选）+ IP 段端口扫描 8883（备用）。
/// 端口扫描会做 MQTT TLS 握手验证，排除非 MQTT 服务误报。
/// 扫描结果缓存 5 分钟，避免短时间内重复扫描。
class LanScanStep extends ConsumerStatefulWidget {
  const LanScanStep({super.key});
  @override
  ConsumerState<LanScanStep> createState() => _LanScanStepState();
}

class _LanScanStepState extends ConsumerState<LanScanStep> {
  bool _isScanning = false;
  List<DiscoveredBambuPrinter> _results = [];
  String? _error;
  String _scanPhase = '';
  int _scanProgress = 0;
  int _scanTotal = 0;
  bool _cancelled = false;
  LanScanCancellationToken? _token;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    // 若已有缓存，直接命中（discover 内部会处理），强制刷新时清缓存
    final token = LanScanCancellationToken();
    _token = token;
    setState(() {
      _isScanning = true;
      _error = null;
      _results = [];
      _scanPhase = '';
      _scanProgress = 0;
      _scanTotal = 0;
      _cancelled = false;
    });
    try {
      final printers = await BambuLanDiscovery.discover(
        forceRefresh: true,
        cancellationToken: token,
        onProgress: (phase, progress, total) {
          if (!mounted) return;
          setState(() {
            _scanPhase = phase;
            _scanProgress = progress;
            _scanTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _results = printers;
        _isScanning = false;
      });
      if (!_cancelled) {
        ref.read(onboardingProvider.notifier).setScannedPrinters(printers);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '扫描失败：${friendlyError(e)}';
        _isScanning = false;
      });
    }
  }

  void _cancelScan() {
    _token?.cancel();
    setState(() {
      _cancelled = true;
      _isScanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '扫描局域网内的拓竹打印机',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '请让电脑和打印机连接同一个网络，然后开始扫描。也可以跳过，稍后手动添加。',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            if (_isScanning)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(Icons.wifi_rounded, color: AppColors.primary, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _cancelled
                    ? '已取消扫描'
                    : _isScanning
                    ? _scanPhase == 'portscan'
                          ? (_scanTotal > 0
                                ? '端口扫描中... $_scanProgress/$_scanTotal'
                                : '端口扫描中...')
                          : '正在扫描...'
                    : _results.isEmpty
                    ? '未发现打印机'
                    : '发现 ${_results.length} 台打印机',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_isScanning)
              TextButton.icon(
                onPressed: _cancelScan,
                icon: const Icon(Icons.cancel_rounded, size: 16),
                label: const Text('取消'),
                style: glassButtonStyle(
                  context,
                  TextButton.styleFrom(foregroundColor: AppColors.danger),
                  variant: AppGlassButtonVariant.quiet,
                ),
              )
            else
              TextButton.icon(
                onPressed: _scan,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重新扫描'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.dangerContainer,
              borderRadius: BorderRadius.circular(AppColors.radiusMd),
            ),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: AppColors.danger),
            ),
          )
        else if (_cancelled && _results.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppColors.radiusMd),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.cancel_outlined,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '扫描已取消。可重新扫描或直接进入下一步手动添加。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (_results.isEmpty && !_isScanning)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppColors.radiusMd),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '未发现打印机。请确认打印机和电脑在同一 WiFi，且打印机已开启「局域网访问」模式。可在下一步手动添加。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          ..._results.map(
            (p) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(AppColors.radiusMd),
              ),
              child: Row(
                children: [
                  Icon(Icons.print_rounded, color: AppColors.primary, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.deviceName.isNotEmpty
                              ? p.deviceName
                              : p.instanceName,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${p.ip}:${p.port}${p.serial != null ? "  ·  SN: ${p.serial}" : ""}  ·  ${p.source == "mdns" ? "mDNS" : "端口扫描(已验证)"}',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          '提示：若仍未发现，请确认打印机已开启「局域网访问」模式（打印机屏幕 → 设置 → 网络 → WLAN → 局域网访问），且与电脑在同一 WiFi。端口扫描结果已通过 MQTT 协议握手验证，可放心选用。',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
