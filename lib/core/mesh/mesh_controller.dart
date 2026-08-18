/// Mesh controller: owns node identity, sequence counter, nonce dedup and
/// the TTL flood relay (FEAT-MESH-02 / FR-1).
///
/// Every received frame is validated, deduplicated against the last 500
/// nonces, and rebroadcast with a decremented TTL unless it originated here
/// or is exhausted.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../mesh_packet.dart';
import '../nonce_dedup.dart';
import 'mesh_adapter.dart';
import 'mesh_node.dart';
import 'native_mesh.dart';
import 'simulated_mesh.dart';

class MeshController {
  MeshController({required this.nodeId, MeshAdapter? adapter})
    : adapter = adapter ?? _pickAdapter() {
    _adapterSub = this.adapter.onPacket.listen(_onRx);
  }

  final int nodeId;
  final MeshAdapter adapter;

  /// Own device GPS. Laptops have no radio fix; phones set this via GPS.
  bool gpsFix = false;
  double? gpsLatitude;
  double? gpsLongitude;

  void setGpsFix({required double latitude, required double longitude}) {
    gpsFix = true;
    gpsLatitude = latitude;
    gpsLongitude = longitude;
  }

  void clearGpsFix() {
    gpsFix = false;
    gpsLatitude = null;
    gpsLongitude = null;
  }

  /// Raw peer coordinates broadcast with each frame; 0,0 means "no fix".
  static bool validCoord(double lat, double lon) =>
      lat.abs() > 1e-6 &&
      lon.abs() > 1e-6 &&
      lat >= -90 &&
      lat <= 90 &&
      lon >= -180 &&
      lon <= 180;

  bool _validNode(MeshNodeState n) => validCoord(n.latitude, n.longitude);

  List<MeshNodeState> get _fixNodes => _nodes.values.where(_validNode).toList();

  /// Approximate position derived from GPS-bearing peers (median filter
  /// rejects a single spoofed far-away coordinate).
  double? get approxLatitude => _approx().lat;
  double? get approxLongitude => _approx().lon;
  int get approxSourceCount => _approx().count;
  double? get approxRadiusKm => _approx().radiusKm;

  ({double? lat, double? lon, int count, double? radiusKm}) _approxCache = (
    lat: null,
    lon: null,
    count: 0,
    radiusKm: null,
  );
  bool _approxDirty = true;

  ({double? lat, double? lon, int count, double? radiusKm}) _approx() {
    if (!_approxDirty) return _approxCache;
    _approxDirty = false;
    final nodes = _fixNodes;
    if (nodes.isEmpty) {
      return _approxCache = (lat: null, lon: null, count: 0, radiusKm: null);
    }
    final median = _median(lat: nodes, lon: nodes);
    // Drop anything farther than 3x the median distance (or 0.5km floor):
    // a single malicious node far away loses to the consensus.
    final kept = nodes.where((n) {
      final d = kmBetween(n.latitude, n.longitude, median.$1, median.$2);
      return d <= max(median.$3 * 3, 0.5);
    }).toList();
    final center = _median(lat: kept, lon: kept);
    final radius = kept
        .map((n) => kmBetween(n.latitude, n.longitude, center.$1, center.$2))
        .fold(0.0, (a, b) => max(a, b));
    return _approxCache = (
      lat: center.$1,
      lon: center.$2,
      count: kept.length,
      radiusKm: radius < 0.1 ? 0.1 : radius,
    );
  }

  (double, double, double) _median({
    required List<MeshNodeState> lat,
    required List<MeshNodeState> lon,
  }) {
    final lats = lat.map((n) => n.latitude).toList()..sort();
    final lons = lon.map((n) => n.longitude).toList()..sort();
    final ml = lats[lats.length ~/ 2];
    final mo = lons[lons.length ~/ 2];
    final dists =
        lat.map((n) => kmBetween(n.latitude, n.longitude, ml, mo)).toList()
          ..sort();
    return (ml, mo, dists[dists.length ~/ 2]);
  }

