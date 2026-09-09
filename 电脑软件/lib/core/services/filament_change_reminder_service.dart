import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../../app.dart';
import '../../data/database/database.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/slicer/filament_change_point.dart';
import '../../data/external/slicer/gcode_parser.dart';
import '../../data/prefs/app_prefs.dart';
import '../../features/print_task/filament_change_reminder_dialog.dart';
import '../../providers/database_provider.dart';
import '../../providers/external_multicolor_plan_provider.dart';
import 'notification_service.dart';

/// Coordinates external-spool color changes for every connected printer.
/// Dialog completion is driven by printer telemetry, never by a user bypass.
class FilamentChangeReminderService {
  FilamentChangeReminderService(this._ref) {
    _ref.listen<bool>(studioModeEnabledProvider, (_, farmMode) {
      if (farmMode) _suppressPersonalDialogs();
    });
  }

  final Ref _ref;

  static const int _previewLayerAhead = 1;

  final Map<String, List<FilamentChangePoint>> _pointsCache = {};
  final Map<String, Set<String>> _triggeredPreviews = {};
  final Map<String, Set<String>> _triggeredPauses = {};
  final Map<String, _FeedSession> _activeByPrinter = {};
  final List<_FeedSession> _dialogQueue = [];
  bool _dialogShowing = false;

  Future<void> onPrinterStateChanged({
    required int taskId,
    required String printerSerial,
    required String printerLabel,
    required String taskName,
    required BambuGcodeState? gcodeState,
    required int? currLayer,
    required int? totalLayers,
    required String? gcodePath,
    required String? trayNow,
    required bool hasAms,
    required int? mcPrintStage,
    required int? hwSwitchState,
    required List<bool?>? extruderFilamentPresent,
    List<FilamentChangePoint>? knownChangePoints,
  }) async {
    _updateFeedSession(
      printerSerial: printerSerial,
      gcodeState: gcodeState,
      mcPrintStage: mcPrintStage,
      hwSwitchState: hwSwitchState,
      extruderFilamentPresent: extruderFilamentPresent,
    );
    if (_ref.read(studioModeEnabledProvider)) {
      _suppressPersonalDialogs();
      return;
    }
    if (_dialogQueue.isNotEmpty) unawaited(_pumpDialogs());

    final enabled = await AppPrefs.getExternalFilamentColorReminderEnabled();
    if (!enabled ||
        gcodePath == null ||
        gcodePath.isEmpty ||
        currLayer == null) {
      return;
    }

    // A normal AMS channel is automatic. External slots 254/255 and printers
    // without AMS still require the blocking manual feed workflow.
    if (hasAms && trayNow != null && trayNow != '254' && trayNow != '255') {
      _triggeredPreviews.remove(_taskKey(printerSerial, gcodePath));
      _triggeredPauses.remove(_taskKey(printerSerial, gcodePath));
      return;
    }

    final points = knownChangePoints ?? await _loadChangePoints(gcodePath);
    if (knownChangePoints != null) _pointsCache[gcodePath] = knownChangePoints;
    if (points.isEmpty) return;
    final key = _taskKey(printerSerial, gcodePath);

    await _maybeTriggerPreview(
      taskKey: key,
      printerLabel: printerLabel,
      currLayer: currLayer,
      points: points,
    );

    // Do not rely on observing the exact running -> pause edge. Reconnects and
    // incremental MQTT frames may first arrive while already paused.
    if (gcodeState == BambuGcodeState.pause) {
      await _maybeTriggerPause(
        taskId: taskId,
        taskKey: key,
        printerSerial: printerSerial,
        printerLabel: printerLabel,
        taskName: taskName,
        gcodePath: gcodePath,
        currLayer: currLayer,
        points: points,
        mcPrintStage: mcPrintStage,
        filamentPresent: _filamentPresent(
          hwSwitchState,
          extruderFilamentPresent,
        ),
      );
    }
  }

