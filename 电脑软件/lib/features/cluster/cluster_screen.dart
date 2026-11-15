import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/mifu_client.dart';
import '../../core/services/cluster_mifu_request.dart';
import '../../core/services/cluster_training_observation.dart';
import '../../core/theme/interaction_effects.dart';
import '../../providers/cluster_provider.dart';
import '../../providers/mifu_provider.dart';
import '../../ui/aurora_design.dart';
import '../../widgets/mifu_brand.dart';
import '../project_orders/personal_project_orders_screen.dart';
import 'cluster_decision_widgets.dart';
import 'cluster_assistance.dart';
import 'cluster_host_status.dart';
import 'cluster_device_details.dart';
import 'cluster_observation.dart';
import 'cluster_outcome_dialog.dart';
import 'cluster_preparation_dialog.dart';
import 'cluster_task_array.dart';

/// Native desktop cluster workspace. All numbers come from the scoped database,
/// live fleet or the local model; there is deliberately no demo-data fallback.
class ClusterScreen extends ConsumerStatefulWidget {
  const ClusterScreen({super.key});
  @override
  ConsumerState<ClusterScreen> createState() => _ClusterScreenState();
}

class _ClusterScreenState extends ConsumerState<ClusterScreen> {
  bool _checking = false;
  bool _preparing = false;
  String? _checkMessage;
  String? _pendingFingerprint, _pendingModelIdentity;
  String? _checkFingerprint, _checkModelIdentity, _decisionModelIdentity;
  String? _plateId, _selectedDevice, _requestFingerprint, _recordedRequestId;
  String _deviceSearch = '';
  String _deviceFilter = 'all', _deviceSort = 'name';
  bool _eligibleOnly = false, _limitCandidates = false;
  bool _inferring = false, _recording = false, _dispatching = false;
  int _generation = 0;
  int _selectionRevision = 0;
  Timer? _decisionExpiry;
  Timer? _checkExpiry;
  bool _invalidated = false;
  MifuDecisionRequest? _request;
  MifuDecision? _decision;
  DateTime? _decidedAt;
  String? _error;
  bool _initialPlateSelected = false;
  final _preparationCache = ClusterPreparationCache();

  List<ClusterPlatePlan> _plates(ClusterPlanningSnapshot snapshot) => [
    for (final task in snapshot.tasks)
      for (final package in task.packages) ...package.plates,
  ];

  bool _matchesDevice(ClusterPrinter printer) =>
      '${printer.name} ${printer.model}'.toLowerCase().contains(
        _deviceSearch.toLowerCase(),
      );

  List<ClusterPrinterCandidate> _candidates(
    ClusterPlanningSnapshot snapshot,
    ClusterPlatePlan? plan,
  ) {
    if (plan == null) return const [];
    final visible = snapshot.printers
        .where(_matchesDevice)
        .map((p) => p.id)
        .toSet();
    return plan.candidates
        .where((c) => !_limitCandidates || visible.contains(c.printerId))
        .toList();
  }

  String _fingerprint(
    ClusterPlanningSnapshot snapshot,
    ClusterPlatePlan plan,
    List<ClusterPrinterCandidate> candidates,
  ) => jsonEncode({
    'workspace': plan.plate.workspaceId,
    'artifactSha256': plan.plate.sliceArtifactSha256,
    'plate': plan.toModelFeatures(),
    'candidates': candidates.map((c) => c.toModelCandidate()).toList(),
    'hardware': [
      for (final candidate in candidates)
        _hardwareEvidence(snapshot, candidate.printerId),
    ],
  });

  Map<String, Object?> _hardwareEvidence(
    ClusterPlanningSnapshot snapshot,
    int printerId,
  ) {
    final device = snapshot.printers
        .where((p) => p.id == printerId)
        .firstOrNull;
    return {
      'id': printerId,
      'eligible': device?.isEligible,
      'model': device?.model,
      'nozzle_mm': device?.state?.installedNozzleDiameter,
      'connection': device?.state?.connectionState.name,
      'mode': device?.state?.mode.name,
      'lan_capable': device?.state?.isLanCapable,
    };
  }

  // GPU telemetry changes are not model changes. Contract/objective changes
  // are, even if a service reuses the same human-readable version string.
  String _modelIdentity(MifuHealth? health) => jsonEncode({
    'state': health?.trainingState ?? 'disconnected',
    'version': health?.version,
    'contract': health?.inputContract ?? 'legacy_v1',
    'objectives': (health?.supportedObjectives.toSet().toList() ?? [])..sort(),
    'contracts': (health?.supportedInputContracts.toSet().toList() ?? [])
      ..sort(),
  });

  void _clearCheck() {
    _checkExpiry?.cancel();
    _checkExpiry = null;
    _checkMessage = null;
    _checkFingerprint = null;
    _checkModelIdentity = null;
  }

  void _clearDecision() {
    _generation++;
    _decisionExpiry?.cancel();
    _decisionExpiry = null;
    _inferring = false;
    _preparing = false;
    _pendingFingerprint = null;
    _pendingModelIdentity = null;
    _decisionModelIdentity = null;
    _checking = false;
    _clearCheck();
    _recording = false;
    _invalidated = false;
    _decision = null;
    _request = null;
    _selectedDevice = null;
    _error = null;
    _requestFingerprint = null;
    _recordedRequestId = null;
    _decidedAt = null;
  }

