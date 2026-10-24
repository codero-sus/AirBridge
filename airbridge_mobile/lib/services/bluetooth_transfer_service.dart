import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../config/node_config.dart';
import 'file_transfer_store.dart';
import 'security.dart';

const String _serviceUuid = 'a7f30001-7b9a-4b1d-9c8c-7f6a4d1e0001';
const String _identityCharacteristicUuid = 'a7f30002-7b9a-4b1d-9c8c-7f6a4d1e0001';
const String _dataCharacteristicUuid = 'a7f30003-7b9a-4b1d-9c8c-7f6a4d1e0001';
const int _fragmentHeaderBytes = 8;
const int _maxBlePacketBytes = 128 * 1024;
const int _maxBleFileChunkBytes = 12 * 1024;
const int _lowMtuBleFileThreshold = 64;
const int _maxLowMtuBleFileBytes = 10 * 1024 * 1024;

class BluetoothTransferService {
  BluetoothTransferService({
    required this.config,
    required this.fileStore,
    required this.peerSecretProvider,
    required this.allowIncomingFiles,
    required this.onFileReceived,
    required this.onMessageReceived,
    required this.onLog,
    required this.onChanged,
  });

  final NodeConfig config;
  final FileTransferStore fileStore;
  final String? Function(String deviceId) peerSecretProvider;
  final bool Function() allowIncomingFiles;
  final void Function(FileTransferRecord record) onFileReceived;
  final Future<void> Function({
    required String senderId,
    required String senderName,
    required Object? payload,
  }) onMessageReceived;
  final void Function(String level, String message) onLog;
  final VoidCallback onChanged;

  final Map<String, BleDevice> _devices = <String, BleDevice>{};
  final Map<String, _BleAssembly> _assemblies = <String, _BleAssembly>{};
  final Set<String> _connectedDevices = <String>{};
  Future<void> _eventQueue = Future<void>.value();
  final Random _random = Random.secure();
  bool _enabled = false;
  bool _scanning = false;
  bool _advertising = false;
  bool _peripheralSupported = false;
  String _status = 'Bluetooth is off';
  String? _lastError;

  bool get isEnabled => _enabled;
  bool get isScanning => _scanning;
  bool get isAdvertising => _advertising;
  bool get supportsPeripheralMode => _peripheralSupported;
  String get status => _status;
  String? get lastError => _lastError;
  List<BleDevice> get devices => List<BleDevice>.unmodifiable(_devices.values);

  Future<void> start() async {
    if (_enabled) return;
    _lastError = null;
    _status = 'Requesting Bluetooth access…';
    _notify();
    try {
      await UniversalBle.requestPermissions();
      final availability = await UniversalBle.getBluetoothAvailabilityState();
      if (availability != AvailabilityState.poweredOn) {
        throw StateError('Bluetooth is ${availability.name}. Turn Bluetooth on and try again.');
      }

      UniversalBle.onScanResult = _handleScanResult;
      await _preparePeripheral();
      _enabled = true;
      _status = _peripheralSupported
          ? (_advertising
              ? 'Advertising securely • ready to scan and transfer'
              : 'Bluetooth ready • advertising unavailable on this adapter')
          : 'Bluetooth ready • this platform can scan/send but cannot advertise/receive';
      onLog('INFO', _status);
      _notify();
    } on Object catch (error) {
      _lastError = error.toString();
      _status = 'Bluetooth unavailable';
      onLog('WARN', 'Bluetooth could not start: $error');
      _notify();
      rethrow;
    }
  }

