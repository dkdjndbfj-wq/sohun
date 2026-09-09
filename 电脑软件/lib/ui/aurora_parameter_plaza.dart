import 'dart:async';
import '../core/theme/glass_button_theme.dart';
import '../widgets/app_glass_button.dart';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_util;

import '../core/utils/friendly_error.dart';

import '../core/theme/app_typography.dart';
import '../core/theme/interaction_effects.dart';
import '../core/services/preset_diff_service.dart';
import '../core/utils/image_storage.dart';
import '../core/utils/public_image_url.dart';
import '../data/external/slicer/bambu_studio_param_exporter.dart';
import '../data/external/slicer/material_catalog_service.dart';
import '../data/external/slicer/preset_cloud_uploader.dart';
import '../data/external/community/community_api_client.dart'
    show CommunityTrustSummary;
import '../data/models/community_preset.dart';
import '../data/models/print_parameter.dart';
import '../data/models/printer_preset.dart';
import '../features/parameters/builtin_presets.dart';
import '../features/parameters/parameter_config_screen.dart';
import '../features/parameters/preset_compare_dialog.dart';
import '../providers/bambu_cloud_provider.dart';
import '../providers/app_auth_provider.dart';
import '../providers/community_preset_provider.dart';
import '../providers/community_share_provider.dart';
import '../providers/material_catalog_provider.dart';
import '../providers/parameter_preset_provider.dart';
import '../widgets/bambu_icon.dart';
import '../widgets/app_select.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/material_picker.dart';
import '../widgets/printer_image.dart';
import '../widgets/experience_ui.dart';
import 'aurora_design.dart';

enum _PresetScope { all, published, mine, local, liked }

enum _PresetSort { recommended, newest, popular, mostLiked, name }

class AuroraParameterPlazaPage extends ConsumerStatefulWidget {
  const AuroraParameterPlazaPage({super.key});

  @override
  ConsumerState<AuroraParameterPlazaPage> createState() =>
      _AuroraParameterPlazaPageState();
}

