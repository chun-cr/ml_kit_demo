// 舌诊特征数据模型：舌色、舌苔、舌形三类特征的数据结构与描述方法

/// 舌色分类
enum TongueColor {
  pale,    // 淡白
  red,     // 红
  crimson, // 绛
  paleRed, // 淡红
  purple,  // 紫
  cyanPurple, // 青紫
}

extension TongueColorLabel on TongueColor {
  String get label {
    switch (this) {
      case TongueColor.pale:       return '淡白';
      case TongueColor.red:        return '红';
      case TongueColor.crimson:    return '绛';
      case TongueColor.paleRed:    return '淡红';
      case TongueColor.purple:     return '紫';
      case TongueColor.cyanPurple: return '青紫';
    }
  }
}

/// 舌苔特征
class CoatingFeatures {
  final String color;      // 白苔 / 黄苔
  final String thickness;  // 厚苔 / 薄苔
  final String moisture;   // 润 / 燥
  final double whiteRatio; // 白色像素占比 0~1
  final double avgBrightness; // 平均明度 0~1

  const CoatingFeatures({
    required this.color,
    required this.thickness,
    required this.moisture,
    required this.whiteRatio,
    required this.avgBrightness,
  });

  Map<String, dynamic> toMap() => {
    'color':         color,
    'thickness':     thickness,
    'moisture':      moisture,
    'whiteRatio':    whiteRatio,
    'avgBrightness': avgBrightness,
  };

  String toText() =>
      '$color$thickness，质地偏$moisture（白色占比 ${(whiteRatio * 100).toStringAsFixed(1)}%）';
}

/// 舌形特征
class ShapeFeatures {
  final String size;      // 胖大 / 瘦 / 正常
  final bool hasCracks;   // 是否有裂纹
  final bool hasIndents;  // 是否有齿痕
  final double aspectRatio;        // 宽高比
  final double edgeDensity;        // 边缘像素密度
  final double contourStdDev;      // 轮廓标准差

  const ShapeFeatures({
    required this.size,
    required this.hasCracks,
    required this.hasIndents,
    required this.aspectRatio,
    required this.edgeDensity,
    required this.contourStdDev,
  });

  Map<String, dynamic> toMap() => {
    'size':          size,
    'hasCracks':     hasCracks,
    'hasIndents':    hasIndents,
    'aspectRatio':   aspectRatio,
    'edgeDensity':   edgeDensity,
    'contourStdDev': contourStdDev,
  };

  String toText() {
    final parts = <String>['舌体$size'];
    if (hasCracks) parts.add('有裂纹');
    if (hasIndents) parts.add('有齿痕');
    return parts.join('，');
  }
}

/// 完整舌诊特征
class TongueFeatures {
  final TongueColor tongueColor;
  final double avgHue;         // 平均色相 0~360
  final double avgSaturation;  // 平均饱和度 0~1
  final double avgBrightness;  // 平均明度 0~1
  final double avgR;           // 平均 R 通道 0~255
  final double avgG;           // 平均 G 通道 0~255
  final double avgB;           // 平均 B 通道 0~255
  final CoatingFeatures coating;
  final ShapeFeatures shape;

  const TongueFeatures({
    required this.tongueColor,
    required this.avgHue,
    required this.avgSaturation,
    required this.avgBrightness,
    required this.avgR,
    required this.avgG,
    required this.avgB,
    required this.coating,
    required this.shape,
  });

  Map<String, dynamic> toMap() => {
    'tongueColor':     tongueColor.label,
    'avgHue':          avgHue,
    'avgSaturation':   avgSaturation,
    'avgBrightness':   avgBrightness,
    'avgR':            avgR,
    'avgG':            avgG,
    'avgB':            avgB,
    'coating':         coating.toMap(),
    'shape':           shape.toMap(),
  };

  /// 生成给 Claude 的文字描述
  String toText() => '''
舌质颜色：${tongueColor.label}（色相 ${avgHue.toStringAsFixed(1)}，饱和度 ${(avgSaturation * 100).toStringAsFixed(1)}%，明度 ${(avgBrightness * 100).toStringAsFixed(1)}%）
舌苔：${coating.toText()}
舌形：${shape.toText()}
''';
}
