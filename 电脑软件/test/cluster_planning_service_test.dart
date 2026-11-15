import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/core/services/cluster_planning_service.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_queue_item.dart';
import 'package:consumable_tracker_desktop/data/database/models/scheduler_models.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/providers/cluster_provider.dart'
    show clusterQueueDelaySeconds;

final _now = DateTime(2026, 11, 11, 12);
const _white = StudioPlateFilamentUsage(
  toolIndex: 0,
  grams: 100,
  materialType: 'PLA',
  colorHex: '#FFFFFF',
);

void main() {
  test(
    'fixed mapping accepts a valid alternative instead of only the first suggestion',
    () async {
      final printers = [
        _printer(slots: [_slot(), _slot(id: 11, channelIndex: 1)]),
      ];
      final suggested = await _build(
        printers: printers,
        farm: true,
        available: {10: 1000, 11: 500},
      );
      expect(
        suggested
            .plates
            .single
            .candidates
            .single
            .materialMatches
            .single
            .channelId,
        10,
      );
      final selected = await _build(
        printers: printers,
        farm: true,
        available: {10: 1000, 11: 500},
        fixed: {0: 11},
      );
      expect(
        selected
            .plates
            .single
            .candidates
            .single
            .materialMatches
            .single
            .channelId,
        11,
      );
      expect(_validate(selected, mapping: {0: 11}), isNull);
    },
  );

  test(
    'fixed mapping cannot fall back when its chosen channel is insufficient or invalid',
    () async {
      final printers = [
        _printer(slots: [_slot(), _slot(id: 11, channelIndex: 1)]),
      ];
      for (final fixed in <Map<int, int>>[
        {0: 11},
        {0: 999},
        {},
        {0: 10, 5: 11},
      ]) {
        final result = await _build(
          printers: printers,
          farm: true,
          available: {10: 1000, 11: 109},
          fixed: fixed,
        );
        expect(result.plates.single.candidates, isEmpty);
        expect(_validate(result, mapping: fixed), isNotNull);
      }
    },
  );

  test(
    'final validation enforces current queue bound and requested positive run count',
    () async {
      final result = await _build(
        snapshot: _snapshot(plates: [_plate('a', runs: 8)]),
        count: 3,
        fixed: {0: 10},
      );
      expect(_validate(result, runs: 2), isNull);
      expect(_validate(result, runs: 3), contains('最多可排 2'));
      expect(_validate(result, runs: 0), isNotNull);
      expect(_validate(result, runs: -1), isNotNull);
    },
  );

  test(
    'final validation binds exact current plate artifact, device and mapping',
    () async {
      final result = await _build(fixed: {0: 10});
      expect(_validate(result, hash: 'b' * 64), contains('切片已变化'));
      expect(_validate(result, hash: ''), isNotNull);
      expect(_validate(result, plate: 'other'), isNotNull);
      expect(_validate(result, printer: 99), isNotNull);
      expect(_validate(result, mapping: {0: 11}), isNotNull);
      expect(_validate(result), isNull);
    },
  );

  test(
    'fixed shared-slot mapping still aggregates all tool demands and reservations',
    () async {
      final plate = _plate(
        'a',
        needs: const [
          StudioPlateFilamentUsage(
            toolIndex: 0,
            grams: 40,
            materialType: 'PLA',
            colorHex: '#FFFFFF',
          ),
          StudioPlateFilamentUsage(
            toolIndex: 1,
            grams: 40,
            materialType: 'PLA',
            colorHex: '#FFFFFF',
          ),
        ],
      );
      final result = await _build(
        snapshot: _snapshot(plates: [plate]),
        fixed: {0: 10, 1: 10},
        available: {10: 87},
      );
      expect(_validate(result, mapping: {0: 10, 1: 10}), isNotNull);
    },
  );

  test(
    'one order keeps independent package, plate and remaining-run structure',
    () async {
      final a = _plate('a', runs: 5);
      final b = _plate('b', runs: 2, package: 'package2');
      final snapshot = _snapshot(
        plates: [a, b],
        work: [
          _work('pending', a, quantity: 3),
          _work(
            'assigned',
            a,
            printer: 1,
            status: StudioWorkOrderStatus.assigned,
          ),
          _work(
            'done',
            a,
            printer: 1,
            status: StudioWorkOrderStatus.completed,
            completed: 1,
          ),
          _work('other-plate', b, quantity: 2),
        ],
      );
      final result = await _build(snapshot: snapshot);
      expect(result.tasks, hasLength(1));
      expect(result.tasks.single.packages, hasLength(2));
      expect(result.plates.map((item) => item.remainingRuns), [3, 2]);
      expect(result.plates.first.assignedRuns, 1);
      expect(result.plates.first.completedRuns, 1);
      expect(result.pendingRuns, 5);
      expect(result.plates.first.candidates.single.maxRuns, 3);
    },
  );

  test(
    'failed and cancelled runs do not silently re-enter pending allocation',
    () async {
      final plate = _plate('a', runs: 3);
      final result = await _build(
        snapshot: _snapshot(
          plates: [plate],
          work: [
            _work('failed', plate, status: StudioWorkOrderStatus.failed),
            _work('cancelled', plate, status: StudioWorkOrderStatus.cancelled),
            _work('queued', plate),
          ],
        ),
      );
      expect(result.plates.single.remainingRuns, 1);
      expect(result.plates.single.candidates.single.maxRuns, 1);
    },
  );

  test(
    'fully assigned and completed plates never produce extra candidates',
    () async {
      final plate = _plate('a', runs: 2);
      final result = await _build(
        snapshot: _snapshot(
          plates: [plate],
          work: [
            _work(
              'assigned',
              plate,
              printer: 1,
              status: StudioWorkOrderStatus.printing,
            ),
            _work(
              'done',
              plate,
              printer: 1,
              status: StudioWorkOrderStatus.completed,
              completed: 1,
            ),
          ],
        ),
      );
      expect(result.plates.single.remainingRuns, 0);
      expect(result.plates.single.candidates, isEmpty);
    },
  );

  for (final invalid in [
    (label: 'negative quantity', quantity: -1, completed: 0),
    (label: 'zero quantity', quantity: 0, completed: 0),
    (label: 'negative completed quantity', quantity: 1, completed: -1),
    (label: 'completed quantity exceeds quantity', quantity: 1, completed: 2),
  ]) {
    test('invalid ledger ${invalid.label} blocks the whole plate', () async {
      final plate = _plate('a', runs: 5);
      var inspections = 0;
      final result = await _build(
        snapshot: _snapshot(
          plates: [plate],
          work: [
            _work('pending', plate),
            _work(
              'invalid',
              plate,
              quantity: invalid.quantity,
              completed: invalid.completed,
              printer: 1,
              status: StudioWorkOrderStatus.assigned,
            ),
          ],
        ),
        inspector: (_) async {
          inspections++;
          return _evidence(plate);
        },
      );
      expect(result.plates.single.remainingRuns, 1);
      expect(result.plates.single.candidates, isEmpty);
      expect(result.plates.single.blockers.join(), contains('盘次台账'));
      expect(_validate(result), contains('盘次台账'));
      expect(inspections, 0);
    });
  }

  test(
    'invalid ledger is reported without a positive pending row',
    () async {
      final plate = _plate('a');
      final result = await _build(
        snapshot: _snapshot(
          plates: [plate],
          work: [_work('invalid', plate, quantity: -1)],
        ),
      );
      expect(result.plates.single.remainingRuns, 0);
      expect(result.plates.single.candidates, isEmpty);
      expect(result.plates.single.blockers.join(), contains('盘次台账'));
    },
  );

  test(
    'foreign workspace rows and foreign stock cannot become candidates',
    () async {
      final foreign = _plate('foreign', workspace: 'elsewhere');
      final snapshot = _snapshot(plates: [_plate('a'), foreign]);
      final result = await _build(snapshot: snapshot, allowed: {});
      expect(result.plates.map((item) => item.plate.id), ['a']);
      expect(result.plates.single.candidates, isEmpty);
    },
  );

  test(
    'no file/evidence, unsliced plate and auto-eject policy fail closed',
    () async {
      for (final plate in [
        _plate('a', sliced: false),
        _plate('a', autoEject: true),
        _plate('a', autoEject: null),
      ]) {
        var inspections = 0;
        final result = await _build(
          snapshot: _snapshot(plates: [plate]),
          inspector: (_) async {
            inspections++;
            return _evidence(plate);
          },
        );
        expect(result.plates.single.candidates, isEmpty);
        expect(result.plates.single.blockers, isNotEmpty);
        expect(inspections, 0);
      }
      final result = await _build(
        inspector: (_) async =>
            const ClusterArtifactEvidence(blockers: ['missing']),
      );
      expect(result.plates.single.candidates, isEmpty);
      expect(result.plates.single.blockers, contains('missing'));
    },
  );

  test(
    'stable file inspector rejects nonexistent local slice without leaking path',
    () async {
      final result = await ClusterSliceInspector().inspect(_plate('a'));
      expect(result.blockers, isNotEmpty);
      expect(result.blockers.join(), isNot(contains('private-file')));
    },
  );

  test(
    'exact target and nozzle are mandatory, never same-series compatibility',
    () async {
      for (final state in [
        _fleet(model: 'P1P'),
        _fleet(nozzle: .6),
        _fleet(nozzle: double.nan),
        _fleet(model: 'P1'),
      ]) {
        final result = await _build(state: state);
        expect(result.plates.single.candidates, isEmpty);
        expect(result.plates.single.rejections[1], isNotEmpty);
      }
      final result = await _build(
        inspector: (plate) async => ClusterArtifactEvidence(
          targetSpec: const PrinterModelSpec(
            canonicalModel: 'P1P',
            nozzleDiameter: .4,
          ),
          filaments: plate.filaments,
        ),
      );
      expect(result.plates.single.candidates, isEmpty);
    },
  );

  test(
    'LAN, connection, freshness, fault and known status are hard requirements',
    () async {
      for (final state in [
        _fleet(lan: false),
        _fleet(connected: false),
        _fleet(updated: _now.subtract(const Duration(minutes: 6))),
        _fleet(updated: _now.add(const Duration(seconds: 1))),
        _fleet(gcode: BambuGcodeState.failed),
        _fleet(gcode: BambuGcodeState.pause),
        _fleet(
          status: BambuPrinterStatus(
            serial: 'secret-serial',
            printError: '1234',
            gcodeState: BambuGcodeState.idle,
          ),
        ),
        _fleet(status: BambuPrinterStatus(serial: 'secret-serial')),
      ]) {
        final result = await _build(state: state);
        expect(result.plates.single.candidates, isEmpty);
      }
      final result = await _build(fleet: {});
      expect(result.plates.single.candidates, isEmpty);
    },
  );

  test(
    'completed firmware upgrade remains eligible after incremental status updates',
    () async {
      final completedUpgrade = _fleet().lastStatus!.copyWith(
        upgradeStatus: 'UPGRADE_SUCCESS',
      );
      final latest = completedUpgrade.copyWith(
        gcodeState: BambuGcodeState.idle,
        nozzleTemper: 25,
      );
      expect(latest.upgradeStatus, 'UPGRADE_SUCCESS');
      expect(latest.hasBlockingUpgradeStatus, isFalse);
      expect(
        (await _build(state: _fleet(status: latest))).plates.single.candidates,
        hasLength(1),
      );

      final fresh = _fleet(status: latest, updated: DateTime.now());
      expect(fresh.printerBusy, isFalse);
      expect(fresh.canAcceptQueuedTask(SchedulingConfig.defaults), isTrue);
      expect(fresh.canAutoDispatch(SchedulingConfig.defaults), isTrue);
    },
  );

  test(
    'active failed and unknown upgrade states block all admission gates',
    () async {
      for (final upgrade in ['UPGRADING', 'UPGRADE_FAILED', 'UNKNOWN', ' ']) {
        final status = _fleet().lastStatus!.copyWith(upgradeStatus: upgrade);
        expect(status.hasBlockingUpgradeStatus, isTrue, reason: upgrade);
        final result = await _build(state: _fleet(status: status));
        expect(result.plates.single.candidates, isEmpty, reason: upgrade);
        final fresh = _fleet(status: status, updated: DateTime.now());
        expect(fresh.printerBusy, isTrue, reason: upgrade);
        expect(
          fresh.canAcceptQueuedTask(SchedulingConfig.defaults),
          isFalse,
          reason: upgrade,
        );
        expect(
          fresh.canAutoDispatch(SchedulingConfig.defaults),
          isFalse,
          reason: upgrade,
        );
      }
    },
  );

  test(
    'upgrade success cannot override connection freshness or current print state',
    () async {
      final status = _fleet().lastStatus!.copyWith(
        upgradeStatus: 'UPGRADE_SUCCESS',
      );
      for (final state in [
        _fleet(status: status, lan: false),
        _fleet(status: status, connected: false),
        _fleet(
          status: status,
          updated: _now.subtract(const Duration(minutes: 6)),
        ),
        _fleet(status: status.copyWith(gcodeState: BambuGcodeState.failed)),
      ]) {
        expect((await _build(state: state)).plates.single.candidates, isEmpty);
      }
      final now = DateTime.now();
      for (final state in [
        _fleet(status: status, lan: false, updated: now),
        _fleet(status: status, connected: false, updated: now),
        _fleet(
          status: status,
          updated: now.subtract(const Duration(minutes: 6)),
        ),
        _fleet(
          status: status.copyWith(gcodeState: BambuGcodeState.failed),
          updated: now,
        ),
      ]) {
        expect(state.canAcceptQueuedTask(SchedulingConfig.defaults), isFalse);
        expect(state.canAutoDispatch(SchedulingConfig.defaults), isFalse);
      }
      final running = _fleet(
        status: status.copyWith(gcodeState: BambuGcodeState.running),
        updated: DateTime.now(),
      );
      expect(running.canAcceptQueuedTask(SchedulingConfig.defaults), isTrue);
      expect(running.canAutoDispatch(SchedulingConfig.defaults), isFalse);
    },
  );

  test(
    'normal running device can receive a future suggestion, not a print command',
    () async {
      final result = await _build(
        state: _fleet(gcode: BambuGcodeState.running),
      );
      expect(result.plates.single.candidates, hasLength(1));
      expect(
        result.plates.single.candidates.single.availableAfterSeconds,
        isNull,
      );
    },
  );

  test(
    'active queue limits cap run count and missing queue facts reject',
    () async {
      final plate = _plate('a', runs: 8);
      final result = await _build(
        snapshot: _snapshot(plates: [plate]),
        count: 3,
      );
      expect(result.plates.single.candidates.single.maxRuns, 2);
      final full = await _build(count: 5);
      expect(full.plates.single.candidates, isEmpty);
      final unknown = await _build(counts: {});
      expect(unknown.plates.single.candidates, isEmpty);
    },
  );

  test(
    'one source ledger row bounds each confirmation, even if many pending rows exist',
    () async {
      final plate = _plate('a', runs: 4);
      final result = await _build(
        snapshot: _snapshot(
          plates: [plate],
          work: [
            _work('one', plate, quantity: 2),
            _work('two', plate, quantity: 2),
          ],
        ),
      );
      expect(result.plates.single.remainingRuns, 4);
      expect(result.plates.single.candidates.single.maxRuns, 2);
    },
  );

  test(
    'physical 1000g limit, strictly above 30g, held roll and reservations are respected',
    () async {
      for (final slot in [
        _slot(remaining: 30),
        _slot(remaining: 1001),
        _slot(remaining: double.nan),
        _slot(held: true),
      ]) {
        final result = await _build(
          printers: [
            _printer(slots: [slot]),
          ],
        );
        expect(result.plates.single.candidates, isEmpty);
      }
      final insufficient = await _build(available: {10: 109.99});
      expect(insufficient.plates.single.candidates, isEmpty);
      final enough = await _build(available: {10: 110});
      expect(enough.plates.single.candidates, hasLength(1));
      final missing = await _build(available: {});
      expect(missing.plates.single.candidates, isEmpty);
    },
  );

  test(
    'multi-tool shared physical slot demand is summed before accepting',
    () async {
      const needs = [
        StudioPlateFilamentUsage(
          toolIndex: 0,
          grams: 40,
          materialType: 'PLA',
          colorHex: '#FFFFFF',
        ),
        StudioPlateFilamentUsage(
          toolIndex: 1,
          grams: 40,
          materialType: 'PLA',
          colorHex: '#FFFFFF',
        ),
      ];
      final plate = _plate('a', needs: needs);
      final stock = [
        _printer(slots: [_slot(remaining: 100)]),
      ];
      final insufficient = await _build(
        snapshot: _snapshot(plates: [plate]),
        printers: stock,
        available: {10: 87},
      );
      expect(insufficient.plates.single.candidates, isEmpty);
      final enough = await _build(
        snapshot: _snapshot(plates: [plate]),
        printers: stock,
        available: {10: 88},
      );
      expect(
        enough.plates.single.candidates.single.materialMatches,
        hasLength(2),
      );
      expect(
        enough.plates.single.candidates.single.materialMatches.map(
          (item) => item.channelId,
        ),
        [10, 10],
      );
    },
  );

  test(
    'material/color mismatch and disconnected real AMS path are rejected',
    () async {
      for (final slot in [_slot(material: 'PETG'), _slot(color: '#000000')]) {
        final result = await _build(
          printers: [
            _printer(slots: [slot]),
          ],
        );
        expect(result.plates.single.candidates, isEmpty);
      }
      final disconnected = await _build(
        state: _fleet(
          status: BambuPrinterStatus(
            serial: 'secret-serial',
            gcodeState: BambuGcodeState.idle,
            amsTrays: [],
          ),
        ),
      );
      expect(disconnected.plates.single.candidates, isEmpty);
    },
  );

  test(
    'invalid metadata and conflicting artifact material fail closed',
    () async {
      final result = await _build(
        inspector: (_) async => const ClusterArtifactEvidence(
          targetSpec: PrinterModelSpec(
            canonicalModel: 'P1S',
            nozzleDiameter: .4,
          ),
          filaments: [
            StudioPlateFilamentUsage(
              toolIndex: 0,
              grams: 90,
              materialType: 'PLA',
              colorHex: '#FFFFFF',
            ),
          ],
        ),
      );
      expect(result.plates.single.candidates, isEmpty);
      final badColor = _plate(
        'a',
        needs: const [
          StudioPlateFilamentUsage(
            toolIndex: 0,
            grams: 100,
            materialType: 'PLA',
            colorHex: 'red',
          ),
        ],
      );
      expect(
        (await _build(
          snapshot: _snapshot(plates: [badColor]),
        )).plates.single.candidates,
        isEmpty,
      );
    },
  );

  test(
    'same personal spool cannot be counted twice; farm SKU can represent separate physical rolls',
    () async {
      final printers = [
        _printer(slots: [_slot(), _slot(id: 11, channelIndex: 1)]),
      ];
      expect(
        (await _build(
          printers: printers,
          available: {10: 1000, 11: 1000},
        )).plates.single.candidates,
        isEmpty,
      );
      final farm = await _build(
        printers: printers,
        available: {10: 1000, 11: 1000},
        farm: true,
      );
      expect(farm.plates.single.candidates, hasLength(1));
    },
  );

  test(
    'empty device set remains empty, never manufactures a model recommendation',
    () async {
      final result = await _build(printers: []);
      expect(result.printers, isEmpty);
      expect(result.plates.single.candidates, isEmpty);
      expect(result.plates.single.blockers, contains('暂无满足安全条件的设备'));
    },
  );

  test(
    'model contract uses opaque ids and excludes local paths, names and serials',
    () async {
      final result = await _build();
      final plan = result.plates.single;
      expect(plan.toModelFeatures()['id'], 'a');
      expect(plan.toModelFeatures()['taskId'], 'order');
      final candidate = plan.candidates.single.toModelCandidate();
      expect(candidate['id'], '1');
      expect(candidate['features'], isA<Map<String, Object?>>());
      final encoded = jsonEncode(result.toModelInput());
      for (final privateValue in [
        'secret-serial',
        'private-file',
        'PRIVATE CUSTOMER',
        'PRIVATE DEVICE',
        'accessCode',
        'rank',
        'score',
      ]) {
        expect(encoded, isNot(contains(privateValue)));
      }
    },
  );

  test(
    'queue delay preserves unknown work and manual removal instead of pretending idle',
    () {
      final queued = PrintQueueItem(
        printerSerial: 'secret-serial',
        gcodePath: 'private-file',
        filename: 'private-file',
        queuedAt: _now,
      );
      expect(
        clusterQueueDelaySeconds(
          queue: [queued],
          workOrders: [],
          state: _fleet(),
        ),
        isNull,
      );
      expect(
        clusterQueueDelaySeconds(queue: [], workOrders: [], state: _fleet()),
        0,
      );
      expect(
        clusterQueueDelaySeconds(
          queue: [],
          workOrders: [],
          state: _fleet(gcode: BambuGcodeState.running),
        ),
        isNull,
      );
      final waiting = PrintQueueItem(
        printerSerial: 'secret-serial',
        gcodePath: 'private-file',
        filename: 'private-file',
        queuedAt: _now,
        status: PrintQueueStatus.waitingRemoval,
      );
      expect(
        clusterQueueDelaySeconds(
          queue: [waiting],
          workOrders: [],
          state: _fleet(),
        ),
        isNull,
      );
    },
  );

  test('queue delay keeps one running job plus queued work duration', () {
    final plate = _plate('a');
    final running = PrintQueueItem(
      printerSerial: 'secret-serial',
      gcodePath: 'private-file',
      filename: 'private-file',
      queuedAt: _now,
      status: PrintQueueStatus.printing,
    );
    final queued = running.copyWith(
      status: PrintQueueStatus.queued,
      studioWorkOrderId: 'queued-work',
    );
    expect(
      clusterQueueDelaySeconds(
        queue: [
          running,
          queued,
          running.copyWith(status: PrintQueueStatus.completed),
        ],
        workOrders: [_work('queued-work', plate, printer: 1)],
        state: _fleet(
          status: BambuPrinterStatus(
            serial: 'secret-serial',
            gcodeState: BambuGcodeState.running,
            mcRemainingTime: 12,
          ),
        ),
      ),
      12 * 60 + plate.estimatedSeconds,
    );
  });

  test(
    'multiple printing queue rows cannot share one remaining-time reading',
    () {
      final running = PrintQueueItem(
        printerSerial: 'secret-serial',
        gcodePath: 'private-file',
        filename: 'private-file',
        queuedAt: _now,
        status: PrintQueueStatus.printing,
      );
      expect(
        clusterQueueDelaySeconds(
          queue: [running.copyWith(id: 1), running.copyWith(id: 2)],
          workOrders: [],
          state: _fleet(
            status: BambuPrinterStatus(
              serial: 'secret-serial',
              gcodeState: BambuGcodeState.running,
              mcRemainingTime: 12,
            ),
          ),
        ),
        isNull,
      );
    },
  );
}