  Future<List<FilamentChangePoint>> _loadChangePoints(String gcodePath) async {
    final memory = _pointsCache[gcodePath];
    if (memory != null) return memory;

    final file = File(gcodePath);
    if (!await file.exists()) return const [];
    final stat = await file.stat();
    final cacheKey =
        'fcache_v2_${gcodePath.hashCode}_${stat.modified.millisecondsSinceEpoch}';
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(cacheKey);
    if (cached != null) {
      try {
        final list = (jsonDecode(cached) as List)
            .map(
              (item) => FilamentChangePoint.fromJson(
                item as Map<String, dynamic>,
              ),
            )
            .toList();
        _pointsCache[gcodePath] = list;
        return list;
      } catch (_) {
        // Reparse a stale or incomplete cache entry.
      }
    }

    try {
      final points = await GcodeParser.parseFilamentChangeLayers(gcodePath);
      _pointsCache[gcodePath] = points;
      await prefs.setString(
        cacheKey,
        jsonEncode(points.map((point) => point.toJson()).toList()),
      );
      return points;
    } catch (error) {
      debugPrint('[FilamentChangeReminder] 解析换色点失败: $error');
      return const [];
    }
  }

  Future<void> _maybeTriggerPreview({
    required String taskKey,
    required String printerLabel,
    required int currLayer,
    required List<FilamentChangePoint> points,
  }) async {
    final future = points.where((point) => point.layerNum > currLayer);
    if (future.isEmpty) return;
    final next = future.first;
    if (next.layerNum - currLayer > _previewLayerAhead) return;

    final eventKey = _pointKey(next);
    final triggered = _triggeredPreviews.putIfAbsent(taskKey, () => {});
    if (!triggered.add(eventKey)) return;
    await _ref.read(notificationServiceProvider).alert(
          type: AlertType.filamentChange,
          title: '$printerLabel 即将换色',
          body: '第 ${next.layerNum} 层装入 ${_formatColorDesc(next)}',
        );
  }

  Future<void> _maybeTriggerPause({
    required int taskId,
    required String taskKey,
    required String printerSerial,
    required String printerLabel,
    required String taskName,
    required String gcodePath,
    required int currLayer,
    required List<FilamentChangePoint> points,
    required int? mcPrintStage,
    required bool? filamentPresent,
  }) async {
    if (_ref
        .read(externalMulticolorPlanQueueProvider)
        .any((request) => request.taskId == taskId)) {
      return;
    }
    if (_activeByPrinter.containsKey(printerSerial)) return;
    final candidates = points
        .where((point) => (point.layerNum - currLayer).abs() <= 1)
        .toList();
    if (candidates.isEmpty) return;
    candidates.sort(
      (a, b) => (a.layerNum - currLayer)
          .abs()
          .compareTo((b.layerNum - currLayer).abs()),
    );
    final point = candidates.first;
    final eventKey = _pointKey(point);
    final triggered = _triggeredPauses.putIfAbsent(taskKey, () => {});
    if (!triggered.add(eventKey)) return;

    final index = points.indexOf(point);
    final spoolData = await _loadMappedSpools(taskId, point);
    final currentColorHex = spoolData.current?.colorHex ??
        _colorForTool(points, point.previousToolIndex);
    final phase = ValueNotifier<FilamentFeedPhase>(
      switch (mcPrintStage) {
        22 => FilamentFeedPhase.unloading,
        24 => FilamentFeedPhase.loading,
        _ => FilamentFeedPhase.waiting,
      },
    );
    final session = _FeedSession(
      printerSerial: printerSerial,
      gcodePath: gcodePath,
      eventKey: eventKey,
      phase: phase,
      data: FilamentChangeReminderData(
        point: point,
        printerLabel: printerLabel,
        taskName: taskName,
        changeIndex: index + 1,
        changeCount: points.length,
        upcoming: points.skip(index + 1).take(3).toList(),
        currentColorHex: currentColorHex,
        currentSpool: spoolData.current,
        targetSpool: spoolData.target,
      ),
      sawUnload: mcPrintStage == 22,
      sawLoading: mcPrintStage == 24,
      lastPrintStage: mcPrintStage,
      lastFilamentPresent: filamentPresent,
    );
    _activeByPrinter[printerSerial] = session;
    _dialogQueue.add(session);
    unawaited(_pumpDialogs());
  }

