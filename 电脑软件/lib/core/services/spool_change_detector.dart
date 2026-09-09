import '../../data/database/models/printer_feed_models.dart';
import '../../data/external/printer/bambu_printer_models.dart';

enum SpoolChangeKind { inserted, removed, manual }

/// An unbound physical spool that was previously received from a reusable
/// CUID/FUID material card. The inventory UID identifies the concrete spool;
/// the card UID remains reusable and is only attached after explicit choice.
class SpoolRfidStockCandidate {
  const SpoolRfidStockCandidate({
    required this.inventoryUid,
    required this.tagUid,
    required this.tagType,
    required this.ownerAccount,
  });

  final String inventoryUid;
  final String tagUid;
  final String tagType;
  final String ownerAccount;
}

/// A physical spool replacement observed on one printer slot.
///
/// `current` is null for the manual workflow used by printers that expose no
/// AMS/RFID telemetry. Automatic observations always contain the current tray.
class SpoolChangeObservation {
  SpoolChangeObservation({
    required this.printerSerial,
    required this.printerLabel,
    required this.channelIndex,
    required this.previous,
    required this.current,
    required this.detectedAt,
    this.printerId,
    this.amsOrdinal,
    this.amsType,
    this.isManual = false,
    this.isExternal = false,
    this.farmMode = false,
    this.externalInputCount = 1,
    this.externalInputIndex = 0,
    this.kind = SpoolChangeKind.inserted,
    this.requiresRfidConfirmation = false,
    this.rfidCandidateIds = const [],
    this.rfidCandidateUids = const {},
    this.rfidCandidateInventoryUids = const {},
    this.rfidStockCandidates = const {},
    this.personalOwnerAccount = '',
  });

  final String printerSerial;
  final String printerLabel;
  final int channelIndex;
  final AmsTray? previous;
  final AmsTray? current;
  final DateTime detectedAt;
  final int? printerId;
  final int? amsOrdinal;
  final AmsUnitType? amsType;
  final bool isManual;
  final bool isExternal;
  final bool farmMode;
  final int externalInputCount;
  final int externalInputIndex;
  final SpoolChangeKind kind;
  final bool requiresRfidConfirmation;
  final List<int> rfidCandidateIds;
  final Map<int, String> rfidCandidateUids;
  final Map<int, String> rfidCandidateInventoryUids;
  final Map<int, SpoolRfidStockCandidate> rfidStockCandidates;
  final String personalOwnerAccount;

  bool get isRemoval => kind == SpoolChangeKind.removed;

  String get eventId =>
      '${farmMode ? 'farm' : 'personal:$personalOwnerAccount'}:$printerSerial:$channelIndex:${detectedAt.microsecondsSinceEpoch}';

  String get locationKey =>
      '${farmMode ? 'farm' : 'personal:$personalOwnerAccount'}:$printerSerial:$channelIndex:${isExternal ? 'external' : 'ams'}';

  /// Used to collapse duplicate MQTT listeners for the same physical change.
  String get dedupeKey =>
      '${farmMode ? 'farm' : 'personal:$personalOwnerAccount'}:$printerSerial:$channelIndex:${kind.name}:${trayIdentity(current)}';

  SpoolChangeObservation forPersonalOwner(String ownerAccount) {
    if (farmMode) return this;
    return SpoolChangeObservation(
      printerSerial: printerSerial,
      printerLabel: printerLabel,
      printerId: printerId,
      channelIndex: channelIndex,
      previous: previous,
      current: current,
      detectedAt: detectedAt,
      amsOrdinal: amsOrdinal,
      amsType: amsType,
      isManual: isManual,
      isExternal: isExternal,
      farmMode: farmMode,
      externalInputCount: externalInputCount,
      externalInputIndex: externalInputIndex,
      kind: kind,
      requiresRfidConfirmation: requiresRfidConfirmation,
      rfidCandidateIds: rfidCandidateIds,
      rfidCandidateUids: rfidCandidateUids,
      rfidCandidateInventoryUids: rfidCandidateInventoryUids,
      rfidStockCandidates: rfidStockCandidates,
      personalOwnerAccount: ownerAccount.trim().toLowerCase(),
    );
  }

  bool get hasRfidIdentity =>
      !requiresRfidConfirmation && current?.isBambuOfficialRfid == true;

