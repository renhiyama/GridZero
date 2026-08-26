import 'dart:math';

/// Still-vs-moving decision from a window of accelerometer magnitudes.
/// Pure and injectable so the heuristic is unit-testable without a sensor.
///
/// Schmitt trigger: leaving "still" requires variance above [moveVariance],
/// returning to "still" only below [stillVariance]. The gap between the two
/// absorbs hand tremor, which produces small but rapid variance spikes that
/// would otherwise flap the gate and spam GPS fixes.
class MovementGate {
  MovementGate({
    this.window = 25,
    this.stillVariance = 0.1,
    this.moveVariance = 0.15,
  }) : _mag = List<double>.filled(window, 0);

  /// Sample window (5s at a 5Hz sensor).
  final int window;

  /// Variance floor (m/s²)² below which a moving gate returns to still.
  final double stillVariance;

  /// Variance required to leave "still" and start an episode. Deliberately
  /// higher than [stillVariance]: hand-held tremor sits between the two.
  final double moveVariance;

  final List<double> _mag;
  int _count = 0;
  int _idx = 0;
  bool _moving = true;

  double _variance() {
    var mean = 0.0;
    for (final m in _mag) {
      mean += m;
    }
    mean /= _count;
    var variance = 0.0;
    for (final m in _mag) {
      final d = m - mean;
      variance += d * d;
    }
    return variance / _count;
  }

  /// Applies the hysteresis to the current window and returns the state.
  /// Mutates [_moving]: enter "moving" above [moveVariance], drop back below
  /// [stillVariance], hold anywhere in between.
  bool get moving {
    if (_count < window) return true;
    final v = _variance();
    _moving = _moving ? v >= stillVariance : v >= moveVariance;
    return _moving;
  }

  /// Feeds one accelerometer reading; returns true on the rising edge
  /// (moving now, still before) so callers fire GPS exactly once per motion
  /// episode. Hysteresis keeps micro-jitter from re-arming mid-episode.
  bool feed(double x, double y, double z) {
    _mag[_idx] = sqrt(x * x + y * y + z * z);
    _idx = (_idx + 1) % window;
    if (_count < window) {
      _count++;
      return false; // window filling: no edges until it is full
    }
    final now = moving; // runs the hysteresis for this window
    final rising = now && !_prevMoving;
    _prevMoving = now;
    return rising;
  }

  bool _prevMoving = true;
}
