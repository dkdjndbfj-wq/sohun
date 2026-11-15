import 'package:flutter/material.dart';

import '../../core/services/cluster_planning_service.dart';
import '../../core/theme/interaction_effects.dart';
import '../../ui/aurora_design.dart';

/// Read-only, virtualized task/package/plate view. Selecting a plate never
/// reserves material or dispatches a print; those actions belong to the parent.
class ClusterTaskArray extends StatefulWidget {
  const ClusterTaskArray({
    super.key,
    required this.snapshot,
    required this.selectedPlateId,
    required this.onSelectPlate,
  });

  final ClusterPlanningSnapshot snapshot;
  final String? selectedPlateId;
  final ValueChanged<ClusterPlatePlan>? onSelectPlate;

  @override
  State<ClusterTaskArray> createState() => _ClusterTaskArrayState();
}

enum _PlateFilter {
  all('全部'),
  pending('待安排'),
  blocked('受阻'),
  assigned('已安排'),
  completed('技术完成');

  const _PlateFilter(this.label);
  final String label;

  bool includes(ClusterPlatePlan plan) => switch (this) {
    all => true,
    pending => plan.remainingRuns > 0,
    blocked =>
      plan.remainingRuns > 0 &&
          (plan.blockers.isNotEmpty || plan.candidates.isEmpty),
    assigned => plan.assignedRuns > 0,
    completed => plan.completedRuns > 0,
  };
}

class _TaskArrayRow {
  const _TaskArrayRow.task(this.task) : package = null, plan = null;
  const _TaskArrayRow.package(this.package) : task = null, plan = null;
  const _TaskArrayRow.plate(this.plan) : task = null, package = null;

  final ClusterTaskGroup? task;
  final ClusterPackageGroup? package;
  final ClusterPlatePlan? plan;
}

class _ClusterTaskArrayState extends State<ClusterTaskArray> {
  final _searchController = TextEditingController();
  final _collapsedTasks = <String>{};
  String _query = '';
  _PlateFilter _filter = _PlateFilter.all;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _contains(String value) => value.toLowerCase().contains(_query);

