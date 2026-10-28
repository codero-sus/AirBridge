import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/node_config.dart';
import '../models/peer.dart';
import 'security.dart';

typedef PeerSeenCallback = void Function(Peer peer);
typedef PeerExpiredCallback = void Function(String deviceId);
typedef DiscoveryLogCallback = void Function(String level, String message);
typedef RoleCallback = String Function();
typedef MasterIdCallback = String Function();

/// UDP broadcast discovery with periodic liveness beacons and peer expiry.
/// The JSON beacon advertises the DNS-SD service identifier, while discovery
/// itself remains broadcast-based and does not claim to publish an mDNS record.
class DiscoveryService {
  DiscoveryService({
    required this.config,
    required this.roleProvider,
    required this.masterIdProvider,
    required this.onPeerSeen,
    required this.onPeerExpired,
    required this.onLog,
  });

  final NodeConfig config;
  final RoleCallback roleProvider;
  final MasterIdCallback masterIdProvider;
  final PeerSeenCallback onPeerSeen;
  final PeerExpiredCallback onPeerExpired;
  final DiscoveryLogCallback onLog;

  final Map<String, DateTime> _lastSeen = <String, DateTime>{};
  final Set<String> _broadcastAddressStrings = <String>{};
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _expiryTimer;
  bool _stopped = false;

