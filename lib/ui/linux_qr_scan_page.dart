/// QR scan page for Linux desktops.
///
/// mobile_scanner has no Linux plugin, so this path drives the laptop's
/// built-in camera (V4L2, /dev/video*) through flutter_lite_camera and
/// decodes frames with zxing2 (pure-Dart ZXing port).
///
/// The plugin's `startPreview()`/Texture path has a use-after-free on Linux
/// (the raster thread can still read a buffer the plugin frees in
/// `copy_pixels`), which crashes the app. This page never starts a texture:
/// it polls `captureFrame()` directly (a safe synchronous DQBUF read) and
/// renders each frame through `decodeImageFromPixels` into a `RawImage`.
/// Frames are downscaled 2x and decoded on a background isolate so the UI
/// thread only renders; the frame is mirrored before decode so the decoder
/// reads exactly what the preview shows.
///
/// This page renders no Scaffold/AppBar of its own: it is always embedded in
/// ProvisionScanPage's Scaffold, which supplies the chrome.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_lite_camera/flutter_lite_camera.dart';
// zxing2 does not export a concrete reader; the decoder lives in src/.
// ignore: implementation_imports
import 'package:zxing2/src/qrcode/qrcode_reader.dart';
import 'package:zxing2/zxing2.dart';

/// Input to the background decode job: a raw YUYV-converted frame plus its
/// negotiated dimensions. Plain fields so it can cross the isolate boundary.
class _FrameJob {
  const _FrameJob({required this.data, required this.w, required this.h});

  final Uint8List data;
  final int w;
  final int h;
}

/// Result of a background decode job: the full-resolution decode verdict plus
/// a bounded-size RGBA copy for the live preview.
class _DecodedFrame {
  const _DecodedFrame({
    required this.rgba,
    required this.pw,
    required this.ph,
    required this.text,
  });

  final Uint8List rgba;
  final int pw;
  final int ph;
  final String text;
}

class LinuxQrScanPage extends StatefulWidget {
  const LinuxQrScanPage({super.key, this.onScan});

  /// When set, decoded frames are forwarded instead of closing the page.
  /// Used by the paged provisioning flow, which must keep scanning.
  final ValueChanged<String>? onScan;

  @override
  State<LinuxQrScanPage> createState() => _LinuxQrScanPageState();
}

