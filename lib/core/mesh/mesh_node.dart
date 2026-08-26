/// Live per-node mesh state aggregated by the controller.
library;

import '../mesh_packet.dart';
import 'mesh_adapter.dart';

class MeshNodeState {
  MeshNodeState({required this.nodeId});

  final int nodeId;
  double latitude = 0;
  double longitude = 0;
  double? altitudeM;
  int severity = 1;
  int rssi = -70;
  int hopCount = 0;
  int lastSeenEpoch = 0;
  bool hasSos = false;

  /// Identity learned from identityAnnounce frames; null until a name arrives.
  /// Nodes that only relay SOS/telemetry frames stay anonymous.
  String? username;
  int? roleCode;

  /// Wall-clock deadline until the 30s SOS re-broadcast lease expires.
  /// A cleared frame resets it immediately; the controller sweep also
  /// enforces it so a dead node never shows a permanent SOS.
  int sosExpiryEpoch = 0;
  MeshPacketType lastType = MeshPacketType.relayStatus;

  void updateFrom(MeshRxPacket rx) {
    final p = rx.packet;
    lastSeenEpoch = DateTime.now().millisecondsSinceEpoch;
    lastType = p.type;
    // Identity and ledger frames reuse the coordinate bytes as payload, so
    // they must never clobber a node's known position.
    switch (p.type) {
      case MeshPacketType.identityAnnounce:
        if (p.identityUsername != null) username = p.identityUsername;
        if (p.identityRole != null) roleCode = p.identityRole;
        return;
      case MeshPacketType.ledgerRecord:
      case MeshPacketType.ledgerSyncRequest:
      case MeshPacketType.revocationAlert:
      case MeshPacketType.chat:
      case MeshPacketType.announce:
      case MeshPacketType.respond:
        return;
      case MeshPacketType.sosBeacon:
      case MeshPacketType.relayStatus:
        break;
    }
    latitude = p.latitude;
    longitude = p.longitude;
    if (p.altitudeM != null) altitudeM = p.altitudeM;
    severity = p.triage.severity;
    rssi = rx.rssi;
    hopCount = p.hopCount;
    if (p.type == MeshPacketType.sosBeacon) {
      if (p.sosCleared) {
        clearSos();
      } else {
        hasSos = true;
        sosExpiryEpoch = DateTime.now().millisecondsSinceEpoch + _sosLeaseMs;
      }
    } else if (p.type == MeshPacketType.relayStatus && hasSos) {
      // The originator swaps the heartbeat from SOS beacon to plain relay
      // status the moment SOS is deactivated, so a non-SOS announce proves
      // the alarm is off even if the one-shot cleared beacon was dropped.
      clearSos();
    }
  }

  void clearSos() {
    hasSos = false;
    sosExpiryEpoch = 0;
  }

  bool get stale =>
      DateTime.now().millisecondsSinceEpoch - lastSeenEpoch > 120000;
}

/// How long a received SOS stays lit without a fresh beacon or clear frame.
const int _sosLeaseMs = 90000;
