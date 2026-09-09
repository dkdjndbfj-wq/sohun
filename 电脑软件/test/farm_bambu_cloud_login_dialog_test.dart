import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_models.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_bambu_cloud_login_dialog.dart';
import 'package:consumable_tracker_desktop/providers/bambu_cloud_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestBambuCloudNotifier extends BambuCloudNotifier {
  _TestBambuCloudNotifier(Ref ref, BambuCloudState initial) : super(ref) {
    state = initial;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpDialog(
    WidgetTester tester, {
    BambuCloudState state = const BambuCloudState(),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bambuCloudProvider.overrideWith(
            (ref) => _TestBambuCloudNotifier(ref, state),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: FarmBambuCloudLoginDialog()),
        ),
      ),
    );
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('农场拓竹登录默认使用中国区手机号和密码', (tester) async {
    await pumpDialog(tester);

    expect(
      find.byKey(const ValueKey('farm-bambu-cloud-login-dialog')),
      findsOneWidget,
    );
    expect(find.text('拓竹账号'), findsOneWidget);
    expect(find.text('手机号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('登录拓竹账号'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('farm-bambu-region-overseas')),
    );
    await tester.pump();

    expect(find.text('邮箱地址'), findsOneWidget);
    expect(find.textContaining('海外区使用邮箱登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('需要二次验证时显示验证码输入与重新发送入口', (tester) async {
    await pumpDialog(
      tester,
      state: const BambuCloudState(
        pendingAccount: PendingAccount(
          region: BambuRegion.china,
          account: '13800000000',
          password: 'test-password',
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('farm-bambu-code')),
      findsOneWidget,
    );
    expect(find.textContaining('13800000000'), findsOneWidget);
    expect(find.text('重新发送'), findsOneWidget);
    expect(find.text('确认并同步设备'), findsOneWidget);
    expect(find.byKey(const ValueKey('farm-bambu-password')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
