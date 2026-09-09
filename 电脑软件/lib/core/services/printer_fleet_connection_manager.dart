// 多打印机连接管理器（PrinterFleetConnectionManager）。
//
// 任务书 Phase C 硬性要求：
// - 当前 ActivePrinterConnectionNotifier 只维护一个活跃 _connector，
//   必须新增 PrinterFleetConnectionManager 维护 Map<serial, connection/state>。
// - 每台设备分别记录状态更新时间（status_updated_at），过期状态不得参与自动下发。
// - 只有具备有效 LAN 配置且连接器真实支持发送的设备才进入"可自动下发"候选。
// - 仅云连接设备可以监控/排队，但必须标为"仅监控，无法自动下发"。
//
// 设计要点：
// 1. 每台打印机独立 BambuPrinterConnector（连接器自带指数退避重连）
// 2. 状态更新时间由 statusStream 推送时记录，超过 staleStatusThreshold 视为过期
// 3. 仅 LAN 配置的打印机 isLanCapable=true，可参与自动下发
// 4. 云连接的打印机 isLanCapable=false，仅监控/排队
// 5. 并发上限由 SchedulingConfig.maxConcurrentConnections 控制
// 6. 不破坏现有 ActivePrinterConnectionNotifier（UI 活跃打印机仍用它）
//
// 调度器（SchedulerNotifier）通过此管理器查询候选打印机的实时状态，
// 判断是否可自动下发、是否状态过期、是否处于错误/维护/升级等不可下发状态。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/models/scheduler_models.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../data/seed/printer_seed.dart';
import '../../data/external/printer/bambu_printer_connector.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_connector.dart';
import '../../data/prefs/app_prefs.dart';
import '../../providers/bambu_account_manager.dart';
import '../../providers/consumable_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/spool_change_provider.dart';
import 'spool_change_detector.dart';
import 'printer_model_normalizer.dart';
import 'printer_fault_monitor.dart';

typedef PrinterConnectorFactory =
    PrinterConnector Function(PrinterConnectionConfig config);

/// 可覆盖的连接器工厂，生产环境使用拓竹 MQTT 连接器，测试使用内存 fake。
final printerConnectorFactoryProvider = Provider<PrinterConnectorFactory>(
  (ref) => (config) {
    if (config.mode != BambuConnectionMode.cloud) {
      return BambuPrinterConnector(config);
    }
    final session = cloudSessionForPrinterSerial(
      serial: config.serial,
      ownerMap: ref.read(printerOwnerMapProvider),
      accountState: ref.read(bambuAccountManagerProvider),
    );
    return BambuPrinterConnector(config, cloudSession: session);
  },
);

/// 单台打印机的舰队状态快照。
class FleetPrinterState {
  /// 打印机序列号
  final String serial;

  /// 显示名（displayName / devProductName / serial 兜底）
  final String displayLabel;

  /// 当前连接状态
  final PrinterConnectionState connectionState;

  /// 最后一次 MQTT 状态推送的快照
  final BambuPrinterStatus? lastStatus;

  /// 最后一次状态更新时间（用于判断新鲜度）
  final DateTime? statusUpdatedAt;

  /// 是否具备 LAN 配置（true=可自动下发，false=仅云连接/仅监控）
  final bool isLanCapable;

  /// 连接模式（lan / cloud）
  final BambuConnectionMode mode;

  /// 配置或云端明确报告的精确机型；未知时为 null。
  final String? reportedModel;

  /// 当前安装喷嘴直径；未知时为 null，不能参与自动调度。
  final double? installedNozzleDiameter;

  /// 是否正在连接中（防止重复触发连接）
  final bool isConnecting;

  const FleetPrinterState({
    required this.serial,
    required this.displayLabel,
    required this.connectionState,
    required this.lastStatus,
    required this.statusUpdatedAt,
    required this.isLanCapable,
    required this.mode,
    required this.reportedModel,
    required this.installedNozzleDiameter,
    required this.isConnecting,
  });

  /// 状态是否过期（超过 staleStatusThreshold）
  bool isStale(SchedulingConfig config) {
    if (statusUpdatedAt == null) return true;
    return DateTime.now().difference(statusUpdatedAt!) >
        config.staleStatusThreshold;
  }

