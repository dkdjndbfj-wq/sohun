import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/error_logger.dart';
import '../data/database/daos/preset_result_dao.dart';
import '../data/external/print_task/gram_calculator.dart';
import '../data/external/slicer/bambu_studio_detector.dart';
import '../data/external/slicer/gcode_watcher.dart';
import '../data/external/slicer/slicer_detector.dart';
import '../data/external/slicer/slice_isolate_runner.dart';
import '../data/external/slicer/slice_result.dart';
import '../data/prefs/app_prefs.dart';
import '../data/prefs/slicer_prefs.dart';
import 'bambu_account_manager.dart';
import 'database_provider.dart';
import 'farm_slice_intake_provider.dart';
import 'print_task_provider.dart';

/// 当前活跃拓竹云账号的标识（"email|region_code" 格式），未登录为 null。
/// 用于切片软件配置按账号隔离：切换账号后切片 exe/output 路径自动加载该账号的配置。
final activeAccountKeyProvider = Provider<String?>((ref) {
  final state = ref.watch(bambuAccountManagerProvider);
  final email = state.activeAccountEmail;
  final region = state.activeRegion;
  if (email == null || region == null) return null;
  return '$email|${region.code}';
});

/// 切片文件读取方式（持久化，默认 onDemand）。
/// 切换后控制 [SlicerWatcherNotifier] 是否启动目录监听。
/// 读取方式为个人偏好，全局共享不按账号隔离。
class SliceReadModeNotifier extends StateNotifier<SliceReadMode> {
  SliceReadModeNotifier() : super(SliceReadMode.onDemand) {
    _load();
  }

  Future<void> _load() async {
    final mode = await SlicerPrefs.getReadMode();
    if (mounted) state = mode;
  }

  Future<void> setMode(SliceReadMode mode) async {
    await SlicerPrefs.setReadMode(mode);
    state = mode;
  }
}

final sliceReadModeProvider =
    StateNotifierProvider<SliceReadModeNotifier, SliceReadMode>((ref) {
      return SliceReadModeNotifier();
    });

/// 所有已检测到的切片软件状态列表。
/// 应用启动时自动扫描所有注册的切片软件。
final slicerStatusListProvider = FutureProvider<List<SlicerStatus>>((
  ref,
) async {
  return SlicerRegistry.detectAll();
});

/// 当前选中的切片软件 ID。
///
/// 选择会写入 SharedPreferences，应用重启后继续使用上次选择。
/// 已移除或不再支持的切片器 ID 会安全回退到 Bambu Studio，
/// 但不会覆盖存储值，以便未来重新支持该切片器时自动恢复。
class ActiveSlicerIdNotifier extends StateNotifier<String> {
  static const defaultId = 'bambu_studio';

  int _generation = 0;

  ActiveSlicerIdNotifier() : super(defaultId) {
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final persisted = await SlicerPrefs.getActiveSlicerId();
    if (!mounted || generation != _generation) return;
    if (persisted != null && SlicerRegistry.byId(persisted) != null) {
      state = persisted;
    }
  }

  /// 选择已注册的切片软件并持久化。
  ///
  /// 未注册的 ID 被忽略，避免 provider 进入无法检测的死状态。
  Future<void> setId(String id) async {
    if (SlicerRegistry.byId(id) == null) return;
    final generation = ++_generation;
    await SlicerPrefs.setActiveSlicerId(id);
    if (mounted && generation == _generation) state = id;
  }
}

/// 当前选中的切片软件 id。
/// 默认 'bambu_studio'。
final activeSlicerIdProvider =
    StateNotifierProvider<ActiveSlicerIdNotifier, String>((ref) {
      return ActiveSlicerIdNotifier();
    });

/// 当前选中的切片软件检测器。
final activeSlicerDetectorProvider = Provider<SlicerDetector?>((ref) {
  final id = ref.watch(activeSlicerIdProvider);
  return SlicerRegistry.byId(id);
});