  void _updateFeedSession({
    required String printerSerial,
    required BambuGcodeState? gcodeState,
    required int? mcPrintStage,
    required int? hwSwitchState,
    required List<bool?>? extruderFilamentPresent,
  }) {
    final session = _activeByPrinter[printerSerial];
    if (session == null || session.phase.value == FilamentFeedPhase.completed) {
      return;
    }
    final present = _filamentPresent(
      hwSwitchState,
      extruderFilamentPresent,
    );
    final sensorReloaded =
        session.lastFilamentPresent == false && present == true;
    final leftLoadingStage = session.lastPrintStage == 24 &&
        mcPrintStage != null &&
        mcPrintStage != 24;

    if (mcPrintStage == 22 || present == false) {
      session.sawUnload = true;
      session.phase.value = FilamentFeedPhase.unloading;
    }
    if (mcPrintStage == 24) {
      session.sawLoading = true;
      session.phase.value = FilamentFeedPhase.loading;
    }

    final terminal = gcodeState == BambuGcodeState.idle ||
        gcodeState == BambuGcodeState.finish ||
        gcodeState == BambuGcodeState.failed;
    final resumed = gcodeState == BambuGcodeState.running;
    final loadConfirmed = sensorReloaded ||
        (session.sawLoading && leftLoadingStage && present != false);
    if (resumed || terminal || loadConfirmed) {
      session.phase.value = FilamentFeedPhase.completed;
    }
    session.lastPrintStage = mcPrintStage ?? session.lastPrintStage;
    session.lastFilamentPresent = present ?? session.lastFilamentPresent;
  }

  Future<void> _pumpDialogs() async {
    if (_dialogShowing) return;
    _dialogShowing = true;
    try {
      while (_dialogQueue.isNotEmpty) {
        final session = _dialogQueue.removeAt(0);
        if (_ref.read(studioModeEnabledProvider)) {
          session.phase.value = FilamentFeedPhase.completed;
        }
        if (session.phase.value == FilamentFeedPhase.completed) {
          _disposeSession(session);
          continue;
        }

        try {
          await windowManager.show();
          await windowManager.focus();
        } catch (_) {}

        final context = navigatorKey.currentContext;
        if (context == null) {
          if (!session.fallbackNotified) {
            session.fallbackNotified = true;
            await _ref.read(notificationServiceProvider).alert(
                  type: AlertType.filamentChange,
                  title: '${session.data.printerLabel} 请换色',
                  body: '请装入 ${_formatColorDesc(session.data.point)}',
                );
          }
          _dialogQueue.insert(0, session);
          break;
        }

        if (!context.mounted) {
          _dialogQueue.insert(0, session);
          break;
        }
        await FilamentChangeReminderDialog.show(
          context,
          data: session.data,
          phase: session.phase,
        );
        _disposeSession(session);
      }
    } finally {
      _dialogShowing = false;
    }
  }

  Future<({ReminderSpool? current, ReminderSpool? target})> _loadMappedSpools(
    int taskId,
    FilamentChangePoint point,
  ) async {
    try {
      final entries =
          await _ref.read(printTaskConsumableDaoProvider).getByTask(taskId);
      int? targetId;
      int? currentId;
      for (final entry in entries) {
        if (entry.toolIndex == point.toolIndex) {
          targetId = entry.consumableId;
        }
        if (entry.toolIndex == point.previousToolIndex) {
          currentId = entry.consumableId;
        }
      }
      final dao = _ref.read(consumableDaoProvider);
      final target = targetId == null ? null : await dao.getById(targetId);
      final current = currentId == null ? null : await dao.getById(currentId);
      return (
        current: _toReminderSpool(current),
        target: _toReminderSpool(target),
      );
    } catch (_) {
      return (current: null, target: null);
    }
  }

