#!/usr/bin/env python3
import os, pathlib
for pkg in ["ble_peripheral_plus-2.5.4", "permission_handler_windows-0.2.2"]:
    p = pathlib.Path(os.environ.get("PUB_CACHE", str(pathlib.Path.home() / ".pub-cache"))) / f"hosted/pub.dev/{pkg}/windows/CMakeLists.txt"
    if not p.exists():
        win_path = pathlib.Path.home() / f"AppData/Local/Pub/Cache/hosted/pub.dev/{pkg}/windows/CMakeLists.txt"
        if win_path.exists():
            p = win_path
    if not p.exists():
        continue
    t = p.read_text()
    if "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS" not in t:
        t = t.replace("target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)", "target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)")
        # Fallback for permission_handler which may have different pattern
        if "_SILENCE" not in t and "apply_standard_settings" in t:
            t = t.replace("apply_standard_settings(${PLUGIN_NAME})", "apply_standard_settings(${PLUGIN_NAME})\nadd_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)")
        p.write_text(t)
        print(f"patched {pkg} for MSVC coroutine")
    else:
        print(f"{pkg} already patched")
