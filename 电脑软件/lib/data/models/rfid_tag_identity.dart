/// Canonical representation used when matching a reusable CUID/FUID tag.
///
/// Readers return the same UID with spaces, colons or lowercase depending on
/// the platform. Hex UIDs use the historical compact uppercase format so
/// migrated mobile rows continue to match. Opaque
/// test/legacy identifiers preserve their case; they are not guaranteed to
/// be hexadecimal and changing their case would mutate the physical ID.
String normalizeRfidTagUid(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  // Only remove common NFC formatting separators. Stripping every
  // non-hex character would turn opaque identifiers such as `rfid-moved`
  // into the unrelated hex value `FDED`.
  final compact = trimmed.replaceAll(RegExp(r'[\s:._-]'), '');
  if (compact.length >= 4 &&
      compact.length.isEven &&
      RegExp(r'^[0-9a-fA-F]+$').hasMatch(compact)) {
    // Keep the historical compact representation used by the mobile reader.
    // This lets v47 rows migrated from consumables.tray_uuid match newly
    // scanned tags without a second data migration.
    return compact.toUpperCase();
  }
  return trimmed.replaceAll(RegExp(r'\s+'), ' ');
}

/// Compares reader-provided identities without changing the persisted value.
/// Opaque legacy identifiers can differ only by case across NFC/JSON sources.
bool rfidTagUidEquals(String left, String right) {
  final normalizedLeft = normalizeRfidTagUid(left);
  final normalizedRight = normalizeRfidTagUid(right);
  if (normalizedLeft.isEmpty || normalizedRight.isEmpty) return false;
  return normalizedLeft == normalizedRight ||
      normalizedLeft.toLowerCase() == normalizedRight.toLowerCase();
}

bool isReusableRfidTagType(String value) => isConsumableRfidTagType(value);

/// Only an explicitly identified CUID/FUID may enter the mobile consumable
/// workflow. A UID, a generic Classic technology, or an old blank type does
/// not identify the card variant and must not stand in for confirmation.
bool isConsumableRfidTagType(String? value) =>
    const {'cuid', 'fuid'}.contains(value?.trim().toLowerCase());

/// Old phone versions recorded a technology instead of the confirmed card
/// variant. Keep these rows readable, but require a fresh CUID/FUID declaration
/// before using them as consumable labels. Known other card types never qualify.
bool requiresConsumableRfidTagTypeConfirmation(String? value) => const {
  '',
  'classic',
  'mifare_classic',
  'mifare_classic_1k',
  'mifare classic',
  'mifare classic 1k',
}.contains(value?.trim().toLowerCase() ?? '');

const validConsumableLifecycleStatuses = <String>{
  'active',
  'depleted',
  'replaced',
  'retired',
};

/// The twin ledger must identify a concrete roll, never a reusable tag.
String rfidSpoolLedgerKey(String inventoryUid) => 'spool:$inventoryUid';
