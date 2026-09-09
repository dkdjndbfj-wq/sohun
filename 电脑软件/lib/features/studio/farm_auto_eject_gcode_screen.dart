import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/farm_printer_model_profile_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_design.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_ui/farm_feedback.dart';

/// Dedicated per-model automatic part-removal script library.
///
/// The script belongs to a printer model because bed geometry, toolhead travel
/// and safe eject motion are hardware-specific. Saving a script never enables
/// it globally: an operator must opt in for each continuous-production batch.
class FarmAutoEjectGcodeScreen extends ConsumerWidget {
  const FarmAutoEjectGcodeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printers =
        ref.watch(printersWithChannelsProvider).valueOrNull ?? const [];
    final profiles = ref.watch(farmPrinterModelProfilesProvider);
    final canMaintain =
        ref.watch(currentFarmPermissionProvider('printer.maintain'));
    final models = {
      for (final printer in printers) printer.printer.model.trim(),
    }.where((model) => model.isNotEmpty).toList()
      ..sort();
    final configured = models.where((model) {
      final profile = profiles[normalizeFarmPrinterModelKey(model)];
      return profile?.hasAutoEjectScript == true;
    }).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FarmPageHeader(
            title: '自动取件 G-code',
            subtitle: '按打印机型号管理实机验证脚本；仅在批量生产发布时按批次启用。',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _SummaryCard(value: '${models.length}', label: '打印机型号'),
              _SummaryCard(value: '$configured', label: '已保存脚本'),
              _SummaryCard(
                value: '${models.length - configured}',
                label: '等待配置',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: models.isEmpty
                ? const Center(child: Text('先在“设备与耗材”扫描并添加打印机，随后会按型号生成配置卡片。'))
                : GridView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 430,
                      mainAxisExtent: 190,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: models.length,
                    itemBuilder: (context, index) {
                      final model = models[index];
                      final key = normalizeFarmPrinterModelKey(model);
                      final profile = profiles[key] ??
                          FarmPrinterModelProfile(
                            modelKey: key,
                            displayName: model,
                          );
                      return _ModelGcodeCard(
                        model: model,
                        profile: profile,
                        enabled: canMaintain,
                        onEdit: () => _showEditor(context, ref, profile),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        width: 180,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(FarmPalette.radius),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
}

class _ModelGcodeCard extends StatelessWidget {
  const _ModelGcodeCard({
    required this.model,
    required this.profile,
    required this.enabled,
    required this.onEdit,
  });

  final String model;
  final FarmPrinterModelProfile profile;
  final bool enabled;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = profile.hasAutoEjectScript;
    final lines = profile.autoEjectGcode
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .length;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        side: BorderSide(
          color: active
              ? FarmVisual.primary.withValues(alpha: .4)
              : scheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.cleaning_services_outlined,
                  color: active ? FarmVisual.primary : scheme.outline,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    model,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Chip(label: Text(active ? '脚本已保存' : '未配置')),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              active
                  ? '$lines 行脚本 · 喷嘴 ${profile.nozzleDiameter.toStringAsFixed(1)} mm'
                  : '尚未保存该机型的自动取件脚本；订单默认人工取件。',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: enabled ? onEdit : null,
                icon: const Icon(Icons.code_rounded, size: 17),
                label: Text(active ? '编辑脚本' : '配置脚本'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showEditor(
  BuildContext context,
  WidgetRef ref,
  FarmPrinterModelProfile profile,
) async {
  final controller = TextEditingController(text: profile.autoEjectGcode);
  final save = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text('${profile.displayName} · 自动取件 G-code'),
      content: SizedBox(
        width: 760,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '保存的是该机型的脚本模板。保存不等于启用，普通订单仍然人工取件；'
              '进入“批量连续生产”页面发布这个文件时，需要为该批次主动选择。',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              minLines: 14,
              maxLines: 22,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '; 输入经过同型号打印机实机验证的清件脚本',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请只保存已在同型号、同喷嘴设备上实机验证的脚本。清空内容并保存即可移除脚本。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (save == true && context.mounted) {
    if (controller.text.length > 64 * 1024) {
      showSnack(context, 'G-code 不能超过 64 KB', error: true);
    } else {
      await ref.read(farmPrinterModelProfilesProvider.notifier).save(
            FarmPrinterModelProfile(
              modelKey: profile.modelKey,
              displayName: profile.displayName,
              machineSettingsPath: profile.machineSettingsPath,
              processSettingsPath: profile.processSettingsPath,
              filamentSettingsPaths: profile.filamentSettingsPaths,
              nozzleDiameter: profile.nozzleDiameter,
              autoEjectEnabled: false,
              autoEjectGcode: controller.text
                  .replaceAll('\r\n', '\n')
                  .replaceAll('\r', '\n')
                  .trim(),
            ),
          );
      await recordCurrentFarmActivity(
        ref,
        actionCode: 'auto_eject_gcode.updated',
        entityType: 'printer_model',
        entityId: profile.modelKey,
        summary: controller.text.trim().isEmpty
            ? '移除 ${profile.displayName} 的自动取件脚本模板'
            : '保存 ${profile.displayName} 的自动取件脚本模板',
      );
      if (context.mounted) {
        showSnack(
          context,
          controller.text.trim().isEmpty
              ? '${profile.displayName} 的脚本已移除'
              : '${profile.displayName} 的脚本模板已保存，排产时仍需单独确认',
        );
      }
    }
  }
  controller.dispose();
}
