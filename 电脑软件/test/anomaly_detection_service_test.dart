import 'package:consumable_tracker_desktop/core/services/anomaly_detection_service.dart';
import 'package:consumable_tracker_desktop/core/services/notification_service.dart';
import 'package:consumable_tracker_desktop/core/services/theme_icon_service.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_task.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_task_consumable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('invalid estimates do not trigger realtime ratio alerts', () async {
    SharedPreferences.setMockInitialValues(const {});
    final notifications = _RecordingNotificationService();
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(notifications),
      ],
    );
    addTearDown(container.dispose);

    final service = container.read(anomalyDetectionServiceProvider);
    final task = _task();

    for (final estimate in [0.0, -1.0, double.nan, double.infinity]) {
      await service.detectRealtimeDeduction(
        task: task,
        entry: _entry(estimate),
        delta: 10,
        mcPercent: 50,
      );
    }

    expect(notifications.alertCount, 0);
  });
}

PrintTask _task() {
  final now = DateTime(2026, 8, 2);
  return PrintTask(
    id: 1,
    uid: 'task-1',
    gcodePath: r'C:\test.3mf',
    taskName: 'test task',
    estimatedGrams: 10,
    estimatedSeconds: 60,
    actualGrams: 0,
    lastMcPercent: 50,
    lastLayer: 1,
    status: PrintTaskStatus.printing,
    source: 'test',
    createdAt: now,
    updatedAt: now,
  );
}

PrintTaskConsumable _entry(double estimatedGrams) {
  final now = DateTime(2026, 8, 2);
  return PrintTaskConsumable(
    id: 1,
    taskId: 1,
    printerId: 1,
    channelIndex: 0,
    consumableId: 1,
    toolIndex: 0,
    estimatedGrams: estimatedGrams,
    createdAt: now,
    updatedAt: now,
  );
}

class _RecordingNotificationService extends NotificationService {
  _RecordingNotificationService()
      : super(
          ThemeIconService(
            setWindowIcon: (_) async {},
            setTrayIcon: (_) async {},
            supportsWindowIcon: false,
          ),
        );

  int alertCount = 0;

  @override
  Future<void> alert({
    required AlertType type,
    required String title,
    required String body,
    VoidCallback? onClick,
  }) async {
    alertCount++;
  }
}
