import 'dart:typed_data';

import 'package:aapadsetu/core/mesh_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('18-byte frame roundtrips through encode/decode', () {
    final p = MeshPacket(
      type: MeshPacketType.sosBeacon,
      senderId: 0xBEEF,
      latitude: 19.0760001,
      longitude: 72.8777000,
      triage: TriageFlags(medical: true, trapped: true, severity: 5),
      seq: 42,
    );
    final raw = p.encode();
    expect(raw.length, meshPacketLength);
    expect(raw[0], meshMagic);
    final decoded = MeshPacket.decode(raw);
    expect(decoded.type, MeshPacketType.sosBeacon);
    expect(decoded.senderId, 0xBEEF);
    expect(decoded.latitude, closeTo(19.0760001, 1e-6));
    expect(decoded.longitude, closeTo(72.8777, 1e-6));
    expect(decoded.triage.medical, isTrue);
    expect(decoded.triage.trapped, isTrue);
    expect(decoded.triage.severity, 5);
    expect(decoded.seq, 42);
    expect(decoded.ttl, defaultInitialTtl);
    expect(decoded.isExpired, isFalse);
  });

  test('tampered payload fails CRC', () {
    final raw = MeshPacket(
      type: MeshPacketType.relayStatus,
      senderId: 0x1234,
      latitude: 1,
      longitude: 2,
      triage: TriageFlags(),
      seq: 1,
    ).encode();
    raw[8] ^= 0x01; // flip a longitude byte without fixing CRC
    expect(() => MeshPacket.decode(raw), throwsFormatException);
  });

  test('wrong magic rejected', () {
    final raw = MeshPacket(
      type: MeshPacketType.sosBeacon,
      senderId: 0,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: 0,
    ).encode();
    raw[0] = 0x00;
    expect(() => MeshPacket.decode(raw), throwsFormatException);
  });

  test('TTL accounting decrements on relay hop', () {
    final p = MeshPacket(
      type: MeshPacketType.sosBeacon,
      senderId: 1,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: 7,
      initialTtl: 5,
      hopCount: 3,
    );
    expect(p.ttl, 2);
    expect(p.isExpired, isFalse);

    final expired = MeshPacket(
      type: MeshPacketType.sosBeacon,
      senderId: 1,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: 8,
      initialTtl: 5,
      hopCount: 5,
    );
    expect(expired.ttl, 0);
    expect(expired.isExpired, isTrue);
  });

  test('triage bitfield layout matches REQ 2.1', () {
    final flags = TriageFlags(
      medical: true,
      trapped: false,
      water: true,
      food: false,
      severity: 3,
    );
    // [7]=medical [6]=trapped [5]=water [4]=food [3..0]=severity
    expect(flags.value, 0x80 | 0x20 | 0x03);
  });

  test('dedup key composes sender and sequence', () {
    final a = MeshPacket(
      type: MeshPacketType.relayStatus,
      senderId: 0x00FF,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: 0x1234,
    );
    expect(a.dedupKey, 0x00FF1234);
  });

  test('decode rejects malformed lengths', () {
    expect(
      () => MeshPacket.decode(Uint8List(meshPacketLength - 1)),
      throwsFormatException,
    );
  });
}