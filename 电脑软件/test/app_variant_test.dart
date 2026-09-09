import 'package:consumable_tracker_desktop/core/app_identity.dart';
import 'package:consumable_tracker_desktop/core/app_variant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('product constants select one consistent desktop application', () {
    expect(AppVariant.isFarm, isNot(AppVariant.isPersonal));
    expect(
      AppIdentity.name,
      AppVariant.isFarm ? 'sohun 农场' : 'sohun',
    );
    expect(
      AppVariant.executableName,
      AppVariant.isFarm ? 'sohun-farm' : 'sohun',
    );
    expect(
      AppVariant.dataNamespace,
      AppVariant.isFarm ? 'sohun-farm' : 'sohun-personal',
    );
  });
}
