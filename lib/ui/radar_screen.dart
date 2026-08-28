/// Responder locator: AirTag-style view of a live SOS target. With GPS on
/// both devices you get a real bearing + range; without a fix the screen
/// degrades to an RSSI range estimate and says clearly *which* side lacks
/// GPS, since direction needs both ends fixed.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
  double? _smoothedHeading;
  double? _targetHeading;
  Ticker? _ticker;

  /// Shortest signed arc from [from] to [to] in degrees (-180..180). Naive
  /// subtraction breaks smoothing across the 359/0 wrap.
  static double _angleDelta(double from, double to) =>
      (to - from + 540) % 360 - 180;
  bool _responding = false;
  Timer? _respondTimer;

  @override
  void initState() {
    super.initState();
    // 60fps ticker that lerps _heading toward _targetHeading. The underlying
    // magnetometer (FlutterCompass) fires at ~15Hz on Android, so without
    // interpolation the bezel stutters. The ticker runs at display refresh
    // rate and eases with a higher factor (0.22) for snappy yet smooth motion.
    _ticker = createTicker((elapsed) {
      if (_targetHeading == null || _smoothedHeading == null) return;
      final delta = _angleDelta(_smoothedHeading!, _targetHeading!);
      if (delta.abs() < 0.05) return;
      _smoothedHeading = _smoothedHeading! + delta * 0.22;
      // Normalize to 0..360 for display
      _smoothedHeading = (_smoothedHeading! % 360 + 360) % 360;
      _heading = _smoothedHeading;
      if (mounted) setState(() {});
    });
    _ticker!.start();
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      _compassSub = FlutterCompass.events?.listen((e) {
        if (!mounted || e.heading == null) return;
        final raw = (e.heading! % 360 + 360) % 360;
        if (_smoothedHeading == null) {
          _smoothedHeading = raw;
          _heading = raw;
          _targetHeading = raw;
          if (mounted) setState(() {});
        } else {
          _targetHeading = raw;
        }
      });
    }
  }

  @override
  void dispose() {
    _respondTimer?.cancel();
    _compassSub?.cancel();
    _ticker?.dispose();
    _pulse.dispose();
    super.dispose();
  }

  /// Respond toggle: on = ack the SOS node now, then re-ack every 10s while
  /// the radar stays open so a missed scan window self-heals. Off = stand
  /// down (the target still has this ack until its beacon lease lapses).
  void _toggleRespond(AppState app, int targetNodeId) {
    if (_responding) {
      _respondTimer?.cancel();
      _respondTimer = null;
      setState(() => _responding = false);
      return;
    }
    unawaited(app.sendSosRespond(targetNodeId));
    _respondTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      unawaited(app.sendSosRespond(targetNodeId));
    });
    setState(() => _responding = true);
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
                _header(p, app, node, t),
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
        'TARGET LOST: NO FRESH BEACON',
        style: TextStyle(color: p.error, fontFamily: 'monospace'),
      ),
    ),
  );

  Widget _header(AppPalette p, AppState app, MeshNodeState node, _TrackTarget t) {
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
            onPressed: () => _toggleRespond(app, node.nodeId),
            palette: p,
          ),
        ],
      ),
    );
  }

  String _rssiLabel(_TrackTarget t) =>
      'SIGNAL ${_rssiPercent(t.node.rssi)}% ${_signalWord(_rssiPercent(t.node.rssi))}';

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
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              _SignalBars(
                percent: _rssiPercent(t.node.rssi),
                color: p.primary,
              ),
              _chip(
                p,
                '${_rssiPercent(t.node.rssi)}% '
                '${_signalWord(_rssiPercent(t.node.rssi))}',
              ),
              _chip(
                p,
                t.node.hopCount == 0 ? 'DIRECT' : 'RELAY ${t.node.hopCount}',
              ),
              if (t.altDeltaM != null)
                _chip(p, _altLabel(t.altDeltaM!)),
            ],
          ),
          if (_heading != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'FACING ${_cardinal(_heading!)} '
                '${_heading!.round().toString().padLeft(3, '0')}°',
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
      final deg = t.bearingDeg!.round();
      return 'TARGET ${_cardinal(t.bearingDeg!)}: ${deg.toString().padLeft(3, '0')}°';
    }
    if (!t.hasOwnGps) return 'YOUR DEVICE HAS NO GPS FIX';
    return 'TARGET HAS NO GPS FIX: RANGE ESTIMATE ONLY';
  }

  String _altLabel(double altDeltaM) {
    if (altDeltaM.abs() < 1.5) return 'ALT SAME LEVEL';
    return 'ALT ${altDeltaM.abs().round()} m '
        '${altDeltaM < 0 ? 'BELOW' : 'ABOVE'}';
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
                'RESPONDING: SOS KEEPS BROADCASTING TO OTHERS',
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
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

/// Perceived signal quality as a percent, mapping raw dBm onto a human
/// scale: -55 dBm reads 100%, -110 dBm reads 10%, linear in between.
/// A stand-in without a calibrated RSSI curve, but far more readable than
/// a raw dBm number and stable enough for direction-of-approach.
int _rssiPercent(int rssi) {
  if (rssi >= -55) return 100;
  if (rssi <= -110) return 10;
  return (10 + ((rssi + 110) / 55 * 90)).round();
}

String _signalWord(int pct) {
  if (pct >= 80) return 'STRONG';
  if (pct >= 55) return 'GOOD';
  if (pct >= 35) return 'FAIR';
  return 'WEAK';
}

/// Five-bar signal meter. Filled bars scale with the percent, so the readout
/// survives being read from a few metres away.
class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.percent, required this.color});

  final int percent;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final filled = (percent / 20).ceil().clamp(0, 5);
    const heights = [6.0, 9.0, 12.0, 15.0, 18.0];
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 5; i++)
          Container(
            width: 5,
            height: heights[i],
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
              color: i < filled
                  ? color
                  : color.withValues(alpha: 0.22),
            ),
          ),
      ],
    );
  }
}

