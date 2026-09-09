import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/error_logger.dart';
import '../core/services/product_issue_collector.dart';
import '../data/external/printer/bambu_cloud_models.dart';
import '../data/external/printer/bambu_lan_discovery.dart';
import '../data/external/printer/bambu_printer_models.dart';
import '../data/prefs/onboarding_prefs.dart';
import '../data/prefs/slicer_prefs.dart';
import 'printer_connection_provider.dart';
import 'slicer_provider.dart';

/// 引导是否已完成。完成或跳过后调 [ref.invalidate] 切换路由。
final onboardingCompletedProvider = FutureProvider<bool>((ref) async {
  return OnboardingPrefs.isCompleted();
});

/// 引导向导状态。收集各步骤中间数据，complete() 时统一落库。
class OnboardingState {
  /// 0=欢迎 1=云登录 2=扫描 3=配置打印机 4=切片 5=成本 6=完成
  final int stepIndex;
  final BambuCloudSession? cloudSession;
  final List<BambuCloudDevice> cloudDevices;
  final List<DiscoveredBambuPrinter> scannedPrinters;
  final List<PrinterConnectionConfig> configuredPrinters;
  final String? slicerExePath;
  final String? slicerOutputDir;

  /// key: electricityPrice/machinePower/machineLossRate/laborCost
  final Map<String, double>? costParams;
  final bool isProcessing;

  const OnboardingState({
    this.stepIndex = 0,
    this.cloudSession,
    this.cloudDevices = const [],
    this.scannedPrinters = const [],
    this.configuredPrinters = const [],
    this.slicerExePath,
    this.slicerOutputDir,
    this.costParams,
    this.isProcessing = false,
  });

  OnboardingState copyWith({
    int? stepIndex,
    BambuCloudSession? cloudSession,
    List<BambuCloudDevice>? cloudDevices,
    List<DiscoveredBambuPrinter>? scannedPrinters,
    List<PrinterConnectionConfig>? configuredPrinters,
    String? slicerExePath,
    String? slicerOutputDir,
    Map<String, double>? costParams,
    bool? isProcessing,
  }) {
    return OnboardingState(
      stepIndex: stepIndex ?? this.stepIndex,
      cloudSession: cloudSession ?? this.cloudSession,
      cloudDevices: cloudDevices ?? this.cloudDevices,
      scannedPrinters: scannedPrinters ?? this.scannedPrinters,
      configuredPrinters: configuredPrinters ?? this.configuredPrinters,
      slicerExePath: slicerExePath ?? this.slicerExePath,
      slicerOutputDir: slicerOutputDir ?? this.slicerOutputDir,
      costParams: costParams ?? this.costParams,
      isProcessing: isProcessing ?? this.isProcessing,
    );
  }
}

class OnboardingNotifier extends StateNotifier<OnboardingState> {
  final Ref ref;
  DateTime _startedAt = DateTime.now();
  final Set<int> _visitedSteps = {0};

  OnboardingNotifier(this.ref) : super(const OnboardingState()) {
    ProductIssueCollector.recordDetached(
      category: ProductIssueCategory.firstUse,
      outcome: 'started',
      details: _issueDetails(state, action: 'start'),
    );
  }

  static const int _totalSteps = 7;

  void next() {
    if (state.stepIndex < _totalSteps - 1) {
      state = state.copyWith(stepIndex: state.stepIndex + 1);
      _visitedSteps.add(state.stepIndex);
    }
  }

  void back() {
    if (state.stepIndex > 0) {
      state = state.copyWith(stepIndex: state.stepIndex - 1);
      _visitedSteps.add(state.stepIndex);
    }
  }

  /// 只允许返回已经经过的步骤，避免绕过当前设置流程。
  void returnToStep(int index) {
    if (state.isProcessing || index < 0 || index >= state.stepIndex) return;
    state = state.copyWith(stepIndex: index);
    _visitedSteps.add(index);
  }

  void reset() {
    state = const OnboardingState();
    _startedAt = DateTime.now();
    _visitedSteps
      ..clear()
      ..add(0);
    ProductIssueCollector.recordDetached(
      category: ProductIssueCategory.firstUse,
      outcome: 'restarted',
      details: _issueDetails(state, action: 'reset'),
    );
  }

