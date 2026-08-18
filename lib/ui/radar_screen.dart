/// Responder locator: AirTag-style view of a live SOS target. With GPS on
/// both devices you get a real bearing + range; without a fix the screen
/// degrades to an RSSI range estimate and says clearly *which* side lacks
/// GPS, since direction needs both ends fixed.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/mesh/mesh_controller.dart';
import '../core/mesh/mesh_node.dart';
import 'hud_theme.dart';

class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key, required this.nodeId});

  final int nodeId;

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  StreamSubscription<CompassEvent>? _compassSub;
  double? _heading;
  bool _responding = false;

  @override
  void initState() {
    super.initState();
    // Compass needs a magnetometer; laptops return null and fall back to
    // north-up mode.
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      _compassSub = FlutterCompass.events?.listen((e) {
        if (!mounted || e.heading == null) return;
        setState(() => _heading = e.heading);
      });
    }
  }

  @override
  void dispose() {
    _compassSub?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final app = AppScope.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final mesh = app.mesh!;
        final node = mesh.nodes[widget.nodeId];
        if (node == null) {
          return _targetLost(p);
        }
        final t = _TrackTarget(mesh: mesh, node: node);
        return Scaffold(
          backgroundColor: p.bg,
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(p, node, t),
                Expanded(
                  child: _RadarDial(
                    pulse: _pulse,
                    palette: p,
                    bearingDeg: t.bearingDeg,
                    distanceM: t.distanceM,
                    hasBearing: t.hasBearing,
                    heading: _heading,
                  ),
                ),
                _readouts(p, t),
                _hint(p, t),
                _actions(p, app, mesh, node),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _targetLost(AppPalette p) => Scaffold(
    backgroundColor: p.bg,
    body: Center(
      child: Text(
        'TARGET LOST — NO FRESH BEACON',
        style: TextStyle(color: p.error, fontFamily: 'monospace'),
      ),
    ),
  );

  Widget _header(AppPalette p, MeshNodeState node, _TrackTarget t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            color: p.textDim,
            onPressed: () => Navigator.of(context).pop(),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'TRACK NODE ${node.nodeId.toRadixString(16).toUpperCase()}',
                style: TextStyle(
                  color: p.primary,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              Text(
                'TRIAGE ${node.severity} · ${_rssiLabel(t)}',
                style: TextStyle(
                  color: p.textDim,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const Spacer(),
          _RespondButton(
            active: _responding,
            onPressed: () => setState(() => _responding = !_responding),
            palette: p,
          ),
        ],
      ),
    );
  }

  String _rssiLabel(_TrackTarget t) => 'RSSI ${t.node.rssi} dBm';

  Widget _readouts(AppPalette p, _TrackTarget t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            t.distanceLabel,
            style: TextStyle(
              color: p.primary,
              fontFamily: 'monospace',
              fontSize: 44,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _directionText(t),
            style: TextStyle(
              color: t.hasBearing ? p.text : p.error,
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _chip(p, 'RSSI ${t.node.rssi} dBm'),
              _chip(p, 'HOP ${t.node.hopCount}'),
              if (t.altDeltaM != null)
                _chip(
                  p,
                  'ALT ${t.altDeltaM!.abs().round()} m '
                  '${t.altDeltaM! < 0 ? 'BELOW' : 'ABOVE'}',
                ),
            ],
          ),
          if (_heading != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'HEADING ${_heading!.round().toString().padLeft(3, '0')}°',
                style: TextStyle(
                  color: p.textDim,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Says which side is missing a fix instead of blaming this device.
  String _directionText(_TrackTarget t) {
    if (t.hasBearing) {
      return 'BEARING ${t.bearingDeg!.round().toString().padLeft(3, '0')}° '
          '${_cardinal(t.bearingDeg!)}';
    }
    if (!t.hasOwnGps) return 'YOUR DEVICE HAS NO GPS FIX';
    return 'TARGET HAS NO GPS FIX — RANGE ESTIMATE ONLY';
  }

  Widget _chip(AppPalette p, String label) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 4),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      border: Border.all(color: p.primaryDim),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(color: p.textDim, fontFamily: 'monospace', fontSize: 11),
    ),
  );

  Widget _hint(AppPalette p, _TrackTarget t) {
    final turn = t.turnDeg(_heading);
    if (turn == null) return const SizedBox.shrink();
    final straight = turn.abs() < 8;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        straight
            ? 'STRAIGHT ON'
            : 'TURN ${turn.abs().round()}° ${turn < 0 ? 'LEFT' : 'RIGHT'}',
        style: TextStyle(
          color: p.secondary,
          fontFamily: 'monospace',
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _actions(
    AppPalette p,
    AppState app,
    MeshController mesh,
    MeshNodeState node,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Column(
        children: [
          if (_responding)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'RESPONDING — SOS KEEPS BROADCASTING TO OTHERS',
                style: TextStyle(
                  color: p.error,
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                app.openSos(widget.nodeId.toRadixString(16));
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('VIEW ON MAP'),
              style: OutlinedButton.styleFrom(
                foregroundColor: p.primary,
                side: BorderSide(color: p.primaryDim),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Position tracking for one target node.
class _TrackTarget {
  _TrackTarget({required this.mesh, required this.node});

  final MeshController mesh;
  final MeshNodeState node;

  bool get hasOwnGps => mesh.gpsFix;
  bool get _targetGps =>
      MeshController.validCoord(node.latitude, node.longitude);

  bool get hasBearing => hasOwnGps && _targetGps;

  /// Bearing degrees clockwise from north (own → target), or null without
  /// both fixes.
  double? get bearingDeg {
    if (!hasBearing) return null;
    final aLat = mesh.gpsLatitude!;
    final aLon = mesh.gpsLongitude!;
    final dLon = (node.longitude - aLon) * pi / 180;
    final y = sin(dLon) * cos(node.latitude * pi / 180);
    final x =
        cos(aLat * pi / 180) * sin(node.latitude * pi / 180) -
        sin(aLat * pi / 180) * cos(node.latitude * pi / 180) * cos(dLon);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  /// Bearing relative to where the device currently faces. Null without both
  /// the compass and a computed bearing.
  double? turnDeg(double? heading) {
    final b = bearingDeg;
    if (b == null || heading == null) return null;
    var rel = (b - heading) % 360;
    if (rel > 180) rel -= 360;
    return rel;
  }

  /// Range: equal-lat distance when both fixes exist (under 5 m it's noise,
  /// so the radio estimate wins), otherwise an RSSI estimate.
  double? get distanceM {
    if (hasBearing) {
      final gpsD =
          MeshController.kmBetween(
            mesh.gpsLatitude!,
            mesh.gpsLongitude!,
            node.latitude,
            node.longitude,
          ) *
          1000;
      if (gpsD > 5) return gpsD;
    }
    final dBm = node.rssi;
    // tx power unknown, assume -59 dBm @1m, path loss exponent 2.4.
    final est = pow(10, (-59 - dBm) / (10 * 2.4)).toDouble();
    return est.clamp(2.0, 5000.0);
  }

  String get distanceLabel {
    final d = distanceM;
    if (d == null) return 'NO RANGE';
    if (d < 1000) return '≈ ${d.round()} m';
    return '≈ ${(d / 1000).toStringAsFixed(1)} km';
  }

  /// How far vertically the target sits vs this device (m).
  double? get altDeltaM {
    if (!hasOwnGps || node.altitudeM == null) return null;
    return node.altitudeM! - (mesh.gpsAltitude ?? 0);
  }
}

String _cardinal(double deg) {
  const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  return dirs[((deg + 22.5) % 360) ~/ 45];
}

/// Find-My style dial: concentric rings with cardinal labels, you at the
/// centre, and the target at (bearing − heading) so "up" is where you face.
/// No rotating sweep — just a breathing pulse so the screen reads at a glance.
class _RadarDial extends StatelessWidget {
  const _RadarDial({
    required this.pulse,
    required this.palette,
    required this.bearingDeg,
    required this.distanceM,
    required this.hasBearing,
    required this.heading,
  });

  final AnimationController pulse;
  final AppPalette palette;
  final double? bearingDeg;
  final double? distanceM;
  final bool hasBearing;
  final double? heading;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) => CustomPaint(
        painter: _RadarPainter(
          progress: pulse.value,
          palette: palette,
          bearingDeg: bearingDeg,
          distanceM: distanceM,
          hasBearing: hasBearing,
          heading: heading,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.progress,
    required this.palette,
    required this.bearingDeg,
    required this.distanceM,
    required this.hasBearing,
    required this.heading,
  });

  final double progress;
  final AppPalette palette;
  final double? bearingDeg;
  final double? distanceM;
  final bool hasBearing;
  final double? heading;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = min(size.width, size.height) / 2 - 30;
    final center = Offset(cx, cy);

    // Concentric rings with cardinal labels (north = up when heading known).
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(
        center,
        radius * i / 3,
        Paint()
          ..color = palette.grid
          ..style = PaintingStyle.stroke,
      );
    }
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final (label, angle) in const [
      ('N', 0.0),
      ('E', pi / 2),
      ('S', pi),
      ('W', 3 * pi / 2),
    ]) {
      tp.text = TextSpan(
        text: label,
        style: TextStyle(color: palette.textDim, fontSize: 11),
      );
      tp.layout();
      tp.paint(
        canvas,
        center +
            Offset((radius + 14) * sin(angle), -(radius + 14) * cos(angle)) -
            Offset(tp.width / 2, tp.height / 2),
      );
    }

    // Heading triangle: points up so "top of dial = where you face".
    if (heading != null) {
      final path = Path()
        ..moveTo(cx - 8, cy - radius - 20)
        ..lineTo(cx + 8, cy - radius - 20)
        ..lineTo(cx, cy - radius - 32)
        ..close();
      canvas.drawPath(path, Paint()..color = palette.primary);
    }

    // You at the centre.
    canvas.drawCircle(center, 6, Paint()..color = palette.secondary);
    canvas.drawCircle(
      center,
      11,
      Paint()
        ..color = palette.secondary
        ..style = PaintingStyle.stroke,
    );

    if (!hasBearing) {
      // No direction possible: show a fixed blip so the dial doesn't lie.
      canvas.drawCircle(
        center + Offset(0, -radius * 0.5),
        7,
        Paint()..color = palette.error,
      );
      return;
    }

    // Target blip: bearing relative to heading (0 = north-up).
    final angle = (bearingDeg! - (heading ?? 0)) * pi / 180;
    final d = distanceM ?? 0;
    // Log-compressed range so 10 m and 2 km both fit on the dial, and the
    // blip closes in on you as you approach.
    final r = radius * (1 - pow(0.5, d / 80).toDouble());
    final blip = center + Offset(sin(angle), -cos(angle)) * r;

    // Breathing pulse around the target, like a sonar ping.
    final pingR = 8 + 10 * sin(progress * 2 * pi);
    canvas.drawCircle(
      blip,
      pingR,
      Paint()
        ..color = palette.error.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(blip, 7, Paint()..color = palette.error);
    canvas.drawLine(
      center,
      blip,
      Paint()..color = palette.error.withValues(alpha: 0.4),
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.bearingDeg != bearingDeg ||
      oldDelegate.distanceM != distanceM ||
      oldDelegate.heading != heading ||
      oldDelegate.hasBearing != hasBearing ||
      oldDelegate.palette.error != palette.error;
}

class _RespondButton extends StatelessWidget {
  const _RespondButton({
    required this.active,
    required this.onPressed,
    required this.palette,
  });

  final bool active;
  final VoidCallback onPressed;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? palette.error : Colors.transparent,
          border: Border.all(
            color: active ? palette.error : palette.primaryDim,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          active ? 'RESPONDING' : 'RESPOND',
          style: TextStyle(
            color: active ? Colors.white : palette.primary,
            fontFamily: 'monospace',
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}
