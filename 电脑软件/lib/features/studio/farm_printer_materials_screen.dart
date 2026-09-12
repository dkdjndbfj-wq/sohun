import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/printer_fleet_connection_manager.dart';
import '../../core/services/studio_video_relay_service.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/filament_model_code.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/database.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../data/database/models/studio_models.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_connector.dart';
import '../../data/seed/printer_seed.dart';
import '../../providers/database_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/studio_provider.dart';
import '../../providers/farm_consumable_metadata_provider.dart';
import 'farm_ui/farm_design.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_bambu_cloud_login_dialog.dart';
import 'farm_inventory_stock.dart';
import 'farm_lan_bulk_import_dialog.dart';
import 'farm_printer_camera_dialog.dart';

/// Farm-only material routing view.
///
/// A farm cannot safely dispatch a job by looking at a printer name alone:
/// every AMS/external slot must point at a physical farm spool. This page puts
/// that relationship in one place and deliberately reads [farmConsumablesProvider]
/// instead of the personal inventory provider.
class FarmPrinterMaterialsScreen extends ConsumerWidget {
  const FarmPrinterMaterialsScreen({
    super.key,
    this.allowGuestEnrollment = false,
  });

  final bool allowGuestEnrollment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printers = ref.watch(printersWithChannelsProvider);
    final stock = ref.watch(farmConsumablesProvider);
    final fleet = ref.watch(fleetPrinterStatesProvider);
    final relay = ref.watch(studioVideoRelayControllerProvider);
    final connections = ref.watch(mergedPrinterListProvider);
    final connectionBySerial = {
      for (final connection in connections) connection.serial: connection,
    };
    final canMaintain =
        ref.watch(currentFarmPermissionProvider('printer.maintain'));
    final canEnroll = allowGuestEnrollment || canMaintain;
    final studio = ref.watch(studioSnapshotProvider).valueOrNull;
    final stockItems = stock.valueOrNull ?? const [];
    final states = {for (final item in fleet) item.serial: item};

