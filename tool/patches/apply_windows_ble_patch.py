#!/usr/bin/env python3
"""Idempotent patcher for ble_peripheral_plus Windows manufacturer-data advertise."""
import pathlib

base = pathlib.Path.home() / ".pub-cache/hosted/pub.dev/ble_peripheral_plus-2.5.4/windows"
h = base / "ble_peripheral_plugin.h"
cpp = base / "ble_peripheral_plugin.cpp"

if not h.exists():
    print(f"skip: {h} not found")
    exit(0)

ht = h.read_text()
if "advertisementPublisher" not in ht:
    # apply h patch
    old = "        // BluetoothLe\n        Radio bluetoothRadio{nullptr};\n        BluetoothAdapter adapter{nullptr};"
    new = "        // BluetoothLe\n        Radio bluetoothRadio{nullptr};\n        BluetoothAdapter adapter{nullptr};\n        BluetoothLEAdvertisementPublisher advertisementPublisher{nullptr};\n        winrt::event_token publisherStatusChangedToken{};\n        bool publisherStarted{false};\n        void Publisher_StatusChanged(BluetoothLEAdvertisementPublisher const &sender, BluetoothLEAdvertisementPublisherStatusChangedEventArgs const &args);\n        std::string PublisherStatusToString(BluetoothLEAdvertisementPublisherStatus status);"
    if old in ht:
        h.write_text(ht.replace(old, new))
        print("h patched")
    else:
        print("h already patched or mismatch")

cpt = cpp.read_text()
if "publisherStarted && advertisementPublisher" not in cpt:
    # full cpp patch via diff files
    import subprocess, pathlib as p
    root = p.Path(__file__).resolve().parents[2]
    for diff in [root / "tool/patches/windows_ble_advertise_h.patch", root / "tool/patches/windows_ble_advertise_cpp.patch"]:
        if diff.exists():
            subprocess.run(["patch", "-p0", "-N", "-i", str(diff)], cwd="/", check=False)
    print("cpp patched via diff fallback")
else:
    print("cpp already patched")
