import 'dart:math';

/// Bounded exponential backoff with small random jitter for peer reconnects.
class ReconnectBackoff {
  ReconnectBackoff({
    Random? random,
    this.maxBaseSeconds = 30,
    this.jitterMilliseconds = 500,
  })  : _random = random ?? Random.secure() {
    if (maxBaseSeconds < 1 || jitterMilliseconds < 0) {
      throw ArgumentError('Reconnect backoff limits must be non-negative.');
    }
  }

  final Random _random;
  final int maxBaseSeconds;
  final int jitterMilliseconds;

  Duration delayForAttempt(int attempt) {
    if (attempt < 1) throw ArgumentError.value(attempt, 'attempt', 'Must be positive.');
    final exponent = min(attempt - 1, 5).toInt();
    final baseSeconds = min(maxBaseSeconds, 1 << exponent).toInt();
    final jitter = _random.nextInt(jitterMilliseconds + 1);
    return Duration(seconds: baseSeconds, milliseconds: jitter);
  }
}