class _LinuxQrScanPageState extends State<LinuxQrScanPage> {
  final _camera = FlutterLiteCamera();
  // The Dart wrapper hides them, but the native plugin also implements
  // setResolution/getWidth/getHeight on this channel; call them directly so
  // we can negotiate a high-res mode instead of the 640x480 default.
  // (listMediaTypes exists too but double-frees natively: never call it.)
  static const _channel = MethodChannel('flutter_lite_camera');
  Timer? _pollTimer;
  String? _error;
  bool _done = false;
  ui.Image? _previewImage;
  double _previewAspect = 4 / 3;
  int _frame = 0;

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
              'CAMERA OPEN FAILED: check /dev/video access '
              '(video group)',
        );
        return;
      }
      await _negotiateBestResolution();
      if (!mounted) return;
      // Decode runs off-thread, so polling can be aggressive without jank.
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 120),
        (_) => _decodeFrame(),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'CAMERA ERROR: $e');
    }
  }

  /// Probes common modes highest-first and keeps the first one the driver
  /// grants EXACTLY (S_FMT reports what it actually negotiated via
  /// getWidth/getHeight). YUYV caps most sensors well below their max JPEG
  /// size, so exact-match probing avoids ending up at some odd driver-clamped
  /// mode. Falls back silently to whatever open() negotiated.
  static const _candidateResolutions = <(int, int)>[
    (1920, 1080),
    (1600, 1200),
    (1280, 960),
    (1280, 720),
    (1024, 768),
    (800, 600),
  ];

  Future<void> _negotiateBestResolution() async {
    try {
      for (final (w, h) in _candidateResolutions) {
        final ok = await _channel.invokeMethod('setResolution', {
          'width': w,
          'height': h,
        });
        if (ok != true) continue;
        final gw = await _channel.invokeMethod<int>('getWidth');
        final gh = await _channel.invokeMethod<int>('getHeight');
        if (gw == w && gh == h) return;
      }
    } catch (_) {
      // Negotiation is an optimization; the default mode still scans.
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

      // Decode runs off the UI isolate at full resolution (small QR modules
      // survive), with a bounded-size copy for the preview.
      final result = await compute(
        _decodeAndPreview,
        _FrameJob(data: data, w: w, h: h),
      );
      if (result == null) return;
      _renderPreview(result.rgba, result.pw, result.ph);
      if (result.text.isNotEmpty) {
        final cb = widget.onScan;
        if (cb != null) {
          cb(result.text);
        } else if (!_done) {
          _done = true;
          if (mounted) Navigator.of(context).pop(result.text);
        }
      }
    } catch (_) {
      // NotFound / checksum errors are expected between frames; keep polling.
    }
  }

  /// Background-isolate job. Orientation matters here: the phone shows its QR
  /// straight into the laptop's front camera, and a camera capture is a true
  /// projection of what it sees: never mirrored. So BOTH the decoder and the
  /// preview consume raw pixels; no flip anywhere keeps them consistent.
  ///
  /// Luminance is built at full resolution for the decoder while the preview
  /// RGBA is decimated by the smallest integer factor keeping it under ~960px
  /// wide: one pass over the source builds both.
  static _DecodedFrame? _decodeAndPreview(_FrameJob job) {
    final w = job.w;
    final h = job.h;
    final factor = (w / 960).ceil().clamp(1, 8);
    final pw = w ~/ factor;
    final ph = h ~/ factor;
    final luminance = Int32List(w * h);
    final rgba = Uint8List(pw * ph * 4);
    for (var y = 0; y < h; y++) {
      final srcRow = y * w * 3;
      final lumRow = y * w;
      final dstRow = (y ~/ factor) * pw;
      final previewY = y % factor == 0;
      for (var x = 0; x < w; x++) {
        final j = srcRow + x * 3;
        final r = job.data[j];
        final g = job.data[j + 1];
        final b = job.data[j + 2];
        luminance[lumRow + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
        if (previewY && x % factor == 0) {
          final k = (dstRow + x ~/ factor) * 4;
          rgba[k] = r;
          rgba[k + 1] = g;
          rgba[k + 2] = b;
          rgba[k + 3] = 0xFF;
        }
      }
    }
    try {
      final bitmap = BinaryBitmap(
        GlobalHistogramBinarizer(RGBLuminanceSource(w, h, luminance)),
      );
      final result = QRCodeReader().decode(bitmap);
      return _DecodedFrame(
        rgba: rgba,
        pw: pw,
        ph: ph,
        text: result.text,
      );
    } catch (_) {
      // No code in this frame; still hand back the pixels for preview.
      return _DecodedFrame(rgba: rgba, pw: pw, ph: ph, text: '');
    }
  }

  /// Best-effort live preview from the frames already captured. Never throws:
  /// scanning keeps running even if rendering fails. Stale decodes are
  /// dropped so an older frame can never dispose an image still on screen.
  Future<void> _renderPreview(Uint8List rgba, int w, int h) async {
    final frame = ++_frame;
    try {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        w,
        h,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final image = await completer.future;
      if (!mounted || frame != _frame) {
        image.dispose();
        return;
      }
      setState(() {
        _previewImage?.dispose();
        _previewImage = image;
        if (w > 0 && h > 0) _previewAspect = w / h;
      });
    } catch (_) {
      // No preview without a decode; scanning continues regardless.
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _previewImage?.dispose();
    _previewImage = null;
    _camera.release().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _previewImage;
    // No Scaffold/AppBar here: this page is always embedded in
    // ProvisionScanPage's Scaffold, which already provides the chrome.
    return _error != null
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
        : preview == null
        ? const Center(
            child: CircularProgressIndicator(color: Colors.white54),
          )
        : Center(
            child: AspectRatio(
              aspectRatio: _previewAspect,
              child: RawImage(
                image: preview,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
            ),
          );
  }
}