  Future<void> start() async {
    if (_socket != null) return;
    _stopped = false;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      config.udpPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    _broadcastAddressStrings.add('255.255.255.255');
    await _findDirectedBroadcasts();
    _subscription = socket.listen(
      (event) {
        if (event == RawSocketEvent.read) _drainDatagrams(socket);
      },
      onError: (Object error, StackTrace stack) {
        onLog('ERROR', 'UDP discovery socket error: $error');
      },
      onDone: () {
        if (!_stopped) onLog('WARN', 'UDP discovery socket closed unexpectedly.');
      },
      cancelOnError: false,
    );

    _heartbeatTimer = Timer.periodic(
      Duration(seconds: config.heartbeatSeconds),
      (_) => _sendBeacon(),
    );
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) => _expirePeers());
    _sendBeacon();
    onLog(
      'INFO',
      'UDP discovery listening on 0.0.0.0:${config.udpPort}; '
          'broadcast targets: ${_broadcastAddressStrings.length}.',
    );
  }

  Future<void> stop() async {
    _stopped = true;
    _heartbeatTimer?.cancel();
    _expiryTimer?.cancel();
    _heartbeatTimer = null;
    _expiryTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    for (final deviceId in _lastSeen.keys.toList(growable: false)) {
      onPeerExpired(deviceId);
    }
    _lastSeen.clear();
  }

  Future<void> _findDirectedBroadcasts() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final networkInterface in interfaces) {
        for (final interfaceAddress in networkInterface.addresses) {
          final octets = interfaceAddress.address
              .split('.')
              .map(int.tryParse)
              .toList(growable: false);
          final prefixLength = interfaceAddress.prefixLength;
          if (octets.length != 4 || prefixLength < 0 || prefixLength > 32 ||
              octets.any((octet) => octet == null || octet < 0 || octet > 255)) {
            continue;
          }
          final broadcast = List<int>.generate(4, (index) {
            final bitsInOctet = prefixLength - index * 8;
            final mask = bitsInOctet >= 8
                ? 0xff
                : bitsInOctet <= 0
                    ? 0
                    : (0xff << (8 - bitsInOctet)) & 0xff;
            return (octets[index]! & mask) | ((~mask) & 0xff);
          });
          _broadcastAddressStrings.add(broadcast.join('.'));
        }
      }
    } on SocketException catch (error) {
      onLog('WARN', 'Could not enumerate broadcast interfaces: $error');
    } on UnsupportedError catch (error) {
      onLog('WARN', 'Directed broadcast enumeration is unavailable: $error');
    }
  }

  void _sendBeacon() {
    final socket = _socket;
    if (_stopped || socket == null) return;
    final unsigned = <String, Object?>{
      'protocol': 'airbridge',
      'protocolVersion': NodeConfig.protocolVersion,
      'serviceType': NodeConfig.serviceType,
      'deviceId': config.deviceId,
      'deviceName': config.deviceName,
      'httpPort': config.httpPort,
      'udpPort': config.udpPort,
      'role': roleProvider(),
      'masterId': masterIdProvider(),
      'sentAt': DateTime.now().toUtc().millisecondsSinceEpoch,
    };
    final packet = Map<String, Object?>.from(unsigned);
    if (config.hasSharedSecret) {
      packet['signature'] = hmacSha256Hex(
        config.sharedSecret,
        utf8.encode(jsonEncode(unsigned)),
      );
    }
    final bytes = utf8.encode(jsonEncode(packet));
    for (final address in _broadcastAddressStrings) {
      try {
        socket.send(bytes, InternetAddress(address), config.udpPort);
      } on SocketException catch (error) {
        onLog('WARN', 'Could not broadcast discovery beacon to $address: $error');
      }
    }
  }

  void _drainDatagrams(RawDatagramSocket socket) {
    Datagram? datagram;
    var processed = 0;
    while (processed < 64 && (datagram = socket.receive()) != null) {
      processed++;
      final current = datagram!;
      if (current.data.length > 16 * 1024) continue;
      try {
        final raw = jsonDecode(utf8.decode(current.data));
        if (raw is! Map<String, dynamic>) continue;
        _acceptBeacon(raw, current.address.address);
      } on FormatException {
        // Ignore non-Airbridge traffic delivered to this UDP port.
      } on TypeError {
        // Ignore structurally invalid beacons.
      }
    }
  }

  void _acceptBeacon(Map<String, dynamic> raw, String host) {
    if (raw['protocol'] != 'airbridge' ||
        raw['protocolVersion'] != NodeConfig.protocolVersion ||
        raw['serviceType'] != NodeConfig.serviceType) {
      return;
    }
    final deviceId = raw['deviceId'];
    final deviceNameValue = raw['deviceName'];
    final httpPort = raw['httpPort'];
    final udpPort = raw['udpPort'];
    final sentAt = raw['sentAt'];
    if (sentAt is! int ||
        (DateTime.now().toUtc().millisecondsSinceEpoch - sentAt).abs() > 120000) {
      return;
    }
    if (deviceId is! String ||
        deviceId.length > 64 ||
        deviceId == config.deviceId ||
        deviceNameValue is! String ||
        httpPort is! int ||
        udpPort is! int ||
        httpPort < 1 ||
        httpPort > 65535 ||
        udpPort < 1 ||
        udpPort > 65535) {
      return;
    }

    if (config.hasSharedSecret) {
      final signature = raw['signature'];
      final unsigned = Map<String, dynamic>.from(raw)..remove('signature');
      if (!verifyHmacSha256Hex(
        config.sharedSecret,
        utf8.encode(jsonEncode(unsigned)),
        signature is String ? signature : null,
      )) {
        return;
      }
    }

    if (!_lastSeen.containsKey(deviceId) && _lastSeen.length >= 256) return;

    final remoteRole = raw['role'];
    final masterId = raw['masterId'];
    final peer = Peer(
      deviceId: deviceId,
      deviceName: deviceNameValue.length > 64
          ? deviceNameValue.substring(0, 64)
          : deviceNameValue,
      host: host,
      httpPort: httpPort,
      udpPort: udpPort,
      lastSeen: DateTime.now(),
      role: remoteRole == 'master' ? 'master' : 'peer',
      masterId: masterId is String ? masterId : '',
    );
    _lastSeen[deviceId] = peer.lastSeen;
    onPeerSeen(peer);
  }

  void _expirePeers() {
    final threshold = DateTime.now().subtract(
      Duration(seconds: config.peerTimeoutSeconds),
    );
    final expired = _lastSeen.entries
        .where((entry) => entry.value.isBefore(threshold))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final deviceId in expired) {
      _lastSeen.remove(deviceId);
      onPeerExpired(deviceId);
      onLog('INFO', 'Peer $deviceId timed out and was removed.');
    }
  }
}
