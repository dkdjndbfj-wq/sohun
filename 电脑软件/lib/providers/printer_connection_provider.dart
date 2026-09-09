import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/error_logger.dart';
import '../core/services/printer_fault_monitor.dart';
import '../core/services/kill_switch_service.dart';
import '../core/services/notification_service.dart';
import '../core/services/consumable_twin_service.dart';
import '../core/services/product_issue_collector.dart';
import '../core/services/spool_change_detector.dart';
import '../data/database/models/ams_change_event.dart';
import '../data/database/daos/printer_dao.dart';
import '../data/external/printer/bambu_cloud_client.dart';
import '../data/external/printer/bambu_cloud_models.dart';
import '../data/external/printer/bambu_cloud_session_store.dart';
import '../data/external/printer/bambu_printer_connector.dart';
import '../data/external/printer/bambu_printer_models.dart';
import '../data/external/printer/printer_connection_store.dart';
import '../data/external/printer/printer_certificate_trust_store.dart';
import '../data/external/printer/printer_connector.dart';
import '../data/database/models/printer_feed_models.dart';
import '../data/seed/printer_seed.dart';
import '../data/external/slicer/bambu_studio_lan_config_writer.dart';
import '../data/external/slicer/slice_isolate_runner.dart';
import '../data/prefs/app_prefs.dart';
import 'bambu_account_manager.dart';
import 'consumable_provider.dart';
import 'database_provider.dart';
import 'spool_change_provider.dart';

/// 打印机连接配置列表（多台打印机）。
/// LAN access code 由 Windows DPAPI 加密后持久化。
class PrinterConnectionListNotifier
    extends StateNotifier<List<PrinterConnectionConfig>> {
  PrinterConnectionListNotifier(this._ref, this._store) : super([]) {
    _ready = _load();
  }

  final Ref _ref;
  final PrinterConnectionStore _store;
  late final Future<void> _ready;
  Future<void> _mutationQueue = Future<void>.value();

  Future<void> get ready => _ready;

  Future<void> _load() async {
    try {
      final list = await _store.read();
      if (!mounted) return;
      state = list;
      await _syncLanConnectionsToWorkbench(state);
      _ref.read(printerConnectionLoadErrorProvider.notifier).state = null;
    } catch (e, st) {
      ErrorLogger.log(
        e,
        st,
        source: 'printer_connection_config',
        level: ErrorLevel.error,
        context: {'phase': 'load_protected_connections'},
      );
      if (mounted) {
        _ref.read(printerConnectionLoadErrorProvider.notifier).state =
            '打印机连接配置无法安全解密。原始密文已保留，请重新添加连接或检查当前 Windows 用户。';
      }
    }
  }

  Future<void> _save([List<PrinterConnectionConfig>? snapshot]) async {
    await _store.write(snapshot ?? state);
    _ref.read(printerConnectionLoadErrorProvider.notifier).state = null;
  }

  Future<void> _enqueueMutation(Future<void> Function() mutation) {
    final result = _mutationQueue.then((_) => mutation());
    // Keep the queue usable after a failed write while preserving the error
    // for the caller that initiated this mutation.
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  Future<void> add(PrinterConnectionConfig config) async {
    await addAll([config]);
  }

  /// 一次持久化多台 LAN 打印机，避免逐台写入凭据时留下半完成批次。
  Future<void> addAll(Iterable<PrinterConnectionConfig> configs) {
    final snapshot = configs.toList(growable: false);
    return _enqueueMutation(() => _addAllInternal(snapshot));
  }

  Future<void> _addAllInternal(
    Iterable<PrinterConnectionConfig> configs,
  ) async {
    await _ready;
    final incomingBySerial = <String, PrinterConnectionConfig>{};
    for (final config in configs) {
      if (config.serial.trim().isEmpty) {
        throw ArgumentError.value(config.serial, 'serial', '打印机序列号不能为空');
      }
      incomingBySerial[config.serial] = config;
    }
    final incoming = incomingBySerial.values.toList(growable: false);
    if (incoming.isEmpty) return;

    final serials = incomingBySerial.keys.toSet();
    final hosts = incoming
        .where((config) => config.mode == BambuConnectionMode.lan)
        .map((config) => config.host)
        .where((host) => host.isNotEmpty)
        .toSet();
    final previousState = state;
    final replaced = previousState
        .where(
          (config) =>
              serials.contains(config.serial) ||
              (config.host.isNotEmpty && hosts.contains(config.host)),
        )
        .toList(growable: false);
    state = [
      ...previousState.where(
        (config) =>
            !serials.contains(config.serial) &&
            (config.host.isEmpty || !hosts.contains(config.host)),
      ),
      ...incoming,
    ];
    final nextState = state;
    try {
      await _save(nextState);
    } catch (_) {
      if (mounted && identical(state, nextState)) state = previousState;
      rethrow;
    }

    for (final config in incoming) {
      await _syncLanConnectionToWorkbench(config);
      await _syncLanAccessCodeToBs(config, isAdd: true);
    }
    for (final previous in replaced) {
      final replacement = incomingBySerial[previous.serial];
      if (replacement == null || previous.host != replacement.host) {
        await PrinterCertificateTrustStore.forgetIdentity(
          serial: previous.serial,
          host: previous.host,
        );
      }
    }
  }

  Future<void> _syncLanConnectionsToWorkbench(
    Iterable<PrinterConnectionConfig> configs,
  ) async {
    for (final config in configs) {
      await _syncLanConnectionToWorkbench(config);
    }
  }

  Future<void> _syncLanConnectionToWorkbench(
    PrinterConnectionConfig config,
  ) async {
    if (config.mode != BambuConnectionMode.lan) return;
    try {
      await _ref.read(printerDaoProvider).upsertLanConnection(config);
    } catch (error, stackTrace) {
      ErrorLogger.log(
        error,
        stackTrace,
        source: 'lan_printer_workbench_sync',
        level: ErrorLevel.error,
        context: {'serial': config.serial},
      );
    }
  }

  Future<void> remove(String serial) =>
      _enqueueMutation(() => _removeInternal(serial));

  Future<void> _removeInternal(String serial) async {
    await _ready;
    final previousState = state;
    final removed = previousState.where((c) => c.serial == serial).toList();
    final nextState = previousState
        .where((c) => c.serial != serial)
        .toList(growable: false);
    state = nextState;
    try {
      await _save(nextState);
    } catch (_) {
      if (mounted && identical(state, nextState)) state = previousState;
      rethrow;
    }
    // 从 BS 配置中移除对应 access code
    for (final c in removed) {
      await _syncLanAccessCodeToBs(c, isAdd: false);
      await PrinterCertificateTrustStore.forgetIdentity(
        serial: c.serial,
        host: c.host,
      );
    }
  }

  /// 将 LAN 配置的 access code 同步到 Bambu Studio 配置文件。
  /// BS 未安装/正在运行时静默跳过，不报错。
  /// serial 为 IP 时跳过（BS 的 user_access_code key 必须是真实序列号）。
  Future<void> _syncLanAccessCodeToBs(
    PrinterConnectionConfig config, {
    required bool isAdd,
  }) async {
    try {
      if (!_ref.read(printerConnectionBambuStudioSyncEnabledProvider)) return;
      if (!BambuStudioLanConfigWriter.isInstalled()) return;
      if (config.mode != BambuConnectionMode.lan) return;
      if (config.serial.isEmpty || config.accessCode.isEmpty) return;
      // serial 为 IP 时跳过（BS 无法用 IP 匹配 access code）
      if (_looksLikeIp(config.serial)) {
        debugPrint('[PrinterConnList] serial 为 IP(${config.serial})，跳过 BS 同步');
        return;
      }
      if (isAdd) {
        final ok = await BambuStudioLanConfigWriter.writeLanAccessCode(
          serial: config.serial,
          accessCode: config.accessCode,
        );
        if (!ok) {
          debugPrint(
            '[PrinterConnList] BS 正在运行，access code 同步跳过（将在下次 BS 切换账号时批量补写）',
          );
        }
      } else {
        await BambuStudioLanConfigWriter.removeLanAccessCode(config.serial);
      }
    } catch (e) {
      debugPrint('[PrinterConnList] 同步 access code 到 BS 失败: $e');
    }
  }

  /// 判断字符串是否像 IP 地址（如 192.168.31.100）
  bool _looksLikeIp(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) => int.tryParse(p) != null);
  }

  PrinterConnectionConfig? get(String serial) {
    for (final c in state) {
      if (c.serial == serial) return c;
    }
    return null;
  }
}

final printerConnectionStoreProvider = Provider<PrinterConnectionStore>((ref) {
  return DpapiPrinterConnectionStore();
});

/// Allows tests and isolated environments to disable writes to the user's
/// real Bambu Studio configuration while keeping LAN persistence exercised.
final printerConnectionBambuStudioSyncEnabledProvider = Provider<bool>(
  (ref) => true,
);

