// ignore_for_file: use_null_aware_elements
/// Paged QR provisioning (FR-2.3 / HQ enrolment handoff).
///
/// A single QR can hold ~100 bytes readable on a phone; account and family
/// payloads run several hundred bytes. [provisionChunks] splits any payload
/// into frames small enough to render as a low-version QR, and
/// [ProvisionAssembler] reassembles them on the scanning side. Every frame
/// carries a CRC32 of the full payload so a corrupted scan is detected the
/// moment the last chunk lands, instead of silently provisioning garbage.
///
/// Frame layout (byte mode, ASCII):
///   `GZ1|<index>/<total>|<crc32hex>|<data>`
/// e.g. `GZ1|2/5|1A2B3C4D|{"v":2,"t":"account",`...
///
/// All handoffs share one typed, expiring envelope (v2):
///   `{"v":2,"t":"account|family","exp":<epoch>,"nonce":"<hex>",`
///   `"data":{...}}`
/// `t` is checked strictly on the scanning side so a family QR can never be
/// mistaken for an account QR, `exp` kills stale scans, and `nonce` makes each
/// issuance unique.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math';

/// Fixed overhead of one frame before the data slice.
const int kProvisionFrameOverhead = 18;

/// Default slice size: 96 data bytes per frame keeps each QR at version ~6
/// (45x45 modules) so a 220px render leaves ~4px per module: readable by a
/// phone camera.
const int kProvisionChunkBytes = 96;

/// Account QRs are short-lived: the admin relays the password in person, so a
/// captured frame stops being valid within a day.
const int kAccountLifetimeSeconds = 24 * 3600;

/// Family cards are data handoffs cached by officers at distribution time and
/// can legitimately be scanned days after issuance.
const int kFamilyCardLifetimeSeconds = 30 * 24 * 3600;

/// Officer-hosted sync hotspots are transient: the phone keeps the access
/// point only while the sync panel is open, so the QR must be consumed
/// promptly or it is garbage.
const int kHotspotLifetimeSeconds = 10 * 60;

const String _magic = 'GZ1';

/// Splits [payload] into paged QR frames. The returned list is ordered; the
/// scanner accepts any arrival order.
List<String> provisionChunks(
  String payload, {
  int chunkBytes = kProvisionChunkBytes,
}) {
  final data = utf8.encode(payload);
  final crc = _crc32(data).toRadixString(16).toUpperCase().padLeft(8, '0');
  final total = (data.length + chunkBytes - 1) ~/ chunkBytes;
  return [
    for (var i = 0; i < total; i++)
      '$_magic|${i + 1}/$total|$crc|'
          '${utf8.decode(data.sublist(i * chunkBytes, (i + 1) * chunkBytes > data.length ? data.length : (i + 1) * chunkBytes))}',
  ];
}

/// True when [frame] is a provision frame (not, say, a plain claim QR).
bool isProvisionFrame(String frame) => frame.startsWith('$_magic|');

/// Incremental reassembler for a paged provision payload. Feed every scanned
/// frame to [add]; when the payload is complete and its CRC32 matches,
/// [complete] turns true and [payload] is ready.
class ProvisionAssembler {
  final Map<int, String> _chunks = {};
  int? _total;
  String? _expectedCrc;
  bool complete = false;
  String payload = '';

  /// Returns a status string when the frame is rejected, else null.
  String? add(String frame) {
    if (!isProvisionFrame(frame)) return 'not a provision frame';
    final rest = frame.substring(_magic.length + 1);
    final slash = rest.indexOf('/');
    final pipe = rest.indexOf('|', slash + 1);
    final idx = int.tryParse(rest.substring(0, slash));
    final total = int.tryParse(rest.substring(slash + 1, pipe));
    if (idx == null || total == null || total < 1) {
      return 'malformed provision frame';
    }
    final crcPart = rest.substring(pipe + 1);
    final crcSep = crcPart.indexOf('|');
    final crcHex = crcPart.substring(0, crcSep);
    final data = crcPart.substring(crcSep + 1);
    if (_total != null && _total != total) {
      return 'frame count changed: restart scan';
    }
    if (_expectedCrc != null && _expectedCrc != crcHex) {
      return 'different payload: restart scan';
    }
    _total = total;
    _expectedCrc = crcHex;
    _chunks[idx] = data;
    if (_chunks.length == total) {
      final raw = _chunks.keys.toList()..sort();
      final joined = raw.map((k) => _chunks[k]).join();
      final bytes = utf8.encode(joined);
      if (_crc32(bytes).toRadixString(16).toUpperCase().padLeft(8, '0') !=
          crcHex) {
        _chunks.clear();
        _total = null;
        return 'checksum mismatch: re-scan';
      }
      payload = utf8.decode(bytes);
      complete = true;
    }
    return null;
  }

