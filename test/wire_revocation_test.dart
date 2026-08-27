import 'package:gridzero/core/app_state.dart';
import 'package:gridzero/core/ledger/ledger_store.dart';
import 'package:gridzero/core/ledger/memory_ledger.dart';
import 'package:gridzero/core/ledger/officer_sign.dart';
import 'package:gridzero/core/mesh_packet.dart';
import 'package:gridzero/core/mesh_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_mesh_adapter.dart';

AppState makeState() {
  AppState.nativeAdapterFactory = (nodeId) => FakeMeshAdapter();
  return AppState();
}

/// Citizen ids are Aadhaar numbers now; revocations key by the same canonical
/// 4-byte tag the mesh frame carries, not the raw formatted string.
String canonId(String id) => bitsToId('CIT-', idToBits(id));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() { setNetworkKey(null); SharedPreferences.setMockInitialValues({}); });

  test('0x06 revocation alert roundtrips encode/decode', () {
    final p = MeshPacket(
      type: MeshPacketType.revocationAlert,
      senderId: 0xBEEF,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(severity: 3),
      seq: 1,
      revocation: RevocationAlert(
        citizenId: 'CIT-0000A1B2',
        reasonCode: kRevokeStolen,
        issuedAt: 1700000000,
      ),
    );
    final decoded = MeshPacket.decode(p.encode());
    expect(decoded.type, MeshPacketType.revocationAlert);
    expect(decoded.revocation!.citizenId, 'CIT-0000A1B2');
    expect(decoded.revocation!.reasonCode, kRevokeStolen);
    expect(decoded.revocation!.issuedAt, 1700000000);
  });

  test(
    'officer revocation flags citizen; citizen claims are refused',
    () async {
      final officer = makeState();
      await officer.init();
      await officer.register('OFFR1', 'pass', Role.officer);

      final citizen = makeState();
      await citizen.init();
      await citizen.register('CITX1', 'pass', Role.citizen);
      final cid = citizen.citizenId;
      final payload = citizen.citizenQrPayload();

      final before = await officer.claimFromPayload(payload, 'Rice');
      expect(before.status, ClaimStatus.granted);

      await officer.revokeCitizen(cid, reasonCode: kRevokeStolen);
      expect(officer.revokedCitizens[canonId(cid)], kRevokeStolen);

      final after = await officer.claimFromPayload(payload, 'Rice');
      expect(after.status, ClaimStatus.revoked);

      await officer.revokeCitizen(cid, reasonCode: kRevokeCleared);
      expect(officer.revokedCitizens.containsKey(canonId(cid)), isFalse);

      // The same TOTP window can't be claimed twice in a day, so the cleared
      // card returns a daily-duplicate, never a revoked refusal.
      final cleared = await officer.claimFromPayload(payload, 'Rice');
      expect(cleared.status, isNot(ClaimStatus.revoked));
      expect(cleared.status, ClaimStatus.duplicate);

      citizen.dispose();
      officer.dispose();
    },
  );

  test('citizen revocation is rejected at a second terminal too', () async {
    // Both terminals share one ledger store, as real devices would over
    // persistence (SQLite) rather than a fresh in-memory backend per state.
    final shared = MemoryLedgerStore();
    final officer = makeState();
    await officer.init(store: shared);
    await officer.register('OFFR2', 'pass', Role.officer);

    final citizen = makeState();
    await citizen.init(store: shared);
    await citizen.register('CITX2', 'pass', Role.citizen);
    final cid = citizen.citizenId;
    final payload = citizen.citizenQrPayload();

    await officer.revokeCitizen(cid, reasonCode: kRevokeStolen);

    // A second officer terminal loads the shared revocation set at startup
    // and its claim point must also refuse the flagged card.
    final officer2 = makeState();
    await officer2.init(store: shared);
    await officer2.register('OFFR3', 'pass', Role.officer);

    final result = await officer2.claimFromPayload(payload, 'Rice');
    expect(result.status, ClaimStatus.revoked);

    citizen.dispose();
    officer.dispose();
    officer2.dispose();
  });

  test('officer-signed claim embeds a verifiable signature', () async {
    final officer = makeState();
    await officer.init();
    await officer.register('OFFS1', 'pass', Role.officer);

    final citizen = makeState();
    await citizen.init();
    await citizen.register('CITS1', 'pass', Role.citizen);
    final payload = citizen.citizenQrPayload();

    final result = await officer.claimFromPayload(payload, 'Medicine');
    expect(result.status, ClaimStatus.granted);
    final records = await officer.ledger.allRecords();
    final mine = records.firstWhere(
      (r) => r.recordId == result.record!.recordId,
    );
    expect(mine.signature, isNotNull);
    expect(mine.signerPublic, isNotNull);
    expect(
      verifyOfficerRecord(
        mine.signerPublic!,
        mine.recordData(),
        mine.signature!,
      ),
      isTrue,
    );

    citizen.dispose();
    officer.dispose();
  });

  test(
    'fresh device adopts an account announced over the mesh (FR-3.9)',
    () async {
      // Two terminals sharing one radio: the host announced its account at
      // session start, the fresh device adopts it via the login probe.
      final radio = FakeMeshAdapter();
      AppState.nativeAdapterFactory = (nodeId) => radio;
      final host = AppState();
      await host.init();
      await host.register('ANNOUNCE1', 'pass123', Role.officer);

      final fresh = AppState();
      await fresh.init();
      expect(await fresh.login('ANNOUNCE1', 'pass123'), isNull);
      expect(fresh.loggedIn, isTrue);
      expect(fresh.role, Role.officer);
      expect(fresh.username, 'ANNOUNCE1');

      // Wrong password is refused even when the mesh announces the account.
      final fresh2 = AppState();
      await fresh2.init();
      expect(await fresh2.login('ANNOUNCE1', 'nope'), 'wrong password');

      fresh2.dispose();
      fresh.dispose();
      host.dispose();
    },
  );

  test('revocations persist across restart', () async {
    final shared = MemoryLedgerStore();
    final officer = makeState();
    await officer.init(store: shared);
    await officer.register('OFFR4', 'pass', Role.officer);
    final citizen = makeState();
    await citizen.init(store: shared);
    await citizen.register('CITX9', 'pass', Role.citizen);
    final cid = citizen.citizenId;
    await officer.revokeCitizen(cid, reasonCode: kRevokeSuspended);
    citizen.dispose();
    officer.dispose();

    // A fresh process (state) reloads the blacklist from the persisted store.
    final officer2 = makeState();
    await officer2.init(store: shared);
    expect(officer2.revokedCitizens[canonId(cid)], kRevokeSuspended);
    officer2.dispose();
  });
}
