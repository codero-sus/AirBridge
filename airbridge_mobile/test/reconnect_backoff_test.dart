import 'dart:math';

import 'package:airbridge_mobile/services/reconnect_backoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses bounded exponential retry delays', () {
    final backoff = ReconnectBackoff(
      random: Random(7),
      jitterMilliseconds: 0,
    );

    expect(
      List<int>.generate(7, (index) => backoff.delayForAttempt(index + 1).inSeconds),
      <int>[1, 2, 4, 8, 16, 30, 30],
    );
  });

  test('adds bounded jitter and rejects invalid attempt numbers', () {
    final backoff = ReconnectBackoff(random: Random(17));
    final delay = backoff.delayForAttempt(1);

    expect(delay.inMilliseconds, inInclusiveRange(1000, 1500));
    expect(() => backoff.delayForAttempt(0), throwsArgumentError);
  });
}
