import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/printer_fault_monitor.dart';
import '../../core/services/printer_fault_sync_service.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/printer_fault.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/glass_card.dart';

class PrinterFaultCard extends StatelessWidget {
  final PrinterFaultRecord fault;
  final VoidCallback? onRead;
  const PrinterFaultCard({super.key, required this.fault, this.onRead});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = !fault.active
        ? theme.colorScheme.primary
        : fault.severity == 'error'
        ? theme.colorScheme.error
        : Colors.orange.shade700;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .06),
        border: Border.all(color: color.withValues(alpha: .22)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                fault.active
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline,
                color: color,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  fault.printerName,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                !fault.active
                    ? '已解除'
                    : fault.readAt == null
                    ? '待查看'
                    : '仍在报警',
                style: TextStyle(color: color, fontSize: 12),
              ),
            ],
          ),
          if (fault.model.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(fault.model, style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 12),
          SelectableText(
            fault.message,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
          ),
          const SizedBox(height: 12),
          SelectableText(
            '${fault.kind == 'hms' ? 'HMS' : '错误码'}  ${fault.code}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: [AppTypography.chineseFontFamily],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${fault.source == 'bambu-official' ? '拓竹官方提示' : '设备报告 · 尚无匹配的官方说明'}'
            ' · ${DateFormat('MM-dd HH:mm').format(fault.firstSeenAt.toLocal())}',
            style: theme.textTheme.bodySmall,
          ),
          if (fault.active)
            Text(
              '最近收到 ${DateFormat('HH:mm:ss').format(fault.lastSeenAt.toLocal())}',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              if (_officialUri(fault.helpUrl) case final uri?)
                TextButton.icon(
                  onPressed: () async {
                    var opened = false;
                    try {
                      opened = await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    } catch (_) {}
                    if (!opened && context.mounted)
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        const SnackBar(
                          content: Text('无法打开浏览器，请复制故障信息后查询拓竹 Wiki'),
                        ),
                      );
                  },
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('官方处理说明'),
                ),
              TextButton.icon(
                onPressed: () => Clipboard.setData(
                  ClipboardData(
                    text:
                        '${fault.printerName}\n${fault.code}\n${fault.message}\n${fault.helpUrl ?? ''}',
                  ),
                ),
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('复制'),
              ),
              if (onRead != null && fault.readAt == null)
                TextButton(onPressed: onRead, child: const Text('标为已读')),
            ],
          ),
        ],
      ),
    );
  }
}

Uri? _officialUri(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  return uri != null &&
          uri.scheme == 'https' &&
          uri.userInfo.isEmpty &&
          {'e.bambulab.com', 'wiki.bambulab.com'}.contains(uri.host)
      ? uri
      : null;
}

class PrinterFaultBell extends ConsumerWidget {
  const PrinterFaultBell({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(printerFaultMonitorProvider).active.length;
    return IconButton(
      tooltip: '打印机故障中心',
      onPressed: () => showPrinterFaultCenter(context),
      iconSize: 19,
      icon: Badge(
        isLabelVisible: active > 0,
        label: Text('$active'),
        child: const Icon(Icons.notifications_none_rounded),
      ),
    );
  }
}

Future<void> showPrinterFaultCenter(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    backgroundColor: Colors.transparent,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
      child: GlassCard(
        level: GlassLevel.l3,
        padding: const EdgeInsets.all(24),
        borderRadius: BorderRadius.circular(22),
        child: const _DesktopFaultCenter(),
      ),
    ),
  ),
);

class _DesktopFaultCenter extends ConsumerStatefulWidget {
  const _DesktopFaultCenter();
  @override
  ConsumerState<_DesktopFaultCenter> createState() =>
      _DesktopFaultCenterState();
}

class _DesktopFaultCenterState extends ConsumerState<_DesktopFaultCenter> {
  bool _history = false;
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final monitor = ref.watch(printerFaultMonitorProvider);
    final records = (_history ? monitor.records : monitor.active)
        .where(
          (r) => '${r.printerName} ${r.model} ${r.code} ${r.message}'
              .toLowerCase()
              .contains(_query.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '打印机故障中心',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              onPressed: () => Navigator.pop(context),
              tooltip: '关闭',
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('已读仅关闭提醒；设备明确清除故障后才会显示“已解除”。'),
        const SizedBox(height: 6),
        Text(
          ref.watch(printerFaultSyncStatusProvider) ??
              '登录同一 sohun 账号后，可在手机“打印提醒”中查看。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        TextField(
          onChanged: (v) => setState(() => _query = v),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '搜索机器、故障码或故障内容',
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              labelStyle: Theme.of(context).textTheme.labelLarge,
              label: Text('当前故障 ${monitor.active.length}'),
              selected: !_history,
              onSelected: (_) => setState(() => _history = false),
            ),
            ChoiceChip(
              labelStyle: Theme.of(context).textTheme.labelLarge,
              label: const Text('故障历史'),
              selected: _history,
              onSelected: (_) => setState(() => _history = true),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: records.isEmpty
              ? const Center(child: Text('没有符合条件的故障记录'))
              : ListView.builder(
                  itemCount: records.length,
                  itemBuilder: (_, i) => PrinterFaultCard(
                    fault: records[i],
                    onRead: () => ref
                        .read(printerFaultMonitorProvider.notifier)
                        .markRead([records[i].eventId]),
                  ),
                ),
        ),
      ],
    );
  }
}

Future<void> showPrinterFaultPopup(BuildContext context, Set<String> ids) =>
    AppDialog.show<void>(
      context: context,
      title: '打印机需要处理',
      barrierDismissible: false,
      content: Consumer(
        builder: (context, ref, _) {
          final records = ref
              .watch(printerFaultMonitorProvider)
              .records
              .where((r) => ids.contains(r.eventId));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final record in records) PrinterFaultCard(fault: record),
              const Text('关闭提醒不会恢复打印，也不会清除设备故障。'),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
