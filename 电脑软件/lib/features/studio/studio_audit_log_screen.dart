import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database/models/studio_models.dart';
import '../../data/external/community/studio_api_client.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_design.dart';

class StudioAuditLogScreen extends ConsumerStatefulWidget {
  const StudioAuditLogScreen({super.key});

  @override
  ConsumerState<StudioAuditLogScreen> createState() =>
      _StudioAuditLogScreenState();
}

class _StudioAuditLogScreenState extends ConsumerState<StudioAuditLogScreen> {
  final _searchController = TextEditingController();
  String _category = 'all';
  String _range = 'all';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final local = ref.watch(studioActivityEventsProvider);
    final remote = ref.watch(farmAuditLogsProvider);
    final rows = _combine(
      local.valueOrNull ?? const [],
      remote.valueOrNull ?? const [],
    ).where(_matchesFilters).toList(growable: false);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FarmPageHeader(
            title: '操作记录',
            subtitle: '记录管理员和成员所有会改变农场数据或账号状态的操作；记录只可追加，不能修改或删除。',
            actions: [
              OutlinedButton.icon(
                onPressed: remote.isLoading
                    ? null
                    : () {
                        ref.invalidate(farmAuditLogsProvider);
                        ref
                            .read(studioSyncControllerProvider.notifier)
                            .requestNow();
                      },
                icon: remote.isLoading
                    ? const SizedBox.square(
                        dimension: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('刷新记录'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.42),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '共保存 ${_combine(local.valueOrNull ?? const [], remote.valueOrNull ?? const []).length} 条，当前筛选显示 ${rows.length} 条。删除成员不会删除其历史记录，姓名按操作发生时的快照显示。',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          if (remote.hasError) ...[
            const SizedBox(height: 8),
            Text(
              '云端安全审计暂时读取失败，本机业务操作记录仍可查看：${remote.error}',
              style: TextStyle(fontSize: 11, color: scheme.error),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 300,
                height: 40,
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                    hintText: '搜索操作人、内容或对象编号',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              _AuditFilter(
                value: _category,
                items: const {
                  'all': '全部操作',
                  'member': '成员与账号',
                  'order': '订单与生产',
                  'inventory': '库存与耗材',
                  'organization': '农场设置',
                  'security': '登录与安全',
                },
                onChanged: (value) => setState(() => _category = value),
              ),
              _AuditFilter(
                value: _range,
                items: const {
                  'all': '全部时间',
                  'today': '今天',
                  '7d': '最近 7 天',
                  '30d': '最近 30 天',
                },
                onChanged: (value) => setState(() => _range = value),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: local.isLoading && rows.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : rows.isEmpty
                      ? const Center(child: Text('没有符合条件的操作记录'))
                      : LayoutBuilder(
                          builder: (context, constraints) =>
                              constraints.maxWidth >= 860
                                  ? _AuditTable(rows: rows)
                                  : _AuditCards(rows: rows),
                        ),
            ),
          ),
        ],
      ),
    );
  }

  bool _matchesFilters(_AuditRow row) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty &&
        !'${row.actorName} ${row.summary} ${row.action} ${row.resourceId}'
            .toLowerCase()
            .contains(query)) {
      return false;
    }
    if (_category != 'all' && _auditCategory(row.action) != _category) {
      return false;
    }
    final now = DateTime.now();
    final cutoff = switch (_range) {
      'today' => DateTime(now.year, now.month, now.day),
      '7d' => now.subtract(const Duration(days: 7)),
      '30d' => now.subtract(const Duration(days: 30)),
      _ => null,
    };
    return cutoff == null || !row.createdAt.isBefore(cutoff);
  }
}

List<_AuditRow> _combine(
  List<StudioActivityEvent> local,
  List<StudioRemoteAuditLog> remote,
) {
  final rows = <String, _AuditRow>{};
  for (final event in local) {
    rows[event.id] = _AuditRow.fromLocal(event);
  }
  for (final event in remote) {
    final key = event.clientEventId ?? 'remote:${event.id}';
    rows[key] = _AuditRow.fromRemote(event);
  }
  final result = rows.values.toList(growable: false)
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return result;
}

class _AuditTable extends StatelessWidget {
  const _AuditTable({required this.rows});

  final List<_AuditRow> rows;

  @override
  Widget build(BuildContext context) {
    final headerStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              SizedBox(width: 150, child: Text('时间', style: headerStyle)),
              SizedBox(width: 150, child: Text('操作人', style: headerStyle)),
              SizedBox(width: 150, child: Text('操作', style: headerStyle)),
              SizedBox(width: 120, child: Text('对象', style: headerStyle)),
              Expanded(child: Text('内容', style: headerStyle)),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) => _AuditTableRow(row: rows[index]),
          ),
        ),
      ],
    );
  }
}

class _AuditTableRow extends StatelessWidget {
  const _AuditTableRow({required this.row});

  final _AuditRow row;

  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              DateFormat('yyyy-MM-dd HH:mm:ss').format(row.createdAt),
              style: const TextStyle(fontSize: 11),
            ),
          ),
          SizedBox(
            width: 150,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.actorName, overflow: TextOverflow.ellipsis),
                Text(
                  _identityLabel(row.actorIdentity),
                  style: TextStyle(fontSize: 10, color: secondary),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 150,
            child: Text(
              _actionLabel(row.action),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 120,
            child: Text(
              _resourceLabel(row.resourceType),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: secondary),
            ),
          ),
          Expanded(
            child: Text(
              row.summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditCards extends StatelessWidget {
  const _AuditCards({required this.rows});

  final List<_AuditRow> rows;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(10),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final row = rows[index];
        return ListTile(
          dense: true,
          title: Text('${row.actorName} · ${_actionLabel(row.action)}'),
          subtitle: Text(row.summary),
          trailing: Text(
            DateFormat('MM-dd\nHH:mm:ss').format(row.createdAt),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 10),
          ),
        );
      },
    );
  }
}