/// 用户手动覆盖的切片软件可执行文件路径。
/// 为 null 时用自动检测结果。
///
/// 按拓竹云账号隔离：监听 [activeAccountKeyProvider]，切换账号后自动重新加载
/// 该账号的配置；未配置过则返回 null 走自动检测。
class SlicerExeOverrideNotifier extends StateNotifier<String?> {
  final Ref ref;
  int _generation = 0;

  SlicerExeOverrideNotifier(this.ref) : super(null) {
    // 监听账号变化，重新加载该账号的切片配置（fireImmediately 启动时加载一次）
    ref.listen<String?>(activeAccountKeyProvider, (_, accountKey) {
      _load(accountKey);
    }, fireImmediately: true);
  }

  Future<void> _load(String? accountKey) async {
    final generation = ++_generation;
    final path = await SlicerPrefs.getExeOverride(accountKey: accountKey);
    if (mounted && generation == _generation) state = path;
  }

  Future<void> setPath(String? path) async {
    final accountKey = ref.read(activeAccountKeyProvider);
    final generation = ++_generation;
    await SlicerPrefs.setExeOverride(path, accountKey: accountKey);
    if (mounted &&
        generation == _generation &&
        ref.read(activeAccountKeyProvider) == accountKey) {
      state = path;
    }
  }
}

final slicerExecutableOverrideProvider =
    StateNotifierProvider<SlicerExeOverrideNotifier, String?>((ref) {
      return SlicerExeOverrideNotifier(ref);
    });

/// 用户手动覆盖的切片软件输出目录。
/// 为 null 时用自动检测结果。
///
/// 按拓竹云账号隔离：监听 [activeAccountKeyProvider]，切换账号后自动重新加载
/// 该账号的配置；未配置过则返回 null 走自动检测。
class SlicerOutputOverrideNotifier extends StateNotifier<String?> {
  final Ref ref;
  int _generation = 0;

  SlicerOutputOverrideNotifier(this.ref) : super(null) {
    ref.listen<String?>(activeAccountKeyProvider, (_, accountKey) {
      _load(accountKey);
    }, fireImmediately: true);
  }

  Future<void> _load(String? accountKey) async {
    final generation = ++_generation;
    final path = await SlicerPrefs.getOutputOverride(accountKey: accountKey);
    if (mounted && generation == _generation) state = path;
  }

  Future<void> setPath(String? path) async {
    final accountKey = ref.read(activeAccountKeyProvider);
    final generation = ++_generation;
    await SlicerPrefs.setOutputOverride(path, accountKey: accountKey);
    if (mounted &&
        generation == _generation &&
        ref.read(activeAccountKeyProvider) == accountKey) {
      state = path;
    }
  }
}

final slicerOutputOverrideProvider =
    StateNotifierProvider<SlicerOutputOverrideNotifier, String?>((ref) {
      return SlicerOutputOverrideNotifier(ref);
    });

/// 当前切片软件的综合状态（合并自动检测 + 用户覆盖）。
final activeSlicerStatusProvider = FutureProvider<SlicerStatus?>((ref) async {
  final detector = ref.watch(activeSlicerDetectorProvider);
  if (detector == null) return null;

  final overrideExe = ref.watch(slicerExecutableOverrideProvider);
  final overrideOut = ref.watch(slicerOutputOverrideProvider);

  final exe = overrideExe ?? await detector.detectExecutable();
  final out = overrideOut ?? await detector.detectOutputDirectory();

  return SlicerStatus(
    detector: detector,
    executablePath: exe,
    outputDirectory: out,
    isInstalled: exe != null,
  );
});

/// 切片文件监听器状态。
/// 监听当前切片软件的输出目录，新切片完成时自动解析并通知。
class SlicerWatcherState {
  final bool isWatching;
  final String? watchDirectory;
  final List<SliceResult> recentSlices;
  final SliceResult? latestSlice;
  final String? error;

  const SlicerWatcherState({
    this.isWatching = false,
    this.watchDirectory,
    this.recentSlices = const [],
    this.latestSlice,
    this.error,
  });

