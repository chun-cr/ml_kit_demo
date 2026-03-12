// 舌诊采集页面：相机预览 + 引导检测 + 满足条件自动抓拍跳转结果页

import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/tongue_channel.dart';
import '../services/module_preloader.dart';
import '../utils/adaptive_throttle.dart';
import 'tongue_result_screen.dart';

/// 三步引导阶段
enum _GuideStep { alignFace, showTongue, holdStill }

/// 舌诊采集全屏页（独立页面，通过 Navigator.push 打开）
class TongueCaptureScreen extends StatefulWidget {
  final String claudeApiKey;

  const TongueCaptureScreen({super.key, required this.claudeApiKey});

  @override
  State<TongueCaptureScreen> createState() => _TongueCaptureScreenState();
}

class _TongueCaptureScreenState extends State<TongueCaptureScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── 相机 ─────────────────────────────────────────────────────
  CameraController? _controller;
  CameraDescription? _camera;
  bool _isInitialized = false;
  bool _isDisposed    = false;
  String? _errorMessage;

  // ── 通道 ─────────────────────────────────────────────────────
  final _tongueChannel = TongueChannel();

  // ── 引导状态 ─────────────────────────────────────────────────
  TongueGuideState _guideState = TongueGuideState.idle();

  // ── 帧率控制 ─────────────────────────────────────────────────
  final _frameThrottle = AdaptiveThrottle();

  // ── 抓拍防重入 ────────────────────────────────────────────────
  bool _captured = false;
  bool _isResultPageOpen = false;
  bool _isNavigatingToResult = false;

  // ── 椭圆描边动画控制器 ────────────────────────────────────────
  late AnimationController _ovalController;
  late Animation<double>   _ovalAnim;

  // ── 步骤标签 ─────────────────────────────────────────────────
  static const _stepLabels = [
    '对准面部', '伸出舌头', '保持不动',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ovalController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _ovalAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ovalController, curve: Curves.easeInOut),
    );

    _tongueChannel.listenGuideState(_onGuideState);
    _tongueChannel.listenCapture(_onCapture);
    _initAll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    if (state == AppLifecycleState.paused)  _releaseCamera();
    if (state == AppLifecycleState.resumed && !_isResultPageOpen) _initAll();
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _tongueChannel.dispose();
    _stopStream();
    _controller?.dispose();
    _ovalController.dispose();
    super.dispose();
  }

  // ── 初始化 ───────────────────────────────────────────────────

  Future<void> _initAll() async {
    if (_isDisposed) return;
    if (mounted) setState(() => _isInitialized = false);
    try {
      await ModulePreloader.warmupTongue();
      await _initCamera();
      if (_isDisposed) return;
      if (_controller != null && _controller!.value.isInitialized) {
        _startStream();
        if (mounted) setState(() => _isInitialized = true);
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = '初始化相机失败：$e');
    }
  }

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
      _controller = CameraController(
        _camera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.nv21,
      );
      await _controller!.initialize();
    } catch (e) {
      debugPrint('[TongueCapture] Camera init error: $e');
      if (mounted) setState(() => _errorMessage = '摄像头初始化失败：$e');
    }
  }

  void _releaseCamera() {
    _stopStream();
    _controller?.dispose();
    _controller = null;
    if (mounted) setState(() => _isInitialized = false);
  }

  // ── 帧流 ─────────────────────────────────────────────────────

  void _startStream() {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (ctrl.value.isStreamingImages) return;
    try {
      ctrl.startImageStream(_processFrame);
    } catch (e) {
      debugPrint('[TongueCapture] Failed to start stream: $e');
    }
  }

  void _stopStream() {
    try {
      if (_controller?.value.isStreamingImages ?? false) {
        _controller?.stopImageStream();
      }
    } catch (_) {}
  }

  Future<void> _processFrame(CameraImage image) async {
    if (_isDisposed || _captured) return;
    if (!_frameThrottle.shouldProcess()) return;

    _frameThrottle.setProcessing(true);
    final start = DateTime.now().millisecondsSinceEpoch;
    try {
      final plane      = image.planes.first;
      final rotation   = Platform.isIOS
          ? _controller!.description.sensorOrientation
          : _calcAndroidRotation();
      await _tongueChannel.sendFrame(
        bytes:      plane.bytes,
        width:      image.width,
        height:     image.height,
        bytesPerRow: plane.bytesPerRow,
        rotation:   rotation,
      );
    } finally {
      final cost = DateTime.now().millisecondsSinceEpoch - start;
      _frameThrottle.recordProcessTime(cost);
      _frameThrottle.setProcessing(false);
    }
  }

  int _calcAndroidRotation() {
    if (_controller == null) return 0;
    const orientationMap = {
      DeviceOrientation.portraitUp:    0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown:  180,
      DeviceOrientation.landscapeRight: 270,
    };
    final deviceRot = orientationMap[_controller!.value.deviceOrientation] ?? 0;
    final so = _controller!.description.sensorOrientation;
    return (so + deviceRot) % 360;
  }

  // ── 引导状态处理 ─────────────────────────────────────────────

  void _onGuideState(TongueGuideState state) {
    if (_isDisposed || !mounted || _captured) return;
    setState(() => _guideState = state);

    // 满足条件时原生层会通过 capture channel 推送图像；这里监听 isStable 锁定
    if (state.isStable && state.stableProgress >= 1.0 && !_captured) {
      _captured = true;
    }
  }

  Future<void> _onCapture(Uint8List jpeg) async {
    if (_isDisposed || !mounted || _isNavigatingToResult) return;
    _isNavigatingToResult = true;
    _isResultPageOpen = true;
    _stopStream();
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TongueResultScreen(
            imageBytes:    jpeg,
            claudeApiKey:  widget.claudeApiKey,
          ),
        ),
      );

      if (_isDisposed || !mounted) return;
      setState(() {
        _captured = false;
        _guideState = TongueGuideState.idle();
      });

      if (_controller != null && _controller!.value.isInitialized) {
        _startStream();
      } else {
        await _initAll();
      }
    } finally {
      _isResultPageOpen = false;
      _isNavigatingToResult = false;
    }
  }

  // ── 当前引导阶段 ─────────────────────────────────────────────

  _GuideStep get _currentStep {
    if (!_guideState.faceDetected)  return _GuideStep.alignFace;
    if (!_guideState.tongueVisible) return _GuideStep.showTongue;
    return _GuideStep.holdStill;
  }

  // ── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) return _buildError();
    if (!_isInitialized || _controller == null) return _buildLoading();
    return _buildMain();
  }

  Widget _buildError() => Scaffold(
    backgroundColor: const Color(0xFF0A0A0F),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
          const SizedBox(height: 16),
          Text(_errorMessage!, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
        ]),
      ),
    ),
  );

  Widget _buildLoading() => const Scaffold(
    backgroundColor: Color(0xFF0A0A0F),
    body: Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: Color(0xFFE8563A), strokeWidth: 3),
        SizedBox(height: 20),
        Text('正在初始化摄像头...', style: TextStyle(color: Colors.white54, fontSize: 14)),
      ]),
    ),
  );

  Widget _buildMain() {
    final step = _currentStep;
    final isReady  = step == _GuideStep.holdStill;
    final ovalColor = isReady ? const Color(0xFF4CAF50) : Colors.white38;
    final progress = _guideState.stableProgress;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── 相机预览（居中，保持真实比例，不拉伸且防放大）──────────────────
          Positioned.fill(
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: CameraPreview(_controller!),
            ),
          ),

          // ── 暗色遮罩（非椭圆区域）──────────────────────────
          CustomPaint(
            painter: _OvalMaskPainter(ovalColor: ovalColor, isReady: isReady),
          ),

          // ── 稳定进度动画描边 ────────────────────────────────
          if (isReady && progress < 1.0)
            AnimatedBuilder(
              animation: _ovalAnim,
              builder: (_, __) => CustomPaint(
                painter: _ProgressOvalPainter(progress: progress, pulse: _ovalAnim.value),
              ),
            ),

          // ── 顶部：四步进度条 ────────────────────────────────
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                            width: 36, height: 36,
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: const Icon(Icons.close, color: Colors.white, size: 20),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          '中医舌诊',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildStepIndicator(step),
                  ],
                ),
              ),
            ),
          ),

          // ── 底部：提示文字 ────────────────────────────────────
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: Column(
                  children: [
                    if (isReady)
                      _buildProgressBar(progress),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Text(
                        _guideState.hint.isNotEmpty ? _guideState.hint : '请将面部对准摄像头',
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(_GuideStep currentStep) {
    final currentIdx = currentStep.index;
    return Row(
      children: List.generate(_stepLabels.length, (i) {
        final done    = i < currentIdx;
        final active  = i == currentIdx;
        final barColor = done ? const Color(0xFFE8563A) : (active ? Colors.white : Colors.white24);
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                height: 3,
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _stepLabels[i],
                style: TextStyle(
                  color: barColor,
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ]),
          ),
        );
      }),
    );
  }

  Widget _buildProgressBar(double progress) {
    return Column(
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('保持稳定', style: TextStyle(color: Colors.white70, fontSize: 12)),
          Text('${(progress * 100).toInt()}%', style: const TextStyle(color: Color(0xFF4CAF50), fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF4CAF50)),
            minHeight: 6,
          ),
        ),
      ],
    );
  }
}

