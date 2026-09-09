import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/spool_change_detector.dart';
import '../data/database/daos/consumable_dao.dart';
import '../data/database/daos/printer_dao.dart';
import '../data/database/personal_ams_identity.dart';
import '../data/database/models/printer_feed_models.dart';
import '../data/external/printer/bambu_printer_models.dart';
import '../data/models/rfid_tag_identity.dart';
import 'consumable_provider.dart';

/// Only physical feeds without a complete official RFID identity need user
/// configuration. External feeds never have AMS RFID and therefore always
/// remain interactive.
bool spoolChangeRequiresConfiguration(SpoolChangeObservation event) {
  if (event.isRemoval) return !event.farmMode;
  return event.isManual || event.isExternal || !event.hasRfidIdentity;
}

/// Prompts for unidentified feeds that were already loaded when monitoring
/// started. Existing bindings suppress the prompt, so reconnecting does not
/// repeatedly ask about configured spools.
Future<void> enqueueUnboundFeedConfiguration({
  required SpoolChangeQueueNotifier queue,
  required PrinterDao printerDao,
  required int printerId,
  required String printerSerial,
  required String printerLabel,
  required BambuPrinterStatus status,
  bool farmMode = false,
  String personalOwnerAccount = '',
}) async {
  final now = DateTime.now();
  final candidates = <SpoolChangeObservation>[];
  final identityResolver = farmMode
      ? null
      : await PersonalAmsIdentityResolver.load(
          printerDao.attachedDatabase,
          ownerAccount: personalOwnerAccount,
        );
  final presentUnits = (status.amsUnits ?? const <AmsUnit>[])
      .where((unit) => unit.isPresent)
      .toList(growable: false);
  final unitFacts = <int, ({int ordinal, AmsUnitType type})>{
    for (var index = 0; index < presentUnits.length; index++)
      presentUnits[index].id: (
        ordinal: index + 1,
        type: presentUnits[index].type,
      ),
  };
  for (final tray in status.amsTrays ?? const <AmsTray>[]) {
    if (!tray.hasFilament) continue;
    final identity = identityResolver?.resolve(tray.normalizedTagUid);
    final localHoldState = farmMode
        ? ChannelRollHoldState.loaded
        : await printerDao.getChannelRollHoldState(printerId, tray.globalSlot);
    final heldBindings = <RfidSpoolBinding>[];
    if (!farmMode && identity != null) {
      for (final binding in identity.history.where(
        (binding) => binding.isActive || binding.status == 'replaced',
      )) {
        if (localHoldState == ChannelRollHoldState.awaitingSelection ||
            await printerDao.isPersonalSpoolAwaitingSelection(
              binding.consumableId,
            )) {
          heldBindings.add(binding);
        }
      }
    }
    if (!farmMode && localHoldState == ChannelRollHoldState.awaitingSelection) {
      final heldId = await printerDao.getConsumableIdByChannel(
        printerId,
        tray.globalSlot,
      );
      final heldBinding = heldId == null
          ? null
          : await printerDao.attachedDatabase.consumableDao
                .getRfidSpoolBindingById(heldId);
      final reported = normalizeRfidTagUid(tray.normalizedTagUid);
      final heldTag = normalizeRfidTagUid(heldBinding?.tagUid ?? '');
      final sameReusableCard =
          heldBinding?.isActive == true &&
          isConsumableRfidTagType(heldBinding?.tagType) &&
          (rfidTagUidEquals(reported, heldTag) ||
              (reported.length == 16 &&
                  heldTag.length == 8 &&
                  reported.startsWith(heldTag)));
      if (heldId != null &&
          heldBinding != null &&
          sameReusableCard &&
          await printerDao.attachedDatabase.consumableDao
              .ensurePersonalConsumableAccess(
                heldId,
                ownerAccount: personalOwnerAccount,
              ) &&
          !heldBindings.any((binding) => binding.consumableId == heldId)) {
        heldBindings.add(heldBinding);
      }
    }
    final requiresHeldSelection =
        localHoldState == ChannelRollHoldState.awaitingSelection ||
        heldBindings.isNotEmpty;
    final bindingCandidates = <int, RfidSpoolBinding>{
      for (final binding in identity?.candidates ?? const <RfidSpoolBinding>[])
        if (binding.isActive || binding.status == 'replaced')
          binding.consumableId: binding,
      if (requiresHeldSelection)
        for (final binding in heldBindings) binding.consumableId: binding,
    }.values.toList(growable: false);
    final stockCandidates = identity?.stockCandidates ?? const [];
    final fact = unitFacts[tray.amsId];
    final event = SpoolChangeObservation(
      printerSerial: printerSerial,
      printerLabel: printerLabel,
      printerId: printerId,
      channelIndex: tray.globalSlot,
      previous: null,
      current: tray,
      detectedAt: now,
      amsOrdinal: fact?.ordinal,
      amsType: fact?.type,
      farmMode: farmMode,
      requiresRfidConfirmation:
          identity?.requiresConfirmation == true || requiresHeldSelection,
      rfidCandidateUids: {
        for (final b in bindingCandidates) b.consumableId: b.tagUid,
        for (final stock in stockCandidates) stock.consumableId: stock.tagUid,
      },
      rfidCandidateInventoryUids: {
        for (final b in bindingCandidates) b.consumableId: b.inventoryUid,
        for (final stock in stockCandidates)
          stock.consumableId: stock.inventoryUid,
      },
      rfidCandidateIds: {
        for (final b in bindingCandidates) b.consumableId,
        for (final stock in stockCandidates) stock.consumableId,
      }.toList(growable: false),
      rfidStockCandidates: {
        for (final stock in stockCandidates)
          stock.consumableId: SpoolRfidStockCandidate(
            inventoryUid: stock.inventoryUid,
            tagUid: stock.tagUid,
            tagType: stock.tagType,
            ownerAccount: stock.ownerAccount,
          ),
      },
      personalOwnerAccount: personalOwnerAccount,
    );
    if (!farmMode && !spoolChangeRequiresConfiguration(event)) continue;
    if (identity?.requiresConfirmation == true ||
        requiresHeldSelection ||
        await printerDao.getConsumableIdByChannel(printerId, tray.globalSlot) ==
            null) {
      candidates.add(event);
    }
  }

  final sensors = externalFeedSensorReadings(
    sensors: status.extruderFilamentPresent,
    trayNow: status.trayNow,
    hwSwitchState: status.hwSwitchState,
    units: status.amsUnits,
    trays: status.amsTrays,
  );
  final metadata = <int, AmsTray>{
    for (final tray in status.externalTrays ?? const <AmsTray>[])
      tray.slot: tray,
  };
  for (var input = 0; input < sensors.length; input++) {
    if (sensors[input] != true) continue;
    final channelIndex = input == 1
        ? externalFeedLeftChannel
        : externalFeedRightChannel;
    if (await printerDao.getConsumableIdByChannel(printerId, channelIndex) !=
        null) {
      continue;
    }
    final source = metadata[input];
    candidates.add(
      SpoolChangeObservation(
        printerSerial: printerSerial,
        printerLabel: printerLabel,
        printerId: printerId,
        channelIndex: channelIndex,
        previous: null,
        current: AmsTray(
          amsId: -1,
          slot: input,
          trayType: source?.trayType ?? '',
          trayColor: source?.trayColor ?? '',
          trayWeight: source?.trayWeight ?? 0,
          traySubBrands: source?.traySubBrands ?? '',
          trayInfoIdx: source?.trayInfoIdx ?? '',
          hasFilament: true,
          trayTag: 'external',
        ),
        detectedAt: now,
        isExternal: true,
        externalInputCount: sensors.length,
        externalInputIndex: input,
        farmMode: farmMode,
        personalOwnerAccount: personalOwnerAccount,
      ),
    );
  }

  // On startup/reconnect the detector may not have seen the true→empty
  // transition. For personal inventory, reconcile explicit empty telemetry
  // against still-bound channels so a repair/removal is not silently missed.
  // Missing tray entries are deliberately excluded: they can be partial AMS
  // payloads while a unit reconnects and are not reliable empty signals.
  if (!farmMode &&
      ((status.amsTrays?.isEmpty == true &&
              detectedAmsState(status) == AmsDetectionState.absent) ||
          (status.amsTrays?.any(
                (tray) => tray.hasFilamentObservation && !tray.hasFilament,
              ) ??
              false) ||
          sensors.any((present) => present == false))) {
    final printer = await printerDao.getByIdWithChannels(printerId);
    final byChannel = {
      for (final item in printer?.channels ?? const <ChannelWithConsumable>[])
        item.channel.channelIndex: item,
    };
    for (final tray in status.amsTrays ?? const <AmsTray>[]) {
      if (!tray.hasFilamentObservation || tray.hasFilament) continue;
      final bound = byChannel[tray.globalSlot];
      if (bound?.consumable == null || bound!.farmRollPaused) continue;
      if (!await printerDao.attachedDatabase.consumableDao
          .ensurePersonalConsumableAccess(
            bound.consumable!.id,
            ownerAccount: personalOwnerAccount,
          )) {
        continue;
      }
      candidates.add(
        SpoolChangeObservation(
          printerSerial: printerSerial,
          printerLabel: printerLabel,
          printerId: printerId,
          channelIndex: tray.globalSlot,
          previous: _asLoadedTray(tray),
          current: null,
          detectedAt: now,
          amsOrdinal: unitFacts[tray.amsId]?.ordinal,
          amsType: unitFacts[tray.amsId]?.type,
          kind: SpoolChangeKind.removed,
          personalOwnerAccount: personalOwnerAccount,
        ),
      );
    }
    if (status.amsTrays?.isEmpty == true &&
        detectedAmsState(status) == AmsDetectionState.absent) {
      for (final item in byChannel.values) {
        if (isExternalFeedChannel(item.channel.channelIndex) ||
            item.consumable == null ||
            item.farmRollPaused) {
          continue;
        }
        if (!await printerDao.attachedDatabase.consumableDao
            .ensurePersonalConsumableAccess(
              item.consumable!.id,
              ownerAccount: personalOwnerAccount,
            )) {
          continue;
        }
        candidates.add(
          SpoolChangeObservation(
            printerSerial: printerSerial,
            printerLabel: printerLabel,
            printerId: printerId,
            channelIndex: item.channel.channelIndex,
            previous: null,
            current: null,
            detectedAt: now,
            kind: SpoolChangeKind.removed,
            personalOwnerAccount: personalOwnerAccount,
          ),
        );
      }
    }
    for (var input = 0; input < sensors.length; input++) {
      if (sensors[input] != false) continue;
      final channelIndex = input == 1
          ? externalFeedLeftChannel
          : externalFeedRightChannel;
      final bound = byChannel[channelIndex];
      if (bound?.consumable == null || bound!.farmRollPaused) continue;
      if (!await printerDao.attachedDatabase.consumableDao
          .ensurePersonalConsumableAccess(
            bound.consumable!.id,
            ownerAccount: personalOwnerAccount,
          )) {
        continue;
      }
      final source = metadata[input];
      candidates.add(
        SpoolChangeObservation(
          printerSerial: printerSerial,
          printerLabel: printerLabel,
          printerId: printerId,
          channelIndex: channelIndex,
          previous: AmsTray(
            amsId: -1,
            slot: input,
            trayType: source?.trayType ?? '',
            trayColor: source?.trayColor ?? '',
            remain: source?.remain ?? -1,
            trayWeight: source?.trayWeight ?? 0,
            traySubBrands: source?.traySubBrands ?? '',
            trayInfoIdx: source?.trayInfoIdx ?? '',
            hasFilament: true,
            trayTag: 'external',
          ),
          current: null,
          detectedAt: now,
          isExternal: true,
          externalInputCount: sensors.length,
          externalInputIndex: input,
          kind: SpoolChangeKind.removed,
          personalOwnerAccount: personalOwnerAccount,
        ),
      );
    }
  }
  queue.observeAll(candidates);
}

