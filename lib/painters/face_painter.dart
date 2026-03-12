import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

/// 嘴巴内部区域点集 —— 两个端点都在此集合中的连线将被跳过
const Set<int> _mouthInteriorPoints = {
  13,
  14,
  17,
  37,
  39,
  40,
  61,
  78,
  80,
  81,
  82,
  84,
  87,
  88,
  91,
  95,
  146,
  178,
  181,
  185,
  191,
  267,
  269,
  270,
  291,
  308,
  310,
  311,
  312,
  314,
  317,
  318,
  321,
  324,
  375,
  402,
  405,
  409,
  415,
};

/// 外唇轮廓点序列（首尾闭合）
const List<int> _outerLipContour = [
  61,
  185,
  40,
  39,
  37,
  0,
  267,
  269,
  270,
  409,
  291,
  375,
  321,
  405,
  314,
  17,
  84,
  181,
  91,
  146,
  61,
];

/// 内唇轮廓点序列（首尾闭合）
const List<int> _innerLipContour = [
  78,
  191,
  80,
  81,
  82,
  13,
  312,
  311,
  310,
  415,
  308,
  324,
  318,
  402,
  317,
  14,
  87,
  178,
  88,
  95,
  78,
];

/// CustomPainter that draws face bounding boxes, face mesh triangles, and
/// 468 face mesh landmark points on top of the camera preview.
///
/// 坐标变换说明：
///   ML Kit 返回的是基于传感器原始坐标系的坐标。
///   imageSize 已经过旋转补偿（宽高已对调），与预览画面方向一致。
///   前置摄像头预览是镜像的，所以 x 坐标需要额外翻转。
class FacePainter extends CustomPainter {
  final List<Face> faces;
  final List<FaceMesh> meshes;
  // iOS MediaPipe FaceLandmarker 结果：每张脸的归一化坐标点列表 (0~1)
  final List<List<Offset>> iosFaceLandmarks;
  final Size imageSize;
  final CameraLensDirection cameraLensDirection;
  final int sensorOrientation;

  FacePainter({
    required this.faces,
    required this.meshes,
    required this.iosFaceLandmarks,
    required this.imageSize,
    required this.cameraLensDirection,
    required this.sensorOrientation,
    this.isIos = false,
  });

  /// iOS 标志位：坐标系与 Android 不同，需要单独处理
  final bool isIos;

  // ── 坐标变换 ──────────────────────────────────────────────────

  /// 将 ML Kit 坐标映射到屏幕坐标
  ///
  /// Android 路径：
  ///   imageSize 已经对调宽高，x→screenWidth，y→screenHeight，前置摄像头镜像 x
  ///
  /// iOS 路径：
  ///   imageSize 是原始传感器尺寸（portrait: width=短边≈480, height=长边≈640）
  ///   sensorOrientation=90 → 图像需旋转90°：原始 x 对应屏幕 y，原始 y 对应屏幕 x
  ///   前置摄像头：CameraPreview 不自动镜像，ML Kit iOS 也不自动镜像 bbox，
  ///   需要沿 x 轴翻转（screenW - screenX）
  Offset _toScreenOffsetIos(double x, double y, Size screenSize) {
    // 传感器坐标 (x, y)，其中 x ∈ [0, imageSize.width], y ∈ [0, imageSize.height]
    // sensorOrientation=90：旋转90° CW → 原始 x 轴变成屏幕 y 轴，原始 y 轴变成屏幕 x 轴
    final screenX = (y / imageSize.height) * screenSize.width;
    final screenY = (x / imageSize.width)  * screenSize.height;
    // 前置摄像头镜像（CameraPreview 在 iOS 不自动镜像前置画面）
    final mirroredX = screenSize.width - screenX;
    return Offset(mirroredX, screenY);
  }

  double _translateX(double x, Size screenSize) {
    if (cameraLensDirection == CameraLensDirection.front) {
      return screenSize.width - (x / imageSize.width) * screenSize.width;
    } else {
      return (x / imageSize.width) * screenSize.width;
    }
  }

  double _translateY(double y, Size screenSize) {
    return (y / imageSize.height) * screenSize.height;
  }

  Offset _toScreenOffset(double x, double y, Size screenSize) {
    return Offset(_translateX(x, screenSize), _translateY(y, screenSize));
  }

