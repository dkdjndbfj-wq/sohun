import 'dart:io';
import 'dart:math' as math;

import '../../data/database/daos/printer_dao.dart';
import '../../data/database/models/scheduler_models.dart';
import '../../data/database/models/studio_models.dart';
import '../../data/external/printer/bambu_ftp_uploader.dart';
import '../../data/external/printer/bambu_print_feed.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_connector.dart';
import '../../data/external/slicer/slice_isolate_runner.dart';
import '../constants/personal_spool_policy.dart';
import 'printer_fleet_connection_manager.dart';
import 'printer_model_normalizer.dart';
import 'slice_artifact_hash_service.dart';
import 'slice_geometry_evidence.dart';
import 'toolpath_geometry_evidence.dart';

/// A read-only observation, not a reservation, ranking or dispatch command.
/// Mifu may select among these candidates; confirmation must re-read live data
/// and enter the existing plate-dispatch workflow.
class ClusterPlanningSnapshot {
  const ClusterPlanningSnapshot({
    required this.studio,
    required this.tasks,
    required this.printers,
    required this.generatedAt,
    this.visibleConsumableIds = const {},
  });

  final StudioSnapshot studio;
  final List<ClusterTaskGroup> tasks;
  final List<ClusterPrinter> printers;
  final DateTime generatedAt;

  /// Only these account/workspace-scoped materials may be exposed by detail
  /// views. A visible printer may still carry another account's material.
  final Set<int> visibleConsumableIds;

  List<ClusterPlatePlan> get plates => [
    for (final task in tasks) ...task.plates,
  ];

  int get pendingRuns =>
      plates.fold(0, (sum, plate) => sum + plate.remainingRuns);

  /// No file paths, printer serials, customer notes or credentials cross the
  /// inference boundary. Local IDs are opaque identifiers, never commands.
  Map<String, Object?> toModelInput() => {
    'schema_version': 1,
    'observed_at': generatedAt.toUtc().toIso8601String(),
    'plates': [
      for (final plate in plates.where((item) => item.remainingRuns > 0))
        {
          ...plate.toModelFeatures(),
          'candidates': [
            for (final candidate in plate.candidates)
              candidate.toModelCandidate(),
          ],
        },
    ],
  };
}

class ClusterTaskGroup {
  const ClusterTaskGroup({required this.order, required this.packages});
  final StudioOrder order;
  final List<ClusterPackageGroup> packages;
  List<ClusterPlatePlan> get plates => [
    for (final package in packages) ...package.plates,
  ];
}

class ClusterPackageGroup {
  const ClusterPackageGroup({required this.package, required this.plates});
  final StudioProductionPackage package;
  final List<ClusterPlatePlan> plates;
}

class ClusterPlatePlan {
  const ClusterPlatePlan({
    required this.plate,
    required this.remainingRuns,
    required this.assignedRuns,
    required this.completedRuns,
    required this.candidates,
    required this.blockers,
    required this.rejections,
    this.dueAt,
    this.declaredSliceGeometry,
    this.toolpathGeometry,
  });

  final StudioProductionPlate plate;
  final int remainingRuns;
  final int assignedRuns;
  final int completedRuns;
  final DateTime? dueAt;
  final Map<String, Object?>? declaredSliceGeometry;
  final Map<String, Object?>? toolpathGeometry;
  final List<ClusterPrinterCandidate> candidates;
  final List<String> blockers;
  final Map<int, List<String>> rejections;

  Map<String, Object?> toModelFeatures() => {
    'id': plate.id,
    'taskId': plate.orderId,
    'package_id': plate.packageId,
    'plate_index': plate.plateIndex,
    'remaining_runs': remainingRuns,
    'assigned_runs': assignedRuns,
    'completed_runs': completedRuns,
    'estimated_seconds': plate.estimatedSeconds,
    'estimated_grams': plate.estimatedGrams,
    'due_at': dueAt?.toUtc().toIso8601String(),
    'target_model': plate.sliceTargetModel,
    'nozzle_diameter': plate.sliceNozzleDiameter,
    'materials': [
      for (final item in plate.activeFilaments)
        {
          'tool_index': item.toolIndex,
          'material_type': item.materialType,
          'color_hex': item.colorHex,
          'grams_per_run': item.grams,
        },
    ],
  };
}

