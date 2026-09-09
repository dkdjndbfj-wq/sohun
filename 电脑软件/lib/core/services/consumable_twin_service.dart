import 'dart:async';

import '../../data/database/daos/consumable_twin_dao.dart';
import '../../data/database/database.dart';
import '../../data/database/personal_ams_identity.dart';
import '../../data/database/models/consumable_twin_event.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/models/rfid_tag_identity.dart';

/// 拓竹 RFID 耗材数字孪生服务。
///
/// 负责把 MQTT 推送的 AMS tray 数据转化为数字孪生事件，
/// 管理位置追踪、余量核对和冲突检测。
///
/// 资格判断（硬性）：
/// ```text
/// AmsTray.isBambuOfficialRfid == true
/// OR AmsTray.hasAmsRfidIdentity == true
/// ```
///
/// 对第三方 RFID 载体，后续仍必须通过 trayUuid 查到本地已绑定记录；
/// 未绑定的 UUID 不会自动建档或产生库存事件。
class ConsumableTwinService {
  final ConsumableTwinDao _twinDao;
  final ConsumableDao _consumableDao;
  final AppDatabase _db;

  /// AMS 湿度采样节流：同 AMS 单元数值明显变化或最长 5 分钟一次。
  final Map<String, (int, DateTime)> _lastHumiditySample = {};

  /// 最近一次位置记录，避免相同位置重复写 moved 事件。
  final Map<String, (int?, int?, int?)> _lastLocation = {};

  /// 每台打印机每个槽位最近一次有料快照，用于识别空槽和同槽换卷。
  final Map<String, ({String trayUuid, int amsId, int slot})>
  _lastTrayByPosition = {};

  ConsumableTwinService(AppDatabase db)
    : _db = db,
      _twinDao = ConsumableTwinDao(db),
      _consumableDao = ConsumableDao(db);

  /// 判断 AMS tray 是否有资格进入数字孪生。
  static bool isTwinEligible(AmsTray tray) {
    return tray.isBambuOfficialRfid || tray.hasAmsRfidIdentity;
  }

