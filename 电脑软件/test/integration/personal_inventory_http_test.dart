import 'dart:convert';
import 'dart:io';

import 'package:consumable_tracker_desktop/core/services/personal_inventory_sync_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/printer_fault.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

// Requires Node 24 and the community server dependencies. Keep the ordinary
// Flutter-only suite independent; run explicitly with the documented flag.
void main() {
  test(
    'real HTTP: inventory settlement/replacement and quota-safe fault protocol',
    () async {
      final process = await Process.start('node', [
        'test/fixtures/personal_inventory_http_server.mjs',
      ]);
      final errors = StringBuffer();
      final stderr = process.stderr
          .transform(utf8.decoder)
          .listen(errors.write);
      addTearDown(() async {
        process.stdin.writeln('stop');
        await process.stdin.flush();
        final code = await process.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            process.kill();
            return -1;
          },
        );
        await stderr.cancel();
        expect(code, 0, reason: errors.toString());
      });
      final base = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      final client = http.Client();
      addTearDown(client.close);
      final response = await client.post(
        Uri.parse('$base/v1/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': 'inventory-http@example.com',
          'handle': 'inventory_http',
          'displayName': '库存验收',
          'password': 'IntegrationTest123!',
          'acceptTerms': true,
          'termsVersion': '2026-07-29',
          'privacyVersion': '2026-07-29',
        }),
      );
      expect(response.statusCode, 201, reason: response.body);
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final session = AppAuthSession(
        user: AppUser.fromJson(payload['user'] as Map<String, dynamic>),
        accessToken: payload['accessToken'] as String,
        refreshToken: payload['refreshToken'] as String,
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        serverBaseUrl: base,
      );
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(
        () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false,
      );
      final desktop = AppDatabase.forTesting(NativeDatabase.memory());
      final phone = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(desktop.close);
      addTearDown(phone.close);
      final api = CommunityApiClient(
        baseUri: Uri.parse(base),
        httpClient: client,
      );
      final fault = PrinterFaultRecord(
        eventId: 'http-fault',
        printerKey: 'isolated-printer',
        printerName: '本机 HTTP 验收',
        model: 'X1C',
        code: '07004001',
        kind: 'print_error',
        severity: 'error',
        title: '故障验收',
        message: '仅写入隔离测试数据库',
        firstSeenAt: DateTime.utc(2026, 9, 6, 10),
        lastSeenAt: DateTime.utc(2026, 9, 6, 10),
      );
      await api.uploadPrinterFaults(
        accessToken: session.accessToken,
        events: [fault],
      );
      final cleared = fault.copyWith(
        clearedAt: DateTime.utc(2026, 9, 6, 11),
        lastSeenAt: DateTime.utc(2026, 9, 6, 11),
      );
      final overQuota = PrinterFaultRecord.fromJson({
        ...fault.toJson(),
        'eventId': 'http-over-quota',
      });
      await expectLater(
        api.uploadPrinterFaults(
          accessToken: session.accessToken,
          events: [cleared, overQuota],
        ),
        throwsA(
          isA<CommunityApiException>()
              .having(
                (e) => e.code,
                'code',
                'printer_fault_count_quota_exceeded',
              )
              .having((e) => e.details, 'details', {
                'rejectedEventIds': ['http-over-quota'],
              }),
        ),
      );
      expect(
        (await api.fetchPrinterFaults(
          accessToken: session.accessToken,
        )).events.single.clearedAt,
        isNull,
      );
      await api.uploadPrinterFaults(
        accessToken: session.accessToken,
        events: [cleared],
      );
      expect(
        (await api.fetchPrinterFaults(
          accessToken: session.accessToken,
        )).events.single.clearedAt,
        isNotNull,
      );
      final desktopSync = PersonalInventorySyncService(
        dao: desktop.consumableDao,
        api: api,
      );
      final phoneSync = PersonalInventorySyncService(
        dao: phone.consumableDao,
        api: api,
      );
      final draft = MobileConsumableDraft(
        brand: 'eSUN',
        model: 'PLA',
        color: Colors.blue,
        colorName: '蓝色',
      );
      final first = await MobileInventoryRepository(desktop.consumableDao)
          .addFromDraft(
            draft,
            tagUid: '04:a1:b2:c3',
            tagType: 'CUID',
            ownerAccount: owner,
            initialGrams: 750,
          );
      final firstRow = (await desktop.consumableDao.getPersonalByUid(
        first.inventoryUid,
        ownerAccount: owner,
      ))!;
      final at = DateTime.utc(2026, 9, 6, 10, 30);
      await desktop.consumableDao.adjustGrams(firstRow.id, 50);
      await desktop.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          consumableId: Value(firstRow.id),
          consumedGrams: const Value(50),
          loggedAt: Value(at),
        ),
        taskUid: 'http-task-1',
      );
      await desktopSync.synchronize(session: session);
      await phoneSync.synchronize(session: session);
      final phoneFirst = (await phone.consumableDao.getPersonalByUid(
        first.inventoryUid,
        ownerAccount: owner,
      ))!;
      expect(phoneFirst.remainingGrams, 700);
      final remoteEvent = (await phone.consumableDao.getPersonalInventoryEvents(
        owner,
      )).single;
      expect(remoteEvent.occurredAt, at);
      expect(remoteEvent.taskUid, 'http-task-1');
      expect(remoteEvent.isRemote, true);
      final next = await MobileInventoryRepository(phone.consumableDao)
          .addFromDraft(
            draft,
            tagUid: '04A1B2C3',
            ownerAccount: owner,
            forceNewCycle: true,
            initialGrams: 2000,
            expectedInventoryUid: first.inventoryUid,
          );
      await phoneSync.synchronize(session: session);
      await desktopSync.synchronize(session: session);
      final secondRow = (await desktop.consumableDao.getPersonalByUid(
        next.inventoryUid,
        ownerAccount: owner,
      ))!;
      await desktop.consumableDao.adjustGrams(secondRow.id, 25);
      await desktop.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          consumableId: Value(secondRow.id),
          consumedGrams: const Value(25),
          loggedAt: Value(at.add(const Duration(hours: 1))),
        ),
        taskUid: 'http-task-2',
      );
      await desktopSync.synchronize(session: session);
      await phoneSync.synchronize(session: session);
      await desktopSync.synchronize(session: session);
      await phoneSync.synchronize(session: session);
      expect(
        (await phone.consumableDao.getById(phoneFirst.id))!.remainingGrams,
        700,
      );
      expect(
        (await phone.consumableDao.getPersonalByUid(
          next.inventoryUid,
          ownerAccount: owner,
        ))!.remainingGrams,
        1975,
      );
      expect(
        await phone.consumableDao.getPersonalInventoryConsumedGrams(
          first.inventoryUid,
          ownerAccount: owner,
        ),
        50,
      );
      expect(
        await phone.consumableDao.getPersonalInventoryConsumedGrams(
          next.inventoryUid,
          ownerAccount: owner,
        ),
        25,
      );
      expect(
        (await phone.consumableDao.getPersonalInventoryEvents(
          owner,
        )).where((e) => e.source == 'usage'),
        hasLength(2),
      );
      expect(
        (await phone.consumableDao.getRfidSpoolBindingById(
          phoneFirst.id,
        ))!.status,
        'replaced',
      );
      await phoneSync.rebindAndSynchronize(
        session: session,
        consumableId: phoneFirst.id,
        expectedTagUid: '04A1B2C3',
        newTagUid: '04BB0002',
        newTagType: 'FUID',
      );
      await desktopSync.synchronize(session: session);
      final rebound = (await desktop.consumableDao.getRfidSpoolBindingById(
        firstRow.id,
      ))!;
      expect(rebound.tagUid, '04BB0002');
      expect(rebound.tagHistory.single.tagUid, '04A1B2C3');
      expect(
        (await desktopSync.synchronize(session: session)).pushedChanges,
        isFalse,
      );
      expect(
        (await phoneSync.synchronize(session: session)).pushedChanges,
        isFalse,
      );
      expect(
        (await desktop.consumableDao.getById(firstRow.id))!.remainingGrams,
        700,
      );
      final originalHistory = await desktop.consumableDao
          .getPersonalRfidSpoolHistory('04A1B2C3', ownerAccount: owner);
      expect(originalHistory, hasLength(2));
      expect(originalHistory.first.inventoryUid, next.inventoryUid);
      expect(originalHistory.last.isHistoricalTag, isTrue);
      await desktop.consumableDao.adjustGrams(firstRow.id, 15);
      await desktop.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          consumableId: Value(firstRow.id),
          consumedGrams: const Value(15),
        ),
      );
      await desktopSync.synchronize(session: session);
      await phoneSync.synchronize(session: session);
      expect(
        (await phone.consumableDao.getById(phoneFirst.id))!.remainingGrams,
        685,
      );
      expect(
        await phone.consumableDao.getPersonalInventoryConsumedGrams(
          first.inventoryUid,
          ownerAccount: owner,
        ),
        65,
      );
      expect(
        (await phone.consumableDao.getPersonalByUid(
          next.inventoryUid,
          ownerAccount: owner,
        ))!.remainingGrams,
        1975,
      );
    },
    skip: !const bool.fromEnvironment('RUN_INVENTORY_HTTP_TESTS'),
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
