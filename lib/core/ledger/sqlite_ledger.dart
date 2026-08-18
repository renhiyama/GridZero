/// SQLite hash-chain ledger backend (FR-3). Schema mirrors docs/REQ.md 2.2.
library;

import 'package:sqflite_common/sqflite.dart';

import 'ledger_store.dart';

const String kLedgerSchema = '''
CREATE TABLE IF NOT EXISTS ledger_records (
    record_id TEXT PRIMARY KEY,
    citizen_id TEXT NOT NULL,
    ration_code TEXT NOT NULL,
    claimed_at INTEGER NOT NULL,
    officer_id TEXT NOT NULL,
    prev_hash TEXT NOT NULL,
    current_hash TEXT NOT NULL,
    sync_status INTEGER DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_citizen_daily_claim
ON ledger_records (citizen_id, ration_code, (claimed_at / 86400));
CREATE TABLE IF NOT EXISTS known_mesh_nodes (
    node_id INTEGER PRIMARY KEY,
    last_latitude REAL,
    last_longitude REAL,
    triage_severity INTEGER,
    last_seen_epoch INTEGER
);
''';

class SqliteLedgerStore implements LedgerStore {
  SqliteLedgerStore(this._db);

  final Database _db;

  static Future<LedgerStore> open(DatabaseFactory factory, String path) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute(kLedgerSchema),
      ),
    );
    return SqliteLedgerStore(db);
  }

  @override
  Future<void> close() => _db.close();

  @override
  Future<String> lastHash() async {
    final rows = await _db.query(
      'ledger_records',
      columns: ['current_hash'],
      orderBy: 'claimed_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? genesisHash : rows.first['current_hash'] as String;
  }

  @override
  Future<List<LedgerRecord>> allRecords() async {
    final rows = await _db.query('ledger_records', orderBy: 'claimed_at DESC');
    return rows.map(LedgerRecord.fromMap).toList();
  }

  @override
  Future<int> recordsCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM ledger_records');
    return rows.first['c'] as int;
  }

  @override
  Future<ClaimResult> append(LedgerRecord record) async {
    final expectedPrev = await lastHash();
    if (record.prevHash != expectedPrev) {
      return ClaimResult(
        ClaimStatus.chainMismatch,
        message: 'chain broken: record prev_hash != stored last hash',
      );
    }
    if (await _hasDailyDuplicate(record)) {
      return ClaimResult(
        ClaimStatus.duplicate,
        message:
            'citizen ${record.citizenId} already claimed '
            '${record.rationCode} within 24h window',
      );
    }
    try {
      await _db.insert(
        'ledger_records',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return ClaimResult(ClaimStatus.granted, record: record);
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        return ClaimResult(
          ClaimStatus.duplicate,
          message:
              'citizen ${record.citizenId} already claimed '
              '${record.rationCode} within 24h window',
        );
      }
      return ClaimResult(ClaimStatus.error, message: e.toString());
    }
  }

  /// FR-3.4 duplicate guard keyed on the UTC day of the claim.
  Future<bool> _hasDailyDuplicate(LedgerRecord record) async {
    final day = record.claimedAt ~/ 86400;
    final rows = await _db.query(
      'ledger_records',
      where: 'citizen_id = ? AND ration_code = ? AND (claimed_at / 86400) = ?',
      whereArgs: [record.citizenId, record.rationCode, day],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> upsertNode({
    required int nodeId,
    double? latitude,
    double? longitude,
    int? severity,
  }) async {
    await _db.insert('known_mesh_nodes', {
      'node_id': nodeId,
      'last_latitude': latitude,
      'last_longitude': longitude,
      'triage_severity': severity,
      'last_seen_epoch': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<Map<String, Object?>>> knownNodes() =>
      _db.query('known_mesh_nodes', orderBy: 'last_seen_epoch DESC');
}
