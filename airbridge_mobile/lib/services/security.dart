import 'dart:convert';

import 'package:crypto/crypto.dart' show Hmac, sha256;

String hmacSha256Hex(String secret, List<int> bytes) =>
    Hmac(sha256, utf8.encode(secret)).convert(bytes).toString();

String hmacTextHex(String secret, String text) =>
    hmacSha256Hex(secret, utf8.encode(text));

bool verifyHmacSha256Hex(String secret, List<int> bytes, String? signature) {
  if (signature == null || signature.length != 64) return false;
  final expected = hmacSha256Hex(secret, bytes);
  var difference = 0;
  for (var index = 0; index < expected.length; index++) {
    difference |= expected.codeUnitAt(index) ^ signature.codeUnitAt(index);
  }
  return difference == 0;
}