  /// Flat-earth km distance (fine for local ~km scales).
  static double kmBetween(double aLat, double aLon, double bLat, double bLon) {
    final dLat = (aLat - bLat) * 111.32;
    final dLon = (aLon - bLon) * 111.32 * cos(bLat * pi / 180);
    return sqrt(dLat * dLat + dLon * dLon);
  }

  final NonceDeduplicator _dedup = NonceDeduplicator();
  final Map<int, MeshNodeState> _nodes = {};
  int _seq = Random().nextInt(65536);
  StreamSubscription<MeshRxPacket>? _adapterSub;

  final _nodeUpdates = StreamController<Map<int, MeshNodeState>>.broadcast();
  final _sos = StreamController<MeshPacket>.broadcast();

  /// Latest map of known nodes keyed by node id.
  Stream<Map<int, MeshNodeState>> get nodeUpdates => _nodeUpdates.stream;

  /// SOS beacon frames as they are seen or relayed.
  Stream<MeshPacket> get sosStream => _sos.stream;

  Map<int, MeshNodeState> get nodes => Map.unmodifiable(_nodes);

  /// Number of frames seen so far (telemetry).
  int framesSeen = 0;
  int framesRelayed = 0;

  static MeshAdapter _pickAdapter() {
    if (kIsWeb) return SimulatedMeshAdapter();
    return NativeMeshAdapter(advertisingPayload: Uint8List(meshPacketLength));
  }

  Future<void> start() => adapter.start();

  Future<void> stop() async {
    await _adapterSub?.cancel();
    await adapter.stop();
    await _nodeUpdates.close();
    await _sos.close();
  }

  /// Builds, sequence-stamps and floods a new local packet.
  Future<void> broadcastSos({
    required TriageFlags triage,
    double? latitude,
    double? longitude,
  }) {
    final packet = _newPacket(
      MeshPacketType.sosBeacon,
      triage: triage,
      latitude: latitude ?? (gpsFix ? gpsLatitude! : 0),
      longitude: longitude ?? (gpsFix ? gpsLongitude! : 0),
    );
    return broadcast(packet);
  }

  /// Floods an arbitrary locally-built packet with a fresh sequence stamp.
  Future<void> broadcast(MeshPacket packet) {
    _dedup.insert(packet.dedupKey);
    return adapter.broadcast(packet);
  }

  /// Announces relay status (heartbeat) so peers map this node.
  Future<void> announce() {
    final packet = _newPacket(
      MeshPacketType.relayStatus,
      triage: TriageFlags(),
      latitude: gpsFix ? gpsLatitude! : 0,
      longitude: gpsFix ? gpsLongitude! : 0,
    );
    _dedup.insert(packet.dedupKey);
    return adapter.broadcast(packet);
  }

  MeshPacket _newPacket(
    MeshPacketType type, {
    required TriageFlags triage,
    required double latitude,
    required double longitude,
  }) {
    _seq = (_seq + 1) & 0xffff;
    return MeshPacket(
      type: type,
      senderId: nodeId,
      latitude: latitude,
      longitude: longitude,
      triage: triage,
      seq: _seq,
    );
  }

  void _onRx(MeshRxPacket rx) {
    final p = rx.packet;
    framesSeen++;
    final isOwn = p.senderId == nodeId;
    if (!isOwn && !_dedup.insert(p.dedupKey)) {
      return; // FR-1.4: sliding-window replay rejection
    }

    final node = _nodes.putIfAbsent(
      p.senderId,
      () => MeshNodeState(nodeId: p.senderId),
    );
    node.updateFrom(rx);
    _approxDirty = true;
    _nodeUpdates.add(Map.of(_nodes));

    if (p.type == MeshPacketType.sosBeacon) {
      _sos.add(p);
    }

    // FR-1.3: relay while TTL remains and the frame is not ours.
    if (p.ttl > 1 && p.senderId != nodeId) {
      final relay = MeshPacket(
        type: p.type,
        senderId: p.senderId,
        latitude: p.latitude,
        longitude: p.longitude,
        triage: p.triage,
        seq: p.seq,
        initialTtl: p.initialTtl,
        hopCount: p.hopCount + 1,
        reserved: p.reserved,
      );
      framesRelayed++;
      adapter.broadcast(relay);
    }
  }
}
