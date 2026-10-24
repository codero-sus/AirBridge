import 'dart:io';

import 'package:airbridge_mobile/services/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late SettingsStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('airbridge-settings-test-');
    store = SettingsStore(supportDirectory: directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('loads defaults and persists settings across store instances', () async {
    final defaults = await store.load(fallbackName: 'Host device');
    expect(defaults.deviceName, 'Host device');
    expect(defaults.bluetoothEnabled, isFalse);
    expect(defaults.autoAcceptFiles, isTrue);
    expect(defaults.maxIncomingFileBytes, 100 * 1024 * 1024);

    await store.save(
      defaults.copyWith(
        deviceName: '  Office laptop  ',
        bluetoothEnabled: true,
        autoAcceptFiles: false,
        maxIncomingFileBytes: 512 * 1024 * 1024,
      ),
    );
    final restored = await SettingsStore(supportDirectory: directory)
        .load(fallbackName: 'Fallback name');
    expect(restored.deviceName, 'Office laptop');
    expect(restored.bluetoothEnabled, isTrue);
    expect(restored.autoAcceptFiles, isFalse);
    expect(restored.maxIncomingFileBytes, 512 * 1024 * 1024);
  });

  test('sanitizes names and replaces invalid receive-size values', () async {
    await store.save(
      const AirbridgeSettings(
        deviceName: '  Desk\nname  ',
        maxIncomingFileBytes: 20,
      ),
    );
    final restored = await SettingsStore(supportDirectory: directory)
        .load(fallbackName: 'Fallback name');
    expect(restored.deviceName, 'Deskname');
    expect(restored.maxIncomingFileBytes, 100 * 1024 * 1024);
  });
}
