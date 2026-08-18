import 'package:gridzero/core/master_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sample master key verifies against embedded public key', () async {
    final check = await verifyMasterKey(payload: kSampleMasterKeyPayload);
    expect(check.ok, isTrue, reason: check.message);
    expect(check.masterKey!.officerId, 'OFF-0A3F0FAB');
  });

  test('tampered payload fails signature', () async {
    final tampered = kSampleMasterKeyPayload.replaceFirst(
      'OFF-0A3F0FAB',
      'OFF-EVIL0001',
    );
    final check = await verifyMasterKey(payload: tampered);
    expect(check.ok, isFalse);
  });

  test('garbage payload is rejected', () async {
    final check = await verifyMasterKey(payload: 'not-json');
    expect(check.ok, isFalse);
  });

  test('embedded PEM decodes to RSA 2048 modulus', () async {
    final pem = await loadOfficerPublicKeyPem();
    final parsed = parseRsaPublicPem(pem);
    expect(parsed.modulus.bitLength, 2048);
    expect(parsed.exponent, BigInt.parse('65537'));
  });
}
