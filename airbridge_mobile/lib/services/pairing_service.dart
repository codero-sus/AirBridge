import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

import '../config/node_config.dart';
import 'security.dart';

const Duration _invitationLifetime = Duration(minutes: 5);
const int _maxPairingAttempts = 5;
const int _maxTrustedPeers = 256;
const int _pairingBodyLimit = 16 * 1024;
final RegExp _hexTokenPattern = RegExp(r'^[0-9a-fA-F]{64}$');
final RegExp _pairingIdPattern = RegExp(r'^[0-9a-fA-F]{32}$');
final RegExp _deviceIdPattern = RegExp(r'^[A-Za-z0-9._:-]{1,64}$');
final RegExp _controlCharacterPattern = RegExp(r'[\x00-\x1F\x7F]');

class PairingException implements Exception {
  const PairingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An expiring QR invitation. The QR carries a random 256-bit one-time key;
/// the six-digit code is a short authentication string to compare on both
/// devices, not a six-digit password sent over the network.
class PairingInvitation {
  const PairingInvitation({
    required this.pairingId,
    required this.hostAddress,
    required this.httpPort,
    required this.udpPort,
    required this.hostDeviceId,
    required this.hostDeviceName,
    required this.secret,
    required this.expiresAt,
    required this.sharedSecretFingerprint,
  });

  final String pairingId;
  final String hostAddress;
  final int httpPort;
  final int udpPort;
  final String hostDeviceId;
  final String hostDeviceName;
  final String secret;
  final DateTime expiresAt;
  final String? sharedSecretFingerprint;

  String get qrPayload => Uri(
        scheme: 'airbridge',
        host: 'pair',
        queryParameters: <String, String>{
          'v': '1',
          'id': pairingId,
          'host': hostAddress,
          'http': '$httpPort',
          'udp': '$udpPort',
          'device': hostDeviceId,
          'name': hostDeviceName,
          'key': secret,
          'mesh': sharedSecretFingerprint ?? 'none',
          'exp': '${expiresAt.toUtc().millisecondsSinceEpoch}',
        },
      ).toString();

  String get verificationCode {
    final digest = hmacTextHex(
      secret,
      'airbridge-pair-code-v1:$pairingId:$hostDeviceId',
    );
    final value = BigInt.parse(digest.substring(0, 12), radix: 16) %
        BigInt.from(1000000);
    return value.toString().padLeft(6, '0');
  }

  String get formattedVerificationCode =>
      '${verificationCode.substring(0, 3)} ${verificationCode.substring(3)}';

  bool get isExpired => !DateTime.now().toUtc().isBefore(expiresAt);

  static PairingInvitation parse(String payload) {
    if (payload.length > 2048) {
      throw const FormatException('The QR pairing invitation is too large.');
    }
    final uri = Uri.tryParse(payload.trim());
    if (uri == null ||
        uri.scheme != 'airbridge' ||
        uri.host != 'pair' ||
        uri.path.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.queryParameters['v'] != '1') {
      throw const FormatException('This is not a valid Airbridge pairing QR.');
    }

    final pairingId = uri.queryParameters['id'] ?? '';
    final host = uri.queryParameters['host'] ?? '';
    final httpPort = int.tryParse(uri.queryParameters['http'] ?? '');
    final udpPort = int.tryParse(uri.queryParameters['udp'] ?? '');
    final deviceId = uri.queryParameters['device'] ?? '';
    final deviceName = uri.queryParameters['name']?.trim() ?? '';
    final key = uri.queryParameters['key'] ?? '';
    final meshFingerprint = uri.queryParameters['mesh'];
    final expiration = int.tryParse(uri.queryParameters['exp'] ?? '');
    final address = InternetAddress.tryParse(host);

    if (!_pairingIdPattern.hasMatch(pairingId) ||
        address == null ||
        address.type != InternetAddressType.IPv4 ||
        httpPort == null ||
        httpPort < 1024 ||
        httpPort > 65535 ||
        udpPort == null ||
        udpPort < 1024 ||
        udpPort > 65535 ||
        !_deviceIdPattern.hasMatch(deviceId) ||
        deviceName.isEmpty ||
        deviceName.length > 64 ||
        _controlCharacterPattern.hasMatch(deviceName) ||
        !_hexTokenPattern.hasMatch(key) ||
        meshFingerprint == null ||
        (meshFingerprint != 'none' && !_hexTokenPattern.hasMatch(meshFingerprint)) ||
        expiration == null) {
      throw const FormatException('The Airbridge pairing QR is incomplete or invalid.');
    }

    final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiration, isUtc: true);
    if (!DateTime.now().toUtc().isBefore(expiresAt)) {
      throw const FormatException('This pairing QR has expired. Ask the other device for a new one.');
    }

