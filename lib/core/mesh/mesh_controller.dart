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
  MeshController({
    required this.nodeId,
    required this.startLatitude,
    required this.startLongitude,
    MeshAdapter? adapter,
  }) : adapter = adapter ?? _pickAdapter() {
    _adapterSub = this.adapter.onPacket.listen(_onRx);
  }

  final int nodeId;
  final double startLatitude;
  final double startLongitude;
  final MeshAdapter adapter;

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
      latitude: latitude ?? startLatitude,
      longitude: longitude ?? startLongitude,
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
      latitude: startLatitude,
      longitude: startLongitude,
    );
    _dedup.insert(packet.dedupKey);
    return adapter.broadcast(packet);
  }

  MeshPacket _newPacket(MeshPacketType type,
      {required TriageFlags triage,
      required double latitude,
      required double longitude}) {
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

    final node = _nodes.putIfAbsent(p.senderId, () => MeshNodeState(nodeId: p.senderId));
    node.updateFrom(rx);
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
