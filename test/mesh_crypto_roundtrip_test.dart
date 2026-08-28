import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/mesh_crypto.dart';
import 'package:gridzero/core/mesh_packet.dart';

void main() {
  test('sosBeacon roundtrip with network key', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i + 1));
    setNetworkKey(key);
    final packet = MeshPacket(
      type: MeshPacketType.sosBeacon,
      senderId: 0x1234,
      latitude: 12.34,
      longitude: 56.78,
      triage: TriageFlags(severity: 3),
      seq: 10,
    );
    final enc = packet.encode();
    final dec = MeshPacket.decode(enc);
    expect(dec.senderId, 0x1234);
    expect(dec.latitude, closeTo(12.34, 0.0001));
    setNetworkKey(null);
    expect(() => MeshPacket.decode(enc), throwsA(isA<FormatException>()));
    setNetworkKey(key);
    final dec2 = MeshPacket.decode(enc);
    expect(dec2.senderId, 0x1234);
    setNetworkKey(null);
  });
}
