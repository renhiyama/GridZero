/// Persona B: Field Relief Officer. QR verification, hash-chain ledger and
/// tactical map HUD.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/ledger/ledger_store.dart';
import '../core/mesh_packet.dart';
import '../core/provision_packet.dart';
import 'package:latlong2/latlong.dart';
import 'hud_theme.dart';
import 'mesh_map.dart';
import 'provision_scan_page.dart';

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
              length: 4,
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
                            'OFFICER ▸ ${app.officerId}${app.networkId == null ? '' : ' · ${app.networkId}'}',
                            style: TextStyle(
                              color: p.primary,
                              fontFamily: 'monospace',
                              fontSize: 12,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                  const TabBar(
                    tabs: [
                      Tab(text: 'SCAN'),
                      Tab(text: 'LEDGER'),
                      Tab(text: 'MAP'),
                      Tab(text: 'SYNC'),
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
                        _SyncTab(app: app),
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

/// Enlistment gate: shown when the officer identity has not been assigned.
/// Uses the same paged provisioning scanner as account handoff, constrained
/// to account-type envelopes.
class _EnlistGate extends StatelessWidget {
  const _EnlistGate({required this.app, required this.cameraUsable});

  final dynamic app;
  final bool cameraUsable;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return HudScroll(
      children: [
        HudPanel(
          title: 'OFFICER ENLISTMENT / AIR-GAPPED',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const HduReadout(
                'REQ',
                'Scan the HQ provisioning QR on the Register tab. No internet.',
              ),
              const SizedBox(height: 12),
              if (cameraUsable) ...[
                _EnlistScanButton(app: app),
                const SizedBox(height: 12),
                HduReadout(
                  'NOTE',
                  'Show the officer provisioning QR on the Register tab and '
                      'point this camera at it.',
                  color: p.textDim,
                ),
              ] else
                HudAlertBar(
                  'NO CAMERA ON THIS DEVICE: RUN OFFICER MODE ON A PHONE',
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
        // Account provisioning payloads span several QR frames: paged scan
        // keeps every frame readable by a phone camera.
        final payload = await Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => const ProvisionScanPage(
              label: 'OFFICER PROVISION',
              expectedType: ProvisionType.account,
            ),
          ),
        );
        if (payload == null || !context.mounted) return;
        final error = await app.provisionAccount(payload);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: error != null ? p.error : p.primary,
            content: Text(error ?? 'OFFICER PROVISIONED'),
          ),
        );
      },
      icon: const Icon(Icons.qr_code_scanner),
      label: const Text(
        'SCAN HQ PROVISIONING QR',
        style: TextStyle(fontFamily: 'monospace'),
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
              ? 'CLEARED $citizenId: broadcast over mesh'
              : 'FLAGGED ${revocationReasonLabel(reasonCode).toUpperCase()}: '
                    '$citizenId: broadcast over mesh',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return HudScroll(
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
                  builder: (_) => const ProvisionScanPage(
                    label: 'CITIZEN CLAIM QR',
                  ),
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
                builder: (_) => const ProvisionScanPage(
                  label: 'FAMILY CARD QR',
                  expectedType: ProvisionType.family,
                ),
              ),
            );
            if (payload == null || !context.mounted) return;
            final error = await widget.app.provisionFamilyCard(payload);
            if (!context.mounted) return;
            final cards = error == null
                ? await widget.app.ledger.familyCards()
                : const <FamilyCard>[];
            if (!context.mounted) return;
            final fresh = cards.isNotEmpty ? cards.last : null;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: error != null ? p.error : p.primary,
                content: Text(
                  error ??
                      'FAMILY CARD ${fresh!.familyId} CACHED '
                          '(${fresh.dailyUnits.toStringAsFixed(0)}U/day, '
                          '${fresh.memberCitizenIds.length} members)',
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
        return HudScroll(
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
  Widget build(BuildContext context) => MeshMap(
        mesh: app.mesh,
        landmarks: app.officialLandmarks.where((l) => !l.isExpired).toList(),
        onLongPressPoint: (point) => _composeLandmark(context, point),
      );

  /// Long-press placed a pin: collect details and broadcast + persist.
  Future<void> _composeLandmark(BuildContext context, LatLng point) async {
    var typeCode = 0;
    final labelCtrl = TextEditingController();
    var validityHours = 24;
    final p = AppPalette.of(context);

    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: p.bg,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'PUBLISH LANDMARK',
                style: TextStyle(
                  color: p.primary,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${point.latitude.toStringAsFixed(5)}, '
                '${point.longitude.toStringAsFixed(5)}',
                style: TextStyle(
                  color: p.textDim,
                  fontFamily: 'monospace',
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButton<int>(
                value: typeCode,
                isExpanded: true,
                dropdownColor: p.bg,
                items: [
                  for (var i = 0; i < kLandmarkTypes.length; i++)
                    DropdownMenuItem(value: i, child: Text(kLandmarkTypes[i])),
                ],
                onChanged: (v) => setSheet(() => typeCode = v ?? 0),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: labelCtrl,
                maxLength: 60,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: p.text,
                ),
                decoration: InputDecoration(
                  labelText: 'LABEL (e.g. NORTH CAMP GATE)',
                  labelStyle: TextStyle(
                    color: p.textDim,
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                  border: const UnderlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final h in const [6, 24, 48, 168])
                    ChoiceChip(
                      label: Text('${h}H'),
                      selected: validityHours == h,
                      onSelected: (_) => setSheet(() => validityHours = h),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => Navigator.of(ctx).pop(true),
                icon: const Icon(Icons.publish, size: 18),
                label: const Text(
                  'SIGN & BROADCAST',
                  style: TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final error = await app.postOfficialLandmark(
      label: labelCtrl.text,
      typeCode: typeCode,
      latitude: point.latitude,
      longitude: point.longitude,
      validFor: Duration(hours: validityHours),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor:
            error != null ? AppPalette.of(context).error : p.primary,
        content: Text(
          error ?? 'LANDMARK SIGNED AND BROADCAST',
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      ),
    );
  }
}

/// HQ data sync tab: HQ hosts the `GZ-<USER>` link and shows a WIFI QR;
/// this phone joins it (system camera) and the two-way exchange runs
/// automatically against HQ's server.
class _SyncTab extends StatelessWidget {
  const _SyncTab({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        return HudScroll(
          children: [
            HudPanel(
              title: 'HQ DATA SYNC',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const HduReadout(
                    'HOW',
                    'HQ shows a QR. Tap SYNC, scan it: the phone joins the '
                    "link and both sides exchange data automatically. "
                    'Credentials are wiped when done.',
                  ),
                  const SizedBox(height: 12),
                  if (!app.hotspotActive) ...[
                    FilledButton.icon(
                      onPressed: () async {
                        // In-app scanner: reads HQ's WIFI join QR.
                        final wifiQr = await Navigator.of(context)
                            .push<String>(
                          MaterialPageRoute(
                            builder: (_) =>
                                const ProvisionScanPage(label: 'SCAN HQ LINK QR'),
                          ),
                        );
                        if (!context.mounted || wifiQr == null) return;
                        final error = await app.startOfficerHotspot(
                          wifiQr: wifiQr,
                        );
                        if (!context.mounted) return;
                        if (error != null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: p.error,
                              content: Text(
                                error,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          );
                        }
                      },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text(
                      'SYNC: SCAN HQ QR',
                      style: TextStyle(fontFamily: 'monospace'),
                    ),
                    ),
                  ] else ...[
                    HduReadout(
                      'STATUS',
                      app.lastSyncStep ??
                          'WAITING FOR LINK: open your camera app and scan '
                              'the QR on the HQ screen (joins wifi '
                              'automatically)',
                      color: p.primary,
                    ),
                    if (app.lastSyncImported > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: HduReadout(
                          'RECEIVED',
                          '${app.lastSyncImported} records from HQ',
                          color: p.primary,
                        ),
                      ),
                    if (app.faceSyncedToHq)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: HduReadout('FACE DATA', 'COLLECTED BY HQ',
                            color: p.primary),
                      ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await app.stopOfficerHotspot();
                      },
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text(
                        'CANCEL',
                        style: TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
