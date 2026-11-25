import 'models.dart';

enum PlaybackRecoveryAction { alternative, refresh, stop }

class PlaybackRecovery {
  // 自动恢复预算：取流不稳定时多试几次再报错（原来 3 次、只刷新 1 次）。
  static const maxAttempts = 6;
  static const maxRefreshes = 3;
  int _attempts = 0;
  int _refreshes = 0;

  void reset() {
    _attempts = 0;
    _refreshes = 0;
  }

  bool get canRetry => _attempts < maxAttempts;

  /// 还没装好播放计划时（取流失败）：只允许重新取地址，计一次。
  /// 次数用完返回 false，调用方直接弹错。
  bool tryRefresh() {
    if (_attempts >= maxAttempts || _refreshes >= maxRefreshes) return false;
    _attempts++;
    _refreshes++;
    return true;
  }

  PlaybackRecoveryAction next(PlaybackPlan plan) {
    if (_attempts >= maxAttempts) {
      return PlaybackRecoveryAction.stop;
    }
    // 403 这类错是地址本身被拒：换线路还是同一个签名、同一个地址，
    // 换哪个节点都照样 403；先重新取一个新地址，再考虑换线路。
    if (_refreshes < maxRefreshes) {
      _attempts++;
      _refreshes++;
      return PlaybackRecoveryAction.refresh;
    }
    if (plan.hasAlternative) {
      _attempts++;
      return PlaybackRecoveryAction.alternative;
    }
    return PlaybackRecoveryAction.stop;
  }
}

class PlaybackHealth {
  static const stallTimeout = Duration(seconds: 20);
  Duration? _position;
  DateTime? _lastProgress;

  void reset() {
    _position = null;
    _lastProgress = null;
  }

  bool stalled({
    required Duration position,
    required bool playing,
    required bool foreground,
    required DateTime now,
  }) {
    if (!playing || !foreground || position != _position) {
      _position = position;
      _lastProgress = now;
      return false;
    }
    _lastProgress ??= now;
    return now.difference(_lastProgress!) >= stallTimeout;
  }
}