  /// 处理 MQTT 推送的 AMS trays。
  ///
  /// 对每个有资格的 tray：
  /// 1. 查找或绑定到库存耗材
  /// 2. 记录位置（moved 事件 if 位置变化）
  /// 3. 记录 RFID 观测（rfid_observed 事件 if remain 变化）
  /// 4. 检测耗尽（depleted 事件 if remain == 0）
  /// 5. 节流记录 AMS 湿度
  Future<void> handleAmsTrays({
    required int printerId,
    required String printerSerial,
    required List<AmsTray> trays,
    int? amsHumidity,
    DateTime? amsHumiditySampledAt,
    int? taskId,
    bool adoptObservedRemain = true,
    Set<String> preserveObservedRemainFor = const {},
    String? personalOwnerAccount,
  }) async {
    final resolver = await PersonalAmsIdentityResolver.load(
      _db,
      ownerAccount: personalOwnerAccount,
    );
    final identityCounts = <String, int>{};
    for (final tray in trays.where((t) => t.hasFilament)) {
      final keys = resolver.resolve(tray.normalizedTagUid).collisionKeys;
      for (final identity
          in keys.isNotEmpty
              ? keys
              : {tray.physicalRfidIdentity.toLowerCase()}) {
        if (identity.isNotEmpty) {
          identityCounts.update(identity, (v) => v + 1, ifAbsent: () => 1);
        }
      }
    }
    final seenPositions = trays
        .map((tray) => _positionKey(printerSerial, tray.amsId, tray.slot))
        .toSet();

    // 完整 AMS 快照中槽位直接消失时，也要把上一卷记为 removed。
    final disappeared = _lastTrayByPosition.entries
        .where(
          (entry) =>
              entry.key.startsWith('$printerSerial|') &&
              !seenPositions.contains(entry.key),
        )
        .toList(growable: false);
    for (final entry in disappeared) {
      _lastTrayByPosition.remove(entry.key);
      await _handleRemovedByIdentity(
        trayUuid: entry.value.trayUuid,
        amsId: entry.value.amsId,
        slotIndex: entry.value.slot,
        printerId: printerId,
        printerSerial: printerSerial,
        personalOwnerAccount: personalOwnerAccount,
      );
    }

    for (final tray in trays) {
      final positionKey = _positionKey(printerSerial, tray.amsId, tray.slot);
      if (!tray.hasFilament) {
        // 空槽通常不会携带 trayUuid，先用内存快照，再回查位置账本。
        final previous = _lastTrayByPosition.remove(positionKey);
        final previousUuid = previous?.trayUuid;
        if (previousUuid != null && previousUuid.isNotEmpty) {
          await _handleRemovedByIdentity(
            trayUuid: previousUuid,
            amsId: tray.amsId,
            slotIndex: tray.slot,
            printerId: printerId,
            printerSerial: printerSerial,
            personalOwnerAccount: personalOwnerAccount,
          );
        } else {
          final occupant = await _twinDao.getCurrentOccupantAtPosition(
            printerSerial: printerSerial,
            amsId: tray.amsId,
            slotIndex: tray.slot,
          );
          if (occupant != null) {
            await _handleRemovedByIdentity(
              trayUuid: occupant.trayUuid,
              amsId: tray.amsId,
              slotIndex: tray.slot,
              printerId: printerId,
              printerSerial: printerSerial,
              personalOwnerAccount: personalOwnerAccount,
            );
          }
        }
        continue;
      }
      if (!isTwinEligible(tray)) continue;
      final identityResolution = resolver.resolve(tray.normalizedTagUid);
      if (identityResolution.requiresConfirmation) continue;
      final registeredTagHistory = identityResolution.history;
      final isOfficialRfid =
          tray.isBambuOfficialRfid &&
          !registeredTagHistory.any((b) => b.tagType != 'ams');
      if (!isOfficialRfid &&
          identityResolution.collisionKeys.any(
            (key) => (identityCounts[key] ?? 0) > 1,
          )) {
        continue;
      }

      Consumable? consumable;
      final identities = !isOfficialRfid && tray.normalizedTagUid.isNotEmpty
          ? [identityResolution.tagUid]
          : tray.rfidIdentityCandidates;
      for (final identity in identities) {
        consumable = identityResolution.isPersonalTag
            ? identityResolution.currentConsumableId == null
                  ? null
                  : await _consumableDao.getById(
                      identityResolution.currentConsumableId!,
                    )
            : personalOwnerAccount == null
            ? await _consumableDao.getAnyPersonalByRfidTagUid(identity)
            : await _consumableDao.getPersonalByRfidTagUid(
                identity,
                ownerAccount: personalOwnerAccount,
              );
        if (consumable == null && isOfficialRfid) {
          consumable = personalOwnerAccount == null
              ? await _consumableDao.getByTrayUuid(identity)
              : await _consumableDao.getPersonalByTrayUuid(
                  identity,
                  ownerAccount: personalOwnerAccount,
                );
        }
        if (consumable != null) break;
      }
      if (consumable == null) continue;
      if (personalOwnerAccount != null &&
          !await _consumableDao.ensurePersonalConsumableAccess(
            consumable.id,
            ownerAccount: personalOwnerAccount,
            claimAnonymous: true,
          )) {
        continue;
      }
      final binding = await _consumableDao.getRfidSpoolBindingById(
        consumable.id,
      );
      if (binding?.tagUid.isNotEmpty == true && !binding!.isActive) continue;
      // The reusable tag is a locator. Each concrete inventory UID has its
      // own ledger, including when two successive rolls occupy the same slot.
      final ledgerKey =
          binding?.tagUid.isNotEmpty == true && binding?.tagType != 'ams'
          ? rfidSpoolLedgerKey(consumable.uid)
          : tray.trayUuid;
      if (ledgerKey.isEmpty) continue;

      // 同一 UUID 已出现在另一台打印机/槽位时，当前位置是移动后的唯一事实。
      // 移除旧缓存，避免旧打印机随后上报空槽时把已移动的卷误记为 removed。
      final oldPositions = _lastTrayByPosition.entries
          .where(
            (entry) =>
                entry.key != positionKey && entry.value.trayUuid == ledgerKey,
          )
          .map((entry) => entry.key)
          .toList(growable: false);
      for (final oldPosition in oldPositions) {
        _lastTrayByPosition.remove(oldPosition);
      }

      // 同一槽位出现不同 UUID：先结束上一卷的位置，再登记新卷。
      final previous = _lastTrayByPosition[positionKey];
      if (previous != null && previous.trayUuid != ledgerKey) {
        await _handleRemovedByIdentity(
          trayUuid: previous.trayUuid,
          amsId: previous.amsId,
          slotIndex: previous.slot,
          printerId: printerId,
          printerSerial: printerSerial,
          personalOwnerAccount: personalOwnerAccount,
        );
      } else if (previous == null) {
        final occupant = await _twinDao.getCurrentOccupantAtPosition(
          printerSerial: printerSerial,
          amsId: tray.amsId,
          slotIndex: tray.slot,
        );
        if (occupant != null && occupant.trayUuid != ledgerKey) {
          await _handleRemovedByIdentity(
            trayUuid: occupant.trayUuid,
            amsId: tray.amsId,
            slotIndex: tray.slot,
            printerId: printerId,
            printerSerial: printerSerial,
            personalOwnerAccount: personalOwnerAccount,
          );
        }
      }
      _lastTrayByPosition[positionKey] = (
        trayUuid: ledgerKey,
        amsId: tray.amsId,
        slot: tray.slot,
      );

      // 已绑定：检查位置变化
      await _handleLocationChange(
        consumable: consumable,
        tray: tray,
        ledgerKey: ledgerKey,
        printerId: printerId,
        printerSerial: printerSerial,
      );

      // 记录 RFID 观测
      await _handleRfidObservation(
        consumable: consumable,
        tray: tray,
        ledgerKey: ledgerKey,
        printerId: printerId,
        printerSerial: printerSerial,
        amsHumidity: amsHumidity,
        taskId: taskId,
        adoptObservedRemain:
            adoptObservedRemain &&
            (binding?.tagUid.isNotEmpty != true || isOfficialRfid),
        preserveObservedRemain:
            preserveObservedRemainFor.contains(tray.trayUuid) ||
            preserveObservedRemainFor.contains(tray.physicalRfidIdentity),
      );

      // 检测耗尽
      if (tray.remain == 0) {
        await _twinDao.recordEvent(
          consumableId: consumable.id,
          trayUuid: ledgerKey,
          eventType: TwinEventType.depleted,
          printerId: printerId,
          printerSerial: printerSerial,
          amsId: tray.amsId,
          slotIndex: tray.slot,
          beforeGrams: consumable.remainingGrams,
          afterGrams: 0.0,
          rfidPercent: 0,
          trayWeight: tray.trayWeight.toDouble(),
          observedAt: DateTime.now(),
          source: 'mqtt',
        );
      }
    }
  }

