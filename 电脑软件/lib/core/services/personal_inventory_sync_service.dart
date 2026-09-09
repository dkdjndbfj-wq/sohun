import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import '../../data/database/database.dart';
import '../../data/database/personal_inventory_balance_sync.dart';
import '../../data/external/community/community_api_client.dart';
import '../../data/external/slicer/material_catalog_service.dart';
import '../../data/models/app_auth.dart';
import '../../data/models/personal_inventory_event.dart';
import '../../data/models/personal_inventory_sync.dart';
import '../../data/models/rfid_tag_identity.dart';
import '../../data/models/rfid_tag_history.dart';
import '../../data/prefs/community_server_settings.dart';

/// Bidirectional merge for the desktop personal inventory.
///
/// Balances use revisioned snapshots; immutable history is appended and pulled
/// in bounded pages. Both imports preserve edits made while requests run.
class PersonalInventorySyncService {
  PersonalInventorySyncService({required this.dao, required this.api});

  final ConsumableDao dao;
  final PersonalInventoryApi api;

  /// Account retagging requires a successful cloud round-trip. If another
  /// device wins the revision race, roll back the tentative local binding.
  Future<void> rebindAndSynchronize({
    required AppAuthSession session,
    required int consumableId,
    required String expectedTagUid,
    required String newTagUid,
    required String newTagType,
  }) => dao.transaction(() async {
    await synchronize(session: session);
    await dao.rebindPersonalRfidSpool(
      consumableId: consumableId,
      expectedTagUid: expectedTagUid,
      newTagUid: newTagUid,
      newTagType: newTagType,
      ownerAccount: ownerAccountFor(session),
    );
    await synchronize(session: session);
  });

  static String ownerAccountFor(AppAuthSession session) {
    final server = serverBaseUrlFor(session);
    final userId = session.user.id.trim();
    if (userId.isEmpty) throw StateError('个人账号缺少稳定用户 ID');
    // owner_account is compared case-insensitively by older database helpers.
    // Hex keeps the complete, case-sensitive server/user identity while
    // producing a lowercase opaque key that those helpers cannot corrupt.
    return 'personal:v2:${_hex(server)}:${_hex(userId)}';
  }

  static String legacyOwnerAccountFor(AppAuthSession session) =>
      '${session.user.email.trim().toLowerCase()}|personal';

  static String serverBaseUrlFor(AppAuthSession session) =>
      normalizeCommunityServerUri(session.serverBaseUrl).toString();

