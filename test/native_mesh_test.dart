import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/mesh/native_mesh.dart';

void main() {
  final now = 1_000_000;
  final leap = const Duration(seconds: 90).inMilliseconds;
  final burst = const Duration(seconds: 12).inMilliseconds;

  group('radio governor duty-cycle tiers', () {
    test('alert scans continuously', () {
      expect(
        radioGovernorSleep(
          alert: true,
          peerSosUntil: 0,
          burstUntil: 0,
          active: true,
          now: now,
        ),
        Duration.zero,
      );
    });

    test('a live peer SOS within its lease keeps continuous scanning', () {
      expect(
        radioGovernorSleep(
          alert: false,
          peerSosUntil: now + leap - 1,
          burstUntil: 0,
          active: false,
          now: now,
        ),
        Duration.zero,
      );
    });

    test('an expired peer SOS lease falls back to normal duty', () {
      final sleep = radioGovernorSleep(
        alert: false,
        peerSosUntil: now + leap,
        burstUntil: 0,
        active: true,
        now: now,
      );
      expect(sleep, Duration.zero);
      final expired = radioGovernorSleep(
        alert: false,
        peerSosUntil: now - 1,
        burstUntil: 0,
        active: true,
        now: now,
      );
      expect(expired, isNot(Duration.zero));
      expect(expired, radioGovernorSleep(
        alert: false,
        peerSosUntil: 0,
        burstUntil: 0,
        active: true,
        now: now,
      ));
    });

    test('a discovery burst is near-continuous and time-boxed', () {
      final activeBurst = radioGovernorSleep(
        alert: false,
        peerSosUntil: 0,
        burstUntil: now + burst - 1,
        active: true,
        now: now,
      );
      expect(activeBurst, isNot(Duration.zero));
      expect(activeBurst, lessThan(const Duration(seconds: 1)));

      final lapsed = radioGovernorSleep(
        alert: false,
        peerSosUntil: 0,
        burstUntil: now - 1,
        active: true,
        now: now,
      );
      expect(lapsed, const Duration(seconds: 9));
    });

    test('signed-in sessions scan at nominal duty', () {
      expect(
        radioGovernorSleep(
          alert: false,
          peerSosUntil: 0,
          burstUntil: 0,
          active: true,
          now: now,
        ),
        const Duration(seconds: 9),
      );
    });

    test('anonymous standby scans rarely to bank battery', () {
      expect(
        radioGovernorSleep(
          alert: false,
          peerSosUntil: 0,
          burstUntil: 0,
          active: false,
          now: now,
        ),
        const Duration(seconds: 27),
      );
    });
  });
}