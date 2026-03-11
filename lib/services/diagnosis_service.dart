// Claude Vision API 调用封装：构建舌诊 prompt 并解析返回的 JSON 结果

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/tongue_features.dart';
import '../models/diagnosis_result.dart';

/// Codex / OpenAI Vision 舌诊诊断服务
class DiagnosisService {
  final String apiKey;

  // 请根据实际 codex 服务节点调整 _apiUrl，常见的形如 https://api.codex.icu/v1/chat/completions 或 https://api.openai.com/v1/chat/completions
  static const _apiUrl = 'https://api.ticketpro.cc';
  static const _model =
      'gpt-5.3-codex'; // 依据实际 codex 提供的模型名称可能需调整，如 gpt-4o 或 gpt-4o-mini

  static const _systemPrompt = '你是一位经验丰富的中医师，请根据舌象图片和检测特征给出中医舌诊参考分析，'
      '语言简洁专业，中文回答，严格按 JSON 格式输出，不要输出 JSON 以外的任何内容。'
      '返回格式为：'
      '{"tongueBody":"舌质描述","tongueCoating":"舌苔描述","pattern":"证型",'
      '"constitution":"体质倾向","suggestions":["建议1","建议2","建议3"],'
      '"disclaimer":"仅供参考，不构成医疗诊断建议"}';

  DiagnosisService(
      {this.apiKey =
          'sk-12f27afbf3f367b8b426944127e677892eb926de6250610394a28ba1b8eac5d6'});

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
          'type': 'text',
          'text':
              '以下是通过图像算法自动提取的舌象特征，请结合图片综合分析：\n$featureText\n请输出 JSON 格式的诊断结果。',
        },
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:image/jpeg;base64,$base64Image',
          },
        },
      ];

      final body = jsonEncode({
        'model': _model,
        'max_tokens': 1024,
        'messages': [
          {'role': 'system', 'content': _systemPrompt},
          {'role': 'user', 'content': userContent},
        ],
      });

      final response = await http
          .post(
            Uri.parse(_apiUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        // 因服务器可能返回 UTF-8，需正确解码
        final decoded =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

        final choices = decoded['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) {
          throw Exception('No choices in response');
        }
        final message = choices[0]['message'] as Map<String, dynamic>;
        final text = message['content'] as String;

        // 提取 JSON 部分（防止模型混入无关文字）
        final jsonStr = _extractJson(text);
        final resultMap = jsonDecode(jsonStr) as Map<String, dynamic>;
        return DiagnosisResult.fromJson(resultMap);
      } else {
        debugPrint(
            '[DiagnosisService] API error ${response.statusCode}: ${response.body}');
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
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return text.substring(start, end + 1);
    }
    return '{}';
  }
}
