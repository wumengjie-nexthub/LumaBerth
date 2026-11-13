import 'dart:io';

import 'package:flutter/material.dart';

/// Quiet album design: neutral surfaces, one blue accent, semantic colors only.
/// Light follows the Google Photos / iOS Photos convention; dark is a true
/// neutral gray, not a tinted theme.
ThemeData albumTheme({Brightness brightness = Brightness.light}) {
  final dark = brightness == Brightness.dark;

  final accent = dark ? const Color(0xff8ab4f8) : const Color(0xff0b57d0);
  final surface = dark ? const Color(0xff131314) : Colors.white;
  final onSurface = dark ? const Color(0xffe3e3e3) : const Color(0xff202124);
  final secondaryText = dark ? const Color(0xff9aa0a6) : const Color(0xff5f6368);
  final lowest = dark ? const Color(0xff1e1f20) : const Color(0xfff8f9fa);
  final highest = dark ? const Color(0xff333537) : const Color(0xffe8eaed);
  final outline = dark ? const Color(0xff444746) : const Color(0xffdadce0);

  final colors = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    surface: surface,
  ).copyWith(
    primary: accent,
    onPrimary: dark ? const Color(0xff062e6f) : Colors.white,
    primaryContainer: dark ? const Color(0xff0842a0) : const Color(0xffd3e3fd),
    onPrimaryContainer: dark ? const Color(0xffd3e3fd) : const Color(0xff041e49),
    secondaryContainer: dark ? const Color(0xff1e2a3a) : const Color(0xffe8f0fe),
    onSecondaryContainer: dark ? const Color(0xffd3e3fd) : const Color(0xff174ea6),
    surface: surface,
    onSurface: onSurface,
    onSurfaceVariant: secondaryText,
    surfaceContainerLowest: lowest,
    surfaceContainerHighest: highest,
    outlineVariant: outline,
    error: dark ? const Color(0xfff28b82) : const Color(0xffb3261e),
    onError: dark ? const Color(0xff601410) : Colors.white,
    errorContainer: dark ? const Color(0xff8c1d18) : const Color(0xfff9dedc),
    onErrorContainer: dark ? const Color(0xfff9dedc) : const Color(0xff410e0b),
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: surface,
    fontFamily: Platform.isWindows ? 'Microsoft YaHei UI' : null,
  );

  final text = base.textTheme.copyWith(
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontSize: 26,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleSmall: base.textTheme.titleSmall?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      color: secondaryText,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
    ),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.5),
    bodySmall: base.textTheme.bodySmall?.copyWith(height: 1.45),
  );

  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(22));

  return base.copyWith(
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge?.copyWith(color: onSurface),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        shape: pill,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        shape: pill,
        side: BorderSide(color: outline),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: pill,
        textStyle: text.labelLarge,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: dark ? const Color(0xff1e1f20) : Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: colors.secondaryContainer,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? colors.onSecondaryContainer
              : secondaryText,
          size: 24,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelSmall?.copyWith(
          color: states.contains(WidgetState.selected)
              ? colors.onSecondaryContainer
              : secondaryText,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surface,
      indicatorColor: colors.secondaryContainer,
      selectedIconTheme: IconThemeData(color: colors.onSecondaryContainer),
      unselectedIconTheme: IconThemeData(color: secondaryText),
      selectedLabelTextStyle: text.labelMedium?.copyWith(
        color: colors.onSecondaryContainer,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: text.labelMedium?.copyWith(
        color: secondaryText,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: lowest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outline),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered)
            ? secondaryText
            : outline,
      ),
      radius: const Radius.circular(8),
      thickness: WidgetStateProperty.all(8),
      crossAxisMargin: 2,
    ),
    dividerTheme: DividerThemeData(color: outline, thickness: 1),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : null,
      ),
      checkColor: WidgetStateProperty.all(dark ? const Color(0xff062e6f) : Colors.white),
      shape: const CircleBorder(),
      side: BorderSide(color: dark ? Colors.white70 : Colors.white, width: 1.6),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.onPrimary
            : secondaryText,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : highest,
      ),
    ),
  );
}

/// Semantic success tone used for verified backups.
Color backupDoneColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff81c995)
    : const Color(0xff188038);
