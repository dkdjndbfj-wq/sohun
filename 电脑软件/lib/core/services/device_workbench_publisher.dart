import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/external/community/community_api_client.dart';
import '../../data/external/printer/printer_connector.dart';
import '../../providers/app_auth_provider.dart';
import 'printer_fault_monitor.dart' show printerFaultAccountKey;
import 'printer_fleet_connection_manager.dart';

Map<String, dynamic> deviceStatusForWorkbench(FleetPrinterState device) {
  final status = device.lastStatus;
  return {
    'printerKey': sha256.convert(utf8.encode(device.serial)).toString(),
    'name': device.displayLabel,
    'model': device.reportedModel ?? '',
    'online': device.connectionState == PrinterConnectionState.connected,
    'state': status?.gcodeState?.name ?? 'unknown',
    'taskName': status?.subtaskName,
    'progress': status?.mcPercent,
    'remainingMinutes': status?.mcRemainingTime,
    'nozzleTemperature': status?.nozzleTemper,
    'bedTemperature': status?.bedTemper,
    'observedAt':
        (device.statusUpdatedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
            .toUtc()
            .toIso8601String(),
  };
}

class DeviceSharingState {
  const DeviceSharingState({
    this.owner,
    this.enabled = false,
    this.busy = false,
    this.error,
    this.syncedAt,
  });
  final String? owner, error;
  final bool enabled, busy;
  final DateTime? syncedAt;
}

final deviceWorkbenchPublisherProvider =
    StateNotifierProvider<DeviceWorkbenchPublisher, DeviceSharingState>(
      DeviceWorkbenchPublisher.new,
    );

class DeviceWorkbenchPublisher extends StateNotifier<DeviceSharingState> {
  DeviceWorkbenchPublisher(this.ref) : super(const DeviceSharingState()) {
    ref.listen(
      appAuthProvider,
      (_, next) => unawaited(_load(printerFaultAccountKey(next))),
      fireImmediately: true,
    );
    _timer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(sync()),
    );
  }
  final Ref ref;
  Timer? _timer;
  int _generation = 0;
  bool _initialized = false, _running = false;
  Future<void> _load(String? owner) async {
    if (_initialized && owner == state.owner) return;
    _initialized = true;
    final generation = ++_generation;
    state = DeviceSharingState(owner: owner);
    if (owner == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || generation != _generation) return;
    state = DeviceSharingState(
      owner: owner,
      enabled: prefs.getBool('device_workbench_sharing_$owner') ?? false,
    );
    await sync();
  }

  Future<void> setEnabled(bool enabled) async {
    final owner = state.owner, generation = _generation;
    if (owner == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('device_workbench_sharing_$owner', enabled);
    if (!mounted || generation != _generation) return;
    state = DeviceSharingState(owner: owner, enabled: enabled);
    if (enabled) await sync();
  }

  Future<void> sync() async {
    final owner = state.owner, generation = _generation;
    final api = ref.read(communityApiProvider);
    if (!state.enabled ||
        owner == null ||
        api is! PersonalDeviceApi ||
        _running)
      return;
    _running = true;
    state = DeviceSharingState(
      owner: owner,
      enabled: true,
      busy: true,
      syncedAt: state.syncedAt,
    );
    try {
      final session = await ref
          .read(appAuthProvider.notifier)
          .ensureValidSession();
      if (!mounted || generation != _generation || !state.enabled) return;
      final devices = ref
          .read(fleetPrinterStatesProvider)
          .map(deviceStatusForWorkbench)
          .toList();
      for (var start = 0; start < devices.length; start += 100) {
        if (!mounted || generation != _generation || !state.enabled) return;
        await (api as PersonalDeviceApi).uploadDeviceStatus(
          accessToken: session.accessToken,
          devices: devices.skip(start).take(100).toList(),
        );
      }
      if (mounted && generation == _generation)
        state = DeviceSharingState(
          owner: owner,
          enabled: state.enabled,
          syncedAt: DateTime.now(),
        );
    } catch (_) {
      if (mounted && generation == _generation)
        state = DeviceSharingState(
          owner: owner,
          enabled: state.enabled,
          error: '设备状态尚未同步，请检查网络与配套服务版本',
          syncedAt: state.syncedAt,
        );
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    ++_generation;
    _timer?.cancel();
    super.dispose();
  }
}

class DeviceSharingSettingsTile extends ConsumerWidget {
  const DeviceSharingSettingsTile({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(deviceWorkbenchPublisherProvider);
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('共享设备状态到手机'),
            subtitle: Text(
              state.owner == null
                  ? '登录 sohun 个人账号后，使用 NTAG213 打开设备工作台'
                  : '同步设备名称、任务进度和温度；在手机制作设备标签并记录保养',
            ),
            value: state.enabled,
            onChanged: state.owner == null
                ? null
                : (value) => ref
                      .read(deviceWorkbenchPublisherProvider.notifier)
                      .setEnabled(value),
          ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(state.error!),
            ),
          if (state.enabled)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: state.busy
                    ? null
                    : () => ref
                          .read(deviceWorkbenchPublisherProvider.notifier)
                          .sync(),
                icon: const Icon(Icons.sync),
                label: Text(state.busy ? '正在同步…' : '立即同步设备'),
              ),
            ),
        ],
      ),
    );
  }
}