  String get slotLabel {
    if (isExternal) {
      if (externalInputCount <= 1) return '外挂料位';
      return externalInputIndex == 1 ? '外挂料位 L' : '外挂料位 R';
    }
    final tray = current ?? previous;
    if (tray == null || tray.amsId < 0) {
      return printerFeedChannelLabel(channelIndex);
    }
    final ordinal = amsOrdinal ?? tray.amsId + 1;
    final type = switch (amsType) {
      AmsUnitType.ams => 'AMS 1',
      AmsUnitType.amsLite => 'AMS Lite',
      AmsUnitType.ams2Pro => 'AMS 2 Pro',
      AmsUnitType.amsHt => 'AMS HT',
      _ => 'AMS',
    };
    return '第 $ordinal 台 $type · 第 ${tray.slot + 1} 通道';
  }

  static SpoolChangeObservation manualEvent({
    required String printerSerial,
    required String printerLabel,
    required int channelIndex,
    int? printerId,
    bool isExternal = false,
    int externalInputCount = 1,
    int externalInputIndex = 0,
    bool farmMode = false,
  }) {
    return SpoolChangeObservation(
      printerSerial: printerSerial,
      printerLabel: printerLabel,
      channelIndex: channelIndex,
      previous: null,
      current: null,
      detectedAt: DateTime.now(),
      printerId: printerId,
      isManual: true,
      isExternal: isExternal,
      farmMode: farmMode,
      externalInputCount: externalInputCount,
      externalInputIndex: externalInputIndex,
      kind: SpoolChangeKind.manual,
    );
  }

  static String trayIdentity(AmsTray? tray) {
    if (tray == null) return 'unknown';
    if (tray.normalizedTagUid.isNotEmpty) return 'tag:${tray.normalizedTagUid}';
    if (tray.trayUuid.trim().isNotEmpty) return 'uuid:${tray.trayUuid.trim()}';
    return [
      tray.trayInfoIdx.trim(),
      tray.trayType.trim().toLowerCase(),
      tray.trayColor.trim().toLowerCase(),
      tray.trayTag.trim().toLowerCase(),
      tray.trayWeight,
    ].join('|');
  }
}

/// Compares successive AMS snapshots by physical global slot.
///
/// Empty snapshots establish a removal state but do not prompt. The next
/// occupied snapshot becomes the replacement event, which handles a user
/// removing two spools and inserting them again several seconds later.
class SpoolChangeDetector {
  static const removalStableDuration = Duration(milliseconds: 800);

  final Map<int, AmsTray> _lastLoaded = {};
  final Map<int, bool> _present = {};
  final Map<int, DateTime> _removedAt = {};
  final Set<int> _removalReported = {};
  final Map<int, AmsTray> _lastExternalTray = {};
  final Map<int, bool> _externalPresent = {};
  final Map<int, DateTime> _externalRemovedAt = {};
  final Set<int> _externalRemovalReported = {};
  final Map<int, bool> _externalUnloadObserved = {};
  final Map<int, bool> _externalLoadObserved = {};
  bool _initialized = false;
  bool _externalInitialized = false;

