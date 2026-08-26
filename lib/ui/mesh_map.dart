/// Reusable OpenStreetMap view of the mesh: device markers, GPS/estimate
/// status badge and an offline grid fallback. Used by the officer MAP tab
/// and the Command HQ field map.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app_scope.dart';
import '../core/mesh/mesh_controller.dart';
import '../core/mesh/mesh_node.dart';
import '../core/mesh_packet.dart';
import '../core/app_state.dart';
import 'hud_theme.dart';
import 'radar_screen.dart';

class MeshMap extends StatefulWidget {
  const MeshMap({
    super.key,
    required this.mesh,
    this.focus,
    this.landmarks = const [],
    this.onLongPressPoint,
  });

  final MeshController mesh;

  /// Optional SOS target the camera flies to and holds (notification taps).
  final LatLng? focus;

  /// Verified officer-signed landmarks rendered as shield pins.
  final List<OfficialLandmark> landmarks;

  /// When set, long-pressing the map hands the tapped coordinates to the
  /// parent (officer landmark placement).
  final void Function(LatLng point)? onLongPressPoint;

  @override
  State<MeshMap> createState() => _MeshMapState();
}

class _MeshMapState extends State<MeshMap> {
  final _mapController = MapController();
  Timer? _ticker;
  LatLng _lastCenter = const LatLng(0, 0);
  double _zoom = 16;

  /// Tapped peer node id, or [_selfSelected] for the device's own dot. Tapping
  /// the empty map clears both.
  int? _selectedId;
  bool _selfSelected = false;

  /// Set whenever the user pans/zooms (gesture or slider). Auto-fit stands
  /// down for a while so the camera does not fight back at the user.
  int _manualAt = 0;

