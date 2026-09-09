import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/data/models/rfid_tag_identity.dart';

void main() {
  test(
    'normalizes hexadecimal reader formatting without corrupting opaque IDs',
    () {
      expect(normalizeRfidTagUid('04 aa:bb-cc'), '04AABBCC');
      expect(normalizeRfidTagUid('rfid-moved'), 'rfid-moved');
      expect(normalizeRfidTagUid('RFID-MOVED'), 'RFID-MOVED');
      expect(rfidTagUidEquals('rfid-moved', 'RFID-MOVED'), isTrue);
    },
  );

  test(
    'consumable card types require an exact confirmed CUID or FUID name',
    () {
      expect(isConsumableRfidTagType(' CUID '), isTrue);
      expect(isConsumableRfidTagType('fuid'), isTrue);
      expect(isReusableRfidTagType(' CUID '), isTrue);
      expect(isReusableRfidTagType('fuid'), isTrue);
      for (final type in [
        null,
        '',
        'CLASSIC',
        'NTAG213',
        'Ultralight',
        'NTAG213 CUID',
        'ams',
      ]) {
        expect(isConsumableRfidTagType(type), isFalse, reason: '$type');
        expect(isReusableRfidTagType(type ?? ''), isFalse, reason: '$type');
      }
      expect(requiresConsumableRfidTagTypeConfirmation(null), isTrue);
      expect(
        requiresConsumableRfidTagTypeConfirmation('MIFARE_CLASSIC_1K'),
        isTrue,
      );
      expect(requiresConsumableRfidTagTypeConfirmation('NTAG213'), isFalse);
    },
  );
}
