/// Windows BLE mesh — scan via flutter_blue_plus_winrt, advertise via
/// patched ble_peripheral_plus (BluetoothLEAdvertisementPublisher).
///
/// The upstream plugin's Windows C++ used only GattServiceProvider and never
/// published manufacturer data, so GridZero's 0xFFFF mesh frames never went
/// on air. This adapter now forwards `broadcast()` to the inner
/// NativeMeshAdapter, whose BlePeripheral calls go through the patched
/// `ble_peripheral_plugin.cpp` (see tool/patches/windows_ble_advertise.patch).
/// Without the patch it degrades to scan-only with a clear HUD hint.
library;
// ignore_for_file: unnecessary_import

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import '../mesh_packet.dart';
import 'mesh_adapter.dart';
import 'native_mesh.dart';

class WinMeshAdapter implements MeshAdapter {
  WinMeshAdapter({required Uint8List advertisingPayload})
      : _inner = NativeMeshAdapter(advertisingPayload: advertisingPayload);

  final NativeMeshAdapter _inner;

  @override
  String get name => 'WIN-BLE';

  @override
  Stream<MeshRxPacket> get onPacket => _inner.onPacket;

  @override
  String get status => _inner.status;

  @override
  Future<String> ensurePermissions() => _inner.ensurePermissions();

  @override
  Future<void> start() async {
    try {
      await _inner.start();
    } catch (e) {
      debugPrint('GridZero: win mesh start: $e');
    }
  }

  @override
  Future<void> broadcast(MeshPacket packet, {bool persistent = false}) =>
      _inner.broadcast(packet, persistent: persistent);

  @override
  Future<void> injectRemote(MeshPacket packet) => _inner.injectRemote(packet);

  @override
  Future<void> setRadioAlert(bool active) => _inner.setRadioAlert(active);

  @override
  Future<void> setRadioActive(bool active) => _inner.setRadioActive(active);

  @override
  void boostScan() => _inner.boostScan();

  @override
  Map<String, String> get diagnostics => _inner.diagnostics;

  @override
  Future<void> stop() => _inner.stop();
}
