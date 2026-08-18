import 'dart:convert';

import 'package:gridzero/core/app_state.dart';
import 'package:gridzero/core/ledger/ledger_store.dart';
import 'package:gridzero/core/master_key.dart';
import 'package:gridzero/core/mesh_packet.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_mesh_adapter.dart';

AppState makeState() {
  AppState.nativeAdapterFactory = (nodeId) => FakeMeshAdapter();
  return AppState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('officer enlistment activates officer role offline', () async {
    final app = makeState();
    await app.init();
    final check = await app.enlistOfficer(kSampleMasterKeyPayload);
    expect(check.ok, isTrue);
    expect(app.officerId, isNotNull);
    expect(app.role, Role.officer);
    app.dispose();
  });

  test('claim flow grants once then rejects duplicate (FR-3.4)', () async {
    final officer = makeState();
    await officer.init();
    await officer.register('OFF1', 'pass', Role.officer);

    final citizen = makeState();
    await citizen.init();
    await citizen.register('CIT1', 'pass', Role.citizen);
    final payload = citizen.citizenQrPayload();

    final first = await officer.claimFromPayload(payload, 'Rice');
    expect(first.status, ClaimStatus.granted);
    expect(officer.claimCount, 1);

    final second = await officer.claimFromPayload(payload, 'Rice');
    expect(second.status, ClaimStatus.duplicate);
    expect(officer.claimCount, 1);

    citizen.dispose();
    officer.dispose();
  });

  test('expired token is rejected before ledger append', () async {
    final officer = makeState();
    await officer.init();
    await officer.register('OFF2', 'pass', Role.officer);

    final citizen = makeState();
    await citizen.init();
    await citizen.register('CIT2', 'pass', Role.citizen);
    // forged claim: expired window + bogus token
    final forged = jsonEncode({
      'v': 1,
      'c': citizen.citizenId,
      'w': 1,
      'tok': '0' * 32,
    });

    final result = await officer.claimFromPayload(forged, 'Rice');
    expect(result.status, ClaimStatus.invalidToken);
    expect(officer.claimCount, 0);

    citizen.dispose();
    officer.dispose();
  });

  test('switch role survives', () async {
    final app = makeState();
    await app.init();
    app.switchRole(Role.citizen);
    expect(app.role, Role.citizen);
    app.dispose();
  });

  test('login gate: wrong password refused, ADMIN bypasses', () async {
    final app = makeState();
    await app.init();
    expect(app.loggedIn, isFalse);

    expect(await app.login('GHOST', 'pass'), isNotNull);
    expect(app.loggedIn, isFalse);

    await app.register('USER1', 'pass', Role.citizen);
    expect(app.loggedIn, isTrue);
    await app.logout();
    expect(app.loggedIn, isFalse);

    expect(await app.login('USER1', 'wrong'), isNotNull);
    expect(app.loggedIn, isFalse);
    expect(await app.login('USER1', 'pass'), isNull);
    expect(app.loggedIn, isTrue);
    expect(app.role, Role.citizen);
    await app.logout();

    expect(await app.login('ADMIN', 'anything'), isNull);
    expect(app.loggedIn, isTrue);
    expect(app.role, Role.admin);
    app.dispose();
  });

  test('citizen identity is stable per account across logins', () async {
    final first = makeState();
    await first.init();
    await first.register('SAME', 'pass', Role.citizen);
    final id1 = first.citizenId;
    final node1 = first.mesh!.nodeId;
    await first.logout();

    // Re-open the app and log in with the same account: same identity, so
    // peers never see a new node id for the same phone.
    final second = makeState();
    await second.init();
    expect(await second.login('SAME', 'pass'), isNull);
    expect(second.citizenId, id1);
    expect(second.mesh!.nodeId, node1);
    second.dispose();
  });

  test('delete all data wipes ledger, accounts and identity', () async {
    final app = makeState();
    await app.init();
    await app.register('USER2', 'pass', Role.officer);
    await app.enlistOfficer(kSampleMasterKeyPayload);
    expect(await app.ledger.recordsCount(), 0);

    // A real claim lands a record before the wipe.
    final citizen = makeState();
    await citizen.init();
    await citizen.register('CIT3', 'pass', Role.citizen);
    final result = await app.claimFromPayload(
      citizen.citizenQrPayload(),
      'Rice',
    );
    expect(result.status, ClaimStatus.granted);
    expect(await app.ledger.recordsCount(), 1);

    await app.deleteAllData();
    expect(app.loggedIn, isFalse);
    expect(app.citizenId, isEmpty);
    expect(await app.ledger.recordsCount(), 0);
    expect(
      await app.login('USER2', 'pass'),
      isNotNull,
      reason: 'account erased',
    );

    citizen.dispose();
    app.dispose();
  });

  test('login announces account identity onto the mesh', () async {
    final app = makeState();
    await app.init();
    await app.register('NAMED', 'pass', Role.officer);
    final adapter = app.mesh!.adapter as FakeMeshAdapter;
    final idPkts = adapter.broadcasted
        .where((p) => p.type == MeshPacketType.identityAnnounce)
        .toList();
    expect(idPkts, isNotEmpty);
    expect(idPkts.first.identityUsername, 'NAMED');
    expect(idPkts.first.identityRole, kRoleOfficer);
    app.dispose();
  });

  test(
    'claim pushes a ledger record that syncs back through the mesh (FR-3.5)',
    () async {
      final officer = makeState();
      await officer.init();
      await officer.register('OFFSYNC', 'pass', Role.officer);
      final adapter = officer.mesh!.adapter as FakeMeshAdapter;

      final citizen = makeState();
      await citizen.init();
      await citizen.register('CITSYNC', 'pass', Role.citizen);

      final result = await officer.claimFromPayload(
        citizen.citizenQrPayload(),
        'Rice',
      );
      expect(result.status, ClaimStatus.granted);
      // The fresh claim is pushed onto the mesh and marked shipped so a later
      // pull request never re-sends it.
      final pushes = adapter.broadcasted
          .where((p) => p.type == MeshPacketType.ledgerRecord)
          .toList();
      expect(pushes, isNotEmpty);
      expect(pushes.last.syncRecord!.rationCode, 'Rice');
      expect(await officer.ledger.pendingRecords(), isEmpty);

      citizen.dispose();
      officer.dispose();
    },
  );

  test('remote ledger records merge once and dedupe (FR-3.5)', () async {
    final app = makeState();
    await app.init();
    await app.register('HUB', 'pass', Role.officer);
    final adapter = app.mesh!.adapter as FakeMeshAdapter;

    CompactRecord rec() => CompactRecord(
      citizenId: 'CIT-0A3F0FAB',
      officerId: 'OFF-00BEEF',
      claimedAt: 1700000000,
      rationCode: 'Medicine',
    );
    await adapter.injectRemote(
      MeshPacket(
        type: MeshPacketType.ledgerRecord,
        senderId: 0x77,
        latitude: 0,
        longitude: 0,
        triage: TriageFlags(),
        seq: 1,
        syncRecord: rec(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await app.ledger.syncRecordsCount(), 1);

    // Same claim relayed again (or a cross-officer double-claim) is dropped.
    await adapter.injectRemote(
      MeshPacket(
        type: MeshPacketType.ledgerRecord,
        senderId: 0x88,
        latitude: 0,
        longitude: 0,
        triage: TriageFlags(),
        seq: 2,
        syncRecord: rec(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await app.ledger.syncRecordsCount(), 1);

    app.dispose();
  });
}
