import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import '../../core/services/preset_diff_service.dart';
import '../../core/theme/app_colors.dart';
import '../../data/external/slicer/bambu_system_preset_loader.dart';

/// 预设比较对话框。
///
/// 并排显示两个预设的参数差异，仅显示不同的字段。
class PresetCompareDialog extends StatefulWidget {
  /// 预设 A 的名称
  final String presetAName;

  /// 预设 A 的参数 Map
  final Map<String, String> presetAValues;

  /// 预设 B 的名称
  final String presetBName;

  /// 预设 B 的参数 Map
  final Map<String, String> presetBValues;

  const PresetCompareDialog({
    super.key,
    required this.presetAName,
    required this.presetAValues,
    required this.presetBName,
    required this.presetBValues,
  });

  @override
  State<PresetCompareDialog> createState() => _PresetCompareDialogState();

  /// 比较两个系统预设。
  static Future<void> showCompare(
    BuildContext context, {
    required String presetAName,
    required String nozzleDiameterA,
    required String presetBName,
    required String nozzleDiameterB,
  }) async {
    final valuesA = await BambuSystemPresetLoader.loadProcessPreset(
      presetAName,
      nozzleDiameterA,
    );
    final valuesB = await BambuSystemPresetLoader.loadProcessPreset(
      presetBName,
      nozzleDiameterB,
    );
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (_) => PresetCompareDialog(
        presetAName: presetAName,
        presetAValues: valuesA,
        presetBName: presetBName,
        presetBValues: valuesB,
      ),
    );
  }

  /// 比较系统预设与当前编辑值。
  static Future<void> showCompareWithCurrent(
    BuildContext context, {
    required String presetName,
    required String nozzleDiameter,
    required Map<String, String> currentValues,
  }) async {
    final values = await BambuSystemPresetLoader.loadProcessPreset(
      presetName,
      nozzleDiameter,
    );
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (_) => PresetCompareDialog(
        presetAName: presetName,
        presetAValues: values,
        presetBName: '当前编辑值',
        presetBValues: currentValues,
      ),
    );
  }
}

class _PresetCompareDialogState extends State<PresetCompareDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 计算所有差异字段（已按字段名排序）。
  List<_DiffEntry> _computeDiffs() {
    return PresetDiffService.compareMaps(
          widget.presetAValues,
          widget.presetBValues,
        )
        .map(
          (diff) => _DiffEntry(
            field: diff.field,
            valueA: diff.valueA,
            valueB: diff.valueB,
          ),
        )
        .toList(growable: false);
  }

  List<_DiffEntry> _filter(List<_DiffEntry> all) {
    if (_query.isEmpty) return all;
    final q = _query.toLowerCase();
    return all.where((e) {
      return e.field.toLowerCase().contains(q) ||
          e.valueA.toLowerCase().contains(q) ||
          e.valueB.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final allDiffs = _computeDiffs();
    final shownDiffs = _filter(allDiffs);
    final size = MediaQuery.sizeOf(context);

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppColors.radiusLg),
      ),
      child: SizedBox(
        width: (size.width - 48).clamp(320.0, 800.0).toDouble(),
        height: (size.height - 48).clamp(320.0, 600.0).toDouble(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppColors.radiusLg),
          child: Column(
            children: [
              _buildHeader(),
              _buildSearchBar(),
              Expanded(child: _buildBody(allDiffs, shownDiffs)),
              _buildFooter(allDiffs.length, shownDiffs.length),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: BoxDecoration(
        color: AppColors.primary50,
        border: const Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Icon(Icons.compare_arrows, color: AppColors.primary, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '预设比较',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${widget.presetAName} vs ${widget.presetBName}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            color: AppColors.textTertiary,
            onPressed: () => Navigator.of(context).pop(),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: '搜索差异项（字段名 / 值）',
          hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          prefixIcon: const Icon(
            Icons.search,
            color: AppColors.textTertiary,
            size: 20,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  color: AppColors.textTertiary,
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: AppColors.surfaceContainerHigh,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            borderSide: const BorderSide(color: AppColors.outline),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            borderSide: const BorderSide(color: AppColors.outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(List<_DiffEntry> allDiffs, List<_DiffEntry> shownDiffs) {
    if (allDiffs.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_rounded,
              color: AppColors.success,
              size: 48,
            ),
            SizedBox(height: 12),
            Text(
              '两个预设参数完全一致',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (shownDiffs.isEmpty) {
      return Center(
        child: Text(
          '没有匹配 "$_query" 的差异项',
          style: const TextStyle(color: AppColors.textTertiary, fontSize: 13),
        ),
      );
    }

    return Column(
      children: [
        _buildTableHeader(),
        const Divider(height: 1, color: AppColors.divider),
        Expanded(
          child: ListView.separated(
            itemCount: shownDiffs.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: AppColors.divider),
            itemBuilder: (_, i) => _buildDiffRow(shownDiffs[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildTableHeader() {
    return Container(
      color: AppColors.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          _headerCell('字段名', alignment: Alignment.centerLeft, flex: 2),
          _headerCell(widget.presetAName, alignment: Alignment.center, flex: 2),
          _headerCell(widget.presetBName, alignment: Alignment.center, flex: 2),
        ],
      ),
    );
  }

  Widget _headerCell(
    String text, {
    required Alignment alignment,
    required int flex,
  }) {
    return Expanded(
      flex: flex,
      child: Align(
        alignment: alignment,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textTertiary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildDiffRow(_DiffEntry entry) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                entry.field,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.center,
              child: Text(
                entry.valueA.isEmpty ? '-' : entry.valueA,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.danger,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.center,
              child: Text(
                entry.valueB.isEmpty ? '-' : entry.valueB,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.success,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(int totalDiffs, int shownDiffs) {
    final countText = _query.isEmpty
        ? '差异项：$totalDiffs'
        : '差异项：$shownDiffs / $totalDiffs';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          const Icon(Icons.tune, color: AppColors.textTertiary, size: 16),
          const SizedBox(width: 6),
          Text(
            countText,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const Spacer(),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: glassButtonStyle(
              context,
              ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimary,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppColors.radiusMd),
                ),
              ),
              variant: AppGlassButtonVariant.primary,
            ),
            child: const Text('关闭', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// 单条差异项。
class _DiffEntry {
  final String field;
  final String valueA;
  final String valueB;

  const _DiffEntry({
    required this.field,
    required this.valueA,
    required this.valueB,
  });
}
