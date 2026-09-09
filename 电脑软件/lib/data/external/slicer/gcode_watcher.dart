import 'dart:async';
import 'dart:io';

import 'package:watcher/watcher.dart';

import 'slice_isolate_runner.dart';
import 'slice_result.dart';

/// A cheap identity for an output artifact.  A timestamp alone is not
/// sufficient on filesystems with coarse timestamp resolution, while hashing
/// every multi-hundred-megabyte G-code file would make the watcher expensive.
/// Size + modification time gives us stable, deterministic de-duplication and
/// still allows a re-sliced file at the same path to be processed again.
class _FileSignature {
  const _FileSignature({required this.length, required this.modifiedMicros});

  final int length;
  final int modifiedMicros;

  @override
  bool operator ==(Object other) =>
      other is _FileSignature &&
      other.length == length &&
      other.modifiedMicros == modifiedMicros;

  @override
  int get hashCode => Object.hash(length, modifiedMicros);
}

class _ProcessedFile {
  const _ProcessedFile({required this.signature, required this.processedAt});

  final _FileSignature signature;
  final DateTime processedAt;
}

/// G-code / 3MF 文件监听器。
///
/// 监听 BambuStudio 输出目录，当检测到新的 `.gcode` 或 `.3mf` 文件时：
/// 1. 等待文件写入完成（BambuStudio 切片完成后会一次性写出，但大文件可能需要几百毫秒）
/// 2. 解析切片信息
/// 3. 通过 [onSliceCompleted] 回调通知 UI
///
/// 监听策略：使用 `watcher` 包的 `DirectoryWatcher`，监听 `create` 和 `modify` 事件。
/// 为避免重复解析，按文件路径去重，每个文件只回调一次（除非文件被重新切片覆盖）。
class GcodeWatcher {
  /// 监听的目录路径
  final String directoryPath;

  /// 是否启用精细模式（解析层级累计克数映射）
  final bool enableLayerMapping;

  /// 切片完成回调。传入 null 表示解析失败。
  final void Function(SliceResult? result) onSliceCompleted;

  /// 监听出错回调
  final void Function(Object error)? onError;

  DirectoryWatcher? _watcher;
  StreamSubscription<WatchEvent>? _subscription;
  // 路径 → 最近一次成功处理的文件签名。资源修复：加上限防止长期监听
  // 累积大量路径条目，并允许同一路径被重新切片后再次处理。
  final _processedFiles = <String, _ProcessedFile>{};
  // 同一路径的解析只允许一个实例；文件在解析期间再次变化时排队重试，
  // 不能简单丢弃事件，否则会永久漏掉覆盖写入的切片。
  final _processingFiles = <String>{};
  final _rerunFiles = <String>{};
  final _pendingTimers = <String, Timer>{};
  int _runGeneration = 0;
  static const int _maxProcessedFiles = 500;

  /// 防抖从最后一次文件事件重新计时，避免大文件仍在持续写入时提前解析。
  static const _debounceDelay = Duration(milliseconds: 800);
  static const _stabilitySample = Duration(milliseconds: 300);
  static const _maxStabilityWait = Duration(seconds: 60);

  GcodeWatcher({
    required this.directoryPath,
    required this.onSliceCompleted,
    this.enableLayerMapping = false,
    this.onError,
  });

