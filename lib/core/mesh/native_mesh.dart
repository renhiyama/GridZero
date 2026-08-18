/// Real BLE transport.
///
/// Scanning (Central) uses flutter_blue_plus; advertising (Peripheral) uses
/// ble_peripheral_plus with the 18-byte frame placed in manufacturer data.
/// Scanning follows the NFR-1 low-power duty cycle: 1.1s scan / 4.9s sleep.
///
/// Linux and web lack peripheral advertising support, so on those platforms
/// the adapter silently degrades to scan-only operation and the app falls
/// back to the simulator for the transmit half.
library;

import 'dart:async';

import 'package:ble_peripheral_plus/ble_peripheral_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../mesh_packet.dart';
import 'mesh_adapter.dart';

/// Custom company identifier for AapadSetu manufacturer-data frames.
const int kMeshCompanyId = 0xffff;

class NativeMeshAdapter implements MeshAdapter {
  NativeMeshAdapter({required this.advertisingPayload});

  /// Latest 18-byte frame to advertise (rotated by the controller).
  Uint8List advertisingPayload;

  final _rx = StreamController<MeshRxPacket>.broadcast();
  Timer? _dutyCycleTimer;
  bool _advertising = false;
  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  String get name => 'BLE';

  @override
  bool get isSimulated => false;

  @override
  Stream<MeshRxPacket> get onPacket => _rx.stream;

  @override
  Future<void> start() async {
    await _startScanning();
    await _startAdvertising();
    _dutyCycleTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      _runScanWindow();
    });
  }

  Future<void> _runScanWindow() async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        continuousDivisor: 1,
        timeout: const Duration(milliseconds: 1100),
      );
    } catch (_) {
      // radio unavailable; duty cycle keeps retrying cheaply
    }
  }

  Future<void> _startScanning() async {
    try {
      await FlutterBluePlus.turnOn(timeout: 5);
      _scanSub ??= FlutterBluePlus.scanResults.listen(_onScanResults);
      await _runScanWindow();
    } catch (e) {
      debugPrint('AapadSetu: BLE scan unavailable: $e');
    }
  }

  void _onScanResults(List<ScanResult> results) {
    for (final result in results) {
      final mfg = result.advertisementData.manufacturerData;
      final payload = mfg[kMeshCompanyId];
      if (payload == null) continue;
      try {
        final packet = MeshPacket.decode(Uint8List.fromList(payload));
        _rx.add(MeshRxPacket(packet: packet, rssi: result.rssi));
      } on FormatException {
        // foreign or corrupt frame; ignore
      }
    }
  }

  Future<void> _startAdvertising() async {
    if (kIsWeb) return;
    try {
      final supported = await BlePeripheral.isSupported();
      if (!supported) return;
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
      _advertising = true;
    } catch (e) {
      _advertising = false;
      debugPrint('AapadSetu: BLE advertising unavailable: $e');
    }
  }

  @override
  Future<void> broadcast(MeshPacket packet) async {
    advertisingPayload = packet.encode();
    if (_advertising) {
      // rotate manufacturer data; most platforms push updates on stop/start
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
  }

  @override
  Future<void> injectRemote(MeshPacket packet) async {
    throw UnsupportedError('injectRemote is only for simulated transport');
  }

  @override
  Future<void> stop() async {    _dutyCycleTimer?.cancel();
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