AmsTray _asLoadedTray(AmsTray tray) {
  return AmsTray(
    amsId: tray.amsId,
    slot: tray.slot,
    mixedAmsLite: tray.mixedAmsLite,
    tagUid: tray.tagUid,
    trayType: tray.trayType,
    trayColor: tray.trayColor,
    remain: tray.remain,
    trayWeight: tray.trayWeight,
    traySubBrands: tray.traySubBrands,
    trayInfoIdx: tray.trayInfoIdx,
    hasFilament: true,
    trayTag: tray.trayTag,
    trayUuid: tray.trayUuid,
    nozzleTempMin: tray.nozzleTempMin,
    nozzleTempMax: tray.nozzleTempMax,
    dryingTemp: tray.dryingTemp,
    dryingTime: tray.dryingTime,
  );
}

/// Pending spool replacements are global so a prompt can be shown even when
/// the changed printer is not the currently selected printer.
class SpoolChangeQueueNotifier
    extends StateNotifier<List<SpoolChangeObservation>> {
  SpoolChangeQueueNotifier() : super(const []);

  final Map<String, DateTime> _recentKeys = {};
  final Map<String, DateTime> _recentLocations = {};
  final Map<String, DateTime> _snoozedKeys = {};
  String? _activePersonalOwner;

  void usePersonalOwner(String ownerAccount) {
    final normalized = ownerAccount.trim().toLowerCase();
    if (_activePersonalOwner == normalized) return;
    _activePersonalOwner = normalized;
    _recentKeys.clear();
    _recentLocations.clear();
    _snoozedKeys.clear();
    state = state
        .where(
          (event) => event.farmMode || event.personalOwnerAccount == normalized,
        )
        .toList(growable: false);
  }

  void enqueue(SpoolChangeObservation event, {String? personalOwnerAccount}) {
    if (!event.farmMode && personalOwnerAccount != null) {
      event = event.forPersonalOwner(personalOwnerAccount);
    }
    if (!event.farmMode &&
        _activePersonalOwner != null &&
        event.personalOwnerAccount != _activePersonalOwner) {
      return;
    }
    final now = DateTime.now();
    _recentKeys.removeWhere(
      (_, time) => now.difference(time) > const Duration(seconds: 8),
    );
    _recentLocations.removeWhere(
      (_, time) => now.difference(time) > const Duration(seconds: 8),
    );
    _snoozedKeys.removeWhere((_, time) => time.isBefore(now));
    final snoozeKey = '${event.locationKey}:${event.kind.name}';
    if (_snoozedKeys[snoozeKey]?.isAfter(now) == true) return;
    if (event.kind == SpoolChangeKind.inserted) {
      _snoozedKeys.remove(
        '${event.locationKey}:${SpoolChangeKind.removed.name}',
      );
    }
    final sameLocation = state.indexWhere(
      (item) =>
          item.printerSerial == event.printerSerial &&
          item.channelIndex == event.channelIndex &&
          item.farmMode == event.farmMode &&
          (item.farmMode ||
              item.personalOwnerAccount == event.personalOwnerAccount) &&
          item.isExternal == event.isExternal,
    );
    if (sameLocation >= 0) {
      final pending = state[sameLocation];
      final keepConfirmation =
          pending.requiresRfidConfirmation &&
          !event.isRemoval &&
          SpoolChangeObservation.trayIdentity(pending.current) ==
              SpoolChangeObservation.trayIdentity(event.current);
      final merged = SpoolChangeObservation(
        printerSerial: event.printerSerial,
        printerLabel: event.printerLabel,
        printerId: event.printerId ?? pending.printerId,
        channelIndex: event.channelIndex,
        previous: pending.previous ?? event.previous,
        current: event.isRemoval ? null : event.current ?? pending.current,
        detectedAt: pending.detectedAt,
        amsOrdinal: event.amsOrdinal ?? pending.amsOrdinal,
        amsType: event.amsType ?? pending.amsType,
        isManual: pending.isManual && event.isManual,
        isExternal: event.isExternal,
        farmMode: event.farmMode,
        externalInputCount: event.externalInputCount,
        externalInputIndex: event.externalInputIndex,
        kind: event.kind,
        requiresRfidConfirmation:
            event.requiresRfidConfirmation || keepConfirmation,
        rfidCandidateIds: event.requiresRfidConfirmation
            ? event.rfidCandidateIds
            : keepConfirmation
            ? pending.rfidCandidateIds
            : const [],
        rfidCandidateUids: event.requiresRfidConfirmation
            ? event.rfidCandidateUids
            : keepConfirmation
            ? pending.rfidCandidateUids
            : const {},
        rfidCandidateInventoryUids: event.requiresRfidConfirmation
            ? event.rfidCandidateInventoryUids
            : keepConfirmation
            ? pending.rfidCandidateInventoryUids
            : const {},
        rfidStockCandidates: event.requiresRfidConfirmation
            ? event.rfidStockCandidates
            : keepConfirmation
            ? pending.rfidStockCandidates
            : const {},
        personalOwnerAccount: event.personalOwnerAccount,
      );
      state = [
        for (var index = 0; index < state.length; index++)
          if (index == sameLocation) merged else state[index],
      ];
      _recentKeys[event.dedupeKey] = now;
      _recentLocations['${event.locationKey}:${event.kind.name}'] = now;
      return;
    }
    final recentLocationKey = '${event.locationKey}:${event.kind.name}';
    if (_recentLocations[recentLocationKey] != null) return;
    if (_recentKeys[event.dedupeKey] != null ||
        state.any((item) => item.dedupeKey == event.dedupeKey)) {
      return;
    }
    _recentKeys[event.dedupeKey] = now;
    _recentLocations[recentLocationKey] = now;
    state = [...state, event];
  }

  void enqueueAll(
    Iterable<SpoolChangeObservation> events, {
    String? personalOwnerAccount,
  }) {
    for (final event in events) {
      enqueue(event, personalOwnerAccount: personalOwnerAccount);
    }
  }

  /// Reconciles raw detector facts with the user-facing configuration queue.
  ///
  /// A tray can first arrive without metadata and receive its official RFID a
  /// moment later. In that case the complete observation removes the pending
  /// prompt for the same location instead of leaving a stale dialog behind.
  void observeAll(
    Iterable<SpoolChangeObservation> events, {
    String? personalOwnerAccount,
  }) {
    for (final rawEvent in events) {
      final event = !rawEvent.farmMode && personalOwnerAccount != null
          ? rawEvent.forPersonalOwner(personalOwnerAccount)
          : rawEvent;
      if (spoolChangeRequiresConfiguration(event)) {
        enqueue(event);
      } else {
        // Template metadata can arrive after the unresolved physical UID.
        // Only the database identity check/user action can settle that case.
        if (state.any(
          (pending) =>
              pending.locationKey == event.locationKey &&
              pending.requiresRfidConfirmation &&
              SpoolChangeObservation.trayIdentity(pending.current) ==
                  SpoolChangeObservation.trayIdentity(event.current),
        )) {
          continue;
        }
        resolveLocation(event.locationKey);
      }
    }
  }

  /// Returns only events belonging to one inventory domain. The queue remains
  /// process-wide so printer listeners do not need to be torn down when the
  /// user switches modes, but each dialog consumes its own domain only.
  List<SpoolChangeObservation> pendingForMode(bool farmMode) {
    return state
        .where((event) => event.farmMode == farmMode)
        .toList(growable: false);
  }

  void resolveLocation(String locationKey) {
    state = state
        .where((item) => item.locationKey != locationKey)
        .toList(growable: false);
  }

  void resolve(String eventId) {
    state = state.where((item) => item.eventId != eventId).toList();
  }

  void snooze(SpoolChangeObservation event) {
    _snoozedKeys['${event.locationKey}:${event.kind.name}'] = DateTime.now()
        .add(const Duration(minutes: 10));
    resolve(event.eventId);
  }

  void clear() {
    _recentKeys.clear();
    _recentLocations.clear();
    _snoozedKeys.clear();
    state = const [];
  }
}

final spoolChangeQueueProvider =
    StateNotifierProvider<
      SpoolChangeQueueNotifier,
      List<SpoolChangeObservation>
    >((ref) {
      final notifier = SpoolChangeQueueNotifier();
      ref.listen<PersonalInventoryAccountScope>(
        personalInventoryAccountScopeProvider,
        (_, scope) {
          if (scope.enforce) notifier.usePersonalOwner(scope.ownerAccount);
        },
        fireImmediately: true,
      );
      return notifier;
    });
