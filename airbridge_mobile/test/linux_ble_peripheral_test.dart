import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:airbridge_mobile/services/linux_ble_peripheral.dart';
import 'package:butane_dart/butane_dart.dart'
    show AttRequest, AttResult, MutableService, UuidIdentifier;
import 'package:flutter_test/flutter_test.dart';

const String _serviceUuid = 'a7f30001-7b9a-4b1d-9c8c-7f6a4d1e0001';
const String _identityUuid = 'a7f30002-7b9a-4b1d-9c8c-7f6a4d1e0001';
const String _dataUuid = 'a7f30003-7b9a-4b1d-9c8c-7f6a4d1e0001';

void main() {
  group('Linux BLE peripheral', () {
    late _FakeLinuxBlePeripheralBackend backend;
    late List<String> logs;
    late LinuxBlePeripheral peripheral;

    setUp(() {
      backend = _FakeLinuxBlePeripheralBackend();
      logs = <String>[];
      peripheral = LinuxBlePeripheral(
        deviceId: 'airbridge-test-node',
        serviceUuid: _serviceUuid,
        identityCharacteristicUuid: _identityUuid,
        dataCharacteristicUuid: _dataUuid,
        onWrite: (centralId, value) {},
        onLog: (level, message) => logs.add('$level:$message'),
        backend: backend,
      );
    });

    tearDown(() async {
      await peripheral.stop();
      await backend.close();
    });

    test('registers the shared Airbridge GATT service and advertises it', () async {
      await peripheral.start();

      expect(backend.services, hasLength(1));
      final service = backend.services.single;
      expect(service.uuid.toString(), _serviceUuid);
      expect(service.isPrimary, isTrue);
      expect(service.characteristics, hasLength(2));

      final identity = service.characteristics[0];
      expect(identity.uuid.toString(), _identityUuid);
      expect(identity.properties?.read, isTrue);
      expect(identity.properties?.write, isFalse);
      expect(identity.permissions?.readable, isTrue);
      expect(identity.value, utf8.encode('airbridge-test-node'));

      final data = service.characteristics[1];
      expect(data.uuid.toString(), _dataUuid);
      expect(data.properties?.write, isTrue);
      expect(data.properties?.writeWithoutResponse, isTrue);
      expect(data.permissions?.writeable, isTrue);

      expect(backend.advertisedLocalName, 'Airbridge');
      expect(backend.advertisedServices, <UuidIdentifier>[
        const UuidIdentifier(_serviceUuid),
      ]);
    });

    test('serves identity reads with ATT offsets and rejects other attributes', () async {
      await peripheral.start();

      final readFuture = backend.nextResponse();
      backend.readController.add(_request(
        requestId: 11,
        characteristicUuid: _identityUuid,
        offset: 3,
      ));
      final read = await readFuture;
      expect(read.requestId, 11);
      expect(read.result, AttResult.success);
      expect(utf8.decode(read.value!), 'bridge-test-node');

      final invalidOffsetFuture = backend.nextResponse();
      backend.readController.add(_request(
        requestId: 12,
        characteristicUuid: _identityUuid,
        offset: 100,
      ));
      final invalidOffset = await invalidOffsetFuture;
      expect(invalidOffset.result, AttResult.invalidOffset);
      expect(invalidOffset.value, isNull);

      final wrongCharacteristicFuture = backend.nextResponse();
      backend.readController.add(_request(
        requestId: 13,
        characteristicUuid: _dataUuid,
      ));
      final wrongCharacteristic = await wrongCharacteristicFuture;
      expect(wrongCharacteristic.result, AttResult.readNotPermitted);
    });

    test('forwards valid writes and rejects invalid GATT writes', () async {
      final writes = <(String, Uint8List)>[];
      peripheral = LinuxBlePeripheral(
        deviceId: 'airbridge-test-node',
        serviceUuid: _serviceUuid,
        identityCharacteristicUuid: _identityUuid,
        dataCharacteristicUuid: _dataUuid,
        onWrite: (centralId, value) => writes.add((centralId, value)),
        onLog: (level, message) => logs.add('$level:$message'),
        backend: backend,
      );
      await peripheral.start();

      final payload = Uint8List.fromList(<int>[0x41, 0x42, 0x00, 0x01]);
      final validResponseFuture = backend.nextResponse();
      backend.writeController.add(<AttRequest>[
        _request(
          requestId: 21,
          characteristicUuid: _dataUuid,
          value: payload,
          centralIdentifier: 'central-01',
        ),
      ]);
      final validResponse = await validResponseFuture;
      expect(validResponse.requestId, 21);
      expect(validResponse.result, AttResult.success);
      expect(writes, hasLength(1));
      expect(writes.single.$1, 'central-01');
      expect(writes.single.$2, payload);
      expect(identical(writes.single.$2, payload), isFalse);

      final invalidOffsetResponseFuture = backend.nextResponse();
      backend.writeController.add(<AttRequest>[
        _request(
          requestId: 22,
          characteristicUuid: _dataUuid,
          offset: 1,
          value: payload,
        ),
      ]);
      final invalidOffsetResponse = await invalidOffsetResponseFuture;
      expect(invalidOffsetResponse.result, AttResult.invalidOffset);
      expect(writes, hasLength(1));

      final wrongCharacteristicResponseFuture = backend.nextResponse();
      backend.writeController.add(<AttRequest>[
        _request(
          requestId: 23,
          characteristicUuid: _identityUuid,
          value: payload,
        ),
      ]);
      final wrongCharacteristicResponse = await wrongCharacteristicResponseFuture;
      expect(wrongCharacteristicResponse.result, AttResult.writeNotPermitted);
      expect(writes, hasLength(1));
    });

    test('stops advertising and disposes backend resources exactly once', () async {
      await peripheral.start();

      await peripheral.stop();
      await peripheral.stop();

      expect(backend.stopAdvertisingCount, 1);
      expect(backend.removeAllServicesCount, 1);
      expect(backend.disposeCount, 1);
      expect(logs, isEmpty);
    });
  });
}

