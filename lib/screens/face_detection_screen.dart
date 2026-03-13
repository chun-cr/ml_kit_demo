import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

import '../painters/face_painter.dart';
import '../utils/adaptive_throttle.dart';
import '../utils/camera_utils.dart';

/// 自包含的面部检测页面：相机 + 检测器 + 描点绘制
///
/// Android：使用 google_mlkit_face_detection + google_mlkit_face_mesh_detection
/// iOS：使用 google_mlkit_face_detection + MediaPipe FaceLandmarker (via platform channel)
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

  // ── 检测器（Android only） ──────────────────────────────────
  FaceDetector? _faceDetector;
  FaceMeshDetector? _faceMeshDetector;

  // ── iOS: MediaPipe FaceLandmarker via platform channel ─────
  static const _iosFaceFrameChannel = MethodChannel('face/frame');
  static const _iosFaceMeshChannel  = EventChannel('face/mesh/stream');
  StreamSubscription? _iosFaceMeshSubscription;

  // iOS FaceLandmarker 结果：每张脸 478 个归一化坐标点
  // 格式：List<List<Offset>>，与 _meshes 用途相同但来源不同
  List<List<Offset>> _iosFaceLandmarks = [];
  List<List<Offset>> _lastGoodIosFaceLandmarks = [];
  // Smoothing buffer: stores last N frames of landmarks per face
  final List<List<List<Offset>>> _landmarkHistory = [];
  static const int _smoothingFrames = 8; // increase from 5 to 8
  int _emptyFrameCount = 0;
  static const int _maxEmptyFrames = 6;

  // ── 整体初始化状态 ──────────────────────────────────────────
  bool _isInitialized = false;

  // ── 检测结果 ────────────────────────────────────────────────
  List<Face> _faces = [];
  List<FaceMesh> _meshes = [];   // Android only
  Size? _imageSize;
  int _faceCount = 0;

  // ── 自适应帧率控制 ────────────────────────────────────────────
  final _detectThrottle = AdaptiveThrottle(
    minInterval: 33,
    maxInterval: 100,
    targetProcessTime: 80,
  );
  final _paintThrottle = AdaptiveThrottle(
    minInterval: 30,
    maxInterval: 30,
    adaptive: false,
  );

  // ── iOS 帧发送节流（与手势识别共享同一套逻辑）──────────────
  final _iosFaceThrottle = AdaptiveThrottle(
    minInterval: 33,
    maxInterval: 100,
    targetProcessTime: 80,
  );

  // ── Lifecycle ─────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isIOS) {
      _listenIosFaceMeshStream();
    }
    _initAll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    switch (state) {
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.paused:
        _releaseCamera();
        break;
      case AppLifecycleState.resumed:
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
    _iosFaceMeshSubscription?.cancel();
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
    if (mounted) setState(() => _isInitialized = false);
  }

  // ── 统一初始化 ────────────────────────────────────────────────
  Future<void> _initAll() async {
    if (_isDisposed) return;
    if (mounted) setState(() => _isInitialized = false);

    try {
      final futures = <Future>[_initCamera()];
      if (!Platform.isIOS) futures.add(_initDetectors());
      await Future.wait(futures);

      if (_isDisposed) return;

      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          (Platform.isIOS || _faceDetector != null)) {
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

  // ── 初始化检测器（Android only） ────────────────────────────
  Future<void> _initDetectors() async {
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

  // ── iOS: 监听 FaceLandmarker 结果 ──────────────────────────
  void _listenIosFaceMeshStream() {
    _iosFaceMeshSubscription =
        _iosFaceMeshChannel.receiveBroadcastStream().listen(
      (event) {
        if (_isDisposed || !mounted) return;
        if (event is! Map) return;
        final facesRaw = event['faces'];
        if (facesRaw is! List) {
          _landmarkHistory.clear();
          _lastGoodIosFaceLandmarks = [];
          setState(() {
            _iosFaceLandmarks = [];
            _faceCount = 0;
          });
          return;
        }
        final parsed = <List<Offset>>[];
        for (final face in facesRaw) {
          if (face is! List) continue;
          final pts = <Offset>[];
          for (final pt in face) {
            if (pt is Map) {
              final x = (pt['x'] as num?)?.toDouble() ?? 0.0;
              final y = (pt['y'] as num?)?.toDouble() ?? 0.0;
              pts.add(Offset(x, y));
            }
          }
          if (pts.isNotEmpty && _isLandmarkSetValid(pts)) {
            parsed.add(pts);
          }
        }
        final stableParsed = _filterUnstableLandmarks(parsed);
        if (stableParsed.isEmpty) {
          _emptyFrameCount++;
          if (_emptyFrameCount >= _maxEmptyFrames) {
            _landmarkHistory.clear();
            _lastGoodIosFaceLandmarks = [];
            setState(() {
              _iosFaceLandmarks = [];
              _faceCount = 0;
            });
          }
        } else {
          _emptyFrameCount = 0;
          final smoothed = _smoothLandmarks(stableParsed);
          _lastGoodIosFaceLandmarks = smoothed
              .map((face) => List<Offset>.from(face))
              .toList();
          setState(() {
            _iosFaceLandmarks = smoothed;
            _faceCount = smoothed.length;
          });
        }
      },
      onError: (e) => debugPrint('[FaceMeshChannel] error: $e'),
    );
  }

  /// Returns true if landmark set looks valid (points spread across a reasonable area)
  bool _isLandmarkSetValid(List<Offset> landmarks) {
    if (landmarks.length < 100) return false;

    double minX = double.infinity, maxX = 0;
    double minY = double.infinity, maxY = 0;

    for (final pt in landmarks) {
      if (pt.dx < minX) minX = pt.dx;
      if (pt.dx > maxX) maxX = pt.dx;
      if (pt.dy < minY) minY = pt.dy;
      if (pt.dy > maxY) maxY = pt.dy;
    }

    final spreadX = maxX - minX;
    final spreadY = maxY - minY;

    // Valid face landmarks should spread at least 5% of the normalized image in both axes
    return spreadX > 0.05 && spreadY > 0.05;
  }

  List<List<Offset>> _filterUnstableLandmarks(List<List<Offset>> candidates) {
    if (_lastGoodIosFaceLandmarks.isEmpty ||
        _lastGoodIosFaceLandmarks.length != candidates.length) {
      return candidates;
    }

    final filtered = <List<Offset>>[];
    for (int i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      final previous = _lastGoodIosFaceLandmarks[i];
      if (_isLandmarkTransitionStable(previous, candidate)) {
        filtered.add(candidate);
      }
    }
    return filtered;
  }

  bool _isLandmarkTransitionStable(
    List<Offset> previous,
    List<Offset> candidate,
  ) {
    if (previous.length < 100 || candidate.length < 100) return false;

    final previousBounds = _computeLandmarkBounds(previous);
    final candidateBounds = _computeLandmarkBounds(candidate);

    final previousCenter = previousBounds.center;
    final candidateCenter = candidateBounds.center;
    final centerShift = (candidateCenter - previousCenter).distance;

    final previousWidth = previousBounds.width;
    final previousHeight = previousBounds.height;
    final candidateWidth = candidateBounds.width;
    final candidateHeight = candidateBounds.height;

    if (previousWidth <= 0 || previousHeight <= 0) return true;

    final widthRatio = candidateWidth / previousWidth;
    final heightRatio = candidateHeight / previousHeight;

    // 眼镜反光/遮挡导致的异常帧通常表现为：
    // 1) 面部中心瞬间大跳；2) 点集边界突然塌缩或膨胀。
    return centerShift < 0.12 &&
        widthRatio > 0.7 &&
        widthRatio < 1.3 &&
        heightRatio > 0.7 &&
        heightRatio < 1.3;
  }

  Rect _computeLandmarkBounds(List<Offset> landmarks) {
    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (final pt in landmarks) {
      if (pt.dx < minX) minX = pt.dx;
      if (pt.dx > maxX) maxX = pt.dx;
      if (pt.dy < minY) minY = pt.dy;
      if (pt.dy > maxY) maxY = pt.dy;
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  List<List<Offset>> _smoothLandmarks(List<List<Offset>> newFrameLandmarks) {
    // If face count changed, reset history
    if (_landmarkHistory.isEmpty ||
        _landmarkHistory[0].length != newFrameLandmarks.length) {
      _landmarkHistory.clear();
    }

    _landmarkHistory.add(newFrameLandmarks);
    if (_landmarkHistory.length > _smoothingFrames) {
      _landmarkHistory.removeAt(0);
    }

    // Average coordinates across buffered frames
    final smoothed = <List<Offset>>[];
    final faceCount = newFrameLandmarks.length;
    for (int f = 0; f < faceCount; f++) {
      final pointCount = newFrameLandmarks[f].length;
      final smoothedFace = <Offset>[];
      for (int p = 0; p < pointCount; p++) {
        double sx = 0, sy = 0;
        int count = 0;
        for (final frame in _landmarkHistory) {
          if (f < frame.length && p < frame[f].length) {
            sx += frame[f][p].dx;
            sy += frame[f][p].dy;
            count++;
          }
        }
        smoothedFace.add(
          count > 0
              ? Offset(sx / count, sy / count)
              : newFrameLandmarks[f][p],
        );
      }
      smoothed.add(smoothedFace);
    }
    return smoothed;
  }

  // ── Image stream ──────────────────────────────────────────────
  void _startStream() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isStreamingImages) return;
    try {
      if (Platform.isIOS) {
        controller.startImageStream(_processImageIos);
      } else {
        controller.startImageStream(_processImageAndroid);
      }
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

  // ── iOS 帧处理：发送到原生 FaceLandmarker + ML Kit 人脸检测 ──
  Future<void> _processImageIos(CameraImage image) async {
    if (_isDisposed) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    // 描点刷新
    if (_paintThrottle.shouldProcess()) {
      if (mounted) setState(() {});
    }

    if (!_iosFaceThrottle.shouldProcess()) return;
    _iosFaceThrottle.setProcessing(true);
    final startTime = DateTime.now().millisecondsSinceEpoch;

    try {
      // iOS BGRA8888: 单平面，必须传 bytesPerRow （包含 stride padding）
      final plane = image.planes.first;
      final bytes = plane.bytes;
      final bytesPerRow = plane.bytesPerRow;
      // sensorOrientation 在 iOS 上是正确的旋转补偿值（与 camera_utils.dart 一致）
      final rotation = _cameraController!.description.sensorOrientation;

      // 同时发送给 ML Kit（人脸检测框 + 表情）和 FaceLandmarker（特征点）
      await Future.wait([
        _sendToMlKitIos(image),
        _iosFaceFrameChannel.invokeMethod('processFrame', {
          'bytes': bytes,
          'width': image.width,
          'height': image.height,
          'bytesPerRow': bytesPerRow,
          'rotation': rotation,
        }),
      ]);
    } catch (e) {
      debugPrint('[FaceDetection iOS] error: $e');
    } finally {
      final cost = DateTime.now().millisecondsSinceEpoch - startTime;
      _iosFaceThrottle.recordProcessTime(cost);
      _iosFaceThrottle.setProcessing(false);
    }
  }

  Future<void> _sendToMlKitIos(CameraImage image) async {
    _faceDetector ??= FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableContours: false,
        enableLandmarks: false,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    try {
      final inputImage = cameraImageToInputImage(
        image,
        _camera!,
        _cameraController!.value.deviceOrientation,
      );
      if (inputImage == null) return;

      // iOS: ML Kit 内部已处理旋转，boundingBox 坐标基于原始传感器尺寸
      // （像素坐标，不需要对调宽高）。对调会导致坐标映射错误，人脸框偏移。
      // Android: sensorOrientation=90/270 时需要对调，因为返回坐标是旋转后的。
      final rawSize = inputImage.metadata!.size;
      final so = _camera!.sensorOrientation;
      _imageSize = (!Platform.isIOS && (so == 90 || so == 270))
          ? Size(rawSize.height, rawSize.width)
          : rawSize;

      final faces = await _faceDetector!.processImage(inputImage);
      if (mounted && !_isDisposed) {
        setState(() {
          _faces = faces;
          // faceCount 由 FaceLandmarker 结果决定，这里只更新检测框
        });
      }
    } catch (e) {
      debugPrint('[FaceDetection iOS MLKit] error: $e');
    }
  }

  // ── Android 帧处理（原逻辑不变）────────────────────────────
  Future<void> _processImageAndroid(CameraImage image) async {
    if (_isDisposed) return;
    if (_faceDetector == null || _camera == null) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    if (_paintThrottle.shouldProcess()) {
      if (mounted) setState(() {});
    }
    if (!_detectThrottle.shouldProcess()) return;

    _detectThrottle.setProcessing(true);
    final startTime = DateTime.now().millisecondsSinceEpoch;

    try {
      final inputImage = cameraImageToInputImage(
        image, _camera!, _cameraController!.value.deviceOrientation,
      );
      if (inputImage == null) return;

      final rawSize = inputImage.metadata!.size;
      final so = _camera!.sensorOrientation;
      _imageSize = (so == 90 || so == 270)
          ? Size(rawSize.height, rawSize.width)
          : rawSize;

      final results = await Future.wait([
        _faceDetector!.processImage(inputImage),
        _faceMeshDetector != null
            ? _faceMeshDetector!
                .processImage(inputImage)
                .catchError((_) => <FaceMesh>[])
            : Future.value(<FaceMesh>[]),
      ]);
      final faces = results[0] as List<Face>;
      final meshes = results[1] as List<FaceMesh>;

      if (mounted && !_isDisposed) {
        setState(() {
          _faces = faces;
          _meshes = meshes;
          _faceCount = faces.length;
        });
      }
    } catch (e) {
      debugPrint('[FaceDetection Android] Error: $e');
    } finally {
      final cost = DateTime.now().millisecondsSinceEpoch - startTime;
      _detectThrottle.recordProcessTime(cost);
      _detectThrottle.setProcessing(false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) return _buildErrorView();
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
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 64),
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
              style: TextStyle(color: Colors.white54, fontSize: 14, letterSpacing: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainView() {
    // iOS 用 FaceLandmarker 点数，Android 用 ML Kit 结果
    final displayCount = Platform.isIOS ? _iosFaceLandmarks.length : _faceCount;
    final hasMesh = Platform.isIOS
        ? _iosFaceLandmarks.isNotEmpty
        : _meshes.isNotEmpty;
    final meshLabel = Platform.isIOS ? '478 特征点' : '468 特征点';

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
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00C9FF), Color(0xFF92FE9D)],
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.face_retouching_natural_rounded,
                            color: Colors.white, size: 16),
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
                            // 绘制层：iOS 用 FaceLandmarker 点，Android 用 ML Kit
                            if (Platform.isIOS)
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: FacePainter(
                                    faces: _faces,
                                    meshes: const [],
                                    iosFaceLandmarks: _iosFaceLandmarks,
                                    imageSize: _imageSize ?? const Size(1, 1),
                                    cameraLensDirection: _camera!.lensDirection,
                                    sensorOrientation: _camera!.sensorOrientation,
                                    isIos: true,
                                  ),
                                ),
                              )
                            else if (_imageSize != null)
                              CustomPaint(
                                painter: FacePainter(
                                  faces: _faces,
                                  meshes: _meshes,
                                  iosFaceLandmarks: const [],
                                  imageSize: _imageSize!,
                                  cameraLensDirection: _camera!.lensDirection,
                                  sensorOrientation: _camera!.sensorOrientation,
                                ),
                              ),
                            // 调试信息
                            Positioned(
                              top: 10,
                              right: 10,
                              child: Text(
                                '检测间隔: ${Platform.isIOS ? _iosFaceThrottle.currentInterval : _detectThrottle.currentInterval}ms',
                                style: const TextStyle(color: Colors.green, fontSize: 12),
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
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
                  displayCount > 0
                      ? '检测到 $displayCount 张人脸  ·  ${hasMesh ? meshLabel : "特征点加载中…"}'
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
    final isActive = Platform.isIOS ? _iosFaceLandmarks.isNotEmpty : _faceCount > 0;
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
