import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../config/node_config.dart';
import '../models/peer.dart';
import 'security.dart';
import 'task_worker.dart';

typedef NodeStatusProvider = Map<String, Object?> Function();
typedef PayloadFactory = Future<Map<String, dynamic>> Function(
  Object? payload, {
  required String senderName,
});
typedef EnvelopeCallback = Future<void> Function(
  Map<String, dynamic> envelope, {
  required bool local,
});
typedef GatewayLogCallback = void Function(String level, String message);
typedef GatewayChangeCallback = void Function();

/// HTTP/WS gateway and outbound peer mesh. The listener always binds all IPv4
/// interfaces. One WebSocket is initiated per peer pair by the lower node ID.
class ApiGateway {
  ApiGateway({
    required this.config,
    required this.statusProvider,
    required this.payloadFactory,
    required this.onEnvelope,
    required this.onLog,
    required this.onConnectionsChanged,
  });

  final NodeConfig config;
  final NodeStatusProvider statusProvider;
  final PayloadFactory payloadFactory;
  final EnvelopeCallback onEnvelope;
  final GatewayLogCallback onLog;
  final GatewayChangeCallback onConnectionsChanged;

  final Set<_SocketLink> _links = <_SocketLink>{};
  final Map<String, Peer> _knownPeers = <String, Peer>{};
  final Set<String> _dialing = <String>{};
  final LinkedHashMap<String, DateTime> _seenMessages =
      LinkedHashMap<String, DateTime>();
  final LinkedHashMap<String, DateTime> _httpNonces =
      LinkedHashMap<String, DateTime>();
  final Set<String> _processingMessages = <String>{};
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _serverSubscription;
  Timer? _reconnectTimer;
  bool _stopped = false;

  Set<String> get connectedPeerIds => _links
      .map((link) => link.peerId)
      .where((id) => id.isNotEmpty)
      .toSet();