  // ── 绘制入口 ──────────────────────────────────────────────────

  @override
  void paint(Canvas canvas, Size size) {
    _drawFaceBoundingBoxes(canvas, size);
    // Android: ML Kit FaceMesh 三角网格 + 点
    _drawFaceMeshTriangles(canvas, size);
    _drawFaceMeshPoints(canvas, size);
    _drawLips(canvas, size);
    // iOS: MediaPipe FaceLandmarker 归一化点
    _drawIosFaceLandmarks(canvas, size);
  }

  // ---------------------------------------------------------------------------
  // Face bounding boxes
  // ---------------------------------------------------------------------------

  void _drawFaceBoundingBoxes(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xFF00FF88);

    for (final face in faces) {
      final rect = face.boundingBox;

      final Rect screenRect;
      if (isIos) {
        // iOS: 与 _drawIosFaceLandmarks 使用同一坐标系，仅做镜像缩放，不做旋转轴交换
        final left = (1.0 - rect.right / imageSize.width) * size.width;
        final right = (1.0 - rect.left / imageSize.width) * size.width;
        final top = (rect.top / imageSize.height) * size.height;
        final bottom = (rect.bottom / imageSize.height) * size.height;
        screenRect = Rect.fromLTRB(left, top, right, bottom);
      } else {
        // Android: 直接用 _toScreenOffset（imageSize 已对调宽高）
        final topLeft     = _toScreenOffset(rect.left.toDouble(),  rect.top.toDouble(),    size);
        final bottomRight = _toScreenOffset(rect.right.toDouble(), rect.bottom.toDouble(), size);
        screenRect = Rect.fromLTRB(
          topLeft.dx < bottomRight.dx ? topLeft.dx : bottomRight.dx,
          topLeft.dy < bottomRight.dy ? topLeft.dy : bottomRight.dy,
          topLeft.dx < bottomRight.dx ? bottomRight.dx : topLeft.dx,
          topLeft.dy < bottomRight.dy ? bottomRight.dy : topLeft.dy,
        );
      }

      canvas.drawRRect(
        RRect.fromRectAndRadius(screenRect, const Radius.circular(8)),
        boxPaint,
      );

      _drawCornerAccents(canvas, screenRect);
      _drawFaceLabels(canvas, face, screenRect);
    }
  }

  void _drawCornerAccents(Canvas canvas, Rect rect) {
    const len = 14.0;
    final accentPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..color = const Color(0xFF00FF88)
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      rect.topLeft,
      rect.topLeft + const Offset(len, 0),
      accentPaint,
    );
    canvas.drawLine(
      rect.topLeft,
      rect.topLeft + const Offset(0, len),
      accentPaint,
    );
    canvas.drawLine(
      rect.topRight,
      rect.topRight + const Offset(-len, 0),
      accentPaint,
    );
    canvas.drawLine(
      rect.topRight,
      rect.topRight + const Offset(0, len),
      accentPaint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft + const Offset(len, 0),
      accentPaint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft + const Offset(0, -len),
      accentPaint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight + const Offset(-len, 0),
      accentPaint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight + const Offset(0, -len),
      accentPaint,
    );
  }

  void _drawFaceLabels(Canvas canvas, Face face, Rect rect) {
    final labels = <String>[];

    final smile = face.smilingProbability;
    if (smile != null) {
      labels.add('😊 ${(smile * 100).toStringAsFixed(0)}%');
    }

    final leftEye = face.leftEyeOpenProbability;
    final rightEye = face.rightEyeOpenProbability;
    if (leftEye != null && rightEye != null) {
      final avgEye = ((leftEye + rightEye) / 2 * 100).toStringAsFixed(0);
      labels.add('👁 $avgEye%');
    }

    if (labels.isEmpty) return;

    final text = labels.join('  ');
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xFF00FF88),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    tp.paint(canvas, Offset(rect.left, rect.top - 22));
  }

  // ---------------------------------------------------------------------------
  // Face mesh triangles — 跳过嘴巴内部连线
  // ---------------------------------------------------------------------------

  void _drawFaceMeshTriangles(Canvas canvas, Size size) {
    if (meshes.isEmpty) return;

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.4
      ..color = const Color(0x5500CCFF);

    for (final mesh in meshes) {
      for (final triangle in mesh.triangles) {
        final pts = triangle.points;
        if (pts.length != 3) continue;

        // 逐边绘制，跳过嘴巴内部连线
        for (int i = 0; i < 3; i++) {
          final from = pts[i];
          final to = pts[(i + 1) % 3];

          // 两个端点都在嘴巴内部区域 → 跳过
          if (_mouthInteriorPoints.contains(from.index) &&
              _mouthInteriorPoints.contains(to.index)) {
            continue;
          }

          final p1 = _toScreenOffset(
            from.x.toDouble(),
            from.y.toDouble(),
            size,
          );
          final p2 = _toScreenOffset(to.x.toDouble(), to.y.toDouble(), size);
          canvas.drawLine(p1, p2, linePaint);
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Face mesh 468 landmark points
  // ---------------------------------------------------------------------------

  void _drawFaceMeshPoints(Canvas canvas, Size size) {
    if (meshes.isEmpty) return;

    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xCC00CCFF);

    for (final mesh in meshes) {
      for (final point in mesh.points) {
        final offset = _toScreenOffset(
          point.x.toDouble(),
          point.y.toDouble(),
          size,
        );
        canvas.drawCircle(offset, 1.2, dotPaint);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 嘴唇轮廓 — 外唇 + 内唇独立描边
  // ---------------------------------------------------------------------------

  void _drawLips(Canvas canvas, Size size) {
    if (meshes.isEmpty) return;

    final lipPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = const Color(0xCC00CCFF)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (final mesh in meshes) {
      final points = mesh.points;
      if (points.isEmpty) continue;

      // 构建 index → FaceMeshPoint 查找表
      final Map<int, FaceMeshPoint> pointMap = {};
      for (final pt in points) {
        pointMap[pt.index] = pt;
      }

      // 绘制外唇轮廓
      _drawLipContour(canvas, size, pointMap, _outerLipContour, lipPaint);

      // 绘制内唇轮廓
      _drawLipContour(canvas, size, pointMap, _innerLipContour, lipPaint);
    }
  }

  void _drawLipContour(
    Canvas canvas,
    Size size,
    Map<int, FaceMeshPoint> pointMap,
    List<int> contourIndices,
    Paint paint,
  ) {
    if (contourIndices.length < 2) return;

    final path = Path();
    bool started = false;

    for (final idx in contourIndices) {
      final pt = pointMap[idx];
      if (pt == null) continue;

      final offset = _toScreenOffset(pt.x.toDouble(), pt.y.toDouble(), size);

      if (!started) {
        path.moveTo(offset.dx, offset.dy);
        started = true;
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }

    if (started) {
      canvas.drawPath(path, paint);
    }
  }

  // ---------------------------------------------------------------------------
  // iOS: MediaPipe FaceLandmarker 归一化点绘制
  // 坐标已经是 0~1 归一化，前置摄像头需要镜像 x
  // ---------------------------------------------------------------------------

  void _drawIosFaceLandmarks(Canvas canvas, Size size) {
    if (iosFaceLandmarks.isEmpty) return;

    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xCC00CCFF);

    for (final landmarks in iosFaceLandmarks) {
      if (landmarks.isEmpty) continue;
      for (final lm in landmarks) {
        final x = (1.0 - lm.dx) * size.width;
        final y = lm.dy * size.height;
        canvas.drawCircle(Offset(x, y), 1.2, dotPaint);
      }
      _drawIosLipContour(canvas, size, landmarks);
    }
  }

  void _drawIosLipContour(Canvas canvas, Size size, List<Offset> lm) {
    if (lm.length < 409) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = const Color(0xCC00CCFF)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Offset toScreen(int idx) {
      final pt = lm[idx];
      return Offset((1.0 - pt.dx) * size.width, pt.dy * size.height);
    }

    void drawContour(List<int> indices) {
      if (indices.length < 2) return;
      final path = Path();
      path.moveTo(toScreen(indices[0]).dx, toScreen(indices[0]).dy);
      for (int i = 1; i < indices.length; i++) {
        final p = toScreen(indices[i]);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }

    drawContour(_outerLipContour);
    drawContour(_innerLipContour);
  }

  @override
  bool shouldRepaint(FacePainter oldDelegate) => true;
}