/// Find-My style dial: concentric rings with cardinal labels, you at the
/// centre, and the target at (bearing − heading) so "up" is where you face.
/// No rotating sweep: just a breathing pulse so the screen reads at a glance.
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
    final radius = min(size.width, size.height) / 2 - 36;
    final center = Offset(cx, cy);
    // The bezel swings opposite the heading so the marks you see ahead of
    // you are the ones you are actually facing, like a real magnetic
    // compass held flat.
    final bezel = -(heading ?? 0) * pi / 180;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(bezel);
    canvas.translate(-center.dx, -center.dy);

    // Degree ticks every 15 deg, taller at cardinals and intercardinals.
    for (var a = 0; a < 360; a += 15) {
      final cardinal = a % 90 == 0;
      final major = a % 45 == 0;
      final rad = a * pi / 180;
      final inner = radius * (cardinal ? 0.86 : major ? 0.91 : 0.95);
      canvas.drawLine(
        center + Offset(sin(rad), -cos(rad)) * inner,
        center + Offset(sin(rad), -cos(rad)) * radius,
        Paint()
          ..color = cardinal
                ? palette.primary.withValues(alpha: 0.9)
                : palette.primaryDim.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = cardinal ? 2 : 1,
      );
    }

    // Concentric rings; outermost is the accent frame.
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(
        center,
        radius * i / 3,
        Paint()
          ..color = i == 3 ? palette.primaryDim : palette.grid
          ..style = PaintingStyle.stroke
          ..strokeWidth = i == 3 ? 2.5 : 1.5,
      );
    }

    // Cardinal letters ride the rotating bezel, each glyph set upright in
    // its own slot like a physical compass rose.
    final tp = TextPainter(textDirection: TextDirection.ltr);
    const labels = [
      ('N', 0.0, true),
      ('E', pi / 2, false),
      ('S', pi, false),
      ('W', 3 * pi / 2, false),
    ];
    for (final (label, angle, primary) in labels) {
      canvas.save();
      canvas.translate(
        center.dx + (radius + 16) * sin(angle),
        center.dy - (radius + 16) * cos(angle),
      );
      canvas.rotate(angle);
      tp.text = TextSpan(
        text: label,
        style: TextStyle(
          color: primary ? palette.primary : palette.text,
          fontSize: primary ? 20 : 15,
          fontWeight: FontWeight.bold,
        ),
      );
      tp.layout();
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
    canvas.restore();

    // Field-of-view wedge: a soft 60 deg arc showing where "forward" is.
    if (heading != null) {
      final sweepPaint = Paint()
        ..shader = SweepGradient(
          startAngle: -pi / 2 - pi / 6,
          endAngle: -pi / 2 + pi / 6,
          colors: [
            palette.primary.withValues(alpha: 0.0),
            palette.primary.withValues(alpha: 0.14),
            palette.primary.withValues(alpha: 0.0),
          ],
          transform: GradientRotation(bezel + pi / 6),
        ).createShader(Rect.fromCircle(center: center, radius: radius))
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, radius, sweepPaint);

      // Fixed lubber line: the little nose triangle stays screen-up and
      // always reads "you are facing this way".
      final path = Path()
        ..moveTo(cx - 10, cy - radius - 24)
        ..lineTo(cx + 10, cy - radius - 24)
        ..lineTo(cx, cy - radius - 40)
        ..close();
      canvas.drawPath(path, Paint()..color = palette.primary);
    }

    // You at the centre: filled disc + wide ring so the own position stays
    // visible while the target pulses.
    canvas.drawCircle(center, 7, Paint()..color = palette.secondary);
    canvas.drawCircle(
      center,
      14,
      Paint()
        ..color = palette.secondary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    if (!hasBearing) {
      // No direction possible: show a fixed blip so the dial doesn't lie.
      canvas.drawCircle(
        center + Offset(0, -radius * 0.5),
        9,
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

    // Solid bearing line, then a sonar double-ping around the target with a
    // white core so the marker holds up against any tile colour.
    canvas.drawLine(
      center,
      blip,
      Paint()
        ..color = palette.error.withValues(alpha: 0.55)
        ..strokeWidth = 2,
    );
    final pingR = 10 + 12 * sin(progress * 2 * pi);
    canvas.drawCircle(
      blip,
      pingR,
      Paint()
        ..color = palette.error.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      blip,
      pingR * 0.6,
      Paint()
        ..color = palette.error.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(blip, 9, Paint()..color = palette.error);
    canvas.drawCircle(blip, 3.5, Paint()..color = Colors.white);
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? palette.error : Colors.transparent,
          border: Border.all(
            color: active ? palette.error : palette.primaryDim,
            width: 1,
          ),
          borderRadius: BorderRadius.zero,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active) ...[
              Icon(
                Icons.check_circle,
                color: onColor(palette.error),
                size: 13,
              ),
              const SizedBox(width: 5),
            ],
            Text(
              active ? 'RESPONDING' : 'RESPOND',
              style: TextStyle(
                color: active ? onColor(palette.error) : palette.primary,
                fontFamily: 'monospace',
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
