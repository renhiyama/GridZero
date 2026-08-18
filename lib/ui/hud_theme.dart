/// OLED cyber-industrial HUD theme (FEAT-UI-01): black canvas, phosphor
/// green/amber accents, 1px structural borders and glowing halos.
library;

import 'package:flutter/material.dart';

abstract final class HudColors {
  static const Color bg = Color(0xFF000805);
  static const Color panel = Color(0xFF04120C);
  static const Color grid = Color(0xFF0A2A1C);
  static const Color primary = Color(0xFF00FF9C);
  static const Color primaryDim = Color(0xFF007A4D);
  static const Color amber = Color(0xFFFFB300);
  static const Color alert = Color(0xFFFF3B30);
  static const Color cyan = Color(0xFF00E5FF);
  static const Color text = Color(0xFFBFEED9);
  static const Color textDim = Color(0xFF4E7A64);
}

abstract final class HudTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: HudColors.bg,
      colorScheme: base.colorScheme.copyWith(
        primary: HudColors.primary,
        secondary: HudColors.amber,
        surface: HudColors.panel,
      ),
      splashFactory: NoSplash.splashFactory,
      dividerColor: HudColors.primaryDim,
      textTheme: base.textTheme.apply(
        fontFamily: 'monospace',
        bodyColor: HudColors.text,
        displayColor: HudColors.text,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: HudColors.bg,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: HudColors.primary,
          fontFamily: 'monospace',
          fontSize: 16,
          letterSpacing: 2,
        ),
        iconTheme: IconThemeData(color: HudColors.primary),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(
          borderSide: BorderSide(color: HudColors.primaryDim),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: HudColors.primaryDim),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: HudColors.primary),
        ),
        labelStyle: TextStyle(color: HudColors.textDim),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: HudColors.primary,
          foregroundColor: HudColors.bg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: HudColors.primary,
        unselectedLabelColor: HudColors.textDim,
        indicatorColor: HudColors.primary,
      ),
    );
  }
}

/// Structural 1px bordered panel with a glowing top rule.
class HudPanel extends StatelessWidget {
  const HudPanel({super.key, required this.child, this.title, this.borderColor});

  final Widget child;
  final String? title;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final color = borderColor ?? HudColors.primaryDim;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1),
        color: HudColors.panel.withValues(alpha: 0.6),
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
                Container(
                  width: 6,
                  height: 6,
                  color: color,
                ),
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
    this.color = HudColors.primary,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color color;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        children: [
          TextSpan(text: '$label: ', style: TextStyle(color: HudColors.textDim)),
          TextSpan(
            text: value,
            style: TextStyle(
              color: valueColor ?? color,
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
  const HudAlertBar(this.message, {super.key, this.color = HudColors.alert});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        color: color.withValues(alpha: 0.12),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 8),
        ],
      ),
      child: Text(
        '!! $message',
        style: TextStyle(
          color: color,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }
}
