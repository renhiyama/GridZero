/// Real BLE transport.
///
/// Scanning (Central) uses flutter_blue_plus; advertising (Peripheral) uses
/// ble_peripheral_plus with the 18-byte frame placed in manufacturer data.
/// Scanning follows a low-power duty cycle: 2.2s scan / ~3.8s sleep.
///
/// Advertising success/failure is reported asynchronously by the platform
/// callback, NOT by the startAdvertising future (the plugin posts to its own
/// thread). This adapter subscribes to that callback so a silent adv failure
/// is surfaced in the HUD instead of masquerading as healthy.
library;

import 'dart:async';
import 'dart:math';

import 'package:ble_peripheral_plus/ble_peripheral_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../mesh_packet.dart';
import 'mesh_adapter.dart';

/// Custom company identifier for GridZero manufacturer-data frames.
const int kMeshCompanyId = 0xffff;

/// How long each scan window runs before the radio sleeps again.
const Duration _scanWindow = Duration(milliseconds: 3000);

// Radio governor: deterministic duty-cycle tiers. Scanning is the dominant
// battery cost (RX ≈ TX), so the sleep between windows is the lever we trade.
// Every tier is a fixed rule, not a learned model:
//   ALERT    (our SOS active, or a peer SOS within its lease) -> continuous
//   BURST    (new peer discovered / alarm just heard)         -> ~continuous,
//            time-boxed to [_burstLease] so a discovery handshake finishes
//            in ~1s instead of waiting out a sleep gap
//   NOMINAL  (signed-in session)                              -> 3s/9s (25%)
//   STANDBY  (anonymous, no session)                          -> 3s/27s (10%)
/// How long a discovery burst forces near-continuous scanning.
const Duration _burstLease = Duration(seconds: 12);

/// A heard SOS keeps the peer in ALERT for this long; the source re-beacons
/// every 10s so the lease only bridges the gap between beacons, never lasts.
const Duration _peerSosLease = Duration(seconds: 90);

/// Scan sleep in NOMINAL (signed-in) mode.
const Duration _nominalSleep = Duration(seconds: 9);

/// Scan sleep in STANDBY (anonymous) mode.
const Duration _standbySleep = Duration(seconds: 27);

/// Scan sleep during a discovery burst: short, not zero, so the radio still
/// breathes between windows while the exchange completes.
const Duration _burstSleep = Duration(milliseconds: 400);

/// Deterministic governor decision, pure and testable. Returns how long the
/// radio sleeps between scan windows for the current state.
Duration radioGovernorSleep({
  required bool alert,
  required int peerSosUntil,
  required int burstUntil,
  required bool active,
  required int now,
}) {
  if (alert || now < peerSosUntil) return Duration.zero;
  if (now < burstUntil) return _burstSleep;
  return active ? _nominalSleep : _standbySleep;
}

class NativeMeshAdapter implements MeshAdapter {
  NativeMeshAdapter({required this.advertisingPayload});

  /// Latest 18-byte frame to advertise (rotated by the controller).
  Uint8List advertisingPayload;

  bool _radioAlert = false;
  bool _radioActive = true;
  int _peerSosUntil = 0;
  int _burstUntil = 0;

  final _rx = StreamController<MeshRxPacket>.broadcast();
  Timer? _dutyCycleTimer;
  Timer? _scanClearTimer;
  Timer? _advRetryTimer;
  bool _advertising = false;
  bool _scanning = false;
  String? _advertisingError;
  String? _scanError;
  String _permStatus = 'unknown';

  /// Peers seen in the last few minutes (id -> last seen epoch), pruned each
  /// scan cycle so the HUD count is live instead of a lifetime accumulator.
  final Map<int, int> _peers = {};
  final _rand = Random();
  int _advRetries = 0;
  int _scanFailures = 0;
  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  String get name => 'BLE';

