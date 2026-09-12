import 'package:flutter/material.dart';

/// The farm workspace owns its complete visual system. It deliberately does
/// not read the personal workspace's color tokens or component themes.
abstract final class FarmPalette {
  static const primary = Color(0xFF008F36);
  static const primaryHover = Color(0xFF00782E);
  static const success = Color(0xFF168A45);
  static const warning = Color(0xFFD97706);
  static const danger = Color(0xFFD14343);
  static const info = Color(0xFF2563EB);
  static const violet = Color(0xFF6D5BD0);

  static const lightCanvas = Color(0xFFE8EFEB);
  static const lightSurface = Color(0xFFF8FBF9);
  static const lightSurfaceMuted = Color(0xFFDDE8E1);
  static const lightSurfaceSelected = Color(0xFFD2F0DB);
  static const lightText = Color(0xFF122019);
  static const lightTextSoft = Color(0xFF4D6255);
  static const lightMuted = Color(0xFF718579);
  static const lightLine = Color(0xFFC5D5CA);

  static const darkCanvas = Color(0xFF0B110E);
  static const darkSurface = Color(0xFF151D18);
  static const darkSurfaceMuted = Color(0xFF1D2921);
  static const darkSurfaceSelected = Color(0xFF173825);
  static const darkText = Color(0xFFF2F6F3);
  static const darkTextSoft = Color(0xFFB4BDB7);
  static const darkMuted = Color(0xFF7F8A83);
  static const darkLine = Color(0xFF343D37);

  static const radius = 8.0;
  static const controlRadius = 8.0;
  static const dialogRadius = 16.0;
  static const sidebarWidth = 252.0;
  static const sidebarCollapsedWidth = 72.0;
  static const topBarHeight = 62.0;
  static const controlHeight = 38.0;

  static Color accent(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  static Color rim(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0x24FFFFFF)
          : const Color(0xB3FFFFFF);

  static Color glassFill(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? darkSurface.withValues(alpha: 0.72)
          : Colors.white.withValues(alpha: 0.62);

  static List<BoxShadow> shadow(BuildContext context, {bool elevated = false}) =>
      [
        BoxShadow(
          color: Colors.black.withValues(
            alpha: Theme.of(context).brightness == Brightness.dark
                ? (elevated ? 0.18 : 0.10)
                : (elevated ? 0.07 : 0.035),
          ),
          blurRadius: elevated ? 24 : 16,
          offset: Offset(0, elevated ? 8 : 4),
        ),
      ];
}

/// Compatibility tokens for farm pages that need a direct semantic color.
/// They are configured by [FarmThemeScope] and never touch personal-mode
/// globals.
abstract final class FarmVisual {
  static const primary = FarmPalette.primary;
  static const blue = FarmPalette.info;
  static const warning = FarmPalette.warning;
  static const danger = FarmPalette.danger;
  static const violet = FarmPalette.violet;

  static Color text = FarmPalette.lightText;
  static Color textSoft = FarmPalette.lightTextSoft;
  static Color muted = FarmPalette.lightMuted;
  static Color line = FarmPalette.lightLine;
  static Color fill = FarmPalette.lightSurfaceMuted;
  static Color panel = FarmPalette.lightSurface;

  static void configure(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    text = dark ? FarmPalette.darkText : FarmPalette.lightText;
    textSoft = dark ? FarmPalette.darkTextSoft : FarmPalette.lightTextSoft;
    muted = dark ? FarmPalette.darkMuted : FarmPalette.lightMuted;
    line = dark ? FarmPalette.darkLine : FarmPalette.lightLine;
    fill = dark ? FarmPalette.darkSurfaceMuted : FarmPalette.lightSurfaceMuted;
    panel = dark ? FarmPalette.darkSurface : FarmPalette.lightSurface;
  }

  static TextStyle mono = const TextStyle(
    fontFamily: 'Cascadia Code',
    fontFamilyFallback: ['Consolas', 'Microsoft YaHei UI', 'monospace'],
    fontWeight: FontWeight.w700,
    color: FarmPalette.lightText,
    letterSpacing: 0,
  );

  static TextStyle title(BuildContext context) =>
      Theme.of(context).textTheme.titleLarge!.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
            letterSpacing: 0,
          );

  static TextStyle label(BuildContext context) =>
      Theme.of(context).textTheme.bodySmall!.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            letterSpacing: 0,
          );
}

class FarmThemeScope extends StatelessWidget {
  const FarmThemeScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    FarmVisual.configure(brightness);
    FarmVisual.mono = FarmVisual.mono.copyWith(
      color: brightness == Brightness.dark
          ? FarmPalette.darkText
          : FarmPalette.lightText,
    );
    return Theme(
      data: FarmThemeData.build(brightness),
      child: child,
    );
  }
}