  /// 打印机是否处于忙碌状态（错误/维护/升级/打印中）
  /// 调度器据此判断是否可接受新任务。
  bool get printerBusy {
    final s = lastStatus;
    if (s == null) return true; // 无状态视为不可下发
    final gcode = s.gcodeState;
    if (gcode == null) return true;
    // running/pause/init/prepare 都算忙碌（不能发新任务）
    // idle/finish 可以下发
    // failed/offline/slicing/unknown 视为忙碌（异常状态）
    if (gcode == BambuGcodeState.idle || gcode == BambuGcodeState.finish) {
      // 检查是否在升级
      if (s.upgradeStatus != null && s.upgradeStatus!.isNotEmpty) {
        return true;
      }
      return false;
    }
    return true;
  }

  /// 是否可自动下发：已连接 + LAN 可达 + 状态未过期 + 不忙碌
  bool canAutoDispatch(SchedulingConfig config) {
    if (!isLanCapable) return false; // 仅云连接不能自动下发
    if (connectionState != PrinterConnectionState.connected) return false;
    if (isStale(config)) return false;
    if (printerBusy) return false;
    return true;
  }

  /// 是否能安全接受一个“未来任务”。正在正常打印可以预排，但异常、升级、
  /// 离线或状态过期仍然拒绝。真正发送仍必须通过 [canAutoDispatch]。
  bool canAcceptQueuedTask(SchedulingConfig config) {
    if (!isLanCapable ||
        connectionState != PrinterConnectionState.connected ||
        isStale(config)) {
      return false;
    }
    final status = lastStatus;
    if (status == null ||
        status.upgradeStatus?.isNotEmpty == true ||
        status.gcodeState == null) {
      return false;
    }
    return switch (status.gcodeState!) {
      BambuGcodeState.idle ||
      BambuGcodeState.finish ||
      BambuGcodeState.running ||
      BambuGcodeState.pause ||
      BambuGcodeState.init ||
      BambuGcodeState.prepare => true,
      _ => false,
    };
  }

  /// 校验现成 G-code 的精确机型与喷嘴硬约束。
  /// 返回 null 表示匹配，否则返回可展示的拒绝原因。
  String? targetSpecMismatch(PrinterModelSpec? targetSpec) {
    if (targetSpec == null) {
      return '任务缺少精确目标机型或喷嘴信息，请重新添加任务';
    }
    final model = reportedModel?.trim() ?? '';
    final canonical = PrinterModelNormalizer.normalize(model);
    if (model.isEmpty || !PrinterModelNormalizer.isKnownBambuModel(model)) {
      return '打印机精确机型未知，不能安全发送现成 G-code';
    }
    if (!PrinterModelNormalizer.sameModel(
      targetSpec.canonicalModel,
      canonical,
    )) {
      return '机型不匹配：任务要求 ${targetSpec.canonicalModel}，打印机为 $canonical';
    }
    final nozzle = installedNozzleDiameter;
    if (nozzle == null || nozzle <= 0) {
      return '打印机喷嘴直径未知，不能安全发送现成 G-code';
    }
    if ((targetSpec.nozzleDiameter - nozzle).abs() >= 0.001) {
      return '喷嘴不匹配：任务要求 ${targetSpec.nozzleDiameter}mm，'
          '打印机安装 ${nozzle}mm';
    }
    return null;
  }

  FleetPrinterState copyWith({
    String? displayLabel,
    PrinterConnectionState? connectionState,
    BambuPrinterStatus? lastStatus,
    DateTime? statusUpdatedAt,
    bool? isConnecting,
    String? reportedModel,
    double? installedNozzleDiameter,
  }) {
    return FleetPrinterState(
      serial: serial,
      displayLabel: displayLabel ?? this.displayLabel,
      connectionState: connectionState ?? this.connectionState,
      lastStatus: lastStatus ?? this.lastStatus,
      statusUpdatedAt: statusUpdatedAt ?? this.statusUpdatedAt,
      isLanCapable: isLanCapable,
      mode: mode,
      reportedModel: reportedModel ?? this.reportedModel,
      installedNozzleDiameter:
          installedNozzleDiameter ?? this.installedNozzleDiameter,
      isConnecting: isConnecting ?? this.isConnecting,
    );
  }
}

