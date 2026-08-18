/// QR scan page for Linux desktops.
///
/// mobile_scanner has no Linux plugin, so this path drives the laptop's
/// built-in camera (V4L2, /dev/video*) through flutter_lite_camera and
/// decodes frames with zxing2 (pure-Dart ZXing port). Frames are downscaled
/// 2x before decoding to keep the per-frame cost small.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_lite_camera/flutter_lite_camera.dart';
// zxing2 does not export a concrete reader; the decoder lives in src/.
// ignore: implementation_imports
import 'package:zxing2/src/qrcode/qrcode_reader.dart';
import 'package:zxing2/zxing2.dart';

class LinuxQrScanPage extends StatefulWidget {
  const LinuxQrScanPage({super.key, required this.label});

  final String label;

  @override
  State<LinuxQrScanPage> createState() => _LinuxQrScanPageState();
}

class _LinuxQrScanPageState extends State<LinuxQrScanPage> {
  final _camera = FlutterLiteCamera();
  int? _textureId;
  Timer? _pollTimer;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final devices = await _camera.getDeviceList();
      if (devices.isEmpty) {
        setState(() => _error = 'NO CAMERA FOUND (/dev/video*)');
        return;
      }
      final opened = await _camera.open(0);
      if (!opened) {
        setState(
          () => _error =
              'CAMERA OPEN FAILED — check /dev/video access '
              '(video group)',
        );
        return;
      }
      final id = await _camera.startPreview();
      if (!mounted) return;
      setState(() => _textureId = id);
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _decodeFrame(),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'CAMERA ERROR: $e');
    }
  }

  Future<void> _decodeFrame() async {
    if (_done) return;
    try {
      final frame = await _camera.captureFrame();
      final data = frame['data'] as Uint8List?;
      final w = frame['width'] as int?;
      final h = frame['height'] as int?;
      if (data == null || w == null || h == null || data.isEmpty) return;

      // Downscale 2x before decoding: QR modules stay readable at ~240px and
      // this cuts the per-frame pixel loop ~4x.
      final sw = w ~/ 2;
      final sh = h ~/ 2;
      final pixels = Int32List(sw * sh);
      for (var y = 0; y < sh; y++) {
        final srcRow = (y * 2 * w + w) * 3;
        final dstRow = y * sw;
        for (var x = 0; x < sw; x++) {
          final j = srcRow + (x * 2 + 1) * 3;
          final r = data[j];
          final g = data[j + 1];
          final b = data[j + 2];
          pixels[dstRow + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
        }
      }

      final bitmap = BinaryBitmap(
        GlobalHistogramBinarizer(RGBLuminanceSource(sw, sh, pixels)),
      );
      final result = QRCodeReader().decode(bitmap);
      if (result.text.isNotEmpty && !_done) {
        _done = true;
        if (mounted) Navigator.of(context).pop(result.text);
      }
    } catch (_) {
      // NotFound / checksum errors are expected between frames; keep polling.
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _camera.stopPreview().catchError((_) {});
    _camera.release().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.label)),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                ),
              ),
            )
          : _textureId == null
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white54),
            )
          : Center(
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Texture(textureId: _textureId!),
              ),
            ),
    );
  }
}