  /// 跳过全部：只写完成标志
  Future<void> skipAll() async {
    state = state.copyWith(isProcessing: true);
    try {
      await OnboardingPrefs.setCompleted(true);
      await ProductIssueCollector.record(
        category: ProductIssueCategory.firstUse,
        outcome: 'skipped',
        durationMs: DateTime.now().difference(_startedAt).inMilliseconds,
        details: _issueDetails(state, action: 'skip_all'),
      );
      ref.invalidate(onboardingCompletedProvider);
    } catch (_) {
      await ProductIssueCollector.record(
        category: ProductIssueCategory.firstUse,
        outcome: 'failed',
        level: ErrorLevel.error,
        durationMs: DateTime.now().difference(_startedAt).inMilliseconds,
        details: _issueDetails(state, action: 'skip_all'),
      );
      rethrow;
    } finally {
      if (mounted) state = state.copyWith(isProcessing: false);
    }
  }

  void setCloudResult({
    BambuCloudSession? session,
    List<BambuCloudDevice>? devices,
  }) {
    state = state.copyWith(
      cloudSession: session ?? state.cloudSession,
      cloudDevices: devices ?? state.cloudDevices,
    );
  }

  void setScannedPrinters(List<DiscoveredBambuPrinter> printers) {
    state = state.copyWith(scannedPrinters: printers);
  }

  void setConfiguredPrinters(List<PrinterConnectionConfig> printers) {
    state = state.copyWith(configuredPrinters: printers);
  }

  void setSlicerResult({String? exePath, String? outputDir}) {
    state = state.copyWith(
      slicerExePath: exePath ?? state.slicerExePath,
      slicerOutputDir: outputDir ?? state.slicerOutputDir,
    );
  }

  void setCostParams(Map<String, double> params) {
    state = state.copyWith(costParams: params);
  }

  void setProcessing(bool value) {
    state = state.copyWith(isProcessing: value);
  }

  /// 完成：落库 + 写完成标志
  Future<void> complete() async {
    final s = state;
    state = state.copyWith(isProcessing: true);
    try {
      // 打印机连接配置
      final connectionList = ref.read(printerConnectionListProvider.notifier);
      for (final config in s.configuredPrinters) {
        await connectionList.add(config);
      }
      // 切片路径持久化（按当前活跃账号隔离）
      final accountKey = ref.read(activeAccountKeyProvider);
      if (s.slicerExePath != null) {
        await SlicerPrefs.setExeOverride(
          s.slicerExePath,
          accountKey: accountKey,
        );
      }
      if (s.slicerOutputDir != null) {
        await SlicerPrefs.setOutputOverride(
          s.slicerOutputDir,
          accountKey: accountKey,
        );
      }
      // 成本参数在 cost_params_step 中实时持久化。
      // 云 session 已在云登录步骤中持久化。
      await OnboardingPrefs.setCompleted(true);
      await ProductIssueCollector.record(
        category: ProductIssueCategory.firstUse,
        outcome: 'completed',
        durationMs: DateTime.now().difference(_startedAt).inMilliseconds,
        details: _issueDetails(s, action: 'complete'),
      );
      ref.invalidate(onboardingCompletedProvider);
    } catch (_) {
      await ProductIssueCollector.record(
        category: ProductIssueCategory.firstUse,
        outcome: 'failed',
        level: ErrorLevel.error,
        durationMs: DateTime.now().difference(_startedAt).inMilliseconds,
        details: _issueDetails(s, action: 'complete'),
      );
      rethrow;
    } finally {
      if (mounted) state = state.copyWith(isProcessing: false);
    }
  }

  Map<String, dynamic> _issueDetails(
    OnboardingState snapshot, {
    required String action,
  }) {
    return {
      'stepIndex': snapshot.stepIndex,
      'visitedSteps': _visitedSteps.length,
      'cloudConnected': snapshot.cloudSession != null,
      'printerCount': snapshot.configuredPrinters.length,
      'slicerConfigured':
          snapshot.slicerExePath != null || snapshot.slicerOutputDir != null,
      'costConfigured': snapshot.costParams != null,
      'action': action,
    };
  }
}

final onboardingProvider =
    StateNotifierProvider<OnboardingNotifier, OnboardingState>((ref) {
  return OnboardingNotifier(ref);
});
