import 'dart:async';
import 'package:uuid/uuid.dart';

import '../core/constants/personal_spool_policy.dart';
import '../data/database/daos/consumable_dao.dart';
import '../data/database/database.dart' show PersonalStockReceipt;
import '../data/models/personal_inventory_sync.dart';
import '../data/external/community/community_api_client.dart';
import '../data/models/app_auth.dart';
import '../core/services/personal_inventory_sync_service.dart';
import 'mobile_inventory_repository.dart';
import 'mobile_rfid_models.dart';
import 'rfid_native_bridge.dart';

abstract interface class MobileInventoryRebindSync {
  Future<void> rebind({
    required int consumableId,
    required String expectedTagUid,
    required String newTagUid,
    required String newTagType,
  });
}

class MobileStockReceiptResult {
  const MobileStockReceiptResult(this.receipt, {this.syncPending = false});
  final PersonalStockReceipt receipt;
  final bool syncPending;
}

/// Explicit receipt of new stock using a reusable material-information card.
/// Re-reading the same card is separate from confirming a new receipt.
abstract interface class MobileInventoryStockSync {
  Future<MobileStockReceiptResult> receiveFromCard(
    MobileConsumableDraft draft, {
    required String operationUid,
    required String tagUid,
    required String tagType,
    required int quantity,
    required double initialGrams,
  });
}

/// A manual batch is one local transaction, not a sequence of independently
/// committed rolls that a user could accidentally repeat after partial failure.
abstract interface class MobileInventoryBatchSync {
  Future<List<MobileInventorySaveResult>> saveManualBatch(
    MobileConsumableDraft draft, {
    required int quantity,
    required double initialGrams,
    String? operationUid,
  });
}

Future<List<MobileInventorySaveResult>> _saveManualBatch(
  ConsumableDao dao,
  MobileConsumableDraft draft, {
  required int quantity,
  required double initialGrams,
  String? ownerAccount,
  String? operationUid,
  Future<void> Function()? beforeCommit,
}) async {
  if (quantity < 1 || quantity > 100) {
    throw ArgumentError.value(quantity, 'quantity', '每批数量须为 1 到 100 卷');
  }
  return dao.transaction(() async {
    final receipt = await dao.addPersonalStockManual(
      operationUid: operationUid ?? const Uuid().v4(),
      template: _stockTemplate(draft, initialGrams),
      quantity: quantity,
      ownerAccount: ownerAccount,
    );
    final saved = [
      for (final uid in receipt.inventoryUids)
        MobileInventorySaveResult(inventoryUid: uid),
    ];
    await beforeCommit?.call();
    return saved;
  });
}

PersonalInventoryRecord _stockTemplate(
  MobileConsumableDraft draft,
  double grams,
) {
  final now = DateTime.now();
  return PersonalInventoryRecord(
    uid: 'receipt-template',
    manufacturer: draft.brand.trim(),
    model: draft.model.trim(),
    materialType: draft.model.trim(),
    colorHex: draft.colorHex,
    colorName: draft.colorName.trim(),
    totalGrams: personalSpoolCapacityGrams,
    remainingGrams: grams,
    createdAt: now,
    updatedAt: now,
  );
}

