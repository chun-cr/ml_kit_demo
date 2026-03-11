// 舌诊结果页面：展示抓拍图、三类特征卡片、Claude 诊断结果及免责声明

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/tongue_features.dart';
import '../models/diagnosis_result.dart';
import '../services/tongue_analyzer.dart';
import '../services/diagnosis_service.dart';

/// 分析进度阶段
enum _AnalysisPhase { segmenting, extracting, diagnosing, done, error }

/// 舌诊结果页
class TongueResultScreen extends StatefulWidget {
  final Uint8List imageBytes;  // 原始 JPEG 抓拍图
  final String claudeApiKey;

  const TongueResultScreen({
    super.key,
    required this.imageBytes,
    required this.claudeApiKey,
  });

  @override
  State<TongueResultScreen> createState() => _TongueResultScreenState();
}

class _TongueResultScreenState extends State<TongueResultScreen> {
  _AnalysisPhase _phase   = _AnalysisPhase.segmenting;
  TongueFeatures? _features;
  DiagnosisResult? _result;
  String? _errorMsg;

  static const _phaseLabels = {
    _AnalysisPhase.segmenting: '正在分割舌头区域...',
    _AnalysisPhase.extracting: '正在提取舌象特征...',
    _AnalysisPhase.diagnosing: '正在进行中医诊断分析...',
    _AnalysisPhase.done:       '分析完成',
    _AnalysisPhase.error:      '分析失败',
  };

  @override
  void initState() {
    super.initState();
    _runAnalysis();
  }

  Future<void> _runAnalysis() async {
    try {
      // 阶段 1：解码图像 + 生成 mask
      _setPhase(_AnalysisPhase.segmenting);
      final decoded = await _decodeJpeg(widget.imageBytes);
      if (decoded == null) throw Exception('图像解码失败');

      final rgba   = decoded.$1;
      final width  = decoded.$2;
      final height = decoded.$3;
      final mask   = _simpleRedMask(rgba, width, height);

      // 阶段 2：特征提取
      _setPhase(_AnalysisPhase.extracting);
      final features = TongueAnalyzer.analyze(
        rgbaBytes: rgba,
        maskBytes: mask,
        width:     width,
        height:    height,
      );
      if (mounted) setState(() => _features = features);

      // 阶段 3：Claude 诊断
      _setPhase(_AnalysisPhase.diagnosing);
      final service = DiagnosisService(apiKey: widget.claudeApiKey);
      final result  = await service.diagnose(widget.imageBytes, features);

      if (mounted) {
        setState(() {
          _result = result;
          _phase  = _AnalysisPhase.done;
        });
      }
    } catch (e) {
      debugPrint('[TongueResult] analysis error: $e');
      if (mounted) setState(() {
        _errorMsg = e.toString();
        _phase    = _AnalysisPhase.error;
      });
    }
  }

  void _setPhase(_AnalysisPhase p) {
    if (mounted) setState(() => _phase = p);
  }

  // ── 图像解码（dart:ui）──────────────────────────────────────

