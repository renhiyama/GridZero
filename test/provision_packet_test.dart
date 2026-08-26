import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:gridzero/core/provision_packet.dart';

void main() {
  group('provisionChunks', () {
    test('splits a payload into ordered frames with crc', () {
      final payload = jsonEncode({
        'v': 1,
        'p': 'citizen',
        'u': 'AMARA',
        'h': List.generate(32, (i) => i).map((e) => e.toRadixString(16).padLeft(2, '0')).join(),
      });
      final frames = provisionChunks(payload);
      expect(frames.length, greaterThan(1));
      expect(frames.first.startsWith('GZ1|1/'), isTrue);
      expect(frames.last, contains('${frames.length}/${frames.length}'));
      expect(isProvisionFrame(frames.first), isTrue);
    });

    test('tiny payload still frames as 1 chunk', () {
      final frames = provisionChunks('{"v":1,"p":"citizen"}');
      expect(frames.length, 1);
      expect(frames.single, startsWith('GZ1|1/1|'));
    });
  });

  group('ProvisionAssembler', () {
    test('reassembles in any order and verifies crc', () {
      final payload = jsonEncode({
        'v': 1,
        'p': 'officer',
        'u': 'OFFICER9001!',
        'h': List.generate(32, (i) => i * 3)
            .map((e) => e.toRadixString(16).padLeft(2, '0'))
            .join(),
      });
      final frames = provisionChunks(payload);
      final assembler = ProvisionAssembler();
      // Feed reversed: order must not matter.
      for (final f in frames.reversed) {
        expect(assembler.add(f), isNull);
      }
      expect(assembler.complete, isTrue);
      expect(assembler.payload, payload);
    });

    test('rejects a corrupt frame with checksum mismatch', () {
      final payload = '{"v":1,"p":"citizen","u":"AMARA","h":"${'a' * 64}"}';
      final frames = provisionChunks(payload);
      final assembler = ProvisionAssembler();
      final bad = frames.toList();
      // Flip a char in the last chunk's data.
      final last = bad.last;
      bad[bad.length - 1] = '${last.substring(0, last.length - 3)}ZZZ';
      String? status;
      for (final f in bad) {
        status = assembler.add(f);
        if (status != null) break;
      }
      expect(status, contains('checksum'));
      expect(assembler.complete, isFalse);
    });

    test('detects a frame from a different payload', () {
      final a = provisionChunks('payload one data');
      final b = provisionChunks('payload two data');
      final assembler = ProvisionAssembler();
      expect(assembler.add(a.first), isNull);
      expect(assembler.add(b.first), isNotNull);
      expect(assembler.add(b.last), isNotNull);
    });

    test('rejects non-provision frames', () {
      final assembler = ProvisionAssembler();
      expect(assembler.add('{"v":1,"p":"citizen"}'), isNotNull);
      expect(assembler.complete, isFalse);
    });
  });

  group('account provision codec', () {
    test('roundtrips a citizen payload', () {
      final payload = encodeAccountProvision(
        purpose: ProvisionPurpose.citizen,
        username: 'AMARA',
        passwordHash: 'a' * 64,
        pinHash: 'b' * 64,
        aadhaar: '2345 6789 0123',
        familyId: 'FAM-DEADBEEF',
      );
      final decoded = decodeAccountProvision(payload);
      expect(decoded, isNotNull);
      expect(decoded!.purpose, ProvisionPurpose.citizen);
      expect(decoded.username, 'AMARA');
      expect(decoded.passwordHash, 'a' * 64);
      expect(decoded.pinHash, 'b' * 64);
      expect(decoded.aadhaar, '2345 6789 0123');
      expect(decoded.familyId, 'FAM-DEADBEEF');
    });

    test('roundtrips an officer payload with officer id', () {
      final payload = encodeAccountProvision(
        purpose: ProvisionPurpose.officer,
        username: 'NAVIN',
        passwordHash: 'c' * 64,
        officerId: 'OFF-0A3F0FAB',
      );
      final decoded = decodeAccountProvision(payload);
      expect(decoded, isNotNull);
      expect(decoded!.purpose, ProvisionPurpose.officer);
      expect(decoded.officerId, 'OFF-0A3F0FAB');
      expect(decoded.aadhaar, isNull);
    });

    test('rejects malformed payloads', () {
      expect(decodeAccountProvision('not json'), isNull);
      expect(decodeAccountProvision('{"v":2,"p":"citizen"}'), isNull);
      expect(decodeAccountProvision('{"v":1,"p":"ghost","u":"X","h":"${'a' * 64}"}'), isNull);
      expect(decodeAccountProvision('{"v":1,"p":"citizen","u":"X","h":"short"}'), isNull);
    });
  });

  group('hotspot provision codec', () {
    test('roundtrips credentials in a typed envelope', () {
      final payload = encodeHotspotProvision(
        ssid: 'DIRECT-gz-sync',
        password: 'abc12345',
        now: 1700000000,
      );
      final decoded = decodeHotspotProvision(payload, now: 1700000000);
      expect(decoded, isNotNull);
      expect(decoded!.ssid, 'DIRECT-gz-sync');
      expect(decoded.password, 'abc12345');
    });

    test('expires after the short hotspot lifetime', () {
      final payload = encodeHotspotProvision(
        ssid: 'DIRECT-gz',
        password: 'abc12345',
        now: 1700000000,
      );
      expect(
        decodeHotspotProvision(
          payload,
          now: 1700000000 + kHotspotLifetimeSeconds + 1,
        ),
        isNull,
      );
    });

    test('is rejected when a different type is required', () {
      final payload = encodeHotspotProvision(
        ssid: 'DIRECT-gz',
        password: 'abc12345',
      );
      expect(
        parseProvisionEnvelope(
          payload,
          requireType: ProvisionType.family,
        ).envelope,
        isNull,
      );
      expect(
        parseProvisionEnvelope(
          payload,
          requireType: ProvisionType.hotspot,
        ).envelope,
        isNotNull,
      );
    });

    test('rejects malformed hotspot payloads', () {
      final envelope = encodeProvisionEnvelope(
        type: ProvisionType.hotspot,
        data: {'ssid': 'x'},
      );
      expect(decodeHotspotProvision(envelope), isNull);
    });
  });
}