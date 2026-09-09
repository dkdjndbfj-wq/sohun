import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/friendly_error.dart';
import '../../data/external/printer/bambu_lan_discovery.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/seed/printer_seed.dart';
import '../../providers/printer_connection_provider.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_printer_certificate_trust_dialog.dart';

typedef FarmLanDiscover = Future<List<DiscoveredBambuPrinter>> Function({
  void Function(String phase, int progress, int total)? onProgress,
  LanScanCancellationToken? cancellationToken,
  bool forceRefresh,
});

typedef FarmBatchCertificateTrust = Future<bool> Function(
  BuildContext context,
  Iterable<PrinterConnectionConfig> configs,
);

Future<int> showFarmLanBulkImportDialog(
  BuildContext context,
  WidgetRef ref, {
  FarmLanDiscover discover = BambuLanDiscovery.discover,
  FarmBatchCertificateTrust confirmTrust = confirmPrinterCertificatesTrust,
}) async {
  final count = await showDialog<int>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _FarmLanBulkImportDialog(
          discover: discover,
          confirmTrust: confirmTrust,
        ),
      ) ??
      0;
  if (count > 0 && context.mounted) {
    showSnack(context, '已批量添加 $count 台局域网打印机');
  }
  return count;
}

class _FarmLanBulkImportDialog extends ConsumerStatefulWidget {
  const _FarmLanBulkImportDialog({
    required this.discover,
    required this.confirmTrust,
  });

  final FarmLanDiscover discover;
  final FarmBatchCertificateTrust confirmTrust;

  @override
  ConsumerState<_FarmLanBulkImportDialog> createState() =>
      _FarmLanBulkImportDialogState();
}