  /// 开始监听。返回是否成功启动。
  ///
  /// **递归监听说明**：`watcher` 包的 `DirectoryWatcher` 在 Windows 和 macOS
  /// 上内部使用 `RecursiveDirectoryWatcher`，**默认就是递归的**，无需额外参数。
  /// 在 Linux 上使用 `LinuxDirectoryWatcher`（inotify，也支持递归）。
  /// 只有当 `FileSystemEntity.isWatchSupported` 为 false 时才回退到
  /// `PollingDirectoryWatcher`（非递归轮询）。
  ///
  /// BambuStudio 切片 G-code 在 `bamboo_model/<日期>/<时间>#<PID>#<plate>/Metadata/`
  /// 多层子目录下，递归监听能完整捕获。
  Future<bool> start() async {
    final generation = ++_runGeneration;
    final previous = _subscription;
    _subscription = null;
    _watcher = null;
    _clearPending();
    await previous?.cancel();
    if (generation != _runGeneration) return false;
    final dir = Directory(directoryPath);
    if (!await dir.exists()) {
      if (generation != _runGeneration) return false;
      onError?.call(StateError('监听目录不存在: $directoryPath'));
      return false;
    }
    if (generation != _runGeneration) return false;

    try {
      // DirectoryWatcher 在 Windows/macOS 内部用 RecursiveDirectoryWatcher
      // （见 watcher 包 directory_watcher.dart 源码），已递归监听所有子目录
      _watcher = DirectoryWatcher(directoryPath);
      _subscription = _watcher!.events.listen(
        (event) => _onEvent(event, generation),
        onError: (e) {
          if (generation == _runGeneration) onError?.call(e);
        },
      );
      return true;
    } catch (e) {
      if (generation == _runGeneration) onError?.call(e);
      return false;
    }
  }

  /// 停止监听
  Future<void> stop() async {
    ++_runGeneration;
    final previous = _subscription;
    _subscription = null;
    _watcher = null;
    _clearPending();
    await previous?.cancel();
  }

  void _clearPending() {
    for (final timer in _pendingTimers.values) {
      timer.cancel();
    }
    _pendingTimers.clear();
    _processedFiles.clear();
    _processingFiles.clear();
    _rerunFiles.clear();
  }

  void _onEvent(WatchEvent event, [int? generation]) {
    final expectedGeneration = generation ?? _runGeneration;
    if (expectedGeneration != _runGeneration) return;
    final path = event.path;
    // 只处理 .gcode / .g / .3mf
    final lower = path.toLowerCase();
    if (!lower.endsWith('.gcode') &&
        !lower.endsWith('.g') &&
        !lower.endsWith('.gc') &&
        !lower.endsWith('.3mf')) {
      return;
    }

    // 只处理 create 和 modify
    if (event.type != ChangeType.ADD && event.type != ChangeType.MODIFY) {
      return;
    }

    // 每次 MODIFY 都重置计时器，窗口从最后一次事件起算。
    if (_processingFiles.contains(path)) {
      _rerunFiles.add(path);
    }
    _pendingTimers.remove(path)?.cancel();
    _pendingTimers[path] = Timer(_debounceDelay, () {
      _pendingTimers.remove(path);
      if (_subscription == null || expectedGeneration != _runGeneration) {
        return; // 已 stop 或已切换到新的 watcher
      }
      _parseFile(path, expectedGeneration).catchError((e) {
        onError?.call(e);
      });
    });
  }

