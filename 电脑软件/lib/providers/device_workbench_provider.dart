import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/services/printer_fault_monitor.dart'
    show printerFaultAccountKey;
import '../data/database/device_workbench_store.dart';
import '../data/external/community/community_api_client.dart';
import '../data/models/app_auth.dart';
import '../data/models/personal_device.dart';
import '../mobile/device_tag_nfc.dart';
import 'app_auth_provider.dart';
import 'database_provider.dart';

final deviceTagNfcProvider = Provider<DeviceTagNfc>((ref) {
  final nfc = MethodChannelDeviceTagNfc();
  ref.onDispose(nfc.dispose);
  return nfc;
});
final deviceTagOpenRequestProvider = StateProvider<String?>((ref) => null);
final deviceWorkbenchStoreProvider = Provider(
  (ref) => DeviceWorkbenchStore(ref.watch(databaseProvider)),
);

class DeviceWorkbenchState {
  const DeviceWorkbenchState({
    this.owner,
    this.devices = const [],
    this.records = const [],
    this.busy = false,
    this.error,
    this.refreshedAt,
  });
  final String? owner, error;
  final List<PersonalDevice> devices;
  final List<DeviceMaintenanceRecord> records;
  final bool busy;
  final DateTime? refreshedAt;
  DeviceWorkbenchState copyWith({
    List<PersonalDevice>? devices,
    List<DeviceMaintenanceRecord>? records,
    bool? busy,
    String? error,
    DateTime? refreshedAt,
  }) => DeviceWorkbenchState(
    owner: owner,
    devices: devices ?? this.devices,
    records: records ?? this.records,
    busy: busy ?? this.busy,
    error: error,
    refreshedAt: refreshedAt ?? this.refreshedAt,
  );
}

final deviceWorkbenchProvider =
    StateNotifierProvider.autoDispose<
      DeviceWorkbenchController,
      DeviceWorkbenchState
    >(DeviceWorkbenchController.new);

