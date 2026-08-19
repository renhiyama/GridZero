import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:gridzero/core/app_state.dart';
import 'package:gridzero/core/ledger/ledger_store.dart';
import 'package:gridzero/core/master_key.dart';
import 'package:gridzero/core/mesh_packet.dart';
import 'package:gridzero/core/totp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_mesh_adapter.dart';

AppState makeState() {
  AppState.nativeAdapterFactory = (nodeId) => FakeMeshAdapter();
  return AppState();
}

const m1 = 'CIT-00000001';
const m2 = 'CIT-00000002';
const pin = '4821';

String claimQr(String citizenId, {String? pinHash, String? familyId}) {
  final window = totpTimeWindow(DateTime.now());
  return '{"v":1,"c":"$citizenId","w":$window,"tok":'
      '"${totpToken(citizenId: citizenId, citizenKey: _key(citizenId), timeWindow: window)}"'
      '${pinHash != null ? ',"ph":"$pinHash"' : ''}'
      '${familyId != null ? ',"f":"$familyId"' : ''}}';
}

List<int> _key(String citizenId) =>
    sha256.convert(utf8.encode('gridzero:citizen:$citizenId')).bytes;

String _pinHash(String pin) =>
    sha256.convert(utf8.encode('gridzero:pin:$pin')).toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('family card payload parses and verifies signature', () async {
    final check = await verifyFamilyCard(payload: kSampleFamilyCardPayload);
    expect(check.ok, isTrue);
    expect(check.card!.familyId, 'FAM-DEADBEEF');
    expect(check.card!.rationCode, 'Rice');
    expect(check.card!.dailyUnits, 4.0);
    expect(check.card!.memberCitizenIds, [m1, m2]);
  });

  test('enlistFamily caches a verified card in the ledger', () async {
    final app = makeState();
    await app.init();
    final check = await app.enlistFamily(kSampleFamilyCardPayload);
    expect(check.ok, isTrue);
    final card = await app.ledger.familyCard('FAM-DEADBEEF');
    expect(card, isNotNull);
    expect(card!.memberCitizenIds, contains(m1));
    app.dispose();
  });

  test('fractional claim draws against family card daily cap', () async {
    final officer = makeState();
    await officer.init();
    await officer.enlistOfficer(kSampleMasterKeyPayload);
    await officer.ledger.upsertFamilyCard(
      FamilyCard(
        familyId: 'FAM-TEST',
        rationCode: 'Rice',
        dailyUnits: 1.0,
        memberCitizenIds: [m1, m2],
      ),
    );

    final first = await officer.claimFromPayload(
      claimQr(m1, familyId: 'FAM-TEST'),
      'Rice',
      claimUnits: 0.75,
    );
    expect(first.status, ClaimStatus.granted);
    expect(first.record!.claimUnits, 0.75);
    expect(first.record!.familyId, 'FAM-TEST');

    final dayStart =
        DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 ~/ 86400 * 86400;
    expect(await officer.ledger.familyUsedUnits('FAM-TEST', dayStart), 0.75);

    // Second member pushes the household over its 1.0/day entitlement.
    final second = await officer.claimFromPayload(
      claimQr(m2, familyId: 'FAM-TEST'),
      'Rice',
      claimUnits: 0.75,
    );
    expect(second.status, ClaimStatus.familyExhausted);

    officer.dispose();
  });

  test('family claims reject unknown card and non-member', () async {
    final officer = makeState();
    await officer.init();
    await officer.enlistOfficer(kSampleMasterKeyPayload);
    await officer.ledger.upsertFamilyCard(
      FamilyCard(
        familyId: 'FAM-TEST',
        rationCode: 'Rice',
        dailyUnits: 4.0,
        memberCitizenIds: [m1],
      ),
    );

    final unknown = await officer.claimFromPayload(
      claimQr(m1, familyId: 'FAM-UNKNOWN'),
      'Rice',
    );
    expect(unknown.status, ClaimStatus.familyUnknown);

    final outsider = await officer.claimFromPayload(
      claimQr('CIT-99999999', familyId: 'FAM-TEST'),
      'Rice',
    );
    expect(outsider.status, ClaimStatus.notFamilyMember);

    officer.dispose();
  });

  test('PIN fallback verifies when TOTP window is stale', () async {
    final officer = makeState();
    await officer.init();
    await officer.enlistOfficer(kSampleMasterKeyPayload);

    // TOTP token from a past window so the primary check fails.
    final staleWindow = totpTimeWindow(DateTime.now()) - 3;
    final payload =
        '{"v":1,"c":"$m1","w":$staleWindow,"tok":'
        '"${totpToken(citizenId: m1, citizenKey: _key(m1), timeWindow: staleWindow)}"'
        ',"ph":"${_pinHash(pin)}"}';

    final noFallback = await officer.claimFromPayload(payload, 'Rice');
    expect(noFallback.status, ClaimStatus.invalidToken);

    final wrong = await officer.claimFromPayload(
      payload,
      'Rice',
      fallbackPin: '0000',
    );
    expect(wrong.status, ClaimStatus.pinMismatch);

    final ok = await officer.claimFromPayload(
      payload,
      'Rice',
      fallbackPin: pin,
    );
    expect(ok.status, ClaimStatus.granted);
    expect(ok.record!.signature, isNotNull);

    officer.dispose();
  });

  test('claim units roundtrip the 0x05 sync frame', () {
    for (final units in [0.25, 0.5, 0.75, 1.0]) {
      final packet = MeshPacket(
        type: MeshPacketType.ledgerRecord,
        senderId: 0xBEEF,
        latitude: 0,
        longitude: 0,
        triage: TriageFlags(),
        seq: 1,
        syncRecord: CompactRecord(
          citizenId: m1,
          officerId: 'OFF-0A3F0FAB',
          claimedAt: 1700000000,
          rationCode: 'Rice',
          claimUnits: units,
        ),
      );
      final decoded = MeshPacket.decode(packet.encode());
      expect(decoded.syncRecord!.claimUnits, units);
    }
  });

  test('legacy 0x05 frame with bare flags decodes to a full unit', () {
    final raw = MeshPacket(
      type: MeshPacketType.ledgerRecord,
      senderId: 0xBEEF,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: 1,
      syncRecord: CompactRecord(
        citizenId: m1,
        officerId: 'OFF-0A3F0FAB',
        claimedAt: 1700000000,
        rationCode: 'Rice',
      ),
    ).encode();
    raw[17] = 0x01; // legacy marker, no unit bits
    expect(MeshPacket.decode(raw).syncRecord!.claimUnits, 1.0);
  });

  test('packet symbol rendering covers the tactical set', () {
    expect(packetSymbol(MeshPacketType.sosBeacon), '[▲ SOS]');
    expect(packetSymbol(MeshPacketType.ledgerRecord), '[≡ LEDGER]');
    expect(packetSymbol(MeshPacketType.revocationAlert), '[✕ REVOKED]');
  });
}
