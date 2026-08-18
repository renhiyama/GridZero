import 'dart:convert';

import 'package:aapadsetu/core/app_state.dart';
import 'package:aapadsetu/core/ledger/ledger_store.dart';
import 'package:aapadsetu/core/master_key.dart';
import 'package:aapadsetu/core/mesh/mesh_adapter.dart';
import 'package:aapadsetu/core/mesh/simulated_mesh.dart';
import 'package:flutter_test/flutter_test.dart';

AppState makeState() {
  AppState.nativeAdapterFactory = (nodeId) =>
      SimulatedMeshAdapter() as MeshAdapter;
  return AppState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    await officer.enlistOfficer(kSampleMasterKeyPayload);

    final citizen = makeState();
    await citizen.init();
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
    await officer.enlistOfficer(kSampleMasterKeyPayload);

    final citizen = makeState();
    await citizen.init();
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

  test('switch role and simulator toggle survive', () async {
    final app = makeState();
    await app.init();
    app.switchRole(Role.citizen);
    expect(app.role, Role.citizen);

    await app.setUseSimulator(true);
    expect(app.useSimulator, isTrue);
    app.dispose();
  });
}
