import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/external/community/community_api_client.dart';
import '../../data/models/printer_fault.dart';
import '../../providers/app_auth_provider.dart';
import 'printer_fault_monitor.dart';

final printerFaultSyncStatusProvider = StateProvider<String?>((ref) => null);

class _FaultUploadState {
  int cursor = 0;
  String? problem;
  final deferred = <String, ({String fingerprint, DateTime retryAt})>{};
}

class PrinterFaultSyncService {
  static const _uploadInterval = Duration(seconds: 15);
  static const _quotaRetryInterval = Duration(minutes: 5);
  static const _maxUploadAttempts = 8;
  static const _quotaMessage = '故障云端配额已满，部分记录保留在本机；已有故障仍继续同步';
  final Ref ref;
  final DateTime Function() _now;
  final bool _autoStart;
  final _uploads = <String, _FaultUploadState>{};
  Timer? _timer;
  DateTime? _nextUploadAt;
  String? _owner;
  int _generation = 0;
  bool _running = false, _disposed = false;

  PrinterFaultSyncService(
    this.ref, {
    DateTime Function()? now,
    bool autoStart = true,
  }) : _now = now ?? DateTime.now,
       _autoStart = autoStart {
    _owner = printerFaultAccountKey(ref.read(appAuthProvider));
    ref.listen(appAuthProvider, (_, auth) {
      final nextOwner = printerFaultAccountKey(auth);
      if (nextOwner != _owner) {
        _owner = nextOwner;
        _generation++;
      }
      if (_autoStart) unawaited(sync());
    });
    if (_autoStart) {
      _timer = Timer.periodic(_uploadInterval, (_) => sync());
      ref.listen(printerFaultMonitorProvider, (_, __) => sync());
      scheduleMicrotask(sync);
    }
  }

  bool _isCurrent(String owner, int generation) =>
      !_disposed &&
      generation == _generation &&
      printerFaultAccountKey(ref.read(appAuthProvider)) == owner;

  static bool _isQuota(CommunityApiException error) =>
      error.code == 'printer_fault_count_quota_exceeded' ||
      error.code == 'printer_fault_storage_quota_exceeded';

  static String _fingerprint(Map<String, String> row) =>
      sha256.convert(utf8.encode(row['payload']!)).toString();

  Future<void> _uploadPage({
    required String owner,
    required int generation,
    required String accessToken,
    required PersonalPrinterFaultApi api,
    required PrinterFaultStore store,
    required _FaultUploadState upload,
  }) async {
    final now = _now();
    upload.deferred.removeWhere((_, entry) => !entry.retryAt.isAfter(now));
    var rows = await store.pending(owner, afterRowId: upload.cursor);
    if (!_isCurrent(owner, generation)) return;
    if (rows.isEmpty && upload.cursor != 0) {
      upload.cursor = 0;
      rows = await store.pending(owner);
      if (!_isCurrent(owner, generation)) return;
    }
    if (rows.isEmpty) {
      upload.problem = null;
      return;
    }
    // Rotate through deterministic account pages even when a page only
    // contains quota-deferred rows. Retained rows cannot poison the head.
    upload.cursor = int.parse(rows.last['cursor']!);
    final eligible = rows.where((row) {
      final deferred = upload.deferred[row['id']];
      if (deferred == null) return true;
      if (deferred.fingerprint == _fingerprint(row)) return false;
      upload.deferred.remove(row['id']);
      return true; // A changed lifecycle payload may retry now.
    }).toList();
    final batches = <List<Map<String, String>>>[
      if (eligible.isNotEmpty) eligible,
    ];
    var attempts = 0;
    upload.problem = upload.deferred.isEmpty ? null : _quotaMessage;
    while (batches.isNotEmpty && attempts < _maxUploadAttempts) {
      if (!_isCurrent(owner, generation)) return;
      final batch = batches.removeAt(0);
      attempts++;
      try {
        await api.uploadPrinterFaults(
          accessToken: accessToken,
          events: batch
              .map(
                (row) => PrinterFaultRecord.fromJson(
                  jsonDecode(row['payload']!) as Map<String, dynamic>,
                ),
              )
              .toList(),
        );
        if (!_isCurrent(owner, generation)) return;
        for (final row in batch) {
          if (!_isCurrent(owner, generation)) return;
          // A newer local clear must remain queued for its own upload.
          await store.sent(owner, row);
          upload.deferred.remove(row['id']);
        }
      } on CommunityApiException catch (error) {
        if (!_isCurrent(owner, generation)) return;
        if (error.isAuthenticationFailure) rethrow;
        if (!_isQuota(error)) rethrow;
        upload.problem = _quotaMessage;
        final details = error.details;
        final rawIds = details is Map ? details['rejectedEventIds'] : null;
        final batchIds = batch.map((row) => row['id']).toSet();
        final rejected = rawIds is List
            ? rawIds.whereType<String>().where(batchIds.contains).toSet()
            : <String>{};
        if (rejected.isEmpty && batch.length > 1) {
          // Older quota responses have no ID list. Split only within the
          // same bounded request budget. Single-row attempts allow the SQL
          // cursor to resume exactly where this round's budget runs out.
          batches.insertAll(0, batch.map((row) => [row]));
          continue;
        }
        if (batch.length == 1) rejected.add(batch.single['id']!);
        for (final row in batch.where((row) => rejected.contains(row['id']))) {
          upload.deferred[row['id']!] = (
            fingerprint: _fingerprint(row),
            retryAt: now.add(_quotaRetryInterval),
          );
        }
        final remaining = batch
            .where((row) => !rejected.contains(row['id']))
            .toList();
        if (remaining.isNotEmpty) batches.insert(0, remaining);
      }
    }
    if (batches.isNotEmpty) {
      // Resume at the first unattempted row, not the start of the old page.
      // Otherwise a legacy server plus expiring deferrals could repeatedly
      // consume the budget on the same prefix and starve a later clear.
      upload.cursor = int.parse(batches.first.first['cursor']!) - 1;
    }
    // Eight writes per 15 seconds leaves room below 120 / minute.
    upload.problem = upload.deferred.isNotEmpty || batches.isNotEmpty
        ? _quotaMessage
        : null;
  }

