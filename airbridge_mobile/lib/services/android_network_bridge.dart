import 'dart:io';

import 'package:flutter/services.dart';

class AndroidNetworkBridge {
  AndroidNetworkBridge._();

  static const MethodChannel _channel = MethodChannel(
    'com.coderosus.airbridge_mobile/network',
  );

  static Future<void> acquireMulticastLock() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<bool>('acquireMulticastLock');
  }

  static Future<void> releaseMulticastLock() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<bool>('releaseMulticastLock');
  }
}
