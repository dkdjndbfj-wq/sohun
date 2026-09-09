import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/mobile/ams_tag_template.dart';
import 'package:consumable_tracker_desktop/mobile/ams_template_picker.dart';
import 'package:consumable_tracker_desktop/mobile/ams_template_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ams_template_fixture.dart';

class _LayoutVault implements AmsTemplateRepository {
  final template = syntheticAmsTemplate();

  @override
  Future<List<AmsTagTemplate>> list({required String ownerAccount}) async => [
    template,
  ];

  @override
  Future<AmsTagTemplate?> read(
    String id, {
    required String ownerAccount,
  }) async => template;

  @override
  Future<void> save(
    AmsTagTemplate template, {
    required String ownerAccount,
  }) async {}

  @override
  Future<void> delete(String id, {required String ownerAccount}) async {}
}

Future<void> _mountAtLargeText(
  WidgetTester tester, {
  required Size size,
  required void Function(BuildContext context) onOpen,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => onOpen(context),
            child: const Text('打开模板'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开模板'));
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [const Size(320, 640), const Size(640, 360)]) {
    testWidgets('template picker stays usable at $size with 2x text', (
      tester,
    ) async {
      final revision = ValueNotifier(0);
      addTearDown(revision.dispose);
      final vault = _LayoutVault();
      AmsTemplateChoice? selected;
      await _mountAtLargeText(
        tester,
        size: size,
        onOpen: (context) async {
          selected = await showAmsTemplatePicker(
            context,
            repository: vault,
            ownerAccount: 'alice',
            accountRevision: revision,
          );
        },
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(CustomScrollView), findsOneWidget);

      // Header, lazy list, and privacy warning share a scrollable viewport.
      final warning = find.textContaining('导入只检查数据结构');
      final scrollable = find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(warning, 160, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(warning.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      final item = find.text(vault.template.name);
      await tester.scrollUntilVisible(item, -160, scrollable: scrollable);
      await tester.pumpAndSettle();
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(selected?.template?.id, vault.template.id);
      expect(find.text('兼容标签模板'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('small 2x text restore dialog keeps risk consent operable', (
    tester,
  ) async {
    String? selectedTarget;
    await _mountAtLargeText(
      tester,
      size: const Size(320, 640),
      onOpen: (context) async {
        selectedTarget = await confirmAmsTemplateRestore(
          context,
          syntheticAmsTemplate(),
        );
      },
    );
    expect(tester.takeException(), isNull);
    final confirm = find.widgetWithText(FilledButton, '确认并开始写入');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.ensureVisible(find.text('FUID'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FUID'));
    await tester.pumpAndSettle();
    final risk = find.textContaining('仅能修改一次');
    await tester.ensureVisible(risk);
    await tester.pumpAndSettle();
    expect(risk.hitTestable(), findsOneWidget);

    final consent = find.byType(CheckboxListTile);
    await tester.ensureVisible(consent);
    await tester.pumpAndSettle();
    await tester.tap(consent);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(consent).value, isTrue);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(selectedTarget, 'fuid');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
