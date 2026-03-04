import 'dart:ui';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

/// Converts a [CameraImage] from the camera stream to an ML Kit [InputImage].
///
/// Returns `null` if rotation or format cannot be determined.
InputImage? cameraImageToInputImage(
  CameraImage image,
  CameraDescription camera,
  DeviceOrientation deviceOrientation,
) {
  final rotation = _inputImageRotationFromCamera(
    camera: camera,
    deviceOrientation: deviceOrientation,
  );
  if (rotation == null) return null;

  final format = InputImageFormatValue.fromRawValue(image.format.raw);
  if (format == null) return null;

  final isAndroidFormatValid =
      Platform.isAndroid && format == InputImageFormat.nv21;
  final isIosFormatValid =
      Platform.isIOS && format == InputImageFormat.bgra8888;
  if (!(isAndroidFormatValid || isIosFormatValid)) return null;

  // Android camera streams may arrive as either 1-plane NV21 or 3-plane YUV420.
  // ML Kit expects NV21 bytes on Android, so convert multi-plane YUV if needed.
  final Uint8List bytes;
  final int bytesPerRow;

  if (Platform.isAndroid) {
    if (image.planes.length == 1) {
      bytes = image.planes.first.bytes;
      bytesPerRow = image.planes.first.bytesPerRow;
    } else if (image.planes.length >= 3) {
      bytes = _yuv420ToNv21(image);
      bytesPerRow = image.width;
    } else {
      return null;
    }
  } else {
    if (image.planes.length != 1) return null;
    bytes = image.planes.first.bytes;
    bytesPerRow = image.planes.first.bytesPerRow;
  }

  return InputImage.fromBytes(
    bytes: bytes,
    metadata: InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: bytesPerRow,
    ),
  );
}

Uint8List _yuv420ToNv21(CameraImage image) {
  final width = image.width;
  final height = image.height;

  if (image.planes.length < 3) {
    throw StateError('Expected at least 3 planes for YUV420 format, got ${image.planes.length}');
  }

  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];

  final ySize = width * height;
  final uvSize = ySize ~/ 2;
  final out = Uint8List(ySize + uvSize);

  int outIndex = 0;

  for (int row = 0; row < height; row++) {
    final rowStart = row * yPlane.bytesPerRow;
    out.setRange(outIndex, outIndex + width, yPlane.bytes, rowStart);
    outIndex += width;
  }

  final uvHeight = height ~/ 2;
  final uvWidth = width ~/ 2;
  final uvPixelStride = uPlane.bytesPerPixel ?? 1;

  for (int row = 0; row < uvHeight; row++) {
    final uRowStart = row * uPlane.bytesPerRow;
    final vRowStart = row * vPlane.bytesPerRow;
    for (int col = 0; col < uvWidth; col++) {
      final uIndex = uRowStart + col * uvPixelStride;
      final vIndex = vRowStart + col * uvPixelStride;
      out[outIndex++] = vPlane.bytes[vIndex];
      out[outIndex++] = uPlane.bytes[uIndex];
    }
  }

  return out;
}

InputImageRotation? _inputImageRotationFromCamera({
  required CameraDescription camera,
  required DeviceOrientation deviceOrientation,
}) {
  if (Platform.isIOS) {
    return InputImageRotationValue.fromRawValue(camera.sensorOrientation);
  }

  if (Platform.isAndroid) {
    const orientationMap = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    };

    final rotationCompensation = orientationMap[deviceOrientation];
    if (rotationCompensation == null) return null;

    final sensorOrientation = camera.sensorOrientation;
    final adjustedRotation = camera.lensDirection == CameraLensDirection.front
        ? (sensorOrientation + rotationCompensation) % 360
        : (sensorOrientation - rotationCompensation + 360) % 360;

    return InputImageRotationValue.fromRawValue(adjustedRotation);
  }

  return null;
}

/// Translates an x-coordinate from ML Kit image space to canvas/screen space.
///
/// Accounts for sensor rotation and camera lens direction (mirroring for front
/// camera).
double translateX(
  double x,
  Size canvasSize,
  Size imageSize,
  InputImageRotation rotation,
  CameraLensDirection direction,
) {
  double translatedX;
  switch (rotation) {
    case InputImageRotation.rotation90deg:
      translatedX = x * canvasSize.width / imageSize.height;
    case InputImageRotation.rotation270deg:
      translatedX =
          (imageSize.height - x) * canvasSize.width / imageSize.height;
    case InputImageRotation.rotation180deg:
      translatedX = (imageSize.width - x) * canvasSize.width / imageSize.width;
    case InputImageRotation.rotation0deg:
      translatedX = x * canvasSize.width / imageSize.width;
  }
  if (direction == CameraLensDirection.front) {
    translatedX = canvasSize.width - translatedX;
  }
  return translatedX;
}

/// Translates a y-coordinate from ML Kit image space to canvas/screen space.
///
/// Accounts for sensor rotation.
double translateY(
  double y,
  Size canvasSize,
  Size imageSize,
  InputImageRotation rotation,
) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return y * canvasSize.height / imageSize.width;
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      return y * canvasSize.height / imageSize.height;
  }
}