  int get received => _chunks.length;
  int? get total => _total;

  void reset() {
    _chunks.clear();
    _total = null;
    _expectedCrc = null;
    complete = false;
    payload = '';
  }
}

/// Standard CRC-32 (IEEE 802.3, polynomial 0xEDB88320).
int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// The kinds of handoff a QR can carry. [ProvisionScanPage] requires one so a
/// scanning phone rejects the wrong panel's QR instead of assembling it.
enum ProvisionType {
  account('account'),
  family('family'),
  hotspot('hotspot');

  const ProvisionType(this.tag);
  final String tag;

  static ProvisionType? fromTag(String? tag) => switch (tag) {
    'account' => ProvisionType.account,
    'family' => ProvisionType.family,
    'hotspot' => ProvisionType.hotspot,
    _ => null,
  };
}

/// A decoded v2 envelope, ready for typed data extraction.
class ProvisionEnvelope {
  const ProvisionEnvelope({
    required this.type,
    required this.expiresAt,
    required this.nonce,
    required this.data,
    this.signature,
  });

  final ProvisionType type;
  final int expiresAt;
  final String nonce;
  final Map<String, Object?> data;
  final String? signature;
}

/// Result of parsing an envelope: [envelope] set when [error] is null.
typedef EnvelopeParse = ({ProvisionEnvelope? envelope, String? error});

String _canonicalData(Map<String, Object?> data) {
  // Deterministic JSON with sorted keys for signing.
  return jsonEncode(SplayTreeMap<String, Object?>.from(data));
}

/// Canonical string for HQ signature: GZPROV|v|t|exp|nonce|canonicalData
String canonicalProvision({
  required int v,
  required String t,
  required int exp,
  required String nonce,
  required Map<String, Object?> data,
}) {
  return 'GZPROV|$v|$t|$exp|$nonce|${_canonicalData(data)}';
}

