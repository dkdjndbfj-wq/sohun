import 'dart:async';
import 'package:uuid/uuid.dart';

import 'package:flutter/material.dart';
import '../core/constants/personal_spool_policy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/glass_button_theme.dart';
import '../core/theme/interaction_effects.dart';
import '../core/utils/color_utils.dart';
import '../core/utils/friendly_error.dart';
import '../data/database/database.dart';
import '../data/models/rfid_tag_identity.dart';
import '../data/external/slicer/material_catalog_service.dart';
import '../features/color_picker/color_picker_panel.dart';
import '../providers/consumable_provider.dart';
import '../providers/database_provider.dart';
import '../widgets/rfid_spool_history.dart';
import '../widgets/rfid_spool_rebind_dialog.dart';
import '../widgets/filament_spool_icon.dart';
import '../widgets/glass_card.dart';
import '../widgets/stock_bar.dart';
import 'mobile_rfid_models.dart';
import 'mobile_inventory_repository.dart';
import 'mobile_inventory_groups.dart';
import 'mobile_glass_choice_chip.dart';
import 'mobile_visual_theme.dart';
import 'mobile_inventory_sync.dart';
import 'mobile_rfid_tag_repository.dart';
import 'rfid_native_bridge.dart';

/// A small bridge that can be supplied by an Android host once it exposes a
/// raw CUID/FUID UID scan. Keeping this capability optional lets the inventory
/// screen remain useful on desktop/widget-test hosts without pretending that a
/// normal NTAG213 record is an AMS tag.
class MobileInventoryTagScan {
  const MobileInventoryTagScan({this.draft, this.tagId, this.tagType});

  /// A blank CUID/FUID only exposes its UID. A non-null draft is supported
  /// for future app-owned records, but the batch flow never requires it.
  final MobileConsumableDraft? draft;
  final String? tagId;
  final String? tagType;
}

typedef MobileInventoryTagScanner = Future<MobileInventoryTagScan?> Function();

/// Personal inventory surface for the Android extension.
///
/// The data stream is the same personal `consumables` stream used by the
/// desktop inventory. This screen only changes presentation and entry points;
/// writes still pass through [MobileInventorySync], so account ownership and
/// the sohun snapshot remain on the existing chain.
class MobileInventoryPage extends ConsumerStatefulWidget {
  const MobileInventoryPage({
    super.key,
    required this.sync,
    this.loadMaterials,
    this.accountLabel,
    this.accountIdentity,
    this.ownerAccount,
    this.onAccountTap,
    this.onOpenWriter,
    this.onScanCuidFuid,
    this.onCancelTagScan,
    this.onRefreshInventory,
    this.tagRepository,
  });

  final MobileInventorySync sync;
  final Future<List<String>> Function()? loadMaterials;
  final String? accountLabel;
  final String? accountIdentity;
  final String? ownerAccount;
  final void Function(BuildContext context)? onAccountTap;
  final VoidCallback? onOpenWriter;
  final MobileInventoryTagScanner? onScanCuidFuid;
  final Future<void> Function()? onCancelTagScan;

  /// Optional account-aware pull invoked by pull-to-refresh.  Local-only
  /// embedders can omit it; the page still invalidates its local stream.
  final Future<void> Function()? onRefreshInventory;
  final MobileRfidTagRepository? tagRepository;

  @override
  ConsumerState<MobileInventoryPage> createState() =>
      _MobileInventoryPageState();
}

