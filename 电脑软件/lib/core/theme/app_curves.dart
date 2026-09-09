import 'package:flutter/animation.dart';

/// 苹果风格动效曲线（v4 新增）。
///
/// 三条核心曲线覆盖全应用动效：
/// - [easeOutCubic]：页面切换、列表项淡入（380ms，柔和减速）
/// - [easeOutBack]：弹窗入场、按钮回弹（220ms，轻微回弹）
/// - [easeInOutCubic]：状态切换、折叠展开（450ms，对称平滑）
class AppCurves {
  AppCurves._();

  /// 页面切换 / 列表项淡入：柔和减速，带 8px 上移。
  static const Duration durationPage = Duration(milliseconds: 380);
  static const Curve curvePage = Cubic(0.33, 1, 0.68, 1);

  /// 弹窗入场 / 按钮回弹：轻微回弹，0.92→1。
  static const Duration durationModal = Duration(milliseconds: 220);
  static const Curve curveModal = Cubic(0.34, 1.56, 0.64, 1);

  /// 卡片悬浮 / 按钮点按：快速响应。
  static const Duration durationHover = Duration(milliseconds: 220);
  static const Duration durationTap = Duration(milliseconds: 150);
  static const Curve curveHover = Cubic(0.33, 1, 0.68, 1);
  static const Curve curveTap = Cubic(0.34, 1.56, 0.64, 1);

  /// 状态切换 / 折叠展开：对称平滑。
  static const Duration durationState = Duration(milliseconds: 450);
  static const Curve curveState = Cubic(0.65, 0, 0.35, 1);

  /// 进度条光流：线性循环。
  static const Duration durationProgressFlow = Duration(milliseconds: 2500);

  /// 侧栏呼吸光晕：缓慢脉冲。
  static const Duration durationBreath = Duration(milliseconds: 2400);
}
