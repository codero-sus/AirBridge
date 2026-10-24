import 'dart:async';
import 'dart:io';

import 'package:airbridge_mobile/config/node_config.dart';
import 'package:airbridge_mobile/models/peer.dart';
import 'package:airbridge_mobile/services/api_gateway.dart';
import 'package:airbridge_mobile/services/file_transfer_store.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

const String _leftId = '00000000-0000-4000-8000-000000000001';
const String _rightId = '00000000-0000-4000-8000-000000000002';
const String _pairSecret = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Future<int> _availablePort() async {
  final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sends and receives a multi-chunk file with encrypted metadata and chunks', () async {
    await _withDirectHttp(() async {
      final leftDirectory = await Directory.systemTemp.createTemp('airbridge-file-left-');
      final rightDirectory = await Directory.systemTemp.createTemp('airbridge-file-right-');
      final sourceDirectory = await Directory.systemTemp.createTemp('airbridge-file-source-');
      final leftPort = await _availablePort();
      final rightPort = await _availablePort();
      const bytesCount = 2 * 1024 * 1024 + 37;
      final contents = List<int>.generate(bytesCount, (index) => index % 251);
      final source = File('${sourceDirectory.path}${Platform.pathSeparator}payload.bin');
      await source.writeAsBytes(contents, flush: true);

      NodeConfig makeConfig(String id, String name, Directory directory, int port) =>
          NodeConfig.forTesting(
            deviceId: id,
            deviceName: name,
            supportDirectory: directory,
            messageDirectory: directory,
            httpPort: port,
            sharedSecret: '',
          );

      final leftConfig = makeConfig(_leftId, 'Receiving node', leftDirectory, leftPort);
      final rightConfig = makeConfig(_rightId, 'Sending node', rightDirectory, rightPort);
      final receivedStore = FileTransferStore(supportDirectory: leftDirectory);
      await receivedStore.loadExisting();
      final receivedFile = Completer<FileTransferRecord>();
      final leftGateway = ApiGateway(
        config: leftConfig,
        statusProvider: () => <String, Object?>{'deviceId': _leftId},
        payloadFactory: (payload, {required senderName}) async => <String, dynamic>{},
        onEnvelope: (_, {required local}) async {},
        onLog: (_, __) {},
        onConnectionsChanged: () {},
        peerSecretProvider: (id) => id == _rightId ? _pairSecret : null,
        fileTransferStore: receivedStore,
        allowIncomingFiles: () => true,
        onFileReceived: (record) {
          if (!receivedFile.isCompleted) receivedFile.complete(record);
        },
      );
      final rightGateway = ApiGateway(
        config: rightConfig,
        statusProvider: () => <String, Object?>{'deviceId': _rightId},
        payloadFactory: (payload, {required senderName}) async => <String, dynamic>{},
        onEnvelope: (_, {required local}) async {},
        onLog: (_, __) {},
        onConnectionsChanged: () {},
        peerSecretProvider: (id) => id == _leftId ? _pairSecret : null,
      );
      await leftGateway.start();
      await rightGateway.start();
      rightGateway.updatePeer(
        Peer(
          deviceId: _leftId,
          deviceName: 'Receiving node',
          host: '127.0.0.1',
          httpPort: leftPort,
          udpPort: 47660,
          lastSeen: DateTime.now(),
          role: 'peer',
          masterId: _leftId,
        ),
      );
      addTearDown(() async {
        await leftGateway.stop();
        await rightGateway.stop();
        for (final directory in <Directory>[leftDirectory, rightDirectory, sourceDirectory]) {
          if (await directory.exists()) await directory.delete(recursive: true);
        }
      });

      var sentBytes = 0;
      try {
        await rightGateway.sendFile(
          path: source.path,
          peerId: _leftId,
          onProgress: (sent, _) => sentBytes = sent,
        );
      } on Object catch (error, stackTrace) {
        debugPrint('FILE_TRANSFER_GATEWAY_SEND_ERROR: $error');
        debugPrint('$stackTrace');
        rethrow;
      }
      final record = await receivedFile.future.timeout(const Duration(seconds: 15));
      expect(sentBytes, bytesCount);
      expect(record.fileName, 'payload.bin');
      expect(record.source, 'LAN');
      expect(await File(record.path).readAsBytes(), contents);
    });
  });
}
