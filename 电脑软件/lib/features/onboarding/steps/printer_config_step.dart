import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/external/printer/bambu_lan_discovery.dart';
import '../../../data/external/printer/bambu_printer_connector.dart';
import '../../../data/external/printer/bambu_printer_models.dart';
import '../../../data/seed/printer_seed.dart';
import '../../../providers/onboarding_provider.dart';
import '../../printers/printer_certificate_trust_dialog.dart';

/// 步骤4：配置打印机。
///
/// 将步骤3扫描到的打印机展示为可勾选卡片，勾选后展开配置区：
/// 名称 / 物理供料布局 / Access Code（云端匹配则自动填入）/ 测试连接。
/// 支持手动添加一台（填 IP / Access Code）。
class PrinterConfigStep extends ConsumerStatefulWidget {
  const PrinterConfigStep({super.key});

  @override
  ConsumerState<PrinterConfigStep> createState() => _PrinterConfigStepState();
}

class _PrinterConfigStepState extends ConsumerState<PrinterConfigStep> {
  /// 所有待配置的打印机条目（扫描到的 + 手动添加的）。
  final List<_PrinterEntry> _entries = [];
  int _manualSeq = 0;
  bool _synced = false;

  @override
  void initState() {
    super.initState();
    // 在首帧后用 ref 初始化条目（含预填）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _initEntries());
  }

  void _initEntries() {
    if (_synced) return;
    final state = ref.read(onboardingProvider);
    final scanned = state.scannedPrinters;
    final configured = state.configuredPrinters;

    for (final p in scanned) {
      final key = 'scan_${p.ip}_${p.port}';
      // 预填：若已配置过则勾选
      PrinterConnectionConfig? existing;
      for (final c in configured) {
        if (c.host == p.ip) {
          existing = c;
          break;
        }
      }
      // 云端匹配 access code
      String accessCode = '';
      bool auto = false;
      String? devProductName;
      double? nozzleDiameter;
      for (final cd in state.cloudDevices) {
        if (p.matches(cd.devId)) {
          accessCode = cd.devAccessCode;
          auto = true;
          devProductName = cd.devProductName;
          nozzleDiameter = cd.nozzleDiameter;
          break;
        }
      }
      // 预填的 config 优先
      if (existing != null && existing.accessCode.isNotEmpty) {
        accessCode = existing.accessCode;
      }
      _entries.add(
        _PrinterEntry(
          key: key,
          discovered: p,
          ip: p.ip,
          port: p.port,
          serial: p.serial ?? '',
          selected: existing != null,
          name: existing?.displayName ??
              (p.deviceName.isNotEmpty ? p.deviceName : p.instanceName),
          accessCode: accessCode,
          autoAccessCode: auto,
          devProductName: devProductName ?? existing?.devProductName,
          nozzleDiameter: nozzleDiameter ?? existing?.installedNozzleDiameter,
        ),
      );
    }

    // 若扫描为空但已有配置（重新运行），补回手动条目
    if (scanned.isEmpty && configured.isNotEmpty) {
      for (final c in configured) {
        _manualSeq++;
        _entries.add(
          _PrinterEntry(
            key: 'manual_restore_$_manualSeq',
            discovered: null,
            ip: c.host,
            port: c.port,
            serial: c.serial,
            selected: true,
            name: c.displayName ?? c.devProductName ?? c.host,
            accessCode: c.accessCode,
            autoAccessCode: false,
            devProductName: c.devProductName,
            nozzleDiameter: c.installedNozzleDiameter,
          ),
        );
      }
    }

    _synced = true;
    if (mounted) setState(() {});
  }

  /// 把所有勾选的条目同步到 OnboardingState。
  void _syncToProvider() {
    final list = <PrinterConnectionConfig>[];
    for (final e in _entries) {
      if (!e.selected) continue;
      final serial = e.serial.isNotEmpty ? e.serial : e.ip;
      list.add(
        PrinterConnectionConfig.lan(
          serial: serial,
          host: e.ip,
          accessCode: e.accessCode,
          devProductName: e.devProductName,
          installedNozzleDiameter: e.nozzleDiameter,
          displayName: e.name,
        ),
      );
    }
    ref.read(onboardingProvider.notifier).setConfiguredPrinters(list);
  }

