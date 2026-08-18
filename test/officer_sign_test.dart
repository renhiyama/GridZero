import 'package:gridzero/core/ledger/officer_sign.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated officer key is P-256 uncompressed point + 32B scalar', () {
    final (pub, priv) = generateOfficerKey();
    expect(pub.length, 65);
    expect(pub.first, 0x04); // uncompressed point marker
    expect(priv.length, 32);
  });

  test('sign/verify roundtrip accepts a valid signature', () {
    final (pub, priv) = generateOfficerKey();
    final sig = signOfficerRecord(priv, 'CIT-0001|Rice|1700000000|OFF1');
    expect(sig.length, 64);
    expect(
      verifyOfficerRecord(pub, 'CIT-0001|Rice|1700000000|OFF1', sig),
      isTrue,
    );
  });

  test('signature is deterministic under RFC-6979 (no RNG)', () {
    final (_, priv) = generateOfficerKey();
    final data = 'CIT-0001|Rice|1700000000|OFF1';
    final a = signOfficerRecord(priv, data);
    final b = signOfficerRecord(priv, data);
    expect(a, b);
  });

  test('tampered record data fails verification', () {
    final (pub, priv) = generateOfficerKey();
    final sig = signOfficerRecord(priv, 'CIT-0001|Rice|1700000000|OFF1');
    expect(
      verifyOfficerRecord(pub, 'CIT-0001|Rice|1700000000|OFF2', sig),
      isFalse,
    );
    expect(
      verifyOfficerRecord(pub, 'CIT-0002|Rice|1700000000|OFF1', sig),
      isFalse,
    );
  });

  test('tampered signature or wrong key fails verification', () {
    final (pub, priv) = generateOfficerKey();
    final (otherPub, _) = generateOfficerKey();
    final sig = signOfficerRecord(priv, 'CIT-0001|Rice|1700000000|OFF1');
    final flipped = List<int>.from(sig)..[10] ^= 0x01;
    expect(
      verifyOfficerRecord(pub, 'CIT-0001|Rice|1700000000|OFF1', flipped),
      isFalse,
    );
    expect(
      verifyOfficerRecord(otherPub, 'CIT-0001|Rice|1700000000|OFF1', sig),
      isFalse,
    );
  });

  test('malformed signature length is rejected without throwing', () {
    final (pub, priv) = generateOfficerKey();
    final sig = signOfficerRecord(priv, 'x');
    expect(verifyOfficerRecord(pub, 'x', sig.sublist(0, 10)), isFalse);
    expect(verifyOfficerRecord(pub, 'x', const <int>[]), isFalse);
  });
}