  Future<void> _parseFile(String path, [int? generation]) async {
    final expectedGeneration = generation ?? _runGeneration;
    if (expectedGeneration != _runGeneration || _subscription == null) return;
    if (_processingFiles.contains(path)) {
      _rerunFiles.add(path);
      return;
    }
    _processingFiles.add(path);
    try {
      final file = File(path);
      if (!await file.exists()) {
        return;
      }
      if (expectedGeneration != _runGeneration) return;

      if (!await _waitUntilComplete(file, expectedGeneration)) {
        if (expectedGeneration != _runGeneration) return;
        onError?.call(StateError('切片文件在 60 秒内未写完，已延后处理: $path'));
        if (expectedGeneration == _runGeneration &&
            _subscription != null &&
            !_pendingTimers.containsKey(path)) {
          _pendingTimers[path] = Timer(const Duration(seconds: 2), () {
            _pendingTimers.remove(path);
            if (_subscription != null && expectedGeneration == _runGeneration) {
              _parseFile(
                path,
                expectedGeneration,
              ).catchError((e) => onError?.call(e));
            }
          });
        }
        return;
      }

      final beforeParse = await _signatureFor(file);
      if (beforeParse == null) return;
      if (expectedGeneration != _runGeneration) return;
      final previous = _processedFiles[path];
      if (previous?.signature == beforeParse) return;

      // P1-3: 在 Isolate 中解析（避免大文件阻塞 UI）
      SliceResult? result;
      if (path.toLowerCase().endsWith('.3mf')) {
        result = await SliceIsolateRunner.parse3mf(
          path,
          enableLayerMapping: enableLayerMapping,
        );
      } else {
        result = await SliceIsolateRunner.parseGcode(
          path,
          enableLayerMapping: enableLayerMapping,
        );
      }
      // 解析可能耗时数秒；如果切片器在此期间覆盖文件，丢弃旧结果并
      // 让排队的下一轮重新读取，避免把半旧数据关联到打印任务。
      final afterParse = await _signatureFor(file);
      if (expectedGeneration != _runGeneration) return;
      if (afterParse == null || afterParse != beforeParse) {
        _rerunFiles.add(path);
        return;
      }
      _markProcessed(path, afterParse);
      onSliceCompleted(result);
    } catch (e) {
      if (expectedGeneration == _runGeneration) {
        onError?.call(e);
        onSliceCompleted(null);
      }
    } finally {
      if (expectedGeneration == _runGeneration) {
        _processingFiles.remove(path);
        if (_rerunFiles.remove(path) &&
            _subscription != null &&
            !_pendingTimers.containsKey(path)) {
          _pendingTimers[path] = Timer(_debounceDelay, () {
            _pendingTimers.remove(path);
            if (_subscription != null && expectedGeneration == _runGeneration) {
              _parseFile(
                path,
                expectedGeneration,
              ).catchError((e) => onError?.call(e));
            }
          });
        }
      }
    }
  }

  void _markProcessed(String path, _FileSignature signature) {
    // Remove/reinsert so the map's insertion order reflects processing order;
    // this makes eviction O(n) without retaining a second LRU structure.
    _processedFiles.remove(path);
    _processedFiles[path] = _ProcessedFile(
      signature: signature,
      processedAt: DateTime.now(),
    );
    if (_processedFiles.length <= _maxProcessedFiles) return;
    final sorted = _processedFiles.entries.toList()
      ..sort((a, b) => a.value.processedAt.compareTo(b.value.processedAt));
    for (var i = 0; i < sorted.length ~/ 2; i++) {
      _processedFiles.remove(sorted[i].key);
    }
  }