  Future<void> _testConnection(_PrinterEntry e) async {
    setState(() {
      e.testResult = _TestStatus.testing;
      e.testFailReason = null;
    });
    final config = PrinterConnectionConfig.lan(
      serial: e.serial.isNotEmpty ? e.serial : e.ip,
      host: e.ip,
      accessCode: e.accessCode,
      devProductName: e.devProductName,
      installedNozzleDiameter: e.nozzleDiameter,
      displayName: e.name,
      port: e.port,
    );
    if (!await confirmPrinterCertificateTrust(context, config)) {
      if (!mounted) return;
      setState(() {
        e.testResult = _TestStatus.fail;
        e.testFailReason = '未确认打印机证书';
      });
      return;
    }
    if (!mounted) return;
    final connector = BambuPrinterConnector(config);
    try {
      final ok = await connector.connect().timeout(
            const Duration(seconds: 8),
            onTimeout: () => false,
          );
      if (ok) {
        await connector.disconnect();
      }
      await connector.dispose();
      if (!mounted) return;
      setState(() {
        e.testResult = ok ? _TestStatus.success : _TestStatus.fail;
        e.testFailReason = ok ? null : '连接被拒绝或超时';
      });
    } catch (ex) {
      try {
        await connector.dispose();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        e.testResult = _TestStatus.fail;
        e.testFailReason = ex.toString();
      });
    }
  }

  Future<void> _addManual() async {
    final result = await showDialog<_ManualResult>(
      context: context,
      builder: (ctx) => const _ManualAddDialog(),
    );
    if (result == null) return;
    _manualSeq++;
    setState(() {
      _entries.add(
        _PrinterEntry(
          key: 'manual_$_manualSeq',
          discovered: null,
          ip: result.ip,
          port: 8883,
          serial: '',
          selected: true,
          name: result.name.isEmpty ? result.ip : result.name,
          accessCode: result.accessCode,
          autoAccessCode: false,
        ),
      );
    });
    _syncToProvider();
  }

  @override
  Widget build(BuildContext context) {
    if (!_synced) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '配置打印机',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '勾选要添加的打印机，自动填入的 Access Code 来自拓竹账号。可手动添加或测试连接。',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        if (_entries.isEmpty)
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
                    '未发现打印机，可手动添加一台。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          ..._entries.map((e) => _buildEntryCard(e)),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addManual,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('手动添加一台'),
          ),
        ),
      ],
    );
  }

  Widget _buildEntryCard(_PrinterEntry e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(
          color: e.selected
              ? AppColors.primary
              : Theme.of(context).colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
      ),
      child: Column(
        children: [
          // 勾选行
          InkWell(
            onTap: () {
              setState(() => e.selected = !e.selected);
              _syncToProvider();
            },
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppColors.radiusMd),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    e.selected
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    color: e.selected
                        ? AppColors.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.print_rounded, color: AppColors.primary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${e.ip}:${e.port}${e.serial.isNotEmpty ? "  ·  SN: ${e.serial}" : ""}',
                          style: TextStyle(
                            fontSize: 11,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (e.devProductName != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary50,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        e.devProductName!,
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 展开配置区
          if (e.selected) ...[
            Divider(
              height: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 名称
                  _LabelField(
                    label: '名称',
                    child: TextField(
                      controller: TextEditingController(text: e.name)
                        ..selection = TextSelection.fromPosition(
                          TextPosition(offset: e.name.length),
                        ),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 13),
                      onChanged: (v) {
                        e.name = v;
                        _syncToProvider();
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 供料位由机型能力和实时 MQTT 共同决定，不能手工压成 A/B/C/D。
                  _LabelField(
                    label: '供料布局',
                    hint: '外挂料位与 AMS 分开管理；连接后会按打印机实际上报自动校准。',
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.cable_rounded,
                            size: 16,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _feedLayoutSummary(e),
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurface,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Access Code
                  _LabelField(
                    label: 'LAN Access Code',
                    hint: !e.autoAccessCode
                        ? '打印机屏幕：设置 → 网络 → WLAN → 局域网访问码（8位数字）'
                        : null,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller:
                                TextEditingController(text: e.accessCode),
                            enabled: !e.autoAccessCode,
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              border: const OutlineInputBorder(),
                              suffix: e.autoAccessCode
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppColors.successContainer,
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: const Text(
                                        '自动',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: AppColors.success,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    )
                                  : null,
                            ),
                            style: TextStyle(
                              fontSize: 13,
                              color: e.autoAccessCode
                                  ? Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant
                                  : Theme.of(context).colorScheme.onSurface,
                            ),
                            onChanged: (v) {
                              e.accessCode = v;
                              _syncToProvider();
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        _TestButton(
                          entry: e,
                          onPressed: () => _testConnection(e),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _feedLayoutSummary(_PrinterEntry entry) {
    final model = entry.devProductName?.trim() ?? '';
    final preset = model.isEmpty ? null : PrinterPresets.findByModel(model);
    if (preset == null) {
      return '机型待识别 · 暂按单外挂料位显示，连接后自动识别双外挂与 AMS';
    }
    final external = preset.externalInputCount == 2 ? '左右双外挂料位' : '单外挂料位';
    if (!preset.supportsAms) return external;
    if (preset.externalExclusiveWithAms) {
      return '$external · AMS 与外挂共用进料路径，打印时选择其中一种来源';
    }
    return '$external · 按 AMS 实际连接判断可用外挂，左右喷头分别校验';
  }
}

/// 测试连接按钮，展示测试状态。
class _TestButton extends StatelessWidget {
  final _PrinterEntry entry;
  final VoidCallback onPressed;
  const _TestButton({required this.entry, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final st = entry.testResult;
    Widget content;
    if (st == _TestStatus.testing) {
      content = const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (st == _TestStatus.success) {
      content = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, color: AppColors.success, size: 16),
          SizedBox(width: 4),
          Text(
            '成功',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.success,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    } else if (st == _TestStatus.fail) {
      content = Tooltip(
        message: entry.testFailReason ?? '连接失败',
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cancel_rounded, color: AppColors.danger, size: 16),
            SizedBox(width: 4),
            Text(
              '失败',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    } else {
      content = const Text('测试连接', style: TextStyle(fontSize: 12));
    }
    return OutlinedButton(
      onPressed: st == _TestStatus.testing ? null : onPressed,
      child: content,
    );
  }
}

/// 标签 + 字段 的纵向小组件。
class _LabelField extends StatelessWidget {
  final String label;
  final Widget child;

  /// 可选的提示文案，展示在 label 下方、字段上方（小字）。
  final String? hint;
  const _LabelField({required this.label, required this.child, this.hint});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 2),
          Text(
            hint!,
            style: TextStyle(
              fontSize: 10,
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

/// 手动添加打印机对话框。
class _ManualAddDialog extends StatefulWidget {
  const _ManualAddDialog();

  @override
  State<_ManualAddDialog> createState() => _ManualAddDialogState();
}

class _ManualAddDialogState extends State<_ManualAddDialog> {
  final _nameCtrl = TextEditingController();
  final _ipCtrl = TextEditingController();
  final _accessCtrl = TextEditingController();
  String? _ipError;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ipCtrl.dispose();
    _accessCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        '手动添加打印机',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '名称（可选）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ipCtrl,
              decoration: InputDecoration(
                labelText: 'IP 地址',
                isDense: true,
                border: const OutlineInputBorder(),
                errorText: _ipError,
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _accessCtrl,
              decoration: const InputDecoration(
                labelText: 'Access Code',
                hintText: '打印机屏幕：设置 → 网络 → WLAN → 局域网访问码（8位数字）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 16,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '供料布局将在连接后自动识别：单/双外挂料位、AMS 数量、代际与通道都会分别建立。',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final ip = _ipCtrl.text.trim();
            if (ip.isEmpty) {
              setState(() => _ipError = '请输入 IP 地址');
              return;
            }
            Navigator.pop(
              context,
              _ManualResult(
                name: _nameCtrl.text.trim(),
                ip: ip,
                accessCode: _accessCtrl.text.trim(),
              ),
            );
          },
          child: const Text('添加'),
        ),
      ],
    );
  }
}

class _ManualResult {
  final String name;
  final String ip;
  final String accessCode;
  _ManualResult({
    required this.name,
    required this.ip,
    required this.accessCode,
  });
}

/// 单台打印机的配置状态。
class _PrinterEntry {
  final String key;
  final DiscoveredBambuPrinter? discovered;
  final String ip;
  final int port;
  final String serial;
  bool selected;
  String name;
  String accessCode;
  final bool autoAccessCode;
  final String? devProductName;
  final double? nozzleDiameter;
  _TestStatus? testResult;
  String? testFailReason;

  _PrinterEntry({
    required this.key,
    required this.discovered,
    required this.ip,
    required this.port,
    required this.serial,
    required this.selected,
    required this.name,
    required this.accessCode,
    required this.autoAccessCode,
    this.devProductName,
    this.nozzleDiameter,
  });
}

/// 测试连接结果状态。
enum _TestStatus { testing, success, fail }
