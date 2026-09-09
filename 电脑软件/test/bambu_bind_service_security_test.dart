import 'package:consumable_tracker_desktop/data/external/printer/bambu_bind_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('绑定工具命令行只含 stdin 模式和 token 路径，不含 PIN', () {
    const syntheticPin = 'ABC123';
    final arguments = BambuBindService.bindToolArgumentsForTesting(
      r'C:\secure_runtime\bind_token.json',
    );

    expect(arguments, [
      '--stdin',
      r'C:\secure_runtime\bind_token.json',
    ]);
    expect(arguments, isNot(contains(syntheticPin)));
  });
}
