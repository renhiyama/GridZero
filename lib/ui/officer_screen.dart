/// Persona B: Field Relief Officer. QR verification, hash-chain ledger and
/// tactical map HUD.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/ledger/ledger_store.dart';
import '../core/mesh_packet.dart';
import 'hud_theme.dart';
import 'linux_qr_scan_page.dart';
import 'mesh_map.dart';

class OfficerScreen extends StatefulWidget {
  const OfficerScreen({super.key});

  @override
  State<OfficerScreen> createState() => _OfficerScreenState();
}

class _OfficerScreenState extends State<OfficerScreen> {
  ClaimResult? _lastClaim;
  // mobile_scanner covers Android/iOS/macOS; Linux uses the V4L2 path.
  final bool _cameraUsable =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    return SafeArea(
      child: app.officerId == null
          ? _EnlistGate(app: app, cameraUsable: _cameraUsable)
          : DefaultTabController(
              length: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: p.primary),
                            color: p.primary.withValues(alpha: 0.12),
                          ),
                          child: Text(
                            'OFFICER ▸ ${app.officerId}',
                            style: TextStyle(
                              color: p.primary,
                              fontFamily: 'monospace',
                              fontSize: 12,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => app.switchRole(Role.citizen),
                          icon: Icon(Icons.logout, color: p.textDim, size: 18),
                          tooltip: 'Return to citizen mode',
                        ),
                      ],
                    ),
                  ),
                  const TabBar(
                    tabs: [
                      Tab(text: 'SCAN'),
                      Tab(text: 'LEDGER'),
                      Tab(text: 'MAP'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _ScanTab(
                          app: app,
                          cameraUsable: _cameraUsable,
                          onResult: (r) => setState(() => _lastClaim = r),
                        ),
                        _LedgerTab(app: app),
                        _MapTab(app: app),
                      ],
                    ),
                  ),
                  if (_lastClaim != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: HudAlertBar(
                        _claimText(_lastClaim!),
                        color: _lastClaim!.ok ? p.primary : p.error,
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  String _claimText(ClaimResult r) =>
      '${r.status.name.toUpperCase()}: ${r.message}';
}

/// Picks the scanner implementation for the current platform.
Widget _scannerPageFor(String label) =>
    defaultTargetPlatform == TargetPlatform.linux
    ? LinuxQrScanPage(label: label)
    : _QrScanPage(label: label);

class _EnlistGate extends StatelessWidget {
  const _EnlistGate({required this.app, required this.cameraUsable});

  final dynamic app;
  final bool cameraUsable;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        HudPanel(
          title: 'OFFICER ENLISTMENT / AIR-GAPPED',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const HduReadout(
                'REQ',
                'Scan the ENLISTMENT QR on the Command HQ tab. No internet.',
              ),
              const SizedBox(height: 12),
              if (cameraUsable) ...[
                _EnlistScanButton(app: app),
                const SizedBox(height: 12),
                HduReadout(
                  'NOTE',
                  'Open HQ ▸ ENLISTMENT QR on the signing device and point '
                      'this camera at it.',
                  color: p.textDim,
                ),
              ] else
                HudAlertBar(
                  'NO CAMERA ON THIS DEVICE — RUN OFFICER MODE ON A PHONE',
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EnlistScanButton extends StatelessWidget {
  const _EnlistScanButton({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return FilledButton.icon(
      onPressed: () async {
        final payload = await Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => _scannerPageFor('MASTER KEY')),
        );
        if (payload == null || !context.mounted) return;
        final check = await app.enlistOfficer(payload);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: check.ok ? p.primary : p.error,
            content: Text(check.ok ? 'OFFICER ENLISTED' : check.message),
          ),
        );
      },
      icon: const Icon(Icons.qr_code_scanner),
      label: const Text(
        'SCAN MASTER KEY QR',
        style: TextStyle(fontFamily: 'monospace'),
      ),
    );
  }
}

/// Camera scan page returning the first decoded QR payload. Requests the
/// camera runtime permission up front so the popup appears before the UI.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage({required this.label});

  final String label;

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  bool _done = false;
  bool _cameraGranted = false;

  @override
  void initState() {
    super.initState();
    _requestCamera();
  }

  Future<void> _requestCamera() async {
    // Linux uses the V4L2 page (no permission prompt).
    if (defaultTargetPlatform == TargetPlatform.linux) {
      if (mounted) setState(() => _cameraGranted = true);
      return;
    }
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;
      setState(() => _cameraGranted = status.isGranted);
    } catch (_) {
      if (mounted) setState(() => _cameraGranted = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.label)),
      body: _cameraGranted
          ? MobileScanner(
              onDetect: (capture) {
                if (_done) return;
                final raw = capture.barcodes
                    .map((b) => b.rawValue)
                    .whereType<String>()
                    .firstOrNull;
                if (raw != null) {
                  _done = true;
                  Navigator.of(context).pop(raw);
                }
              },
            )
          : Center(
              child: Text(
                _cameraGranted ? '' : 'CAMERA PERMISSION REQUIRED',
                style: const TextStyle(
                  color: Colors.white54,
                  fontFamily: 'monospace',
                ),
              ),
            ),
    );
  }
}

