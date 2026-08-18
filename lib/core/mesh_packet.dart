/// AapadSetu 18-byte BLE mesh frame codec.
///
/// Layout (from docs/REQ.md section 2.1):
///   Byte 0     MAGIC       0xA5
///   Byte 1     TYPE        0x01 SOS | 0x02 Relay Status | 0x03 Ledger Sync Req
///   Bytes 2-3  SENDER_ID   uint16 node id hash suffix
///   Bytes 4-7  LATITUDE    int32 fixed point lat * 1e7
///   Bytes 8-11 LONGITUDE   int32 fixed point lon * 1e7
///   Byte 12    TRIAGE_FLAGS bitfield
///   Byte 13    TTL_HOP     [7..4] initial TTL, [3..0] current hop count
///   Bytes 14-15 SEQ_NUM    uint16 monotonic counter
///   Byte 16    CRC8        over bytes 0..15
///   Byte 17    RESERVED    dynamic extension byte
library;

import 'dart:typed_data';

import 'crc8.dart';

const int meshMagic = 0xA5;
const int meshPacketLength = 18;
const int defaultInitialTtl = 5;
const int maxSeverity = 5;

enum MeshPacketType {
  sosBeacon(0x01),
  relayStatus(0x02),
  ledgerSyncRequest(0x03);

  const MeshPacketType(this.value);

  final int value;

  static MeshPacketType fromValue(int v) => values.firstWhere(
        (t) => t.value == v,
        orElse: () => throw FormatException('unknown mesh packet type $v'),
      );
}

/// TRIAGE_FLAGS bitfield: [7 Medical][6 Trapped][5 Water][4 Food][3..0 Severity].
class TriageFlags {
  TriageFlags({
    this.medical = false,
    this.trapped = false,
    this.water = false,
    this.food = false,
    this.severity = 1,
  }) : assert(severity >= 1 && severity <= maxSeverity);

  final bool medical;
  final bool trapped;
  final bool water;
  final bool food;
  final int severity;

  int get value =>
      (medical ? 0x80 : 0) |
      (trapped ? 0x40 : 0) |
      (water ? 0x20 : 0) |
      (food ? 0x10 : 0) |
      (severity & 0x0f);

  factory TriageFlags.fromValue(int v) => TriageFlags(
        medical: v & 0x80 != 0,
        trapped: v & 0x40 != 0,
        water: v & 0x20 != 0,
        food: v & 0x10 != 0,
        severity: v & 0x0f,
      );

  @override
  String toString() {
    final needs = [
      if (medical) 'MED',
      if (trapped) 'TRAP',
      if (water) 'WATER',
      if (food) 'FOOD',
    ];
    return needs.isEmpty ? 'SEV$severity' : '${needs.join('|')}/SEV$severity';
  }
}

class MeshPacket {
  MeshPacket({
    required this.type,
    required this.senderId,
    required this.latitude,
    required this.longitude,
    required this.triage,
    required this.seq,
    this.initialTtl = defaultInitialTtl,
    this.hopCount = 0,
    this.reserved = 0,
  });

  final MeshPacketType type;
  final int senderId;
  final double latitude;
  final double longitude;
  final TriageFlags triage;
  final int seq;
  final int initialTtl;
  final int hopCount;
  final int reserved;

  /// Remaining hops before the frame must be dropped.
  int get ttl => initialTtl - hopCount;

  bool get isExpired => ttl <= 0;

  int _fixedPoint(double v, int scale) =>
      (v * scale).round().clamp(-2147483648, 2147483647);

  Uint8List encode() {
    final out = Uint8List(meshPacketLength);
    out[0] = meshMagic;
    out[1] = type.value;
    out.buffer.asByteData().setUint16(2, senderId, Endian.big);
    out.buffer.asByteData().setInt32(4, _fixedPoint(latitude, 10000000), Endian.big);
    out.buffer.asByteData().setInt32(8, _fixedPoint(longitude, 10000000), Endian.big);
    out[12] = triage.value;
    out[13] = ((initialTtl & 0x0f) << 4) | (hopCount & 0x0f);
    out.buffer.asByteData().setUint16(14, seq, Endian.big);
    out[16] = crc8(out.sublist(0, 16));
    out[17] = reserved;
    return out;
  }

  factory MeshPacket.decode(Uint8List raw) {
    if (raw.length != meshPacketLength) {
      throw const FormatException('packet length must be 18 bytes');
    }
    if (raw[0] != meshMagic) {
      throw const FormatException('bad magic');
    }
    final expectedCrc = crc8(raw.sublist(0, 16));
    if (raw[16] != expectedCrc) {
      throw const FormatException('crc mismatch');
    }
    final bd = raw.buffer.asByteData();
    return MeshPacket(
      type: MeshPacketType.fromValue(raw[1]),
      senderId: bd.getUint16(2, Endian.big),
      latitude: bd.getInt32(4, Endian.big) / 10000000.0,
      longitude: bd.getInt32(8, Endian.big) / 10000000.0,
      triage: TriageFlags.fromValue(raw[12]),
      initialTtl: (raw[13] >> 4) & 0x0f,
      hopCount: raw[13] & 0x0f,
      seq: bd.getUint16(14, Endian.big),
      reserved: raw[17],
    );
  }

  /// Duplicate frame identifier: sender + sequence.
  int get dedupKey => (senderId << 16) | (seq & 0xffff);

  @override
  String toString() =>
      'MeshPacket(type=${type.name}, sender=${senderId.toRadixString(16)}, '
      'lat=$latitude lon=$longitude triage=$triage seq=$seq ttl=$ttl)';
}
