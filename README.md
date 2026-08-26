# GridZero — air-gapped disaster relief & P2P triage

BLE mesh (BlueZ on Linux, WinRT on Windows), dynamic TOTP ration QR, hash-chain ledger, Command HQ. **Offline-first:** no internet, no backend.

## Repo map

- `lib/` — Flutter app (HQ laptop + Android phone, same binary)
- `docs/PATCHES.md` — all vendored fixes, how to reapply after `pub get`
- `CROSS_BUILD.md` — Windows cross-compile from Linux (why MinGW fails, xwin/WinBridge, CI)
- `tool/apply_patches.sh` — idempotent patcher for `~/.pub-cache`
- `windows/` — Windows desktop target (CMake + WinRT BLE publisher patch)

## Fresh system — full setup (Arch / Ubuntu / Windows)

### 1. Prerequisites

**All hosts:**
- Flutter 3.47+ (stable), Dart 3.13+, Git
- `flutter doctor` must be clean for your target (see below)

**Linux (HQ, primary):**
```bash
# Arch
sudo pacman -S base-devel clang cmake ninja pkgconf gtk3 \
  libbluetooth bluez v4l-utils hostapd dnsmasq iw iproute2 networkmanager

# Ubuntu/Debian
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev \
  libbluetooth-dev bluez v4l2-utils hostapd dnsmasq iw iproute2 network-manager

# Hostapd/dnsmasq need passwordless sudo for the HQ link (see linux_network.dart:158)
echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/iw, /usr/bin/ip, /usr/bin/hostapd, /usr/sbin/dnsmasq, /usr/bin/nft, /usr/sbin/ufw, /usr/bin/nmcli" | sudo tee /etc/sudoers.d/gridzero
sudo visudo -c
```

**Windows (HQ alt):**
- Visual Studio 2022 **with** `Desktop development with C++` (MSVC v143, Windows 11 SDK) + `C++ CMake tools`
- Or use CI (see Cross-build). `clang-cl` + `xwin` SDK for local cross.
- Bluetooth LE capable adapter + `bluetooth` capability in manifest (already declared).

**Android (phone/Citizen/Officer):**
- Android Studio, SDK platform 34+, NDK (for `flutter_litert`/`tflite`), `adb`
- Enable USB debugging; `flutter doctor --android-licenses`

### 2. Clone & fetch

```bash
git clone <this-repo> gridzero && cd gridzero
flutter pub get
bash tool/apply_patches.sh    # ← CRITICAL: re-applies every time after pub get
flutter analyze               # should be "No issues found"
flutter test                  # 166/166
```

**Why `apply_patches.sh` every time?** `flutter pub get` wipes `~/.pub-cache/hosted/pub.dev/`,
so all vendor fixes are lost. The script is idempotent — run it twice safely.
See `docs/PATCHES.md` for what each patch does and how to verify.

| Package | File | Symptom without patch | Patch |
|---------|------|----------------------|-------|
| `flutter_lite_camera 0.1.0` | `linux/CameraLinux.cpp` + `include/Camera.h` | `SetResolution` EBUSY, camera stuck 640×480, `listMediaTypes` double-free crash | `tool/patches/flutter_lite_camera_linux.patch` + `apply_lite_camera_patch.py` |
| `wifi_iot 0.3.19+2` | `android/build.gradle` | `jcenter 403`, AGP mismatch | `tool/patches/wifi_iot_build_gradle.patch` → minimal stub |
| `ble_peripheral_plus 2.5.4` | `windows/ble_peripheral_plugin.{h,cpp}` | Windows `manufacturerData` never advertises (GATT-only path) | `tool/patches/windows_ble_advertise_{h,cpp}.patch` → `BluetoothLEAdvertisementPublisher` |

Each patch is a unified diff + Python sentinel check; the shell wrapper logs `[patch] ... already patched` on re-run.

### 3. Build & run

**Linux HQ:**
```bash
flutter build linux --debug && ./build/linux/x64/debug/bundle/gridzero
# or dev:
flutter run -d linux
```