  Future<_FileSignature?> _signatureFor(File file) async {
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return _FileSignature(
        length: stat.size,
        modifiedMicros: stat.modified.microsecondsSinceEpoch,
      );
    } catch (_) {
      // The slicer may rename/delete a temporary file between watcher events.
      return null;
    }
  }

  /// 连续三次大小不变且文件尾结构完整才允许解析。
  Future<bool> _waitUntilComplete(
    File file,
    int generation, {
    Duration maxWait = _maxStabilityWait,
  }) async {
    final deadline = DateTime.now().add(maxWait);
    int? previousSize;
    var stableSamples = 0;
    while (generation == _runGeneration && DateTime.now().isBefore(deadline)) {
      if (!await file.exists()) return false;
      final size = await file.length();
      if (size > 0 && size == previousSize) {
        stableSamples++;
      } else {
        stableSamples = 0;
      }
      previousSize = size;
      if (stableSamples >= 2 && await _hasCompleteTail(file, size)) return true;
      await Future<void>.delayed(_stabilitySample);
    }
    return false;
  }

  Future<bool> _hasCompleteTail(File file, int size) async {
    if (size <= 0) return false;
    final start = size > 128 * 1024 ? size - 128 * 1024 : 0;
    final tailChunks = await file.openRead(start).toList();
    final tail = <int>[for (final chunk in tailChunks) ...chunk];
    if (file.path.toLowerCase().endsWith('.3mf')) {
      // ZIP End of Central Directory: 50 4B 05 06。
      for (var i = tail.length - 4; i >= 0; i--) {
        if (tail[i] == 0x50 &&
            tail[i + 1] == 0x4B &&
            tail[i + 2] == 0x05 &&
            tail[i + 3] == 0x06) {
          return true;
        }
      }
      return false;
    }
    final text = String.fromCharCodes(tail);
    if (text.contains('; EXECUTABLE_BLOCK_END') ||
        text.contains(';EXECUTABLE_BLOCK_END')) {
      return true;
    }
    // Generic slicers do not emit Bambu's EXECUTABLE_BLOCK_END marker.  Once
    // the file has been stable for three samples, accept a syntactically
    // plausible final line instead of silently rejecting otherwise valid
    // .gcode/.g/.gc output.
    final trimmed = text.trimRight();
    if (trimmed.isEmpty || trimmed.contains('\u0000')) return false;
    final lastLine = trimmed.split(RegExp(r'\r?\n')).last.trimLeft();
    return RegExp(
          r'^(?:N\d+\s*)?(?:G|M|T|F|S|X|Y|Z|E)\s*[-+0-9.]',
          caseSensitive: false,
        ).hasMatch(lastLine) ||
        lastLine.startsWith(';') ||
        lastLine.startsWith('(');
  }

  /// 手动扫描目录中已有的切片文件（应用启动时调用一次）
  ///
  /// 递归扫描子目录（BambuStudio 临时 G-code 在
  /// `bamboo_model/<日期>/<时间>#<PID>#<plate>/Metadata/` 多层子目录下）。
  Future<List<SliceResult>> scanExisting() async {
    final generation = _runGeneration;
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return [];

    final results = <SliceResult>[];
    // Keep at most 20 candidates in memory, even for a long-lived slicer cache.
    final candidates = <({File file, int modified})>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (generation != _runGeneration) return [];
      if (entity is! File) continue;
      final path = entity.path.toLowerCase();
      if (!path.endsWith('.gcode') &&
          !path.endsWith('.g') &&
          !path.endsWith('.gc') &&
          !path.endsWith('.3mf'))
        continue;
      final signature = await _signatureFor(entity);
      if (signature == null) continue;
      candidates.add((file: entity, modified: signature.modifiedMicros));
      candidates.sort((a, b) => b.modified.compareTo(a.modified));
      if (candidates.length > 20) candidates.removeLast();
    }

    // Only inspect the newest candidates.  Waiting up to 60 seconds for every
    // stale temporary file can otherwise block startup for many minutes.
    for (final candidate in candidates) {
      if (generation != _runGeneration) return [];
      final entity = candidate.file;
      try {
        // Incomplete old files must not make a manual scan wait 20 minutes.
        // The live watcher will retry files that are still being written.
        if (!await _waitUntilComplete(
          entity,
          generation,
          maxWait: const Duration(seconds: 1),
        ))
          continue;
        final signature = await _signatureFor(entity);
        if (signature == null) continue;
        // A scan returns a complete list, including previously processed
        // files. Skipping those would clear the inbox on every manual rescan.
        // P1-3: 在 Isolate 中解析（避免大文件阻塞 UI）
        SliceResult? result;
        final path = entity.path.toLowerCase();
        if (path.endsWith('.3mf')) {
          result = await SliceIsolateRunner.parse3mf(
            entity.path,
            enableLayerMapping: enableLayerMapping,
          );
        } else {
          result = await SliceIsolateRunner.parseGcode(
            entity.path,
            enableLayerMapping: enableLayerMapping,
          );
        }
        final afterParse = await _signatureFor(entity);
        if (generation != _runGeneration) return [];
        if (afterParse == null || afterParse != signature) continue;
        _markProcessed(entity.path, afterParse);
        if (result != null) results.add(result);
      } catch (_) {
        // 跳过解析失败的文件
      }
      // 只取最近 20 个
      if (results.length >= 20) break;
    }
    return results;
  }
}