class ClusterPrinter {
  const ClusterPrinter({
    required this.source,
    required this.state,
    required this.activeQueueCount,
    required this.availableAfterSeconds,
    required this.blockers,
  });

  final PrinterWithChannels source;
  final FleetPrinterState? state;
  final int activeQueueCount;

  /// Null when an existing job has no known duration or needs manual removal.
  /// This is a lower-bound estimate, not a promised start time.
  final int? availableAfterSeconds;
  final List<String> blockers;
  int get id => source.printer.id;
  String get name => source.printer.name ?? state?.displayLabel ?? model;
  String? get serial => source.serial;
  String get model => state?.reportedModel ?? source.printer.model;
  bool get isEligible => blockers.isEmpty;
}

class ClusterPrinterCandidate {
  const ClusterPrinterCandidate({
    required this.printerId,
    required this.printerSerial,
    required this.printerName,
    required this.maxRuns,
    required this.materialMatches,
    required this.queuedRuns,
    required this.availableAfterSeconds,
  });

  final int printerId;
  final String printerSerial;
  final String printerName;
  final int maxRuns;
  final List<ClusterMaterialMatch> materialMatches;
  final int queuedRuns;
  final int? availableAfterSeconds;

  Map<String, Object?> toModelCandidate() => {
    'id': printerId.toString(),
    'features': {
      'max_runs': maxRuns,
      'queued_runs': queuedRuns,
      'available_after_seconds': availableAfterSeconds,
      'materials': [for (final item in materialMatches) item.toModelFeatures()],
    },
  };
}

class ClusterMaterialMatch {
  const ClusterMaterialMatch({
    required this.toolIndex,
    required this.consumableId,
    required this.channelId,
    required this.channelIndex,
    required this.gramsPerRun,
    required this.availableGrams,
  });
  final int toolIndex;
  final int consumableId;
  final int channelId;
  final int channelIndex;
  final double gramsPerRun;
  final double availableGrams;

  Map<String, Object?> toModelFeatures() => {
    'tool_index': toolIndex,
    'resource_id': channelId.toString(),
    'grams_per_run': gramsPerRun,
    'available_grams': availableGrams,
  };
}

/// Evidence is obtained from the actual selected plate in a stable artifact.
/// Injectable solely to make safety tests independent from disk and hardware.
class ClusterArtifactEvidence {
  const ClusterArtifactEvidence({
    this.targetSpec,
    this.filaments = const [],
    this.toolExtruders = const {},
    this.blockers = const [],
    this.declaredSliceGeometry,
    this.toolpathGeometry,
  });
  final PrinterModelSpec? targetSpec;
  final List<StudioPlateFilamentUsage> filaments;
  final Map<int, int> toolExtruders;
  final List<String> blockers;
  final Map<String, Object?>? declaredSliceGeometry;
  final Map<String, Object?>? toolpathGeometry;
}

typedef ClusterArtifactInspector =
    Future<ClusterArtifactEvidence> Function(StudioProductionPlate plate);

class ClusterPlanningService {
  ClusterPlanningService({ClusterArtifactInspector? inspectArtifact})
    : _inspectArtifact = inspectArtifact ?? ClusterSliceInspector().inspect;

  final ClusterArtifactInspector _inspectArtifact;

