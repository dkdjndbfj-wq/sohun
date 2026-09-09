import 'package:consumable_tracker_desktop/core/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('主题从粉色切到绿色时全部派生色同步更新', () {
    const pink = Color(0xFFEC4899);
    const pinkAccent = Color(0xFFF472B6);
    const green = Color(0xFF00B42A);
    const greenAccent = Color(0xFF14B8A6);

    AppColors.applyTheme(pink, pinkAccent);
    final oldScale = <Color>[
      AppColors.primary50,
      AppColors.primary400,
      AppColors.primary800,
      AppColors.accentContainer,
      AppColors.lightGreen,
      AppColors.cardBorder,
    ];

    AppColors.applyTheme(green, greenAccent);

    expect(AppColors.primary, green);
    expect(AppColors.primary500, green);
    expect(AppColors.accent, greenAccent);
    expect(AppColors.primary50, isNot(oldScale[0]));
    expect(AppColors.primary400, isNot(oldScale[1]));
    expect(AppColors.primary800, isNot(oldScale[2]));
    expect(AppColors.accentContainer, isNot(oldScale[3]));
    expect(AppColors.lightGreen, isNot(oldScale[4]));
    expect(AppColors.cardBorder, isNot(oldScale[5]));
  });
}
