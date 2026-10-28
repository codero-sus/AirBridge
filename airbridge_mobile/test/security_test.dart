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

    test('accepts uppercase hex without weakening the digest comparison', () {
      final signature = hmacSha256Hex(secret, body).toUpperCase();
      expect(verifyHmacSha256Hex(secret, body, signature), isTrue);
    });

    test('rejects changed bytes and malformed signatures', () {
      final signature = hmacSha256Hex(secret, body);
      expect(
        verifyHmacSha256Hex(secret, utf8.encode('{"payload":"changed"}'), signature),
        isFalse,
      );
      expect(verifyHmacSha256Hex(secret, body, 'abc'), isFalse);
      expect(verifyHmacSha256Hex(secret, body, List.filled(64, 'z').join()), isFalse);
      expect(verifyHmacSha256Hex(secret, body, '$signature\n'), isFalse);
      expect(verifyHmacSha256Hex(secret, body, null), isFalse);
    });
  });

  group('peer transport encryption', () {
    const secret = 'a-qr-paired-secret-with-256-bits-of-entropy';
    const context = 'airbridge-test:sender:recipient:message-1';

    test('seals and opens a payload with AES-256-GCM', () async {
      final cleartext = utf8.encode('{"message":"private"}');
      final sealed = await sealPeerPayload(
        secret: secret,
        cleartext: cleartext,
        associatedData: context,
      );

      expect(sealed['algorithm'], 'AES-256-GCM');
      expect(sealed.containsKey('payload'), isFalse);
      expect(
        await openPeerPayload(
          secret: secret,
          sealed: Map<String, dynamic>.from(sealed),
          associatedData: context,
        ),
        cleartext,
      );
    });

    test('rejects a changed context or authentication tag', () async {
      final sealed = await sealPeerPayload(
        secret: secret,
        cleartext: utf8.encode('authenticated content'),
        associatedData: context,
      );
      await expectLater(
        openPeerPayload(
          secret: secret,
          sealed: Map<String, dynamic>.from(sealed),
          associatedData: '$context:other-recipient',
        ),
        throwsA(anything),
      );

      final tampered = Map<String, dynamic>.from(sealed)
        ..['mac'] = base64Encode(List<int>.filled(16, 0));
      await expectLater(
        openPeerPayload(
          secret: secret,
          sealed: tampered,
          associatedData: context,
        ),
        throwsA(anything),
      );
    });
  });
}
