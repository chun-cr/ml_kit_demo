import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ModulePreloader {
  ModulePreloader._();

  static const MethodChannel _gestureChannel = MethodChannel('gesture/frame');
  static const MethodChannel _tongueChannel = MethodChannel('tongue/frame');

  static Future<void>? _gestureWarmupFuture;
  static Future<void>? _tongueWarmupFuture;
  static Future<void> warmupGesture() {
    final existing = _gestureWarmupFuture;
    if (existing != null) return existing;

    final future = _invokeWarmup(_gestureChannel, 'gesture').then((success) {
      if (!success) _gestureWarmupFuture = null;
    });
    _gestureWarmupFuture = future;
    return future;
  }

  static Future<void> warmupTongue() {
    final existing = _tongueWarmupFuture;
    if (existing != null) return existing;

    final future = _invokeWarmup(_tongueChannel, 'tongue').then((success) {
      if (!success) _tongueWarmupFuture = null;
    });
    _tongueWarmupFuture = future;
    return future;
  }

  static void warmupSecondaryModulesInBackground() {
    warmupGesture();
    warmupTongue();
  }

  static Future<bool> _invokeWarmup(
    MethodChannel channel,
    String moduleName,
  ) async {
    try {
      await channel.invokeMethod('warmup');
      return true;
    } catch (e) {
      debugPrint('[ModulePreloader] $moduleName warmup failed: $e');
      return false;
    }
  }
}
