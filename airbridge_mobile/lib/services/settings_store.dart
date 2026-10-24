import 'dart:convert';
import 'dart:io';

import 'file_transfer_store.dart';

class AirbridgeSettings {
  const AirbridgeSettings({
    required this.deviceName,
    this.bluetoothEnabled = false,
    this.autoAcceptFiles = true,
    this.maxIncomingFileBytes = defaultMaxIncomingFileBytes,
  });

  final String deviceName;
  final bool bluetoothEnabled;
  final bool autoAcceptFiles;
  final int maxIncomingFileBytes;

  AirbridgeSettings copyWith({
    String? deviceName,
    bool? bluetoothEnabled,
    bool? autoAcceptFiles,
    int? maxIncomingFileBytes,
  }) =>
      AirbridgeSettings(
        deviceName: deviceName ?? this.deviceName,
        bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
        autoAcceptFiles: autoAcceptFiles ?? this.autoAcceptFiles,
        maxIncomingFileBytes: maxIncomingFileBytes ?? this.maxIncomingFileBytes,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'deviceName': deviceName,
        'bluetoothEnabled': bluetoothEnabled,
        'autoAcceptFiles': autoAcceptFiles,
        'maxIncomingFileBytes': maxIncomingFileBytes,
      };

  static AirbridgeSettings fromJson(Object? value, {required String fallbackName}) {
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      return AirbridgeSettings(deviceName: fallbackName);
    }
    final nameValue = value['deviceName'];
    final name = _sanitizeDeviceName(nameValue is String ? nameValue : fallbackName);
    final maxBytesValue = value['maxIncomingFileBytes'];
    final maxBytes = maxBytesValue is int &&
            maxBytesValue >= 1024 * 1024 &&
            maxBytesValue <= maxSupportedIncomingFileBytes
        ? maxBytesValue
        : defaultMaxIncomingFileBytes;
    return AirbridgeSettings(
      deviceName: name,
      bluetoothEnabled: value['bluetoothEnabled'] == true,
      autoAcceptFiles: value['autoAcceptFiles'] != false,
      maxIncomingFileBytes: maxBytes,
    );
  }

  static String sanitizeDeviceName(String value) => _sanitizeDeviceName(value);
}

class SettingsStore {
  SettingsStore({required Directory supportDirectory})
      : _file = File(
          '${supportDirectory.path}${Platform.pathSeparator}settings.json',
        );

  final File _file;

  Future<AirbridgeSettings> load({required String fallbackName}) async {
    try {
      final decoded = jsonDecode(await _file.readAsString());
      return AirbridgeSettings.fromJson(decoded, fallbackName: fallbackName);
    } on FileSystemException {
      return AirbridgeSettings(deviceName: fallbackName);
    } on FormatException {
      return AirbridgeSettings(deviceName: fallbackName);
    }
  }

  Future<void> save(AirbridgeSettings settings) async {
    await _file.parent.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(jsonEncode(settings.toJson()), flush: true);
    if (await _file.exists()) await _file.delete();
    await temporary.rename(_file.path);
  }
}

String _sanitizeDeviceName(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
  if (cleaned.isEmpty) return 'Airbridge node';
  return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
}