  static String _hex(String value) => utf8
      .encode(value)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  Future<PersonalInventorySyncResult> synchronize({
    required AppAuthSession session,
  }) async {
    var remote = await api.fetchPersonalInventory(
      accessToken: session.accessToken,
    );
    final ownerAccount = ownerAccountFor(session);
    final server = serverBaseUrlFor(session);
    await dao.migrateVerifiedLegacyPersonalOwner(
      legacyOwnerAccount: legacyOwnerAccountFor(session),
      nextOwnerAccount: ownerAccount,
      serverUrl: server,
      remoteInventoryUids: remote.records.map((record) => record.uid),
      remoteDeletedUids: remote.deletedUids.keys,
    );
    final eventApi =
        remote.eventSyncVersion >= 1 && api is PersonalInventoryEventApi
        ? api as PersonalInventoryEventApi
        : null;
    await dao.claimPersonalInventoryEvents(ownerAccount);
    var local = await _readLocalRecords(ownerAccount);
    final localDeleted = await dao.getPersonalInventoryTombstones(ownerAccount);
    final localCatalog = await MaterialCatalogService.load();
    var localEvents = eventApi == null
        ? await dao.getPersonalInventoryEvents(ownerAccount)
        : <PersonalInventoryEvent>[];
    var mergedDeleted = _mergeDeleted(remote.deletedUids, localDeleted);
    mergedDeleted = _protectTaggedHistory(mergedDeleted, [
      ...remote.records,
      ...local,
    ]);
    var merged = await _mergeBalances(
      remote.records,
      local,
      mergedDeleted,
      ownerAccount,
      server,
    );
    await _retainConflicts(merged, ownerAccount);
    var mergedCatalog = _mergeCatalog(remote.materialCatalog, localCatalog);
    var mergedEvents = _mergeEvents(remote.events, localEvents);
    var pushed = false;

    if (!_sameRecords(remote.records, merged) ||
        !_sameCatalog(remote.materialCatalog, mergedCatalog) ||
        !_sameDeleted(remote.deletedUids, mergedDeleted) ||
        !_sameEvents(remote.events, mergedEvents)) {
      try {
        remote = await api.replacePersonalInventory(
          accessToken: session.accessToken,
          snapshot: PersonalInventorySnapshot(
            revision: remote.revision,
            records: merged,
            materialCatalog: mergedCatalog,
            deletedUids: mergedDeleted,
            events: eventApi == null ? mergedEvents : const [],
          ),
        );
        pushed = true;
        merged = remote.records;
        mergedCatalog = remote.materialCatalog;
        mergedDeleted = remote.deletedUids;
        mergedEvents = remote.events;
      } on CommunityApiException catch (error) {
        if (error.code != 'revision_conflict') rethrow;
        // Re-read once and merge against the newer server revision. A second
        // conflict is surfaced instead of silently dropping inventory data.
        remote = await api.fetchPersonalInventory(
          accessToken: session.accessToken,
        );
        local = await _readLocalRecords(ownerAccount);
        mergedDeleted = _mergeDeleted(
          remote.deletedUids,
          await dao.getPersonalInventoryTombstones(ownerAccount),
        );
        mergedDeleted = _protectTaggedHistory(mergedDeleted, [
          ...remote.records,
          ...local,
        ]);
        merged = await _mergeBalances(
          remote.records,
          local,
          mergedDeleted,
          ownerAccount,
          server,
        );
        await _retainConflicts(merged, ownerAccount);
        mergedCatalog = _mergeCatalog(
          remote.materialCatalog,
          await MaterialCatalogService.load(),
        );
        localEvents = eventApi == null
            ? await dao.getPersonalInventoryEvents(ownerAccount)
            : <PersonalInventoryEvent>[];
        mergedEvents = _mergeEvents(remote.events, localEvents);
        remote = await api.replacePersonalInventory(
          accessToken: session.accessToken,
          snapshot: PersonalInventorySnapshot(
            revision: remote.revision,
            records: merged,
            materialCatalog: mergedCatalog,
            deletedUids: mergedDeleted,
            events: eventApi == null ? mergedEvents : const [],
          ),
        );
        pushed = true;
        merged = remote.records;
        mergedCatalog = remote.materialCatalog;
        mergedDeleted = remote.deletedUids;
        mergedEvents = remote.events;
      }
    }

    var imported = 0;
    // Import the merged snapshot atomically. A transient SQLite failure must
    // not leave half of a remote snapshot visible on the phone (or cause a
    // later sync to upload a partially imported state).
    await dao.transaction(() async {
      // Printer deductions and confirmed replacements may happen while a
      // network request is in flight. Keep those live changes for the next
      // upload instead of overwriting them with the earlier PUT response.
      final latest = await _readLocalRecords(ownerAccount);
      final latestEvents = eventApi == null
          ? await dao.getPersonalInventoryEvents(ownerAccount)
          : <PersonalInventoryEvent>[];
      final beforeRequest = {
        for (final record in local) _uidKey(record.uid): record,
      };
      final liveMerged = {
        for (final record in merged) _uidKey(record.uid): record,
      };
      for (final record in latest) {
        final before = beforeRequest[_uidKey(record.uid)];
        if (before == null || !_sameJson(record.toJson(), before.toJson())) {
          liveMerged[_uidKey(record.uid)] = record;
        }
      }
      mergedDeleted = _mergeDeleted(
        mergedDeleted,
        await dao.getPersonalInventoryTombstones(ownerAccount),
      );
      mergedDeleted = _protectTaggedHistory(mergedDeleted, [
        ...merged,
        ...latest,
      ]);
      merged = _merge(liveMerged.values.toList(), const [], mergedDeleted);
      mergedEvents = _mergeEvents(mergedEvents, latestEvents);
      for (final uid in mergedDeleted.keys) {
        await dao.deletePersonalByUid(uid, ownerAccount: ownerAccount);
      }
      await _assertPendingTaskLifecycles(merged, latest, ownerAccount);
      for (final record in merged) {
        final existing = await dao.getPersonalByUid(
          record.uid,
          ownerAccount: ownerAccount,
        );
        if (existing == null ||
            !await _sameLocalWithBinding(existing, record)) {
          if (existing != null) {
            final before = await dao.getRfidSpoolBindingById(existing.id);
            if (before?.tagUid.isNotEmpty == true &&
                (!rfidTagUidEquals(before!.tagUid, record.rfidTagUid ?? '') ||
                    record.lifecycleStatus == 'replaced' ||
                    record.lifecycleStatus == 'retired')) {
              // An idle physical slot is not evidence that the retagged spool
              // is still loaded there. Let the next explicit load/AMS reading
              // establish its identity; pending tasks were checked above.
              await dao.customUpdate(
                'UPDATE printer_channels SET consumable_id = NULL, loaded_spool_uid = NULL, '
                'loaded_remaining_grams = 0, farm_roll_paused = 0 WHERE consumable_id = ?',
                variables: [Variable(existing.id)],
                updates: {dao.attachedDatabase.printerChannels},
              );
            }
          }
          await dao.upsertPersonalInventoryRecord(
            record,
            ownerAccount: ownerAccount,
          );
          imported += 1;
        } else {
          // A legacy row may match the remote record but still have no owner;
          // claim it once the account-scoped sync has verified its contents.
          await dao.setOwnerAccount(existing.id, ownerAccount);
        }
        await dao.removePersonalInventoryTombstone(ownerAccount, record.uid);
      }
      await dao.upsertPersonalInventoryEvents(
        mergedEvents,
        ownerAccount: ownerAccount,
      );
      await dao.saveInventorySyncBaselines(
        ownerAccount,
        server,
        remote.records,
      );
    });
    if (eventApi != null) {
      await _synchronizeEventLedger(session, ownerAccount, eventApi);
    }
    return PersonalInventorySyncResult(
      remoteRevision: remote.revision,
      importedCount: imported,
      pushedChanges: pushed,
    );
  }