  SlicerWatcherState copyWith({
    bool? isWatching,
    String? watchDirectory,
    List<SliceResult>? recentSlices,
    SliceResult? latestSlice,
    String? error,
  }) {
    return SlicerWatcherState(
      isWatching: isWatching ?? this.isWatching,
      watchDirectory: watchDirectory ?? this.watchDirectory,
      recentSlices: recentSlices ?? this.recentSlices,
      latestSlice: latestSlice ?? this.latestSlice,
      error: error,
    );
  }
}

class SlicerWatcherNotifier extends StateNotifier<SlicerWatcherState> {
  final Ref ref;
  GcodeWatcher? _watcher;
  // Listener callbacks can request a restart faster than the previous
  // DirectoryWatcher can stop/scan.  A generation token prevents an older
  // start/scan from replacing the state (or delivering slices) after a newer
  // directory has already been selected.
  int _watchGeneration = 0;

  SlicerWatcherNotifier(this.ref) : super(const SlicerWatcherState()) {
    // 监听切片软件状态变化，自动重启监听（仅 watch 模式）
    ref.listen<AsyncValue<SlicerStatus?>>(activeSlicerStatusProvider, (
      previous,
      next,
    ) {
      final mode = ref.read(sliceReadModeProvider);
      if (mode != SliceReadMode.watch && !ref.read(studioModeEnabledProvider)) {
        return;
      }
      final status = next.maybeWhen(data: (s) => s, orElse: () => null);
      if (status != null && status.outputDirectory != null) {
        startWatching(status.outputDirectory!);
      } else {
        stopWatching();
      }
    });

    // 监听读取方式切换：切到 watch 时启动监听，切到 onDemand 时停止
    ref.listen<SliceReadMode>(sliceReadModeProvider, (previous, next) {
      if (next == SliceReadMode.watch || ref.read(studioModeEnabledProvider)) {
        final status = ref
            .read(activeSlicerStatusProvider)
            .maybeWhen(data: (s) => s, orElse: () => null);
        if (status?.outputDirectory != null) {
          startWatching(status!.outputDirectory!);
        }
      } else {
        stopWatching();
      }
    });

    // Farm mode always needs the slicer inbox, even when the personal-mode
    // preference is still set to on-demand reading.
    ref.listen<bool>(studioModeEnabledProvider, (previous, enabled) {
      if (enabled) {
        final status = ref
            .read(activeSlicerStatusProvider)
            .maybeWhen(data: (s) => s, orElse: () => null);
        if (status?.outputDirectory != null) {
          startWatching(status!.outputDirectory!);
        }
      } else if (ref.read(sliceReadModeProvider) != SliceReadMode.watch) {
        stopWatching();
      }
    });
  }

  @override
  void dispose() {
    ++_watchGeneration;
    _watcher?.stop();
    super.dispose();
  }

  Future<void> startWatching(String directory) async {
    final generation = ++_watchGeneration;
    final previous = _watcher;
    _watcher = null;
    await previous?.stop();
    if (!mounted || generation != _watchGeneration) return;
    state = SlicerWatcherState(watchDirectory: directory);

    final enableLayerMapping =
        ref.read(printTaskCalculationModeProvider) == CalculationMode.precise;

    late final GcodeWatcher watcher;
    watcher = GcodeWatcher(
      directoryPath: directory,
      enableLayerMapping: enableLayerMapping,
      onSliceCompleted: (result) {
        if (result == null || !mounted || generation != _watchGeneration)
          return;
        unawaited(_acceptCompletedSlice(result, generation));
      },
      onError: (e) {
        if (!mounted || generation != _watchGeneration) return;
        state = state.copyWith(error: e.toString());
      },
    );
    _watcher = watcher;

    final ok = await watcher.start();
    if (!mounted ||
        generation != _watchGeneration ||
        !identical(_watcher, watcher)) {
      await watcher.stop();
      return;
    }
    if (ok) {
      // 启动时扫描已有文件
      final existing = await watcher.scanExisting();
      if (!mounted ||
          generation != _watchGeneration ||
          !identical(_watcher, watcher)) {
        await watcher.stop();
        return;
      }
      state = state.copyWith(
        isWatching: true,
        recentSlices: existing,
        latestSlice: existing.isEmpty ? null : existing.first,
      );
    } else {
      state = state.copyWith(isWatching: false, error: '无法监听目录：$directory');
    }
  }