class _AuroraParameterPlazaPageState
    extends ConsumerState<AuroraParameterPlazaPage> {
  final _searchController = TextEditingController();
  _PresetScope _scope = _PresetScope.all;
  _PresetSort _sort = _PresetSort.recommended;
  String _query = '';
  String? _material;
  String? _scene;
  String? _printer;
  final Set<String> _applyingIds = {};
  final Map<String, PrintParameterPreset> _comparePresets = {};
  Timer? _communitySearchTimer;
  bool _cloudRefreshInFlight = false;
  bool _initialRefreshComplete = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshCurrentScope(announce: false).whenComplete(() {
        if (mounted) _initialRefreshComplete = true;
      });
    });
  }

  @override
  void dispose() {
    _communitySearchTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localPresets = ref.watch(parameterPresetProvider);
    final localUserPresets = localPresets
        .where((preset) => !_isSystem(preset))
        .toList();
    final cloudPresets = ref.watch(cloudParameterPresetsProvider);
    final cloudItems = cloudPresets.valueOrNull ?? const [];
    final communityFeed = ref.watch(communityPresetFeedProvider);
    final myCommunityFeed = ref.watch(myCommunityPresetFeedProvider);
    final communityItems = communityFeed.items;
    final myCommunityItems = myCommunityFeed.items;
    final communityByPresetId = <String, CommunityPreset>{
      for (final item in [...communityItems, ...myCommunityItems])
        item.preset.id: item,
    };
    final localLikedIds = ref.watch(likedPresetsProvider);
    final likedIds = <String>{
      ...localLikedIds,
      ...communityItems
          .where((item) => item.likedByMe)
          .map((item) => item.preset.id),
    };
    final materialCatalog =
        ref.watch(materialCatalogProvider).valueOrNull ??
        MaterialCatalogService.fallbackMaterials;
    final materials = _values([
      ...materialCatalog,
      ...communityItems.map((item) => item.preset.material),
      ...myCommunityItems.map((item) => item.preset.material),
      ...cloudItems.map((p) => p.material),
      ...localUserPresets.map((p) => p.material),
    ]);
    final scenes = _values([
      ...communityItems.map((item) => item.preset.scene),
      ...myCommunityItems.map((item) => item.preset.scene),
      ...cloudItems.map((p) => p.scene),
      ...localUserPresets.map((p) => p.scene),
    ]);
    final loadedPrinters = ref.watch(printerPresetProvider);
    final printers = loadedPrinters.isEmpty
        ? BuiltinPresets.getAllPrinters()
        : loadedPrinters;
    final source = switch (_scope) {
      _PresetScope.all => communityItems.map((item) => item.preset).toList(),
      _PresetScope.published =>
        myCommunityItems.map((item) => item.preset).toList(),
      _PresetScope.mine => cloudItems,
      _PresetScope.local => localUserPresets,
      _PresetScope.liked =>
        communityItems
            .where((item) => item.likedByMe)
            .map((item) => item.preset)
            .toList(),
    };
    final shown = _filterAndSort(source, likedIds);
    final pagedCommunityFeed = _scope == _PresetScope.published
        ? myCommunityFeed
        : communityFeed;

    ref.listen<int>(parameterPlazaActivationProvider, (previous, next) {
      // The first activation can race with the first build when the shell
      // lazily mounts this page. Its post-frame load already covers that
      // entry; subsequent activations represent a real return from another
      // workspace page and must refresh the selected scope once.
      if (previous != next && _initialRefreshComplete) {
        _refreshCurrentScope(announce: false);
      }
    });

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 220,
            child: _CategoryRail(
              scope: _scope,
              publicPresetCount: communityItems.length,
              publishedPresetCount: myCommunityItems.length,
              cloudPresetCount: cloudItems.length,
              localPresetCount: localUserPresets.length,
              likedIds: likedIds,
              onScopeChanged: _selectScope,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              children: [
                _buildHeader(
                  publicCount: communityItems.length,
                  publishedCount: myCommunityItems.length,
                  cloudCount: cloudItems.length,
                  likedCount: likedIds.length,
                  isLoading: _scope == _PresetScope.mine
                      ? cloudPresets.isLoading
                      : _scope == _PresetScope.published
                      ? myCommunityFeed.isLoading
                      : communityFeed.isLoading,
                ),
                const SizedBox(height: 12),
                _buildFilterBar(materials, scenes, printers, shown.length),
                if (_comparePresets.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _ParameterLabTray(
                    presets: _comparePresets.values.toList(growable: false),
                    onRemove: (preset) =>
                        setState(() => _comparePresets.remove(preset.id)),
                    onClear: () => setState(_comparePresets.clear),
                    onCompare: _showComparison,
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child:
                      (_scope == _PresetScope.all ||
                              _scope == _PresetScope.liked) &&
                          communityFeed.isLoading &&
                          communityFeed.items.isEmpty
                      ? const _CommunityPresetStatus(loading: true)
                      : (_scope == _PresetScope.all ||
                                _scope == _PresetScope.liked) &&
                            communityFeed.errorMessage != null &&
                            communityFeed.items.isEmpty
                      ? _CommunityPresetStatus(
                          error: communityFeed.errorMessage,
                          onRetry: _refreshCommunityPresets,
                        )
                      : _scope == _PresetScope.published &&
                            myCommunityFeed.isLoading &&
                            myCommunityFeed.items.isEmpty
                      ? const _CommunityPresetStatus(loading: true, mine: true)
                      : _scope == _PresetScope.published &&
                            myCommunityFeed.errorMessage != null &&
                            myCommunityFeed.items.isEmpty
                      ? _CommunityPresetStatus(
                          mine: true,
                          error: myCommunityFeed.errorMessage,
                          onRetry: _refreshMyPublishedPresets,
                        )
                      : _scope == _PresetScope.mine && cloudPresets.isLoading
                      ? const _CloudPresetStatus(loading: true)
                      : _scope == _PresetScope.mine && cloudPresets.hasError
                      ? _CloudPresetStatus(
                          error: friendlyError(cloudPresets.error!),
                          onRetry: _refreshCloudPresets,
                        )
                      : _scope == _PresetScope.mine && shown.isEmpty
                      ? _CloudPresetStatus(
                          empty: true,
                          onRetry: _refreshCloudPresets,
                        )
                      : shown.isEmpty
                      ? _EmptyResult(
                          hasFilters: _hasFilters,
                          onReset: _resetFilters,
                          onCreate: _createPreset,
                        )
                      : _PresetGrid(
                          presets: shown,
                          likedIds: likedIds,
                          communityByPresetId: communityByPresetId,
                          currentAppUserId: ref.watch(appAuthProvider).user?.id,
                          applyingIds: _applyingIds,
                          compareIds: _comparePresets.keys.toSet(),
                          onOpen: _openPreset,
                          onApply: _applyPreset,
                          onLike: _toggleLike,
                          onCompareToggle: _toggleCompare,
                          onAction: _handleAction,
                          hasMore:
                              _usesCommunityFeed &&
                              pagedCommunityFeed.nextCursor != null,
                          isLoadingMore:
                              _usesCommunityFeed &&
                              pagedCommunityFeed.isLoadingMore,
                          loadMoreError: _usesCommunityFeed
                              ? pagedCommunityFeed.errorMessage
                              : null,
                          onLoadMore: _usesCommunityFeed
                              ? _loadMoreCommunityPresets
                              : null,
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _toggleCompare(PrintParameterPreset preset) {
    setState(() {
      if (_comparePresets.containsKey(preset.id)) {
        _comparePresets.remove(preset.id);
        return;
      }
      if (_comparePresets.length == 2) {
        _comparePresets.remove(_comparePresets.keys.first);
      }
      _comparePresets[preset.id] = preset;
    });
  }

  void _showComparison() {
    if (_comparePresets.length != 2) return;
    final presets = _comparePresets.values.toList(growable: false);
    showDialog<void>(
      context: context,
      builder: (_) => PresetCompareDialog(
        presetAName: presets[0].name,
        presetAValues: PresetDiffService.flatten(presets[0]),
        presetBName: presets[1].name,
        presetBValues: PresetDiffService.flatten(presets[1]),
      ),
    );
  }

  Widget _buildHeader({
    required int publicCount,
    required int publishedCount,
    required int cloudCount,
    required int likedCount,
    required bool isLoading,
  }) {
    return FrostPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      color: Aurora.panelStrong,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showMetrics = constraints.maxWidth >= 820;
          return Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Aurora.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(Aurora.radius),
                ),
                child: Center(
                  child: BambuIcon(
                    name: 'tab_presets_active',
                    size: 23,
                    color: Aurora.primary,
                    applyColorFilter: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('参数广场', style: Aurora.title(context)),
                    const SizedBox(height: 3),
                    Text(
                      '搜索社区作者分享的参数，并直接应用到拓竹切片',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Aurora.label(context),
                    ),
                  ],
                ),
              ),
              if (showMetrics) ...[
                _HeaderMetric(label: '广场', value: publicCount),
                const SizedBox(width: 8),
                _HeaderMetric(label: '发布', value: publishedCount),
                const SizedBox(width: 8),
                _HeaderMetric(label: '点赞', value: likedCount),
                const SizedBox(width: 8),
                _HeaderMetric(label: '拓竹云', value: cloudCount),
                const SizedBox(width: 12),
              ],
              BambuGlyphButton(
                icon: 'refresh_normal',
                tooltip: isLoading ? '正在刷新参数' : '刷新当前参数列表',
                onPressed: isLoading ? null : _refreshCurrentScope,
                background: Aurora.fill,
              ),
              const SizedBox(width: 8),
              AuroraButton(
                label: '新建预设',
                icon: 'add_filament',
                onPressed: _createPreset,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilterBar(
    List<String> materials,
    List<String> scenes,
    List<PrinterPreset> printers,
    int resultCount,
  ) {
    return FrostPanel(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 900;
          final searchField = TextField(
            controller: _searchController,
            onChanged: (value) {
              setState(() => _query = value.trim());
              _scheduleCommunityRefresh();
            },
            decoration: InputDecoration(
              hintText: '搜索预设名称、作者、材料、场景或打印机',
              prefixIcon: Padding(
                padding: const EdgeInsets.all(12),
                child: BambuIcon(
                  name: 'search',
                  size: 17,
                  color: Aurora.textSoft,
                  applyColorFilter: true,
                ),
              ),
              suffixIcon: _query.isEmpty
                  ? null
                  : BambuGlyphButton(
                      icon: 'cross',
                      tooltip: '清除搜索',
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                        _scheduleCommunityRefresh(immediate: true);
                      },
                    ),
              filled: true,
              fillColor: Aurora.fill,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Aurora.radius),
                borderSide: BorderSide(color: Aurora.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Aurora.radius),
                borderSide: BorderSide(color: Aurora.line),
              ),
            ),
          );
          final controls = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FilterPickerButton(
                label: '材料',
                value: _material,
                onPressed: () => _showMaterialFilter(materials),
              ),
              const SizedBox(width: 8),
              _FilterPickerButton(
                label: '场景',
                value: _scene,
                onPressed: () => _showFilterPicker(
                  label: '场景',
                  values: scenes,
                  selected: _scene,
                  icon: Icons.tune_rounded,
                  onSelected: _selectScene,
                ),
              ),
              const SizedBox(width: 8),
              _FilterPickerButton(
                label: '打印机',
                value: _printer,
                onPressed: () => _showPrinterFilter(printers),
              ),
              const SizedBox(width: 8),
              _SortSelect(
                value: _sort,
                onChanged: (value) {
                  setState(() => _sort = value);
                  _scheduleCommunityRefresh(immediate: true);
                },
              ),
            ],
          );
          return Column(
            children: [
              if (compact) ...[
                SizedBox(width: double.infinity, child: searchField),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: controls,
                  ),
                ),
              ] else
                Row(
                  children: [
                    Expanded(child: searchField),
                    const SizedBox(width: 10),
                    controls,
                  ],
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    '$_sectionTitle · $resultCount 个预设',
                    style: Aurora.label(
                      context,
                    ).copyWith(color: Aurora.text, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  if (_hasFilters)
                    TextButton.icon(
                      onPressed: _resetFilters,
                      icon: BambuIcon(
                        name: 'cross',
                        size: 14,
                        color: Aurora.textSoft,
                        applyColorFilter: true,
                      ),
                      label: const Text('清除筛选'),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  List<PrintParameterPreset> _filterAndSort(
    List<PrintParameterPreset> source,
    Set<String> likedIds,
  ) {
    final query = _query.toLowerCase();
    final result = source.where((preset) {
      if (_scope == _PresetScope.liked && !likedIds.contains(preset.id)) {
        return false;
      }
      if (_material != null && preset.material != _material) {
        return false;
      }
      if (_scene != null && preset.scene != _scene) return false;
      if (_printer != null &&
          preset.compatiblePrinters.isNotEmpty &&
          !preset.compatiblePrinters.any(
            (value) => _printerModelMatches(value, _printer!),
          )) {
        return false;
      }
      if (query.isEmpty) return true;
      final searchable = [
        preset.name,
        preset.description ?? '',
        preset.author ?? '',
        preset.material ?? '',
        preset.scene ?? '',
        ...preset.tags,
        ...preset.compatiblePrinters,
      ].join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList();

    // Community pages are already filtered and ordered by the server. Keeping
    // that order is required for cursor pagination and prevents anonymous
    // download counters from changing recommendation order on the client.
    if (_usesCommunityFeed) return result;

    switch (_sort) {
      case _PresetSort.recommended:
        result.sort((a, b) {
          final aScore =
              a.downloads * 2 + a.likes + (likedIds.contains(a.id) ? 1 : 0);
          final bScore =
              b.downloads * 2 + b.likes + (likedIds.contains(b.id) ? 1 : 0);
          final score = bScore.compareTo(aScore);
          return score != 0 ? score : b.updatedAt.compareTo(a.updatedAt);
        });
      case _PresetSort.newest:
        result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case _PresetSort.popular:
        result.sort((a, b) => b.downloads.compareTo(a.downloads));
      case _PresetSort.mostLiked:
        result.sort((a, b) {
          final aLikes = a.likes + (likedIds.contains(a.id) ? 1 : 0);
          final bLikes = b.likes + (likedIds.contains(b.id) ? 1 : 0);
          return bLikes.compareTo(aLikes);
        });
      case _PresetSort.name:
        result.sort((a, b) => a.name.compareTo(b.name));
    }
    return result;
  }

  void _selectScope(_PresetScope value) {
    if (value == _scope) return;
    setState(() {
      _scope = value;
      _material = null;
      _scene = null;
      _printer = null;
    });
    _refreshCurrentScope(announce: false);
  }

  void _selectMaterial(String? value) {
    setState(() {
      _material = value;
    });
    _scheduleCommunityRefresh(immediate: true);
  }

  Future<void> _showMaterialFilter(List<String> materials) async {
    final result = await showMaterialPicker(
      context: context,
      materials: materials,
      selected: _material,
      allowAll: true,
    );
    if (result != null && mounted) _selectMaterial(result.value);
  }

  Future<void> _showPrinterFilter(List<PrinterPreset> printers) async {
    final result = await showDialog<_PrinterFilterChoice>(
      context: context,
      builder: (_) =>
          _PrinterFilterDialog(printers: printers, selectedModel: _printer),
    );
    if (result != null && mounted) {
      setState(() => _printer = result.model);
      _scheduleCommunityRefresh(immediate: true);
    }
  }

  void _selectScene(String? value) {
    setState(() {
      _scene = value;
    });
    _scheduleCommunityRefresh(immediate: true);
  }

  Future<void> _showFilterPicker({
    required String label,
    required List<String> values,
    required String? selected,
    required IconData icon,
    required ValueChanged<String?> onSelected,
  }) async {
    final result = await showDialog<_FilterChoice>(
      context: context,
      builder: (_) => _FilterPickerDialog(
        label: label,
        values: values,
        selected: selected,
        icon: icon,
      ),
    );
    if (result != null && mounted) onSelected(result.value);
  }

  void _resetFilters() {
    _searchController.clear();
    setState(() {
      _scope = _PresetScope.all;
      _query = '';
      _material = null;
      _scene = null;
      _printer = null;
      _sort = _PresetSort.recommended;
    });
    _refreshCommunityPresets(announce: false);
  }

  bool get _hasFilters =>
      _scope != _PresetScope.all ||
      _query.isNotEmpty ||
      _material != null ||
      _scene != null ||
      _printer != null ||
      _sort != _PresetSort.recommended;

  String get _sectionTitle {
    if (_material != null) return _material!;
    if (_scene != null) return _scene!;
    return switch (_scope) {
      _PresetScope.all => '广场预设',
      _PresetScope.published => '我的发布',
      _PresetScope.mine => '我的预设',
      _PresetScope.local => '本地草稿',
      _PresetScope.liked => '我的点赞',
    };
  }

  bool get _usesCommunityFeed =>
      _scope == _PresetScope.all ||
      _scope == _PresetScope.published ||
      _scope == _PresetScope.liked;

  String get _communitySort => switch (_sort) {
    _PresetSort.recommended => 'recommended',
    _PresetSort.newest => 'newest',
    _PresetSort.popular => 'popular',
    _PresetSort.mostLiked => 'mostLiked',
    _PresetSort.name => 'name',
  };

  CommunityPresetQuery get _communityQuery => CommunityPresetQuery(
    query: _query,
    material: _material,
    scene: _scene,
    printer: _printer,
    sort: _communitySort,
  );

  void _scheduleCommunityRefresh({bool immediate = false}) {
    if (!_usesCommunityFeed) return;
    _communitySearchTimer?.cancel();
    if (immediate) {
      _refreshCurrentScope(announce: false);
      return;
    }
    _communitySearchTimer = Timer(
      const Duration(milliseconds: 350),
      () => _refreshCurrentScope(announce: false),
    );
  }

  Future<void> _refreshCommunityPresets({bool announce = true}) async {
    await ref
        .read(communityPresetFeedProvider.notifier)
        .refresh(query: _communityQuery, force: true);
    if (!mounted || !announce) return;
    final state = ref.read(communityPresetFeedProvider);
    if (state.errorMessage != null) {
      showSnack(context, state.errorMessage!, error: true);
    } else {
      showSnack(context, '广场参数已刷新，共 ${state.items.length} 条');
    }
  }

  Future<void> _refreshMyPublishedPresets({bool announce = true}) async {
    await ref
        .read(myCommunityPresetFeedProvider.notifier)
        .refresh(query: _communityQuery, force: true);
    if (!mounted || !announce) return;
    final state = ref.read(myCommunityPresetFeedProvider);
    if (state.errorMessage != null) {
      showSnack(context, state.errorMessage!, error: true);
    } else {
      showSnack(context, '我的发布已刷新，共 ${state.items.length} 条');
    }
  }

  Future<void> _refreshCurrentScope({bool announce = true}) async {
    switch (_scope) {
      case _PresetScope.all:
      case _PresetScope.liked:
        await _refreshCommunityPresets(announce: announce);
      case _PresetScope.published:
        await _refreshMyPublishedPresets(announce: announce);
      case _PresetScope.mine:
        await _refreshCloudPresets(announce: announce);
      case _PresetScope.local:
        await ref.read(parameterPresetProvider.notifier).reload();
        if (mounted && announce) showSnack(context, '本地草稿已刷新');
    }
  }

  Future<void> _loadMoreCommunityPresets() async {
    final notifier = _scope == _PresetScope.published
        ? ref.read(myCommunityPresetFeedProvider.notifier)
        : ref.read(communityPresetFeedProvider.notifier);
    await notifier.loadMore();
  }

  Future<void> _createPreset() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ParameterConfigScreen()));
  }

  Future<void> _openPreset(PrintParameterPreset preset) async {
    final publication = _findCommunityPreset(preset);
    final isOwner =
        publication != null &&
        (publication.ownedByMe ||
            publication.owner.id == ref.read(appAuthProvider).user?.id);
    await showDialog<void>(
      context: context,
      builder: (_) => _PresetDetailDialog(
        preset: preset,
        isSystem: _isSystem(preset),
        isLiked:
            publication?.likedByMe ??
            ref.read(likedPresetsProvider).contains(preset.id),
        canEdit: publication == null || isOwner,
        applying: _applyingIds.contains(preset.id),
        communityPublicationId: publication?.publicationId,
        communityApplicationCount: publication?.applicationCount,
        onLike: () => _toggleLike(preset),
        onEdit: () {
          Navigator.of(context).pop();
          _editPreset(preset);
        },
        onApply: () {
          Navigator.of(context).pop();
          _applyPreset(preset);
        },
      ),
    );
  }

  Future<void> _editPreset(PrintParameterPreset preset) async {
    final publication = _findCommunityPreset(preset);
    if (publication != null) {
      final currentUser = ref.read(appAuthProvider).user;
      if (currentUser == null ||
          (!publication.ownedByMe && currentUser.id != publication.owner.id)) {
        final copy = await ref
            .read(parameterPresetProvider.notifier)
            .duplicate(preset);
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ParameterConfigScreen(preset: copy),
          ),
        );
        return;
      }

      final mirrorId = 'user_community_${publication.publicationId}';
      var editable = ref
          .read(parameterPresetProvider.notifier)
          .findById(mirrorId);
      if (editable == null) {
        editable = preset.copyWith(
          id: mirrorId,
          shareId: null,
          uploadedAt: null,
          serverVersion: null,
        );
        await ref.read(parameterPresetProvider.notifier).add(editable);
        if (!mounted) return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ParameterConfigScreen(preset: editable),
        ),
      );
      if (!mounted) return;
      final saved = ref
          .read(parameterPresetProvider.notifier)
          .findById(mirrorId);
      if (saved == null) return;
      try {
        final updated = await ref
            .read(myCommunityPresetFeedProvider.notifier)
            .updatePublication(publication: publication, preset: saved);
        await ref
            .read(parameterPresetProvider.notifier)
            .update(
              saved.copyWith(
                communityPublicationId: updated.publicationId,
                communityOwnerId: currentUser.id,
                communityRevision: updated.revision,
                communityVisibility: updated.visibility,
              ),
            );
        await _refreshCommunityPresets(announce: false);
        if (mounted) showSnack(context, '广场参数已更新');
      } catch (error) {
        if (mounted) {
          showSnack(context, '更新失败：${friendlyError(error)}', error: true);
        }
      }
      return;
    }

    var editable = preset;
    if (preset.id.startsWith('cloud_')) {
      final local = ref
          .read(parameterPresetProvider)
          .where((item) => item.shareId == preset.shareId);
      if (local.isNotEmpty) {
        editable = local.first;
      } else {
        editable = preset.copyWith(id: 'user_cloud_${preset.shareId}');
        await ref.read(parameterPresetProvider.notifier).add(editable);
        if (!mounted) return;
      }
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ParameterConfigScreen(preset: editable),
      ),
    );
    if (!mounted) return;
    ref.invalidate(cloudParameterPresetsProvider);
  }

  CommunityPreset? _findCommunityPreset(PrintParameterPreset preset) {
    for (final publication in [
      ...ref.read(communityPresetFeedProvider).items,
      ...ref.read(myCommunityPresetFeedProvider).items,
    ]) {
      if (publication.preset.id == preset.id) return publication;
    }
    return null;
  }

  Future<void> _toggleLike(PrintParameterPreset preset) async {
    final publication = _findCommunityPreset(preset);
    if (publication == null) {
      await ref.read(likedPresetsProvider.notifier).toggle(preset.id);
      return;
    }
    if (ref.read(appAuthProvider).session == null) {
      if (mounted) {
        showSnack(context, '请先登录工作台账号后再点赞', error: true);
      }
      return;
    }
    try {
      final publicContains = ref
          .read(communityPresetFeedProvider)
          .items
          .any((item) => item.publicationId == publication.publicationId);
      final notifier = publicContains
          ? ref.read(communityPresetFeedProvider.notifier)
          : ref.read(myCommunityPresetFeedProvider.notifier);
      await notifier.toggleLike(publication);
      if (publicContains) {
        await ref
            .read(myCommunityPresetFeedProvider.notifier)
            .refresh(force: true);
      } else {
        await ref
            .read(communityPresetFeedProvider.notifier)
            .refresh(force: true);
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, '点赞失败：${friendlyError(error)}', error: true);
      }
    }
  }

  Future<void> _refreshCloudPresets({bool announce = true}) async {
    if (_cloudRefreshInFlight) return;
    if (ref.read(bambuCloudProvider).session == null) {
      if (announce && mounted) {
        showSnack(context, '请先登录拓竹云账号', error: true);
      }
      return;
    }
    _cloudRefreshInFlight = true;
    try {
      ref.invalidate(cloudParameterPresetsProvider);
      final items = await ref.read(cloudParameterPresetsProvider.future);
      if (announce && mounted) {
        showSnack(context, '云端预设已刷新，共 ${items.length} 条');
      }
    } catch (error) {
      if (announce && mounted) {
        showSnack(context, '云端预设刷新失败：${friendlyError(error)}', error: true);
      }
    } finally {
      _cloudRefreshInFlight = false;
    }
  }

  Future<void> _handleAction(
    PrintParameterPreset preset,
    _PresetAction action,
  ) async {
    switch (action) {
      case _PresetAction.open:
        await _openPreset(preset);
      case _PresetAction.edit:
        await _editPreset(preset);
      case _PresetAction.duplicate:
        await ref.read(parameterPresetProvider.notifier).duplicate(preset);
        if (mounted) showSnack(context, '已复制「${preset.name}」为新预设');
      case _PresetAction.upload:
        await _uploadPreset(preset);
      case _PresetAction.publish:
        await _publishCommunityPreset(preset);
      case _PresetAction.exportJson:
        await _exportPreset(preset, bbsparam: false);
      case _PresetAction.exportBbsparam:
        await _exportPreset(preset, bbsparam: true);
      case _PresetAction.delete:
        await _deletePreset(preset);
      case _PresetAction.report:
        await _reportPreset(preset);
    }
  }

  /// Phase E-4：举报社区参数。
  ///
  /// 仅对社区参数可用；本地/系统/云端预设不进入举报流程。
  /// 举报对话框关闭前禁用重复提交，成功后给反馈。
  Future<void> _reportPreset(PrintParameterPreset preset) async {
    final publication = _findCommunityPreset(preset);
    if (publication == null) {
      if (mounted) {
        showSnack(context, '仅可举报社区公开参数', error: true);
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ReportPresetDialog(publication: publication),
    );
  }

  Future<void> _applyPreset(PrintParameterPreset preset) async {
    if (_applyingIds.contains(preset.id)) return;
    setState(() => _applyingIds.add(preset.id));
    try {
      final path = await BambuStudioParamExporter.writeToBambuStudioUserDir(
        preset,
      );
      final publication = _findCommunityPreset(preset);
      final resultDao = ref.read(presetResultDaoProvider);
      final snapshotId = await resultDao.getOrCreateSnapshot(preset);
      final applicationId = await resultDao.recordApplication(
        snapshotId: snapshotId,
        displayName: preset.name,
        localPresetId: publication == null ? preset.id : null,
        communityPublicationId: publication?.publicationId,
        communityVersionId: publication?.versionId,
        communityRevision: publication?.revision,
        slicerProcessSettingsId: path_util.basenameWithoutExtension(path),
      );
      if (publication != null) {
        await ref
            .read(communityPresetFeedProvider.notifier)
            .registerDownload(publication);
        unawaited(
          ref
              .read(communityShareServiceProvider)
              .uploadApplicationRecord(
                publication.publicationId,
                applicationId,
              ),
        );
      } else {
        await ref
            .read(parameterPresetProvider.notifier)
            .incrementDownloads(preset.id);
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('已应用到拓竹切片'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('预设「${preset.name}」已写入用户工艺预设目录。'),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Aurora.fill,
                    borderRadius: BorderRadius.circular(Aurora.radius),
                    border: Border.all(color: Aurora.line),
                  ),
                  child: SelectableText(
                    path,
                    style: Aurora.mono.copyWith(fontSize: 11),
                  ),
                ),
                const SizedBox(height: 10),
                const Text('重新启动拓竹切片后，即可在工艺预设列表中使用。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('完成'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await _launchBambuStudio();
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              icon: Builder(
                builder: (context) => BambuIcon(
                  name: 'open_in_browser',
                  size: 16,
                  color: GlassButtonsTheme.enabledOf(context)
                      ? IconTheme.of(context).color
                      : Colors.white,
                  applyColorFilter: true,
                ),
              ),
              label: const Text('打开拓竹切片'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        showSnack(
          context,
          '${friendlyError(error)}\n请确认已安装并启动过拓竹切片。',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _applyingIds.remove(preset.id));
    }
  }

  Future<void> _uploadPreset(PrintParameterPreset preset) async {
    if (_isSystem(preset)) {
      showSnack(context, '请先复制为自定义预设，再上传到云端', error: true);
      return;
    }
    final session = ref.read(bambuCloudProvider).session;
    if (session == null) {
      showSnack(context, '请先登录拓竹云账号', error: true);
      return;
    }
    final isUpdate = preset.shareId?.isNotEmpty == true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isUpdate ? '更新云端预设' : '上传到拓竹云端'),
        content: Text(
          isUpdate
              ? '将用当前内容更新云端预设「${preset.name}」。'
              : '将预设「${preset.name}」上传到当前拓竹账号。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isUpdate ? '更新' : '上传'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final updated = await PresetCloudUploader.upload(
        session: session,
        preset: preset,
      );
      await ref.read(parameterPresetProvider.notifier).update(updated);
      ref.invalidate(cloudParameterPresetsProvider);
      if (mounted) showSnack(context, isUpdate ? '云端预设已更新' : '预设已上传到云端');
    } catch (error) {
      if (mounted) {
        showSnack(context, '上传失败：${friendlyError(error)}', error: true);
      }
    }
  }

  Future<void> _publishCommunityPreset(PrintParameterPreset preset) async {
    if (_isSystem(preset)) {
      showSnack(context, '请先复制为自定义预设，再发布到参数广场', error: true);
      return;
    }
    final auth = ref.read(appAuthProvider);
    if (auth.endpoint == null) {
      showSnack(context, 'sohun 云暂时不可用，请稍后重试', error: true);
      return;
    }
    if (auth.session == null) {
      showSnack(context, '请先登录工作台账号', error: true);
      return;
    }
    final isUpdate = preset.communityPublicationId?.isNotEmpty == true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isUpdate ? '更新广场参数' : '发布到参数广场'),
        content: Text(
          isUpdate
              ? '用当前内容更新已发布的「${preset.name}」。'
              : '公开发布「${preset.name}」，其他用户可以搜索并应用这套参数。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isUpdate ? '更新' : '发布'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final validSession = await ref
          .read(appAuthProvider.notifier)
          .ensureValidSession();
      final published = isUpdate
          ? await ref
                .read(communityPresetApiProvider)!
                .updatePublishedPreset(
                  accessToken: validSession.accessToken,
                  publicationId: preset.communityPublicationId!,
                  revision: preset.communityRevision ?? 1,
                  preset: preset,
                  visibility: preset.communityVisibility ?? 'public',
                )
          : await ref
                .read(communityPresetFeedProvider.notifier)
                .publish(preset);
      if (ref
          .read(parameterPresetProvider)
          .any((item) => item.id == preset.id)) {
        await ref
            .read(parameterPresetProvider.notifier)
            .update(
              preset.copyWith(
                communityPublicationId: published.publicationId,
                communityOwnerId: auth.user!.id,
                communityRevision: published.revision,
                communityVisibility: published.visibility,
              ),
            );
      }
      await ref
          .read(myCommunityPresetFeedProvider.notifier)
          .refresh(force: true);
      if (mounted) {
        showSnack(context, isUpdate ? '广场参数已更新' : '已发布到参数广场');
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, '发布失败：${friendlyError(error)}', error: true);
      }
    }
  }

  Future<void> _exportPreset(
    PrintParameterPreset preset, {
    required bool bbsparam,
  }) async {
    final extension = bbsparam ? 'bbsparam' : 'json';
    final safeName = preset.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final location = await getSaveLocation(
      suggestedName: '$safeName.$extension',
      acceptedTypeGroups: [
        XTypeGroup(
          label: bbsparam ? 'BBS Param' : 'JSON',
          extensions: [extension],
        ),
      ],
    );
    if (location == null) return;
    final content = bbsparam
        ? BambuStudioParamExporter.exportToBbsparam(preset)
        : BambuStudioParamExporter.exportToBambuStudioJson(preset);
    await File(location.path).writeAsString(content);
    if (mounted) showSnack(context, '已导出 ${preset.name}.$extension');
  }

  Future<void> _deletePreset(PrintParameterPreset preset) async {
    if (_isSystem(preset)) return;
    final publication = _findCommunityPreset(preset);
    if (publication != null &&
        !publication.ownedByMe &&
        publication.owner.id != ref.read(appAuthProvider).user?.id) {
      showSnack(context, '只能删除自己发布的参数', error: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除预设'),
        content: Text('确定删除「${preset.name}」吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: glassButtonStyle(
              context,
              FilledButton.styleFrom(backgroundColor: Aurora.danger),
              variant: AppGlassButtonVariant.primary,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (publication != null) {
      try {
        await ref
            .read(myCommunityPresetFeedProvider.notifier)
            .deletePublication(publication);
        await ref
            .read(parameterPresetProvider.notifier)
            .clearCommunityPublication(publication.publicationId);
        await _refreshCommunityPresets(announce: false);
        if (mounted) showSnack(context, '已从参数广场删除「${preset.name}」');
      } catch (error) {
        if (mounted) {
          showSnack(context, '删除失败：${friendlyError(error)}', error: true);
        }
      }
      return;
    }
    await ref
        .read(parameterPresetProvider.notifier)
        .delete(
          preset.id,
          onDeleted: (id) => ref.read(likedPresetsProvider.notifier).remove(id),
        );
    if (mounted) showSnack(context, '已删除「${preset.name}」');
  }

  Future<void> _launchBambuStudio() async {
    final paths = <String>{
      if (Platform.environment['PROGRAMFILES'] != null)
        '${Platform.environment['PROGRAMFILES']}\\Bambu Studio\\bambu-studio.exe',
      if (Platform.environment['LOCALAPPDATA'] != null)
        '${Platform.environment['LOCALAPPDATA']}\\Programs\\Bambu Studio\\bambu-studio.exe',
    };
    for (final path in paths) {
      if (await File(path).exists()) {
        await Process.start(path, const []);
        return;
      }
    }
    if (mounted) showSnack(context, '未找到拓竹切片可执行文件', error: true);
  }

  static bool _isSystem(PrintParameterPreset preset) =>
      preset.id.startsWith('builtin_') || preset.id.startsWith('system_');

  static List<String> _values(Iterable<String?> source) {
    final values = source
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    values.sort();
    return values;
  }
}

class _HeaderMetric extends StatelessWidget {
  final String label;
  final int value;

  const _HeaderMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 58,
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: Aurora.fill,
        borderRadius: BorderRadius.circular(Aurora.radius),
        border: Border.all(color: Aurora.line),
      ),
      child: Column(
        children: [
          Text('$value', style: Aurora.mono.copyWith(fontSize: 15)),
          const SizedBox(height: 1),
          Text(label, style: Aurora.label(context).copyWith(fontSize: 10)),
        ],
      ),
    );
  }
}

