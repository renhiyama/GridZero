import 'package:aapadsetu/core/totp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = List<int>.generate(32, (i) => i);

  test('token is deterministic within a window', () {
    final t1 = totpToken(citizenId: 'CIT-AABBCCDD', citizenKey: key, timeWindow: 1000);
    final t2 = totpToken(citizenId: 'CIT-AABBCCDD', citizenKey: key, timeWindow: 1000);
    expect(t1, t2);
    expect(t1.length, 32);
  });

  test('adjacent windows produce different tokens', () {
    final a = totpToken(citizenId: 'CIT-X', citizenKey: key, timeWindow: 100);
    final b = totpToken(citizenId: 'CIT-X', citizenKey: key, timeWindow: 101);
    expect(a, isNot(b));
  });

  test('different citizen ids produce different tokens', () {
    final a = totpToken(citizenId: 'CIT-AAAA', citizenKey: key, timeWindow: 5);
    final b = totpToken(citizenId: 'CIT-BBBB', citizenKey: key, timeWindow: 5);
    expect(a, isNot(b));
  });

  test('verify accepts current window', () {
    final now = DateTime.fromMillisecondsSinceEpoch(30 * 1000 * 12345);
    final token =
        totpToken(citizenId: 'CIT-Z', citizenKey: key, timeWindow: totpTimeWindow(now));
    expect(
      totpVerify(citizenId: 'CIT-Z', citizenKey: key, claimedToken: token, now: now),
      isTrue,
    );
  });

  test('verify rejects expired tokens outside tolerance', () {
    final oldWindow = 1000;
    final token = totpToken(citizenId: 'CIT-Z', citizenKey: key, timeWindow: oldWindow);
    final later = DateTime.fromMillisecondsSinceEpoch((oldWindow + 10) * 30 * 1000);
    expect(
      totpVerify(citizenId: 'CIT-Z', citizenKey: key, claimedToken: token, now: later),
      isFalse,
    );
  });

  test('verify rejects forged tokens', () {
    expect(
      totpVerify(
        citizenId: 'CIT-Z',
        citizenKey: key,
        claimedToken: 'f' * 32,
        now: DateTime.fromMillisecondsSinceEpoch(30 * 1000 * 777),
      ),
      isFalse,
    );
  });

  test('window boundary is floor of epoch / 30', () {
    expect(totpTimeWindow(DateTime.fromMillisecondsSinceEpoch(30 * 1000 * 5)), 5);
    expect(totpTimeWindow(DateTime.fromMillisecondsSinceEpoch(30 * 1000 * 5 + 29999)), 5);
  });
}