    return PairingInvitation(
      pairingId: pairingId.toLowerCase(),
      hostAddress: host,
      httpPort: httpPort,
      udpPort: udpPort,
      hostDeviceId: deviceId,
      hostDeviceName: deviceName,
      secret: key.toLowerCase(),
      expiresAt: expiresAt,
      sharedSecretFingerprint:
          meshFingerprint == 'none' ? null : meshFingerprint.toLowerCase(),
    );
  }
}

class TrustedPeer {
  const TrustedPeer({
    required this.deviceId,
    required this.deviceName,
    required this.secret,
    required this.httpPort,
    required this.udpPort,
    required this.pairedAt,
  });

  final String deviceId;
  final String deviceName;
  final String secret;
  final int httpPort;
  final int udpPort;
  final DateTime pairedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'deviceId': deviceId,
        'deviceName': deviceName,
        'secret': secret,
        'httpPort': httpPort,
        'udpPort': udpPort,
        'pairedAt': pairedAt.toUtc().toIso8601String(),
      };

  static TrustedPeer? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final deviceId = value['deviceId'];
    final deviceName = value['deviceName'];
    final secret = value['secret'];
    final httpPort = value['httpPort'];
    final udpPort = value['udpPort'];
    final pairedAtText = value['pairedAt'];
    if (deviceId is! String ||
        !_deviceIdPattern.hasMatch(deviceId) ||
        deviceName is! String ||
        deviceName.isEmpty ||
        deviceName.length > 64 ||
        _controlCharacterPattern.hasMatch(deviceName) ||
        secret is! String ||
        !_hexTokenPattern.hasMatch(secret) ||
        httpPort is! int ||
        httpPort < 1024 ||
        httpPort > 65535 ||
        udpPort is! int ||
        udpPort < 1024 ||
        udpPort > 65535 ||
        pairedAtText is! String) {
      return null;
    }
    final pairedAt = DateTime.tryParse(pairedAtText);
    if (pairedAt == null) return null;
    return TrustedPeer(
      deviceId: deviceId,
      deviceName: deviceName,
      secret: secret.toLowerCase(),
      httpPort: httpPort,
      udpPort: udpPort,
      pairedAt: pairedAt.toUtc(),
    );
  }
}

class PairingService {
  PairingService({
    required this.config,
    required this.onPeerTrusted,
  }) : _storeFile = File(
          '${config.supportDirectory.path}${Platform.pathSeparator}trusted-peers.json',
        );

  final NodeConfig config;
  final void Function(TrustedPeer peer, String remoteHost) onPeerTrusted;
  final File _storeFile;
  final Map<String, TrustedPeer> _trustedPeers = <String, TrustedPeer>{};
  PairingInvitation? _activeInvitation;
  int _failedAttempts = 0;
  bool _loaded = false;

  List<TrustedPeer> get trustedPeers =>
      List<TrustedPeer>.unmodifiable(_trustedPeers.values);

  String? secretForPeer(String deviceId) => _trustedPeers[deviceId]?.secret;

  bool isInvitationActive(PairingInvitation invitation) =>
      _activeInvitation?.pairingId == invitation.pairingId && !invitation.isExpired;

  Future<void> load() async {
    if (_loaded) return;
    await config.supportDirectory.create(recursive: true);
    if (await _storeFile.exists()) {
      final decoded = jsonDecode(await _storeFile.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['peers'] is! List<dynamic>) {
        throw const FormatException('The saved Airbridge trusted-device list is invalid.');
      }
      for (final raw in decoded['peers']! as List<dynamic>) {
        final peer = TrustedPeer.tryParse(raw);
        if (peer != null && peer.deviceId != config.deviceId) {
          _trustedPeers[peer.deviceId] = peer;
        }
      }
    }
    _loaded = true;
  }

  void cancelInvitation(PairingInvitation invitation) {
    if (_activeInvitation?.pairingId == invitation.pairingId) {
      _activeInvitation = null;
      _failedAttempts = 0;
    }
  }