class _CategoryRail extends StatelessWidget {
  final _PresetScope scope;
  final int publicPresetCount;
  final int publishedPresetCount;
  final int cloudPresetCount;
  final int localPresetCount;
  final Set<String> likedIds;
  final ValueChanged<_PresetScope> onScopeChanged;

  const _CategoryRail({
    required this.scope,
    required this.publicPresetCount,
    required this.publishedPresetCount,
    required this.cloudPresetCount,
    required this.localPresetCount,
    required this.likedIds,
    required this.onScopeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return FrostPanel(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      color: Aurora.panelStrong,
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
            child: Text(
              '预设目录',
              style: Aurora.title(context).copyWith(fontSize: 15),
            ),
          ),
          const _RailLabel('发现'),
          _RailItem(
            icon: 'tab_presets_active',
            label: '广场预设',
            count: publicPresetCount,
            selected: scope == _PresetScope.all,
            onTap: () => onScopeChanged(_PresetScope.all),
          ),
          _RailItem(
            icon: 'bar_publish',
            label: '我的发布',
            count: publishedPresetCount,
            selected: scope == _PresetScope.published,
            onTap: () => onScopeChanged(_PresetScope.published),
          ),
          _RailItem(
            icon: 'edit',
            label: '我的预设',
            count: cloudPresetCount,
            selected: scope == _PresetScope.mine,
            onTap: () => onScopeChanged(_PresetScope.mine),
          ),
          _RailItem(
            icon: 'save',
            label: '本地草稿',
            count: localPresetCount,
            selected: scope == _PresetScope.local,
            onTap: () => onScopeChanged(_PresetScope.local),
          ),
          _RailItem(
            icon: 'confirm',
            label: '我的点赞',
            count: likedIds.length,
            selected: scope == _PresetScope.liked,
            onTap: () => onScopeChanged(_PresetScope.liked),
          ),
        ],
      ),
    );
  }
}

