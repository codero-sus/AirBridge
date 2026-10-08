import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:airbridge_mobile/services/security.dart';

void main() {
  group('HMAC helpers', () {
    const secret = 'correct horse battery staple';
    final body = utf8.encode('{"payload":"hello"}');

    test('accepts a signature over the exact request bytes', () {
      final signature = hmacSha256Hex(secret, body);
      expect(verifyHmacSha256Hex(secret, body, signature), isTrue);
    });

    test('rejects changed bytes and malformed signatures', () {
      final signature = hmacSha256Hex(secret, body);
      expect(
        verifyHmacSha256Hex(secret, utf8.encode('{"payload":"changed"}'), signature),
        isFalse,
      );
      expect(verifyHmacSha256Hex(secret, body, 'abc'), isFalse);
      expect(verifyHmacSha256Hex(secret, body, null), isFalse);
    });
  });
}
