import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:cryptography/cryptography.dart';

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

/// Encrypts a peer-to-peer payload using the QR-paired secret. The caller must
/// use a unique, protocol-specific [associatedData] value for every message.
/// Pairwise key derivation deliberately uses a different domain from HMAC auth.
Future<Map<String, Object?>> sealPeerPayload({
  required String secret,
  required List<int> cleartext,
  required String associatedData,
}) async {
  if (secret.isEmpty) {
    throw ArgumentError.value(secret, 'secret', 'A trusted peer key is required.');
  }
  final key = sha256
      .convert(utf8.encode('airbridge-peer-aes-gcm-v1:$secret'))
      .bytes;
  final cipher = AesGcm.with256bits();
  final box = await cipher.encrypt(
    cleartext,
    secretKey: SecretKey(key),
    nonce: cipher.newNonce(),
    aad: utf8.encode(associatedData),
  );
  return <String, Object?>{
    'algorithm': 'AES-256-GCM',
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode(box.cipherText),
    'mac': base64Encode(box.mac.bytes),
  };
}

/// Authenticates and decrypts a peer payload. A bad tag or mismatched context
/// is rejected by AES-GCM; callers must not fall back to cleartext.
Future<Uint8List> openPeerPayload({
  required String secret,
  required Map<String, dynamic> sealed,
  required String associatedData,
}) async {
  if (secret.isEmpty ||
      sealed['algorithm'] != 'AES-256-GCM' ||
      sealed['nonce'] is! String ||
      sealed['ciphertext'] is! String ||
      sealed['mac'] is! String) {
    throw const FormatException('The encrypted Airbridge payload is malformed.');
  }

  try {
    final key = sha256
        .convert(utf8.encode('airbridge-peer-aes-gcm-v1:$secret'))
        .bytes;
    final cipher = AesGcm.with256bits();
    final cleartext = await cipher.decrypt(
      SecretBox(
        base64Decode(sealed['ciphertext']! as String),
        nonce: base64Decode(sealed['nonce']! as String),
        mac: Mac(base64Decode(sealed['mac']! as String)),
      ),
      secretKey: SecretKey(key),
      aad: utf8.encode(associatedData),
    );
    return Uint8List.fromList(cleartext);
  } on FormatException {
    rethrow;
  } on SecretBoxAuthenticationError {
    rethrow;
  } on Object catch (error) {
    throw FormatException('Could not decrypt the Airbridge payload: $error');
  }
}

/// Creates the replay-protected headers used by signed peer HTTP requests.
/// The full encrypted body is covered by HMAC-SHA256, including the sender ID.
Map<String, String> createSignedPeerHeaders({
  required String secret,
  required String deviceId,
  required List<int> body,
  DateTime? now,
}) {
  final timestamp =
      (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
  final nonce = _newUrlSafeNonce();
  final prefix = '$timestamp.$nonce.$deviceId.';
  final bytes = <int>[...utf8.encode(prefix), ...body];
  return <String, String>{
    'X-Airbridge-Device-Id': deviceId,
    'X-Airbridge-Timestamp': '$timestamp',
    'X-Airbridge-Nonce': nonce,
    'X-Airbridge-Signature': hmacSha256Hex(secret, bytes),
  };
}

String _newUrlSafeNonce() {
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}
