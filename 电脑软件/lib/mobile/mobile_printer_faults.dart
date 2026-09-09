import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/services/printer_fault_monitor.dart'
    show printerFaultAccountKey;
import '../data/external/community/community_api_client.dart';
import '../data/models/printer_fault.dart';
import '../providers/app_auth_provider.dart';
import '../features/diagnostics/printer_fault_center.dart'
    show PrinterFaultCard;
import 'mobile_glass_choice_chip.dart';

final mobileFaultOpenRequestProvider = StateProvider<int>((ref) => 0);

class MobilePrinterFaultState {
  final List<PrinterFaultRecord> records;
  final bool signedIn, syncing, backgroundEnabled, permissionAllowed;
  final String? error;
  final DateTime? syncedAt, leaseExpiresAt;
  const MobilePrinterFaultState({
    this.records = const [],
    this.signedIn = false,
    this.syncing = false,
    this.backgroundEnabled = false,
    this.permissionAllowed = false,
    this.error,
    this.syncedAt,
    this.leaseExpiresAt,
  });
  MobilePrinterFaultState copyWith({
    List<PrinterFaultRecord>? records,
    bool? syncing,
    bool? backgroundEnabled,
    bool? permissionAllowed,
    String? error,
    DateTime? syncedAt,
    DateTime? leaseExpiresAt,
  }) => MobilePrinterFaultState(
    records: records ?? this.records,
    signedIn: signedIn,
    syncing: syncing ?? this.syncing,
    backgroundEnabled: backgroundEnabled ?? this.backgroundEnabled,
    permissionAllowed: permissionAllowed ?? this.permissionAllowed,
    error: error,
    syncedAt: syncedAt ?? this.syncedAt,
    leaseExpiresAt: leaseExpiresAt ?? this.leaseExpiresAt,
  );
}

