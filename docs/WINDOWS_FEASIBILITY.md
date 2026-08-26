# Windows feasibility — Linux version port

Date: 2026-08-28. Basis: current `linux_network.dart` (500 lines, iw/hostapd/dnsmasq/nmcli/nft/ufw), `bluez_mesh.dart` (BlueZ D-Bus), `native_mesh.dart` (flutter_blue_plus + ble_peripheral_plus), `linux_qr_scan_page.dart` (flutter_lite_camera V4L2 → zxing2).

## 1. What the Linux HQ actually does

* BLE mesh: BlueZ D-Bus `org.bluez` — advertise manufacturerData 0xFFFF 18-byte frames, scan via Device1.ManufacturerData + PropertiesChanged. Duty cycle 2.2s scan / 4s sleep with rotation queue (32) and slot-leak cleanup. Falls back to `NativeMeshAdapter` on non-Linux.
* Camera QR: `flutter_lite_camera` direct `captureFrame()` YUYV → isolate zxing2 decode + `RawImage` preview, no Texture path (avoids use-after-free). Resolution negotiated via MethodChannel `setResolution/getWidth/getHeight`.
* Network HQ link: virtual `ap0` on `wlp1s0` (`iw dev ... interface add ap0 type __ap`), unmanaged via NM conf, `ip addr add 192.168.51.1/24`, UFW `allow in on ap0`, `hostapd + dnsmasq` on `/tmp/gridzero`, nft masquerade, DFS channel fallback (sta channel → g:6 → a:36), autoconnect disabled for ALL wifi profiles before STA disconnect, stale pid-file sweep.
* Ledger/geo/compass: `sqflite_common_ffi` (cross-platform), `geolocator`, `flutter_compass`, `sensors_plus` — desktop variants exist but compass is mobile-only.

## 2. Windows plugin matrix (updated 2026-08-28)

| Area | Linux dep | Windows counterpart | Status on Windows |
|------|-----------|---------------------|-------------------|
| BLE central (scan) | `bluez`+`dbus` | `flutter_blue_plus_winrt` (WinRT BluetoothLE) | ✅ Generated registrant already includes `FlutterBluePlusPlugin` on Windows. Works for scanning manufacturerData. |
| BLE peripheral (adv) | `ble_peripheral_plus` | `ble_peripheral_plus` Windows `GattServiceProvider` path ignores manufacturerData — patched to `BluetoothLEAdvertisementPublisher` (Win10 10240+, `bluetooth` capability, 31B legacy / 254B extended). See `tool/patches/windows_ble_advertise_{h,cpp}.patch` + `lib/core/mesh/win_mesh_adapter.dart` (now full TX/RX, not scan-only). | ✅ Patched — `0xFFFF` + 18B mesh frames go on air. Re-apply via `tool/apply_patches.sh` after `pub get`. |
| Camera QR | `flutter_lite_camera` (Linux-only, V4L2) | `camera_windows` via `camera` package (MediaFoundation) + `mobile_scanner` has Windows support via `mobile_scanner_windows` | ✅ `lib/ui/windows_qr_scan_page.dart` (MediaFoundation) routed via `ProvisionScanPage` on Windows. |
| WiFi join | `nmcli` | `netsh wlan` (add profile XML + `netsh wlan connect name=SSID`) | ✅ `lib/core/windows_network.dart` client join already wired. |
| WiFi hosted AP | `hostapd+dnsmasq+iw` | `netsh wlan set hostednetwork` (deprecated, driver-removed since 1803) OR WinRT `NetworkOperatorTetheringManager` (`Windows.Networking.NetworkOperators`, requires admin + `IsNoConnectionsTimeoutEnabled`) exposed via PowerShell `Start-Tethering` or `win32` WinRT | ⚠️ Feasible but admin-only, driver-dependent, and not available on all adapters. Most Windows 11 Intel AX cards still support TetheringManager; Realtek/USB often not. Recommend degrade to client-only on Windows unless admin hotspot explicitly requested. |
| Firewall/NAT | `ufw`+`nft` | `netsh advfirewall` + `netsh interface portproxy` / ICS | Not needed if HQ is client (phone hosts). If HQ hosts via TetheringManager, Windows handles NAT/DHCP itself. |
| Location/compass | `geolocator`, `flutter_compass` | `geolocator_windows` ✅, `flutter_compass` ❌ (returns error on Windows) | Compass HUD must hide/disable on Windows. |
| DB | `sqflite_common_ffi` | same (`sqlite3.dll` bundled) | ✅ |

