/// Air-gapped officer enlistment (FR-2.3 / FEAT-ROLE-01).
///
/// An Officer Master Key is a QR payload signed with the HQ private key. The
/// terminal only embeds the public half (assets/officer_pubkey.pem), so role
/// activation works with zero connectivity. Verification is plain PKCS#1 v1.5
/// RSA over the canonical payload string.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart';

/// Sample master key produced by `tool/generate_master_key.dart` (v=1).
const String kSampleMasterKeyPayload =
    '{"v":1,"officer_id":"OFF-0A3F0FAB","issued_at":1787051724,"sig":"hmWBrjWHw8aSTrIIRP++LXpYFxNm24JJkFwogHxnuzSRcfBJaZnGa1P7la+Wzwyh3X6YUXq8oj4EUB4FHsyp6KQ9PAXMTUfn/MBn4UuIqSFJQfF2HcSu7JX1zBsGI0gn0wbrCqwUw0wvYkj/3rT4/W5n21GRFTW4GbPgGvEc35/Fkpz6e5DlpuE5GPyId+XuDPLYxUl5YSMmJ6urVsL8oO8sYEoCDXABZyWZ4qqvQgMLcRZTkZsqsavNrF99T9EUFZCmAlNv3caTg/gJpbQt5SbGqN8ZhArL7Mrw+j5MlH0u/n58cZYg7IzEfqW/MhZghH+lPNjssgn8qYaprmrfqA=="}';

const String _canonicalPrefix = 'v=1|officer_id=';

class MasterKey {
  MasterKey({required this.officerId, required this.issuedAt});

  final String officerId;
  final int issuedAt;
}

class MasterKeyCheck {
  MasterKeyCheck.ok(this.masterKey)
      : message = '',
        ok = true;
  MasterKeyCheck.fail(this.message)
      : masterKey = null,
        ok = false;

  final bool ok;
  final String message;
  final MasterKey? masterKey;
}

Future<String> loadOfficerPublicKeyPem() async {
  final raw = await rootBundle.loadString('assets/officer_pubkey.pem');
  return raw.trim();
}

/// Parses a scanned master-key QR payload without trusting it.
MasterKey? parseMasterKeyPayload(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map<String, dynamic>) return null;
    if (map['v'] != 1) return null;
    final officerId = map['officer_id'];
    final issuedAt = map['issued_at'];
    final sig = map['sig'];
    if (officerId is! String || issuedAt is! int || sig is! String) return null;
    return MasterKey(officerId: officerId, issuedAt: issuedAt);
  } catch (_) {
    return null;
  }
}

String _canonical(MasterKey key) => '$_canonicalPrefix${key.officerId}|issued_at=${key.issuedAt}';

/// Decodes a PEM `PUBLIC KEY` block into the embedded RSA (n, e).
({BigInt modulus, BigInt exponent}) parseRsaPublicPem(String pem) {
  final body = pem
      .replaceAll('-----BEGIN PUBLIC KEY-----', '')
      .replaceAll('-----END PUBLIC KEY-----', '')
      .replaceAll('\n', '')
      .trim();
  final der = base64Decode(body);
  return _parseRsaDer(der);
}

/// Walks DER, collecting INTEGER leaves in order; first two are n then e.
({BigInt modulus, BigInt exponent}) _parseRsaDer(Uint8List der) {
  final ints = <BigInt>[];
  void walk(int offset, int end) {
    var i = offset;
    while (i < end) {
      final tag = der[i];
      i++;
      var length = der[i] & 0x7f;
      i++;
      if ((der[i - 1] & 0x80) != 0) {
        var lenBytes = length;
        length = 0;
        for (var b = 0; b < lenBytes; b++) {
          length = (length << 8) | der[i];
          i++;
        }
      }
      final valueStart = i;
      final valueEnd = i + length;
      if (tag == 0x02) {
        var value = BigInt.zero;
        for (var b = valueStart; b < valueEnd; b++) {
          value = (value << 8) | BigInt.from(der[b]);
        }
        ints.add(value);
      } else if (tag == 0x30 || tag == 0xa0) {
        walk(valueStart, valueEnd);
      }
      i = valueEnd;
    }
  }

  walk(0, der.length);
  if (ints.length < 2) {
    throw const FormatException('RSA public key DER has no modulus/exponent');
  }
  return (modulus: ints[0], exponent: ints[1]);
}

/// Validates a signed master-key payload against the embedded public key.
Future<MasterKeyCheck> verifyMasterKey({
  required String payload,
  String? officerPublicKeyPem,
}) async {
  final key = parseMasterKeyPayload(payload);
  if (key == null) {
    return MasterKeyCheck.fail('malformed master key payload');
  }
  final pem = officerPublicKeyPem ?? await loadOfficerPublicKeyPem();
  final pub = parseRsaPublicPem(pem);
  final sig = base64Decode(jsonDecode(payload)['sig'] as String);

  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(
        false,
        PublicKeyParameter<RSAPublicKey>(
            RSAPublicKey(pub.modulus, pub.exponent)));
  final valid = signer.verifySignature(
    utf8.encode(_canonical(key)),
    RSASignature(Uint8List.fromList(sig)),
  );
  if (!valid) {
    return MasterKeyCheck.fail('signature invalid — master key rejected');
  }
  return MasterKeyCheck.ok(key);
}