AttRequest _request({
  required int requestId,
  required String characteristicUuid,
  int offset = 0,
  Uint8List? value,
  String centralIdentifier = 'test-central',
}) =>
    AttRequest(
      requestId: requestId,
      centralIdentifier: centralIdentifier,
      serviceUuid: const UuidIdentifier(_serviceUuid),
      characteristicUuid: UuidIdentifier(characteristicUuid),
      offset: offset,
      value: value,
    );

class _FakeLinuxBlePeripheralBackend implements LinuxBlePeripheralBackend {
  final StreamController<AttRequest> readController =
      StreamController<AttRequest>();
  final StreamController<List<AttRequest>> writeController =
      StreamController<List<AttRequest>>();
  final StreamController<_Response> _responseController =
      StreamController<_Response>.broadcast(sync: true);
  final List<MutableService> services = <MutableService>[];
  final List<_Response> responses = <_Response>[];

  String? advertisedLocalName;
  List<UuidIdentifier>? advertisedServices;
  int stopAdvertisingCount = 0;
  int removeAllServicesCount = 0;
  int disposeCount = 0;

  @override
  Stream<AttRequest> get readRequests => readController.stream;

  @override
  Stream<List<AttRequest>> get writeRequests => writeController.stream;

  @override
  Future<void> addService(MutableService service) async {
    services.add(service);
  }

  @override
  Future<void> startAdvertising({
    required String localName,
    required List<UuidIdentifier> serviceUuids,
  }) async {
    advertisedLocalName = localName;
    advertisedServices = serviceUuids;
  }

  @override
  Future<void> stopAdvertising() async {
    stopAdvertisingCount++;
  }

  @override
  Future<void> removeAllServices() async {
    removeAllServicesCount++;
  }

  @override
  Future<void> respondToRequest({
    required int requestId,
    required AttResult result,
    Uint8List? value,
  }) async {
    final response = _Response(
      requestId: requestId,
      result: result,
      value: value == null ? null : Uint8List.fromList(value),
    );
    responses.add(response);
    _responseController.add(response);
  }

  Future<_Response> nextResponse() => _responseController.stream.first.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('No ATT response was received.'),
      );

  @override
  void dispose() {
    disposeCount++;
  }

  Future<void> close() async {
    await readController.close();
    await writeController.close();
    await _responseController.close();
  }
}

class _Response {
  const _Response({
    required this.requestId,
    required this.result,
    required this.value,
  });

  final int requestId;
  final AttResult result;
  final Uint8List? value;
}
