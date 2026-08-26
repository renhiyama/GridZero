/// Face enrolment (FR: face scan during registration, MobileFaceNet).
///
/// Identity is bound to a 192-d (or model-defined) MobileFaceNet embedding
/// captured on-device at registration and stored in the local ledger keyed by
/// citizen id. Later flows (officer claim verification) can compare a live
/// embedding to the enrolled one by cosine similarity.
///
/// The heavy lifting: ML Kit face detection and LiteRT inference: is gated
/// behind a runtime capability check so desktop/tests can import this module
/// without a camera or model runtime; only the pure-Dart crop/resize math and
/// the storage round-trip are unit-tested here.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_litert/flutter_litert.dart' show Interpreter;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

/// Resolution the MobileFaceNet graph expects.
const int kFaceNetInputSize = 112;

/// Asset path of the bundled MobileFaceNet model. Flutter asset keys carry
/// the full pubspec path (with `assets/`), and flutter_litert resolves via
/// [rootBundle], so the prefix is required.
const String kFaceNetModelAsset = 'assets/face/mobilefacenet.tflite';

/// A detected face plus the source frame, ready for alignment.
class FaceEnrollCandidate {
  FaceEnrollCandidate({
    required this.frameRgba,
    required this.width,
    required this.height,
    required this.boundingBox,
    required this.leftEye,
    required this.rightEye,
  });

  /// Raw RGB pixel buffer, `width * height * 3` bytes.
  final Uint8List frameRgba;
  final int width;
  final int height;

  /// Face bounding box in frame pixel coordinates.
  final Rect boundingBox;

  /// Eye positions in frame pixel coordinates (0/0 = top-left).
  final (double, double) leftEye;
  final (double, double) rightEye;
}

/// Crops a square region centred on the eye line and scales it to
/// [kFaceNetInputSize]^2×3 with bilinear interpolation, normalized to [-1,1]
/// as MobileFaceNet expects. Pure Dart so the geometry is unit-testable
/// without a camera.
///
/// The crop side is [cropFactor]× the face width (1.8x gives a tight face
/// crop, 2.6x includes the head margin the model was trained on); the box is
/// centred on the eye midpoint so the eyes land at a consistent height.
Float32List alignFaceRgba({
  required FaceEnrollCandidate face,
  int outSize = kFaceNetInputSize,
  double cropFactor = 2.0,
}) {
  final w = face.width;
  final h = face.height;
  final bw = face.boundingBox.width;
  final bh = face.boundingBox.height;
  final cx = (face.leftEye.$1 + face.rightEye.$1) / 2;
  final cy = (face.leftEye.$2 + face.rightEye.$2) / 2;
  // Use the larger of width/height so a tilted or wide box still crops the
  // whole face.
  final side = (bw > bh ? bw : bh) * cropFactor;
  final half = side / 2;
  final x0 = cx - half;
  final y0 = cy - half - bh * 0.1; // a little forehead room

  final out = Float32List(outSize * outSize * 3);
  for (var oy = 0; oy < outSize; oy++) {
    final sy = y0 + oy / (outSize - 1) * side;
    for (var ox = 0; ox < outSize; ox++) {
      final sx = x0 + ox / (outSize - 1) * side;
      final (r, g, b) = _bilinear(frameRgba: face.frameRgba, w: w, h: h, x: sx, y: sy);
      final o = (oy * outSize + ox) * 3;
      out[o] = r / 127.5 - 1;
      out[o + 1] = g / 127.5 - 1;
      out[o + 2] = b / 127.5 - 1;
    }
  }
  return out;
}