/// Saves a newly written spool to the shared local database and, when a
/// sohun session is available, publishes the complete personal snapshot.
class AccountMobileInventorySync
    implements
        MobileInventorySync,
        MobileInventoryAuditSync,
        MobileInventoryRebindSync,
        MobileInventoryBatchSync,
        MobileInventoryStockSync {
  static final Map<String, Future<void>> _syncTails = {};

  AccountMobileInventorySync({
    required ConsumableDao dao,
    required PersonalInventoryApi api,
    required AppAuthSession session,
    this.ensureSession,
  }) : _repository = MobileInventoryRepository(dao),
       _dao = dao,
       _api = api,
       _session = session;

  final MobileInventoryRepository _repository;
  final ConsumableDao _dao;
  final PersonalInventoryApi _api;
  final AppAuthSession _session;
  final Future<AppAuthSession> Function()? ensureSession;

  @override
  Future<List<MobileInventorySaveResult>> saveManualBatch(
    MobileConsumableDraft draft, {
    required int quantity,
    required double initialGrams,
    String? operationUid,
  }) => _enqueueSync(_syncKey(_session), () async {
    final current = await _currentSession();
    final saved = await _saveManualBatch(
      _dao,
      draft,
      operationUid: operationUid,
      quantity: quantity,
      initialGrams: initialGrams,
      ownerAccount: PersonalInventorySyncService.ownerAccountFor(current),
      beforeCommit: () async {
        await _currentSession();
      },
    );
    try {
      await PersonalInventorySyncService(
        dao: _dao,
        api: _api,
      ).synchronize(session: current);
      return saved;
    } catch (_) {
      return saved
          .map((entry) => entry.withPendingSync())
          .toList(growable: false);
    }
  });

  Future<AppAuthSession> _currentSession() async {
    final current = await (ensureSession?.call() ?? Future.value(_session));
    if (_syncKey(current) != _syncKey(_session)) {
      throw const MobileInventoryAccountChangedException();
    }
    return current;
  }

  @override
  Future<MobileStockReceiptResult> receiveFromCard(
    MobileConsumableDraft draft, {
    required String operationUid,
    required String tagUid,
    required String tagType,
    required int quantity,
    required double initialGrams,
  }) async {
    final session = await _currentSession();
    return _enqueueSync(_syncKey(session), () async {
      final current = await _currentSession();
      final receipt = await _dao.addPersonalStockFromRfidCard(
        operationUid: operationUid,
        tagUid: tagUid,
        tagType: tagType,
        template: _stockTemplate(draft, initialGrams),
        quantity: quantity,
        ownerAccount: PersonalInventorySyncService.ownerAccountFor(current),
      );
      try {
        await PersonalInventorySyncService(
          dao: _dao,
          api: _api,
        ).synchronize(session: current);
        return MobileStockReceiptResult(receipt);
      } catch (_) {
        return MobileStockReceiptResult(receipt, syncPending: true);
      }
    });
  }

  @override
  Future<void> rebind({
    required int consumableId,
    required String expectedTagUid,
    required String newTagUid,
    required String newTagType,
  }) => _enqueueSync(_syncKey(_session), () async {
    final session = await _currentSession();
    await PersonalInventorySyncService(
      dao: _dao,
      api: _api,
    ).rebindAndSynchronize(
      session: session,
      consumableId: consumableId,
      expectedTagUid: expectedTagUid,
      newTagUid: newTagUid,
      newTagType: newTagType,
    );
  });

  /// Reconciles local rows created while the user was signed out.
  ///
  /// The desktop sync service owns the snapshot merge and revision retry, so
  /// mobile login uses the same conflict semantics instead of uploading only
  /// the row that triggered the login.
  Future<PersonalInventorySyncResult> synchronizeExisting() async {
    return _enqueueSync(_syncKey(_session), _synchronizeExisting);
  }

  @override
  Future<void> synchronizeAuditRecords() async {
    await synchronizeExisting();
  }

  Future<PersonalInventorySyncResult> _synchronizeExisting() async {
    final session = await _currentSession();
    return PersonalInventorySyncService(
      dao: _dao,
      api: _api,
    ).synchronize(session: session);
  }

  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    // Serialize the local write together with the subsequent snapshot merge.
    // Without this, two quick NFC taps could both observe the same reusable
    // tag cycle and race to update one spool before either PUT reaches the
    // server.
    final session = await _currentSession();
    return _enqueueSync<MobileInventorySaveResult>(_syncKey(session), () async {
      final currentSession = await _currentSession();
      final saved = await _repository.addFromDraft(
        draft,
        tagUid: tagId,
        tagType: tagType,
        ownerAccount: PersonalInventorySyncService.ownerAccountFor(
          currentSession,
        ),
        forceNewCycle: forceNewCycle,
        initialGrams: initialGrams,
        expectedInventoryUid: expectedInventoryUid,
      );
      // Merge the complete owner-scoped local inventory. This prevents a row
      // created while the initial login sync was still running from being
      // omitted by a remote-snapshot-plus-current-row PUT.
      try {
        await PersonalInventorySyncService(
          dao: _dao,
          api: _api,
        ).synchronize(session: currentSession);
      } catch (_) {
        // The local transaction has committed. Return that fact so callers
        // can record the NFC event and avoid repeating a replacement.
        return saved.withPendingSync();
      }
      return saved;
    });
  }

  Future<T> _enqueueSync<T>(String key, Future<T> Function() operation) {
    final previous = _syncTails[key] ?? Future<void>.value();
    final ready = previous.then<void>((_) {}, onError: (_, __) {});
    final completer = Completer<T>();
    late Future<void> tail;
    tail = ready.then<void>((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _syncTails[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_syncTails[key], tail)) _syncTails.remove(key);
      }),
    );
    return completer.future;
  }

  static String _syncKey(AppAuthSession session) {
    return '${session.serverBaseUrl}|${session.user.id}|${session.user.email.toLowerCase()}';
  }
}

