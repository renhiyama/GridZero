import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/movement_gate.dart';

void main() {
  group('MovementGate', () {
    test('reports moving until the window fills', () {
      final g = MovementGate();
      expect(g.moving, isTrue);
      for (var i = 0; i < g.window - 1; i++) {
        g.feed(0, 0, 9.81);
      }
      expect(g.moving, isTrue); // window not full yet
      g.feed(0, 0, 9.81);
      expect(g.moving, isFalse); // full window, all still
    });

    test('still phone reads below the threshold', () {
      final g = MovementGate();
      for (var i = 0; i < g.window; i++) {
        g.feed(0, 0, 9.81 + 0.01 * ((i % 2) - 0.5));
      }
      expect(g.moving, isFalse);
    });

    test('slow motion trips the gate', () {
      final g = MovementGate();
      // ±0.5 m/s² swing on a walking scale -> variance 0.25 above the 0.1 floor.
      for (var i = 0; i < g.window; i++) {
        g.feed(0, 0, 9.81 + (i.isEven ? -0.5 : 0.5));
      }
      expect(g.moving, isTrue);
    });

    test('rising edge fires once per motion episode', () {
      final g = MovementGate();
      for (var i = 0; i < g.window; i++) {
        g.feed(0, 0, 9.81);
      }
      expect(g.moving, isFalse);

      // Sustained strong motion pushes the 25-window variance through the
      // hysteresis band (enter 0.2); the crossing is a single rising edge
      // for the whole episode.
      var edges = 0;
      for (var i = 0; i < 10; i++) {
        if (g.feed(5, 5, 5)) edges++;
      }
      expect(edges, 1);
      expect(g.feed(5, 5, 5), isFalse); // still moving: no re-fire

      for (var i = 0; i < g.window; i++) {
        g.feed(0, 0, 9.81); // settle back to still
      }
      edges = 0;
      for (var i = 0; i < 10; i++) {
        if (g.feed(5, 5, 5)) edges++;
      }
      expect(edges, 1); // new episode re-arms
    });

    test('hand tremor between the two thresholds never fires an edge', () {
      final g = MovementGate();
      // Tremor variance ~0.05-0.1: above exit(0.1)? no - below move(0.2)
      // while still, so a held phone stays still and GPS stays quiet.
      for (var i = 0; i < g.window; i++) {
        g.feed(0, 0, 9.81);
      }
      expect(g.moving, isFalse);
      var edges = 0;
      for (var i = 0; i < g.window * 4; i++) {
        // ±0.08 swing -> variance ~0.02; plus slow drift under the floor.
        g.feed(0.04 * (i.isEven ? -1 : 1), 0, 9.81 + 0.03 * ((i % 3) - 1));
        if (g.feed(0, 0, 9.81)) edges++;
      }
      expect(edges, 0);
      expect(g.moving, isFalse);
    });

    test('window size is honored', () {
      final g = MovementGate(window: 4, stillVariance: 0.1);
      for (var i = 0; i < 4; i++) {
        g.feed(0, 0, 9.81);
      }
      expect(g.moving, isFalse);
      g.feed(0, 0, 11.0); // one strong outlier in a 4-window
      expect(g.moving, isTrue);
    });
  });
}