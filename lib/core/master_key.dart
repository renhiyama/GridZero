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

import 'ledger/ledger_store.dart';

/// Sample master key produced by `tool/generate_master_key.dart` (v=1).
const String kSampleMasterKeyPayload =
    '{"v":1,"officer_id":"OFF-0A3F0FAB","issued_at":1787082581,"sig":"BjbFIYFKLf0ROogTuJeCekJ0IHeRsLamok5GMBLPG/3vrfLEE+kQPm2/M2OlJo0zxy5nSp6/vM2S4InBoWIEve1fdtew8pwpgKyjgOBwWKbPYwe9pxn94ViRx7JHiVt3EZ4QDoqAZw9ueVJmMnRVycwuUwTZhiR1LbxzpEYskoVCDv86l51vzmNS1uiU6EhHwGtD6uLaqv69Ef/HDfLZHRB894v77hQWRukikX6ISzvn4O8W9Ctj0Ok6JTfyY+j8TYx7JIk4WgeY5BxQlFjbNx5Te7pvSiOo8QAkrnJ1oSWopGZwR6H842O1op5n3z6jllehGxuajB6dqAPkOx4kXw=="}';

/// Sample Tier-2 family card signed by the same HQ key, members replaced
/// with the demo roster. Officers cache whatever card they scan.
const String kSampleFamilyCardPayload =
    '{"v":1,"kind":"family","family_id":"FAM-DEADBEEF","ration_code":"Rice","daily_units":4.0,"member_ids":["CIT-00000001","CIT-00000002"],"issued_at":1787082581,"sig":"AVB+kL9yWAbIDYEKgDL6Rfrn8cZ/Y5NQD9OIwA+uJ/YoNzwlkVZPcaLD3SDmPGxUvLjJIlpO2KO/cGG4I4SkK6nTSNHa5ukrYA/sZEwgT74p0EqpO+9UQAO1dW2DVO3+pN7fnQlCtH+J48g9HUFApNHVSIjP/UViquPAXMt9On16msrLQFoaO3yNA/PnTRzpDlNSQzqKaVdvCginp1EKaVleDVxdH7M4YNzMU8eIHIBfHBCoQS/Da3SaX0NPwPqf5J/77CZSDXaA/4+92QcJgwbsD/cLy7oucRAY6La6PTeQSq6OvJ7k5jFqrWfmfsjhWyM0Y+dEWd1TRXI5NqKGUg=="}';

const String _canonicalPrefix = 'v=1|officer_id=';

/// Canonical prefix for Tier-2 family card payloads, distinct from the
/// officer key so a family QR can never be mistaken for an enlistment.
const String _familyCanonicalPrefix = 'v=1|kind=family|family_id=';

class MasterKey {
  MasterKey({required this.officerId, required this.issuedAt});

  final String officerId;
  final int issuedAt;
}

class MasterKeyCheck {
  MasterKeyCheck.ok(this.masterKey) : message = '', ok = true;
  MasterKeyCheck.fail(this.message) : masterKey = null, ok = false;

  final bool ok;
  final String message;
  final MasterKey? masterKey;
}

/// Tier-2 family card result: a verified [FamilyCard] ready to cache.
class FamilyCardCheck {
  FamilyCardCheck.ok(this.card) : message = '', ok = true;
  FamilyCardCheck.fail(this.message) : card = null, ok = false;

  final bool ok;
  final String message;
  final FamilyCard? card;
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

String _canonical(MasterKey key) =>
    '$_canonicalPrefix${key.officerId}|issued_at=${key.issuedAt}';

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
      PublicKeyParameter<RSAPublicKey>(RSAPublicKey(pub.modulus, pub.exponent)),
    );
  final valid = signer.verifySignature(
    utf8.encode(_canonical(key)),
    RSASignature(Uint8List.fromList(sig)),
  );
  if (!valid) {
    return MasterKeyCheck.fail('signature invalid — master key rejected');
  }
  return MasterKeyCheck.ok(key);
}

/// Parses a family enlistment QR payload without trusting it:
/// `{"v":1,"kind":"family","family_id":"FAM-..","ration_code":"Rice",
/// "daily_units":4,"member_ids":["CIT-.."],"issued_at":..,"sig":".."}`.
FamilyCard? parseFamilyCardPayload(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map<String, dynamic>) return null;
    if (map['v'] != 1 || map['kind'] != 'family') return null;
    final familyId = map['family_id'];
    final rationCode = map['ration_code'];
    final dailyUnits = map['daily_units'];
    final members = map['member_ids'];
    final sig = map['sig'];
    if (familyId is! String ||
        rationCode is! String ||
        dailyUnits is! num ||
        members is! List ||
        sig is! String) {
      return null;
    }
    final memberIds = members.whereType<String>().toList();
    if (memberIds.isEmpty || memberIds.length != members.length) return null;
    return FamilyCard(
      familyId: familyId,
      rationCode: rationCode,
      dailyUnits: dailyUnits.toDouble(),
      memberCitizenIds: memberIds,
    );
  } catch (_) {
    return null;
  }
}

String _familyCanonical(FamilyCard card) {
  final members = card.memberCitizenIds.join(',');
  return '$_familyCanonicalPrefix${card.familyId}|ration_code=${card.rationCode}'
      '|daily_units=${card.dailyUnits.toStringAsFixed(2)}'
      '|member_ids=$members';
}

/// Validates a family enlistment QR against the same embedded HQ public key
/// used for officer keys. Returns a usable [FamilyCard] on success.
Future<FamilyCardCheck> verifyFamilyCard({
  required String payload,
  String? officerPublicKeyPem,
}) async {
  final card = parseFamilyCardPayload(payload);
  if (card == null) {
    return FamilyCardCheck.fail('malformed family card payload');
  }
  final pem = officerPublicKeyPem ?? await loadOfficerPublicKeyPem();
  final pub = parseRsaPublicPem(pem);
  final sig = base64Decode(jsonDecode(payload)['sig'] as String);

  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(
      false,
      PublicKeyParameter<RSAPublicKey>(RSAPublicKey(pub.modulus, pub.exponent)),
    );
  final valid = signer.verifySignature(
    utf8.encode(_familyCanonical(card)),
    RSASignature(Uint8List.fromList(sig)),
  );
  if (!valid) {
    return FamilyCardCheck.fail('signature invalid — family card rejected');
  }
  return FamilyCardCheck.ok(card);
}
