import 'dart:convert';
import 'dart:io';

import 'package:consumable_tracker_desktop/core/services/personal_inventory_sync_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/personal_rfid_stock.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'real HTTP: reusable CUID switches A to B to A without merging physical rolls',
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
          'email': 'spool-reuse-http@example.com',
          'handle': 'spool_reuse_http',
          'displayName': '复用卷验收',
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
      final phone = AppDatabase.forTesting(NativeDatabase.memory());
      final desktop = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(phone.close);
      addTearDown(desktop.close);
      final api = CommunityApiClient(
        baseUri: Uri.parse(base),
        httpClient: client,
      );
      final phoneSync = PersonalInventorySyncService(
        dao: phone.consumableDao,
        api: api,
      );
      final desktopSync = PersonalInventorySyncService(
        dao: desktop.consumableDao,
        api: api,
      );

      const card = 'D021B75E';
      final now = DateTime.now().toUtc();
      final receipt = await phone.consumableDao.addPersonalStockFromRfidCard(
        operationUid: 'be25b9a6-96b1-4b6b-a4a0-f87431c8d001',
        tagUid: card,
        tagType: 'CUID',
        template: PersonalInventoryRecord(
          uid: 'unused-template',
          manufacturer: 'eSUN',
          model: 'PLA+',
          materialType: 'PLA',
          colorHex: '#3366FF',
          colorName: '蓝色',
          totalGrams: 1000,
          remainingGrams: 1000,
          createdAt: now,
          updatedAt: now,
        ),
        quantity: 2,
        ownerAccount: owner,
      );
      expect(receipt.consumableIds, hasLength(2));
      final spoolAId = receipt.consumableIds[0];
      final spoolBId = receipt.consumableIds[1];
      final spoolAUid = receipt.inventoryUids[0];
      final spoolBUid = receipt.inventoryUids[1];
      final phoneStock = PersonalRfidStockStore(phone);

      await phoneStock.activate(
        consumableId: spoolAId,
        tagUid: card,
        tagType: 'CUID',
        ownerAccount: owner,
      );
      await phone.consumableDao.adjustGrams(spoolAId, 585);
      await phone.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          consumableId: Value(spoolAId),
          consumedGrams: const Value(585),
          loggedAt: Value(now.add(const Duration(minutes: 1))),
        ),
        taskUid: 'reuse-http-a-585',
      );
      await phoneStock.activate(
        consumableId: spoolBId,
        tagUid: card,
        tagType: 'CUID',
        ownerAccount: owner,
      );
      await phoneStock.activate(
        consumableId: spoolAId,
        tagUid: card,
        tagType: 'CUID',
        ownerAccount: owner,
      );

      await phoneSync.synchronize(session: session);
      await desktopSync.synchronize(session: session);
      await phoneSync.synchronize(session: session);

      Future<Consumable> rowByUid(AppDatabase db, String uid) async =>
          (await db.consumableDao.getPersonalByUid(uid, ownerAccount: owner))!;

      for (final db in [phone, desktop]) {
        expect(
          await db.consumableDao.getPersonalForOwnerAccount(owner),
          hasLength(2),
        );
        expect((await rowByUid(db, spoolAUid)).remainingGrams, 415);
        expect((await rowByUid(db, spoolBUid)).remainingGrams, 1000);
        final aBinding = (await db.consumableDao.getRfidSpoolBindingById(
          (await rowByUid(db, spoolAUid)).id,
        ))!;
        final bBinding = (await db.consumableDao.getRfidSpoolBindingById(
          (await rowByUid(db, spoolBUid)).id,
        ))!;
        expect(aBinding.status, 'active');
        expect(aBinding.cycle, 3);
        expect(aBinding.previousInventoryUid, spoolBUid);
        expect(aBinding.tagHistory.map((entry) => entry.cycle), [1]);
        expect(bBinding.status, 'replaced');
        expect(bBinding.cycle, 2);
        expect(bBinding.previousInventoryUid, spoolAUid);
      }

      final desktopA = await rowByUid(desktop, spoolAUid);
      await desktop.consumableDao.adjustGrams(desktopA.id, 25);
      await desktop.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          consumableId: Value(desktopA.id),
          consumedGrams: const Value(25),
          loggedAt: Value(now.add(const Duration(minutes: 2))),
        ),
        taskUid: 'reuse-http-a-25',
      );
      await desktopSync.synchronize(session: session);
      await phoneSync.synchronize(session: session);
      expect(
        (await desktopSync.synchronize(session: session)).pushedChanges,
        isFalse,
      );
      expect(
        (await phoneSync.synchronize(session: session)).pushedChanges,
        isFalse,
      );

      for (final db in [phone, desktop]) {
        expect(
          await db.consumableDao.getPersonalForOwnerAccount(owner),
          hasLength(2),
        );
        expect((await rowByUid(db, spoolAUid)).remainingGrams, 390);
        expect((await rowByUid(db, spoolBUid)).remainingGrams, 1000);
      }
      final remote = await api.fetchPersonalInventory(
        accessToken: session.accessToken,
      );
      expect(remote.records, hasLength(2));
      expect(
        remote.records
            .singleWhere((row) => row.uid == spoolAUid)
            .remainingGrams,
        390,
      );
      expect(
        remote.records
            .singleWhere((row) => row.uid == spoolBUid)
            .remainingGrams,
        1000,
      );
      expect(
        remote.records
            .where((row) => row.lifecycleStatus == 'active')
            .single
            .uid,
        spoolAUid,
      );
    },
    skip: !const bool.fromEnvironment('RUN_INVENTORY_HTTP_TESTS'),
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