  void _invalidateDecision() {
    _preparationCache.clear();
    _clearDecision();
    _invalidated = true;
  }

  String? _currentFingerprint(AsyncValue<ClusterPlanningSnapshot> state) {
    if (state.hasError) return null;
    final snapshot = state.valueOrNull;
    if (snapshot == null) return null;
    final plan = _plates(
      snapshot,
    ).where((p) => p.plate.id == _plateId).firstOrNull;
    return plan == null
        ? null
        : _fingerprint(snapshot, plan, _candidates(snapshot, plan));
  }

  @override
  void dispose() {
    _decisionExpiry?.cancel();
    _checkExpiry?.cancel();
    super.dispose();
  }

  Future<bool> _evidenceStillCurrent(
    int generation,
    String fingerprint,
    String modelIdentity,
  ) async {
    if (!mounted || generation != _generation) return false;
    if (ref.read(clusterPlanningSnapshotProvider).isLoading) {
      await ref.read(clusterPlanningSnapshotProvider.future);
      if (!mounted || generation != _generation) return false;
    }
    final state = ref.read(clusterPlanningSnapshotProvider);
    if (state.isLoading ||
        _currentFingerprint(state) != fingerprint ||
        _modelIdentity(ref.read(mifuHealthProvider).valueOrNull) !=
            modelIdentity) {
      setState(_invalidateDecision);
      return false;
    }
    return true;
  }

  MifuDecisionRequest _newRequest(
    ClusterPlanningSnapshot snapshot,
    ClusterPlatePlan plan,
    List<ClusterPrinterCandidate> candidates,
  ) {
    final requestId = const Uuid().v4();
    return MifuDecisionRequest(
      requestId: requestId,
      plate: plan.toModelFeatures(),
      candidates: candidates.map((c) => c.toModelCandidate()).toList(),
      observation: clusterTrainingObservation(
        snapshot,
        plan,
        candidates,
        requestId,
      ),
    );
  }

