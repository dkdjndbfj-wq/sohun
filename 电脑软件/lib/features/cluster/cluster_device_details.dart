import 'package:flutter/material.dart';

import '../../core/constants/personal_spool_policy.dart';
import '../../core/services/cluster_planning_service.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_connector.dart';
import 'cluster_observation.dart';

/// A read-only, scoped snapshot. Opening this view never starts an executor or
/// reads another account's materials, maintenance records or printer secrets.
Future<void> showClusterDeviceDetails(
  BuildContext context, {
  required ClusterPrinter printer,
  required ClusterPlanningSnapshot snapshot,
  ClusterPlatePlan? plan,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _ClusterDeviceDetails(printer: printer, snapshot: snapshot, plan: plan),
);

class _ClusterDeviceDetails extends StatefulWidget {
  const _ClusterDeviceDetails({
    required this.printer,
    required this.snapshot,
    this.plan,
  });

  final ClusterPrinter printer;
  final ClusterPlanningSnapshot snapshot;
  final ClusterPlatePlan? plan;

  @override
  State<_ClusterDeviceDetails> createState() => _ClusterDeviceDetailsState();
}

class _ClusterDeviceDetailsState extends State<_ClusterDeviceDetails> {
  int _tab = 0;
  static const _tabs = ['状态与材料', '评分档案', '维护与证据'];

  ClusterPrinter get _printer => widget.printer;

  ClusterPrinterCandidate? get _candidate => widget.plan?.candidates
      .where((candidate) => candidate.printerId == _printer.id)
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      insetPadding: const EdgeInsets.all(16),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _printer.name == _printer.serial ? '未命名设备' : _printer.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 5),
          Text(
            '${_printer.model} · 设备档案',
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      content: SizedBox(
        width: 680,
        height: (size.height * .6).clamp(140.0, 520.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  ChoiceChip(
                    label: Text(
                      _tabs[i],
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    selected: _tab == i,
                    onSelected: (_) => setState(() => _tab = i),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: ListView(
                key: ValueKey('cluster-device-tab-$_tab'),
                children: switch (_tab) {
                  1 => _scoreContents(),
                  2 => _maintenanceContents(),
                  _ => _statusContents(),
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  List<Widget> _statusContents() {
    final fleet = _printer.state;
    final status = fleet?.lastStatus;
    final reasons = <String>{
      ..._printer.blockers,
      ...?widget.plan?.blockers,
      ...?widget.plan?.rejections[_printer.id],
    };
    return [
      _section(
        '设备观察',
        Icons.sensors_outlined,
        child: Column(
          children: [
            _row('连接', _connectionLabel(fleet?.connectionState)),
            _row('最近运行状态', _stateLabel(status?.gcodeState)),
            _row(
              '数据来源',
              fleet == null
                  ? '未接入'
                  : fleet.mode == BambuConnectionMode.lan
                  ? 'LAN 直连'
                  : '云端监控',
            ),
            _row('最后上报', _time(fleet?.statusUpdatedAt)),
            _row('队列', '${_printer.activeQueueCount} 盘次'),
            _row(
              '机器等待估计',
              _wait(
                ClusterDeviceObservation.from(_printer).fresh
                    ? _printer.availableAfterSeconds
                    : null,
              ),
            ),
            _row(
              '已知喷嘴',
              fleet?.installedNozzleDiameter == null
                  ? '—'
                  : '${fleet!.installedNozzleDiameter} mm',
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _section(
        '当前盘检查',
        Icons.fact_check_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.plan == null
                  ? '尚未选择打印盘'
                  : _candidate != null
                  ? '通过当前候选检查'
                  : '本盘暂不可分配',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (_candidate case final candidate?) ...[
              const SizedBox(height: 8),
              _row('可排上限', '${candidate.maxRuns} 盘次'),
              _row('匹配工具', '${candidate.materialMatches.length} 个'),
            ],
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(reason),
              ),
            const SizedBox(height: 10),
            _hint('候选检查不等于已开打；排产前仍需重新核验。'),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Text('供料槽', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      if (_printer.source.channels.isEmpty)
        _section(
          '暂无供料槽记录',
          Icons.inventory_2_outlined,
          child: _hint('当前快照没有材料数据，不代表机上没有耗材。'),
        )
      else
        for (final slot in _printer.source.channels)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _material(slot),
          ),
      const SizedBox(height: 8),
      _hint(
        '打开时快照 · ${_time(widget.snapshot.generatedAt)}\n'
        '机器等待估计不含取件、人工准备；完成状态不代表清床或质检通过。',
      ),
    ];
  }

  List<Widget> _scoreContents() => [
    _section(
      '设备综合分',
      Icons.insights_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('待评估', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          _hint('尚未接入设备评分与验收统计，不从任务次数推算成功率。'),
        ],
      ),
    ),
    const SizedBox(height: 12),
    _section(
      '评价维度',
      Icons.stacked_bar_chart_outlined,
      child: Column(
        children: [
          for (final label in ['运行可靠性', '成品质量', '维护落实', '连接可观测性'])
            _row(label, '—'),
          _row('有效样本 / 验收覆盖', '未接入'),
          _row('评分趋势', '待积累证据'),
        ],
      ),
    ),
    const SizedBox(height: 12),
    _section(
      '本盘适配分',
      Icons.tune_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('待评估', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _hint('当前只检查是否符合候选条件。设备分、本盘适配分与 Mifu 偏好概率分别记录，不能互相替代。'),
        ],
      ),
    ),
  ];

  List<Widget> _maintenanceContents() => [
    _section(
      '维修验收',
      Icons.build_circle_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('尚未接入', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _hint('本页尚未读取整机维修锁、维修工单与验收结果，不能据此判断设备无需维修。'),
        ],
      ),
    ),
    const SizedBox(height: 12),
    _section(
      '待接入的证据',
      Icons.checklist_outlined,
      child: Column(
        children: [
          _row('整机 / 组件维修状态', '未接入'),
          _row('保养到期与备件安排', '未接入'),
          _row('修后验证与验收', '未接入'),
          _row('清床 / 装板确认', '未接入'),
          _row('外部作业身份核对', '未接入'),
        ],
      ),
    ),
    const SizedBox(height: 12),
    _hint('供料槽的“耗材暂取”仅表示该卷暂停供料，不等于整台打印机在维修。故障消失、技术完成也不代表维修已验收。'),
  ];

  Widget _material(ChannelWithConsumable slot) {
    final material = slot.consumable;
    final visible =
        material != null &&
        widget.snapshot.visibleConsumableIds.contains(material.id);
    final label = slot.channel.label.trim().isEmpty
        ? '供料槽 ${slot.channel.channelIndex + 1}'
        : slot.channel.label;
    // Do not expose another account's color, material, remaining weight or hold
    // state just because the printer itself is visible in the fleet.
    if (!visible) {
      return _section(
        label,
        Icons.inventory_2_outlined,
        child: _hint(material == null ? '未绑定材料资料' : '材料资料不在当前范围'),
      );
    }
    final grams = slot.channel.loadedRemainingGrams;
    final invalid =
        !grams.isFinite || grams < 0 || grams > personalSpoolCapacityGrams;
    final usable = canReusePersonalSpool(grams);
    final match = _candidate?.materialMatches
        .where((item) => item.channelId == slot.channel.id)
        .firstOrNull;
    final color = _materialColor(material.colorHex);
    final stateLabel = switch (slot.rollHoldState) {
      ChannelRollHoldState.maintenance => '耗材暂取',
      ChannelRollHoldState.awaitingSelection => '等待选卷',
      ChannelRollHoldState.loaded =>
        invalid
            ? '余量异常 · 待核对'
            : usable
            ? '已登记装载'
            : '余量不足以继续使用',
    };
    return _section(
      label,
      Icons.inventory_2_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.only(right: 8, top: 2),
                decoration: BoxDecoration(
                  color:
                      color ??
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  '${material.manufacturer} · ${material.materialType}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _row('颜色', material.colorName ?? material.colorHex),
          _row(
            '机上登记余量',
            grams.isFinite ? '${grams.toStringAsFixed(1)} g' : '数值异常',
          ),
          if (!invalid)
            Semantics(
              label: '登记余量，标准单卷 ${personalSpoolCapacityGrams.toInt()} 克',
              value: '${grams.toStringAsFixed(1)} 克',
              child: LinearProgressIndicator(
                value: grams / personalSpoolCapacityGrams,
                minHeight: 4,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          const SizedBox(height: 8),
          Text(stateLabel, style: const TextStyle(fontSize: 12)),
          if (match != null)
            _row('本盘检查可用量', '${match.availableGrams.toStringAsFixed(1)} g'),
          const SizedBox(height: 6),
          _hint('登记余量不等于扣除全部预留后的可用量。'),
        ],
      ),
    );
  }

  Widget _section(String title, IconData icon, {required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: .035),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 300) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 3),
              Text(value),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodySmall),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(value, textAlign: TextAlign.end)),
          ],
        );
      },
    ),
  );

  Widget _hint(String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      height: 1.5,
    ),
  );

  String _connectionLabel(PrinterConnectionState? state) => switch (state) {
    PrinterConnectionState.connected => '已连接',
    PrinterConnectionState.connecting => '连接中',
    PrinterConnectionState.reconnecting => '重连中',
    PrinterConnectionState.disconnected => '已断开',
    PrinterConnectionState.error => '连接异常',
    null => '未接入',
  };

  String _stateLabel(BambuGcodeState? state) => switch (state) {
    BambuGcodeState.finish => '技术完成',
    null => '未知',
    _ => state.label,
  };

  String _wait(int? seconds) => seconds == null || seconds < 0
      ? '待核对'
      : seconds == 0
      ? '无已知机器等待'
      : '${(seconds / 60).ceil()} 分钟起';

  String _time(DateTime? time) {
    if (time == null) return '—';
    final local = time.toLocal();
    String two(int value) => '$value'.padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Color? _materialColor(String value) {
    final normalized = value.replaceFirst('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(normalized)) return null;
    return Color(0xff000000 | int.parse(normalized, radix: 16));
  }
}
