import 'package:flutter/material.dart';

/// 排版系统。
///
/// 中文字体优先 HarmonyOS Sans（华为设备），回退 Microsoft YaHei UI（Windows 自带）。
/// 数字字体用 Cascadia Code 等宽字体，用于温度/克数/百分比等数据展示。
class AppTypography {
  AppTypography._();

  /// 中文字体族（亮色模式）。
  ///
  /// 优先级：HarmonyOS Sans → Microsoft YaHei UI → PingFang SC → sans-serif。
  static const String chineseFontFamily =
      'HarmonyOS Sans, Microsoft YaHei UI, PingFang SC, sans-serif';

  /// 等宽字体族（数据展示）。
  static const String monoFontFamily = 'Cascadia Code, Consolas, monospace';

  /// 通用正文样式（14px w400）。
  static const TextStyle body = TextStyle(
    fontFamily: chineseFontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );

  /// 标题样式（16px w700）。
  static const TextStyle title = TextStyle(
    fontFamily: chineseFontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );

  /// 大标题样式（20px w700）。
  static const TextStyle headline = TextStyle(
    fontFamily: chineseFontFamily,
    fontSize: 20,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );

  /// 次要文字样式（12px w300 灰色）。
  static const TextStyle caption = TextStyle(
    fontFamily: chineseFontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w300,
    color: Color(0xFF868E96),
  );

  /// 数据展示样式（等宽 14px w600）。
  static const TextStyle data = TextStyle(
    fontFamily: monoFontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );

  /// 大数据展示（统计卡数字 28px w700 等宽）。
  static const TextStyle dataLarge = TextStyle(
    fontFamily: monoFontFamily,
    fontSize: 28,
    fontWeight: FontWeight.w700,
  );

  /// 按钮文字样式（14px w600）。
  static const TextStyle button = TextStyle(
    fontFamily: chineseFontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );

  /// 标签胶囊文字（11px w500）。
  static const TextStyle label = TextStyle(
    fontFamily: chineseFontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
  );
}
