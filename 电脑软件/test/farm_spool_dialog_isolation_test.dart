import 'dart:io';

import 'package:consumable_tracker_desktop/core/services/spool_change_detector.dart';
import 'package:consumable_tracker_desktop/providers/spool_change_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('农场与普通模式使用完全独立的换料弹窗和库存来源', () {
    final app = File('lib/app.dart').readAsStringSync();
    final farmDialog = File(
      'lib/features/studio/farm_spool_change_confirmation_dialog.dart',
    ).readAsStringSync();
    final personalDialog = File(
      'lib/features/print_task/spool_change_confirmation_dialog.dart',
    ).readAsStringSync();

    expect(app, contains('FarmSpoolChangeConfirmationDialog.show'));
    expect(app, contains('SpoolChangeConfirmationDialog.show'));
    expect(app, contains('studioModeEnabledProvider'));
    expect(app, contains('pendingForMode(farmMode)'));

    expect(farmDialog, contains('farmConsumablesProvider'));
    expect(farmDialog, contains('currentFarmPermissionProvider'));
    expect(farmDialog, contains('确认并扣仓库 1 卷'));
    expect(farmDialog, isNot(contains('consumablesProvider')));
    expect(farmDialog, isNot(contains('ConsumableShelfPickerDialog')));
    expect(farmDialog, contains('event.farmMode'));
    expect(farmDialog, isNot(contains('旧卷还有多少料')));

    expect(personalDialog, contains('consumablesProvider'));
    expect(personalDialog, isNot(contains('farmConsumablesProvider')));
    expect(personalDialog, isNot(contains('farmOwnerConfirmed')));
    expect(personalDialog, isNot(contains('FarmRollLoadAuthorization')));
    expect(personalDialog, contains('!event.farmMode'));
  });

  test('换料队列按农场和普通库存域完全分流', () {
    final queue = SpoolChangeQueueNotifier();
    queue.enqueue(
      SpoolChangeObservation.manualEvent(
        printerSerial: 'P1',
        printerLabel: '普通设备',
        channelIndex: 0,
      ),
    );
    queue.enqueue(
      SpoolChangeObservation.manualEvent(
        printerSerial: 'P1',
        printerLabel: '农场设备',
        channelIndex: 0,
        farmMode: true,
      ),
    );

    final personal = queue.pendingForMode(false);
    final farm = queue.pendingForMode(true);
    expect(personal, hasLength(1));
    expect(farm, hasLength(1));
    expect(personal.single.farmMode, isFalse);
    expect(farm.single.farmMode, isTrue);
    expect(personal.single.locationKey, isNot(farm.single.locationKey));
  });
}
