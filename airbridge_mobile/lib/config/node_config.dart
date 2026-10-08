import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

class NodeConfig {
  NodeConfig._({
    required this.deviceId,
    required this.deviceName,
    required this.supportDirectory,
    required this.messageDirectory,
    required this.httpPort,
    required this.udpPort,
    required this.sharedSecret,
    required this.maxPayloadBytes,
    required this.heartbeatSeconds,
    required this.peerTimeoutSeconds,
  });

  static const String serviceType = '_airbridge._tcp.local.';
  static const int protocolVersion = 1;

  static const int _httpPort = int.fromEnvironment(
    'AIRBRIDGE_HTTP_PORT',
    defaultValue: 8765,
  );
  static const int _udpPort = int.fromEnvironment(
    'AIRBRIDGE_UDP_PORT',
    defaultValue: 47660,
  );
  static const int _maxPayloadBytes = int.fromEnvironment(
    'AIRBRIDGE_MAX_PAYLOAD_BYTES',
    defaultValue: 1048576,
  );
  static const int _heartbeatSeconds = int.fromEnvironment(
    'AIRBRIDGE_HEARTBEAT_SECONDS',
    defaultValue: 3,
  );
  static const int _peerTimeoutSeconds = int.fromEnvironment(
    'AIRBRIDGE_PEER_TIMEOUT_SECONDS',
    defaultValue: 12,
  );
  static const String _configuredSecret = String.fromEnvironment(
    'AIRBRIDGE_SHARED_SECRET',
    defaultValue: '',
  );
  static const String _configuredName = String.fromEnvironment(
    'AIRBRIDGE_DEVICE_NAME',
    defaultValue: '',
  );

  final String deviceId;
  final String deviceName;
  final Directory supportDirectory;
  final Directory messageDirectory;
  final int httpPort;
  final int udpPort;
  final String sharedSecret;
  final int maxPayloadBytes;
  final int heartbeatSeconds;
  final int peerTimeoutSeconds;

  bool get hasSharedSecret => sharedSecret.isNotEmpty;

  static Future<NodeConfig> load() async {
    _validatePort('AIRBRIDGE_HTTP_PORT', _httpPort);
    _validatePort('AIRBRIDGE_UDP_PORT', _udpPort);
    if (_maxPayloadBytes < 1024 || _maxPayloadBytes > 16 * 1024 * 1024) {
      throw StateError('AIRBRIDGE_MAX_PAYLOAD_BYTES must be between 1 KiB and 16 MiB.');
    }
    if (_heartbeatSeconds < 1 || _peerTimeoutSeconds <= _heartbeatSeconds) {
      throw StateError('Peer timeout must be greater than the heartbeat interval.');
    }

    final appSupport = await getApplicationSupportDirectory();
    final nodeDirectory = Directory('${appSupport.path}${Platform.pathSeparator}airbridge');
    await nodeDirectory.create(recursive: true);
    final identityFile = File(
      '${nodeDirectory.path}${Platform.pathSeparator}device-id',
    );

    var deviceId = '';
    try {
      final storedId = (await identityFile.readAsString()).trim();
      if (_isUuid(storedId)) deviceId = storedId;
    } on FileSystemException {
      // Create a persistent identity on first launch.
    }
    if (deviceId.isEmpty) {
      deviceId = _newUuidV4();
      final temporary = File('${identityFile.path}.tmp');
      await temporary.writeAsString(deviceId, flush: true);
      if (await identityFile.exists()) await identityFile.delete();
      await temporary.rename(identityFile.path);
    }

    var deviceName = _configuredName.trim();
    if (deviceName.isEmpty) {
      try {
        deviceName = Platform.localHostname.trim();
      } on UnsupportedError {
        deviceName = '';
      }
    }
    if (deviceName.isEmpty) deviceName = 'Airbridge node';
    if (deviceName.length > 64) deviceName = deviceName.substring(0, 64);

    final messageDirectory = Directory(
      '${nodeDirectory.path}${Platform.pathSeparator}messages',
    );
    await messageDirectory.create(recursive: true);

    return NodeConfig._(
      deviceId: deviceId,
      deviceName: deviceName,
      supportDirectory: nodeDirectory,
      messageDirectory: messageDirectory,
      httpPort: _httpPort,
      udpPort: _udpPort,
      sharedSecret: _configuredSecret,
      maxPayloadBytes: _maxPayloadBytes,
      heartbeatSeconds: _heartbeatSeconds,
      peerTimeoutSeconds: _peerTimeoutSeconds,
    );
  }

  static void _validatePort(String name, int port) {
    if (port < 1024 || port > 65535) {
      throw StateError('$name must be between 1024 and 65535.');
    }
  }

  static bool _isUuid(String value) => RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
      ).hasMatch(value);

  static String _newUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