  /// 处理位置变化：同 trayUuid 换槽/换打印机不创建第二卷，只记录 moved 事件。
  Future<void> _handleLocationChange({
    required Consumable consumable,
    required AmsTray tray,
    required String ledgerKey,
    required int printerId,
    required String printerSerial,
  }) async {
    final lastLoc = _lastLocation[ledgerKey];
    final currentLoc = (printerId, tray.amsId, tray.slot);
    if (lastLoc != null && lastLoc == currentLoc) return;

    // 查最近一次位置
    final state = await _twinDao.getCurrentState(ledgerKey);
    if (state != null &&
        state.printerSerial == printerSerial &&
        state.amsId == tray.amsId &&
        state.slotIndex == tray.slot) {
      // 数据库中位置相同，只更新内存缓存
      _lastLocation[ledgerKey] = currentLoc;
      return;
    }

    // 首次绑定写 discovered，之后跨槽/跨设备才写 moved。
    await _twinDao.recordEvent(
      consumableId: consumable.id,
      trayUuid: ledgerKey,
      eventType: state == null ? TwinEventType.discovered : TwinEventType.moved,
      printerId: printerId,
      printerSerial: printerSerial,
      amsId: tray.amsId,
      slotIndex: tray.slot,
      afterGrams: consumable.remainingGrams,
      trayWeight: tray.trayWeight.toDouble(),
      observedAt: DateTime.now(),
      source: 'mqtt',
    );
    _lastLocation[ledgerKey] = currentLoc;
  }

  /// 处理 RFID 观测：remain 变化时记录 rfid_observed 事件。
  ///
  /// remain == 0 是合法耗尽状态，必须同步；remain < 0（-1/未知）不覆盖。
  Future<void> _handleRfidObservation({
    required Consumable consumable,
    required AmsTray tray,
    required String ledgerKey,
    required int printerId,
    required String printerSerial,
    int? amsHumidity,
    int? taskId,
    required bool adoptObservedRemain,
    required bool preserveObservedRemain,
  }) async {
    if (!tray.hasValidRemain) return; // -1/未知值不覆盖

    final rfidGrams = tray.remainingGrams;
    final beforeGrams = consumable.remainingGrams;

    // 节流记录湿度（数值明显变化或最长 5 分钟一次）
    double? sampledHumidity;
    if (amsHumidity != null) {
      final key = '${printerSerial}_${tray.amsId}';
      final last = _lastHumiditySample[key];
      final now = DateTime.now();
      if (last == null ||
          (last.$1 - amsHumidity).abs() >= 5 ||
          now.difference(last.$2).inMinutes >= 5) {
        sampledHumidity = amsHumidity.toDouble();
        _lastHumiditySample[key] = (amsHumidity, now);
      }
    }

    await _twinDao.recordEvent(
      consumableId: consumable.id,
      trayUuid: ledgerKey,
      eventType: TwinEventType.rfidObserved,
      printerId: printerId,
      printerSerial: printerSerial,
      amsId: tray.amsId,
      slotIndex: tray.slot,
      beforeGrams: beforeGrams,
      afterGrams: rfidGrams,
      rfidPercent: tray.remain,
      trayWeight: tray.trayWeight.toDouble(),
      amsHumidity: sampledHumidity,
      observedAt: DateTime.now(),
      source: 'mqtt',
      taskId: taskId,
    );

    // 普通用户的一条耗材记录就是一卷，可直接采用 RFID 余量。农场库存
    // 记录的是仓库整卷数量，物理余量由 PrinterDao 写入对应槽位，绝不能
    // 用 RFID 克数覆盖仓库卷数。
    if (!await _consumableDao.isFarmConsumable(consumable.id) &&
        adoptObservedRemain &&
        !preserveObservedRemain &&
        (rfidGrams - beforeGrams).abs() >= 1.0) {
      await _consumableDao.updateRfidSync(
        consumableId: consumable.id,
        remainingGrams: rfidGrams,
      );
    }
  }