  Future<List<PersonalInventoryRecord>> _mergeBalances(
    List<PersonalInventoryRecord> remote,
    List<PersonalInventoryRecord> local,
    Map<String, DateTime> deleted,
    String owner,
    String server,
  ) async {
    final merged = _merge(remote, local, deleted);
    await _assertPendingTaskLifecycles(merged, local, owner);
    final baselines = await dao.readInventorySyncBaselines(owner, server);
    final localMap = {for (final row in local) _uidKey(row.uid): row};
    final balances = <String, double>{};
    var hasConflict = false;
    for (final row in remote) {
      final key = _uidKey(row.uid);
      final here = localMap[key];
      if (here == null ||
          ['retired', 'replaced'].contains(here.lifecycleStatus) ||
          ['retired', 'replaced'].contains(row.lifecycleStatus))
        continue;
      final individualSpool =
          here.stockReceiptUid != null ||
          row.stockReceiptUid != null ||
          (here.rfidTagUid != null &&
              row.rfidTagUid != null &&
              rfidTagUidEquals(here.rfidTagUid!, row.rfidTagUid!));
      if (here.remainingGrams == row.remainingGrams) {
        await dao.clearInventoryBalanceConflict(owner, server, row.uid);
        continue;
      }
      final baseline = baselines[key];
      final localChanged =
          baseline == null || here.remainingGrams != baseline.remainingGrams;
      final remoteChanged =
          baseline == null || row.remainingGrams != baseline.remainingGrams;
      if (localChanged && remoteChanged) {
        final baselineIndividual =
            baseline?.stockReceiptUid != null || baseline?.rfidTagUid != null;
        if (!individualSpool &&
            !baselineIndividual &&
            baseline != null &&
            here.totalGrams == baseline.totalGrams &&
            row.totalGrams == baseline.totalGrams) {
          // Legacy rows represent an aggregate stock balance. Their normal
          // mutations (printing, adding rolls, corrections) are additive, so
          // merge both branches relative to the last cloud ancestor instead
          // of dropping whichever device has the older wall clock.
          final combined =
              baseline.remainingGrams +
              (here.remainingGrams - baseline.remainingGrams) +
              (row.remainingGrams - baseline.remainingGrams);
          if (combined.isFinite && combined <= 100000) {
            balances[key] = combined < 0 ? 0 : combined;
            await dao.clearInventoryBalanceConflict(owner, server, row.uid);
            continue;
          }
        }
        await dao.retainInventoryBalanceConflict(owner, server, row);
        hasConflict = true;
      } else {
        balances[key] = localChanged ? here.remainingGrams : row.remainingGrams;
        await dao.clearInventoryBalanceConflict(owner, server, row.uid);
      }
    }
    if (hasConflict) {
      throw const CommunityApiException(
        '同一库存的本机余量与云端余量均已变化，已保留两份记录。请核对实际余量后重试同步。',
        code: 'inventory_balance_conflict',
        category: CommunityApiErrorCategory.conflict,
      );
    }
    return [
      for (final row in merged)
        if (balances.containsKey(_uidKey(row.uid)))
          row.copyWith(
            remainingGrams: balances[_uidKey(row.uid)],
            lifecycleStatus:
                row.lifecycleStatus == 'active' ||
                    row.lifecycleStatus == 'depleted'
                ? (balances[_uidKey(row.uid)]! <= 0 ? 'depleted' : 'active')
                : row.lifecycleStatus,
          )
        else
          row,
    ];
  }