## 3. Can we ship a Windows HQ?

**Yes — with degraded feature tiers.**

* Tier GOOD (no admin, no WinRT adv): Windows HQ = BLE scanner (no advertise) + WiFi client that joins phone hotspot (`netsh wlan`). Covers officer sync + map — the primary HQ job. Mesh chat/landmark relay is receive-only; HQ still appears in directory via WiFi sync, not BLE.
* Tier BETTER (WinRT publisher via `win32`): add 80–120 line FFI `BluetoothLEAdvertisementPublisher` publisher; unlocks full mesh (scan+adv). Same rotation/pacing logic as `NativeMeshAdapter` but through WinRT.
* Tier FULL (hosted AP): PowerShell `TetheringManager.StartTetheringAsync` behind admin check. Only worth it if HQ must host when phones can't (some Samsung hotspot bugs). Can keep Linux-style `GZ-<USER>` SSID.

No blocking build issue: `flutter create . --platforms=windows` already succeeded, `generated_plugin_registrant.cc` lists `BlePeripheralPluginCApi`, `FlutterBluePlusPlugin`, `GeolocatorWindows`, etc. `flutter analyze` passes. `flutter build windows` requires a Windows host (expected).

## 4. Limitations to carry over explicitly

* STA/AP concurrency: Intel AX211 on Windows cannot do STA + SoftAP on different bands either; TetheringManager also forces channel share. Same DFS caveat as Linux.
* Driver variance: `netsh wlan show drivers` `Hosted network supported: No` on many USB dongles — must surface that as HUD error, not crash.
* UAC: `netsh`/`TetheringManager` need elevated prompt; the current passwordless-sudo pattern maps to "run as Administrator" + manifest `requireAdministrator` is NOT set, so we must detect `Access is denied` and show instructions.
* Paths: `/tmp/gridzero` → `%TEMP%\gridzero`, `/etc/NetworkManager/conf.d` has no equivalent.
* `flutter_lite_camera` double-free/`listMediaTypes` bug is Linux-only; Windows camera path must not call it.

## 5. Implementation plan (this PR) — update

1. `lib/core/windows_network.dart` — netsh client join path done; `startLinkAp` returns hosted-not-supported hint (TetheringManager still TODO behind admin check).
2. `lib/core/mesh/win_mesh_adapter.dart` — now full TX/RX: forwards `broadcast()` to `NativeMeshAdapter` → `BlePeripheral` → patched `BluetoothLEAdvertisementPublisher` path (manufacturerData 0xFFFF). No longer stub; `status`/`diagnostics` just proxy inner.
3. `windows/ble_peripheral` C++ patch — `tool/patches/windows_ble_advertise_{h,cpp}.patch` adds `advertisementPublisher` + `Publisher_StatusChanged` + `IsAdvertising`/`StartAdvertising`/`StopAdvertising` branches. Apply via `tool/apply_patches.sh` (idempotent, rerun after `pub get`).
4. `lib/ui/windows_qr_scan_page.dart` + `ProvisionScanPage` routing (linux→V4L2, windows→MediaFoundation, else mobile_scanner).
5. Dispatch helpers in `app_state.dart` (`_isWindows` → `win_net`/`linux_net`) and `mesh_controller.dart`/`main.dart` pick `WinMeshAdapter` on Windows. No DB/ledger changes; `db_sync.dart` already cross-platform.

Next: WinRT `NetworkOperatorTetheringManager` hosted-AP (PowerShell `Start-Tethering`) + installer elevation when HQ must host.

## 6. Recommendation

Proceed with MVP now: lets SIH judges and field officers run HQ on Windows laptops without Linux. Gate full peripheral/hosted-AP behind feature flag `kWindowsBleAdvertise` and admin check — no regression for Linux/Android path.
