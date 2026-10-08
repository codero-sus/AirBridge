import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:airbridge_mobile/config/node_config.dart';
import 'package:airbridge_mobile/models/peer.dart';
import 'package:airbridge_mobile/services/api_gateway.dart';
import 'package:airbridge_mobile/services/security.dart';
import 'package:flutter_test/flutter_test.dart';

const String _sharedSecret = 'integration-test-shared-secret-32-bytes-minimum';
const String _leftId = '00000000-0000-4000-8000-000000000001';
const String _rightId = '00000000-0000-4000-8000-000000000002';

Future<int> _availablePort() async {
  final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

Future<Directory> _newDirectory(String name) async =>
    Directory.systemTemp.createTemp('airbridge-$name-');

Future<void> _withDirectHttp(Future<void> Function() body) {
  final overrides = _DirectHttpOverrides();
  return HttpOverrides.runZoned(
    body,
    createHttpClient: overrides.createHttpClient,
  );
}

class _DirectHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

NodeConfig _testConfig({
  required String deviceId,
  required String deviceName,
  required Directory directory,
  required int httpPort,
}) =>
    NodeConfig.forTesting(
      deviceId: deviceId,
      deviceName: deviceName,
      supportDirectory: directory,
      messageDirectory: directory,
      httpPort: httpPort,
      sharedSecret: _sharedSecret,
    );

PayloadFactory _envelopeFactory(String senderId) {
  var sequence = 0;
  return (payload, {required senderName}) async => <String, dynamic>{
        'version': 1,
        'id': '$senderId-${sequence++}',
        'senderId': senderId,
        'senderName': senderName,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'algorithm': 'none',
        'payload': payload,
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('status, signed writes, and WebSocket challenge flow work end-to-end', () async {
    await _withDirectHttp(() async {
      final directory = await _newDirectory('gateway');
      final port = await _availablePort();
      final config = _testConfig(
        deviceId: _leftId,
        deviceName: 'Gateway test node',
        directory: directory,
        httpPort: port,
      );
      final received = <Map<String, dynamic>>[];
      final gateway = ApiGateway(
        config: config,
        statusProvider: () => <String, Object?>{
          'deviceId': config.deviceId,
          'deviceName': config.deviceName,
          'httpPort': config.httpPort,
          'bindAddress': '0.0.0.0',
          'role': 'master',
        },
        payloadFactory: _envelopeFactory(config.deviceId),
        onEnvelope: (envelope, {required local}) async {
          received.add(envelope);
        },
        onLog: (_, __) {},
        onConnectionsChanged: () {},
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      await gateway.start();
      addTearDown(() async {
        client.close(force: true);
        await gateway.stop();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final statusRequest = await client.getUrl(Uri.parse('http://127.0.0.1:$port/status'));
      final statusResponse = await statusRequest.close();
      final statusBody = await utf8.decoder.bind(statusResponse).join();
      expect(
        statusResponse.statusCode,
        HttpStatus.ok,
        reason: 'GET /status returned ${statusResponse.statusCode} with body: $statusBody',
      );
      expect(
        statusBody,
        isNotEmpty,
        reason: 'GET /status returned an empty body (${statusResponse.headers.contentType}).',
      );
      final status = jsonDecode(statusBody) as Map<String, dynamic>;
      expect(status['deviceId'], _leftId);
      expect(status['bindAddress'], '0.0.0.0');
      expect(status['role'], 'master');

      final body = jsonEncode(<String, Object?>{
        'payload': <String, Object?>{'source': 'signed HTTP'},
      });
      final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      const nonce = '0123456789abcdef0123456789abcdef';
      final signature = hmacSha256Hex(
        _sharedSecret,
        utf8.encode('$timestamp.$nonce.$body'),
      );
      final writeRequest = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/api/write'),
      );
      writeRequest.headers.contentType = ContentType.json;
      writeRequest.headers.set('X-Airbridge-Timestamp', '$timestamp');
      writeRequest.headers.set('X-Airbridge-Nonce', nonce);
      writeRequest.headers.set('X-Airbridge-Signature', signature);
      writeRequest.write(body);
      final writeResponse = await writeRequest.close();
      final writeResult = jsonDecode(await utf8.decoder.bind(writeResponse).join())
          as Map<String, dynamic>;
      expect(writeResponse.statusCode, HttpStatus.created);
      expect(writeResult['ok'], isTrue);
      expect(received, hasLength(1));

      final replayRequest = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/api/write'),
      );
      replayRequest.headers.contentType = ContentType.json;
      replayRequest.headers.set('X-Airbridge-Timestamp', '$timestamp');
      replayRequest.headers.set('X-Airbridge-Nonce', nonce);
      replayRequest.headers.set('X-Airbridge-Signature', signature);
      replayRequest.write(body);
      final replayResponse = await replayRequest.close();
      await replayResponse.drain<void>();
      expect(replayResponse.statusCode, HttpStatus.unauthorized);
      expect(received, hasLength(1));

      final webSocketClient = HttpClient()..findProxy = (_) => 'DIRECT';
      final webSocket = await WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        customClient: webSocketClient,
      );
      final iterator = StreamIterator<dynamic>(webSocket);
      addTearDown(() async {
        await iterator.cancel();
        await webSocket.close();
        webSocketClient.close(force: true);
      });
      expect(await iterator.moveNext().timeout(const Duration(seconds: 3)), isTrue);
      final challenge = jsonDecode(iterator.current as String) as Map<String, dynamic>;
      expect(challenge['type'], 'challenge');
      final challengeNonce = challenge['nonce'] as String;
      const clientId = 'websocket-test-client';
      webSocket.add(jsonEncode(<String, Object?>{
        'type': 'auth',
        'deviceId': clientId,
        'signature': hmacTextHex(
          _sharedSecret,
          'airbridge-ws-v1:$challengeNonce:$clientId',
        ),
      }));
      expect(await iterator.moveNext().timeout(const Duration(seconds: 3)), isTrue);
      final hello = jsonDecode(iterator.current as String) as Map<String, dynamic>;
      expect(hello['type'], 'hello');
      expect(hello['deviceId'], _leftId);

      webSocket.add(jsonEncode(<String, Object?>{
        'type': 'write',
        'payload': <String, Object?>{'source': 'websocket'},
      }));
      var gotEcho = false;
      var gotAccepted = false;
      while (!gotEcho || !gotAccepted) {
        expect(await iterator.moveNext().timeout(const Duration(seconds: 3)), isTrue);
        final frame = jsonDecode(iterator.current as String) as Map<String, dynamic>;
        gotEcho |= frame['type'] == 'message';
        gotAccepted |= frame['type'] == 'accepted';
      }
      expect(received, hasLength(2));
    });
  });

  test(
    'discovered peer establishes a challenged WebSocket mesh link and receives messages',
    () async {
      await _withDirectHttp(() async {
        final leftDirectory = await _newDirectory('left');
        final rightDirectory = await _newDirectory('right');
        final leftPort = await _availablePort();
        final rightPort = await _availablePort();
        final leftConfig = _testConfig(
          deviceId: _leftId,
          deviceName: 'Left node',
          directory: leftDirectory,
          httpPort: leftPort,
        );
        final rightConfig = _testConfig(
          deviceId: _rightId,
          deviceName: 'Right node',
          directory: rightDirectory,
          httpPort: rightPort,
        );
        final leftLinked = Completer<void>();
        final rightLinked = Completer<void>();
        final messageReceived = Completer<Map<String, dynamic>>();
        late ApiGateway left;
        late ApiGateway right;

        left = ApiGateway(
          config: leftConfig,
          statusProvider: () => <String, Object?>{'deviceId': leftConfig.deviceId},
          payloadFactory: _envelopeFactory(leftConfig.deviceId),
          onEnvelope: (envelope, {required local}) async {},
          onLog: (_, __) {},
          onConnectionsChanged: () {
            if (left.connectedPeerIds.contains(_rightId) && !leftLinked.isCompleted) {
              leftLinked.complete();
            }
          },
        );
        right = ApiGateway(
          config: rightConfig,
          statusProvider: () => <String, Object?>{'deviceId': rightConfig.deviceId},
          payloadFactory: _envelopeFactory(rightConfig.deviceId),
          onEnvelope: (envelope, {required local}) async {
            if (!local && !messageReceived.isCompleted) messageReceived.complete(envelope);
          },
          onLog: (_, __) {},
          onConnectionsChanged: () {
            if (right.connectedPeerIds.contains(_leftId) && !rightLinked.isCompleted) {
              rightLinked.complete();
            }
          },
        );
        await right.start();
        await left.start();
        addTearDown(() async {
          await left.stop();
          await right.stop();
          if (await leftDirectory.exists()) await leftDirectory.delete(recursive: true);
          if (await rightDirectory.exists()) await rightDirectory.delete(recursive: true);
        });

        left.updatePeer(
          Peer(
            deviceId: _rightId,
            deviceName: rightConfig.deviceName,
            host: '127.0.0.1',
            httpPort: rightPort,
            udpPort: rightConfig.udpPort,
            lastSeen: DateTime.now(),
            role: 'peer',
            masterId: _leftId,
          ),
        );
        await leftLinked.future.timeout(const Duration(seconds: 10));
        await rightLinked.future.timeout(const Duration(seconds: 10));

        await left.publish(<String, Object?>{'mesh': 'hello peer'});
        final envelope = await messageReceived.future.timeout(const Duration(seconds: 5));
        expect(envelope['senderId'], _leftId);
        expect(envelope['payload'], <String, Object?>{'mesh': 'hello peer'});
      });
    },
  );
}