  List<_TaskArrayRow> _rows() {
    final rows = <_TaskArrayRow>[];
    for (final task in widget.snapshot.tasks) {
      final taskMatches = _contains(
        '${task.order.title} ${task.order.orderNo}',
      );
      final contents = <_TaskArrayRow>[];
      for (final package in task.packages) {
        final packageMatches = _contains(package.package.sourceName);
        final plates = package.plates.where(
          (plan) =>
              _filter.includes(plan) &&
              (taskMatches ||
                  packageMatches ||
                  _contains(
                    '${plan.plate.name} P${plan.plate.plateIndex.toString().padLeft(2, '0')}',
                  )),
        );
        if (plates.isEmpty) continue;
        contents.add(_TaskArrayRow.package(package));
        contents.addAll(plates.map(_TaskArrayRow.plate));
      }
      if (contents.isEmpty) continue;
      rows.add(_TaskArrayRow.task(task));
      // Searching/filtering reveals matches even inside a collapsed task.
      if (!_collapsedTasks.contains(task.order.id) ||
          _query.isNotEmpty ||
          _filter != _PlateFilter.all) {
        rows.addAll(contents);
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    final plans = widget.snapshot.plates;
    final theme = Theme.of(context);
    return FrostPanel(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Expanded(
                child: Text(
                  '任务阵列',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              Tooltip(
                message: '技术完成 ≠ 质检通过或交付',
                child: Icon(Icons.info_outline, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.snapshot.tasks.length} 任务 · ${plans.length} 盘',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '搜索任务、打印盘',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除任务搜索',
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close, size: 16),
                    ),
            ),
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final filter in _PlateFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(
                        filter.label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 11,
                        ),
                      ),
                      selected: _filter == filter,
                      onSelected: (_) => setState(() => _filter = filter),
                      showCheckmark: false,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: rows.isEmpty
                ? _empty(context)
                : ListView.builder(
                    key: const PageStorageKey('cluster-task-array'),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      if (row.task case final task?) {
                        return _taskHeader(context, task);
                      }
                      if (row.package case final package?) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(3, 10, 3, 7),
                          child: Tooltip(
                            message: package.package.sourceName,
                            child: Text(
                              package.package.sourceName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                        );
                      }
                      return _plate(context, row.plan!);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.layers_outlined,
              size: 30,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 10),
            Text(widget.snapshot.tasks.isEmpty ? '暂无任务' : '没有匹配的打印盘'),
            const SizedBox(height: 5),
            Text(
              widget.snapshot.tasks.isEmpty ? '在项目页面导入打印任务' : '调整搜索或盘次状态筛选',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11),
            ),
            if (widget.snapshot.tasks.isNotEmpty)
              TextButton(
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _query = '';
                    _filter = _PlateFilter.all;
                  });
                },
                child: const Text('清除筛选'),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _taskHeader(BuildContext context, ClusterTaskGroup task) {
    final plates = task.plates;
    final required = plates.fold<int>(
      0,
      (sum, p) => sum + p.plate.requiredRuns,
    );
    final pending = plates.fold<int>(0, (sum, p) => sum + p.remainingRuns);
    final due = task.order.dueAt?.toLocal();
    final collapsed =
        _collapsedTasks.contains(task.order.id) &&
        _query.isEmpty &&
        _filter == _PlateFilter.all;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() {
            if (!_collapsedTasks.add(task.order.id)) {
              _collapsedTasks.remove(task.order.id);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: task.order.title,
                        child: Text(
                          task.order.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 18,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  task.order.orderNo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    Text(
                      '${plates.length} 盘 · 需求 $required 次',
                      style: const TextStyle(fontSize: 11),
                    ),
                    Text(
                      '待安排 $pending 次',
                      style: const TextStyle(fontSize: 11),
                    ),
                    Text(
                      due == null
                          ? '交期 —'
                          : '交期 ${due.month}/${due.day} ${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _plate(BuildContext context, ClusterPlatePlan plan) {
    final colors = Theme.of(context).colorScheme;
    final selected = widget.selectedPlateId == plan.plate.id;
    final blocked = _PlateFilter.blocked.includes(plan);
    final values = [plan.completedRuns, plan.assignedRuns, plan.remainingRuns];
    final recorded = values.fold<int>(0, (sum, value) => sum + value);
    final unclassified = plan.plate.requiredRuns - recorded;
    final invalid =
        plan.plate.requiredRuns <= 0 ||
        values.any((value) => value < 0) ||
        unclassified < 0;
    final segmentColors = [
      colors.primary,
      colors.tertiary,
      colors.outline.withValues(alpha: .4),
      colors.surfaceContainerHighest,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AnimatedContainer(
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 180),
        ),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: selected ? .12 : .025),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? colors.primary.withValues(alpha: .7)
                : colors.outlineVariant.withValues(alpha: .5),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onSelectPlate == null
                ? null
                : () => widget.onSelectPlate!(plan),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'P${plan.plate.plateIndex.toString().padLeft(2, '0')}  ${plan.plate.name}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.arrow_forward,
                          size: 14,
                          color: colors.primary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 5,
                    children: [
                      _count('所需', plan.plate.requiredRuns, null),
                      _count('待安排', plan.remainingRuns, segmentColors[2]),
                      _count('已安排', plan.assignedRuns, segmentColors[1]),
                      _count('技术完成', plan.completedRuns, segmentColors[0]),
                      if (unclassified > 0)
                        _count('未归类', unclassified, segmentColors[3]),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (invalid)
                    Text(
                      '盘次需核对',
                      style: TextStyle(fontSize: 10, color: colors.error),
                    )
                  else
                    Semantics(
                      label:
                          '所需${plan.plate.requiredRuns}次，技术完成${plan.completedRuns}次，已安排${plan.assignedRuns}次，待安排${plan.remainingRuns}次，未归类$unclassified次',
                      child: ExcludeSemantics(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: SizedBox(
                            key: ValueKey(
                              'cluster-plate-progress-${plan.plate.id}',
                            ),
                            height: 5,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < 4; i++)
                                  if ((i == 3 ? unclassified : values[i]) > 0)
                                    Expanded(
                                      flex: i == 3 ? unclassified : values[i],
                                      child: ColoredBox(
                                        color: segmentColors[i],
                                      ),
                                    ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    children: [
                      Text(
                        plan.plate.estimatedSeconds > 0
                            ? '约 ${(plan.plate.estimatedSeconds / 60).ceil()} 分 / 次'
                            : '时长 —',
                        style: const TextStyle(fontSize: 10),
                      ),
                      Text(
                        plan.plate.estimatedGrams.isFinite &&
                                plan.plate.estimatedGrams > 0
                            ? '约 ${plan.plate.estimatedGrams.toStringAsFixed(1)} g / 次'
                            : '用量 —',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                  if (blocked) ...[
                    const SizedBox(height: 7),
                    Text(
                      plan.blockers.isNotEmpty
                          ? '受阻 · ${plan.blockers.first}'
                          : '受阻 · 暂无合格候选',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: colors.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _count(String label, int value, Color? color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (color != null) ...[
        Container(width: 5, height: 5, color: color),
        const SizedBox(width: 4),
      ],
      Text('$label $value', style: const TextStyle(fontSize: 10)),
    ],
  );
}
