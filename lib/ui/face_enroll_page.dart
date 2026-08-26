/// Face enrolment capture page (FR: face scan during registration).
///
/// Front camera preview; on capture the snapshot is run through ML Kit face
/// detection, the largest face is aligned to the bundled MobileFaceNet input
/// and embedded on-device. The page pops the L2-normalized embedding, or null
/// if the user backs out. Phone-only: Linux desktop has no camera pipeline, so
/// it degrades to an explanatory panel.
library;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/face_enroll.dart';
import 'hud_theme.dart';

class FaceEnrollPage extends StatefulWidget {
  const FaceEnrollPage({super.key, this.label = 'FACE ENROLLMENT'});

  final String label;

  @override
  State<FaceEnrollPage> createState() => _FaceEnrollPageState();
}

class _FaceEnrollPageState extends State<FaceEnrollPage> {
  CameraController? _controller;
  bool _ready = false;
  bool _busy = false;
  String? _status;
  FaceEmbedder? _embedder;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  Future<void> _startCamera() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      setState(() => _status = 'CAMERA CAPTURE IS PHONE-ONLY');
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.windows) {
      setState(() => _status = 'CAMERA CAPTURE UNAVAILABLE ON THIS DEVICE');
      return;
    }
    try {
      final granted = await Permission.camera.request();
      if (!granted.isGranted) {
        if (mounted) setState(() => _status = 'CAMERA PERMISSION DENIED');
        return;
      }
      final cameras = await availableCameras();
      final front = cameras.where((c) => c.lensDirection == CameraLensDirection.front);
      final cam = front.isNotEmpty ? front.first : cameras.first;
      final controller = CameraController(cam, ResolutionPreset.medium);
      _controller = controller;
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _ready = true;
        _status = 'CENTER YOUR FACE: THEN TAP CAPTURE';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'CAMERA START FAILED: $e');
    }
  }

  Future<void> _capture() async {
    if (_busy || _controller == null) return;
    setState(() {
      _busy = true;
      _status = 'CAPTURING…';
    });
    try {
      final shot = await _controller!.takePicture();
      final candidate = await detectLargestFaceFromJpeg(shot.path);
      if (candidate == null) {
        if (mounted) {
          setState(() {
            _busy = false;
            _status = 'NO FACE DETECTED: TAP TO RETRY';
          });
        }
        return;
      }
      _embedder ??= await FaceEmbedder.fromAsset();
      final aligned = alignFaceRgba(face: candidate);
      final embedding = _embedder!.embed(aligned);
      if (mounted) Navigator.of(context).pop(embedding);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'ENROLL FAILED: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _embedder?.close();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final controller = _controller;
    final preview = controller != null && controller.value.isInitialized
        ? _fullScreenPreview(controller)
        : const SizedBox.expand();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmAbort();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(widget.label)),
        body: Stack(
          children: [
            Positioned.fill(child: preview),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black.withValues(alpha: 0.7),
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _status ?? '…',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontFamily: 'monospace',
                        fontSize: 13,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _ready && !_busy ? _capture : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: p.primary,
                        foregroundColor: Colors.black,
                      ),
                      icon: const Icon(Icons.face),
                      label: Text(_busy ? 'CAPTURING…' : 'CAPTURE FACE'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Full-screen camera preview that keeps the sensor's true aspect ratio:
  /// the plugin already sizes [CameraPreview] to the preview dimensions, so we
  /// center it and scale up to cover the screen. Crops the overflow instead of
  /// stretching the image.
  Widget _fullScreenPreview(CameraController controller) {
    final ps = controller.value.previewSize;
    if (ps == null) {
      return Center(
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: CameraPreview(controller),
        ),
      );
    }
    final screen = MediaQuery.of(context).size;
    final screenRatio = screen.height / screen.width;
    final previewRatio = ps.height / ps.width;
    final scale = screenRatio > previewRatio
        ? screen.height / ps.height
        : screen.width / ps.width;
    return Transform.scale(
      scale: scale,
      child: Center(child: CameraPreview(controller)),
    );
  }

  Future<void> _confirmAbort() async {
    if (!mounted) return;
    final p = AppPalette.of(context);
    final abort = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.bg,
        title: const Text(
          'ABANDON FACE ENROLLMENT?',
          style: TextStyle(fontFamily: 'monospace'),
        ),
        content: const Text(
          'The face binding is not saved until you capture and confirm.',
          style: TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'KEEP GOING',
              style: TextStyle(color: p.primary, fontFamily: 'monospace'),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'ABANDON',
              style: TextStyle(color: p.error, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
    if (abort == true && mounted) Navigator.of(context).pop();
  }
}