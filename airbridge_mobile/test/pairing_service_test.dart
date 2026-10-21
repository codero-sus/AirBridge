import 'dart:async';
import 'dart:io';

import 'package:airbridge_mobile/config/node_config.dart';
import 'package:airbridge_mobile/models/peer.dart';
import 'package:airbridge_mobile/services/api_gateway.dart';
import 'package:airbridge_mobile/services/pairing_service.dart';
import 'package:flutter_test/flutter_test.dart';

const String _hostId = '10000000-0000-4000-8000-000000000001';
const String _clientId = '20000000-0000-4000-8000-000000000002';

Future<int> _availablePort() async {
  final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

Future<void> _withDirectHttp(Future<void> Function() body) =>
    HttpOverrides.runZoned(
      body,
      createHttpClient: (_) => HttpClient()..findProxy = (_) => 'DIRECT',
    );

NodeConfig _config({
  required String deviceId,
  required String deviceName,
  required Directory directory,
  required int httpPort,
  String sharedSecret = '',
}) =>
    NodeConfig.forTesting(
      deviceId: deviceId,
      deviceName: deviceName,
      supportDirectory: directory,
      messageDirectory: directory,
      httpPort: httpPort,
      sharedSecret: sharedSecret,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('QR invitation parses and produces the same six-digit verification code', () async {
    final directory = await Directory.systemTemp.createTemp('airbridge-pair-qr-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final config = _config(
      deviceId: _hostId,
      deviceName: 'QR host',
      directory: directory,
      httpPort: 8765,
    );
    final service = PairingService(config: config, onPeerTrusted: (_, __) {});
    final invitation = await service.createInvitation(
      hostAddress: '192.168.1.20',
      httpPort: 8765,
      udpPort: 47660,
    );

    final parsed = PairingInvitation.parse(invitation.qrPayload);
    expect(parsed.hostDeviceId, _hostId);
    expect(parsed.hostDeviceName, 'QR host');
    expect(parsed.secret, invitation.secret);
    expect(parsed.verificationCode, matches(RegExp(r'^\d{6}$')));
    expect(parsed.verificationCode, invitation.verificationCode);
    expect(() => PairingInvitation.parse('https://example.com'), throwsFormatException);
  });

  test('QR pairing authenticates, encrypts the response, persists both trust records, and is one-use', () async {
    await _withDirectHttp(() async {
      final hostDirectory = await Directory.systemTemp.createTemp('airbridge-pair-host-');
      final clientDirectory = await Directory.systemTemp.createTemp('airbridge-pair-client-');
      final port = await _availablePort();
      var clientPort = await _availablePort();
      while (clientPort == port) {
        clientPort = await _availablePort();
      }
      final hostConfig = _config(
        deviceId: _hostId,
        deviceName: 'Host phone',
        directory: hostDirectory,
        httpPort: port,
      );
      final clientConfig = _config(
        deviceId: _clientId,
        deviceName: 'Laptop',
        directory: clientDirectory,
        httpPort: clientPort,
      );
      var observedRemoteHost = '';
      final host = PairingService(
        config: hostConfig,
        onPeerTrusted: (_, remoteHost) => observedRemoteHost = remoteHost,
      );
      final client = PairingService(config: clientConfig, onPeerTrusted: (_, __) {});
      await host.load();
      await client.load();
      final invitation = await host.createInvitation(
        hostAddress: '127.0.0.1',
        httpPort: port,
        udpPort: hostConfig.udpPort,
      );
      final hostLinked = Completer<void>();
      final clientLinked = Completer<void>();
      late ApiGateway gateway;
      ApiGateway? clientGateway;
      gateway = ApiGateway(
        config: hostConfig,
        statusProvider: () => <String, Object?>{'deviceId': _hostId},
        payloadFactory: (_, {required senderName}) async => <String, dynamic>{},
        onEnvelope: (_, {required local}) async {},
        onLog: (_, __) {},
        onConnectionsChanged: () {
          if (gateway.connectedPeerIds.contains(_clientId) && !hostLinked.isCompleted) {
            hostLinked.complete();
          }
        },
        peerSecretProvider: host.secretForPeer,
        pairingClaimHandler: host.handleClaim,
      );
      await gateway.start();
      addTearDown(() async {
        await clientGateway?.stop();
        await gateway.stop();
        if (await hostDirectory.exists()) await hostDirectory.delete(recursive: true);
        if (await clientDirectory.exists()) await clientDirectory.delete(recursive: true);
      });

      final pairedHost = await client.joinInvitation(
        qrPayload: invitation.qrPayload,
        httpPort: clientConfig.httpPort,
        udpPort: clientConfig.udpPort,
      );
      expect(pairedHost.deviceId, _hostId);
      expect(pairedHost.deviceName, 'Host phone');
      expect(host.secretForPeer(_clientId), isNotNull);
      expect(client.secretForPeer(_hostId), host.secretForPeer(_clientId));
      expect(observedRemoteHost, '127.0.0.1');

      final reloadedHost = PairingService(config: hostConfig, onPeerTrusted: (_, __) {});
      final reloadedClient = PairingService(config: clientConfig, onPeerTrusted: (_, __) {});
      await reloadedHost.load();
      await reloadedClient.load();
      expect(reloadedHost.secretForPeer(_clientId), host.secretForPeer(_clientId));
      expect(reloadedClient.secretForPeer(_hostId), client.secretForPeer(_hostId));

      clientGateway = ApiGateway(
        config: clientConfig,
        statusProvider: () => <String, Object?>{'deviceId': _clientId},
        payloadFactory: (_, {required senderName}) async => <String, dynamic>{},
        onEnvelope: (_, {required local}) async {},
        onLog: (_, __) {},
        onConnectionsChanged: () {
          if (clientGateway?.connectedPeerIds.contains(_hostId) == true &&
              !clientLinked.isCompleted) {
            clientLinked.complete();
          }
        },
        peerSecretProvider: client.secretForPeer,
      );
      await clientGateway.start();
      gateway.updatePeer(
        Peer(
          deviceId: _clientId,
          deviceName: 'Laptop',
          host: '127.0.0.1',
          httpPort: clientPort,
          udpPort: clientConfig.udpPort,
          lastSeen: DateTime.now(),
          role: 'peer',
          masterId: _hostId,
        ),
      );
      clientGateway.updatePeer(
        Peer(
          deviceId: _hostId,
          deviceName: 'Host phone',
          host: '127.0.0.1',
          httpPort: port,
          udpPort: hostConfig.udpPort,
          lastSeen: DateTime.now(),
          role: 'master',
          masterId: _hostId,
        ),
      );
      await Future.wait<void>(<Future<void>>[
        hostLinked.future.timeout(const Duration(seconds: 10)),
        clientLinked.future.timeout(const Duration(seconds: 10)),
      ]);

      await expectLater(
        client.joinInvitation(
          qrPayload: invitation.qrPayload,
          httpPort: clientConfig.httpPort,
          udpPort: clientConfig.udpPort,
        ),
        throwsA(isA<PairingException>()),
      );
    });
  });

  test('pairing refuses mixed installation-wide secret settings', () async {
    final hostDirectory = await Directory.systemTemp.createTemp('airbridge-pair-key-host-');
    final clientDirectory = await Directory.systemTemp.createTemp('airbridge-pair-key-client-');
    addTearDown(() async {
      if (await hostDirectory.exists()) await hostDirectory.delete(recursive: true);
      if (await clientDirectory.exists()) await clientDirectory.delete(recursive: true);
    });
    final hostConfig = _config(
      deviceId: _hostId,
      deviceName: 'Secret host',
      directory: hostDirectory,
      httpPort: 8765,
      sharedSecret: 'host-installation-secret-that-is-not-on-client',
    );
    final clientConfig = _config(
      deviceId: _clientId,
      deviceName: 'Unconfigured client',
      directory: clientDirectory,
      httpPort: 8766,
    );
    final host = PairingService(config: hostConfig, onPeerTrusted: (_, __) {});
    final client = PairingService(config: clientConfig, onPeerTrusted: (_, __) {});
    final invitation = await host.createInvitation(
      hostAddress: '127.0.0.1',
      httpPort: 8765,
      udpPort: 47660,
    );

    await expectLater(
      client.joinInvitation(
        qrPayload: invitation.qrPayload,
        httpPort: clientConfig.httpPort,
        udpPort: clientConfig.udpPort,
      ),
      throwsA(isA<PairingException>()),
    );
  });

  test('a pairing QR locks after five invalid proofs', () async {
    final directory = await Directory.systemTemp.createTemp('airbridge-pair-lock-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final config = _config(
      deviceId: _hostId,
      deviceName: 'Host',
      directory: directory,
      httpPort: 8765,
    );
    final service = PairingService(config: config, onPeerTrusted: (_, __) {});
    final invitation = await service.createInvitation(
      hostAddress: '127.0.0.1',
      httpPort: 8765,
      udpPort: 47660,
    );
    final invalidProof = List<String>.filled(64, '0').join();

    for (var attempt = 0; attempt < 5; attempt++) {
      final result = await service.handleClaim(
        <String, dynamic>{
          'version': 1,
          'pairingId': invitation.pairingId,
          'deviceId': _clientId,
          'deviceName': 'Untrusted device',
          'httpPort': 8766,
          'udpPort': 47660,
          'nonce': attempt.toRadixString(16).padLeft(64, '0'),
          'proof': invalidProof,
        },
        '127.0.0.1',
      );
      expect(result.$1, HttpStatus.unauthorized);
    }
    final locked = await service.handleClaim(
      <String, dynamic>{'pairingId': invitation.pairingId},
      '127.0.0.1',
    );
    expect(locked.$1, HttpStatus.gone);
  });

  test('expired QR invitations are rejected before pairing', () async {
    final directory = await Directory.systemTemp.createTemp('airbridge-pair-expired-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final config = _config(
      deviceId: _hostId,
      deviceName: 'Host',
      directory: directory,
      httpPort: 8765,
    );
    final service = PairingService(config: config, onPeerTrusted: (_, __) {});
    final invitation = await service.createInvitation(
      hostAddress: '127.0.0.1',
      httpPort: 8765,
      udpPort: 47660,
      now: DateTime.now().toUtc().subtract(const Duration(minutes: 6)),
    );
    expect(() => PairingInvitation.parse(invitation.qrPayload), throwsFormatException);
  });
}