class MobileInventoryAccountChangedException implements Exception {
  const MobileInventoryAccountChangedException();

  @override
  String toString() => '登录账号已切换，本次耗材同步已取消';
}

/// Returns whether local work still needs a cloud retry. Do not immediately
/// repeat a failed save's network request; an explicit refresh will retry it.
Future<bool> synchronizeMobileAuditRecords(
  MobileInventorySync sync, {
  required bool syncPending,
}) async {
  if (syncPending || sync is! MobileInventoryAuditSync) return syncPending;
  try {
    await (sync as MobileInventoryAuditSync).synchronizeAuditRecords();
    return false;
  } catch (_) {
    return true;
  }
}

/// Offline fallback used before account login. It preserves the user's work
/// locally without claiming that the record was synced to another device.
class LocalMobileInventorySync
    implements
        MobileInventorySync,
        MobileInventoryRebindSync,
        MobileInventoryBatchSync,
        MobileInventoryStockSync {
  LocalMobileInventorySync(ConsumableDao dao)
    : _repository = MobileInventoryRepository(dao),
      _dao = dao;

  final MobileInventoryRepository _repository;
  final ConsumableDao _dao;

  @override
  Future<List<MobileInventorySaveResult>> saveManualBatch(
    MobileConsumableDraft draft, {
    required int quantity,
    required double initialGrams,
    String? operationUid,
  }) => _saveManualBatch(
    _dao,
    draft,
    operationUid: operationUid,
    quantity: quantity,
    initialGrams: initialGrams,
  );

  @override
  Future<MobileStockReceiptResult> receiveFromCard(
    MobileConsumableDraft draft, {
    required String operationUid,
    required String tagUid,
    required String tagType,
    required int quantity,
    required double initialGrams,
  }) async => MobileStockReceiptResult(
    await _dao.addPersonalStockFromRfidCard(
      operationUid: operationUid,
      tagUid: tagUid,
      tagType: tagType,
      template: _stockTemplate(draft, initialGrams),
      quantity: quantity,
    ),
  );

  @override
  Future<void> rebind({
    required int consumableId,
    required String expectedTagUid,
    required String newTagUid,
    required String newTagType,
  }) async {
    await _dao.rebindPersonalRfidSpool(
      consumableId: consumableId,
      expectedTagUid: expectedTagUid,
      newTagUid: newTagUid,
      newTagType: newTagType,
      ownerAccount: null,
    );
  }

  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    return _repository.addFromDraft(
      draft,
      tagUid: tagId,
      tagType: tagType,
      forceNewCycle: forceNewCycle,
      initialGrams: initialGrams,
      expectedInventoryUid: expectedInventoryUid,
    );
  }
}
