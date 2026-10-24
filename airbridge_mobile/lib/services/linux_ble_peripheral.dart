import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:butane_dart/butane_dart.dart'
    show
        AttRequest,
        AttResult,
        CharacteristicPermissions,
        CharacteristicProperties,
        MutableCharacteristic,
        MutableService,
        PeripheralManager,
        UuidIdentifier;

/// BlueZ-backed GATT server used on Linux. The central/client side continues
/// to use universal_ble; both adapters expose the same Airbridge service and
/// byte-level protocol.
class LinuxBlePeripheral {
  LinuxBlePeripheral({
    required this.deviceId,
    required this.serviceUuid,
    required this.identityCharacteristicUuid,
    required this.dataCharacteristicUuid,
    required this.onWrite,
    required this.onLog,
    LinuxBlePeripheralBackend? backend,
  }) : _backend = backend ?? ButaneLinuxBlePeripheralBackend(deviceId);

  final String deviceId;
  final String serviceUuid;
  final String identityCharacteristicUuid;
  final String dataCharacteristicUuid;
  final void Function(String centralId, Uint8List value) onWrite;
  final void Function(String level, String message) onLog;

  final LinuxBlePeripheralBackend _backend;
  StreamSubscription<AttRequest>? _readRequests;
  StreamSubscription<List<AttRequest>>? _writeRequests;
  bool _advertising = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_disposed) throw StateError('The Linux BLE peripheral has been disposed.');
    if (_advertising) return;

    await _backend.addService(
      MutableService(
        uuid: UuidIdentifier(serviceUuid),
        isPrimary: true,
        characteristics: <MutableCharacteristic>[
          MutableCharacteristic(
            uuid: UuidIdentifier(identityCharacteristicUuid),
            properties: const CharacteristicProperties(read: true),
            permissions: const CharacteristicPermissions(readable: true),
            value: Uint8List.fromList(utf8.encode(deviceId)),
          ),
          MutableCharacteristic(
            uuid: UuidIdentifier(dataCharacteristicUuid),
            properties: const CharacteristicProperties(
              write: true,
              writeWithoutResponse: true,
            ),
            permissions: const CharacteristicPermissions(writeable: true),
          ),
        ],
      ),
    );

    _readRequests = _backend.readRequests.listen(
      (request) => unawaited(_handleReadRequest(request).catchError((Object error) {
        onLog('WARN', 'Linux Bluetooth read handler failed: $error');
      })),
      onError: (Object error, StackTrace stackTrace) {
        onLog('WARN', 'Linux Bluetooth read request stream failed: $error');
      },
    );
    _writeRequests = _backend.writeRequests.listen(
      (requests) => unawaited(_handleWriteRequests(requests).catchError((Object error) {
        onLog('WARN', 'Linux Bluetooth write handler failed: $error');
      })),
      onError: (Object error, StackTrace stackTrace) {
        onLog('WARN', 'Linux Bluetooth write request stream failed: $error');
      },
    );

    await _backend.startAdvertising(
      localName: 'Airbridge',
      serviceUuids: <UuidIdentifier>[UuidIdentifier(serviceUuid)],
    );
    _advertising = true;
  }

  Future<void> stop() async {
    if (_disposed) return;
    _disposed = true;
    await _readRequests?.cancel();
    await _writeRequests?.cancel();
    _readRequests = null;
    _writeRequests = null;

    if (_advertising) {
      try {
        await _backend.stopAdvertising();
      } on Object catch (error) {
        onLog('WARN', 'Could not stop Linux Bluetooth advertising: $error');
      }
      _advertising = false;
    }

    try {
      await _backend.removeAllServices();
    } on Object catch (error) {
      onLog('WARN', 'Could not remove Linux Bluetooth services: $error');
    }
    _backend.dispose();
  }

  Future<void> _handleReadRequest(AttRequest request) async {
    final isIdentityRead =
        request.serviceUuid.toString().toLowerCase() == serviceUuid.toLowerCase() &&
        request.characteristicUuid.toString().toLowerCase() ==
            identityCharacteristicUuid.toLowerCase();
    final identity = Uint8List.fromList(utf8.encode(deviceId));
    final offset = request.offset;
    final result = !isIdentityRead
        ? AttResult.readNotPermitted
        : (offset < 0 || offset > identity.length
            ? AttResult.invalidOffset
            : AttResult.success);
    final value = result == AttResult.success
        ? Uint8List.fromList(identity.sublist(offset))
        : null;
    await _backend.respondToRequest(
      requestId: request.requestId,
      result: result,
      value: value,
    );
  }

  Future<void> _handleWriteRequests(List<AttRequest> requests) async {
    for (final request in requests) {
      final isAirbridgeWrite =
          request.serviceUuid.toString().toLowerCase() == serviceUuid.toLowerCase() &&
          request.characteristicUuid.toString().toLowerCase() ==
              dataCharacteristicUuid.toLowerCase();
      final value = request.value;
      var result = !isAirbridgeWrite
          ? AttResult.writeNotPermitted
          : (request.offset != 0 || value == null
              ? AttResult.invalidOffset
              : AttResult.success);
      if (result == AttResult.success) {
        try {
          onWrite(request.centralIdentifier, Uint8List.fromList(value!));
        } on Object catch (error) {
          onLog('WARN', 'Rejected Linux Bluetooth data write: $error');
          result = AttResult.unlikelyError;
        }
      }
      await _backend.respondToRequest(
        requestId: request.requestId,
        result: result,
      );
    }
  }
}

/// Minimal BlueZ peripheral operations used by [LinuxBlePeripheral].
///
/// Keeping the adapter boundary injectable allows the ATT contract and the
/// Airbridge service layout to be tested without a Bluetooth controller.
abstract interface class LinuxBlePeripheralBackend {
  Stream<AttRequest> get readRequests;
  Stream<List<AttRequest>> get writeRequests;

  Future<void> addService(MutableService service);
  Future<void> startAdvertising({
    required String localName,
    required List<UuidIdentifier> serviceUuids,
  });
  Future<void> stopAdvertising();
  Future<void> removeAllServices();
  Future<void> respondToRequest({
    required int requestId,
    required AttResult result,
    Uint8List? value,
  });
  void dispose();
}

class ButaneLinuxBlePeripheralBackend implements LinuxBlePeripheralBackend {
  ButaneLinuxBlePeripheralBackend(String deviceId)
      : _manager = PeripheralManager(clientIdentifier: 'airbridge-$deviceId');

  final PeripheralManager _manager;

  @override
  Stream<AttRequest> get readRequests => _manager.readRequests;

  @override
  Stream<List<AttRequest>> get writeRequests => _manager.writeRequests;

  @override
  Future<void> addService(MutableService service) => _manager.addService(service);

  @override
  Future<void> startAdvertising({
    required String localName,
    required List<UuidIdentifier> serviceUuids,
  }) =>
      _manager.startAdvertising(
        localName: localName,
        serviceUuids: serviceUuids,
      );

  @override
  Future<void> stopAdvertising() => _manager.stopAdvertising();

  @override
  Future<void> removeAllServices() => _manager.removeAllServices();

  @override
  Future<void> respondToRequest({
    required int requestId,
    required AttResult result,
    Uint8List? value,
  }) =>
      _manager.respondToRequest(
        requestId: requestId,
        result: result,
        value: value,
      );

  @override
  void dispose() => _manager.dispose();
}
