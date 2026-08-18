/// Settings tab: theme (light/dark/system), Material You accent selection,
/// mesh transport + permissions, identity and protocol readouts.
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'hud_theme.dart';

const _seedSwatches = <(String, Color)>[
  ('GREEN', Color(0xFF00FF9C)),
  ('CYAN', Color(0xFF00D9FF)),
  ('AMBER', Color(0xFFFFB300)),
  ('RED', Color(0xFFFF3B30)),
  ('VIOLET', Color(0xFFB388FF)),
  ('BLUE', Color(0xFF448AFF)),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _permStatus = '…';
  bool _permInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_permInitialized) {
      _permInitialized = true;
      _permStatus = AppScope.of(context).mesh.adapter.status;
    }
  }

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
                      Text('THEME MODE',
                          style: TextStyle(
                              color: p.textDim,
                              fontFamily: 'monospace',
                              fontSize: 11)),
                      const SizedBox(height: 6),
                      SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('SYSTEM'),
                            icon: Icon(Icons.brightness_auto),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text('LIGHT'),
                            icon: Icon(Icons.light_mode),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text('DARK'),
                            icon: Icon(Icons.dark_mode),
                          ),
                        ],
                        selected: {app.themeMode},
                        onSelectionChanged: (s) =>
                            app.setThemeMode(s.first),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Text('MATERIAL YOU ACCENT (SYSTEM)',
                              style: TextStyle(
                                  color: p.textDim,
                                  fontFamily: 'monospace',
                                  fontSize: 11)),
                          const Spacer(),
                          Switch(
                            value: app.useSystemDynamic,
                            activeThumbColor: p.primary,
                            onChanged: app.useSystemDynamic
                                ? (v) => app.setUseSystemDynamic(v)
                                : null,
                          ),
                        ],
                      ),
                      if (!app.useSystemDynamic) ...[
                        const SizedBox(height: 8),
                        Text('PRIMARY ACCENT',
                            style: TextStyle(
                                color: p.textDim,
                                fontFamily: 'monospace',
                                fontSize: 11)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final (name, color) in _seedSwatches)
                              Tooltip(
                                message: '$name (${color.toARGB32().toRadixString(16).toUpperCase()})',
                                child: InkWell(
                                  onTap: () =>
                                      app.setSeedColor(color),
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
                                        ? Icon(Icons.check,
                                            color: p.text, size: 18)
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
                  title: 'MESH UPLINK',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text('SIMULATED TRANSPORT',
                              style: TextStyle(
                                  color: p.textDim,
                                  fontFamily: 'monospace',
                                  fontSize: 11)),
                          const Spacer(),
                          Switch(
                            value: app.useSimulator,
                            activeThumbColor: p.primary,
                            onChanged: (v) {
                              app.setUseSimulator(v);
                              _permStatus = app.mesh.adapter.status;
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      HduReadout('ADAPTER', app.mesh.adapter.name),
                      const SizedBox(height: 2),
                      HduReadout('STATUS', _permStatus),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: () async {
                          final status = await app.requestMeshPermissions();
                          if (!mounted) return;
                          setState(() => _permStatus = status);
                        },
                        icon: const Icon(Icons.lock_open),
                        label: const Text('REQUEST PERMISSIONS',
                            style: TextStyle(
                                fontFamily: 'monospace', letterSpacing: 1)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'IDENTITY',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HduReadout('CITIZEN', app.citizenId),
                      const SizedBox(height: 2),
                      HduReadout('OFFICER',
                          app.officerId ?? '— not enlisted —'),
                      const SizedBox(height: 2),
                      HduReadout(
                          'NODE',
                          app.mesh.nodeId
                              .toRadixString(16)
                              .padLeft(4, '0')
                              .toUpperCase()),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'ABOUT',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const HduReadout('PROTOCOL',
                          'AapadSetu mesh v1 · 18B frame · CRC-8 · TTL5'),
                      const SizedBox(height: 2),
                      const HduReadout('RATION TOKEN',
                          'TOTP-HMAC-SHA256 · 30s window'),
                      const SizedBox(height: 2),
                      const HduReadout('LEDGER',
                          'SHA-256 hash chain · daily duplicate rejection'),
                      const SizedBox(height: 2),
                      const HduReadout('ENLISTMENT',
                          'RSA-signed master key · air-gapped'),
                    ],
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