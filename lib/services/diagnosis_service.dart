// Claude Vision API 调用封装：构建舌诊 prompt 并解析返回的 JSON 结果

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/tongue_features.dart';
import '../models/diagnosis_result.dart';

/// Claude Vision 舌诊诊断服务
class DiagnosisService {
  final String apiKey;

  static const _apiUrl = 'https://api.anthropic.com/v1/messages';
  static const _model  = 'claude-opus-4-5';

  static const _systemPrompt =
      '你是一位经验丰富的中医师，请根据舌象图片和检测特征给出中医舌诊参考分析，'
      '语言简洁专业，中文回答，严格按 JSON 格式输出，不要输出 JSON 以外的任何内容。'
      '返回格式为：'
      '{"tongueBody":"舌质描述","tongueCoating":"舌苔描述","pattern":"证型",'
      '"constitution":"体质倾向","suggestions":["建议1","建议2","建议3"],'
      '"disclaimer":"仅供参考，不构成医疗诊断建议"}';

  DiagnosisService({required this.apiKey});

  /// 对舌头图像和提取到的特征调用 Claude 进行诊断
  /// [jpegBytes] 抓拍的 JPEG 图像
  /// [features]  已提取的特征
  Future<DiagnosisResult> diagnose(
    Uint8List jpegBytes,
    TongueFeatures features,
  ) async {
    try {
      final base64Image = base64Encode(jpegBytes);
      final featureText = features.toText();

      final userContent = [
        {
          'type': 'image',
          'source': {
            'type':       'base64',
            'media_type': 'image/jpeg',
            'data':       base64Image,
          },
        },
        {
          'type': 'text',
          'text': '以下是通过图像算法自动提取的舌象特征，请结合图片综合分析：\n$featureText\n请输出 JSON 格式的诊断结果。',
        },
      ];

      final body = jsonEncode({
        'model':      _model,
        'max_tokens': 1024,
        'system':     _systemPrompt,
        'messages': [
          {'role': 'user', 'content': userContent},
        ],
      });

      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type':      'application/json',
          'x-api-key':         apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: body,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final content = decoded['content'] as List<dynamic>;
        final text = (content.firstWhere(
          (c) => c['type'] == 'text',
          orElse: () => {'text': '{}'},
        )['text'] as String);

        // 提取 JSON 部分（防止模型混入无关文字）
        final jsonStr = _extractJson(text);
        final resultMap = jsonDecode(jsonStr) as Map<String, dynamic>;
        return DiagnosisResult.fromJson(resultMap);
      } else {
        debugPrint('[DiagnosisService] API error ${response.statusCode}: ${response.body}');
        return DiagnosisResult.empty();
      }
    } catch (e) {
      debugPrint('[DiagnosisService] diagnose error: $e');
      return DiagnosisResult.empty();
    }
  }

  /// 从文本中提取第一个 JSON 对象
  String _extractJson(String text) {
    final start = text.indexOf('{');
    final end   = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return text.substring(start, end + 1);
    }
    return '{}';
  }
}
