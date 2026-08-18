/// GridZero 22-byte BLE mesh frame codec.
///
/// Layout (from docs/REQ.md section 2.1):
///   Byte 0     MAGIC       0xA5
///   Byte 1     TYPE        0x01 SOS | 0x02 Relay Status | 0x03 Ledger Sync Req
///                          | 0x04 Identity | 0x05 Ledger Record
///   Bytes 2-3  SENDER_ID   uint16 node id hash suffix
///   Bytes 4-7  LATITUDE    int32 fixed point lat * 1e7
///   Bytes 8-11 LONGITUDE   int32 fixed point lon * 1e7
///   Byte 12    TRIAGE_FLAGS bitfield
///   Byte 13    TTL_HOP     [7..4] initial TTL, [3..0] current hop count
///   Bytes 14-15 SEQ_NUM    uint16 monotonic counter
///   Byte 16    CRC8        over bytes 0..15
///   Byte 17    FLAGS       bit0 = SOS cleared marker
///   Bytes 18-21 ALTITUDE   int32 altitude in cm; 0x80000000 = no data
///
/// Identity (0x04) and ledger-record (0x05) frames repurpose bytes 4-21 as
/// payload, since they carry no coordinates:
///   0x04  [4-7][8-11][18-21] username ascii (≤12 chars)
///         [12] role (1 citizen, 2 officer, 3 admin) [17] username length
///   0x05  [4-7] citizenId hex [8-11] officerId hex [18-21] claimedAt epoch32
///         [12] ration code index (0..4 | 0x0F other) [17] bit0 = record marker
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'crc8.dart';

const int meshMagic = 0xA5;
const int meshPacketLength = 22;
const int defaultInitialTtl = 5;
const int maxSeverity = 5;

/// Frame sentinel meaning "altitude unknown" (stored cm).
const int _altUnknown = -2147483648;

/// Role codes shared with app_state.dart. Kept here so the wire codec and the
/// mesh node model agree without importing the whole app state.
const int kRoleCitizen = 1;
const int kRoleOfficer = 2;
const int kRoleAdmin = 3;

/// Ration items an officer can dispatch; the wire carries the index so a
/// full string survives the 22-byte frame.
const List<String> kRationCodes = [
  'Rice',
  'Water',
  'Blanket',
  'Medicine',
  'Fuel',
];

enum MeshPacketType {
  sosBeacon(0x01),
  relayStatus(0x02),
  ledgerSyncRequest(0x03),
  identityAnnounce(0x04),
  ledgerRecord(0x05);

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

/// A ration claim squeezed into one 22-byte frame for store-and-forward
/// ledger sync (FR-3.5 / FEAT-LEDG-02). Holds just the identity essentials;
/// the sender's local hash-chain record keeps the full hashes.
class CompactRecord {
  CompactRecord({
    required this.citizenId,
    required this.officerId,
    required this.claimedAt,
    required this.rationCode,
  });

