import 'dart:io';

import '../../core/theme/glass_button_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/friendly_error.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/external/calibration/bambu_studio_preset_writer.dart';
import '../../data/external/calibration/calibration_guide.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../../providers/calibration_provider.dart';
import '../../providers/parameter_preset_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/app_input.dart';
import '../../widgets/app_select.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/app_segmented.dart';
import '../parameters/parameter_experiment_panel.dart';

enum _QualityOptimizationView { calibration, experiments }

/// 打印质量优化页面。
///
/// 基于内置的多功能测试模型（3mf），一个模型覆盖 7 个测试维度。
/// 使用流程：
/// 1. 点「用 BambuStudio 打开测试模型」→ 3mf 文件用 BambuStudio 打开
/// 2. 在 BambuStudio 里切片（用当前耗材预设）→ 发送打印
/// 3. 打印完成后对照 7 个测试维度观察结果
/// 4. 在下方填入优化值（留空的不写）→ 选目标预设 → 点写入
/// 5. 软件自动备份原预设 → 修改字段 → 提示成功
/// 6. 可从备份列表一键回滚
class CalibrationScreen extends ConsumerStatefulWidget {
  const CalibrationScreen({super.key});

  @override
  ConsumerState<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends ConsumerState<CalibrationScreen> {
  /// 6 个参数输入框的控制器，key = PresetField.key
  final Map<String, TextEditingController> _controllers = {};
  bool _isWriting = false;
  bool _isExtracting = false;
  _QualityOptimizationView _selectedView = _QualityOptimizationView.calibration;

  @override
  void initState() {
    super.initState();
    for (final f in kAllPresetFields) {
      _controllers[f.key] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 把 assets 里的 3mf 提取到临时目录，然后用系统默认程序打开。
  ///
  /// assets 里的文件不能直接用 Process 打开，需要先提取到文件系统。
  /// 提取到 getTemporaryDirectory()/calibration/test_model.3mf。
  /// Windows 上 .3mf 默认关联 BambuStudio，用 explorer.exe 打开即可。
  Future<void> _openModelInBambuStudio() async {
    setState(() => _isExtracting = true);
    try {
      // 1. 从 assets 加载 3mf 字节
      final bytes = await rootBundle.load(kModelAssetPath);

      // 2. 写到临时目录
      final tmpDir = await getTemporaryDirectory();
      final modelDir = Directory('${tmpDir.path}\\calibration');
      if (!modelDir.existsSync()) {
        modelDir.createSync(recursive: true);
      }
      final modelFile = File('${modelDir.path}\\test_model.3mf');
      await modelFile.writeAsBytes(bytes.buffer.asUint8List());

      // 3. 用 explorer.exe 打开（Windows 会用 .3mf 关联的程序，即 BambuStudio）
      // 用 Process.run 同步等待，explorer.exe 会立即返回 0
      final result = await Process.run('explorer.exe', [modelFile.path]);
      if (mounted) {
        if (result.exitCode == 0) {
          showSnack(context, '已用 BambuStudio 打开测试模型');
        } else {
          showSnack(context, '打开失败，exitCode=${result.exitCode}', error: true);
        }
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, '打开失败: ${friendlyError(e)}', error: true);
      }
    } finally {
      if (mounted) setState(() => _isExtracting = false);
    }
  }

  /// 收集所有填了值的参数。
  Map<String, double> _collectFilledFields() {
    final result = <String, double>{};
    for (final entry in _controllers.entries) {
      final text = entry.value.text.trim();
      if (text.isEmpty) continue;
      final value = double.tryParse(text);
      if (value != null) {
        result[entry.key] = value;
      }
    }
    return result;
  }

  /// 写入预设（多字段一次写入，含备份）。
  Future<void> _writePreset() async {
    final preset = ref.read(selectedPresetProvider);
    if (preset == null) {
      showSnack(context, '请先选择目标预设', error: true);
      return;
    }
    if (preset.isSystem) {
      showSnack(context, '系统预设只读，请选择用户预设', error: true);
      return;
    }

    final fields = _collectFilledFields();
    if (fields.isEmpty) {
      showSnack(context, '请至少填入一个参数值', error: true);
      return;
    }

    setState(() => _isWriting = true);
    try {
      final result = await writeCalibrationPresetFields(
        preset: preset,
        fields: fields,
        session: ref.read(bambuCloudProvider).session,
      );
      // 本地目录与拓竹云端都重新拉取；参数广场的“我的预设”同步看到更新。
      ref.invalidate(bambuStudioPresetsProvider);
      ref.invalidate(bambuCloudFilamentPresetsProvider);
      ref.invalidate(cloudParameterPresetsProvider);
      if (preset.isLocal) {
        ref.invalidate(presetBackupsProvider(preset.filePath));
      }
      if (mounted) {
        final fieldNames = fields.keys
            .map((k) => kAllPresetFields.firstWhere((f) => f.key == k).label)
            .join('、');
        if (result.cloudError != null) {
          showSnack(
            context,
            '本地预设已写入，但云端同步失败：${friendlyError(result.cloudError!)}',
            error: true,
          );
        } else {
          final destination = result.localWritten && result.cloudWritten
              ? '本地与拓竹云端'
              : result.cloudWritten
              ? '拓竹云端'
              : '本地 BambuStudio';
          showSnack(context, '已写入「${preset.name}」并同步到$destination：$fieldNames');
        }
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, '写入失败: ${friendlyError(e)}', error: true);
      }
    } finally {
      if (mounted) setState(() => _isWriting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final padding = width < 600 ? 16.0 : 24.0;
    // 桌面端用固定宽度居中，避免宽屏下卡片过宽难看
    final maxContentWidth = width < 900 ? double.infinity : 1160.0;
    final selectedPreset = ref.watch(selectedPresetProvider);

    final calibrationView = Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxContentWidth),
        child: ListView(
          padding: EdgeInsets.fromLTRB(padding, 16, padding, 32),
          children: [
            const ExperiencePageHeader(
              title: '质量实验室',
              description: '先打印测试件，再把观察结果整理成优化草案。所有填写内容都会在实验台即时汇总，确认后才写入预设。',
            ),
            const SizedBox(height: AppSpacing.lg),

            _CalibrationLabStage(
              controllers: _controllers,
              selectedPreset: selectedPreset,
              onClear: () {
                for (final controller in _controllers.values) {
                  controller.clear();
                }
              },
            ),
            const SizedBox(height: 14),

            // 1. 测试模型说明 + 打开按钮
            _ModelIntroCard(
              onOpen: _openModelInBambuStudio,
              isExtracting: _isExtracting,
            ),
            const SizedBox(height: 14),

            // 2. 测试维度说明
            const _DimensionsCard(),
            const SizedBox(height: 14),

            // 3. 参数填入 + 预设选择 + 写入（两列布局：左参数，右预设+写入）
            _ParamsAndPresetCard(
              controllers: _controllers,
              isWriting: _isWriting,
              onWrite: _writePreset,
            ),
            const SizedBox(height: 14),

            // 4. 备份与回滚
            const _BackupCard(),
          ],
        ),
      ),
    );

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(padding, 12, padding, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: AppSegmented<_QualityOptimizationView>(
              value: _selectedView,
              segments: const [
                AppSegment(
                  label: '校准优化',
                  value: _QualityOptimizationView.calibration,
                  icon: Icon(Icons.tune_rounded),
                ),
                AppSegment(
                  label: '参数实验',
                  value: _QualityOptimizationView.experiments,
                  icon: Icon(Icons.science_outlined),
                ),
              ],
              onChanged: (value) => setState(() => _selectedView = value),
            ),
          ),
        ),
        Expanded(
          child: _selectedView == _QualityOptimizationView.calibration
              ? calibrationView
              : const ParameterExperimentPanel(),
        ),
      ],
    );
  }
}