    return _FarmMaterialsPage(
      title: '设备与耗材',
      subtitle: '集中查看每台打印机的实时进度和 AMS/外挂耗材余量。普通用户库存不会出现在这里。',
      actions: [
        FilledButton.icon(
          onPressed: canEnroll
              ? () => showFarmLanBulkImportDialog(context, ref)
              : null,
          icon: const Icon(Icons.radar_outlined, size: 17),
          label: const Text('局域网绑定'),
        ),
        OutlinedButton.icon(
          onPressed: canEnroll
              ? () => showFarmBambuCloudLoginDialog(context, ref)
              : null,
          icon: const Icon(Icons.account_circle_outlined, size: 17),
          label: const Text('拓竹账号'),
        ),
        OutlinedButton.icon(
          onPressed: () => ref
              .read(printerFleetConnectionManagerProvider.notifier)
              .monitorAllConfigured(),
          icon: const Icon(Icons.refresh_rounded, size: 17),
          label: const Text('刷新连接'),
        ),
      ],
      child: printers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('设备读取失败：$error')),
        data: (items) {
          if (items.isEmpty) {
            return const _FarmMaterialsEmpty(
              icon: Icons.precision_manufacturing_outlined,
              text: '还没有登记打印机，点击“扫描并批量添加”发现设备。',
            );
          }
          var totalSlots = 0;
          var boundSlots = 0;
          for (final item in items) {
            final state = item.serial == null ? null : states[item.serial];
            final layout = _farmFeedLayout(item, state?.lastStatus);
            final visible = [...layout.ams, ...layout.external];
            totalSlots += visible.length;
            boundSlots +=
                visible.where((slot) => slot.consumable != null).length;
          }
          return Column(
            children: [
              _FarmMaterialsSummary(
                items: [
                  ('打印机', '${items.length}'),
                  ('供料槽位', '$boundSlots / $totalSlots'),
                  (
                    '仓库库存',
                    '${stockItems.fold<int>(
                      0,
                      (sum, item) =>
                          sum + farmUsableRollCount(item.remainingGrams),
                    )} 卷'
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 360,
                    mainAxisExtent: 190,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final state =
                        item.serial == null ? null : states[item.serial];
                    return _FarmPrinterMaterialCard(
                      item: item,
                      state: state,
                      stock: stockItems,
                      canMaintain: canMaintain,
                      cameraInUse: item.serial != null &&
                          relay.activePrinterSerials.contains(item.serial),
                      connectionMode: connectionBySerial[item.serial]?.mode,
                      activity: studio?.latestActivityFor(
                        'printer',
                        '${item.printer.id}',
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

Future<void> showFarmPrinterSlotEditor(
  BuildContext context, {
  required PrinterWithChannels printer,
  required FleetPrinterState? state,
  required List<Consumable> stock,
  required bool canMaintain,
}) async {
  final layout = _farmFeedLayout(printer, state?.lastStatus);
  final amsConfigurable = layout.amsState == AmsDetectionState.present;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${printer.printer.name ?? printer.printer.model} · 设置耗材'),
      content: SizedBox(
        width: 820,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (layout.amsState != AmsDetectionState.absent) ...[
                _FarmFeedSection(
                  title: 'AMS 槽位',
                  description: amsConfigurable
                      ? '${layout.amsSummary} · 新卷装入即为 1000g'
                      : '等待设备上线并识别 AMS 型号后才能配置',
                  icon: Icons.grid_view_rounded,
                  slots: layout.ams,
                  canMaintain: canMaintain && amsConfigurable,
                  stock: stock,
                  legacySingleExternal: layout.legacySingleExternal,
                ),
                const SizedBox(height: 12),
              ],
              _FarmFeedSection(
                title: '外挂料位',
                description: '装入新卷即为 1000g；设备报无料时自动清空',
                icon: Icons.cable_rounded,
                slots: layout.external,
                canMaintain: canMaintain,
                stock: stock,
                legacySingleExternal: layout.legacySingleExternal,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    ),
  );
}

class _FarmFeedLayout {
  const _FarmFeedLayout({
    required this.ams,
    required this.external,
    required this.legacySingleExternal,
    required this.amsState,
    required this.amsSummary,
  });

  final List<ChannelWithConsumable> ams;
  final List<ChannelWithConsumable> external;
  final bool legacySingleExternal;
  final AmsDetectionState amsState;
  final String amsSummary;
}

_FarmFeedLayout _farmFeedLayout(
  PrinterWithChannels printer,
  BambuPrinterStatus? status,
) {
  final amsState = detectedAmsState(status);
  final preset = PrinterPresets.findByModel(
    printer.printer.model,
    brand: printer.printer.brand,
  );
  final explicitExternal = printer.channels.any(
    (slot) =>
        slot.channel.channelIndex < 0 ||
        isExternalFeedChannel(slot.channel.channelIndex),
  );
  final legacySingleExternal = amsState != AmsDetectionState.present &&
      !explicitExternal &&
      printer.channels.length == 1 &&
      (preset == null || preset.maxAmsCount == 0);
  final external = printer.channels
      .where(
        (slot) =>
            slot.channel.channelIndex < 0 ||
            isExternalFeedChannel(slot.channel.channelIndex) ||
            (legacySingleExternal && slot.channel.channelIndex == 0),
      )
      .toList(growable: false);
  final storedAms = printer.channels
      .where((slot) => !external.contains(slot))
      .toList(growable: false);
  return _FarmFeedLayout(
    ams: amsState == AmsDetectionState.absent
        ? const <ChannelWithConsumable>[]
        : storedAms,
    external: external,
    legacySingleExternal: legacySingleExternal,
    amsState: amsState,
    amsSummary: detectedAmsSummary(status),
  );
}

class _FarmAmsSlotIdentity {
  const _FarmAmsSlotIdentity({
    required this.unitOrdinal,
    required this.slotOrdinal,
    required this.type,
  });

  final int unitOrdinal;
  final int slotOrdinal;
  final AmsUnitType type;
}

_FarmAmsSlotIdentity _farmAmsSlotIdentity(
  ChannelWithConsumable slot,
  BambuPrinterStatus? status,
) {
  final savedMatch = RegExp(
    r'^第\s*(\d+)\s*台\s*(.+?)\s*·\s*第\s*(\d+)\s*通道$',
  ).firstMatch(slot.channel.label.trim());
  if (savedMatch != null) {
    return _FarmAmsSlotIdentity(
      unitOrdinal: int.tryParse(savedMatch.group(1) ?? '') ?? 1,
      slotOrdinal: int.tryParse(savedMatch.group(3) ?? '') ?? 1,
      type: _farmAmsTypeFromName(savedMatch.group(2) ?? ''),
    );
  }

  final trays = status?.amsTrays ?? const <AmsTray>[];
  AmsTray? liveTray;
  for (final tray in trays) {
    if (tray.globalSlot == slot.channel.channelIndex) {
      liveTray = tray;
      break;
    }
  }
  if (liveTray != null) {
    final units = (status?.amsUnits ?? const <AmsUnit>[])
        .where((unit) => unit.isPresent)
        .toList(growable: false);
    final unitIndex = units.indexWhere((unit) => unit.id == liveTray!.amsId);
    if (unitIndex >= 0) {
      final unit = units[unitIndex];
      return _FarmAmsSlotIdentity(
        unitOrdinal: unitIndex + 1,
        slotOrdinal: liveTray.slot + 1,
        type: unit.type == AmsUnitType.unknown
            ? (status?.amsModuleTypes?[unit.id] ?? AmsUnitType.unknown)
            : unit.type,
      );
    }
  }

  final channelIndex = slot.channel.channelIndex;
  if (channelIndex >= 24 && channelIndex <= 27) {
    return _FarmAmsSlotIdentity(
        unitOrdinal: 1,
        slotOrdinal: channelIndex - 23,
        type: AmsUnitType.amsLite);
  }
  if (channelIndex >= 16 && channelIndex <= 23) {
    return _FarmAmsSlotIdentity(
      unitOrdinal: channelIndex - 15,
      slotOrdinal: 1,
      type: AmsUnitType.amsHt,
    );
  }
  return _FarmAmsSlotIdentity(
    unitOrdinal: channelIndex ~/ 4 + 1,
    slotOrdinal: channelIndex % 4 + 1,
    type: AmsUnitType.unknown,
  );
}

AmsUnitType _farmAmsTypeFromName(String raw) {
  final normalized = raw.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (normalized.contains('2pro')) return AmsUnitType.ams2Pro;
  if (normalized.contains('lite')) return AmsUnitType.amsLite;
  if (normalized.contains('ht')) return AmsUnitType.amsHt;
  if (normalized.contains('ams1')) return AmsUnitType.ams;
  return AmsUnitType.unknown;
}

String _farmAmsTypeBadge(AmsUnitType type) => switch (type) {
      AmsUnitType.ams => '①',
      AmsUnitType.ams2Pro => '②',
      AmsUnitType.amsHt => 'HT',
      AmsUnitType.amsLite => 'Lite',
      AmsUnitType.unknown => 'AMS',
    };

class _FarmMaterialsPage extends StatelessWidget {
  const _FarmMaterialsPage({
    required this.title,
    required this.subtitle,
    required this.child,
    this.actions = const [],
  });

  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FarmPageHeader(
            title: title,
            subtitle: subtitle,
            actions: actions,
          ),
          const SizedBox(height: 16),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _FarmMaterialsSummary extends StatelessWidget {
  const _FarmMaterialsSummary({required this.items});
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final item in items)
            Container(
              width: 148,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(FarmPalette.radius),
                border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.$2,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(item.$1, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _FarmPrinterMaterialCard extends ConsumerWidget {
  const _FarmPrinterMaterialCard({
    required this.item,
    required this.state,
    required this.stock,
    required this.canMaintain,
    required this.cameraInUse,
    required this.connectionMode,
    this.activity,
  });

  final PrinterWithChannels item;
  final FleetPrinterState? state;
  final List<Consumable> stock;
  final bool canMaintain;
  final bool cameraInUse;
  final BambuConnectionMode? connectionMode;
  final StudioActivityEvent? activity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final layout = _farmFeedLayout(item, state?.lastStatus);
    final externalSlots = layout.external;
    final amsSlots = layout.ams;
    final cardSlots = [...amsSlots, ...externalSlots];
    return Card(
      key: ValueKey(
        'farm-printer-card-${item.serial ?? item.printer.id}',
      ),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        side: BorderSide(
          color: state?.connectionState == PrinterConnectionState.connected
              ? FarmVisual.primary.withValues(alpha: .35)
              : scheme.outlineVariant,
        ),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 300;
                    final identity = Row(
                      children: [
                        Icon(
                          Icons.precision_manufacturing_outlined,
                          color: scheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    item.printer.name?.trim().isNotEmpty == true
                                        ? item.printer.name!
                                        : item.printer.model,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800)),
                                Text(
                                    '${item.printer.brand} · ${item.printer.model}${item.serial == null ? '' : ' · ${item.serial}'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                                if (activity != null && !narrow)
                                  Text(
                                    '${activity!.actorDisplayName} · '
                                    '${_farmActivityTime(activity!.createdAt)} · '
                                    '${activity!.summary}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                              ]),
                        ),
                      ],
                    );
                    return Row(
                      children: [
                        Expanded(child: identity),
                        const SizedBox(width: 9),
                        _FarmPrinterProgress(state: state),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 1),
                SizedBox(
                  height: 112,
                  child: cardSlots.isEmpty
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '等待识别供料槽位',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : _FarmMaterialSlotRail(
                          slots: cardSlots,
                          status: state?.lastStatus,
                          legacySingleExternal: layout.legacySingleExternal,
                          onTap: !canMaintain
                              ? null
                              : () => showFarmPrinterSlotEditor(
                                    context,
                                    printer: item,
                                    state: state,
                                    stock: stock,
                                    canMaintain: canMaintain,
                                  ),
                        ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: _FarmCameraViewerDot(
              inUse: cameraInUse,
              serial: item.serial,
              onTap: () => showFarmPrinterCameraDialog(
                context,
                ref,
                printer: item,
                state: state,
              ),
            ),
          ),
          if (connectionMode != null)
            Positioned(
              right: 8,
              bottom: 7,
              child: _FarmConnectionModeBadge(mode: connectionMode!),
            ),
        ],
      ),
    );
  }
}

class _FarmConnectionModeBadge extends StatelessWidget {
  const _FarmConnectionModeBadge({required this.mode});

  final BambuConnectionMode mode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cloud = mode == BambuConnectionMode.cloud;
    return IgnorePointer(
      child: Container(
        key: ValueKey('farm-printer-connection-${mode.name}'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: .94),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: .08),
              blurRadius: 4,
            ),
          ],
        ),
        child: Text(
          cloud ? '云端' : '局域网',
          style: TextStyle(
            color: cloud ? scheme.primary : scheme.onSurfaceVariant,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

class _FarmPrinterProgress extends StatelessWidget {
  const _FarmPrinterProgress({required this.state});

  final FleetPrinterState? state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = state?.lastStatus;
    final connected =
        state?.connectionState == PrinterConnectionState.connected;
    final gcodeState = status?.gcodeState;
    final progress = (status?.mcPercent ?? 0).clamp(0, 100);
    final label = !connected ? '离线' : (gcodeState?.label ?? '等待状态');
    final detailParts = <String>[
      if (status?.mcRemainingTime case final minutes?) '剩余 $minutes 分钟',
      if (status?.currLayer case final layer?)
        status?.totalLayers == null
            ? '第 $layer 层'
            : '$layer / ${status!.totalLayers} 层',
    ];
    final active = gcodeState == BambuGcodeState.running ||
        gcodeState == BambuGcodeState.pause ||
        gcodeState == BambuGcodeState.init ||
        gcodeState == BambuGcodeState.prepare;
    final color = !connected
        ? scheme.outline
        : active
            ? FarmVisual.warning
            : FarmVisual.primary;

    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '$progress%',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          LinearProgressIndicator(
            value: progress / 100,
            minHeight: 6,
            color: color,
            backgroundColor: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 5),
          Text(
            detailParts.isEmpty ? '当前没有打印任务' : detailParts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 9.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _FarmCameraViewerDot extends StatelessWidget {
  const _FarmCameraViewerDot({
    required this.inUse,
    required this.serial,
    required this.onTap,
  });

  final bool inUse;
  final String? serial;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = inUse ? const Color(0xFFE5484D) : const Color(0xFF19B34A);
    return Tooltip(
      message: inUse ? '客户正在查看 · 点击打开实时画面' : '点击打开实时画面',
      child: Semantics(
        button: true,
        label: inUse ? '摄像头正在被客户查看，点击打开实时画面' : '点击打开摄像头实时画面',
        child: InkResponse(
          key: ValueKey('farm-camera-preview-trigger-${serial ?? 'unknown'}'),
          onTap: onTap,
          radius: 14,
          containedInkWell: true,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: 28,
            child: Center(
              child: AnimatedContainer(
                key: ValueKey(
                  'farm-camera-viewer-${serial ?? 'unknown'}-${inUse ? 'active' : 'idle'}',
                ),
                duration: const Duration(milliseconds: 180),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: .35),
                      blurRadius: 4,
                      spreadRadius: 1,
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
}

class _FarmGroupedSlot {
  const _FarmGroupedSlot(this.slot, this.identity);

  final ChannelWithConsumable slot;
  final _FarmAmsSlotIdentity? identity;
}

class _FarmSlotGroup {
  _FarmSlotGroup({
    required this.unitOrdinal,
    required this.type,
    required this.isExternal,
  });

  final int unitOrdinal;
  final AmsUnitType type;
  final bool isExternal;
  final List<_FarmGroupedSlot> slots = [];
}

class _FarmMaterialSlotRail extends StatefulWidget {
  const _FarmMaterialSlotRail({
    required this.slots,
    required this.status,
    required this.legacySingleExternal,
    required this.onTap,
  });

  final List<ChannelWithConsumable> slots;
  final BambuPrinterStatus? status;
  final bool legacySingleExternal;
  final VoidCallback? onTap;

  @override
  State<_FarmMaterialSlotRail> createState() => _FarmMaterialSlotRailState();
}

class _FarmMaterialSlotRailState extends State<_FarmMaterialSlotRail> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amsGroups = <int, _FarmSlotGroup>{};
    final externalSlots = <_FarmGroupedSlot>[];
    for (final slot in widget.slots) {
      final channelIndex = slot.channel.channelIndex;
      final external = isExternalFeedChannel(channelIndex) ||
          (widget.legacySingleExternal && channelIndex == 0);
      if (external) {
        externalSlots.add(_FarmGroupedSlot(slot, null));
        continue;
      }
      final identity = _farmAmsSlotIdentity(slot, widget.status);
      final group = amsGroups.putIfAbsent(
        identity.unitOrdinal,
        () => _FarmSlotGroup(
          unitOrdinal: identity.unitOrdinal,
          type: identity.type,
          isExternal: false,
        ),
      );
      group.slots.add(_FarmGroupedSlot(slot, identity));
    }

    final groups = amsGroups.values.toList(growable: true)
      ..sort((a, b) => a.unitOrdinal.compareTo(b.unitOrdinal));
    for (final group in groups) {
      group.slots.sort(
        (a, b) => a.identity!.slotOrdinal.compareTo(b.identity!.slotOrdinal),
      );
    }
    if (externalSlots.isNotEmpty) {
      groups.add(
        _FarmSlotGroup(
          unitOrdinal: groups.length + 1,
          type: AmsUnitType.unknown,
          isExternal: true,
        )..slots.addAll(externalSlots),
      );
    }
    final physicalAmsGroups = groups.where((group) => !group.isExternal);
    final showTypeBadges =
        physicalAmsGroups.map((group) => group.type).toSet().length > 1;
    final scrollable = groups.length > 1;

    return LayoutBuilder(
      builder: (context, constraints) => Scrollbar(
        controller: _controller,
        thumbVisibility: scrollable,
        interactive: true,
        thickness: 5,
        radius: const Radius.circular(3),
        scrollbarOrientation: ScrollbarOrientation.bottom,
        child: ListView.separated(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.only(bottom: scrollable ? 8 : 0),
          itemCount: groups.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) => SizedBox(
            width: constraints.maxWidth,
            child: _FarmSlotGroupPage(
              group: groups[index],
              showTypeBadge: showTypeBadges,
              legacySingleExternal: widget.legacySingleExternal,
              onTap: widget.onTap,
            ),
          ),
        ),
      ),
    );
  }
}

class _FarmSlotGroupPage extends ConsumerWidget {
  const _FarmSlotGroupPage({
    required this.group,
    required this.showTypeBadge,
    required this.legacySingleExternal,
    required this.onTap,
  });

  final _FarmSlotGroup group;
  final bool showTypeBadge;
  final bool legacySingleExternal;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final metadata =
        ref.watch(farmConsumableMetadataProvider).valueOrNull ?? const {};
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 6.0;
        final slotWidth = (constraints.maxWidth - gap * 3) / 4;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!group.isExternal)
              SizedBox(
                height: 17,
                child: Row(
                  children: [
                    Text(
                      'AMS ${group.unitOrdinal}',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (!group.isExternal && showTypeBadge) ...[
                      const SizedBox(width: 5),
                      Tooltip(
                        message: group.type.displayLabel,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: Text(
                            _farmAmsTypeBadge(group.type),
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            SizedBox(height: group.isExternal ? 0 : 2),
            Row(
              children: [
                for (var index = 0; index < group.slots.length; index++) ...[
                  if (index > 0) const SizedBox(width: gap),
                  SizedBox(
                    width: slotWidth,
                    height: 84,
                    child: _FarmMaterialSlotBox(
                      slot: group.slots[index].slot,
                      metadata:
                          metadata[group.slots[index].slot.consumable?.id],
                      displayLabel: group.isExternal
                          ? printerFeedChannelLabel(
                              group.slots[index].slot.channel.channelIndex,
                              storedLabel:
                                  group.slots[index].slot.channel.label,
                              compact: true,
                              legacySingleExternal: legacySingleExternal,
                            )
                          : '${group.slots[index].identity!.slotOrdinal}槽',
                      onTap: onTap,
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

class _FarmMaterialSlotBox extends StatelessWidget {
  const _FarmMaterialSlotBox({
    required this.slot,
    required this.displayLabel,
    required this.onTap,
    this.metadata,
  });

  final ChannelWithConsumable slot;
  final String displayLabel;
  final VoidCallback? onTap;
  final FarmConsumableMetadata? metadata;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = slot.consumable;
    final configured = item != null && slot.channel.loadedRemainingGrams > 0;
    final body = Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            children: [
              Text(
                displayLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9.5,
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Container(
                width: 20,
                height: 20,
                decoration: configured && metadata?.hasMultipleColors == true
                    ? BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            ColorUtils.fromHex(item.colorHex),
                            ColorUtils.fromHex(metadata!.secondaryColorHex!),
                          ],
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.outlineVariant),
                      )
                    : BoxDecoration(
                        color: configured
                            ? ColorUtils.fromHex(item.colorHex)
                            : scheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                child: configured
                    ? null
                    : Icon(
                        Icons.add_rounded,
                        size: 13,
                        color: scheme.onSurfaceVariant,
                      ),
              ),
              const SizedBox(height: 3),
              Text(
                configured
                    ? FilamentModelCode.of(
                        model: item.model,
                        materialType: item.materialType,
                      )
                    : '配置耗材',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                item == null
                    ? '剩余—g'
                    : slot.farmRollPaused
                        ? '暂存${slot.channel.loadedRemainingGrams.toStringAsFixed(0)}g'
                        : '剩余${slot.channel.loadedRemainingGrams.toStringAsFixed(0)}g',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 8.5,
                  color: slot.farmRollPaused
                      ? scheme.error
                      : configured
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (item == null) return body;
    return Tooltip(
      message: FilamentModelCode.description(
        manufacturer: item.manufacturer,
        model: item.model,
        materialType: item.materialType,
      ),
      child: body,
    );
  }
}

class _FarmFeedSection extends StatelessWidget {
  const _FarmFeedSection({
    required this.title,
    required this.description,
    required this.icon,
    required this.slots,
    required this.canMaintain,
    required this.stock,
    required this.legacySingleExternal,
  });

  final String title;
  final String description;
  final IconData icon;
  final List<ChannelWithConsumable> slots;
  final bool canMaintain;
  final List<Consumable> stock;
  final bool legacySingleExternal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Icon(icon, size: 17, color: scheme.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Text('${slots.length} 槽',
                    style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                Text(description, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (slots.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Text(
                title == 'AMS 槽位' ? '此设备尚未配置 AMS 槽位' : '此设备尚未配置外挂料位',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          else
            for (var index = 0; index < slots.length; index++) ...[
              if (index > 0) const Divider(height: 1),
              _FarmSlotRow(
                slot: slots[index],
                canMaintain: canMaintain,
                stock: stock,
                legacySingleExternal: legacySingleExternal,
              ),
            ],
        ],
      ),
    );
  }
}

class _FarmSlotRow extends ConsumerWidget {
  const _FarmSlotRow({
    required this.slot,
    required this.canMaintain,
    required this.stock,
    required this.legacySingleExternal,
  });
  final ChannelWithConsumable slot;
  final bool canMaintain;
  final List<Consumable> stock;
  final bool legacySingleExternal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final consumable = slot.consumable;
    final metadata = consumable == null
        ? null
        : ref.watch(farmConsumableMetadataProvider).valueOrNull?[consumable.id];
    final belongsToFarm =
        consumable != null && stock.any((item) => item.id == consumable.id);
    final color = consumable == null
        ? Theme.of(context).colorScheme.outline
        : ColorUtils.fromHex(consumable.colorHex);
    final displayLabel = printerFeedChannelLabel(
      slot.channel.channelIndex,
      storedLabel: slot.channel.label,
      legacySingleExternal: legacySingleExternal,
    );
    final canReplace = !slot.farmRollPaused &&
        (consumable == null ||
            slot.channel.loadedRemainingGrams <= 0 ||
            !belongsToFarm);
    final label = consumable == null
        ? '未绑定农场耗材'
        : !belongsToFarm
            ? '已绑定普通用户库存，农场任务禁止使用，请替换'
            : slot.farmRollPaused
                ? '维修暂存 · ${consumable.colorName ?? consumable.colorHex} · '
                    '保留 ${slot.channel.loadedRemainingGrams.toStringAsFixed(0)}g'
                : '${consumable.colorName?.trim().isNotEmpty == true ? consumable.colorName : consumable.colorHex} · ${consumable.materialType} · ${slot.channel.loadedRemainingGrams.toStringAsFixed(0)}g';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          Container(
            width: 16,
            height: 16,
            decoration:
                metadata?.hasMultipleColors == true && consumable != null
                    ? BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            color,
                            ColorUtils.fromHex(metadata!.secondaryColorHex!),
                          ],
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      )
                    : BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
          ),
          const SizedBox(width: 9),
          SizedBox(
              width: 120,
              child: Text(displayLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: !belongsToFarm && consumable != null
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            ),
          ),
          if (consumable != null &&
              belongsToFarm &&
              !canReplace &&
              !slot.farmRollPaused)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '已装机 · 耗尽后更换',
                style: TextStyle(fontSize: 11, color: FarmVisual.primary),
              ),
            ),
          if (canMaintain && slot.farmRollPaused)
            TextButton.icon(
              onPressed: () => _resumeAfterMaintenance(context, ref),
              icon: const Icon(Icons.build_circle_outlined, size: 16),
              label: const Text('维修完成，继续使用'),
            ),
          if (canMaintain &&
              consumable != null &&
              belongsToFarm &&
              !canReplace &&
              !slot.farmRollPaused)
            IconButton(
              tooltip: '堵头/维修，临时取下耗材',
              onPressed: () => _pauseForMaintenance(context, ref),
              icon: const Icon(Icons.build_outlined, size: 18),
            ),
          if (canMaintain && canReplace)
            TextButton.icon(
              onPressed: () => _pick(context, ref),
              icon: Icon(consumable == null ? Icons.add_link : Icons.swap_horiz,
                  size: 16),
              label: Text(consumable == null ? '装入' : '更换空卷'),
            ),
          if (canMaintain && consumable != null && canReplace)
            IconButton(
              tooltip: '取下空卷',
              onPressed: () async {
                await ref
                    .read(printerDaoProvider)
                    .unbindChannel(slot.channel.id);
                await _recordSlotActivity(ref, '$displayLabel 取下空卷');
                if (context.mounted) {
                  showSnack(context, '已从 $displayLabel 取下空卷');
                }
              },
              icon: const Icon(Icons.link_off_outlined, size: 18),
            ),
        ],
      ),
    );
  }

  Future<void> _pauseForMaintenance(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final displayLabel = printerFeedChannelLabel(
      slot.channel.channelIndex,
      storedLabel: slot.channel.label,
      legacySingleExternal: legacySingleExternal,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('是否因堵头或维修临时取下？'),
        content: Text(
          '确认后会把这卷耗材标记为“维修暂存”，保留当前 '
          '${slot.channel.loadedRemainingGrams.toStringAsFixed(0)}g。\n\n'
          '不会再次扣仓库，也不会按耗尽处理；维修期间该槽位不能排产，重新装回后会从原克数继续计算。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.build_outlined, size: 17),
            label: const Text('确认维修暂存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref
          .read(printerDaoProvider)
          .pauseFarmChannelRollForMaintenance(slot.channel.id);
      await _recordSlotActivity(ref, '$displayLabel 维修暂存');
      if (context.mounted) {
        showSnack(context, '已保留当前克数；维修完成后点击“继续使用”');
      }
    } catch (error) {
      if (context.mounted) showSnack(context, '$error', error: true);
    }
  }

  Future<void> _resumeAfterMaintenance(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final displayLabel = printerFeedChannelLabel(
      slot.channel.channelIndex,
      storedLabel: slot.channel.label,
      legacySingleExternal: legacySingleExternal,
    );
    await ref.read(printerDaoProvider).resumeFarmChannelRoll(slot.channel.id);
    await _recordSlotActivity(ref, '$displayLabel 维修完成并继续使用');
    if (context.mounted) {
      showSnack(
        context,
        '已重新装回，从 ${slot.channel.loadedRemainingGrams.toStringAsFixed(0)}g 继续计算',
      );
    }
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final displayLabel = printerFeedChannelLabel(
      slot.channel.channelIndex,
      storedLabel: slot.channel.label,
      legacySingleExternal: legacySingleExternal,
    );
    final available = groupFarmWarehouseMaterials(stock)
        // Manual enrollment consumes one fresh 1000g roll. A SKU may still
        // have only a retained partial remainder (counted for inventory
        // visibility), but it is not a valid candidate for this flow.
        .where((group) => group.nextWholeRoll != null)
        .toList(growable: false);
    if (available.isEmpty) {
      showSnack(context, '农场库存没有可绑定的耗材，请先入库。', error: true);
      return;
    }
    final selected = await showDialog<Consumable>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${slot.channel.label} · 手动确认耗材'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '拓竹官方料识别到 RFID 后会自动扣库，不需要手动选择。这里只处理第三方料或 RFID 未识别的情况。',
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.separated(
                  itemCount: available.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final group = available[index];
                    final item = group.representative;
                    final backingItem = group.nextWholeRoll!;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: ColorUtils.fromHex(item.colorHex),
                        radius: 13,
                      ),
                      title: Text(
                        '${item.manufacturer} · ${item.colorName?.trim().isNotEmpty == true ? item.colorName : item.colorHex}',
                      ),
                      subtitle: Text(
                        '${item.materialType} · ${item.model} · '
                        '仓库 ${group.availableRolls} 卷'
                        '${group.batchCount > 1 ? ' · ${group.batchCount} 个批次' : ''}',
                      ),
                      onTap: () => Navigator.pop(context, backingItem),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消'))
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('未检测到 RFID，确认扣库？'),
        content: Text(
          '确认 ${selected.manufacturer} · ${selected.materialType} · '
          '${selected.colorName ?? selected.colorHex} 就是刚装入的耗材？\n\n'
          '确认后仓库扣除 1 卷，该槽位建立独立 1000g 余额；之后打印只扣槽位克数。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回检查'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认耗材并扣 1 卷'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(printerDaoProvider).changeRoll(
            channelId: slot.channel.id,
            newConsumableId: selected.id,
            farmLoadAuthorization: FarmRollLoadAuthorization.farmOwnerConfirmed,
          );
      await _recordSlotActivity(
        ref,
        '$displayLabel 装入 ${selected.manufacturer} ${selected.materialType}',
      );
      if (context.mounted) {
        showSnack(
          context,
          '已装入 ${selected.colorName ?? selected.colorHex} · 槽内 1000g',
        );
      }
    } catch (error) {
      if (context.mounted) showSnack(context, '绑定失败：$error', error: true);
    }
  }

  Future<void> _recordSlotActivity(WidgetRef ref, String summary) async {
    final studio = await ref.read(studioSnapshotProvider.future);
    await ref.read(studioDaoProvider).recordActivity(
          workspaceId: studio.workspace.id,
          actionCode: 'printer.material_updated',
          entityType: 'printer',
          entityId: '${slot.channel.printerId}',
          summary: summary,
        );
  }
}

class _FarmMaterialsEmpty extends StatelessWidget {
  const _FarmMaterialsEmpty({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 44, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 12),
        Text(text)
      ]));
}

String _farmActivityTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
