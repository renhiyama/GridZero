/// Live per-node mesh state aggregated by the controller.
library;

import '../mesh_packet.dart';
import 'mesh_adapter.dart';

class MeshNodeState {
  MeshNodeState({required this.nodeId});

  final int nodeId;
  double latitude = 0;
  double longitude = 0;
  int severity = 1;
  int rssi = -70;
  int hopCount = 0;
  int lastSeenEpoch = 0;
  bool hasSos = false;

  /// Wall-clock deadline until the 30s SOS re-broadcast lease expires.
  /// A cleared frame resets it immediately; the controller sweep also
  /// enforces it so a dead node never shows a permanent SOS.
  int sosExpiryEpoch = 0;
  MeshPacketType lastType = MeshPacketType.relayStatus;

  void updateFrom(MeshRxPacket rx) {
    final p = rx.packet;
    latitude = p.latitude;
    longitude = p.longitude;
    severity = p.triage.severity;
    rssi = rx.rssi;
    hopCount = p.hopCount;
    lastSeenEpoch = DateTime.now().millisecondsSinceEpoch;
    lastType = p.type;
    if (p.type == MeshPacketType.sosBeacon) {
      if (p.sosCleared) {
        clearSos();
      } else {
        hasSos = true;
        sosExpiryEpoch =
            DateTime.now().millisecondsSinceEpoch + _sosLeaseMs;
      }
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