final printerConnectionListProvider =
    StateNotifierProvider<
      PrinterConnectionListNotifier,
      List<PrinterConnectionConfig>
    >((ref) {
      return PrinterConnectionListNotifier(
        ref,
        ref.watch(printerConnectionStoreProvider),
      );
    });

/// 连接配置损坏时向设置页暴露明确错误，不再静默显示为空列表。
final printerConnectionLoadErrorProvider = StateProvider<String?>(
  (ref) => null,
);

/// 所有账号的云端设备聚合状态。
///
/// 遍历所有已登录账号的 session，串行调用 getDeviceList 拉取设备列表
/// （串行避免触发拓竹云限流），合并后供 mergedPrinterListProvider 使用。
///
/// 刷新策略：启动时拉一次 + 用户手动刷新。切换账号不再触发重新拉取
/// （因为所有账号的设备本来就在列表里）。
class AllCloudDevicesState {
  /// 所有账号的云设备合并列表
  final List<BambuCloudDevice> devices;

  /// serial → "email|region_code" 归属映射
  final Map<String, String> ownerMap;

  /// 最后一次刷新时间
  final DateTime? lastRefreshed;

  /// 是否正在刷新
  final bool isLoading;

  /// 拉取失败的账号列表（token 过期 / 网络错误等）
  /// key: "email|region_code"，value: 错误信息
  final Map<String, String> failedAccounts;

  /// 是否全部账号都拉取失败（网络断开等）
  bool get allFailed =>
      failedAccounts.isNotEmpty && devices.isEmpty && lastRefreshed != null;

  const AllCloudDevicesState({
    this.devices = const [],
    this.ownerMap = const {},
    this.lastRefreshed,
    this.isLoading = false,
    this.failedAccounts = const {},
  });

  AllCloudDevicesState copyWith({
    List<BambuCloudDevice>? devices,
    Map<String, String>? ownerMap,
    DateTime? lastRefreshed,
    bool? isLoading,
    Map<String, String>? failedAccounts,
  }) {
    return AllCloudDevicesState(
      devices: devices ?? this.devices,
      ownerMap: ownerMap ?? this.ownerMap,
      lastRefreshed: lastRefreshed ?? this.lastRefreshed,
      isLoading: isLoading ?? this.isLoading,
      failedAccounts: failedAccounts ?? this.failedAccounts,
    );
  }
}

@visibleForTesting
bool cloudDeviceListsEquivalent(
  List<BambuCloudDevice> previous,
  List<BambuCloudDevice> next,
) {
  if (identical(previous, next)) return true;
  if (previous.length != next.length) return false;
  for (var i = 0; i < previous.length; i++) {
    final a = previous[i];
    final b = next[i];
    if (a.devId != b.devId ||
        a.name != b.name ||
        a.online != b.online ||
        a.printStatus != b.printStatus ||
        a.devModelName != b.devModelName ||
        a.devProductName != b.devProductName ||
        a.devAccessCode != b.devAccessCode ||
        a.nozzleDiameter != b.nozzleDiameter ||
        a.swVer != b.swVer ||
        a.hwVer != b.hwVer ||
        a.deviceOemType != b.deviceOemType ||
        !mapEquals(a.moduleVersions, b.moduleVersions)) {
      return false;
    }
  }
  return true;
}

class AllCloudDevicesNotifier extends StateNotifier<AllCloudDevicesState> {
  final Ref _ref;
  AllCloudDevicesNotifier(this._ref) : super(const AllCloudDevicesState());

  /// 遍历所有已登录账号串行拉取设备列表。
  /// [forceRefresh] 为 true 时强制重新拉取，否则若已有数据则跳过。
  Future<void> refresh({bool forceRefresh = false}) async {
    if (state.isLoading) return;
    if (!forceRefresh &&
        state.devices.isNotEmpty &&
        state.lastRefreshed != null &&
        DateTime.now().difference(state.lastRefreshed!) <
            const Duration(minutes: 5)) {
      return; // 5 分钟内有数据，跳过
    }

    state = state.copyWith(isLoading: true);

    try {
      // 用 ref.watch 声明对 bambuAccountManagerProvider 的依赖（让 Riverpod 管理依赖图），
      // 替代原来的 ref.read。在 StateNotifier 方法中 ref.watch 行为等同于 ref.read
      // （仅获取当前值，依赖注册发生在构造时），但语义上更清晰地表达依赖关系。
      // TODO: 若要真正让 Riverpod 自动响应账号列表变化并触发刷新，
      // 需在构造时用 ref.listen(bambuAccountManagerProvider, ...) 并在回调中调用 refresh，
      // 或将 allCloudDevicesProvider 重构为依赖 bambuAccountManagerProvider 的派生 provider。
      // 当前保守起见保持命令式 refresh 调用，避免引入状态重置等回归风险。
      final managerState = _ref.watch(bambuAccountManagerProvider);
      // 无账号时直接清空
      if (managerState.accounts.isEmpty) {
        if (mounted) {
          state = AllCloudDevicesState(
            lastRefreshed: DateTime.now(),
            isLoading: false,
          );
        }
        return;
      }

      final allDevices = <BambuCloudDevice>[];
      final ownerMap = <String, String>{};
      final failedAccounts = <String, String>{};

      // 遍历所有账号，串行拉取（避免限流）
      for (final account in managerState.accounts) {
        final key = '${account.email}|${account.region.code}';
        var session = managerState.sessions[key];
        if (session == null || session.accessToken.isEmpty) {
          failedAccounts[key] = 'session 缺失';
          continue;
        }
        if (session.isExpired) {
          try {
            final login = await BambuCloudClient.loginWithPassword(
              region: account.region,
              account: account.email,
              password: account.password,
            );
            if (login.needsVerificationCode) {
              failedAccounts[key] = '登录已过期，需要验证码确认';
              continue;
            }
            session = login.session!;
            await BambuCloudSessionStore.upsertSession(session);
          } catch (e) {
            failedAccounts[key] = '自动续登失败：$e';
            continue;
          }
        }
        try {
          final devices = await BambuCloudClient.getDeviceList(session);
          for (final d in devices) {
            if (d.devId.isEmpty) continue;
            allDevices.add(d);
            ownerMap[d.devId] = key;
            // P0 修复：将云端设备同步写入本地数据库，
            // Dashboard 的打印机列表来源是本地数据库（printersWithChannelsProvider），
            // 否则会出现"账号有设备但软件显示 0 台"的链路断裂
            try {
              await _ref.read(printerDaoProvider).upsertCloudDevice(d);
            } catch (e) {
              debugPrint('[AllCloudDevices] 同步设备 ${d.devId} 到本地失败: $e');
            }
          }
        } catch (e) {
          debugPrint('[AllCloudDevices] 拉取账号 ${account.email} 设备失败: $e');
          // 区分 token 过期和其他错误
          final errStr = e.toString();
          if (errStr.contains('401') || errStr.contains('Unauthorized')) {
            failedAccounts[key] = 'token 过期，请重新登录';
          } else if (errStr.contains('SocketException') ||
              errStr.contains('HandshakeException') ||
              errStr.contains('TimeoutException')) {
            failedAccounts[key] = '网络错误';
          } else {
            failedAccounts[key] = errStr;
          }
        }
      }

      if (mounted) {
        final stableDevices =
            cloudDeviceListsEquivalent(state.devices, allDevices)
            ? state.devices
            : List<BambuCloudDevice>.unmodifiable(allDevices);
        final stableOwnerMap = mapEquals(state.ownerMap, ownerMap)
            ? state.ownerMap
            : Map<String, String>.unmodifiable(ownerMap);
        state = AllCloudDevicesState(
          devices: stableDevices,
          ownerMap: stableOwnerMap,
          lastRefreshed: DateTime.now(),
          isLoading: false,
          failedAccounts: failedAccounts,
        );
      }
    } catch (e) {
      debugPrint('[AllCloudDevices] 刷新失败: $e');
      if (mounted) state = state.copyWith(isLoading: false);
    }
  }
}

final allCloudDevicesProvider =
    StateNotifierProvider<AllCloudDevicesNotifier, AllCloudDevicesState>((ref) {
      return AllCloudDevicesNotifier(ref);
    });

/// 打印机归属映射：serial → "email|region_code"（仅云设备有归属，LAN 为 null）。
final printerOwnerMapProvider = Provider<Map<String, String>>((ref) {
  return ref.watch(allCloudDevicesProvider.select((state) => state.ownerMap));
});

