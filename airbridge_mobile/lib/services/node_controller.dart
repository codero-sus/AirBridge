import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../config/node_config.dart';
import '../models/node_message.dart';
import '../models/peer.dart';
import 'android_network_bridge.dart';
import 'api_gateway.dart';
import 'discovery_service.dart';
import 'network_address_selector.dart';
import 'pairing_service.dart';
import 'task_worker.dart';

class NodeController extends ChangeNotifier {
  NodeController(this.config) {
    _masterId = config.deviceId;
    _pairing = PairingService(
      config: config,
      onPeerTrusted: _handleTrustedPeer,
    );
  }

  final NodeConfig config;
  late final PairingService _pairing;
  TaskWorker _worker = TaskWorker(maxConcurrent: 2, maxQueued: 64);
  final Map<String, Peer> _peers = <String, Peer>{};
  final List<NodeMessage> _messages = <NodeMessage>[];
  final List<NodeLogEntry> _logs = <NodeLogEntry>[];
  List<Peer>? _sortedPeersCache;
  UnmodifiableListView<Peer>? _peerView;
  final Map<String, int> _peerPositions = <String, int>{};
  bool _workerClosed = false;

  ApiGateway? _gateway;
  DiscoveryService? _discovery;
  Timer? _addressRefreshTimer;
  Completer<void>? _startupDone;
  String _localAddress = 'Resolving…';
  String _role = 'master';
  String _masterId = '';
  String _lifecycle = 'starting';
  bool _started = false;
  bool _starting = false;
  bool _stopping = false;
  bool _disposed = false;

  String get localAddress => _localAddress;
  String get role => _role;
  String get masterId => _masterId;
  String get lifecycle => _lifecycle;
  bool get isRunning => _lifecycle == 'online';
  bool get hasSharedSecret => config.hasSharedSecret;
  List<TrustedPeer> get trustedPeers => _pairing.trustedPeers;
  int get connectedPeerCount => _gateway?.connectedPeerIds.length ?? 0;
  Set<String> get connectedPeerIds =>
      Set<String>.unmodifiable(_gateway?.connectedPeerIds ?? const <String>{});
  List<Peer> get peers {
    final cached = _peerView;
    if (cached != null) return cached;
    final sorted = _peers.values.toList()
      ..sort((a, b) => a.deviceName.toLowerCase().compareTo(b.deviceName.toLowerCase()));
    _peerPositions
      ..clear()
      ..addEntries(
        sorted.indexed.map((entry) => MapEntry(entry.$2.deviceId, entry.$1)),
      );
    _sortedPeersCache = sorted;
    return _peerView = UnmodifiableListView<Peer>(sorted);
  }

  List<NodeMessage> get messages => List<NodeMessage>.unmodifiable(_messages);
  List<NodeLogEntry> get logs => List<NodeLogEntry>.unmodifiable(_logs);

