import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 手势 → Emoji 映射
const Map<String, String> _gestureEmojis = {
  'Open_Palm': '🖐️',
  'Closed_Fist': '✊',
  'Thumb_Up': '👍',
  'Thumb_Down': '👎',
  'Pointing_Up': '☝️',
  'Victory': '✌️',
  'ILoveYou': '🤟',
  'None': '🔍',
};

/// 手势 → 中文名
const Map<String, String> _gestureLabels = {
  'Open_Palm': '张开手掌',
  'Closed_Fist': '握拳',
  'Thumb_Up': '点赞',
  'Thumb_Down': '踩一下',
  'Pointing_Up': '向上指',
  'Victory': '剪刀手',
  'ILoveYou': '我爱你',
  'None': '未检测到',
};

/// 手势 → 渐变色
const Map<String, List<Color>> _gestureColors = {
  'Open_Palm': [Color(0xFF00C9FF), Color(0xFF92FE9D)],
  'Closed_Fist': [Color(0xFFFC5C7D), Color(0xFF6A82FB)],
  'Thumb_Up': [Color(0xFFF7971E), Color(0xFFFFD200)],
  'Thumb_Down': [Color(0xFFEB3349), Color(0xFFF45C43)],
  'Pointing_Up': [Color(0xFF11998E), Color(0xFF38EF7D)],
  'Victory': [Color(0xFF667EEA), Color(0xFF764BA2)],
  'ILoveYou': [Color(0xFFF093FB), Color(0xFFF5576C)],
  'None': [Color(0xFF434343), Color(0xFF000000)],
};

/// 手部骨架连接关系
const List<List<int>> _handConnections = [
  // 拇指
  [0, 1], [1, 2], [2, 3], [3, 4],
  // 食指
  [0, 5], [5, 6], [6, 7], [7, 8],
  // 中指
  [0, 9], [9, 10], [10, 11], [11, 12],
  // 无名指
  [0, 13], [13, 14], [14, 15], [15, 16],
  // 小指
  [0, 17], [17, 18], [18, 19], [19, 20],
  // 手掌横连
  [5, 9], [9, 13], [13, 17],
];

class GestureScreen extends StatefulWidget {
  const GestureScreen({super.key});

  @override
  State<GestureScreen> createState() => _GestureScreenState();
}

