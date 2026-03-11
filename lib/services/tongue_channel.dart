// 舌诊模块所有 Platform Channel 调用的封装类

import 'dart:async';
import 'package:flutter/services.dart';

/// 引导状态数据模型
class TongueGuideState {
  final bool faceDetected;
  final bool mouthOpen;
  final bool tongueVisible;
  final bool isStable;
  final double stableProgress; // 0.0 ~ 1.0
  final String hint;

  const TongueGuideState({
    required this.faceDetected,
    required this.mouthOpen,
    required this.tongueVisible,
    required this.isStable,
    required this.stableProgress,
    required this.hint,
  });

  factory TongueGuideState.idle() => const TongueGuideState(
    faceDetected:   false,
    mouthOpen:      false,
    tongueVisible:  false,
    isStable:       false,
    stableProgress: 0.0,
    hint:           '请将面部对准摄像头',
  );

  factory TongueGuideState.fromMap(Map<dynamic, dynamic> map) {
    return TongueGuideState(
      faceDetected:   (map['faceDetected']  as bool?) ?? false,
      mouthOpen:      (map['mouthOpen']     as bool?) ?? false,
      tongueVisible:  (map['tongueVisible'] as bool?) ?? false,
      isStable:       (map['isStable']      as bool?) ?? false,
      stableProgress: (map['stableProgress'] as num?)?.toDouble() ?? 0.0,
      hint:           (map['hint']          as String?) ?? '',
    );
  }
}

/// 封装舌诊相关的所有 Platform Channel 操作
class TongueChannel {
  static const _frameChannel  = MethodChannel('tongue/frame');
  static const _guideChannel  = EventChannel('tongue/guide/stream');
  static const _captureChannel = EventChannel('tongue/capture/stream');

  StreamSubscription<TongueGuideState>? _guideSubscription;
  StreamSubscription<dynamic>? _captureSubscription;

  /// 向原生层发送一帧相机图像
  Future<void> sendFrame({
    required List<int> bytes,
    required int width,
    required int height,
    required int bytesPerRow,
    required int rotation,
  }) async {
    try {
      await _frameChannel.invokeMethod('processFrame', {
        'bytes':      Uint8List.fromList(bytes),
        'width':      width,
        'height':     height,
        'bytesPerRow': bytesPerRow,
        'rotation':   rotation,
      });
    } catch (e) {
      // 帧发送失败不抛出，避免中断相机流
    }
  }

  /// 监听引导状态推送
  void listenGuideState(void Function(TongueGuideState state) onState) {
    _guideSubscription?.cancel();
    _guideSubscription = _guideChannel
        .receiveBroadcastStream()
        .map((event) {
          if (event is Map) return TongueGuideState.fromMap(event);
          return TongueGuideState.idle();
        })
        .listen(
          onState,
          onError: (e) {}, // channel 错误静默处理
        );
  }

  /// 监听抓拍图像推送（JPEG 字节）
  void listenCapture(void Function(Uint8List jpeg) onCapture) {
    _captureSubscription?.cancel();
    _captureSubscription = _captureChannel
        .receiveBroadcastStream()
        .listen(
          (event) {
            if (event is List) {
              onCapture(Uint8List.fromList(event.cast<int>()));
            } else if (event is Uint8List) {
              onCapture(event);
            }
          },
          onError: (e) {},
        );
  }

  /// 取消所有监听
  void dispose() {
    _guideSubscription?.cancel();
    _captureSubscription?.cancel();
    _guideSubscription  = null;
    _captureSubscription = null;
  }
}