**Windows HQ (on Windows host):**
```powershell
flutter pub get
bash tool/apply_patches.sh   # Git Bash, or run the Python appliers via WSL
flutter build windows --release
# → build\windows\x64\runner\Release\gridzero.exe
```

**Windows from Linux (cross):** `flutter build windows` is blocked on Linux (`only supported on Windows hosts`). Use one of:

- **CI (recommended):** `git push` → `.github/workflows/windows.yml` builds on `windows-latest` and uploads `gridzero-windows` artifact. Manual trigger: Actions → `windows-build` → Run.
- **WinBridge + xwin (local cross):** see `CROSS_BUILD.md` — `cargo install xwin && xwin splat && pipx install winbridge && winbridge build --target x86_64-pc-windows-msvc`. Not officially supported by Flutter; fallback to CI if it fails.
- **WSL/VM:** run Flutter inside Windows.

**Android APK:**
```bash
flutter build apk --debug      # needs wifi_iot + litert patches already applied
adb install build/app/outputs/flutter-apk/app-debug.apk
```

### 4. Reproducing patches — deep verify

```bash
# 1. lite_camera
grep -n RestartCapture ~/.pub-cache/hosted/pub.dev/flutter_lite_camera-0.1.0/linux/CameraLinux.cpp
# → 3 hits (decl + impl + SetResolution)

# 2. wifi_iot
cat ~/.pub-cache/hosted/pub.dev/wifi_iot-0.3.19+2/android/build.gradle
# → 15-line minimal stub, no jcenter

# 3. BLE Windows
grep -n advertisementPublisher ~/.pub-cache/hosted/pub.dev/ble_peripheral_plus-2.5.4/windows/ble_peripheral_plugin.h
# → 4 hits
grep -n publisherStarted ~/.pub-cache/hosted/pub.dev/ble_peripheral_plus-2.5.4/windows/ble_peripheral_plugin.cpp
# → branch in StartAdvertising/StopAdvertising/IsAdvertising

# Adding a new vendor fix:
# 1) edit file under ~/.pub-cache/..., 2) diff -u file.bak file > tool/patches/<name>.patch,
# 3) add Python sentinel in tool/patches/apply_<name>.py, 4) hook in tool/apply_patches.sh,
# 5) document in docs/PATCHES.md.
```

## Cross-build for Windows — start now

On **this Linux box** (Arch, `clang 19`, `clang-cl` present, `cargo` present):

```bash
# One-time SDK fetch (~2 GB, cached)
cargo install xwin            # if not present
xwin --accept-license splat --output /tmp/xwin

# WinBridge (Flutter-aware cross driver)
pipx install winbridge 2>/dev/null || cargo install winbridge
winbridge --help
winbridge build --target x86_64-pc-windows-msvc
file build/windows/x64/runner/Release/gridzero.exe  # → PE32+ executable (x64)
```

If `winbridge build` errors on this Flutter engine (MSVC STL ABI is picky), push to CI instead — it is the supported path and already wired. See `CROSS_BUILD.md` for why plain MinGW (`x86_64-w64-mingw32-gcc`) **won't** work (MSVC runtime mismatch).

## Troubleshooting

- `flutter pub get` after switching branches → **always** `bash tool/apply_patches.sh` afterward.
- `Hosted network supported: No` on Windows HQ → adapter/driver can't host; use reverse link (phone hosts `GZ-*`, HQ joins via `netsh`).
- `HIGH_SAMPLING_RATE_SENSORS` SecurityException (Android) → reinstall after `AndroidManifest.xml` permission change.
- `free(): invalid pointer` in camera → `listMediaTypes` double-free; the app never calls it — do not re-enable.

## Docs

- `docs/PATCHES.md` — all patches, how to reapply
- `docs/WINDOWS_FEASIBILITY.md` — Windows port matrix (BLE scan/adv, netsh vs NetworkManager, camera)
- `CROSS_BUILD.md` — Windows building from Linux
- `.agents/TASK_TRACK.md` — session task log