/// Wraps [data] in a typed, expiring v2 envelope. [now] is injectable for
/// tests. If [signature] is provided it is added as top-level `sig`.
String encodeProvisionEnvelope({
  required ProvisionType type,
  required Map<String, Object?> data,
  int expiresInSeconds = kAccountLifetimeSeconds,
  int? now,
  String? signature,
}) {
  final ts = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final nonce = List.generate(8, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
  final map = <String, Object?>{
    'v': 2,
    't': type.tag,
    'exp': ts + expiresInSeconds,
    'nonce': nonce,
    'data': data,
  };
  if (signature != null) map['sig'] = signature;
  return jsonEncode(map);
}

/// Parses and validates a v2 envelope without trusting it. When
/// [requireType] is given, any other type is rejected with a clear error.
/// [now] is injectable for tests. Returns the envelope even if `sig` is
/// missing — the caller must verify `sig` against the HQ authority when it
/// matters (fake-account block).
EnvelopeParse parseProvisionEnvelope(
  String payload, {
  ProvisionType? requireType,
  int? now,
}) {
  Object? map;
  try {
    map = jsonDecode(payload);
  } catch (_) {
    return (envelope: null, error: 'malformed provision payload');
  }
  if (map is! Map<String, dynamic>) {
    return (envelope: null, error: 'malformed provision payload');
  }
  if (map['v'] != 2) {
    return (envelope: null, error: 'unsupported payload version');
  }
  final type = ProvisionType.fromTag(map['t'] as String?);
  final exp = map['exp'];
  final nonce = map['nonce'];
  final data = map['data'];
  final sig = map['sig'] as String?;
  if (type == null || exp is! int || nonce is! String || nonce.isEmpty) {
    return (envelope: null, error: 'malformed provision payload');
  }
  if (data is! Map<String, dynamic>) {
    return (envelope: null, error: 'malformed provision payload');
  }
  if (requireType != null && type != requireType) {
    return (
      envelope: null,
      error: 'wrong QR type (expected ${requireType.tag}): scan the correct panel',
    );
  }
  final ts = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (exp < ts) {
    return (envelope: null, error: 'provision payload expired: get a fresh QR');
  }
  return (
    envelope: ProvisionEnvelope(
      type: type,
      expiresAt: exp,
      nonce: nonce,
      data: data,
      signature: sig,
    ),
    error: null,
  );
}

/// Purpose tag carried by HQ-issued account payloads.
enum ProvisionPurpose {
  citizen('citizen'),
  officer('officer');

  const ProvisionPurpose(this.tag);
  final String tag;

  static ProvisionPurpose? fromTag(String? tag) => switch (tag) {
    'citizen' => ProvisionPurpose.citizen,
    'officer' => ProvisionPurpose.officer,
    _ => null,
  };
}

/// Encodes an account into a typed v2 provisioning payload. The password hash
/// (not the plaintext) travels in the QR so the holder of a captured frame
/// cannot replay the account; only the password's digest is published.
/// When [certB64] (GZCERT) and a `signer` are supplied the envelope is
/// HQ-signed (`sig`) so fake QRs cannot be forged without the authority key.
String encodeAccountProvision({
  required ProvisionPurpose purpose,
  required String username,
  required String passwordHash,
  String? pinHash,
  String? aadhaar,
  String? familyId,
  String? officerId,
  String? authorityPub,
  String? certB64,
  String? netKeyB64,
  String? Function(String canonical)? signer,
  int expiresInSeconds = kAccountLifetimeSeconds,
  int? now,
}) {
  final data = <String, Object?>{
    'p': purpose.tag,
    'u': username,
    'h': passwordHash,
    if (pinHash != null) 'pin': pinHash,
    if (aadhaar != null) 'a': aadhaar,
    if (familyId != null) 'f': familyId,
    if (officerId != null) 'oid': officerId,
    if (authorityPub != null) 'ak': authorityPub,
    if (certB64 != null) 'cert': certB64,
    if (netKeyB64 != null) 'netKey': netKeyB64,
  };
  if (signer == null) {
    return encodeProvisionEnvelope(
      type: ProvisionType.account,
      expiresInSeconds: expiresInSeconds,
      now: now,
      data: data,
    );
  }
  // Signed path: build unsigned envelope to get exp/nonce, then sign canonical.
  final ts = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final nonce = List.generate(8, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
  final exp = ts + expiresInSeconds;
  final canonical = canonicalProvision(v: 2, t: ProvisionType.account.tag, exp: exp, nonce: nonce, data: data);
  final sig = signer(canonical);
  return jsonEncode({
    'v': 2,
    't': ProvisionType.account.tag,
    'exp': exp,
    'nonce': nonce,
    'data': data,
    'sig': sig,
  });
}

/// Parses an account provisioning payload. Returns null on any malformed,
/// expired, or non-account payload. The `sig` is not verified here — the
/// caller must call `verifyProvisionEnvelope` with the HQ authority pub.
({ProvisionPurpose purpose, String username, String passwordHash, String? pinHash, String? aadhaar, String? familyId, String? officerId, String? authorityPub, String? certB64, String? netKeyB64, String? sig})?
decodeAccountProvision(String payload, {int? now}) {
  final parsed = parseProvisionEnvelope(payload, requireType: ProvisionType.account, now: now);
  final env = parsed.envelope;
  if (env == null) return null;
  final purpose = ProvisionPurpose.fromTag(env.data['p'] as String?);
  final username = env.data['u'] as String?;
  final hash = env.data['h'] as String?;
  if (purpose == null || username == null || hash == null) return null;
  final pin = env.data['pin'] as String?;
  final aadhaar = env.data['a'] as String?;
  final family = env.data['f'] as String?;
  final officerId = env.data['oid'] as String?;
  final authorityPub = env.data['ak'] as String?;
  final cert = env.data['cert'] as String?;
  final netKey = env.data['netKey'] as String?;
  if (pin != null && pin.length != 64) return null;
  if (hash.length != 64) return null;
  return (
    purpose: purpose,
    username: username,
    passwordHash: hash,
    pinHash: pin,
    aadhaar: aadhaar,
    familyId: family,
    officerId: officerId,
    authorityPub: authorityPub,
    certB64: cert,
    netKeyB64: netKey,
    sig: env.signature,
  );
}

/// Returns true when `env` carries a `sig` that verifies against `authorityPubB64`.
/// Canonical is `GZPROV|v|t|exp|nonce|canonicalData` where canonicalData is
/// sorted-key JSON of `env.data`. Uses the same ECDSA verify as landmarks.
bool verifyProvisionEnvelope(
  ProvisionEnvelope env,
  String authorityPubB64,
  bool Function(List<int> pub, String canonical, List<int> sig) verifier,
) {
  final sigB64 = env.signature;
  if (sigB64 == null) return false;
  try {
    final canonical = canonicalProvision(v: 2, t: env.type.tag, exp: env.expiresAt, nonce: env.nonce, data: env.data);
    final sig = base64Decode(sigB64);
    final pub = base64Decode(authorityPubB64);
    return verifier(pub, canonical, sig);
  } catch (_) {
    return false;
  }
}

/// Encodes a Tier-2 family card handoff. Unlike the old RSA-signed sample, the
/// QR itself is the trust handoff: HQ physically issues it, same model as
/// accounts: so no on-device signing key is needed.
String encodeFamilyCardProvision({
  required String familyId,
  required String rationCode,
  required double dailyUnits,
  required List<String> memberIds,
  int expiresInSeconds = kFamilyCardLifetimeSeconds,
  int? now,
}) {
  return encodeProvisionEnvelope(
    type: ProvisionType.family,
    expiresInSeconds: expiresInSeconds,
    now: now,
    data: {
      'fid': familyId,
      'rc': rationCode,
      'du': dailyUnits,
      'm': memberIds,
    },
  );
}

/// Parsed family card fields from a typed v2 envelope.
typedef FamilyCardData = ({
  String familyId,
  String rationCode,
  double dailyUnits,
  List<String> memberIds,
});

/// Parses a family card payload. Returns null on malformed, expired, or
/// non-family payloads.
FamilyCardData? decodeFamilyCardProvision(String payload, {int? now}) {
  final parsed = parseProvisionEnvelope(payload, requireType: ProvisionType.family, now: now);
  final env = parsed.envelope;
  if (env == null) return null;
  final familyId = env.data['fid'] as String?;
  final rationCode = env.data['rc'] as String?;
  final dailyUnits = env.data['du'] as num?;
  final members = env.data['m'];
  if (familyId == null || rationCode == null || dailyUnits == null) return null;
  if (members is! List) return null;
  final memberIds = members.whereType<String>().toList();
  if (memberIds.isEmpty || memberIds.length != members.length) return null;
  return (
    familyId: familyId,
    rationCode: rationCode,
    dailyUnits: dailyUnits.toDouble(),
    memberIds: memberIds,
  );
}

/// Encodes a wifi hotspot handoff: SSID + password for a temporary
/// officer-hosted access point (the laptop HQ joins it to push the DB).
/// Credentials travel in the clear because the QR itself is the trusted
/// in-person handoff, same trust model as account provisioning.
String encodeHotspotProvision({
  required String ssid,
  required String password,
  int expiresInSeconds = kHotspotLifetimeSeconds,
  int? now,
}) {
  return encodeProvisionEnvelope(
    type: ProvisionType.hotspot,
    expiresInSeconds: expiresInSeconds,
    now: now,
    data: {
      'ssid': ssid,
      'pass': password,
    },
  );
}

/// Parsed hotspot wifi credentials from a typed v2 envelope.
typedef HotspotData = ({String ssid, String password});

/// Parses a hotspot payload. Returns null on malformed, expired, or
/// non-hotspot payloads.
HotspotData? decodeHotspotProvision(String payload, {int? now}) {
  final parsed = parseProvisionEnvelope(
    payload,
    requireType: ProvisionType.hotspot,
    now: now,
  );
  final env = parsed.envelope;
  if (env == null) return null;
  final ssid = env.data['ssid'] as String?;
  final password = env.data['pass'] as String?;
  if (ssid == null || ssid.isEmpty) return null;
  if (password == null || password.isEmpty) return null;
  return (ssid: ssid, password: password);
}