Future<ClusterPlanningSnapshot> _build({
  StudioSnapshot? snapshot,
  List<PrinterWithChannels>? printers,
  FleetPrinterState? state,
  Map<String, FleetPrinterState>? fleet,
  Set<int>? allowed,
  Map<int, double>? available,
  int count = 0,
  Map<String, int>? counts,
  ClusterArtifactInspector? inspector,
  bool farm = false,
  Map<int, int>? fixed,
}) =>
    ClusterPlanningService(
      inspectArtifact: inspector ?? (plate) async => _evidence(plate),
    ).build(
      studio: snapshot ?? _snapshot(plates: [_plate('a')]),
      printers: printers ?? [_printer()],
      fleet: fleet ?? {'secret-serial': state ?? _fleet()},
      allowedConsumableIds: allowed ?? {100},
      channelAvailableGrams: available ?? {10: 1000},
      activeQueueCounts: counts ?? {'secret-serial': count},
      farmInventory: farm,
      fixedPlateId: fixed == null ? null : 'a',
      fixedChannelByTool: fixed,
      now: _now,
    );

String? _validate(
  ClusterPlanningSnapshot snapshot, {
  String plate = 'a',
  int printer = 1,
  int runs = 1,
  Map<int, int> mapping = const {0: 10},
  String? hash,
}) => validateClusterSnapshotSelection(
  snapshot: snapshot,
  plateId: plate,
  printerId: printer,
  runs: runs,
  channelByTool: mapping,
  expectedArtifactSha256: hash ?? 'a' * 64,
);