  Future<void> _synchronizeEventLedger(
    AppAuthSession session,
    String owner,
    PersonalInventoryEventApi eventApi,
  ) async {
    final server = serverBaseUrlFor(session);
    while (true) {
      final batch = await dao.getPendingPersonalInventoryEvents(owner, server);
      if (batch.isEmpty) break;
      await eventApi.appendPersonalInventoryEvents(
        accessToken: session.accessToken,
        events: batch,
      );
      // Only acknowledge after a successful response. A dropped response can
      // safely repeat the same IDs; a transaction commits receipts together.
      await dao.transaction(
        () => dao.acknowledgePersonalInventoryEvents(owner, server, batch),
      );
    }
    var cursor = await dao.getPersonalInventoryEventCursor(owner, server);
    while (true) {
      final page = await eventApi.fetchPersonalInventoryEvents(
        accessToken: session.accessToken,
        afterCursor: cursor,
      );
      if (page.nextCursor < cursor ||
          ((page.hasMore || page.events.isNotEmpty) &&
              page.nextCursor <= cursor)) {
        throw const FormatException('耗材账本分页未前进，已保留本地同步进度');
      }
      await dao.transaction(() async {
        await dao.upsertPersonalInventoryEvents(
          page.events,
          ownerAccount: owner,
        );
        await dao.setPersonalInventoryEventCursor(
          owner,
          server,
          page.nextCursor,
        );
      });
      cursor = page.nextCursor;
      if (!page.hasMore) break;
    }
  }

  /// Bring both branches into view before asking the user to identify the
  /// physical spool. Never silently choose a branch or send an invalid graph.
  Future<void> _retainConflicts(
    List<PersonalInventoryRecord> records,
    String owner,
  ) async {
    final cycles = <String>{};
    final active = <String>{};
    var conflict = false;
    for (final record in records) {
      for (final old in record.rfidTagHistory) {
        final key = normalizeRfidTagUid(old.tagUid).toLowerCase();
        if (!cycles.add('$key:${old.cycle}')) conflict = true;
      }
      final tag = record.rfidTagUid;
      if (tag == null || tag.isEmpty || record.lifecycleStatus == 'retired')
        continue;
      final key = normalizeRfidTagUid(tag).toLowerCase();
      if (!cycles.add('$key:${record.rfidTagCycle}')) conflict = true;
      if (record.lifecycleStatus == 'active' && !active.add(key))
        conflict = true;
    }
    if (!conflict) return;
    await dao.transaction(() async {
      final latest = await _readLocalRecords(owner);
      for (final record in _merge(records, latest, {})) {
        await dao.upsertPersonalInventoryRecord(record, ownerAccount: owner);
      }
    });
    throw CommunityApiException(
      '同一标签有多个候选卷，已保留两端记录。请在标签生命周期中核对当前卷后重试同步。',
      code: 'inventory_tag_cycle_conflict',
      category: CommunityApiErrorCategory.conflict,
    );
  }