class _MobileInventoryPageState extends ConsumerState<MobileInventoryPage> {
  final _searchController = TextEditingController();
  final _replacementWeightController = TextEditingController(text: '1000');
  String _query = '';
  _InventoryFilter _filter = _InventoryFilter.all;
  _InventorySort _sort = _InventorySort.recent;
  bool _groupByBrand = true;
  final _collapsedBrands = <String>{};
  final _expandedCategories = <(String, String, String)>{};
  String? _brandFilter;
  String? _materialFilter;
  List<Consumable>? _bindingItems;
  Future<_MobileInventoryRfidMetadata>? _rfidMetadataFuture;
  List<String> _materials = const [];
  bool _materialsLoading = true;
  bool _batchSaving = false;
  bool _replacing = false;
  bool _refreshing = false;
  bool _refreshed = false;
  String? _refreshError;
  int _accountGeneration = 0;
  int _catalogGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadMaterials();
  }

  @override
  void didUpdateWidget(covariant MobileInventoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountIdentity != widget.accountIdentity ||
        oldWidget.ownerAccount != widget.ownerAccount) {
      _accountGeneration += 1;
      _replacing = false;
      _refreshing = false;
      _refreshed = false;
      _refreshError = null;
      _searchController.clear();
      _query = '';
      _filter = _InventoryFilter.all;
      _brandFilter = null;
      _materialFilter = null;
      _bindingItems = null;
      _rfidMetadataFuture = null;
      _collapsedBrands.clear();
      _expandedCategories.clear();
    }
    if (oldWidget.accountIdentity != widget.accountIdentity ||
        oldWidget.loadMaterials != widget.loadMaterials) {
      _loadMaterials();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _replacementWeightController.dispose();
    super.dispose();
  }

  Future<void> _loadMaterials() async {
    final generation = ++_catalogGeneration;
    setState(() => _materialsLoading = true);
    try {
      final values =
          await (widget.loadMaterials ?? MaterialCatalogService.load)();
      if (!mounted || generation != _catalogGeneration) return;
      setState(() {
        _materials = values;
        _materialsLoading = false;
      });
    } catch (_) {
      if (!mounted || generation != _catalogGeneration) return;
      setState(() {
        _materials = MaterialCatalogService.fallbackMaterials;
        _materialsLoading = false;
      });
    }
  }

  List<Consumable> _visibleItems(
    List<Consumable> items, {
    Map<int, RfidSpoolBinding> bindings = const {},
    Map<int, PersonalRfidStockSource> sources = const {},
  }) {
    final query = _query.trim().toLowerCase();
    final filtered = items.where((item) {
      if (_brandFilter != null && item.manufacturer != _brandFilter) {
        return false;
      }
      if (_materialFilter != null && item.materialType != _materialFilter) {
        return false;
      }
      final binding = bindings[item.id];
      final hasRfidTag =
          binding?.tagUid.trim().isNotEmpty == true ||
          sources[item.id]?.tagUid?.trim().isNotEmpty == true ||
          item.trayUuid?.trim().isNotEmpty == true;
      if (_filter == _InventoryFilter.tagged && !hasRfidTag) {
        return false;
      }
      if (_filter == _InventoryFilter.low && _stockRatio(item) > 0.2) {
        return false;
      }
      if (query.isEmpty) return true;
      final haystack = [
        item.manufacturer,
        item.model,
        item.materialType,
        item.colorName ?? '',
        item.colorHex,
        item.trayUuid ?? '',
        binding?.tagUid ?? '',
        sources[item.id]?.tagUid ?? '',
      ].join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList();
    filtered.sort((a, b) {
      final comparison = switch (_sort) {
        _InventorySort.recent => b.updatedAt.compareTo(a.updatedAt),
        _InventorySort.weightAsc => a.remainingGrams.compareTo(
          b.remainingGrams,
        ),
        _InventorySort.weightDesc => b.remainingGrams.compareTo(
          a.remainingGrams,
        ),
        _InventorySort.brand => a.manufacturer.compareTo(b.manufacturer),
      };
      return comparison != 0 ? comparison : b.id.compareTo(a.id);
    });
    return filtered;
  }

  Future<_MobileInventoryRfidMetadata> _loadRfidMetadata(
    List<Consumable> items,
  ) async {
    final dao = ref.read(consumableDaoProvider);
    final ids = items.map((item) => item.id).toList(growable: false);
    final bindingsFuture = dao.getRfidSpoolBindingsMap(ids);
    final sourcesFuture = dao.getPersonalRfidStockSourcesMap(ids);
    return _MobileInventoryRfidMetadata(
      bindings: await bindingsFuture,
      sources: await sourcesFuture,
    );
  }

  double _stockRatio(Consumable item) {
    if (item.totalGrams <= 0) return 0;
    return (item.remainingGrams / item.totalGrams).clamp(0.0, 1.0);
  }

  Future<void> _openBatchAdd() async {
    if (_batchSaving) return;
    final batchGeneration = _accountGeneration;
    final batchSync = widget.sync;
    final result = await showMobileGlassBottomSheet<_MobileBatchDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => _MobileBatchAddSheet(
        materials: _materials,
        materialsLoading: _materialsLoading,
        onScanCuidFuid: widget.onScanCuidFuid,
        onCancelTagScan: widget.onCancelTagScan,
        ownerAccount: widget.ownerAccount,
        tagRepository: widget.tagRepository,
      ),
    );
    if (result == null || !mounted) return;
    if (batchGeneration != _accountGeneration) {
      _showMessage('登录账号已切换，本次批量入库已取消', error: true);
      return;
    }

    setState(() => _batchSaving = true);
    var saved = 0;
    var syncPending = false;
    try {
      final sourceTag = MobileInventoryRepository.normalizeTagUid(
        result.tagId ?? result.tagIds.firstOrNull,
      );
      if (sourceTag != null) {
        if (batchSync is! MobileInventoryStockSync)
          throw StateError('当前库存服务尚未支持资料卡新增，请更新客户端');
        final sourceType = result.tagTypes[sourceTag];
        if (!isConsumableRfidTagType(sourceType))
          throw StateError('请先确认资料卡为 CUID/FUID');
        final received = await (batchSync as MobileInventoryStockSync)
            .receiveFromCard(
              result.draft,
              operationUid: result.operationUid,
              tagUid: sourceTag,
              tagType: sourceType!,
              quantity: result.count,
              initialGrams: result.initialGrams,
            );
        saved = received.receipt.inventoryUids.length;
        if (!mounted) return;
        if (batchGeneration != _accountGeneration) {
          throw const MobileInventoryAccountChangedException();
        }
        if (received.syncPending)
          setState(() {
            _refreshed = false;
            _refreshError = '新增库存已保存到本机，联网后可继续同步。';
          });
        _showMessage(
          '${received.receipt.replayed ? '此入库批次已处理，未重复增加' : '已用资料卡新增 $saved 卷（每卷规格 1 kg，单卷余量 ${result.initialGrams} g）'}'
          '${received.syncPending ? '；云端待同步' : ''}',
        );
        return;
      }
      final List<MobileInventorySaveResult> received;
      if (batchSync is MobileInventoryBatchSync) {
        received = await (batchSync as MobileInventoryBatchSync)
            .saveManualBatch(
              result.draft,
              operationUid: result.operationUid,
              quantity: result.count,
              initialGrams: result.initialGrams,
            );
      } else {
        if (result.count != 1) {
          throw StateError('当前库存服务尚未支持原子批量入库，请更新客户端');
        }
        received = [
          await batchSync.save(result.draft, initialGrams: result.initialGrams),
        ];
      }
      saved = received.length;
      if (!mounted || batchGeneration != _accountGeneration) return;
      syncPending = received.any((entry) => entry.syncPending);
      if (syncPending) {
        setState(() {
          _refreshed = false;
          _refreshError = '本机记录已保存，请联网后重试同步。';
        });
      }
      _showMessage(
        '已加入 $saved 卷耗材'
        '${syncPending ? '；已存本机，云端待同步' : ''}',
      );
    } catch (error) {
      if (mounted) {
        final suffix = saved == 0 ? '' : '（已保存 $saved/${result.count} 卷）';
        _showMessage('批量入库中断$suffix：$error', error: true);
      }
    } finally {
      if (mounted) setState(() => _batchSaving = false);
    }
  }

  void _showMessage(String message, {bool error = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? AppColors.danger : AppColors.textPrimary,
        ),
      );
  }

  Future<void> _refreshInventory() async {
    if (_refreshing) return;
    final generation = _accountGeneration;
    final owner = widget.ownerAccount;
    Object? remoteError;
    Object? localError;
    setState(() => _refreshing = true);
    try {
      try {
        await widget.onRefreshInventory?.call();
      } catch (error) {
        remoteError = error;
      }
      if (!mounted || generation != _accountGeneration) return;
      try {
        if (owner != null) {
          ref.invalidate(personalConsumablesByOwnerProvider(owner));
          await ref.read(personalConsumablesByOwnerProvider(owner).future);
        } else {
          ref.invalidate(consumablesProvider);
          await ref.read(consumablesProvider.future);
        }
      } catch (error) {
        localError = error;
      }
      if (!mounted || generation != _accountGeneration) return;
      setState(() {
        _refreshed = remoteError == null && localError == null;
        _refreshError = remoteError != null
            ? friendlyError(remoteError)
            : localError != null
            ? friendlyError(localError)
            : null;
      });
      if (localError != null) {
        _showMessage('本机库存刷新失败，请重试：${friendlyError(localError)}', error: true);
      } else if (remoteError != null) {
        _showMessage('云端未同步，仍可使用本机库存', error: true);
      }
    } finally {
      if (mounted && generation == _accountGeneration) {
        setState(() => _refreshing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final owner = widget.ownerAccount;
    // The host passes an empty owner while signed out so the provider exposes
    // only unclaimed local rows; a non-empty owner is always account-scoped.
    final async = owner != null
        ? ref.watch(personalConsumablesByOwnerProvider(owner))
        : ref.watch(consumablesProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return MobileScaffold(
      appBar: AppBar(
        flexibleSpace: const MobileGlassBar(),
        title: const Text('耗材库存'),
        actions: [
          if (widget.onOpenWriter != null)
            IconButton(
              onPressed: widget.onOpenWriter,
              tooltip: '写入耗材标签',
              icon: const Icon(Icons.nfc_rounded),
            ),
          if (widget.tagRepository != null)
            IconButton(
              onPressed: _showTagHistory,
              tooltip: '标签记录',
              icon: const Icon(Icons.history_rounded),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Tooltip(
              message: '批量加库存',
              child: FilledButton.icon(
                key: const ValueKey('mobile-add-inventory'),
                onPressed: _batchSaving ? null : _openBatchAdd,
                style: glassButtonStyle(
                  context,
                  FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 44),
                  ),
                ),
                icon: _batchSaving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_rounded, size: 19),
                label: Text(_batchSaving ? '入库中' : '入库'),
              ),
            ),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_rounded, size: 42, color: textSecondary),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '库存加载失败',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  friendlyError(error),
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: textSecondary),
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton.icon(
                  onPressed: _refreshing ? null : _refreshInventory,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试加载库存'),
                ),
              ],
            ),
          ),
        ),
        data: (items) {
          // Filtering/sorting must not re-query every RFID binding on each
          // keystroke. The inventory stream supplies a new list on mutation.
          if (!identical(_bindingItems, items)) {
            _bindingItems = items;
            _rfidMetadataFuture = _loadRfidMetadata(items);
          }
          return FutureBuilder<_MobileInventoryRfidMetadata>(
            future: _rfidMetadataFuture,
            builder: (context, snapshot) => _buildInventory(
              context,
              items,
              bindings: snapshot.data?.bindings ?? const {},
              sources: snapshot.data?.sources ?? const {},
            ),
          );
        },
      ),
    );
  }

  Widget _buildInventory(
    BuildContext context,
    List<Consumable> items, {
    Map<int, RfidSpoolBinding> bindings = const {},
    Map<int, PersonalRfidStockSource> sources = const {},
  }) {
    final visible = _visibleItems(items, bindings: bindings, sources: sources);
    final totalGrams = items.fold<double>(
      0,
      (sum, item) => sum + item.remainingGrams.clamp(0, double.infinity),
    );
    final lowCount = items.where((item) => _stockRatio(item) <= 0.2).length;
    final taggedCount = items.where((item) {
      return bindings[item.id]?.tagUid.trim().isNotEmpty == true ||
          sources[item.id]?.tagUid?.trim().isNotEmpty == true ||
          item.trayUuid?.trim().isNotEmpty == true;
    }).length;
    final scheme = Theme.of(context).colorScheme;
    final hasFacets = _brandFilter != null || _materialFilter != null;
    final grouped = _groupByBrand && _query.trim().isEmpty;
    final entries = _inventoryEntries(
      visible,
      bindings,
      sources: sources,
      grouped: grouped,
    );

    return Column(
      children: [
        // Search and filters stay reachable even after scrolling hundreds
        // of rolls; summary and status scroll away with the inventory.
        MobileGlassSurface(
          radius: 18,
          opacity: 0.48,
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 0),
            child: Column(
              children: [
                TextField(
                  key: const ValueKey('mobile-inventory-search'),
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  style: Theme.of(context).textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: '搜索耗材、颜色、标签 UID',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
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
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _InventoryFilterChip(
                              label: '全部 ${items.length}',
                              selected: _filter == _InventoryFilter.all,
                              onSelected: () => setState(
                                () => _filter = _InventoryFilter.all,
                              ),
                            ),
                            _InventoryFilterChip(
                              label: '低余量 $lowCount',
                              selected: _filter == _InventoryFilter.low,
                              onSelected: () => setState(
                                () => _filter = _InventoryFilter.low,
                              ),
                            ),
                            _InventoryFilterChip(
                              label: '有 RFID 来源 $taggedCount',
                              selected: _filter == _InventoryFilter.tagged,
                              onSelected: () => setState(
                                () => _filter = _InventoryFilter.tagged,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '筛选品牌和材质',
                      onPressed: () => _showFilters(items),
                      icon: Badge(
                        isLabelVisible: hasFacets,
                        smallSize: 6,
                        child: Icon(
                          Icons.tune_rounded,
                          color: hasFacets
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                    ),
                    PopupMenuButton<_InventorySort>(
                      tooltip: '库存排序',
                      initialValue: _sort,
                      onSelected: (value) => setState(() => _sort = value),
                      icon: const Icon(Icons.sort_rounded, size: 21),
                      itemBuilder: (_) => [
                        for (final value in _InventorySort.values)
                          CheckedPopupMenuItem(
                            value: value,
                            checked: _sort == value,
                            child: Text(value.label),
                          ),
                      ],
                    ),
                  ],
                ),
                if (hasFacets || _query.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            [
                              if (_brandFilter != null) _brandFilter!,
                              if (_materialFilter != null) _materialFilter!,
                              '找到 ${visible.length} 卷',
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: _clearFilters,
                          child: const Text('重置'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshInventory,
            child: CustomScrollView(
              key: const PageStorageKey('mobile-inventory-list'),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: _InventoryOverview(
                          rolls: items.length,
                          totalGrams: totalGrams,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: TextButton.icon(
                          onPressed: _query.trim().isNotEmpty
                              ? null
                              : () => setState(
                                  () => _groupByBrand = !_groupByBrand,
                                ),
                          icon: Icon(
                            grouped
                                ? Icons.account_tree_outlined
                                : Icons.view_list_outlined,
                            size: 16,
                          ),
                          label: Text(
                            _query.trim().isNotEmpty
                                ? '搜索结果'
                                : grouped
                                ? '品牌分类'
                                : '逐卷列表',
                          ),
                          style: glassButtonStyle(
                            context,
                            TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                            variant: AppGlassButtonVariant.quiet,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_refreshing || _refreshed || _refreshError != null)
                  SliverToBoxAdapter(
                    child: _MobileSyncStatusCard(
                      accountLabel: widget.accountLabel,
                      cloudAvailable:
                          widget.onRefreshInventory != null &&
                          (widget.accountIdentity != null ||
                              widget.accountLabel?.trim().isNotEmpty == true),
                      refreshing: _refreshing,
                      refreshed: _refreshed,
                      error: _refreshError,
                      onRetry: _refreshInventory,
                    ),
                  ),
                if (visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _InventoryEmptyState(
                      hasItems: items.isNotEmpty,
                      secondary: scheme.onSurfaceVariant,
                      onAdd: items.isNotEmpty ? _clearFilters : _openBatchAdd,
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.only(bottom: 16),
                    sliver: SliverList.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) => entries[index](context),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<WidgetBuilder> _inventoryEntries(
    List<Consumable> visible,
    Map<int, RfidSpoolBinding> bindings, {
    Map<int, PersonalRfidStockSource> sources = const {},
    required bool grouped,
  }) {
    Widget row(Consumable item) => _MobileInventoryCard(
      key: ValueKey('mobile-inventory-row-${item.id}'),
      item: item,
      binding: bindings[item.id],
      source: sources[item.id],
      onTap: () => _showItemDetails(item),
    );
    if (!grouped) return [for (final item in visible) (_) => row(item)];
    final entries = <WidgetBuilder>[];
    final brands = groupMobileInventory(visible);
    for (final entry in brands.entries) {
      final brand = entry.key;
      final expanded = !_collapsedBrands.contains(brand.toLowerCase());
      entries.add(
        (_) => MobileInventoryBrandHeader(
          key: ValueKey('mobile-brand-$brand'),
          brand: brand,
          count: entry.value.fold(
            0,
            (sum, category) => sum + category.items.length,
          ),
          expanded: expanded,
          onTap: () => setState(() {
            final key = brand.toLowerCase();
            if (!_collapsedBrands.add(key)) _collapsedBrands.remove(key);
          }),
        ),
      );
      if (!expanded) continue;
      for (final category in entry.value) {
        final open = _expandedCategories.contains(category.id);
        entries.add(
          (_) => MobileInventoryCategoryRow(
            key: ValueKey(category.id),
            category: category,
            expanded: open,
            onTap: () {
              if (category.items.length == 1) {
                _showItemDetails(category.items.single);
              } else {
                setState(() {
                  if (!_expandedCategories.add(category.id)) {
                    _expandedCategories.remove(category.id);
                  }
                });
              }
            },
          ),
        );
        if (open) {
          for (final item in category.items) {
            entries.add((_) => row(item));
          }
        }
      }
    }
    return entries;
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _filter = _InventoryFilter.all;
      _brandFilter = null;
      _materialFilter = null;
    });
  }

  Future<void> _showFilters(List<Consumable> items) async {
    final brands = items.map((item) => item.manufacturer).toSet().toList()
      ..sort();
    final materials = items.map((item) => item.materialType).toSet().toList()
      ..sort();
    var brand = brands.contains(_brandFilter) ? _brandFilter : null;
    var material = materials.contains(_materialFilter) ? _materialFilter : null;
    final generation = _accountGeneration;
    final apply = await showMobileGlassBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('筛选库存', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                initialValue: brand ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '品牌'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部品牌')),
                  for (final value in brands.where((value) => value.isNotEmpty))
                    DropdownMenuItem(
                      value: value,
                      child: Text(value, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) =>
                    update(() => brand = value == '' ? null : value),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: material ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '材质'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部材质')),
                  for (final value in materials.where(
                    (value) => value.isNotEmpty,
                  ))
                    DropdownMenuItem(
                      value: value,
                      child: Text(value, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) =>
                    update(() => material = value == '' ? null : value),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('应用筛选'),
              ),
            ],
          ),
        ),
      ),
    );
    if (apply == true && mounted && generation == _accountGeneration) {
      setState(() {
        _brandFilter = brand;
        _materialFilter = material;
      });
    }
  }

  Future<void> _showItemDetails(Consumable item) async {
    final detailsGeneration = _accountGeneration;
    final detailsOwner = widget.ownerAccount;
    final color = ColorUtils.fromHex(item.colorHex);
    final binding = await ref
        .read(consumableDaoProvider)
        .getRfidSpoolBindingById(item.id);
    final tag = binding?.tagUid.trim();
    final source = (await ref
        .read(consumableDaoProvider)
        .getPersonalRfidStockSourcesMap([item.id]))[item.id];
    final history = tag?.isNotEmpty == true
        ? await ref
              .read(consumableDaoProvider)
              .getPersonalRfidSpoolHistory(tag!, ownerAccount: detailsOwner)
        : source != null && binding != null
        ? [binding]
        : const <RfidSpoolBinding>[];
    if (!mounted || detailsGeneration != _accountGeneration) return;
    await showMobileGlassBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                FilamentSpoolIcon(color: color, size: 34),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${item.manufacturer} · ${item.model}',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _DetailLine(label: '颜色', value: item.colorName ?? item.colorHex),
            _DetailLine(
              label: '余量',
              value:
                  '${item.remainingGrams.toStringAsFixed(0)} g / ${item.totalGrams.toStringAsFixed(0)} g',
            ),
            _DetailLine(
              label: '当前卷标签',
              value: tag?.isNotEmpty == true ? tag! : '未绑定 RFID',
            ),
            if (source?.tagUid?.trim().isNotEmpty == true)
              _DetailLine(
                label: '入库资料卡',
                value: '${source!.tagUid} · ${source.tagType} · 可重复用于加库存',
              ),
            if (binding != null) ...[
              if (tag?.isNotEmpty == true)
                _DetailLine(
                  label: '复用周期',
                  value:
                      '第 ${binding.cycle} 卷 · ${_lifecycleLabel(binding.status)}',
                ),
              if (history.length > 1)
                _DetailLine(
                  label: '标签链路',
                  value: '已记录 ${history.length} 卷，可追溯每次消耗',
                ),
              if (history.isNotEmpty &&
                  (source != null || isConsumableRfidTagType(binding.tagType)))
                TextButton.icon(
                  onPressed: () async {
                    Navigator.of(sheetContext).pop();
                    await showMobileGlassBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      showDragHandle: true,
                      builder: (_) => SizedBox(
                        height: MediaQuery.sizeOf(context).height * 0.75,
                        child: RfidSpoolHistoryList(
                          history: history,
                          currentUid: item.uid,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.history),
                  label: Text(
                    tag?.isNotEmpty == true ? '查看每卷的消耗与位置记录' : '查看本卷入库与消耗记录',
                  ),
                ),
            ],
            if (binding != null &&
                tag?.isNotEmpty == true &&
                !isConsumableRfidTagType(binding.tagType))
              const Text('历史标签仅供查看；耗材标签需要重新扫描并确认 CUID/FUID 卡型。'),
            if (source != null &&
                binding != null &&
                tag?.isNotEmpty == true &&
                isConsumableRfidTagType(binding.tagType)) ...[
              const SizedBox(height: 10),
              Text(
                '这张 CUID/FUID 是可重复资料卡。换卷时请在 AMS/打印机通道中选择已入库的具体库存卷；没有可用卷时，再读卡新增库存。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
            if (source == null &&
                binding != null &&
                isConsumableRfidTagType(binding.tagType) &&
                history.isNotEmpty &&
                history.first.inventoryUid == item.uid) ...[
              const SizedBox(height: 10),
              Text(
                '如果实体耗材已换新但旧卷仍有记录余量，请手动创建下一周期。旧卷会保留原 UID、余量和消耗记录。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _replacing
                    ? null
                    : () async {
                        Navigator.of(sheetContext).pop();
                        await _replaceRfidSpool(item, binding);
                      },
                icon: _replacing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.autorenew_rounded),
                label: const Text('旧版标签链路：换入新卷'),
              ),
            ],
            if (binding?.status == 'replaced' &&
                isConsumableRfidTagType(binding?.tagType) &&
                item.totalGrams == personalSpoolCapacityGrams &&
                canReusePersonalSpool(item.remainingGrams) &&
                widget.sync is MobileInventoryRebindSync)
              OutlinedButton.icon(
                icon: const Icon(Icons.link),
                label: const Text('旧余料换绑新标签'),
                onPressed: () async {
                  Navigator.of(sheetContext).pop();
                  final sync = widget.sync;
                  final identity = widget.accountIdentity;
                  final owner = widget.ownerAccount;
                  final saved = await showRfidSpoolRebindDialog(
                    context,
                    item: item,
                    scan: widget.onScanCuidFuid == null
                        ? null
                        : () async {
                            final scanned = await widget.onScanCuidFuid!();
                            if (scanned == null) return null;
                            if (!isConsumableRfidTagType(scanned.tagType) &&
                                !requiresConsumableRfidTagTypeConfirmation(
                                  scanned.tagType,
                                )) {
                              throw const MobileInventoryTagTypeException(
                                '新耗材标签只支持 CUID/FUID；不能使用 NTAG213 等标签',
                              );
                            }
                            return scanned.tagId;
                          },
                    save: (uid, type) async {
                      if (!mounted ||
                          !identical(sync, widget.sync) ||
                          identity != widget.accountIdentity ||
                          owner != widget.ownerAccount) {
                        throw const MobileInventoryAccountChangedException();
                      }
                      await (sync as MobileInventoryRebindSync).rebind(
                        consumableId: item.id,
                        expectedTagUid: binding!.tagUid,
                        newTagUid: uid,
                        newTagType: type,
                      );
                    },
                  );
                  if (saved && mounted) _showMessage('已换绑新标签，原有余量与消耗记录已保留');
                },
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => Navigator.pop(sheetContext),
              icon: const Icon(Icons.check_rounded),
              label: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _replaceRfidSpool(
    Consumable item,
    RfidSpoolBinding binding,
  ) async {
    if (_replacing) return;
    final replacementGeneration = _accountGeneration;
    final replacementSync = widget.sync;
    final replacementRepository = widget.tagRepository;
    final replacementOwner = widget.ownerAccount;
    _replacementWeightController.clear();
    var entryMode = _InventoryEntryMode.rolls;
    String? inputError;
    final initialGrams = await showDialog<double>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('换入新耗材卷'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('旧卷余量和历史会保留；标签进入下一使用周期。'),
                const SizedBox(height: 16),
                GlassSegmentedSurface(
                  child: SegmentedButton<_InventoryEntryMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: _InventoryEntryMode.rolls,
                        label: Text('按卷数入库'),
                      ),
                      ButtonSegment(
                        value: _InventoryEntryMode.remaining,
                        label: Text('按余量入库'),
                      ),
                    ],
                    selected: {entryMode},
                    onSelectionChanged: (value) => update(() {
                      entryMode = value.single;
                      inputError = null;
                    }),
                  ),
                ),
                const SizedBox(height: 16),
                if (entryMode == _InventoryEntryMode.rolls)
                  const Text('换入 1 卷 · 1000 g')
                else
                  TextField(
                    key: const ValueKey('replacement-remaining-grams'),
                    controller: _replacementWeightController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: '剩余克数',
                      suffixText: 'g',
                      errorText: inputError,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final value = entryMode == _InventoryEntryMode.rolls
                    ? personalSpoolCapacityGrams
                    : double.tryParse(_replacementWeightController.text.trim());
                if (value == null || !canReusePersonalSpool(value)) {
                  update(() => inputError = '请输入大于 30 且不超过 1000 g 的剩余克数');
                  return;
                }
                Navigator.of(dialogContext).pop(value);
              },
              child: const Text('创建新周期'),
            ),
          ],
        ),
      ),
    );
    if (!mounted ||
        initialGrams == null ||
        replacementGeneration != _accountGeneration)
      return;
    setState(() => _replacing = true);
    try {
      final draft = MobileConsumableDraft(
        brand: item.manufacturer,
        model: item.model,
        color: ColorUtils.fromHex(item.colorHex),
        colorName: item.colorName ?? '',
      );
      final saved = await replacementSync.save(
        draft,
        tagId: binding.tagUid,
        tagType: binding.tagType,
        forceNewCycle: true,
        initialGrams: initialGrams,
        expectedInventoryUid: item.uid,
      );
      if (!mounted || replacementGeneration != _accountGeneration) return;
      if (saved.createdNewCycle) {
        await replacementRepository?.recordBinding(
          tagUid: binding.tagUid,
          inventoryUid: saved.inventoryUid,
          ownerAccount: replacementOwner,
          tagType: binding.tagType,
          brand: draft.brand,
          model: draft.model,
          colorHex: draft.colorHex,
          colorName: draft.colorName,
          cycle: saved.rfidTagCycle,
          message: '手动换入新卷，上一卷已保留',
        );
      }
      if (!mounted || replacementGeneration != _accountGeneration) return;
      ref.invalidate(
        replacementOwner == null
            ? consumablesProvider
            : personalConsumablesByOwnerProvider(replacementOwner),
      );
      _showMessage(
        '已创建第 ${saved.rfidTagCycle} 卷；旧卷消耗记录已保留${saved.syncPending ? '；已存本机，云端待同步' : ''}',
      );
    } catch (error) {
      if (mounted && replacementGeneration == _accountGeneration) {
        _showMessage('换卷失败：$error', error: true);
      }
    } finally {
      if (mounted && replacementGeneration == _accountGeneration) {
        setState(() => _replacing = false);
      }
    }
  }

  String _lifecycleLabel(String status) {
    switch (status) {
      case 'depleted':
        return '已用完';
      case 'replaced':
        return '已换卷';
      case 'retired':
        return '已停用';
      default:
        return '使用中';
    }
  }

  Future<void> _showTagHistory() async {
    final repository = widget.tagRepository;
    if (repository == null) return;
    final owner = widget.ownerAccount ?? '';
    await showMobileGlassBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.42,
        maxChildSize: 0.92,
        builder: (_, controller) => FutureBuilder<List<RfidTagRecord>>(
          future: repository.list(ownerAccount: owner, limit: 100),
          builder: (context, snapshot) {
            final records = snapshot.data ?? const <RfidTagRecord>[];
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '标签记录',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '保存每次 CUID/FUID 操作；同一资料卡的新批次会单独保留，旧版其他标签记录仅供查看。',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const Expanded(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (snapshot.hasError)
                    const Expanded(child: Center(child: Text('标签记录暂时无法加载')))
                  else if (records.isEmpty)
                    const Expanded(child: Center(child: Text('还没有保存的标签记录')))
                  else
                    Expanded(
                      child: ListView.separated(
                        controller: controller,
                        itemCount: records.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: AppSpacing.xs),
                        itemBuilder: (_, index) => _TagHistoryTile(
                          record: records[index],
                          onCopy: () async {
                            await Clipboard.setData(
                              ClipboardData(text: records[index].tagUid),
                            );
                            if (sheetContext.mounted) {
                              ScaffoldMessenger.of(sheetContext).showSnackBar(
                                const SnackBar(content: Text('UID 已复制')),
                              );
                            }
                          },
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MobileInventoryRfidMetadata {
  const _MobileInventoryRfidMetadata({
    required this.bindings,
    required this.sources,
  });

  final Map<int, RfidSpoolBinding> bindings;
  final Map<int, PersonalRfidStockSource> sources;
}

enum _InventoryFilter { all, tagged, low }

class _MobileSyncStatusCard extends StatelessWidget {
  const _MobileSyncStatusCard({
    required this.accountLabel,
    required this.cloudAvailable,
    required this.refreshing,
    required this.refreshed,
    required this.error,
    required this.onRetry,
  });

  final String? accountLabel;
  final bool cloudAvailable;
  final bool refreshing;
  final bool refreshed;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final failed = error != null;
    final tint = failed
        ? AppColors.warning
        : refreshed
        ? AppColors.success
        : Theme.of(context).colorScheme.primary;
    final title = refreshing
        ? (cloudAvailable ? '正在同步个人库存…' : '正在刷新本机库存…')
        : failed
        ? (cloudAvailable ? '云端未同步 · 本机库存可用' : '刷新未完成，请重试')
        : refreshed
        ? (cloudAvailable ? '本次云端同步完成' : '本机库存已刷新')
        : cloudAvailable
        ? '个人账号已登录'
        : '本机库存模式';
    final subtitle = refreshing
        ? '正在获取最新记录，请稍候'
        : failed
        ? '本机数据不会丢失。联网后点击重试。'
        : cloudAvailable
        ? '${accountLabel?.trim() ?? '个人账号'} · 下拉刷新获取最新库存'
        : '登录 sohun 后，可与桌面端共享个人库存';

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      level: GlassLevel.l1,
      onTap: !refreshing && failed ? onRetry : null,
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: AppMotion.duration(
              context,
              const Duration(milliseconds: 220),
            ),
            child: refreshing
                ? SizedBox(
                    key: const ValueKey('syncing'),
                    width: 19,
                    height: 19,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: tint,
                    ),
                  )
                : Icon(
                    key: ValueKey('$cloudAvailable|$refreshed|$failed'),
                    failed
                        ? Icons.cloud_off_rounded
                        : cloudAvailable
                        ? (refreshed
                              ? Icons.cloud_done_rounded
                              : Icons.cloud_outlined)
                        : Icons.phone_android_rounded,
                    size: 19,
                    color: tint,
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AnimatedSwitcher(
              duration: AppMotion.duration(
                context,
                const Duration(milliseconds: 220),
              ),
              layoutBuilder: (currentChild, previousChildren) => Stack(
                alignment: Alignment.centerLeft,
                children: [
                  ...previousChildren,
                  if (currentChild != null) currentChild,
                ],
              ),
              child: Column(
                key: ValueKey('$title|$subtitle'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: tint,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: secondary, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          if (failed)
            IconButton(
              tooltip: '重试同步',
              onPressed: refreshing ? null : onRetry,
              icon: Icon(Icons.refresh_rounded, color: tint),
            ),
        ],
      ),
    );
  }
}

enum _InventorySort {
  recent('最近更新'),
  weightAsc('余量从少到多'),
  weightDesc('余量从多到少'),
  brand('按品牌');

  const _InventorySort(this.label);
  final String label;
}

class _InventoryOverview extends StatelessWidget {
  const _InventoryOverview({required this.rolls, required this.totalGrams});
  final int rolls;
  final double totalGrams;

  @override
  Widget build(BuildContext context) {
    final weight = totalGrams >= 1000
        ? '${(totalGrams / 1000).toStringAsFixed(1)} kg'
        : '${totalGrams.toStringAsFixed(0)} g';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Wrap(
        key: const ValueKey('mobile-inventory-metrics-grid'),
        spacing: 18,
        runSpacing: 6,
        children: [
          _metric(context, '$rolls', '卷耗材'),
          _metric(context, weight, '可用'),
        ],
      ),
    );
  }

  Widget _metric(
    BuildContext context,
    String value,
    String label, {
    Color? color,
  }) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: value,
            style: theme.textTheme.titleSmall?.copyWith(
              color: color ?? theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          TextSpan(text: ' $label', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _InventoryFilterChip extends StatelessWidget {
  const _InventoryFilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: MobileGlassChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        selectedColor: theme.colorScheme.primary.withValues(alpha: 0.12),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        onSelected: (_) => onSelected(),
        labelStyle: theme.textTheme.labelMedium?.copyWith(
          color: selected
              ? mobileAccentTextColor(theme)
              : theme.colorScheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }
}

class _InventoryEmptyState extends StatelessWidget {
  const _InventoryEmptyState({
    required this.hasItems,
    required this.secondary,
    required this.onAdd,
  });

  final bool hasItems;
  final Color secondary;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilamentSpoolIcon(
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppColors.textTertiaryDark
                  : AppColors.textMuted,
              size: 46,
            ),
            const SizedBox(height: 12),
            Text(
              hasItems ? '没有匹配的耗材' : '库存还是空的',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              hasItems ? '换一个搜索词或筛选条件' : '把第一卷耗材加入个人库',
              style: TextStyle(color: secondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onAdd,
              icon: Icon(
                hasItems
                    ? Icons.filter_alt_off_outlined
                    : Icons.playlist_add_rounded,
              ),
              label: Text(hasItems ? '清除筛选' : '批量加库存'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileInventoryCard extends StatelessWidget {
  const _MobileInventoryCard({
    super.key,
    required this.item,
    this.binding,
    this.source,
    this.onTap,
  });
  final Consumable item;
  final RfidSpoolBinding? binding;
  final PersonalRfidStockSource? source;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = ColorUtils.fromHex(item.colorHex);
    final colorName = item.colorName?.trim().isNotEmpty == true
        ? item.colorName!.trim()
        : item.colorHex;
    final ratio = item.totalGrams <= 0
        ? 0.0
        : (item.remainingGrams / item.totalGrams).clamp(0.0, 1.0);
    final hasCurrentTag =
        binding?.tagUid.trim().isNotEmpty == true ||
        item.trayUuid?.trim().isNotEmpty == true;
    final hasSourceCard = source?.tagUid?.trim().isNotEmpty == true;
    final low = ratio <= 0.2;
    final grams =
        '${item.remainingGrams.clamp(0, double.infinity).toStringAsFixed(0)} g';
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          item.model,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Flexible(
              child: Text(
                item.manufacturer,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            Text(' · ', style: theme.textTheme.bodySmall),
            Flexible(
              child: Text(
                colorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (hasCurrentTag || hasSourceCard) ...[
              const SizedBox(width: 5),
              Tooltip(
                message: hasCurrentTag
                    ? '当前卷已绑定 RFID 标签'
                    : '由可重复 CUID/FUID 资料卡入库',
                child: Icon(
                  Icons.nfc_rounded,
                  size: 14,
                  color: hasCurrentTag ? scheme.primary : scheme.tertiary,
                ),
              ),
            ],
          ],
        ),
        if (largeText) ...[
          const SizedBox(height: 4),
          Text(
            grams,
            style: theme.textTheme.labelLarge?.copyWith(
              color: low ? scheme.error : scheme.onSurface,
            ),
          ),
        ],
      ],
    );
    return MobileGlassSurface(
      blur: 0,
      radius: 12,
      opacity: 0.56,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            children: [
              // Same painter and default flat treatment as desktop inventory.
              FilamentSpoolIcon(color: color, size: 26),
              const SizedBox(width: 14),
              Expanded(child: info),
              if (!largeText) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: 78,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        grams,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: low ? scheme.error : scheme.onSurface,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 7),
                      StockBar(
                        remaining: item.remainingGrams,
                        total: item.totalGrams,
                        height: 3,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).brightness == Brightness.dark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: TextStyle(color: secondary, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _TagHistoryTile extends StatelessWidget {
  const _TagHistoryTile({required this.record, required this.onCopy});

  final RfidTagRecord record;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).brightness == Brightness.dark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final title = record.model.trim().isEmpty
        ? '未关联耗材信息'
        : '${record.brand} · ${record.model}';
    final operation = record.operation == 'write' ? '写入' : '扫描';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: AppColors.primary.withValues(alpha: 0.12),
        child: Icon(
          record.operation == 'write'
              ? Icons.nfc_rounded
              : Icons.contactless_rounded,
          color: AppColors.primary,
          size: 20,
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${record.tagUid} · $operation · ${record.occurredAt.toLocal().toString().substring(0, 16)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: secondary, fontSize: 11),
      ),
      trailing: IconButton(
        onPressed: onCopy,
        tooltip: '复制 UID',
        icon: const Icon(Icons.copy_rounded, size: 18),
      ),
    );
  }
}

class _MobileBatchDraft {
  const _MobileBatchDraft({
    required this.draft,
    required this.count,
    required this.initialGrams,
    required this.operationUid,
    this.tagId,
    this.tagIds = const <String>[],
    this.tagTypes = const <String, String>{},
  });

  final MobileConsumableDraft draft;
  final int count;
  final double initialGrams;
  final String operationUid;
  final String? tagId;
  final List<String> tagIds;
  final Map<String, String> tagTypes;
}

enum _BatchMode { manual, scan }

enum _InventoryEntryMode { rolls, remaining }

class _MobileBatchAddSheet extends StatefulWidget {
  const _MobileBatchAddSheet({
    required this.materials,
    required this.materialsLoading,
    this.onScanCuidFuid,
    this.onCancelTagScan,
    this.ownerAccount,
    this.tagRepository,
  });

  final List<String> materials;
  final bool materialsLoading;
  final MobileInventoryTagScanner? onScanCuidFuid;
  final Future<void> Function()? onCancelTagScan;
  final String? ownerAccount;
  final MobileRfidTagRepository? tagRepository;

  @override
  State<_MobileBatchAddSheet> createState() => _MobileBatchAddSheetState();
}

class _MobileBatchAddSheetState extends State<_MobileBatchAddSheet> {
  final _operationUid = const Uuid().v4();
  final _brandController = TextEditingController();
  final _tagController = TextEditingController();
  final _initialWeightController = TextEditingController();
  _BatchMode _mode = _BatchMode.manual;
  _InventoryEntryMode _entryMode = _InventoryEntryMode.rolls;
  String _model = '';
  Color _color = Colors.white;
  String _colorName = '';
  int _count = 1;
  bool _scanning = false;
  bool _submitting = false;
  String? _error;
  final List<String> _scannedTagIds = <String>[];
  final Map<String, String> _tagTypes = <String, String>{};

  @override
  void dispose() {
    if (_scanning) unawaited(widget.onCancelTagScan?.call());
    _brandController.dispose();
    _tagController.dispose();
    _initialWeightController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final scanner = widget.onScanCuidFuid;
    if (_scanning || scanner == null) return;
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final result = await scanner();
      if (!mounted || result == null) return;
      final tagId = MobileInventoryRepository.normalizeTagUid(result.tagId);
      if (tagId == null) throw StateError('未读取到标签 UID，请重新扫描');
      final tagType = await _confirmTagType(tagId, result.tagType);
      if (!mounted || tagType == null) return;
      MobileConsumableDraft? template = result.draft;
      if (template == null && widget.tagRepository != null) {
        final sources = await widget.tagRepository!.listInventoryTagBindings(
          ownerAccount: widget.ownerAccount ?? '',
          limit: 500,
        );
        final record = sources
            .where(
              (r) =>
                  rfidTagUidEquals(r.tagUid, tagId) && r.isConsumableTagRecord,
            )
            .firstOrNull;
        if (record != null)
          template = MobileConsumableDraft(
            brand: record.brand,
            model: record.model,
            color: ColorUtils.fromHex(record.colorHex),
            colorName: record.colorName ?? '',
          );
      }
      if (!mounted) return;
      setState(() {
        final draft = template;
        if (draft != null) {
          if (draft.brand.trim().isNotEmpty) {
            _brandController.text = draft.brand;
          }
          if (draft.model.trim().isNotEmpty) _model = draft.model;
          _color = draft.color;
          _colorName = draft.colorName;
        }
        _tagTypes[tagId] = tagType;
        _scannedTagIds
          ..clear()
          ..add(tagId);
        _tagController.text = tagId;
        _mode = _BatchMode.scan;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '扫描失败：$error');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<String?> _confirmTagType(String uid, String? scannedType) async {
    if (isConsumableRfidTagType(scannedType)) {
      return scannedType!.trim().toUpperCase();
    }
    if (!requiresConsumableRfidTagTypeConfirmation(scannedType)) {
      throw const MobileInventoryTagTypeException(
        '耗材标签只支持 CUID/FUID；NTAG213 等标签不能用于耗材入库',
      );
    }
    final knownType = _tagTypes[uid];
    if (isConsumableRfidTagType(knownType)) return knownType;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认耗材标签卡型'),
        content: SingleChildScrollView(
          child: Text(
            '标签 UID：$uid\n手机无法仅凭 UID 或 Classic 技术名称判断卡型。'
            '请按所购标签信息选择 CUID 或 FUID；不确定时请取消。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          for (final type in const ['CUID', 'FUID'])
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(type),
              child: Text('确认 $type'),
            ),
        ],
      ),
    );
  }

  Future<void> _pickModel() async {
    if (widget.materialsLoading || widget.materials.isEmpty) return;
    final result = await showMobileGlassBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BatchModelPicker(materials: widget.materials),
    );
    if (result != null && mounted) setState(() => _model = result);
  }

  Future<void> _pickColor() async {
    final result = await ColorPickerPanel.show(
      context,
      initial: _color,
      initialName: _colorName,
    );
    if (result != null && mounted) {
      setState(() {
        _color = result.color;
        _colorName = result.name;
      });
    }
  }

  Future<void> _pickSavedTag() async {
    final repository = widget.tagRepository;
    if (repository == null) return;
    try {
      final owner = widget.ownerAccount ?? '';
      final results = await Future.wait([
        repository.list(ownerAccount: owner, profile: 'ams', limit: 100),
        // History is local-only by design.  Inventory bindings are part of
        // the synced personal snapshot, so include them for a fresh phone
        // that has never performed a local NFC operation yet.
        repository.listInventoryTagBindings(ownerAccount: owner, limit: 100),
      ]);
      if (!mounted) return;
      final latestByUid = <String, RfidTagRecord>{};
      for (final record in [...results[0], ...results[1]]) {
        final uid =
            MobileInventoryRepository.normalizeTagUid(record.tagUid) ?? '';
        if (uid.isEmpty || !record.succeeded || !record.isConsumableTagRecord) {
          continue;
        }
        latestByUid.putIfAbsent(uid, () => record.copyWith(tagUid: uid));
      }
      final selected = await showMobileGlassBottomSheet<String>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => _SavedTagPicker(
          records: latestByUid.values.toList(growable: false),
        ),
      );
      if (selected != null && mounted) {
        setState(() {
          _scannedTagIds.clear();
          _tagTypes.clear();
          _tagTypes[selected] = latestByUid[selected]!.tagType
              .trim()
              .toUpperCase();
          _tagController.text = selected;
          _mode = _BatchMode.manual;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '标签记录加载失败：$error');
    }
  }

  Future<void> _submit() async {
    if (_submitting || _scanning) return;
    final brand = _brandController.text.trim();
    final tagId = MobileInventoryRepository.normalizeTagUid(
      _tagController.text,
    );
    if (brand.isEmpty) {
      setState(() => _error = '请输入品牌');
      return;
    }
    if (_model.trim().isEmpty) {
      setState(() => _error = '请选择型号');
      return;
    }
    final initialGrams = _entryMode == _InventoryEntryMode.rolls
        ? 1000.0
        : double.tryParse(_initialWeightController.text.trim());
    if (initialGrams == null ||
        !initialGrams.isFinite ||
        initialGrams <= 0 ||
        initialGrams > 1000) {
      setState(() => _error = '请输入大于 0 且不超过 1000 g 的剩余克数');
      return;
    }
    if (_mode == _BatchMode.scan && _scannedTagIds.isEmpty) {
      setState(() => _error = '请先扫描 CUID/FUID 标签再登记库存');
      return;
    }
    setState(() => _submitting = true);
    try {
      if (tagId != null && !isConsumableRfidTagType(_tagTypes[tagId])) {
        final type = await _confirmTagType(tagId, null);
        if (!mounted || type == null) return;
        _tagTypes[tagId] = type;
      }
      if (!mounted) return;
      Navigator.of(context).pop(
        _MobileBatchDraft(
          draft: MobileConsumableDraft(
            brand: brand,
            model: _model.trim(),
            color: _color,
            colorName: _colorName.trim(),
          ),
          count: _entryMode == _InventoryEntryMode.rolls ? _count : 1,
          initialGrams: initialGrams,
          operationUid: _operationUid,
          tagId: tagId,
          tagIds: List<String>.unmodifiable(
            _mode == _BatchMode.scan && _scannedTagIds.isNotEmpty
                ? _scannedTagIds
                : (tagId == null ? const <String>[] : <String>[tagId]),
          ),
          tagTypes: Map<String, String>.unmodifiable(_tagTypes),
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _editCount() async {
    var input = _count.toString();
    final formKey = GlobalKey<FormState>();
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        void submit() {
          if (formKey.currentState!.validate()) {
            Navigator.of(dialogContext).pop(int.parse(input));
          }
        }

        return AlertDialog(
          title: const Text('输入本次新增卷数'),
          content: Form(
            key: formKey,
            child: TextFormField(
              key: const ValueKey('batch-count-input'),
              initialValue: input,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '数量',
                helperText: '每批可新增 1–100 卷',
                suffixText: '卷',
              ),
              validator: (value) {
                final count = int.tryParse(value ?? '');
                return count != null && count >= 1 && count <= 100
                    ? null
                    : '请输入 1–100 之间的整数卷数';
              },
              onChanged: (value) => input = value,
              onFieldSubmitted: (_) => submit(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(onPressed: submit, child: const Text('确定')),
          ],
        );
      },
    );
    if (selected != null && mounted) {
      setState(() => _count = selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '批量加库存',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '1 卷 = 1 kg',
                  style: TextStyle(color: secondary, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GlassSegmentedSurface(
              child: SegmentedButton<_BatchMode>(
                key: const ValueKey('batch-source-mode'),
                segments: const [
                  ButtonSegment(
                    value: _BatchMode.manual,
                    icon: Icon(Icons.edit_note_rounded),
                    label: Text('手动添加'),
                  ),
                  ButtonSegment(
                    value: _BatchMode.scan,
                    icon: Icon(Icons.nfc_rounded),
                    label: Text('读取 CUID/FUID'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: _scanning || _submitting
                    ? null
                    : (selection) {
                        setState(() {
                          _mode = selection.first;
                          // A UID collected in scan mode must not leak into a later
                          // manual submission (and vice versa). The text field is
                          // kept only as a convenience for the selected/manual UID.
                          if (_mode == _BatchMode.manual) {
                            _scannedTagIds.clear();
                            _tagTypes.clear();
                            _tagController.clear();
                          } else {
                            _tagController.clear();
                          }
                          _error = null;
                        });
                      },
              ),
            ),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: AppMotion.duration(
                context,
                const Duration(milliseconds: 220),
              ),
              child: _mode == _BatchMode.scan
                  ? _ScanPanel(
                      key: const ValueKey('scan'),
                      available: widget.onScanCuidFuid != null,
                      scanning: _scanning,
                      scannedCount: _scannedTagIds.length,
                      onScan: _scan,
                    )
                  : _ManualPanel(
                      key: const ValueKey('manual'),
                      tagController: _tagController,
                      secondary: secondary,
                      onPickSaved: widget.tagRepository == null
                          ? null
                          : _pickSavedTag,
                    ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _brandController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '品牌',
                hintText: '例如：eSUN、Bambu Lab',
                prefixIcon: Icon(Icons.sell_outlined),
              ),
            ),
            const SizedBox(height: 12),
            _BatchSelectionField(
              label: '耗材型号',
              value: _model,
              placeholder: widget.materialsLoading ? '正在加载型号库…' : '选择桌面端型号',
              icon: Icons.category_outlined,
              onTap: widget.materialsLoading ? null : _pickModel,
            ),
            const SizedBox(height: 12),
            _BatchColorField(
              color: _color,
              name: _colorName,
              onTap: _pickColor,
            ),
            const SizedBox(height: 12),
            GlassSegmentedSurface(
              child: SegmentedButton<_InventoryEntryMode>(
                key: const ValueKey('batch-entry-mode'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: _InventoryEntryMode.rolls,
                    label: Text('按卷数入库'),
                    icon: Icon(Icons.inventory_2_outlined),
                  ),
                  ButtonSegment(
                    value: _InventoryEntryMode.remaining,
                    label: Text('按余量入库'),
                    icon: Icon(Icons.scale_outlined),
                  ),
                ],
                selected: {_entryMode},
                onSelectionChanged: _scanning || _submitting
                    ? null
                    : (selection) {
                        setState(() {
                          _entryMode = selection.single;
                          _error = null;
                        });
                      },
              ),
            ),
            const SizedBox(height: 14),
            AnimatedSize(
              duration: AppMotion.duration(
                context,
                const Duration(milliseconds: 220),
              ),
              alignment: Alignment.topCenter,
              child: _entryMode == _InventoryEntryMode.rolls
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _CountStepper(
                          count: _count,
                          onChanged: _scanning || _submitting
                              ? (_) {}
                              : (value) => setState(() => _count = value),
                          onEdit: _scanning || _submitting ? () {} : _editCount,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '每卷固定 1000 g · 本次共 ${_count * 1000} g',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    )
                  : TextField(
                      key: const ValueKey('batch-remaining-grams'),
                      controller: _initialWeightController,
                      enabled: !_scanning && !_submitting,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: '剩余克数',
                        suffixText: 'g',
                        helperText: '登记一卷余料，只计入填写的剩余重量。',
                        helperMaxLines: 2,
                      ),
                    ),
            ),
            if (_mode == _BatchMode.scan) const Text('资料卡只提供耗材信息，点击确认后才会新增库存。'),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.danger,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _scanning || _submitting ? null : _submit,
              icon: const Icon(Icons.add_task_rounded),
              label: Text(
                _entryMode == _InventoryEntryMode.rolls
                    ? '确认新增 $_count 卷'
                    : '确认余量入库',
              ),
            ),
            TextButton(
              onPressed: _submitting
                  ? null
                  : () {
                      if (_scanning) unawaited(widget.onCancelTagScan?.call());
                      Navigator.of(context).pop();
                    },
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanPanel extends StatelessWidget {
  const _ScanPanel({
    super.key,
    required this.available,
    required this.scanning,
    required this.scannedCount,
    required this.onScan,
  });

  final bool available;
  final bool scanning;
  final int scannedCount;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final tint = available ? AppColors.primary : AppColors.warning;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(color: tint.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(Icons.contactless_rounded, color: tint, size: 27),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              available
                  ? '靠近可重复使用的 CUID/FUID 资料卡，读取后选择本次新增的卷数。${scannedCount > 0 ? '已读取资料卡。' : ''}'
                  : '当前版本还没有接入 CUID/FUID UID 读取桥；可以先手动录入，接入后此入口会直接启用。',
              style: TextStyle(color: secondary, fontSize: 12, height: 1.4),
            ),
          ),
          if (available)
            IconButton(
              onPressed: scanning ? null : onScan,
              tooltip: '开始扫描',
              icon: scanning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.play_circle_outline_rounded, color: tint),
            ),
        ],
      ),
    );
  }
}

class _ManualPanel extends StatelessWidget {
  const _ManualPanel({
    super.key,
    required this.tagController,
    required this.secondary,
    this.onPickSaved,
  });

  final TextEditingController tagController;
  final Color secondary;
  final VoidCallback? onPickSaved;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: tagController,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: '资料卡 UID（可选）',
            hintText: '填入已保存的 CUID/FUID UID',
            prefixIcon: const Icon(Icons.tag_rounded),
            helperText: '同一张 CUID/FUID 可为多次入库提供资料，不要求每卷配一张卡。',
            helperStyle: TextStyle(color: secondary, fontSize: 11),
          ),
        ),
        if (onPickSaved != null) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onPickSaved,
              icon: const Icon(Icons.history_rounded, size: 17),
              label: const Text('从已保存标签选择'),
              style: glassButtonStyle(
                context,
                TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: Theme.of(context).colorScheme.primary,
                ),
                variant: AppGlassButtonVariant.quiet,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SavedTagPicker extends StatelessWidget {
  const _SavedTagPicker({required this.records});

  final List<RfidTagRecord> records;

  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).brightness == Brightness.dark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '选择已保存标签',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            records.isEmpty ? '还没有可复用的 CUID/FUID 记录' : '选择后会填入当前批量库存表单',
            style: TextStyle(color: secondary, fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (records.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Icon(Icons.nfc_rounded, size: 44),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: records.length,
                itemBuilder: (context, index) {
                  final record = records[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: AppColors.primary.withValues(
                        alpha: 0.12,
                      ),
                      child: Icon(Icons.nfc_rounded, color: AppColors.primary),
                    ),
                    title: Text(
                      record.tagUid,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                    subtitle: Text(
                      record.model.trim().isEmpty
                          ? '最近使用 · ${record.occurredAt.toLocal().toString().substring(0, 16)}'
                          : '${record.brand} · ${record.model}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: secondary, fontSize: 11),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).pop(record.tagUid),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _BatchSelectionField extends StatelessWidget {
  const _BatchSelectionField({
    required this.label,
    required this.value,
    required this.placeholder,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String value;
  final String placeholder;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = value.isEmpty
        ? (isDark ? AppColors.textTertiaryDark : AppColors.textTertiary)
        : (isDark ? AppColors.textPrimaryDark : AppColors.textPrimary);
    return Semantics(
      button: true,
      label: '$label，${value.isEmpty ? placeholder : value}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppColors.radiusMd),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: Icon(icon),
              suffixIcon: const Icon(Icons.expand_more_rounded),
              enabled: onTap != null,
            ),
            child: Text(
              value.isEmpty ? placeholder : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: foreground, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}

class _BatchColorField extends StatelessWidget {
  const _BatchColorField({
    required this.color,
    required this.name,
    required this.onTap,
  });

  final Color color;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: '颜色，${name.isEmpty ? '选择颜色' : name}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppColors.radiusMd),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: '颜色',
              prefixIcon: Icon(Icons.palette_outlined),
              suffixIcon: Icon(Icons.tune_rounded),
            ),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isDark ? AppColors.outlineDark : AppColors.outline,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name.isEmpty ? ColorUtils.toHex(color) : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CountStepper extends StatelessWidget {
  const _CountStepper({
    required this.count,
    required this.onChanged,
    required this.onEdit,
  });

  final int count;
  final ValueChanged<int> onChanged;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).brightness == Brightness.dark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('入库数量', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                '每卷按 1000 g 计入',
                style: TextStyle(color: secondary, fontSize: 11),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: count <= 1 ? null : () => onChanged(count - 1),
          tooltip: '减少数量',
          icon: const Icon(Icons.remove_circle_outline_rounded),
        ),
        Tooltip(
          message: '直接输入数量',
          child: InkWell(
            key: const ValueKey('batch-count-value'),
            onTap: onEdit,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: 40,
              child: Center(
                child: Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: count >= 100 ? null : () => onChanged(count + 1),
          tooltip: '增加数量',
          icon: const Icon(Icons.add_circle_outline_rounded),
        ),
      ],
    );
  }
}

class _BatchModelPicker extends StatefulWidget {
  const _BatchModelPicker({required this.materials});

  final List<String> materials;

  @override
  State<_BatchModelPicker> createState() => _BatchModelPickerState();
}

class _BatchModelPickerState extends State<_BatchModelPicker> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final values = widget.materials
        .where((value) => query.isEmpty || value.toLowerCase().contains(query))
        .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: '搜索型号',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              itemCount: values.length,
              itemBuilder: (context, index) {
                final value = values[index];
                return ListTile(
                  leading: const Icon(Icons.category_outlined),
                  title: Text(value),
                  onTap: () => Navigator.pop(context, value),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
