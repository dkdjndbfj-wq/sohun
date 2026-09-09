import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/features/studio/studio_audit_log_screen.dart';
import 'package:consumable_tracker_desktop/providers/studio_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('管理员操作记录页展示操作者、时间和操作内容', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 8, 5, 14, 30);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          studioActivityEventsProvider.overrideWith(
            (ref) => Stream.value([
              StudioActivityEvent(
                id: 'audit-1',
                workspaceId: 'farm-1',
                actorMemberId: 'member-1',
                actorDisplayName: '成员张三',
                actorIdentity: 'member',
                actionCode: 'order.created',
                entityType: 'order',
                entityId: 'order-1',
                summary: '创建订单 SO-20260805',
                createdAt: now,
              ),
            ]),
          ),
          farmAuditLogsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(
          home: Scaffold(body: StudioAuditLogScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('操作记录'), findsOneWidget);
    expect(find.text('成员张三'), findsOneWidget);
    expect(find.text('创建订单'), findsOneWidget);
    expect(find.text('创建订单 SO-20260805'), findsOneWidget);
    expect(find.textContaining('2026-08-05 14:30:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('打印机实时画面记录使用中文标签且不暴露内部代码', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          studioActivityEventsProvider.overrideWith(
            (ref) => Stream.value([
              StudioActivityEvent(
                id: 'audit-camera-1',
                workspaceId: 'farm-1',
                actorMemberId: 'owner-1',
                actorDisplayName: '农场管理员',
                actorIdentity: 'administrator',
                actionCode: 'printer.camera_preview_opened',
                entityType: 'printer',
                entityId: 'printer-1',
                summary: '查看 01 号打印机的实时画面',
                createdAt: DateTime(2026, 8, 11, 4, 20),
              ),
            ]),
          ),
          farmAuditLogsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(
          home: Scaffold(body: StudioAuditLogScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('查看实时画面'), findsOneWidget);
    expect(find.text('打印机'), findsOneWidget);
    expect(find.text('printer.camera_preview_opened'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