  List<SpoolChangeObservation> update({
    required String printerSerial,
    required String printerLabel,
    required List<AmsTray>? trays,
    List<AmsUnit>? units,
    List<AmsTray>? externalTrays,
    List<bool?>? extruderFilamentPresent,
    int? hwSwitchState,
    int? printStage,
    String? trayNow,
    DateTime? now,
    bool farmMode = false,
  }) {
    final timestamp = now ?? DateTime.now();
    final events = <SpoolChangeObservation>[];
    events.addAll(
      _updateExternal(
        printerSerial: printerSerial,
        printerLabel: printerLabel,
        externalTrays: externalTrays,
        extruderFilamentPresent: externalFeedSensorReadings(
          sensors: extruderFilamentPresent,
          trayNow: trayNow,
          hwSwitchState: hwSwitchState,
          units: units,
          trays: trays,
        ),
        hwSwitchState: null,
        printStage: printStage,
        now: timestamp,
        farmMode: farmMode,
      ),
    );
    if (trays == null) return events;
    final bySlot = <int, AmsTray>{
      for (final tray in trays.where((tray) => tray.amsId >= 0))
        tray.globalSlot: tray,
    };
    final slots = <int>{..._present.keys, ...bySlot.keys};
    final presentUnits = (units ?? const <AmsUnit>[])
        .where((unit) => unit.isPresent)
        .toList(growable: false);
    final unitFacts = <int, ({int ordinal, AmsUnitType type})>{
      for (var i = 0; i < presentUnits.length; i++)
        presentUnits[i].id: (ordinal: i + 1, type: presentUnits[i].type),
    };

    if (!_initialized) {
      _initialized = true;
      for (final slot in slots) {
        final tray = bySlot[slot];
        if (tray?.hasFilamentObservation != true) continue;
        final present = tray?.hasFilament == true;
        _present[slot] = present;
        if (present) _lastLoaded[slot] = tray!;
      }
      return events;
    }

    for (final slot in slots) {
      final tray = bySlot[slot];
      // AMS payloads can be partial while an AMS unit reconnects. A missing
      // slot is not an authoritative empty signal; only an explicit tray with
      // hasFilament=false may start the stable-removal timer.
      if (tray == null || !tray.hasFilamentObservation) continue;
      final present = tray.hasFilament;
      if (!_present.containsKey(slot)) {
        _present[slot] = present;
        if (present) _lastLoaded[slot] = tray;
        continue;
      }
      final wasPresent = _present[slot] ?? false;
      final previous = _lastLoaded[slot];

      if (!present) {
        if (wasPresent) {
          _removedAt[slot] = timestamp;
          _removalReported.remove(slot);
        }
        _present[slot] = false;
        final removedAt = _removedAt[slot];
        if (!farmMode &&
            previous != null &&
            removedAt != null &&
            !_removalReported.contains(slot) &&
            timestamp.difference(removedAt) >= removalStableDuration) {
          events.add(
            SpoolChangeObservation(
              printerSerial: printerSerial,
              printerLabel: printerLabel,
              channelIndex: slot,
              previous: previous,
              current: null,
              detectedAt: timestamp,
              amsOrdinal: unitFacts[previous.amsId]?.ordinal,
              amsType: unitFacts[previous.amsId]?.type,
              farmMode: false,
              kind: SpoolChangeKind.removed,
            ),
          );
          _removalReported.add(slot);
        }
        continue;
      }

      final insertedAfterRemoval = !wasPresent;
      final identityChanged =
          previous != null &&
          SpoolChangeObservation.trayIdentity(previous) !=
              SpoolChangeObservation.trayIdentity(tray);
      final removedAt = _removedAt[slot];
      final briefSensorBounce =
          insertedAfterRemoval &&
          !identityChanged &&
          !_removalReported.contains(slot) &&
          removedAt != null &&
          timestamp.difference(removedAt) < removalStableDuration;
      if ((insertedAfterRemoval && !briefSensorBounce) || identityChanged) {
        events.add(
          SpoolChangeObservation(
            printerSerial: printerSerial,
            printerLabel: printerLabel,
            channelIndex: slot,
            previous: previous,
            current: tray,
            detectedAt: timestamp,
            amsOrdinal: unitFacts[tray.amsId]?.ordinal,
            amsType: unitFacts[tray.amsId]?.type,
            farmMode: farmMode,
          ),
        );
      }
      _removedAt.remove(slot);
      _removalReported.remove(slot);
      _present[slot] = true;
      _lastLoaded[slot] = tray;
    }
    return events;
  }