class _FarmLanBulkImportDialogState
    extends ConsumerState<_FarmLanBulkImportDialog> {
  static final _bambuModels = PrinterPresets.all
      .where((preset) => preset.isBambu)
      .toList(growable: false);

  final List<_LanPrinterDraft> _drafts = [];
  LanScanCancellationToken? _scanToken;
  bool _scanning = false;
  bool _saving = false;
  String _scanStatus = '';
  String? _scanError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  @override
  void dispose() {
    _scanToken?.cancel();
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _scan() async {
    if (_scanning || _saving) return;
    final token = LanScanCancellationToken();
    _scanToken = token;
    setState(() {
      _scanning = true;
      _scanError = null;
      _scanStatus = '正在发现打印机…';
    });
    try {
      final results = await widget.discover(
        forceRefresh: true,
        cancellationToken: token,
        onProgress: (phase, progress, total) {
          if (!mounted || token.isCancelled) return;
          setState(() {
            _scanStatus = total > 0 ? '$phase · $progress/$total' : phase;
          });
        },
      );
      if (!mounted || token.isCancelled) return;
      final connectionNotifier =
          ref.read(printerConnectionListProvider.notifier);
      await connectionNotifier.ready;
      if (!mounted || token.isCancelled) return;
      final configured = ref.read(printerConnectionListProvider);
      for (final draft in _drafts) {
        draft.dispose();
      }
      _drafts
        ..clear()
        ..addAll(
          results.map((printer) {
            final existing = _findExistingConfig(configured, printer);
            final preset = _inferModel(printer);
            return _LanPrinterDraft(
              printer: printer,
              existingConfig: existing,
              selected: existing == null ||
                  (printer.serial != null &&
                      existing.host.trim() != printer.ip.trim()),
              model: existing?.devProductName ?? preset?.model,
            );
          }),
        );
      setState(() {
        _scanStatus = results.isEmpty
            ? '没有发现局域网打印机'
            : '发现 ${results.length} 台，已自动勾选未添加设备';
      });
    } catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _scanError = friendlyError(error);
        _scanStatus = '扫描失败';
      });
    } finally {
      if (mounted) setState(() => _scanning = false);
      if (identical(_scanToken, token)) _scanToken = null;
    }
  }

  Future<void> _requestRescan() async {
    final hasUnsavedInput = _drafts.any(
      (draft) => draft.manual || draft.accessCode.text.trim().isNotEmpty,
    );
    if (hasUnsavedInput) {
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('重新扫描局域网？'),
              content: const Text('重新扫描会清空当前尚未添加的序列号、名称和 Access Code。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('保留当前内容'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('清空并重新扫描'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !mounted) return;
    }
    await _scan();
  }

  void _addManualDraft() {
    setState(() {
      _drafts.add(_LanPrinterDraft.manual());
      _scanStatus = '可继续选择扫描结果，或填写手动添加设备';
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _drafts.where((draft) => draft.selected).toList();
    final selectedCount = selected.length;
    final updateCount = selected.where((draft) => draft.existing).length;
    final addCount = selectedCount - updateCount;
    final saveLabel = switch ((addCount, updateCount)) {
      (final additions, 0) => '批量添加 $additions 台',
      (0, final updates) => '批量更新 $updates 台',
      _ => '批量保存 $selectedCount 台（新增 $addCount / 更新 $updateCount）',
    };
    return AlertDialog(
      title: const Text('一键扫描并批量添加打印机'),
      content: SizedBox(
        width: 760,
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '扫描同时使用 mDNS 和 MQTT 端口验证。勾选需要加入的设备，分别填写局域网 Access Code；凭据会使用 Windows DPAPI 加密保存。',
                style: TextStyle(fontSize: 12, height: 1.45),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (_scanning)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    _scanError == null
                        ? Icons.radar_outlined
                        : Icons.error_outline,
                    size: 18,
                  ),
                const SizedBox(width: 8),
                Expanded(child: Text(_scanStatus)),
                TextButton.icon(
                  onPressed: _scanning || _saving ? null : _addManualDraft,
                  icon: const Icon(Icons.add_outlined, size: 17),
                  label: const Text('手动添加'),
                ),
                TextButton.icon(
                  onPressed: _scanning || _saving ? null : _requestRescan,
                  icon: const Icon(Icons.refresh_outlined, size: 17),
                  label: const Text('重新扫描'),
                ),
              ],
            ),
            if (_scanError != null)
              Text(
                _scanError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            const Divider(),
            Expanded(
              child: _drafts.isEmpty
                  ? _ScanEmptyState(scanning: _scanning)
                  : ListView.separated(
                      itemCount: _drafts.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, index) => _buildDraft(_drafts[index]),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : () {
                  _scanToken?.cancel();
                  Navigator.of(context).pop(0);
                },
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _saving || _scanning || selectedCount == 0 ? null : _save,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.playlist_add_check_outlined),
          label: Text(saveLabel),
        ),
      ],
    );
  }

  Widget _buildDraft(_LanPrinterDraft draft) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: draft.selected
            ? scheme.primary.withValues(alpha: 0.06)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: draft.selected ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Checkbox(
                value: draft.selected,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => draft.selected = value == true),
              ),
              const Icon(Icons.precision_manufacturing_outlined, size: 21),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      draft.label,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${draft.host.text.isEmpty ? 'IP 待填写' : '${draft.host.text}:${draft.printer.port}'} · '
                      '${draft.manual ? '手动添加' : draft.printer.source == 'mdns' ? 'mDNS' : '端口扫描'}',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (draft.existing)
                Chip(
                  avatar: Icon(
                    draft.selected ? Icons.update_rounded : Icons.check_rounded,
                    size: 15,
                  ),
                  label: Text(draft.selected ? '待更新' : '已添加'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          if (draft.selected) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: draft.name,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: '设备名称（可选）',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: draft.model,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '机型',
                      isDense: true,
                    ),
                    items: [
                      for (final preset in _bambuModels)
                        DropdownMenuItem(
                          value: preset.model,
                          child: Text(
                            preset.model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() => draft.model = value),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 128,
                  child: DropdownButtonFormField<double>(
                    initialValue: draft.nozzleDiameter,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '喷嘴',
                      hintText: '未知',
                      isDense: true,
                    ),
                    items: const [0.2, 0.4, 0.6, 0.8]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(
                              '${value.toStringAsFixed(1)} mm',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      setState(() => draft.nozzleDiameter = value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: draft.host,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'IP 地址',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: draft.serial,
                    decoration: const InputDecoration(
                      labelText: '序列号 SN',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: draft.accessCode,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Access Code',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _save() async {
    final selected = _drafts.where((draft) => draft.selected).toList();
    final serials = <String>{};
    final hosts = <String>{};
    for (final draft in selected) {
      final serial = draft.serial.text.trim().toUpperCase();
      final host = draft.host.text.trim();
      final accessCode = draft.accessCode.text.trim();
      if (draft.model == null ||
          host.isEmpty ||
          serial.isEmpty ||
          accessCode.isEmpty) {
        showSnack(
          context,
          '请为每台勾选设备填写机型、IP、序列号和 Access Code',
          error: true,
        );
        return;
      }
      if (serial.length < 6) {
        showSnack(context, '${draft.label} 的序列号格式不完整', error: true);
        return;
      }
      if (!_isValidIpv4(host)) {
        showSnack(context, '${draft.label} 的局域网 IP 格式不正确', error: true);
        return;
      }
      if (!RegExp(r'^[A-Za-z0-9]{8,32}$').hasMatch(accessCode)) {
        showSnack(
          context,
          '${draft.label} 的 Access Code 应为 8-32 位字母或数字',
          error: true,
        );
        return;
      }
      if (!serials.add(serial)) {
        showSnack(context, '批次内存在重复序列号：$serial', error: true);
        return;
      }
      if (!hosts.add(host)) {
        showSnack(context, '批次内存在重复 IP：$host', error: true);
        return;
      }
    }

    final configs = [
      for (final draft in selected)
        PrinterConnectionConfig(
          serial: draft.serial.text.trim().toUpperCase(),
          host: draft.host.text.trim(),
          accessCode: draft.accessCode.text.trim(),
          port: draft.printer.port,
          devProductName: draft.model,
          installedNozzleDiameter: draft.nozzleDiameter,
          displayName:
              draft.name.text.trim().isEmpty ? null : draft.name.text.trim(),
        ),
    ];
    setState(() => _saving = true);
    try {
      if (!await widget.confirmTrust(context, configs)) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      await ref.read(printerConnectionListProvider.notifier).addAll(configs);
      if (mounted) Navigator.of(context).pop(configs.length);
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(
          context,
          '批量添加失败：${friendlyError(error)}',
          error: true,
        );
      }
    }
  }

  static PrinterPreset? _inferModel(DiscoveredBambuPrinter printer) {
    final source =
        '${printer.deviceName} ${printer.instanceName}'.toUpperCase();
    final ordered = _bambuModels.toList()
      ..sort((a, b) => b.model.length.compareTo(a.model.length));
    for (final preset in ordered) {
      final aliases = <String>{preset.model.toUpperCase()};
      if (preset.model == 'A1mini') aliases.addAll({'A1 MINI', 'A1MINI'});
      if (aliases.any(source.contains)) return preset;
    }
    return null;
  }

  static PrinterConnectionConfig? _findExistingConfig(
    Iterable<PrinterConnectionConfig> configured,
    DiscoveredBambuPrinter printer,
  ) {
    final serial = printer.serial?.trim().toUpperCase();
    if (serial != null && serial.isNotEmpty) {
      for (final config in configured) {
        if (config.serial.trim().toUpperCase() == serial) return config;
      }
    }
    final host = printer.ip.trim();
    for (final config in configured) {
      if (host.isNotEmpty && config.host.trim() == host) return config;
    }
    return null;
  }

  static bool _isValidIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      final number = int.tryParse(part);
      return number != null && number >= 0 && number <= 255;
    });
  }
}