  Future<ClusterPlanningSnapshot> build({
    required StudioSnapshot studio,
    required List<PrinterWithChannels> printers,
    required Map<String, FleetPrinterState> fleet,
    required Set<int> allowedConsumableIds,
    required Map<int, double> channelAvailableGrams,
    required Map<String, int> activeQueueCounts,
    bool farmInventory = false,
    Map<String, int?> availableAfterSeconds = const {},
    SchedulingConfig config = SchedulingConfig.defaults,
    DateTime? now,
    String? fixedPlateId,
    Map<int, int>? fixedChannelByTool,
  }) async {
    final observedAt = now ?? DateTime.now();
    final physicalUseCounts = <int, int>{};
    for (final printer in printers) {
      for (final slot in printer.channels) {
        if (slot.consumable != null &&
            !slot.farmRollPaused &&
            slot.channel.loadedRemainingGrams > 0) {
          physicalUseCounts.update(
            slot.consumable!.id,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }
      }
    }
    final scopedIds = allowedConsumableIds
        .where((id) => farmInventory || (physicalUseCounts[id] ?? 0) <= 1)
        .toSet();
    final devices = [
      for (final printer in printers)
        _device(
          printer,
          fleet[printer.serial],
          activeQueueCounts[printer.serial],
          availableAfterSeconds[printer.serial],
          config,
          observedAt,
        ),
    ];
    final tasks = <ClusterTaskGroup>[];
    for (final order in studio.orders.where(
      (item) => item.workspaceId == studio.workspace.id,
    )) {
      final packages = <ClusterPackageGroup>[];
      for (final package in studio.productionPackages.where(
        (item) =>
            item.orderId == order.id && item.workspaceId == studio.workspace.id,
      )) {
        final plans = <ClusterPlatePlan>[];
        for (final plate in studio.productionPlates.where(
          (item) =>
              item.packageId == package.id &&
              item.orderId == order.id &&
              item.workspaceId == studio.workspace.id &&
              (fixedPlateId == null || item.id == fixedPlateId),
        )) {
          final work = studio.workOrders.where(
            (item) =>
                item.productionPlateId == plate.id &&
                item.orderId == order.id &&
                item.workspaceId == studio.workspace.id,
          );
          // Exactly the source states accepted by StudioDao.assignPlateRuns.
          // Failed/cancelled or already assigned runs are never rescheduled
          // implicitly. Retries remain in the established review flow.
          final unassigned = work.where(
            (item) =>
                item.printerId == null &&
                item.completedQuantity == 0 &&
                (item.status == StudioWorkOrderStatus.queued ||
                    item.status == StudioWorkOrderStatus.paused),
          );
          final remaining = unassigned.fold<int>(
            0,
            (sum, item) => sum + math.max(0, item.quantity),
          );
          // The DAO allocates from one source row per transaction.
          final maxSourceRuns = unassigned.fold<int>(
            0,
            (value, item) => math.max(value, item.quantity),
          );
          final assigned = work
              .where(
                (item) =>
                    item.printerId != null &&
                    item.status != StudioWorkOrderStatus.cancelled &&
                    item.status != StudioWorkOrderStatus.completed,
              )
              .fold<int>(
                0,
                (sum, item) =>
                    sum + math.max(0, item.quantity - item.completedQuantity),
              );
          final completed = work.fold<int>(
            0,
            (sum, item) => sum + math.max(0, item.completedQuantity),
          );
          // Display totals stay nonnegative, but that projection must not hide
          // a corrupt source row or authorize more work from the same plate.
          // Keep the anomaly in the snapshot even without pending runs.
          final blockers = <String>[
            if (work.any(
              (item) =>
                  item.quantity <= 0 ||
                  item.completedQuantity < 0 ||
                  item.completedQuantity > item.quantity,
            ))
              '盘次台账存在无效份数，请先核对',
          ];
          final candidates = <ClusterPrinterCandidate>[];
          final rejections = <int, List<String>>{};
          Map<String, Object?>? declaredSliceGeometry;
          Map<String, Object?>? toolpathGeometry;
          if (remaining > 0) {
            if (order.status == StudioOrderStatus.cancelled ||
                order.status == StudioOrderStatus.completed ||
                order.status == StudioOrderStatus.delivered) {
              blockers.add('订单已结束，不能继续排产');
            }
            if (!plate.isSliced) blockers.add('本盘尚未完成切片');
            if (plate.autoEjectEnabled != false) {
              blockers.add('本盘取件策略尚未确认为人工取件，请重新切片');
            }
            if (plate.plateIndex <= 0 ||
                plate.requiredRuns <= 0 ||
                plate.estimatedSeconds <= 0 ||
                !plate.estimatedGrams.isFinite ||
                plate.estimatedGrams <= 0) {
              blockers.add('本盘切片用量或时长不完整');
            }
            if (remaining + assigned + completed > plate.requiredRuns) {
              blockers.add('盘次台账与订单份数不一致，请先核对');
            }
            final evidence = blockers.isEmpty
                ? await _inspectArtifact(plate)
                : const ClusterArtifactEvidence();
            blockers.addAll(evidence.blockers);
            declaredSliceGeometry = evidence.declaredSliceGeometry;
            toolpathGeometry = evidence.toolpathGeometry;
            if (blockers.isEmpty) {
              blockers.addAll(_validateEvidence(plate, evidence));
            }
            if (blockers.isEmpty) {
              for (final device in devices) {
                final reasons = [...device.blockers];
                if (reasons.isEmpty) {
                  final mismatch = device.state!.targetSpecMismatch(
                    evidence.targetSpec,
                  );
                  if (mismatch != null) reasons.add(mismatch);
                }
                if (reasons.isEmpty) {
                  final limit = math.min(
                    maxSourceRuns,
                    config.maxQueuedTasksPerPrinter - device.activeQueueCount,
                  );
                  final matched = _matchMaterials(
                    device,
                    evidence,
                    scopedIds,
                    channelAvailableGrams,
                    limit,
                    config,
                    fixedChannelByTool: fixedChannelByTool,
                  );
                  if (matched == null) {
                    reasons.add('逐工具耗材、实际供料路径或预留后余量不满足本盘');
                  } else {
                    candidates.add(
                      ClusterPrinterCandidate(
                        printerId: device.id,
                        printerSerial: device.serial!,
                        printerName: device.name,
                        maxRuns: matched.runs,
                        materialMatches: matched.matches,
                        queuedRuns: device.activeQueueCount,
                        availableAfterSeconds: device.availableAfterSeconds,
                      ),
                    );
                  }
                }
                if (reasons.isNotEmpty) rejections[device.id] = reasons;
              }
              if (candidates.isEmpty) blockers.add('暂无满足安全条件的设备');
            }
          }
          plans.add(
            ClusterPlatePlan(
              plate: plate,
              remainingRuns: remaining,
              assignedRuns: assigned,
              completedRuns: completed,
              dueAt: order.dueAt,
              candidates: List.unmodifiable(candidates),
              blockers: List.unmodifiable(blockers),
              rejections: Map.unmodifiable(rejections),
              declaredSliceGeometry: declaredSliceGeometry,
              toolpathGeometry: toolpathGeometry,
            ),
          );
        }
        packages.add(ClusterPackageGroup(package: package, plates: plans));
      }
      if (packages.isNotEmpty) {
        tasks.add(ClusterTaskGroup(order: order, packages: packages));
      }
    }
    return ClusterPlanningSnapshot(
      studio: studio,
      tasks: List.unmodifiable(tasks),
      printers: List.unmodifiable(devices),
      generatedAt: observedAt,
      visibleConsumableIds: Set<int>.unmodifiable(allowedConsumableIds),
    );
  }

  ClusterPrinter _device(
    PrinterWithChannels printer,
    FleetPrinterState? state,
    int? queueCount,
    int? availableAfterSeconds,
    SchedulingConfig config,
    DateTime now,
  ) {
    final blockers = <String>[];
    if (printer.serial?.trim().isNotEmpty != true) {
      blockers.add('设备没有序列号');
    }
    if (state == null) {
      blockers.add('未取得设备实时状态');
    } else {
      if (!state.isLanCapable) blockers.add('仅云连接，不能下发');
      if (state.installedNozzleDiameter?.isFinite != true ||
          state.installedNozzleDiameter! <= 0) {
        blockers.add('设备喷嘴未知或无效');
      }
      if (state.connectionState != PrinterConnectionState.connected) {
        blockers.add('局域网未连接');
      }
      final age = state.statusUpdatedAt == null
          ? null
          : now.difference(state.statusUpdatedAt!);
      if (age == null || age.isNegative || age > config.staleStatusThreshold) {
        blockers.add('设备状态已过期或时间异常');
      }
      final status = state.lastStatus;
      if (status?.printError?.replaceAll(RegExp(r'[0xX_\s]'), '').isNotEmpty ==
              true ||
          status?.hmsAlerts?.isNotEmpty == true) {
        blockers.add('设备报告了未清除故障');
      }
      if (status == null ||
          status.hasBlockingUpgradeStatus ||
          !const {
            BambuGcodeState.idle,
            BambuGcodeState.finish,
            BambuGcodeState.running,
            BambuGcodeState.init,
            BambuGcodeState.prepare,
          }.contains(status.gcodeState)) {
        blockers.add('设备未就绪、暂停或异常');
      }
    }
    if (queueCount == null || queueCount < 0) {
      blockers.add('尚未确认正式队列');
    } else if (queueCount >= config.maxQueuedTasksPerPrinter) {
      blockers.add('活动队列已达上限');
    }
    return ClusterPrinter(
      source: printer,
      state: state,
      activeQueueCount: queueCount ?? 0,
      availableAfterSeconds: availableAfterSeconds,
      blockers: List.unmodifiable(blockers),
    );
  }

  List<String> _validateEvidence(
    StudioProductionPlate plate,
    ClusterArtifactEvidence evidence,
  ) {
    final target = evidence.targetSpec;
    if (target == null ||
        !PrinterModelNormalizer.isKnownBambuModel(target.canonicalModel) ||
        !target.nozzleDiameter.isFinite ||
        target.nozzleDiameter <= 0 ||
        plate.sliceTargetModel == null ||
        !PrinterModelNormalizer.sameModel(
          plate.sliceTargetModel!,
          target.canonicalModel,
        ) ||
        plate.sliceNozzleDiameter == null ||
        !plate.sliceNozzleDiameter!.isFinite ||
        (plate.sliceNozzleDiameter! - target.nozzleDiameter).abs() >= .001) {
      return const ['切片文件的精确机型或喷嘴与盘记录不一致'];
    }
    final stored = plate.activeFilaments;
    final actual = evidence.filaments;
    if (actual.isEmpty || stored.length != actual.length) {
      return const ['本盘逐工具耗材记录缺失或与切片不一致'];
    }
    for (final item in actual) {
      final metadata = stored
          .where((value) => value.toolIndex == item.toolIndex)
          .firstOrNull;
      if (item.toolIndex < 0 ||
          item.toolIndex > 255 ||
          !item.grams.isFinite ||
          item.grams <= .01 ||
          item.materialType?.trim().isNotEmpty != true ||
          item.colorHex?.trim().isNotEmpty != true ||
          !RegExp(r'^[A-F0-9]{6}$').hasMatch(_color(item.colorHex)) ||
          metadata == null ||
          !metadata.grams.isFinite ||
          (metadata.grams - item.grams).abs() > .01 ||
          _material(metadata.materialType) != _material(item.materialType) ||
          _color(metadata.colorHex) != _color(item.colorHex)) {
        return const ['本盘逐工具材料、颜色或用量不完整，请重新切片'];
      }
    }
    if (actual.map((item) => item.toolIndex).toSet().length != actual.length) {
      return const ['切片工具号重复，请重新切片'];
    }
    return const [];
  }

  ({int runs, List<ClusterMaterialMatch> matches})? _matchMaterials(
    ClusterPrinter device,
    ClusterArtifactEvidence evidence,
    Set<int> allowedIds,
    Map<int, double> available,
    int maxRuns,
    SchedulingConfig config, {
    Map<int, int>? fixedChannelByTool,
  }) {
    final slots = device.source.channels.where((slot) {
      final grams = available[slot.channel.id];
      return slot.consumable != null &&
          allowedIds.contains(slot.consumable!.id) &&
          slot.channel.consumableId == slot.consumable!.id &&
          slot.channel.printerId == device.id &&
          !slot.farmRollPaused &&
          canReusePersonalSpool(slot.channel.loadedRemainingGrams) &&
          grams != null &&
          grams.isFinite &&
          grams >= 0 &&
          grams <= slot.channel.loadedRemainingGrams;
    }).toList()..sort((a, b) => a.channel.id.compareTo(b.channel.id));
    final needs = evidence.filaments;
    if (fixedChannelByTool != null &&
        (fixedChannelByTool.length != needs.length ||
            needs.any(
              (need) => !fixedChannelByTool.containsKey(need.toolIndex),
            ))) {
      return null;
    }
    final options = [
      for (final item in needs)
        slots
            .where(
              (slot) =>
                  (fixedChannelByTool == null ||
                      fixedChannelByTool[item.toolIndex] == slot.channel.id) &&
                  _material(slot.consumable!.materialType) ==
                      _material(item.materialType) &&
                  _color(slot.consumable!.colorHex) == _color(item.colorHex),
            )
            .toList(),
    ];
    if (options.any((items) => items.isEmpty)) return null;
    // Bounded DFS finds a feasible mapping, not a model-derived preference.
    // Failing closed on unusually large combinations keeps the UI responsive.
    var budget = 20000;
    for (var runs = maxRuns; runs > 0 && budget > 0; runs--) {
      final selected = <int, ChannelWithConsumable>{};
      final demand = <int, double>{};
      bool visit(int index) {
        if (--budget < 0) return false;
        if (index == needs.length) {
          final maxTool = needs.fold<int>(
            0,
            (v, item) => math.max(v, item.toolIndex),
          );
          final mapping = List<int>.filled(maxTool + 1, -1);
          for (final entry in selected.entries) {
            mapping[entry.key] = entry.value.channel.channelIndex;
          }
          return validateBambuPrintFeed(
                model: device.model,
                mapping: mapping,
                activeTools: needs.map((item) => item.toolIndex),
                status: device.state!.lastStatus,
                toolExtruders: evidence.toolExtruders,
              ) ==
              null;
        }
        final need = needs[index];
        for (final slot in options[index]) {
          final id = slot.channel.id;
          final previous = demand[id] ?? 0;
          final total = previous + need.grams * runs;
          final afterReservations = available[id]!;
          if (total + config.safetyBuffer(total) > afterReservations + .001) {
            continue;
          }
          // Each subsequent run may start only while that physical roll still
          // exceeds 30g, even when the complete batch would technically fit.
          final perRun = total / runs;
          if (afterReservations - perRun * (runs - 1) <=
              minimumReusableSpoolGrams) {
            continue;
          }
          demand[id] = total;
          selected[need.toolIndex] = slot;
          if (visit(index + 1)) return true;
          selected.remove(need.toolIndex);
          if (previous == 0) {
            demand.remove(id);
          } else {
            demand[id] = previous;
          }
        }
        return false;
      }

      if (visit(0)) {
        return (
          runs: runs,
          matches: [
            for (final need in needs)
              ClusterMaterialMatch(
                toolIndex: need.toolIndex,
                consumableId: selected[need.toolIndex]!.consumable!.id,
                channelId: selected[need.toolIndex]!.channel.id,
                channelIndex: selected[need.toolIndex]!.channel.channelIndex,
                gramsPerRun: need.grams,
                availableGrams:
                    available[selected[need.toolIndex]!.channel.id]!,
              ),
          ],
        );
      }
    }
    return null;
  }
}

/// Final advisory gate for an already user-confirmed selection. This validates
/// a freshly rebuilt fixed-mapping snapshot; it does not claim a queue slot or
/// material reservation. The dispatch transaction remains authoritative.
String? validateClusterSnapshotSelection({
  required ClusterPlanningSnapshot snapshot,
  required String plateId,
  required int printerId,
  required int runs,
  required Map<int, int> channelByTool,
  required String expectedArtifactSha256,
}) {
  if (runs <= 0) return '打印份数必须大于零';
  final plan = snapshot.plates
      .where((item) => item.plate.id == plateId)
      .firstOrNull;
  if (plan == null) return '打印盘已移除或当前工作区已变化';
  if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedArtifactSha256) ||
      plan.plate.sliceArtifactSha256?.toLowerCase() !=
          expectedArtifactSha256.toLowerCase()) {
    return '打印盘的切片已变化，请重新确认本盘';
  }
  final candidate = plan.candidates
      .where((item) => item.printerId == printerId)
      .firstOrNull;
  if (candidate == null) {
    return plan.rejections[printerId]?.firstOrNull ??
        plan.blockers.firstOrNull ??
        '所选设备或供料映射已不满足本盘条件';
  }
  if (runs > candidate.maxRuns || runs > plan.remainingRuns) {
    return '所选设备当前最多可排 ${candidate.maxRuns} 次，请减少份数后重新确认';
  }
  if (channelByTool.length != candidate.materialMatches.length ||
      candidate.materialMatches.any(
        (item) => channelByTool[item.toolIndex] != item.channelId,
      )) {
    return '供料映射已变化，请重新确认实际槽位';
  }
  return null;
}

