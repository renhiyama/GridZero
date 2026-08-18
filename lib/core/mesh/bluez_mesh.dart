import 'dart:async';

import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../mesh_packet.dart';
import 'mesh_adapter.dart';

const int kMeshCompanyId = 0xffff;

/// How long each scan window runs before the radio goes idle (adv-only).
const Duration _scanWindowDuration = Duration(milliseconds: 2200);

/// Idle period between scan windows (advertisement transmits during this).
const Duration _sleepWindowDuration = Duration(seconds: 4);

/// Linux desktop transport: real BLE through BlueZ on the system D-Bus.
///
/// Scanning watches Device1.ManufacturerData on every discovered device;
/// advertising registers a broadcast LE advertisement. BlueZ has no
/// advertisement monitor in this package version, so discovery must read the
/// cached manufacturer data property for each device.
class BluezMeshAdapter implements MeshAdapter {
  BluezMeshAdapter({required this.advertisingPayload});

  Uint8List advertisingPayload;

  final _rx = StreamController<MeshRxPacket>.broadcast();
  BlueZClient? _client;
  BlueZAdapter? _adapter;
  StreamSubscription? _deviceAddedSub;
  StreamSubscription? _adapterAddedSub;
  final Map<String, StreamSubscription<List<String>>> _devicePropSubs = {};
  BlueZAdvertisement? _advert;
  Timer? _dutyCycleTimer;
  bool _scanOn = false;
  bool _advertising = false;
  String? _error;
  final _seenPeers = <int>{};

  @override
  String get name => 'BLUEZ';

  @override
  Stream<MeshRxPacket> get onPacket => _rx.stream;

  @override
  String get status {
    if (_client == null) {
      return 'bluez unavailable${_error != null ? ' ($_error)' : ''}';
    }
    return [
      _scanOn ? 'SCANNING' : 'SCAN IDLE',
      _advertising ? 'ADV' : 'ADV OFF',
      if (_seenPeers.isNotEmpty) '${_seenPeers.length} peer(s)',
    ].join(' · ');
  }

  @override
  Future<String> ensurePermissions() async => 'no runtime perms (system D-Bus)';

  @override
  Future<void> start() async {
    try {
      final client = BlueZClient();
      await client.connect();
      _client = client;
      _adapterAddedSub = client.adapterAdded.listen(_initAdapter);
      _deviceAddedSub = client.deviceAdded.listen(_handleDevice);
      for (final device in client.devices) {
        _handleDevice(device);
      }
      if (client.adapters.isNotEmpty) {
        _initAdapter(client.adapters.first);
      }
    } catch (e) {
      _error = '$e';
      debugPrint('AapadSetu: bluez unavailable: $e');
    }
  }

  Future<void> _initAdapter(BlueZAdapter adapter) async {
    if (_adapter != null) return;
    _adapter = adapter;
    try {
      if (!adapter.powered) {
        await adapter.setPowered(true);
      }
    } catch (e) {
      _error = 'power: $e';
      debugPrint('AapadSetu: bluez power-on failed: $e');
    }
    // Duty cycle: a single radio cannot transmit its own advertisement while
    // scanning full-time on controllers without concurrent adv+scan support.
    // Scan for a window, then go idle so the advertisement actually gets out.
    _scanWindow();
    await _startAdvertising();
  }

  Future<void> _scanWindow() async {
    _dutyCycleTimer?.cancel();
    _scanOn = true;
    try {
      await _adapter!.startDiscovery();
    } catch (e) {
      _error = 'discovery: $e';
      debugPrint('AapadSetu: bluez discovery failed: $e');
    }
    _dutyCycleTimer = Timer(_scanWindowDuration, _sleepWindow);
  }

  Future<void> _sleepWindow() async {
    _scanOn = false;
    try {
      await _adapter!.stopDiscovery();
    } catch (_) {
      // Discovery may already be stopped.
    }
    _dutyCycleTimer = Timer(_sleepWindowDuration, _scanWindow);
  }

  void _handleDevice(BlueZDevice device) {
    _ingest(device);
    if (_devicePropSubs.containsKey(device.address)) return;
    _devicePropSubs[device.address] = device.propertiesChanged.listen(
      (_) => _ingest(device),
    );
  }

  void _ingest(BlueZDevice device) {
    final data = device.manufacturerData[BlueZManufacturerId(kMeshCompanyId)];
    if (data == null || data.isEmpty) return;
    try {
      final packet = MeshPacket.decode(Uint8List.fromList(data));
      if (_seenPeers.add(packet.senderId)) {
        debugPrint(
          'AapadSetu: peer ${packet.senderId} seen via bluez '
          '(rssi ${device.rssi})',
        );
      }
      _rx.add(MeshRxPacket(packet: packet, rssi: device.rssi));
    } on FormatException {
      // Foreign or corrupt frame; ignore.
    }
  }

  Future<void> _startAdvertising() async {
    if (_advertising) return;
    try {
      _advert = await _adapter!.advertisingManager.registerAdvertisement(
        type: BlueZAdvertisementType.broadcast,
        manufacturerData: {
          BlueZManufacturerId(kMeshCompanyId): DBusArray.byte(
            advertisingPayload,
          ),
        },
      );
      _advertising = true;
    } catch (e) {
      _error = 'adv: $e';
      debugPrint('AapadSetu: bluez advertising failed: $e');
    }
  }

  @override
  Future<void> broadcast(MeshPacket packet) async {
    final payload = packet.encode();
    final changed = !listEquals(advertisingPayload, payload);
    advertisingPayload = payload;
    if (!_advertising || !changed) return;
    try {
      final advert = _advert;
      if (advert != null) {
        await _adapter!.advertisingManager.unregisterAdvertisement(advert);
      }
      _advert = null;
      await _startAdvertising();
    } catch (e) {
      debugPrint('AapadSetu: bluez advertise rotation failed: $e');
    }
  }

  @override
  Future<void> injectRemote(MeshPacket packet) async {
    throw UnsupportedError('injectRemote is for test harnesses only');
  }

  @override
  Future<void> stop() async {
    _dutyCycleTimer?.cancel();
    _dutyCycleTimer = null;
    await _deviceAddedSub?.cancel();
    _deviceAddedSub = null;
    await _adapterAddedSub?.cancel();
    _adapterAddedSub = null;
    for (final sub in _devicePropSubs.values) {
      await sub.cancel();
    }
    _devicePropSubs.clear();
    try {
      if (_adapter != null) {
        await _adapter!.stopDiscovery();
      }
    } catch (_) {
      // Adapter may already be gone.
    }
    try {
      if (_advert != null && _adapter != null) {
        await _adapter!.advertisingManager.unregisterAdvertisement(_advert!);
      }
    } catch (_) {
      // Advertisement may already be gone.
    }
    _advert = null;
    _advertising = false;
    _scanOn = false;
    await _client?.close();
    _client = null;
    await _rx.close();
  }
}