ClusterArtifactEvidence _evidence(StudioProductionPlate plate) =>
    ClusterArtifactEvidence(
      targetSpec: const PrinterModelSpec(
        canonicalModel: 'P1S',
        nozzleDiameter: .4,
      ),
      filaments: plate.activeFilaments,
    );

StudioProductionPlate _plate(
  String id, {
  int runs = 1,
  String package = 'package',
  String workspace = 'workspace',
  bool sliced = true,
  bool? autoEject = false,
  List<StudioPlateFilamentUsage> needs = const [_white],
}) => StudioProductionPlate(
  id: id,
  workspaceId: workspace,
  orderId: 'order',
  packageId: package,
  plateIndex: id == 'b' ? 2 : 1,
  name: id,
  requiredRuns: runs,
  estimatedSeconds: 3600,
  estimatedGrams: needs.fold(0, (sum, item) => sum + item.grams),
  createdAt: _now,
  sliceStatus: sliced
      ? StudioPlateSliceStatus.sliced
      : StudioPlateSliceStatus.pending,
  filaments: needs,
  sliceArtifactPath: 'C:/private-file.gcode.3mf',
  sliceArtifactSha256: 'a' * 64,
  sliceTargetModel: 'P1S',
  sliceNozzleDiameter: .4,
  autoEjectEnabled: autoEject,
);

