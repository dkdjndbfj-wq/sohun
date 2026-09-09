import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import '../features/settings/settings_sheet.dart';

/// 设置页直接承载完整偏好工作区。
///
/// 所有分类与弹窗入口共用同一套表单，用户无需先进入设置页、再点击一次
/// “打开完整设置”。
class AuroraSettingsPage extends StatelessWidget {
  const AuroraSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppSpacing.lg),
      child: SettingsWorkspace(embedded: true),
    );
  }
}