// ── 自定义绘制：椭圆镂空遮罩 ──────────────────────────────────

class _OvalMaskPainter extends CustomPainter {
  final Color ovalColor;
  final bool isReady;
  const _OvalMaskPainter({required this.ovalColor, required this.isReady});

  @override
  void paint(Canvas canvas, Size size) {
    final ovalRect = _ovalRect(size);

    // 暗色遮罩
    final maskPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(maskPath, Paint()..color = Colors.black.withValues(alpha: 0.55));

    // 椭圆描边
    canvas.drawOval(
      ovalRect,
      Paint()
        ..color = ovalColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_OvalMaskPainter old) =>
      old.ovalColor != ovalColor || old.isReady != isReady;
}

class _ProgressOvalPainter extends CustomPainter {
  final double progress;
  final double pulse;
  const _ProgressOvalPainter({required this.progress, required this.pulse});

  @override
  void paint(Canvas canvas, Size size) {
    final ovalRect = _ovalRect(size);
    final sweepAngle = 2 * 3.14159 * progress;

    canvas.drawArc(
      ovalRect,
      -3.14159 / 2,
      sweepAngle,
      false,
      Paint()
        ..color = Color.lerp(const Color(0xFF4CAF50), const Color(0xFF8BC34A), pulse)!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ProgressOvalPainter old) =>
      old.progress != progress || old.pulse != pulse;
}

Rect _ovalRect(Size size) {
  final cx = size.width / 2;
  final cy = size.height * 0.42;
  final rx = size.width * 0.38;
  final ry = size.height * 0.28;
  return Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2);
}