  final String citizenId;
  final String officerId;
  final int claimedAt;
  final String rationCode;
}

/// Packs "CIT-XXXXXXXX" / "OFF-XXXXXXXX" into 4 bytes. Anything not in that
/// shape hashes down to a stable 4-byte tag instead of corrupting the frame.
int _idToBits(String id) {
  final hex = id.split('-').last.toUpperCase();
  if (hex.length == 8 && RegExp(r'^[0-9A-F]{8}$').hasMatch(hex)) {
    return int.parse(hex, radix: 16);
  }
  final digest = sha256.convert(utf8.encode(id)).bytes;
  return (digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3];
}

String _bitsToId(String prefix, int bits) =>
    '$prefix${(bits & 0xffffffff).toRadixString(16).padLeft(8, '0').toUpperCase()}';

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
    this.flags = 0,
    this.altitudeCm,
    this.identityUsername,
    this.identityRole,
    this.syncRecord,
  });

  final MeshPacketType type;
  final int senderId;
  final double latitude;
  final double longitude;
  final TriageFlags triage;
  final int seq;
  final int initialTtl;
  final int hopCount;

  /// Flags byte (index 17). Bit 0 = SOS-cleared marker so a deactivated SOS
  /// propagates through the mesh instead of lingering until timeout. On
  /// identity frames it carries the username length; on ledger records bit 0
  /// marks the payload as a record (vs an empty sync request).
  final int flags;

  /// True when this sosBeacon announces the sender's SOS is now off.
  bool get sosCleared => (flags & 0x01) != 0;

  /// Identity announcement payload (type == identityAnnounce).
  final String? identityUsername;
  final int? identityRole;

  /// Ledger payload (type == ledgerRecord); null on a plain sync request.
  final CompactRecord? syncRecord;

  /// Altitude in cm above sea level, or null when unknown.
  final int? altitudeCm;

  /// Altitude in metres, or null when unknown.
  double? get altitudeM => altitudeCm == null ? null : altitudeCm! / 100.0;

  /// Remaining hops before the frame must be dropped.
  int get ttl => initialTtl - hopCount;

  bool get isExpired => ttl <= 0;

  int _fixedPoint(double v, int scale) =>
      (v * scale).round().clamp(-2147483648, 2147483647);

  Uint8List encode() {
    final out = Uint8List(meshPacketLength);
    final bd = out.buffer.asByteData();
    out[0] = meshMagic;
    out[1] = type.value;
    bd.setUint16(2, senderId, Endian.big);
    switch (type) {
      case MeshPacketType.identityAnnounce:
        final name = (identityUsername ?? '')
            .toUpperCase()
            .codeUnits
            .take(12)
            .toList();
        final buf = Uint8List(12)..setRange(0, name.length, name);
        final bufBd = buf.buffer.asByteData();
        bd.setInt32(4, bufBd.getInt32(0, Endian.big), Endian.big);
        bd.setInt32(8, bufBd.getInt32(4, Endian.big), Endian.big);
        bd.setInt32(18, bufBd.getInt32(8, Endian.big), Endian.big);
        out[12] = identityRole ?? kRoleCitizen;
        out[17] = name.length;
      case MeshPacketType.ledgerRecord:
        final rec = syncRecord;
        bd.setInt32(4, _idToBits(rec!.citizenId), Endian.big);
        bd.setInt32(8, _idToBits(rec.officerId), Endian.big);
        bd.setUint32(18, rec.claimedAt, Endian.big);
        final idx = kRationCodes.indexOf(rec.rationCode);
        out[12] = idx >= 0 ? idx : 0x0f;
        out[17] = 0x01;
      case MeshPacketType.ledgerSyncRequest:
      case MeshPacketType.sosBeacon:
      case MeshPacketType.relayStatus:
        bd.setInt32(4, _fixedPoint(latitude, 10000000), Endian.big);
        bd.setInt32(8, _fixedPoint(longitude, 10000000), Endian.big);
        out[12] = triage.value;
        out[17] = flags;
        bd.setInt32(18, altitudeCm ?? _altUnknown, Endian.big);
    }
    out[13] = ((initialTtl & 0x0f) << 4) | (hopCount & 0x0f);
    bd.setUint16(14, seq, Endian.big);
    out[16] = crc8(out.sublist(0, 16));
    return out;
  }

  factory MeshPacket.decode(Uint8List raw) {
    if (raw.length != meshPacketLength) {
      throw const FormatException('packet length must be 22 bytes');
    }
    if (raw[0] != meshMagic) {
      throw const FormatException('bad magic');
    }
    final expectedCrc = crc8(raw.sublist(0, 16));
    if (raw[16] != expectedCrc) {
      throw const FormatException('crc mismatch');
    }
    final bd = raw.buffer.asByteData();
    final type = MeshPacketType.fromValue(raw[1]);
    final carriesCoords = switch (type) {
      MeshPacketType.sosBeacon ||
      MeshPacketType.relayStatus ||
      MeshPacketType.ledgerSyncRequest => true,
      _ => false,
    };
    final base = MeshPacket(
      type: type,
      senderId: bd.getUint16(2, Endian.big),
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: bd.getUint16(14, Endian.big),
      initialTtl: (raw[13] >> 4) & 0x0f,
      hopCount: raw[13] & 0x0f,
      flags: carriesCoords ? raw[17] : 0,
      altitudeCm: null,
    );
    switch (type) {
      case MeshPacketType.identityAnnounce:
        final buf = Uint8List(12);
        final bufBd = buf.buffer.asByteData();
        bufBd.setInt32(0, bd.getInt32(4, Endian.big), Endian.big);
        bufBd.setInt32(4, bd.getInt32(8, Endian.big), Endian.big);
        bufBd.setInt32(8, bd.getInt32(18, Endian.big), Endian.big);
        final len = raw[17].clamp(0, 12);
        return MeshPacket(
          type: type,
          senderId: base.senderId,
          latitude: 0,
          longitude: 0,
          triage: TriageFlags(),
          seq: base.seq,
          initialTtl: base.initialTtl,
          hopCount: base.hopCount,
          flags: 0,
          altitudeCm: null,
          identityUsername: String.fromCharCodes(buf.sublist(0, len)),
          identityRole: raw[12],
        );
      case MeshPacketType.ledgerRecord:
        final code = raw[12];
        return MeshPacket(
          type: type,
          senderId: base.senderId,
          latitude: 0,
          longitude: 0,
          triage: TriageFlags(),
          seq: base.seq,
          initialTtl: base.initialTtl,
          hopCount: base.hopCount,
          flags: 0x01,
          altitudeCm: null,
          syncRecord: CompactRecord(
            citizenId: _bitsToId('CIT-', bd.getInt32(4, Endian.big)),
            officerId: _bitsToId('OFF-', bd.getInt32(8, Endian.big)),
            claimedAt: bd.getUint32(18, Endian.big),
            rationCode: code == 0x0f
                ? 'Other'
                : (code < kRationCodes.length ? kRationCodes[code] : 'Other'),
          ),
        );
      case MeshPacketType.ledgerSyncRequest:
      case MeshPacketType.sosBeacon:
      case MeshPacketType.relayStatus:
        return MeshPacket(
          type: type,
          senderId: base.senderId,
          latitude: bd.getInt32(4, Endian.big) / 10000000.0,
          longitude: bd.getInt32(8, Endian.big) / 10000000.0,
          triage: TriageFlags.fromValue(raw[12]),
          seq: base.seq,
          initialTtl: base.initialTtl,
          hopCount: base.hopCount,
          flags: base.flags,
          altitudeCm: switch (bd.getInt32(18, Endian.big)) {
            _altUnknown => null,
            final int v => v,
          },
        );
    }
  }

  /// Duplicate frame identifier: sender + sequence.
  int get dedupKey => (senderId << 16) | (seq & 0xffff);

  @override
  String toString() =>
      'MeshPacket(type=${type.name}, sender=${senderId.toRadixString(16)}, '
      'lat=$latitude lon=$longitude triage=$triage seq=$seq ttl=$ttl)';
}
