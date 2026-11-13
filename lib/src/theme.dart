import 'dart:io';

import 'package:flutter/material.dart';

ThemeData albumTheme() {
  const blue = Color(0xff006fe6);
  const secondaryText = Color(0xff6e6e73);
  final colors = ColorScheme.fromSeed(seedColor: blue, surface: Colors.white)
      .copyWith(
        primary: blue,
        onPrimary: Colors.white,
        primaryContainer: const Color(0xffe8f2ff),
        onPrimaryContainer: const Color(0xff004c9e),
        surface: Colors.white,
        onSurface: const Color(0xff1c1c1e),
        onSurfaceVariant: secondaryText,
        surfaceContainerLowest: const Color(0xfff2f2f7),
        surfaceContainerHighest: const Color(0xffe5e5ea),
        outlineVariant: const Color(0xffe5e5ea),
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    fontFamily: Platform.isWindows ? 'Microsoft YaHei UI' : null,
  );
  final text = base.textTheme.copyWith(
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    ),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));

  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: colors.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge?.copyWith(color: colors.onSurface),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: shape,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: shape,
        side: BorderSide(color: colors.outlineVariant),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: shape,
        textStyle: text.labelLarge,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 70,
      backgroundColor: const Color(0xfffafafa),
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? blue : secondaryText,
          size: 24,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelSmall?.copyWith(
          color: states.contains(WidgetState.selected) ? blue : secondaryText,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colors.surface,
      indicatorColor: Colors.transparent,
      selectedIconTheme: const IconThemeData(color: blue),
      unselectedIconTheme: const IconThemeData(color: secondaryText),
      selectedLabelTextStyle: text.labelMedium?.copyWith(
        color: blue,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: text.labelMedium?.copyWith(
        color: secondaryText,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