  Future<void> sync() async {
    if (_running || _disposed) return;
    final owner = printerFaultAccountKey(ref.read(appAuthProvider));
    final api = ref.read(communityApiProvider);
    if (owner == null || api is! PersonalPrinterFaultApi) return;
    final generation = _generation;
    _running = true;
    try {
      await ref.read(printerFaultMonitorProvider.notifier).ready;
      if (!_isCurrent(owner, generation)) return;
      final store = ref.read(printerFaultStoreProvider);
      final session = await ref
          .read(appAuthProvider.notifier)
          .ensureValidSession();
      if (!_isCurrent(owner, generation)) return;
      final faultApi = api as PersonalPrinterFaultApi;
      final upload = _uploads.putIfAbsent(owner, _FaultUploadState.new);
      if (_nextUploadAt == null || !_now().isBefore(_nextUploadAt!)) {
        _nextUploadAt = _now().add(_uploadInterval);
        try {
          await _uploadPage(
            owner: owner,
            generation: generation,
            accessToken: session.accessToken,
            api: faultApi,
            store: store,
            upload: upload,
          );
        } on CommunityApiException catch (error) {
          if (error.isAuthenticationFailure) rethrow;
          upload.problem = '部分故障上传待重试，已继续接收手机已读状态';
        } catch (_) {
          upload.problem = '部分故障上传待重试，已继续接收手机已读状态';
        }
      }
      if (!_isCurrent(owner, generation)) return;
      // An upload rejection must not stop independent read reconciliation.
      final prefs = await SharedPreferences.getInstance();
      if (!_isCurrent(owner, generation)) return;
      final key = 'desktop_fault_read_cursor_$owner';
      var cursor = prefs.getInt(key) ?? 0;
      while (_isCurrent(owner, generation)) {
        final page = await faultApi.fetchPrinterFaults(
          accessToken: session.accessToken,
          after: cursor,
        );
        if (!_isCurrent(owner, generation)) return;
        final localUnread = ref
            .read(printerFaultMonitorProvider)
            .records
            .where((e) => e.readAt == null)
            .map((e) => e.eventId)
            .toSet();
        await ref
            .read(printerFaultMonitorProvider.notifier)
            .markRead(
              page.events
                  .where(
                    (e) => e.readAt != null && localUnread.contains(e.eventId),
                  )
                  .map((e) => e.eventId),
              isCurrent: () => _isCurrent(owner, generation),
            );
        if (!_isCurrent(owner, generation)) return;
        if (page.hasMore && page.cursor <= cursor) {
          throw const FormatException('Invalid fault cursor');
        }
        cursor = page.cursor;
        if (!page.hasMore) break;
      }
      if (!_isCurrent(owner, generation)) return;
      await prefs.setInt(key, cursor);
      if (_isCurrent(owner, generation)) {
        ref.read(printerFaultSyncStatusProvider.notifier).state =
            upload.problem ?? '已同步到手机账号';
      }
    } catch (_) {
      if (_isCurrent(owner, generation)) {
        ref.read(printerFaultSyncStatusProvider.notifier).state =
            '手机同步待重试，故障已保存在本机';
      }
    } finally {
      _running = false;
      if (!_disposed && _autoStart && generation != _generation) {
        scheduleMicrotask(sync);
      }
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}

final printerFaultSyncServiceProvider = Provider((ref) {
  final service = PrinterFaultSyncService(ref);
  ref.onDispose(service.dispose);
  return service;
});