class DeviceWorkbenchController extends StateNotifier<DeviceWorkbenchState>
    with WidgetsBindingObserver {
  DeviceWorkbenchController(this.ref) : super(const DeviceWorkbenchState()) {
    WidgetsBinding.instance.addObserver(this);
    ref.listen(
      appAuthProvider,
      (_, next) => unawaited(_accountChanged(next)),
      fireImmediately: true,
    );
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_foreground) unawaited(refresh());
    });
  }
  final Ref ref;
  Timer? _timer;
  bool _foreground = true, _busy = false, _initialized = false;
  bool _deviceMutationBusy = false;
  int _generation = 0;
  // Account generations do not change when the same owner rotates a tag or
  // archives a device. Invalidate those older reads separately.
  int _deviceRevision = 0;
  DeviceWorkbenchStore get _store => ref.read(deviceWorkbenchStoreProvider);
  bool _current(int generation, String owner) =>
      mounted && _generation == generation && state.owner == owner;
  bool _readCurrent(int generation, String owner, int revision) =>
      _current(generation, owner) &&
      !_deviceMutationBusy &&
      revision == _deviceRevision;

  Future<void> _accountChanged(AppAuthState auth) async {
    if (auth.status == AppAuthStatus.initializing) return;
    final owner = printerFaultAccountKey(auth);
    if (_initialized && owner == state.owner) return;
    _initialized = true;
    final generation = ++_generation;
    state = DeviceWorkbenchState(owner: owner);
    if (owner == null) return;
    await _reloadLocal(owner, generation);
    if (_current(generation, owner)) await refresh();
  }

  Future<void> _reloadLocal(
    String owner,
    int generation, {
    int? deviceRevision,
  }) async {
    final revision = deviceRevision ?? _deviceRevision;
    final devices = await _store.devices(owner);
    final records = await _store.maintenance(owner);
    if (_current(generation, owner) && revision == _deviceRevision)
      state = state.copyWith(devices: devices, records: records);
  }

  Future<
    ({
      PersonalDeviceApi api,
      AppAuthSession session,
      String owner,
      int generation,
    })
  >
  _access() async {
    final owner = state.owner;
    final generation = _generation;
    final api = ref.read(communityApiProvider);
    if (owner == null) throw StateError('请登录 sohun 个人账号');
    if (api is! PersonalDeviceApi) throw StateError('设备工作台服务暂不可用');
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession();
    if (!_current(generation, owner) || session.authRealm != 'personal')
      throw StateError('账号已变化，请重试');
    return (
      api: api as PersonalDeviceApi,
      session: session,
      owner: owner,
      generation: generation,
    );
  }

  Future<bool> refresh() async {
    if (!mounted || _busy || _deviceMutationBusy || state.owner == null)
      return false;
    _busy = true;
    final owner = state.owner!, generation = _generation;
    final revision = _deviceRevision;
    state = state.copyWith(busy: true);
    try {
      final access = await _access();
      final devices = await access.api.fetchDevices(
        accessToken: access.session.accessToken,
      );
      if (!_readCurrent(generation, owner, revision)) return false;
      await _store.replaceDevices(owner, devices);
      var pendingFailed = false;
      for (final record in await _store.maintenance(owner, pendingOnly: true)) {
        if (!_readCurrent(generation, owner, revision)) return false;
        if (!devices.any(
          (d) => d.printerKey == record.printerKey && !d.archived,
        )) {
          pendingFailed = true;
          continue;
        }
        try {
          final saved = await access.api.saveDeviceMaintenance(
            accessToken: access.session.accessToken,
            record: record,
          );
          if (!_readCurrent(generation, owner, revision)) return false;
          await _store.acknowledge(owner, saved);
        } catch (_) {
          pendingFailed = true;
        }
      }
      var cursor = await _store.cursor(owner);
      while (_readCurrent(generation, owner, revision)) {
        final page = await access.api.fetchDeviceMaintenance(
          accessToken: access.session.accessToken,
          printerKey: '',
          after: cursor,
        );
        if (!_readCurrent(generation, owner, revision)) return false;
        if (page.cursor < cursor || (page.hasMore && page.cursor <= cursor))
          throw const FormatException('维护分页没有前进');
        await _store.importPage(owner, page);
        cursor = page.cursor;
        if (!page.hasMore) break;
      }
      if (!_readCurrent(generation, owner, revision)) return false;
      await _reloadLocal(owner, generation, deviceRevision: revision);
      if (!_readCurrent(generation, owner, revision)) return false;
      state = state.copyWith(
        busy: false,
        refreshedAt: DateTime.now(),
        error: pendingFailed ? '部分维护记录已保存在本机，待同步' : null,
      );
      return true;
    } catch (_) {
      if (_readCurrent(generation, owner, revision))
        state = state.copyWith(
          busy: false,
          error: '暂时无法同步设备。请检查网络与桌面共享设置；当前显示本机保存的记录。',
        );
      return false;
    } finally {
      _busy = false;
      if (_current(generation, owner) && state.busy)
        state = state.copyWith(busy: false, error: state.error);
      if (mounted && generation != _generation && state.owner != null)
        unawaited(refresh());
    }
  }

  Future<PersonalDevice> resolve(
    String token, {
    bool allowCached = true,
  }) async {
    final owner = state.owner;
    final generation = _generation;
    final revision = _deviceRevision;
    if (owner == null) throw StateError('请先登录，再打开设备标签');
    if (_deviceMutationBusy) throw StateError('正在更改设备设置，请完成后重新扫描');
    try {
      final access = await _access();
      if (!_readCurrent(generation, owner, revision))
        throw StateError('设备或账号已变化，请重新扫描');
      final device = await access.api.resolveDeviceTag(
        accessToken: access.session.accessToken,
        deviceToken: token,
      );
      if (!_readCurrent(generation, owner, revision))
        throw StateError('设备或账号已变化，请重新扫描');
      await _store.putDevice(owner, device);
      await _reloadLocal(owner, generation, deviceRevision: revision);
      if (!_readCurrent(generation, owner, revision))
        throw StateError('设备或账号已变化，请重新扫描');
      unawaited(refresh());
      return device;
    } on CommunityApiException catch (error) {
      if (!_readCurrent(generation, owner, revision))
        throw StateError('设备或账号已变化，请重新扫描');
      if (error.statusCode == 404 ||
          error.statusCode == 403 ||
          error.isAuthenticationFailure) {
        // A denial also invalidates pending reads, otherwise an older device
        // list could restore the just-revoked token for offline access.
        ++_deviceRevision;
        for (final d in state.devices.where((d) => d.deviceToken == token)) {
          await _store.forgetDevice(owner, d.printerKey);
        }
        await _reloadLocal(owner, generation);
        throw StateError('当前账号无权查看这台设备，或设备标签已失效');
      }
      if (allowCached &&
          _readCurrent(generation, owner, revision) &&
          [
            CommunityApiErrorCategory.network,
            CommunityApiErrorCategory.timeout,
            CommunityApiErrorCategory.server,
          ].contains(error.category)) {
        final cached = state.devices
            .where((d) => d.deviceToken == token && !d.archived)
            .firstOrNull;
        if (cached != null) {
          state = state.copyWith(error: '当前离线，显示此账号上次保存的设备与维护记录');
          return cached;
        }
      }
      rethrow;
    }
  }

  Future<void> updateDevice(String key, Map<String, dynamic> changes) =>
      _mutateDevice(
        key,
        (api, session) => api.updateDevice(
          accessToken: session.accessToken,
          printerKey: key,
          changes: changes,
        ),
      );

  Future<void> rotateTag(String key) => _mutateDevice(
    key,
    (api, session) =>
        api.rotateDeviceTag(accessToken: session.accessToken, printerKey: key),
  );

  Future<void> _mutateDevice(
    String key,
    Future<PersonalDevice> Function(PersonalDeviceApi, AppAuthSession) mutate,
  ) async {
    if (_deviceMutationBusy) throw StateError('已有设备设置操作进行中，请稍后重试');
    final owner = state.owner, generation = _generation;
    if (owner == null) throw StateError('请登录 sohun 个人账号');
    _deviceMutationBusy = true;
    final revision = ++_deviceRevision;
    PersonalDevice? previous;
    var evicted = false;
    try {
      final access = await _access();
      previous = (await _store.devices(
        owner,
      )).where((device) => device.printerKey == key).firstOrNull;
      if (!_current(generation, owner)) return;
      // Persist invalidation before submitting. A successful remote mutation
      // can otherwise leave an old offline identity after logout or app exit.
      await _store.forgetDevice(owner, key);
      evicted = true;
      if (!_current(generation, owner)) return;
      final device = await mutate(access.api, access.session);
      if (!_current(generation, owner)) return;
      await _store.putDevice(owner, device);
      await _reloadLocal(owner, generation, deviceRevision: revision);
    } catch (error) {
      // A lost response may mean the server already revoked the old tag.
      // Do not keep authorizing that cached identity until an online refresh.
      final rejected =
          error is CommunityApiException &&
          error.statusCode != null &&
          error.statusCode! >= 400 &&
          error.statusCode! < 500 &&
          ![401, 403, 404, 408].contains(error.statusCode);
      if (evicted && _current(generation, owner)) {
        if (rejected && previous != null) {
          await _store.putDevice(owner, previous);
        }
        await _reloadLocal(owner, generation, deviceRevision: revision);
      }
      rethrow;
    } finally {
      ++_deviceRevision;
      _deviceMutationBusy = false;
      if (mounted && generation != _generation && state.owner != null)
        unawaited(refresh());
    }
  }

  Future<void> addMaintenance({
    required String key,
    required String kind,
    required String notes,
    required DateTime performedAt,
    DateTime? nextDueAt,
    String? faultEventId,
  }) async {
    final owner = state.owner;
    final generation = _generation;
    if (owner == null) throw StateError('请先登录');
    if (_deviceMutationBusy) throw StateError('正在更改设备设置，请完成后重试');
    await _store.enqueueMaintenance(
      owner,
      DeviceMaintenanceRecord(
        eventId: const Uuid().v4(),
        printerKey: key,
        kind: kind,
        notes: notes.trim(),
        performedAt: performedAt,
        nextDueAt: nextDueAt,
        faultEventId: faultEventId,
      ),
    );
    await _reloadLocal(owner, generation);
    if (_current(generation, owner)) unawaited(refresh());
  }

  Future<void> recordTagWrite(
    PersonalDevice device,
    DeviceTagWriteSuccess result,
  ) async {
    final owner = state.owner;
    if (owner == null ||
        _deviceMutationBusy ||
        !result.verified ||
        result.deviceToken != device.deviceToken)
      throw StateError('标签或账号已变化，未登记设备标签');
    await _store.recordTagWrite(owner, device, result.tagId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    ++_generation;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
