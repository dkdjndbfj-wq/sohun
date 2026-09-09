import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/database.dart';
import '../data/database/personal_inventory_balance_sync.dart';
import '../data/models/personal_inventory_event.dart';
import '../providers/database_provider.dart';
import '../providers/consumable_provider.dart';
import '../providers/personal_inventory_action_guard.dart';

Future<double?> showPersonalInventoryBalanceReconcileDialog(
  BuildContext context, {
  required Consumable spool,
  required PersonalInventoryBalanceConflict conflict,
  bool aggregateInventory = false,
}) => showDialog<double>(
  context: context,
  builder: (_) => _BalanceReconcileDialog(
    spool: spool,
    conflict: conflict,
    aggregateInventory: aggregateInventory,
  ),
);

/// Both personal clients show the same concrete roll and consumption ledger.
class RfidSpoolHistoryList extends ConsumerWidget {
  const RfidSpoolHistoryList({
    super.key,
    required this.history,
    this.currentUid,
  });
  final List<RfidSpoolBinding> history;
  final String? currentUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView.builder(
    itemCount: history.length,
    itemBuilder: (context, index) => _SpoolTrace(
      key: ValueKey(history[index].inventoryUid),
      binding: history[index],
      selected: history[index].inventoryUid == currentUid,
      canResolve:
          history.where((b) => b.isActive).length > 1 &&
          history[index].isActive &&
          history[index].cycle == history.first.cycle,
    ),
  );
}

class _SpoolTrace extends ConsumerStatefulWidget {
  const _SpoolTrace({
    super.key,
    required this.binding,
    required this.selected,
    required this.canResolve,
  });
  final RfidSpoolBinding binding;
  final bool selected;
  final bool canResolve;
  @override
  ConsumerState<_SpoolTrace> createState() => _SpoolTraceState();
}

typedef _SpoolTraceData = ({
  Consumable? spool,
  double used,
  List<PersonalInventoryEvent> events,
  bool hasMore,
  List<PersonalInventoryBalanceConflict> conflicts,
  PersonalRfidStockSource? source,
});

class _SpoolTraceState extends ConsumerState<_SpoolTrace> {
  late final _account = PersonalInventoryActionGuard.fromRef(ref);
  late Future<_SpoolTraceData> _trace = _load();
  bool _loadingMore = false;