StudioWorkOrder _work(
  String id,
  StudioProductionPlate plate, {
  int quantity = 1,
  int? printer,
  StudioWorkOrderStatus status = StudioWorkOrderStatus.queued,
  int completed = 0,
}) => StudioWorkOrder(
  id: id,
  workspaceId: plate.workspaceId,
  orderId: plate.orderId,
  productionPlateId: plate.id,
  title: id,
  quantity: quantity,
  completedQuantity: completed,
  status: status,
  materialCostSnapshot: 0,
  quotedPriceSnapshot: 0,
  createdAt: _now,
  updatedAt: _now,
  printerId: printer,
  estimatedSeconds: plate.estimatedSeconds * quantity,
);

StudioSnapshot _snapshot({
  required List<StudioProductionPlate> plates,
  List<StudioWorkOrder>? work,
}) => StudioSnapshot(
  workspace: StudioWorkspace(
    id: 'workspace',
    name: 'workspace',
    createdAt: _now,
    updatedAt: _now,
  ),
  members: [],
  customers: [],
  orders: [
    StudioOrder(
      id: 'order',
      workspaceId: 'workspace',
      orderNo: '1',
      title: 'PRIVATE CUSTOMER',
      status: StudioOrderStatus.production,
      totalPrice: 0,
      createdAt: _now,
      updatedAt: _now,
    ),
  ],
  workOrders:
      work ??
      [
        for (final plate in plates)
          _work('pending-${plate.id}', plate, quantity: plate.requiredRuns),
      ],
  quotes: [],
  inventoryEvents: [],
  inventoryBatches: [],
  shareLinks: [],
  productionPlates: plates,
  productionPackages: [
    for (final id in plates.map((item) => item.packageId).toSet())
      StudioProductionPackage(
        id: id,
        workspaceId: 'workspace',
        orderId: 'order',
        sourceName: 'PRIVATE CUSTOMER',
        artifactKind: '3mf',
        createdAt: _now,
      ),
  ],
);

