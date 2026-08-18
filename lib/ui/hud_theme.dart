/// OLED cyber-industrial HUD theme (FEAT-UI-01).
///
/// Structure (grid lines, 1px borders, monospace, glowing halos) is fixed;
/// the accent palette is generated from a user-selected seed colour — either
/// the platform's Material You colour (Android 12+) or a manual pick. Only
/// the accent set changes, not full Material You theming.
library;

import 'package:flutter/material.dart';

/// Resolved palette for the current theme/brightness. Widgets read this via
/// [AppPalette.of] instead of hard-coding the original green.
class AppPalette {
  const AppPalette({
    required this.primary,
    required this.primaryDim,
    required this.secondary,
    required this.error,
    required this.bg,
    required this.panel,
    required this.grid,
    required this.text,
    required this.textDim,
  });

  final Color primary;
  final Color primaryDim;
  final Color secondary;
  final Color error;
  final Color bg;
  final Color panel;
  final Color grid;
  final Color text;
  final Color textDim;

  static AppPalette of(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final dark = s.brightness == Brightness.dark;
    return AppPalette(
      primary: s.primary,
      primaryDim: s.primary.withValues(alpha: dark ? 0.5 : 0.6),
      secondary: s.secondary,
      error: s.error,
      bg: dark ? const Color(0xFF000805) : const Color(0xFFF2F8F5),
      panel: dark ? const Color(0xFF04120C) : const Color(0xFFEAF4EF),
      grid: dark ? const Color(0xFF0A2A1C) : const Color(0xFFCFE3D8),
      text: dark ? const Color(0xFFBFEED9) : const Color(0xFF0B2218),
      textDim: dark ? const Color(0xFF4E7A64) : const Color(0xFF5C7A6C),
    );
  }
}

/// Default seed used before any user selection (legacy AapadSetu green).
const Color kDefaultSeed = Color(0xFF00FF9C);

abstract final class HudTheme {
  static ThemeData dark = build(
    seed: kDefaultSeed,
    brightness: Brightness.dark,
  );

  static ThemeData build({
    required Color seed,
    required Brightness brightness,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final dark = brightness == Brightness.dark;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
    );
    return base.copyWith(
      scaffoldBackgroundColor: dark
          ? const Color(0xFF000805)
          : const Color(0xFFF2F8F5),
      splashFactory: NoSplash.splashFactory,
      dividerColor: scheme.primary.withValues(alpha: 0.4),
      textTheme: base.textTheme.apply(
        fontFamily: 'monospace',
        bodyColor: dark ? const Color(0xFFBFEED9) : const Color(0xFF0B2218),
        displayColor: dark ? const Color(0xFFBFEED9) : const Color(0xFF0B2218),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: dark
            ? const Color(0xFF000805)
            : const Color(0xFFF2F8F5),
        elevation: 0,
        titleTextStyle: TextStyle(
          color: scheme.primary,
          fontFamily: 'monospace',
          fontSize: 16,
          letterSpacing: 2,
        ),
        iconTheme: IconThemeData(color: scheme.primary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(
          borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.5)),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: scheme.primary),
        ),
        labelStyle: TextStyle(
          color: dark ? const Color(0xFF4E7A64) : const Color(0xFF5C7A6C),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: dark ? const Color(0xFF000805) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: dark
            ? const Color(0xFF4E7A64)
            : const Color(0xFF5C7A6C),
        indicatorColor: scheme.primary,
      ),
    );
  }
}

/// Structural 1px bordered panel with a glowing top rule.
class HudPanel extends StatelessWidget {
  const HudPanel({
    super.key,
    required this.child,
    this.title,
    this.borderColor,
  });

  final Widget child;
  final String? title;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final color = borderColor ?? p.primaryDim;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1),
        color: p.panel.withValues(alpha: 0.6),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.18), blurRadius: 6),
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Row(
              children: [
                Container(width: 6, height: 6, color: color),
                const SizedBox(width: 6),
                Text(
                  title!,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}

/// Single-line telemetry readout label:value.
class HduReadout extends StatelessWidget {
  const HduReadout(
    this.label,
    this.value, {
    super.key,
    this.color,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? color;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return RichText(
      text: TextSpan(
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(color: p.textDim),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
              color: valueColor ?? color ?? p.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// Blinking warning strip for anti-fraud alerts.
class HudAlertBar extends StatelessWidget {
  const HudAlertBar(this.message, {super.key, this.color});

  final String message;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppPalette.of(context).error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: c),
        color: c.withValues(alpha: 0.12),
        boxShadow: [BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 8)],
      ),
      child: Text(
        '!! $message',
        style: TextStyle(
          color: c,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }
}