  Future<void> stop() async {
    if (!_enabled && !_scanning && !_advertising) return;
    try {
      if (_scanning) await UniversalBle.stopScan();
    } on Object catch (error) {
      onLog('WARN', 'Could not stop the Bluetooth scan: $error');
    }
    try {
      if (_advertising) await UniversalBlePeripheral.stopAdvertising();
    } on Object catch (error) {
      onLog('WARN', 'Could not stop Bluetooth advertising: $error');
    }
    for (final deviceId in _connectedDevices.toList(growable: false)) {
      try {
        await UniversalBle.disconnect(deviceId, timeout: const Duration(seconds: 3));
      } on Object {
        // Device may already have disconnected.
      }
    }
    _connectedDevices.clear();
    UniversalBle.onScanResult = null;
    _assemblies.clear();
    _enabled = false;
    _scanning = false;
    _advertising = false;
    _devices.clear();
    _status = 'Bluetooth is off';
    _lastError = null;
    _notify();
  }

  Future<void> startScan() async {
    if (!_enabled) await start();
    if (_scanning) return;
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: <String>[_serviceUuid]),
        skipDuplicates: true,
      );
      _scanning = true;
      _status = _advertising
          ? 'Advertising • scanning for nearby Airbridge devices'
          : 'Scanning for nearby Airbridge devices';
      _notify();
    } on Object catch (error) {
      _lastError = error.toString();
      _status = 'Bluetooth scan failed';
      onLog('WARN', 'Bluetooth scan failed: $error');
      _notify();
      rethrow;
    }
  }

  Future<void> stopScan() async {
    if (!_scanning) return;
    await UniversalBle.stopScan();
    _scanning = false;
    _status = _advertising ? 'Advertising securely' : 'Bluetooth ready';
    _notify();
  }

  Future<void> sendMessage({
    required BleDevice device,
    required Object? payload,
    required String senderName,
  }) async {
    if (!_enabled) throw StateError('Enable Bluetooth in Settings first.');
    final connection = await _connectToPeer(device);
    try {
      final messageId = _newId();
      final plaintext = utf8.encode(jsonEncode(<String, Object?>{
        'payload': payload,
        'senderName': senderName,
      }));
      await _sendEncryptedEvent(
        deviceId: device.deviceId,
        peerId: connection.peerId,
        secret: connection.secret,
        kind: 'message',
        transferId: messageId,
        index: null,
        plaintext: plaintext,
        mtu: connection.mtu,
      );
      _status = 'Message sent to ${device.name ?? connection.peerName}';
      onLog('DATA', 'Sent an encrypted Bluetooth message to ${connection.peerName}.');
      _notify();
    } finally {
      await _disconnect(device.deviceId);
    }
  }

  Future<void> sendFile({
    required BleDevice device,
    required String path,
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    if (!_enabled) throw StateError('Enable Bluetooth in Settings first.');
    final file = File(path);
    if (!await file.exists()) throw FileSystemException('The selected file no longer exists.', path);
    final totalBytes = await file.length();
    if (totalBytes > maxSupportedIncomingFileBytes) {
      throw FileTransferException(
        'Files larger than ${_formatBytes(maxSupportedIncomingFileBytes)} are not supported.',
        statusCode: HttpStatus.requestEntityTooLarge,
      );
    }
    final digest = await sha256.bind(file.openRead()).first;
    final transferId = _newId();
    onProgress?.call(0, totalBytes);
    final connection = await _connectToPeer(device);
    try {
      if (connection.mtu < _lowMtuBleFileThreshold &&
          totalBytes > _maxLowMtuBleFileBytes) {
        throw const FileTransferException(
          'This BLE link negotiated a small MTU. Use Wi-Fi/LAN for files over 10 MB.',
          statusCode: HttpStatus.requestEntityTooLarge,
        );
      }
      final metadata = utf8.encode(jsonEncode(<String, Object?>{
        'fileName': path.replaceAll(String.fromCharCode(92), '/').split('/').last,
        'sizeBytes': totalBytes,
        'sha256': digest.toString(),
        'senderName': config.deviceName,
      }));
      await _sendEncryptedEvent(
        deviceId: device.deviceId,
        peerId: connection.peerId,
        secret: connection.secret,
        kind: 'file-start',
        transferId: transferId,
        index: null,
        plaintext: metadata,
        mtu: connection.mtu,
      );

      final chunkSize = _fileChunkSize(connection.mtu);
      final handle = await file.open(mode: FileMode.read);
      var sentBytes = 0;
      var index = 0;
      try {
        while (sentBytes < totalBytes) {
          final chunk = await handle.read(chunkSize);
          if (chunk.isEmpty) {
            throw const FileTransferException('The selected file changed during transfer.');
          }
          await _sendEncryptedEvent(
            deviceId: device.deviceId,
            peerId: connection.peerId,
            secret: connection.secret,
            kind: 'file-chunk',
            transferId: transferId,
            index: index,
            plaintext: chunk,
            mtu: connection.mtu,
          );
          sentBytes += chunk.length;
          index++;
          onProgress?.call(sentBytes, totalBytes);
        }
      } finally {
        await handle.close();
      }

      await _sendEncryptedEvent(
        deviceId: device.deviceId,
        peerId: connection.peerId,
        secret: connection.secret,
        kind: 'file-complete',
        transferId: transferId,
        index: null,
        plaintext: utf8.encode('complete'),
        mtu: connection.mtu,
      );
      onProgress?.call(totalBytes, totalBytes);
      _status = 'File sent to ${connection.peerName}';
      onLog('DATA', 'Sent ${_formatBytes(totalBytes)} over Bluetooth to ${connection.peerName}.');
      _notify();
    } finally {
      await _disconnect(device.deviceId);
    }
  }

  Future<_BluetoothConnection> _connectToPeer(BleDevice device) async {
    if (_scanning) await stopScan();
    _status = 'Connecting to ${device.name ?? 'Bluetooth device'}…';
    _lastError = null;
    _notify();
    try {
      await UniversalBle.connect(
        device.deviceId,
        timeout: const Duration(seconds: 20),
      );
      _connectedDevices.add(device.deviceId);
      await UniversalBle.discoverServices(
        device.deviceId,
        timeout: const Duration(seconds: 10),
      );
      final identity = await UniversalBle.read(
        device.deviceId,
        _serviceUuid,
        _identityCharacteristicUuid,
        timeout: const Duration(seconds: 10),
      );
      final peerId = utf8.decode(identity, allowMalformed: false).trim();
      if (peerId.isEmpty || peerId.length > 64 || peerId == config.deviceId) {
        throw const FormatException('The Bluetooth device returned an invalid Airbridge identity.');
      }
      final secret = peerSecretProvider(peerId);
      if (secret == null || secret.isEmpty) {
        throw StateError('Pair with ${device.name ?? 'this device'} using the QR code first.');
      }

      var mtu = 23;
      try {
        mtu = await UniversalBle.requestMtu(
          device.deviceId,
          512,
          timeout: const Duration(seconds: 8),
        );
      } on Object {
        // ATT's mandatory default MTU is 23; fragmentation handles that case.
      }
      final safeMtu = mtu.clamp(23, 512).toInt();
      final peerName = device.name?.trim().isNotEmpty == true
          ? device.name!.trim()
          : peerId;
      _status = 'Secure Bluetooth link to $peerName';
      _notify();
      return _BluetoothConnection(
        peerId: peerId,
        peerName: peerName,
        secret: secret,
        mtu: safeMtu,
      );
    } on Object catch (error) {
      await _disconnect(device.deviceId);
      _lastError = error.toString();
      _status = 'Bluetooth connection failed';
      onLog('WARN', 'Bluetooth connection failed: $error');
      _notify();
      rethrow;
    }
  }

  Future<void> _sendEncryptedEvent({
    required String deviceId,
    required String peerId,
    required String secret,
    required String kind,
    required String transferId,
    required int? index,
    required List<int> plaintext,
    required int mtu,
  }) async {
    final sealed = await sealPeerPayload(
      secret: secret,
      cleartext: plaintext,
      associatedData: _eventAad(
        config.deviceId,
        peerId,
        kind,
        transferId,
        index,
      ),
    );
    final event = <String, Object?>{
      'version': 1,
      'senderId': config.deviceId,
      'recipientId': peerId,
      'kind': kind,
      'transferId': transferId,
      if (index != null) 'index': index,
      'sealed': sealed,
    };
    final bytes = utf8.encode(jsonEncode(event));
    if (bytes.length > _maxBlePacketBytes) {
      throw const FileTransferException('Bluetooth transfer packet exceeds the safe size limit.');
    }
    await _sendPacket(deviceId, bytes, mtu);
  }

  Future<void> _sendPacket(String deviceId, List<int> bytes, int mtu) async {
    final writeValueLength = (mtu - 3).clamp(20, 509).toInt();
    final fragmentPayloadLength = writeValueLength - _fragmentHeaderBytes;
    final fragmentCount = (bytes.length + fragmentPayloadLength - 1) ~/ fragmentPayloadLength;
    if (fragmentCount < 1 || fragmentCount > 0xffff) {
      throw const FileTransferException('Bluetooth message requires too many fragments.');
    }
    final packetId = _random.nextInt(0x10000);
    for (var index = 0; index < fragmentCount; index++) {
      final start = index * fragmentPayloadLength;
      final end = min(start + fragmentPayloadLength, bytes.length).toInt();
      final frame = Uint8List(_fragmentHeaderBytes + end - start);
      frame[0] = 0x41;
      frame[1] = 0x42;
      final header = ByteData.sublistView(frame);
      header.setUint16(2, packetId, Endian.big);
      header.setUint16(4, index, Endian.big);
      header.setUint16(6, fragmentCount, Endian.big);
      frame.setRange(_fragmentHeaderBytes, frame.length, bytes, start);
      await UniversalBle.write(
        deviceId,
        _serviceUuid,
        _dataCharacteristicUuid,
        frame,
        timeout: const Duration(seconds: 15),
      );
    }
  }

  void _handleScanResult(BleDevice device) {
    if (!device.services.any((service) => service.toLowerCase() == _serviceUuid)) return;
    final current = _devices[device.deviceId];
    if (current == null || current.rssi != device.rssi || current.name != device.name) {
      _devices[device.deviceId] = device;
      _notify();
    }
  }

  Future<void> _preparePeripheral() async {
    try {
      final capabilities = await UniversalBlePeripheral.getCapabilities();
      _peripheralSupported = capabilities.supportsPeripheralMode;
      if (!_peripheralSupported) return;

      UniversalBlePeripheral.setReadRequestHandlers(
        (deviceId, characteristicId, offset, value) {
          if (characteristicId.toLowerCase() != _identityCharacteristicUuid) return null;
          final identity = Uint8List.fromList(utf8.encode(config.deviceId));
          final start = offset.clamp(0, identity.length).toInt();
          return PeripheralReadRequestResult(
            value: Uint8List.fromList(identity.sublist(start)),
            offset: start,
          );
        },
      );
      UniversalBlePeripheral.setWriteRequestHandlers(
        (deviceId, characteristicId, offset, value) {
          if (characteristicId.toLowerCase() == _dataCharacteristicUuid &&
              offset == 0 &&
              value != null) {
            _acceptFragment(deviceId, value);
          }
          return PeripheralWriteRequestResult();
        },
      );

      final registered = await UniversalBlePeripheral.getServices();
      if (!registered.any((service) => service.toLowerCase() == _serviceUuid)) {
        await UniversalBlePeripheral.addService(
          BlePeripheralService(
            uuid: _serviceUuid,
            primary: true,
            characteristics: <BlePeripheralCharacteristic>[
              BlePeripheralCharacteristic(
                uuid: _identityCharacteristicUuid,
                properties: <CharacteristicProperty>[CharacteristicProperty.read],
                permissions: <PeripheralAttributePermission>[
                  PeripheralAttributePermission.readable,
                ],
                value: Uint8List.fromList(utf8.encode(config.deviceId)),
              ),
              BlePeripheralCharacteristic(
                uuid: _dataCharacteristicUuid,
                properties: <CharacteristicProperty>[CharacteristicProperty.write],
                permissions: <PeripheralAttributePermission>[
                  PeripheralAttributePermission.writeable,
                ],
              ),
            ],
          ),
        );
      }
      final readiness = await UniversalBlePeripheral.getAvailabilityState();
      if (readiness != PeripheralReadinessState.ready) {
        _status = 'Bluetooth is on, but this adapter is ${readiness.name} for receiving';
        return;
      }
      await UniversalBlePeripheral.startAdvertising(
        services: <String>[_serviceUuid],
        localName: Platform.isWindows ? null : 'Airbridge',
      );
      _advertising = true;
    } on Object catch (error) {
      _peripheralSupported = false;
      _advertising = false;
      _lastError = error.toString();
      onLog('WARN', 'Bluetooth receive/advertising is unavailable: $error');
    }
  }

  void _acceptFragment(String deviceId, Uint8List value) {
    if (value.length < _fragmentHeaderBytes || value[0] != 0x41 || value[1] != 0x42) {
      return;
    }
    final header = ByteData.sublistView(value);
    final packetId = header.getUint16(2, Endian.big);
    final index = header.getUint16(4, Endian.big);
    final count = header.getUint16(6, Endian.big);
    if (count == 0 || count > 12000 || index >= count) return;

    _pruneAssemblies();
    final key = '$deviceId:$packetId';
    var assembly = _assemblies[key];
    if (assembly == null) {
      final deviceAssemblyCount = _assemblies.keys.where((item) => item.startsWith('$deviceId:')).length;
      if (deviceAssemblyCount >= 4) return;
      assembly = _BleAssembly(count);
      _assemblies[key] = assembly;
    }
    if (assembly.count != count) {
      _assemblies.remove(key);
      return;
    }
    if (!assembly.fragments.containsKey(index)) {
      assembly.fragments[index] = Uint8List.fromList(value.sublist(_fragmentHeaderBytes));
      assembly.receivedBytes += value.length - _fragmentHeaderBytes;
    }
    if (assembly.receivedBytes > _maxBlePacketBytes) {
      _assemblies.remove(key);
      return;
    }
    if (assembly.fragments.length != count) return;

    final builder = BytesBuilder(copy: false);
    for (var fragmentIndex = 0; fragmentIndex < count; fragmentIndex++) {
      final fragment = assembly.fragments[fragmentIndex];
      if (fragment == null) return;
      builder.add(fragment);
    }
    _assemblies.remove(key);
    final packet = builder.takeBytes();
    _eventQueue = _eventQueue.then((_) => _handleEvent(packet));
  }

  Future<void> _handleEvent(List<int> packet) async {
    try {
      final decoded = jsonDecode(utf8.decode(packet));
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['senderId'] is! String ||
          decoded['recipientId'] != config.deviceId ||
          decoded['kind'] is! String ||
          decoded['transferId'] is! String ||
          decoded['sealed'] is! Map<String, dynamic>) {
        throw const FormatException('Bluetooth data packet is malformed.');
      }
      final senderId = decoded['senderId']! as String;
      final kind = decoded['kind']! as String;
      final transferId = decoded['transferId']! as String;
      final indexValue = decoded['index'];
      final index = indexValue is int ? indexValue : null;
      final secret = peerSecretProvider(senderId);
      if (secret == null || secret.isEmpty) {
        throw const FormatException('Unpaired Bluetooth device rejected. Pair with QR first.');
      }
      final plaintext = await openPeerPayload(
        secret: secret,
        sealed: Map<String, dynamic>.from(decoded['sealed']! as Map),
        associatedData: _eventAad(senderId, config.deviceId, kind, transferId, index),
      );
      if ((kind == 'file-start' || kind == 'file-chunk' || kind == 'file-complete') &&
          !allowIncomingFiles()) {
        await fileStore.cancelTransfer(transferId);
        throw const FileTransferException(
          'Incoming files are disabled in Settings.',
          statusCode: HttpStatus.forbidden,
        );
      }

      switch (kind) {
        case 'message':
          final content = jsonDecode(utf8.decode(plaintext));
          if (content is! Map<String, dynamic> || !content.containsKey('payload')) {
            throw const FormatException('Bluetooth message content is invalid.');
          }
          final senderName = content['senderName'];
          await onMessageReceived(
            senderId: senderId,
            senderName: senderName is String ? senderName : 'Bluetooth peer',
            payload: content['payload'],
          );
          break;
        case 'file-start':
          final metadata = jsonDecode(utf8.decode(plaintext));
          if (metadata is! Map<String, dynamic> ||
              metadata['fileName'] is! String ||
              metadata['sizeBytes'] is! int ||
              metadata['sha256'] is! String ||
              metadata['senderName'] is! String) {
            throw const FormatException('Bluetooth file metadata is incomplete.');
          }
          await fileStore.beginTransfer(
            transferId: transferId,
            fileName: metadata['fileName']! as String,
            sizeBytes: metadata['sizeBytes']! as int,
            sha256Hex: metadata['sha256']! as String,
            source: 'Bluetooth',
            senderId: senderId,
            senderName: metadata['senderName']! as String,
          );
          break;
        case 'file-chunk':
          if (index == null || index < 0) {
            throw const FormatException('Bluetooth file chunk has no valid index.');
          }
          await fileStore.addChunk(
            transferId: transferId,
            index: index,
            bytes: plaintext,
          );
          break;
        case 'file-complete':
          final record = await fileStore.completeTransfer(transferId);
          onFileReceived(record);
          onLog('DATA', 'Received ${record.fileName} over Bluetooth (${_formatBytes(record.sizeBytes)}).');
          break;
        default:
          throw const FormatException('Unsupported Bluetooth transfer type.');
      }
      _notify();
    } on Object catch (error) {
      onLog('WARN', 'Rejected Bluetooth transfer data: $error');
      _lastError = error.toString();
      _notify();
    }
  }

  Future<void> _disconnect(String deviceId) async {
    if (!_connectedDevices.remove(deviceId)) return;
    try {
      await UniversalBle.disconnect(deviceId, timeout: const Duration(seconds: 5));
    } on Object {
      // Disconnect is best effort; the peer may have gone out of range.
    }
  }

  void _pruneAssemblies() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    _assemblies.removeWhere((_, assembly) => assembly.createdAt.isBefore(cutoff));
  }

  int _fileChunkSize(int mtu) {
    final characteristicBytes = max(12, mtu - 3 - _fragmentHeaderBytes);
    return (characteristicBytes * 20).clamp(128, _maxBleFileChunkBytes).toInt();
  }

  String _newId() => List<int>.generate(16, (_) => _random.nextInt(256))
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  void _notify() => onChanged();
}

String _eventAad(
  String senderId,
  String recipientId,
  String kind,
  String transferId,
  int? index,
) =>
    'airbridge-ble-v1:$senderId:$recipientId:$kind:$transferId:${index ?? '-'}';

String _formatBytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _BluetoothConnection {
  const _BluetoothConnection({
    required this.peerId,
    required this.peerName,
    required this.secret,
    required this.mtu,
  });

  final String peerId;
  final String peerName;
  final String secret;
  final int mtu;
}

class _BleAssembly {
  _BleAssembly(this.count) : createdAt = DateTime.now();

  final int count;
  final DateTime createdAt;
  final Map<int, Uint8List> fragments = <int, Uint8List>{};
  int receivedBytes = 0;
}