  Future<void> _assertPendingTaskLifecycles(
    List<PersonalInventoryRecord> incoming,
    List<PersonalInventoryRecord> local,
    String owner,
  ) async {
    final reserved = await dao
        .customSelect(
          'SELECT DISTINCT c.uid FROM print_task_consumables p '
          'JOIN consumables c ON c.id = p.consumable_id '
          "WHERE p.consumed_at IS NULL AND c.inventory_scope = 'personal' "
          "AND (c.owner_account IS NULL OR lower(trim(c.owner_account)) = ?)",
          variables: [Variable(owner.trim().toLowerCase())],
        )
        .get();
    if (reserved.isEmpty) return;
    final reservedUids = reserved
        .map((r) => _uidKey(r.read<String>('uid')))
        .toSet();
    final byUid = {for (final row in incoming) _uidKey(row.uid): row};
    for (final row in local) {
      if (row.rfidTagUid == null && row.stockReceiptUid == null) continue;
      final key = _uidKey(row.uid);
      if (!reservedUids.contains(key)) continue;
      final next = byUid[key];
      final hasSuccessor = incoming.any(
        (candidate) =>
            [_recordIdentity(candidate), ...candidate.rfidTagHistory].any(
              (binding) =>
                  _uidKey(binding.previousInventoryUid ?? '') == key &&
                  rfidTagUidEquals(binding.tagUid, row.rfidTagUid ?? '') &&
                  binding.cycle == row.rfidTagCycle + 1,
            ),
      );
      if (!hasSuccessor &&
          next != null &&
          ((next.rfidTagUid == null && row.rfidTagUid == null) ||
              rfidTagUidEquals(next.rfidTagUid ?? '', row.rfidTagUid ?? '')) &&
          next.lifecycleStatus != 'replaced' &&
          next.lifecycleStatus != 'retired')
        continue;
      throw CommunityApiException(
        '另一端已复用或结束标签，但本机仍有未结算任务。请在打印机所在设备确认换卷接续或完成任务结算后再同步。',
        code: 'inventory_task_handoff_required',
        category: CommunityApiErrorCategory.conflict,
      );
    }
  }

  Future<List<PersonalInventoryRecord>> _readLocalRecords(
    String ownerAccount,
  ) async {
    final rows = await dao.getPersonalForOwnerAccount(ownerAccount);
    final bindings = await dao.getRfidSpoolBindingsMap(
      rows.map((row) => row.id),
    );
    final sources = await dao.getPersonalRfidStockSourcesMap(
      rows.map((row) => row.id),
    );
    return [
      for (final row in rows)
        if (row.uid.trim().isNotEmpty)
          _recordFromLocal(
            row,
            binding: bindings[row.id],
            source: sources[row.id],
          ),
    ];
  }

  static PersonalInventoryRecord _recordFromLocal(
    Consumable row, {
    RfidSpoolBinding? binding,
    PersonalRfidStockSource? source,
  }) {
    return PersonalInventoryRecord(
      uid: row.uid.trim(),
      manufacturer: row.manufacturer,
      model: row.model,
      materialType: row.materialType,
      colorHex: row.colorHex,
      colorName: row.colorName,
      totalGrams: row.totalGrams,
      remainingGrams: row.remainingGrams,
      batchNo: row.batchNo,
      purchaseDate: row.purchaseDate,
      note: row.note,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      density: row.density,
      recommendedNozzleTemp: row.recommendedNozzleTemp,
      hygroscopicity: row.hygroscopicity,
      trayUuid: row.trayUuid,
      rfidSyncedAt: row.rfidSyncedAt,
      rfidTagUid: binding?.tagUid,
      rfidTagType: binding?.tagType,
      rfidTagCycle: binding?.cycle ?? 1,
      lifecycleStatus:
          binding?.status ?? (row.remainingGrams <= 0 ? 'depleted' : 'active'),
      previousConsumableUid: binding?.previousInventoryUid,
      rfidTagHistory: binding?.tagHistory ?? const [],
      sourceRfidTagUid: source?.tagUid,
      sourceRfidTagType: source?.tagType,
      stockReceiptUid: source?.receiptUid,
      stockReceiptIndex: source?.index,
      stockReceiptQuantity: source?.quantity,
    );
  }

