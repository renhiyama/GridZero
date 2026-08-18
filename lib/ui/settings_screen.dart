/// Settings tab: theme (light/dark/system), accent selection, mesh link status
/// and identity. Deliberately minimal — no radio/transport jargon for the end
/// user; technical detail lives in the HUD, not here.
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import 'hud_theme.dart';

const _seedSwatches = <(String, Color)>[
  ('GREEN', Color(0xFF00FF9C)),
  ('CYAN', Color(0xFF00D9FF)),
  ('AMBER', Color(0xFFFFB300)),
  ('RED', Color(0xFFFF3B30)),
  ('VIOLET', Color(0xFFB388FF)),
  ('BLUE', Color(0xFF448AFF)),
];

class _LocationRows extends StatelessWidget {
  const _LocationRows({required this.mesh});

  final dynamic mesh;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<int, dynamic>>(
      stream: mesh.nodeUpdates,
      builder: (context, _) {
        if (mesh.gpsFix) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HduReadout('LAT', '${mesh.gpsLatitude!.toStringAsFixed(5)}'),
              const SizedBox(height: 2),
              HduReadout('LONG', '${mesh.gpsLongitude!.toStringAsFixed(5)}'),
            ],
          );
        }
        if (mesh.approxLatitude != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HduReadout(
                'LAT (APPROX)',
                '${mesh.approxLatitude!.toStringAsFixed(5)} '
                    '· ${peopleCount(mesh.approxSourceCount)}',
              ),
              const SizedBox(height: 2),
              HduReadout(
                'LONG (APPROX)',
                '${mesh.approxLongitude!.toStringAsFixed(5)} '
                    '· ≈${mesh.approxRadiusKm!.toStringAsFixed(1)} km',
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HduReadout('POSITION', 'NO GPS HW FOUND'),
            const SizedBox(height: 2),
            const HduReadout('ESTIMATE', 'LOOKING FOR NEARBY PEOPLE'),
          ],
        );
      },
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              'SETTINGS',
              style: TextStyle(
                color: p.primary,
                fontFamily: 'monospace',
                fontSize: 16,
                letterSpacing: 3,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                HudPanel(
                  title: 'APPEARANCE',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'THEME',
                        style: TextStyle(
                          color: p.textDim,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 6),
                      HudSegmented<ThemeMode>(
                        options: const [
                          (ThemeMode.system, 'SYSTEM'),
                          (ThemeMode.light, 'LIGHT'),
                          (ThemeMode.dark, 'DARK'),
                        ],
                        value: app.themeMode,
                        onChanged: app.setThemeMode,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'USE DEVICE ACCENT COLOR',
                              style: TextStyle(
                                color: p.textDim,
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ),
                          HudToggle(
                            value: app.useSystemDynamic,
                            onChanged: (v) => app.setUseSystemDynamic(v),
                          ),
                        ],
                      ),
                      if (!app.useSystemDynamic) ...[
                        const SizedBox(height: 8),
                        Text(
                          'ACCENT COLOR',
                          style: TextStyle(
                            color: p.textDim,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final (name, color) in _seedSwatches)
                              Tooltip(
                                message:
                                    '$name (${color.toARGB32().toRadixString(16).toUpperCase()})',
                                child: InkWell(
                                  onTap: () => app.setSeedColor(color),
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: color,
                                      border: Border.all(
                                        color: app.seedColor == color
                                            ? p.text
                                            : p.primaryDim,
                                        width: app.seedColor == color ? 3 : 1,
                                      ),
                                    ),
                                    child: app.seedColor == color
                                        ? Icon(
                                            Icons.check,
                                            color: p.text,
                                            size: 18,
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'MESH LINK',
                  child: ListenableBuilder(
                    listenable: app,
                    builder: (context, _) {
                      final mesh = app.mesh!;
                      final nodes = mesh.nodes.length;
                      final ok = nodes > 0;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                color: ok ? p.primary : p.error,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                ok ? 'MESH LINK: OK' : 'MESH LINK: SCANNING…',
                                style: TextStyle(
                                  color: ok ? p.primary : p.error,
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ],
                          ),
                          if (!ok) ...[
                            const SizedBox(height: 6),
                            HduReadout('RADIO', mesh.adapter.status),
                          ],
                          const SizedBox(height: 6),
                          HduReadout('NEARBY PEOPLE', '$nodes'),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'IDENTITY',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HduReadout('CITIZEN ID', app.citizenId),
                      const SizedBox(height: 2),
                      _LocationRows(mesh: app.mesh),
                      if (app.officerId != null) ...[
                        const SizedBox(height: 2),
                        HduReadout('OFFICER ID', app.officerId!),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'ACCOUNT',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HduReadout('USER', app.username),
                      const SizedBox(height: 2),
                      HduReadout('ROLE', app.role.name.toUpperCase()),
                      const SizedBox(height: 10),
                      FilledButton(
                        onPressed: () => app.logout(),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            'LOG OUT',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'DANGER ZONE',
                  borderColor: p.error,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'DELETE ALL DATA & LOG OUT',
                        style: TextStyle(
                          color: p.error,
                          fontFamily: 'monospace',
                          fontSize: 12,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'WIPES THE LEDGER, ALL ACCOUNTS AND '
                        'PREFERENCES ON THIS DEVICE.',
                        style: TextStyle(
                          color: p.textDim,
                          fontFamily: 'monospace',
                          fontSize: 10,
                        ),
                      ),
                      const SizedBox(height: 10),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: p.error,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => _confirmDeleteAll(context, app),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            'DELETE ALL DATA & LOG OUT',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'ABOUT',
                  child: const HduReadout(
                    'AAPADSETU',
                    'air-gapped relief mesh · v1',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Destructive, so confirm before running. The whole point is to avoid a
/// reinstall, which is exactly why a careless tap must not erase everything.
Future<void> _confirmDeleteAll(BuildContext context, AppState app) async {
  final p = AppPalette.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text(
        'ERASE ALL DATA?',
        style: TextStyle(fontFamily: 'monospace'),
      ),
      content: const Text(
        'This wipes the local ledger, every account and all '
        'settings. It cannot be undone.',
        style: TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(
            'CANCEL',
            style: TextStyle(fontFamily: 'monospace'),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: p.error,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('ERASE', style: TextStyle(fontFamily: 'monospace')),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await app.deleteAllData();
}