  ReminderSpool? _toReminderSpool(Consumable? item) {
    if (item == null) return null;
    return ReminderSpool(
      manufacturer: item.manufacturer,
      materialType: item.materialType,
      colorHex: item.colorHex,
      colorName: item.colorName,
      remainingGrams: item.remainingGrams,
    );
  }

  bool? _filamentPresent(int? legacy, List<bool?>? extruders) {
    if (extruders != null && extruders.isNotEmpty) {
      if (extruders.any((present) => present == true)) return true;
      return extruders.any((present) => present == null) ? null : false;
    }
    if (legacy != null) return legacy == 1;
    return null;
  }

  String? _colorForTool(
    List<FilamentChangePoint> points,
    int? toolIndex,
  ) {
    if (toolIndex == null) return null;
    for (final point in points) {
      if (point.toolIndex == toolIndex && point.colorHex != null) {
        return point.colorHex;
      }
    }
    return null;
  }

  String _formatColorDesc(FilamentChangePoint point) {
    final material = point.materialType ?? '耗材';
    final color = point.colorHex ?? '目标颜色';
    return '$material $color';
  }

  String _taskKey(String serial, String path) => '$serial|$path';

  String _pointKey(FilamentChangePoint point) =>
      '${point.layerNum}:${point.toolIndex}';

  void _disposeSession(_FeedSession session) {
    if (identical(_activeByPrinter[session.printerSerial], session)) {
      _activeByPrinter.remove(session.printerSerial);
    }
    session.phase.dispose();
  }

  void clearForGcode(String gcodePath) {
    _pointsCache.remove(gcodePath);
    _triggeredPreviews.removeWhere((key, _) => key.endsWith('|$gcodePath'));
    _triggeredPauses.removeWhere((key, _) => key.endsWith('|$gcodePath'));
    for (final session in _activeByPrinter.values
        .where((item) => item.gcodePath == gcodePath)
        .toList()) {
      session.phase.value = FilamentFeedPhase.completed;
    }
  }

  void clearAll() {
    _pointsCache.clear();
    _triggeredPreviews.clear();
    _triggeredPauses.clear();
    for (final session in _activeByPrinter.values) {
      session.phase.value = FilamentFeedPhase.completed;
    }
  }

  void _suppressPersonalDialogs() {
    for (final session in _activeByPrinter.values) {
      session.phase.value = FilamentFeedPhase.completed;
    }
    for (final session in _dialogQueue) {
      session.phase.value = FilamentFeedPhase.completed;
    }
    if (_dialogQueue.isNotEmpty) unawaited(_pumpDialogs());
  }

  List<FilamentChangePoint> getCachedPoints(String gcodePath) {
    return _pointsCache[gcodePath] ?? const [];
  }
}

class _FeedSession {
  _FeedSession({
    required this.printerSerial,
    required this.gcodePath,
    required this.eventKey,
    required this.phase,
    required this.data,
    required this.sawUnload,
    required this.sawLoading,
    required this.lastPrintStage,
    required this.lastFilamentPresent,
  });

  final String printerSerial;
  final String gcodePath;
  final String eventKey;
  final ValueNotifier<FilamentFeedPhase> phase;
  final FilamentChangeReminderData data;
  bool sawUnload;
  bool sawLoading;
  int? lastPrintStage;
  bool? lastFilamentPresent;
  bool fallbackNotified = false;
}

final filamentChangeReminderServiceProvider =
    Provider<FilamentChangeReminderService>((ref) {
  return FilamentChangeReminderService(ref);
});
