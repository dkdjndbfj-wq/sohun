import 'dart:async';
import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/services/material_identity_service.dart';
import '../../core/services/printer_fleet_connection_manager.dart';
import '../../core/services/printer_model_normalizer.dart';
import '../../core/services/slice_artifact_hash_service.dart';
import '../../core/services/studio_dispatch_service.dart';
import '../../core/theme/app_colors.dart';
import '../../data/database/database.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../data/database/models/scheduler_models.dart';
import '../../data/database/models/studio_models.dart';
import '../../data/models/print_parameter.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/bambu_print_feed.dart';
import '../../data/seed/printer_seed.dart';
import '../../data/external/printer/printer_connector.dart';
import '../../data/external/slicer/bambu_studio_editor_service.dart';
import '../../data/external/slicer/bambu_studio_slicing_service.dart';
import '../../data/external/slicer/production_package_inspector.dart';
import 'personal_plate_editor.dart';
import '../../providers/consumable_provider.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/farm_slice_intake_provider.dart';
import '../../providers/farm_slicing_preset_provider.dart';
import '../../providers/parameter_preset_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/print_queue_provider.dart';
import '../../providers/slicer_provider.dart';
import '../../providers/studio_provider.dart';
import '../../ui/aurora_design.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/app_input.dart';

// Thumbnail-only path for the personal workspace. It reads the central
// directory and the small Metadata/plate_*.png entries without loading model
// meshes or running the heavier production inspection.
final _personalPlateThumbnailsProvider =
    FutureProvider.family<Map<int, Uint8List>, String>(
      (ref, path) => PersonalPlateEditorStore.readPlateThumbnails(path),
    );

/// Personal-mode project workspace.
///
/// This deliberately lives outside `features/studio`: the farm workspace has
/// its own visual system and the personal product must never inherit it. The
/// data and printing services are shared, while every surface below uses the
/// Aurora design language.
class PersonalProjectsScreen extends ConsumerStatefulWidget {
  const PersonalProjectsScreen({super.key});

  @override
  ConsumerState<PersonalProjectsScreen> createState() =>
      _PersonalProjectsScreenState();
}

class _PersonalProjectsScreenState
    extends ConsumerState<PersonalProjectsScreen> {
  final _search = TextEditingController();
  String _filter = '全部';
  String? _busyImport;
  bool _dragging = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(studioSnapshotProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '我的项目',
                      style: Aurora.title(context).copyWith(fontSize: 22),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '拖入一个 3MF，选中想打印的那一盘；参数、耗材和进度都会留在这里。',
                      style: Aurora.label(context).copyWith(fontSize: 13),
                    ),
                  ],
                ),
              ),
              AuroraButton(
                label: '导入项目',
                icon: 'add_filament',
                onPressed: () => _openImportDialog(),
              ),
              const SizedBox(width: 10),
              AuroraButton(
                label: '参数库',
                icon: 'plate_settings',
                filled: false,
                onPressed: () => _showPresetInfo(),
              ),
            ],
          ),
          const SizedBox(height: 20),
          snapshot.when(
            loading: () => const Expanded(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => Expanded(
              child: _PersonalErrorState(message: '项目数据读取失败：$error'),
            ),
            data: (studio) {
              final projects = _filteredProjects(studio);
              final allPlates = studio.productionPlates.length;
              final readyPlates = studio.productionPlates
                  .where((p) => p.isSliced)
                  .length;
              final running = studio.workOrders
                  .where((w) => w.status == StudioWorkOrderStatus.printing)
                  .length;
              final completed = studio.workOrders.fold<int>(
                0,
                (sum, workOrder) => sum + workOrder.completedQuantity,
              );
              return Expanded(
                child: Column(
                  children: [
                    _ProjectMetrics(
                      projectCount: studio.orders.length,
                      plateCount: allPlates,
                      readyCount: readyPlates,
                      runningCount: running,
                      completedCount: completed,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: AppInput(
                            controller: _search,
                            search: true,
                            hint: '搜索项目名称或文件名',
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _FilterChips(
                          value: _filter,
                          onChanged: (value) => setState(() => _filter = value),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: DropTarget(
                        onDragEntered: (_) => setState(() => _dragging = true),
                        onDragExited: (_) => setState(() => _dragging = false),
                        onDragDone: (detail) {
                          setState(() => _dragging = false);
                          _openImportDialog(
                            initialPaths: detail.files.map((file) => file.path),
                          );
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          decoration: BoxDecoration(
                            color: _dragging
                                ? AppColors.primary.withValues(alpha: .07)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(
                              AppColors.radiusLg,
                            ),
                            border: _dragging
                                ? Border.all(
                                    color: AppColors.primary,
                                    width: 1.5,
                                  )
                                : null,
                          ),
                          child: projects.isEmpty
                              ? _ProjectEmptyState(
                                  hasAnyProjects: studio.orders.isNotEmpty,
                                  dragging: _dragging,
                                  onImport: () => _openImportDialog(),
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  itemCount: projects.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 12),
                                  itemBuilder: (context, index) {
                                    final order = projects[index];
                                    return _PersonalProjectCard(
                                      order: order,
                                      studio: studio,
                                      onImport: () => _openImportDialog(),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  List<StudioOrder> _filteredProjects(StudioSnapshot studio) {
    final query = _search.text.trim().toLowerCase();
    return studio.orders
        .where((order) {
          final hasMatchingFile = studio.productionPackages.any(
            (package) =>
                package.orderId == order.id &&
                package.sourceName.toLowerCase().contains(query),
          );
          final matchesQuery =
              query.isEmpty ||
              order.title.toLowerCase().contains(query) ||
              hasMatchingFile;
          final status = _personalProjectStatus(
            order,
            studio.productionPlates,
            studio.workOrders,
          );
          final matchesFilter = switch (_filter) {
            '待准备' =>
              status == StudioOrderStatus.draft ||
                  status == StudioOrderStatus.confirmed,
            '打印中' => status == StudioOrderStatus.production,
            '已完成' =>
              status == StudioOrderStatus.completed ||
                  status == StudioOrderStatus.delivered,
            _ => true,
          };
          return matchesQuery && matchesFilter;
        })
        .toList(growable: false);
  }

  Future<void> _openImportDialog({
    Iterable<String> initialPaths = const [],
  }) async {
    if (_busyImport != null) return;
    setState(() => _busyImport = 'project');
    try {
      final result = await showPersonalProjectImportDialog(
        context,
        ref,
        initialPaths: initialPaths.toList(growable: false),
      );
      if (result == true && mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _busyImport = null);
    }
  }

  Future<void> _showPresetInfo() async {
    final notifier = ref.read(farmSlicingPresetsProvider.notifier);
    await notifier.ready;
    if (!mounted) return;
    await AppDialog.show<void>(
      context: context,
      title: '参数库',
      content: const _PersonalPresetLibraryContent(),
      actions: [
        AppButton(
          label: '导入本地参数',
          compact: true,
          variant: AppButtonVariant.secondary,
          onPressed: () {
            Navigator.of(context).pop();
            _importPersonalPreset();
          },
        ),
        const SizedBox(width: 8),
        AppButton(
          label: '知道了',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Future<void> _importPersonalPreset() async {
    const group = XTypeGroup(
      label: 'Bambu Studio 参数 JSON',
      extensions: ['json'],
    );
    final files = await openFiles(acceptedTypeGroups: const [group]);
    if (files.isEmpty || !mounted) return;
    final notifier = ref.read(farmSlicingPresetsProvider.notifier);
    try {
      await notifier.ready;
      final candidate = await notifier.inspectImportFiles(
        files.map((file) => file.path),
      );
      if (!mounted) return;
      final name = await _askPersonalPresetName(candidate);
      if (name == null || !mounted) return;
      final preset = await notifier.importCandidate(
        candidate: candidate,
        name: name,
      );
      if (mounted) {
        _personalSnack(context, '已保存“${preset.name}”，打印前会自动检查机型和喷嘴兼容性');
      }
    } on FarmSlicingPresetException catch (error) {
      if (mounted) _personalSnack(context, error.message, error: true);
    } catch (error) {
      if (mounted) _personalSnack(context, '参数导入失败：$error', error: true);
    }
  }

  Future<String?> _askPersonalPresetName(
    FarmSlicingPresetCandidate candidate,
  ) async {
    final controller = TextEditingController(
      text:
          '${candidate.displayModel} ${candidate.nozzleDiameter.toStringAsFixed(1)} mm',
    );
    try {
      return await AppDialog.show<String>(
        context: context,
        title: '保存这套拓竹参数',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${candidate.displayModel} · ${candidate.nozzleDiameter.toStringAsFixed(1)} mm',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '会把机器、工艺和耗材 JSON 复制到软件的参数库中，原文件不会被修改。',
              style: Aurora.label(context).copyWith(height: 1.45),
            ),
            const SizedBox(height: 14),
            AppInput(label: '参数名称', controller: controller),
          ],
        ),
        actions: [
          AppButton(
            label: '取消',
            compact: true,
            variant: AppButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
          AppButton(
            label: '保存参数',
            compact: true,
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          ),
        ],
      );
    } finally {
      controller.dispose();
    }
  }
}

/// Personal parameter library: two clearly separated sources keep the
/// read-only Bambu catalog distinct from presets owned by the current user.
class _PersonalPresetLibraryContent extends ConsumerStatefulWidget {
  const _PersonalPresetLibraryContent();

  @override
  ConsumerState<_PersonalPresetLibraryContent> createState() =>
      _PersonalPresetLibraryContentState();
}

class _PersonalPresetLibraryContentState
    extends ConsumerState<_PersonalPresetLibraryContent> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final official = ref
        .watch(parameterPresetProvider)
        .where(
          (preset) =>
              preset.id.startsWith('system_') ||
              preset.id.startsWith('builtin_'),
        )
        .toList(growable: false);
    final managed = ref.watch(farmSlicingPresetsProvider);
    final cloudAsync = ref.watch(cloudParameterPresetsProvider);
    final cloudSession = ref.watch(
      bambuCloudProvider.select((state) => state.session),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            border: Border.all(color: Aurora.line),
          ),
          child: Row(
            children: [_libraryTab('拓竹官方', 0), _libraryTab('我的云端预设', 1)],
          ),
        ),
        const SizedBox(height: 14),
        if (_tab == 0)
          _buildOfficial(context, official)
        else
          _buildCloud(context, cloudAsync, cloudSession != null, managed),
      ],
    );
  }

  Widget _libraryTab(String label, int index) {
    final selected = _tab == index;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: () => setState(() => _tab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : Aurora.textSoft,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOfficial(
    BuildContext context,
    List<PrintParameterPreset> presets,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Bambu Studio 随软件提供的只读参数，适合直接作为切片起点。',
          style: Aurora.label(context).copyWith(height: 1.45),
        ),
        const SizedBox(height: 10),
        _librarySummary(
          context,
          icon: Icons.verified_outlined,
          color: AppColors.primary,
          text: '${presets.length} 套官方工艺参数 · 不会被个人修改',
        ),
        const SizedBox(height: 10),
        if (presets.isEmpty)
          _libraryEmpty(context, Icons.inventory_2_outlined, '官方参数正在加载')
        else
          for (final preset in presets.take(8))
            _presetLine(
              context,
              icon: Icons.tune_rounded,
              title: preset.name,
              subtitle:
                  '${preset.compatiblePrinters.firstOrNull ?? 'Bambu Lab'} · 层高 ${preset.quality.layerHeight} mm',
              badge: '官方',
            ),
        if (presets.length > 8)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              '还有 ${presets.length - 8} 套，可在参数广场查看全部。',
              style: Aurora.label(context),
            ),
          ),
      ],
    );
  }

  Widget _buildCloud(
    BuildContext context,
    AsyncValue<List<PrintParameterPreset>> cloudAsync,
    bool connected,
    List<FarmSlicingPreset> managed,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          connected
              ? '已连接拓竹云端，发送打印时可直接选择自己的预设。'
              : '登录拓竹账号后，这里会显示你在 Bambu Studio 中保存的云端预设。',
          style: Aurora.label(context).copyWith(height: 1.45),
        ),
        const SizedBox(height: 10),
        if (cloudAsync.isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (cloudAsync.hasError)
          _libraryEmpty(context, Icons.cloud_off_outlined, '云端预设暂时无法读取')
        else if (cloudAsync.valueOrNull?.isNotEmpty == true)
          for (final preset in cloudAsync.valueOrNull!.take(8))
            _presetLine(
              context,
              icon: Icons.cloud_done_outlined,
              title: preset.name,
              subtitle:
                  '${preset.compatiblePrinters.firstOrNull ?? '拓竹云端'} · 层高 ${preset.quality.layerHeight} mm',
              badge: '云端',
            )
        else
          _libraryEmpty(
            context,
            connected ? Icons.cloud_queue_outlined : Icons.login_outlined,
            connected ? '还没有云端预设' : '登录后查看你的云端预设',
          ),
        if (managed.isNotEmpty) ...[
          const SizedBox(height: 13),
          Text(
            '本地托管备份',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          for (final preset in managed.take(4))
            _presetLine(
              context,
              icon: Icons.folder_copy_outlined,
              title: preset.name,
              subtitle:
                  '${preset.displayModel} · ${preset.nozzleDiameter.toStringAsFixed(1)} mm',
              badge: '本地',
            ),
        ],
      ],
    );
  }

  Widget _presetLine(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String badge,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: Aurora.label(context),
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              badge,
              style: TextStyle(
                fontSize: 10,
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _librarySummary(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: Aurora.label(context))),
      ],
    );
  }

  Widget _libraryEmpty(BuildContext context, IconData icon, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Aurora.line),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Aurora.muted),
          const SizedBox(width: 8),
          Text(text, style: Aurora.label(context)),
        ],
      ),
    );
  }
}

