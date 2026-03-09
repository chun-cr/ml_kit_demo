/// 自适应节流器
///
/// 监测每帧实际处理耗时，动态调整下一帧等待间隔。
/// - 高端机处理快 → 间隔短 → 帧率高
/// - 低端机处理慢 → 间隔长 → 帧率低
class AdaptiveThrottle {
  /// 创建自适应节流器。
  ///
  /// [minInterval] 最小帧间隔（ms），默认 33（约 30fps）
  /// [maxInterval] 最大帧间隔（ms），默认 200（约 5fps）
  /// [targetProcessTime] 目标每帧处理时间（ms），默认 50
  /// [adaptive] 是否启用自适应调整，设为 false 时仅做固定间隔节流
  AdaptiveThrottle({
    int minInterval = _defaultMinInterval,
    int maxInterval = _defaultMaxInterval,
    int targetProcessTime = _defaultTargetProcessTime,
    bool adaptive = true,
  }) : _minInterval = minInterval,
       _maxInterval = maxInterval,
       _targetProcessTime = targetProcessTime,
       _adaptive = adaptive,
       _currentInterval = (minInterval + maxInterval) ~/ 2;

  // ── 默认常量 ──────────────────────────────────────────────────
  static const int _defaultMinInterval = 33; // 最快 ~30fps
  static const int _defaultMaxInterval = 200; // 最慢 ~5fps
  static const int _defaultTargetProcessTime = 50; // 目标 50ms/帧

  // ── 配置 ──────────────────────────────────────────────────────
  final int _minInterval;
  final int _maxInterval;
  final int _targetProcessTime;
  final bool _adaptive;

  // ── 状态 ──────────────────────────────────────────────────────
  int _currentInterval;
  int _lastFrameTime = 0;
  bool _isProcessing = false;

  // ── 耗时采样（滑动窗口取平均）─────────────────────────────────
  final List<int> _processTimes = [];
  static const int _sampleSize = 5;

  // ── 公开接口 ──────────────────────────────────────────────────

  /// 判断当前是否应处理新一帧。
  /// 调用后会自动更新 [_lastFrameTime]。
  bool shouldProcess() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_isProcessing) return false;
    if (now - _lastFrameTime < _currentInterval) return false;
    _lastFrameTime = now;
    return true;
  }

  /// 记录一帧实际处理耗时（毫秒），触发自适应调整。
  void recordProcessTime(int milliseconds) {
    _processTimes.add(milliseconds);
    if (_processTimes.length > _sampleSize) {
      _processTimes.removeAt(0);
    }
    if (_adaptive) {
      _adjustInterval();
    }
  }

  /// 设置当前是否正在处理中，防止重入。
  void setProcessing(bool value) => _isProcessing = value;

  /// 当前帧间隔（毫秒），可用于调试显示。
  int get currentInterval => _currentInterval;

  // ── 内部：自适应调整 ──────────────────────────────────────────

  void _adjustInterval() {
    if (_processTimes.length < _sampleSize) return;

    final avgTime =
        _processTimes.reduce((a, b) => a + b) ~/ _processTimes.length;

    if (avgTime > _targetProcessTime * 1.5) {
      // 处理太慢 → 增大间隔 → 降低帧率
      _currentInterval = (_currentInterval * 1.2).toInt().clamp(
        _minInterval,
        _maxInterval,
      );
    } else if (avgTime < _targetProcessTime * 0.8) {
      // 处理很快 → 缩短间隔 → 提高帧率
      _currentInterval = (_currentInterval * 0.9).toInt().clamp(
        _minInterval,
        _maxInterval,
      );
    }
  }
}
