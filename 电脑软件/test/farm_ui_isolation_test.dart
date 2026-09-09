import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('农场模式不导入普通模式 UI 实现', () {
    final studioDirectory = Directory('lib/features/studio');
    expect(studioDirectory.existsSync(), isTrue);

    final violations = <String>[];
    final dartFiles = studioDirectory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in dartFiles) {
      final content = file.readAsStringSync();
      if (content.contains('Aurora.')) {
        violations.add('${file.path}: 使用了普通模式 Aurora 视觉令牌');
      }

      for (final match in _importPattern.allMatches(content)) {
        final uri = match.group(1)!.replaceAll('\\', '/');
        final referencesPersonalWidgets = uri.contains('/widgets/');
        final referencesPersonalFeatureUi =
            uri.contains('/features/settings/') ||
                uri.contains('/features/printers/');
        final referencesSharedUi = uri.contains('/ui/') &&
            !uri.endsWith('/ui/workspace_navigation.dart');
        if (referencesPersonalWidgets ||
            referencesPersonalFeatureUi ||
            referencesSharedUi) {
          violations.add('${file.path}: 禁止的 UI 导入 $uri');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: '农场模式必须使用 lib/features/studio/farm_ui 下的独立组件：\n'
          '${violations.join('\n')}',
    );
  });

  test('农场专属 UI 基础文件完整', () {
    const requiredFiles = [
      'lib/features/studio/farm_ui/farm_theme.dart',
      'lib/features/studio/farm_ui/farm_design.dart',
      'lib/features/studio/farm_ui/farm_components.dart',
      'lib/features/studio/farm_ui/farm_feedback.dart',
      'lib/features/studio/farm_ui/farm_account_flows.dart',
      'lib/features/studio/farm_ui/farm_brand_picker.dart',
    ];

    expect(
      requiredFiles.where((path) => !File(path).existsSync()),
      isEmpty,
      reason: '农场模式的主题、组件和交互流程必须保留独立副本。',
    );
  });
}

final _importPattern = RegExp(r'''import\s+['"]([^'"]+)['"]''');