/// 单台打印机的内部连接条目（含 connector 和 stream 订阅）。
class _FleetEntry {
  final PrinterConnector connector;
  PrinterConnectionConfig config;
  StreamSubscription<dynamic>? statusSub;
  StreamSubscription<PrinterConnectionState>? connStateSub;
  StreamSubscription<String>? errorSub;
  FleetPrinterState state;
  final SpoolChangeDetector spoolChangeDetector;
  Timer? stateEmitTimer;
  bool pendingStateEmit = false;

  _FleetEntry({
    required this.connector,
    required this.config,
    required this.state,
    SpoolChangeDetector? spoolChangeDetector,
  }) : spoolChangeDetector = spoolChangeDetector ?? SpoolChangeDetector();
}

/// 多打印机连接管理器。
///
/// 维护 Map<serial, FleetPrinterState>，每台设备独立连接、独立重连、
/// 独立状态新鲜度跟踪。调度器通过 [getState] / [isLanCapable] /
/// [canAutoDispatch] 查询候选打印机状态。
///
/// **不破坏 ActivePrinterConnectionNotifier**：UI 活跃打印机仍由它管理，
/// 本管理器仅供调度器/舰队仪表盘使用。同一台打印机可能同时被两个组件
/// 连接（MQTT broker 支持多客户端），开销可接受。
class PrinterFleetConnectionManager
    extends StateNotifier<Map<String, FleetPrinterState>> {
  PrinterFleetConnectionManager(this._ref) : super(const {}) {
    _connectorFactory = _ref.read(printerConnectorFactoryProvider);
    // 监听打印机配置列表变化，自动同步连接
    _configListSub = _ref.listen(mergedPrinterListProvider, (previous, next) {
      _requestConfigSync(next);
    }, fireImmediately: true);
  }

  final Ref _ref;
  late final PrinterConnectorFactory _connectorFactory;
  final Map<String, _FleetEntry> _entries = {};
  final Map<String, Future<void>> _connectOperations = {};
  List<PrinterConnectionConfig>? _pendingConfigs;
  bool _isSyncingConfigs = false;
  bool _backgroundMonitoringEnabled = false;

  /// 并发连接上限（防止一次性连接几十台打印机导致资源耗尽）
  int _maxConcurrent = SchedulingConfig.defaults.maxConcurrentConnections;

  /// 当前正在连接的数量（用于并发控制）
  int _connectingCount = 0;

  late final ProviderSubscription<List<PrinterConnectionConfig>> _configListSub;

  /// 设置并发上限（可由配置页调整）
  void setMaxConcurrent(int value) {
    if (value < 1) return;
    _maxConcurrent = value;
  }

  /// 同步配置列表变化：新增的连接、移除的断开。
  ///
  /// 关键约束：仅 LAN 配置的打印机 isLanCapable=true，云连接的 isLanCapable=false。
  /// 同一 serial 若存在两种配置，由 mergedPrinterListProvider 的用户模式选择决定；
  /// 舰队连接不会跨模式自动切换。
  void _requestConfigSync(List<PrinterConnectionConfig> configs) {
    _pendingConfigs = List<PrinterConnectionConfig>.unmodifiable(configs);
    if (_isSyncingConfigs) return;
    unawaited(_drainConfigSync());
  }

  Future<void> _drainConfigSync() async {
    _isSyncingConfigs = true;
    try {
      while (mounted && _pendingConfigs != null) {
        final configs = _pendingConfigs!;
        _pendingConfigs = null;
        await _syncConfigs(configs);
      }
    } catch (error, stackTrace) {
      debugPrint('[FleetManager] 同步打印机配置失败: $error\n$stackTrace');
    } finally {
      _isSyncingConfigs = false;
      if (mounted && _pendingConfigs != null) {
        unawaited(_drainConfigSync());
      }
    }
  }

  Future<void> _syncConfigs(List<PrinterConnectionConfig> configs) async {
    if (!mounted) return;
    final newSerials = configs.map((c) => c.serial).toSet();
    final oldSerials = _entries.keys.toSet();

    // 移除已不存在的打印机
    for (final serial in oldSerials.difference(newSerials)) {
      await _disconnectAndRemove(serial);
    }

    // 新增或更新打印机
    for (final config in configs) {
      final existing = _entries[config.serial];
      if (existing != null) {
        // 只有端点或认证变化才重连。固件/云列表刷新带来的名称、
        // 机型和喷嘴元数据变化只更新展示状态。
        if (printerConnectionEndpointChanged(existing.config, config)) {
          await _disconnectAndRemove(config.serial);
          if (!mounted) return;
          await _connectSerialized(config);
        } else {
          existing.config = config;
          existing.state = existing.state.copyWith(
            displayLabel: config.displayLabel,
            reportedModel: config.devProductName,
            installedNozzleDiameter: config.installedNozzleDiameter,
          );
          _emitState(existing);
        }
        continue;
      }
      // 新打印机先注册 connector 条目但不连接，供 ensureConnected 按需使用。
      _registerDisconnected(config);
      if (_backgroundMonitoringEnabled) {
        await _connectSerialized(config);
      }
    }
  }

  void _registerDisconnected(PrinterConnectionConfig config) {
    if (!mounted) return;
    final entry = _FleetEntry(
      connector: _connectorFactory(config),
      config: config,
      state: FleetPrinterState(
        serial: config.serial,
        displayLabel: config.displayLabel,
        connectionState: PrinterConnectionState.disconnected,
        lastStatus: null,
        statusUpdatedAt: null,
        isLanCapable: config.mode == BambuConnectionMode.lan,
        mode: config.mode,
        reportedModel: config.devProductName,
        installedNozzleDiameter: config.installedNozzleDiameter,
        isConnecting: false,
      ),
    );
    _entries[config.serial] = entry;
    _emitState(entry);
  }

  /// 确保指定打印机已连接（若未连接则触发连接）。
  ///
  /// 调度器在评分前调用此方法确保候选打印机状态新鲜。
  /// 若正在连接中则直接返回，不重复触发。
  /// 若已超过并发上限则排队等待（简单实现：直接返回，下次调度再试）。
  Future<void> ensureConnected(String serial) async {
    final entry = _entries[serial];
    if (entry == null) return;
    if (entry.state.connectionState == PrinterConnectionState.connected) return;
    if (entry.state.isConnecting) return;
    if (_connectingCount >= _maxConcurrent) {
      debugPrint(
        '[FleetManager] 并发连接数已达上限 $_maxConcurrent，'
        '$serial 排队等待下次调度',
      );
      return;
    }
    await _connectSerialized(entry.config);
  }

  /// 为换料识别建立所有已配置打印机的后台监控连接。
  ///
  /// 调度器仍可按需连接；该入口只由应用级换料监控调用，串行建立连接，
  /// 避免多个 AMS 同时上线时造成连接风暴。
  Future<void> monitorAllConfigured() async {
    _backgroundMonitoringEnabled = true;
    final configs = _ref.read(mergedPrinterListProvider);
    for (final config in configs) {
      if (!mounted) return;
      final current = _entries[config.serial];
      if (current?.state.connectionState == PrinterConnectionState.connected) {
        // A connected printer can be quiet while idle.  Refreshing the fleet
        // must actively request a snapshot instead of treating the old state
        // as fresh merely because the socket is still open.
        try {
          await current!.connector.requestStatus();
        } catch (error) {
          debugPrint('[FleetManager] 请求 ${config.serial} 状态失败: $error');
        }
        continue;
      }
      await _connectSerialized(config);
    }
  }

  /// 停止农场后台监控，但保留打印机配置供个人工作台按需连接。
  Future<void> stopBackgroundMonitoring() async {
    _backgroundMonitoringEnabled = false;
    final configs = List<PrinterConnectionConfig>.from(
      _ref.read(mergedPrinterListProvider),
    );
    for (final serial in _entries.keys.toList(growable: false)) {
      await _disconnectAndRemove(serial);
    }
    if (mounted) _requestConfigSync(configs);
  }

  Future<void> _connectSerialized(PrinterConnectionConfig config) {
    final existing = _connectOperations[config.serial];
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = _connectPrinter(config).whenComplete(() {
      if (identical(_connectOperations[config.serial], operation)) {
        _connectOperations.remove(config.serial);
      }
    });
    _connectOperations[config.serial] = operation;
    return operation;
  }

  /// 连接并等待该设备返回一份未过期的状态事实。
  Future<FleetPrinterState?> ensureFreshStatus(
    String serial,
    SchedulingConfig config, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await ensureConnected(serial);
    final current = state[serial];
    final entry = _entries[serial];
    FleetPrinterState? fresh;
    if (current != null &&
        current.connectionState == PrinterConnectionState.connected &&
        current.lastStatus != null &&
        !current.isStale(config)) {
      fresh = current;
    } else {
      // Connected printers may stop publishing telemetry while idle. Ask for
      // one explicit snapshot before waiting on the stream so the refresh
      // button and print preflight can recover without reconnecting the unit.
      if (entry != null && entry.connector.isConnected) {
        try {
          await entry.connector.requestStatus();
        } catch (error) {
          debugPrint('[FleetManager] 请求 $serial 状态失败: $error');
        }
      }
      try {
        fresh = await stream
            .map((snapshot) => snapshot[serial])
            .where(
              (item) =>
                  item != null &&
                  item.connectionState == PrinterConnectionState.connected &&
                  item.lastStatus != null &&
                  !item.isStale(config),
            )
            .cast<FleetPrinterState>()
            .first
            .timeout(timeout);
      } on TimeoutException {
        fresh = state[serial];
      }
    }

    // A status push also triggers a database channel sync (AMS/external
    // slots, RFID bindings and live remaining grams).  The listener starts
    // that work in the background for normal telemetry, but a print preflight
    // must wait for it so the mapping dialog never renders an older slot
    // layout than the status it just validated.
    final status = fresh?.lastStatus;
    if (entry != null && status != null) {
      await _syncObservedTrays(entry.config, status);
    }
    return fresh;
  }

  /// 使用指定打印机自己的舰队连接发送任务，不依赖当前 UI 活跃打印机。
  Future<bool> sendPrintTask(
    String serial,
    String filePath, {
    List<int>? amsMapping,
    int plateIndex = 1,
  }) async {
    await ensureConnected(serial);
    final entry = _entries[serial];
    if (entry == null || entry.config.mode != BambuConnectionMode.lan) {
      return false;
    }
    if (!entry.connector.isConnected ||
        entry.state.connectionState != PrinterConnectionState.connected) {
      return false;
    }
    return entry.connector.sendPrintTask(
      filePath,
      amsMapping: amsMapping,
      plateIndex: plateIndex,
    );
  }

  /// 主动连接指定打印机。
  Future<void> _connectPrinter(PrinterConnectionConfig config) async {
    // 移除旧条目（若存在）
    final existing = _entries[config.serial];
    if (existing != null) {
      await _cleanupEntry(existing);
    }

    // 标记为 connecting
    final entry = _FleetEntry(
      connector: _connectorFactory(config),
      config: config,
      state: FleetPrinterState(
        serial: config.serial,
        displayLabel: config.displayLabel,
        connectionState: PrinterConnectionState.connecting,
        lastStatus: null,
        statusUpdatedAt: null,
        isLanCapable: config.mode == BambuConnectionMode.lan,
        mode: config.mode,
        reportedModel: config.devProductName,
        installedNozzleDiameter: config.installedNozzleDiameter,
        isConnecting: true,
      ),
    );
    _entries[config.serial] = entry;
    _connectingCount++;
    _emitState(entry);

    // 订阅状态流（statusStream 推送时更新 statusUpdatedAt）
    entry.statusSub = entry.connector.statusStream.listen((rawStatus) {
      if (!mounted || !identical(_entries[config.serial], entry)) return;
      if (rawStatus is! BambuPrinterStatus) return;
      final status = rawStatus;
      unawaited(
        _ref
            .read(printerFaultMonitorProvider.notifier)
            .observe(
              serial: config.serial,
              name: config.displayLabel,
              model: entry.state.reportedModel ?? '',
              status: status,
            ),
      );
      final previousStatus = entry.state.lastStatus;
      final hadStatus = previousStatus != null;
      final changes = entry.spoolChangeDetector.update(
        printerSerial: config.serial,
        printerLabel: config.displayLabel,
        trays: status.amsTrays,
        units: status.amsUnits,
        externalTrays: status.externalTrays,
        extruderFilamentPresent: status.extruderFilamentPresent,
        hwSwitchState: status.hwSwitchState,
        printStage: status.mcPrintStage,
        trayNow: status.trayNow,
      );
      if (changes.isNotEmpty) {
        final accountScope = _ref.read(personalInventoryAccountScopeProvider);
        _ref
            .read(spoolChangeQueueProvider.notifier)
            .observeAll(
              changes,
              personalOwnerAccount: accountScope.enforce
                  ? accountScope.ownerAccount
                  : null,
            );
      }
      entry.state = entry.state.copyWith(
        lastStatus: status,
        statusUpdatedAt: DateTime.now(),
      );
      // Cloud MQTT can publish fast-changing telemetry several times per
      // frame. Keep parsing every message for printer logic, but coalesce the
      // provider notification so the whole farm UI is not rebuilt for each
      // temperature or progress tick.
      _emitState(
        entry,
        coalesce:
            previousStatus != null &&
            !_statusNeedsImmediateFleetEmit(previousStatus, status),
      );
      if (!hadStatus || changes.isNotEmpty) {
        unawaited(_syncObservedTrays(config, status));
      }
    });

    // 订阅连接状态流
    entry.connStateSub = entry.connector.connectionStateStream.listen((cs) {
      if (!mounted || !identical(_entries[config.serial], entry)) return;
      entry.state = entry.state.copyWith(connectionState: cs);
      _emitState(entry);
    });

    // 订阅错误流
    entry.errorSub = entry.connector.errorStream.listen((error) {
      debugPrint('[FleetManager] ${config.serial} 错误: $error');
    });

    try {
      final ok = await entry.connector.connect();
      if (!ok && mounted) {
        entry.state = entry.state.copyWith(
          connectionState: PrinterConnectionState.error,
        );
        _emitState(entry);
      }
    } catch (e) {
      debugPrint('[FleetManager] ${config.serial} 连接异常: $e');
      if (mounted) {
        entry.state = entry.state.copyWith(
          connectionState: PrinterConnectionState.error,
        );
        _emitState(entry);
      }
    } finally {
      _connectingCount = (_connectingCount - 1).clamp(0, 1 << 30);
      if (mounted && identical(_entries[config.serial], entry)) {
        entry.state = entry.state.copyWith(isConnecting: false);
        _emitState(entry);
      }
    }
  }

  Future<void> _syncObservedTrays(
    PrinterConnectionConfig config,
    BambuPrinterStatus status,
  ) async {
    final trays = status.amsTrays;
    final sensorCount =
        status.extruderFilamentPresent?.length ??
        (status.hwSwitchState == null ? 0 : 1);
    final metadataCount = status.externalTrays?.length ?? 0;
    final externalCount =
        PrinterPresets.findByModel(
          config.devProductName ?? '',
        )?.externalInputCount ??
        (sensorCount > metadataCount ? sensorCount : metadataCount);
    if ((trays == null || trays.isEmpty) &&
        status.amsUnits == null &&
        externalCount == 0) {
      return;
    }
    try {
      final printerId = await _ref
          .read(printerDaoProvider)
          .getPrinterIdBySerial(config.serial);
      if (printerId == null) return;
      final printerDao = _ref.read(printerDaoProvider);
      if (externalCount > 0) {
        final hasAms =
            status.amsUnits?.any((unit) => unit.isPresent) == true ||
            trays?.any((tray) => tray.amsId >= 0) == true;
        await printerDao.syncExternalFeedChannels(
          printerId,
          externalInputCount: externalCount,
          hasAms: hasAms,
        );
        final occupancy = externalFeedSensorReadings(
          sensors: status.extruderFilamentPresent,
          trayNow: status.trayNow,
          hwSwitchState: status.hwSwitchState,
          units: status.amsUnits,
          trays: status.amsTrays,
        );
        if (occupancy.isNotEmpty) {
          await printerDao.syncExternalFeedOccupancy(
            printerId,
            occupancy,
            unbindEmpty: _ref.read(studioModeEnabledProvider),
          );
        }
      }
      if (status.amsUnits != null || (trays != null && trays.isNotEmpty)) {
        await printerDao.syncChannelsFromAms(
          printerId,
          trays ?? const <AmsTray>[],
          amsUnits: status.amsUnits,
          autoBindRfid: true,
          // 普通用户先询问拔料原因；农场继续沿用自动清空流程。
          unbindEmpty: _ref.read(studioModeEnabledProvider),
          farmMode: _ref.read(studioModeEnabledProvider),
          personalOwnerAccount:
              _ref.read(personalInventoryAccountScopeProvider).enforce
              ? _ref.read(personalInventoryAccountScopeProvider).ownerAccount
              : null,
        );
      }
      await enqueueUnboundFeedConfiguration(
        queue: _ref.read(spoolChangeQueueProvider.notifier),
        printerDao: printerDao,
        printerId: printerId,
        printerSerial: config.serial,
        printerLabel: config.displayLabel,
        status: status,
        farmMode: _ref.read(studioModeEnabledProvider),
        personalOwnerAccount: _ref
            .read(personalInventoryAccountScopeProvider)
            .ownerAccount,
      );
    } catch (error) {
      debugPrint('[FleetManager] 同步 ${config.serial} 槽位失败: $error');
    }
  }

  /// 断开指定打印机并移除条目。
  Future<void> _disconnectAndRemove(String serial) async {
    final connecting = _connectOperations[serial];
    if (connecting != null) await connecting;
    final entry = _entries.remove(serial);
    if (entry == null) return;
    await _cleanupEntry(entry);
    if (mounted) {
      final newState = Map<String, FleetPrinterState>.from(state);
      newState.remove(serial);
      state = newState;
    }
  }

  /// 清理 entry 的订阅和 connector。
  Future<void> _cleanupEntry(_FleetEntry entry) async {
    entry.stateEmitTimer?.cancel();
    entry.stateEmitTimer = null;
    entry.pendingStateEmit = false;
    await entry.statusSub?.cancel();
    await entry.connStateSub?.cancel();
    await entry.errorSub?.cancel();
    entry.statusSub = null;
    entry.connStateSub = null;
    entry.errorSub = null;
    try {
      await entry.connector.disconnect();
      await entry.connector.dispose();
    } catch (e) {
      debugPrint('[FleetManager] 清理 connector 异常: $e');
    }
  }

  /// 推送单台打印机状态到 state。
  void _emitState(_FleetEntry entry, {bool coalesce = false}) {
    if (!mounted || !identical(_entries[entry.state.serial], entry)) return;
    if (coalesce) {
      entry.pendingStateEmit = true;
      if (entry.stateEmitTimer?.isActive == true) return;
      // One fleet snapshot per second is sufficient for temperatures and
      // progress while keeping large farm workspaces responsive. State
      // transitions handled by _statusNeedsImmediateFleetEmit bypass this.
      entry.stateEmitTimer = Timer(const Duration(seconds: 1), () {
        entry.stateEmitTimer = null;
        if (!mounted || !identical(_entries[entry.state.serial], entry)) {
          entry.pendingStateEmit = false;
          return;
        }
        if (!entry.pendingStateEmit) return;
        entry.pendingStateEmit = false;
        _emitStateNow(entry);
      });
      return;
    }
    entry.stateEmitTimer?.cancel();
    entry.stateEmitTimer = null;
    entry.pendingStateEmit = false;
    _emitStateNow(entry);
  }

  void _emitStateNow(_FleetEntry entry) {
    if (!mounted || !identical(_entries[entry.state.serial], entry)) return;
    final newState = Map<String, FleetPrinterState>.from(state);
    newState[entry.state.serial] = entry.state;
    state = newState;
  }

  static bool _statusNeedsImmediateFleetEmit(
    BambuPrinterStatus before,
    BambuPrinterStatus after,
  ) {
    return before.gcodeState != after.gcodeState ||
        before.trayNow != after.trayNow ||
        before.gcodeFile != after.gcodeFile ||
        before.subtaskName != after.subtaskName ||
        before.failReason != after.failReason ||
        before.printError != after.printError ||
        !listEquals(
          before.hmsAlerts?.map((h) => '${h.code}:${h.severity}').toList(),
          after.hmsAlerts?.map((h) => '${h.code}:${h.severity}').toList(),
        ) ||
        before.upgradeStatus != after.upgradeStatus ||
        before.upgradeProgress != after.upgradeProgress ||
        before.amsDrying != after.amsDrying;
  }

  /// 查询指定打印机的状态快照。
  FleetPrinterState? getState(String serial) => state[serial];

  /// 查询指定打印机是否具备 LAN 配置（可自动下发）。
  bool? isLanCapable(String serial) => state[serial]?.isLanCapable;

  /// 查询指定打印机是否可自动下发（综合判断）。
  bool canAutoDispatch(String serial, SchedulingConfig config) {
    final s = state[serial];
    if (s == null) return false;
    return s.canAutoDispatch(config);
  }

  /// 主动断开指定打印机（用户在 UI 手动断开时调用）。
  Future<void> disconnectPrinter(String serial) async {
    await _disconnectAndRemove(serial);
    // 重新注册为 disconnected 状态（保留在列表中）
    final configs = _ref.read(mergedPrinterListProvider);
    for (final c in configs) {
      if (c.serial == serial) {
        _registerDisconnected(c);
        break;
      }
    }
  }

  /// 主动连接指定打印机（用户在 UI 手动连接时调用）。
  Future<void> connectPrinter(String serial) async {
    final configs = _ref.read(mergedPrinterListProvider);
    for (final c in configs) {
      if (c.serial == serial) {
        await _connectSerialized(c);
        return;
      }
    }
    debugPrint('[FleetManager] 未找到 serial=$serial 的配置');
  }

  /// 获取所有已知打印机的状态（UI 舰队仪表盘用）。
  /// 返回列表按 serial 排序，便于 UI 稳定渲染。
  List<FleetPrinterState> getAllStates() {
    final list = state.values.toList();
    list.sort((a, b) => a.serial.compareTo(b.serial));
    return list;
  }

  /// 获取所有可自动下发的打印机 serial（调度器候选池）。
  List<String> getAutoDispatchableSerials(SchedulingConfig config) {
    return state.values
        .where((s) => s.canAutoDispatch(config))
        .map((s) => s.serial)
        .toList();
  }

  /// 获取所有"仅监控"的打印机 serial（仅云连接，无法自动下发）。
  List<String> getMonitorOnlySerials() {
    return state.values
        .where((s) => !s.isLanCapable)
        .map((s) => s.serial)
        .toList();
  }

  @override
  void dispose() {
    _configListSub.close();
    _pendingConfigs = null;
    final entries = _entries.values.toList(growable: false);
    _entries.clear();
    _connectOperations.clear();
    for (final entry in entries) {
      unawaited(
        _cleanupEntry(entry).catchError((Object error, StackTrace stackTrace) {
          debugPrint('[FleetManager] dispose 清理失败: $error\n$stackTrace');
        }),
      );
    }
    super.dispose();
  }
}

