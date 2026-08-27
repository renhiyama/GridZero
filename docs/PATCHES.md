# Patched vendor code — reproducible

All patches live under `tool/patches/` and are re-applied by `tool/apply_patches.sh`
after every `flutter pub get` (which wipes `~/.pub-cache`). Each patch is
idempotent; running `bash tool/apply_patches.sh` twice is safe.

## How to reproduce

```bash
flutter pub get
bash tool/apply_patches.sh
flutter analyze        # should be clean
flutter test           # 166/166
# Windows build (on Windows host, or via CI):
flutter build windows --release   # needs patched ble_peripheral_plus C++
```

CI (`.github/workflows/windows.yml`) runs `flutter pub get` → `tool/apply_patches.sh`
before `flutter build windows`.

## Patches

### 1. `flutter_lite_camera 0.1.0` — `SetResolution` EBUSY + `RestartCapture`

- **Pub-cache path:** `~/.pub-cache/hosted/pub.dev/flutter_lite_camera-0.1.0/linux/include/Camera.h` and `linux/CameraLinux.cpp`
- **Upstream bug:** `Open()` leaves `VIDIOC_STREAMON` active. `SetResolution` then
  calls `VIDIOC_S_FMT` without `STREAMOFF` → `EBUSY` on most V4L2 drivers; the
  fallback `RestartCapture()` was missing entirely, so the first resolution
  probe wedged the camera and `listMediaTypes` later double-frees
  (`fl_value_append_take` on a `g_autoptr` map → `free(): invalid pointer`).
- **Symptom:** Linux HQ QR scanner crashes or stays at 640×480; `flutter test`
  not affected but `flutter build linux` would segfault on camera open.
- **Fix:**
  - `Camera.h:112` adds `bool RestartCapture();` with comment `STREAMOFF -> S_FMT -> requeue -> STREAMON`.
  - `CameraLinux.cpp:203` implements `RestartCapture()` (re-queue all `mmap` buffers via `VIDIOC_QBUF`, then `VIDIOC_STREAMON`).
  - `CameraLinux.cpp:224` `SetResolution()` now does `StopCaptureLoop(); StopCapture(); ioctl(VIDIOC_S_FMT)` → save `frameWidth/Height` → `RestartCapture()`, restoring the stream on both success and failure.
  - Dart side (`lib/ui/linux_qr_scan_page.dart:132`) never calls `listMediaTypes`; it probes `setResolution`/`getWidth`/`getHeight` exact-match highest-first.
- **Patch file:** `tool/patches/flutter_lite_camera_linux.patch` (unified diff) + `tool/patches/apply_lite_camera_patch.py` (idempotent Python applier used by the shell wrapper).
- **Verify:** `grep -n RestartCapture ~/.pub-cache/hosted/pub.dev/flutter_lite_camera-0.1.0/linux/CameraLinux.cpp` should show 3 hits; `flutter analyze lib/ui/linux_qr_scan_page.dart` clean.

### 2. `wifi_iot 0.3.19+2` — `android/build.gradle` jcenter + AGP 8.2.0

- **Pub-cache path:** `~/.pub-cache/hosted/pub.dev/wifi_iot-0.3.19+2/android/build.gradle`
- **Upstream bug:** Plugin's `build.gradle` still references `jcenter()` (removed), pins `classpath "com.android.tools.build:gradle:8.2.0"` and injects `allprojects { repositories { jcenter() } }` into the root project, breaking AGP 8.13 / Gradle 8.11 builds with `Plugin not found` / `jcenter 403`.
- **Symptom:** `flutter build apk --debug` fails at `:wifi_iot:compileDebugKotlin` on Android.
- **Fix:** Replace the file with the minimal `com.android.library` stub (see `tool/patches/wifi_iot_build_gradle.patch` — the replacement is only ~15 lines):
  ```
  group 'com.alternadom.wifiiot'
  version '1.0-SNAPSHOT'
  apply plugin: 'com.android.library'
  android {
      namespace 'com.alternadom.wifiiot'
      compileSdk 34
      defaultConfig { minSdkVersion 16 ... }
      lintOptions { disable 'InvalidPackage' }
  }
  ```
  No repositories, no buildscript classpath — the host app's AGP provides them.
- **Patch file:** `tool/patches/wifi_iot_build_gradle.patch` + replacement logic in `apply_patches.sh`.
- **Verify:** `cat ~/.pub-cache/hosted/pub.dev/wifi_iot-0.3.19+2/android/build.gradle` should be the 15-line stub; `flutter build apk --debug` succeeds.

### 3. `flutter_litert 3.8.0` — Android build no longer patched

- **Status:** Upstream now ships `android/build.gradle.kts` with `AGP 8.13.2` + `kotlin-gradle-plugin 2.3.20` and correct `compileSdk 36`. No patch required on current version. The older `flutter pub get` workaround (strip to `compileSdk 34`) mentioned in `ARCH_REVIEW.md` is kept in history but not applied unless the version regresses. `tool/apply_patches.sh` probes `flutter_litert` version and only warns if a stale `android/build.gradle` reappears.

### 4. `ble_peripheral_plus 2.5.4` — Windows `BluetoothLEAdvertisementPublisher` for manufacturer data

