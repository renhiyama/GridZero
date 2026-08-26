# GridZero release keep rules (R8). Dart code is AOT-compiled and unaffected;
# these keep lines only matter if a plugin relies on reflection or JNI lookups.
# Keep annotations processed by plugins (e.g. @KeepEntryPoint) reachable.
-keepattributes *Annotation*