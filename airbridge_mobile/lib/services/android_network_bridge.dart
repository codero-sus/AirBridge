import 'dart:io';

import 'package:flutter/services.dart';

class AndroidNetworkBridge {
  AndroidNetworkBridge._();

  static const MethodChannel _channel = MethodChannel(
    'com.coderosus.airbridge_mobile/network',
  );

  static Future<String?> getWifiIPv4Address() async {
    if (!Platform.isAndroid) return null;
    try {
      final value = await _channel.invokeMethod<String>('getWifiIPv4Address');
      final address = value == null ? null : InternetAddress.tryParse(value);
      if (address == null || address.type != InternetAddressType.IPv4) return null;
      return address.address;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> acquireMulticastLock() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<bool>('acquireMulticastLock');
  }

  static Future<void> releaseMulticastLock() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<bool>('releaseMulticastLock');
  }
}
