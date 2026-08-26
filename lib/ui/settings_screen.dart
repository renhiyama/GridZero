/// Settings tab: theme (light/dark/system), accent selection, mesh link status
/// and identity. Deliberately minimal: no radio/transport jargon for the end
/// user; technical detail lives in the HUD, not here.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/provision_packet.dart';
import 'face_enroll_page.dart';
import 'hud_theme.dart';
import 'provision_scan_page.dart';

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
            child: HudScroll(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
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
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'SHOW TECHNICAL DETAILS',
                                  style: TextStyle(
                                    color: p.textDim,
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'packet info, IDs and radio readouts: '
                                  'turn on only for demos',
                                  style: TextStyle(
                                    color: p.textDim,
                                    fontFamily: 'monospace',
                                    fontSize: 9,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          HudToggle(
                            value: app.showDebugInfo,
                            onChanged: (v) => app.setShowDebugInfo(v),
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
                            // Missing BLE permissions are the usual cause
                            // on a fresh phone; Android silently ignores
                            // re-requests after a denial, so give the user
                            // an explicit path back.
                            if (mesh.adapter.status.contains('missing:')) ...[
                              const SizedBox(height: 8),
                              FilledButton.icon(
                                onPressed: () async {
                                  final result = await app
                                      .requestMeshPermissions();
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      backgroundColor: p.primary,
                                      content: Text(
                                        result,
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.key, size: 16),
                                label: const Text(
                                  'GRANT BLUETOOTH PERMISSIONS',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              const HduReadout(
                                'HINT',
                                'denied earlier? enable Bluetooth + Location '
                                'for GridZero in system settings',
                              ),
                            ],
                          ],
                          const SizedBox(height: 6),
                          HduReadout('NEARBY PEOPLE', '$nodes'),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                const _DataLinkPanel(),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'RESPONSE ALERT',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'RING VOLUME WHEN A RESPONDER '
                        'ACKS YOUR SOS (PLAYED VIA SPEAKER)',
                        style: TextStyle(
                          color: p.textDim,
                          fontFamily: 'monospace',
                          fontSize: 10,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 2,
                                activeTrackColor: p.primary,
                                inactiveTrackColor: p.primaryDim,
                                thumbColor: p.primary,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 10,
                                ),
                                overlayColor: p.primary.withValues(alpha: 0.2),
                              ),
                              child: Slider(
                                min: 0,
                                max: 1,
                                value: app.respondAlertVolume,
                                onChanged: app.setRespondAlertVolume,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '${(app.respondAlertVolume * 100).round()}%',
                            style: TextStyle(
                              color: p.primary,
                              fontFamily: 'monospace',
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
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
                      HduReadout('AADHAAR', app.citizenId),
                      if (app.familyId != null) ...[
                        const SizedBox(height: 2),
                        HduReadout('RATION', app.familyId!),
                      ],
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
                      if (app.role == Role.citizen) ...[
                        const SizedBox(height: 10),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: p.primaryDim,
                            foregroundColor: p.text,
                          ),
                          onPressed: () => _provisionOfficer(context, app),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: Text(
                              'BECOME OFFICER (SCAN HQ QR)',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                letterSpacing: 1,
                              ),
                            ),
                          ),
                        ),
                      ] else if (app.role == Role.officer) ...[
                        const SizedBox(height: 10),
                        Text(
                          'OFFICER: APPLIED',
                          style: TextStyle(
                            color: p.primary,
                            fontFamily: 'monospace',
                            fontSize: 11,
                            letterSpacing: 1,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'enlisted · claims signed on this device',
                          style: TextStyle(
                            color: p.textDim,
                            fontFamily: 'monospace',
                            fontSize: 10,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      FilledButton(
                        onPressed: () => _reEnrollFace(context, app),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            'FACE ENROLL / RE-ENROLL',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ),
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
                          foregroundColor: onColor(p.error),
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
                    'GRIDZERO',
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

/// Officer promotion now routes through HQ provisioning instead of
/// self-enlistment: the user scans the CREATE OFFICER ACCOUNT QR shown on the
/// Command HQ dashboard. HQ stays the source of truth for who is an officer.
Future<void> _provisionOfficer(BuildContext context, AppState app) async {
  final payload = await Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => const ProvisionScanPage(
                  label: 'OFFICER PROVISIONING',
                  expectedType: ProvisionType.account,
                ),
    ),
  );
  if (payload == null || !context.mounted) return;
  final result = await app.provisionAccount(payload);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        result ?? 'OFFICER ENLISTED',
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      backgroundColor: result == null
          ? AppPalette.of(context).primaryDim
          : AppPalette.of(context).error,
    ),
  );
}

/// Re-captures (or adds) the enrolled face for the current account.
Future<void> _reEnrollFace(BuildContext context, AppState app) async {
  final embedding = await Navigator.of(context).push<Float32List>(
    MaterialPageRoute(builder: (_) => const FaceEnrollPage()),
  );
  if (embedding == null || !context.mounted) return;
  await app.saveFaceEmbedding(app.username, embedding);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        app.faceSyncedToHq
            ? 'FACE ENROLLED: already collected by HQ'
            : 'FACE ENROLLED: HQ collects it on your next link exchange',
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    ),
  );
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
            foregroundColor: onColor(p.error),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('ERASE', style: TextStyle(fontFamily: 'monospace')),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await app.deleteAllData();
}

/// HQ data link (client side): hosts the direct link so the HQ laptop can
/// pull this device's fresh data (face embedding, records) and push its own
/// DB down in the same session. Available to every logged-in role: the
/// reverse push is how a citizen's enrolment reaches HQ.
class _DataLinkPanel extends StatelessWidget {
  const _DataLinkPanel();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    return HudPanel(
      title: 'HQ DATA LINK',
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HduReadout(
                'STATUS',
                app.hotspotActive
                    ? (app.lastSyncStep ?? 'WAITING FOR LINK: scan the QR '
                        'on the HQ laptop')
                    : 'IDLE: tap READY TO SYNC when at an HQ desk',
                color: app.hotspotActive ? p.primary : p.textDim,
              ),
              if (app.lastDataExchangeAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: HduReadout(
                    'LAST EXCHANGE',
                    _clockText(app.lastDataExchangeAt!),
                    color: p.primary,
                  ),
                ),
              // Face data is device-local until an HQ exchange collects it.
              ListenableBuilder(
                listenable: app,
                builder: (context, _) {
                  final enrolled = app.lastFaceEnrollAt != null;
                  if (!enrolled) {
                    return const SizedBox.shrink();
                  }
                  final synced = app.faceSyncedToHq;
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: HduReadout(
                      'FACE DATA',
                      synced
                          ? 'COLLECTED BY HQ · '
                              '${_clockText(app.lastDataExchangeAt!)}'
                          : 'ON THIS DEVICE ONLY: HQ collects it on your '
                              'next link exchange',
                      color: synced ? p.primary : p.textDim,
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () async {
                  String? error;
                  if (app.hotspotActive) {
                    await app.stopOfficerHotspot();
                  } else {
                    error = await app.startOfficerHotspot();
                  }
                  if (!context.mounted) return;
                  if (error != null) {
                    // Surface the real failure; jargon only appears here.
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: p.error,
                        content: Text(error,
                            style:
                                const TextStyle(fontFamily: 'monospace')),
                      ),
                    );
                  }
                },
                icon: Icon(
                  app.hotspotActive
                      ? Icons.link_off
                      : Icons.link,
                  size: 18,
                ),
                label: Text(
                  app.hotspotActive
                      ? 'CANCEL'
                      : 'READY TO SYNC: SCAN HQ QR',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Compact HH:MM clock text for sync timestamps.
String _clockText(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
