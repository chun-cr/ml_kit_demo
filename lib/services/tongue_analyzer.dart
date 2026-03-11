// 舌象特征提取算法：舌色、舌苔、舌形分析（纯 Dart 实现，不依赖原生）

import 'dart:math' as math;
import 'dart:typed_data';
import '../models/tongue_features.dart';

/// HSV 颜色结构
class _HSV {
  final double h; // 0~360
  final double s; // 0~1
  final double v; // 0~1
  const _HSV(this.h, this.s, this.v);
}

/// 舌象特征提取静态工具类
class TongueAnalyzer {
  TongueAnalyzer._();

  /// 主入口：对抓拍图做特征提取
  /// [rgbaBytes]  RGBA 格式像素数组（每像素 4 字节）
  /// [maskBytes]  8bit 灰度 mask（255 = 舌头，0 = 背景）
  /// [width] / [height] 图像尺寸
  static TongueFeatures analyze({
    required Uint8List rgbaBytes,
    required Uint8List maskBytes,
    required int width,
    required int height,
  }) {
    // ── 舌色分析 ───────────────────────────────────────────────
    final colorResult = _analyzeColor(rgbaBytes, maskBytes, width, height);

    // ── 舌苔分析（取 mask 上半 50% 区域）──────────────────────
    final coating = _analyzeCoating(rgbaBytes, maskBytes, width, height);

    // ── 舌形分析 ────────────────────────────────────────────────
    final shape = _analyzeShape(maskBytes, width, height);

    return TongueFeatures(
      tongueColor:   colorResult.$1,
      avgHue:        colorResult.$2,
      avgSaturation: colorResult.$3,
      avgBrightness: colorResult.$4,
      avgR:          colorResult.$5,
      avgG:          colorResult.$6,
      avgB:          colorResult.$7,
      coating:       coating,
      shape:         shape,
    );
  }

  // ── 颜色分析 ────────────────────────────────────────────────

  static (TongueColor, double, double, double, double, double, double) _analyzeColor(
    Uint8List rgba,
    Uint8List mask,
    int width,
    int height,
  ) {
    double sumR = 0, sumG = 0, sumB = 0;
    int count = 0;
    final pixCount = width * height;

    for (int i = 0; i < pixCount; i++) {
      if (mask[i] < 128) continue;
      final base = i * 4;
      sumR += rgba[base];
      sumG += rgba[base + 1];
      sumB += rgba[base + 2];
      count++;
    }

    if (count == 0) {
      return (TongueColor.paleRed, 0, 0, 0.5, 200, 100, 100);
    }

    final avgR = sumR / count;
    final avgG = sumG / count;
    final avgB = sumB / count;
    final hsv  = _rgbToHsv(avgR, avgG, avgB);

    final color = _classifyColor(hsv, avgR, avgG, avgB);
    return (color, hsv.h, hsv.s, hsv.v, avgR, avgG, avgB);
  }

  static TongueColor _classifyColor(_HSV hsv, double r, double g, double b) {
    // 淡白：饱和度极低
    if (hsv.s < 0.2) return TongueColor.pale;

    // 青紫：明度低
    if (hsv.v < 0.4) return TongueColor.cyanPurple;

    // 紫：蓝分量显著大于红分量
    if (b > r && (b - r) > 20) return TongueColor.purple;

    final isReddish = (hsv.h <= 15 || hsv.h >= 345);

    // 红 / 绛：色调偏红
    if (isReddish) {
      return hsv.v > 0.7 ? TongueColor.red : TongueColor.crimson;
    }

    // 淡红：色调 15~30
    if (hsv.h > 15 && hsv.h <= 30) return TongueColor.paleRed;

    return TongueColor.paleRed;
  }

  // ── 舌苔分析 ────────────────────────────────────────────────

