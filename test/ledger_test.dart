import 'package:aapadsetu/core/ledger/ledger_store.dart';
import 'package:aapadsetu/core/ledger/memory_ledger.dart';
import 'package:aapadsetu/core/ledger/sqlite_ledger.dart';
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
  });
}

void main() {
  runSuite(() async => MemoryLedgerStore(), 'memory');

  setUpAll(sqfliteFfiInit);

  runSuite(
    () => SqliteLedgerStore.open(
        databaseFactoryFfi, inMemoryDatabasePath),
    'sqlite-ffi',
  );
}