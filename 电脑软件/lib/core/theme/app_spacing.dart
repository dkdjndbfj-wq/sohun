import 'package:flutter/material.dart';

/// 4 基线间距系统（v4 新增）。
///
/// 所有间距为 4 的倍数，保证视觉节奏统一。
class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 48;

  // 常用 EdgeInsets 快捷构造
  static const EdgeInsets allXs = EdgeInsets.all(xs);
  static const EdgeInsets allSm = EdgeInsets.all(sm);
  static const EdgeInsets allMd = EdgeInsets.all(md);
  static const EdgeInsets allLg = EdgeInsets.all(lg);
  static const EdgeInsets allXl = EdgeInsets.all(xl);

  static const EdgeInsets hLg = EdgeInsets.symmetric(horizontal: lg);
  static const EdgeInsets hXl = EdgeInsets.symmetric(horizontal: xl);
  static const EdgeInsets vLg = EdgeInsets.symmetric(vertical: lg);
  static const EdgeInsets hvLg =
      EdgeInsets.symmetric(horizontal: lg, vertical: lg);
  static const EdgeInsets hvXl =
      EdgeInsets.symmetric(horizontal: xl, vertical: xl);
}
