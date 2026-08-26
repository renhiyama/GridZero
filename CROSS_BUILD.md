# Cross-building Windows from Linux

`flutter build windows` officially requires a Windows host (MSVC + Windows SDK).
`flutter` on Linux refuses: `build windows only supported on Windows hosts`.

## What works

| Method | How | When to use |
|--------|-----|-------------|
| **GitHub Actions `windows-latest`** (recommended) | `.github/workflows/windows.yml` does `flutter pub get` → `tool/apply_patches.sh` → `flutter build windows --release` and uploads `build/windows/x64/runner/Release/` as artifact. Push to `main` or Run workflow. | CI/release builds, no local Windows needed. |
| **WinBridge** (Linux → Windows cross-compile) | https://github.com/Dhiva-Labs/WinBridge — auto-detects Flutter projects and cross-builds to PE32+ via `xwin` Windows SDK + `clang-cl` MSVC shim, verifies EXE. Experimental for Flutter 3.x. | Local dev on Linux without VM, if you must produce an EXE on this machine. |
| **WSL / VM / dual-boot** | Run Flutter inside Windows (native or WSL2 with Windows toolchain passthrough) | Local debugging of BLE publisher / installer. |

## Why not plain MinGW

Flutter's Windows engine (`flutter_windows.dll`, `libflutter`) is built with MSVC STL/ABI.
MinGW `x86_64-w64-mingw32-gcc` links `libstdc++-6.dll` and is ABI-incompatible — you would
rebuild the engine itself. Flutter issue #106992 / #93164 track cross-compile but it is
P3 triaged, not on roadmap. Use `xwin` + `clang-cl` (MSVC-compatible) if you go the
cross path, not MinGW.

## Local cross attempt (if you insist)

```bash
# 1. Install xwin for Windows SDK
cargo install xwin
xwin --accept-license splat --output /tmp/xwin

# 2. WinBridge one-liner (detects Flutter, picks xwin+clang)
# https://github.com/Dhiva-Labs/WinBridge
pipx install winbridge  # or cargo install winbridge
winbridge build --target x86_64-pc-windows-msvc

# Verify
file build/windows/x64/runner/Release/gridzero.exe  # → PE32+ executable
```

If WinBridge fails on this Flutter version, fall back to GitHub Actions — it is the
supported path and what the feeder workflow already does.

## BLE publisher note

The Windows BLE advert fix (`tool/patches/windows_ble_advertise_*.patch`) is C++ and
rebuilt as part of `flutter build windows`. It must be reapplied after every
`flutter pub get` (the workflow does this; locally run `bash tool/apply_patches.sh`).