  Future<void> _infer(
    ClusterPlanningSnapshot snapshot,
    ClusterPlatePlan plan,
    List<ClusterPrinterCandidate> candidates, {
    Map<int, int?>? confirmedPreparation,
    bool editPreparation = false,
  }
  ) async {
    if (_preparing || _inferring || _checking || _recording || _dispatching) {
      return;
    }
    var generation = _generation;
    final selectionRevision = _selectionRevision;
    final fingerprint = _fingerprint(snapshot, plan, candidates);
    final initialHealth = ref.read(mifuHealthProvider).valueOrNull;
    final modelIdentity = _modelIdentity(initialHealth);
    final contract = initialHealth?.inputContract ?? 'legacy_v1';
    final MifuDecisionRequest request;
    try {
      if (contract == 'mifu-decision-v4') {
        if (initialHealth?.supportedObjectives.contains(
              'earliest_known_finish',
            ) !=
            true) {
          throw const MifuException('当前模型尚未验收完成时间比较');
        }
        // Keep an existing suggestion's timer running while the user fills
        // this dialog. Cancelling preparation must not renew that suggestion.
        setState(() {
          _preparing = true;
          _pendingFingerprint = fingerprint;
          _pendingModelIdentity = modelIdentity;
        });
        final cached = _preparationCache.read(
          fingerprint: fingerprint,
          modelIdentity: modelIdentity,
          candidateIds: candidates.map((c) => c.printerId),
          now: DateTime.now(),
        );
        final preparation = confirmedPreparation ??
            (!editPreparation && cached != null && cached.values.values.every((v) => v != null)
                ? cached.values
                : await showClusterPreparationDialog(
                    context,
                    candidates: candidates,
                    checkingOnly: false,
                    initialValues: cached?.values ?? const {},
                  ));
        if (!mounted || generation != _generation || preparation == null) {
          return;
        }
        if (!await _evidenceStillCurrent(
          generation,
          fingerprint,
          modelIdentity,
        )) {
          return;
        }
        final now = DateTime.now();
        final observedAt = confirmedPreparation == null && !editPreparation && identical(preparation, cached?.values)
            ? cached!.observedAt
            : now;
        _preparationCache.store(
          fingerprint: fingerprint,
          modelIdentity: modelIdentity,
          candidateIds: candidates.map((c) => c.printerId),
          values: preparation,
          observedAt: observedAt,
        );
        request = clusterMifuRequest(
          snapshot: snapshot,
          plan: plan,
          candidates: candidates,
          requestId: const Uuid().v4(),
          preparationSeconds: preparation,
          preparationObservedAt: observedAt,
          now: now,
        );
      } else if (contract == 'legacy_v1') {
        request = _newRequest(snapshot, plan, candidates);
      } else {
        throw const MifuException('当前模型输入版本尚不受支持');
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
      return;
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _preparing = false;
          _pendingFingerprint = null;
          _pendingModelIdentity = null;
        });
      }
    }
    generation = ++_generation;
    final version = initialHealth?.version;
    setState(() {
      _decisionExpiry?.cancel();
      _clearCheck();
      _invalidated = false;
      _inferring = true;
      _error = null;
      _decision = null;
      _request = request;
      _requestFingerprint = fingerprint;
      _decisionModelIdentity = modelIdentity;
      _recordedRequestId = null;
    });
    try {
      if (request.inputContract == 'mifu-decision-v4') {
        final check = await ref.read(mifuClientProvider).checkDecision(request);
        if (!await _evidenceStillCurrent(
          generation,
          fingerprint,
          modelIdentity,
        )) {
          return;
        }
        if (!check.canInfer) {
          throw MifuException(
            check.issues.isEmpty ? '模型或输入检查尚未就绪' : check.issues.join('；'),
          );
        }
      }
      final result = await ref.read(mifuClientProvider).decide(request);
      if (!await _evidenceStillCurrent(
        generation,
        fingerprint,
        modelIdentity,
      )) {
        return;
      }
      if (result.version != version) {
        setState(_invalidateDecision);
        return;
      }
      setState(() {
        _decision = result;
        if (_selectionRevision == selectionRevision) {
          _selectedDevice = result.choice;
        }
        _decidedAt = DateTime.now();
      });
      _decisionExpiry = Timer(const Duration(minutes: 2), () {
        if (mounted && generation == _generation) {
          setState(_invalidateDecision);
        }
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _inferring = false);
      }
    }
  }

  Future<void> _checkInput(
    ClusterPlanningSnapshot snapshot,
    ClusterPlatePlan plan,
    List<ClusterPrinterCandidate> candidates,
  ) async {
    if (_preparing || _inferring || _checking || _recording || _dispatching) {
      return;
    }
    final generation = _generation;
    final fingerprint = _fingerprint(snapshot, plan, candidates);
    final modelIdentity = _modelIdentity(
      ref.read(mifuHealthProvider).valueOrNull,
    );
    setState(() {
      _checking = true;
      _clearCheck();
      _pendingFingerprint = fingerprint;
      _pendingModelIdentity = modelIdentity;
      _error = null;
    });
    try {
      final preparation = await showClusterPreparationDialog(
        context,
        candidates: candidates,
        checkingOnly: true,
        initialValues: _preparationCache.read(
          fingerprint: fingerprint,
          modelIdentity: modelIdentity,
          candidateIds: candidates.map((c) => c.printerId),
          now: DateTime.now(),
        )?.values ?? const {},
      );
      if (!mounted || generation != _generation || preparation == null) return;
      if (!await _evidenceStillCurrent(
        generation,
        fingerprint,
        modelIdentity,
      )) {
        return;
      }
      final now = DateTime.now();
      _preparationCache.store(
        fingerprint: fingerprint,
        modelIdentity: modelIdentity,
        candidateIds: candidates.map((c) => c.printerId),
        values: preparation,
        observedAt: now,
      );
      final request = clusterMifuRequest(
        snapshot: snapshot,
        plan: plan,
        candidates: candidates,
        requestId: const Uuid().v4(),
        preparationSeconds: preparation,
        preparationObservedAt: now,
        now: now,
      );
      final check = await ref.read(mifuClientProvider).checkDecision(request);
      if (!await _evidenceStillCurrent(
        generation,
        fingerprint,
        modelIdentity,
      )) {
        return;
      }
      setState(() {
        _checkFingerprint = fingerprint;
        _checkModelIdentity = modelIdentity;
        _checkMessage = check.canInfer
            ? '比较条件已齐备'
            : check.issues.isNotEmpty
            ? check.issues.join('；')
            : check.evidencePassed
            ? '输入条件已齐备，等待模型验收'
            : '比较条件尚未齐备';
      });
      _checkExpiry = Timer(const Duration(minutes: 2), () {
        if (mounted && generation == _generation) setState(_clearCheck);
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _checking = false;
          _pendingFingerprint = null;
          _pendingModelIdentity = null;
        });
      }
    }
  }

  Future<void> _record(
    ClusterPlanningSnapshot snapshot,
    ClusterPlatePlan plan,
    List<ClusterPrinterCandidate> candidates,
    String selected,
    MifuDecision? decision,
  ) async {
    final fingerprint = _fingerprint(snapshot, plan, candidates);
    final generation = _generation;
    final selectionRevision = _selectionRevision;
    final MifuDecisionRequest request;
    try {
      request = _requestFingerprint == fingerprint && _request != null
          ? _request!
          : _newRequest(snapshot, plan, candidates);
    } catch (error) {
      setState(() => _error = '$error');
      return;
    }
    setState(() {
      _recording = true;
      // A sole eligible device is selected implicitly in the view. Persist
      // that effective selection so its receipt can be matched correctly.
      _selectedDevice = selected;
      _error = null;
      _invalidated = false;
      _request = request;
      _requestFingerprint = fingerprint;
    });
    try {
      await ref
          .read(mifuClientProvider)
          .record(
            request: request,
            selectedCandidateId: selected,
            decision: decision,
          );
      if (!mounted || generation != _generation) return;
      if (ref.read(clusterPlanningSnapshotProvider).isLoading) {
        await ref.read(clusterPlanningSnapshotProvider.future);
        if (!mounted || generation != _generation) return;
      }
      if (!mounted ||
          generation != _generation ||
          selectionRevision != _selectionRevision ||
          _selectedDevice != selected ||
          ref.read(clusterPlanningSnapshotProvider).isLoading ||
          _currentFingerprint(ref.read(clusterPlanningSnapshotProvider)) !=
              fingerprint) {
        return;
      }
      setState(() {
        _request = request;
        _requestFingerprint = fingerprint;
        _recordedRequestId = request.requestId;
      });
      _notice('选择已记录，复核后才会进入训练集');
    } catch (error) {
      if (mounted &&
          generation == _generation &&
          selectionRevision == _selectionRevision) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _recording = false);
      }
    }
  }

  Future<void> _review(
    ClusterPlatePlan plan,
    ClusterPrinterCandidate candidate,
  ) async {
    final generation = _generation;
    final selectionRevision = _selectionRevision;
    setState(() => _dispatching = true);
    try {
      // Rebuild the eligibility snapshot immediately before handing off. The
      // established project flow rechecks live telemetry, material and hash.
      final fresh = await ref.refresh(clusterPlanningSnapshotProvider.future);
      final freshPlan = _plates(
        fresh,
      ).where((p) => p.plate.id == plan.plate.id).firstOrNull;
      if (!mounted) return;
      final freshCandidate = freshPlan?.candidates
          .where((c) => c.printerId == candidate.printerId)
          .firstOrNull;
      if (generation != _generation ||
          selectionRevision != _selectionRevision ||
          _plateId != plan.plate.id ||
          freshPlan == null ||
          freshPlan.plate.workspaceId != plan.plate.workspaceId ||
          freshCandidate == null) {
        _notice('盘次或设备状态已变化，请重新选择');
        return;
      }
      await reviewPersonalClusterPlate(
        context,
        ref,
        plateId: plan.plate.id,
        preferredPrinterId: candidate.printerId,
        maxRuns: freshCandidate.maxRuns,
        validateDispatch: ref.read(clusterDispatchValidatorProvider),
      );
      if (mounted) {
        ref.invalidate(clusterPlanningSnapshotProvider);
        if (generation == _generation) setState(_clearDecision);
      }
    } catch (error) {
      if (mounted) _notice('检查未完成：$error');
    } finally {
      if (mounted) setState(() => _dispatching = false);
    }
  }

  void _notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    ref.listen(clusterPlanningSnapshotProvider, (previous, next) {
      // Keep ordinary telemetry refreshes usable, but permanently retire a
      // request when its facts change. Hiding it during a mismatch would allow
      // an obsolete result to reappear when the same facts later return.
      if (next.isLoading) return;
      final oldWorkspace = previous?.valueOrNull?.studio.workspace.id;
      final newWorkspace = next.valueOrNull?.studio.workspace.id;
      final snapshot = next.valueOrNull;
      final plan = snapshot == null
          ? null
          : _plates(snapshot).where((p) => p.plate.id == _plateId).firstOrNull;
      final fingerprint = _currentFingerprint(next);
      if (oldWorkspace != null && newWorkspace != oldWorkspace) {
        setState(() {
          _preparationCache.clear();
          _clearDecision();
          _plateId = null;
          _initialPlateSelected = false;
        });
      } else if (_plateId != null && !next.hasError && plan == null) {
        setState(() {
          _clearDecision();
          _plateId = null;
        });
      } else if ((_selectedDevice != null &&
              (plan == null ||
                  !_candidates(
                    snapshot!,
                    plan,
                  ).any((c) => '${c.printerId}' == _selectedDevice))) ||
          (_request != null && _requestFingerprint != fingerprint) ||
          (_pendingFingerprint != null && _pendingFingerprint != fingerprint) ||
          (_checkFingerprint != null && _checkFingerprint != fingerprint)) {
        setState(_invalidateDecision);
      }
    });
    ref.listen(mifuHealthProvider, (previous, next) {
      if (next.isLoading) return;
      final identity = _modelIdentity(next.valueOrNull);
      if (((_decision != null || _inferring) &&
              _decisionModelIdentity != identity) ||
          (_pendingModelIdentity != null &&
              _pendingModelIdentity != identity) ||
          (_checkModelIdentity != null && _checkModelIdentity != identity)) {
        setState(_invalidateDecision);
      }
    });
    final snapshot = ref.watch(clusterPlanningSnapshotProvider);
    final health =
        ref.watch(mifuHealthProvider).valueOrNull ??
        const MifuHealth.disconnected();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: snapshot.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('集群数据暂不可用'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () =>
                    ref.invalidate(clusterPlanningSnapshotProvider),
                child: const Text('重新读取'),
              ),
            ],
          ),
        ),
        data: (snapshot) => _workspace(snapshot, health),
      ),
    );
  }

  Widget _workspace(ClusterPlanningSnapshot snapshot, MifuHealth health) {
    final plans = _plates(snapshot);
    if (!_initialPlateSelected && plans.isNotEmpty) {
      _initialPlateSelected = true;
      final initial = selectClusterPendingPlate(plans);
      if (initial != null) {
        _plateId = initial.plate.id;
      }
    }
    final plan = plans.where((p) => p.plate.id == _plateId).firstOrNull;
    final candidates = _candidates(snapshot, plan);
    final fingerprint = plan == null
        ? null
        : _fingerprint(snapshot, plan, candidates);
    final stale =
        _invalidated ||
        (_decision != null &&
            (_requestFingerprint != fingerprint ||
                !health.ready ||
                health.version != _decision!.version ||
                _modelIdentity(health) != _decisionModelIdentity ||
                _decidedAt == null ||
                DateTime.now().difference(_decidedAt!) >
                    const Duration(minutes: 2)));
    final decision = stale ? null : _decision;
    final selected =
        candidates
            .where((c) => '${c.printerId}' == _selectedDevice)
            .firstOrNull ??
        (candidates.length == 1 ? candidates.single : null);
    final observations = {
      for (final printer in snapshot.printers)
        printer.id: ClusterDeviceObservation.from(printer),
    };
    final printing = observations.values.where((o) => o.printing).length;
    final attention = observations.values.where((o) => o.needsAttention).length;
    final blocked = plans
        .where(
          (p) =>
              p.remainingRuns > 0 &&
              (p.blockers.isNotEmpty || p.candidates.isEmpty),
        )
        .length;
    return LayoutBuilder(
      builder: (context, bounds) {
        final wide =
            bounds.maxWidth >= 1000 &&
            MediaQuery.textScalerOf(context).scale(1) < 1.4;
        final panelHeight = (bounds.maxHeight - 210).clamp(460.0, 1100.0);
        final left = ClusterTaskArray(
          snapshot: snapshot,
          selectedPlateId: plan?.plate.id,
          onSelectPlate: _dispatching
              ? null
              : (next) => setState(() {
                  if (_plateId == next.plate.id) return;
                  _preparationCache.clear();
                  _clearDecision();
                  _plateId = next.plate.id;
                }),
        );
        final middle = _decisionPanel(
          snapshot,
          plan,
          candidates,
          selected,
          decision,
          stale,
          health,
        );
        final right = _devices(snapshot, plan, candidates, selected);
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 20,
                runSpacing: 14,
                children: [
                  const Text(
                    '生产集群',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                  ClusterHostStatus(health: health, onOpenDetails: () => _modelDetails(health)),
                ],
              ),
              const SizedBox(height: 10),
              FrostPanel(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    _number('设备总数', '${snapshot.printers.length}'),
                    _number('打印中', '$printing'),
                    _number('设备待核对', '$attention'),
                    _number(
                      '通过设备检查',
                      '${snapshot.printers.where((p) => p.isEligible).length}',
                    ),
                    _number('受阻打印盘', '$blocked'),

                    _number(
                      '待分配盘次',
                      '${plans.fold<int>(0, (v, p) => v + p.remainingRuns)}',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (wide)
                SizedBox(
                  height: panelHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 28, child: left),
                      const SizedBox(width: 10),
                      Expanded(flex: 32, child: middle),
                      const SizedBox(width: 10),
                      Expanded(flex: 40, child: right),
                    ],
                  ),
                )
              else ...[
                SizedBox(height: 400, child: left),
                const SizedBox(height: 12),
                SizedBox(height: 660, child: middle),
                const SizedBox(height: 12),
                SizedBox(height: 500, child: right),
              ],
              const SizedBox(height: 6),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 12,
                children: [
                  Text(
                    '更新于 ${clusterTimestamp(snapshot.generatedAt)}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  TextButton.icon(
                    onPressed: _dispatching
                        ? null
                        : () => ref.invalidate(clusterPlanningSnapshotProvider),
                    icon: const Icon(Icons.sync, size: 14),
                    label: const Text('刷新状态'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _modelDetails(MifuHealth health) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('mifu-model-details'),
        alignment: Alignment.center,
        title: const Text('模型与计算节点'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const MifuBrandDetails(),
                const Divider(height: 24),
                _detailRow(
                  '本机服务',
                  health.trainingState == 'disconnected' ? '未连接' : '已连接',
                ),
                _detailRow('模型状态', health.label),
                _detailRow('权重版本', health.version ?? '尚未配置'),
                _detailRow('推理设备', health.device ?? '未启用'),
                _detailRow('GPU', health.gpuName ?? '未取得'),
                if (!health.ready) ...[
                  const Divider(height: 24),
                  const Text(
                    '连接检查',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(switch (health.trainingState) {
                    'disconnected' =>
                      '启动本机 Mifu 服务（127.0.0.1:27961），并确认软件与服务使用相同的 MIFU_API_TOKEN。',
                    'loading' => '权重正在加载，完成后可重新比较候选。',
                    'error' => '检查本机 Mifu 服务日志及权重配置，恢复后再比较。',
                    _ => '本机服务已连接；配置经过评估的专属权重后才能比较。',
                  }),
                  const SizedBox(height: 6),
                  const Text('打开本页不会自动下载权重或启动训练。'),
                ],
                const Divider(height: 28),
                const Text(
                  '远程训练节点',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text('尚未接入本界面。此处 GPU 数据来自本机服务，不代表远端 4070。'),
                const SizedBox(height: 16),
                const Text(
                  '数据闭环',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text('人工选择 → 独立复核 → 离线训练 → 独立评估\n接受建议不自动成为训练标签。'),
                const SizedBox(height: 12),
                const Text('设备分、维修验收和整单交付预测尚未接入；未训练时不显示替代概率。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        Text(value),
      ],
    ),
  );

  Widget _number(String label, String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      const SizedBox(width: 8),
      Text(
        value.padLeft(2, '0'),
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    ],
  );
  Widget _panel(String title, String tag, Widget body, {Widget? trailing}) =>
      FrostPanel(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(tag, style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 10),
            Expanded(child: body),
          ],
        ),
      );

  Widget _decisionPanel(
    ClusterPlanningSnapshot snapshot,
    ClusterPlatePlan? plan,
    List<ClusterPrinterCandidate> candidates,
    ClusterPrinterCandidate? selected,
    MifuDecision? decision,
    bool stale,
    MifuHealth health,
  ) {
    final ordered = [...candidates];
    final refreshing = ref.watch(clusterPlanningSnapshotProvider).isLoading;
    final scheme = Theme.of(context).colorScheme;
    if (decision != null) {
      ordered.sort(
        (a, b) => decision.probabilities['${b.printerId}']!.compareTo(
          decision.probabilities['${a.printerId}']!,
        ),
      );
    }
    final canInfer =
        plan != null &&
        candidates.length >= 2 &&
        candidates.length <= 16 &&
        health.ready &&
        !refreshing &&
        !_inferring &&
        !_preparing &&
        !_checking &&
        !_recording &&
        !_dispatching;
    final alreadyRecorded =
        _recordedRequestId != null &&
        _recordedRequestId == _request?.requestId &&
        plan != null &&
        _requestFingerprint == _fingerprint(snapshot, plan, candidates);
    final recommended = decision == null ? null : candidates.where((c) => '${c.printerId}' == decision.choice).firstOrNull;
    final content = <Widget>[
      if (plan == null) ...[
        const SizedBox(height: 24),
        Icon(
          Icons.layers_outlined,
          size: 30,
          color: scheme.onSurfaceVariant.withValues(alpha: .5),
        ),
        _empty('选择一个打印盘', '先看候选，再作决策'),
        _modelReadiness(health),
      ] else ...[
        MifuPlateSummary(
          plan: plan,
          duration: _duration(plan.plate.estimatedSeconds),
        ),
        const SizedBox(height: 10),
        MifuCandidateSummary(
          total: snapshot.printers.length,
          eligible: plan.candidates.length,
          compared: candidates.length,
        ),
        const SizedBox(height: 12),
        MifuRecommendationCard(
          plan: plan,
          candidate: recommended ?? (candidates.length == 1 ? candidates.single : null),
          candidateCount: candidates.length,
          request: decision == null ? null : _request,
          modelRecommended: recommended != null,
          busy: _inferring || _checking,
          ready: health.ready,
          stale: stale,
          onReadyToCompare: canInfer && health.inputContract == 'mifu-decision-v4'
              ? () => _infer(snapshot, plan, candidates, confirmedPreparation: {for (final candidate in candidates) candidate.printerId: 0})
              : null,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: '概率只在本次候选中比较，不是打印成功率。',
                child: Text(
                  decision == null ? '可选设备' : '设备比较',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            if (health.supportsV4Check)
              TextButton(
                onPressed: canInfer || (!health.ready && candidates.length >= 2 && candidates.length <= 16 && !refreshing && !_checking && !_inferring && !_preparing && !_recording && !_dispatching)
                    ? () => _checkInput(snapshot, plan, candidates)
                    : null,
                child: Text(_checking ? '检查中' : '检查条件'),
              ),
            TextButton(
              onPressed: () => _details(snapshot, plan, decision),
              child: const Text('详情'),
            ),
          ],
        ),
        if (_inferring)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        if (stale)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              '状态已变化，请重新决策',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        if (candidates.isEmpty)
          _empty(
            '暂无可分配设备',
            plan.blockers.isEmpty ? '查看详情检查设备与材料' : plan.blockers.first,
          ),
        if (candidates.length == 1)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text('仅一台适配设备，无需模型比较', style: TextStyle(fontSize: 11)),
          ),
        if (candidates.length > 16)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text(
              '候选超过 16 台，请用右侧搜索限定本次候选',
              style: TextStyle(fontSize: 11),
            ),
          ),
        for (final candidate in ordered)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: MifuCandidateTile(
              candidate: candidate,
              selected: selected?.printerId == candidate.printerId,
              probability: decision?.probabilities['${candidate.printerId}'],
              recommended: recommended?.printerId == candidate.printerId,
              onTap: () => setState(() {
                _selectionRevision++;
                _selectedDevice = '${candidate.printerId}';
                _recordedRequestId = null;
              }),
            ),
          ),
      ],
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            _error!,
            style: TextStyle(fontSize: 12, color: scheme.error),
          ),
        ),
      if (_checkMessage != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(_checkMessage!, style: const TextStyle(fontSize: 12)),
        ),
    ];
    final actions = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(height: 20, color: scheme.onSurface.withValues(alpha: .08)),
        if (selected != null) ...[
          Text(
            '当前选择 · ${selected.printerName}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: canInfer
                  ? () => _infer(snapshot, plan, candidates)
                  : null,
              icon: const Icon(Icons.compare_arrows_rounded, size: 15),
              label: Text(_inferring ? '推理中' : '重新决策'),
            ),
            OutlinedButton(
              onPressed:
                  selected == null ||
                      plan == null ||
                      _recording ||
                      _inferring ||
                      _preparing ||
                      _checking ||
                      _dispatching ||
                      refreshing ||
                      alreadyRecorded ||
                      health.trainingState == 'disconnected' ||
                      candidates.isEmpty ||
                      candidates.length > 16
                  ? null
                  : () => _record(
                      snapshot,
                      plan,
                      candidates,
                      '${selected.printerId}',
                      decision,
                    ),
              child: Text(
                alreadyRecorded
                    ? '已记录'
                    : _recording
                    ? '保存中'
                    : '记录选择',
              ),
            ),
            OutlinedButton.icon(
              onPressed:
                  plan == null ||
                      _recording ||
                      refreshing ||
                      health.trainingState == 'disconnected'
                  ? null
                  : () => showClusterOutcomeDialog(
                      context,
                      client: ref.read(mifuClientProvider),
                      plateId: plan.plate.id,
                      plateName:
                          'P${plan.plate.plateIndex} · ${plan.plate.name}',
                      visiblePrinters: {
                        for (final printer in snapshot.printers)
                          '${printer.id}': printer.name,
                      },
                    ),
              icon: const Icon(Icons.fact_check_outlined, size: 15),
              label: const Text('打印结果'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const ValueKey('mifu-primary-action'),
          onPressed:
              plan == null ||
                  _dispatching ||
                  refreshing ||
                  _recording ||
                  _preparing ||
                  _checking ||
                  _inferring
              ? null
              : selected != null
                  ? () => _review(plan, selected)
                  : canInfer ? () => _infer(snapshot, plan, candidates) : null,
          icon: const Icon(Icons.arrow_forward, size: 16),
          label: Text(_dispatching ? '检查中' : selected != null ? '检查并排产' : '智能推荐'),
        ),
        const SizedBox(height: 6),
        Text(
          selected != null ? '确认设备与份数后开始' : '自动检查条件并比较设备',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
        ),
      ],
    );
    return FrostPanel(
      key: const ValueKey('mifu-decision-panel'),
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(
        builder: (context, bounds) {
          // On small or enlarged-text layouts the footer joins the scroll, so
          // actions never consume all space needed for candidate inspection.
          final inlineActions =
              bounds.maxHeight < 600 ||
              MediaQuery.textScalerOf(context).scale(1) >= 1.4;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MifuDecisionHeader(
                health: health,
                inferring: _inferring,
                onDetails: () => _modelDetails(health),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  key: const ValueKey('mifu-decision-scroll'),
                  padding: EdgeInsets.zero,
                  children: [...content, if (inlineActions) actions],
                ),
              ),
              if (!inlineActions) actions,
            ],
          );
        },
      ),
    );
  }

  Widget _modelReadiness(MifuHealth health) => Container(
    alignment: Alignment.center,
    child: TextButton.icon(
      onPressed: () => _modelDetails(health),
      icon: const Icon(Icons.account_tree_outlined, size: 14),
      label: const Text('模型与训练状态'),
    ),
  );

  Widget _devices(
    ClusterPlanningSnapshot snapshot,
    ClusterPlatePlan? plan,
    List<ClusterPrinterCandidate> candidates,
    ClusterPrinterCandidate? selected,
  ) {
    final ids = candidates.map((c) => c.printerId).toSet();
    final observed = {
      for (final p in snapshot.printers) p.id: ClusterDeviceObservation.from(p),
    };
    final devices =
        snapshot.printers
            .where(
              (p) =>
                  _matchesDevice(p) &&
                  (!_eligibleOnly || ids.contains(p.id)) &&
                  (_deviceFilter != 'attention' ||
                      observed[p.id]!.needsAttention) &&
                  (_deviceFilter != 'printing' || observed[p.id]!.printing),
            )
            .toList()
          ..sort((a, b) {
            if (_deviceSort == 'queue') {
              final result = a.activeQueueCount.compareTo(b.activeQueueCount);
              if (result != 0) return result;
            }
            return a.name.compareTo(b.name);
          });
    return _panel(
      '打印机阵列',
      '${devices.length} / ${snapshot.printers.length} 台 · 名称视图',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            decoration: const InputDecoration(
              hintText: '搜索设备名、机型',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            onChanged: (v) => setState(() {
              _deviceSearch = v;
              if (_limitCandidates) _clearDecision();
            }),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              FilterChip(
                label: Text(
                  '只看适配',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(fontSize: 11),
                ),
                selected: _eligibleOnly,
                onSelected: plan == null
                    ? null
                    : (v) => setState(() => _eligibleOnly = v),
              ),
              FilterChip(
                label: Text(
                  '打印中',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(fontSize: 11),
                ),
                selected: _deviceFilter == 'printing',
                onSelected: (v) =>
                    setState(() => _deviceFilter = v ? 'printing' : 'all'),
              ),
              FilterChip(
                label: Text(
                  '需处理',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(fontSize: 11),
                ),
                selected: _deviceFilter == 'attention',
                onSelected: (v) =>
                    setState(() => _deviceFilter = v ? 'attention' : 'all'),
              ),
              FilterChip(
                label: Text(
                  '搜索限定候选',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(fontSize: 11),
                ),
                selected: _limitCandidates,
                onSelected: (v) => setState(() {
                  _limitCandidates = v;
                  _clearDecision();
                }),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: devices.isEmpty
                ? _empty(
                    snapshot.printers.isEmpty ? '没有设备' : '没有匹配设备',
                    snapshot.printers.isEmpty ? '请先添加设备' : '调整搜索或筛选条件',
                  )
                : LayoutBuilder(
                    builder: (context, bounds) {
                      final scale = MediaQuery.textScalerOf(context).scale(1);
                      return GridView.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: scale < 1.3
                              ? (bounds.maxWidth / 180).floor().clamp(1, 4)
                              : 1,
                          mainAxisExtent: 158 + (scale - 1).clamp(0, 2) * 160,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: devices.length,
                        itemBuilder: (context, index) {
                          final printer = devices[index];
                          final observation = observed[printer.id]!;
                          final eligible = ids.contains(printer.id);
                          return _selectable(
                            selected: selected?.printerId == printer.id,
                            onTap: () {
                              if (eligible) {
                                setState(() {
                                  _selectionRevision++;
                                  _selectedDevice = '${printer.id}';
                                  _recordedRequestId = null;
                                });
                              } else {
                                showClusterDeviceDetails(
                                  context,
                                  printer: printer,
                                  snapshot: snapshot,
                                  plan: plan,
                                );
                              }
                            },
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Tooltip(
                                        message: printer.name,
                                        child: Text(
                                          printer.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 30,
                                      height: 32,
                                      child: IconButton(
                                        tooltip: '查看${printer.name}档案',
                                        padding: EdgeInsets.zero,
                                        onPressed: () =>
                                            showClusterDeviceDetails(
                                              context,
                                              printer: printer,
                                              snapshot: snapshot,
                                              plan: plan,
                                            ),
                                        icon: const Icon(
                                          Icons.more_horiz,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  printer.model,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 5,
                                  runSpacing: 4,
                                  children: [
                                    _tag(
                                      observation.label,
                                      warning: observation.needsAttention,
                                    ),
                                    if (plan != null)
                                      _tag(
                                        eligible ? '本盘可选' : '本盘不适配',
                                        muted: !eligible,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                if (observation.progress != null)
                                  Semantics(
                                    label:
                                        '打印进度 ${(observation.progress! * 100).round()}%',
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: LinearProgressIndicator(
                                            value: observation.progress,
                                            minHeight: 3,
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          '${(observation.progress! * 100).round()}%',
                                          style: const TextStyle(fontSize: 10),
                                        ),
                                      ],
                                    ),
                                  )
                                else
                                  Text(
                                    clusterMachineWait(
                                      observation.fresh
                                          ? printer.availableAfterSeconds
                                          : null,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                const Spacer(),
                                Text(
                                  '活动队列 ${printer.activeQueueCount < 0 ? '未知' : printer.activeQueueCount}',
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '设备排序',
        initialValue: _deviceSort,
        onSelected: (v) => setState(() => _deviceSort = v),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'name', child: Text('按设备名称')),
          PopupMenuItem(value: 'queue', child: Text('按队列数量')),
        ],
        icon: const Icon(Icons.sort, size: 18),
      ),
    );
  }

  Widget _tag(String text, {bool warning = false, bool muted = false}) {
    final colors = Theme.of(context).colorScheme;
    final base = warning
        ? colors.error
        : muted
        ? colors.onSurfaceVariant
        : colors.primary;
    final color = Theme.of(context).brightness == Brightness.dark && !muted
        ? Color.lerp(base, Colors.white, .35)!
        : base;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: .16)),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }

  Widget _selectable({
    required bool selected,
    required Widget child,
    VoidCallback? onTap,
  }) => AnimatedContainer(
    duration: AppMotion.duration(context, const Duration(milliseconds: 180)),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: selected ? .12 : .025),
      border: Border.all(
        color: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: .7)
            : Theme.of(context).dividerColor.withValues(alpha: .3),
      ),
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(11), child: child),
      ),
    ),
  );

  Widget _empty(String title, String hint) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.hub_outlined,
          size: 30,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          hint,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11),
        ),
      ],
    ),
  );

  String _duration(int seconds) => clusterDuration(seconds);

  void _details(
    ClusterPlanningSnapshot snapshot,
    ClusterPlatePlan plan,
    MifuDecision? decision,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('决策详情'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'P${plan.plate.plateIndex.toString().padLeft(2, '0')} · ${plan.plate.name}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                _detailRow('切片目标', plan.plate.sliceTargetModel ?? '未取得'),
                _detailRow(
                  '喷嘴要求',
                  plan.plate.sliceNozzleDiameter == null
                      ? '未取得'
                      : '${plan.plate.sliceNozzleDiameter} mm',
                ),
                _detailRow(
                  '盘次需求',
                  '${plan.plate.requiredRuns} 次 · 待安排 ${plan.remainingRuns} 次',
                ),
                _detailRow(
                  '当前进展',
                  '已安排 ${plan.assignedRuns} 次 · 技术完成 ${plan.completedRuns} 次',
                ),
                _detailRow(
                  '交期',
                  plan.dueAt == null ? '未设置' : clusterTimestamp(plan.dueAt!),
                ),
                _detailRow('快照时间', clusterTimestamp(snapshot.generatedAt)),
                const Divider(height: 24),
                const Text(
                  '候选与依据',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                if (decision != null)
                  Text(
                    '模型 ${decision.version} · ${decision.elapsedMs.toStringAsFixed(0)} ms\n偏好概率不是打印成功率，也不是思维链。',
                  ),
                if (decision == null) const Text('尚无本盘模型输出。候选列表不代表模型排名。'),
                const SizedBox(height: 12),
                Text(
                  '通过检查 ${plan.candidates.length} 台 · 排除 ${plan.rejections.length} 台',
                ),
                const SizedBox(height: 8),
                for (final reason in plan.blockers) Text('• $reason'),
                for (final rejection in plan.rejections.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${snapshot.printers.where((p) => p.id == rejection.key).firstOrNull?.name ?? '设备 ${rejection.key}'}：${rejection.value.join('、')}',
                    ),
                  ),
                const SizedBox(height: 16),
                const Text('机器等待只是已知占用估计，不含取件和准备；技术完成不等于质检通过。'),
                const SizedBox(height: 10),
                const Text('“记录选择”只采集人工反馈。复核标签、独立评估后才用于 Mifu 后训练。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
