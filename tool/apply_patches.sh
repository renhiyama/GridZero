#!/bin/bash
set -e
# Re-apply all GridZero pub-cache patches after `flutter pub get` wipes them.
# Idempotent — safe to run twice. See docs/PATCHES.md for rationale.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
echo "[patch] GridZero pub-cache patches — see docs/PATCHES.md"

echo "[patch] 1/5 flutter_lite_camera 0.1.0 RestartCapture (linux/CameraLinux.cpp)..."
python3 "$ROOT/tool/patches/apply_lite_camera_patch.py" 2>&1 | sed 's/^/[patch] /'

echo "[patch] 2/5 wifi_iot 0.3.19+2 android/build.gradle (jcenter strip)..."
python3 "$ROOT/tool/patches/apply_wifi_iot_patch.py" 2>&1 | sed 's/^/[patch] /'

echo "[patch] 3/5 ble_peripheral_plus 2.5.4 windows BLE advertise (BluetoothLEAdvertisementPublisher)..."
python3 "$ROOT/tool/patches/apply_windows_ble_patch.py" 2>&1 | sed 's/^/[patch] /'

echo "[patch] 4/5 ble_peripheral_plus 2.5.4 windows CMake PLUGIN_NAME (plus)..."
python3 "$ROOT/tool/patches/apply_ble_cmake_patch.py" 2>&1 | sed 's/^/[patch] /'

echo "[patch] 5/5 MSVC coroutine deprecation (VS 2022 18, experimental/coroutine)..."
python3 "$ROOT/tool/patches/apply_msvc_coroutine_patch.py" 2>&1 | sed 's/^/[patch] /'

# flutter_litert 3.8.0 currently needs no patch; probe and warn if stale
if grep -q "jcenter" "$HOME/.pub-cache/hosted/pub.dev/flutter_litert-3.8.0/android/build.gradle" 2>/dev/null; then
  echo "[patch] WARN: flutter_litert still references jcenter — manual inspect docs/PATCHES.md"
fi

echo "[patch] done. Verify: flutter analyze && flutter test"