  Future<void> start() async {
    if (_started || _starting || _stopping) return;
    if (_workerClosed) {
      _worker = TaskWorker(maxConcurrent: 2, maxQueued: 64);
      _workerClosed = false;
    }
    _starting = true;
    final startupDone = Completer<void>();
    _startupDone = startupDone;
    _lifecycle = 'starting';
    _recordLog('INFO', 'Starting Airbridge node ${config.deviceId}.');

    try {
      try {
        await AndroidNetworkBridge.acquireMulticastLock();
        if (Platform.isAndroid) {
          _recordLog('INFO', 'Android Wi-Fi MulticastLock acquired.');
        }
      } on Object catch (error) {
        _recordLog('WARN', 'Could not acquire Android MulticastLock: $error');
      }

      await _pairing.load();
      await _restorePersistedMessages();
      _localAddress = await _resolveLocalAddress();
      _gateway = ApiGateway(
        config: config,
        statusProvider: _statusSnapshot,
        payloadFactory: _createEnvelope,
        onEnvelope: _handleEnvelope,
        onLog: _recordLog,
        onConnectionsChanged: _handleConnectionChange,
        peerSecretProvider: _pairing.secretForPeer,
        pairingClaimHandler: _pairing.handleClaim,
      );
      await _gateway!.start();

      _discovery = DiscoveryService(
        config: config,
        roleProvider: () => _role,
        masterIdProvider: () => _masterId,
        onPeerSeen: _handlePeerSeen,
        onPeerExpired: _handlePeerExpired,
        onLog: _recordLog,
      );
      await _discovery!.start();

      _started = true;
      _lifecycle = 'online';
      if (!config.hasSharedSecret) {
        _recordLog(
          'WARN',
          'Per-device pairing authentication is active, but mesh payloads are not encrypted. Configure AIRBRIDGE_SHARED_SECRET if payload encryption is required.',
        );
      } else if (config.sharedSecret.length < 32) {
        _recordLog(
          'WARN',
          'Shared secret is shorter than 32 characters; use a random 32-byte secret.',
        );
      }
      _recordLog(
        'INFO',
        'Node online at $_localAddress:${config.httpPort}; UDP ${config.udpPort}.',
      );
      _addressRefreshTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_refreshLocalAddress()),
      );
    } on Object catch (error) {
      _lifecycle = 'error';
      _recordLog('ERROR', 'Node startup failed: $error');
      await _cleanupServices();
    } finally {
      _starting = false;
      if (!startupDone.isCompleted) startupDone.complete();
    }
  }

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _pairing.cancelActiveInvitation();
    _lifecycle = 'stopping';
    if (_starting) await _startupDone?.future;
    _addressRefreshTimer?.cancel();
    _addressRefreshTimer = null;
    _notify();
    await _cleanupServices();
    _started = false;
    _starting = false;
    _stopping = false;
    _lifecycle = 'stopped';
    _recordLog('INFO', 'Airbridge node stopped.');
  }

  Future<PairingInvitation> createPairingInvitation() async {
    if (!_started) {
      throw const PairingException('Start the Airbridge node before showing a pairing QR.');
    }
    await _refreshLocalAddress();
    if (_localAddress == 'Unavailable' || _localAddress == 'Resolving…') {
      throw const PairingException(
        'Connect this device to a reachable Wi-Fi/LAN before creating a pairing QR.',
      );
    }
    return _pairing.createInvitation(
      hostAddress: _localAddress,
      httpPort: config.httpPort,
      udpPort: config.udpPort,
    );
  }

  Future<TrustedPeer> joinPairingInvitation(String qrPayload) {
    if (!_started) {
      throw const PairingException('Start the Airbridge node before pairing a device.');
    }
    return _pairing.joinInvitation(
      qrPayload: qrPayload,
      httpPort: config.httpPort,
      udpPort: config.udpPort,
    );
  }

  bool isPairingInvitationActive(PairingInvitation invitation) =>
      _pairing.isInvitationActive(invitation);

  void cancelPairingInvitation(PairingInvitation invitation) {
    _pairing.cancelInvitation(invitation);
  }

  Future<void> sendPayload(Object? payload) async {
    final gateway = _gateway;
    if (!_started || gateway == null) {
      throw StateError('The Airbridge node is not online.');
    }
    try {
      await gateway.publish(payload, senderName: config.deviceName);
    } on Object catch (error) {
      _recordLog('ERROR', 'Could not dispatch payload: $error');
      rethrow;
    }
  }

  Map<String, Object?> _statusSnapshot() => <String, Object?>{
        'service': 'airbridge',
        'protocolVersion': NodeConfig.protocolVersion,
        'serviceType': NodeConfig.serviceType,
        'deviceId': config.deviceId,
        'deviceName': config.deviceName,
        'host': _localAddress,
        'bindAddress': '0.0.0.0',
        'httpPort': config.httpPort,
        'udpPort': config.udpPort,
        'role': _role,
        'masterId': _masterId,
        'lifecycle': _lifecycle,
        'peerCount': _peers.length,
        'trustedPeerCount': trustedPeers.length,
        'connectedPeerCount': connectedPeerCount,
        'connectedPeerIds': connectedPeerIds.toList(growable: false),
      };

  Future<Map<String, dynamic>> _createEnvelope(
    Object? payload, {
    required String senderName,
  }) {
    final id = _newMessageId();
    return _worker.storeMessage(
      directoryPath: config.messageDirectory.path,
      sharedSecret: config.sharedSecret,
      messageId: id,
      senderId: config.deviceId,
      senderName: senderName,
      createdAt: DateTime.now(),
      payload: payload,
      maxPayloadBytes: config.maxPayloadBytes,
    );
  }

  Future<void> _restorePersistedMessages() async {
    if (_messages.isNotEmpty) return;
    try {
      final stored = await _worker.loadRecentMessages(
        directoryPath: config.messageDirectory.path,
        sharedSecret: config.sharedSecret,
        limit: 100,
      );
      for (final record in stored) {
        final timestamp = DateTime.tryParse(record['timestamp']! as String) ??
            DateTime.now().toUtc();
        _messages.add(
          NodeMessage(
            messageId: record['messageId']! as String,
            senderId: record['senderId']! as String,
            senderName: record['senderName']! as String,
            text: record['text']! as String,
            timestamp: timestamp.toLocal(),
            isLocal: record['senderId'] == config.deviceId,
          ),
        );
      }
      if (_messages.isNotEmpty) {
        _recordLog('INFO', 'Restored ${_messages.length} messages from local history.');
      }
    } on Object catch (error) {
      _recordLog('WARN', 'Could not restore local message history: $error');
    }
  }

  Future<void> _handleEnvelope(
    Map<String, dynamic> envelope, {
    required bool local,
  }) async {
    final decoded = await _worker.decodeEnvelope(
      sharedSecret: config.sharedSecret,
      envelope: envelope,
    );
    if (!local) {
      await _worker.persistReceivedEnvelope(
        directoryPath: config.messageDirectory.path,
        envelope: envelope,
      );
    }
    final createdAtValue = envelope['createdAt'];
    final createdAt = DateTime.tryParse(
          createdAtValue is String ? createdAtValue : '',
        ) ??
        DateTime.now();
    final payloadText = decoded is String
        ? decoded
        : const JsonEncoder.withIndent('  ').convert(decoded);
    _messages.add(
      NodeMessage(
        messageId: envelope['id'] as String? ?? '',
        senderId: envelope['senderId'] as String? ?? 'unknown',
        senderName: envelope['senderName'] as String? ?? 'Airbridge peer',
        text: payloadText,
        timestamp: createdAt.toLocal(),
        isLocal: envelope['senderId'] == config.deviceId,
      ),
    );
    while (_messages.length > 200) {
      _messages.removeAt(0);
    }
    _recordLog(
      'DATA',
      '${local ? 'Dispatched' : 'Received'} message ${envelope['id']}.',
    );
  }

  void _handleTrustedPeer(TrustedPeer trusted, String remoteHost) {
    if (trusted.deviceId == config.deviceId) return;
    final peer = Peer(
      deviceId: trusted.deviceId,
      deviceName: trusted.deviceName,
      host: remoteHost,
      httpPort: trusted.httpPort,
      udpPort: trusted.udpPort,
      lastSeen: DateTime.now(),
      role: 'peer',
      masterId: _masterId,
    );
    _peers[peer.deviceId] = peer;
    _invalidatePeerSnapshot();
    _recomputeElection();
    _gateway?.updatePeer(peer);
    _recordLog('SECURITY', 'Passwordless QR pairing trusted ${peer.deviceName}.');
  }

  void _handlePeerSeen(Peer peer) {
    if (peer.deviceId == config.deviceId) return;
    final previous = _peers[peer.deviceId];
    final isNew = previous == null;
    final addressChanged = previous != null &&
        (previous.host != peer.host || previous.httpPort != peer.httpPort);
    final detailsChanged = previous != null &&
        (previous.deviceName != peer.deviceName ||
            previous.role != peer.role ||
            previous.masterId != peer.masterId ||
            previous.udpPort != peer.udpPort);
    _peers[peer.deviceId] = peer;

    if (isNew || detailsChanged || addressChanged) _invalidatePeerSnapshot();
    if (!isNew && !detailsChanged && !addressChanged) {
      final index = _peerPositions[peer.deviceId];
      if (index != null && _sortedPeersCache != null) {
        _sortedPeersCache![index] = peer;
      }
      // Beacons refresh lastSeen often. Keep the model fresh without sorting,
      // notifying the whole dashboard, or rechecking every mesh connection.
      return;
    }

    if (isNew) {
      _recomputeElection();
      _gateway?.updatePeer(peer);
      _recordLog('PEER', 'Discovered ${peer.deviceName} at ${peer.host}:${peer.httpPort}.');
    } else {
      if (addressChanged || detailsChanged) _gateway?.updatePeer(peer);
      if (addressChanged) {
        _recordLog('INFO', '${peer.deviceName} changed address to ${peer.host}:${peer.httpPort}.');
      } else {
        _notify();
      }
    }
  }

  void _handlePeerExpired(String deviceId) {
    final peer = _peers.remove(deviceId);
    if (peer != null) {
      _invalidatePeerSnapshot();
      _recomputeElection();
      unawaited(_gateway?.removePeer(deviceId) ?? Future<void>.value());
      _recordLog('WARN', 'Peer ${peer.deviceName} is no longer reachable.');
    }
  }

  void _invalidatePeerSnapshot() {
    _sortedPeersCache = null;
    _peerView = null;
    _peerPositions.clear();
  }

  void _recomputeElection() {
    final candidates = <String>[config.deviceId, ..._peers.keys]..sort();
    _masterId = candidates.first;
    _role = _masterId == config.deviceId ? 'master' : 'peer';
  }

  void _handleConnectionChange() {
    _recordLog('INFO', 'Mesh links active: $connectedPeerCount.');
  }

  void _recordLog(String level, String message) {
    _logs.add(
      NodeLogEntry(timestamp: DateTime.now(), level: level, message: message),
    );
    while (_logs.length > 250) {
      _logs.removeAt(0);
    }
    _notify();
  }

  Future<String> _resolveLocalAddress() async {
    if (Platform.isAndroid) {
      final wifiAddress = await AndroidNetworkBridge.getWifiIPv4Address();
      if (wifiAddress != null) return wifiAddress;
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final candidates = <NetworkAddressCandidate>[
        for (final networkInterface in interfaces)
          for (final interfaceAddress in networkInterface.addresses)
            NetworkAddressCandidate(
              interfaceName: networkInterface.name,
              address: interfaceAddress.address,
            ),
      ];
      final selected = selectPreferredIpv4Address(candidates);
      if (selected != null) return selected;
      if (_localAddress != 'Unavailable') {
        _recordLog(
          'WARN',
          'No reachable IPv4 address found. Connect to Wi-Fi/LAN; '
          'a cellular, VPN, or isolated network may not be reachable by the other device.',
        );
      }
    } on SocketException catch (error) {
      _recordLog('WARN', 'Could not read local network address: $error');
    } on UnsupportedError catch (error) {
      _recordLog('WARN', 'Local address lookup is unavailable: $error');
    }
    return 'Unavailable';
  }

  Future<void> _refreshLocalAddress() async {
    if (!_started) return;
    final refreshed = await _resolveLocalAddress();
    if (refreshed != _localAddress) {
      _localAddress = refreshed;
      _recordLog('INFO', 'Local network address changed to $_localAddress.');
    }
  }

  String _newMessageId() {
    final random = Random.secure();
    final suffix = List<int>.generate(12, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(16)}-$suffix';
  }

  Future<void> _cleanupServices() async {
    _addressRefreshTimer?.cancel();
    _addressRefreshTimer = null;
    try {
      await _discovery?.stop();
    } on Object catch (error) {
      _recordLog('WARN', 'Discovery shutdown error: $error');
    }
    _discovery = null;
    try {
      await _gateway?.stop();
    } on Object catch (error) {
      _recordLog('WARN', 'Gateway shutdown error: $error');
    }
    _gateway = null;
    try {
      await _worker.close();
      _workerClosed = true;
    } on Object catch (error) {
      _recordLog('WARN', 'Task worker shutdown error: $error');
    }
    try {
      await AndroidNetworkBridge.releaseMulticastLock();
    } on Object catch (error) {
      _recordLog('WARN', 'Could not release Android MulticastLock: $error');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
