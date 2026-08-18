/// Opens the best ledger backend for the current platform.
///
/// Desktop and mobile use SQLite via FFI; if native sqlite is unavailable the
/// app degrades gracefully to memory rather than crashing.
library;

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ledger_store.dart';
import 'memory_ledger.dart';
import 'sqlite_ledger.dart';

Future<LedgerStore> openLedgerStore() async {
  try {
    sqfliteFfiInit();
    final dir = await getApplicationSupportDirectory();
    final store = await SqliteLedgerStore.open(
      databaseFactoryFfi,
      '${dir.path}/gridzero_ledger.db',
    );
    return store;
  } catch (_) {
    return MemoryLedgerStore();
  }
}