  @override
  String get status {
    final parts = <String>[_permStatus, _scanning ? 'SCANNING' : 'SCAN IDLE'];
    parts.add(
      _advertising
          ? 'ADV'
          : (_advertisingError != null
                ? 'ADV FAIL ($_advertisingError)'
                : 'ADV OFF'),
    );
    if (_scanError != null) parts.add('SCAN ERR ($_scanError)');
    if (_peers.isNotEmpty) parts.add('${_peers.length} peer(s)');
    return parts.join(' · ');
  }

  @override
  Stream<MeshRxPacket> get onPacket => _rx.stream;

  @override
  Future<String> ensurePermissions() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final scan = await Permission.bluetoothScan.request();
        final advert = await Permission.bluetoothAdvertise.request();
        final connect = await Permission.bluetoothConnect.request();
        final location = await Permission.locationWhenInUse.request();
        final denied = [
          if (!scan.isGranted) 'SCAN',
          if (!advert.isGranted) 'ADVERT',
          if (!connect.isGranted) 'CONNECT',
          if (!location.isGranted) 'LOCATION',
        ];
        _permStatus = denied.isEmpty
            ? 'permissions granted'
            : 'missing: ${denied.join(', ')}';
      } else {
        _permStatus = 'no runtime perms (bluez/desktop)';
      }
    } catch (e) {
      _permStatus = 'perm error: $e';
    }
    return _permStatus;
  }

  @override
  Future<void> start() async {
    await ensurePermissions();
    // The plugin logs every startScan/stopScan/onMethodCall at debug level;
    // our duty cycle and adv rotation would flood logcat on every ~6s cycle.
    // Warnings/errors still pass through.
    await FlutterBluePlus.setLogLevel(LogLevel.warning);
    BlePeripheral.setAdvertisingStatusUpdateCallback(_onAdvertisingStatus);
    await _startScanning();
    await _startAdvertising();
    _scheduleScanCycle();
  }

  /// Self-rescheduling cycle with jitter: two peers running near-equal duty
  /// cycles otherwise drift into phase-lock where they both scan or both
  /// sleep at once and never hear each other.
  void _scheduleScanCycle() {
    _prunePeers();
    _dutyCycleTimer?.cancel();
    _dutyCycleTimer = Timer(
      _scanSleep(DateTime.now().millisecondsSinceEpoch) +
          Duration(milliseconds: _rand.nextInt(900)),
      _runScanWindow,
    );
  }

  /// Deterministic sleep between scan windows for the current radio state.
  Duration _scanSleep(int now) => radioGovernorSleep(
    alert: _radioAlert,
    peerSosUntil: _peerSosUntil,
    burstUntil: _burstUntil,
    active: _radioActive,
    now: now,
  );

  void _prunePeers() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - 180000;
    _peers.removeWhere((_, lastSeen) => lastSeen < cutoff);
  }

  Future<void> _runScanWindow() async {
    try {
      _scanError = null;
      _scanning = true;
      _scanClearTimer?.cancel();
      final sleep = _scanSleep(DateTime.now().millisecondsSinceEpoch);
      if (sleep <= _burstSleep) {
        // ALERT/BURST tier: keep ONE scan open instead of restarting a
        // 3.4s window. Android throttles rapid startScan/stopScan cycles
        // (status=6 "scanning too frequently"), and a burst must not give
        // the radio a gap to sleep through. Re-check the governor on a
        // short tick so the radio drops out as soon as the burst lapses.
        if (!FlutterBluePlus.isScanningNow) {
          await FlutterBluePlus.startScan(
            continuousUpdates: true,
            continuousDivisor: 1,
          );
        }
        _dutyCycleTimer = Timer(const Duration(seconds: 2), _runScanWindow);
      } else {
        // Duty-cycle tier: bounded window, then sleep so the radio breathes.
        _scanClearTimer = Timer(_scanWindow, () => _scanning = false);
        if (FlutterBluePlus.isScanningNow) {
          await FlutterBluePlus.stopScan();
        }
        await FlutterBluePlus.startScan(
          continuousUpdates: true,
          continuousDivisor: 1,
          timeout: _scanWindow,
        );
        _scheduleScanCycle();
      }
      _scanFailures = 0;
    } catch (e) {
      _scanning = false;
      _scanError = '$e';
      debugPrint('GridZero: scan window failed: $_scanError');
      // Back off instead of retrying instantly: a throttled startScan that
      // throws would otherwise reschedule immediately and keep failing.
      _scanFailures++;
      _dutyCycleTimer?.cancel();
      _dutyCycleTimer = Timer(
        Duration(seconds: _scanFailures * 2),
        _runScanWindow,
      );
    }
  }

  Future<void> _startScanning() async {
    try {
      await FlutterBluePlus.turnOn(timeout: 5);
      _scanSub ??= FlutterBluePlus.scanResults.listen(_onScanResults);
      await _runScanWindow();
    } catch (e) {
      _scanError = '$e';
      debugPrint('GridZero: BLE scan unavailable: $_scanError');
    }
  }

  void _onScanResults(List<ScanResult> results) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final result in results) {
      final mfg = result.advertisementData.manufacturerData;
      final payload = mfg[kMeshCompanyId];
      if (payload == null) continue;
      try {
        final packet = MeshPacket.decode(Uint8List.fromList(payload));
        // Governor triggers: a fresh sender earns a discovery burst so the
        // coords/identity exchange finishes in ~1s, not after a sleep gap.
        // A peer's SOS (not cleared) keeps us scanning continuously until its
        // lease lapses; a cleared alarm drops us straight back out.
        if (!_peers.containsKey(packet.senderId)) {
          _burstUntil = now + _burstLease.inMilliseconds;
        }
        if (packet.type == MeshPacketType.sosBeacon) {
          _peerSosUntil = packet.sosCleared
              ? 0
              : now + _peerSosLease.inMilliseconds;
        }
        _peers[packet.senderId] = now;
        _rx.add(MeshRxPacket(packet: packet, rssi: result.rssi));
      } on FormatException {
        // foreign or corrupt frame; ignore
      }
    }
  }

  /// Platform reports advertising success/failure asynchronously. This is the
  /// ONLY reliable signal: the startAdvertising future returns immediately
  /// because the Android plugin posts the call to its own handler thread.
  void _onAdvertisingStatus(bool advertising, String? error) {
    // "Already started" is benign: startAdvertising was called while the
    // radio was already broadcasting (a rotation race). Treat it as success,
    // or the error retry loop wedges the HUD and stalls payload rotation.
    if ((error ?? '').toLowerCase().contains('already started')) {
      _advertising = true;
      _advertisingError = null;
      _advRetries = 0;
      return;
    }
    _advertising = advertising;
    if (error != null) {
      _advertisingError = error;
      debugPrint('GridZero: BLE advertising failed: $error');
      _scheduleAdvRetry();
    } else {
      _advertisingError = null;
      _advRetries = 0;
    }
  }

  /// Serializes advertisement operations (rotation + retries) so a retry
  /// timer and a broadcast() can never interleave and double-start the
  /// peripheral. Calls are chained; failures don't break the chain.
  Future<void> _advQueue = Future.value();

  Future<T> _advSerial<T>(Future<T> Function() action) {
    final run = _advQueue.then((_) => action());
    _advQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Latest persistent frame (announce with coords, or SOS). After the
  /// rotation drains a heartbeat burst (identity / ledger / relay), the slot
  /// returns here so peers always have a good chance of catching our live
  /// position instead of a one-shot frame.
  Uint8List? _persistentPayload;

  /// Frames waiting to take the advertisement slot. broadcast() only enqueues;
  /// the rotation timer swaps the radio onto each frame for a short dwell so a
  /// burst (announce + identity + ledger on one heartbeat tick) doesn't leave
  /// only the last frame on the air: without this, a peer's scan window can
  /// catch the identity frame while the coords-carrying announce is rotated
  /// away within milliseconds.
  final List<Uint8List> _rotateQueue = [];
  Timer? _rotateTimer;

  /// Diagnostics: frames handed to the queue vs successfully swapped onto
  /// the radio vs failed swaps. A gap between enqueued and swapped = frames
  /// lost inside this adapter (never transmitted).
  int enqueuedFrames = 0;
  int swappedFrames = 0;
  int failedSwaps = 0;

  void _scheduleRotation() {
    if (_rotateTimer != null) return;
    void tick() async {
      _rotateTimer = null;
      if (_rotateQueue.isEmpty) {
        // Burst drained: hand the slot back to the persistent frame so the
        // long idle gap between heartbeats advertises coords, not the last
        // identity/ledger frame that happened to be broadcast last.
        final sticky = _persistentPayload;
        if (sticky != null && !listEquals(advertisingPayload, sticky)) {
          await _swapPayload(sticky);
        }
        return;
      }
      // Peek-then-commit: only drop the frame once it actually went on the
      // air. A failed swap (radio busy mid-scan-window, transient BLE error)
      // previously ATE the chunk silently: multi-frame payloads like hotspot
      // offers then never reassembled on the far end.
      final ok = await _swapPayload(_rotateQueue.first);
      if (ok) {
        _rotateQueue.removeAt(0);
        swappedFrames++;
      } else {
        failedSwaps++;
      }
      // More queued: rotate FAST so a burst (e.g. an 11-chunk link offer)
      // drains in seconds instead of 2s-per-frame minutes, but leave a long
      // tail dwell once drained so the sticky frame gets airtime again.
      _rotateTimer = Timer(
        Duration(
          milliseconds: _rotateQueue.isEmpty
              ? 2000
              : (ok ? 400 : 1000),
        ),
        tick,
      );
    }

    _rotateTimer = Timer(Duration.zero, tick);
  }

  /// Stops the radio and restarts it advertising [payload]. Returns false
  /// when the swap did not happen (radio down or platform error) so callers
  /// can keep their frame queued instead of losing it.
  Future<bool> _swapPayload(Uint8List payload) {
    return _advSerial(() async {
      if (!_advertising) return false; // radio down; the retry picks up the slot
      try {
        await BlePeripheral.stopAdvertising();
        advertisingPayload = payload;
        await BlePeripheral.startAdvertising(
          services: const [],
          manufacturerData: ManufacturerData(
            manufacturerId: kMeshCompanyId,
            data: payload,
          ),
          addManufacturerDataInScanResponse: false,
          requireBonding: false,
        );
        return true;
      } catch (e) {
        _advertising = false;
        _advertisingError = '$e';
        debugPrint('GridZero: BLE advertising rotation failed: \$e');
        _scheduleAdvRetry();
        return false;
      }
    });
  }

  void _scheduleAdvRetry() {
    if (_advRetries >= 3) return;
    _advRetries++;
    _advRetryTimer?.cancel();
    _advRetryTimer = Timer(const Duration(seconds: 5), _startAdvertising);
  }

  Future<void> _startAdvertising() => _advSerial(() async {
    try {
      // initialize() must run first: isSupported() reads the BluetoothManager
      // the plugin only sets up during initialize(), so checking it before
      // would always report "unsupported".
      await BlePeripheral.initialize();
      if (await BlePeripheral.isAdvertising() ?? false) {
        // A broadcast() rotation won the race and the radio is already on:
        // reconcile state instead of double-starting.
        _advertising = true;
        _advertisingError = null;
        _advRetries = 0;
        return;
      }
      await BlePeripheral.startAdvertising(
        services: const [],
        localName: null,
        timeout: 0,
        manufacturerData: ManufacturerData(
          manufacturerId: kMeshCompanyId,
          data: advertisingPayload,
        ),
        addManufacturerDataInScanResponse: false,
        requireBonding: false,
      );
    } catch (e) {
      _advertising = false;
      _advertisingError = '$e';
      debugPrint('GridZero: BLE advertising unavailable: $e');
      _scheduleAdvRetry();
    }
  });

  @override
  Future<void> broadcast(MeshPacket packet, {bool persistent = false}) async {
    final payload = packet.encode();
    if (persistent) {
      // New sticky frame: swap it in immediately (coords changed or an SOS
      // fired) and remember it as the long-dwell slot.
      _persistentPayload = payload;
      if (listEquals(advertisingPayload, payload)) return;
      await _swapPayload(payload);
    }
    // Android cannot mutate manufacturer data in place: stop/start is the only
    // way to push a new frame, so skip the churn when nothing changed.
    if (listEquals(advertisingPayload, payload)) return;
    if (_rotateQueue.isNotEmpty && listEquals(_rotateQueue.last, payload)) {
      return;
    }
    enqueuedFrames++;
    _rotateQueue.add(payload);
    // Cap must exceed the largest multi-frame payload (a hotspot offer runs
    // ~10 chunks); dropping the HEAD silently breaks reassembly on the far
    // end, which is worse than delaying a heartbeat frame.
    if (_rotateQueue.length > 32) _rotateQueue.removeAt(0);
    _scheduleRotation();
  }

  @override
  Future<void> injectRemote(MeshPacket packet) async {
    throw UnsupportedError('injectRemote is for test harnesses only');
  }

  @override
  Future<void> setRadioAlert(bool active) async {
    if (_radioAlert == active) return;
    _radioAlert = active;
    if (!active) _burstUntil = 0;
    _scheduleScanCycle();
  }

  @override
  void boostScan() {
    // Extend the discovery burst so multi-frame payloads (chat, landmarks)
    // are heard even by devices whose duty cycle would otherwise skip them.
    _burstUntil = DateTime.now().millisecondsSinceEpoch +
        const Duration(seconds: 15).inMilliseconds;
    _scheduleScanCycle();
  }

    @override
  Map<String, String> get diagnostics {
    final now = DateTime.now().millisecondsSinceEpoch;
    final peerSosLeft = _peerSosUntil > now ? _peerSosUntil - now : 0;
    final burstLeft = _burstUntil > now ? _burstUntil - now : 0;
    final sleep = _scanSleep(now);
    final tier = _radioAlert || peerSosLeft > 0
        ? 'ALERT'
        : burstLeft > 0
        ? 'BURST'
        : _radioActive
        ? 'NOMINAL'
        : 'STANDBY';
    return {
      'tier': tier,
      'scanSleep': '${sleep.inMilliseconds}ms',
      'advQueue': '${_rotateQueue.length}',
      'advError': _advertisingError ?? '',
      'enqueued': '$enqueuedFrames',
      'swapped': '$swappedFrames',
      'failed': '$failedSwaps',
      'peerSosLease': peerSosLeft > 0 ? '${peerSosLeft ~/ 1000}s' : '-',
      'burstLease': burstLeft > 0 ? '${burstLeft ~/ 1000}s' : '-',
      'peers': '${_peers.length}',
      'advertising': _advertising ? 'ON' : 'OFF',
    };
  }

  @override
  Future<void> setRadioActive(bool active) async {
    if (_radioActive == active) return;
    _radioActive = active;
    _scheduleScanCycle();
  }

  @override
  Future<void> stop() async {
    _dutyCycleTimer?.cancel();
    _scanClearTimer?.cancel();
    _advRetryTimer?.cancel();
    _rotateTimer?.cancel();
    _rotateTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      if (_advertising) {
        await BlePeripheral.stopAdvertising();
      }
    } catch (_) {}
    await _rx.close();
  }
}