  void cancelActiveInvitation() {
    _activeInvitation = null;
    _failedAttempts = 0;
  }

  Future<PairingInvitation> createInvitation({
    required String hostAddress,
    required int httpPort,
    required int udpPort,
    DateTime? now,
  }) async {
    await _ensureLoaded();
    final address = InternetAddress.tryParse(hostAddress);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        httpPort < 1024 ||
        httpPort > 65535 ||
        udpPort < 1024 ||
        udpPort > 65535) {
      throw const PairingException('The node does not have a usable local network address.');
    }
    final issuedAt = (now ?? DateTime.now()).toUtc();
    final invitation = PairingInvitation(
      pairingId: _randomHex(16),
      hostAddress: hostAddress,
      httpPort: httpPort,
      udpPort: udpPort,
      hostDeviceId: config.deviceId,
      hostDeviceName: _safeDeviceName(config.deviceName),
      secret: _randomHex(32),
      expiresAt: issuedAt.add(_invitationLifetime),
      sharedSecretFingerprint: config.hasSharedSecret
          ? _sharedSecretFingerprint(config.sharedSecret)
          : null,
    );
    _activeInvitation = invitation;
    _failedAttempts = 0;
    return invitation;
  }

  Future<(int, Map<String, Object?>)> handleClaim(
    Map<String, dynamic> input,
    String remoteHost,
  ) async {
    await _ensureLoaded();
    final invitation = _activeInvitation;
    if (invitation == null || invitation.isExpired) {
      _activeInvitation = null;
      return (410, <String, Object?>{
        'error': 'The pairing invitation expired or was already used. Create a new QR.',
      });
    }
    if (_failedAttempts >= _maxPairingAttempts) {
      _activeInvitation = null;
      return (429, <String, Object?>{
        'error': 'Too many invalid pairing attempts. Create a new QR.',
      });
    }

    final pairingId = input['pairingId'];
    if (pairingId != invitation.pairingId) {
      return (401, <String, Object?>{'error': 'Pairing request was not authorized.'});
    }

    final deviceId = input['deviceId'];
    final deviceName = input['deviceName'];
    final httpPort = input['httpPort'];
    final udpPort = input['udpPort'];
    final nonce = input['nonce'];
    final proof = input['proof'];
    if (input['version'] != 1 ||
        deviceId is! String ||
        !_deviceIdPattern.hasMatch(deviceId) ||
        deviceId == config.deviceId ||
        deviceName is! String ||
        deviceName.trim().isEmpty ||
        deviceName.trim().length > 64 ||
        _controlCharacterPattern.hasMatch(deviceName) ||
        httpPort is! int ||
        httpPort < 1024 ||
        httpPort > 65535 ||
        udpPort is! int ||
        udpPort < 1024 ||
        udpPort > 65535 ||
        nonce is! String ||
        !_hexTokenPattern.hasMatch(nonce) ||
        proof is! String) {
      return (400, <String, Object?>{'error': 'The pairing request is malformed.'});
    }

    _failedAttempts++;
    final normalizedName = deviceName.trim();
    final claimBytes = utf8.encode(
      jsonEncode(_claimFields(
        pairingId: invitation.pairingId,
        deviceId: deviceId,
        deviceName: normalizedName,
        httpPort: httpPort,
        udpPort: udpPort,
        nonce: nonce.toLowerCase(),
      )),
    );
    if (!verifyHmacSha256Hex(invitation.secret, claimBytes, proof)) {
      if (_failedAttempts >= _maxPairingAttempts) _activeInvitation = null;
      return (401, <String, Object?>{
        'error': 'Pairing proof was invalid. The QR will lock after five attempts.',
      });
    }

    if (!_trustedPeers.containsKey(deviceId) &&
        _trustedPeers.length >= _maxTrustedPeers) {
      return (503, <String, Object?>{'error': 'This node has reached its pairing limit.'});
    }

    // Consume the one-time invitation before the first asynchronous write so
    // parallel claim requests cannot both pair using the same QR.
    _activeInvitation = null;
    final ids = <String>[config.deviceId, deviceId]..sort();
    final peerSecret = hmacTextHex(
      invitation.secret,
      'airbridge-peer-key-v1:${invitation.pairingId}:${ids.join(':')}',
    );
    final peer = TrustedPeer(
      deviceId: deviceId,
      deviceName: normalizedName,
      secret: peerSecret,
      httpPort: httpPort,
      udpPort: udpPort,
      pairedAt: DateTime.now().toUtc(),
    );
    final aad = _responseAad(invitation.pairingId, config.deviceId, deviceId);
    final algorithm = AesGcm.with256bits();
    final responseKey = _responseKey(invitation.secret);
    final responseNonce = algorithm.newNonce();
    final responsePlaintext = utf8.encode(jsonEncode(<String, Object?>{
      'pairingId': invitation.pairingId,
      'hostDeviceId': config.deviceId,
      'hostDeviceName': invitation.hostDeviceName,
      'hostHttpPort': invitation.httpPort,
      'hostUdpPort': invitation.udpPort,
      'clientDeviceId': deviceId,
      'secret': peerSecret,
    }));
    final encrypted = await algorithm.encrypt(
      responsePlaintext,
      secretKey: SecretKey(responseKey),
      nonce: responseNonce,
      aad: aad,
    );
    final previous = _trustedPeers[deviceId];
    _trustedPeers[deviceId] = peer;
    try {
      await _persist();
    } on Object {
      if (previous == null) {
        _trustedPeers.remove(deviceId);
      } else {
        _trustedPeers[deviceId] = previous;
      }
      return (500, <String, Object?>{'error': 'Could not save the trusted-device record.'});
    }

    onPeerTrusted(peer, remoteHost);
    return (201, <String, Object?>{
      'pairingId': invitation.pairingId,
      'hostDeviceId': config.deviceId,
      'clientDeviceId': deviceId,
      'nonce': base64Encode(encrypted.nonce),
      'ciphertext': base64Encode(encrypted.cipherText),
      'mac': base64Encode(encrypted.mac.bytes),
    });
  }

  Future<TrustedPeer> joinInvitation({
    required String qrPayload,
    required int httpPort,
    required int udpPort,
  }) async {
    await _ensureLoaded();
    final invitation = PairingInvitation.parse(qrPayload);
    if (invitation.hostDeviceId == config.deviceId) {
      throw const PairingException('You cannot pair this device with itself.');
    }
    final localFingerprint = config.hasSharedSecret
        ? _sharedSecretFingerprint(config.sharedSecret)
        : null;
    if (invitation.sharedSecretFingerprint != localFingerprint) {
      throw const PairingException(
        'Both devices must use the same AIRBRIDGE_SHARED_SECRET setting. Rebuild both with the same key, or omit it on both.',
      );
    }
    if (!_trustedPeers.containsKey(invitation.hostDeviceId) &&
        _trustedPeers.length >= _maxTrustedPeers) {
      throw const PairingException('This node has reached its pairing limit.');
    }

    final nonce = _randomHex(32);
    final fields = _claimFields(
      pairingId: invitation.pairingId,
      deviceId: config.deviceId,
      deviceName: _safeDeviceName(config.deviceName),
      httpPort: httpPort,
      udpPort: udpPort,
      nonce: nonce,
    );
    final proof = hmacSha256Hex(
      invitation.secret,
      utf8.encode(jsonEncode(fields)),
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client
          .postUrl(Uri(
            scheme: 'http',
            host: invitation.hostAddress,
            port: invitation.httpPort,
            path: '/pair/claim',
          ))
          .timeout(const Duration(seconds: 6));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(<String, Object?>{
        ...fields,
        'proof': proof,
      }));
      final response = await request.close().timeout(const Duration(seconds: 8));
      final responseBytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (responseBytes.length + chunk.length > _pairingBodyLimit) {
          throw const PairingException('The pairing response exceeded the size limit.');
        }
        responseBytes.add(chunk);
      }
      final responseText = utf8.decode(responseBytes.takeBytes());
      final decoded = jsonDecode(responseText);
      if (response.statusCode != 201) {
        final message = decoded is Map<String, dynamic> && decoded['error'] is String
            ? decoded['error']! as String
            : 'The other device rejected the pairing request.';
        throw PairingException(message);
      }
      if (decoded is! Map<String, dynamic>) {
        throw const PairingException('The pairing response was invalid.');
      }
      final secret = await _decryptResponse(decoded, invitation, config.deviceId);
      final peer = TrustedPeer(
        deviceId: invitation.hostDeviceId,
        deviceName: invitation.hostDeviceName,
        secret: secret,
        httpPort: invitation.httpPort,
        udpPort: invitation.udpPort,
        pairedAt: DateTime.now().toUtc(),
      );
      _trustedPeers[peer.deviceId] = peer;
      await _persist();
      onPeerTrusted(peer, invitation.hostAddress);
      return peer;
    } on TimeoutException {
      throw const PairingException('The pairing request timed out. Check the local network and try again.');
    } on SocketException catch (error) {
      throw PairingException('Could not reach ${invitation.hostAddress}: ${error.message}');
    } on FormatException {
      throw const PairingException('The pairing response was not valid Airbridge data.');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _decryptResponse(
    Map<String, dynamic> response,
    PairingInvitation invitation,
    String localDeviceId,
  ) async {
    final responsePairingId = response['pairingId'];
    final responseHostId = response['hostDeviceId'];
    final responseClientId = response['clientDeviceId'];
    final nonceText = response['nonce'];
    final ciphertextText = response['ciphertext'];
    final macText = response['mac'];
    if (responsePairingId != invitation.pairingId ||
        responseHostId != invitation.hostDeviceId ||
        responseClientId != localDeviceId ||
        nonceText is! String ||
        ciphertextText is! String ||
        ciphertextText.length > 8192 ||
        macText is! String) {
      throw const PairingException('The pairing response did not match this invitation.');
    }
    try {
      final box = SecretBox(
        base64Decode(ciphertextText),
        nonce: base64Decode(nonceText),
        mac: Mac(base64Decode(macText)),
      );
      final clearText = await AesGcm.with256bits().decrypt(
        box,
        secretKey: SecretKey(_responseKey(invitation.secret)),
        aad: _responseAad(
          invitation.pairingId,
          invitation.hostDeviceId,
          localDeviceId,
        ),
      );
      final decoded = jsonDecode(utf8.decode(clearText));
      if (decoded is! Map<String, dynamic> ||
          decoded['pairingId'] != invitation.pairingId ||
          decoded['hostDeviceId'] != invitation.hostDeviceId ||
          decoded['clientDeviceId'] != localDeviceId ||
          decoded['hostDeviceName'] != invitation.hostDeviceName ||
          decoded['hostHttpPort'] != invitation.httpPort ||
          decoded['hostUdpPort'] != invitation.udpPort ||
          decoded['secret'] is! String ||
          !_hexTokenPattern.hasMatch(decoded['secret']! as String)) {
        throw const PairingException('The encrypted pairing confirmation was invalid.');
      }
      return (decoded['secret']! as String).toLowerCase();
    } on SecretBoxAuthenticationError {
      throw const PairingException('Pairing confirmation failed authentication. Rescan a fresh QR.');
    } on FormatException {
      throw const PairingException('The encrypted pairing response was malformed.');
    }
  }

  Future<void> _ensureLoaded() async {
    if (!_loaded) await load();
  }

  Future<void> _persist() async {
    final contents = jsonEncode(<String, Object?>{
      'version': 1,
      'peers': _trustedPeers.values.map((peer) => peer.toJson()).toList(),
    });
    final temporary = File('${_storeFile.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    if (await _storeFile.exists()) await _storeFile.delete();
    await temporary.rename(_storeFile.path);
  }
}

String _safeDeviceName(String value) {
  final normalized = value.replaceAll(_controlCharacterPattern, ' ').trim();
  if (normalized.isEmpty) return 'Airbridge device';
  return normalized.length <= 64 ? normalized : normalized.substring(0, 64).trim();
}

Map<String, Object?> _claimFields({
  required String pairingId,
  required String deviceId,
  required String deviceName,
  required int httpPort,
  required int udpPort,
  required String nonce,
}) =>
    <String, Object?>{
      'version': 1,
      'pairingId': pairingId,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'httpPort': httpPort,
      'udpPort': udpPort,
      'nonce': nonce,
    };

String _sharedSecretFingerprint(String secret) =>
    sha256.convert(utf8.encode(secret)).toString();

List<int> _responseKey(String invitationSecret) => sha256
    .convert(utf8.encode('airbridge-pair-response-key-v1:$invitationSecret'))
    .bytes;

List<int> _responseAad(String pairingId, String hostId, String clientId) =>
    utf8.encode('airbridge-pair-response-v1:$pairingId:$hostId:$clientId');

String _randomHex(int byteCount) {
  final random = Random.secure();
  return List<int>.generate(byteCount, (_) => random.nextInt(256))
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