class _RailLabel extends StatelessWidget {
  final String label;
  const _RailLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 5),
      child: Text(
        label,
        style: Aurora.label(
          context,
        ).copyWith(fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final String icon;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _RailItem({
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? Aurora.primary : Aurora.textSoft;
    return Material(
      color: selected
          ? Aurora.primary.withValues(alpha: 0.09)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(Aurora.radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Aurora.radius),
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              const SizedBox(width: 9),
              BambuIcon(
                name: icon,
                size: 16,
                color: color,
                applyColorFilter: true,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
              Text(
                '$count',
                style: Aurora.mono.copyWith(fontSize: 10, color: color),
              ),
              const SizedBox(width: 9),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrinterFilterChoice {
  final String? model;

  const _PrinterFilterChoice(this.model);
}

class _PrinterFilterDialog extends StatefulWidget {
  final List<PrinterPreset> printers;
  final String? selectedModel;

  const _PrinterFilterDialog({
    required this.printers,
    required this.selectedModel,
  });

  @override
  State<_PrinterFilterDialog> createState() => _PrinterFilterDialogState();
}

class _PrinterFilterDialogState extends State<_PrinterFilterDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final byModel = <String, PrinterPreset>{};
    for (final printer in widget.printers) {
      byModel.putIfAbsent(printer.printerModel, () => printer);
    }
    final query = _query.toLowerCase();
    final printers =
        byModel.values
            .where(
              (printer) =>
                  printer.printerModel.toLowerCase().contains(query) ||
                  printer.name.toLowerCase().contains(query),
            )
            .toList()
          ..sort((a, b) => a.printerModel.compareTo(b.printerModel));
    final colors = Theme.of(context).colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 760,
        height: 590,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
              child: Row(
                children: [
                  Icon(Icons.print_outlined, color: colors.primary, size: 21),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text(
                      '选择打印机',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: const InputDecoration(
                  hintText: '搜索打印机型号',
                  prefixIcon: Icon(Icons.search_rounded, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(14),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 170,
                  childAspectRatio: 0.88,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                ),
                itemCount: printers.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _PrinterFilterTile(
                      label: '全部打印机',
                      selected: widget.selectedModel == null,
                      onTap: () => Navigator.of(
                        context,
                      ).pop(const _PrinterFilterChoice(null)),
                    );
                  }
                  final printer = printers[index - 1];
                  return _PrinterFilterTile(
                    label: _shortPrinterModel(printer.printerModel),
                    imageAsset: _printerImageAsset(printer.printerModel),
                    selected:
                        widget.selectedModel != null &&
                        _printerModelMatches(
                          printer.printerModel,
                          widget.selectedModel!,
                        ),
                    onTap: () => Navigator.of(
                      context,
                    ).pop(_PrinterFilterChoice(printer.printerModel)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrinterFilterTile extends StatelessWidget {
  final String label;
  final String? imageAsset;
  final bool selected;
  final VoidCallback onTap;

  const _PrinterFilterTile({
    required this.label,
    this.imageAsset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.primaryContainer.withValues(alpha: 0.55)
          : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: imageAsset == null
                          ? Icon(
                              Icons.apps_rounded,
                              size: 48,
                              color: colors.onSurfaceVariant,
                            )
                          : PrinterImage(
                              assetPath: imageAsset,
                              brand: '拓竹',
                              size: 92,
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.2,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Positioned(
                right: 6,
                top: 6,
                child: Icon(
                  Icons.check_circle_rounded,
                  size: 19,
                  color: colors.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _shortPrinterModel(String model) {
  return model.replaceFirst(RegExp(r'^Bambu Lab\s+'), '');
}

String? _printerImageAsset(String model) {
  const assets = <String, String>{
    'Bambu Lab X1 Carbon': 'assets/images/printers/bambu_x1c.png',
    'Bambu Lab X1': 'assets/images/printers/bambu_x1.png',
    'Bambu Lab X1E': 'assets/images/printers/bambu_x1e.png',
    'Bambu Lab X2D': 'assets/images/printers/bambu_x2d.png',
    'Bambu Lab P1P': 'assets/images/printers/bambu_p1p.webp',
    'Bambu Lab P1S': 'assets/images/printers/bambu_p1s.png',
    'Bambu Lab P2S': 'assets/images/printers/bambu_p2s.png',
    'Bambu Lab A1': 'assets/images/printers/bambu_a1.png',
    'Bambu Lab A1 mini': 'assets/images/printers/bambu_a1_mini.png',
    'Bambu Lab A2L': 'assets/images/printers/bambu_a2l.png',
    'Bambu Lab H2D': 'assets/images/printers/bambu_h2d.webp',
    'Bambu Lab H2D Pro': 'assets/images/printers/bambu_h2d_pro.webp',
    'Bambu Lab H2S': 'assets/images/printers/bambu_h2s.webp',
    'Bambu Lab H2C': 'assets/images/printers/bambu_h2c.webp',
  };
  return assets[model];
}

bool _printerModelMatches(String candidate, String selected) {
  return _normalizePrinterModel(candidate) == _normalizePrinterModel(selected);
}

String _normalizePrinterModel(String value) {
  var normalized = value.toLowerCase();
  normalized = normalized.replaceAll(RegExp(r'\bx1c\b'), 'x1 carbon');
  normalized = normalized.replaceAll(RegExp(r'\ba1m\b'), 'a1 mini');
  normalized = normalized.replaceAll(RegExp(r'\bh2dp\b'), 'h2d pro');
  normalized = normalized.replaceAll(
    RegExp(r'\s+[0-9.]+\s*(?:mm\s*)?nozzle.*$'),
    '',
  );
  normalized = normalized.replaceAll('bambu lab', '');
  normalized = normalized.replaceAll('@bbl', '');
  normalized = normalized.replaceAll('bbl', '');
  return normalized.replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

class _FilterPickerButton extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onPressed;

  const _FilterPickerButton({
    required this.label,
    required this.value,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (GlassButtonsTheme.enabledOf(context)) {
      return SizedBox(
        width: 132,
        height: 40,
        child: AppGlassButton(
          label: value ?? '全部$label',
          onPressed: onPressed,
          variant: value == null
              ? AppGlassButtonVariant.quiet
              : AppGlassButtonVariant.primary,
          compact: true,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  value ?? '全部$label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: value == null
                        ? FontWeight.w500
                        : FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.open_in_new_rounded, size: 14),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      width: 132,
      height: 40,
      child: Material(
        color: Aurora.fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Aurora.radius),
          side: BorderSide(color: value == null ? Aurora.line : Aurora.primary),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(Aurora.radius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value ?? '全部$label',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: value == null
                          ? FontWeight.w500
                          : FontWeight.w700,
                      color: value == null ? Aurora.textSoft : Aurora.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.open_in_new_rounded,
                  size: 14,
                  color: value == null ? Aurora.textSoft : Aurora.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterChoice {
  final String? value;

  const _FilterChoice(this.value);
}

class _FilterPickerDialog extends StatefulWidget {
  final String label;
  final List<String> values;
  final String? selected;
  final IconData icon;

  const _FilterPickerDialog({
    required this.label,
    required this.values,
    required this.selected,
    required this.icon,
  });

  @override
  State<_FilterPickerDialog> createState() => _FilterPickerDialogState();
}

class _FilterPickerDialogState extends State<_FilterPickerDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? const Color(0xFF171B1D) : Colors.white;
    final query = _query.toLowerCase();
    final filtered = widget.values
        .where((value) => value.toLowerCase().contains(query))
        .toList();

    return Dialog(
      backgroundColor: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Aurora.radius),
      ),
      child: SizedBox(
        width: 680,
        height: 540,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(widget.icon, size: 21, color: Aurora.primary),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '选择${widget.label}',
                      style: Aurora.title(context).copyWith(fontSize: 16),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: InputDecoration(
                  hintText: '搜索${widget.label}',
                  prefixIcon: const Icon(Icons.search_rounded, size: 19),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                  filled: true,
                  fillColor: Aurora.fill,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Aurora.radius),
                    borderSide: BorderSide(color: Aurora.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Aurora.radius),
                    borderSide: BorderSide(color: Aurora.line),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 300,
                    mainAxisExtent: 48,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: filtered.length + 1,
                  itemBuilder: (context, index) {
                    final value = index == 0 ? null : filtered[index - 1];
                    final selected = value == widget.selected;
                    return Material(
                      color: selected
                          ? Aurora.primary.withValues(alpha: 0.1)
                          : Aurora.fill,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Aurora.radius),
                        side: BorderSide(
                          color: selected ? Aurora.primary : Aurora.line,
                        ),
                      ),
                      child: InkWell(
                        onTap: () =>
                            Navigator.of(context).pop(_FilterChoice(value)),
                        borderRadius: BorderRadius.circular(Aurora.radius),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              Icon(
                                selected
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_off_rounded,
                                size: 18,
                                color: selected
                                    ? Aurora.primary
                                    : Aurora.textSoft,
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  value ?? '全部${widget.label}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: selected
                                        ? Aurora.primary
                                        : Aurora.text,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SortSelect extends StatelessWidget {
  final _PresetSort value;
  final ValueChanged<_PresetSort> onChanged;

  const _SortSelect({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 124,
      child: AppSelect<_PresetSort>(
        value: value,
        items: const [
          DropdownMenuItem(value: _PresetSort.recommended, child: Text('推荐排序')),
          DropdownMenuItem(value: _PresetSort.newest, child: Text('最近更新')),
          DropdownMenuItem(value: _PresetSort.popular, child: Text('应用最多')),
          DropdownMenuItem(value: _PresetSort.mostLiked, child: Text('点赞最多')),
          DropdownMenuItem(value: _PresetSort.name, child: Text('名称排序')),
        ],
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    );
  }
}

class _ParameterLabTray extends StatelessWidget {
  const _ParameterLabTray({
    required this.presets,
    required this.onRemove,
    required this.onClear,
    required this.onCompare,
  });

  final List<PrintParameterPreset> presets;
  final ValueChanged<PrintParameterPreset> onRemove;
  final VoidCallback onClear;
  final VoidCallback onCompare;

  @override
  Widget build(BuildContext context) {
    final differenceCount = presets.length == 2
        ? PresetDiffService.comparePresets(presets[0], presets[1]).length
        : null;
    return OpenStage(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      color: Aurora.panelStrong,
      borderColor: Aurora.primary.withValues(alpha: 0.25),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.science_outlined, color: Aurora.primary, size: 19),
              const SizedBox(width: 8),
              Text(
                '参数对比实验台',
                style: Aurora.title(context).copyWith(fontSize: 13),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  differenceCount == null
                      ? '再选择一个预设即可比较'
                      : '检测到 $differenceCount 项参数差异',
                  style: Aurora.label(context),
                ),
              ),
              TextButton(onPressed: onClear, child: const Text('清空')),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: presets.length == 2 ? onCompare : null,
                icon: const Icon(Icons.compare_arrows_rounded, size: 16),
                label: const Text('展开对比'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _LabPresetSlot(
                  label: 'A',
                  preset: presets.isEmpty ? null : presets[0],
                  onRemove: presets.isEmpty ? null : () => onRemove(presets[0]),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Icon(
                  Icons.compare_arrows_rounded,
                  color: Aurora.textSoft,
                  size: 20,
                ),
              ),
              Expanded(
                child: _LabPresetSlot(
                  label: 'B',
                  preset: presets.length < 2 ? null : presets[1],
                  onRemove: presets.length < 2
                      ? null
                      : () => onRemove(presets[1]),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LabPresetSlot extends StatelessWidget {
  const _LabPresetSlot({
    required this.label,
    required this.preset,
    required this.onRemove,
  });

  final String label;
  final PrintParameterPreset? preset;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: ExperienceTokens.contentDuration,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: preset == null
            ? Aurora.fill.withValues(alpha: 0.45)
            : Aurora.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(Aurora.radius),
        border: Border.all(
          color: preset == null
              ? Aurora.line
              : Aurora.primary.withValues(alpha: 0.32),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: preset == null ? Aurora.fill : Aurora.primary,
              shape: BoxShape.circle,
            ),
            child: Text(
              label,
              style: TextStyle(
                color: preset == null ? Aurora.textSoft : Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preset?.name ?? '等待选择',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Aurora.title(context).copyWith(fontSize: 11),
                ),
                Text(
                  preset == null
                      ? '点击预设卡片上的实验图标'
                      : '${preset!.material ?? '通用材料'} · ${preset!.quality.layerHeight} mm',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Aurora.label(context).copyWith(fontSize: 9),
                ),
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              tooltip: '移出对比',
              icon: const Icon(Icons.close_rounded, size: 16),
              color: Aurora.textSoft,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

class _PresetGrid extends StatelessWidget {
  final List<PrintParameterPreset> presets;
  final Set<String> likedIds;
  final Map<String, CommunityPreset> communityByPresetId;
  final String? currentAppUserId;
  final Set<String> applyingIds;
  final Set<String> compareIds;
  final ValueChanged<PrintParameterPreset> onOpen;
  final ValueChanged<PrintParameterPreset> onApply;
  final ValueChanged<PrintParameterPreset> onLike;
  final ValueChanged<PrintParameterPreset> onCompareToggle;
  final void Function(PrintParameterPreset, _PresetAction) onAction;
  final bool hasMore;
  final bool isLoadingMore;
  final String? loadMoreError;
  final Future<void> Function()? onLoadMore;

  const _PresetGrid({
    required this.presets,
    required this.likedIds,
    required this.communityByPresetId,
    required this.currentAppUserId,
    required this.applyingIds,
    required this.compareIds,
    required this.onOpen,
    required this.onApply,
    required this.onLike,
    required this.onCompareToggle,
    required this.onAction,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.loadMoreError,
    this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1180
            ? 3
            : constraints.maxWidth >= 720
            ? 2
            : 1;
        const spacing = 12.0;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final preset in presets)
                SizedBox(
                  width: width,
                  child: _PresetCard(
                    preset: preset,
                    publication: communityByPresetId[preset.id],
                    ownedCommunity:
                        communityByPresetId[preset.id]?.owner.id ==
                        currentAppUserId,
                    liked: likedIds.contains(preset.id),
                    applying: applyingIds.contains(preset.id),
                    selectedForCompare: compareIds.contains(preset.id),
                    onOpen: () => onOpen(preset),
                    onApply: () => onApply(preset),
                    onLike: () => onLike(preset),
                    onCompareToggle: () => onCompareToggle(preset),
                    onAction: (action) => onAction(preset, action),
                  ),
                ),
              if (hasMore || isLoadingMore || loadMoreError != null)
                SizedBox(
                  width: constraints.maxWidth,
                  child: Center(
                    child: loadMoreError != null && !hasMore
                        ? Text(
                            loadMoreError!,
                            style: Aurora.label(
                              context,
                            ).copyWith(color: Aurora.warning),
                          )
                        : TextButton.icon(
                            onPressed: isLoadingMore ? null : onLoadMore,
                            icon: isLoadingMore
                                ? const SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.expand_more, size: 18),
                            label: Text(
                              loadMoreError == null ? '加载更多' : '重试加载',
                            ),
                          ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

enum _PresetAction {
  open,
  edit,
  duplicate,
  upload,
  publish,
  exportJson,
  exportBbsparam,
  delete,
  report,
}

String _printerLabel(PrintParameterPreset preset) {
  if (preset.compatiblePrinters.isEmpty) return '通用机型';
  final models = preset.compatiblePrinters
      .map((value) {
        return value
            .replaceFirst('Bambu Lab ', '')
            .replaceAll(RegExp(r'\s+[0-9.]+\s+nozzle$'), '')
            .trim();
      })
      .toSet()
      .toList();
  if (models.length <= 2) return models.join(' / ');
  return '${models.take(2).join(' / ')} 等 ${models.length} 款';
}

String _supportLabel(PrintParameterPreset preset) {
  final enabled = preset.support.enableSupport.toLowerCase();
  if (enabled != '1' && enabled != 'true') return '无';
  final type = preset.support.supportType.toLowerCase();
  if (type.contains('tree')) return '树状';
  return '普通';
}

class _PresetCard extends StatelessWidget {
  final PrintParameterPreset preset;
  final CommunityPreset? publication;
  final bool ownedCommunity;
  final bool liked;
  final bool applying;
  final bool selectedForCompare;
  final VoidCallback onOpen;
  final VoidCallback onApply;
  final VoidCallback onLike;
  final VoidCallback onCompareToggle;
  final ValueChanged<_PresetAction> onAction;

  const _PresetCard({
    required this.preset,
    required this.publication,
    required this.ownedCommunity,
    required this.liked,
    required this.applying,
    required this.selectedForCompare,
    required this.onOpen,
    required this.onApply,
    required this.onLike,
    required this.onCompareToggle,
    required this.onAction,
  });

  bool get _system =>
      preset.id.startsWith('builtin_') || preset.id.startsWith('system_');
  bool get _community => publication != null;

  @override
  Widget build(BuildContext context) {
    return FrostPanel(
      padding: EdgeInsets.zero,
      elevated: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PresetPreview(
            preset: preset,
            system: _system,
            verifiedApplicationCount: publication?.applicationCount,
            onTap: onOpen,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        preset.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Aurora.title(context).copyWith(fontSize: 14),
                      ),
                    ),
                    Tooltip(
                      message: selectedForCompare ? '移出对比实验台' : '加入对比实验台',
                      child: IconButton(
                        onPressed: onCompareToggle,
                        icon: Icon(
                          selectedForCompare
                              ? Icons.science_rounded
                              : Icons.science_outlined,
                          size: 18,
                        ),
                        color: selectedForCompare
                            ? Aurora.primary
                            : Aurora.textSoft,
                        style: glassButtonStyle(
                          context,
                          IconButton.styleFrom(
                            backgroundColor: selectedForCompare
                                ? Aurora.primary.withValues(alpha: 0.12)
                                : Aurora.fill,
                            minimumSize: const Size(30, 30),
                            maximumSize: const Size(30, 30),
                            padding: EdgeInsets.zero,
                          ),
                          variant: AppGlassButtonVariant.quiet,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    BambuGlyphButton(
                      icon: liked ? 'favorite_filled' : 'favorite',
                      tooltip: liked ? '取消点赞' : '点赞',
                      color: liked ? Aurora.danger : Aurora.textSoft,
                      onPressed: onLike,
                      size: 30,
                    ),
                    PopupMenuButton<_PresetAction>(
                      tooltip: '更多操作',
                      onSelected: onAction,
                      padding: EdgeInsets.zero,
                      elevation: 8,
                      color: Aurora.panelStrong,
                      surfaceTintColor: Colors.transparent,
                      position: PopupMenuPosition.under,
                      constraints: const BoxConstraints(minWidth: 210),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Aurora.radius),
                        side: BorderSide(color: Aurora.line),
                      ),
                      icon: Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: GlassButtonsTheme.enabledOf(context)
                              ? Colors.transparent
                              : Aurora.fill,
                          borderRadius: BorderRadius.circular(Aurora.radius),
                          border: GlassButtonsTheme.enabledOf(context)
                              ? null
                              : Border.all(color: Aurora.line),
                        ),
                        child: Builder(
                          builder: (context) => BambuIcon(
                            name: 'more',
                            size: 17,
                            color: GlassButtonsTheme.enabledOf(context)
                                ? IconTheme.of(context).color
                                : Aurora.textSoft,
                            applyColorFilter: true,
                          ),
                        ),
                      ),
                      itemBuilder: (_) => [
                        _menuItem(_PresetAction.open, '查看详情', 'open'),
                        if (!_system && (!_community || ownedCommunity))
                          _menuItem(_PresetAction.edit, '编辑参数', 'edit'),
                        _menuItem(
                          _PresetAction.duplicate,
                          '复制为新预设',
                          'tree_copy',
                        ),
                        if (!_system && !_community)
                          _menuItem(
                            _PresetAction.publish,
                            '发布到参数广场',
                            'bar_publish',
                          ),
                        if (!_system && !_community)
                          _menuItem(
                            _PresetAction.upload,
                            '上传到拓竹云端',
                            'bar_publish',
                          ),
                        _menuItem(
                          _PresetAction.exportJson,
                          '导出 JSON',
                          'tree_export',
                        ),
                        _menuItem(
                          _PresetAction.exportBbsparam,
                          '导出 .bbsparam',
                          'save',
                        ),
                        if (!_system && (!_community || ownedCommunity))
                          _menuItem(
                            _PresetAction.delete,
                            '删除',
                            'tree_delete',
                            danger: true,
                          ),
                        // Phase E-4：非作者本人的社区参数允许举报
                        if (_community && !ownedCommunity)
                          _menuItem(
                            _PresetAction.report,
                            '举报参数',
                            'warning',
                            danger: true,
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _AuthorLine(
                  name:
                      publication?.owner.displayName ?? preset.author ?? '本地作者',
                  handle: publication?.owner.handle,
                  avatarUrl: publication?.owner.avatarUrl ?? preset.avatarUrl,
                ),
                if (_community) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _TrustBadge(publicationId: publication!.publicationId),
                      _AuthorReputationBadge(handle: publication!.owner.handle),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  preset.description?.isNotEmpty == true
                      ? preset.description!
                      : '暂无描述',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Aurora.label(context).copyWith(height: 1.4),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (preset.material?.isNotEmpty == true)
                      _Tag(preset.material!),
                    if (preset.scene?.isNotEmpty == true) _Tag(preset.scene!),
                    _Tag(_printerLabel(preset)),
                    for (final tag in preset.tags.take(2)) _Tag(tag),
                  ],
                ),
                const SizedBox(height: 11),
                Row(
                  children: [
                    Expanded(
                      child: _Spec(label: '打印机', value: _printerLabel(preset)),
                    ),
                    Expanded(
                      child: _Spec(
                        label: '层高',
                        value: '${preset.quality.layerHeight} mm',
                      ),
                    ),
                    Expanded(
                      child: _Spec(label: '支撑', value: _supportLabel(preset)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _Spec(
                        label: '墙层数',
                        value: preset.strength.wallLoops,
                      ),
                    ),
                    Expanded(
                      child: _Spec(
                        label: '填充',
                        value: preset.strength.sparseInfillDensity,
                      ),
                    ),
                    Expanded(
                      child: _Spec(label: '材料', value: preset.material ?? '通用'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onOpen,
                        child: Text(
                          _system || (_community && !ownedCommunity)
                              ? '查看参数'
                              : '查看与编辑',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: applying ? null : onApply,
                        icon: applying
                            ? Builder(
                                builder: (context) => SizedBox.square(
                                  dimension: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: GlassButtonsTheme.enabledOf(context)
                                        ? IconTheme.of(context).color
                                        : Colors.white,
                                  ),
                                ),
                              )
                            : Builder(
                                builder: (context) => BambuIcon(
                                  name: 'confirm',
                                  size: 15,
                                  color: GlassButtonsTheme.enabledOf(context)
                                      ? IconTheme.of(context).color
                                      : Colors.white,
                                  applyColorFilter: true,
                                ),
                              ),
                        label: Text(applying ? '正在应用' : '应用到切片'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<_PresetAction> _menuItem(
    _PresetAction value,
    String label,
    String icon, {
    bool danger = false,
  }) {
    final color = danger ? Aurora.danger : Aurora.textSoft;
    return PopupMenuItem(
      value: value,
      height: 40,
      child: Row(
        children: [
          BambuIcon(name: icon, size: 16, color: color, applyColorFilter: true),
          const SizedBox(width: 9),
          Text(label, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}

class _PresetPreview extends StatefulWidget {
  final PrintParameterPreset preset;
  final bool system;
  final int? verifiedApplicationCount;
  final VoidCallback onTap;

  const _PresetPreview({
    required this.preset,
    required this.system,
    required this.onTap,
    this.verifiedApplicationCount,
  });

  @override
  State<_PresetPreview> createState() => _PresetPreviewState();
}

class _PresetPreviewState extends State<_PresetPreview> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final community = preset.id.startsWith('community_');
    final placeholder = Container(
      color: const Color(0xFFEAF2EC),
      child: Center(
        child: BambuIcon(
          name: 'tab_presets_active',
          size: 42,
          color: Aurora.primary,
          applyColorFilter: true,
        ),
      ),
    );
    final preview = preset.previewImageUrl?.isNotEmpty == true
        ? _PresetImage(path: preset.previewImageUrl!, fallback: placeholder)
        : placeholder;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        key: ValueKey('preset-preview-${preset.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          height: 112,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedScale(
                scale: _hovering && AppMotion.enabled(context) ? 1.035 : 1,
                duration: AppMotion.duration(
                  context,
                  ExperienceTokens.hoverDuration,
                ),
                curve: ExperienceTokens.motionCurve,
                child: preview,
              ),
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _hovering ? 1 : 0,
                  duration: AppMotion.duration(
                    context,
                    ExperienceTokens.hoverDuration,
                  ),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.16),
                    child: Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.34),
                          ),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.visibility_outlined,
                                size: 14,
                                color: Colors.white,
                              ),
                              SizedBox(width: 6),
                              Text(
                                '查看参数',
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
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 10,
                top: 10,
                child: StatusPill(
                  label: widget.system
                      ? '拓竹系统预设'
                      : community
                      ? '社区分享'
                      : '自定义预设',
                  color: widget.system
                      ? Aurora.blue
                      : community
                      ? Aurora.violet
                      : Aurora.primary,
                ),
              ),
              if (preset.shareId?.isNotEmpty == true)
                const Positioned(
                  right: 10,
                  top: 10,
                  child: StatusPill(label: '已上传', color: Aurora.violet),
                ),
              Positioned(
                right: 10,
                bottom: 9,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(Aurora.radius),
                  ),
                  child: Text(
                    widget.verifiedApplicationCount == null
                        ? '${preset.downloads} 次应用'
                        : '${widget.verifiedApplicationCount} 次登录应用',
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: AppTypography.monoFontFamily,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetImage extends ConsumerWidget {
  final String path;
  final Widget fallback;

  const _PresetImage({required this.path, required this.fallback});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trustedOrigin = ref.watch(
      appAuthProvider.select((state) => state.endpoint),
    );
    final remoteUri = parsePublicHttpsImageUrl(
      path,
      trustedOrigin: trustedOrigin,
    );
    if (remoteUri != null) {
      return Image.network(
        remoteUri.toString(),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      );
    }
    if (!isLocalImageReference(path)) return fallback;
    return FutureBuilder<String>(
      future: ImageStorage.getFullPath(path),
      builder: (_, snapshot) {
        if (snapshot.hasData && File(snapshot.data!).existsSync()) {
          return Image.file(
            File(snapshot.data!),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback,
          );
        }
        return fallback;
      },
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  const _Tag(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Aurora.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Aurora.radius),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Aurora.primary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AuthorLine extends StatelessWidget {
  final String name;
  final String? handle;
  final String? avatarUrl;

  const _AuthorLine({required this.name, this.handle, this.avatarUrl});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _AuthorAvatar(name: name, path: avatarUrl),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            handle == null ? name : '$name  @$handle',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Aurora.label(context).copyWith(
              color: Aurora.text,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _AuthorAvatar extends ConsumerWidget {
  final String name;
  final String? path;

  const _AuthorAvatar({required this.name, this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initial = name.isEmpty ? '?' : String.fromCharCode(name.runes.first);
    final fallback = Container(
      color: Aurora.primary.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Aurora.primary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    final value = path?.trim();
    Widget image = fallback;
    final trustedOrigin = ref.watch(
      appAuthProvider.select((state) => state.endpoint),
    );
    final remoteUri = parsePublicHttpsImageUrl(
      value,
      trustedOrigin: trustedOrigin,
    );
    if (remoteUri != null) {
      image = Image.network(
        remoteUri.toString(),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      );
    } else if (value?.isNotEmpty == true && isLocalImageReference(value!)) {
      image = FutureBuilder<String>(
        future: ImageStorage.getFullPath(value),
        builder: (_, snapshot) {
          if (snapshot.hasData && File(snapshot.data!).existsSync()) {
            return Image.file(
              File(snapshot.data!),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback,
            );
          }
          return fallback;
        },
      );
    }
    return ClipOval(child: SizedBox.square(dimension: 22, child: image));
  }
}

class _Spec extends StatelessWidget {
  final String label;
  final String value;

  const _Spec({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Aurora.label(context).copyWith(fontSize: 10)),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Aurora.mono.copyWith(fontSize: 12),
        ),
      ],
    );
  }
}

class _PresetDetailDialog extends ConsumerWidget {
  final PrintParameterPreset preset;
  final bool isSystem;
  final bool isLiked;
  final bool canEdit;
  final bool applying;
  final String? communityPublicationId;
  final int? communityApplicationCount;
  final VoidCallback onLike;
  final VoidCallback onEdit;
  final VoidCallback onApply;

  const _PresetDetailDialog({
    required this.preset,
    required this.isSystem,
    required this.isLiked,
    required this.canEdit,
    required this.applying,
    this.communityPublicationId,
    this.communityApplicationCount,
    required this.onLike,
    required this.onEdit,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: MediaQuery.sizeOf(context).height - 80,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(preset.name, style: Aurora.title(context)),
                    ),
                    StatusPill(
                      label: isSystem ? '拓竹系统预设' : '自定义预设',
                      color: isSystem ? Aurora.blue : Aurora.primary,
                    ),
                    const SizedBox(width: 8),
                    BambuGlyphButton(
                      icon: 'cross',
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  preset.description?.isNotEmpty == true
                      ? preset.description!
                      : '暂无描述',
                  style: Aurora.label(context).copyWith(height: 1.5),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (preset.material?.isNotEmpty == true)
                      _Tag(preset.material!),
                    if (preset.scene?.isNotEmpty == true) _Tag(preset.scene!),
                    _Tag(_printerLabel(preset)),
                    for (final tag in preset.tags) _Tag(tag),
                  ],
                ),
                if (communityPublicationId != null) ...[
                  const SizedBox(height: 16),
                  _TrustDetailSection(publicationId: communityPublicationId!),
                ],
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Aurora.fill,
                    borderRadius: BorderRadius.circular(Aurora.radius),
                    border: Border.all(color: Aurora.line),
                  ),
                  child: Column(
                    children: [
                      _DetailRow(label: '作者', value: preset.author ?? '未标注'),
                      _DetailRow(label: '兼容打印机', value: _printerLabel(preset)),
                      _DetailRow(
                        label: '层高',
                        value: '${preset.quality.layerHeight} mm',
                      ),
                      _DetailRow(
                        label: '线宽',
                        value: '${preset.quality.lineWidth} mm',
                      ),
                      _DetailRow(
                        label: '墙层数',
                        value: preset.strength.wallLoops,
                      ),
                      _DetailRow(
                        label: '稀疏填充密度',
                        value: preset.strength.sparseInfillDensity,
                      ),
                      _DetailRow(
                        label: '稀疏填充图案',
                        value: preset.strength.sparseInfillPattern,
                      ),
                      _DetailRow(
                        label: '内墙速度',
                        value: '${preset.speed.innerWallSpeed} mm/s',
                      ),
                      _DetailRow(
                        label: '外墙速度',
                        value: '${preset.speed.outerWallSpeed} mm/s',
                      ),
                      _DetailRow(label: '支撑', value: _supportLabel(preset)),
                      _DetailRow(
                        label: communityApplicationCount == null
                            ? '应用次数'
                            : '登录应用',
                        value:
                            '${communityApplicationCount ?? preset.downloads}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: onLike,
                      icon: BambuIcon(
                        name: isLiked ? 'favorite_filled' : 'favorite',
                        size: 15,
                        color: isLiked ? Aurora.danger : Aurora.textSoft,
                        applyColorFilter: true,
                      ),
                      label: Text(isLiked ? '取消点赞' : '点赞'),
                    ),
                    const Spacer(),
                    OutlinedButton(
                      onPressed: onEdit,
                      child: Text(
                        isSystem
                            ? '查看全部参数'
                            : canEdit
                            ? '编辑全部参数'
                            : '复制后编辑',
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: applying ? null : onApply,
                      icon: Builder(
                        builder: (context) => BambuIcon(
                          name: 'confirm',
                          size: 15,
                          color: GlassButtonsTheme.enabledOf(context)
                              ? IconTheme.of(context).color
                              : Colors.white,
                          applyColorFilter: true,
                        ),
                      ),
                      label: const Text('应用到拓竹切片'),
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
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 128,
            child: Text(label, style: Aurora.label(context)),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Aurora.mono.copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _CloudPresetStatus extends StatelessWidget {
  final bool loading;
  final bool empty;
  final String? error;
  final VoidCallback? onRetry;

  const _CloudPresetStatus({
    this.loading = false,
    this.empty = false,
    this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else
              Icon(Icons.cloud_off_outlined, size: 34, color: Aurora.textSoft),
            const SizedBox(height: 12),
            Text(
              loading
                  ? '正在读取拓竹云端预设'
                  : empty
                  ? '云端还没有工艺预设'
                  : '云端预设读取失败',
              style: Aurora.title(context).copyWith(fontSize: 15),
            ),
            if (error != null) ...[
              const SizedBox(height: 6),
              Text(
                error!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Aurora.label(context),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              AuroraButton(
                label: '重新读取',
                icon: 'refresh_normal',
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CommunityPresetStatus extends StatelessWidget {
  final bool loading;
  final bool mine;
  final String? error;
  final VoidCallback? onRetry;

  const _CommunityPresetStatus({
    this.loading = false,
    this.mine = false,
    this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else
              BambuIcon(
                name: 'tab_presets_active',
                size: 38,
                color: Aurora.textSoft,
                applyColorFilter: true,
              ),
            const SizedBox(height: 12),
            Text(
              loading
                  ? mine
                        ? '正在读取我的发布'
                        : '正在读取参数广场'
                  : mine
                  ? '我的发布读取失败'
                  : '参数广场读取失败',
              style: Aurora.title(context).copyWith(fontSize: 15),
            ),
            if (error != null) ...[
              const SizedBox(height: 6),
              Text(
                error!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Aurora.label(context),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              BambuGlyphButton(
                icon: 'refresh_normal',
                tooltip: '重新读取',
                onPressed: onRetry,
                background: Aurora.fill,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyResult extends StatelessWidget {
  final bool hasFilters;
  final VoidCallback onReset;
  final VoidCallback onCreate;

  const _EmptyResult({
    required this.hasFilters,
    required this.onReset,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return FrostPanel(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BambuIcon(
              name: 'tab_presets_active',
              size: 48,
              color: Aurora.muted,
              applyColorFilter: true,
            ),
            const SizedBox(height: 12),
            Text(
              hasFilters ? '没有符合条件的预设' : '还没有参数预设',
              style: Aurora.title(context).copyWith(fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              hasFilters ? '调整分类、搜索词或筛选条件' : '创建第一个自定义工艺预设',
              style: Aurora.label(context),
            ),
            const SizedBox(height: 14),
            AuroraButton(
              label: hasFilters ? '清除筛选' : '新建预设',
              icon: hasFilters ? 'cross' : 'add_filament',
              onPressed: hasFilters ? onReset : onCreate,
            ),
          ],
        ),
      ),
    );
  }
}

// ===== Phase E-4：社区可信汇总与举报 =====

/// 卡片上的紧凑可信徽章。
///
/// 任务书 10.3/10.6 要求：
/// - 公共有效样本少于 3：显示"样本不足"，不显示百分比徽章。
/// - 达到阈值后展示"X 次社区实打 · Y% 可用"等紧凑摘要。
/// - 离线时显示上次缓存汇总并标注更新时间；不显示成实时数据。
class _TrustBadge extends ConsumerWidget {
  final String publicationId;

  const _TrustBadge({required this.publicationId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSummary = ref.watch(trustSummaryProvider(publicationId));
    return asyncSummary.when(
      loading: () => _buildChip(
        context,
        text: '读取可信度…',
        color: Aurora.muted,
        background: Aurora.fill,
      ),
      error: (_, __) => _buildChip(
        context,
        text: '暂无可信数据',
        color: Aurora.muted,
        background: Aurora.fill,
      ),
      data: (summary) {
        if (summary == null) {
          return _buildChip(
            context,
            text: '暂无可信数据',
            color: Aurora.muted,
            background: Aurora.fill,
          );
        }
        if (!summary.meetsThreshold) {
          return _buildChip(
            context,
            text: summary.isStale ? '缓存 · 样本不足' : '样本不足',
            color: Aurora.muted,
            background: Aurora.fill,
            tooltip: _buildTooltip(summary),
          );
        }
        // 达到阈值：显示紧凑摘要
        final usable = summary.smoothedUsableRate ?? summary.userUsableRate;
        final usableText = usable == null
            ? null
            : '${(usable * 100).round()}% 可用';
        final liveText = usableText == null
            ? '${summary.publicSamples} 次社区实打'
            : '${summary.publicSamples} 次社区实打 · $usableText';
        final text = summary.isStale ? '缓存 · $liveText' : liveText;
        final color = summary.isStale
            ? Aurora.muted
            : summary.isHighTrust
            ? Aurora.primary
            : Aurora.warning;
        return Tooltip(
          message: _buildTooltip(summary),
          waitDuration: const Duration(milliseconds: 300),
          child: _buildChip(
            context,
            text: text,
            color: color,
            background: color.withValues(alpha: 0.12),
            icon: summary.isHighTrust ? 'confirm' : 'warning',
          ),
        );
      },
    );
  }

  Widget _buildChip(
    BuildContext context, {
    required String text,
    required Color color,
    required Color background,
    String? icon,
    String? tooltip,
  }) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(Aurora.radius),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            BambuIcon(
              name: icon,
              size: 11,
              color: color,
              applyColorFilter: true,
            ),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
    if (tooltip != null) {
      return Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 300),
        child: chip,
      );
    }
    return chip;
  }

  String _buildTooltip(CommunityTrustSummary summary) {
    final parts = <String>['社区实打：${summary.publicSamples} 条'];
    parts.add('独立用户：${summary.uniqueUserCount}');
    if (summary.userUsableRate != null) {
      parts.add('用户可用率：${(summary.userUsableRate! * 100).round()}%');
    }
    if (summary.deviceCompletionRate != null) {
      parts.add('设备完成率：${(summary.deviceCompletionRate! * 100).round()}%');
    }
    if (summary.ratingAverage != null && summary.ratingCount > 0) {
      parts.add(
        '评分：${summary.ratingAverage!.toStringAsFixed(1)} '
        '(${summary.ratingCount} 人)',
      );
    }
    parts.add('作者自测：${summary.authorSelfTestCount}');
    parts.add('机型覆盖：${summary.printerModelCoverage}');
    if (summary.lastRecordedAt != null) {
      parts.add('最近记录：${_formatDate(summary.lastRecordedAt!)}');
    }
    if (summary.isStale) {
      parts.add(
        summary.cachedAt == null
            ? '当前离线，显示上次缓存'
            : '当前离线，缓存于 ${_formatDate(summary.cachedAt!)}',
      );
    }
    if (summary.meetsThreshold && summary.isHighTrust) {
      parts.add('等级：高可信');
    } else if (summary.meetsThreshold) {
      parts.add('等级：可信');
    } else {
      parts.add('等级：样本不足');
    }
    return parts.join('\n');
  }

  String _formatDate(DateTime t) {
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '$m-$d';
  }
}

class _AuthorReputationBadge extends ConsumerWidget {
  final String handle;

  const _AuthorReputationBadge({required this.handle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reputation = ref.watch(authorReputationProvider(handle));
    return reputation.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (value) {
        if (value == null) return const SizedBox.shrink();
        final established = value.meetsThreshold && value.score != null;
        final color = established ? Aurora.blue : Aurora.muted;
        final label = established
            ? '${value.badgeLabel ?? '作者信誉'} ${value.score!.round()}'
            : '作者信誉样本不足';
        final details = established
            ? [
                '非作者样本：${value.nonAuthorSamples}',
                '参数覆盖：${value.uniquePresetCoverage}',
                '用户覆盖：${value.uniqueUsers}',
                if (value.completionPerformance != null)
                  '设备完成表现：${(value.completionPerformance! * 100).round()}%',
                if (value.usableRate != null)
                  '成品可用表现：${(value.usableRate! * 100).round()}%',
                if (value.ratingAverage != null)
                  '评分：${value.ratingAverage!.toStringAsFixed(1)} / 5',
                if (value.diversityPerformance != null)
                  '样本多样性：${(value.diversityPerformance! * 100).round()}%',
                if (value.recencyPerformance != null)
                  '近期性：${(value.recencyPerformance! * 100).round()}%',
              ].join('\n')
            : '至少需要 5 条非作者有效记录，并覆盖 2 个公开参数。';
        return Tooltip(
          message: details,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(Aurora.radius),
              border: Border.all(color: color.withValues(alpha: 0.25)),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 详情对话框中的可信汇总详细区。
///
/// 任务书 10.3/10.6 要求：详细分布放在"更多信息"弹窗中，使用现有统一弹窗
/// 和打印机图片组件。本组件展示完整指标，包括：
/// - 参数可用率及样本数
/// - 设备技术完成/失败/取消分布
/// - 评分均值及评分人数
/// - 独立用户数 / 打印机型号覆盖数 / 最近记录时间 / 作者自测数
class _TrustDetailSection extends ConsumerWidget {
  final String publicationId;

  const _TrustDetailSection({required this.publicationId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSummary = ref.watch(trustSummaryProvider(publicationId));
    return asyncSummary.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, __) => _buildEmpty(context, '暂无可信数据'),
      data: (summary) {
        if (summary == null) return _buildEmpty(context, '暂无可信数据');
        if (!summary.meetsThreshold) {
          return _buildInfoCard(
            context,
            title: '社区实打记录',
            badge: '样本不足',
            badgeColor: Aurora.muted,
            rows: [
              ('公共样本数', '${summary.publicSamples}'),
              ('独立用户数', '${summary.uniqueUserCount}'),
              ('作者自测', '${summary.authorSelfTestCount}'),
              if (summary.lastRecordedAt != null)
                ('最近记录', _formatDateTime(summary.lastRecordedAt!)),
            ],
            note:
                '有效社区样本少于 3 条或非作者账号少于 2 个，'
                '暂不展示可用率与评分。可稍后再来查看。',
          );
        }
        final rows = <(String, String)>[
          ('公共样本数', '${summary.publicSamples}'),
          ('成品评价样本', '${summary.outcomeSampleCount}'),
          ('独立用户数', '${summary.uniqueUserCount}'),
          ('作者自测', '${summary.authorSelfTestCount}'),
          ('机型覆盖', '${summary.printerModelCoverage}'),
          if (summary.userUsableRate != null)
            (
              '用户可用率',
              '${(summary.userUsableRate! * 100).round()}% '
                  '(${summary.publicSamples} 条)',
            ),
          if (summary.deviceCompletionRate != null)
            ('设备完成率', '${(summary.deviceCompletionRate! * 100).round()}%'),
          (
            '设备记录分布',
            '完成 ${summary.deviceFinishedCount} / '
                '失败 ${summary.deviceFailedCount} / '
                '取消 ${summary.deviceCancelledCount}',
          ),
          (
            '成品结果分布',
            '成功 ${summary.userSuccessCount} / '
                '可用 ${summary.userUsableCount} / '
                '品质失败 ${summary.userQualityFailedCount}',
          ),
          if (summary.smoothedUsableRate != null)
            (
              '平滑可用率',
              '${(summary.smoothedUsableRate! * 100).round()}% '
                  '(Wilson 下界 ${(summary.wilsonLowerBound * 100).round()}%)',
            ),
          if (summary.ratingAverage != null && summary.ratingCount > 0)
            (
              '用户评分',
              '${summary.ratingAverage!.toStringAsFixed(1)} / 5 '
                  '(${summary.ratingCount} 人)',
            ),
          if (summary.lastRecordedAt != null)
            ('最近记录', _formatDateTime(summary.lastRecordedAt!)),
        ];
        return _buildInfoCard(
          context,
          title: '社区实打记录',
          badge: summary.isHighTrust ? '高可信' : '可信',
          badgeColor: summary.isHighTrust ? Aurora.primary : Aurora.warning,
          rows: rows,
          note:
              '${summary.isStale ? '当前为离线缓存，不是实时数据。' : ''}'
              '设备故障、网络中断和用户取消单列，不会直接归罪于参数。'
              '徽章文案为"社区实打记录"，不代表官方认证或保证成功。',
        );
      },
    );
  }

  Widget _buildEmpty(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          BambuIcon(
            name: 'info',
            size: 14,
            color: Aurora.muted,
            applyColorFilter: true,
          ),
          const SizedBox(width: 6),
          Text(text, style: Aurora.label(context)),
        ],
      ),
    );
  }

  Widget _buildInfoCard(
    BuildContext context, {
    required String title,
    required String badge,
    required Color badgeColor,
    required List<(String, String)> rows,
    String? note,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Aurora.fill,
        borderRadius: BorderRadius.circular(Aurora.radius),
        border: Border.all(color: Aurora.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: Aurora.title(context).copyWith(fontSize: 13)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: badgeColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(row.$1, style: Aurora.label(context)),
                  ),
                  Expanded(
                    child: Text(
                      row.$2,
                      textAlign: TextAlign.right,
                      style: Aurora.mono.copyWith(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          if (note != null) ...[
            const SizedBox(height: 8),
            Text(
              note,
              style: Aurora.label(context).copyWith(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: Aurora.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDateTime(DateTime t) {
    final y = t.year;
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}

/// 举报参数对话框。
///
/// 任务书 10.5/10.6 要求：
/// - 举报原因至少包含：危险参数、说明不实、侵权/冒用、垃圾内容、其他。
/// - 每个用户对同一参数同一活动举报只能有一条。
/// - 提交时禁用按钮防止重复；成功后反馈。
/// - 普通客户端只能看到公开状态，不得访问举报人信息。
class _ReportPresetDialog extends ConsumerStatefulWidget {
  final CommunityPreset publication;

  const _ReportPresetDialog({required this.publication});

  @override
  ConsumerState<_ReportPresetDialog> createState() =>
      _ReportPresetDialogState();
}

class _ReportPresetDialogState extends ConsumerState<_ReportPresetDialog> {
  static const _reasons = <(String, String)>[
    ('dangerous_params', '危险参数（温度/喷嘴/构建板不安全）'),
    ('misleading_description', '说明不实（与实际表现不符）'),
    ('infringement_or_impersonation', '侵权或冒用'),
    ('spam', '垃圾内容'),
    ('other', '其他'),
  ];

  String _reason = _reasons.first.$1;
  final TextEditingController _noteController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final note = _noteController.text.trim().isEmpty
        ? null
        : _noteController.text.trim();
    final result = await submitPresetReport(
      ref,
      publicationId: widget.publication.publicationId,
      reason: _reason,
      note: note,
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (result.success) {
      Navigator.of(context).pop();
      showSnack(context, '举报已提交，等待审核处理');
    } else {
      showSnack(context, result.errorMessage ?? '举报提交失败', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          BambuIcon(
            name: 'warning',
            size: 18,
            color: Aurora.danger,
            applyColorFilter: true,
          ),
          SizedBox(width: 6),
          Text('举报参数'),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '参数：${widget.publication.preset.name}',
                style: Aurora.title(context).copyWith(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                '作者：${widget.publication.owner.displayName}',
                style: Aurora.label(context),
              ),
              const SizedBox(height: 12),
              Text('举报原因 *', style: Aurora.label(context)),
              const SizedBox(height: 6),
              RadioGroup<String>(
                groupValue: _reason,
                onChanged: (value) {
                  if (value != null) setState(() => _reason = value);
                },
                child: Column(
                  children: [
                    for (final entry in _reasons)
                      RadioListTile<String>(
                        value: entry.$1,
                        title: Text(
                          entry.$2,
                          style: const TextStyle(fontSize: 12),
                        ),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text('补充说明（可选）', style: Aurora.label(context)),
              const SizedBox(height: 4),
              TextField(
                controller: _noteController,
                maxLines: 3,
                maxLength: 300,
                decoration: InputDecoration(
                  hintText: '简要说明问题，最多 300 字',
                  hintStyle: TextStyle(fontSize: 11, color: Aurora.muted),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Aurora.radius),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Aurora.fill,
                  borderRadius: BorderRadius.circular(Aurora.radius),
                  border: Border.all(color: Aurora.line),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BambuIcon(
                      name: 'info',
                      size: 12,
                      color: Aurora.muted,
                      applyColorFilter: true,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '同一参数同一活动举报只能有一条。'
                        '仅凭举报数量不会自动删除内容，恶意围攻不会得逞。',
                        style: TextStyle(
                          fontSize: 10,
                          color: Aurora.muted,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: glassButtonStyle(
            context,
            FilledButton.styleFrom(backgroundColor: Aurora.danger),
            variant: AppGlassButtonVariant.primary,
          ),
          child: _submitting
              ? Builder(
                  builder: (context) => SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: GlassButtonsTheme.enabledOf(context)
                          ? IconTheme.of(context).color
                          : Colors.white,
                    ),
                  ),
                )
              : const Text('提交举报'),
        ),
      ],
    );
  }
}
