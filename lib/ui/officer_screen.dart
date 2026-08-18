/// Persona B: Field Relief Officer. QR verification, hash-chain ledger and
/// tactical map HUD.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/ledger/ledger_store.dart';
import '../core/master_key.dart';
import '../core/mesh/mesh_controller.dart';
import '../core/mesh/mesh_node.dart';
import 'hud_theme.dart';

class OfficerScreen extends StatefulWidget {
  const OfficerScreen({super.key});

  @override
  State<OfficerScreen> createState() => _OfficerScreenState();
}

class _OfficerScreenState extends State<OfficerScreen> {
  ClaimResult? _lastClaim;
  final bool _cameraUsable =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

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
                'Scan Master Key QR signed by HQ. No internet required.',
              ),
              const SizedBox(height: 12),
              if (cameraUsable) ...[
                _EnlistScanButton(app: app),
                const SizedBox(height: 12),
              ],
              const HduReadout('MANUAL ENTRY', 'Paste signed payload below'),
              const SizedBox(height: 6),
              _EnlistManualField(app: app),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  final check = await app.enlistOfficer(
                    kSampleMasterKeyPayload,
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: check.ok ? p.primary : p.error,
                      content: Text(
                        check.ok
                            ? 'OFFICER ENLISTED: ${check.masterKey!.officerId}'
                            : check.message,
                      ),
                    ),
                  );
                },
                child: const Text(
                  'USE DEMO MASTER KEY',
                  style: TextStyle(fontFamily: 'monospace', letterSpacing: 1),
                ),
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
          MaterialPageRoute(
            builder: (_) => const _QrScanPage(label: 'MASTER KEY'),
          ),
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

class _EnlistManualField extends StatefulWidget {
  const _EnlistManualField({required this.app});

  final dynamic app;

  @override
  State<_EnlistManualField> createState() => _EnlistManualFieldState();
}

class _EnlistManualFieldState extends State<_EnlistManualField> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            decoration: const InputDecoration(hintText: '{"v":1,...}'),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () async {
            if (_ctrl.text.trim().isEmpty) return;
            final check = await widget.app.enlistOfficer(_ctrl.text.trim());
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: check.ok ? p.primary : p.error,
                content: Text(
                  check.message.isEmpty ? 'OFFICER ENLISTED' : check.message,
                ),
              ),
            );
          },
          child: const Text('ENLIST'),
        ),
      ],
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
  String _rationCode = 'Rice';

  static const _items = ['Rice', 'Water', 'Blanket', 'Medicine', 'Fuel'];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<ClaimResult> _claim(String payload) =>
      widget.app.claimFromPayload(payload, _rationCode);

  void _showClaimResult(ClaimResult result) {
    final p = AppPalette.of(context);
    widget.onResult(result);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: result.ok ? p.primary : p.error,
        content: Text(
          result.ok
              ? 'GRANTED: ${result.record!.citizenId} / ${result.record!.rationCode}'
              : result.message,
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
                  builder: (_) => const _QrScanPage(label: 'CITIZEN CLAIM QR'),
                ),
              );
              if (payload == null) return;
              _showClaimResult(await _claim(payload));
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
                  _showClaimResult(await _claim(_ctrl.text.trim()));
                }
              },
              child: const Text('CLAIM'),
            ),
          ],
        ),
        const SizedBox(height: 12),
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
          padding: const EdgeInsets.all(12),
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

class _MapTab extends StatefulWidget {
  const _MapTab({required this.app});

  final dynamic app;

  @override
  State<_MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<_MapTab> {
  final _mapController = MapController();
  Timer? _ticker;
  LatLng _lastCenter = const LatLng(0, 0);

  static const _fallbackCenter = LatLng(20.5937, 78.9629);

  @override
  void initState() {
    super.initState();
    // Re-pan when the mesh estimate moves while the tab stays open.
    _ticker = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      final mesh = widget.app.mesh;
      final center = mesh.approxLatitude != null
          ? LatLng(mesh.approxLatitude!, mesh.approxLongitude!)
          : _fallbackCenter;
      if (MeshController.kmBetween(
            center.latitude,
            center.longitude,
            _lastCenter.latitude,
            _lastCenter.longitude,
          ) >
          0.2) {
        _lastCenter = center;
        _mapController.move(center, 15);
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final mesh = widget.app.mesh;
    final nodes = (mesh.nodes.values as Iterable<MeshNodeState>).toList();
    final estimated = mesh.approxLatitude != null;
    final center = estimated
        ? LatLng(mesh.approxLatitude!, mesh.approxLongitude!)
        : _fallbackCenter;
    if (_lastCenter == const LatLng(0, 0)) _lastCenter = center;

    return Stack(
      children: [
        Positioned.fill(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 15,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              // Offline fallback: grid shows through failed/blank tiles.
              CustomPaint(
                painter: _GridPainter(grid: p.grid, textDim: p.textDim),
              ),
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'org.aapadsetu.aapadsetu',
              ),
              MarkerLayer(
                markers: [
                  for (final n in nodes)
                    if (MeshController.validCoord(n.latitude, n.longitude))
                      Marker(
                        point: LatLng(n.latitude, n.longitude),
                        width: 14,
                        height: 14,
                        child: _MapDot(
                          color: n.nodeId == mesh.nodeId
                              ? p.primary
                              : n.hasSos
                              ? p.error
                              : p.secondary,
                          self: n.nodeId == mesh.nodeId,
                          sos: n.hasSos,
                        ),
                      ),
                ],
              ),
              const RichAttributionWidget(
                attributions: [TextSourceAttribution('OpenStreetMap')],
              ),
            ],
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: HduReadout('NODES', '${nodes.length}', color: p.secondary),
        ),
        Positioned(
          left: 8,
          top: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: estimated ? p.secondary : p.error),
              color: p.bg.withValues(alpha: 0.8),
            ),
            child: Text(
              estimated
                  ? 'ESTIMATED POSITION (${mesh.approxSourceCount} '
                        'device${mesh.approxSourceCount == 1 ? '' : 's'} · '
                        '≈${mesh.approxRadiusKm!.toStringAsFixed(1)} km)'
                  : 'NO GPS HW FOUND — LOOKING FOR DEVICES',
              style: TextStyle(
                color: estimated ? p.secondary : p.error,
                fontFamily: 'monospace',
                fontSize: 9,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MapDot extends StatelessWidget {
  const _MapDot({required this.color, required this.self, required this.sos});

  final Color color;
  final bool self;
  final bool sos;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: self ? 12 : 8,
        height: self ? 12 : 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: sos
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.6),
                    blurRadius: 10,
                    spreadRadius: 4,
                  ),
                ]
              : null,
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.grid, required this.textDim});

  final Color grid;
  final Color textDim;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = grid
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const step = 36.0;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    final tp = TextPainter(
      text: TextSpan(
        text: 'OFFLINE — AWAITING TILE MAP',
        style: TextStyle(color: textDim, fontFamily: 'monospace', fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, size.height / 2));
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.grid != grid;
}
