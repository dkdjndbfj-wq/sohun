import 'package:flutter/material.dart';

/// 颜色转换工具。HEX/HSV/RGB 互转。
class ColorUtils {
  ColorUtils._();

  /// 从 HEX 字符串解析颜色。支持 #RGB / #RRGGBB / #AARRGGBB / 无 # 前缀。
  /// 解析失败返回 [fallback]（默认浅灰），不抛异常。
  static Color fromHex(String hex, {Color fallback = const Color(0xFFCBD5E1)}) {
    try {
      var cleaned =
          hex.replaceAll('#', '').replaceAll('0x', '').toUpperCase().trim();
      if (cleaned.isEmpty) return fallback;
      // 3 位缩写 #RGB → #RRGGBB
      if (cleaned.length == 3) {
        cleaned = cleaned.split('').map((c) => c + c).join();
      }
      if (cleaned.length == 6) {
        return Color(int.parse('FF$cleaned', radix: 16));
      }
      if (cleaned.length == 8) {
        return Color(int.parse(cleaned, radix: 16));
      }
      return fallback;
    } catch (_) {
      return fallback;
    }
  }

  /// Color → HEX 字符串（#RRGGBB 格式，不含 alpha）。
  static String toHex(Color c) {
    final argb = c.toARGB32();
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  /// HSV → HEX（isolate 友好的纯数据版本）
  static String hsvToHex(double h, double s, double v) {
    final color = HSVColor.fromAHSV(1.0, h, s, v).toColor();
    return toHex(color);
  }
}