/// 每台打印机当前明确选择的连接模式。
///
/// 云端和局域网是两套独立链路。保存 LAN 配置不应自动覆盖云端模式，
/// 云连接失败也不应静默切换到 LAN。用户从相应入口选择模式后持久化到本机。
class PrinterConnectionModeSelectionNotifier
    extends StateNotifier<Map<String, BambuConnectionMode>> {
  PrinterConnectionModeSelectionNotifier() : super(const {}) {
    unawaited(_load());
  }

  static const _storageKey = 'printer_connection_mode_selection_v1';
  Future<void> _mutationQueue = Future<void>.value();

  /// SharedPreferences is restored asynchronously at startup. Preserve a
  /// mode selected by the user while that restore is still in flight.
  Future<void> _mergeRestoredState(
    Map<String, BambuConnectionMode> restored,
  ) async {
    if (!mounted) return;
    state = Map.unmodifiable({...restored, ...state});
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final restored = <String, BambuConnectionMode>{};
      for (final entry in decoded.entries) {
        final serial = entry.key.toString().trim();
        if (serial.isEmpty) continue;
        restored[serial] = entry.value == BambuConnectionMode.lan.name
            ? BambuConnectionMode.lan
            : BambuConnectionMode.cloud;
      }
      await _mergeRestoredState(restored);
    } catch (error) {
      debugPrint('[PrinterConnectionMode] 读取连接模式失败: $error');
    }
  }

  Future<void> _enqueueMutation(Future<void> Function() mutation) {
    final result = _mutationQueue.then((_) => mutation());
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  Future<void> select(String serial, BambuConnectionMode mode) {
    final normalized = serial.trim();
    if (normalized.isEmpty) return Future<void>.value();
    return _enqueueMutation(() => _selectInternal(normalized, mode));
  }

  Future<void> _selectInternal(String serial, BambuConnectionMode mode) async {
    final previousState = state;
    final nextState = Map<String, BambuConnectionMode>.unmodifiable({
      ...previousState,
      serial: mode,
    });
    state = nextState;
    try {
      await _save(nextState);
    } catch (_) {
      if (mounted && identical(state, nextState)) state = previousState;
      rethrow;
    }
  }

  Future<void> clear(String serial) {
    final normalized = serial.trim();
    if (normalized.isEmpty) return Future<void>.value();
    return _enqueueMutation(() => _clearInternal(normalized));
  }

  Future<void> _clearInternal(String serial) async {
    if (!state.containsKey(serial)) return;
    final previousState = state;
    final nextState = Map<String, BambuConnectionMode>.from(previousState)
      ..remove(serial);
    final next = Map<String, BambuConnectionMode>.unmodifiable(nextState);
    state = next;
    try {
      await _save(next);
    } catch (_) {
      if (mounted && identical(state, next)) state = previousState;
      rethrow;
    }
  }

  Future<void> _save(Map<String, BambuConnectionMode> snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _storageKey,
      jsonEncode({
        for (final entry in snapshot.entries) entry.key: entry.value.name,
      }),
    );
    if (!saved) throw StateError('无法保存打印机连接模式');
  }
}

final printerConnectionModeSelectionProvider =
    StateNotifierProvider<
      PrinterConnectionModeSelectionNotifier,
      Map<String, BambuConnectionMode>
    >((ref) {
      return PrinterConnectionModeSelectionNotifier();
    });

BambuCloudSession? cloudSessionForPrinterSerial({
  required String serial,
  required Map<String, String> ownerMap,
  required BambuAccountManagerState accountState,
}) {
  final ownerKey = ownerMap[serial];
  return ownerKey == null ? null : accountState.sessions[ownerKey];
}

@visibleForTesting
List<PrinterConnectionConfig> selectEffectivePrinterConnections({
  required List<PrinterConnectionConfig> lanConfigs,
  required List<PrinterConnectionConfig> cloudConfigs,
  required Map<String, BambuConnectionMode> selectedModes,
}) {
  final lanBySerial = <String, PrinterConnectionConfig>{
    for (final config in lanConfigs) config.serial: config,
  };
  final cloudBySerial = <String, PrinterConnectionConfig>{
    for (final config in cloudConfigs) config.serial: config,
  };
  final serials = <String>[
    ...lanBySerial.keys,
    ...cloudBySerial.keys.where((serial) => !lanBySerial.containsKey(serial)),
  ];
  final selectedConfigs = <PrinterConnectionConfig>[];
  for (final serial in serials) {
    final lan = lanBySerial[serial];
    final cloud = cloudBySerial[serial];
    final selected = selectedModes[serial];
    if (selected == BambuConnectionMode.cloud && cloud != null) {
      selectedConfigs.add(cloud);
    } else if (selected == BambuConnectionMode.lan && lan != null) {
      selectedConfigs.add(lan);
    } else {
      selectedConfigs.add(lan ?? cloud!);
    }
  }
  return selectedConfigs;
}

/// 有效打印机连接列表：手动添加的 LAN 配置 + **所有账号**的云端设备。
///
/// 同一序列号同时存在两种配置时，只暴露用户明确选择的那一种。旧版本没有
/// 模式偏好时保留 LAN 作为兼容默认；用户点击云端或 LAN 入口后会立即固定模式。
///
/// 多账号聚合：不再只显示活跃账号的设备，而是所有已登录账号的设备都显示。
/// 切换账号不再过滤打印机列表，只影响切片配置和 BS 登录态。
final mergedPrinterListProvider = Provider<List<PrinterConnectionConfig>>((
  ref,
) {
  final lanList = ref.watch(printerConnectionListProvider);
  final cloudDevices = ref.watch(
    allCloudDevicesProvider.select((state) => state.devices),
  );

  // 云设备转 config
  final cloudConfigs = cloudDevices
      .where((d) => d.devId.isNotEmpty)
      .map(
        (d) => PrinterConnectionConfig.cloud(
          serial: d.devId,
          devProductName: d.devProductName,
          displayName: d.name,
          installedNozzleDiameter: d.nozzleDiameter,
        ),
      )
      .toList();

  return selectEffectivePrinterConnections(
    lanConfigs: lanList,
    cloudConfigs: cloudConfigs,
    selectedModes: ref.watch(printerConnectionModeSelectionProvider),
  );
});

/// 当前选中的打印机序列号（P0-5 修复：持久化到 SharedPreferences，重启后恢复选中）。
///
/// 旧实现为内存态 StateProvider，应用重启后丢失选中打印机，
/// 用户需重新手动点选，体验割裂。现改为 StateNotifier 在构造时加载、
/// 在 set() 时写盘。
class ActivePrinterSerialNotifier extends StateNotifier<String?> {
  ActivePrinterSerialNotifier() : super(null) {
    _load();
  }

  static const _key = 'active_printer_serial';
  Future<void> _mutationQueue = Future<void>.value();
  int _stateGeneration = 0;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // A user selection made before SharedPreferences finished loading wins
      // over the restored value.
      if (mounted && _stateGeneration == 0) state = prefs.getString(_key);
    } catch (error) {
      debugPrint('[ActivePrinterSerial] 读取活跃打印机失败: $error');
    }
  }

  /// 设置活跃打印机序列号。传 null 清除选中。
  Future<void> set(String? serial) {
    final generation = ++_stateGeneration;
    return _enqueueMutation(() => _setInternal(serial, generation));
  }

  Future<void> _enqueueMutation(Future<void> Function() mutation) {
    final result = _mutationQueue.then((_) => mutation());
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  Future<void> _setInternal(String? serial, int generation) async {
    if (!mounted) return;
    final previousState = state;
    state = serial;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = serial == null
          ? await prefs.remove(_key)
          : await prefs.setString(_key, serial);
      if (!saved) throw StateError('无法保存活跃打印机');
    } catch (_) {
      if (mounted && generation == _stateGeneration && state == serial) {
        state = previousState;
      }
      rethrow;
    }
  }
}

final activePrinterSerialProvider =
    StateNotifierProvider<ActivePrinterSerialNotifier, String?>((ref) {
      return ActivePrinterSerialNotifier();
    });

/// 当前选中的打印机连接配置
///
/// 聚合设备列表在启动和账号刷新期间可能短暂尚未就绪。此处只解析配置，
/// 不因一次暂时缺失主动清空持久化 serial，避免工作台卡片闪烁和连接抖动。
/// 账号或设备的明确删除流程负责清理 active serial。
final activePrinterConfigProvider = Provider<PrinterConnectionConfig?>((ref) {
  final serial = ref.watch(activePrinterSerialProvider);
  if (serial == null) return null;
  // 用合并列表：LAN + 云端设备
  final list = ref.watch(mergedPrinterListProvider);
  for (final c in list) {
    if (c.serial == serial) return c;
  }
  return null;
});

/// 只有真正影响 MQTT 端点或认证的信息变化才需要重建连接。
/// 设备名称、机型展示、喷嘴信息和固件事实刷新不得触发重连。
bool printerConnectionEndpointChanged(
  PrinterConnectionConfig? previous,
  PrinterConnectionConfig next,
) {
  if (previous == null) return true;
  return previous.mode != next.mode ||
      previous.host != next.host ||
      previous.port != next.port ||
      previous.accessCode != next.accessCode;
}

/// 活跃打印机的综合状态（连接状态 + 实时状态 + 错误信息）。
/// 注意：类名故意不叫 PrinterConnectionState，避免和 printer_connector.dart 里的枚举重名。
class ActivePrinterState {
  final PrinterConnectionState connectionState;
  final BambuPrinterStatus? status;
  final String? errorMessage;

  const ActivePrinterState({
    this.connectionState = PrinterConnectionState.disconnected,
    this.status,
    this.errorMessage,
  });