class _LanPrinterDraft {
  _LanPrinterDraft({
    required this.printer,
    required this.existingConfig,
    required this.selected,
    required this.model,
  })  : host = TextEditingController(text: printer.ip),
        name = TextEditingController(
          text: existingConfig?.displayName ?? printer.deviceName,
        ),
        serial = TextEditingController(
          text: printer.serial ?? existingConfig?.serial ?? '',
        ),
        accessCode = TextEditingController(
          text: existingConfig?.accessCode ?? '',
        ),
        nozzleDiameter = existingConfig?.installedNozzleDiameter;

  factory _LanPrinterDraft.manual() {
    return _LanPrinterDraft(
      printer: const DiscoveredBambuPrinter(
        ip: '',
        port: 8883,
        instanceName: '手动添加打印机',
        source: 'manual',
      ),
      existingConfig: null,
      selected: true,
      model: null,
    )..manual = true;
  }

  final DiscoveredBambuPrinter printer;
  final PrinterConnectionConfig? existingConfig;
  final TextEditingController host;
  final TextEditingController name;
  final TextEditingController serial;
  final TextEditingController accessCode;
  bool selected;
  bool manual = false;
  String? model;
  double? nozzleDiameter;

  bool get existing => existingConfig != null;

  String get label {
    if (name.text.trim().isNotEmpty) return name.text.trim();
    if (printer.deviceName.trim().isNotEmpty) return printer.deviceName.trim();
    if (printer.instanceName.trim().isNotEmpty) return printer.instanceName;
    return printer.ip;
  }

  void dispose() {
    host.dispose();
    name.dispose();
    serial.dispose();
    accessCode.dispose();
  }
}

class _ScanEmptyState extends StatelessWidget {
  const _ScanEmptyState({required this.scanning});

  final bool scanning;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            scanning ? Icons.radar_outlined : Icons.router_outlined,
            size: 42,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 10),
          Text(scanning ? '正在扫描局域网' : '没有发现可添加的打印机'),
          const SizedBox(height: 5),
          Text(
            '请确认打印机已开启局域网访问，并与电脑位于同一网络。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