  Future<(Uint8List, int, int)?> _decodeJpeg(Uint8List jpeg) async {
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      final frame = await codec.getNextFrame();
      final img   = frame.image;
      final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;
      return (byteData.buffer.asUint8List(), img.width, img.height);
    } catch (e) {
      debugPrint('[TongueResult] decode error: $e');
      return null;
    }
  }

  /// 基于 HSV 红色范围生成简单 mask（替代 tflite 分割，无额外依赖）
  Uint8List _simpleRedMask(Uint8List rgba, int width, int height) {
    final mask = Uint8List(width * height);
    for (int i = 0; i < width * height; i++) {
      final r = rgba[i * 4].toDouble();
      final g = rgba[i * 4 + 1].toDouble();
      final b = rgba[i * 4 + 2].toDouble();
      final maxC = [r, g, b].reduce((a, x) => a > x ? a : x);
      final minC = [r, g, b].reduce((a, x) => a < x ? a : x);
      final delta = maxC - minC;
      if (maxC == 0) continue;
      final s = delta / maxC;
      final v = maxC / 255.0;
      double h = 0;
      if (delta > 0) {
        if (maxC == r) {
          h = 60 * (((g - b) / delta) % 6);
        } else if (maxC == g) {
          h = 60 * (((b - r) / delta) + 2);
        } else {
          h = 60 * (((r - g) / delta) + 4);
        }
        if (h < 0) h += 360;
      }
      if ((h <= 25 || h >= 335) && s > 0.25 && v > 0.25) {
        mask[i] = 255;
      }
    }
    return mask;
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: _phase != _AnalysisPhase.done
            ? _buildLoading()
            : _buildResult(),
      ),
    );
  }

  Widget _buildLoading() {
    final label = _phaseLabels[_phase] ?? '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_phase == _AnalysisPhase.error) ...[
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
            const SizedBox(height: 16),
            Text(_errorMsg ?? '未知错误',
                style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回重试', style: TextStyle(color: Color(0xFFE8563A))),
            ),
          ] else ...[
            const SizedBox(
              width: 64, height: 64,
              child: CircularProgressIndicator(
                color: Color(0xFFE8563A), strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 24),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 15)),
          ],
        ]),
      ),
    );
  }

  Widget _buildResult() {
    final feat   = _features!;
    final result = _result!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(children: [
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: Colors.white10, borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
              ),
            ),
            const SizedBox(width: 12),
            const Text('舌诊报告',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildImageCard(),
                const SizedBox(height: 16),
                _buildFeatureRow(feat),
                const SizedBox(height: 16),
                _buildDiagnosisCard(result),
                const SizedBox(height: 12),
                _buildDisclaimer(result.disclaimer),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImageCard() {
    return Container(
      width: double.infinity,
      height: 220,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE8563A).withOpacity(0.3), width: 1.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Image.memory(widget.imageBytes, fit: BoxFit.cover),
      ),
    );
  }

  Widget _buildFeatureRow(TongueFeatures feat) {
    return Row(
      children: [
        Expanded(child: _buildFeatureCard(
          title:    '舌质',
          value:    feat.tongueColor.label,
          subValue: 'H${feat.avgHue.toStringAsFixed(0)} S${(feat.avgSaturation * 100).toStringAsFixed(0)}%',
          colors:   [const Color(0xFFE8563A), const Color(0xFFFF8C69)],
        )),
        const SizedBox(width: 10),
        Expanded(child: _buildFeatureCard(
          title:    '舌苔',
          value:    feat.coating.color + feat.coating.thickness,
          subValue: '${feat.coating.moisture}  白占${(feat.coating.whiteRatio * 100).toStringAsFixed(0)}%',
          colors:   [const Color(0xFF6C63FF), const Color(0xFFB49FFF)],
        )),
        const SizedBox(width: 10),
        Expanded(child: _buildFeatureCard(
          title:    '舌形',
          value:    feat.shape.size,
          subValue: [
            if (feat.shape.hasCracks) '裂纹',
            if (feat.shape.hasIndents) '齿痕',
            if (!feat.shape.hasCracks && !feat.shape.hasIndents) '正常',
          ].join(' '),
          colors:   [const Color(0xFF00C9FF), const Color(0xFF92FE9D)],
        )),
      ],
    );
  }

  Widget _buildFeatureCard({
    required String title,
    required String value,
    required String subValue,
    required List<Color> colors,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [colors[0].withOpacity(0.15), colors[1].withOpacity(0.05)],
        ),
        border: Border.all(color: colors[0].withOpacity(0.25), width: 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(color: colors[0], fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(subValue, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11)),
      ]),
    );
  }

  Widget _buildDiagnosisCard(DiagnosisResult r) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [
            const Color(0xFFE8563A).withOpacity(0.12),
            const Color(0xFFFF8C69).withOpacity(0.04),
          ],
        ),
        border: Border.all(color: const Color(0xFFE8563A).withOpacity(0.2), width: 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('中医诊断参考',
            style: TextStyle(color: Color(0xFFE8563A), fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        _infoRow('证型', r.pattern),
        _infoRow('体质倾向', r.constitution),
        _infoRow('舌质', r.tongueBody),
        _infoRow('舌苔', r.tongueCoating),
        if (r.suggestions.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('调养建议',
              style: TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...r.suggestions.asMap().entries.map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${e.key + 1}.', style: const TextStyle(color: Color(0xFFE8563A), fontSize: 13)),
              const SizedBox(width: 6),
              Expanded(child: Text(e.value, style: const TextStyle(color: Colors.white, fontSize: 13))),
            ]),
          )),
        ],
      ]),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 64,
        child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
      ),
      Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13))),
    ]),
  );

  Widget _buildDisclaimer(String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.04),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white12, width: 1),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white38, fontSize: 11, height: 1.5),
      textAlign: TextAlign.center,
    ),
  );
}
