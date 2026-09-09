import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_typography.dart';
import 'glass_button_theme.dart';

/// Opt-in presentation tokens. Farm workspaces and the mobile application do
/// not install this extension, so shared widgets keep their existing styles.
@immutable
class PersonalDesktopTheme extends ThemeExtension<PersonalDesktopTheme> {
  const PersonalDesktopTheme({this.cardOpacity = 0.60, this.radius = 16});
  final double cardOpacity;
  final double radius;

  static PersonalDesktopTheme? of(BuildContext context) =>
      Theme.of(context).extension<PersonalDesktopTheme>();

  @override
  PersonalDesktopTheme copyWith({double? cardOpacity, double? radius}) =>
      PersonalDesktopTheme(
        cardOpacity: cardOpacity ?? this.cardOpacity,
        radius: radius ?? this.radius,
      );

  @override
  PersonalDesktopTheme lerp(covariant PersonalDesktopTheme? other, double t) =>
      other == null
      ? this
      : PersonalDesktopTheme(
          cardOpacity: cardOpacity + (other.cardOpacity - cardOpacity) * t,
          radius: radius + (other.radius - radius) * t,
        );
}

Color personalDesktopCanvas(Brightness brightness) =>
    brightness == Brightness.dark
    ? const Color(0xFF171A18)
    : const Color(0xFFF4F6F5);

Color personalDesktopAccentText(ThemeData theme) =>
    theme.brightness == Brightness.dark
    ? theme.colorScheme.primary
    : Color.lerp(theme.colorScheme.primary, Colors.black, 0.4)!;

Color personalDesktopGlassFill(ThemeData theme, {double opacity = 0.6}) =>
    (theme.brightness == Brightness.dark
            ? AppColors.glassFillL1Dark
            : Colors.white)
        .withValues(alpha: opacity);

Color personalDesktopGlassRim(ThemeData theme) =>
    theme.brightness == Brightness.dark
    ? const Color(0x20FFFFFF)
    : const Color(0xB3FFFFFF);

/// Keep the desktop's compact controls and typography scale. Only its material
/// and valid font fallback are aligned with the approved phone presentation.
ThemeData buildPersonalDesktopTheme(
  ThemeData base, {
  required bool personalProduct,
  required bool studioMode,
}) {
  if (!personalProduct || studioMode) return base;
  final dark = base.brightness == Brightness.dark;
  final families = AppTypography.chineseFontFamily
      .split(',')
      .map((s) => s.trim())
      .toList();
  TextStyle? normalize(TextStyle? style) => style?.copyWith(
    fontFamily: families.first,
    fontFamilyFallback: [
      ...families.skip(1),
      'Noto Sans CJK SC',
      'Noto Sans SC',
    ],
  );
  final source = base.textTheme;
  final text = TextTheme(
    displayLarge: normalize(source.displayLarge),
    displayMedium: normalize(source.displayMedium),
    displaySmall: normalize(source.displaySmall),
    headlineLarge: normalize(source.headlineLarge),
    headlineMedium: normalize(source.headlineMedium),
    headlineSmall: normalize(source.headlineSmall),
    titleLarge: normalize(source.titleLarge),
    titleMedium: normalize(source.titleMedium),
    titleSmall: normalize(source.titleSmall),
    bodyLarge: normalize(source.bodyLarge),
    bodyMedium: normalize(source.bodyMedium),
    bodySmall: normalize(source.bodySmall),
    labelLarge: normalize(source.labelLarge),
    labelMedium: normalize(source.labelMedium),
    labelSmall: normalize(source.labelSmall),
  );
  final rim = personalDesktopGlassRim(base);
  final field = personalDesktopGlassFill(base, opacity: dark ? 0.5 : 0.62);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  final action = Color.lerp(
    base.colorScheme.primary,
    dark ? Colors.white : Colors.black,
    dark ? 0.16 : 0.25,
  )!;
  return applyGlassButtonTheme(
    base.copyWith(
      extensions: [
        ...base.extensions.values.where((e) => e is! PersonalDesktopTheme),
        const PersonalDesktopTheme(),
      ],
      textTheme: text,
      primaryTextTheme: text,
      scaffoldBackgroundColor: personalDesktopCanvas(base.brightness),
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: normalize(base.appBarTheme.titleTextStyle),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: field,
        filled: true,
        labelStyle: text.bodyMedium,
        hintStyle: text.bodyMedium?.copyWith(
          color: base.colorScheme.onSurfaceVariant,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: rim),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: base.colorScheme.primary, width: 1.3),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: action,
          foregroundColor: dark ? const Color(0xFF102019) : Colors.white,
          textStyle: text.labelLarge,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: base.colorScheme.onSurface,
          backgroundColor: field,
          textStyle: text.labelLarge,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          shape: shape,
          side: BorderSide(color: rim),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: personalDesktopAccentText(base),
          textStyle: text.labelMedium,
          minimumSize: const Size(32, 32),
          shape: shape,
        ),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: Color.alphaBlend(
          field,
          personalDesktopCanvas(base.brightness),
        ),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: rim),
        ),
      ),
      popupMenuTheme: base.popupMenuTheme.copyWith(
        color: Color.alphaBlend(field, personalDesktopCanvas(base.brightness)),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: rim),
        ),
        textStyle: text.bodySmall,
      ),
    ),
  );
}