  Future<void> start() async {
    if (_server != null) return;
    _stopped = false;
    final server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      config.httpPort,
    );
    _server = server;
    _serverSubscription = server.listen(
      (request) => unawaited(_handleRequest(request)),
      onError: (Object error, StackTrace stack) {
        onLog('ERROR', 'HTTP listener error: $error');
      },
      cancelOnError: false,
    );
    _reconnectTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _reconcilePeerConnections(),
    );
    onLog('INFO', 'HTTP/WebSocket gateway listening on 0.0.0.0:${config.httpPort}.');
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _serverSubscription?.cancel();
    _serverSubscription = null;
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);

    final closing = _links.toList(growable: false);
    for (final link in closing) {
      try {
        await link.socket.close(WebSocketStatus.goingAway, 'Node stopped');
      } on WebSocketException {
        // The remote endpoint already closed.
      } on StateError {
        // The socket is already closing.
      }
    }
    _links.clear();
    _knownPeers.clear();
    _dialing.clear();
    onConnectionsChanged();
  }

  void updatePeer(Peer peer) {
    if (_stopped || peer.deviceId == config.deviceId) return;
    final previous = _knownPeers[peer.deviceId];
    _knownPeers[peer.deviceId] = peer;
    if (previous != null &&
        (previous.host != peer.host || previous.httpPort != peer.httpPort)) {
      for (final link in _links.where((item) => item.peerId == peer.deviceId).toList()) {
        unawaited(_closeLink(link, 'Peer network address changed'));
      }
    }
    _reconcilePeerConnections();
  }

  Future<void> removePeer(String deviceId) async {
    _knownPeers.remove(deviceId);
    final links = _links.where((link) => link.peerId == deviceId).toList();
    for (final link in links) {
      try {
        await link.socket.close(WebSocketStatus.goingAway, 'Peer expired');
      } on Object {
        // Socket closure is best effort.
      }
      _dropLink(link);
    }
  }

  Future<Map<String, dynamic>> publish(
    Object? payload, {
    String? senderName,
  }) async {
    _ensureRunning();
    final envelope = await payloadFactory(
      payload,
      senderName: senderName ?? config.deviceName,
    );
    await _routeEnvelope(envelope, local: true);
    return envelope;
  }

  void _ensureRunning() {
    if (_stopped || _server == null) {
      throw StateError('Airbridge gateway is not running.');
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/status') {
        await _sendJson(request.response, HttpStatus.ok, statusProvider());
        return;
      }
      if (request.method == 'POST' && path == '/api/write') {
        await _handleWriteRequest(request);
        return;
      }
      if (path == '/ws' && request.method == 'GET') {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          await _sendJson(request.response, HttpStatus.upgradeRequired, <String, Object?>{
            'error': 'A WebSocket upgrade is required at /ws.',
          });
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        socket.pingInterval = const Duration(seconds: 20);
        await _serveIncomingSocket(socket);
        return;
      }
      await _sendJson(request.response, HttpStatus.notFound, <String, Object?>{
        'error': 'Not found.',
      });
    } on _PayloadTooLargeException {
      await _sendJson(request.response, HttpStatus.requestEntityTooLarge, <String, Object?>{
        'error': 'Payload exceeds the configured size limit.',
      });
    } on WorkerQueueFullException {
      await _sendJson(request.response, HttpStatus.serviceUnavailable, <String, Object?>{
        'error': 'Background task queue is busy. Retry shortly.',
      });
    } on FormatException catch (error) {
      await _sendJson(request.response, HttpStatus.badRequest, <String, Object?>{
        'error': error.message,
      });
    } on Object catch (error) {
      onLog('ERROR', 'HTTP request failed: $error');
      try {
        await _sendJson(request.response, HttpStatus.internalServerError, <String, Object?>{
          'error': 'Request processing failed.',
        });
      } on Object {
        // A response may already have been committed before a later failure.
      }
    }
  }

  Future<void> _handleWriteRequest(HttpRequest request) async {
    final body = await _readBoundedBody(request);
    if (config.hasSharedSecret && !_verifyHttpSignature(request, body)) {
      await _sendJson(request.response, HttpStatus.unauthorized, <String, Object?>{
        'error': 'Missing, expired, replayed, or invalid Airbridge request signature.',
      });
      return;
    }
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map<String, dynamic> || !decoded.containsKey('payload')) {
      throw const FormatException('Body must be a JSON object containing "payload".');
    }
    final requestedName = decoded['senderName'];
    final remoteHost = request.connectionInfo?.remoteAddress.address ?? 'HTTP peer';
    final trimmedName = requestedName is String ? requestedName.trim() : '';
    final senderName = trimmedName.isNotEmpty
        ? (trimmedName.length > 64 ? trimmedName.substring(0, 64) : trimmedName)
        : 'HTTP peer $remoteHost';
    final envelope = await publish(decoded['payload'], senderName: senderName);
    await _sendJson(request.response, HttpStatus.created, <String, Object?>{
      'ok': true,
      'messageId': envelope['id'],
      'envelope': envelope,
    });
  }

  Future<List<int>> _readBoundedBody(HttpRequest request) async {
    final advertisedLength = request.contentLength;
    final maxLength = config.maxPayloadBytes + 64 * 1024;
    if (advertisedLength > maxLength) throw const _PayloadTooLargeException();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      if (builder.length + chunk.length > maxLength) {
        throw const _PayloadTooLargeException();
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  bool _verifyHttpSignature(HttpRequest request, List<int> body) {
    final timestampText = request.headers.value('x-airbridge-timestamp');
    final nonce = request.headers.value('x-airbridge-nonce');
    final signature = request.headers.value('x-airbridge-signature');
    final timestamp = timestampText == null ? null : int.tryParse(timestampText);
    if (timestamp == null ||
        nonce == null ||
        !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(nonce)) {
      return false;
    }
    final nowSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    if ((nowSeconds - timestamp).abs() > 120) return false;

    final now = DateTime.now();
    final expiredNonces = _httpNonces.entries
        .where((entry) => now.difference(entry.value) > const Duration(minutes: 5))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final expired in expiredNonces) {
      _httpNonces.remove(expired);
    }
    if (_httpNonces.containsKey(nonce)) return false;

    final signedBytes = <int>[
      ...utf8.encode('$timestamp.$nonce.'),
      ...body,
    ];
    if (!verifyHmacSha256Hex(config.sharedSecret, signedBytes, signature)) {
      return false;
    }
    _httpNonces[nonce] = now;
    while (_httpNonces.length > 10000) {
      _httpNonces.remove(_httpNonces.keys.first);
    }
    return true;
  }

  Future<void> _serveIncomingSocket(WebSocket socket) async {
    final iterator = StreamIterator<dynamic>(socket);
    _SocketLink? link;
    var iteratorTransferred = false;
    final challenge = _newChallenge();
    try {
      socket.add(jsonEncode(<String, Object?>{
        'type': 'challenge',
        'nonce': challenge,
        'deviceId': config.deviceId,
        'serviceType': NodeConfig.serviceType,
      }));
      final gotFirstFrame = await iterator
          .moveNext()
          .timeout(const Duration(seconds: 8));
      if (!gotFirstFrame) return;
      final auth = _decodeFrame(iterator.current);
      final deviceId = auth?['deviceId'];
      final signature = auth?['signature'];
      if (auth?['type'] != 'auth' ||
          deviceId is! String ||
          deviceId.isEmpty ||
          deviceId.length > 64 ||
          deviceId == config.deviceId ||
          (config.hasSharedSecret &&
              !verifyHmacSha256Hex(
                config.sharedSecret,
                utf8.encode('airbridge-ws-v1:$challenge:$deviceId'),
                signature is String ? signature : null,
              ))) {
        await socket.close(WebSocketStatus.policyViolation, 'Invalid Airbridge auth');
        return;
      }

      if (_links.length >= 256) {
        await socket.close(WebSocketStatus.policyViolation, 'Peer connection limit reached');
        return;
      }
      link = _SocketLink(socket: socket, peerId: deviceId);
      _links.add(link);
      socket.add(jsonEncode(_helloFrame()));
      onLog('INFO', 'WebSocket peer connected: $deviceId.');
      onConnectionsChanged();
      iteratorTransferred = true;
      await _consumeFrames(iterator, link);
    } on TimeoutException {
      onLog('WARN', 'WebSocket client did not authenticate in time.');
      await socket.close(WebSocketStatus.policyViolation, 'Auth timeout');
    } on Object catch (error) {
      onLog('WARN', 'Incoming WebSocket closed: $error');
    } finally {
      if (!iteratorTransferred) await iterator.cancel();
      if (link != null) _dropLink(link);
      if (socket.closeCode == null) {
        await socket.close(WebSocketStatus.normalClosure);
      }
    }
  }

  Future<void> _consumeFrames(StreamIterator<dynamic> iterator, _SocketLink link) async {
    try {
      while (await iterator.moveNext()) {
        await _handleSocketFrame(link, iterator.current);
      }
    } on Object catch (error) {
      onLog('WARN', 'WebSocket ${link.peerId} frame handling ended: $error');
      try {
        await link.socket.close(WebSocketStatus.internalServerError, 'Frame handling failed');
      } on Object {
        // Closing a failed link is best effort.
      }
    } finally {
      await iterator.cancel();
      _dropLink(link);
    }
  }

  Future<void> _handleSocketFrame(_SocketLink link, Object? rawFrame) async {
    final frameSize = _frameSize(rawFrame);
    if (frameSize < 0 || frameSize > config.maxPayloadBytes * 2 + 64 * 1024) {
      await link.socket.close(WebSocketStatus.messageTooBig, 'Frame too large');
      return;
    }
    final frame = _decodeFrame(rawFrame);
    if (frame == null) {
      onLog('WARN', 'Ignored non-JSON WebSocket frame from ${link.peerId}.');
      return;
    }

    switch (frame['type']) {
      case 'ping':
        link.socket.add(jsonEncode(<String, Object?>{'type': 'pong'}));
        return;
      case 'write':
        if (!frame.containsKey('payload')) {
          link.socket.add(jsonEncode(<String, Object?>{
            'type': 'error',
            'error': 'write frame requires a payload field.',
          }));
          return;
        }
        final envelope = await publish(
          frame['payload'],
          senderName: link.peerId.isEmpty ? 'WebSocket peer' : link.peerId,
        );
        link.socket.add(jsonEncode(<String, Object?>{
          'type': 'accepted',
          'messageId': envelope['id'],
        }));
        return;
      case 'message':
        final rawEnvelope = frame['envelope'];
        if (rawEnvelope is! Map<String, dynamic>) return;
        final envelope = Map<String, dynamic>.from(rawEnvelope);
        if (!_isValidEnvelope(envelope)) {
          onLog('WARN', 'Rejected malformed mesh envelope from ${link.peerId}.');
          return;
        }
        await _routeEnvelope(envelope, origin: link, local: false);
        return;
      default:
        link.socket.add(jsonEncode(<String, Object?>{
          'type': 'error',
          'error': 'Unsupported WebSocket frame type.',
        }));
    }
  }

  Map<String, dynamic>? _decodeFrame(Object? frame) {
    try {
      final String text;
      if (frame is String) {
        text = frame;
      } else if (frame is List<int>) {
        text = utf8.decode(frame);
      } else {
        return null;
      }
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  int _frameSize(Object? frame) {
    if (frame is String) return utf8.encode(frame).length;
    if (frame is List<int>) return frame.length;
    return -1;
  }

  bool _isValidEnvelope(Map<String, dynamic> envelope) {
    final id = envelope['id'];
    final senderId = envelope['senderId'];
    final senderName = envelope['senderName'];
    final createdAt = envelope['createdAt'];
    final algorithm = envelope['algorithm'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        senderId is! String ||
        senderId.isEmpty ||
        senderId.length > 64 ||
        senderName is! String ||
        senderName.length > 64 ||
        createdAt is! String ||
        DateTime.tryParse(createdAt) == null ||
        (algorithm != 'none' && algorithm != 'AES-256-GCM')) {
      return false;
    }
    if (algorithm == 'AES-256-GCM') {
      return envelope['nonce'] is String &&
          envelope['ciphertext'] is String &&
          envelope['mac'] is String;
    }
    return envelope.containsKey('payload');
  }

  Future<void> _routeEnvelope(
    Map<String, dynamic> envelope, {
    _SocketLink? origin,
    required bool local,
  }) async {
    if (!_isValidEnvelope(envelope)) {
      throw const FormatException('Invalid Airbridge message envelope.');
    }
    final messageId = envelope['id']! as String;
    _pruneSeenMessages();
    if (_seenMessages.containsKey(messageId) ||
        !_processingMessages.add(messageId)) {
      return;
    }

    // Decrypt/validate and persist before forwarding, so corrupt payloads are
    // not propagated through the rest of the mesh. Failed processing remains
    // retryable if the sender retransmits.
    try {
      await onEnvelope(envelope, local: local);
      _seenMessages[messageId] = DateTime.now();
      while (_seenMessages.length > 4096) {
        _seenMessages.remove(_seenMessages.keys.first);
      }
    } finally {
      _processingMessages.remove(messageId);
    }
    final frame = jsonEncode(<String, Object?>{
      'type': 'message',
      'envelope': envelope,
    });
    for (final link in _links.toList(growable: false)) {
      if (identical(link, origin) || link.socket.closeCode != null) continue;
      try {
        link.socket.add(frame);
      } on Object catch (error) {
        onLog('WARN', 'Could not forward message to ${link.peerId}: $error');
      }
    }
  }

  void _pruneSeenMessages() {
    final threshold = DateTime.now().subtract(const Duration(hours: 1));
    final expired = _seenMessages.entries
        .where((entry) => entry.value.isBefore(threshold))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final id in expired) {
      _seenMessages.remove(id);
    }
  }

  String _newChallenge() {
    final random = Random.secure();
    return List<int>.generate(32, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Map<String, Object?> _helloFrame() => <String, Object?>{
        'type': 'hello',
        'deviceId': config.deviceId,
        'deviceName': config.deviceName,
        'serviceType': NodeConfig.serviceType,
      };

  String _authFrame(String challenge) {
    final frame = <String, Object?>{
      'type': 'auth',
      'deviceId': config.deviceId,
    };
    if (config.hasSharedSecret) {
      frame['signature'] = hmacTextHex(
        config.sharedSecret,
        'airbridge-ws-v1:$challenge:${config.deviceId}',
      );
    }
    return jsonEncode(frame);
  }

  void _reconcilePeerConnections() {
    if (_stopped || _links.length >= 256) return;
    for (final peer in _knownPeers.values) {
      if (_links.length + _dialing.length >= 256) return;
      // Deterministically choose one outbound connection per pair.
      if (config.deviceId.compareTo(peer.deviceId) >= 0) continue;
      if (_dialing.contains(peer.deviceId) ||
          _links.any((link) => link.peerId == peer.deviceId)) {
        continue;
      }
      unawaited(_dialPeer(peer));
    }
  }

  Future<void> _dialPeer(Peer peer) async {
    if (_stopped || !_dialing.add(peer.deviceId)) return;
    WebSocket? socket;
    StreamIterator<dynamic>? iterator;
    try {
      final uri = Uri(
        scheme: 'ws',
        host: peer.host,
        port: peer.httpPort,
        path: '/ws',
      );
      final connectedSocket = await WebSocket.connect(uri.toString()).timeout(
        const Duration(seconds: 5),
      );
      socket = connectedSocket;
      connectedSocket.pingInterval = const Duration(seconds: 20);
      final streamIterator = StreamIterator<dynamic>(connectedSocket);
      iterator = streamIterator;
      final gotChallenge = await streamIterator.moveNext().timeout(
        const Duration(seconds: 8),
      );
      if (!gotChallenge) throw const FormatException('Peer closed before challenge.');
      final challengeFrame = _decodeFrame(streamIterator.current);
      final challenge = challengeFrame?['nonce'];
      if (challengeFrame?['type'] != 'challenge' ||
          challengeFrame?['deviceId'] != peer.deviceId ||
          challenge is! String ||
          challenge.length > 128) {
        throw const FormatException('Peer sent an invalid WebSocket challenge.');
      }
      connectedSocket.add(_authFrame(challenge));
      final gotHello = await streamIterator.moveNext().timeout(
        const Duration(seconds: 8),
      );
      if (!gotHello) throw const FormatException('Peer closed before hello.');
      final hello = _decodeFrame(streamIterator.current);
      if (hello?['type'] != 'hello' || hello?['deviceId'] != peer.deviceId) {
        throw const FormatException('Peer identity did not match its discovery beacon.');
      }
      final link = _SocketLink(
        socket: connectedSocket,
        peerId: peer.deviceId,
      );
      _links.add(link);
      onLog('INFO', 'Connected WebSocket mesh link to ${peer.deviceName}.');
      onConnectionsChanged();
      await _consumeFrames(streamIterator, link);
      iterator = null;
      await connectedSocket.close(WebSocketStatus.normalClosure);
      socket = null;
    } on TimeoutException {
      onLog('WARN', 'Timed out connecting to peer ${peer.deviceId}.');
    } on SocketException catch (error) {
      onLog('WARN', 'Could not connect to peer ${peer.deviceId}: $error');
    } on Object catch (error) {
      onLog('WARN', 'Peer ${peer.deviceId} WebSocket handshake failed: $error');
    } finally {
      await iterator?.cancel();
      if (socket != null) {
        try {
          await socket.close(WebSocketStatus.goingAway);
        } on Object {
          // Socket cleanup is best effort.
        }
      }
      _dialing.remove(peer.deviceId);
    }
  }

  Future<void> _closeLink(_SocketLink link, String reason) async {
    try {
      await link.socket.close(WebSocketStatus.goingAway, reason);
    } on Object {
      // Closing a stale connection is best effort.
    } finally {
      _dropLink(link);
    }
  }

  void _dropLink(_SocketLink link) {
    if (!_links.remove(link)) return;
    onLog('INFO', 'WebSocket mesh link closed: ${link.peerId}.');
    onConnectionsChanged();
  }

  Future<void> _sendJson(
    HttpResponse response,
    int statusCode,
    Object? value,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.headers.set('x-content-type-options', 'nosniff');
    response.write(jsonEncode(value));
    await response.close();
  }
}

class _SocketLink {
  const _SocketLink({required this.socket, required this.peerId});

  final WebSocket socket;
  final String peerId;
}

class _PayloadTooLargeException implements Exception {
  const _PayloadTooLargeException();
}
