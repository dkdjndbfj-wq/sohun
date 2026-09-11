import 'dart:convert';
import 'dart:io';

import 'package:consumable_tracker_desktop/core/services/personal_inventory_sync_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/personal_ams_identity.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'real HTTP: reusable card receives stock repeatedly and chooses existing spool without duplicating it',
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
          'email': 'stock-http@example.com',
          'handle': 'stock_http',
          'displayName': '入库验收',
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
      const firstOperation = '8bccb30f-5da8-48d0-988f-ab01e23b0b01';
      final template = PersonalInventoryRecord(
        uid: 'unused-template',
        manufacturer: 'eSUN',
        model: 'PLA',
        materialType: 'PLA',
        colorHex: '#123456',
        totalGrams: 1000,
        remainingGrams: 1000,
        createdAt: DateTime.utc(2026, 9, 8),
        updatedAt: DateTime.utc(2026, 9, 8),
      );
      final first = await phone.consumableDao.addPersonalStockFromRfidCard(
        operationUid: firstOperation,
        tagUid: card,
        tagType: 'CUID',
        template: template,
        quantity: 3,
        ownerAccount: owner,
      );
      await phoneSync.synchronize(session: session);
      await desktopSync.synchronize(session: session);
      expect(await desktop.consumableDao.getPersonal(), hasLength(3));
      expect(
        (await PersonalAmsIdentityResolver.load(
          desktop,
        )).resolve('${card}00000100').requiresConfirmation,
        isTrue,
      );
      final firstId = (await desktop.consumableDao.getPersonalByUid(
        first.inventoryUids.first,
        ownerAccount: owner,
      ))!.id;
      await desktop.consumableDao.attachPersonalRfidTagToExistingStock(
        consumableId: firstId,
        tagUid: card,
        tagType: 'CUID',
        ownerAccount: owner,
      );
      await confirmPersonalAmsIdentity(
        desktop,
        consumableId: firstId,
        reportedUid: '${card}00000100',
      );
      await desktop.consumableDao.adjustGrams(firstId, 125);
      await desktopSync.synchronize(session: session);
      await phoneSync.synchronize(session: session);
      await phone.consumableDao.addPersonalStockFromRfidCard(
        operationUid: '8bccb30f-5da8-48d0-988f-ab01e23b0b02',
        tagUid: card,
        tagType: 'CUID',
        template: template,
        quantity: 2,
        ownerAccount: owner,
      );
      await phoneSync.synchronize(session: session);
      await desktopSync.synchronize(session: session);
      expect(await desktop.consumableDao.getPersonal(), hasLength(5));
      expect(
        (await desktop.consumableDao.getById(firstId))!.remainingGrams,
        875,
      );
      final nextId = (await desktop.consumableDao.getPersonalByUid(
        first.inventoryUids[1],
        ownerAccount: owner,
      ))!.id;
      final next = await desktop.consumableDao
          .attachPersonalRfidTagToExistingStock(
            consumableId: nextId,
            tagUid: card,
            tagType: 'CUID',
            ownerAccount: owner,
          );
      expect(next.cycle, 2);
      expect(next.inventoryUid, first.inventoryUids[1]);
      await desktopSync.synchronize(session: session);
      await phoneSync.synchronize(session: session);
      final retry = await phone.consumableDao.addPersonalStockFromRfidCard(
        operationUid: firstOperation,
        tagUid: card,
        tagType: 'CUID',
        template: template,
        quantity: 3,
        ownerAccount: owner,
      );
      expect(retry.replayed, isTrue);
      await phoneSync.synchronize(session: session);
      final remote = await api.fetchPersonalInventory(
        accessToken: session.accessToken,
      );
      expect(remote.records, hasLength(5));
      expect(
        remote.records
            .where((r) => r.rfidTagUid != null && r.lifecycleStatus == 'active')
            .single
            .uid,
        next.inventoryUid,
      );
      expect(remote.records.map((r) => r.sourceRfidTagUid), everyElement(card));
      expect(
        remote.records
            .firstWhere((r) => r.uid == first.inventoryUids.first)
            .remainingGrams,
        875,
      );
      final events = await api.fetchPersonalInventoryEvents(
        accessToken: session.accessToken,
        afterCursor: 0,
      );
      expect(
        events.events.where((e) => e.eventType == 'stock_received'),
        hasLength(5),
      );

      // A manual 1 kg receipt must stay one actual spool after cloud import,
      // with its receipt identity and remaining balance preserved.
      final manual = AccountMobileInventorySync(
        dao: phone.consumableDao,
        api: api,
        session: session,
      );
      const manualOperation = '8bccb30f-5da8-48d0-988f-ab01e23b0b03';
      const draft = MobileConsumableDraft(
        brand: 'eSUN',
        model: 'PLA',
        color: Colors.blue,
        colorName: '蓝',
      );
      final manualSaved = await manual.saveManualBatch(
        draft,
        operationUid: manualOperation,
        quantity: 1,
        initialGrams: 1000,
      );
      expect(manualSaved.single.syncPending, isFalse);
      await desktopSync.synchronize(session: session);
      final importedManual = (await desktop.consumableDao.getPersonalByUid(
        manualSaved.single.inventoryUid,
        ownerAccount: owner,
      ))!;
      expect(
        await desktop.consumableDao.isIndividualPersonalSpool(
          importedManual.id,
        ),
        isTrue,
      );
      final source = (await desktop.consumableDao
          .getPersonalRfidStockSourcesMap([
            importedManual.id,
          ]))[importedManual.id]!;
      expect(source.tagUid, isNull);
      expect(source.tagType, isNull);
      expect(source.receiptUid, manualOperation);
      expect(importedManual.totalGrams, 1000);
      await desktop.consumableDao.adjustGrams(importedManual.id, 125);
      await desktopSync.synchronize(session: session);
      await manual.synchronizeExisting();
      final manualRetry = await manual.saveManualBatch(
        draft,
        operationUid: manualOperation,
        quantity: 1,
        initialGrams: 1000,
      );
      expect(manualRetry.single.inventoryUid, manualSaved.single.inventoryUid);
      final manualRemote = await api.fetchPersonalInventory(
        accessToken: session.accessToken,
      );
      expect(manualRemote.records, hasLength(6));
      final manualRecord = manualRemote.records.singleWhere(
        (r) => r.stockReceiptUid == manualOperation,
      );
      expect(manualRecord.sourceRfidTagUid, isNull);
      expect(manualRecord.rfidTagUid, isNull);
      expect(manualRecord.remainingGrams, 875);
    },
    skip: !const bool.fromEnvironment('RUN_INVENTORY_HTTP_TESTS'),
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
