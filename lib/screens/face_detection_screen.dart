import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

import '../painters/face_painter.dart';
import '../utils/adaptive_throttle.dart';
import '../utils/camera_utils.dart';

/// 自包含的面部检测页面：相机 + 检测器 + 描点绘制
class FaceDetectionScreen extends StatefulWidget {
  const FaceDetectionScreen({super.key});

  @override
  State<FaceDetectionScreen> createState() => _FaceDetectionScreenState();
}

class _FaceDetectionScreenState extends State<FaceDetectionScreen>
    with WidgetsBindingObserver {
  // ── 相机相关 ─────────────────────────────────────────────────
  CameraController? _cameraController;
  CameraDescription? _camera;
  bool _isDisposed = false;
  String? _errorMessage;

  // ── 检测器 ──────────────────────────────────────────────────
  FaceDetector? _faceDetector;
  FaceMeshDetector? _faceMeshDetector;

  // ── 整体初始化状态 ──────────────────────────────────────────
  bool _isInitialized = false;

  // ── 检测结果 ────────────────────────────────────────────────
  List<Face> _faces = [];
  List<FaceMesh> _meshes = [];
  Size? _imageSize;
  int _faceCount = 0;

  // ── 自适应帧率控制 ────────────────────────────────────────────
  final _detectThrottle = AdaptiveThrottle(); // 检测频率（自适应）
  final _paintThrottle = AdaptiveThrottle(
    // 描点刷新（固定 30ms）
    minInterval: 30,
    maxInterval: 30,
    adaptive: false,
  );

  // ── Lifecycle ─────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;

    switch (state) {
      case AppLifecycleState.inactive:
        // 上滑查看后台时触发，不释放相机，画面自然定格在最后一帧
        break;
      case AppLifecycleState.paused:
        // 真正进入后台才释放相机资源
        _releaseCamera();
        break;
      case AppLifecycleState.resumed:
        // 回到前台重新初始化
        _initAll();
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopStream();
    _cameraController?.dispose();
    _cameraController = null;
    _faceDetector?.close();
    _faceMeshDetector?.close();
    super.dispose();
  }

  // ── 释放相机资源 ──────────────────────────────────────────────
  void _releaseCamera() {
    _stopStream();
    _cameraController?.dispose();
    _cameraController = null;
    _camera = null;
    if (mounted) {
      setState(() => _isInitialized = false);
    }
  }

  // ── 统一初始化（相机 + 检测器并行）────────────────────────────
  Future<void> _initAll() async {
    if (_isDisposed) return;
    if (mounted) setState(() => _isInitialized = false);

    try {
      await Future.wait([_initCamera(), _initDetectors()]);

      if (_isDisposed) return;

      // 相机和检测器都准备好后开始帧流
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          _faceDetector != null) {
        _startStream();
        if (mounted) setState(() => _isInitialized = true);
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = '初始化失败：$e');
    }
  }

  // ── 初始化相机 ──────────────────────────────────────────────
  Future<void> _initCamera() async {
    if (_isDisposed) return;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _errorMessage = '未发现可用摄像头');
        return;
      }

      _camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        _camera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.nv21,
      );

      await _cameraController!.initialize();
    } catch (e) {
      debugPrint('[FaceDetection] Camera init error: $e');
      if (mounted) setState(() => _errorMessage = '摄像头初始化失败：$e');
    }
  }

  // ── 初始化检测器（异步，与相机并行）────────────────────────
  Future<void> _initDetectors() async {
    // 检测器初始化本身很快，但放在 Future 里便于 Future.wait 并行
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableContours: true,
        enableLandmarks: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );

    _faceMeshDetector = FaceMeshDetector(
      option: FaceMeshDetectorOptions.faceMesh,
    );
  }

  // ── Image stream ──────────────────────────────────────────────
  void _startStream() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isStreamingImages) return;

    try {
      controller.startImageStream(_processImage);
    } catch (e) {
      debugPrint('[FaceDetection] Failed to start stream: $e');
    }
  }

  void _stopStream() {
    try {
      if (_cameraController?.value.isStreamingImages ?? false) {
        _cameraController?.stopImageStream();
      }
    } catch (_) {}
  }

  // ── Processing（自适应节流）──────────────────────────────────────
  Future<void> _processImage(CameraImage image) async {
    if (_isDisposed) return;
    if (_faceDetector == null || _camera == null) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized)
      return;

    // 描点刷新：固定高频（用缓存数据，不重新检测）
    if (_paintThrottle.shouldProcess()) {
      if (mounted) setState(() {});
    }

    // 检测：自适应频率
    if (!_detectThrottle.shouldProcess()) return;

    _detectThrottle.setProcessing(true);
    final startTime = DateTime.now().millisecondsSinceEpoch;

    try {
      final inputImage = cameraImageToInputImage(
        image,
        _camera!,
        _cameraController!.value.deviceOrientation,
      );
      if (inputImage == null) return;

      final rawSize = inputImage.metadata!.size;
      final sensorOrientation = _camera!.sensorOrientation;
      if (sensorOrientation == 90 || sensorOrientation == 270) {
        _imageSize = Size(rawSize.height, rawSize.width);
      } else {
        _imageSize = rawSize;
      }

      final faces = await _faceDetector!.processImage(inputImage);

      List<FaceMesh> meshes = [];
      try {
        if (_faceMeshDetector != null) {
          meshes = await _faceMeshDetector!.processImage(inputImage);
        }
      } catch (_) {}

      if (mounted && !_isDisposed) {
        _faces = faces;
        _meshes = meshes;
        _faceCount = faces.length;
      }
    } catch (e) {
      debugPrint('[FaceDetection] Error: $e');
    } finally {
      // 记录耗时，自动调整下一帧间隔
      final cost = DateTime.now().millisecondsSinceEpoch - startTime;
      _detectThrottle.recordProcessTime(cost);
      _detectThrottle.setProcessing(false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return _buildErrorView();
    }
    if (!_isInitialized ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return _buildLoadingView();
    }
    return _buildMainView();
  }

  Widget _buildErrorView() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 64,
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF00C9FF).withValues(alpha: 0.3),
                    const Color(0xFF92FE9D).withValues(alpha: 0.1),
                  ],
                ),
              ),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Color(0xFF00C9FF),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '正在初始化摄像头…',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 14,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainView() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: Column(
          children: [
            // ─── 顶部标题栏 ─────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00C9FF), Color(0xFF92FE9D)],
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.face_retouching_natural_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                        SizedBox(width: 6),
                        Text(
                          '面部检测',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  _buildStatusDot(),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ─── 摄像头预览 + 描点叠加 ──────────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1 / _cameraController!.value.aspectRatio,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: const Color(0xFF00C9FF).withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraPreview(_cameraController!),
                            if (_imageSize != null)
                              CustomPaint(
                                painter: FacePainter(
                                  faces: _faces,
                                  meshes: _meshes,
                                  imageSize: _imageSize!,
                                  cameraLensDirection: _camera!.lensDirection,
                                  sensorOrientation: _camera!.sensorOrientation,
                                ),
                              ),
                            // ── 调试信息：当前自适应检测间隔 ──────────
                            Positioned(
                              top: 10,
                              right: 10,
                              child: Text(
                                '检测间隔: ${_detectThrottle.currentInterval}ms',
                                style: const TextStyle(
                                  color: Colors.green,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // ─── 底部状态栏 ─────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF00C9FF).withValues(alpha: 0.15),
                      const Color(0xFF92FE9D).withValues(alpha: 0.05),
                    ],
                  ),
                  border: Border.all(
                    color: const Color(0xFF00C9FF).withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
                child: Text(
                  _faceCount > 0
                      ? '检测到 $_faceCount 张人脸  ·  ${_meshes.isNotEmpty ? "468 特征点" : "特征点加载中…"}'
                      : '未检测到人脸',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusDot() {
    final isActive = _faceCount > 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive ? const Color(0xFF00FF88) : Colors.white24,
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: const Color(0xFF00FF88).withValues(alpha: 0.5),
                      blurRadius: 8,
                    ),
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          isActive ? 'Tracking' : 'Waiting',
          style: TextStyle(
            color: isActive ? const Color(0xFF00FF88) : Colors.white38,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