  static List<PersonalInventoryRecord> _merge(
    List<PersonalInventoryRecord> remote,
    List<PersonalInventoryRecord> local,
    Map<String, DateTime> deleted,
  ) {
    final byUid = <String, PersonalInventoryRecord>{};
    for (final record in remote) {
      final key = _uidKey(record.uid);
      if (key.isEmpty) continue;
      final current = byUid[key];
      byUid[key] = current == null ? record : _mergeRecord(record, current);
    }
    for (final record in local) {
      final key = _uidKey(record.uid);
      if (key.isEmpty) continue;
      final current = byUid[key];
      byUid[key] = current == null ? record : _mergeRecord(record, current);
    }
    for (final entry in byUid.entries) {
      final record = entry.value;
      final deletedAt = deleted[entry.key];
      if (deletedAt != null && record.updatedAt.isAfter(deletedAt)) {
        deleted.remove(entry.key);
      }
    }
    byUid.removeWhere((uidKey, record) {
      final deletedAt = deleted[uidKey];
      return deletedAt != null && !record.updatedAt.isAfter(deletedAt);
    });
    // A successor is stronger evidence than an old client's late "active"
    // snapshot. Close only its matching predecessor; never change its grams.
    for (final successor in byUid.values.toList()) {
      final previousKey = _uidKey(successor.previousConsumableUid ?? '');
      final previous = byUid[previousKey];
      if (previous == null ||
          previous.lifecycleStatus != 'active' ||
          previous.rfidTagCycle >= successor.rfidTagCycle ||
          !rfidTagUidEquals(
            previous.rfidTagUid ?? '',
            successor.rfidTagUid ?? '',
          ))
        continue;
      byUid[previousKey] = previous.copyWith(
        lifecycleStatus: previous.remainingGrams <= 0 ? 'depleted' : 'replaced',
        updatedAt: previous.updatedAt.isAfter(successor.updatedAt)
            ? previous.updatedAt
            : successor.updatedAt,
      );
    }
    return byUid.values.toList(growable: false);
  }

  static PersonalInventoryRecord _mergeRecord(
    PersonalInventoryRecord candidate,
    PersonalInventoryRecord current,
  ) {
    final candidateSource = PersonalRfidStockSource.fromRecord(candidate);
    final currentSource = PersonalRfidStockSource.fromRecord(current);
    if (candidateSource != null &&
        currentSource != null &&
        !_sameJson(candidateSource.toJson(), currentSource.toJson())) {
      throw const CommunityApiException(
        '同一库存卷的来源卡或入库批次不一致，请保留数据并核对。',
        code: 'inventory_stock_receipt_conflict',
        category: CommunityApiErrorCategory.conflict,
      );
    }
    PersonalInventoryRecord preserveSource(PersonalInventoryRecord winner) {
      final source = candidateSource ?? currentSource;
      if (source == null) return winner;
      return winner.copyWith(
        sourceRfidTagUid: source.tagUid,
        sourceRfidTagType: source.tagType,
        stockReceiptUid: source.receiptUid,
        stockReceiptIndex: source.index,
        stockReceiptQuantity: source.quantity,
      );
    }

    // Binding history is append-only. A late v53 snapshot or skewed clock
    // must not replace a confirmed rebind with the original tag identity.
    final left = candidate.rfidTagHistory;
    final right = current.rfidTagHistory;
    if (left.isNotEmpty || right.isNotEmpty) {
      final deeper = left.length > right.length ? candidate : current;
      final earlier = identical(deeper, candidate) ? current : candidate;
      final common = earlier.rfidTagHistory.length;
      final prefix = List.generate(common, (i) => i).every(
        (i) => _sameJson(
          earlier.rfidTagHistory[i].toJson(),
          deeper.rfidTagHistory[i].toJson(),
        ),
      );
      if (!prefix ||
          (left.length == right.length &&
              !_recordIdentity(
                candidate,
              ).sameIdentity(_recordIdentity(current)))) {
        throw const CommunityApiException(
          '两端为同一余料卷选择了不同标签，请保留两端数据并核对后再同步。',
          code: 'inventory_rebind_conflict',
          category: CommunityApiErrorCategory.conflict,
        );
      }
      if (left.length != right.length) {
        if (!deeper.rfidTagHistory[common].sameIdentity(
          _recordIdentity(earlier),
        )) {
          throw const CommunityApiException(
            '标签换绑历史不连续，请核对库存记录。',
            code: 'inventory_rebind_conflict',
            category: CommunityApiErrorCategory.conflict,
          );
        }
        if (earlier.remainingGrams < deeper.remainingGrams) {
          throw const CommunityApiException(
            '旧标签设备记录了更少的余量，请先核对实际余量再同步换绑。',
            code: 'inventory_rebind_balance_conflict',
            category: CommunityApiErrorCategory.conflict,
          );
        }
        return preserveSource(deeper);
      }
    }
    var winner = _isNewer(candidate, current) ? candidate : current;
    for (final version in [candidate, current]) {
      if ((version.lifecycleStatus == 'replaced' ||
              version.lifecycleStatus == 'retired') &&
          (winner.rfidTagUid?.isNotEmpty != true ||
              rfidTagUidEquals(
                version.rfidTagUid ?? '',
                winner.rfidTagUid ?? '',
              ))) {
        if (winner.lifecycleStatus == 'active') {
          // A late pre-replacement snapshot must not refill a historical roll.
          winner = version.copyWith(
            updatedAt: winner.updatedAt.isAfter(version.updatedAt)
                ? winner.updatedAt
                : version.updatedAt,
          );
        } else {
          winner = winner.copyWith(lifecycleStatus: version.lifecycleStatus);
        }
      }
    }
    final tagged = candidate.rfidTagUid?.isNotEmpty == true
        ? candidate
        : current;
    if (winner.rfidTagUid?.isNotEmpty == true ||
        tagged.rfidTagUid?.isNotEmpty != true)
      return preserveSource(winner);
    // Legacy clients omit these columns; omission must not erase a binding.
    return preserveSource(
      winner.copyWith(
        rfidTagUid: tagged.rfidTagUid,
        rfidTagType: tagged.rfidTagType,
        rfidTagCycle: tagged.rfidTagCycle,
        lifecycleStatus: tagged.lifecycleStatus,
        previousConsumableUid: tagged.previousConsumableUid,
        rfidTagHistory: tagged.rfidTagHistory,
      ),
    );
  }

