// Claude API 返回的舌诊诊断结果数据模型

/// Claude 舌诊诊断结果
class DiagnosisResult {
  final String tongueBody;   // 舌质描述
  final String tongueCoating; // 舌苔描述
  final String pattern;      // 证型（如气虚、阴虚、湿热）
  final String constitution; // 体质倾向
  final List<String> suggestions; // 建议列表
  final String disclaimer;   // 免责声明

  const DiagnosisResult({
    required this.tongueBody,
    required this.tongueCoating,
    required this.pattern,
    required this.constitution,
    required this.suggestions,
    required this.disclaimer,
  });

  factory DiagnosisResult.fromJson(Map<String, dynamic> json) {
    return DiagnosisResult(
      tongueBody:    (json['tongueBody']    as String?) ?? '',
      tongueCoating: (json['tongueCoating'] as String?) ?? '',
      pattern:       (json['pattern']       as String?) ?? '',
      constitution:  (json['constitution']  as String?) ?? '',
      suggestions:   (json['suggestions'] is List)
          ? List<String>.from((json['suggestions'] as List).map((e) => e.toString()))
          : [],
      disclaimer:    (json['disclaimer']   as String?) ?? '仅供参考，不构成医疗诊断建议',
    );
  }

  /// 返回空结果（解析失败时使用）
  factory DiagnosisResult.empty() => const DiagnosisResult(
    tongueBody:    '未能解析',
    tongueCoating: '未能解析',
    pattern:       '未能解析',
    constitution:  '未能解析',
    suggestions:   [],
    disclaimer:    '仅供参考，不构成医疗诊断建议',
  );

  Map<String, dynamic> toJson() => {
    'tongueBody':    tongueBody,
    'tongueCoating': tongueCoating,
    'pattern':       pattern,
    'constitution':  constitution,
    'suggestions':   suggestions,
    'disclaimer':    disclaimer,
  };
}
