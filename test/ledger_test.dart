import 'dart:typed_data';

import 'package:gridzero/core/ledger/ledger_store.dart';
import 'package:gridzero/core/ledger/memory_ledger.dart';
import 'package:gridzero/core/ledger/sqlite_ledger.dart';
import 'package:gridzero/core/mesh_packet.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

LedgerRecord makeRecord(int i, {String prev = ''}) => LedgerRecord(
  recordId: 'R-$i',
  citizenId: 'CIT-$i',
  rationCode: 'Rice',
  claimedAt: DateTime.utc(2026, 8, 18).millisecondsSinceEpoch ~/ 1000 + i,
  officerId: 'OFF-1',
  prevHash: prev,
  currentHash: '',
);

void runSuite(Future<LedgerStore> Function() factory, String name) {
  group('ledger ($name)', () {
    test('appends form a verifiable hash chain', () async {
      final store = await factory();
      final prev0 = await store.lastHash();
      expect(prev0, genesisHash);

      final r1 = makeRecord(1, prev: prev0);
      r1.currentHash = r1.computeCurrentHash();
      expect((await store.append(r1)).ok, isTrue);

      final r2 = makeRecord(2, prev: r1.currentHash);
      r2.currentHash = r2.computeCurrentHash();
      expect((await store.append(r2)).ok, isTrue);

      expect(await store.lastHash(), r2.currentHash);
      expect(await store.recordsCount(), 2);
      await store.close();
    });

    test('rejects chain mismatch', () async {
      final store = await factory();
      final r1 = makeRecord(1, prev: genesisHash);
      r1.currentHash = r1.computeCurrentHash();
      await store.append(r1);

      final broken = makeRecord(2, prev: 'f' * 64);
      broken.currentHash = broken.computeCurrentHash();
      final result = await store.append(broken);
      expect(result.status, ClaimStatus.chainMismatch);
      expect(result.ok, isFalse);
      await store.close();
    });

    test('rejects duplicate claim within 24h window', () async {
      final store = await factory();
      final base = DateTime.utc(2026, 8, 18).millisecondsSinceEpoch ~/ 1000;
      final r1 = LedgerRecord(
        recordId: 'R-A',
        citizenId: 'CIT-DUP',
        rationCode: 'Water',
        claimedAt: base,
        officerId: 'OFF-1',
        prevHash: genesisHash,
        currentHash: '',
      );
      r1.currentHash = r1.computeCurrentHash();
      expect((await store.append(r1)).ok, isTrue);

      final r2 = LedgerRecord(
        recordId: 'R-B',
        citizenId: 'CIT-DUP',
        rationCode: 'Water',
        claimedAt: base + 3600,
        officerId: 'OFF-1',
        prevHash: r1.currentHash,
        currentHash: '',
      );
      r2.currentHash = r2.computeCurrentHash();
      final result = await store.append(r2);
      expect(result.status, ClaimStatus.duplicate);
      expect(result.ok, isFalse);
      await store.close();
    });

    test('allows next-day claim for same citizen', () async {
      final store = await factory();
      final base = DateTime.utc(2026, 8, 18).millisecondsSinceEpoch ~/ 1000;
      final r1 = LedgerRecord(
        recordId: 'R-A',
        citizenId: 'CIT-DAY',
        rationCode: 'Rice',
        claimedAt: base,
        officerId: 'OFF-1',
        prevHash: genesisHash,
        currentHash: '',
      );
      r1.currentHash = r1.computeCurrentHash();
      await store.append(r1);

      final r2 = LedgerRecord(
        recordId: 'R-B',
        citizenId: 'CIT-DAY',
        rationCode: 'Rice',
        claimedAt: base + 86400,
        officerId: 'OFF-1',
        prevHash: r1.currentHash,
        currentHash: '',
      );
      r2.currentHash = r2.computeCurrentHash();
      expect((await store.append(r2)).ok, isTrue);
      await store.close();
    });

    test('officer enrolment directory round-trips', () async {
      final store = await factory();
      await store.upsertOfficer(
        OfficerRecord(
          officerId: 'OFF-0A3F0FAB',
          publicKey: 'base64pubkey',
          enlistedAt: 1787082581,
          registeredBy: 'OFF-MASTERKEY',
        ),
      );
      await store.upsertOfficer(
        OfficerRecord(
          officerId: 'OFF-00BEEF',
          publicKey: 'base64pubkey2',
          enlistedAt: 1787082582,
          registeredBy: 'SELF-APPLY',
        ),
      );
      final officers = await store.officers();
      expect(officers, hasLength(2));
      expect(officers.first.officerId, 'OFF-00BEEF'); // newest first
      expect(officers.first.publicKey, 'base64pubkey2');
      expect(officers.last.registeredBy, 'OFF-MASTERKEY');

      // Upserting the same id replaces, not duplicates.
      await store.upsertOfficer(
        OfficerRecord(
          officerId: 'OFF-00BEEF',
          publicKey: 'rotated',
          enlistedAt: 1787082583,
          registeredBy: 'SELF-APPLY',
        ),
      );
      expect(await store.officers(), hasLength(2));
      await store.close();
    });

    test('export/import snapshot round-trips a full DB clone', () async {
      final store = await factory();
      final prev0 = await store.lastHash();
      final r1 = makeRecord(1, prev: prev0);
      r1.currentHash = r1.computeCurrentHash();
      await store.append(r1);

      await store.upsertFamilyCard(
        FamilyCard(
          familyId: 'RCB-SNAP-001',
          rationCode: 'Rice',
          dailyUnits: 4.0,
          memberCitizenIds: const ['CIT-00000001', 'CIT-00000002'],
        ),
      );
      await store.upsertRevocation(
        RevocationEntry(
          citizenId: 'CIT-00000001',
          reasonCode: kRevokeStolen,
          issuedAt: 1787082583,
          sourceNode: 7,
        ),
      );
      await store.upsertOfficer(
        OfficerRecord(
          officerId: 'OFF-SNAP',
          publicKey: 'b64pub',
          enlistedAt: 1787082583,
          registeredBy: 'REGISTER',
        ),
      );
      await store.saveFaceEmbedding(
        'CIT-00000001',
        Float32List.fromList([0.1, -0.2, 0.3]),
      );

      final json = await store.exportSnapshot();
      expect(json, contains('"v":1'));

      // Import into a fresh store: reference rows + records land intact.
      final clone = await factory();
      final error = await clone.importSnapshot(json);
      expect(error, isNull);
      expect(await clone.syncRecordsCount(), 1);
      expect((await clone.familyCard('RCB-SNAP-001'))!.dailyUnits, 4.0);
      expect(await clone.revocations(), hasLength(1));
      expect(await clone.officers(), hasLength(1));
      final emb = await clone.faceEmbedding('CIT-00000001');
      expect(emb, isNotNull);
      expect(emb![0], closeTo(0.1, 1e-6));
      expect(emb[2], closeTo(0.3, 1e-6));

      // Importing again must not duplicate.
      expect(await clone.importSnapshot(json), isNull);
      expect(await clone.syncRecordsCount(), 1);
      await clone.close();
      await store.close();
    });

    test('import rejects malformed snapshots', () async {
      final store = await factory();
      expect(await store.importSnapshot('not json'), isNotNull);
      expect(await store.importSnapshot('{"v":1}'), isNull);
      expect(await store.importSnapshot('{"v":99}'), isNotNull);
      await store.close();
    });

    test('officer key round-trips (List<int> accepted by store)', () async {
      final store = await factory();
      final pub = List<int>.generate(65, (i) => i * 3);
      final priv = List<int>.generate(32, (i) => i * 7);
      await store.saveOfficerKey('OFF-KEY-1', pub, priv);
      final got = await store.officerKey('OFF-KEY-1');
      expect(got, isNotNull);
      expect(got!.$1, pub);
      expect(got.$2, priv);
      await store.close();
    });
  });
}

void main() {
  runSuite(() async => MemoryLedgerStore(), 'memory');

  setUpAll(sqfliteFfiInit);

  runSuite(
    () => SqliteLedgerStore.open(databaseFactoryFfi, inMemoryDatabasePath),
    'sqlite-ffi',
  );
}
