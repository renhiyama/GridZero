#!/usr/bin/env python3
"""Idempotent applier for wifi_iot 0.3.19+2 android/build.gradle minimal stub."""
import pathlib
p = pathlib.Path.home() / ".pub-cache/hosted/pub.dev/wifi_iot-0.3.19+2/android/build.gradle"
if not p.exists():
    print(f"skip: {p} not found")
    exit(0)
minimal = """group 'com.alternadom.wifiiot'
version '1.0-SNAPSHOT'

apply plugin: 'com.android.library'

android {
    namespace 'com.alternadom.wifiiot'
    compileSdk 34
    defaultConfig {
        minSdkVersion 16
        testInstrumentationRunner "androidx.test.runner.AndroidJUnitRunner"
    }
    lintOptions {
        disable 'InvalidPackage'
    }
}
"""
cur = p.read_text()
if "jcenter" in cur or "buildscript" in cur or len(cur) > 600:
    p.write_text(minimal)
    print("wifi_iot build.gradle patched to minimal")
else:
    print("wifi_iot build.gradle already minimal")