String _material(String? value) => value?.trim().toUpperCase() ?? '';
String _color(String? value) {
  var hex = value?.trim().toUpperCase().replaceFirst('#', '') ?? '';
  if (hex.length == 8 && hex.endsWith('FF')) hex = hex.substring(0, 6);
  return hex;
}

/// Reuses verified parsing only while path, expected hash, size and timestamp
/// remain unchanged. Confirmation still performs the existing fresh hash check.
class ClusterSliceInspector {
  final _cache =
      <String, ({int size, int modified, ClusterArtifactEvidence evidence})>{};

  Future<ClusterArtifactEvidence> inspect(StudioProductionPlate plate) async {
    final path = plate.sliceArtifactPath;
    final expectedHash = plate.sliceArtifactSha256;
    if (path == null ||
        path.trim().isEmpty ||
        expectedHash == null ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedHash)) {
      return const ClusterArtifactEvidence(blockers: ['缺少本机切片文件或完整校验值']);
    }
    try {
      final stat = await File(path).stat();
      final key = '$path|${plate.plateIndex}|$expectedHash';
      final cached = _cache[key];
      if (stat.type == FileSystemEntityType.file &&
          cached != null &&
          cached.size == stat.size &&
          cached.modified == stat.modified.microsecondsSinceEpoch) {
        return cached.evidence;
      }
      final identity = await SliceArtifactHashService.computeStable(path);
      if (identity == null ||
          identity.sha256Hex != expectedHash.toLowerCase()) {
        return const ClusterArtifactEvidence(blockers: ['切片文件缺失、仍在变化或校验不一致']);
      }
      if (path.toLowerCase().endsWith('.3mf')) {
        await BambuGcodePathResolver.resolveFrom3mf(
          path,
          plateIndex: plate.plateIndex,
        );
      }
      final parsed = await SliceIsolateRunner.parseAuto(
        path,
        plateIndex: plate.plateIndex,
      );
      if (parsed == null ||
          parsed.printerSettingsId == null ||
          parsed.nozzleDiameter == null) {
        return const ClusterArtifactEvidence(
          blockers: ['无法确认切片文件中的精确机型、喷嘴或指定盘'],
        );
      }
      final extruders = await readBambuToolExtruders(
        path,
        plateIndex: plate.plateIndex,
      );
      final after = await SliceArtifactHashService.computeStable(path);
      if (after == null || after.sha256Hex != identity.sha256Hex) {
        return const ClusterArtifactEvidence(blockers: ['读取期间切片文件发生变化']);
      }
      final evidence = ClusterArtifactEvidence(
        targetSpec: PrinterModelSpec(
          canonicalModel: PrinterModelNormalizer.normalize(
            parsed.printerSettingsId!,
          ),
          nozzleDiameter: parsed.nozzleDiameter!,
          rawModel: parsed.printerSettingsId!,
        ),
        filaments: StudioPlateFilamentUsage.activeByTool([
          for (final item in parsed.filaments)
            StudioPlateFilamentUsage(
              toolIndex: item.toolIndex,
              grams: item.grams,
              materialType: item.materialType,
              colorHex: item.colorHex,
            ),
        ]),
        toolExtruders: extruders,
        declaredSliceGeometry:
            parsed.declaredSliceGeometry != null &&
                SliceGeometryEvidence.matchesBinding(
                  parsed.declaredSliceGeometry!,
                  artifactSha256: identity.sha256Hex,
                  plateIndex: plate.plateIndex,
                )
            ? parsed.declaredSliceGeometry
            : null,
        toolpathGeometry:
            parsed.toolpathGeometry != null &&
                ToolpathGeometryEvidence.matchesBinding(
                  parsed.toolpathGeometry!,
                  artifactSha256: identity.sha256Hex,
                  plateIndex: plate.plateIndex,
                )
            ? parsed.toolpathGeometry
            : null,
      );
      if (_cache.length >= 32) _cache.remove(_cache.keys.first);
      _cache[key] = (
        size: stat.size,
        modified: stat.modified.microsecondsSinceEpoch,
        evidence: evidence,
      );
      return evidence;
    } catch (_) {
      // Do not leak local paths or parser exception details to inference/UI.
      return const ClusterArtifactEvidence(blockers: ['本机切片文件不可读或指定盘无有效刀路']);
    }
  }
}