  List<SpoolChangeObservation> _updateExternal({
    required String printerSerial,
    required String printerLabel,
    required List<AmsTray>? externalTrays,
    required List<bool?>? extruderFilamentPresent,
    required int? hwSwitchState,
    required int? printStage,
    required DateTime now,
    required bool farmMode,
  }) {
    final sensors = extruderFilamentPresent?.isNotEmpty == true
        ? extruderFilamentPresent!
        : hwSwitchState == null
        ? null
        : <bool>[hwSwitchState == 1];
    if (sensors == null || sensors.isEmpty) return const [];

    final metadata = <int, AmsTray>{
      for (final tray in externalTrays ?? const <AmsTray>[]) tray.slot: tray,
    };
    if (!_externalInitialized) {
      _externalInitialized = true;
      for (var input = 0; input < sensors.length; input++) {
        final present = sensors[input];
        if (present == null) continue;
        _externalPresent[input] = present;
        if (present) {
          _lastExternalTray[input] = _externalTray(metadata[input], input);
        }
      }
      return const [];
    }

    final events = <SpoolChangeObservation>[];
    for (var input = 0; input < sensors.length; input++) {
      final present = sensors[input];
      if (present == null) {
        _externalPresent.remove(input);
        _externalRemovedAt.remove(input);
        _lastExternalTray.remove(input);
        _externalRemovalReported.remove(input);
        _externalUnloadObserved.remove(input);
        _externalLoadObserved.remove(input);
        continue;
      }
      final wasPresent = _externalPresent[input] ?? present;
      if (printStage == 22) _externalUnloadObserved[input] = true;
      if (printStage == 24 && _externalRemovedAt[input] != null) {
        _externalLoadObserved[input] = true;
      }

      if (wasPresent && !present) {
        _externalRemovedAt[input] = now;
        _externalRemovalReported.remove(input);
        _externalPresent[input] = false;
        continue;
      }

      if (!present) {
        final removedAt = _externalRemovedAt[input];
        final previous = _lastExternalTray[input];
        if (!farmMode &&
            previous != null &&
            removedAt != null &&
            !_externalRemovalReported.contains(input) &&
            now.difference(removedAt) >= removalStableDuration) {
          events.add(
            SpoolChangeObservation(
              printerSerial: printerSerial,
              printerLabel: printerLabel,
              channelIndex: input == 1 ? 254 : 255,
              previous: previous,
              current: null,
              detectedAt: now,
              isExternal: true,
              farmMode: false,
              externalInputCount: sensors.length,
              externalInputIndex: input,
              kind: SpoolChangeKind.removed,
            ),
          );
          _externalRemovalReported.add(input);
        }
        _externalPresent[input] = false;
        continue;
      }

      if (!wasPresent && present) {
        final removedAt = _externalRemovedAt[input];
        final operationObserved =
            _externalUnloadObserved[input] == true ||
            _externalLoadObserved[input] == true;
        final sensorWasOpenLongEnough =
            removedAt != null &&
            now.difference(removedAt) >= const Duration(milliseconds: 500);
        if (operationObserved || sensorWasOpenLongEnough) {
          final current = _externalTray(metadata[input], input);
          events.add(
            SpoolChangeObservation(
              printerSerial: printerSerial,
              printerLabel: printerLabel,
              // External feeds always use reserved physical IDs. This keeps
              // dual-extruder L/R inputs separate from AMS slot 0/1 and from
              // printers that expose no AMS in the current snapshot.
              channelIndex: input == 1 ? 254 : 255,
              previous: _lastExternalTray[input],
              current: current,
              detectedAt: now,
              isExternal: true,
              farmMode: farmMode,
              externalInputCount: sensors.length,
              externalInputIndex: input,
            ),
          );
          _lastExternalTray[input] = current;
        }
        _externalRemovedAt.remove(input);
        _externalRemovalReported.remove(input);
        _externalUnloadObserved.remove(input);
        _externalLoadObserved.remove(input);
      } else if (present) {
        _lastExternalTray.putIfAbsent(
          input,
          () => _externalTray(metadata[input], input),
        );
      }
      _externalPresent[input] = present;
    }
    return events;
  }

  AmsTray _externalTray(AmsTray? metadata, int input) {
    return AmsTray(
      amsId: -1,
      slot: input,
      trayType: metadata?.trayType ?? '',
      trayColor: metadata?.trayColor ?? '',
      remain: metadata?.remain ?? -1,
      trayWeight: metadata?.trayWeight ?? 0,
      traySubBrands: metadata?.traySubBrands ?? '',
      trayInfoIdx: metadata?.trayInfoIdx ?? '',
      hasFilament: true,
      trayTag: 'external',
      trayUuid: '',
      nozzleTempMin: metadata?.nozzleTempMin ?? 0,
      nozzleTempMax: metadata?.nozzleTempMax ?? 0,
      dryingTemp: metadata?.dryingTemp ?? 0,
      dryingTime: metadata?.dryingTime ?? 0,
    );
  }

  void reset() {
    _lastLoaded.clear();
    _present.clear();
    _removedAt.clear();
    _removalReported.clear();
    _lastExternalTray.clear();
    _externalPresent.clear();
    _externalRemovedAt.clear();
    _externalRemovalReported.clear();
    _externalUnloadObserved.clear();
    _externalLoadObserved.clear();
    _initialized = false;
    _externalInitialized = false;
  }
}
