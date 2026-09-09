import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/widgets/rfid_spool_rebind_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'rebind validates scanned UID and keeps server errors reviewable before retry',
    (tester) async {
      final now = DateTime.now();
      final item = Consumable(
        id: 1,
        uid: 'leftover',
        manufacturer: 'eSUN',
        model: 'PLA',
        materialType: 'PLA',
        colorHex: '#FFFFFF',
        totalGrams: 750,
        remainingGrams: 125,
        createdAt: now,
        updatedAt: now,
      );
      var calls = 0;
      String? savedUid;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                child: const Text('打开'),
                onPressed: () => showRfidSpoolRebindDialog(
                  context,
                  item: item,
                  scan: () async => '04:bb:00:02',
                  save: (uid, type) async {
                    calls++;
                    if (calls == 1) throw StateError('新标签已有绑定');
                    savedUid = uid;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认换绑'));
      await tester.pumpAndSettle();
      expect(find.text('请输入新标签的 8 位十六进制 UID'), findsOneWidget);
      expect(calls, 0);
      await tester.tap(find.text('扫描新标签'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rebind-tag-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CUID').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认换绑'));
      await tester.pumpAndSettle();
      expect(find.textContaining('新标签已有绑定'), findsOneWidget);
      expect(find.text('旧余料换绑新标签'), findsOneWidget);
      await tester.tap(find.text('确认换绑'));
      await tester.pumpAndSettle();
      expect(savedUid, '04BB0002');
      expect(find.text('旧余料换绑新标签'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