  Future<void> _acceptCompletedSlice(SliceResult result, int generation) async {
    if (!mounted || generation != _watchGeneration) return;
    final recent = [
      result,
      ...state.recentSlices
          .where((slice) => slice.filePath != result.filePath)
          .take(19),
    ];
    state = state.copyWith(recentSlices: recent, latestSlice: result);

    if (ref.read(studioModeEnabledProvider)) {
      // Structural package inspection is deliberately separate from the
      // lighter SliceResult path and runs in an isolate so a large 3MF never
      // blocks the farm control surface.
      unawaited(
        SliceIsolateRunner.inspectProductionPackage(result.filePath).then(
          (inspection) {
            if (inspection != null &&
                mounted &&
                generation == _watchGeneration) {
              ref.read(farmSliceIntakeProvider.notifier).submit(inspection);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            ErrorLogger.log(
              error,
              stackTrace,
              source: 'slicer_attribution',
              level: ErrorLevel.warning,
              context: {'phase': 'inspect_package'},
            );
          },
        ),
      );
    }

    final hash = result.artifactSha256;
    final settingsId = result.printSettingsId;
    final modifiedAt = result.artifactModifiedAt;
    if (hash == null || settingsId == null || modifiedAt == null) return;

    final dao = PresetResultDao(ref.read(databaseProvider));
    try {
      final candidates = await dao.getApplicationsBySlicerSettingsId(
        settingsId,
      );
      if (!mounted || generation != _watchGeneration) return;
      final eligible = candidates.where((row) {
        final appliedAt = row['applied_at'] as int?;
        return appliedAt != null &&
            appliedAt <= modifiedAt.millisecondsSinceEpoch;
      }).toList();
      // 名称/最近应用都不是精确证据；只有唯一候选才建立产物绑定。
      if (eligible.length != 1) return;
      await dao.bindSliceArtifact(
        applicationId: eligible.single['id'] as String,
        artifactSha256: hash,
        artifactSize: result.artifactSize ?? 0,
        artifactModifiedAt: modifiedAt.millisecondsSinceEpoch,
        artifactKind: result.filePath.toLowerCase().endsWith('.3mf')
            ? '3mf'
            : 'gcode',
        localPath: result.filePath,
      );
    } catch (error, stackTrace) {
      ErrorLogger.log(
        error,
        stackTrace,
        source: 'slicer_attribution',
        level: ErrorLevel.warning,
        context: {'phase': 'bind_slice_artifact'},
      );
    } finally {
      dao.dispose();
    }
  }

  Future<void> stopWatching() async {
    final generation = ++_watchGeneration;
    final watcher = _watcher;
    _watcher = null;
    await watcher?.stop();
    if (mounted && generation == _watchGeneration) {
      state = const SlicerWatcherState();
    }
  }

  /// 手动重新扫描目录
  Future<void> rescan() async {
    final watcher = _watcher;
    final generation = _watchGeneration;
    if (watcher == null) return;
    final existing = await watcher.scanExisting();
    if (!mounted ||
        generation != _watchGeneration ||
        !identical(_watcher, watcher)) {
      return;
    }
    state = state.copyWith(
      recentSlices: existing,
      latestSlice: existing.isEmpty ? null : existing.first,
    );
  }
}

/// 切片文件监听器 provider
final slicerWatcherProvider =
    StateNotifierProvider<SlicerWatcherNotifier, SlicerWatcherState>((ref) {
      return SlicerWatcherNotifier(ref);
    });
