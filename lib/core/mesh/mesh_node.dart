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
      hasSos = true;
    }
  }

  bool get stale =>
      DateTime.now().millisecondsSinceEpoch - lastSeenEpoch > 120000;
}
