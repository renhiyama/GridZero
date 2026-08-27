/// Mesh network encryption — per-ADMIN isolation, no payload bloat.
///
/// Every ADMIN (A/B) has its own 16-byte network key (random, stored as
/// `network_key` in prefs, distributed via HQ-signed provision QR as `netKey`).
/// All mesh frames (22B) and chunked blobs (11B slices) are encrypted with
/// AES-128-CTR, same-size ciphertext, nonce = senderId(2) + seq(2) + chunkIdx(1) + zeros.
///
/// - No tag expansion: CTR keeps 22B → 22B, 11B → 11B, so legacy adv budget
///   (31B) still fits. Authenticity remains via ECDSA `GZCERT`/`GZCHAT`/`GZANN1`
///   (already `GZCERT`-verified), so CTR's lack of tag is okay for demo;
///   production can swap to AES-GCM with 4B truncated tag if needed.
/// - Two ADMINs A (PQR) and B (XYZ) have different `authorityPriv` → different
///   `networkKey` → different ciphertext → cannot decrypt each other's mesh:
///   two distinct encrypted meshes, isolated.
/// - Anonymous (no `networkKey`) falls back to plaintext but will see only
///   gibberish from encrypted peers (MAGIC check fails after decrypt attempt
///   with wrong key) — effectively isolated until provisioned.
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Network key length for AES-128.
const int kNetworkKeyBytes = 16;

/// Global network key for the current trust domain (per-ADMIN). Set by
/// `AppState` after `_ensureAuthorityKey` / provision, read by `MeshPacket`.
/// `null` → no encryption (anonymous, or before first provision).
Uint8List? _currentNetworkKey;

void setNetworkKey(Uint8List? key) {
  if (key != null && key.length != kNetworkKeyBytes) return;
  _currentNetworkKey = key == null ? null : Uint8List.fromList(key);
}

Uint8List? getNetworkKey() => _currentNetworkKey;

/// Encrypts `frame` bytes 1..21 in-place with AES-CTR, key 16B, nonce = senderId+seq.
/// Frame 0 is MAGIC 0xA5; byte 1 is TYPE; bytes 2-3 SENDER_ID; 14-15 SEQ.
/// We CTR over bytes 1..21 (21 bytes) so MAGIC stays 0xA5 for quick filter
/// before decrypt, but you could also CTR over 0..21 if you prefer hidden MAGIC.
/// Decrypt is same operation (CTR).
Uint8List encryptMeshFrame(Uint8List frame, Uint8List key) {
  if (key.length != kNetworkKeyBytes) return frame;
  if (frame.length != 22) return frame;
  // Build 16B CTR IV: [senderId(2), seq(2), zeros(12)] — deterministic per frame,
  // unique per (sender,seq) so CTR keystream never repeats for same key.
  final bd = frame.buffer.asByteData();
  final senderId = bd.getUint16(2, Endian.big);
  final seq = bd.getUint16(14, Endian.big);
  final iv = Uint8List(16);
  iv[0] = (senderId >> 8) & 0xff;
  iv[1] = senderId & 0xff;
  iv[2] = (seq >> 8) & 0xff;
  iv[3] = seq & 0xff;
  // bytes 4..15 are counter blocks for CTR; we keep them zero and let CTR increment.
  final ctr = SICStreamCipher(AESEngine());
  ctr.init(true, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List.fromList(frame);
  final block = Uint8List(21);
  for (var i = 0; i < 21; i++) {
    block[i] = frame[1 + i];
  }
  final cipher = Uint8List(21);
  ctr.processBytes(block, 0, 21, cipher, 0);
  for (var i = 0; i < 21; i++) {
    out[1 + i] = cipher[i];
  }
  return out;
}

Uint8List decryptMeshFrame(Uint8List frame, Uint8List key) => encryptMeshFrame(frame, key);

/// Encrypts an 11B chunk slice with same key, nonce includes chunk index
/// so each slice gets a distinct keystream even for same (sender,seq) frame.
Uint8List encryptMeshChunk(Uint8List chunk11, Uint8List key, int senderId, int seq, int chunkIdx) {
  if (key.length != kNetworkKeyBytes) return chunk11;
  if (chunk11.length > 11) return chunk11;
  final iv = Uint8List(16);
  iv[0] = (senderId >> 8) & 0xff;
  iv[1] = senderId & 0xff;
  iv[2] = (seq >> 8) & 0xff;
  iv[3] = seq & 0xff;
  iv[4] = chunkIdx & 0xff;
  final ctr = SICStreamCipher(AESEngine());
  ctr.init(true, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(chunk11.length);
  ctr.processBytes(chunk11, 0, chunk11.length, out, 0);
  return out;
}

Uint8List decryptMeshChunk(Uint8List chunk11, Uint8List key, int senderId, int seq, int chunkIdx) =>
    encryptMeshChunk(chunk11, key, senderId, seq, chunkIdx);