  static const _fallbackCenter = LatLng(20.5937, 78.9629);
  static const _minZoom = 3.0;
  static const _maxZoom = 18.0;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      final manual = DateTime.now().millisecondsSinceEpoch - _manualAt < 10000;
      if (!manual) _fitCamera();
      setState(() {});
    });
  }

  void _markManual() {
    _manualAt = DateTime.now().millisecondsSinceEpoch;
  }

  /// Focus target wins over the auto-center while it is set.
  LatLng? get _focus => widget.focus;

  @override
  void didUpdateWidget(covariant MeshMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focus != oldWidget.focus && widget.focus != null) {
      _mapController.move(widget.focus!, 16);
      _lastCenter = widget.focus!;
      _markManual();
    }
  }

  void _setZoom(double value) {
    _markManual();
    setState(() => _zoom = value);
    _mapController.move(_mapController.camera.center, value);
  }

  void _zoomBy(double delta) =>
      _setZoom((_zoom + delta).clamp(_minZoom, _maxZoom));

  void _flyTo(LatLng center) {
    if (MeshController.kmBetween(
          center.latitude,
          center.longitude,
          _lastCenter.latitude,
          _lastCenter.longitude,
        ) >
        0.2) {
      _lastCenter = center;
      _mapController.move(center, _zoom);
    }
  }

  /// Keep the camera glued to the nearby field: when an SOS node is focused,
  /// fly to it; otherwise frame the bounding box of every located node plus
  /// our own position, tight enough that peer markers are plainly visible
  /// instead of a zoomed-out country view. A lone point just flies to it.
  void _fitCamera() {
    final focus = _focus;
    if (focus != null) {
      _flyTo(focus);
      return;
    }
    final m = widget.mesh;
    final points = <LatLng>[];
    if (m.gpsFix) {
      points.add(LatLng(m.gpsLatitude!, m.gpsLongitude!));
    } else if (m.approxLatitude != null) {
      points.add(LatLng(m.approxLatitude!, m.approxLongitude!));
    }
    for (final n in m.nodes.values) {
      if (MeshController.validCoord(n.latitude, n.longitude)) {
        points.add(LatLng(n.latitude, n.longitude));
      }
    }
    if (points.isEmpty) return;
    if (points.length == 1) {
      _flyTo(points.first);
      return;
    }
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    final bounds = LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon));
    _lastCenter = bounds.center;
    // maxZoom keeps a tightly clustered demo from over-zooming into one
    // marker; the floor comes from CameraFit when peers spread out.
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(56),
        maxZoom: 17,
      ),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  /// Where the camera should sit: own GPS fix first (phones), then the
  /// peer-consensus estimate (laptops), then a neutral fallback.
  LatLng get _center {
    final m = widget.mesh;
    if (m.gpsFix) return LatLng(m.gpsLatitude!, m.gpsLongitude!);
    return m.approxLatitude != null
        ? LatLng(m.approxLatitude!, m.approxLongitude!)
        : _fallbackCenter;
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final m = widget.mesh;
    final nodes = m.nodes.values.toList();
    final ownFix = m.gpsFix;
    final estimated = m.approxLatitude != null;
    final located = ownFix || estimated;
    final center = _center;
    if (_lastCenter == const LatLng(0, 0)) _lastCenter = center;

    // Basemap follows the app theme (dark tiles at night, light in the day).
    // Dark tiles get a brightness lift so roads/buildings and label text
    // separate from the near-black background, then a faint accent tint keeps
    // the map reading as ours instead of a stock grey layer.
    Widget tileLayer = TileLayer(
      urlTemplate: dark
          ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'
          : 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
      subdomains: const ['a', 'b', 'c', 'd'],
      userAgentPackageName: 'org.gridzero.gridzero',
      retinaMode: true,
    );
    if (dark) {
      tileLayer = ColorFiltered(
        colorFilter: ColorFilter.matrix(<double>[
          1.38,
          0,
          0,
          0,
          14,
          0,
          1.38,
          0,
          0,
          14,
          0,
          0,
          1.38,
          0,
          14,
          0,
          0,
          0,
          1,
          0,
        ]),
        child: tileLayer,
      );
    }
    tileLayer = ColorFiltered(
      colorFilter: ColorFilter.mode(
        p.primary.withValues(alpha: dark ? 0.10 : 0.08),
        BlendMode.softLight,
      ),
      child: tileLayer,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final size = constraints.biggest;
        // The app runs immersive, so the status bar overlaps the map: every
        // top-anchored overlay must clear it or the HUD hides under it.
        final topInset = MediaQuery.paddingOf(context).top;
        return Stack(
          children: [
            Positioned.fill(
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  backgroundColor: p.bg,
                  initialCenter: center,
                  initialZoom: 16,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                  onPositionChanged: (camera, hasGesture) {
                    _zoom = camera.zoom;
                    if (hasGesture) _markManual();
                    // Keep the tapped-node popup glued to its marker as the
                    // camera pans and zooms instead of floating off.
                    if (_selectedId != null || _selfSelected) setState(() {});
                  },
                  onTap: (_, _) => _clearSelection(),
                  onLongPress: widget.onLongPressPoint == null
                      ? null
                      : (_, point) => widget.onLongPressPoint!(point),
                ),
                children: [
                  // Offline fallback: grid shows through failed/blank tiles.
                  CustomPaint(
                    painter: _GridPainter(grid: p.grid, textDim: p.textDim),
                  ),
                  tileLayer,
                  MarkerLayer(
                    markers: [
                      for (final n in nodes)
                        if (MeshController.validCoord(n.latitude, n.longitude))
                          Marker(
                            point: LatLng(n.latitude, n.longitude),
                            width: 44,
                            height: 44,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() {
                                _selectedId = n.nodeId;
                                _selfSelected = false;
                              }),
                              child: _MapDot(
                                color: n.hasSos ? p.error : p.secondary,
                                sos: n.hasSos,
                                dark: dark,
                              ),
                            ),
                          ),
                      // Own position: the radio never hears itself, so draw the
                      // device explicitly: real GPS on phones, or the peer
                      // consensus estimate on laptops with no fix. Diamond shape
                      // reads as "you are here" against peer dots. A translucent
                      // expanding ping hints at the device's BLE coverage halo.
                      if (ownFix || estimated)
                        Marker(
                          point: _ownPos!,
                          width: 140,
                          height: 140,
                          child: _PingRipple(color: p.primary),
                        ),
                      if (ownFix)
                        Marker(
                          point: LatLng(m.gpsLatitude!, m.gpsLongitude!),
                          width: 30,
                          height: 30,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() {
                              _selectedId = null;
                              _selfSelected = true;
                            }),
                            child: _OwnDot(color: p.primary, estimated: false),
                          ),
                        )
                      else if (estimated)
                        Marker(
                          point: LatLng(m.approxLatitude!, m.approxLongitude!),
                          width: 30,
                          height: 30,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() {
                              _selectedId = null;
                              _selfSelected = true;
                            }),
                            child: _OwnDot(color: p.primary, estimated: true),
                          ),
                        ),
                    ],
                  ),
                  if (widget.landmarks.isNotEmpty)
                    MarkerLayer(
                      markers: [
                        for (final l in widget.landmarks)
                          if (!l.isExpired)
                            Marker(
                              point: LatLng(l.latitude, l.longitude),
                              width: 30,
                              height: 30,
                              alignment: Alignment.topCenter,
                              child: Tooltip(
                                message:
                                    '${l.typeLabel}: ${l.label} (officer-signed)',
                                child: Icon(
                                  Icons.location_pin,
                                  size: 26,
                                  color: p.primary,
                                ),
                              ),
                            ),
                      ],
                    ),
                ],
              ),
            ),
            Positioned(
              left: 8,
              bottom: 8,
              child: HduReadout(
                'PEOPLE',
                '${nodes.length}',
                color: p.secondary,
              ),
            ),
            // Themed attribution overlay: the default flutter_map one renders in
            // its own colours and ignores the HUD palette.
            Positioned(
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                color: p.bg.withValues(alpha: 0.75),
                child: Text(
                  'CARTO · OSM',
                  style: TextStyle(
                    color: p.textDim,
                    fontFamily: 'monospace',
                    fontSize: 8,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              top: 8 + topInset,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: located ? p.secondary : p.error),
                  color: p.bg.withValues(alpha: 0.8),
                ),
                child: Text(
                  ownFix
                      ? 'OWN GPS FIX'
                      : estimated
                      ? 'ESTIMATED POSITION (${peopleCount(m.approxSourceCount)} · '
                            '≈${m.approxRadiusKm!.toStringAsFixed(1)} km)'
                      : nodes.isNotEmpty
                      ? 'NO GPS HW FOUND: AWAITING A GPS-CAPABLE PEER'
                      : 'NO GPS HW FOUND: LOOKING FOR PEOPLE',
                  style: TextStyle(
                    color: located ? p.secondary : p.error,
                    fontFamily: 'monospace',
                    fontSize: 9,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
            // HUD zoom control: the slider mirrors the live camera zoom and
            // drives it directly, so trackpads are not the only way to magnify.
            // Hidden on phones (pinch still works) so it never crowds the
            // bottom nav bar on a narrow screen.
            if (!compact)
              Positioned(
                right: 8,
                bottom: 8,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: p.primaryDim, width: 1),
                    color: p.panel.withValues(alpha: 0.9),
                  ),
                  padding: const EdgeInsets.fromLTRB(4, 3, 8, 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ZoomButton(
                        label: '−',
                        onTap: () => _zoomBy(-0.5),
                        color: p.primary,
                      ),
                      const SizedBox(width: 2),
                      SizedBox(
                        width: 96,
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 2,
                            activeTrackColor: p.primary,
                            inactiveTrackColor: p.primaryDim,
                            thumbColor: p.primary,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 5,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 9,
                            ),
                            overlayColor: p.primary.withValues(alpha: 0.2),
                          ),
                          child: Slider(
                            min: _minZoom,
                            max: _maxZoom,
                            value: _zoom.clamp(_minZoom, _maxZoom),
                            onChanged: _setZoom,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      _ZoomButton(
                        label: '＋',
                        onTap: () => _zoomBy(0.5),
                        color: p.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${_zoom.toStringAsFixed(_zoom == _zoom.roundToDouble() ? 0 : 1)}×',
                        style: TextStyle(
                          color: p.primary,
                          fontFamily: 'monospace',
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_selectedId != null || _selfSelected)
              _selectionCard(context, p, compact, size),
          ],
        );
      },
    );
  }

  void _clearSelection() {
    if (_selectedId != null || _selfSelected) {
      setState(() {
        _selectedId = null;
        _selfSelected = false;
      });
    }
  }

  MeshNodeState? get _selectedNode =>
      _selectedId == null ? null : widget.mesh.nodes[_selectedId!];

  LatLng? get _ownPos {
    final m = widget.mesh;
    if (m.gpsFix) return LatLng(m.gpsLatitude!, m.gpsLongitude!);
    if (m.approxLatitude != null) {
      return LatLng(m.approxLatitude!, m.approxLongitude!);
    }
    return null;
  }

  /// Popup for the tapped marker. Phones get a card pinned to the top of the
  /// map (the bottom bar owns the lower edge); desktops get a card anchored
  /// just above the marker that re-glues itself as the camera moves.
  Widget _selectionCard(
    BuildContext context,
    AppPalette p,
    bool compact,
    Size size,
  ) {
    final debug = AppScope.of(context).showDebugInfo;
    final content = _selfSelected
        ? _selfCard(p, debug)
        : _peerCard(context, p, _selectedNode!, debug);

    if (compact) {
      return Positioned(
        left: 8,
        right: 8,
        top: 8 + MediaQuery.paddingOf(context).top,
        child: content,
      );
    }
    final latlng = _selectedPos;
    if (latlng == null) return const SizedBox.shrink();
    final pos = _mapController.camera.latLngToScreenOffset(latlng);
    const width = 248.0;
    const estHeight = 150.0;
    final left = (pos.dx - width / 2).clamp(8.0, size.width - width - 8.0);
    final above = pos.dy > estHeight + 64;
    var top = above ? pos.dy - estHeight - 18 : pos.dy + 18;
    final topInset = MediaQuery.paddingOf(context).top;
    top = top.clamp(8.0 + topInset, size.height - estHeight - 8.0);
    return Positioned(
      left: left,
      top: top,
      child: SizedBox(width: width, child: content),
    );
  }

  /// The marker the selection points at: own dot (GPS or estimate) or peer.
  LatLng? get _selectedPos {
    if (_selfSelected) return _ownPos;
    final n = _selectedNode;
    if (n == null || !MeshController.validCoord(n.latitude, n.longitude)) {
      return null;
    }
    return LatLng(n.latitude, n.longitude);
  }

  Widget _selfCard(AppPalette p, bool debug) {
    final m = widget.mesh;
    final status = m.gpsFix
        ? 'GPS FIX'
        : m.approxLatitude != null
        ? 'ESTIMATED'
        : 'ESTIMATING…';
    return _mapCard(
      p,
      title: 'THIS DEVICE',
      subtitle: 'you are here',
      rows: [
        ('POSITION', status, null),
        ('LAT', m.effectiveLatitude.toStringAsFixed(5), null),
        ('LON', m.effectiveLongitude.toStringAsFixed(5), null),
        if (debug)
          (
            'NODE',
            m.nodeId.toRadixString(16).padLeft(4, '0').toUpperCase(),
            null,
          ),
      ],
      onClose: _clearSelection,
    );
  }

  Widget _peerCard(
    BuildContext context,
    AppPalette p,
    MeshNodeState n,
    bool debug,
  ) {
    final own = _ownPos;
    final dist = own == null
        ? null
        : MeshController.kmBetween(
            own.latitude,
            own.longitude,
            n.latitude,
            n.longitude,
          );
    final age = DateTime.now().millisecondsSinceEpoch - n.lastSeenEpoch;
    final ageLabel = age < 60000
        ? '${(age / 1000).round()}s ago'
        : '${(age / 60000).round()}m ago';
    return _mapCard(
      p,
      title: n.username ?? 'UNKNOWN',
      subtitle: _roleTag(n.roleCode),
      rows: [
        (
          'SOS',
          n.hasSos ? 'ACTIVE: TRIAGE ${n.severity}' : 'OK',
          n.hasSos ? p.error : null,
        ),
        if (dist != null) ('DISTANCE', '≈${dist.toStringAsFixed(1)} km', null),
        ('LAST SEEN', ageLabel, null),
        if (debug)
          (
            'NODE',
            n.nodeId.toRadixString(16).padLeft(4, '0').toUpperCase(),
            null,
          ),
        if (debug) ('SIGNAL', '${n.rssi} dBm', null),
      ],
      onClose: _clearSelection,
      onTrack: n.hasSos
          ? () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RadarScreen(nodeId: n.nodeId),
              ),
            )
          : null,
    );
  }

  Widget _mapCard(
    AppPalette p, {
    required String title,
    required String subtitle,
    required List<(String, String, Color?)> rows,
    required VoidCallback onClose,
    VoidCallback? onTrack,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: p.primary, width: 1),
        color: p.panel.withValues(alpha: 0.95),
        boxShadow: [
          BoxShadow(color: p.primary.withValues(alpha: 0.25), blurRadius: 10),
        ],
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text,
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              InkWell(
                onTap: onClose,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(
                    '✕',
                    style: TextStyle(
                      color: p.textDim,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Text(
            subtitle,
            style: TextStyle(
              color: p.textDim,
              fontFamily: 'monospace',
              fontSize: 10,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          for (final (label, value, color) in rows)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: HduReadout(label, value, color: color ?? p.primary),
            ),
          if (onTrack != null) ...[
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: p.error,
                foregroundColor: onColor(p.error),
              ),
              onPressed: onTrack,
              child: const Text(
                'RESPOND ▸',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
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

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.label,
    required this.onTap,
    required this.color,
  });

  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: color),
          color: color.withValues(alpha: 0.10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontFamily: 'monospace',
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _MapDot extends StatelessWidget {
  const _MapDot({required this.color, required this.sos, required this.dark});

  final Color color;
  final bool sos;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final border = dark ? const Color(0xFF081310) : Colors.white;
    return Center(
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(color: border, width: 2),
          boxShadow: sos
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.7),
                    blurRadius: 14,
                    spreadRadius: 6,
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Center(
          child: Icon(
            sos ? Icons.emergency : Icons.person,
            size: 14,
            color: border,
          ),
        ),
      ),
    );
  }
}

/// Diamond marker for the device's own position. [estimated] flips a hollow
/// centre so a consensus estimate reads differently from a hard GPS fix.
class _OwnDot extends StatelessWidget {
  const _OwnDot({required this.color, required this.estimated});

  final Color color;
  final bool estimated;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Transform.rotate(
        angle: 45 * 3.14159 / 180,
        child: Container(
          width: estimated ? 14 : 12,
          height: estimated ? 14 : 12,
          decoration: BoxDecoration(
            shape: BoxShape.rectangle,
            color: color,
            border: estimated ? Border.all(color: color, width: 2) : null,
          ),
          child: estimated
              ? Center(child: Container(width: 5, height: 5, color: color))
              : null,
        ),
      ),
    );
  }
}

class _PingRipple extends StatefulWidget {
  const _PingRipple({required this.color});

  final Color color;

  @override
  State<_PingRipple> createState() => _PingRippleState();
}

class _PingRippleState extends State<_PingRipple>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _RipplePainter(color: widget.color, progress: _controller),
      size: const Size.square(140),
    );
  }
}

/// Two staggered translucent rings expanding from the node, like a sonar
/// ping, to hint at the device's approximate BLE reach. Pure paint work: no
/// widget rebuilds during the animation.
class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.color, required this.progress})
      : super(repaint: progress);

  final Color color;
  final Animation<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;
    canvas.drawCircle(
      center,
      maxR * 0.45,
      Paint()..color = color.withValues(alpha: 0.06),
    );
    final t = progress.value;
    for (final phase in const [0.0, 0.5]) {
      final p = (t + phase) % 1.0;
      canvas.drawCircle(
        center,
        maxR * (0.15 + 0.85 * p),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: (1 - p) * 0.35),
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.color != color;
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
        text: 'OFFLINE: AWAITING TILE MAP',
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