(double, double, double) _bilinear({
  required Uint8List frameRgba,
  required int w,
  required int h,
  required double x,
  required double y,
}) {
  // Clamp so crops that poke past the frame edge sample edge pixels instead
  // of throwing. Enrollment snapshots can be close-cropped.
  x = x.clamp(0.0, (w - 1).toDouble());
  y = y.clamp(0.0, (h - 1).toDouble());
  final x0 = x.floor();
  final y0 = y.floor();
  final fx = x - x0;
  final fy = y - y0;
  final x1 = x0 >= w - 1 ? x0 : x0 + 1;
  final y1 = y0 >= h - 1 ? y0 : y0 + 1;
  double lerp(int a, int b) => a + (b - a) * fx;
  double sample(int yy, int xx, int c) =>
      frameRgba[(yy * w + xx) * 3 + c].toDouble();
  final top = (lerp(sample(y0, x0, 0).toInt(), sample(y0, x1, 0).toInt()),
      lerp(sample(y0, x0, 1).toInt(), sample(y0, x1, 1).toInt()),
      lerp(sample(y0, x0, 2).toInt(), sample(y0, x1, 2).toInt()));
  final bot = (lerp(sample(y1, x0, 0).toInt(), sample(y1, x1, 0).toInt()),
      lerp(sample(y1, x0, 1).toInt(), sample(y1, x1, 1).toInt()),
      lerp(sample(y1, x0, 2).toInt(), sample(y1, x1, 2).toInt()));
  double l2(double a, double b) => a + (b - a) * fy;
  return (l2(top.$1, bot.$1), l2(top.$2, bot.$2), l2(top.$3, bot.$3));
}

/// L2-normalizes an embedding in place and returns it.
Float32List l2Normalize(Float32List embedding) {
  var norm = 0.0;
  for (final v in embedding) {
    norm += v * v;
  }
  norm = math.sqrt(norm);
  if (norm > 1e-8) {
    for (var i = 0; i < embedding.length; i++) {
      embedding[i] /= norm;
    }
  }
  return embedding;
}

/// Cosine similarity between two L2-normalized embeddings, clamped to
/// [-1, 1]. The canonical comparison for MobileFaceNet features.
double embeddingCosine(Float32List a, Float32List b) {
  if (a.length != b.length) return 0;
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot.clamp(-1.0, 1.0);
}

/// Detects the largest face in a JPEG file and returns the candidate plus a
/// raw RGB buffer ready for [alignFaceRgba].
///
/// Returns null when no face is found or the image can't be decoded.
Future<FaceEnrollCandidate?> detectLargestFaceFromJpeg(String path) async {
  final detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableLandmarks: true,
      enableTracking: false,
    ),
  );
  try {
    final faces = await detector.processImage(InputImage.fromFilePath(path));
    if (faces.isEmpty) return null;
    faces.sort((a, b) {
      final wa = a.boundingBox.width * a.boundingBox.height;
      final wb = b.boundingBox.width * b.boundingBox.height;
      return wb.compareTo(wa);
    });
    final face = faces.first;

    final bytes = File(path).readAsBytesSync();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final eye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final right = face.landmarks[FaceLandmarkType.rightEye]?.position;
    if (eye == null || right == null) return null;
    return FaceEnrollCandidate(
      frameRgba: decoded.getBytes(order: img.ChannelOrder.rgb),
      width: decoded.width,
      height: decoded.height,
      boundingBox: face.boundingBox,
      leftEye: (eye.x.toDouble(), eye.y.toDouble()),
      rightEye: (right.x.toDouble(), right.y.toDouble()),
    );
  } finally {
    detector.close();
  }
}

/// Loads the bundled MobileFaceNet interpreter and produces an embedding for
/// the given aligned input. One instance per app; close when done.
class FaceEmbedder {
  FaceEmbedder(this._interpreter, this._outputLength);

  final Interpreter _interpreter;
  final int _outputLength;

  static Future<FaceEmbedder> fromAsset() async {
    final interpreter = await Interpreter.fromAsset(kFaceNetModelAsset);
    final outShape = interpreter.getOutputTensors().first.shape;
    final dim = outShape.length >= 2 ? outShape[outShape.length - 1] : 0;
    if (dim <= 0) throw StateError('face model has no output dimension');
    return FaceEmbedder(interpreter, dim);
  }

  /// Runs MobileFaceNet over a [kFaceNetInputSize]^2×3 normalized tensor.
  Float32List embed(Float32List alignedInput) {
    final output = Float32List(_outputLength);
    final input = Float32List(kFaceNetInputSize * kFaceNetInputSize * 3)
      ..setAll(0, alignedInput);
    _interpreter.run(input, output);
    return l2Normalize(output);
  }

  void close() => _interpreter.close();
}