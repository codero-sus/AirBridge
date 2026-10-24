import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import '../config/node_config.dart';
import 'file_transfer_store.dart';
import '../models/peer.dart';
import 'reconnect_backoff.dart';
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
typedef PeerSecretProvider = String? Function(String deviceId);
typedef PairingClaimHandler = Future<(int, Map<String, Object?>)> Function(
  Map<String, dynamic> claim,
  String remoteHost,
);

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
    this.peerSecretProvider,
    this.pairingClaimHandler,
    this.fileTransferStore,
    this.allowIncomingFiles,
    this.onFileReceived,
    this.maxConcurrentHttpRequests = 128,
    this.maxPendingWebSocketHandshakes = 32,
  }) {
    if (maxConcurrentHttpRequests < 1 || maxPendingWebSocketHandshakes < 1) {
      throw ArgumentError('Gateway concurrency limits must be positive.');
    }
  }

  final NodeConfig config;
  final NodeStatusProvider statusProvider;
  final PayloadFactory payloadFactory;
  final EnvelopeCallback onEnvelope;
  final GatewayLogCallback onLog;
  final GatewayChangeCallback onConnectionsChanged;
  final PeerSecretProvider? peerSecretProvider;
  final PairingClaimHandler? pairingClaimHandler;
  final FileTransferStore? fileTransferStore;
  final bool Function()? allowIncomingFiles;
  final void Function(FileTransferRecord record)? onFileReceived;
  final int maxConcurrentHttpRequests;
  final int maxPendingWebSocketHandshakes;

  final Set<_SocketLink> _links = <_SocketLink>{};
  final Map<String, Peer> _knownPeers = <String, Peer>{};
  final Set<String> _dialing = <String>{};
  final LinkedHashMap<String, DateTime> _seenMessages =
      LinkedHashMap<String, DateTime>();
  final LinkedHashMap<String, DateTime> _httpNonces =
      LinkedHashMap<String, DateTime>();
  final Set<String> _processingMessages = <String>{};
  final Map<String, int> _reconnectAttempts = <String, int>{};
  final Map<String, DateTime> _retryAfter = <String, DateTime>{};
  final ReconnectBackoff _reconnectBackoff = ReconnectBackoff();
  int _activeHttpRequests = 0;
  int _pendingWebSocketHandshakes = 0;
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
      (request) => unawaited(_handleGuardedRequest(request)),
      onError: (Object error, StackTrace stack) {
        onLog('ERROR', 'HTTP listener error: $error');
      },
      cancelOnError: false,
    );
    _reconnectTimer = Timer.periodic(
      const Duration(seconds: 1),
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
    _reconnectAttempts.clear();
    _retryAfter.clear();
    onConnectionsChanged();
  }

  void updatePeer(Peer peer) {
    if (_stopped || peer.deviceId == config.deviceId) return;
    final previous = _knownPeers[peer.deviceId];
    _knownPeers[peer.deviceId] = peer;
    if (previous != null &&
        (previous.host != peer.host || previous.httpPort != peer.httpPort)) {
      _reconnectAttempts.remove(peer.deviceId);
      _retryAfter.remove(peer.deviceId);
      for (final link in _links.where((item) => item.peerId == peer.deviceId).toList()) {
        unawaited(_closeLink(link, 'Peer network address changed'));
      }
    }
    _reconcilePeerConnections();
  }

  Future<void> removePeer(String deviceId) async {
    _knownPeers.remove(deviceId);
    _reconnectAttempts.remove(deviceId);
    _retryAfter.remove(deviceId);
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

  Future<void> sendFile({
    required String path,
    required String peerId,
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    _ensureRunning();
    final peer = _knownPeers[peerId];
    if (peer == null) {
      throw StateError('The selected peer is no longer available.');
    }
    final secret = _secretForPeer(peerId);
    if (secret == null) {
      throw StateError('Pair with this device by QR before sending files.');
    }

    final file = File(path);
    if (!await file.exists()) throw FileSystemException('The selected file no longer exists.', path);
    final totalBytes = await file.length();
    if (totalBytes > maxSupportedIncomingFileBytes) {
      throw FileTransferException(
        'Files larger than ${_formatTransferSize(maxSupportedIncomingFileBytes)} are not supported.',
        statusCode: HttpStatus.requestEntityTooLarge,
      );
    }
    final fileName = path.replaceAll(String.fromCharCode(92), '/').split('/').last;
    final digest = await sha256.bind(file.openRead()).first;
    final transferId = _newChallenge();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 30);

    var sentBytes = 0;
    onProgress?.call(0, totalBytes);
    try {
      final metadata = utf8.encode(jsonEncode(<String, Object?>{
        'fileName': fileName,
        'sizeBytes': totalBytes,
        'sha256': digest.toString(),
        'senderName': config.deviceName,
      }));
      final sealedMetadata = await sealPeerPayload(
        secret: secret,
        cleartext: metadata,
        associatedData: _fileMetadataAad(config.deviceId, peerId, transferId),
      );
      await _sendSignedJson(
        client: client,
        peer: peer,
        secret: secret,
        path: '/api/files/start',
        value: <String, Object?>{
          'version': 1,
          'transferId': transferId,
          'senderId': config.deviceId,
          'recipientId': peerId,
          'sealed': sealedMetadata,
        },
      );

      const chunkSize = 1024 * 1024;
      final handle = await file.open(mode: FileMode.read);
      var index = 0;
      try {
        while (sentBytes < totalBytes) {
          final chunk = await handle.read(chunkSize);
          if (chunk.isEmpty) {
            throw const FileTransferException('The selected file changed during transfer.');
          }
          final sealedChunk = await sealPeerPayload(
            secret: secret,
            cleartext: chunk,
            associatedData: _fileChunkAad(
              config.deviceId,
              peerId,
              transferId,
              index,
            ),
          );
          await _sendSignedJson(
            client: client,
            peer: peer,
            secret: secret,
            path: '/api/files/chunk',
            value: <String, Object?>{
              'version': 1,
              'transferId': transferId,
              'senderId': config.deviceId,
              'recipientId': peerId,
              'index': index,
              'sealed': sealedChunk,
            },
          );
          sentBytes += chunk.length;
          index++;
          onProgress?.call(sentBytes, totalBytes);
        }
      } finally {
        await handle.close();
      }

      await _sendSignedJson(
        client: client,
        peer: peer,
        secret: secret,
        path: '/api/files/complete',
        value: <String, Object?>{
          'version': 1,
          'transferId': transferId,
          'senderId': config.deviceId,
          'recipientId': peerId,
        },
      );
      onProgress?.call(totalBytes, totalBytes);
      onLog('DATA', 'Sent ${_formatTransferSize(totalBytes)} file to ${peer.deviceName}.');
    } on Object {
      try {
        await _sendSignedJson(
          client: client,
          peer: peer,
          secret: secret,
          path: '/api/files/cancel',
          value: <String, Object?>{
            'version': 1,
            'transferId': transferId,
            'senderId': config.deviceId,
            'recipientId': peerId,
          },
          checkResponse: false,
        );
      } on Object {
        // The receiver may already have closed or timed out the transfer.
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _sendSignedJson({
    required HttpClient client,
    required Peer peer,
    required String secret,
    required String path,
    required Map<String, Object?> value,
    bool checkResponse = true,
  }) async {
    final body = utf8.encode(jsonEncode(value));
    final headers = createSignedPeerHeaders(
      secret: secret,
      deviceId: config.deviceId,
      body: body,
    );
    final uri = Uri(
      scheme: 'http',
      host: peer.host,
      port: peer.httpPort,
      path: path,
    );
    final request = await client.postUrl(uri).timeout(const Duration(seconds: 10));
    request.headers.contentType = ContentType.json;
    request.contentLength = body.length;
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.add(body);
    final response = await request.close().timeout(const Duration(minutes: 2));
    final responseText = await utf8.decoder.bind(response).join();
    if (checkResponse &&
        (response.statusCode < HttpStatus.ok || response.statusCode >= HttpStatus.multipleChoices)) {
      throw HttpException(
        'Peer rejected the file transfer (${response.statusCode}): $responseText',
        uri: uri,
      );
    }
  }

  Future<void> _handleGuardedRequest(HttpRequest request) async {
    final isWebSocketRoute = request.method == 'GET' && request.uri.path == '/ws';
    if (isWebSocketRoute) {
      if (_pendingWebSocketHandshakes >= maxPendingWebSocketHandshakes) {
        onLog('WARN', 'Rejected WebSocket upgrade: too many pending handshakes.');
        await _sendJson(request.response, HttpStatus.serviceUnavailable, <String, Object?>{
          'error': 'Too many pending WebSocket handshakes. Retry shortly.',
        });
        return;
      }

      _pendingWebSocketHandshakes++;
      var handshakePending = true;
      void releaseHandshakeSlot() {
        if (!handshakePending) return;
        handshakePending = false;
        _pendingWebSocketHandshakes--;
      }
      try {
        await _handleRequest(
          request,
          onWebSocketAuthenticated: releaseHandshakeSlot,
        );
      } finally {
        releaseHandshakeSlot();
      }
      return;
    }

    if (_activeHttpRequests >= maxConcurrentHttpRequests) {
      onLog('WARN', 'Rejected HTTP request: concurrency limit reached.');
      await _sendJson(request.response, HttpStatus.serviceUnavailable, <String, Object?>{
        'error': 'HTTP request capacity is busy. Retry shortly.',
      });
      return;
    }

    _activeHttpRequests++;
    try {
      await _handleRequest(request);
    } finally {
      _activeHttpRequests--;
    }
  }

  Future<void> _handleRequest(
    HttpRequest request, {
    void Function()? onWebSocketAuthenticated,
  }) async {
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/status') {
        await _sendJson(request.response, HttpStatus.ok, statusProvider());
        return;
      }
      if (request.method == 'POST' && path == '/pair/claim') {
        await _handlePairingClaim(request);
        return;
      }
      if (request.method == 'POST' && path == '/api/write') {
        await _handleWriteRequest(request);
        return;
      }
      if (request.method == 'POST' && path.startsWith('/api/files/')) {
        await _handleFileRequest(request, path);
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
        await _serveIncomingSocket(
          socket,
          onAuthenticated: onWebSocketAuthenticated,
        );
        return;
      }
      await _sendJson(request.response, HttpStatus.notFound, <String, Object?>{
        'error': 'Not found.',
      });
    } on _PayloadTooLargeException {
      await _sendJson(request.response, HttpStatus.requestEntityTooLarge, <String, Object?>{
        'error': 'Payload exceeds the configured size limit.',
      });
    } on FileTransferException catch (error) {
      await _sendJson(request.response, error.statusCode, <String, Object?>{
        'error': error.message,
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

  Future<void> _handlePairingClaim(HttpRequest request) async {
    final handler = pairingClaimHandler;
    if (handler == null) {
      await _sendJson(request.response, HttpStatus.notFound, <String, Object?>{
        'error': 'Pairing is not enabled on this node.',
      });
      return;
    }
    final body = await _readBoundedBody(request, maxBytes: 16 * 1024);
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Pairing claim must be a JSON object.');
    }
    final remoteHost = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final result = await handler(decoded, remoteHost);
    await _sendJson(request.response, result.$1, result.$2);
  }

  Future<void> _handleWriteRequest(HttpRequest request) async {
    final body = await _readBoundedBody(
      request,
      maxBytes: config.maxPayloadBytes * 2 + 64 * 1024,
    );
    final authenticated = _authenticateSignedRequest(request, body);
    if (authenticated == null) {
      await _sendJson(request.response, HttpStatus.unauthorized, <String, Object?>{
        'error': 'Missing, expired, replayed, unpaired, or invalid Airbridge request signature.',
      });
      return;
    }
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 1 ||
        decoded['senderId'] != authenticated.deviceId ||
        decoded['recipientId'] != config.deviceId ||
        decoded['sealed'] is! Map<String, dynamic>) {
      throw const FormatException('Write body must contain a versioned encrypted peer payload.');
    }
    final cleartext = await openPeerPayload(
      secret: authenticated.secret,
      sealed: Map<String, dynamic>.from(decoded['sealed']! as Map),
      associatedData: _httpWriteAad(authenticated.deviceId, config.deviceId),
    );
    final clearValue = jsonDecode(utf8.decode(cleartext));
    if (clearValue is! Map<String, dynamic> || !clearValue.containsKey('payload')) {
      throw const FormatException('The decrypted write payload is invalid.');
    }
    final requestedName = clearValue['senderName'];
    final remoteHost = request.connectionInfo?.remoteAddress.address ?? 'HTTP peer';
    final trimmedName = requestedName is String ? requestedName.trim() : '';
    final senderName = trimmedName.isNotEmpty
        ? (trimmedName.length > 64 ? trimmedName.substring(0, 64) : trimmedName)
        : 'HTTP peer $remoteHost';
    final envelope = await publish(clearValue['payload'], senderName: senderName);
    await _sendJson(request.response, HttpStatus.created, <String, Object?>{
      'ok': true,
      'messageId': envelope['id'],
    });
  }

  Future<void> _handleFileRequest(HttpRequest request, String path) async {
    final store = fileTransferStore;
    final incomingFilesDisabled =
        allowIncomingFiles != null && !allowIncomingFiles!();
    if (store == null ||
        (incomingFilesDisabled && path != '/api/files/cancel')) {
      await _sendJson(request.response, HttpStatus.forbidden, <String, Object?>{
        'error': store == null
            ? 'File transfer is not enabled on this node.'
            : 'Incoming files are disabled in Settings.',
      });
      return;
    }
    if (path != '/api/files/start' &&
        path != '/api/files/chunk' &&
        path != '/api/files/complete' &&
        path != '/api/files/cancel') {
      await _sendJson(request.response, HttpStatus.notFound, <String, Object?>{
        'error': 'Unknown file-transfer route.',
      });
      return;
    }

    final body = await _readBoundedBody(
      request,
      maxBytes: path == '/api/files/chunk' ? 2 * 1024 * 1024 : 32 * 1024,
    );
    final authenticated = _authenticateSignedRequest(request, body);
    if (authenticated == null) {
      await _sendJson(request.response, HttpStatus.unauthorized, <String, Object?>{
        'error': 'Missing, expired, replayed, unpaired, or invalid Airbridge request signature.',
      });
      return;
    }

    final value = jsonDecode(utf8.decode(body));
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['senderId'] != authenticated.deviceId ||
        value['recipientId'] != config.deviceId) {
      throw const FormatException('File-transfer request identity or version is invalid.');
    }
    final transferId = value['transferId'];
    if (transferId is! String) {
      throw const FormatException('File-transfer request has no transfer ID.');
    }

    if (path == '/api/files/start') {
      final sealed = value['sealed'];
      if (sealed is! Map<String, dynamic>) {
        throw const FormatException('File metadata must be encrypted.');
      }
      final cleartext = await openPeerPayload(
        secret: authenticated.secret,
        sealed: Map<String, dynamic>.from(sealed),
        associatedData: _fileMetadataAad(
          authenticated.deviceId,
          config.deviceId,
          transferId,
        ),
      );
      final metadata = jsonDecode(utf8.decode(cleartext));
      if (metadata is! Map<String, dynamic>) {
        throw const FormatException('Decrypted file metadata is invalid.');
      }
      final fileName = metadata['fileName'];
      final sizeBytes = metadata['sizeBytes'];
      final digest = metadata['sha256'];
      final senderName = metadata['senderName'];
      if (fileName is! String ||
          sizeBytes is! int ||
          digest is! String ||
          senderName is! String) {
        throw const FormatException('Decrypted file metadata is incomplete.');
      }
      await store.beginTransfer(
        transferId: transferId,
        fileName: fileName,
        sizeBytes: sizeBytes,
        sha256Hex: digest,
        source: 'LAN',
        senderId: authenticated.deviceId,
        senderName: senderName,
      );
      await _sendJson(request.response, HttpStatus.created, <String, Object?>{
        'ok': true,
        'transferId': transferId,
      });
      return;
    }

    if (path == '/api/files/chunk') {
      final index = value['index'];
      final sealed = value['sealed'];
      if (index is! int || index < 0 || sealed is! Map<String, dynamic>) {
        throw const FormatException('File chunk index or encrypted data is invalid.');
      }
      final cleartext = await openPeerPayload(
        secret: authenticated.secret,
        sealed: Map<String, dynamic>.from(sealed),
        associatedData: _fileChunkAad(
          authenticated.deviceId,
          config.deviceId,
          transferId,
          index,
        ),
      );
      await store.addChunk(
        transferId: transferId,
        index: index,
        bytes: cleartext,
      );
      await _sendJson(request.response, HttpStatus.ok, <String, Object?>{
        'ok': true,
        'transferId': transferId,
        'index': index,
      });
      return;
    }

    if (path == '/api/files/complete') {
      final record = await store.completeTransfer(transferId);
      onFileReceived?.call(record);
      onLog('DATA', 'Received ${record.fileName} (${_formatTransferSize(record.sizeBytes)}).');
      await _sendJson(request.response, HttpStatus.created, <String, Object?>{
        'ok': true,
        'transferId': transferId,
      });
      return;
    }

    await store.cancelTransfer(transferId);
    await _sendJson(request.response, HttpStatus.ok, <String, Object?>{
      'ok': true,
      'transferId': transferId,
    });
  }

  _AuthenticatedPeer? _authenticateSignedRequest(
    HttpRequest request,
    List<int> body,
  ) {
    final deviceId = request.headers.value('x-airbridge-device-id');
    if (deviceId == null || deviceId.isEmpty || deviceId.length > 64) return null;
    final secret = _secretForPeer(deviceId);
    if (secret == null ||
        !_verifyHttpSignature(request, body, secret, deviceId: deviceId)) {
      return null;
    }
    return _AuthenticatedPeer(deviceId: deviceId, secret: secret);
  }

  Future<List<int>> _readBoundedBody(
    HttpRequest request, {
    int? maxBytes,
  }) async {
    final advertisedLength = request.contentLength;
    final maxLength = maxBytes ?? config.maxPayloadBytes + 64 * 1024;
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

  bool _verifyHttpSignature(
    HttpRequest request,
    List<int> body,
    String secret, {
    String? deviceId,
  }) {
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
    final nonceKey = deviceId == null ? nonce : '$deviceId:$nonce';
    if (_httpNonces.containsKey(nonceKey)) return false;

    final signedPrefix = deviceId == null
        ? '$timestamp.$nonce.'
        : '$timestamp.$nonce.$deviceId.';
    final signedBytes = <int>[...utf8.encode(signedPrefix), ...body];
    if (!verifyHmacSha256Hex(secret, signedBytes, signature)) return false;
    _httpNonces[nonceKey] = now;
    while (_httpNonces.length > 10000) {
      _httpNonces.remove(_httpNonces.keys.first);
    }
    return true;
  }

  Future<void> _serveIncomingSocket(
    WebSocket socket, {
    void Function()? onAuthenticated,
  }) async {
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
      final peerSecret = deviceId is String ? _secretForPeer(deviceId) : null;
      if (auth?['type'] != 'auth' ||
          deviceId is! String ||
          deviceId.isEmpty ||
          deviceId.length > 64 ||
          deviceId == config.deviceId ||
          peerSecret == null ||
          !verifyHmacSha256Hex(
            peerSecret,
            utf8.encode('airbridge-ws-v1:$challenge:$deviceId'),
            signature is String ? signature : null,
          )) {
        await socket.close(WebSocketStatus.policyViolation, 'Invalid Airbridge auth');
        return;
      }

      if (_links.length >= 256) {
        await socket.close(WebSocketStatus.policyViolation, 'Peer connection limit reached');
        return;
      }
      link = _SocketLink(socket: socket, peerId: deviceId);
      _links.add(link);
      onAuthenticated?.call();
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
        final secret = _secretForPeer(link.peerId);
        final sealed = frame['sealed'];
        if (secret == null ||
            frame['senderId'] != link.peerId ||
            frame['recipientId'] != config.deviceId ||
            sealed is! Map<String, dynamic>) {
          onLog('WARN', 'Rejected unauthenticated or cleartext WebSocket write from ${link.peerId}.');
          return;
        }
        final cleartext = await openPeerPayload(
          secret: secret,
          sealed: Map<String, dynamic>.from(sealed),
          associatedData: _wsWriteAad(link.peerId, config.deviceId),
        );
        final clearValue = jsonDecode(utf8.decode(cleartext));
        if (clearValue is! Map<String, dynamic> || !clearValue.containsKey('payload')) {
          throw const FormatException('The decrypted WebSocket write payload is invalid.');
        }
        final envelope = await publish(
          clearValue['payload'],
          senderName: clearValue['senderName'] is String
              ? clearValue['senderName']! as String
              : 'WebSocket peer ${link.peerId}',
        );
        link.socket.add(jsonEncode(<String, Object?>{
          'type': 'accepted',
          'messageId': envelope['id'],
        }));
        return;
      case 'message':
        final secret = _secretForPeer(link.peerId);
        final sealed = frame['sealed'];
        final messageId = frame['messageId'];
        if (secret == null ||
            frame['version'] != 2 ||
            frame['senderId'] != link.peerId ||
            frame['recipientId'] != config.deviceId ||
            messageId is! String ||
            sealed is! Map<String, dynamic>) {
          onLog('WARN', 'Rejected cleartext or malformed mesh message from ${link.peerId}.');
          return;
        }
        final cleartext = await openPeerPayload(
          secret: secret,
          sealed: Map<String, dynamic>.from(sealed),
          associatedData: _wsMessageAad(link.peerId, config.deviceId, messageId),
        );
        final rawEnvelope = jsonDecode(utf8.decode(cleartext));
        if (rawEnvelope is! Map<String, dynamic>) {
          onLog('WARN', 'Rejected malformed encrypted mesh envelope from ${link.peerId}.');
          return;
        }
        final envelope = Map<String, dynamic>.from(rawEnvelope);
        if (!_isValidEnvelope(envelope) || envelope['id'] != messageId) {
          onLog('WARN', 'Rejected malformed encrypted mesh envelope from ${link.peerId}.');
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
    final version = envelope['version'];
    final id = envelope['id'];
    final senderId = envelope['senderId'];
    final senderName = envelope['senderName'];
    final createdAt = envelope['createdAt'];
    final algorithm = envelope['algorithm'];
    if (version is! int ||
        version != 1 ||
        id is! String ||
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
    for (final link in _links.toList(growable: false)) {
      if (identical(link, origin) || link.socket.closeCode != null) continue;
      try {
        final secret = _secretForPeer(link.peerId);
        if (secret == null) {
          onLog('WARN', 'Cannot encrypt a message for untrusted peer ${link.peerId}.');
          continue;
        }
        final sealed = await sealPeerPayload(
          secret: secret,
          cleartext: utf8.encode(jsonEncode(envelope)),
          associatedData: _wsMessageAad(
            config.deviceId,
            link.peerId,
            messageId,
          ),
        );
        link.socket.add(jsonEncode(<String, Object?>{
          'type': 'message',
          'version': 2,
          'senderId': config.deviceId,
          'recipientId': link.peerId,
          'messageId': messageId,
          'sealed': sealed,
        }));
      } on Object catch (error) {
        onLog('WARN', 'Could not encrypt or forward message to ${link.peerId}: $error');
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

  String? _secretForPeer(String peerId) {
    final pairedSecret = peerSecretProvider?.call(peerId);
    if (pairedSecret != null && pairedSecret.isNotEmpty) return pairedSecret;
    return config.hasSharedSecret ? config.sharedSecret : null;
  }

  String _authFrame(String challenge, String peerId) {
    final secret = _secretForPeer(peerId);
    if (secret == null) {
      throw StateError('This device has not been paired with $peerId.');
    }
    return jsonEncode(<String, Object?>{
      'type': 'auth',
      'deviceId': config.deviceId,
      'signature': hmacTextHex(
        secret,
        'airbridge-ws-v1:$challenge:${config.deviceId}',
      ),
    });
  }

  void _reconcilePeerConnections() {
    if (_stopped || _links.length >= 256) return;
    final now = DateTime.now();
    for (final peer in _knownPeers.values) {
      if (_links.length + _dialing.length >= 256) return;
      // Pairing is required when no installation-wide secret is configured.
      if (_secretForPeer(peer.deviceId) == null) continue;
      // Deterministically choose one outbound connection per pair.
      if (config.deviceId.compareTo(peer.deviceId) >= 0) continue;
      final retryAt = _retryAfter[peer.deviceId];
      if (retryAt != null && now.isBefore(retryAt)) continue;
      _retryAfter.remove(peer.deviceId);
      if (_dialing.contains(peer.deviceId) ||
          _links.any((link) => link.peerId == peer.deviceId)) {
        continue;
      }
      unawaited(_dialPeer(peer));
    }
  }

  void _scheduleReconnect(String peerId) {
    if (_stopped || !_knownPeers.containsKey(peerId)) return;
    final attempt = (_reconnectAttempts[peerId] ?? 0) + 1;
    _reconnectAttempts[peerId] = attempt;
    final delay = _reconnectBackoff.delayForAttempt(attempt);
    _retryAfter[peerId] = DateTime.now().add(delay);
    onLog(
      'WARN',
      'Peer $peerId reconnect scheduled in ${delay.inMilliseconds} ms (attempt $attempt).',
    );
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
      if (_stopped) return;
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
      connectedSocket.add(_authFrame(challenge, peer.deviceId));
      final gotHello = await streamIterator.moveNext().timeout(
        const Duration(seconds: 8),
      );
      if (!gotHello) throw const FormatException('Peer closed before hello.');
      final hello = _decodeFrame(streamIterator.current);
      if (hello?['type'] != 'hello' || hello?['deviceId'] != peer.deviceId) {
        throw const FormatException('Peer identity did not match its discovery beacon.');
      }
      if (_stopped) return;
      _reconnectAttempts.remove(peer.deviceId);
      _retryAfter.remove(peer.deviceId);
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
      if (!_stopped &&
          _knownPeers.containsKey(peer.deviceId) &&
          !_links.any((link) => link.peerId == peer.deviceId)) {
        _scheduleReconnect(peer.deviceId);
      }
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

class _AuthenticatedPeer {
  const _AuthenticatedPeer({required this.deviceId, required this.secret});

  final String deviceId;
  final String secret;
}

String _httpWriteAad(String senderId, String recipientId) =>
    'airbridge-http-write-v1:$senderId:$recipientId';

String _fileMetadataAad(String senderId, String recipientId, String transferId) =>
    'airbridge-file-metadata-v1:$senderId:$recipientId:$transferId';

String _fileChunkAad(
  String senderId,
  String recipientId,
  String transferId,
  int index,
) =>
    'airbridge-file-chunk-v1:$senderId:$recipientId:$transferId:$index';

String _wsWriteAad(String senderId, String recipientId) =>
    'airbridge-ws-write-v1:$senderId:$recipientId';

String _wsMessageAad(String senderId, String recipientId, String messageId) =>
    'airbridge-ws-message-v2:$senderId:$recipientId:$messageId';

String _formatTransferSize(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _SocketLink {
  const _SocketLink({required this.socket, required this.peerId});

  final WebSocket socket;
  final String peerId;
}

class _PayloadTooLargeException implements Exception {
  const _PayloadTooLargeException();
}