PrinterWithChannels _printer({List<ChannelWithConsumable>? slots}) =>
    PrinterWithChannels(
      Printer(
        id: 1,
        uid: 'printer1',
        brand: '拓竹',
        model: 'P1S',
        name: 'PRIVATE DEVICE',
        channelCount: 4,
        isCustomImage: false,
        createdAt: _now,
        updatedAt: _now,
      ),
      slots ?? [_slot()],
      serial: 'secret-serial',
    );

ChannelWithConsumable _slot({
  int id = 10,
  int channelIndex = 0,
  double remaining = 1000,
  bool held = false,
  String material = 'PLA',
  String color = '#FFFFFF',
}) => ChannelWithConsumable(
  PrinterChannel(
    id: id,
    printerId: 1,
    channelIndex: channelIndex,
    label: 'A',
    consumableId: 100,
    loadedRemainingGrams: remaining,
    updatedAt: _now,
  ),
  Consumable(
    id: 100,
    uid: 'spool1',
    manufacturer: 'Bambu',
    model: material,
    materialType: material,
    colorHex: color,
    totalGrams: 1000,
    remainingGrams: 1000,
    createdAt: _now,
    updatedAt: _now,
  ),
  farmRollPaused: held,
);

FleetPrinterState _fleet({
  String model = 'P1S',
  double nozzle = .4,
  bool lan = true,
  bool connected = true,
  DateTime? updated,
  BambuGcodeState gcode = BambuGcodeState.idle,
  BambuPrinterStatus? status,
}) => FleetPrinterState(
  serial: 'secret-serial',
  displayLabel: 'PRIVATE DEVICE',
  connectionState: connected
      ? PrinterConnectionState.connected
      : PrinterConnectionState.disconnected,
  lastStatus:
      status ??
      BambuPrinterStatus(
        serial: 'secret-serial',
        gcodeState: gcode,
        amsTrays: const [
          AmsTray(amsId: 0, slot: 0, hasFilament: true),
          AmsTray(amsId: 0, slot: 1, hasFilament: true),
        ],
      ),
  statusUpdatedAt: updated ?? _now,
  isLanCapable: lan,
  mode: lan ? BambuConnectionMode.lan : BambuConnectionMode.cloud,
  reportedModel: model,
  installedNozzleDiameter: nozzle,
  isConnecting: false,
);
