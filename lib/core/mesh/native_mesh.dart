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

/// Custom company identifier for AapadSetu manufacturer-data frames.
const int kMeshCompanyId = 0xffff;

/// How long each scan window runs before the radio sleeps again.
const Duration _scanWindow = Duration(milliseconds: 3000);

/// Duty-cycle period (scan window + radio sleep).
const Duration _dutyCycle = Duration(seconds: 6);

class NativeMeshAdapter implements MeshAdapter {
  NativeMeshAdapter({required this.advertisingPayload});

  /// Latest 18-byte frame to advertise (rotated by the controller).
  Uint8List advertisingPayload;

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
      _dutyCycle + Duration(milliseconds: _rand.nextInt(900)),
      _runScanWindow,
    );
  }

  void _prunePeers() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - 180000;
    _peers.removeWhere((_, lastSeen) => lastSeen < cutoff);
  }

  Future<void> _runScanWindow() async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      _scanError = null;
      _scanning = true;
      _scanClearTimer?.cancel();
      _scanClearTimer = Timer(_scanWindow, () => _scanning = false);
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        continuousDivisor: 1,
        timeout: _scanWindow,
      );
      _scheduleScanCycle();
    } catch (e) {
      _scanning = false;
      _scanError = '$e';
      debugPrint('AapadSetu: scan window failed: $_scanError');
      _scheduleScanCycle();
    }
  }

  Future<void> _startScanning() async {
    try {
      await FlutterBluePlus.turnOn(timeout: 5);
      _scanSub ??= FlutterBluePlus.scanResults.listen(_onScanResults);
      await _runScanWindow();
    } catch (e) {
      _scanError = '$e';
      debugPrint('AapadSetu: BLE scan unavailable: $_scanError');
    }
  }

  void _onScanResults(List<ScanResult> results) {
    for (final result in results) {
      final mfg = result.advertisementData.manufacturerData;
      final payload = mfg[kMeshCompanyId];
      if (payload == null) continue;
      try {
        final packet = MeshPacket.decode(Uint8List.fromList(payload));
        _peers[packet.senderId] = DateTime.now().millisecondsSinceEpoch;
        _rx.add(MeshRxPacket(packet: packet, rssi: result.rssi));
      } on FormatException {
        // foreign or corrupt frame; ignore
      }
    }
  }

  /// Platform reports advertising success/failure asynchronously. This is the
  /// ONLY reliable signal — the startAdvertising future returns immediately
  /// because the Android plugin posts the call to its own handler thread.
  void _onAdvertisingStatus(bool advertising, String? error) {
    _advertising = advertising;
    if (error != null) {
      _advertisingError = error;
      debugPrint('AapadSetu: BLE advertising failed: $error');
      if (_advRetries < 3) {
        _advRetries++;
        _advRetryTimer?.cancel();
        _advRetryTimer = Timer(const Duration(seconds: 5), _startAdvertising);
      }
    } else {
      _advertisingError = null;
      _advRetries = 0;
    }
  }

  Future<void> _startAdvertising() async {
    BlePeripheral.setAdvertisingStatusUpdateCallback(_onAdvertisingStatus);
    try {
      // initialize() must run first: isSupported() reads the BluetoothManager
      // the plugin only sets up during initialize(), so checking it before
      // would always report "unsupported".
      await BlePeripheral.initialize();
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
      debugPrint('AapadSetu: BLE advertising unavailable: $e');
    }
  }

  @override
  Future<void> broadcast(MeshPacket packet) async {
    final payload = packet.encode();
    final changed = !listEquals(advertisingPayload, payload);
    advertisingPayload = payload;
    // Android cannot mutate manufacturer data in place: stop/start is the only
    // way to push a new frame, so skip the churn when nothing changed.
    if (!_advertising || !changed) return;
    try {
      await BlePeripheral.stopAdvertising();
      await BlePeripheral.startAdvertising(
        services: const [],
        manufacturerData: ManufacturerData(
          manufacturerId: kMeshCompanyId,
          data: advertisingPayload,
        ),
        addManufacturerDataInScanResponse: false,
        requireBonding: false,
      );
    } catch (_) {
      // advertising fell over; scanning path still functions
    }
  }

  @override
  Future<void> injectRemote(MeshPacket packet) async {
    throw UnsupportedError('injectRemote is for test harnesses only');
  }

  @override
  Future<void> stop() async {
    _dutyCycleTimer?.cancel();
    _scanClearTimer?.cancel();
    _advRetryTimer?.cancel();
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
