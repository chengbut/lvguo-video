import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'local_store.dart';
import 'picture_in_picture.dart';
import 'ui/player/mini_player.dart';
import 'ui/player/playback_handle.dart';
import 'ui/player/playback_page.dart';

/// 应用根导航键：播放页由详情页推入、画中画恢复时由 [PlaybackHost]
/// 推入，都走同一个根导航。
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// 从小窗回到播放页的平滑转场（用户 2026-11-26 指定）：淡入 +
/// 轻微放大，比默认的侧滑推入更像“小窗长回全屏”。
Route<void> smoothPlaybackRoute(LocalStore store, PlaybackHandle handle) =>
    PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => PlaybackPage(store: store, handle: handle),
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 250),
      transitionsBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: .94, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );

/// 画中画会话保活（用户 2026-11-26 确认的改法）：iOS 画中画开启后
/// 播放页退出回详情页，会话交给这里继续播；画中画停掉且应用在
/// 前台（用户点了小窗的还原）时把播放页推回来；画中画在后台被
/// 关掉则结束会话。同一时刻最多一段播放，和原来的假设一致。
class PlaybackHost extends ChangeNotifier with WidgetsBindingObserver {
  PlaybackHost._() {
    _pip.addListener(_pipChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  static final instance = PlaybackHost._();

  final _pip = PictureInPicture.instance;
  LocalStore? _store;
  PlaybackHandle? _handle;
  StreamSubscription<bool>? _playingSub;
  Timer? _endTimer;
  bool _pipWasActive = false;

  PlaybackHandle? get handle => _handle;

  /// 播放页退出时把会话交进来（仅 iOS 画中画仍在播时）。
  void adopt(LocalStore store, PlaybackHandle handle) {
    if (identical(_handle, handle)) return;
    _release();
    _store = store;
    _handle = handle;
    _pipWasActive = _pip.active;
    handle.session.addListener(_sync);
    _playingSub = handle.session.player.stream.playing.listen(
      (_) => _sync(),
    );
    _pip.onAction = _action;
    _sync();
  }

  /// 播放页（重新）打开时取回会话所有权。不给 [expected] 就取走
  /// 当前保活的那个；给了就只取那一个，不是就原样不动。
  PlaybackHandle? take([PlaybackHandle? expected]) {
    final handle = _handle;
    if (handle == null) return null;
    if (expected != null && !identical(handle, expected)) return null;
    _release();
    return handle;
  }

  /// 彻底结束保活的会话（换了别的剧、画中画在后台被关掉）。
  void endSession() {
    final handle = _handle;
    _release();
    handle?.dispose();
    _pip.clear();
  }

  void _release() {
    _endTimer?.cancel();
    _endTimer = null;
    final handle = _handle;
    if (handle != null) {
      handle.session.removeListener(_sync);
      if (_pip.onAction == _action) _pip.onAction = null;
    }
    unawaited(_playingSub?.cancel());
    _playingSub = null;
    _handle = null;
    _store = null;
  }

  void _action(String action) {
    final session = _handle?.session;
    if (session == null) return;
    switch (action) {
      case 'play':
        if (!session.player.state.playing) session.togglePlayback();
      case 'pause':
        if (session.player.state.playing) session.togglePlayback();
      case 'toggle':
        session.togglePlayback();
      case 'previous':
        unawaited(session.previous());
      case 'next':
        unawaited(session.next());
    }
  }

  // 和 PlaybackPage._sync 同一套画中画信息同步：页面不在了，
  // 播放/暂停状态、集数角标还得继续喂给系统小窗。
  void _sync() {
    final session = _handle?.session;
    final store = _store;
    if (session == null || store == null) return;
    final playing = session.player.state.playing;
    final iosVideo =
        Platform.isIOS &&
        !session.audio &&
        (session.ready && session.aspectKnown || _pip.active);
    _pip.update(
      aspectRatio: session.aspectRatio,
      playing: playing,
      hasPrevious: session.hasPrevious,
      hasNext: session.hasNext,
      iosPlayer: iosVideo ? session.player : null,
      episodeLabel: session.detail.episodes.length > 1
          ? '第${session.episode.number}集'
          : null,
      autoEnter:
          playing &&
          !session.audio &&
          store.playbackPreferences.autoPictureInPicture,
    );
    _pip.resize(session.aspectRatio);
  }

  void _pipChanged() {
    final active = _pip.active;
    if (_pipWasActive && !active) _onPipStopped();
    _pipWasActive = active;
  }

  void _onPipStopped() {
    if (_handle == null) return;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _restorePage();
      return;
    }
    // 后台停的：给 1.2 秒宽限，若是点了还原、应用随即回前台，
    // 就在回前台时恢复播放页；一直没回前台才当作关掉处理。
    _endTimer?.cancel();
    _endTimer = Timer(const Duration(milliseconds: 1200), () {
      if (_handle != null && !_pip.active) endSession();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final session = _handle?.session;
    if (session == null) return;
    session.setForeground(playerVisible(state));
    if (state == AppLifecycleState.resumed &&
        !_pip.active &&
        _endTimer != null) {
      _endTimer?.cancel();
      _endTimer = null;
      _restorePage();
    }
  }

  void _restorePage() {
    final store = _store;
    final handle = _handle;
    if (store == null || handle == null) return;
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    take();
    unawaited(navigator.push(smoothPlaybackRoute(store, handle)));
  }
}
