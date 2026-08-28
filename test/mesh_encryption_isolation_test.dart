import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/mesh_crypto.dart';
import 'package:gridzero/core/mesh_packet.dart';

void main() {
  setUp(() => setNetworkKey(null));

  test('two ADMIN networks are isolated', () {
    final keyA = Uint8List.fromList(List.generate(16, (i) => i));
    final keyB = Uint8List.fromList(List.generate(16, (i) => 255 - i));

    // Admin A encrypts a frame
    setNetworkKey(keyA);
    final packetA = MeshPacket(
      type: MeshPacketType.chat,
      senderId: 0x1111,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: 1,
      chunk: MeshDataChunk(index: 0, total: 1, data: Uint8List.fromList([1, 2, 3])),
    );
    final encA = packetA.encode();

    // Admin B tries to decode with different key -> should fail magic/crc and be dropped
    setNetworkKey(keyB);
    expect(() => MeshPacket.decode(encA), throwsA(isA<FormatException>()));

    // Admin B encrypts, A cannot decode
    final packetB = MeshPacket(
      type: MeshPacketType.chat,
      senderId: 0x2222,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: 1,
      chunk: MeshDataChunk(index: 0, total: 1, data: Uint8List.fromList([4, 5, 6])),
    );
    final encB = packetB.encode();
    setNetworkKey(keyA);
    expect(() => MeshPacket.decode(encB), throwsA(isA<FormatException>()));

    // Same network key can communicate
    setNetworkKey(keyA);
    final packetA2 = MeshPacket(
      type: MeshPacketType.chat,
      senderId: 0x1111,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: 2,
      chunk: MeshDataChunk(index: 0, total: 1, data: Uint8List.fromList([7, 8, 9])),
    );
    final encA2 = packetA2.encode();
    final decA2 = MeshPacket.decode(encA2);
    expect(decA2.chunk!.data, [7, 8, 9]);
  });

  test('anonymous (no key) cannot read encrypted mesh', () {
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
    // Anonymous has no key
    setNetworkKey(null);
    expect(() => MeshPacket.decode(enc), throwsA(isA<FormatException>()));
    // With correct key, it works
    setNetworkKey(key);
    final dec = MeshPacket.decode(enc);
    expect(dec.senderId, 0x1234);
  });
}
