import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

import '../painters/face_painter.dart';
import '../utils/camera_utils.dart';

/// Overlay widget that runs face detection + face mesh detection on the camera
/// stream and draws the results via [FacePainter].
class FaceDetectionScreen extends StatefulWidget {
  final CameraController controller;
  final CameraDescription camera;

  const FaceDetectionScreen({
    super.key,
    required this.controller,
    required this.camera,
  });

  @override
  State<FaceDetectionScreen> createState() => _FaceDetectionScreenState();
}

class _FaceDetectionScreenState extends State<FaceDetectionScreen> {
  // ── Detectors ─────────────────────────────────────────────────
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      enableContours: true,
      enableLandmarks: true,
      enableTracking: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  final FaceMeshDetector _faceMeshDetector = FaceMeshDetector(
    option: FaceMeshDetectorOptions.faceMesh,
  );

  // ── State ─────────────────────────────────────────────────────
  List<Face> _faces = [];
  List<FaceMesh> _meshes = [];
  bool _isDetecting = false;
  Size? _imageSize; // 已经过旋转补偿的图像尺寸
  int _faceCount = 0;

  // ── 独立频率控制 ──────────────────────────────────────────────
  int _lastDetectTime = 0;
  static const _detectIntervalMs = 100; // 检测频率 100ms
  static const _paintIntervalMs = 30; // 绘制频率 30ms

  // ── 描点刷新定时器 ────────────────────────────────────────────
  Timer? _paintTimer;

  // ── Lifecycle ─────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startStream());

    _paintTimer = Timer.periodic(
      const Duration(milliseconds: _paintIntervalMs),
      (_) {
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _paintTimer?.cancel();
    _stopStream();
    _faceDetector.close();
    _faceMeshDetector.close();
    super.dispose();
  }

  // ── Image stream ──────────────────────────────────────────────
  void _startStream() {
    if (!mounted) return;
    if (!widget.controller.value.isInitialized) return;
    if (widget.controller.value.isStreamingImages) return;

    try {
      widget.controller.startImageStream(_processImage);
    } catch (e) {
      debugPrint('[FaceDetection] Failed to start stream: $e');
    }
  }

  void _stopStream() {
    try {
      if (widget.controller.value.isStreamingImages) {
        widget.controller.stopImageStream();
      }
    } catch (_) {}
  }

  // ── Processing（100ms 节流）────────────────────────────────────
  Future<void> _processImage(CameraImage image) async {
    if (_isDetecting) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastDetectTime < _detectIntervalMs) return;
    _lastDetectTime = now;

    _isDetecting = true;

    try {
      final inputImage = cameraImageToInputImage(
        image,
        widget.camera,
        widget.controller.value.deviceOrientation,
      );
      if (inputImage == null) return;

      // 原始图像尺寸（传感器输出的宽x高）
      final rawSize = inputImage.metadata!.size;

      // Android 竖屏时传感器是横向的，sensorOrientation 为 90 或 270 时需要对调宽高
      // 这样 imageSize 就和预览画面方向一致了
      final sensorOrientation = widget.camera.sensorOrientation;
      if (sensorOrientation == 90 || sensorOrientation == 270) {
        _imageSize = Size(rawSize.height, rawSize.width);
      } else {
        _imageSize = rawSize;
      }

      final faces = await _faceDetector.processImage(inputImage);

      List<FaceMesh> meshes = [];
      try {
        meshes = await _faceMeshDetector.processImage(inputImage);
      } catch (_) {}

      if (mounted) {
        _faces = faces;
        _meshes = meshes;
        _faceCount = faces.length;
      }
    } catch (e) {
      debugPrint('[FaceDetection] Error: $e');
    } finally {
      _isDetecting = false;
    }
  }

  // ── Build ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_imageSize != null)
          CustomPaint(
            painter: FacePainter(
              faces: _faces,
              meshes: _meshes,
              imageSize: _imageSize!,
              cameraLensDirection: widget.camera.lensDirection,
              sensorOrientation: widget.camera.sensorOrientation,
            ),
          ),

        // Bottom status bar
        Positioned(
          bottom: 32,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _faceCount > 0
                    ? '检测到 $_faceCount 张人脸  ·  ${_meshes.isNotEmpty ? "468 特征点" : "特征点加载中…"}'
                    : '未检测到人脸',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