  bool get isConnected => connectionState == PrinterConnectionState.connected;

  /// L1 修复：增加 clearError 参数，允许显式清除 errorMessage
  ActivePrinterState copyWith({
    PrinterConnectionState? connectionState,
    BambuPrinterStatus? status,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ActivePrinterState(
      connectionState: connectionState ?? this.connectionState,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// 这个 StateNotifier 持有一个 BambuPrinterConnector，
/// 监听 activePrinterConfig 变化时自动重连。
///
/// 连接模式由 [printerConnectionModeSelectionProvider] 明确决定；断线重连只在
/// 当前模式内进行，不跨模式自动切换。
class ActivePrinterConnectionNotifier
    extends StateNotifier<ActivePrinterState> {
  final Ref ref;
  late final ConsumableTwinService _twinService;
  BambuPrinterConnector? _connector;
  StreamSubscription? _statusSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _connectionStateSub;

  /// 当前连接配置（用于掉线时判断是否可切换 LAN）
  PrinterConnectionConfig? _currentConfig;

  /// 上次同步到数据库的 AMS 槽位（用于去重，避免每次 MQTT 推送都写库）
  List<AmsTray>? _lastAmsTrays;

  /// Last authoritative external-feed count reported by this printer.
  int? _lastExternalInputCount;

  /// 耗材插入告警防打扰：key = "serial_slotIndex"，value = 上次告警时间。
  /// 同槽位 30 秒内只提示一次，防止用户插拔测试时频繁打扰。
  final Map<String, DateTime> _lastInsertAlert = {};

  /// 上次的 trayNow 值（用于检测换料事件，null 表示尚未建立基线）
  String? _lastTrayNow;

  /// P1-19 修复：缓存当前 serial 对应的 printerId，避免每次 MQTT 推送都查库。
  /// 在首次 status 推送时计算，disconnect 时清空。
  /// 若 cached lookup 返回 null（数据库中无对应记录），下次仍尝试查询。
  int? _cachedPrinterId;

  /// G-code ams_mapping 缓存（key = gcodePath，value = amsMapping 列表或 null）。
  /// 避免每次换料事件重复解析同一 G-code 文件。
  /// 单进程内有效，应用重启后自动重建。
  final Map<String, List<int>?> _gcodeAmsMappingCache = {};

  /// AMS/料盘指纹检测器。检测器按物理 globalSlot 工作，支持多 AMS。
  final SpoolChangeDetector _spoolChangeDetector = SpoolChangeDetector();

  /// C1 修复：可取消的断连确认定时器，替代 Future.delayed
  Timer? _disconnectConfirmTimer;

  /// C1 修复：标识用户是否主动断开（主动断开时不应覆盖状态）
  bool _isExplicitDisconnect = false;

  /// Monotonically increases for every requested connection transition. A
  /// connector can finish connecting after it has been replaced, so every
  /// callback must prove that both its generation and instance are current
  /// before it is allowed to mutate state.
  int _connectionGeneration = 0;

  /// 是否曾经成功连接过（用于区分"启动失败"和"运行中断开"，避免离线告警误报）
  bool _wasConnected = false;

  DateTime? _connectionStartedAt;
  bool _compatibilitySuccessRecorded = false;
  bool _compatibilityFailureRecorded = false;
  // 保留旧遥测字段兼容服务端 schema；严格模式隔离后始终为 false。
  static const bool _fallbackUsed = false;

  ActivePrinterConnectionNotifier(this.ref)
    : super(const ActivePrinterState()) {
    final db = ref.read(databaseProvider);
    _twinService = ConsumableTwinService(db);
    ref.listen<PrinterConnectionConfig?>(activePrinterConfigProvider, (
      previous,
      next,
    ) {
      // Farm mode owns its independent fleet connections. Keeping the
      // personal connector alive here duplicates the same cloud MQTT stream
      // and makes unrelated farm pages rebuild under telemetry load.
      if (ref.read(studioModeEnabledProvider)) {
        if (_connector != null) unawaited(disconnect());
        return;
      }
      if (next == null) {
        unawaited(disconnect());
      } else if (previous?.serial != next.serial ||
          printerConnectionEndpointChanged(previous, next)) {
        unawaited(connect(next));
      }
    });
    ref.listen<bool>(studioModeEnabledProvider, (previous, enabled) {
      if (enabled) {
        unawaited(disconnect());
        return;
      }
      if (previous != true) return;
      final config = ref.read(activePrinterConfigProvider);
      if (config != null) unawaited(connect(config));
    });
  }

  BambuPrinterConnector? get connector => _connector;

  Future<void> connect(PrinterConnectionConfig config) async {
    final generation = ++_connectionGeneration;
    await _disconnectInternal();
    if (!mounted || generation != _connectionGeneration) return;

    _connectionStartedAt = DateTime.now();
    _compatibilitySuccessRecorded = false;
    _compatibilityFailureRecorded = false;
    // C1 修复：连接前重置主动断开标志，并取消遗留的断连确认定时器
    _isExplicitDisconnect = false;
    _disconnectConfirmTimer?.cancel();
    _disconnectConfirmTimer = null;
    _wasConnected = false;
    _currentConfig = config;
    state = const ActivePrinterState(
      connectionState: PrinterConnectionState.connecting,
    );
    // Cloud 模式必须注入这台设备所属账号的 session；不能使用当前 active
    // account，否则切换账号后会把另一账号的 token 发给该设备。
    final cloudSession = config.mode == BambuConnectionMode.cloud
        ? cloudSessionForPrinterSerial(
            serial: config.serial,
            ownerMap: ref.read(printerOwnerMapProvider),
            accountState: ref.read(bambuAccountManagerProvider),
          )
        : null;
    final connector = BambuPrinterConnector(config, cloudSession: cloudSession);
    if (!mounted || generation != _connectionGeneration) {
      await connector.dispose();
      return;
    }
    _connector = connector;
    // 连接状态变化（含 MQTT 断开）→ 更新 UI 状态
    // 关键：MQTT 断开时通过此流通知 UI，避免任务卡在 printing
    _connectionStateSub = connector.connectionStateStream.listen((cs) {
      if (!_isCurrentConnector(connector, generation)) return;
      if (cs == PrinterConnectionState.connected) {
        // MQTT 连接已建立（订阅+pushall 已发送），即使还没收到 status 也要更新 UI
        // 避免 pushall 响应慢时 UI 一直卡在"正在连接..."
        // H1 修复：连接成功时清除旧的 errorMessage，避免重连后残留错误
        _wasConnected = true;
        state = state.copyWith(
          connectionState: PrinterConnectionState.connected,
          clearError: true,
        );
      } else if (cs == PrinterConnectionState.disconnected) {
        _onDisconnected(connector, generation);
      } else if (cs == PrinterConnectionState.reconnecting) {
        // P1-2: 连接器正在重连，取消断连确认定时器让当前模式先尝试
        _disconnectConfirmTimer?.cancel();
        _disconnectConfirmTimer = null;
        state = state.copyWith(
          connectionState: PrinterConnectionState.reconnecting,
          errorMessage: '正在重连打印机...',
        );
      } else if (cs == PrinterConnectionState.error) {
        // P1-2: 连接器重连耗尽或初始连接失败
        _disconnectConfirmTimer?.cancel();
        _disconnectConfirmTimer = null;
        state = state.copyWith(connectionState: PrinterConnectionState.error);
        if (_wasConnected) {
          _notifyPrinterOffline();
        }
      }
    });
    _statusSub = connector.statusStream.listen((status) {
      if (!_isCurrentConnector(connector, generation)) return;
      state = ActivePrinterState(
        connectionState: PrinterConnectionState.connected,
        status: status,
      );
      _recordCompatibilitySuccess(status);
      _recordSpoolChanges(status);
      _maybeSyncExternalFeeds(status);
      // AMS 自动同步到数据库
      _maybeSyncAms(status);
      // AMS 换料事件检测（trayNow 变化时记录）
      _maybeRecordAmsChange(status);
      // 结构化故障进入知识库与生命周期账本
      _maybeRecordFaults(status);
    });
    _errorSub = connector.errorStream.listen((error) {
      if (!_isCurrentConnector(connector, generation)) return;
      state = state.copyWith(
        connectionState: PrinterConnectionState.error,
        errorMessage: error,
      );
      _recordCompatibilityFailure(error);
    });
    final ok = await connector.connect();
    if (!_isCurrentConnector(connector, generation)) {
      // A newer selection replaced this connector while its handshake was in
      // flight. Do not let the stale connection keep sockets or timers alive.
      await connector.disconnect();
      await connector.dispose();
      return;
    }
    if (!ok) {
      _recordCompatibilityFailure(state.errorMessage ?? 'connect_failed');
    }
  }

  /// 断连处理：延迟确认，避免重连过程中的瞬时断线覆盖 UI 状态。
  /// C1 修复：用可取消的 Timer 替代 Future.delayed，
  /// 主动 disconnect() 时取消定时器，避免覆盖状态。
  void _onDisconnected(BambuPrinterConnector connector, int generation) {
    if (!_isCurrentConnector(connector, generation)) return;
    // C1 修复：用户主动断开时，不进入断连确认流程
    if (_isExplicitDisconnect) return;

    // H3 修复：autoReconnect 瞬断时延迟 5 秒确认，若已重连则不覆盖状态
    // C1 修复：用可取消的 Timer 替代 Future.delayed
    _disconnectConfirmTimer?.cancel();
    _disconnectConfirmTimer = Timer(
      const Duration(seconds: 5),
      () => _confirmDisconnect(connector, generation),
    );
  }

  /// C1 修复：断连确认回调，5 秒后若仍未重连则更新状态。
  void _confirmDisconnect(BambuPrinterConnector connector, int generation) {
    if (!_isCurrentConnector(connector, generation)) return;
    // 等待期间若用户主动断开，则不继续
    if (_isExplicitDisconnect) return;
    // 如果 5 秒内已重连成功（状态变为 connected），不覆盖状态
    if (state.connectionState == PrinterConnectionState.connected) return;

    // 确认是真正的断开，更新 UI
    state = const ActivePrinterState(
      connectionState: PrinterConnectionState.disconnected,
      status: null,
      errorMessage: '打印机连接已断开',
    );

    // 离线告警：仅当之前成功连接过时告警，避免启动失败误报
    if (_wasConnected) {
      _notifyPrinterOffline();
    }
  }

  /// 打印机离线告警（Toast 通知）。
  /// 告警失败不影响主流程（try-catch 保护）。
  void _notifyPrinterOffline() {
    try {
      final config = _currentConfig;
      final printerName = config?.displayLabel ?? config?.serial ?? '打印机';
      ref
          .read(notificationServiceProvider)
          .alert(
            type: AlertType.printerOffline,
            title: '打印机离线',
            body: '$printerName 已断开连接',
          );
    } catch (_) {
      // 告警失败不影响主流程
    }
  }

  /// 将整盘换料识别结果放入全局确认队列。
  ///
  /// 这和 trayNow 换色事件是两条不同链路：trayNow 只表示打印工具切换，
  /// 而这里比较每个物理槽位的料盘身份，覆盖普通待机换卷、多个 AMS 快速换卷
  /// 以及 RFID/第三方料盘的混合场景。
  void _recordSpoolChanges(BambuPrinterStatus status) {
    final config = _currentConfig;
    if (config == null) return;
    final changes = _spoolChangeDetector.update(
      printerSerial: config.serial,
      printerLabel: config.displayLabel,
      trays: status.amsTrays,
      units: status.amsUnits,
      externalTrays: status.externalTrays,
      extruderFilamentPresent: status.extruderFilamentPresent,
      hwSwitchState: status.hwSwitchState,
      printStage: status.mcPrintStage,
      trayNow: status.trayNow,
      farmMode: ref.read(studioModeEnabledProvider),
    );
    for (final change in changes) {
      final previousUuid = change.previous?.trayUuid.trim() ?? '';
      final currentUuid = change.current?.trayUuid.trim() ?? '';
      if (previousUuid.isNotEmpty &&
          (change.isRemoval || currentUuid != previousUuid)) {
        _maintenanceRfidFrozen.remove(previousUuid);
      }
    }
    if (changes.isNotEmpty) {
      final accountScope = ref.read(personalInventoryAccountScopeProvider);
      ref
          .read(spoolChangeQueueProvider.notifier)
          .observeAll(
            changes,
            personalOwnerAccount: accountScope.enforce
                ? accountScope.ownerAccount
                : null,
          );
    }
  }

  /// 无 AMS/无 RFID 设备没有可自动读取的料盘身份，提供给打印机通道页的
  /// “我刚换了料”按钮调用，仍走同一套库存选择和绑定流程。
  void requestManualSpoolChange({required int channelIndex}) {
    final config = _currentConfig;
    if (config == null) return;
    final accountScope = ref.read(personalInventoryAccountScopeProvider);
    ref
        .read(spoolChangeQueueProvider.notifier)
        .enqueue(
          SpoolChangeObservation.manualEvent(
            printerSerial: config.serial,
            printerLabel: config.displayLabel,
            channelIndex: channelIndex,
            farmMode: ref.read(studioModeEnabledProvider),
          ),
          personalOwnerAccount: accountScope.enforce
              ? accountScope.ownerAccount
              : null,
        );
  }

  bool _isCurrentConnector(BambuPrinterConnector connector, int generation) {
    return mounted &&
        generation == _connectionGeneration &&
        identical(_connector, connector);
  }

  /// Tear down the currently owned connector without invalidating a caller's
  /// generation. The caller increments [_connectionGeneration] when the
  /// transition itself is a user request, then applies the final UI state only
  /// if no newer request superseded it.
  Future<void> _disconnectInternal() async {
    // C1 修复：标记主动断开，并取消可能挂起的断连确认定时器
    _isExplicitDisconnect = true;
    _disconnectConfirmTimer?.cancel();
    _disconnectConfirmTimer = null;
    _wasConnected = false;
    await _statusSub?.cancel();
    await _errorSub?.cancel();
    await _connectionStateSub?.cancel();
    _statusSub = null;
    _errorSub = null;
    _connectionStateSub = null;
    _lastAmsTrays = null;
    _lastExternalInputCount = null;
    _lastTrayNow = null;
    _spoolChangeDetector.reset();
    _lastInsertAlert.clear();
    _lastRfidSync.clear();
    _twinService.clearCache();
    // P1-19 修复：清空 printerId 缓存，下次连接时重新查询
    _cachedPrinterId = null;
    // 清空 G-code ams_mapping 缓存（断开连接后旧任务不再相关）
    _gcodeAmsMappingCache.clear();
    final connector = _connector;
    _connector = null;
    await connector?.disconnect();
    await connector?.dispose();
  }

  Future<void> disconnect() async {
    final generation = ++_connectionGeneration;
    await _disconnectInternal();
    if (!mounted || generation != _connectionGeneration) return;
    _currentConfig = null;
    state = const ActivePrinterState();
  }

  void _recordCompatibilitySuccess(BambuPrinterStatus status) {
    if (_compatibilitySuccessRecorded) return;
    _compatibilitySuccessRecorded = true;
    final config = _currentConfig;
    final model = config?.devProductName?.trim();
    ProductIssueCollector.recordDetached(
      category: ProductIssueCategory.deviceCompatibility,
      outcome: 'connected',
      durationMs: _connectionStartedAt == null
          ? null
          : DateTime.now().difference(_connectionStartedAt!).inMilliseconds,
      details: {
        'connectionMode': config?.mode.name ?? 'unknown',
        'printerModel': model == null || model.isEmpty ? 'unknown' : model,
        'firmwareVersion': status.fwVersion ?? 'unknown',
        'studioVersion': BambuClientVersion.bambuStudio,
        'amsSummary': status.amsSummary ?? 'none',
        'fallbackUsed': _fallbackUsed,
      },
    );
  }

  void _recordCompatibilityFailure(String error) {
    if (_compatibilityFailureRecorded) return;
    _compatibilityFailureRecorded = true;
    final config = _currentConfig;
    final model = config?.devProductName?.trim();
    ProductIssueCollector.recordDetached(
      category: ProductIssueCategory.deviceCompatibility,
      outcome: 'connection_failed',
      level: ErrorLevel.warning,
      durationMs: _connectionStartedAt == null
          ? null
          : DateTime.now().difference(_connectionStartedAt!).inMilliseconds,
      details: {
        'connectionMode': config?.mode.name ?? 'unknown',
        'printerModel': model == null || model.isEmpty ? 'unknown' : model,
        'studioVersion': BambuClientVersion.bambuStudio,
        'errorCategory': ProductIssueCollector.classifyConnectionError(error),
        'fallbackUsed': _fallbackUsed,
      },
    );
  }

  /// AMS 槽位自动同步到数据库。
  ///
  /// 做两件事：
  /// 1. 通道/绑定同步：trayType+trayColor+hasFilament 变化时触发 syncChannelsFromAms
  ///    （含拓竹原厂料自动绑定逻辑）
  /// 2. RFID 残量同步：每次 MQTT 推送都检查拓竹原厂料的 remain 变化，
  ///    普通用户同步到耗材余量；农场同步到具体打印机槽位中的独立料卷。
  Future<void> _maybeSyncAms(BambuPrinterStatus status) async {
    final trays = status.amsTrays;
    if (trays == null || trays.isEmpty) {
      // `amsUnits == null` 只是普通增量消息没有携带 AMS 字段；显式空列表
      // 才是设备确认当前没有 AMS，必须清掉旧的 AMS 槽位配置。
      if (status.amsUnits == null) return;
      final config = _currentConfig;
      if (config == null) return;
      final printerDao = ref.read(printerDaoProvider);
      final printerId = await _getCachedPrinterId(config.serial, printerDao);
      if (printerId == null) return;
      await printerDao.syncChannelsFromAms(
        printerId,
        const <AmsTray>[],
        amsUnits: status.amsUnits,
        autoBindRfid: false,
        // 普通用户先询问拔料原因；农场继续沿用自动清空流程。
        unbindEmpty: ref.read(studioModeEnabledProvider),
        farmMode: ref.read(studioModeEnabledProvider),
        personalOwnerAccount:
            ref.read(personalInventoryAccountScopeProvider).enforce
            ? ref.read(personalInventoryAccountScopeProvider).ownerAccount
            : null,
      );
      await enqueueUnboundFeedConfiguration(
        queue: ref.read(spoolChangeQueueProvider.notifier),
        printerDao: printerDao,
        printerId: printerId,
        printerSerial: config.serial,
        printerLabel: config.displayLabel,
        status: status,
        farmMode: ref.read(studioModeEnabledProvider),
        personalOwnerAccount: ref
            .read(personalInventoryAccountScopeProvider)
            .ownerAccount,
      );
      _lastAmsTrays = const <AmsTray>[];
      return;
    }

    // 1. 深比较物理槽位和料盘身份（不含 remain）。同型号同颜色的
    // 两卷官方料也会有不同 UUID，必须触发自动换绑。
    bool structuralChanged =
        _lastAmsTrays == null || _lastAmsTrays!.length != trays.length;
    if (!structuralChanged) {
      for (var i = 0; i < trays.length; i++) {
        if (_lastAmsTrays![i].trayType != trays[i].trayType ||
            _lastAmsTrays![i].trayColor != trays[i].trayColor ||
            _lastAmsTrays![i].trayUuid != trays[i].trayUuid ||
            _lastAmsTrays![i].trayInfoIdx != trays[i].trayInfoIdx ||
            _lastAmsTrays![i].trayTag != trays[i].trayTag ||
            _lastAmsTrays![i].amsId != trays[i].amsId ||
            _lastAmsTrays![i].slot != trays[i].slot ||
            _lastAmsTrays![i].hasFilament != trays[i].hasFilament) {
          structuralChanged = true;
          break;
        }
      }
    }

    // 2. AMS 缺料/插入告警（必须在更新 _lastAmsTrays 之前比较）
    if (structuralChanged && _lastAmsTrays != null) {
      _notifyAmsFilamentEmpty(oldTrays: _lastAmsTrays!, newTrays: trays);
      _notifyAmsFilamentInserted(oldTrays: _lastAmsTrays!, newTrays: trays);
    }

    _lastAmsTrays = trays;

    final config = _currentConfig;
    if (config == null) return;

    final printerDao = ref.read(printerDaoProvider);
    final printerId = await _getCachedPrinterId(config.serial, printerDao);
    if (printerId == null) return;

    // 维修暂取的 RFID 卷恢复时，以数据库中已冻结的精确克数为准。
    // 集合会跨后续 MQTT 推送保留，直到该卷再次被物理拔出或被其他卷替换。
    final pausedUuids = await printerDao.getMaintenancePausedTrayUuids(
      printerId,
    );
    _maintenanceRfidFrozen.addAll(pausedUuids);

    // 3. 结构变化 → 同步通道 + 自动绑定拓竹原厂料
    if (structuralChanged) {
      await printerDao.syncChannelsFromAms(
        printerId,
        trays,
        amsUnits: status.amsUnits,
        autoBindRfid: true,
        // 普通用户先询问拔料原因；农场继续沿用自动清空流程。
        unbindEmpty: ref.read(studioModeEnabledProvider),
        farmMode: ref.read(studioModeEnabledProvider),
        personalOwnerAccount:
            ref.read(personalInventoryAccountScopeProvider).enforce
            ? ref.read(personalInventoryAccountScopeProvider).ownerAccount
            : null,
      );
      await enqueueUnboundFeedConfiguration(
        queue: ref.read(spoolChangeQueueProvider.notifier),
        printerDao: printerDao,
        printerId: printerId,
        printerSerial: config.serial,
        printerLabel: config.displayLabel,
        status: status,
        farmMode: ref.read(studioModeEnabledProvider),
        personalOwnerAccount: ref
            .read(personalInventoryAccountScopeProvider)
            .ownerAccount,
      );
    }

    // 数字孪生账本始终记录有效 RFID 观测；远程/本地开关只决定是否自动
    // 采用 RFID 余量，不影响轨迹事实。第三方标签只有在 AMS 上报非空
    // trayUuid 且本地已有同 UUID 耗材时才会被数字孪生接纳。
    final adoptRfid = ref
        .read(killSwitchServiceProvider)
        .isEnabled('rfid_auto_adopt');
    await _twinService.handleAmsTrays(
      printerId: printerId,
      printerSerial: config.serial,
      trays: trays,
      amsHumidity: status.amsHumidity,
      adoptObservedRemain: adoptRfid,
      preserveObservedRemainFor: _maintenanceRfidFrozen,
      personalOwnerAccount:
          ref.read(personalInventoryAccountScopeProvider).enforce
          ? ref.read(personalInventoryAccountScopeProvider).ownerAccount
          : null,
    );

    // 4. RFID 残量同步（每次都执行，不依赖 structuralChanged）
    // 拓竹原厂料的 remain 变化 → 普通库存或农场槽位独立料卷
    // Phase F-5: RFID 自动采用观测值 kill switch 检查
    // 本地开关 AND 远程配置 flag 均开启时才允许同步
    if (adoptRfid) {
      await _syncRfidRemain(
        printerId,
        trays,
        preserveTrayUuids: _maintenanceRfidFrozen,
      );
    }
  }

  Future<void> _maybeSyncExternalFeeds(BambuPrinterStatus status) async {
    final sensorCount =
        status.extruderFilamentPresent?.length ??
        (status.hwSwitchState == null ? 0 : 1);
    final metadataCount = status.externalTrays?.length ?? 0;
    final observedCount = sensorCount > metadataCount
        ? sensorCount
        : metadataCount;
    final count =
        PrinterPresets.findByModel(
          _currentConfig?.devProductName ?? '',
        )?.externalInputCount ??
        observedCount;
    if (count <= 0) return;

    final config = _currentConfig;
    if (config == null) return;
    final printerDao = ref.read(printerDaoProvider);
    final printerId = await _getCachedPrinterId(config.serial, printerDao);
    if (printerId == null) return;
    if (count != _lastExternalInputCount) {
      _lastExternalInputCount = count;
      final hasAms =
          status.amsUnits?.any((unit) => unit.isPresent) == true ||
          status.amsTrays?.any((tray) => tray.amsId >= 0) == true;
      await printerDao.syncExternalFeedChannels(
        printerId,
        externalInputCount: count,
        hasAms: hasAms,
      );
    }
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
        unbindEmpty: ref.read(studioModeEnabledProvider),
      );
    }
    await enqueueUnboundFeedConfiguration(
      queue: ref.read(spoolChangeQueueProvider.notifier),
      printerDao: printerDao,
      printerId: printerId,
      printerSerial: config.serial,
      printerLabel: config.displayLabel,
      status: status,
      farmMode: ref.read(studioModeEnabledProvider),
      personalOwnerAccount: ref
          .read(personalInventoryAccountScopeProvider)
          .ownerAccount,
    );
  }

  Future<void> _maybeRecordFaults(BambuPrinterStatus status) async {
    final config = _currentConfig;
    await ref
        .read(printerFaultMonitorProvider.notifier)
        .observe(
          serial: config?.serial ?? status.serial,
          name: config?.displayLabel ?? '打印机',
          model: config?.devProductName ?? '',
          status: status,
        );
  }

  /// P1-19 修复：获取 printerId（带缓存）。
  /// 首次查询后缓存到 [_cachedPrinterId]，避免每次 MQTT 推送都查库。
  /// disconnect 时清空缓存。
  /// 若缓存为 null（数据库无对应记录），下次仍尝试查询（用户可能刚添加打印机）。
  Future<int?> _getCachedPrinterId(String serial, PrinterDao printerDao) async {
    if (_cachedPrinterId != null) return _cachedPrinterId;
    final id = await printerDao.getPrinterIdBySerial(serial);
    if (id != null) {
      _cachedPrinterId = id;
    }
    return id;
  }

  /// RFID 残量同步：普通用户更新耗材余量；农场更新槽位独立料卷。
  ///
  /// 数字孪生核心：RFID remain 是打印机物理读数（真值），打印扣减是估算值。
  /// 每次 MQTT 推送都检查 remain 变化，用 RFID 值覆盖库存估算值，提升精度。
  ///
  /// 同步有 RFID 且 trayUuid 非空的原厂料；已绑定的第三方 RFID 载体也
  /// 允许同步余量。未知第三方 UUID 不会写入库存。
  /// 节流：同一 trayUuid 30 秒内只同步一次，避免高频推送频繁写库。
  final Map<String, DateTime> _lastRfidSync = {};
  final Set<String> _maintenanceRfidFrozen = {};

  Future<void> _syncRfidRemain(
    int printerId,
    List<AmsTray> trays, {
    Set<String> preserveTrayUuids = const {},
  }) async {
    try {
      final consumableDao = ref.read(consumableDaoProvider);
      final printerDao = ref.read(printerDaoProvider);
      final now = DateTime.now();

      for (final tray in trays) {
        if (!tray.hasFilament) continue;
        if (!tray.isBambuOfficialRfid && !tray.hasAmsRfidIdentity) continue;
        if (preserveTrayUuids.contains(tray.trayUuid)) continue;
        if (tray.remain < 0) continue; // -1 表示无 RFID/未知

        // 节流：同 trayUuid 30 秒内只同步一次
        final lastSync = _lastRfidSync[tray.trayUuid];
        if (lastSync != null && now.difference(lastSync).inSeconds < 30) {
          continue;
        }

        // 查库存里该 trayUuid 对应的耗材
        final accountScope = ref.read(personalInventoryAccountScopeProvider);
        final consumable = accountScope.enforce
            ? await consumableDao.getPersonalByTrayUuid(
                tray.trayUuid,
                ownerAccount: accountScope.ownerAccount,
              )
            : await consumableDao.getByTrayUuid(tray.trayUuid);
        if (consumable == null) continue;

        // 计算 RFID 残量克数
        final rfidGrams = tray.remainingGrams;
        if (rfidGrams < 0) continue;

        if (await consumableDao.isFarmConsumable(consumable.id)) {
          final updated = await printerDao.syncFarmChannelLoadedRemaining(
            printerId: printerId,
            channelIndex: tray.globalSlot,
            remainingGrams: rfidGrams,
            expectedConsumableId: consumable.id,
          );
          if (updated) {
            _lastRfidSync[tray.trayUuid] = now;
          }
          continue;
        }

        // 偏差小于 5g 不写库（避免无意义更新）
        if ((consumable.remainingGrams - rfidGrams).abs() < 5) continue;

        await consumableDao.updateRfidSync(
          consumableId: consumable.id,
          remainingGrams: rfidGrams,
        );
        _lastRfidSync[tray.trayUuid] = now;
      }
    } catch (e, st) {
      ErrorLogger.log(
        e,
        st,
        source: 'rfid_sync',
        level: ErrorLevel.warning,
        context: {'printerId': printerId},
      );
    }
  }

  /// AMS 换料事件检测：监听 [BambuPrinterStatus.trayNow] 变化，
  /// 在真实变化时写入 [AmsChangeEvent] 到数据库。
  ///
  /// 设计要点：
  /// - 首次建立基线（_lastTrayNow == null → null）不记录，仅建立基线
  /// - 仅在 trayNow 真实变化（且能解析为 int 工具号）时记录一次
  /// - 关联当前活跃任务（[PrintTaskDao.getActive] 取首条）
  /// - 关联通道耗材（[PrinterDao.getConsumableIdByChannel] 查 PrinterChannels）
  /// - 记录换料前剩余克数（[ConsumableDao.getById] 查 consumables.remainingGrams）
  /// - try-catch 保护，记录失败不影响打印状态更新主流程
  ///
  /// **AMS 通道映射**（P0 修复）：
  /// - trayNow 是 G-code 工具号（"0"=T0, "1"=T1...），不是物理通道索引
  /// - 单 AMS 场景：toolIndex == channelIndex（T0→槽0, T1→槽1...），两者恰好相等
  /// - 多 AMS 场景：toolIndex ≠ channelIndex，需要通过 ams_mapping 反查
  ///   例如 ams_mapping=[0,4,1,5] 表示 T0→AMS0.slot0, T1→AMS1.slot0...
  /// - 拓竹 MQTT 协议**不回传 ams_mapping**，只能从 G-code 文件解析
  /// - 当前兜底策略：假设 amsTrays 列表按 globalSlot 顺序排列，
  ///   toolIndex 直接作为 amsTrays 列表索引取对应槽位的 globalSlot
  ///   （即假设 ams_mapping=[0,1,2,3,4,5...]，覆盖 90% 单 AMS 场景）
  ///
  /// **虚拟槽位 254/255**（外挂供料）：
  /// - 255 = 单外挂或右侧外挂，254 = 左侧外挂
  /// - 两者都是可绑定库存的真实物理料位，不能再降级为 -1
  Future<void> _maybeRecordAmsChange(BambuPrinterStatus newStatus) async {
    final newTrayNow = newStatus.trayNow;
    if (newTrayNow == null || newTrayNow == _lastTrayNow) return;

    final oldTrayNow = _lastTrayNow;
    // 先更新基线，避免后续推送重复记录
    _lastTrayNow = newTrayNow;
    // 首次建立基线，不记录事件
    if (oldTrayNow == null) return;

    // 解析旧 trayNow 为 toolIndex（trayNow 是字符串如 "0"/"1"，对应 G-code T0/T1）
    final oldToolIndex = int.tryParse(oldTrayNow);
    if (oldToolIndex == null) return;

    try {
      final config = _currentConfig;
      if (config == null) return;

      // 1. 查找打印机 id
      final printerDao = ref.read(printerDaoProvider);
      final printerId = await printerDao.getPrinterIdBySerial(config.serial);
      if (printerId == null) return;

      // 2. 查找当前活跃任务（同时只应有一个，取首条）
      final printTaskDao = ref.read(printTaskDaoProvider);
      final activeTasks = await printTaskDao.getActive();
      final taskId = activeTasks.isEmpty ? null : activeTasks.first.id;

      // 2.5 解析当前任务的 G-code ams_mapping（多 AMS 非顺序映射修复）
      //     - 单 AMS 场景：ams_mapping 通常是 [0,1,2,3]，与顺序映射结果一致
      //     - 多 AMS 非顺序场景：ams_mapping = [1,3,0,2,5,4,7,6] 等，必须用此映射
      //     - 解析失败或无映射：返回 null，回退到顺序映射兜底
      final gcodePath = activeTasks.isEmpty
          ? null
          : activeTasks.first.gcodePath;
      final amsMapping = await _resolveAmsMapping(gcodePath);

      // 3. 解析 channelIndex（P0 修复：toolIndex ↔ channelIndex 映射）
      //    - 虚拟槽位 254/255：直接使用保留的外挂物理通道
      //    - 有 amsMapping：优先用 amsMapping[toolIndex] 精确反查
      //    - 无 amsMapping：回退到 amsTrays 顺序映射兜底
      final int channelIndex;
      int? consumableId;
      if (oldToolIndex == 254 || oldToolIndex == 255) {
        channelIndex = oldToolIndex;
        consumableId = await printerDao.getConsumableIdByChannel(
          printerId,
          channelIndex,
        );
      } else {
        channelIndex = _resolveChannelIndex(
          oldToolIndex,
          newStatus.amsTrays,
          amsMapping: amsMapping,
        );
        // 4. 查找旧通道绑定的耗材（channelIndex 对应 PrinterChannels.channelIndex）
        consumableId = channelIndex >= 0
            ? await printerDao.getConsumableIdByChannel(printerId, channelIndex)
            : null;
      }

      if (consumableId != null) {
        final accountScope = ref.read(personalInventoryAccountScopeProvider);
        if (accountScope.enforce &&
            !await ref
                .read(consumableDaoProvider)
                .ensurePersonalConsumableAccess(
                  consumableId,
                  ownerAccount: accountScope.ownerAccount,
                )) {
          consumableId = null;
        }
      }

      // 5. 查询换料前剩余克数（若该通道绑定了耗材）
      double? previousRemainingGrams;
      if (consumableId != null) {
        final consumable = await ref
            .read(consumableDaoProvider)
            .getById(consumableId);
        if (consumable != null) {
          previousRemainingGrams = consumable.remainingGrams;
        }
      }

      // 6. 写入换料事件
      final event = AmsChangeEvent(
        printerId: printerId,
        taskId: taskId,
        channelIndex: channelIndex,
        toolIndex: oldToolIndex,
        consumableId: consumableId,
        eventType: AmsChangeEventType.switch_,
        previousRemainingGrams: previousRemainingGrams,
        consumedGramsAtEvent: 0,
        occurredAt: DateTime.now(),
      );
      await ref.read(amsChangeEventDaoProvider).create(event);
    } catch (e, st) {
      ErrorLogger.log(
        e,
        st,
        source: 'ams_change_event',
        level: ErrorLevel.warning,
        context: {
          'printerSerial': _currentConfig?.serial ?? '',
          'oldTray': oldTrayNow,
          'newTray': newTrayNow,
        },
      );
    }
  }

  /// 解析 G-code 文件获取 ams_mapping 列表（带缓存）。
  ///
  /// **返回值语义**：
  /// - null：无 G-code 路径、文件不存在、解析失败，或 G-code 未含 ams_mapping
  /// - 空列表 []：切片未指定 AMS 映射（单色或老版本切片软件）
  /// - 非空列表 [1,3,0,2,...]：T→全局槽位映射
  ///
  /// **缓存策略**：按 gcodePath 缓存解析结果，避免重复解析同一文件。
  /// 缓存 value 用 List<int>? （可为 null），命中即返回。
  Future<List<int>?> _resolveAmsMapping(String? gcodePath) async {
    if (gcodePath == null || gcodePath.isEmpty) return null;

    // 命中缓存
    if (_gcodeAmsMappingCache.containsKey(gcodePath)) {
      return _gcodeAmsMappingCache[gcodePath];
    }

    try {
      // P1-3: 在 Isolate 中解析（避免大文件阻塞 UI）
      // 不启用 layer mapping，仅解析头部信息（含 ams_mapping）
      final sliceResult = await SliceIsolateRunner.parseGcode(gcodePath);
      final mapping = sliceResult?.amsMapping;
      _gcodeAmsMappingCache[gcodePath] = mapping;
      if (mapping != null && mapping.isNotEmpty) {
        debugPrint('[AMS] gcode ams_mapping 已加载: $gcodePath → $mapping');
      }
      return mapping;
    } catch (e) {
      debugPrint('[AMS] gcode ams_mapping 解析失败: $gcodePath, $e');
      _gcodeAmsMappingCache[gcodePath] = null;
      return null;
    }
  }

  /// 解析 G-code 工具号 → AMS 物理通道索引（globalSlot = amsId*4+slot）。
  ///
  /// **映射规则**：
  /// - toolIndex 是 G-code T0/T1/T2... 工具号
  /// - channelIndex 是物理槽位全局索引（amsId*4+slot）
  /// - 单 AMS 场景：两者恰好相等（T0→槽0, T1→槽1, T2→槽2, T3→槽3）
  /// - 多 AMS 非顺序场景：必须用 G-code `; ams_mapping = [...]` 反查
  ///
  /// **优先级**：
  /// 1. [amsMapping] 非空且 toolIndex 在范围内：直接取 amsMapping[toolIndex]
  /// 2. [amsTrays] 非空且 toolIndex 在范围内：用 amsTrays[toolIndex].globalSlot
  ///    （假设 amsTrays 列表顺序即 toolIndex 顺序，覆盖 90% 单 AMS 场景）
  /// 3. 兜底：返回 toolIndex 自身
  ///
  /// 返回 -1 表示外部 spool / TPU 直通等无 AMS 槽位。
  int _resolveChannelIndex(
    int toolIndex,
    List<AmsTray>? amsTrays, {
    List<int>? amsMapping,
  }) {
    // 优先级 1：用 G-code ams_mapping 精确反查（覆盖多 AMS 非顺序场景）
    if (amsMapping != null && amsMapping.isNotEmpty) {
      if (toolIndex >= 0 && toolIndex < amsMapping.length) {
        final mapped = amsMapping[toolIndex];
        // 负数表示外部 spool / TPU 直通等无 AMS 槽位
        if (mapped >= 0) return mapped;
        return -1;
      }
      // toolIndex 超出 ams_mapping 范围，继续走兜底
    }

    // 优先级 2：用 amsTrays 顺序映射（覆盖单 AMS 场景）
    if (amsTrays != null && amsTrays.isNotEmpty) {
      if (toolIndex >= 0 && toolIndex < amsTrays.length) {
        return amsTrays[toolIndex].globalSlot;
      }
    }

    // P1-6 修复：兜底返回 -1 让调用方跳过耗材查询，
    // 而非返回 toolIndex 自身（在 AMS 槽位数 ≠ 4 的场景下会错误匹配）
    // 单 AMS 4 槽场景下 toolIndex==channelIndex 巧合正确，但不可依赖
    debugPrint('[ChannelIndex] AMS 映射降级: toolIndex=$toolIndex 无匹配, 返回 -1');
    return -1;
  }

  /// AMS 料卷耗尽告警（Toast 通知）。
  /// 比较新旧 amsTrays，对 hasFilament 从 true 变为 false 的槽位逐个告警。
  /// 告警失败不影响主流程（try-catch 保护）。
  void _notifyAmsFilamentEmpty({
    required List<AmsTray> oldTrays,
    required List<AmsTray> newTrays,
  }) {
    try {
      final config = _currentConfig;
      final printerName = config?.displayLabel ?? config?.serial ?? '打印机';
      final notif = ref.read(notificationServiceProvider);
      final minLen = oldTrays.length < newTrays.length
          ? oldTrays.length
          : newTrays.length;
      for (var i = 0; i < minLen; i++) {
        if (oldTrays[i].hasFilament && !newTrays[i].hasFilament) {
          notif.alert(
            type: AlertType.amsFilamentEmpty,
            title: '料卷耗尽',
            body:
                '$printerName AMS${oldTrays[i].amsId + 1} 槽位 ${oldTrays[i].slot + 1} 料卷已用完',
          );
        }
      }
    } catch (_) {
      // 告警失败不影响主流程
    }
  }

  /// AMS 耗材插入告警：检测 hasFilament 从 false → true 的槽位。
  ///
  /// 场景：用户往空槽插入新料卷，或拔出旧料后换上新料。
  /// 弹通知提示用户前往打印机页面绑定库存耗材。
  ///
  /// 防打扰：同槽位 30 秒内只提示一次（[_lastInsertAlert]），
  /// 防止用户插拔测试或 AMS 信号抖动时频繁打扰。
  void _notifyAmsFilamentInserted({
    required List<AmsTray> oldTrays,
    required List<AmsTray> newTrays,
  }) {
    try {
      final config = _currentConfig;
      final printerName = config?.displayLabel ?? config?.serial ?? '打印机';
      final serial = config?.serial ?? '';
      final notif = ref.read(notificationServiceProvider);
      final minLen = oldTrays.length < newTrays.length
          ? oldTrays.length
          : newTrays.length;
      for (var i = 0; i < minLen; i++) {
        // 检测 false → true（耗材插入/更换新料）
        if (!oldTrays[i].hasFilament && newTrays[i].hasFilament) {
          // 拓竹原厂料（有 RFID）会被自动绑定，不弹通知
          if (newTrays[i].isBambuOfficialRfid) continue;
          // 防打扰：同槽位 30 秒内只提示一次
          final key = '${serial}_$i';
          final lastTime = _lastInsertAlert[key];
          if (lastTime != null &&
              DateTime.now().difference(lastTime).inSeconds < 30) {
            continue;
          }
          _lastInsertAlert[key] = DateTime.now();

          // 读 RFID 信息丰富通知内容
          final tray = newTrays[i];
          String rfidInfo;
          if (tray.isBambuOfficialRfid) {
            // 拓竹原厂料：有 RFID，显示厂商+材质+颜色
            final brand = tray.traySubBrands.isNotEmpty
                ? tray.traySubBrands
                : '未知品牌';
            rfidInfo = '$brand ${tray.trayType}';
          } else {
            // 第三方料或无 RFID
            rfidInfo = tray.trayType.isNotEmpty
                ? '${tray.trayType}（无 RFID）'
                : '未知耗材（无 RFID）';
          }

          notif.alert(
            type: AlertType.amsFilamentInserted,
            title: '检测到新耗材',
            body:
                '$printerName AMS${newTrays[i].amsId + 1} 槽位 '
                '${newTrays[i].slot + 1} 已装入：$rfidInfo，'
                '请前往打印机页面绑定库存耗材',
          );
        }
      }
    } catch (_) {
      // 告警失败不影响主流程
    }
  }

  Future<bool> pause() async => _connector?.pause() ?? false;
  Future<bool> resume() async => _connector?.resume() ?? false;
  Future<bool> stop() async => _connector?.stop() ?? false;
  Future<bool> setSpeed(int speed) async =>
      _connector?.setSpeed(speed) ?? false;
  Future<bool> sendPrintTask(String path, {List<int>? amsMapping}) async =>
      _connector?.sendPrintTask(path, amsMapping: amsMapping) ?? false;
  Future<bool> sendFirmwareUpgrade() async =>
      _connector?.sendFirmwareUpgrade() ?? false;
  Future<bool> sendAmsFirmwareUpgrade(int amsId) async =>
      _connector?.sendAmsFirmwareUpgrade(amsId) ?? false;

  @override
  void dispose() {
    _connectionGeneration++;
    // C1 修复：取消可能挂起的断连确认定时器，防止 dispose 后回调写入 state
    _disconnectConfirmTimer?.cancel();
    _disconnectConfirmTimer = null;
    // H-1 修复：同步取消 stream 订阅，防止 dispose 后异步回调写入 state
    _statusSub?.cancel();
    _errorSub?.cancel();
    _connectionStateSub?.cancel();
    _statusSub = null;
    _errorSub = null;
    _connectionStateSub = null;
    final connector = _connector;
    _connector = null;
    connector?.dispose();
    super.dispose();
  }
}

/// 当前活跃打印机的连接状态和实时状态
final activePrinterConnectionProvider =
    StateNotifierProvider<ActivePrinterConnectionNotifier, ActivePrinterState>((
      ref,
    ) {
      return ActivePrinterConnectionNotifier(ref);
    });