class _AuditFilter extends StatelessWidget {
  const _AuditFilter({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String value;
  final Map<String, String> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: DropdownButton<String>(
        value: value,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(8),
        items: [
          for (final item in items.entries)
            DropdownMenuItem(value: item.key, child: Text(item.value)),
        ],
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
      ),
    );
  }
}

class _AuditRow {
  const _AuditRow({
    required this.id,
    required this.actorName,
    required this.actorIdentity,
    required this.action,
    required this.resourceType,
    required this.resourceId,
    required this.summary,
    required this.createdAt,
  });

  factory _AuditRow.fromLocal(StudioActivityEvent event) => _AuditRow(
        id: event.id,
        actorName: event.actorDisplayName,
        actorIdentity: event.actorIdentity,
        action: event.actionCode,
        resourceType: event.entityType,
        resourceId: event.entityId,
        summary: event.summary,
        createdAt: event.createdAt,
      );

  factory _AuditRow.fromRemote(StudioRemoteAuditLog event) => _AuditRow(
        id: event.id,
        actorName: event.actorName ?? '系统',
        actorIdentity: event.actorIdentity ?? 'system',
        action: event.action,
        resourceType: event.resourceType ?? 'system',
        resourceId: event.resourceId ?? '',
        summary: event.summary ?? _actionLabel(event.action),
        createdAt: event.createdAt,
      );

  final String id;
  final String actorName;
  final String actorIdentity;
  final String action;
  final String resourceType;
  final String resourceId;
  final String summary;
  final DateTime createdAt;
}

String _identityLabel(String identity) => switch (identity) {
      'administrator' => '管理员',
      'member' => '成员',
      _ => '系统',
    };

String _auditCategory(String action) {
  if (action.startsWith('member.') || action.startsWith('staff.')) {
    return action.startsWith('staff.login') ? 'security' : 'member';
  }
  if (action.startsWith('order.') ||
      action.startsWith('work_order.') ||
      action.startsWith('plate.') ||
      action.startsWith('print.') ||
      action.startsWith('quote.') ||
      action.startsWith('share')) {
    return 'order';
  }
  if (action.startsWith('inventory.') || action.startsWith('consumable.')) {
    return 'inventory';
  }
  if (action.startsWith('organization.') || action.startsWith('workspace.')) {
    return 'organization';
  }
  if (action.startsWith('farm_settings.') ||
      action.startsWith('printer_model_profile.') ||
      action.startsWith('continuous_print.') ||
      action.startsWith('auto_eject_gcode.')) {
    return 'organization';
  }
  return 'security';
}

String _actionLabel(String action) => switch (action) {
      'member.created' || 'member.upsert' => '创建成员',
      'member.updated' || 'member.identity_updated' => '修改成员',
      'member.activated' => '启用成员',
      'member.deactivated' || 'member.deactivate' => '停用成员',
      'member.removed' => '删除成员',
      'member.credential_reset' => '重置成员密码',
      'staff.login' => '成员登录',
      'staff.login_failed' => '成员登录失败',
      'staff.initial_password_changed' => '修改初始密码',
      'workspace.renamed' => '修改农场名称',
      'snapshot.update' => '同步农场数据',
      'organization.profile_updated' => '修改农场资料',
      'organization.verification_submitted' => '提交主体审核',
      'farm_settings.updated' => '修改农场设置',
      'printer_model_profile.updated' => '修改机型配置',
      'continuous_print.queue_toggled' => '切换打印队列',
      'continuous_print.prequeue_toggled' => '切换任务预排',
      'continuous_print.unattended_toggled' => '切换无人值守',
      'auto_eject_gcode.updated' => '修改自动取件脚本',
      'printer.camera_preview_opened' => '查看实时画面',
      'customer.created' => '创建客户',
      'customer.archived' => '停用客户',
      'customer.restored' => '恢复客户',
      'order.created' || 'order.production_created' => '创建订单',
      'order.status_updated' => '修改订单状态',
      'work_order.created' => '创建工单',
      'work_order.assigned' || 'plate.assigned' => '分配生产任务',
      'work_order.progress_updated' => '更新工单进度',
      'work_order.queue_status_updated' => '更新打印队列',
      'print.removal_confirmed' => '确认打印取件',
      'work_order.materials_reserved' => '分配工单耗材',
      'work_order.materials_released' => '释放工单耗材',
      'plate.slice_updated' => '更新切片状态',
      'quote.created' => '创建报价',
      'quote.status_updated' => '修改报价状态',
      'inventory.adjusted' => '调整库存',
      'inventory.batch_received' => '批量入库',
      'inventory.batch_updated' || 'inventory.batch_rolls_updated' => '修改入库批次',
      'inventory.batch_deleted' => '删除未使用批次',
      'share_link.created' || 'share.create' => '创建客户链接',
      'share_link.revoked' || 'share.revoke' => '撤销客户链接',
      _ => action,
    };

String _resourceLabel(String type) => switch (type) {
      'member' => '成员',
      'organization' || 'workspace' => '农场',
      'customer' => '客户',
      'order' => '订单',
      'work_order' => '工单',
      'plate' => '生产盘',
      'quote' => '报价',
      'consumable' => '耗材',
      'inventory_batch' => '入库批次',
      'verification_submission' => '主体审核',
      'printer_model' => '打印机型号',
      'printer' => '打印机',
      _ => type,
    };
