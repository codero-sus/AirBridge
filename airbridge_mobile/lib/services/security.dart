import 'dart:convert';

import 'package:crypto/crypto.dart' show Hmac, sha256;

final RegExp _sha256HexPattern = RegExp(r'^[0-9a-fA-F]{64}$');

String hmacSha256Hex(String secret, List<int> bytes) =>
    Hmac(sha256, utf8.encode(secret)).convert(bytes).toString();

String hmacTextHex(String secret, String text) =>
    hmacSha256Hex(secret, utf8.encode(text));

bool verifyHmacSha256Hex(String secret, List<int> bytes, String? signature) {
  if (signature == null ||
      signature.length != 64 ||
      !_sha256HexPattern.hasMatch(signature)) {
    return false;
  }
  final expected = hmacSha256Hex(secret, bytes);
  final normalizedSignature = signature.toLowerCase();
  var difference = 0;
  for (var index = 0; index < expected.length; index++) {
    difference |=
        expected.codeUnitAt(index) ^ normalizedSignature.codeUnitAt(index);
  }
  return difference == 0;
}
