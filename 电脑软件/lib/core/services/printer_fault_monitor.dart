import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/database.dart';
import '../../data/models/printer_fault.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_alerts.dart';
import '../../providers/app_auth_provider.dart';
import '../../providers/database_provider.dart';
import 'printer_fault_service.dart';

String? printerFaultAccountKey(AppAuthState auth) {
  final session = auth.session;
  if (session == null || session.authRealm != 'personal') return null;
  return '${session.serverBaseUrl}|${session.user.id}|personal';
}

class PrinterFaultStore {
  final AppDatabase db;
  PrinterFaultStore(this.db);
  Future<void> initialize() =>
      db.customStatement('''CREATE TABLE IF NOT EXISTS printer_fault_outbox (
    account_key TEXT NOT NULL, event_uid TEXT NOT NULL, payload TEXT NOT NULL,
    PRIMARY KEY(account_key, event_uid))''');

  Future<List<({String serial, PrinterFaultRecord record})>> load() async {
    final rows = await db.customSelect(
      '''SELECT * FROM printer_fault_events
      WHERE cleared_at IS NULL OR id IN (SELECT id FROM printer_fault_events
      ORDER BY last_seen_at DESC LIMIT 500) ORDER BY last_seen_at DESC''',
    ).get();
    final result = <({String serial, PrinterFaultRecord record})>[];
    for (final row in rows) {
      final serial = row.read<String>('printer_serial');
      try {
        final json = jsonDecode(row.read<String?>('raw_payload') ?? '{}');
        if (json is Map<String, dynamic> && json.containsKey('eventId')) {
          result.add((
            serial: serial,
            record: PrinterFaultRecord.fromJson(json),
          ));
          continue;
        }
      } catch (_) {
        /* Legacy MQTT payload is not a display record. */
      }
      final code = row.read<String>('code');
      DateTime? time(String key) {
        final ms = row.read<int?>(key);
        return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
      }

      result.add((
        serial: serial,
        record: PrinterFaultRecord(
          eventId: row.read<String>('event_uid'),
          printerKey: sha256.convert(utf8.encode(serial)).toString(),
          printerName: '打印机',
          model: '',
          code: code,
          kind: code.length == 16
              ? 'hms'
              : code.length == 8
              ? 'print_error'
              : 'device_state',
          severity: row.read<String>('severity'),
          title: row.read<String>('title'),
          message: row.read<String>('summary'),
          firstSeenAt: time('first_seen_at')!,
          lastSeenAt: time('last_seen_at')!,
          clearedAt: time('cleared_at'),
          readAt: time('user_confirmed_at'),
        ),
      ));
    }
    return result;
  }

  Future<void> save(
    String serial,
    PrinterFaultRecord record,
    String? accountKey,
  ) => db.transaction(() async {
    final payload = jsonEncode(record.toJson());
    await db.customStatement(
      '''INSERT INTO printer_fault_events
      (id, event_uid, printer_serial, code, severity, title, summary, first_seen_at,
       last_seen_at, cleared_at, user_confirmed_at, knowledge_base_version, raw_payload)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(event_uid) DO UPDATE SET severity=excluded.severity,
      title=excluded.title, summary=excluded.summary, last_seen_at=excluded.last_seen_at,
      cleared_at=excluded.cleared_at, user_confirmed_at=excluded.user_confirmed_at,
      knowledge_base_version=excluded.knowledge_base_version, raw_payload=excluded.raw_payload''',
      [
        record.eventId,
        record.eventId,
        serial,
        record.code,
        record.severity,
        record.title,
        record.message,
        record.firstSeenAt.millisecondsSinceEpoch,
        record.lastSeenAt.millisecondsSinceEpoch,
        record.clearedAt?.millisecondsSinceEpoch,
        record.readAt?.millisecondsSinceEpoch,
        record.sourceVersion,
        payload,
      ],
    );
    if (accountKey != null)
      await db.customStatement(
        '''INSERT INTO printer_fault_outbox
      (account_key, event_uid, payload) VALUES (?, ?, ?) ON CONFLICT(account_key,event_uid)
      DO UPDATE SET payload=excluded.payload''',
        [accountKey, record.eventId, payload],
      );
  });

