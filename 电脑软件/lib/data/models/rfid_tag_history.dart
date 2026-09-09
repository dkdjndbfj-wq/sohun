import 'rfid_tag_identity.dart';

/// A completed tag binding retained when the same physical spool is retagged.
/// Inventory UID, weights and consumption remain on the original spool row.
class RfidTagHistoryEntry {
  const RfidTagHistoryEntry({
    required this.tagUid,
    this.tagType,
    required this.cycle,
    this.previousInventoryUid,
  });

  final String tagUid;
  final String? tagType;
  final int cycle;
  final String? previousInventoryUid;

  factory RfidTagHistoryEntry.fromJson(Map<String, dynamic> json) {
    final tag = json['tagUid'];
    final cycle = json['cycle'];
    final type = json['tagType'];
    final previous = json['previousInventoryUid'];
    if (tag is! String ||
        tag.trim().isEmpty ||
        tag.length > 128 ||
        cycle is! int ||
        cycle < 1 ||
        (type != null && type is! String) ||
        (previous != null && previous is! String)) {
      throw const FormatException('标签换绑历史格式不正确');
    }
    return RfidTagHistoryEntry(
      tagUid: normalizeRfidTagUid(tag),
      tagType: type as String?,
      cycle: cycle,
      previousInventoryUid: previous as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'tagUid': tagUid,
    'tagType': tagType,
    'cycle': cycle,
    'previousInventoryUid': previousInventoryUid,
  };

  bool sameIdentity(RfidTagHistoryEntry other) =>
      rfidTagUidEquals(tagUid, other.tagUid) &&
      cycle == other.cycle &&
      (previousInventoryUid ?? '').toLowerCase() ==
          (other.previousInventoryUid ?? '').toLowerCase();

  static List<RfidTagHistoryEntry> parseList(Object? value) {
    if (value == null) return const [];
    if (value is! List || value.length > 32) {
      throw const FormatException('标签换绑历史最多保留 32 次');
    }
    return List.unmodifiable(
      value.map((entry) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('标签换绑历史格式不正确');
        }
        return RfidTagHistoryEntry.fromJson(entry);
      }),
    );
  }
}