- **Pub-cache path:** `~/.pub-cache/hosted/pub.dev/ble_peripheral_plus-2.5.4/windows/ble_peripheral_plugin.{h,cpp}`
- **Upstream bug:** Windows implementation only advertises `GattServiceProvider` (GATT service UUID). `StartAdvertising(..., manufacturer_data)` is ignored unless at least one `BleService` was added, so GridZero's mesh frames (`companyId 0xFFFF` + 18B payload via manufacturer data, no GATT service) never go on air. HQ was scan-only on Windows.
- **Symptom:** Windows HQ never appears in `MESH` peer list as a transmitter; `diagnostics` shows `ADV OFF`.
- **Fix (C++ WinRT):**
  - `ble_peripheral_plugin.h:87` adds `BluetoothLEAdvertisementPublisher advertisementPublisher{nullptr}; winrt::event_token publisherStatusChangedToken{}; bool publisherStarted{false};` + `Publisher_StatusChanged` / `PublisherStatusToString` decls.
  - `ble_peripheral_plugin.cpp`:
    - `IsAdvertising()` returns true if `publisherStarted`.
    - `StartAdvertising()` — if `manufacturer_data` non-empty, tear down any stale publisher, create `BluetoothLEAdvertisementPublisher`, attach `BluetoothLEManufacturerData` (`CompanyId = 0xFFFF`, `Data = DetachBuffer()` via `DataWriter`), `Advertisement().ManufacturerData().Append`, hook `StatusChanged`, `Start()`, report `Started`/`Aborted` via `OnAdvertisingStatusUpdate`.
    - `StopAdvertising()` stops the publisher and clears its token before the GATT teardown.
    - New handlers `Publisher_StatusChanged` / `PublisherStatusToString` forward `Started`/`Aborted`/`Stopped` to Dart.
  - Dart side `lib/core/mesh/win_mesh_adapter.dart:1` previously stubbed `broadcast()` (scan-only); it now forwards to `NativeMeshAdapter.broadcast()` which goes through the patched publisher. Status is just `inner.status`; no `ADV UNSUPPORTED` banner.
- **Patch files:** `tool/patches/windows_ble_advertise_h.patch` + `windows_ble_advertise_cpp.patch` (unified diffs) and `tool/patches/apply_windows_ble_patch.py` (idempotent Python that checks for `advertisementPublisher` sentinel before patching; also used as fallback if `patch` fails due to drift).
- **Verify:** `grep -n advertisementPublisher ~/.pub-cache/hosted/pub.dev/ble_peripheral_plus-2.5.4/windows/ble_peripheral_plugin.h` should show 4 hits; on a Windows host `flutter build windows --release` should succeed and `diagnostics` on the Windows HQ should show `tier` without `winAdv: UNSUPPORTED`.
- **Constraint:** Requires Win10 10240+ and `bluetooth` capability (already declared in `windows/runner/Runner.rc` via Flutter). Payload must stay ≤31B legacy (GridZero uses 20B: 2B company + 18B mesh) or enable `UseExtendedAdvertisement` for 254B.

### 5. `ble_peripheral_plus 2.5.4` — Windows `CMakeLists.txt` PLUGIN_NAME mismatch

- **Pub-cache path:** `~/.pub-cache/hosted/pub.dev/ble_peripheral_plus-2.5.4/windows/CMakeLists.txt`
- **Upstream bug:** `set(PLUGIN_NAME "ble_peripheral_plugin")` (without `_plus`) while Dart pubspec declares `ble_peripheral_plus` and Flutter's `generated_plugins.cmake` looks for `ble_peripheral_plus_plugin` via `$<TARGET_FILE:ble_peripheral_plus_plugin>`. CMake fails `No target "ble_peripheral_plus_plugin"` on Windows.
- **Fix:** `tool/patches/ble_peripheral_plus_windows_cmake.patch` changes `PLUGIN_NAME` to `ble_peripheral_plus_plugin`; applier `tool/patches/apply_ble_cmake_patch.py` checks sentinel `ble_peripheral_plus_plugin` before patching.
- **Verify:** `grep PLUGIN_NAME ~/.pub-cache/hosted/pub.dev/ble_peripheral_plus-2.5.4/windows/CMakeLists.txt` should show `ble_peripheral_plus_plugin`; `flutter build windows --release` on `windows-latest` should generate without `No target` error.
- **History:** Added 2026-08-28 after CI `windows-2025` failure on `33094135901`.

## Apply script

`tool/apply_patches.sh` (executable):

```bash
flutter pub get
bash tool/apply_patches.sh   # → [patch] lite_camera ... [patch] wifi_iot ... [patch] windows BLE ...
flutter analyze
```

It is safe to run on Linux hosts where Windows patches are no-ops (the `.cpp` path doesn't exist). On Windows hosts all four are required before `flutter build windows`.

## Adding a new patch

1. Fix the file under `~/.pub-cache/hosted/pub.dev/<pkg>-<ver>/...`.
2. Save a unified diff to `tool/patches/<name>.patch`:
   ```bash
   diff -u <file>.bak <file> > tool/patches/<name>.patch
   ```
3. Add an idempotent Python applier `tool/patches/apply_<name>.py` (check sentinel before patching) and hook it in `tool/apply_patches.sh`.
4. Document here with version, path, symptom, and verification command.

## History

- Camera EBUSY + wifi_iot jcenter fixes first noted in `.agents/TASK_TRACK.md` #Camera negotiation native crash and #Officer downloads DB.
- Windows BLE publisher patch added 2026-08-28 for `windows/` target (`docs/WINDOWS_FEASIBILITY.md`).
