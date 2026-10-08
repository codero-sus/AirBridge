import 'dart:async';
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
import 'task_worker.dart';

class NodeController extends ChangeNotifier {
  NodeController(this.config) {
    _masterId = config.deviceId;
  }

  final NodeConfig config;
  final TaskWorker _worker = TaskWorker(maxConcurrent: 2, maxQueued: 64);
  final Map<String, Peer> _peers = <String, Peer>{};
  final List<NodeMessage> _messages = <NodeMessage>[];
  final List<NodeLogEntry> _logs = <NodeLogEntry>[];

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
  int get connectedPeerCount => _gateway?.connectedPeerIds.length ?? 0;
  Set<String> get connectedPeerIds =>
      Set<String>.unmodifiable(_gateway?.connectedPeerIds ?? const <String>{});
  List<Peer> get peers {
    final result = _peers.values.toList(growable: false)
      ..sort((a, b) => a.deviceName.toLowerCase().compareTo(b.deviceName.toLowerCase()));
    return result;
  }

  List<NodeMessage> get messages => List<NodeMessage>.unmodifiable(_messages);
  List<NodeLogEntry> get logs => List<NodeLogEntry>.unmodifiable(_logs);

  Future<void> start() async {
    if (_started || _starting || _stopping) return;
    _starting = true;
    final startupDone = Completer<void>();
    _startupDone = startupDone;
    _lifecycle = 'starting';
    _recordLog('INFO', 'Starting Airbridge node ${config.deviceId}.');
    _notify();

    try {
      try {
        await AndroidNetworkBridge.acquireMulticastLock();
        if (Platform.isAndroid) {
          _recordLog('INFO', 'Android Wi-Fi MulticastLock acquired.');
        }
      } on Object catch (error) {
        _recordLog('WARN', 'Could not acquire Android MulticastLock: $error');
      }

      _localAddress = await _resolveLocalAddress();
      _gateway = ApiGateway(
        config: config,
        statusProvider: _statusSnapshot,
        payloadFactory: _createEnvelope,
        onEnvelope: _handleEnvelope,
        onLog: _recordLog,
        onConnectionsChanged: _handleConnectionChange,
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
          'No shared secret configured: local mesh traffic is open and payloads are not encrypted.',
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
      _notify();
    } on Object catch (error) {
      _lifecycle = 'error';
      _recordLog('ERROR', 'Node startup failed: $error');
      await _cleanupServices();
      _notify();
    } finally {
      _starting = false;
      if (!startupDone.isCompleted) startupDone.complete();
    }
  }

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
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
    _notify();
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
    final createdAt = DateTime.tryParse(envelope['createdAt'] as String? ?? '') ??
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
    _notify();
  }

  void _handlePeerSeen(Peer peer) {
    if (peer.deviceId == config.deviceId) return;
    final isNew = !_peers.containsKey(peer.deviceId);
    _peers[peer.deviceId] = peer;
    _recomputeElection();
    _gateway?.updatePeer(peer);
    if (isNew) {
      _recordLog('PEER', 'Discovered ${peer.deviceName} at ${peer.host}:${peer.httpPort}.');
    }
    _notify();
  }

  void _handlePeerExpired(String deviceId) {
    final peer = _peers.remove(deviceId);
    if (peer != null) {
      _recomputeElection();
      unawaited(_gateway?.removePeer(deviceId) ?? Future<void>.value());
      _recordLog('WARN', 'Peer ${peer.deviceName} is no longer reachable.');
      _notify();
    }
  }

  void _recomputeElection() {
    final candidates = <String>[config.deviceId, ..._peers.keys]..sort();
    _masterId = candidates.first;
    _role = _masterId == config.deviceId ? 'master' : 'peer';
  }

  void _handleConnectionChange() {
    _recordLog('INFO', 'Mesh links active: $connectedPeerCount.');
    _notify();
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
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final candidates = <String>[];
      for (final networkInterface in interfaces) {
        for (final interfaceAddress in networkInterface.addresses) {
          final address = interfaceAddress.address;
          if (address.startsWith('127.') || address.startsWith('169.254.')) continue;
          candidates.add(address);
        }
      }
      if (candidates.isNotEmpty) return candidates.first;
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
      _notify();
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