class _GestureScreenState extends State<GestureScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── 相机相关 ─────────────────────────────────────────────────
  CameraController? _controller;
  bool _isCameraReady = false;
  bool _isCameraInitialized = false;
  bool _isCameraInitializing = false;
  bool _isDisposed = false;
  String? _errorMessage;

  // ── 通道 ────────────────────────────────────────────────────
  static const _methodChannel = MethodChannel('gesture/frame');
  static const _gestureChannel = EventChannel('gesture/stream');
  static const _landmarkChannel = EventChannel('landmark/stream');
  StreamSubscription? _gestureSubscription;
  StreamSubscription? _landmarkSubscription;

  // ── 帧率节流（发送给原生层）────────────────────────────────
  int _lastFrameTime = 0;
  static const _frameIntervalMs = 30; // 30ms 发一帧给原生层（匹配关键点刷新率）
  bool _isProcessing = false;

  // ── 手势结果 ────────────────────────────────────────────────
  String _gesture = 'None';
  double _confidence = 0.0;
  String _handedness = '';
  int _numHands = 0;

  // ── 关键点数据（多手支持）──────────────────────────────────
  List<List<Offset>> _handsLandmarks = [];

  // ── 动画 ────────────────────────────────────────────────────
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.9, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initCamera();
    _listenGestureStream();
    _listenLandmarkStream();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _stopImageStream();
      controller.dispose();
      _controller = null;
      _isCameraReady = false;
      _isCameraInitialized = false;
      _isCameraInitializing = false;
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _gestureSubscription?.cancel();
    _landmarkSubscription?.cancel();
    _stopImageStream();
    _controller?.dispose();
    _controller = null;
    _pulseController.dispose();
    super.dispose();
  }

  // ── 初始化相机 ──────────────────────────────────────────────
  Future<void> _initCamera() async {
    if (_isDisposed || _isCameraInitialized || _isCameraInitializing) return;
    _isCameraInitializing = true;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _errorMessage = '未发现可用摄像头');
        return;
      }

      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.nv21,
      );

      await _controller!.initialize();
      if (_isDisposed) return;

      _isCameraInitialized = true;
      if (mounted) setState(() => _isCameraReady = true);

      _startImageStream();
    } catch (e) {
      _isCameraInitialized = false;
      if (mounted) setState(() => _errorMessage = '摄像头初始化失败：$e');
    } finally {
      _isCameraInitializing = false;
    }
  }

  // ── 开始帧流 ────────────────────────────────────────────────
  void _startImageStream() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    controller.startImageStream((CameraImage image) {
      if (_isDisposed || _isProcessing) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastFrameTime < _frameIntervalMs) return;
      _lastFrameTime = now;

      _isProcessing = true;
      _sendFrameToNative(image).whenComplete(() {
        _isProcessing = false;
      });
    });
  }

  // ── 停止帧流 ────────────────────────────────────────────────
  void _stopImageStream() {
    try {
      if (_controller?.value.isStreamingImages ?? false) {
        _controller?.stopImageStream();
      }
    } catch (_) {}
  }

  // ── 将相机帧发送给原生层 ───────────────────────────────────
  Future<void> _sendFrameToNative(CameraImage image) async {
    try {
      final bytes = _concatenatePlanes(image.planes);
      final width = image.width;
      final height = image.height;
      final rotation = _controller?.description.sensorOrientation ?? 0;

      await _methodChannel.invokeMethod('processFrame', {
        'bytes': bytes,
        'width': width,
        'height': height,
        'rotation': rotation,
      });
    } catch (e) {
      debugPrint('sendFrame error: $e');
    }
  }

  /// 拼接 CameraImage 所有平面的字节
  Uint8List _concatenatePlanes(List<Plane> planes) {
    int totalLength = 0;
    for (final plane in planes) {
      totalLength += plane.bytes.length;
    }
    final result = Uint8List(totalLength);
    int offset = 0;
    for (final plane in planes) {
      result.setRange(offset, offset + plane.bytes.length, plane.bytes);
      offset += plane.bytes.length;
    }
    return result;
  }

  // ── 监听手势识别结果 ────────────────────────────────────────
  void _listenGestureStream() {
    _gestureSubscription = _gestureChannel.receiveBroadcastStream().listen(
      (event) {
        if (_isDisposed || !mounted) return;
        if (event is Map) {
          setState(() {
            _gesture = (event['gesture'] as String?) ?? 'None';
            _confidence = (event['confidence'] as num?)?.toDouble() ?? 0.0;
            _handedness = (event['handedness'] as String?) ?? '';
            _numHands = (event['numHands'] as int?) ?? 0;
          });
        }
      },
      onError: (error) {
        debugPrint('GestureChannel error: $error');
      },
    );
  }

  // ── 监听关键点数据 ─────────────────────────────────────────
  void _listenLandmarkStream() {
    _landmarkSubscription = _landmarkChannel.receiveBroadcastStream().listen(
      (event) {
        if (_isDisposed || !mounted) return;
        if (event is Map) {
          final hands = event['hands'];
          if (hands is List) {
            final parsed = <List<Offset>>[];
            for (final hand in hands) {
              if (hand is List) {
                final points = <Offset>[];
                for (final pt in hand) {
                  if (pt is Map) {
                    final x = (pt['x'] as num?)?.toDouble() ?? 0.0;
                    final y = (pt['y'] as num?)?.toDouble() ?? 0.0;
                    points.add(Offset(x, y));
                  }
                }
                if (points.isNotEmpty) {
                  parsed.add(points);
                }
              }
            }
            setState(() {
              _handsLandmarks = parsed;
            });
          } else {
            setState(() {
              _handsLandmarks = [];
            });
          }
        }
      },
      onError: (error) {
        debugPrint('LandmarkChannel error: $error');
      },
    );
  }

  // ── UI ──────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return _buildErrorView();
    }
    if (!_isCameraReady || _controller == null) {
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
                    const Color(0xFF6C63FF).withValues(alpha: 0.3),
                    const Color(0xFF6C63FF).withValues(alpha: 0.1),
                  ],
                ),
              ),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Color(0xFF6C63FF),
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
    final colors = _gestureColors[_gesture] ?? _gestureColors['None']!;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: Column(
          children: [
            // ─── 顶部标题栏 ──────────────────────────────────
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
                      gradient: LinearGradient(colors: colors),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.back_hand_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                        SizedBox(width: 6),
                        Text(
                          '手势识别',
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

            // ─── 摄像头预览 + 关键点叠加 ─────────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: colors[0].withValues(alpha: 0.3),
                        width: 2,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: AspectRatio(
                        aspectRatio: 1 / _controller!.value.aspectRatio,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // 摄像头预览
                            CameraPreview(_controller!),
                            // 关键点描点层
                            Positioned.fill(
                              child: CustomPaint(
                                painter: HandLandmarkPainter(
                                  handsLandmarks: _handsLandmarks,
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

            // ─── 手势结果展示 ────────────────────────────────
            _buildResultCard(colors),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// 状态指示灯
  Widget _buildStatusDot() {
    final isActive = _gesture != 'None';
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

  /// 手势结果卡片
  Widget _buildResultCard(List<Color> colors) {
    final emoji = _gestureEmojis[_gesture] ?? '🔍';
    final label = _gestureLabels[_gesture] ?? _gesture;
    final pct = (_confidence * 100).toStringAsFixed(1);
    final isDetected = _gesture != 'None';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colors[0].withValues(alpha: 0.15),
              colors[1].withValues(alpha: 0.05),
            ],
          ),
          border: Border.all(color: colors[0].withValues(alpha: 0.2), width: 1),
        ),
        child: Row(
          children: [
            // Emoji with pulse
            ScaleTransition(
              scale: isDetected
                  ? _pulseAnimation
                  : const AlwaysStoppedAnimation(1.0),
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: colors),
                  boxShadow: [
                    BoxShadow(
                      color: colors[0].withValues(alpha: 0.3),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(emoji, style: const TextStyle(fontSize: 28)),
                ),
              ),
            ),

            const SizedBox(width: 16),

            // 文字信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _gesture,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),

            // 置信度 + 手信息
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: colors[0].withValues(alpha: 0.2),
                  ),
                  child: Text(
                    '$pct%',
                    style: TextStyle(
                      color: colors[0],
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                if (isDetected)
                  Text(
                    '$_handedness · $_numHands hand${_numHands > 1 ? 's' : ''}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// HandLandmarkPainter - 绘制手部 21 个关键点 + 骨架连线
// ═══════════════════════════════════════════════════════════════════
class HandLandmarkPainter extends CustomPainter {
  final List<List<Offset>> handsLandmarks;

  HandLandmarkPainter({required this.handsLandmarks});

  // 每只手一组颜色，方便多手区分
  static const _handColors = [
    [Color(0xFFFF4444), Color(0xFF00FF88)], // 手1: 红点 + 绿线
    [Color(0xFFFFAA00), Color(0xFF00BBFF)], // 手2: 橙点 + 蓝线
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (int h = 0; h < handsLandmarks.length; h++) {
      final landmarks = handsLandmarks[h];
      if (landmarks.length < 21) continue;

      final colorIndex = h % _handColors.length;
      final dotColor = _handColors[colorIndex][0];
      final lineColor = _handColors[colorIndex][1];

      final linePaint = Paint()
        ..color = lineColor
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final dotPaint = Paint()
        ..color = dotColor
        ..style = PaintingStyle.fill;

      final dotGlowPaint = Paint()
        ..color = dotColor.withValues(alpha: 0.3)
        ..style = PaintingStyle.fill;

      // ── 绘制骨架连线 ──────────────────────────────────
      for (final conn in _handConnections) {
        final from = landmarks[conn[0]];
        final to = landmarks[conn[1]];
        // 前置摄像头镜像 x 坐标
        final p1 = Offset((1 - from.dx) * size.width, from.dy * size.height);
        final p2 = Offset((1 - to.dx) * size.width, to.dy * size.height);
        canvas.drawLine(p1, p2, linePaint);
      }

      // ── 绘制 21 个关键点 ──────────────────────────────
      for (final lm in landmarks) {
        final point = Offset((1 - lm.dx) * size.width, lm.dy * size.height);
        // 外层光晕
        canvas.drawCircle(point, 8, dotGlowPaint);
        // 实心圆点
        canvas.drawCircle(point, 5, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant HandLandmarkPainter oldDelegate) => true;
}