  @override
  void didUpdateWidget(covariant _SpoolTrace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.binding.status != widget.binding.status) _trace = _load();
  }

  Future<_SpoolTraceData> _load() async {
    await _account.checkAccess(widget.binding.consumableId);
    final dao = ref.read(consumableDaoProvider);
    final spool = await dao.getById(widget.binding.consumableId);
    final owner = await dao.getOwnerAccount(widget.binding.consumableId);
    final events = await dao.getPersonalInventoryEventsForUid(
      widget.binding.inventoryUid,
      ownerAccount: owner,
      limit: 20,
    );
    final used = await dao.getPersonalInventoryConsumedGrams(
      widget.binding.inventoryUid,
      ownerAccount: owner,
    );
    final conflicts = await dao.readInventoryBalanceConflicts(
      widget.binding.inventoryUid,
      ownerAccount: owner,
    );
    final source = (await dao.getPersonalRfidStockSourcesMap([
      widget.binding.consumableId,
    ]))[widget.binding.consumableId];
    _account.assertCurrent();
    return (
      spool: spool,
      used: used,
      events: events,
      hasMore: events.length == 20,
      conflicts: conflicts,
      source: source,
    );
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      await _account.checkAccess(widget.binding.consumableId);
      final previous = await _trace;
      final dao = ref.read(consumableDaoProvider);
      final owner = await dao.getOwnerAccount(widget.binding.consumableId);
      final page = await dao.getPersonalInventoryEventsForUid(
        widget.binding.inventoryUid,
        ownerAccount: owner,
        limit: 20,
        offset: previous.events.length,
      );
      _account.assertCurrent();
      if (mounted)
        setState(
          () => _trace = Future.value((
            spool: previous.spool,
            used: previous.used,
            events: [...previous.events, ...page],
            hasMore: page.length == 20,
            conflicts: previous.conflicts,
            source: previous.source,
          )),
        );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('读取更多记录失败：$error')));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(personalInventoryAccountScopeProvider);
    if (!_account.isCurrent) return const Text('账号已切换，请关闭对话框后重试');
    return FutureBuilder<_SpoolTraceData>(
      future: _trace,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Text('无法读取此账号的卷记录，请关闭后重试');
        final trace = snapshot.data;
        final hasPhysicalTag = widget.binding.tagUid.trim().isNotEmpty;
        final status = switch (widget.binding.status) {
          'depleted' => '已用完',
          'replaced' => '已换卷',
          'retired' => '已归档',
          _ => hasPhysicalTag ? '当前卷' : '可用',
        };
        final grams = trace?.spool?.remainingGrams;
        return ExpansionTile(
          initiallyExpanded: widget.selected,
          leading: CircleAvatar(
            child: hasPhysicalTag
                ? Text('${widget.binding.cycle}')
                : const Icon(Icons.inventory_2_outlined),
          ),
          title: Text(
            hasPhysicalTag
                ? '第 ${widget.binding.cycle} 卷 · $status'
                : '独立库存卷 · $status',
          ),
          subtitle: Text(
            snapshot.hasError
                ? '读取记录失败'
                : grams == null
                ? '读取卷记录…'
                : '剩余 ${grams.toStringAsFixed(1)} g · 已登记消耗 ${trace!.used.toStringAsFixed(1)} g',
          ),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.canResolve)
              OutlinedButton(
                onPressed: _resolve,
                child: const Text('核对：这卷正在使用'),
              ),
            SelectableText('库存卷号：${widget.binding.inventoryUid}'),
            if (!hasPhysicalTag)
              const Text('尚未绑定物理标签；资料卡仅记录入库来源，不代表这卷已装入 AMS。'),
            if (trace?.source case final source?) ...[
              if (source.tagUid != null)
                SelectableText('来源资料卡：${source.tagUid} · ${source.tagType}')
              else
                const Text('入库来源：手动确认（未使用资料卡）'),
              SelectableText(
                '入库批次：${source.receiptUid} · 第 ${source.index + 1}/${source.quantity} 卷',
              ),
            ],
            if (widget.binding.isHistoricalTag)
              const Text('这卷余料已换绑其他标签；此处保留旧标签周期，余量与消耗按同一库存卷持续记录。'),
            if (widget.binding.previousInventoryUid != null)
              SelectableText('上一卷：${widget.binding.previousInventoryUid}'),
            if (trace != null) ...[
              for (final conflict in trace.conflicts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.balance_outlined),
                  title: const Text('余量需要核对'),
                  subtitle: Text(
                    '本机 ${grams?.toStringAsFixed(1)} g · 云端 ${conflict.remote.remainingGrams.toStringAsFixed(1)} g',
                  ),
                  trailing: TextButton(
                    onPressed: () => _reconcile(conflict, trace.spool!),
                    child: const Text('核对余量'),
                  ),
                ),
              if (trace.events.isEmpty) const Text('尚无这卷的操作与消耗记录'),
              for (final event in trace.events)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    event.isRemote
                        ? Icons.cloud_done_outlined
                        : Icons.receipt_long_outlined,
                    size: 18,
                  ),
                  title: Text(_personalEventLabel(event)),
                  subtitle: Text(
                    [
                      '${event.occurredAt.toLocal()}',
                      event.isRemote ? '其他设备' : '本机',
                      if (event.printerName != null) event.printerName!,
                      if (event.channelIndex != null)
                        '槽位 ${event.channelIndex! + 1}',
                      if (event.taskUid != null) '任务 ${event.taskUid}',
                      if (event.note != null) event.note!,
                    ].join(' · '),
                  ),
                ),
              if (trace.hasMore)
                TextButton(
                  onPressed: _loadingMore ? null : _loadMore,
                  child: Text(_loadingMore ? '读取中…' : '查看更早记录'),
                ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _reconcile(
    PersonalInventoryBalanceConflict conflict,
    Consumable spool,
  ) async {
    final grams = await showPersonalInventoryBalanceReconcileDialog(
      context,
      spool: spool,
      conflict: conflict,
    );
    if (grams == null || !mounted) return;
    try {
      await _account.run(
        spool.id,
        () => _account.dao.reconcilePersonalInventoryBalance(
          spool.id,
          conflict,
          grams,
        ),
      );
      if (mounted) {
        setState(() => _trace = _load());
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已记录余量核对，请刷新库存完成同步')));
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('核对失败：$error')));
    }
  }

  Future<void> _resolve() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认当前耗材卷'),
        content: Text(
          '将卷号 ${widget.binding.inventoryUid} 作为此标签当前唯一关联。其他冲突卷的余量和历史会保留，并停用它们的标签关联。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认这卷'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _account.run(
        widget.binding.consumableId,
        () => _account.dao.resolvePersonalRfidSpoolConflict(
          widget.binding.consumableId,
        ),
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已确认当前卷，冲突记录已保留')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('核对失败：$error')));
    }
  }
}