  static RfidTagHistoryEntry _recordIdentity(PersonalInventoryRecord record) =>
      RfidTagHistoryEntry(
        tagUid: record.rfidTagUid ?? '',
        tagType: record.rfidTagType,
        cycle: record.rfidTagCycle,
        previousInventoryUid: record.previousConsumableUid,
      );

  static Map<String, DateTime> _mergeDeleted(
    Map<String, DateTime> remote,
    Map<String, DateTime> local,
  ) {
    final merged = <String, DateTime>{};
    for (final entry in remote.entries) {
      final key = _uidKey(entry.key);
      if (key.isEmpty) continue;
      final current = merged[key];
      if (current == null || entry.value.isAfter(current)) {
        merged[key] = entry.value.toUtc();
      }
    }
    for (final entry in local.entries) {
      final key = _uidKey(entry.key);
      if (key.isEmpty) continue;
      final current = merged[key];
      if (current == null || entry.value.isAfter(current))
        merged[key] = entry.value.toUtc();
    }
    return merged;
  }

  static bool _sameDeleted(
    Map<String, DateTime> first,
    Map<String, DateTime> second,
  ) {
    final left = <String, DateTime>{};
    final right = <String, DateTime>{};
    for (final entry in first.entries) {
      final key = _uidKey(entry.key);
      if (key.isNotEmpty) left[key] = entry.value.toUtc();
    }
    for (final entry in second.entries) {
      final key = _uidKey(entry.key);
      if (key.isNotEmpty) right[key] = entry.value.toUtc();
    }
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// A tagged row is an auditable physical-spool instance. If an old client
  /// left a tombstone for it, keep the row and let the lifecycle status express
  /// retirement; otherwise the next sync would ask the server to erase the
  /// predecessor chain.
  static Map<String, DateTime> _protectTaggedHistory(
    Map<String, DateTime> deleted,
    Iterable<PersonalInventoryRecord> records,
  ) {
    final tagged = {
      for (final record in records)
        if (record.rfidTagUid?.trim().isNotEmpty == true) _uidKey(record.uid),
    };
    if (tagged.isEmpty) return deleted;
    final result = Map<String, DateTime>.from(deleted);
    result.removeWhere((uid, _) => tagged.contains(uid));
    return result;
  }

  static bool _sameRecords(
    List<PersonalInventoryRecord> first,
    List<PersonalInventoryRecord> second,
  ) {
    final left = <String, Map<String, dynamic>>{};
    final right = <String, Map<String, dynamic>>{};
    for (final record in first) {
      final key = _uidKey(record.uid);
      if (key.isNotEmpty) left[key] = record.toJson();
    }
    for (final record in second) {
      final key = _uidKey(record.uid);
      if (key.isNotEmpty) right[key] = record.toJson();
    }
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!_sameJson(entry.value, right[entry.key])) return false;
    }
    return true;
  }

  static String _uidKey(String value) => value.trim().toLowerCase();

  static bool _isNewer(
    PersonalInventoryRecord candidate,
    PersonalInventoryRecord current,
  ) {
    final candidateTime = candidate.updatedAt.toUtc();
    final currentTime = current.updatedAt.toUtc();
    if (candidateTime.isAfter(currentTime)) return true;
    if (candidateTime.isBefore(currentTime)) return false;
    // Equal timestamps are common when a phone and desktop save in the same
    // second. Prefer the record with the canonical physical-tag identity so a
    // server round-trip cannot accidentally erase an RFID binding.
    final candidateTag = candidate.rfidTagUid == null
        ? ''
        : normalizeRfidTagUid(candidate.rfidTagUid!);
    final currentTag = current.rfidTagUid == null
        ? ''
        : normalizeRfidTagUid(current.rfidTagUid!);
    return candidateTag.isNotEmpty && currentTag.isEmpty;
  }

  static List<String> _mergeCatalog(
    Iterable<String> remote,
    Iterable<String> local,
  ) {
    final values = <String>{};
    for (final value in [...remote, ...local]) {
      final normalized = value.trim();
      if (normalized.isNotEmpty) values.add(normalized);
    }
    final result = values.toList(growable: false);
    result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  static bool _sameCatalog(Iterable<String> first, Iterable<String> second) {
    final left = first.map((value) => value.trim().toLowerCase()).toSet();
    final right = second.map((value) => value.trim().toLowerCase()).toSet();
    return left.length == right.length && left.containsAll(right);
  }

  static List<PersonalInventoryEvent> _mergeEvents(
    Iterable<PersonalInventoryEvent> remote,
    Iterable<PersonalInventoryEvent> local,
  ) {
    final byUid = <String, PersonalInventoryEvent>{};
    for (final event in [...remote, ...local]) {
      final key = event.eventUid.trim().toLowerCase();
      if (key.isEmpty || event.inventoryUid.trim().isEmpty) continue;
      final current = byUid[key];
      if (current == null) {
        byUid[key] = event;
      } else if (!_sameJson(current.toJson(), event.toJson())) {
        throw StateError('同一耗材事件内容冲突，已保留原始记录，不能用更新时间覆盖账本');
      }
    }
    final result = byUid.values.toList(growable: false);
    result.sort((a, b) {
      final time = a.occurredAt.compareTo(b.occurredAt);
      return time != 0 ? time : a.eventUid.compareTo(b.eventUid);
    });
    return result;
  }

  static bool _sameEvents(
    Iterable<PersonalInventoryEvent> first,
    Iterable<PersonalInventoryEvent> second,
  ) {
    final left = <String, Map<String, dynamic>>{
      for (final event in first) event.eventUid.toLowerCase(): event.toJson(),
    };
    final right = <String, Map<String, dynamic>>{
      for (final event in second) event.eventUid.toLowerCase(): event.toJson(),
    };
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!_sameJson(entry.value, right[entry.key])) return false;
    }
    return true;
  }

  Future<bool> _sameLocalWithBinding(
    Consumable local,
    PersonalInventoryRecord remote,
  ) async {
    final binding = await dao.getRfidSpoolBindingById(local.id);
    final source = (await dao.getPersonalRfidStockSourcesMap([
      local.id,
    ]))[local.id];
    return _sameJson(
      _recordFromLocal(
        local,
        binding: binding?.tagUid.isNotEmpty == true ? binding : null,
        source: source,
      ).toJson(),
      remote.toJson(),
    );
  }

  static bool _sameJson(
    Map<String, dynamic> left,
    Map<String, dynamic>? right,
  ) {
    return right != null && _sameValue(left, right);
  }

  static bool _sameValue(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every(
            (key) =>
                right.containsKey(key) && _sameValue(left[key], right[key]),
          );
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          left.indexed.every((entry) => _sameValue(entry.$2, right[entry.$1]));
    }
    return left == right;
  }
}

class PersonalInventorySyncResult {
  const PersonalInventorySyncResult({
    required this.remoteRevision,
    required this.importedCount,
    required this.pushedChanges,
  });

  final int remoteRevision;
  final int importedCount;
  final bool pushedChanges;
}
