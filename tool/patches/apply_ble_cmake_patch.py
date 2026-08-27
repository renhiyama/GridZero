#!/usr/bin/env python3
import pathlib
p = pathlib.Path.home() / ".pub-cache/hosted/pub.dev/ble_peripheral_plus-2.5.4/windows/CMakeLists.txt"
if not p.exists():
    print(f"skip: {p} not found (not Windows)")
    exit(0)
t = p.read_text()
if 'ble_peripheral_plus_plugin' in t:
    print("already patched")
else:
    t = t.replace('set(PLUGIN_NAME "ble_peripheral_plugin")', 'set(PLUGIN_NAME "ble_peripheral_plus_plugin")')
    p.write_text(t)
    print("patched CMakeLists to ble_peripheral_plus_plugin")
