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
import 'bluez_mesh.dart';
import 'mesh_adapter.dart';
import 'mesh_node.dart';
import 'native_mesh.dart';

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
  double? gpsAltitude;

  void setGpsFix({
    required double latitude,
    required double longitude,
    double? altitude,
  }) {
    gpsFix = true;
    gpsLatitude = latitude;
    gpsLongitude = longitude;
    gpsAltitude = altitude;
  }

  void clearGpsFix() {
    gpsFix = false;
    gpsLatitude = null;
    gpsLongitude = null;
    gpsAltitude = null;
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
  final _sosStarted = StreamController<MeshNodeState>.broadcast();
  final _sosEnded = StreamController<MeshNodeState>.broadcast();
  Timer? _sweepTimer;

  /// Latest map of known nodes keyed by node id.
  Stream<Map<int, MeshNodeState>> get nodeUpdates => _nodeUpdates.stream;

  /// SOS beacon frames as they are seen or relayed.
  Stream<MeshPacket> get sosStream => _sos.stream;

  /// Fired once when a peer's SOS goes active (transition, not every beacon).
  Stream<MeshNodeState> get sosStarted => _sosStarted.stream;

  /// Fired when a peer's SOS clears (explicit clear frame or 90s timeout).
  Stream<MeshNodeState> get sosEnded => _sosEnded.stream;

  /// Called by the app layer with a received ledger record so it can merge
  /// it into the central store (FR-3.5 store-and-forward sync).
  void Function(CompactRecord record, int fromNodeId)? onLedgerRecord;

  /// Called when a peer (or a relayed request) asks for our unsynced records.
  void Function(int fromNodeId)? onLedgerSyncRequest;

  /// Called with a stolen/suspended card alert diffused by an officer.
  void Function(RevocationAlert alert, int fromNodeId)? onRevocation;

  /// Called with one slice of a chunked account credential.
  void Function(AccountChunk chunk, int fromNodeId)? onAccountChunk;

  /// Called when a peer asks the mesh to announce its local accounts
  /// (fresh-device login probe).
  void Function(int fromNodeId)? onAccountRequest;

  Map<int, MeshNodeState> get nodes => Map.unmodifiable(_nodes);

  /// Number of frames seen so far (telemetry).
  int framesSeen = 0;
  int framesRelayed = 0;

  static MeshAdapter _pickAdapter() {
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux => BluezMeshAdapter(
        advertisingPayload: Uint8List(meshPacketLength),
      ) as MeshAdapter,
      _ => NativeMeshAdapter(advertisingPayload: Uint8List(meshPacketLength)),
    };
  }

  Future<void> start() async {
    await adapter.start();
    _sweepTimer = Timer.periodic(const Duration(seconds: 15), (_) => _sweep());
  }

  Future<void> stop() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    await _adapterSub?.cancel();
    await adapter.stop();
    await _nodeUpdates.close();
    await _sos.close();
    await _sosStarted.close();
    await _sosEnded.close();
  }

  /// Builds, sequence-stamps and floods a new local packet. With
  /// [cleared] set, the frame tells receivers this node's SOS is now off.
  Future<void> broadcastSos({
    required TriageFlags triage,
    double? latitude,
    double? longitude,
    double? altitude,
    bool cleared = false,
  }) {
    final packet = _newPacket(
      MeshPacketType.sosBeacon,
      triage: triage,
      latitude: latitude ?? (gpsFix ? gpsLatitude! : 0),
      longitude: longitude ?? (gpsFix ? gpsLongitude! : 0),
      altitude: altitude ?? gpsAltitude,
      flags: cleared ? 1 : 0,
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
      altitude: gpsAltitude,
    );
    _dedup.insert(packet.dedupKey);
    return adapter.broadcast(packet);
  }

  /// Broadcasts this node's account identity so peers can name us instead of
  /// showing a bare hex node id.
  Future<void> broadcastIdentity(String username, int roleCode) {
    final packet = MeshPacket(
      type: MeshPacketType.identityAnnounce,
      senderId: nodeId,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: (_seq = (_seq + 1) & 0xffff),
      identityUsername: username,
      identityRole: roleCode,
    );
    _dedup.insert(packet.dedupKey);
    return adapter.broadcast(packet);
  }

  /// Pull request: asks nearby (and, via relay, far) nodes to push back their
  /// unsynced ledger records.
  Future<void> broadcastLedgerSyncRequest() {
    final packet = _newPacket(
      MeshPacketType.ledgerSyncRequest,
      triage: TriageFlags(),
      latitude: gpsFix ? gpsLatitude! : 0,
      longitude: gpsFix ? gpsLongitude! : 0,
    );
    _dedup.insert(packet.dedupKey);
    return adapter.broadcast(packet);
  }

  /// Floods one compact ledger record to the mesh for store-and-forward sync.
  Future<void> broadcastLedgerRecord(CompactRecord record) {
    final packet = MeshPacket(
      type: MeshPacketType.ledgerRecord,
      senderId: nodeId,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: (_seq = (_seq + 1) & 0xffff),
      syncRecord: record,
    );
    _dedup.insert(packet.dedupKey);
    return adapter.broadcast(packet);
  }

  /// Floods a stolen/suspended card alert so every terminal within range (and
  /// one hop beyond) refuses future claims from that citizen.
  Future<void> broadcastRevocation(
    String citizenId, {
    required int reasonCode,
    int? issuedAt,
  }) {
    final packet = MeshPacket(
      type: MeshPacketType.revocationAlert,
      senderId: nodeId,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: (_seq = (_seq + 1) & 0xffff),
      revocation: RevocationAlert(
        citizenId: citizenId,
        reasonCode: reasonCode,
        issuedAt: issuedAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    _dedup.insert(packet.dedupKey);
    return adapter.broadcast(packet);
  }

  /// Floods one account credential chunk set so a fresh device listening at
  /// the login screen can reassemble and adopt the account.
  Future<void> broadcastAccount(List<AccountChunk> chunks) async {
    for (final c in chunks) {
      final packet = MeshPacket(
        type: MeshPacketType.accountRecord,
        senderId: nodeId,
        latitude: 0,
        longitude: 0,
        triage: TriageFlags(),
        seq: (_seq = (_seq + 1) & 0xffff),
        accountChunk: c,
      );
      _dedup.insert(packet.dedupKey);
      await adapter.broadcast(packet);
    }
  }

  /// Asks adjacent terminals to announce their local accounts (login probe).
  Future<void> broadcastAccountRequest() {
    final packet = _newPacket(
      MeshPacketType.accountRequest,
      triage: TriageFlags(),
      latitude: 0,
      longitude: 0,
    );
    _dedup.insert(packet.dedupKey);
    return adapter.broadcast(packet);
  }

  MeshPacket _newPacket(
    MeshPacketType type, {
    required TriageFlags triage,
    required double latitude,
    required double longitude,
    double? altitude,
    int flags = 0,
  }) {
    _seq = (_seq + 1) & 0xffff;
    return MeshPacket(
      type: type,
      senderId: nodeId,
      latitude: latitude,
      longitude: longitude,
      triage: triage,
      seq: _seq,
      flags: flags,
      altitudeCm: altitude == null ? null : (altitude * 100).round(),
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
    final wasSos = node.hasSos;
    node.updateFrom(rx);
    _approxDirty = true;
    _nodeUpdates.add(Map.of(_nodes));

    if (p.type == MeshPacketType.sosBeacon) {
      _sos.add(p);
      if (p.sosCleared) {
        if (wasSos) _sosEnded.add(node);
      } else if (!wasSos && !isOwn) {
        _sosStarted.add(node);
      }
    }

    if (p.type == MeshPacketType.ledgerRecord && p.syncRecord != null) {
      onLedgerRecord?.call(p.syncRecord!, p.senderId);
    } else if (p.type == MeshPacketType.ledgerSyncRequest && !isOwn) {
      onLedgerSyncRequest?.call(p.senderId);
    }

    if (p.type == MeshPacketType.revocationAlert && p.revocation != null) {
      onRevocation?.call(p.revocation!, p.senderId);
    } else if (p.type == MeshPacketType.accountRecord &&
        p.accountChunk != null) {
      onAccountChunk?.call(p.accountChunk!, p.senderId);
    } else if (p.type == MeshPacketType.accountRequest && !isOwn) {
      onAccountRequest?.call(p.senderId);
    }

    // FR-1.3: relay while TTL remains and the frame is not ours. Payload
    // frames (identity / ledger record / revocation / account chunk) must
    // carry their payload along or the next hop's encode() null-checks crash
    // on the missing field.
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
        flags: p.flags,
        altitudeCm: p.altitudeCm,
        identityUsername: p.identityUsername,
        identityRole: p.identityRole,
        syncRecord: p.syncRecord,
        revocation: p.revocation,
        accountChunk: p.accountChunk,
      );
      framesRelayed++;
      adapter.broadcast(relay);
    }
  }

  /// Periodic sweep: drop peers silent for >2min (stale people lingering),
  /// and clear SOS beacons whose 90s re-broadcast lease has lapsed.
  void _sweep() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ended = <MeshNodeState>[];
    var changed = false;
    _nodes.removeWhere((id, n) {
      if (now - n.lastSeenEpoch > 120000) {
        changed = true;
        return true;
      }
      if (n.hasSos && n.sosExpiryEpoch > 0 && now > n.sosExpiryEpoch) {
        n.clearSos();
        ended.add(n);
        changed = true;
      }
      return false;
    });
    if (ended.isNotEmpty) {
      for (final n in ended) {
        _sosEnded.add(n);
      }
    }
    if (changed) {
      _approxDirty = true;
      _nodeUpdates.add(Map.of(_nodes));
    }
  }
}