abstract final class FarmThemeData {
  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final canvas = dark ? FarmPalette.darkCanvas : FarmPalette.lightCanvas;
    final surface = dark ? FarmPalette.darkSurface : FarmPalette.lightSurface;
    final surfaceMuted =
        dark ? FarmPalette.darkSurfaceMuted : FarmPalette.lightSurfaceMuted;
    final text = dark ? FarmPalette.darkText : FarmPalette.lightText;
    final textSoft =
        dark ? FarmPalette.darkTextSoft : FarmPalette.lightTextSoft;
    final line = dark ? FarmPalette.darkLine : FarmPalette.lightLine;
    final accent = dark ? const Color(0xFF70D795) : FarmPalette.primary;
    final rim = dark ? const Color(0x32FFFFFF) : const Color(0xFFFFFFFF);
    final field = dark ? const Color(0xFF1B271F) : const Color(0xFFFFFFFF);
    final scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: dark ? const Color(0xFF102A1B) : Colors.white,
      primaryContainer: dark
          ? FarmPalette.darkSurfaceSelected
          : FarmPalette.lightSurfaceSelected,
      onPrimaryContainer:
          dark ? const Color(0xFFB9F2CD) : const Color(0xFF0B5A2B),
      secondary: dark ? const Color(0xFF65A5FF) : FarmPalette.info,
      onSecondary: Colors.white,
      secondaryContainer:
          dark ? const Color(0xFF1B304E) : const Color(0xFFEAF1FF),
      onSecondaryContainer:
          dark ? const Color(0xFFC9DCFF) : const Color(0xFF183B70),
      tertiary: FarmPalette.warning,
      onTertiary: Colors.white,
      tertiaryContainer:
          dark ? const Color(0xFF4A3115) : const Color(0xFFFFF2DE),
      onTertiaryContainer:
          dark ? const Color(0xFFFFD29A) : const Color(0xFF77410A),
      error: dark ? const Color(0xFFFF9393) : FarmPalette.danger,
      onError: Colors.white,
      errorContainer: dark ? const Color(0xFF4B2022) : const Color(0xFFFFEAEA),
      onErrorContainer:
          dark ? const Color(0xFFFFC7C7) : const Color(0xFF7F1D1D),
      surface: surface,
      onSurface: text,
      surfaceContainerLowest: canvas,
      surfaceContainerLow: surfaceMuted,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceMuted,
      surfaceContainerHighest: surfaceMuted,
      onSurfaceVariant: textSoft,
      outline: line,
      outlineVariant: line,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: text,
      onInverseSurface: surface,
      inversePrimary: const Color(0xFF68D58D),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      dividerColor: line,
      fontFamily: 'HarmonyOS Sans',
      fontFamilyFallback: const [
        'Microsoft YaHei UI',
        'PingFang SC',
        'Noto Sans CJK SC',
        'Noto Sans SC',
        'sans-serif',
      ],
      visualDensity: VisualDensity.standard,
      splashFactory: InkRipple.splashFactory,
    );
    final textTheme = base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontSize: 24,
        height: 1.3,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 18,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 15,
        height: 1.3,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(
        fontSize: 14,
        height: 1.45,
        letterSpacing: 0,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: 13,
        height: 1.45,
        letterSpacing: 0,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        fontSize: 12,
        height: 1.4,
        color: textSoft,
        letterSpacing: 0,
      ),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      labelMedium: base.textTheme.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    );

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(FarmPalette.controlRadius),
    );
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(FarmPalette.controlRadius),
      borderSide: BorderSide(color: line),
    );
    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.30 : 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FarmPalette.radius),
          side: BorderSide(color: rim),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FarmPalette.dialogRadius),
          side: BorderSide(color: rim),
        ),
        titleTextStyle: textTheme.titleLarge?.copyWith(color: text),
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: textSoft),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: field,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        hintStyle: TextStyle(
            color: dark ? FarmPalette.darkMuted : FarmPalette.lightMuted),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
        labelStyle: TextStyle(color: textSoft, fontSize: 12),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, FarmPalette.controlHeight),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          elevation: 0,
          shape: shape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, FarmPalette.controlHeight),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          foregroundColor: text,
          backgroundColor: field,
          side: BorderSide(color: rim),
          shape: shape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: shape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(36),
          maximumSize: const Size.square(36),
          padding: EdgeInsets.zero,
          shape: shape,
          foregroundColor: textSoft,
          backgroundColor: field,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surfaceMuted,
        selectedColor: dark
            ? FarmPalette.darkSurfaceSelected
            : FarmPalette.lightSurfaceSelected,
        side: BorderSide(color: line),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        labelStyle: textTheme.labelMedium,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          side: WidgetStatePropertyAll(BorderSide(color: line)),
          elevation: const WidgetStatePropertyAll(8),
          shape: WidgetStatePropertyAll(shape),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: shape,
        textStyle: textTheme.bodyMedium?.copyWith(color: text),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFEDF1EE) : const Color(0xFF202722),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(
          color: dark ? const Color(0xFF202722) : Colors.white,
          fontSize: 12,
        ),
        waitDuration: const Duration(milliseconds: 450),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: dark ? FarmPalette.darkLine : const Color(0xFFE2E8E4),
        borderRadius: BorderRadius.circular(99),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textSoft,
        textColor: text,
        selectedColor: accent,
        selectedTileColor: scheme.primaryContainer,
        shape: shape,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll(surfaceMuted.withValues(alpha: 0.65)),
        headingTextStyle: textTheme.labelLarge?.copyWith(color: textSoft),
        dataTextStyle: textTheme.bodyMedium?.copyWith(color: text),
        dividerThickness: 0.6,
        columnSpacing: 24,
        horizontalMargin: 16,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: accent,
        unselectedLabelColor: textSoft,
        labelStyle: textTheme.labelLarge,
        unselectedLabelStyle: textTheme.bodyMedium,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(FarmPalette.controlRadius),
          border: Border.all(color: accent.withValues(alpha: 0.18)),
        ),
        indicatorColor: accent,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: accent,
        textColor: text,
        collapsedTextColor: text,
        collapsedIconColor: textSoft,
        shape: shape,
        collapsedShape: shape,
      ),
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(99),
        thickness: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) ? 8 : 5,
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => textSoft.withValues(
            alpha: states.contains(WidgetState.hovered) ? 0.45 : 0.24,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
    );
  }
}