  Future<List<Map<String, String>>> pending(
    String accountKey, {
    int afterRowId = 0,
    int limit = 100,
  }) async {
    final rows = await db
        .customSelect(
          '''SELECT rowid AS outbox_rowid, event_uid, payload
          FROM printer_fault_outbox WHERE account_key = ? AND rowid > ?
          ORDER BY rowid LIMIT ?''',
          variables: [
            Variable.withString(accountKey),
            Variable.withInt(afterRowId),
            Variable.withInt(limit),
          ],
        )
        .get();
    return rows
        .map(
          (r) => {
            'id': r.read<String>('event_uid'),
            'payload': r.read<String>('payload'),
            'cursor': r.read<int>('outbox_rowid').toString(),
          },
        )
        .toList();
  }

  Future<void> sent(
    String accountKey,
    Map<String, String> row,
  ) => db.customStatement(
    'DELETE FROM printer_fault_outbox WHERE account_key=? AND event_uid=? AND payload=?',
    [accountKey, row['id'], row['payload']],
  );
}

class PrinterFaultMonitorState {
  final List<PrinterFaultRecord> records;
  final Set<String> pendingIds;
  const PrinterFaultMonitorState({
    this.records = const [],
    this.pendingIds = const {},
  });
  List<PrinterFaultRecord> get active =>
      records.where((r) => r.active).toList();
  List<PrinterFaultRecord> get pending => records
      .where((r) => r.needsAttention && pendingIds.contains(r.eventId))
      .toList();
}

/// Both active and fleet connectors use this one lifecycle. Per-printer queues
/// prevent two subscriptions/fast clear-recur reports from racing each other.
class PrinterFaultMonitor extends StateNotifier<PrinterFaultMonitorState> {
  final PrinterFaultStore store;
  final PrinterFaultService knowledge;
  final String? Function() accountKey;
  final Map<String, Future<void>> _tails = {};
  final Map<String, String> _serials = {};
  final Map<String, String> _signatures = {};
  final Map<String, DateTime> _lastObserved = {};
  late final Future<void> ready;
  PrinterFaultMonitor({
    required this.store,
    required this.knowledge,
    required this.accountKey,
  }) : super(const PrinterFaultMonitorState()) {
    ready = _initialize();
  }

  Future<void> _initialize() async {
    await store.initialize();
    await knowledge.load();
    final rows = await store.load();
    if (!mounted) return;
    for (final row in rows) {
      _serials[row.record.eventId] = row.serial;
    }
    state = PrinterFaultMonitorState(
      records: rows.map((r) => r.record).toList(),
    );
  }

  Future<void> observe({
    required String serial,
    required String name,
    String model = '',
    required BambuPrinterStatus status,
  }) {
    if (serial.isEmpty || !mounted) return Future.value();
    final owner = accountKey();
    final signature = jsonEncode([
      owner,
      status.gcodeState?.name,
      status.hasHmsState,
      status.hasPrintErrorState,
      status.hasFailReasonState,
      status.hmsAlerts?.map((e) => [e.code, e.severity]).toList(),
      status.printError,
      status.failReason,
    ]);
    final now = DateTime.now();
    if (_signatures[serial] == signature &&
        _lastObserved[serial] != null &&
        now.difference(_lastObserved[serial]!) < const Duration(minutes: 1))
      return _tails[serial] ?? Future.value();
    _signatures[serial] = signature;
    _lastObserved[serial] = now;
    final operation = (_tails[serial] ?? Future.value())
        .then((_) async {
          await ready;
          if (status.hmsAlerts?.isNotEmpty == true ||
              status.printError?.isNotEmpty == true) {
            await knowledge.loadForDevice(serial);
          }
          if (mounted) await _apply(serial, name, model, status, owner, now);
        })
        .catchError((Object error, StackTrace stack) {
          _signatures.remove(serial); // retry after a storage failure
          debugPrint('[PrinterFaultMonitor] 故障记录失败: $error');
        });
    _tails[serial] = operation;
    return operation;
  }