String _personalEventLabel(PersonalInventoryEvent event) {
  final label = switch (event.eventType) {
    'usage_finished' => '消耗结算 · 已完成',
    'usage_partial' => '消耗结算 · 中止/部分消耗',
    'manual_consumption' => '手动扣减库存',
    'stock_received' => event.source == 'manual' ? '手动确认入库' : '资料卡确认入库',
    'balance_reconciled' => '实际余量核对',
    'spool_loaded' => '实体卷装机',
    'tag_rebound' => '余料换绑新标签',
    'spool_unloaded' => '实体卷取下回库',
    'spool_weighed' => '换卷余量核对',
    'nfc_read_success' => '读取标签',
    'nfc_write_success' => '写入标签',
    'nfc_bind_success' => '关联耗材卷',
    'nfc_replace_success' => '确认换入新卷',
    'nfc_resolve_success' => '核对当前卷',
    'nfc_archive_success' => '归档耗材卷',
    'twin_discovered' => '首次识别',
    'twin_bound' => '装入',
    'twin_moved' => '换槽',
    'twin_removed' => '移出',
    'twin_rfid_observed' => 'AMS 余量观测',
    'twin_depleted' => 'AMS 上报耗尽',
    'twin_reconciled' => '余量核对',
    'twin_print_estimated' => '打印估算',
    'twin_migration_snapshot' => '历史快照',
    _ => event.eventType.endsWith('_failed') ? '标签操作未完成' : '耗材操作记录',
  };
  final grams = event.deltaGrams;
  return '$label${grams == null ? (event.afterGrams == null ? '' : ' · ${event.afterGrams!.toStringAsFixed(1)} g') : ' · ${grams > 0 ? '+' : ''}${grams.toStringAsFixed(1)} g'}';
}

class _BalanceReconcileDialog extends StatefulWidget {
  const _BalanceReconcileDialog({
    required this.spool,
    required this.conflict,
    required this.aggregateInventory,
  });
  final Consumable spool;
  final PersonalInventoryBalanceConflict conflict;
  final bool aggregateInventory;
  @override
  State<_BalanceReconcileDialog> createState() =>
      _BalanceReconcileDialogState();
}

class _BalanceReconcileDialogState extends State<_BalanceReconcileDialog> {
  final _controller = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maximum = widget.aggregateInventory
        ? 100000.0
        : widget.spool.totalGrams;
    final target = widget.aggregateInventory ? '这项汇总库存' : '这卷';
    return AlertDialog(
      title: Text('核对$target的实际余量'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '本机记录 ${widget.spool.remainingGrams.toStringAsFixed(1)} g，云端记录 '
            '${widget.conflict.remote.remainingGrams.toStringAsFixed(1)} g。请核对$target实际剩余净重，操作会保留一条修正记录。',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: '实际剩余净重',
              suffixText: 'g',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final grams = double.tryParse(_controller.text.trim());
            if (grams == null ||
                !grams.isFinite ||
                grams < 0 ||
                grams > maximum) {
              setState(() => _error = '请输入 0 到 $maximum 之间的重量');
              return;
            }
            Navigator.pop(context, grams);
          },
          child: const Text('确认实际余量'),
        ),
      ],
    );
  }
}
