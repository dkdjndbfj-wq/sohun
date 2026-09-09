import 'package:consumable_tracker_desktop/providers/print_queue_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('无人值守模式会从偏好加载并持久化修改', () async {
    SharedPreferences.setMockInitialValues({
      'unattended_mode_enabled': true,
    });
    final notifier = UnattendedModeNotifier();
    addTearDown(notifier.dispose);

    await notifier.ready;
    expect(notifier.state, isTrue);

    await notifier.setEnabled(false);
    final prefs = await SharedPreferences.getInstance();
    expect(notifier.state, isFalse);
    expect(prefs.getBool('unattended_mode_enabled'), isFalse);
  });
}