class _ProjectMetrics extends StatelessWidget {
  const _ProjectMetrics({
    required this.projectCount,
    required this.plateCount,
    required this.readyCount,
    required this.runningCount,
    required this.completedCount,
  });
  final int projectCount;
  final int plateCount;
  final int readyCount;
  final int runningCount;
  final int completedCount;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 880 ? 4 : 2;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: width,
              child: MetricTile(
                label: '我的项目',
                value: '$projectCount',
                unit: '个',
                icon: 'monitor_item_print',
                color: AppColors.primary,
              ),
            ),
            SizedBox(
              width: width,
              child: MetricTile(
                label: '项目盘',
                value: '$plateCount',
                unit: '盘',
                icon: 'param_plate',
                color: Aurora.blue,
              ),
            ),
            SizedBox(
              width: width,
              child: MetricTile(
                label: '切片就绪',
                value: '$readyCount',
                unit: '/ $plateCount 盘',
                icon: 'completed',
                color: const Color(0xFF14A86B),
              ),
            ),
            SizedBox(
              width: width,
              child: MetricTile(
                label: '正在打印',
                value: '$runningCount',
                unit: '盘 · 已完成 $completedCount 次',
                icon: 'printer',
                color: Aurora.warning,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in const ['全部', '待准备', '打印中', '已完成'])
            if (GlassButtonsTheme.enabledOf(context))
              Semantics(
                selected: value == item,
                child: AppGlassButton(
                  label: item,
                  onPressed: () => onChanged(item),
                  variant: value == item
                      ? AppGlassButtonVariant.primary
                      : AppGlassButtonVariant.quiet,
                  compact: true,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 9,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  child: Text(
                    item,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              )
            else
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => onChanged(item),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: value == item
                        ? AppColors.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    item,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: value == item ? Colors.white : Aurora.textSoft,
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _ProjectEmptyState extends StatelessWidget {
  const _ProjectEmptyState({
    required this.hasAnyProjects,
    required this.dragging,
    required this.onImport,
  });
  final bool hasAnyProjects;
  final bool dragging;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FrostPanel(
        padding: const EdgeInsets.fromLTRB(42, 36, 42, 34),
        elevated: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: .10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                dragging ? Icons.download_rounded : Icons.layers_outlined,
                color: AppColors.primary,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              hasAnyProjects ? '没有符合条件的项目' : '从一个项目开始',
              style: Aurora.title(context).copyWith(fontSize: 18),
            ),
            const SizedBox(height: 7),
            Text(
              dragging
                  ? '松开鼠标，读取 3MF 中的每一张可打印盘'
                  : '把 Bambu Studio 的 3MF 拖到这里，或选择文件导入',
              style: Aurora.label(context),
            ),
            const SizedBox(height: 18),
            AuroraButton(
              label: '选择 3MF 文件',
              icon: 'add_filament',
              onPressed: onImport,
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonalErrorState extends StatelessWidget {
  const _PersonalErrorState({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Text(message, style: TextStyle(color: Aurora.danger)),
  );
}

class _PersonalProjectCard extends StatelessWidget {
  const _PersonalProjectCard({
    required this.order,
    required this.studio,
    required this.onImport,
  });
  final StudioOrder order;
  final StudioSnapshot studio;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final plates = studio.productionPlates
        .where((p) => p.orderId == order.id)
        .toList(growable: false);
    final workOrders = studio.workOrders
        .where((w) => w.orderId == order.id)
        .toList(growable: false);
    final total = workOrders.fold<int>(0, (sum, item) => sum + item.quantity);
    final completed = workOrders.fold<int>(
      0,
      (sum, item) => sum + item.completedQuantity,
    );
    final hasPrintHistory = workOrders.isNotEmpty;
    final progress = total == 0 ? 0.0 : (completed / total).clamp(0.0, 1.0);
    final packageCount = studio.productionPackages
        .where((p) => p.orderId == order.id)
        .length;
    final packages = studio.productionPackages
        .where((p) => p.orderId == order.id)
        .toList(growable: false);
    final ready = plates.where((p) => p.isSliced).length;
    final status = _personalProjectStatus(order, plates, workOrders);
    return FrostPanel(
      padding: EdgeInsets.zero,
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 15),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: _orderColor(status).withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.folder_copy_outlined,
                    color: _orderColor(status),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              order.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          StatusPill(
                            label: _orderStatus(status),
                            color: _orderColor(status),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$packageCount 个源文件 · $ready/${plates.length} 盘已准备 · 最近更新 ${DateFormat('MM-dd').format(order.updatedAt)}',
                        style: Aurora.label(context),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 166,
                  child: hasPrintHistory
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    minHeight: 6,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${(progress * 100).round()}%',
                                  style: Aurora.mono.copyWith(fontSize: 12),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '$completed / $total 次完成',
                              style: Aurora.label(context),
                            ),
                          ],
                        )
                      : Text(
                          '还没有打印记录',
                          textAlign: TextAlign.end,
                          style: Aurora.label(context),
                        ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Aurora.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: packages.isEmpty
                ? Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 17,
                        color: Aurora.muted,
                      ),
                      const SizedBox(width: 8),
                      Text('这个项目还没有源文件', style: Aurora.label(context)),
                      const Spacer(),
                      AuroraButton(
                        label: '导入文件',
                        icon: 'add_filament',
                        filled: false,
                        onPressed: onImport,
                      ),
                    ],
                  )
                : Column(
                    children: [
                      for (final package in packages)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _PersonalFileSection(
                            key: ValueKey('personal-file-${package.id}'),
                            package: package,
                            plates: plates
                                .where((plate) => plate.packageId == package.id)
                                .toList(growable: false),
                            studio: studio,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// One source file is an independent, collapsible group. This prevents a
/// multi-file import from turning into one long undifferentiated plate grid.
class _PersonalFileSection extends StatefulWidget {
  const _PersonalFileSection({
    super.key,
    required this.package,
    required this.plates,
    required this.studio,
  });

  final StudioProductionPackage package;
  final List<StudioProductionPlate> plates;
  final StudioSnapshot studio;

  @override
  State<_PersonalFileSection> createState() => _PersonalFileSectionState();
}

class _PersonalFileSectionState extends State<_PersonalFileSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final plates = widget.plates;
    final ready = plates.where((plate) => plate.isSliced).length;
    final workOrders = widget.studio.workOrders
        .where(
          (workOrder) =>
              plates.any((plate) => plate.id == workOrder.productionPlateId),
        )
        .toList(growable: false);
    final totalRuns = workOrders.fold<int>(
      0,
      (sum, workOrder) => sum + workOrder.quantity,
    );
    final completedRuns = workOrders.fold<int>(
      0,
      (sum, workOrder) => sum + workOrder.completedQuantity,
    );
    final progress = totalRuns == 0
        ? (plates.isEmpty ? 0.0 : ready / plates.length)
        : (completedRuns / totalRuns).clamp(0.0, 1.0);
    final sourceName = widget.package.sourceName.trim().isEmpty
        ? '未命名文件'
        : widget.package.sourceName.trim();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Aurora.line),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 10, 10),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      Icons.insert_drive_file_outlined,
                      size: 18,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${plates.length} 盘 · $ready 盘已切片',
                          style: Aurora.label(context),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 132,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: progress.clamp(0.0, 1.0),
                                  minHeight: 5,
                                  backgroundColor: AppColors.outlineVariant,
                                  color: progress >= 1
                                      ? const Color(0xFF14A86B)
                                      : AppColors.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 7),
                            Text(
                              '${(progress * 100).round()}%',
                              style: Aurora.mono.copyWith(fontSize: 11),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          totalRuns == 0
                              ? '切片准备进度'
                              : '$completedRuns / $totalRuns 次完成',
                          style: Aurora.label(context).copyWith(fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 7),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: Aurora.muted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: plates.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text('这个文件还没有可打印的盘', style: Aurora.label(context)),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = constraints.maxWidth >= 920
                            ? 4
                            : constraints.maxWidth >= 620
                            ? 3
                            : constraints.maxWidth >= 410
                            ? 2
                            : 1;
                        const gap = 10.0;
                        final cardWidth = columns == 1
                            ? constraints.maxWidth
                            : (constraints.maxWidth - gap * (columns - 1)) /
                                  columns;
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final plate in plates)
                              SizedBox(
                                width: cardWidth,
                                child: PersonalPlateCard(
                                  key: ValueKey(
                                    'personal-project-plate-${plate.id}',
                                  ),
                                  plate: plate,
                                  package: widget.package,
                                  studio: widget.studio,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}

class PersonalPlateCard extends ConsumerStatefulWidget {
  const PersonalPlateCard({
    super.key,
    required this.plate,
    required this.package,
    required this.studio,
  });
  final StudioProductionPlate plate;
  final StudioProductionPackage? package;
  final StudioSnapshot studio;

  @override
  ConsumerState<PersonalPlateCard> createState() => _PersonalPlateCardState();
}

class _PersonalPlateCardState extends ConsumerState<PersonalPlateCard> {
  bool _printing = false;
  bool _syncingSource = false;
  bool _editorSessionActive = false;
  String? _watchedSourcePath;
  _PersonalEditorFileSignature? _editorSignature;
  Timer? _editorPollTimer;
  Timer? _editorSyncTimer;

  @override
  void didUpdateWidget(covariant PersonalPlateCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPath = oldWidget.package?.localPath?.trim();
    final newPath = widget.package?.localPath?.trim();
    if (oldPath != newPath) {
      final resume = _editorSessionActive;
      _stopEditorWatcher();
      if (resume && newPath != null && newPath.isNotEmpty) {
        unawaited(_startEditorWatcher(newPath));
      }
    }
  }

  @override
  void dispose() {
    _stopEditorWatcher();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plate = widget.plate;
    final workOrders = widget.studio.workOrders
        .where((w) => w.productionPlateId == plate.id)
        .toList(growable: false);
    final completed = workOrders.fold<int>(
      0,
      (sum, item) => sum + item.completedQuantity,
    );
    final assigned = workOrders
        .where(
          (w) =>
              w.printerId != null &&
              w.status != StudioWorkOrderStatus.cancelled,
        )
        .length;
    final plateProgress = plate.requiredRuns <= 0
        ? 0.0
        : (completed / plate.requiredRuns).clamp(0.0, 1.0).toDouble();
    final sliceNozzle = plate.sliceNozzleDiameter;
    final sourcePath = widget.package?.localPath?.trim();
    return FrostPanel(
      padding: const EdgeInsets.all(11),
      color: Aurora.panelStrong,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PersonalPlatePreview(
            plate: plate,
            sourcePath: sourcePath,
            onArrange: _openArrange,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '第 ${plate.plateIndex} 盘 · ${plate.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              StatusPill(
                label: plate.isSliced ? '已切片' : '待切片',
                color: plate.isSliced
                    ? const Color(0xFF14A86B)
                    : Aurora.warning,
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            '${_duration(plate.estimatedSeconds)} · ${plate.estimatedGrams.toStringAsFixed(1)} g · ${plate.totalLayers} 层',
            style: Aurora.label(context),
          ),
          if (plate.isSliced &&
              plate.sliceTargetModel?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 4),
            Text(
              '已按 ${plate.sliceTargetModel}${sliceNozzle == null ? '' : ' · ${sliceNozzle.toStringAsFixed(1)} mm'} 切片',
              style: Aurora.label(context).copyWith(color: Aurora.blue),
            ),
          ],
          if (plate.activeFilaments.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                for (final filament in plate.activeFilaments)
                  _FilamentChip(filament: filament),
              ],
            ),
          ],
          const SizedBox(height: 9),
          Row(
            children: [
              Icon(
                assigned > 0
                    ? Icons.print_outlined
                    : Icons.pending_actions_outlined,
                size: 15,
                color: Aurora.muted,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '已完成 $completed / ${plate.requiredRuns}${assigned > 0 ? ' · 队列中 $assigned 次' : ''}',
                  style: Aurora.label(context),
                ),
              ),
              if (plate.isMulticolor)
                Text(
                  '${plate.activeFilaments.length} 色',
                  style: Aurora.label(context),
                ),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: plateProgress,
              minHeight: 4,
              backgroundColor: AppColors.outlineVariant,
              color: plateProgress >= 1
                  ? const Color(0xFF14A86B)
                  : AppColors.primary,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: plate.isSliced ? '切片设置' : '开始切片',
                  compact: true,
                  variant: AppButtonVariant.secondary,
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: _printing
                      ? null
                      : () => _startPrint(forceSliceOnly: true),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: AppButton(
                  label: _printing ? '准备中…' : '发送打印',
                  compact: true,
                  icon: const Icon(Icons.play_arrow_rounded),
                  onPressed: _printing
                      ? null
                      : () => _startPrint(forceSliceOnly: false),
                ),
              ),
            ],
          ),
          if (sourcePath != null && sourcePath.isNotEmpty) ...[
            const SizedBox(height: 5),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _syncingSource ? null : _syncSavedProjectCopy,
                icon: const Icon(Icons.sync_rounded, size: 15),
                label: Text(_syncingSource ? '同步中…' : '同步另存版本'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _startPrint({required bool forceSliceOnly}) async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      await _personalPlateWorkflow(
        context,
        ref,
        plate: widget.plate,
        package: widget.package,
        snapshot: widget.studio,
        forceSliceOnly: forceSliceOnly,
      );
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<void> _openArrange() async {
    final sourcePath = widget.package?.localPath?.trim();
    if (sourcePath == null || sourcePath.isEmpty) {
      _personalSnack(context, '当前项目没有可编辑的源 3MF', error: true);
      return;
    }
    final configuredExecutable = ref.read(slicerExecutableOverrideProvider);
    final result = await BambuStudioEditorService.openProject(
      sourcePath,
      configuredExecutable,
    );
    if (!mounted) return;
    switch (result.status) {
      case BambuStudioEditorLaunchStatus.opened:
        await _startEditorWatcher(sourcePath);
        if (!mounted) return;
        _personalSnack(context, '已打开拓竹原生工作区，可直接使用移动、旋转、缩放、切割、支撑和喷涂等工具');
      case BambuStudioEditorLaunchStatus.missingSource:
        _personalSnack(context, '当前项目源 3MF 不存在，请重新导入项目', error: true);
      case BambuStudioEditorLaunchStatus.missingExecutable:
        _personalSnack(
          context,
          '未检测到 Bambu Studio，无法打开原生模型编辑器；请先安装拓竹切片软件',
          error: true,
        );
      case BambuStudioEditorLaunchStatus.failed:
        _personalSnack(context, '拓竹模型工作区启动失败：${result.error}', error: true);
    }
  }

  Future<void> _startEditorWatcher(String sourcePath) async {
    _stopEditorWatcher();
    final signature = await _readEditorFileSignature(sourcePath);
    if (!mounted || signature == null) return;
    _editorSessionActive = true;
    _watchedSourcePath = sourcePath;
    _editorSignature = signature;
    _editorPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollEditorSource(),
    );
  }

  void _stopEditorWatcher() {
    _editorSessionActive = false;
    _editorPollTimer?.cancel();
    _editorPollTimer = null;
    _editorSyncTimer?.cancel();
    _editorSyncTimer = null;
    _watchedSourcePath = null;
    _editorSignature = null;
  }

  Future<void> _pollEditorSource() async {
    final path = _watchedSourcePath;
    final baseline = _editorSignature;
    if (path == null || baseline == null || _syncingSource) return;
    final current = await _readEditorFileSignature(path);
    if (current == null || current == baseline) return;
    _editorSyncTimer?.cancel();
    _editorSyncTimer = Timer(const Duration(seconds: 2), _syncEditedSource);
  }

  Future<void> _syncEditedSource() async {
    final path = _watchedSourcePath;
    final packageId = widget.package?.id;
    if (path == null || packageId == null || _syncingSource) return;
    final before = await _readEditorFileSignature(path);
    if (before == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final after = await _readEditorFileSignature(path);
    if (after == null || after != before) {
      _editorSyncTimer?.cancel();
      _editorSyncTimer = Timer(const Duration(seconds: 2), _syncEditedSource);
      return;
    }
    if (after == _editorSignature) return;

    setState(() => _syncingSource = true);
    try {
      final inspection = await ProductionPackageInspector.inspect(path);
      if (inspection == null || inspection.productionPlates.isEmpty) {
        _editorSignature = after;
        if (mounted) _personalSnack(context, '拓竹已保存，但项目盘信息暂时无法读取', error: true);
        return;
      }
      final refreshed = await ref
          .read(studioDaoProvider)
          .syncProductionPackageFromInspection(
            packageId: packageId,
            localPath: path,
            inspection: inspection,
          );
      _editorSignature = after;
      ref.invalidate(_personalPlateThumbnailsProvider(path));
      if (mounted) {
        _personalSnack(context, '已同步拓竹保存的项目，$refreshed 个盘的预览已更新；请重新切片后再打印');
      }
    } catch (error) {
      if (mounted) _personalSnack(context, '同步拓竹保存失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _syncingSource = false);
    }
  }

  Future<void> _syncSavedProjectCopy() async {
    final package = widget.package;
    final currentPath = package?.localPath?.trim();
    if (package == null || currentPath == null || currentPath.isEmpty) return;
    const group = XTypeGroup(label: 'Bambu Studio 项目', extensions: ['3mf']);
    final picked = await openFile(acceptedTypeGroups: const [group]);
    if (picked == null || !mounted) return;
    final selectedPath = picked.path.trim();
    if (selectedPath.isEmpty) return;
    setState(() => _syncingSource = true);
    try {
      final inspection = await ProductionPackageInspector.inspect(selectedPath);
      if (inspection == null || inspection.productionPlates.isEmpty) {
        throw const FormatException('这个文件没有可识别的模型盘');
      }
      final durablePath = await BambuStudioSlicingService.preserveSourceProject(
        selectedPath,
      );
      final refreshed = await ref
          .read(studioDaoProvider)
          .syncProductionPackageFromInspection(
            packageId: package.id,
            localPath: durablePath,
            sourceName: inspection.displayName,
            inspection: inspection,
          );
      ref.invalidate(_personalPlateThumbnailsProvider(currentPath));
      ref.invalidate(_personalPlateThumbnailsProvider(durablePath));
      await _startEditorWatcher(durablePath);
      if (mounted) {
        _personalSnack(context, '已同步另存版本，$refreshed 个盘的预览已更新');
      }
    } catch (error) {
      if (mounted) _personalSnack(context, '同步另存版本失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _syncingSource = false);
    }
  }
}

class _PersonalEditorFileSignature {
  const _PersonalEditorFileSignature(this.length, this.modifiedMicros);

  final int length;
  final int modifiedMicros;

  @override
  bool operator ==(Object other) =>
      other is _PersonalEditorFileSignature &&
      other.length == length &&
      other.modifiedMicros == modifiedMicros;

  @override
  int get hashCode => Object.hash(length, modifiedMicros);
}

Future<_PersonalEditorFileSignature?> _readEditorFileSignature(
  String path,
) async {
  try {
    final stat = await File(path).stat();
    return _PersonalEditorFileSignature(
      stat.size,
      stat.modified.microsecondsSinceEpoch,
    );
  } on FileSystemException {
    return null;
  }
}

class _PersonalPlatePreview extends ConsumerWidget {
  const _PersonalPlatePreview({
    required this.plate,
    required this.sourcePath,
    required this.onArrange,
  });
  final StudioProductionPlate plate;
  final String? sourcePath;
  final VoidCallback onArrange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = sourcePath?.trim();
    final thumbnails = path == null || path.isEmpty
        ? null
        : ref.watch(_personalPlateThumbnailsProvider(path));
    final fallback = thumbnails?.valueOrNull?[plate.plateIndex];
    final preview = plate.thumbnailBytes ?? fallback;
    final loadingPreview =
        plate.thumbnailBytes == null && thumbnails?.isLoading == true;
    final failedPreview =
        plate.thumbnailBytes == null && thumbnails?.hasError == true;
    return Semantics(
      button: true,
      label: '打开第 ${plate.plateIndex} 盘的拓竹工作区',
      child: AspectRatio(
        aspectRatio: 1.55,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onArrange,
            borderRadius: BorderRadius.circular(9),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: Aurora.line),
              ),
              child: preview == null
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.view_in_ar_outlined,
                          size: 25,
                          color: Aurora.muted,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          path == null || path.isEmpty
                              ? '暂无模型预览'
                              : loadingPreview
                              ? '读取预览中'
                              : failedPreview
                              ? '预览读取失败'
                              : '暂无缩略图',
                          style: Aurora.label(context),
                        ),
                        if (loadingPreview) ...[
                          const SizedBox(height: 7),
                          SizedBox(
                            width: 70,
                            child: LinearProgressIndicator(
                              minHeight: 3,
                              borderRadius: BorderRadius.circular(3),
                              color: AppColors.primary.withValues(alpha: .75),
                            ),
                          ),
                        ] else if (path != null && path.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            '点击打开拓竹工作区',
                            style: Aurora.label(
                              context,
                            ).copyWith(fontSize: 10, color: Aurora.muted),
                          ),
                        ],
                      ],
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        Image(
                          image: _personalPreviewProvider(plate.id, preview),
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.low,
                          gaplessPlayback: true,
                          frameBuilder:
                              (context, child, frame, wasSynchronouslyLoaded) {
                                if (wasSynchronouslyLoaded || frame != null) {
                                  return child;
                                }
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    child,
                                    const Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                          errorBuilder: (context, error, stackTrace) => Center(
                            child: Text(
                              '预览读取失败，点击打开拓竹工作区',
                              style: Aurora.label(context),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 7,
                          bottom: 7,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .54),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.open_in_full_rounded,
                                  size: 12,
                                  color: Colors.white,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  '拓竹工作区',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

final Map<String, ImageProvider<Object>> _personalPreviewCache =
    <String, ImageProvider<Object>>{};

ImageProvider<Object> _personalPreviewProvider(
  String plateId,
  Uint8List bytes,
) {
  var hash = bytes.length;
  if (bytes.isNotEmpty) {
    hash = 31 * hash + bytes.first;
    hash = 31 * hash + bytes[bytes.length ~/ 2];
    hash = 31 * hash + bytes.last;
  }
  final key = '$plateId:$hash';
  final cached = _personalPreviewCache[key];
  if (cached != null) return cached;
  final provider = ResizeImage(MemoryImage(bytes), width: 640, height: 420);
  _personalPreviewCache[key] = provider;
  if (_personalPreviewCache.length > 80) {
    _personalPreviewCache.remove(_personalPreviewCache.keys.first);
  }
  return provider;
}

class PersonalPlateArrangePage extends ConsumerStatefulWidget {
  const PersonalPlateArrangePage({
    super.key,
    required this.package,
    required this.plate,
  });

  final StudioProductionPackage? package;
  final StudioProductionPlate plate;

  @override
  ConsumerState<PersonalPlateArrangePage> createState() =>
      _PersonalPlateArrangePageState();
}

class _PersonalPlateArrangePageState
    extends ConsumerState<PersonalPlateArrangePage> {
  late Future<PersonalPlateEditorDocument> _documentFuture;
  PersonalPlateEditorDocument? _document;
  final List<List<PersonalEditableModel>> _undo = [];
  final List<List<PersonalEditableModel>> _redo = [];
  String? _selectedId;
  double _zoom = 1.7;
  Offset _canvasPan = Offset.zero;
  List<PersonalEditableModel>? _dragStartModels;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _documentFuture = _loadDocument();
  }

  Future<PersonalPlateEditorDocument> _loadDocument() async {
    final sourcePath = widget.package?.localPath?.trim();
    final document = await PersonalPlateEditorStore.load(
      sourcePath: sourcePath,
      plateIndex: widget.plate.plateIndex,
      // The editor reads the small model metadata itself. Avoid running the
      // production inspector here, which would scan an entire source archive
      // before the user can start arranging a plate.
      fallbackParts: const <ProductionPartInspection>[],
    );
    if (document.models.isNotEmpty) _selectedId = document.models.first.id;
    return document;
  }

  void _setDocument(PersonalPlateEditorDocument next, {bool record = true}) {
    final current = _document;
    if (record && current != null) {
      _undo.add(List<PersonalEditableModel>.from(current.models));
      if (_undo.length > 30) _undo.removeAt(0);
      _redo.clear();
    }
    setState(() => _document = next);
  }

  void _updateModel(
    String id,
    PersonalEditableModel Function(PersonalEditableModel) update, {
    bool record = true,
  }) {
    final document = _document;
    if (document == null) return;
    final models = [
      for (final model in document.models)
        model.id == id ? update(model) : model,
    ];
    _setDocument(
      PersonalPlateEditorDocument(
        sourcePath: document.sourcePath,
        plateIndex: document.plateIndex,
        models: models,
        width: document.width,
        depth: document.depth,
        restored: document.restored,
      ),
      record: record,
    );
  }

  void _beginModelDrag() {
    final document = _document;
    if (document == null) return;
    _dragStartModels = List<PersonalEditableModel>.from(document.models);
  }

  void _endModelDrag() {
    final start = _dragStartModels;
    final document = _document;
    _dragStartModels = null;
    if (start == null || document == null) return;
    final changed =
        start.length != document.models.length ||
        Iterable<int>.generate(
          start.length,
        ).any((index) => !identical(start[index], document.models[index]));
    if (!changed) return;
    _undo.add(start);
    if (_undo.length > 30) _undo.removeAt(0);
    _redo.clear();
    setState(() {});
  }

  PersonalEditableModel? get _selectedModel {
    final document = _document;
    if (document == null || _selectedId == null) return null;
    return document.models.where((item) => item.id == _selectedId).firstOrNull;
  }

  void _autoArrange() {
    final document = _document;
    if (document == null) return;
    final models = [
      for (var i = 0; i < document.models.length; i++)
        document.models[i].copyWith(
          x: 38 + (i % 4) * 60,
          y: 38 + (i ~/ 4) * 60,
          rotation: 0,
        ),
    ];
    _setDocument(
      PersonalPlateEditorDocument(
        sourcePath: document.sourcePath,
        plateIndex: document.plateIndex,
        models: models,
        width: document.width,
        depth: document.depth,
        restored: document.restored,
      ),
    );
  }

  void _centerSelected() {
    final model = _selectedModel;
    if (model == null) return;
    _updateModel(model.id, (item) => item.copyWith(x: 128, y: 128));
  }

  void _duplicateSelected() {
    final document = _document;
    final model = _selectedModel;
    if (document == null || model == null) return;
    final copy = PersonalEditableModel(
      id: '${model.id}:copy:${DateTime.now().microsecondsSinceEpoch}',
      name: '${model.name} 副本',
      x: (model.x + 16).clamp(8, 248),
      y: (model.y + 16).clamp(8, 248),
      z: model.z,
      rotation: model.rotation,
      scale: model.scale,
      width: model.width,
      depth: model.depth,
      height: model.height,
    );
    _setDocument(
      PersonalPlateEditorDocument(
        sourcePath: document.sourcePath,
        plateIndex: document.plateIndex,
        models: [...document.models, copy],
        width: document.width,
        depth: document.depth,
        restored: document.restored,
      ),
    );
    _selectedId = copy.id;
  }

  void _deleteSelected() {
    final document = _document;
    final model = _selectedModel;
    if (document == null || model == null || document.models.length <= 1)
      return;
    final models = document.models
        .where((item) => item.id != model.id)
        .toList();
    _selectedId = models.first.id;
    _setDocument(
      PersonalPlateEditorDocument(
        sourcePath: document.sourcePath,
        plateIndex: document.plateIndex,
        models: models,
        width: document.width,
        depth: document.depth,
        restored: document.restored,
      ),
    );
  }

  void _undoLast() {
    final document = _document;
    if (document == null || _undo.isEmpty) return;
    _redo.add(List<PersonalEditableModel>.from(document.models));
    final models = _undo.removeLast();
    setState(
      () => _document = PersonalPlateEditorDocument(
        sourcePath: document.sourcePath,
        plateIndex: document.plateIndex,
        models: models,
        width: document.width,
        depth: document.depth,
        restored: document.restored,
      ),
    );
  }

  void _redoLast() {
    final document = _document;
    if (document == null || _redo.isEmpty) return;
    _undo.add(List<PersonalEditableModel>.from(document.models));
    final models = _redo.removeLast();
    setState(
      () => _document = PersonalPlateEditorDocument(
        sourcePath: document.sourcePath,
        plateIndex: document.plateIndex,
        models: models,
        width: document.width,
        depth: document.depth,
        restored: document.restored,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppColors.bgBaseDark
          : AppColors.bgBase,
      appBar: AppBar(
        title: Text('摆盘 · 第 ${widget.plate.plateIndex} 盘'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: '返回项目',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: FutureBuilder<PersonalPlateEditorDocument>(
          future: _documentFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  '模型读取失败：${snapshot.error}',
                  style: Aurora.label(context),
                ),
              );
            }
            if (_document == null &&
                snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            _document ??= snapshot.data;
            final document = _document!;
            return Column(
              children: [
                _editorToolbar(context),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 900;
                      final canvas = FrostPanel(
                        elevated: true,
                        padding: EdgeInsets.zero,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(Aurora.radius),
                          child: PersonalPlateEditorCanvas(
                            models: document.models,
                            selectedId: _selectedId,
                            zoom: _zoom,
                            pan: _canvasPan,
                            onSelect: (id) => setState(() => _selectedId = id),
                            onMove: (id, delta) => _updateModel(
                              id,
                              (model) => model.copyWith(
                                x: (model.x + delta.dx).clamp(8, 248),
                                y: (model.y + delta.dy).clamp(8, 248),
                              ),
                              record: false,
                            ),
                            onMoveStart: _beginModelDrag,
                            onMoveEnd: _endModelDrag,
                            onPan: (delta) =>
                                setState(() => _canvasPan += delta),
                          ),
                        ),
                      );
                      final inspector = _buildInspector(context, document);
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(22, 6, 22, 22),
                        child: wide
                            ? Row(
                                children: [
                                  Expanded(child: canvas),
                                  const SizedBox(width: 14),
                                  SizedBox(width: 292, child: inspector),
                                ],
                              )
                            : Column(
                                children: [
                                  Expanded(child: canvas),
                                  const SizedBox(height: 12),
                                  SizedBox(height: 250, child: inspector),
                                ],
                              ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _editorToolbar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
      child: FrostPanel(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showZoom = constraints.maxWidth >= 720;
            return Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        BambuGlyphButton(
                          icon: 'topbar_undo',
                          tooltip: '撤销',
                          onPressed: _undo.isEmpty ? null : _undoLast,
                        ),
                        BambuGlyphButton(
                          icon: 'topbar_redo',
                          tooltip: '重做',
                          onPressed: _redo.isEmpty ? null : _redoLast,
                        ),
                        const SizedBox(width: 8),
                        BambuGlyphButton(
                          icon: 'automatic_material_renewal',
                          tooltip: '自动排布',
                          onPressed: _autoArrange,
                        ),
                        _EditorToolButton(
                          icon: Icons.center_focus_strong_rounded,
                          tooltip: '居中',
                          onPressed: _centerSelected,
                        ),
                        _EditorToolButton(
                          icon: Icons.vertical_align_bottom_rounded,
                          tooltip: '放平',
                          onPressed: _selectedModel == null
                              ? null
                              : () => _updateModel(
                                  _selectedId!,
                                  (model) => model.copyWith(rotation: 0),
                                ),
                        ),
                        BambuGlyphButton(
                          icon: 'tree_copy',
                          tooltip: '复制',
                          onPressed: _duplicateSelected,
                        ),
                        BambuGlyphButton(
                          icon: 'tree_delete',
                          tooltip: '删除',
                          onPressed: _deleteSelected,
                        ),
                        _EditorToolButton(
                          icon: Icons.fit_screen_rounded,
                          tooltip: '适合窗口',
                          onPressed: () => setState(() {
                            _canvasPan = Offset.zero;
                            _zoom = 1.7;
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
                if (showZoom) ...[
                  Icon(Icons.grid_4x4_rounded, size: 15, color: Aurora.muted),
                  SizedBox(
                    width: 110,
                    child: Slider(
                      value: _zoom,
                      min: .8,
                      max: 3.2,
                      onChanged: (value) => setState(() => _zoom = value),
                    ),
                  ),
                  Text(
                    '${(_zoom * 100).round()}%',
                    style: Aurora.label(context),
                  ),
                  const SizedBox(width: 8),
                ],
                AuroraButton(
                  label: _saving ? '保存中…' : '保存布局',
                  icon: 'topbar_save',
                  onPressed: _saving ? null : _saveLayout,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildInspector(
    BuildContext context,
    PersonalPlateEditorDocument document,
  ) {
    final selected = _selectedModel;
    return FrostPanel(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('对象', style: Aurora.title(context).copyWith(fontSize: 16)),
              const Spacer(),
              Text('${document.models.length}', style: Aurora.label(context)),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              itemCount: document.models.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final model = document.models[index];
                final active = model.id == _selectedId;
                return Material(
                  color: active
                      ? AppColors.primary.withValues(alpha: .10)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(7),
                    onTap: () => setState(() => _selectedId = model.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.view_in_ar_outlined,
                            size: 16,
                            color: active ? AppColors.primary : Aurora.muted,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              model.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: active
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          if (active)
                            Icon(
                              Icons.check_rounded,
                              size: 15,
                              color: AppColors.primary,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 16),
          if (selected == null)
            Text('选择一个模型查看属性', style: Aurora.label(context))
          else ...[
            _transformSlider(
              context,
              'X',
              selected.x,
              8,
              248,
              (value) => _updateModel(
                selected.id,
                (model) => model.copyWith(x: value),
              ),
            ),
            _transformSlider(
              context,
              'Y',
              selected.y,
              8,
              248,
              (value) => _updateModel(
                selected.id,
                (model) => model.copyWith(y: value),
              ),
            ),
            _transformSlider(
              context,
              '旋转',
              selected.rotation * 180 / math.pi,
              -180,
              180,
              (value) => _updateModel(
                selected.id,
                (model) => model.copyWith(rotation: value * math.pi / 180),
              ),
            ),
            _transformSlider(
              context,
              '缩放',
              selected.scale,
              .1,
              3,
              (value) => _updateModel(
                selected.id,
                (model) => model.copyWith(scale: value),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _transformSlider(
    BuildContext context,
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(width: 34, child: Text(label, style: Aurora.label(context))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            value.toStringAsFixed(label == '缩放' ? 2 : 0),
            textAlign: TextAlign.right,
            style: Aurora.label(context),
          ),
        ),
      ],
    );
  }

  Future<void> _saveLayout() async {
    final document = _document;
    if (document == null) return;
    setState(() => _saving = true);
    try {
      final saved = await PersonalPlateEditorStore.save(document);
      if (mounted) {
        _personalSnack(
          context,
          saved == null ? '当前项目没有可保存的源 3MF' : '个人摆盘布局已保存',
        );
      }
    } catch (error) {
      if (mounted) _personalSnack(context, '布局保存失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _EditorToolButton extends StatelessWidget {
  const _EditorToolButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: const Duration(milliseconds: 450),
    child: SizedBox.square(
      dimension: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        color: onPressed == null ? Aurora.muted : Aurora.textSoft,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    ),
  );
}

class _FilamentChip extends StatelessWidget {
  const _FilamentChip({required this.filament});
  final StudioPlateFilamentUsage filament;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: _hexColor(filament.colorHex),
            shape: BoxShape.circle,
            border: Border.all(color: Aurora.line),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          'T${filament.toolIndex + 1} ${filament.materialType ?? ''}',
          style: const TextStyle(fontSize: 10),
        ),
      ],
    ),
  );
}

Future<void> _personalPlateWorkflow(
  BuildContext context,
  WidgetRef ref, {
  required StudioProductionPlate plate,
  required StudioProductionPackage? package,
  required StudioSnapshot snapshot,
  required bool forceSliceOnly,
}) async {
  final printers = await ref.read(printersWithChannelsProvider.future);
  final fleet = ref.read(fleetPrinterStatesProvider);
  if (!context.mounted) return;
  final maxRuns = snapshot.workOrders
      .where(
        (item) =>
            item.productionPlateId == plate.id &&
            item.printerId == null &&
            item.status != StudioWorkOrderStatus.cancelled,
      )
      .fold<int>(0, (sum, item) => sum + item.quantity);
  if (!forceSliceOnly && maxRuns <= 0) {
    _personalSnack(context, '这一盘已经全部安排，没有待打印份数');
    return;
  }
  final selection = await showPersonalPrintSetupDialog(
    context,
    ref,
    plate: plate,
    printers: printers,
    fleet: fleet,
    printAction: !forceSliceOnly,
    maxRuns: math.max(1, maxRuns),
  );
  if (selection == null || !context.mounted) return;
  var selectedState = selection.state;
  var selectedPrinter = selection.printer;
  // The dialog can stay open while a printer starts/finishes a job.  Refresh
  // once more immediately before material mapping so we never reserve a slot
  // against a stale AMS snapshot or send to a device that went offline.
  if (!forceSliceOnly) {
    final serial = selection.printer.serial?.trim();
    if (serial == null || serial.isEmpty) {
      _personalSnack(context, '打印机没有序列号，无法发送任务', error: true);
      return;
    }
    final latest = await ref
        .read(printerFleetConnectionManagerProvider.notifier)
        .ensureFreshStatus(serial, SchedulingConfig.defaults);
    if (!context.mounted) return;
    if (latest == null ||
        !latest.canAcceptQueuedTask(SchedulingConfig.defaults)) {
      _personalSnack(context, '打印机状态已变化或已过期，请刷新后重试', error: true);
      return;
    }
    selectedState = latest;
    // The fleet refresh synchronizes the live AMS/external layout in the
    // database. Read the printer again so channel ids, bindings and remaining
    // grams used by the mapping dialog belong to that same snapshot.
    selectedPrinter =
        await ref
            .read(printerDaoProvider)
            .getByIdWithChannels(selection.printer.printer.id) ??
        selection.printer;
  }
  final target = _PersonalSlicingTarget(
    model: PrinterModelNormalizer.normalize(selectedState.reportedModel!),
    nozzleDiameter: selectedState.installedNozzleDiameter!,
  );
  var currentPlate = plate;
  final sameTarget =
      currentPlate.sliceTargetModel?.trim().isNotEmpty == true &&
      PrinterModelNormalizer.sameModel(
        currentPlate.sliceTargetModel!,
        target.model,
      ) &&
      currentPlate.sliceNozzleDiameter != null &&
      (currentPlate.sliceNozzleDiameter! - target.nozzleDiameter).abs() < .001;
  final shouldSlice =
      !currentPlate.isSliced || !sameTarget || selection.preset != null;
  if (shouldSlice) {
    final sourcePath = package?.localPath?.trim();
    if (sourcePath == null || sourcePath.isEmpty) {
      _personalSnack(context, '没有找到源 3MF，无法按当前参数切片', error: true);
      return;
    }
    if (selection.preset == null) {
      _personalSnack(context, '请选择一套拓竹参数后再切片', error: true);
      return;
    }
    final status = await ref.read(activeSlicerStatusProvider.future);
    final executable = status?.executablePath;
    if (executable == null) {
      _personalSnack(context, '未找到 Bambu Studio，请先在设置中配置路径', error: true);
      return;
    }
    final dao = ref.read(studioDaoProvider);
    try {
      await dao.updateProductionPlateSlice(
        id: currentPlate.id,
        status: StudioPlateSliceStatus.slicing,
      );
      await ref
          .read(farmSlicingPresetsProvider.notifier)
          .validateManagedPreset(
            selection.preset!,
            model: target.model,
            nozzleDiameter: target.nozzleDiameter,
          );
      final result = await ref
          .read(farmSliceIntakeProvider.notifier)
          .runManagedSlice(
            () => BambuStudioSlicingService.sliceProject(
              executablePath: executable,
              sourcePath: sourcePath,
              plateIndex: currentPlate.plateIndex,
              settingsPaths: selection.preset!.settingsPaths,
              filamentSettingsPaths: selection.preset!.filamentSettingsPaths,
            ),
            inspectionOf: (value) => value.inspection,
            sourcePath: sourcePath,
          );
      final sliced = result.inspection.plates
          .where(
            (item) =>
                item.plateIndex == currentPlate.plateIndex && item.hasToolpath,
          )
          .firstOrNull;
      if (sliced == null)
        throw const BambuStudioSliceException('切片结果中没有这一盘的刀路');
      await dao.updateProductionPlateSlice(
        id: currentPlate.id,
        status: StudioPlateSliceStatus.sliced,
        artifactPath: result.outputPath,
        artifactSha256: result.inspection.artifactSha256,
        estimatedSeconds: sliced.estimatedSeconds,
        estimatedGrams: sliced.estimatedGrams,
        totalLayers: sliced.totalLayers,
        toolChangeCount: sliced.toolChangeCount,
        targetModel: target.model,
        nozzleDiameter: target.nozzleDiameter,
        thumbnailBytes: sliced.thumbnailBytes,
        filaments: [
          for (final item in sliced.filaments)
            StudioPlateFilamentUsage(
              toolIndex: item.toolIndex,
              grams: item.grams,
              vendor: item.vendor,
              materialType: item.materialType,
              colorHex: item.colorHex,
              trayId: item.trayId,
              sku: item.sku,
              usedForObject: item.usedForObject,
              usedForSupport: item.usedForSupport,
              groupId: item.groupId,
              nozzleDiameter: item.nozzleDiameter,
              volumeType: item.volumeType,
            ),
        ],
      );
      if (!context.mounted) return;
      _personalSnack(
        context,
        forceSliceOnly
            ? '第 ${currentPlate.plateIndex} 盘已按“${selection.preset!.name}”重新切片'
            : '切片完成，正在准备供料槽位',
      );
      if (forceSliceOnly) return;
      currentPlate = (await dao.getDefaultSnapshot()).productionPlates
          .where((item) => item.id == currentPlate.id)
          .first;
    } catch (error) {
      await dao.updateProductionPlateSlice(
        id: currentPlate.id,
        status: StudioPlateSliceStatus.failed,
      );
      if (context.mounted) _personalSnack(context, '切片失败：$error', error: true);
      return;
    }
  }
  if (forceSliceOnly) return;
  final freshSnapshot = await ref.read(studioDaoProvider).getDefaultSnapshot();
  final freshPlate = freshSnapshot.productionPlates
      .where((item) => item.id == currentPlate.id)
      .firstOrNull;
  if (freshPlate == null || !freshPlate.isSliced) {
    if (context.mounted) _personalSnack(context, '这一盘尚未准备好打印', error: true);
    return;
  }
  final artifact = freshPlate.sliceArtifactPath?.trim();
  if (artifact == null || artifact.isEmpty) {
    if (context.mounted)
      _personalSnack(context, '切片文件路径不可用，请重新切片', error: true);
    return;
  }
  final stable = await SliceArtifactHashService.computeStable(artifact);
  if (stable == null) {
    if (context.mounted) _personalSnack(context, '切片文件仍在变化，已阻止发送', error: true);
    return;
  }
  if (freshPlate.sliceArtifactSha256?.trim().isNotEmpty == true &&
      freshPlate.sliceArtifactSha256!.trim().toLowerCase() !=
          stable.sha256Hex.toLowerCase()) {
    if (context.mounted) {
      _personalSnack(context, '切片文件内容已变化，已阻止发送；请重新切片后再试', error: true);
    }
    return;
  }
  final mapping = await _showPersonalMaterialMappingDialog(
    context,
    ref,
    plate: freshPlate,
    printer: selectedPrinter,
    status: selectedState.lastStatus,
    runs: selection.runs,
  );
  if (mapping == null || !context.mounted) return;
  final consumableByTool = <int, int>{};
  final channelByTool = <int, int>{};
  for (final entry in mapping.entries) {
    consumableByTool[entry.key] = entry.value.consumable!.id;
    channelByTool[entry.key] = entry.value.channel.id;
  }
  // Recheck the aggregate demand after the operator has changed mappings.
  // The dialog's initial availability is only a snapshot; another queued
  // task may have reserved the same physical AMS/external slot meanwhile.
  final demandByChannel = <int, double>{};
  for (final filament
      in freshPlate.activeFilaments.isEmpty
          ? [
              StudioPlateFilamentUsage(
                toolIndex: 0,
                grams: freshPlate.estimatedGrams,
              ),
            ]
          : freshPlate.activeFilaments) {
    final slot = mapping[filament.toolIndex];
    if (slot == null) continue;
    demandByChannel.update(
      slot.channel.id,
      (value) => value + filament.grams * selection.runs,
      ifAbsent: () => filament.grams * selection.runs,
    );
  }
  for (final demand in demandByChannel.entries) {
    final available = await ref
        .read(studioDaoProvider)
        .getPrinterChannelAvailableGrams(demand.key);
    if (available + .001 < demand.value) {
      if (context.mounted) {
        _personalSnack(
          context,
          '所选槽位刚刚被其他任务占用，只剩 ${available.toStringAsFixed(1)}g，'
          '本次需要 ${demand.value.toStringAsFixed(1)}g；请重新选择槽位',
          error: true,
        );
      }
      return;
    }
  }
  final maxTool = mapping.keys.fold<int>(-1, math.max);
  final amsMapping = maxTool < 0
      ? null
      : List<int>.generate(
          maxTool + 1,
          (tool) => mapping[tool]?.channel.channelIndex ?? -1,
          growable: false,
        );
  try {
    final serial = selectedPrinter.serial;
    if (serial == null || serial.trim().isEmpty) throw StateError('打印机没有序列号');
    await StudioDispatchService(
      database: ref.read(databaseProvider),
      studioDao: ref.read(studioDaoProvider),
      printQueueDao: ref.read(printQueueDaoProvider),
    ).dispatchPlateRuns(
      StudioPlateDispatchRequest(
        productionPlateId: freshPlate.id,
        printerId: selectedPrinter.printer.id,
        printerSerial: serial,
        runs: selection.runs,
        gcodePath: artifact,
        filename: artifact.split(RegExp(r'[/\\]')).last,
        artifactSha256: stable.sha256Hex,
        consumableByTool: consumableByTool,
        printerChannelByTool: channelByTool,
        amsMapping: amsMapping,
      ),
    );
    final failure = await ref
        .read(printQueueProvider(serial).notifier)
        .activateCommittedStudioDispatch([artifact]);
    if (context.mounted)
      _personalSnack(
        context,
        failure == null
            ? '第 ${freshPlate.plateIndex} 盘已发送到 ${selection.label}，共 ${selection.runs} 份'
            : '打印已保存到队列，但自动发送被阻止：$failure',
        error: failure != null,
      );
  } catch (error) {
    if (context.mounted) _personalSnack(context, '发送失败：$error', error: true);
  }
}

class PersonalPrintSelection {
  const PersonalPrintSelection({
    required this.printer,
    required this.state,
    required this.runs,
    this.preset,
  });
  final PrinterWithChannels printer;
  final FleetPrinterState state;
  final int runs;
  final FarmSlicingPreset? preset;
  String get label => printer.printer.name?.trim().isNotEmpty == true
      ? printer.printer.name!.trim()
      : printer.printer.model;
}

/// A printer option used by the personal print setup dialog.  Keep the
/// printer row even when it cannot be selected so the operator can see why a
/// device was excluded (cloud-only, stale status, missing nozzle, and so on)
/// instead of wondering why it disappeared from the list.
class _PersonalPrinterCandidate {
  const _PersonalPrinterCandidate({required this.printer, this.state});

  final PrinterWithChannels printer;
  final FleetPrinterState? state;

  String get label => printer.printer.name?.trim().isNotEmpty == true
      ? printer.printer.name!.trim()
      : printer.printer.model;

  String get modelLabel {
    final model = state?.reportedModel?.trim();
    return model == null || model.isEmpty ? printer.printer.model : model;
  }

  bool canSelect({required bool printAction}) {
    final current = state;
    if (printer.serial?.trim().isEmpty != false || current == null) {
      return false;
    }
    if (!PrinterModelNormalizer.isKnownBambuModel(
      current.reportedModel ?? '',
    )) {
      return false;
    }
    if (current.installedNozzleDiameter == null ||
        current.installedNozzleDiameter! <= 0) {
      return false;
    }
    return !printAction ||
        current.canAcceptQueuedTask(SchedulingConfig.defaults);
  }

  String unavailableReason({required bool printAction}) {
    if (printer.serial?.trim().isEmpty != false) return '缺少序列号';
    final current = state;
    if (current == null) return '尚未获取状态';
    if (!PrinterModelNormalizer.isKnownBambuModel(
      current.reportedModel ?? '',
    )) {
      return '机型未识别';
    }
    if (current.installedNozzleDiameter == null ||
        current.installedNozzleDiameter! <= 0) {
      return '喷嘴未知';
    }
    if (!printAction) return '可用于切片';
    if (!current.isLanCapable) return '仅云端';
    if (current.connectionState != PrinterConnectionState.connected) {
      return current.isConnecting ? '连接中' : '离线';
    }
    if (current.isStale(SchedulingConfig.defaults)) return '状态过期';
    final status = current.lastStatus;
    if (status?.upgradeStatus?.isNotEmpty == true) return '升级中';
    return switch (status?.gcodeState) {
      BambuGcodeState.running => '打印中（可预排）',
      BambuGcodeState.pause => '已暂停（可预排）',
      BambuGcodeState.init || BambuGcodeState.prepare => '准备中（可预排）',
      BambuGcodeState.failed => '设备异常',
      BambuGcodeState.offline => '设备离线',
      BambuGcodeState.slicing => '设备切片中',
      BambuGcodeState.unknown || null => '状态未知',
      _ => '暂不可用',
    };
  }

  String materialSummary() {
    final status = state?.lastStatus;
    final ams = detectedAmsSummary(status);
    final external = printer.channels
        .where((item) => isExternalFeedChannel(item.channel.channelIndex))
        .length;
    final loaded = printer.channels.where((item) => item.isActive).length;
    return '$ams · ${externalFeedSummary(externalInputCount: external, status: status)} · 已装 $loaded 槽';
  }
}

/// Exact printer target selected for this one personal project plate.
///
/// This local value object keeps the personal UI independent from the farm
/// workflow/picker layer while still sharing the same slicing service.
class _PersonalSlicingTarget {
  const _PersonalSlicingTarget({
    required this.model,
    required this.nozzleDiameter,
  });

  final String model;
  final double nozzleDiameter;
}

Future<PersonalPrintSelection?> showPersonalPrintSetupDialog(
  BuildContext context,
  WidgetRef ref, {
  required StudioProductionPlate plate,
  required List<PrinterWithChannels> printers,
  required List<FleetPrinterState> fleet,
  required bool printAction,
  required int maxRuns,
}) async {
  var currentFleet = fleet;
  List<_PersonalPrinterCandidate> allCandidates() {
    final result = [
      for (final printer in printers)
        _PersonalPrinterCandidate(
          printer: printer,
          state: printer.serial?.trim().isEmpty != false
              ? null
              : currentFleet
                    .where(
                      (item) => item.serial.trim() == printer.serial!.trim(),
                    )
                    .firstOrNull,
        ),
    ];
    result.sort((a, b) {
      final selectable = b.canSelect(printAction: printAction) ? 1 : 0;
      final otherSelectable = a.canSelect(printAction: printAction) ? 1 : 0;
      return otherSelectable != selectable
          ? selectable.compareTo(otherSelectable)
          : a.label.compareTo(b.label);
    });
    return result;
  }

  final initialCandidates = allCandidates();
  final selectableCandidates = initialCandidates
      .where((item) => item.canSelect(printAction: printAction))
      .toList(growable: false);
  if (selectableCandidates.isEmpty) {
    await AppDialog.show<void>(
      context: context,
      title: '没有可用的打印机',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            printAction
                ? '请先连接一台局域网拓竹打印机，或在设备页刷新状态。'
                : '请先连接并同步一台拓竹打印机，才能选择对应的切片参数。',
            style: Aurora.label(context).copyWith(height: 1.5),
          ),
          if (initialCandidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final item in initialCandidates.take(4))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${item.label} · ${item.unavailableReason(printAction: printAction)}',
                  style: Aurora.label(context),
                ),
              ),
          ],
        ],
      ),
      actions: [
        AppButton(
          label: '知道了',
          compact: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
    return null;
  }
  final notifier = ref.read(farmSlicingPresetsProvider.notifier);
  await notifier.ready;
  var selected = selectableCandidates.first;
  var runs = 1;
  var selectedPreset =
      (!plate.isSliced ||
          !printAction ||
          !_plateMatchesTarget(plate, selected.state!))
      ? _compatiblePreset(ref, selected.state!)
      : null;
  return showDialog<PersonalPrintSelection>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final candidates = allCandidates()
            .where((item) => item.canSelect(printAction: printAction))
            .toList(growable: false);
        // A status refresh can make the previously selected printer
        // unavailable. Keep the dialog valid by moving to the first current
        // candidate instead of dereferencing stale state.
        if (!candidates.any(
          (item) => item.printer.printer.id == selected.printer.printer.id,
        )) {
          if (candidates.isNotEmpty) {
            selected = candidates.first;
            selectedPreset =
                (!plate.isSliced ||
                    !printAction ||
                    !_plateMatchesTarget(plate, selected.state!))
                ? _compatiblePreset(ref, selected.state!)
                : null;
          }
        }
        final target = selected.state!;
        final unavailable = allCandidates()
            .where((item) => !item.canSelect(printAction: printAction))
            .toList(growable: false);
        final presets = _compatiblePresets(ref, target);
        final canReuseCurrentSlice =
            plate.isSliced && _plateMatchesTarget(plate, target);
        final needsPreset = !canReuseCurrentSlice;
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          printAction ? '开始前确认一下' : '为这一盘选择参数',
                          style: Aurora.title(context).copyWith(fontSize: 19),
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新设备状态',
                        onPressed: () async {
                          await ref
                              .read(
                                printerFleetConnectionManagerProvider.notifier,
                              )
                              .monitorAllConfigured();
                          if (!context.mounted) return;
                          setState(() {
                            currentFleet = ref.read(fleetPrinterStatesProvider);
                          });
                        },
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  Text(
                    '第 ${plate.plateIndex} 盘 · ${plate.name} · 只影响这一盘',
                    style: Aurora.label(context),
                  ),
                  const SizedBox(height: 17),
                  if (candidates.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(AppColors.radiusMd),
                        border: Border.all(
                          color: AppColors.warning.withValues(alpha: .28),
                        ),
                      ),
                      child: Text(
                        '已没有满足当前条件的设备，请点击右上角刷新状态。',
                        style: Aurora.label(
                          context,
                        ).copyWith(color: Aurora.warning),
                      ),
                    )
                  else if (candidates.length == 1)
                    _SinglePrinterSummary(state: target, label: selected.label)
                  else
                    _SetupSelect<PrinterWithChannels>(
                      label: '打印到哪台机器',
                      value: selected.printer,
                      items: [
                        for (final item in candidates)
                          DropdownMenuItem(
                            value: item.printer,
                            child: Text(
                              '${item.label} · ${item.modelLabel} · ${item.state!.installedNozzleDiameter!.toStringAsFixed(1)} mm 喷嘴',
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        final next = candidates.firstWhere(
                          (item) => item.printer.printer.id == value.printer.id,
                        );
                        setState(() {
                          selected = next;
                          selectedPreset =
                              (!plate.isSliced ||
                                  !printAction ||
                                  !_plateMatchesTarget(plate, next.state!))
                              ? _compatiblePreset(ref, next.state!)
                              : null;
                        });
                      },
                    ),
                  const SizedBox(height: 12),
                  _PersonalPrinterFacts(candidate: selected),
                  if (unavailable.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '未参与本次选择：${unavailable.take(3).map((item) => '${item.label}（${item.unavailableReason(printAction: printAction)}）').join('、')}${unavailable.length > 3 ? ' 等 ${unavailable.length} 台' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Aurora.label(
                        context,
                      ).copyWith(color: Aurora.muted),
                    ),
                  ],
                  _SetupSelect<FarmSlicingPreset?>(
                    label: '拓竹参数方案',
                    value: selectedPreset,
                    items: [
                      const DropdownMenuItem<FarmSlicingPreset?>(
                        value: null,
                        child: Text('沿用当前切片参数'),
                      ),
                      for (final preset in presets)
                        DropdownMenuItem(
                          value: preset,
                          child: Text(
                            '${preset.name} · ${preset.processConfigName} · ${preset.filamentConfigNames.length} 种耗材',
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => selectedPreset = value),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    selectedPreset == null && needsPreset
                        ? '这张盘需要一套兼容的拓竹参数。请先在参数库导入 Bambu Studio 的机器、工艺和耗材 JSON。'
                        : selectedPreset == null
                        ? '当前切片文件会直接使用已保存的机器和工艺参数。'
                        : '发送前会复检机器、喷嘴和托管 JSON；选择不同方案会只重新切当前这一盘。',
                    style: Aurora.label(context).copyWith(height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text('打印份数', style: Aurora.label(context)),
                      const SizedBox(width: 12),
                      DropdownButton<int>(
                        value: runs,
                        items: [
                          for (var i = 1; i <= maxRuns; i++)
                            DropdownMenuItem(value: i, child: Text('$i 份')),
                        ],
                        onChanged: (value) => setState(() => runs = value ?? 1),
                      ),
                      const Spacer(),
                      if (plate.isMulticolor)
                        const Icon(
                          Icons.palette_outlined,
                          size: 16,
                          color: Aurora.violet,
                        ),
                      if (plate.isMulticolor) const SizedBox(width: 5),
                      if (plate.isMulticolor)
                        Text(
                          '${plate.activeFilaments.length} 色打印',
                          style: Aurora.label(context),
                        ),
                    ],
                  ),
                  const SizedBox(height: 19),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      AppButton(
                        label: '取消',
                        compact: true,
                        variant: AppButtonVariant.secondary,
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 9),
                      AppButton(
                        label: printAction ? '继续并检查耗材' : '开始切片',
                        compact: true,
                        onPressed:
                            !selected.canSelect(printAction: printAction) ||
                                (needsPreset && selectedPreset == null)
                            ? null
                            : () => Navigator.pop(
                                context,
                                PersonalPrintSelection(
                                  printer: selected.printer,
                                  state: selected.state!,
                                  runs: runs,
                                  preset: selectedPreset,
                                ),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _SinglePrinterSummary extends StatelessWidget {
  const _SinglePrinterSummary({required this.state, required this.label});
  final FleetPrinterState state;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(color: Aurora.line),
      ),
      child: Row(
        children: [
          Icon(Icons.print_outlined, size: 19, color: AppColors.primary),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            '${state.reportedModel} · ${state.installedNozzleDiameter!.toStringAsFixed(1)} mm',
            style: Aurora.label(context),
          ),
        ],
      ),
    );
  }
}

class _PersonalPrinterFacts extends StatelessWidget {
  const _PersonalPrinterFacts({required this.candidate});

  final _PersonalPrinterCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final state = candidate.state;
    final status = state?.lastStatus;
    final scheme = Theme.of(context).colorScheme;
    final serial = candidate.printer.serial?.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 9),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(color: Aurora.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.settings_input_component_outlined,
                size: 16,
                color: AppColors.primary,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${candidate.modelLabel} · ${state?.installedNozzleDiameter?.toStringAsFixed(1) ?? '?'} mm 喷嘴',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                state?.mode == BambuConnectionMode.lan ? 'LAN' : '云端',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            '${candidate.materialSummary()}${serial == null || serial.isEmpty ? '' : ' · SN ${_shortSerial(serial)}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Aurora.label(context),
          ),
          if (status?.gcodeState != null) ...[
            const SizedBox(height: 3),
            Text(
              '当前状态：${status!.gcodeState!.label}${status.mcRemainingTime == null || status.mcRemainingTime! <= 0 ? '' : ' · 预计剩余 ${status.mcRemainingTime} 分钟'}',
              style: Aurora.label(
                context,
              ).copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

String _shortSerial(String serial) {
  final value = serial.trim();
  if (value.length <= 10) return value;
  return '${value.substring(0, 4)}…${value.substring(value.length - 4)}';
}

class _SetupSelect<T> extends StatelessWidget {
  const _SetupSelect({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(
      labelText: label,
      filled: true,
      fillColor: AppColors.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        borderSide: BorderSide(color: Aurora.line),
      ),
    ),
    items: items,
    onChanged: onChanged,
  );
}

List<FarmSlicingPreset> _compatiblePresets(
  WidgetRef ref,
  FleetPrinterState state,
) {
  final model = state.reportedModel;
  final nozzle = state.installedNozzleDiameter;
  if (model == null || nozzle == null) return const [];
  return ref
      .read(farmSlicingPresetsProvider.notifier)
      .compatiblePresets(model, nozzle);
}

FarmSlicingPreset? _compatiblePreset(WidgetRef ref, FleetPrinterState state) =>
    _compatiblePresets(ref, state).firstOrNull;

bool _plateMatchesTarget(StudioProductionPlate plate, FleetPrinterState state) {
  final model = state.reportedModel;
  final nozzle = state.installedNozzleDiameter;
  if (model == null || nozzle == null) return false;
  return plate.sliceTargetModel?.trim().isNotEmpty == true &&
      PrinterModelNormalizer.sameModel(plate.sliceTargetModel!, model) &&
      plate.sliceNozzleDiameter != null &&
      (plate.sliceNozzleDiameter! - nozzle).abs() < .001;
}

Future<Map<int, ChannelWithConsumable>?> _showPersonalMaterialMappingDialog(
  BuildContext context,
  WidgetRef ref, {
  required StudioProductionPlate plate,
  required PrinterWithChannels printer,
  required BambuPrinterStatus? status,
  required int runs,
}) async {
  final filaments = plate.activeFilaments.isEmpty
      ? [StudioPlateFilamentUsage(toolIndex: 0, grams: plate.estimatedGrams)]
      : plate.activeFilaments;
  final stock =
      ref.read(consumablesProvider).valueOrNull ?? const <Consumable>[];
  final stockIds = stock.map((item) => item.id).toSet();
  final amsState = detectedAmsState(status);
  final amsTypes = detectedAmsTypes(status);
  final preset = PrinterPresets.findByModel(
    printer.printer.model,
    brand: printer.printer.brand,
  );
  final dualFeed = preset?.externalInputCount == 2;
  final toolExtruders = await readBambuToolExtruders(
    plate.sliceArtifactPath ?? '',
    plateIndex: plate.plateIndex,
  );
  final configuredAmsChannels = printer.channels
      .where((slot) => !isExternalFeedChannel(slot.channel.channelIndex))
      .toList(growable: false);
  // Incremental MQTT messages can omit AMS fields even though the local
  // channel layout is already synchronized. Keep those known slots selectable
  // while still treating an explicit empty AMS report as disconnected.
  final amsSelectable =
      amsState == AmsDetectionState.present ||
      (amsState == AmsDetectionState.unknown &&
          configuredAmsChannels.isNotEmpty);
  final externalCount = printer.channels
      .where((slot) => isExternalFeedChannel(slot.channel.channelIndex))
      .length;
  final channels = printer.channels
      .where((slot) {
        if (slot.consumable == null ||
            !stockIds.contains(slot.consumable!.id) ||
            slot.farmRollPaused ||
            slot.channel.loadedRemainingGrams <= 0)
          return false;
        final external = isExternalFeedChannel(slot.channel.channelIndex);
        return (amsSelectable || external) &&
            (!plate.isMulticolor || !external || dualFeed);
      })
      .toList(growable: false);
  final available = <int, double>{};
  final dao = ref.read(studioDaoProvider);
  for (final channel in channels)
    available[channel.channel.id] = await dao.getPrinterChannelAvailableGrams(
      channel.channel.id,
    );
  final selected = <int, ChannelWithConsumable>{};
  bool matchesNozzle(ChannelWithConsumable slot, int tool) {
    if (!dualFeed || toolExtruders[tool] == null) return true;
    final channel = slot.channel.channelIndex;
    if (isExternalFeedChannel(channel)) {
      return toolExtruders[tool] ==
          (channel == externalFeedLeftChannel ? 1 : 0);
    }
    final tray = status?.amsTrays
        ?.where((tray) => tray.globalSlot == channel)
        .firstOrNull;
    final source = status?.amsUnits
        ?.where((unit) => unit.isPresent && unit.id == tray?.amsId)
        .firstOrNull
        ?.extruderId;
    return source != null && source == toolExtruders[tool];
  }

  for (final filament in filaments) {
    final match =
        channels.where((slot) {
          if (!matchesNozzle(slot, filament.toolIndex)) return false;
          final consumable = slot.consumable!;
          final materialMatches =
              filament.materialType == null ||
              MaterialIdentityService.sameFamily(
                consumable.materialType,
                filament.materialType!,
              );
          final colorMatches =
              filament.colorHex == null ||
              consumable.colorHex.toUpperCase() ==
                  filament.colorHex!.toUpperCase();
          return materialMatches &&
              colorMatches &&
              (available[slot.channel.id] ?? 0) + .001 >= filament.grams * runs;
        }).firstOrNull ??
        channels
            .where(
              (slot) =>
                  matchesNozzle(slot, filament.toolIndex) &&
                  (available[slot.channel.id] ?? 0) + .001 >=
                      filament.grams * runs,
            )
            .firstOrNull;
    if (match != null) selected[filament.toolIndex] = match;
  }
  bool hasConflictingSlots() {
    if (!plate.isMulticolor) return false;
    final byChannel = <int, StudioPlateFilamentUsage>{};
    for (final filament in filaments) {
      final slot = selected[filament.toolIndex];
      if (slot == null) continue;
      final previous = byChannel[slot.channel.id];
      if (previous != null &&
          (previous.materialType?.trim().toUpperCase() !=
                  filament.materialType?.trim().toUpperCase() ||
              previous.colorHex?.trim().toUpperCase() !=
                  filament.colorHex?.trim().toUpperCase())) {
        return true;
      }
      byChannel[slot.channel.id] = filament;
    }
    return false;
  }

  String? mappingValidationError() {
    for (final filament in filaments) {
      final slot = selected[filament.toolIndex];
      final consumable = slot?.consumable;
      if (consumable == null) continue;
      final expectedType = filament.materialType?.trim();
      if (expectedType?.isNotEmpty == true &&
          consumable.materialType.trim().toUpperCase() !=
              expectedType!.toUpperCase()) {
        return '工具 ${filament.toolIndex + 1} 需要 $expectedType，当前槽位是 ${consumable.materialType}';
      }
      final expectedColor = filament.colorHex?.trim();
      if (expectedColor?.isNotEmpty == true &&
          consumable.colorHex.trim().toUpperCase() !=
              expectedColor!.toUpperCase()) {
        return '工具 ${filament.toolIndex + 1} 的耗材颜色与切片不一致';
      }
    }
    if (selected.length != filaments.length) return null;
    final maxTool = filaments
        .map((item) => item.toolIndex)
        .reduce((a, b) => a > b ? a : b);
    final mapping = List<int>.filled(maxTool + 1, -1);
    for (final entry in selected.entries) {
      mapping[entry.key] = entry.value.channel.channelIndex;
    }
    return validateBambuPrintFeed(
      model: printer.printer.model,
      mapping: mapping,
      activeTools: filaments.map((item) => item.toolIndex),
      status: status,
      toolExtruders: toolExtruders,
    );
  }

  if (!context.mounted) return null;
  return showDialog<Map<int, ChannelWithConsumable>>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 760,
            maxHeight: MediaQuery.sizeOf(context).height * .88,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '确认耗材与供料槽位',
                    style: Aurora.title(context).copyWith(fontSize: 19),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    plate.isMulticolor && !amsSelectable && !dualFeed
                        ? '这是多色切片，但当前没有识别到 AMS。个人版会阻止自动发送，避免把多种颜色错误送入同一外挂料位。'
                        : plate.isMulticolor
                        ? dualFeed
                              ? '按切片的喷头分配选择供料：AMS 与另一路外挂支撑料可以一起使用；同一路径不能混用。'
                              : '已${amsState == AmsDetectionState.present ? '识别' : '按本机已配置槽位保留'} ${amsTypes.isEmpty ? '${configuredAmsChannels.length} 个 AMS 槽位' : '${amsTypes.length} 个 AMS（${amsTypes.map((item) => item.displayLabel).join('、')}）'}；每种颜色必须映射到不同的 AMS 槽位。'
                        : '单色任务可使用 AMS 或外挂料位；发送前会核对余量，个人库存不足时不会偷偷扣减。',
                    style: Aurora.label(context).copyWith(height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  if (preset != null)
                    Text(
                      preset.externalCanCoexistWithAms
                          ? '双供料路径：左右喷头分别校验，外挂数量随 AMS 接管的路径变化。'
                          : '单供料路径：外挂是可切换来源，不会在 AMS 之外增加一种颜色。选择外挂前需在打印机完成进退料。',
                      style: Aurora.label(context),
                    ),
                  Text(
                    '供料概览：${amsState == AmsDetectionState.present
                        ? '${amsTypes.length} 个 AMS · ${configuredAmsChannels.length} 个 AMS 槽位'
                        : amsSelectable
                        ? 'AMS 状态待确认 · ${configuredAmsChannels.length} 个已配置槽位'
                        : '未识别 AMS'} · ${externalFeedSummary(externalInputCount: externalCount, status: status)} · 已绑定 ${channels.length} 槽',
                    style: Aurora.label(context).copyWith(color: Aurora.muted),
                  ),
                  const SizedBox(height: 16),
                  for (final filament in filaments) ...[
                    if (filament == filaments.first &&
                        preset?.amsLiteCanCombineWithStandard == true)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          'A2L 混接时请确认 AMS Lite 已让出一路进料口给常规 AMS；按实际接管选择其余三个 Lite 槽位。',
                          style: Aurora.label(context),
                        ),
                      ),
                    Row(
                      children: [
                        Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: _hexColor(filament.colorHex),
                            shape: BoxShape.circle,
                            border: Border.all(color: Aurora.line),
                          ),
                        ),
                        const SizedBox(width: 9),
                        SizedBox(
                          width: 150,
                          child: Text(
                            '工具 ${filament.toolIndex + 1} · ${filament.materialType ?? '未知材质'}${dualFeed ? '\n${toolExtruders[filament.toolIndex] == 1
                                      ? '左喷头'
                                      : toolExtruders[filament.toolIndex] == 0
                                      ? '右喷头'
                                      : '喷头待确认'}' : ''}',
                          ),
                        ),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue:
                                selected[filament.toolIndex]?.channel.id,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '槽位',
                              isDense: true,
                            ),
                            items: [
                              for (final slot in channels.where(
                                (slot) =>
                                    matchesNozzle(slot, filament.toolIndex),
                              ))
                                DropdownMenuItem(
                                  value: slot.channel.id,
                                  child: Text(
                                    '${printerFeedChannelLabel(slot.channel.channelIndex, storedLabel: slot.channel.label)} · ${slot.consumable!.colorName ?? slot.consumable!.colorHex} · ${(available[slot.channel.id] ?? 0).toStringAsFixed(0)}g',
                                  ),
                                ),
                            ],
                            onChanged: (value) {
                              final slot = channels
                                  .where((item) => item.channel.id == value)
                                  .firstOrNull;
                              if (slot != null) {
                                setState(
                                  () => selected[filament.toolIndex] = slot,
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (plate.isMulticolor && !amsSelectable && !dualFeed)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '请连接并刷新 AMS 后再发送多色任务；外挂料多色需要在 Bambu Studio 中按换色提示人工操作。',
                        style: TextStyle(color: Aurora.warning, fontSize: 12),
                      ),
                    )
                  else if (hasConflictingSlots())
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '检测到不同颜色共用了同一个槽位，请为每种颜色选择不同的 AMS 槽位。',
                        style: TextStyle(color: Aurora.warning, fontSize: 12),
                      ),
                    )
                  else if (mappingValidationError() case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        error,
                        style: TextStyle(color: Aurora.warning, fontSize: 12),
                      ),
                    )
                  else if (selected.length != filaments.length)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '有颜色没有匹配到可用槽位，请装入耗材后刷新设备。',
                        style: TextStyle(color: Aurora.warning, fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      AppButton(
                        label: '返回',
                        compact: true,
                        variant: AppButtonVariant.secondary,
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 9),
                      AppButton(
                        label: '确认并发送',
                        compact: true,
                        onPressed:
                            selected.length == filaments.length &&
                                !(plate.isMulticolor &&
                                    !amsSelectable &&
                                    !dualFeed) &&
                                !hasConflictingSlots() &&
                                mappingValidationError() == null
                            ? () => Navigator.pop(context, selected)
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<bool> showPersonalProjectImportDialog(
  BuildContext context,
  WidgetRef ref, {
  List<String> initialPaths = const [],
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PersonalProjectImportDialog(initialPaths: initialPaths),
  );
  return result == true;
}

class _PersonalProjectImportDialog extends ConsumerStatefulWidget {
  const _PersonalProjectImportDialog({required this.initialPaths});
  final List<String> initialPaths;
  @override
  ConsumerState<_PersonalProjectImportDialog> createState() =>
      _PersonalProjectImportDialogState();
}

class _PersonalProjectImportDialogState
    extends ConsumerState<_PersonalProjectImportDialog> {
  late final TextEditingController _title;
  final List<_ImportedProject> _projects = [];
  bool _reading = false;
  bool _saving = false;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController();
    if (widget.initialPaths.isNotEmpty)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _addFiles(widget.initialPaths),
      );
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '添加项目',
                      style: Aurora.title(context).copyWith(fontSize: 20),
                    ),
                  ),
                  Text(
                    '${_projects.length} / 5 个文件',
                    style: Aurora.label(context),
                  ),
                  IconButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              DropTarget(
                onDragEntered: (_) => setState(() => _dragging = true),
                onDragExited: (_) => setState(() => _dragging = false),
                onDragDone: (detail) {
                  setState(() => _dragging = false);
                  _addFiles(detail.files.map((file) => file.path));
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: _dragging
                        ? AppColors.primary.withValues(alpha: .08)
                        : AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppColors.radiusMd),
                    border: Border.all(
                      color: _dragging ? AppColors.primary : Aurora.line,
                      width: _dragging ? 1.5 : 1,
                    ),
                  ),
                  child: _projects.isEmpty
                      ? InkWell(
                          onTap: _reading ? null : _pickFiles,
                          child: SizedBox(
                            height: 118,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _reading
                                      ? Icons.hourglass_top_rounded
                                      : Icons.file_upload_outlined,
                                  size: 31,
                                  color: AppColors.primary,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _reading
                                      ? '正在读取项目盘信息…'
                                      : '拖入 Bambu Studio 的 3MF，或点击选择文件',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  '会保留每一张含有模型的打印盘；之后可逐盘切片、逐盘打印',
                                  style: Aurora.label(context),
                                ),
                              ],
                            ),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (var i = 0; i < _projects.length; i++)
                                  Chip(
                                    avatar: const Icon(
                                      Icons.view_in_ar_outlined,
                                      size: 16,
                                    ),
                                    label: Text(
                                      _projects[i].name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onDeleted: _saving
                                        ? null
                                        : () => setState(
                                            () => _projects.removeAt(i),
                                          ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '${_projects.fold<int>(0, (sum, item) => sum + item.inspection.productionPlates.length)} 张可打印盘已识别',
                              style: Aurora.label(context),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: _projects.length >= 5 || _reading
                                    ? null
                                    : _pickFiles,
                                icon: const Icon(Icons.add_rounded, size: 17),
                                label: const Text('继续添加'),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 16),
              AppInput(
                label: '项目名称',
                hint: '例如：桌面摆件 · 8 月作品集',
                controller: _title,
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AppButton(
                    label: '取消',
                    compact: true,
                    variant: AppButtonVariant.secondary,
                    onPressed: _saving
                        ? null
                        : () => Navigator.pop(context, false),
                  ),
                  const SizedBox(width: 9),
                  AppButton(
                    label: _saving ? '正在保存…' : '保存到我的项目',
                    compact: true,
                    onPressed: _saving || _projects.isEmpty ? null : _save,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickFiles() async {
    const group = XTypeGroup(label: 'Bambu Studio 项目', extensions: ['3mf']);
    final files = await openFiles(acceptedTypeGroups: const [group]);
    await _addFiles(files.map((file) => file.path));
  }

  Future<void> _addFiles(Iterable<String> paths) async {
    if (_reading) return;
    final existing = _projects.map((item) => item.path.toLowerCase()).toSet();
    final unique = paths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty && existing.add(path.toLowerCase()))
        .take(5 - _projects.length)
        .toList(growable: false);
    if (unique.isEmpty) return;
    setState(() => _reading = true);
    final rejected = <String>[];
    try {
      for (final path in unique) {
        try {
          final inspection = await ProductionPackageInspector.inspect(path);
          if (inspection == null ||
              inspection.kind != ProductionArtifactKind.bambu3mf ||
              inspection.productionPlates.isEmpty) {
            rejected.add(path.split(RegExp(r'[/\\]')).last);
            continue;
          }
          if (!mounted) return;
          setState(() {
            _projects.add(_ImportedProject(path: path, inspection: inspection));
            if (_title.text.trim().isEmpty)
              _title.text = inspection.displayName;
          });
        } catch (_) {
          rejected.add(path.split(RegExp(r'[/\\]')).last);
        }
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
    if (mounted && rejected.isNotEmpty)
      _personalSnack(
        context,
        '无法读取：${rejected.join('、')}（需要包含模型盘的 3MF）',
        error: true,
      );
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      _personalSnack(context, '请填写项目名称', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final dao = ref.read(studioDaoProvider);
      final workspace = (await dao.getDefaultSnapshot()).workspace;
      final drafts = <StudioProductionPackageDraft>[];
      for (final project in _projects) {
        final durablePath =
            await BambuStudioSlicingService.preserveSourceProject(project.path);
        drafts.add(_draftForImportedProject(project, durablePath));
      }
      await dao.addProductionOrder(
        workspaceId: workspace.id,
        orderNo: 'P-${DateFormat('yyMMdd-HHmmss').format(DateTime.now())}',
        title: _title.text.trim(),
        packages: drafts,
      );
      if (mounted) {
        _personalSnack(context, '项目已保存，展开项目即可逐盘切片和打印');
        Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) _personalSnack(context, '保存项目失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  StudioProductionPackageDraft _draftForImportedProject(
    _ImportedProject project,
    String durablePath,
  ) {
    final inspection = project.inspection;
    return StudioProductionPackageDraft(
      sourceName: inspection.displayName,
      localPath: durablePath,
      artifactSha256: inspection.artifactSha256,
      artifactKind: inspection.kind.name,
      slicerName: inspection.slicerName,
      slicerVersion: inspection.slicerVersion,
      targetModel: inspection.targetModel,
      nozzleDiameter: inspection.nozzleDiameter,
      plates: [
        for (final plate in inspection.productionPlates)
          StudioProductionPlateDraft(
            plateIndex: plate.plateIndex,
            name: plate.name,
            requiredRuns: math.max(
              1,
              plate.parts.fold<int>(
                0,
                (sum, part) => math.max(sum, part.instancesPerRun),
              ),
            ),
            estimatedSeconds: plate.estimatedSeconds,
            estimatedGrams: plate.estimatedGrams,
            sliceStatus: plate.hasToolpath
                ? StudioPlateSliceStatus.sliced
                : StudioPlateSliceStatus.pending,
            sliceArtifactPath: plate.hasToolpath ? durablePath : null,
            sliceArtifactSha256: plate.hasToolpath
                ? inspection.artifactSha256
                : null,
            sliceTargetModel: inspection.targetModel,
            sliceNozzleDiameter: inspection.nozzleDiameter,
            thumbnailBytes: plate.thumbnailBytes,
            totalLayers: plate.totalLayers,
            toolChangeCount: plate.toolChangeCount,
            filaments: [
              for (final filament in plate.filaments)
                StudioPlateFilamentUsage(
                  toolIndex: filament.toolIndex,
                  grams: filament.grams,
                  vendor: filament.vendor,
                  materialType: filament.materialType,
                  colorHex: filament.colorHex,
                  trayId: filament.trayId,
                  sku: filament.sku,
                  usedForObject: filament.usedForObject,
                  usedForSupport: filament.usedForSupport,
                  groupId: filament.groupId,
                  nozzleDiameter: filament.nozzleDiameter,
                  volumeType: filament.volumeType,
                ),
            ],
            items: [
              for (final part in plate.parts)
                StudioOrderItemDraft(
                  sourceKey: part.key,
                  name: part.name,
                  perRunQuantity: math.max(1, part.instancesPerRun),
                  requiredQuantity: math.max(1, part.instancesPerRun),
                ),
            ],
          ),
      ],
    );
  }
}

class _ImportedProject {
  const _ImportedProject({required this.path, required this.inspection});
  final String path;
  final ProductionPackageInspection inspection;
  String get name => inspection.displayName;
}

String _orderStatus(StudioOrderStatus status) => switch (status) {
  StudioOrderStatus.draft => '草稿',
  StudioOrderStatus.confirmed => '待准备',
  StudioOrderStatus.production => '打印中',
  StudioOrderStatus.completed => '已完成',
  StudioOrderStatus.delivered => '已交付',
  StudioOrderStatus.cancelled => '已取消',
};

StudioOrderStatus _personalProjectStatus(
  StudioOrder project,
  List<StudioProductionPlate> plates,
  List<StudioWorkOrder> workOrders,
) {
  final projectPlates = plates.where((plate) => plate.orderId == project.id);
  final projectWorkOrders = workOrders.where(
    (workOrder) => workOrder.orderId == project.id,
  );
  if (projectWorkOrders.any(
        (workOrder) => workOrder.status == StudioWorkOrderStatus.completed,
      ) &&
      projectWorkOrders.every(
        (workOrder) =>
            workOrder.status == StudioWorkOrderStatus.completed ||
            workOrder.status == StudioWorkOrderStatus.cancelled,
      )) {
    return StudioOrderStatus.completed;
  }
  if (projectWorkOrders.any(
    (workOrder) => workOrder.status == StudioWorkOrderStatus.printing,
  )) {
    return StudioOrderStatus.production;
  }
  if (projectPlates.any((plate) => !plate.isSliced)) {
    return StudioOrderStatus.draft;
  }
  if (projectPlates.isNotEmpty || projectWorkOrders.isNotEmpty) {
    return StudioOrderStatus.confirmed;
  }
  return project.status;
}

Color _orderColor(StudioOrderStatus status) => switch (status) {
  StudioOrderStatus.draft => Aurora.muted,
  StudioOrderStatus.confirmed => Aurora.blue,
  StudioOrderStatus.production => Aurora.warning,
  StudioOrderStatus.completed ||
  StudioOrderStatus.delivered => const Color(0xFF14A86B),
  StudioOrderStatus.cancelled => Aurora.danger,
};

String _duration(int seconds) {
  if (seconds <= 0) return '时间待确认';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return hours > 0 ? '$hours 小时 $minutes 分' : '$minutes 分钟';
}

Color _hexColor(String? value) {
  final clean = value?.replaceAll('#', '').trim() ?? '';
  final number = int.tryParse(clean, radix: 16);
  return number == null ? const Color(0xFFBFC5CC) : Color(0xFF000000 | number);
}

void _personalSnack(
  BuildContext context,
  String message, {
  bool error = false,
}) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Aurora.danger : null,
      ),
    );
}
