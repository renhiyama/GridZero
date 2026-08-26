import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/face_enroll.dart';

void main() {
  group('alignFaceRgba', () {
    test('outputs 112x112x3 float32 normalized to [-1,1]', () {
      final w = 224;
      final h = 224;
      // Solid mid-grey frame: crop must be ~ (0.5*255/127.5 - 1) ~ 0.
      final frame = Uint8List(w * h * 3);
      for (var i = 0; i < frame.length; i += 3) {
        frame[i] = 128;
        frame[i + 1] = 128;
        frame[i + 2] = 128;
      }
      final face = FaceEnrollCandidate(
        frameRgba: frame,
        width: w,
        height: h,
        boundingBox: Rect.fromLTWH(80, 60, 80, 100),
        leftEye: (110, 105),
        rightEye: (150, 105),
      );
      final out = alignFaceRgba(face: face);
      expect(out.length, 112 * 112 * 3);
      // solid grey: every channel ≈ 0.00392 (128/127.5-1).
      for (var i = 0; i < out.length; i++) {
        expect((out[i] - (128 / 127.5 - 1)).abs(), lessThan(0.01));
      }
    });

    test('is invariant to frame position of the face', () {
      // Same face rendered on two frames at different offsets must crop to
      // identical tensors (the crop is relative to the face, not the frame).
      Float32List cropAt(int x0, int y0, int w, int h) {
        final frame = Uint8List(w * h * 3);
        final faceW = 80;
        final faceH = 100;
        for (var y = y0; y < y0 + faceH; y++) {
          for (var x = x0; x < x0 + faceW; x++) {
            final o = (y * w + x) * 3;
            frame[o] = 200;
            frame[o + 1] = 120;
            frame[o + 2] = 60;
          }
        }
        return alignFaceRgba(
          face: FaceEnrollCandidate(
            frameRgba: frame,
            width: w,
            height: h,
            boundingBox: Rect.fromLTWH(x0.toDouble(), y0.toDouble(),
                faceW.toDouble(), faceH.toDouble()),
            leftEye: (x0 + 35.0, y0 + 40.0),
            rightEye: (x0 + 55.0, y0 + 40.0),
          ),
        );
      }

      final a = cropAt(10, 10, 200, 200);
      final b = cropAt(70, 50, 200, 200);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect((a[i] - b[i]).abs(), lessThan(0.001));
      }
    });
  });

  group('l2Normalize', () {
    test('unit length for non-zero vector', () {
      final v = Float32List.fromList([3, 4]);
      l2Normalize(v);
      expect((v[0] * v[0] + v[1] * v[1] - 1).abs(), lessThan(1e-6));
    });

    test('zero vector stays zero', () {
      final v = Float32List(4);
      l2Normalize(v);
      expect(v, everyElement(0));
    });
  });

  group('embeddingCosine', () {
    test('same vector is 1.0', () {
      final a = l2Normalize(Float32List.fromList([1, 2, 3, 4]));
      expect(embeddingCosine(a, Float32List.fromList(a)), closeTo(1.0, 1e-6));
    });

    test('orthogonal vectors are 0.0', () {
      final a = Float32List.fromList([1, 0]);
      final b = Float32List.fromList([0, 1]);
      expect(embeddingCosine(a, b), closeTo(0.0, 1e-6));
    });

    test('mismatched length is 0.0', () {
      expect(embeddingCosine(Float32List(3), Float32List(4)), 0.0);
    });
  });
}