class _CalibrationLabStage extends StatelessWidget {
  const _CalibrationLabStage({
    required this.controllers,
    required this.selectedPreset,
    required this.onClear,
  });

  final Map<String, TextEditingController> controllers;
  final PresetInfo? selectedPreset;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(controllers.values.toList()),
      builder: (context, _) {
        final fields = <({PresetField field, String value})>[];
        for (final field in kAllPresetFields) {
          final value = controllers[field.key]?.text.trim() ?? '';
          if (value.isNotEmpty) fields.add((field: field, value: value));
        }
        return OpenStage(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExperienceSectionHeading(
                title: '优化草案实验台',
                trailing: TextButton.icon(
                  onPressed: fields.isEmpty ? null : onClear,
                  icon: const Icon(Icons.restart_alt_rounded, size: 16),
                  label: const Text('清空草案'),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              LayoutBuilder(
                builder: (context, constraints) {
                  final baseline = _CalibrationSpecimen(
                    label: '当前基线',
                    icon: Icons.bookmark_outline_rounded,
                    title: selectedPreset?.name ?? '尚未选择预设',
                    subtitle: selectedPreset == null
                        ? '在下方选择一个用户预设作为写入目标'
                        : '${selectedPreset!.vendor ?? '本地'} · ${selectedPreset!.filamentType ?? '耗材预设'}',
                    accent: Theme.of(context).colorScheme.onSurfaceVariant,
                  );
                  final draft = _CalibrationDraftSpecimen(fields: fields);
                  if (constraints.maxWidth < 720) {
                    return Column(
                      children: [
                        baseline,
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Icon(
                            Icons.arrow_downward_rounded,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        draft,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: baseline),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                      Expanded(child: draft),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CalibrationSpecimen extends StatelessWidget {
  const _CalibrationSpecimen({
    required this.label,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
  });

  final String label;
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 104),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(ExperienceTokens.objectRadius),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, size: 28, color: accent),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 10,
                    height: 1.4,
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

class _CalibrationDraftSpecimen extends StatelessWidget {
  const _CalibrationDraftSpecimen({required this.fields});

  final List<({PresetField field, String value})> fields;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: ExperienceTokens.contentDuration,
      constraints: const BoxConstraints(minHeight: 104),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: fields.isEmpty
            ? scheme.surface
            : scheme.primaryContainer.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(ExperienceTokens.objectRadius),
        border: Border.all(
          color: fields.isEmpty ? scheme.outlineVariant : scheme.primary,
          width: fields.isEmpty ? 1 : 1.5,
        ),
      ),
      child: Row(
        children: [
          Icon(
            fields.isEmpty ? Icons.science_outlined : Icons.science_rounded,
            size: 28,
            color: fields.isEmpty ? scheme.onSurfaceVariant : scheme.primary,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: fields.isEmpty
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '优化草案',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '填写下方参数后，变化会实时汇总到这里。',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  )
                : Wrap(
                    spacing: 12,
                    runSpacing: 7,
                    children: [
                      for (final entry in fields.take(5))
                        Text(
                          '${entry.field.label} ${entry.value}${entry.field.unit}',
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
          ),
          if (fields.isNotEmpty)
            Text(
              '${fields.length} 项',
              style: TextStyle(
                color: scheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
        ],
      ),
    );
  }
}

/// 测试模型说明卡片 + 打开按钮。
class _ModelIntroCard extends StatelessWidget {
  final VoidCallback onOpen;
  final bool isExtracting;

  const _ModelIntroCard({required this.onOpen, required this.isExtracting});

  @override
  Widget build(BuildContext context) {
    // 暗色模式适配
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行：图标 + 标题 + 按钮
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(AppColors.radiusSm),
                ),
                child: Center(
                  child: BambuIcon(
                    name: 'tab_calibration_active',
                    color: AppColors.primary,
                    size: 20,
                    applyColorFilter: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '多功能测试模型',
                  style: AppTypography.title.copyWith(
                    fontSize: 14,
                    color: textPrimary,
                  ),
                ),
              ),
              // 用 BambuStudio 打开按钮（AppButton primary）
              AppButton(
                label: isExtracting ? '打开中...' : '用 BambuStudio 打开',
                variant: AppButtonVariant.primary,
                icon: isExtracting
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: isDark
                              ? AppColors.textTertiaryDark
                              : AppColors.textTertiary,
                        ),
                      )
                    : const Icon(Icons.open_in_new, size: 16),
                onPressed: isExtracting ? null : onOpen,
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 完整说明文本（不截断）
          Text(
            kModelDescription,
            style: AppTypography.body.copyWith(
              fontSize: 11,
              color: textSecondary,
              height: 1.6,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // 提示
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.infoContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(AppColors.radiusSm),
            ),
            child: Row(
              children: [
                const BambuIcon(
                  name: 'info',
                  size: 13,
                  color: AppColors.info,
                  applyColorFilter: true,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '打开后在 BambuStudio 里选耗材预设 → 切片 → 发送打印。打印完成后对照下方测试维度观察结果。',
                    style: AppTypography.caption.copyWith(
                      fontSize: 10,
                      color: AppColors.info,
                    ),
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

/// 7 个测试维度说明卡片（紧凑横排 chip 样式）。
class _DimensionsCard extends StatelessWidget {
  const _DimensionsCard();

  @override
  Widget build(BuildContext context) {
    // 暗色模式适配
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textTertiary = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.checklist_rounded, size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(
                '测试维度',
                style: AppTypography.title.copyWith(
                  fontSize: 13,
                  color: textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '打印完成后逐项检查这些部位',
            style: AppTypography.caption.copyWith(
              fontSize: 11,
              color: textTertiary,
            ),
          ),
          const SizedBox(height: 10),
          for (final d in kTestDimensions) ...[
            _DimensionItem(dimension: d),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _DimensionItem extends StatelessWidget {
  final TestDimension dimension;

  const _DimensionItem({required this.dimension});

  @override
  Widget build(BuildContext context) {
    // 暗色模式适配
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final surfaceVariant = isDark
        ? AppColors.surfaceVariantDark
        : AppColors.surfaceVariant;
    final border = isDark ? AppColors.outlineDark : AppColors.border;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: surfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border: Border.all(color: border.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧名称
          SizedBox(
            width: 140,
            child: Text(
              dimension.name,
              style: AppTypography.body.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 中间描述
          Expanded(
            child: Text(
              dimension.description,
              style: AppTypography.body.copyWith(
                fontSize: 11,
                color: textSecondary,
                height: 1.5,
              ),
            ),
          ),
          // 右侧关联参数标签
          if (dimension.relatedFields.isNotEmpty) ...[
            const SizedBox(width: AppSpacing.sm),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: dimension.relatedFields.map((f) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    f.label,
                    style: AppTypography.label.copyWith(
                      fontSize: 9,
                      color: AppColors.primary,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

/// 参数填入 + 预设选择 + 写入按钮（合并为一个卡片）。
class _ParamsAndPresetCard extends ConsumerWidget {
  final Map<String, TextEditingController> controllers;
  final bool isWriting;
  final VoidCallback onWrite;

  const _ParamsAndPresetCard({
    required this.controllers,
    required this.isWriting,
    required this.onWrite,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presetsAsync = ref.watch(bambuStudioPresetsProvider);
    final cloudPresetsAsync = ref.watch(bambuCloudFilamentPresetsProvider);
    final selectedPreset = ref.watch(selectedPresetProvider);
    final width = MediaQuery.sizeOf(context).width;
    // 手机单列，桌面双列
    final isDesktop = width >= 600;
    // 暗色模式适配
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textTertiary = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(
                '结果填入',
                style: AppTypography.title.copyWith(
                  fontSize: 13,
                  color: textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                '留空的不写入',
                style: AppTypography.caption.copyWith(
                  fontSize: 10,
                  color: textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 参数输入区：桌面 2 列，手机 1 列
          if (isDesktop)
            _buildDesktopParamsGrid()
          else
            _buildMobileParamsList(),
          const SizedBox(height: 14),

          // 预设选择
          presetsAsync.when(
            skipLoadingOnRefresh: true,
            loading: () => const SizedBox(
              height: 24,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text(
              '预设加载失败: ${friendlyError(e)}',
              style: AppTypography.body.copyWith(
                color: AppColors.danger,
                fontSize: 12,
              ),
            ),
            data: (localPresets) {
              final presets = mergeCalibrationPresets(
                localPresets,
                cloudPresetsAsync.valueOrNull ?? const [],
              );
              if (presets.isEmpty) {
                if (cloudPresetsAsync.isLoading) {
                  return const _PresetSyncNotice(
                    icon: Icons.cloud_sync_outlined,
                    message: '正在同步拓竹云端用户耗材预设…',
                    color: AppColors.info,
                    loading: true,
                  );
                }
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.warningContainer,
                    borderRadius: BorderRadius.circular(AppColors.radiusSm),
                  ),
                  child: Row(
                    children: [
                      const BambuIcon(
                        name: 'warning',
                        size: 16,
                        color: AppColors.warning,
                        applyColorFilter: true,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          '本地与拓竹云端都没有检测到用户耗材预设。请确认账号已登录，或先在 BambuStudio 中创建自定义耗材预设。',
                          style: AppTypography.caption.copyWith(
                            fontSize: 11,
                            color: AppColors.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (cloudPresetsAsync.hasError) ...[
                    _PresetSyncNotice(
                      icon: Icons.cloud_off_outlined,
                      message:
                          '云端预设同步失败，仍可使用本地预设：${friendlyError(cloudPresetsAsync.error!)}',
                      color: AppColors.warning,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  AppSelect<PresetInfo>(
                    value:
                        selectedPreset != null &&
                            presets.contains(selectedPreset)
                        ? selectedPreset
                        : null,
                    label: '目标预设 · 打开时自动同步本地与拓竹云端',
                    hint: '选择要写入的用户耗材预设',
                    items: presets
                        .map(
                          (preset) => DropdownMenuItem(
                            value: preset,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${preset.name}${preset.filamentType != null ? ' (${preset.filamentType})' : ''}',
                                    style: AppTypography.body.copyWith(
                                      fontSize: 13,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _PresetSourcePill(preset: preset),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                    onOpen: () => _refreshPresetSources(ref),
                    onChanged: (value) =>
                        ref.read(selectedPresetProvider.notifier).state = value,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${localPresets.length} 个本地 · ${cloudPresetsAsync.valueOrNull?.length ?? 0} 个云端',
                    textAlign: TextAlign.right,
                    style: AppTypography.caption.copyWith(
                      fontSize: 10,
                      color: textTertiary,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),

          // 写入按钮（AppButton primary，全宽）
          SizedBox(
            width: double.infinity,
            child: AppButton(
              label: isWriting
                  ? '写入中...'
                  : (selectedPreset == null
                        ? '请先选择预设'
                        : _writeButtonLabel(selectedPreset)),
              variant: AppButtonVariant.primary,
              icon: isWriting
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiary,
                      ),
                    )
                  : Builder(
                      builder: (context) => BambuIcon(
                        name: 'save',
                        size: 16,
                        color: GlassButtonsTheme.enabledOf(context)
                            ? IconTheme.of(context).color
                            : AppColors.onPrimary,
                        applyColorFilter: true,
                      ),
                    ),
              onPressed: (isWriting || selectedPreset == null) ? null : onWrite,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshPresetSources(WidgetRef ref) async {
    ref.invalidate(bambuStudioPresetsProvider);
    ref.invalidate(bambuCloudFilamentPresetsProvider);
    await ref.read(bambuStudioPresetsProvider.future);
    try {
      await ref.read(bambuCloudFilamentPresetsProvider.future);
    } catch (_) {
      // 下拉框继续展示本地结果，云端错误由卡片内的提示承担。
    }
  }

  String _writeButtonLabel(PresetInfo preset) {
    if (preset.isCloudOnly) return '同步到拓竹云端「${preset.name}」';
    if (preset.isCloudBacked) {
      return '写入「${preset.name}」（本地备份并同步云端）';
    }
    return '写入预设「${preset.name}」（自动备份）';
  }

  /// 桌面端：2 列参数网格（用 Row + Expanded 实现，不用 GridView 避免高度问题）
  Widget _buildDesktopParamsGrid() {
    const fields = kAllPresetFields;
    return Column(
      children: [
        for (int i = 0; i < fields.length; i += 2)
          Padding(
            padding: EdgeInsets.only(bottom: i + 2 < fields.length ? 10 : 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _ParamInputField(
                    field: fields[i],
                    controller: controllers[fields[i].key]!,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: i + 1 < fields.length
                      ? _ParamInputField(
                          field: fields[i + 1],
                          controller: controllers[fields[i + 1].key]!,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 手机端：单列参数列表
  Widget _buildMobileParamsList() {
    return Column(
      children: [
        for (int i = 0; i < kAllPresetFields.length; i++) ...[
          _ParamInputField(
            field: kAllPresetFields[i],
            controller: controllers[kAllPresetFields[i].key]!,
          ),
          if (i < kAllPresetFields.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _PresetSyncNotice extends StatelessWidget {
  const _PresetSyncNotice({
    required this.icon,
    required this.message,
    required this.color,
    this.loading = false,
  });

  final IconData icon;
  final String message;
  final Color color;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          if (loading)
            SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTypography.caption.copyWith(
                color: color,
                fontSize: 10,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetSourcePill extends StatelessWidget {
  const _PresetSourcePill({required this.preset});

  final PresetInfo preset;

  @override
  Widget build(BuildContext context) {
    final label = preset.isCloudOnly
        ? '云端'
        : preset.isCloudBacked
        ? '已同步'
        : '本地';
    final color = preset.isCloudOnly
        ? AppColors.info
        : preset.isCloudBacked
        ? AppColors.success
        : AppColors.textTertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppColors.radiusFull),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 单个参数输入框（AppInput 自带聚焦光环 + 暗色适配）。
class _ParamInputField extends StatelessWidget {
  final PresetField field;
  final TextEditingController controller;

  const _ParamInputField({required this.field, required this.controller});

  @override
  Widget build(BuildContext context) {
    // 标签含单位，如「线宽 (mm)」
    final label = field.unit.isNotEmpty
        ? '${field.label} (${field.unit})'
        : field.label;

    return AppInput(
      label: label,
      hint: field.hint,
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: false,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
      ],
    );
  }
}

/// 备份与回滚卡片。
class _BackupCard extends ConsumerWidget {
  const _BackupCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ref.watch(selectedPresetProvider);
    if (preset == null) return const SizedBox.shrink();
    if (preset.isCloudOnly) {
      return const GlassCard(
        level: GlassLevel.l1,
        padding: EdgeInsets.all(AppSpacing.md),
        child: _PresetSyncNotice(
          icon: Icons.cloud_done_outlined,
          message: '当前目标仅存在于拓竹云端；写入会直接同步云端。本地自动备份将在该预设同步到 BambuStudio 后启用。',
          color: AppColors.info,
        ),
      );
    }

    final backupsAsync = ref.watch(presetBackupsProvider(preset.filePath));
    // 暗色模式适配
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textTertiary = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 16,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '备份与回滚',
                    style: AppTypography.title.copyWith(
                      fontSize: 13,
                      color: textPrimary,
                    ),
                  ),
                ],
              ),
              TextButton.icon(
                onPressed: () =>
                    ref.invalidate(presetBackupsProvider(preset.filePath)),
                icon: BambuIcon(
                  name: 'refresh_normal',
                  size: 14,
                  color: AppColors.primary,
                  applyColorFilter: true,
                ),
                label: Text(
                  '刷新',
                  style: AppTypography.label.copyWith(fontSize: 11),
                ),
                style: glassButtonStyle(
                  context,
                  TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    minimumSize: const Size(40, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  variant: AppGlassButtonVariant.quiet,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '预设：${preset.name}',
            style: AppTypography.caption.copyWith(
              fontSize: 11,
              color: textTertiary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          backupsAsync.when(
            loading: () => const SizedBox(
              height: 24,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text(
              '加载失败: ${friendlyError(e)}',
              style: AppTypography.body.copyWith(
                color: AppColors.danger,
                fontSize: 12,
              ),
            ),
            data: (backups) {
              if (backups.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: EmptyState(
                    icon: Icons.history_rounded,
                    useGlass: true,
                    title: '暂无备份',
                    subtitle: '写入预设后会在此显示备份记录',
                  ),
                );
              }
              return Column(
                children: backups
                    .map(
                      (b) => _BackupItem(
                        backup: b,
                        presetFilePath: preset.filePath,
                        presetName: preset.name,
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 单条备份记录。
class _BackupItem extends ConsumerWidget {
  final BackupInfo backup;
  final String presetFilePath;
  final String presetName;

  const _BackupItem({
    required this.backup,
    required this.presetFilePath,
    required this.presetName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 暗色模式适配
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final textTertiary = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${backup.backupTime.month}-${backup.backupTime.day} '
                  '${backup.backupTime.hour.toString().padLeft(2, '0')}:'
                  '${backup.backupTime.minute.toString().padLeft(2, '0')}',
                  style: AppTypography.data.copyWith(
                    fontSize: 11,
                    color: textTertiary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  backup.fieldName != null
                      ? '备份（${backup.fieldName}）'
                      : '备份时刻的预设快照',
                  style: AppTypography.body.copyWith(
                    fontSize: 12,
                    color: textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // 回滚按钮（AppButton danger 变体）
          AppButton(
            label: '回滚',
            variant: AppButtonVariant.danger,
            onPressed: () async {
              final ok = await AppDialog.confirm(
                context,
                '回滚确认',
                '将预设「$presetName」恢复到此备份（${backup.backupTime.month}-${backup.backupTime.day} '
                    '${backup.backupTime.hour}:${backup.backupTime.minute}）的状态？当前值会被覆盖。',
                destructive: true,
              );
              if (!ok) return;
              try {
                await BambuStudioPresetWriter().restore(
                  backup.backupPath,
                  presetFilePath,
                );
                ref.invalidate(bambuStudioPresetsProvider);
                ref.invalidate(presetBackupsProvider(presetFilePath));
                if (context.mounted) showSnack(context, '已回滚');
              } catch (e) {
                if (context.mounted) {
                  showSnack(context, '回滚失败: ${friendlyError(e)}', error: true);
                }
              }
            },
          ),
        ],
      ),
    );
  }
}