  /// 料盘从 AMS 移除：记录 removed 事件。
  Future<void> _handleRemovedByIdentity({
    required String trayUuid,
    required int amsId,
    required int slotIndex,
    required int printerId,
    required String printerSerial,
    String? personalOwnerAccount,
  }) async {
    if (trayUuid.isEmpty) return;
    final state = await _twinDao.getCurrentState(trayUuid);
    final consumable = state == null
        ? await _consumableDao.getByTrayUuid(trayUuid)
        : await _consumableDao.getById(state.consumableId);
    if (consumable == null) return;
    if (personalOwnerAccount != null &&
        !await _consumableDao.ensurePersonalConsumableAccess(
          consumable.id,
          ownerAccount: personalOwnerAccount,
        )) {
      return;
    }

    await _twinDao.recordEvent(
      consumableId: consumable.id,
      trayUuid: trayUuid,
      eventType: TwinEventType.removed,
      printerId: printerId,
      printerSerial: printerSerial,
      amsId: amsId,
      slotIndex: slotIndex,
      beforeGrams: consumable.remainingGrams,
      observedAt: DateTime.now(),
      source: 'mqtt',
    );

    // 清除位置缓存
    _lastLocation.remove(trayUuid);
  }

  String _positionKey(String printerSerial, int amsId, int slotIndex) =>
      '$printerSerial|$amsId|$slotIndex';

  /// 记录打印估算扣减事件。
  Future<void> recordPrintEstimated({
    required int consumableId,
    required String trayUuid,
    required double beforeGrams,
    required double afterGrams,
    required int taskId,
    int? printerId,
    String? printerSerial,
    double? trayWeight,
  }) async {
    await _twinDao.recordEvent(
      consumableId: consumableId,
      trayUuid: trayUuid,
      eventType: TwinEventType.printEstimated,
      printerId: printerId,
      printerSerial: printerSerial,
      beforeGrams: beforeGrams,
      afterGrams: afterGrams,
      trayWeight: trayWeight,
      observedAt: DateTime.now(),
      source: 'print_settlement',
      taskId: taskId,
    );
  }

  /// 获取某卷耗材的完整时间线。
  Future<List<ConsumableTwinEvent>> getTimeline(String trayUuid) {
    return _twinDao.getTimeline(trayUuid);
  }

  /// 获取当前状态。
  Future<ConsumableTwinState?> getCurrentState(String trayUuid) {
    return _twinDao.getCurrentState(trayUuid);
  }

  /// 获取所有待核对差异。
  Future<List<TwinReconciliation>> getPendingReconciliations() {
    return _twinDao.getPendingReconciliations();
  }

  /// 用户核对修正。
  Future<void> reconcile({
    required int consumableId,
    required String trayUuid,
    required bool adoptRfid,
    required double rfidObservedGrams,
    required double localEstimatedGrams,
    double? trayWeight,
    int? printerId,
    String? printerSerial,
    int? amsId,
    int? slotIndex,
  }) async {
    await _twinDao.reconcile(
      consumableId: consumableId,
      trayUuid: trayUuid,
      adoptRfid: adoptRfid,
      rfidObservedGrams: rfidObservedGrams,
      localEstimatedGrams: localEstimatedGrams,
      trayWeight: trayWeight,
      printerId: printerId,
      printerSerial: printerSerial,
      amsId: amsId,
      slotIndex: slotIndex,
    );

    // 更新普通用户库存。农场 RFID 核对作用于槽位独立料卷，仓库卷数
    // 不能在这里被单卷克数覆盖。
    final finalGrams = adoptRfid ? rfidObservedGrams : localEstimatedGrams;
    final consumable = await _consumableDao.getById(consumableId);
    if (consumable != null &&
        !await _consumableDao.isFarmConsumable(consumableId)) {
      await _consumableDao.updateRfidSync(
        consumableId: consumableId,
        remainingGrams: finalGrams,
      );
    }
  }

  /// 清理内存缓存（断开连接时调用）。
  void clearCache() {
    _lastHumiditySample.clear();
    _lastLocation.clear();
    _lastTrayByPosition.clear();
  }
}
