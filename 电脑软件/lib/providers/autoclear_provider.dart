// 自动清件检测 Provider。
//
// 整合 [AutoClearDetector]（启发式扫描）和 [AutoclearCachePrefs]（缓存），
// 提供 UI 层统一的读写接口。
//
// 流程：
//   1. 入队时调 [AutoclearService.detectAndCache] 异步扫描 G-code
//   2. 扫描结果存入缓存，同时触发 state 通知 UI 刷新徽章
//   3. 用户手动覆盖时调 [AutoclearService.setManualOverride]
//   4. 无人值守安全门读取 [AutoclearService.getFinalFlag]
//
// 状态：StateProvider<Map<filename, AutoclearCacheEntry>>，
// UI 通过 watch 此 state 实时刷新徽章。

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/external/slicer/autoclear_detector.dart';
import '../data/prefs/autoclear_cache_prefs.dart';

/// 自动清件检测状态：filename → 缓存条目。
///
/// UI 通过 watch 此 provider 获取所有文件的检测结果，刷新徽章。
/// 初始值为空 Map（尚未加载），调用 [AutoclearService.loadAll] 后填充。
final autoclearStateProvider =
    StateProvider<Map<String, AutoclearCacheEntry>>((ref) => {});

/// 自动清件检测服务。
class AutoclearService {
  final Ref _ref;

  AutoclearService(this._ref);

  /// 从 prefs 加载所有缓存到 state。
  /// 应用启动时调一次。
  Future<void> loadAll() async {
    final all = await AutoclearCachePrefs.loadAll();
    _ref.read(autoclearStateProvider.notifier).state = all;
  }

  /// 检测指定 G-code 文件并缓存结果。
  ///
  /// - 若缓存已有该文件的非覆盖结果，跳过重复扫描
  /// - 扫描失败不抛异常，记一条空结果避免下次再扫
  /// - 扫描完成后更新 state 通知 UI
  Future<AutoclearCacheEntry> detectAndCache(String gcodePath) async {
    final filename = _basename(gcodePath);

    // 缓存命中：已有自动检测结果且无手动覆盖时直接返回
    final current = _ref.read(autoclearStateProvider.notifier).state;
    final existing = current[filename];
    if (existing != null && existing.score > 0) {
      // 已检测过，避免重复扫描（即使有手动覆盖也复用结果）
      return existing;
    }

    // 异步扫描
    final result = await AutoClearDetector.detect(gcodePath);
    final AutoclearCacheEntry entry;
    if (result.error != null) {
      // 扫描失败：记一条空结果（hasAutoClear=false），避免下次再扫
      debugPrint('[Autoclear] 检测失败 ${result.error}，记为空结果');
      entry = AutoclearCacheEntry(
        score: 0,
        hasAutoClear: false,
        matchedFeatures: ['检测失败: ${result.error}'],
        manualOverride: null,
        detectedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } else {
      entry = AutoclearCacheEntry(
        score: result.score,
        hasAutoClear: result.hasAutoClear,
        matchedFeatures: result.matchedFeatures,
        manualOverride: null,
        detectedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }

    // 持久化 + 更新 state
    await AutoclearCachePrefs.setDetection(
      filename: filename,
      score: entry.score,
      hasAutoClear: entry.hasAutoClear,
      matchedFeatures: entry.matchedFeatures,
    );
    final newState = Map<String, AutoclearCacheEntry>.from(
      _ref.read(autoclearStateProvider.notifier).state,
    );
    newState[filename] = entry;
    _ref.read(autoclearStateProvider.notifier).state = newState;

    return entry;
  }

  /// 获取最终的 hasAutoClear 判定值（手动覆盖优先）。
  /// 缓存不存在返回 null（表示尚未检测）。
  Future<bool?> getFinalFlag(String gcodePath) async {
    final filename = _basename(gcodePath);
    // 优先从 state 读（最新），其次从 prefs 读
    final stateEntry =
        _ref.read(autoclearStateProvider.notifier).state[filename];
    if (stateEntry != null) return stateEntry.finalFlag;
    return AutoclearCachePrefs.getFinalFlag(filename);
  }

  /// 同步版本的 [getFinalFlag]，从 state 读。
  /// 注意：state 可能尚未加载，返回 null 时调用方需触发 detectAndCache。
  bool? getFinalFlagSync(String gcodePath) {
    final filename = _basename(gcodePath);
    return _ref
        .read(autoclearStateProvider.notifier)
        .state[filename]
        ?.finalFlag;
  }

  /// 设置手动覆盖值。
  /// [value] 传 null 清除覆盖（回退到自动检测结果）。
  Future<void> setManualOverride(String gcodePath, bool? value) async {
    final filename = _basename(gcodePath);
    await AutoclearCachePrefs.setManualOverride(filename, value);

    // 更新 state
    final newState = Map<String, AutoclearCacheEntry>.from(
      _ref.read(autoclearStateProvider.notifier).state,
    );
    final existing = newState[filename];
    if (existing != null) {
      newState[filename] = AutoclearCacheEntry(
        score: existing.score,
        hasAutoClear: existing.hasAutoClear,
        matchedFeatures: existing.matchedFeatures,
        manualOverride: value,
        detectedAt: existing.detectedAt,
      );
    } else {
      newState[filename] = AutoclearCacheEntry(
        score: 0,
        hasAutoClear: value ?? false,
        matchedFeatures: const [],
        manualOverride: value,
        detectedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    _ref.read(autoclearStateProvider.notifier).state = newState;
  }

  /// 删除单个文件的缓存（管理入口用）。
  Future<void> remove(String filename) async {
    await AutoclearCachePrefs.remove(filename);
    final newState = Map<String, AutoclearCacheEntry>.from(
      _ref.read(autoclearStateProvider.notifier).state,
    );
    newState.remove(filename);
    _ref.read(autoclearStateProvider.notifier).state = newState;
  }

  /// 清空所有缓存（管理入口用）。
  Future<void> clearAll() async {
    await AutoclearCachePrefs.clearAll();
    _ref.read(autoclearStateProvider.notifier).state = {};
  }

  String _basename(String path) {
    return path.split(RegExp(r'[/\\]')).last;
  }
}

/// 自动清件服务 provider。
final autoclearServiceProvider = Provider<AutoclearService>((ref) {
  return AutoclearService(ref);
});
