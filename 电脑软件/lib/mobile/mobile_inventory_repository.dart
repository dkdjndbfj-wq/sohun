import 'package:uuid/uuid.dart';

import '../data/database/database.dart';
import '../data/models/personal_inventory_sync.dart';
import '../data/models/rfid_tag_identity.dart';
import 'rfid_mobile_models.dart';
import 'rfid_native_bridge.dart';

/// Persists a mobile RFID entry using the desktop personal-inventory DAO.
///
/// CUID/FUID is a reusable physical tag identity. Every replacement roll gets
/// a new inventory UID, while the same normalized tag UID and an incrementing
/// cycle keep the complete chain queryable on both phone and desktop.
class MobileInventoryRepository {
  MobileInventoryRepository(this._dao);

  final ConsumableDao _dao;

  Future<MobileInventorySaveResult> addFromDraft(
    MobileConsumableDraft draft, {
    String? tagUid,
    String? tagType,
    String? ownerAccount,
    DateTime? now,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    if (!initialGrams.isFinite || initialGrams <= 0 || initialGrams > 100000) {
      throw ArgumentError.value(
        initialGrams,
        'initialGrams',
        '新耗材卷重量必须在 0 到 100000 g 之间',
      );
    }
    final timestamp = now ?? DateTime.now();
    final normalizedTagUid = tagUid == null
        ? null
        : normalizeRfidTagUid(tagUid);
    final normalizedOwner = _normalizeOwner(ownerAccount);
    final requestedType = tagType?.trim();
    if (requestedType?.isNotEmpty == true &&
        !isConsumableRfidTagType(requestedType)) {
      throw const MobileInventoryTagTypeException(
        '耗材标签只支持已确认的 CUID/FUID；NTAG213 等标签不能登记或更新耗材',
      );
    }

    return _dao.transaction(() async {
      final history = normalizedTagUid?.isNotEmpty == true
          ? await _dao.getPersonalRfidSpoolHistory(
              normalizedTagUid!,
              ownerAccount: normalizedOwner,
            )
          : const <RfidSpoolBinding>[];

      // A copied UID is not global ownership proof. Signed-in accounts keep
      // separate spool rows; anonymous scans must not adopt an account's row.
      if (normalizedOwner == null && normalizedTagUid?.isNotEmpty == true) {
        final foreign = await _dao.getAnyPersonalRfidSpoolHistory(
          normalizedTagUid!,
        );
        for (final binding in foreign) {
          final owner = await _dao.getOwnerAccount(binding.consumableId);
          if (owner?.trim().isNotEmpty == true &&
              !_sameOwner(owner!, normalizedOwner ?? '')) {
            throw const MobileInventoryTagOwnershipException(
              '该 RFID 标签已绑定其他 sohun 账号，不能写入当前账号',
            );
          }
        }
      }

      var latestBinding = history.isEmpty ? null : history.first;
      var existing = latestBinding == null
          ? null
          : await _dao.getById(latestBinding.consumableId);
      if (existing == null && normalizedTagUid?.isNotEmpty == true) {
        final legacy = await _dao.getPersonalByRfidTagUid(
          normalizedTagUid!,
          ownerAccount: normalizedOwner,
        );
        if (legacy != null) {
          final owner = await _dao.getOwnerAccount(legacy.id);
          if (owner?.trim().isNotEmpty == true &&
              !_sameOwner(owner!, normalizedOwner ?? '')) {
            throw const MobileInventoryTagOwnershipException('该标签属于其他账号');
          }
          existing = legacy;
          latestBinding = await _dao.getRfidSpoolBindingById(legacy.id);
        }
      }
      if (expectedInventoryUid != null &&
          existing?.uid != expectedInventoryUid) {
        throw StateError('标签已换到另一卷，请刷新库存后重试');
      }
      String? consumableTagType;
      if (normalizedTagUid?.isNotEmpty == true) {
        final storedType = latestBinding?.tagType;
        if (storedType != null &&
            !isConsumableRfidTagType(storedType) &&
            !requiresConsumableRfidTagTypeConfirmation(storedType)) {
          throw const MobileInventoryTagTypeException(
            '该历史标签不是 CUID/FUID，不能用于耗材登记、重写或换卷；原记录已保留',
          );
        }
        final resolvedType = isConsumableRfidTagType(requestedType)
            ? requestedType
            : isConsumableRfidTagType(storedType)
            ? storedType
            : null;
        if (resolvedType == null) {
          throw const MobileInventoryTagTypeException(
            '无法确认标签卡型，请重新扫描并确认 CUID 或 FUID；不会根据 UID 猜测类型',
          );
        }
        consumableTagType = resolvedType.trim().toUpperCase();
      }
      final candidates = history.where((b) => b.status != 'retired').toList();
      if (candidates.length > 1 &&
          (candidates[0].cycle == candidates[1].cycle ||
              history.where((b) => b.isActive).length > 1)) {
        throw StateError('该标签有多个当前卷，无法确认实际耗材，请先核对周期');
      }
      if (forceNewCycle) {
        if (existing == null) throw StateError('请先登记当前标签对应的耗材卷');
        // A migrated legacy row may still only carry tray_uuid.
        if (latestBinding?.tagUid.isNotEmpty != true ||
            latestBinding?.tagType != consumableTagType) {
          await _dao.setRfidSpoolBinding(
            existing.id,
            tagUid: normalizedTagUid,
            tagType: consumableTagType,
            cycle: latestBinding?.cycle ?? 1,
            status:
                latestBinding?.status ??
                (existing.remainingGrams <= 0 ? 'depleted' : 'active'),
            previousInventoryUid: latestBinding?.previousInventoryUid,
          );
        }
        final next = await _dao.replacePersonalRfidSpool(
          consumableId: existing.id,
          initialGrams: initialGrams,
          now: timestamp,
        );
        return MobileInventorySaveResult(
          inventoryUid: next.inventoryUid,
          rfidTagUid: next.tagUid,
          rfidTagCycle: next.cycle,
          createdNewCycle: true,
        );
      }

      final inventoryUid = existing?.uid.trim().isNotEmpty == true
          ? existing!.uid
          : const Uuid().v4();
      final cycle = latestBinding?.cycle ?? 1;
      final status = latestBinding != null && !latestBinding.isActive
          ? latestBinding.status
          : existing != null && existing.remainingGrams <= 0
          ? 'depleted'
          : 'active';
      // Reading an empty/historical label does not prove a new roll exists.
      // Keep it unchanged until the user explicitly confirms a replacement.
      if (existing != null && status != 'active') {
        await _dao.setRfidSpoolBinding(
          existing.id,
          tagUid: normalizedTagUid,
          tagType: consumableTagType,
          cycle: cycle,
          status: status,
          previousInventoryUid: latestBinding?.previousInventoryUid,
        );
        return MobileInventorySaveResult(
          inventoryUid: existing.uid,
          rfidTagUid: normalizedTagUid,
          rfidTagCycle: cycle,
          requiresReplacement: true,
        );
      }
      final colorName = draft.colorName.trim();
      final record = PersonalInventoryRecord(
        uid: inventoryUid,
        manufacturer: draft.brand.trim(),
        model: draft.model.trim(),
        materialType: draft.model.trim(),
        colorHex: draft.colorHex,
        colorName: colorName.isEmpty ? null : colorName,
        // Rewriting metadata for an active spool preserves its exact stock.
        totalGrams: existing?.totalGrams ?? initialGrams,
        remainingGrams: existing?.remainingGrams ?? initialGrams,
        batchNo: existing?.batchNo,
        purchaseDate: existing?.purchaseDate ?? timestamp,
        note: existing?.note,
        createdAt: existing?.createdAt ?? timestamp,
        updatedAt: timestamp,
        density: existing?.density,
        recommendedNozzleTemp: existing?.recommendedNozzleTemp,
        hygroscopicity: existing?.hygroscopicity,
        trayUuid: existing?.trayUuid,
        rfidSyncedAt: normalizedTagUid?.isNotEmpty == true
            ? timestamp.millisecondsSinceEpoch
            : existing?.rfidSyncedAt,
        rfidTagUid: normalizedTagUid?.isNotEmpty == true
            ? normalizedTagUid
            : null,
        rfidTagType: consumableTagType,
        rfidTagCycle: cycle,
        lifecycleStatus: status,
        // Keep the predecessor pointer when rewriting an already active
        // cycle; otherwise a normal metadata refresh would sever the chain.
        previousConsumableUid: latestBinding?.previousInventoryUid,
        rfidTagHistory: latestBinding?.tagHistory ?? const [],
      );
      final id = await _dao.upsertPersonalInventoryRecord(
        record,
        ownerAccount: normalizedOwner,
      );
      final saved = await _dao.getById(id);
      if (saved == null) throw StateError('耗材写入本机库存后无法读取');
      return MobileInventorySaveResult(
        inventoryUid: saved.uid,
        rfidTagUid: normalizedTagUid?.isNotEmpty == true
            ? normalizedTagUid
            : null,
        rfidTagCycle: cycle,
        createdNewCycle: false,
      );
    });
  }

  static String? normalizeTagUid(String? value) {
    final normalized = value == null ? '' : normalizeRfidTagUid(value);
    return normalized.isEmpty ? null : normalized;
  }

  static String? _normalizeOwner(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static bool _sameOwner(String left, String right) =>
      left.trim().toLowerCase() == right.trim().toLowerCase();
}

class MobileInventoryTagOwnershipException implements Exception {
  const MobileInventoryTagOwnershipException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MobileInventoryTagTypeException implements Exception {
  const MobileInventoryTagTypeException(this.message);

  final String message;

  @override
  String toString() => message;
}