/// 舰队连接管理器 Provider。
///
/// **生命周期**：应用级单例，与 App 生命周期一致。
/// 不要用 autoDispose，否则调度器在后台运行时连接会被断开。
final printerFleetConnectionManagerProvider =
    StateNotifierProvider<
      PrinterFleetConnectionManager,
      Map<String, FleetPrinterState>
    >((ref) {
      return PrinterFleetConnectionManager(ref);
    });

/// 便捷 Provider：所有打印机舰队状态列表（按 serial 排序）。
final fleetPrinterStatesProvider = Provider<List<FleetPrinterState>>((ref) {
  return ref.watch(printerFleetConnectionManagerProvider).values.toList()
    ..sort((a, b) => a.serial.compareTo(b.serial));
});

/// 便捷 Provider：可自动下发的打印机 serial 列表。
final autoDispatchableSerialsProvider = Provider<List<String>>((ref) {
  final manager = ref.watch(printerFleetConnectionManagerProvider.notifier);
  return manager.getAutoDispatchableSerials(SchedulingConfig.defaults);
});

/// 便捷 Provider：仅监控的打印机 serial 列表。
final monitorOnlySerialsProvider = Provider<List<String>>((ref) {
  final manager = ref.watch(printerFleetConnectionManagerProvider.notifier);
  return manager.getMonitorOnlySerials();
});