  static CoatingFeatures _analyzeCoating(
    Uint8List rgba,
    Uint8List mask,
    int width,
    int height,
  ) {
    // 只统计 mask 上半 50% 区域
    final halfH = height ~/ 2;
    double sumV = 0;
    int whiteCount = 0, totalCount = 0;
    bool isYellow = false;

    for (int y = 0; y < halfH; y++) {
      for (int x = 0; x < width; x++) {
        final idx = y * width + x;
        if (mask[idx] < 128) continue;
        final base = idx * 4;
        final r = rgba[base].toDouble();
        final g = rgba[base + 1].toDouble();
        final b = rgba[base + 2].toDouble();
        final hsv = _rgbToHsv(r, g, b);

        sumV += hsv.v;
        totalCount++;

        // 白色像素：高明度 + 低饱和度
        if (hsv.v > 0.8 && hsv.s < 0.2) whiteCount++;

        // 黄色像素：色相 30~60
        if (hsv.h >= 30 && hsv.h <= 60) isYellow = true;
      }
    }

    if (totalCount == 0) {
      return const CoatingFeatures(
        color: '白苔', thickness: '薄苔', moisture: '润',
        whiteRatio: 0, avgBrightness: 0.5,
      );
    }

    final avgV = sumV / totalCount;
    final whiteRatio = whiteCount / totalCount;

    final color     = isYellow ? '黄苔' : '白苔';
    final thickness = whiteRatio > 0.4 ? '厚苔' : '薄苔';
    final moisture  = avgV > 0.5 ? '润' : '燥';

    return CoatingFeatures(
      color:         color,
      thickness:     thickness,
      moisture:      moisture,
      whiteRatio:    whiteRatio,
      avgBrightness: avgV,
    );
  }

  // ── 舌形分析 ────────────────────────────────────────────────

  static ShapeFeatures _analyzeShape(Uint8List mask, int width, int height) {
    // 计算外接矩形
    int minX = width, maxX = 0, minY = height, maxY = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if (mask[y * width + x] >= 128) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }

    final mW = (maxX - minX).toDouble().clamp(1.0, double.infinity);
    final mH = (maxY - minY).toDouble().clamp(1.0, double.infinity);
    final aspectRatio = mW / mH;

    final size = aspectRatio > 0.9 ? '胖大' : (aspectRatio < 0.6 ? '瘦' : '正常');

    // Sobel 边缘检测（统计 mask 内边缘像素密度）
    int edgeCount = 0, maskTotal = 0;
    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        final idx = y * width + x;
        if (mask[idx] < 128) continue;
        maskTotal++;

        // Sobel X
        final gx = (-mask[(y - 1) * width + (x - 1)] - 2 * mask[y * width + (x - 1)] - mask[(y + 1) * width + (x - 1)] +
                     mask[(y - 1) * width + (x + 1)] + 2 * mask[y * width + (x + 1)] + mask[(y + 1) * width + (x + 1)]).abs();
        // Sobel Y
        final gy = (-mask[(y - 1) * width + (x - 1)] - 2 * mask[(y - 1) * width + x] - mask[(y - 1) * width + (x + 1)] +
                     mask[(y + 1) * width + (x - 1)] + 2 * mask[(y + 1) * width + x] + mask[(y + 1) * width + (x + 1)]).abs();
        final mag = math.sqrt(gx * gx + gy * gy);
        if (mag > 30) edgeCount++;
      }
    }

    final edgeDensity = maskTotal > 0 ? edgeCount / maskTotal : 0.0;
    final hasCracks = edgeDensity > 0.15;

    // 轮廓采样 y 方向标准差（齿痕）
    final contourY = <double>[];
    for (int y = 0; y < height; y++) {
      // 每行找最右边的 mask 像素
      for (int x = width - 1; x >= 0; x--) {
        if (mask[y * width + x] >= 128) {
          contourY.add(y.toDouble());
          break;
        }
      }
    }
    final stdDev = _stdDev(contourY);
    final hasIndents = stdDev > 5.0;

    return ShapeFeatures(
      size:          size,
      hasCracks:     hasCracks,
      hasIndents:    hasIndents,
      aspectRatio:   aspectRatio,
      edgeDensity:   edgeDensity,
      contourStdDev: stdDev,
    );
  }

  // ── 数学工具 ────────────────────────────────────────────────

  static _HSV _rgbToHsv(double r, double g, double b) {
    final rN = r / 255.0;
    final gN = g / 255.0;
    final bN = b / 255.0;

    final maxC = [rN, gN, bN].reduce(math.max);
    final minC = [rN, gN, bN].reduce(math.min);
    final delta = maxC - minC;

    double h = 0;
    if (delta != 0) {
      if (maxC == rN) {
        h = 60 * (((gN - bN) / delta) % 6);
      } else if (maxC == gN) {
        h = 60 * (((bN - rN) / delta) + 2);
      } else {
        h = 60 * (((rN - gN) / delta) + 4);
      }
      if (h < 0) h += 360;
    }

    final s = maxC == 0 ? 0.0 : delta / maxC;
    return _HSV(h, s, maxC);
  }

  static double _stdDev(List<double> values) {
    if (values.length < 2) return 0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / values.length;
    return math.sqrt(variance);
  }
}