class _ScanTab extends StatefulWidget {
  const _ScanTab({
    required this.app,
    required this.cameraUsable,
    required this.onResult,
  });

  final dynamic app;
  final bool cameraUsable;
  final ValueChanged<ClaimResult> onResult;

  @override
  State<_ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<_ScanTab> {
  final _ctrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  String _rationCode = 'Rice';
  double _units = 1.0;
  bool _pinFallback = false;
  String? _lastCitizenId;

  static const _items = ['Rice', 'Water', 'Blanket', 'Medicine', 'Fuel'];
  static const _unitOptions = [0.25, 0.5, 0.75, 1.0];

  @override
  void dispose() {
    _ctrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<ClaimResult> _claim(String payload) => widget.app.claimFromPayload(
    payload,
    _rationCode,
    claimUnits: _units,
    fallbackPin: _pinFallback ? _pinCtrl.text.trim() : null,
  );

  /// The claim QR's `n` (display name) for the visual identity popup.
  String? _displayName(String payload) {
    try {
      final map = jsonDecode(payload);
      return map is Map<String, dynamic> ? map['n'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _showClaimResult(ClaimResult result, String payload) async {
    final p = AppPalette.of(context);
    widget.onResult(result);
    if (result.ok) {
      _lastCitizenId = result.record!.citizenId;
      final name = _displayName(payload);
      if (name != null) {
        await _showIdentityCard(result.record!.citizenId, name);
        if (!mounted) return;
      }
    }
    if (!mounted) return;
    final units = result.record?.claimUnits ?? _units;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: result.ok ? p.primary : p.error,
        content: Text(
          result.ok
              ? 'GRANTED ${units.toStringAsFixed(2)}U: '
                    '${result.record!.citizenId} / ${result.record!.rationCode}'
              : result.message,
        ),
      ),
    );
  }

  /// Photo popup: the citizen's identity card rendered from the claim QR
  /// (initials avatar + name) for a visual person check, used on the
  /// PIN-fallback path where the rotating token could not be trusted.
  Future<void> _showIdentityCard(String citizenId, String name) {
    final p = AppPalette.of(context);
    final initials = name
        .split(' ')
        .where((s) => s.isNotEmpty)
        .take(2)
        .map((s) => s[0].toUpperCase())
        .join();
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: p.panel,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: p.primary, width: 2),
                  color: p.primary.withValues(alpha: 0.12),
                ),
                child: Text(
                  initials,
                  style: TextStyle(
                    color: p.primary,
                    fontFamily: 'monospace',
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                name,
                style: TextStyle(
                  color: p.text,
                  fontFamily: 'monospace',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                citizenId,
                style: TextStyle(
                  color: p.textDim,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('CONFIRM IDENTITY'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _flag(String citizenId, int reasonCode) async {
    await widget.app.revokeCitizen(citizenId, reasonCode: reasonCode);
    if (!mounted) return;
    final p = AppPalette.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: reasonCode == kRevokeCleared ? p.primary : p.error,
        content: Text(
          reasonCode == kRevokeCleared
              ? 'CLEARED $citizenId — broadcast over mesh'
              : 'FLAGGED ${revocationReasonLabel(reasonCode).toUpperCase()}: '
                    '$citizenId — broadcast over mesh',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Text(
              'RATION ITEM',
              style: TextStyle(color: p.textDim, fontFamily: 'monospace'),
            ),
            const Spacer(),
            DropdownButton<String>(
              value: _rationCode,
              dropdownColor: p.panel,
              style: TextStyle(color: p.primary, fontFamily: 'monospace'),
              items: _items
                  .map((i) => DropdownMenuItem(value: i, child: Text(i)))
                  .toList(),
              onChanged: (v) => setState(() => _rationCode = v ?? 'Rice'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (widget.cameraUsable) ...[
          FilledButton.icon(
            onPressed: () async {
              final payload = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => _scannerPageFor('CITIZEN CLAIM QR'),
                ),
              );
              if (payload == null) return;
              _showClaimResult(await _claim(payload), payload);
            },
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text(
              'SCAN CITIZEN DYNAMIC QR',
              style: TextStyle(fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 12),
          const HduReadout('OR', 'manual claim payload entry'),
          const SizedBox(height: 6),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                decoration: const InputDecoration(
                  hintText: '{"v":1,"c":"CIT-..","w":..,"tok":".."}',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () async {
                if (_ctrl.text.trim().isNotEmpty) {
                  _showClaimResult(
                    await _claim(_ctrl.text.trim()),
                    _ctrl.text.trim(),
                  );
                }
              },
              child: const Text('CLAIM'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        HudPanel(
          title: 'CLAIM UNITS / FALLBACK',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    'UNITS',
                    style: TextStyle(
                      color: p.textDim,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                  const Spacer(),
                  DropdownButton<double>(
                    value: _units,
                    dropdownColor: p.panel,
                    style: TextStyle(color: p.primary, fontFamily: 'monospace'),
                    items: _unitOptions
                        .map(
                          (u) => DropdownMenuItem(
                            value: u,
                            child: Text(u.toStringAsFixed(2)),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _units = v ?? 1.0),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    'PIN FALLBACK',
                    style: TextStyle(
                      color: p.textDim,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                  const Spacer(),
                  Switch(
                    value: _pinFallback,
                    activeTrackColor: p.primary,
                    onChanged: (v) => setState(() => _pinFallback = v),
                  ),
                ],
              ),
              if (_pinFallback) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _pinCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'CITIZEN KNOWLEDGE PIN',
                    counterText: '',
                    border: UnderlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () async {
            final payload = await Navigator.of(context).push<String>(
              MaterialPageRoute(
                builder: (_) => _scannerPageFor('FAMILY CARD QR'),
              ),
            );
            if (payload == null || !context.mounted) return;
            final check = await widget.app.enlistFamily(payload);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: check.ok ? p.primary : p.error,
                content: Text(
                  check.ok
                      ? 'FAMILY CARD ${check.card!.familyId} CACHED '
                            '(${check.card!.dailyUnits.toStringAsFixed(0)}U/day, '
                            '${check.card!.memberCitizenIds.length} members)'
                      : check.message,
                ),
              ),
            );
          },
          icon: const Icon(Icons.group_add),
          label: const Text('ENLIST FAMILY CARD'),
        ),
        const SizedBox(height: 12),
        if (_lastCitizenId != null) ...[
          HudPanel(
            title: 'CARD ACTIONS',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                HduReadout('LAST CITIZEN', _lastCitizenId!),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: p.error,
                          foregroundColor: p.bg,
                        ),
                        onPressed: () => _flag(_lastCitizenId!, kRevokeStolen),
                        child: const Text('FLAG STOLEN'),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: FilledButton(
                        onPressed: () =>
                            _flag(_lastCitizenId!, kRevokeSuspended),
                        child: const Text('SUSPEND'),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => _flag(_lastCitizenId!, kRevokeCleared),
                        child: const Text('CLEAR'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        HduReadout(
          'VERIFY PATH',
          'TOTP-HMAC-SHA256 30s window ▸ daily-duplicate rejection ▸ append-only chain',
        ),
      ],
    );
  }
}

class _LedgerTab extends StatelessWidget {
  const _LedgerTab({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return FutureBuilder<List<LedgerRecord>>(
      future: app.ledger.allRecords(),
      builder: (context, snapshot) {
        final records = snapshot.data ?? const <LedgerRecord>[];
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
          children: [
            HduReadout('RECORDS', '${records.length}'),
            HduReadout(
              'CHAIN TAIL',
              records.isEmpty
                  ? 'GENESIS'
                  : records.first.currentHash.substring(0, 16),
            ),
            const SizedBox(height: 8),
            for (final r in records.take(40))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${r.claimedAt} ${r.citizenId} ${r.rationCode} '
                  'by ${r.officerId} [${r.currentHash.substring(0, 8)}]',
                  style: TextStyle(
                    color: p.text,
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MapTab extends StatelessWidget {
  const _MapTab({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) => MeshMap(mesh: app.mesh);
}
