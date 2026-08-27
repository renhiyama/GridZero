#!/usr/bin/env python3
import os, pathlib, shutil
for pkg in ["ble_peripheral_plus-2.5.4", "permission_handler_windows-0.2.2"]:
    base = pathlib.Path(os.environ.get("PUB_CACHE", str(pathlib.Path.home() / ".pub-cache"))) / f"hosted/pub.dev/{pkg}/windows"
    if not base.exists():
        win_base = pathlib.Path.home() / f"AppData/Local/Pub/Cache/hosted/pub.dev/{pkg}/windows"
        if win_base.exists():
            base = win_base
    p = base / "CMakeLists.txt"
    if not p.exists():
        continue
    t = p.read_text()
    if "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS" not in t:
        t = t.replace("target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)", "target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)")
        if "_SILENCE" not in t and "apply_standard_settings" in t:
            t = t.replace("apply_standard_settings(${PLUGIN_NAME})", "apply_standard_settings(${PLUGIN_NAME})\nadd_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)")
        p.write_text(t)
        print(f"patched {pkg} CMake for MSVC coroutine")
    else:
        print(f"{pkg} CMake already patched")
    # Fix ble_peripheral_plus include path for generated_plugin_registrant.cc
    if pkg == "ble_peripheral_plus-2.5.4":
        inc = base / "include"
        for src_rel in ["ble_peripheral/ble_peripheral_plugin_c_api.h", "ble_peripheral_plugin_c_api.h"]:
            src = inc / src_rel
            if src.exists():
                dst_dir = inc / "ble_peripheral_plus"
                dst_dir.mkdir(exist_ok=True)
                dst = dst_dir / "ble_peripheral_plugin_c_api.h"
                if not dst.exists():
                    shutil.copy(src, dst)
                    print(f"copied {src_rel} to ble_peripheral_plus for {pkg}")
                break
