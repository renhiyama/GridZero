import 'dart:convert';
import 'package:gridzero/core/mesh_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/ledger/officer_sign.dart';
import 'package:gridzero/core/provision_packet.dart';

void main() {
  setUp(() => setNetworkKey(null));
  test('HQ-signed provision verifies and fake fails', () {
    final auth = generateOfficerKey();
    final authPubB64 = base64Encode(auth.$1);
    final authPriv = auth.$2;
    final hash = 'a' * 64;
    final citizenKey = deriveOfficerKey(hash);
    final pubB64 = base64Encode(citizenKey.$1);
    final certB64 = base64Encode(signOfficerRecord(authPriv, 'GZCERT|ALICE|$pubB64'));
    final payload = encodeAccountProvision(
      purpose: ProvisionPurpose.citizen,
      username: 'ALICE',
      passwordHash: hash,
      authorityPub: authPubB64,
      certB64: certB64,
      signer: (canonical) => base64Encode(signOfficerRecord(authPriv, canonical)),
    );
    final parsed = parseProvisionEnvelope(payload);
    expect(parsed.envelope?.signature, isNotNull);
    expect(verifyProvisionEnvelope(parsed.envelope!, authPubB64, verifyOfficerRecord), isTrue);
    final fakeAuth = generateOfficerKey();
    expect(verifyProvisionEnvelope(parsed.envelope!, base64Encode(fakeAuth.$1), verifyOfficerRecord), isFalse);
    final dec = decodeAccountProvision(payload);
    expect(dec?.certB64, certB64);
    // unsigned should fail verify
    final unsigned = encodeAccountProvision(purpose: ProvisionPurpose.citizen, username: 'BOB', passwordHash: 'b' * 64);
    final up = parseProvisionEnvelope(unsigned);
    expect(up.envelope?.signature, isNull);
    expect(verifyProvisionEnvelope(up.envelope!, authPubB64, verifyOfficerRecord), isFalse);
  });
}
