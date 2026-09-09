import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/services/printer_fleet_connection_manager.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/seed/printer_seed.dart';
import '../../core/utils/printer_image_utils.dart';
import '../../data/database/database.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../providers/database_provider.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/filament_spool_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/icon_action_button.dart';
import '../../widgets/printer_image.dart';
import 'channel_slot.dart';
import 'printer_camera_dialog.dart';

/// 打印机卡片。v5 GlassCard L2，展示打印机信息、通道列表及换料操作。
///
/// 保留 [PrinterImage] 组件渲染打印机图片，右上角删除按钮走
/// [DeleteActionButton]（已内置 bambuIconName: 'delete_filament'）。
class PrinterCard extends ConsumerWidget {
  final PrinterWithChannels data;

  const PrinterCard({super.key, required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final printer = data.printer;
    final status = ref
        .watch(printerFleetConnectionManagerProvider)[data.serial]
        ?.lastStatus;
    final channels = _displayChannelsForPrinter(printer, data.channels, status);
    final externalCount = channels
        .where((item) => isExternalFeedChannel(item.channel.channelIndex))
        .length;
    final systemCount = channels.length - externalCount;
    final channelLabel = externalCount > 0 && systemCount > 0
        ? '$externalCount 外挂 · $systemCount 多色'
        : externalCount > 0
            ? '$externalCount 个外挂料位'
            : '$systemCount 个多色料位';
    final boundCount = channels.where((item) => item.consumable != null).length;
    // 旧记录可能没有 imageAsset，根据 brand+model 从预设查找
    final imageAsset = PrinterImageUtils.resolveAsset(
      imageAsset: printer.imageAsset,
      brand: printer.brand,
      model: printer.model,
    );

    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部：图片 + 型号(粗体) + 品牌 + 通道数标签 + 菜单
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PrinterImage(
                assetPath: imageAsset,
                isCustomImage: printer.isCustomImage,
                brand: printer.brand,
                size: 72,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      printer.name?.isNotEmpty == true
                          ? printer.name!
                          : printer.model,
                      style: AppTypography.title.copyWith(
                        fontSize: 15,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '${printer.brand} ${printer.model}',
                            style: AppTypography.body.copyWith(
                              fontSize: 12,
                              color: isDark
                                  ? AppColors.textSecondaryDark
                                  : AppColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        _InfoChip(channelLabel),
                      ],
                    ),
                  ],
                ),
              ),
              _PrinterCameraAction(data: data),
              const SizedBox(width: AppSpacing.xs),
              _CardMenu(
                printerId: printer.id,
                brand: printer.brand,
                model: printer.model,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Divider(
            color: isDark ? AppColors.dividerDark : AppColors.divider,
            height: 1,
          ),
          const SizedBox(height: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                BambuIcon(
                  name: 'filament',
                  size: 16,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                  applyColorFilter: true,
                ),
                const SizedBox(width: 6),
                Text(
                  '耗材配置',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? AppColors.textPrimaryDark
                        : AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  channels.isEmpty
                      ? '等待设备识别'
                      : '$boundCount / ${channels.length} 已绑定',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (channels.isEmpty)
            const _NoConsumableSlots()
          else if (channels.length <= 4)
            _FeedRows(
              groups: _feedGroups(channels),
              printerId: printer.id,
              printerBrand: printer.brand,
              printerSerial: data.serial,
              externalFeedCount: externalCount,
              totalFeedSlots: channels.length,
            )
          else
            SizedBox(
              height: 292,
              child: Scrollbar(
                thumbVisibility: true,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(0, 2, 4, 12),
                  itemCount: _feedGroups(channels).length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) => _FeedGroupRow(
                    group: _feedGroups(channels)[index],
                    printerId: printer.id,
                    printerBrand: printer.brand,
                    printerSerial: data.serial,
                    externalFeedCount: externalCount,
                    totalFeedSlots: channels.length,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 隐藏由 AMS 接管的供料路径，保存的外挂通道及耗材绑定保持不变。
/// 单喷头不多算外挂；双喷头只保留 AMS 未占用的另一条路径。
List<ChannelWithConsumable> _displayChannelsForPrinter(
  Printer printer,
  List<ChannelWithConsumable> channels,
  BambuPrinterStatus? status,
) {
  final preset =
      PrinterPresets.findByModel(printer.model, brand: printer.brand);
  if (preset == null || !preset.isBambu) return channels;
  final nonExternal = channels
      .where((item) => !isExternalFeedChannel(item.channel.channelIndex))
      .toList(growable: false);
  final detected = detectedAmsState(status);
  final state = detected == AmsDetectionState.unknown &&
          _looksLikeConfiguredAms(nonExternal)
      ? AmsDetectionState.present
      : detected;
  return channels
      .where((item) =>
          !isExternalFeedChannel(item.channel.channelIndex) ||
          externalFeedAvailability(item.channel.channelIndex,
                  externalInputCount: preset.externalInputCount,
                  amsState: state,
                  units: status?.amsUnits) !=
              ExternalFeedAvailability.switchRequired)
      .toList(growable: false);
}

bool _looksLikeConfiguredAms(List<ChannelWithConsumable> channels) {
  if (channels.isEmpty) return false;
  if (channels.length > 1) return true;
  final item = channels.single;
  return item.channel.channelIndex >= 16 ||
      item.channel.label.toUpperCase().contains('AMS');
}

class _FeedGroup {
  final String label;
  final List<ChannelWithConsumable> channels;

  const _FeedGroup(this.label, this.channels);
}

List<_FeedGroup> _feedGroups(List<ChannelWithConsumable> channels) {
  final sorted = [...channels]
    ..sort((a, b) => a.channel.channelIndex.compareTo(b.channel.channelIndex));
  final groups = <_FeedGroup>[];
  final externals = sorted
      .where((item) => isExternalFeedChannel(item.channel.channelIndex))
      .toList();
  if (externals.isNotEmpty) groups.add(_FeedGroup('外挂料位', externals));

  final grouped = <int, List<ChannelWithConsumable>>{};
  for (final item in sorted.where(
    (item) => !isExternalFeedChannel(item.channel.channelIndex),
  )) {
    final index = item.channel.channelIndex;
    // Standard AMS units expose four consecutive global slots. AMS HT uses
    // the 16+ range and is represented as one row per physical unit.
    final key = printerFeedGroupKey(index);
    (grouped[key] ??= <ChannelWithConsumable>[]).add(item);
  }
  final keys = grouped.keys.toList()..sort();
  for (final key in keys) {
    final items = grouped[key]!
      ..sort(
        (a, b) => a.channel.channelIndex.compareTo(b.channel.channelIndex),
      );
    final first = items.first.channel.channelIndex;
    groups.add(
      _FeedGroup(
          first >= 24 && first <= 27
              ? 'AMS Lite'
              : first >= 16
                  ? 'AMS HT'
                  : 'AMS ${first ~/ 4 + 1}',
          items),
    );
  }
  return groups;
}

class _FeedRows extends StatelessWidget {
  final List<_FeedGroup> groups;
  final int printerId;
  final String? printerBrand;
  final String? printerSerial;
  final int externalFeedCount;
  final int totalFeedSlots;

  const _FeedRows({
    required this.groups,
    required this.printerId,
    required this.printerBrand,
    required this.printerSerial,
    required this.externalFeedCount,
    required this.totalFeedSlots,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < groups.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _FeedGroupRow(
              group: groups[i],
              printerId: printerId,
              printerBrand: printerBrand,
              printerSerial: printerSerial,
              externalFeedCount: externalFeedCount,
              totalFeedSlots: totalFeedSlots,
            ),
          ],
        ],
      ),
    );
  }
}

class _FeedGroupRow extends StatelessWidget {
  final _FeedGroup group;
  final int printerId;
  final String? printerBrand;
  final String? printerSerial;
  final int externalFeedCount;
  final int totalFeedSlots;

  const _FeedGroupRow({
    required this.group,
    required this.printerId,
    required this.printerBrand,
    required this.printerSerial,
    required this.externalFeedCount,
    required this.totalFeedSlots,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Container(
                  width: 5,
                  height: 16,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  group.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  '${group.channels.length} 个料位',
                  style:
                      TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              final count = group.channels.length;
              final fixedWidth =
                  count == 1 ? constraints.maxWidth.clamp(0.0, 220.0) : null;
              return SizedBox(
                height: 220,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < count; i++) ...[
                      if (i > 0) const SizedBox(width: gap),
                      if (fixedWidth != null)
                        SizedBox(
                          width: fixedWidth,
                          child: ChannelSlot(
                            data: group.channels[i],
                            printerId: printerId,
                            printerBrand: printerBrand,
                            printerSerial: printerSerial,
                            externalFeedCount: externalFeedCount,
                            totalFeedSlots: totalFeedSlots,
                            horizontal: true,
                          ),
                        )
                      else
                        Expanded(
                          child: ChannelSlot(
                            data: group.channels[i],
                            printerId: printerId,
                            printerBrand: printerBrand,
                            printerSerial: printerSerial,
                            externalFeedCount: externalFeedCount,
                            totalFeedSlots: totalFeedSlots,
                            horizontal: true,
                          ),
                        ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _NoConsumableSlots extends StatelessWidget {
  const _NoConsumableSlots();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 104),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .65)),
      ),
      child: Row(
        children: [
          FilamentSpoolIcon(
            color: scheme.onSurfaceVariant,
            size: 36,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '等待设备识别耗材位',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '连接打印机后，这里会显示每个料位的颜色和库存。',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
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

/// Camera action is attached to the card's own [PrinterWithChannels] record,
/// preventing a preview from accidentally opening another selected printer.
class _PrinterCameraAction extends ConsumerWidget {
  const _PrinterCameraAction({required this.data});

  final PrinterWithChannels data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasSerial = data.serial?.trim().isNotEmpty == true;
    return IconActionButton(
      icon: Icons.videocam_outlined,
      color: AppColors.primary,
      background: isDark
          ? AppColors.primary.withValues(alpha: .16)
          : AppColors.primaryContainer,
      tooltip: hasSerial ? '查看摄像头' : '该打印机没有序列号',
      onTap: hasSerial
          ? () => showPrinterCameraDialog(context, ref, printer: data)
          : null,
    );
  }
}

/// 通道数标签胶囊。极光绿浅底 + 深绿文字。
class _InfoChip extends StatelessWidget {
  final String text;

  const _InfoChip(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: AppTypography.label.copyWith(
          fontWeight: FontWeight.w600,
          color: AppColors.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// 右上角删除按钮：浅红底圆形 + 红色删除图标（DeleteActionButton 已内置
/// bambuIconName: 'delete_filament'，走 IconActionButton v5 体系）。
class _CardMenu extends ConsumerWidget {
  final int printerId;
  final String brand;
  final String model;

  const _CardMenu({
    required this.printerId,
    required this.brand,
    required this.model,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DeleteActionButton(
      onTap: () => _confirmDelete(context, ref),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await AppDialog.confirm(
      context,
      '删除打印机',
      '确认删除「$brand $model」？其下通道绑定也会一并清除，此操作不可撤销。',
      confirmText: '删除',
      destructive: true,
    );
    if (ok) {
      await ref.read(printerDaoProvider).deletePrinter(printerId);
      if (context.mounted) {
        showSnack(context, '已删除「$brand $model」');
      }
    }
  }
}
