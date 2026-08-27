import 'dart:convert';

import 'package:gridzero/core/app_state.dart';
import 'package:gridzero/core/ledger/ledger_store.dart';
import 'package:gridzero/core/mesh_packet.dart';
import 'package:gridzero/core/provision_packet.dart';
import 'package:gridzero/core/mesh_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_mesh_adapter.dart';

AppState makeState() {
  AppState.nativeAdapterFactory = (nodeId) => FakeMeshAdapter();
  return AppState();
}

String officerProvision(String username, {String? officerId}) =>
    encodeAccountProvision(
      purpose: ProvisionPurpose.officer,
      username: username,
      passwordHash: List.filled(64, 'a').join(),
      officerId: officerId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() { setNetworkKey(null); SharedPreferences.setMockInitialValues({}); });

  test('HQ provisioning activates officer role offline', () async {
    final app = makeState();
    await app.init();
    final err = await app.provisionAccount(officerProvision('REN', officerId: 'OFF-0A3F0FAB'));
    expect(err, isNull);
    expect(app.officerId, 'OFF-0A3F0FAB');
    expect(app.role, Role.officer);

    // Provisioning feeds the enrolment directory (encrypted-at-rest pending).
    final officers = await app.ledger.officers();
    expect(officers, hasLength(1));
    expect(officers.first.officerId, 'OFF-0A3F0FAB');
    expect(officers.first.registeredBy, 'OFF-PROVISION');
    expect(officers.first.publicKey, isNotEmpty);
    app.dispose();
  });

  test('stale or wrong-type provisioning payloads are rejected', () async {
    final app = makeState();
    await app.init();

    // Expired account envelope.
    final past = encodeAccountProvision(
      purpose: ProvisionPurpose.citizen,
      username: 'OLDTIMER',
      passwordHash: List.filled(64, 'a').join(),
      now: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3 * 86400,
      expiresInSeconds: 24 * 3600,
    );
    expect(await app.provisionAccount(past), contains('expired'));

    // A family QR fed to the account path must not be mistaken for one.
    final family = encodeFamilyCardProvision(
      familyId: 'FAM-TEST',
      rationCode: 'Rice',
      dailyUnits: 1.0,
      memberIds: ['CIT-00000001'],
    );
    expect(await app.provisionAccount(family), contains('wrong QR type'));
    app.dispose();
  });

  test('officers promote from existing users only, and link persists', () async {
    final app = makeState();
    await app.init();

    // No such user: enrolment must refuse: officers never appear from
    // thin air.
    expect(await app.promoteToOfficer('GHOST'), contains('no user GHOST'));

    await app.register('COP', 'pass', Role.citizen);
    expect(await app.promoteToOfficer('ADMIN'), isNotNull);
    expect(
      await app.promoteToOfficer('COP', newPassword: 'fresh'),
      isNull,
    );

    final users = await app.accounts();
    final cop = users.singleWhere((u) => u.username == 'COP');
    expect(cop.role, Role.officer);
    expect(cop.officerId, startsWith('OFF-'));

    // Ledger registry records the promotion channel under the same id.
    final officers = await app.ledger.officers();
    expect(officers, hasLength(1));
    expect(officers.first.officerId, cop.officerId);
    expect(officers.first.registeredBy, 'PROMOTED');

    // Re-login keeps the officer identity bound to the account.
    await app.logout();
    expect(await app.login('COP', 'fresh'), isNull);
    expect(app.role, Role.officer);
    expect(app.officerId, startsWith('OFF-'));
    app.dispose();
  });

  test('issued accounts persist at GENERATE-QR time (HQ directory)', () async {
    final app = makeState();
    await app.init();
    final error = await app.saveIssuedAccount(
      username: 'MIRA',
      passwordHash: 'a' * 64,
      role: Role.citizen,
      aadhaar: '234567890123',
    );
    expect(error, isNull);
    // Same identity re-issued with the same hash: idempotent.
    expect(
      await app.saveIssuedAccount(
        username: 'mira',
        passwordHash: 'a' * 64,
        role: Role.citizen,
      ),
      isNull,
    );
    // Conflicting credentials for an existing name are refused.
    expect(
      await app.saveIssuedAccount(
        username: 'MIRA',
        passwordHash: 'b' * 64,
        role: Role.citizen,
      ),
      contains('different credentials'),
    );
    final users = await app.accounts();
    expect(users.where((u) => u.username == 'MIRA'), hasLength(1));
    app.dispose();
  });

  test('demote strips the officer link but keeps the account', () async {
    final app = makeState();
    await app.init();
    await app.register('SGT', 'pass', Role.citizen);
    expect(await app.promoteToOfficer('SGT'), isNull);
    // The promotion started SGT's session; step out before demoting.
    await app.logout();
    expect(await app.demoteToCitizen('sgt'), isNull);

    final users = await app.accounts();
    final sgt = users.singleWhere((u) => u.username == 'SGT');
    expect(sgt.role, Role.citizen);
    expect(sgt.officerId, isNull);
    // Ledger keeps the enlistment history (append-only).
    final officers = await app.ledger.officers();
    expect(officers, hasLength(1));
    // Demoting a non-officer errors; re-login is citizen.
    expect(app.demoteToCitizen('SGT'), isNotNull);
    app.dispose();
  });

  test('delete removes the account, protects ADMIN and live sessions',
      () async {
    final app = makeState();
    await app.init();
    await app.register('TMP', 'pass', Role.citizen);
    expect(
      await app.deleteAccount('ADMIN'),
      contains('ADMIN cannot be deleted'),
    );
    // Deleting the logged-in session logs out instead of leaving a phantom.
    expect(app.username, 'TMP');
    expect(await app.deleteAccount('tmp'), isNull);
    expect((await app.accounts()).any((u) => u.username == 'TMP'), isFalse);
    expect(app.loggedIn, isFalse);
    // Unknown names error.
    expect(await app.deleteAccount('GONE'), isNotNull);
    app.dispose();
  });

  test('officer registration mints an id and feeds the directory', () async {
    final app = makeState();
    await app.init();
    await app.register('REN', 'pass', Role.officer);

    expect(app.role, Role.officer);
    expect(app.officerId, startsWith('OFF-'));
    final officers = await app.ledger.officers();
    expect(officers, hasLength(1));
    expect(officers.first.registeredBy, 'REGISTER');
    expect(officers.first.officerId, app.officerId);
    app.dispose();
  });

  test('admin session survives restart without an account record', () async {
    final app = makeState();
    await app.init();
    await app.login('ADMIN', '');
    // Simulate a restart: fresh AppState over the same prefs.
    final app2 = makeState();
    await app2.init();
    await app2.restoreSession();
    expect(app2.loggedIn, isTrue);
    expect(app2.role, Role.admin);
    expect(app2.username, 'ADMIN');
    app.dispose();
    app2.dispose();
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

  test('technical details default off and persist per-device', () async {
    final app = makeState();
    await app.init();
    expect(app.showDebugInfo, isFalse);

    await app.setShowDebugInfo(true);
    expect(app.showDebugInfo, isTrue);

    // A fresh AppState loads the persisted flag back.
    final reboot = makeState();
    await reboot.init();
    expect(reboot.showDebugInfo, isTrue);
    reboot.dispose();
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

  test('mesh listens anonymously before login (SOS detection)', () async {
    final app = makeState();
    await app.init();
    expect(app.loggedIn, isFalse);
    expect(
      app.mesh,
      isNotNull,
      reason: 'radio must be up at the login screen to hear beacons',
    );

    // A peer beacon is detected even with no session.
    final peer = MeshPacket(
      type: MeshPacketType.sosBeacon,
      senderId: 0x5555,
      latitude: 19.0,
      longitude: 72.8,
      triage: TriageFlags(severity: 4),
      seq: 77,
    );
    final adapter = app.mesh!.adapter as FakeMeshAdapter;
    await adapter.injectRemote(peer);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(app.mesh!.nodes[0x5555]!.hasSos, isTrue);

    // Anonymous mode must not announce a name; only a session may.
    final identity = adapter.broadcasted
        .where((p) => p.type == MeshPacketType.identityAnnounce)
        .toList();
    expect(identity, isEmpty);
    app.dispose();
  });

  test('session resumes after restart (auto-login)', () async {
    final first = makeState();
    await first.init();
    await first.register('KEEPME', 'pass', Role.officer);
    final firstId = first.citizenId;
    // App "closed" without an explicit logout: the session survives.
    expect(first.loggedIn, isTrue);
    first.dispose();

    // A fresh app state over the same prefs picks the session back up.
    final second = makeState();
    await second.init();
    expect(
      second.loggedIn,
      isFalse,
      reason: 'restoreSession must be explicit, not baked into init',
    );
    await second.restoreSession();
    expect(second.loggedIn, isTrue);
    expect(second.username, 'KEEPME');
    expect(second.role, Role.officer);
    expect(second.citizenId, firstId);

    // An explicit logout clears the session so the next restart lands on the
    // login screen.
    await second.logout();
    second.dispose();
    final third = makeState();
    await third.init();
    await third.restoreSession();
    expect(third.loggedIn, isFalse);
    third.dispose();
  });

  test('SOS advertises immediately and clears on deactivation', () async {
    final app = makeState();
    await app.init();
    await app.register('SOS1', 'pass', Role.citizen);
    final adapter = app.mesh!.adapter as FakeMeshAdapter;

    app.setSosActive(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      adapter.broadcasted.any(
        (p) => p.type == MeshPacketType.sosBeacon && !p.sosCleared,
      ),
      isTrue,
    );

    app.setSosActive(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      adapter.broadcasted.any(
        (p) => p.type == MeshPacketType.sosBeacon && p.sosCleared,
      ),
      isTrue,
    );
    expect(app.sosActive, isFalse);
    app.dispose();
  });

  test('radio governor follows the session and SOS state', () async {
    final app = makeState();
    await app.init();
    final adapter = app.mesh!.adapter as FakeMeshAdapter;

    // Anonymous boot: STANDBY scan duty until a session signs in.
    expect(adapter.radioActive, isFalse);

    await app.register('GOV1', 'pass', Role.citizen);
    expect(adapter.radioActive, isTrue);

    app.setSosActive(true);
    expect(adapter.radioAlert, isTrue);
    app.setSosActive(false);
    expect(adapter.radioAlert, isFalse);

    await app.logout();
    expect(adapter.radioActive, isFalse);
    expect(adapter.radioAlert, isFalse);
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
