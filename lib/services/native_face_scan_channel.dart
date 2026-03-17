import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class NativeFaceScanChannel {
  NativeFaceScanChannel._();

  static const MethodChannel _channel = MethodChannel('face/native');

  static Future<Map<String, dynamic>?> startScan() async {
    if (!Platform.isIOS) return null;

    final result = await _channel.invokeMethod<dynamic>('startScan');
    if (result is Map) {
      return result.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return null;
  }
}
