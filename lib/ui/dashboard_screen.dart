/// HQ dashboard: live aggregate mesh telemetry, field map and triage heatmap
/// on one page. Registration lives on its own REGISTER page.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../app_scope.dart';
import '../core/ledger/ledger_store.dart';
import '../core/ledger/officer_sign.dart';
import '../core/mesh/mesh_controller.dart';
import '../core/mesh/mesh_node.dart';
import '../core/mesh_packet.dart';
import 'hud_theme.dart';
import 'mesh_map.dart';
import 'radar_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
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
            child: Row(
              children: [
                Text(
                  '▚▞ COMMAND HQ',
                  style: TextStyle(
                    color: p.primary,
                    fontFamily: 'monospace',
                    fontSize: 16,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
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
                    'LIVE MESH',
                    style: TextStyle(
                      color: p.primary,
                      fontFamily: 'monospace',
                      fontSize: 11,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth > 900;
                final telemetry = _TelemetryPanel(app: app);
                final fieldMap = _FieldMapPanel(app: app);
                final peers = _PeersPanel(app: app);
                final heatmap = _HeatmapPanel(
                  nodes: app.mesh!.nodes.values.toList(),
                  palette: AppPalette.of(context),
                );
                final logs = _LogsPanel(app: app);
                final sosList = _ActiveSosPanel(app: app);
                final radioDiag = app.showDebugInfo
                    ? _RadioDiagnosticsPanel(app: app)
                    : null;

                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: HudScroll(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                          children: [
                            telemetry,
                            const SizedBox(height: 12),
                            if (radioDiag != null) ...[
                              radioDiag,
                              const SizedBox(height: 12),
                            ],
                            fieldMap,
                            const SizedBox(height: 12),
                            heatmap,
                          ],
                        ),
                      ),
                      Expanded(
                        child: HudScroll(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                          children: [
                            peers,
                            const SizedBox(height: 12),
                            logs,
                            const SizedBox(height: 12),
                            sosList,
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return HudScroll(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                  children: [
                    telemetry,
                    const SizedBox(height: 12),
                    peers,
                    const SizedBox(height: 12),
                    if (radioDiag != null) ...[
                      radioDiag,
                      const SizedBox(height: 12),
                    ],
                    fieldMap,
                    const SizedBox(height: 12),
                    heatmap,
                    const SizedBox(height: 12),
                    logs,
                    const SizedBox(height: 12),
                    sosList,
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TelemetryPanel extends StatelessWidget {
  const _TelemetryPanel({required this.app});

  final dynamic app;

  Future<(int, int)> _counts() async => (
    (await app.ledger.recordsCount()) as int,
    (await app.ledger.syncRecordsCount()) as int,
  );

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final nodes = (app.mesh.nodes.values as Iterable<MeshNodeState>).toList();
    final sosCount = nodes.where((MeshNodeState n) => n.hasSos).length;
    final debug = app.showDebugInfo as bool;
    return HudPanel(
      title: 'AGGREGATE MESH HEALTH',
      child: FutureBuilder<(int, int)>(
        future: _counts(),
        builder: (context, snapshot) {
          final (local, synced) = snapshot.data ?? (0, 0);
          final rows = <Widget>[
            HduReadout('PEOPLE IN MESH', '${nodes.length}'),
            HduReadout(
              'ACTIVE SOS BEACONS',
              '$sosCount',
              color: sosCount > 0 ? p.error : p.primary,
            ),
            HduReadout('RATIONS ALLOCATED', '${app.claimCount}'),
            HduReadout('LEDGER RECORDS', '$local'),
          ];
          if (debug) {
            rows.insertAll(0, [
              HduReadout('FRAMES RX', '${app.mesh.framesSeen}'),
              HduReadout('FRAMES RELAYED', '${app.mesh.framesRelayed}'),
              HduReadout('SYNC RECORDS (MESH)', '$synced'),
              HduReadout(
                'MAX HOP SEEN',
                '${nodes.fold<int>(0, (int m, MeshNodeState n) => n.hopCount > m ? n.hopCount : m)}',
              ),
            ]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          );
        },
      ),
    );
  }
}

/// Live radio-governor state (debug only): the duty-cycle tier, the current
/// scan sleep and the active leases. This is the instrument for calibrating
/// the latency/battery tradeoff on real hardware.
class _RadioDiagnosticsPanel extends StatelessWidget {
  const _RadioDiagnosticsPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final d = app.mesh.radioDiagnostics as Map<String, String>;
    final now = DateTime.now().millisecondsSinceEpoch;
    final nodes = (app.mesh.nodes.values as Iterable<MeshNodeState>).toList()
      ..sort((a, b) => b.lastSeenEpoch.compareTo(a.lastSeenEpoch));
    final rows = <Widget>[
      HduReadout('TIER', d['tier'] ?? '-'),
      HduReadout('SCAN SLEEP', d['scanSleep'] ?? '-'),
      HduReadout('PEER SOS LEASE', d['peerSosLease'] ?? '-'),
      HduReadout('DISCOVERY BURST', d['burstLease'] ?? '-'),
      HduReadout('ADVERTISING', d['advertising'] ?? '-'),
      HduReadout('HEARTBEAT', '${(now / 10000).round() % 10}s cycle'),
      for (final n in nodes)
        HduReadout(
          'PEER ${n.nodeId.toRadixString(16).toUpperCase()}',
          '${n.username ?? 'UNKNOWN'} · ${((now - n.lastSeenEpoch) / 1000).round()}s ago'
          '${n.hasSos ? ' · SOS' : ''}',
          color: n.hasSos ? p.error : null,
        ),
    ];
    return HudPanel(title: 'RADIO DIAGNOSTICS', child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    ));
  }
}

/// Live map of the field (same view as an officer's MAP tab).
class _FieldMapPanel extends StatelessWidget {
  const _FieldMapPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final m = app.mesh;
    LatLng? focus;
    final focusId = app.sosFocusId;
    if (focusId != null) {
      final node = m.nodes[focusId];
      if (node != null && node.latitude.abs() > 1e-6) {
        focus = LatLng(node.latitude, node.longitude);
      }
    }
    return HudPanel(
      title: 'FIELD MAP',
      child: LayoutBuilder(
        builder: (context, constraints) => SizedBox(
          // Desktop HQ gets a tall field map; phones keep a compact strip.
          height: constraints.maxWidth > 720 ? 440 : 320,
          child: MeshMap(
            mesh: m,
            focus: focus,
            landmarks: app.officialLandmarks
                .where((l) => !l.isExpired)
                .toList(),
          ),
        ),
      ),
    );
  }
}

/// Who is on the mesh right now, named by their account identity instead of
/// a bare hex node id. The HQ laptop's own node is listed first as SELF (the
/// radio never hears itself); anonymous nodes (still hearable, identity frame
/// not yet received) are listed by id so nobody silently hides.
class _PeersPanel extends StatelessWidget {
  const _PeersPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final mesh = app.mesh;
    final nodes = (mesh.nodes.values as Iterable<MeshNodeState>).toList()
      ..sort((a, b) => b.lastSeenEpoch.compareTo(a.lastSeenEpoch));
    final all = nodes.isEmpty;
    final debug = app.showDebugInfo as bool;
    return HudPanel(
      title: 'DEVICES ON MESH',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _peerRow(
            p,
            isSelf: true,
            showDebug: debug,
            nodeId: mesh.nodeId,
            username: app.username,
            role: null,
            symbol: app.sosActive
                ? packetSymbol(MeshPacketType.sosBeacon)
                : '·',
            rssi: null,
            lastSeenEpoch: DateTime.now().millisecondsSinceEpoch,
            sos: app.sosActive,
          ),
          if (all)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: HduReadout('PEERS', 'no peers yet: keep the radio on'),
            )
          else
            for (final n in nodes)
              _peerRow(
                p,
                showDebug: debug,
                nodeId: n.nodeId,
                username: n.username,
                role: n.roleCode,
                symbol: n.hasSos
                    ? packetSymbol(MeshPacketType.sosBeacon)
                    : n.lastType == MeshPacketType.sosBeacon
                    // A cleared beacon (alarm off) leaves lastType as
                    // sosBeacon; rendering it as the heartbeat symbol
                    // keeps the SOS glyph reserved for real alarms.
                    ? packetSymbol(MeshPacketType.relayStatus)
                    : packetSymbol(n.lastType),
                rssi: n.rssi,
                lastSeenEpoch: n.lastSeenEpoch,
                sos: n.hasSos,
              ),
        ],
      ),
    );
  }

  Widget _peerRow(
    AppPalette p, {
    required int nodeId,
    required String? username,
    required int? role,
    required String symbol,
    required int? rssi,
    required int lastSeenEpoch,
    required bool sos,
    bool isSelf = false,
    bool showDebug = true,
  }) {
    final age = DateTime.now().millisecondsSinceEpoch - lastSeenEpoch;
    final ageLabel = age < 60000
        ? '${(age / 1000).round()}s'
        : '${(age / 60000).round()}m';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          if (isSelf)
            Container(
              width: 32,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: p.primary),
                color: p.primary.withValues(alpha: 0.12),
              ),
              child: Text(
                'SELF',
                style: TextStyle(
                  color: p.primary,
                  fontFamily: 'monospace',
                  fontSize: 8,
                  letterSpacing: 1,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (isSelf) const SizedBox(width: 6),
          Expanded(
            child: Text(
              username ?? 'UNKNOWN',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: sos ? p.error : p.text,
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: username != null
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ),
          Text(
            _roleTag(role),
            style: TextStyle(
              color: p.textDim,
              fontFamily: 'monospace',
              fontSize: 10,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            symbol,
            style: TextStyle(
              color: sos ? p.error : p.primaryDim,
              fontFamily: 'monospace',
              fontSize: 10,
            ),
          ),
          if (showDebug) ...[
            const SizedBox(width: 8),
            Text(
              '0x${nodeId.toRadixString(16).padLeft(4, '0').toUpperCase()}',
              style: TextStyle(
                color: p.textDim,
                fontFamily: 'monospace',
                fontSize: 10,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              rssi == null ? '·' : '$rssi dBm',
              style: TextStyle(
                color: p.textDim,
                fontFamily: 'monospace',
                fontSize: 10,
              ),
            ),
          ],
          const SizedBox(width: 8),
          Text(
            ageLabel,
            style: TextStyle(
              color: p.textDim,
              fontFamily: 'monospace',
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

String _roleTag(int? roleCode) => switch (roleCode) {
  kRoleCitizen => 'CITIZEN',
  kRoleOfficer => 'OFFICER',
  kRoleAdmin => 'ADMIN',
  _ => '·',
};

class _HeatmapPanel extends StatelessWidget {
  const _HeatmapPanel({required this.nodes, required this.palette});

  final List<MeshNodeState> nodes;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final fixed = nodes
        .where(
          (n) =>
              n.latitude.abs() > 1e-6 &&
              n.longitude.abs() > 1e-6 &&
              n.lastSeenEpoch > 0,
        )
        .toList();
    return HudPanel(
      title: 'TRIAGE HEATMAP',
      child: SizedBox(
        height: 220,
        child: fixed.isEmpty
            ? Center(
                child: Text(
                  'NO POSITIONS YET: HEAT BUILDS FROM PEOPLE WITH GPS',
                  style: TextStyle(
                    color: palette.textDim,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              )
            : CustomPaint(
                painter: _HeatmapPainter(nodes: fixed, palette: palette),
                size: Size.infinite,
              ),
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({required this.nodes, required this.palette});

  final List<MeshNodeState> nodes;
  final AppPalette palette;

  /// Gaussian heat kernel: smooth radial falloff with a soft shoulder so a
  /// single node reads as a glow instead of a hard block. SOS nodes carry
  /// more energy and a wider radius so a cluster visibly saturates to red.
  static double _gauss(double d, double sigma) =>
      math.exp(-(d * d) / (2 * sigma * sigma));

  @override
  void paint(Canvas canvas, Size size) {
    // Bounds come from the actual mesh, not a hardcoded demo city: compute the
    // min/max of live coordinates and add a small margin so an SOS cluster is
    // always visible wherever it happens.
    double minLat = double.infinity, maxLat = double.negativeInfinity;
    double minLon = double.infinity, maxLon = double.negativeInfinity;
    for (final n in nodes) {
      minLat = n.latitude < minLat ? n.latitude : minLat;
      maxLat = n.latitude > maxLat ? n.latitude : maxLat;
      minLon = n.longitude < minLon ? n.longitude : minLon;
      maxLon = n.longitude > maxLon ? n.longitude : maxLon;
    }
    final spanLat = maxLat - minLat;
    final spanLon = maxLon - minLon;
    final padLat = spanLat == 0 ? 0.0005 : spanLat * 0.15;
    final padLon = spanLon == 0 ? 0.0005 : spanLon * 0.15;
    minLat -= padLat;
    maxLat += padLat;
    minLon -= padLon;
    maxLon += padLon;
    final spanLat2 = maxLat - minLat;
    final spanLon2 = maxLon - minLon;

    // Fine-grained field so heat edges stay soft. Cell count scales with the
    // panel so a 32x24 on desktop stays ~16x12 on a phone-sized panel.
    final cols = math.max(20, (size.width / 10).round());
    final rows = math.max(14, (size.height / 10).round());
    final cellW = size.width / cols;
    final cellH = size.height / rows;
    final sigma = cellW * 1.6;

    final heat = List<List<double>>.generate(
      cols,
      (_) => List<double>.filled(rows, 0),
    );
    final centers = <Offset>[];
    for (final n in nodes) {
      final x = (n.longitude - minLon) / spanLon2 * size.width;
      final y = (maxLat - n.latitude) / spanLat2 * size.height;
      centers.add(Offset(x, y));
      final strength = n.hasSos ? 2.4 + n.severity * 0.35 : 0.8;
      final kernel = n.hasSos ? sigma * 1.25 : sigma;
      for (var c = 0; c < cols; c++) {
        for (var r = 0; r < rows; r++) {
          final cx = ((c + 0.5) / cols) * size.width;
          final cy = ((r + 0.5) / rows) * size.height;
          final d = (Offset(x, y) - Offset(cx, cy)).distance;
          heat[c][r] += strength * _gauss(d, kernel);
        }
      }
    }

    // Two stacked tints keep the ramp green-halo -> red-core without passing
    // through muddy brown. Cold areas stay at the panel colour.
    for (var c = 0; c < cols; c++) {
      for (var r = 0; r < rows; r++) {
        final h = heat[c][r];
        final green = (h / 3.2).clamp(0.0, 1.0).toDouble();
        final red = ((h - 1.3) / 2.0).clamp(0.0, 1.0).toDouble();
        final cell = RRect.fromRectAndRadius(
          Rect.fromLTWH(c * cellW - 0.5, r * cellH - 0.5, cellW + 1, cellH + 1),
          const Radius.circular(2),
        );
        if (green > 0.02) {
          canvas.drawRRect(
            cell,
            Paint()
              ..color = palette.primary.withValues(alpha: 0.10 + green * 0.30),
          );
        }
        if (red > 0.02) {
          canvas.drawRRect(
            cell,
            Paint()..color = palette.error.withValues(alpha: red * 0.85),
          );
        }
      }
    }

    // Faint quadrant grid so the field reads as a sector map, not noise.
    final gridPaint = Paint()
      ..color = palette.primary.withValues(alpha: 0.07)
      ..strokeWidth = 1;
    for (var c = 4; c < cols; c += 4) {
      canvas.drawLine(
        Offset(c * cellW, 0),
        Offset(c * cellW, size.height),
        gridPaint,
      );
    }
    for (var r = 3; r < rows; r += 4) {
      canvas.drawLine(
        Offset(0, r * cellH),
        Offset(size.width, r * cellH),
        gridPaint,
      );
    }

    // Node markers tie the heat to actual people.
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final at = centers[i];
      final r = n.hasSos ? 5.0 : 3.5;
      canvas.drawCircle(
        at,
        r,
        Paint()..color = n.hasSos ? palette.error : palette.primary,
      );
      canvas.drawCircle(
        at,
        r,
        Paint()
          ..color = palette.panel
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      if (nodes.length <= 6) {
        final tp = TextPainter(
          text: TextSpan(
            text: n.nodeId.toRadixString(16).padLeft(4, '0'),
            style: TextStyle(
              color: palette.textDim,
              fontFamily: 'monospace',
              fontSize: 8,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(
            (at.dx - tp.width / 2).clamp(2, size.width - tp.width - 2),
            (at.dy + r + 2).clamp(2, size.height - tp.height - 2),
          ),
        );
      }
    }

    // Legend: green (low) -> red (critical) gradient swatch with labels.
    final legendW = 92.0;
    final legendH = 6.0;
    final legendX = size.width - legendW - 10;
    final legendY = size.height - 26;
    final swatch = Rect.fromLTWH(legendX, legendY, legendW, legendH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(swatch, const Radius.circular(3)),
      Paint()
        ..shader = LinearGradient(
          colors: [palette.primary, palette.error],
          stops: const [0, 1],
        ).createShader(swatch),
    );
    final low = TextPainter(
      text: TextSpan(
        text: 'LOW',
        style: TextStyle(
          color: palette.textDim,
          fontFamily: 'monospace',
          fontSize: 8,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final crit = TextPainter(
      text: TextSpan(
        text: 'CRITICAL',
        style: TextStyle(
          color: palette.textDim,
          fontFamily: 'monospace',
          fontSize: 8,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    low.paint(canvas, Offset(legendX, legendY + legendH + 2));
    crit.paint(
      canvas,
      Offset(legendX + legendW - crit.width, legendY + legendH + 2),
    );
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter oldDelegate) {
    if (oldDelegate.nodes.length != nodes.length) return true;
    for (var i = 0; i < nodes.length; i++) {
      final a = nodes[i];
      final b = oldDelegate.nodes[i];
      if (a.nodeId != b.nodeId ||
          a.latitude != b.latitude ||
          a.longitude != b.longitude ||
          a.hasSos != b.hasSos) {
        return true;
      }
    }
    return false;
  }
}

/// Dedicated SOS surface for HQ: every live alarm listed with triage, distance
/// and a one-tap track action. Replaces the top banner on the desktop shell: /// the banner stays for phones, where there is no persistent HQ rail to badge.
class _ActiveSosPanel extends StatelessWidget {
  const _ActiveSosPanel({required this.app});

  final dynamic app;

  String _distanceTo(dynamic mesh, MeshNodeState n) {
    if (!mesh.gpsFix && mesh.approxLatitude == null) return '';
    final lat = mesh.gpsFix ? mesh.gpsLatitude : mesh.approxLatitude;
    final lon = mesh.gpsFix ? mesh.gpsLongitude : mesh.approxLongitude;
    final km = MeshController.kmBetween(lat, lon, n.latitude, n.longitude);
    return '${km.toStringAsFixed(1)} km';
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final mesh = app.mesh;
    final active =
        (mesh.nodes.values as Iterable<MeshNodeState>)
            .where((n) => n.hasSos)
            .toList()
          ..sort((a, b) => b.severity.compareTo(a.severity));
    return HudPanel(
      title: 'ACTIVE SOS · HELP',
      borderColor: active.isEmpty ? p.primaryDim : p.error,
      child: active.isEmpty
          ? const HduReadout('STATUS', 'mesh clear: no SOS beacons')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final n in active)
                  InkWell(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RadarScreen(nodeId: n.nodeId),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Text(
                            '0x${n.nodeId.toRadixString(16).padLeft(4, '0').toUpperCase()}',
                            style: TextStyle(
                              color: p.error,
                              fontFamily: 'monospace',
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              n.username ?? 'UNKNOWN',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.text,
                                fontFamily: 'monospace',
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Text(
                            'TRIAGE ${n.severity}',
                            style: TextStyle(
                              color: p.error,
                              fontFamily: 'monospace',
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _distanceTo(mesh, n),
                            style: TextStyle(
                              color: p.textDim,
                              fontFamily: 'monospace',
                              fontSize: 10,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'TRACK ▸',
                            style: TextStyle(
                              color: p.error,
                              fontFamily: 'monospace',
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                HduReadout('HELP', 'tap a node to open the responder radar'),
              ],
            ),
    );
  }
}

class _LogsPanel extends StatelessWidget {
  const _LogsPanel({required this.app});

  final dynamic app;

  /// Compact signature verdict for the audit line: verified, tampered, or
  /// unsigned (claims made before officer signing shipped).
  static String _sigBadge(LedgerRecord r) {
    if (r.signature == null || r.signerPublic == null) return '[SIG·]';
    final ok = verifyOfficerRecord(
      r.signerPublic!,
      r.recordData(),
      r.signature!,
    );
    return ok ? '[SIG✓]' : '[SIG✗]';
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return FutureBuilder<List<LedgerRecord>>(
      future: app.ledger.allRecords(),
      builder: (context, snapshot) {
        final records = snapshot.data ?? const <LedgerRecord>[];
        return HudPanel(
          title: 'SUPPLY ALLOCATION LOG',
          child: records.isEmpty
              ? const HduReadout('LOG', 'no allocations yet')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final r in records.take(30))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '[≡ LEDGER] [${r.claimedAt}] ${r.citizenId} → '
                          '${r.rationCode} ${r.claimUnits.toStringAsFixed(2)}U '
                          'by ${r.officerId} '
                          '·${r.currentHash.substring(0, 8)} '
                          '${_sigBadge(r)}',
                          style: TextStyle(
                            color: p.text,
                            fontFamily: 'monospace',
                            fontSize: 10,
                          ),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}