  Future<void> _apply(
    String serial,
    String name,
    String model,
    BambuPrinterStatus status,
    String? owner,
    DateTime observedAt,
  ) async {
    final alerts = buildPrinterAlerts(
      status,
      knowledgeBase: knowledge,
    ).where((a) => a.code != 'paused' && a.code != 'offline').toList();
    final current = alerts.map((a) => '${a.kind}:${a.code}').toSet();
    final previous = state.active
        .where((r) => _serials[r.eventId] == serial)
        .toList();
    for (final old in previous) {
      final known = switch (old.kind) {
        'hms' => status.hasHmsState || status.hmsAlerts != null,
        'print_error' => status.hasPrintErrorState || status.printError != null,
        _ =>
          status.hasFailReasonState ||
              status.failReason != null ||
              (old.code.startsWith('failed') &&
                  status.gcodeState != null &&
                  status.gcodeState != BambuGcodeState.offline &&
                  status.gcodeState != BambuGcodeState.unknown),
      };
      if (known && !current.contains('${old.kind}:${old.code}')) {
        await _save(
          serial,
          old.copyWith(clearedAt: observedAt, lastSeenAt: observedAt),
          owner,
        );
      }
    }
    for (final alert in alerts) {
      final old = previous
          .where((r) => r.kind == alert.kind && r.code == alert.code)
          .firstOrNull;
      final escalated =
          old != null &&
          old.severity != 'error' &&
          alert.severity == PrinterAlertSeverity.error;
      final record = PrinterFaultRecord(
        eventId: old?.eventId ?? const Uuid().v4(),
        printerKey: sha256.convert(utf8.encode(serial)).toString(),
        printerName: name.trim().isEmpty || name.trim() == serial
            ? '打印机 · ${serial.substring(serial.length > 4 ? serial.length - 4 : 0)}'
            : name,
        model: model.isEmpty ? old?.model ?? '' : model,
        code: alert.code ?? 'raw_reason',
        kind: alert.kind,
        severity: alert.severity.name,
        title: alert.title,
        message: alert.message,
        firstSeenAt: old?.firstSeenAt ?? observedAt,
        lastSeenAt: observedAt,
        readAt: escalated ? null : old?.readAt,
        source: alert.source,
        sourceVersion: alert.sourceVersion,
        helpUrl: alert.helpUrl?.toString(),
      );
      await _save(serial, record, owner, announce: record.needsAttention);
    }
  }

  Future<void> _save(
    String serial,
    PrinterFaultRecord record,
    String? owner, {
    bool announce = false,
  }) async {
    await store.save(serial, record, owner);
    if (!mounted) return;
    _serials[record.eventId] = serial;
    final records = [
      ...state.records.where((r) => r.eventId != record.eventId),
      record,
    ]..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    state = PrinterFaultMonitorState(
      records: records,
      pendingIds: {
        ...state.pendingIds.where(
          (id) => id != record.eventId || record.needsAttention,
        ),
        if (announce) record.eventId,
      },
    );
  }

  Future<void> markRead(
    Iterable<String> ids, {
    bool Function()? isCurrent,
  }) async {
    await ready;
    if (isCurrent?.call() == false) return;
    final owner = accountKey();
    for (final id in ids) {
      final serial = _serials[id];
      if (serial == null) continue;
      final operation = (_tails[serial] ?? Future<void>.value()).then((
        _,
      ) async {
        if (!mounted || isCurrent?.call() == false) return;
        final record = state.records.where((r) => r.eventId == id).firstOrNull;
        if (record != null && record.readAt == null) {
          await _save(serial, record.copyWith(readAt: DateTime.now()), owner);
        }
      });
      _tails[serial] = operation.catchError((Object _) {});
      await operation;
    }
  }
}

final printerFaultStoreProvider = Provider(
  (ref) => PrinterFaultStore(ref.watch(databaseProvider)),
);
final printerFaultMonitorProvider =
    StateNotifierProvider<PrinterFaultMonitor, PrinterFaultMonitorState>((ref) {
      final monitor = PrinterFaultMonitor(
        store: ref.watch(printerFaultStoreProvider),
        knowledge: PrinterFaultService(),
        accountKey: () => printerFaultAccountKey(ref.read(appAuthProvider)),
      );
      unawaited(
        monitor.ready.catchError(
          (Object error) => debugPrint('故障中心初始化失败：$error'),
        ),
      );
      return monitor;
    });