class MobilePrinterFaultController
    extends StateNotifier<MobilePrinterFaultState>
    with WidgetsBindingObserver {
  static const channel = MethodChannel('top.sohun/printer_faults');
  final Ref ref;
  Timer? _timer;
  String? _owner;
  int _cursor = 0, _generation = 0;
  bool _busy = false, _foreground = true, _accountInitialized = false;
  MobilePrinterFaultController(this.ref)
    : super(const MobilePrinterFaultState()) {
    WidgetsBinding.instance.addObserver(this);
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openFaults')
        ref.read(mobileFaultOpenRequestProvider.notifier).state++;
    });
    ref.listen(
      appAuthProvider,
      (_, next) => unawaited(_accountChanged(next)),
      fireImmediately: true,
    );
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_foreground) unawaited(refresh());
    });
  }
  Future<dynamic> _native(String method, [Object? args]) async {
    try {
      return await channel.invokeMethod<dynamic>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _accountChanged(AppAuthState auth) async {
    if (auth.status == AppAuthStatus.initializing) return;
    final next = printerFaultAccountKey(auth);
    if (_accountInitialized &&
        next == _owner &&
        state.signedIn == (next != null))
      return;
    _accountInitialized = true;
    final generation = ++_generation;
    _owner = next;
    _cursor = 0;
    state = MobilePrinterFaultState(signedIn: next != null);
    try {
      final status = await _native('status');
      if (!mounted || generation != _generation) return;
      if (status is Map && status['accountKey'] != next) await _native('clear');
      if (next == null) return;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('phone_faults_v1_$next');
      if (raw != null) {
        final cache = jsonDecode(raw) as Map<String, dynamic>;
        if (!mounted || generation != _generation) return;
        _cursor = cache['cursor'] as int? ?? 0;
        state = state.copyWith(
          records: (cache['events'] as List)
              .map(
                (e) => PrinterFaultRecord.fromJson(e as Map<String, dynamic>),
              )
              .toList(),
          syncedAt: DateTime.tryParse(cache['syncedAt'] as String? ?? ''),
        );
      }
      if (status is Map && status['accountKey'] == next) {
        state = state.copyWith(
          backgroundEnabled: status['enabled'] == true,
          permissionAllowed: status['allowed'] == true,
          leaseExpiresAt: DateTime.tryParse(
            status['expiresAt'] as String? ?? '',
          ),
        );
      }
      if (await _native('takeOpenRequest') == true && mounted)
        ref.read(mobileFaultOpenRequestProvider.notifier).state++;
    } catch (_) {
      if (mounted && generation == _generation) _cursor = 0;
    }
    if (mounted && generation == _generation) await refresh();
  }

  Future<void> refresh() async {
    final owner = _owner;
    final api = ref.read(communityApiProvider);
    if (_busy || !mounted || owner == null || api is! PersonalPrinterFaultApi)
      return;
    _busy = true;
    final generation = _generation;
    state = state.copyWith(syncing: true);
    try {
      final session = await ref
          .read(appAuthProvider.notifier)
          .ensureValidSession();
      if (!mounted || generation != _generation) return;
      final faultApi = api as PersonalPrinterFaultApi;
      final all = {for (final e in state.records) e.eventId: e};
      final changed = <String, PrinterFaultRecord>{};
      var cursor = _cursor;
      while (true) {
        final page = await faultApi.fetchPrinterFaults(
          accessToken: session.accessToken,
          after: cursor,
        );
        if (!mounted || generation != _generation) return;
        for (final event in page.events) {
          all[event.eventId] = event;
          changed[event.eventId] = event;
        }
        if (page.hasMore && page.cursor <= cursor)
          throw const FormatException('Invalid fault cursor');
        cursor = page.cursor;
        if (!page.hasMore) break;
      }
      final records = all.values.toList()
        ..sort((a, b) => b.firstSeenAt.compareTo(a.firstSeenAt));
      final now = DateTime.now();
      final nativeStatus = await _native('status');
      if (!mounted || generation != _generation) return;
      if (nativeStatus is Map && nativeStatus['accountKey'] == owner) {
        state = state.copyWith(
          permissionAllowed: nativeStatus['allowed'] == true,
        );
      }
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || generation != _generation) return;
      await prefs.setString(
        'phone_faults_v1_$owner',
        jsonEncode({
          'cursor': cursor,
          'syncedAt': now.toIso8601String(),
          'events': records.map((e) => e.toJson()).toList(),
        }),
      );
      if (!mounted || generation != _generation) return;
      _cursor = cursor;
      state = state.copyWith(records: records, syncing: false, syncedAt: now);
      await _native('deliver', {
        'accountKey': owner,
        'events': changed.values.map((e) => e.toJson()).toList(),
      });
      if (state.backgroundEnabled &&
          (state.leaseExpiresAt == null ||
              state.leaseExpiresAt!.difference(now) < const Duration(days: 1)))
        await setBackgroundEnabled(true, requestPermission: false);
    } catch (_) {
      if (mounted && generation == _generation)
        state = state.copyWith(
          syncing: false,
          error: '暂时无法同步。请检查账号、网络及电脑端是否运行；当前保留上次收到的记录。',
        );
    } finally {
      _busy = false;
      if (mounted && generation != _generation) unawaited(refresh());
    }
  }

  Future<void> markRead(PrinterFaultRecord fault) async {
    final generation = _generation;
    try {
      final api = ref.read(communityApiProvider);
      if (api is! PersonalPrinterFaultApi || _owner == null) return;
      final session = await ref
          .read(appAuthProvider.notifier)
          .ensureValidSession();
      if (generation != _generation) return;
      await (api as PersonalPrinterFaultApi).readPrinterFaults(
        accessToken: session.accessToken,
        eventIds: [fault.eventId],
      );
      if (!mounted || generation != _generation) return;
      final updated = fault.copyWith(readAt: DateTime.now());
      state = state.copyWith(
        records: state.records
            .map((r) => r.eventId == fault.eventId ? updated : r)
            .toList(),
      );
      await _native('deliver', {
        'accountKey': _owner,
        'events': [updated.toJson()],
      });
    } catch (_) {
      if (mounted) state = state.copyWith(error: '标记已读失败，请稍后重试');
    }
  }

  Future<void> setBackgroundEnabled(
    bool enabled, {
    bool requestPermission = true,
  }) async {
    final generation = _generation;
    try {
      if (!enabled) {
        await _native('clear');
        if (mounted) state = state.copyWith(backgroundEnabled: false);
        return;
      }
      if (_owner == null) return;
      final allowed = await _native(
        requestPermission ? 'requestPermission' : 'permission',
      );
      if (allowed != true) {
        if (mounted)
          state = state.copyWith(
            permissionAllowed: false,
            error: '请在系统设置中允许打印提醒通知',
          );
        return;
      }
      final api = ref.read(communityApiProvider);
      if (api is! PersonalPrinterFaultApi) return;
      final session = await ref
          .read(appAuthProvider.notifier)
          .ensureValidSession();
      final lease = await (api as PersonalPrinterFaultApi)
          .createFaultMonitorLease(accessToken: session.accessToken);
      if (!mounted || generation != _generation) return;
      final configured = await _native('configure', {
        'accountKey': _owner,
        'baseUrl': session.serverBaseUrl,
        'token': lease['token'],
        'expiresAt': lease['expiresAt'],
      });
      if (configured != true) throw StateError('Notifications unavailable');
      await _native('deliver', {
        'accountKey': _owner,
        'events': state.records.map((e) => e.toJson()).toList(),
      });
      if (mounted && generation == _generation)
        state = state.copyWith(
          backgroundEnabled: true,
          permissionAllowed: true,
          leaseExpiresAt: DateTime.tryParse(
            lease['expiresAt'] as String? ?? '',
          ),
        );
    } catch (_) {
      if (mounted) state = state.copyWith(error: '未能开启系统提醒，请检查服务连接后重试');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState value) {
    _foreground = value == AppLifecycleState.resumed;
    if (_foreground) unawaited(refresh());
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}

final mobilePrinterFaultProvider =
    StateNotifierProvider<
      MobilePrinterFaultController,
      MobilePrinterFaultState
    >((ref) => MobilePrinterFaultController(ref));

class MobilePrinterFaultPage extends ConsumerStatefulWidget {
  final VoidCallback onAccountTap;
  const MobilePrinterFaultPage({super.key, required this.onAccountTap});
  @override
  ConsumerState<MobilePrinterFaultPage> createState() =>
      _MobilePrinterFaultPageState();
}

class _MobilePrinterFaultPageState
    extends ConsumerState<MobilePrinterFaultPage> {
  bool _history = false;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mobilePrinterFaultProvider);
    final controller = ref.read(mobilePrinterFaultProvider.notifier);
    final visible = state.records.where((r) => _history || r.active).toList();
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: controller.refresh,
        child: ListView(
          padding: const EdgeInsets.all(20),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '打印提醒',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: '刷新提醒',
                  onPressed: state.syncing ? null : controller.refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('电脑端运行并连接打印机后，会将故障同步到同一 sohun 账号。'),
            if (!state.signedIn) ...[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: widget.onAccountTap,
                child: const Text('登录 sohun 查看提醒'),
              ),
            ] else ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('系统与后台提醒'),
                subtitle: const Text('打开软件时每 15 秒检查；后台由系统约每 15 分钟或更久检查，可能延迟。'),
                value: state.backgroundEnabled,
                onChanged: controller.setBackgroundEnabled,
              ),
              if (state.backgroundEnabled && !state.permissionAllowed)
                const Text('系统通知权限未开启，仍可在本页查看。'),
              Text(
                state.syncedAt == null
                    ? '等待首次同步'
                    : '最近同步 ${state.syncedAt!.toLocal().toString().substring(5, 19)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    state.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  MobileGlassChoiceChip(
                    label: Text(
                      '当前 ${state.records.where((r) => r.active).length}',
                    ),
                    selected: !_history,
                    onSelected: (_) => setState(() => _history = false),
                  ),
                  MobileGlassChoiceChip(
                    label: const Text('历史'),
                    selected: _history,
                    onSelected: (_) => setState(() => _history = true),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (visible.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Center(child: Text('暂未收到故障记录')),
                ),
              for (final fault in visible)
                PrinterFaultCard(
                  fault: fault,
                  onRead: () => controller.markRead(fault),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
