import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../app_device.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../app_scope.dart';
import '../detail/season_strip.dart';
import '../downloads/download_actions.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../widgets/contained_slider.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/native_glass.dart';
import 'cast_page.dart';
import 'danmaku_overlay.dart';
import '../widgets/follow_button.dart';
import 'episode_grid.dart';
import 'mini_player.dart';
import 'playback_handle.dart';
import 'playback_sheets.dart';
import 'player_lock.dart';
import 'player_status.dart';
import 'fade_presence.dart';
import 'player_surface.dart';
import 'player_video.dart';
import 'swipe_controls.dart';
import 'window_fullscreen.dart';

enum _Panel { episodes, settings, speed, quality, fit }

class LandscapePlayerPage extends StatefulWidget {
  const LandscapePlayerPage({
    super.key,
    required this.store,
    required this.handle,
    this.onFullscreen,
    this.onMiniWindow,
    this.followSensor = true,
  });
  final LocalStore store;
  final PlaybackHandle handle;
  final VoidCallback? onFullscreen;
  final bool followSensor;
  final VoidCallback? onMiniWindow;

  @override
  State<LandscapePlayerPage> createState() => _LandscapePlayerPageState();
}

class _LandscapePlayerPageState extends State<LandscapePlayerPage>
    with WidgetsBindingObserver {
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _selected = <int>{};
  bool _episodesExpanded = false;
  final _links = {
    _Panel.speed: LayerLink(),
    _Panel.quality: LayerLink(),
    _Panel.fit: LayerLink(),
  };
  Player? _bound;
  Timer? _hideTimer;
  Timer? _tapTimer;
  Timer? _streakTimer;
  Timer? _clockTimer;
  Timer? _seekTimer;
  Timer? _hintTimer;
  String _hint = '';
  bool? _full;
  bool _visible = true;
  bool _selecting = false;
  bool _holding = false;
  bool _dragging = false;
  // 横版竖屏态：抖音式竖向翻页。页面只负责视频画面本身，
  // 播控、顶栏、弹幕开关等浮层仍在页面层只有一份。
  late final _pages = PageController(initialPage: _session.index);
  // 用户正在拖 PageView 时不同步翻页（避免外部切集和手势打架）。
  bool _paging = false;
  bool _edgeHinted = false;
  // 黑边手势区上下滑翻页累计的纵向位移（SwipeControls 同款 60px 阈值）。
  double _episodeDragOffset = 0;
  double? _seekValue;
  double? _seekTarget;
  int _streak = 0;
  int _streakTaps = 0;
  _Panel? _panel;
  int _sidePanelMount = 0;
  bool _sidePanelShown = false;
  DateTime _now = DateTime.now();
  ({int level, bool charging})? _battery;

  PlaybackSession get _session => widget.handle.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.onFullscreen == null && widget.followSensor) {
      unawaited(AppDevice.setPlayerOrientation(PlayerOrientation.auto));
    }
    _session.addListener(_bind);
    _bind();
    _scheduleHide();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final full = MediaQuery.orientationOf(context) == Orientation.landscape;
    if (full == _full) return;
    _full = full;
    _panel = null;
    _visible = true;
    _scheduleHide();
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ).catchError((Object _) {}),
    );
    _clockTimer?.cancel();
    _clockTimer = null;
    if (full) {
      _tick();
      _clockTimer = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_bind);
    _pages.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _hideTimer?.cancel();
    _tapTimer?.cancel();
    _streakTimer?.cancel();
    _clockTimer?.cancel();
    _seekTimer?.cancel();
    _hintTimer?.cancel();
    if (_holding) _session.endBoost();
    if (widget.onFullscreen == null) {
      if (_full == true && desktopPlatform) {
        unawaited(setWindowFullScreen(false));
      }
      unawaited(AppDevice.releaseOrientation());
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.edgeToEdge,
        ).catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _session.setForeground(playerVisible(state));

  void _bind() {
    _syncPages();
    final player = _session.player;
    if (identical(player, _bound)) {
      _refresh();
      return;
    }
    _bound = player;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final stream = player.stream;
    _subscriptions.add(
      stream.position.listen((position) {
        final target = _seekTarget;
        if (target != null && (position.inMilliseconds - target).abs() < 1000) {
          _endSeek();
        }
      }),
    );
    _subscriptions.add(
      stream.playing.listen((playing) {
        if (playing) _scheduleHide();
        _refresh();
      }),
    );
    for (final changes in [stream.duration, stream.buffering]) {
      _subscriptions.add(changes.listen((_) => _refresh()));
    }
    _refresh();
  }

  // 外部切集（选集网格点选、自动连播、黑边滑动）后把 PageView 跟到当前集；
  // 用户正在拖 PageView 时不动手，拖完 ScrollEnd 里自己会调 _session.play。
  void _syncPages() {
    if (_paging || !_pages.hasClients) return;
    if (_pages.page?.round() == _session.index) return;
    _pages.jumpToPage(_session.index);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _tick() {
    _now = DateTime.now();
    _refresh();
    unawaited(
      AppDevice.battery().then((battery) {
        if (mounted) setState(() => _battery = battery);
      }),
    );
  }

  void _endSeek() {
    _seekTimer?.cancel();
    _seekTarget = null;
    _seekValue = null;
  }

  bool get _pinned =>
      _session.paused || !_session.ready || _dragging || _panel != null;

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _pinned || !_visible) return;
      setState(() => _visible = false);
    });
  }

  void _show() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    if (_visible && !_pinned) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    } else {
      _show();
    }
  }

  void _say(String text) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    _hintTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _hint = '');
    });
  }

  void _lock() {
    if (_holding) _pressEnd();
    _hideTimer?.cancel();
    _tapTimer?.cancel();
    _streakTimer?.cancel();
    _streak = 0;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _panel = null);
    _session.setLocked(true);
    _say('已锁定，点屏幕显示锁图标');
  }

  void _unlock() {
    unawaited(HapticFeedback.selectionClick());
    _session.setLocked(false);
    _show();
    _say('已解锁');
  }

  void _tapUp(TapUpDetails details, double width, bool full) {
    if (_session.locked) {
      _say('已锁定，点屏幕显示锁图标');
      return;
    }
    final x = details.localPosition.dx;
    final side =
        !full && widget.onFullscreen == null ||
            !_session.store.playbackPreferences.doubleTapSeek
        ? 0
        : x < width / 4
        ? -1
        : x > width * 3 / 4
        ? 1
        : 0;
    if (_streak != 0) {
      if (side == _streak.sign) return _streakTap(side);
      setState(_commitStreak);
    }
    if (_tapTimer?.isActive ?? false) {
      _tapTimer!.cancel();
      if (side == 0) {
        _session.togglePlayback();
      } else {
        _startStreak(side);
      }
      return;
    }
    _tapTimer = Timer(const Duration(milliseconds: 300), _toggleControls);
  }

  void _startStreak(int side) {
    final duration = _session.player.state.duration;
    if (!_session.ready || duration <= Duration.zero) return;
    _streak = side;
    _streakTaps = 0;
    unawaited(HapticFeedback.selectionClick());
    _armStreak();
  }

  void _streakTap(int side) {
    _streakTaps++;
    if (_streakTaps.isEven) {
      _streak += side;
      unawaited(HapticFeedback.selectionClick());
    }
    _armStreak();
  }

  void _armStreak() {
    _streakTimer?.cancel();
    _streakTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(_commitStreak);
    });
    setState(() {});
  }

  void _commitStreak() {
    _streakTimer?.cancel();
    final steps = _streak;
    _streak = 0;
    final state = _session.player.state;
    if (steps == 0 || !_session.ready || state.duration <= Duration.zero) {
      return;
    }
    final target = (state.position.inMilliseconds + steps * 10000).clamp(
      0,
      state.duration.inMilliseconds,
    );
    unawaited(_session.seekTo(Duration(milliseconds: target)));
  }

  void _pressStart() {
    if (!_session.ready || _session.locked) return;
    _session.holdBoost();
    unawaited(HapticFeedback.selectionClick());
    setState(() => _holding = true);
  }

  void _pressEnd() {
    if (!_holding) return;
    _session.endBoost();
    setState(() => _holding = false);
  }

  // 黑边手势区上下滑：和视频区的 PageView 同一套翻页——拖够 60px 就
  // 滑向上一集/下一集，不到就留在原地；到头时提示，不硬翻。
  void _pageDragEnd() {
    const threshold = 60.0;
    final offset = _episodeDragOffset;
    _episodeDragOffset = 0;
    if (!_pages.hasClients) return;
    final target = _session.index +
        (offset < -threshold ? 1 : offset > threshold ? -1 : 0);
    if (target == _session.index) return;
    if (target < 0) return _say('已经是第一集');
    if (target >= _session.detail.episodes.length) {
      return _say('已经是最后一集');
    }
    unawaited(
      _pages.animateToPage(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  // PageView 滚动通知：手指拖动时标 _paging，松手落稳后按落点切集；
  // 超出两端 40px 提示已经是第一集/最后一集。
  bool _scrolled(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _edgeHinted = false;
      setState(() => _paging = true);
    } else if (notification is ScrollUpdateNotification && _paging) {
      if (!_edgeHinted && metrics.pixels < metrics.minScrollExtent - 40) {
        _edgeHinted = true;
        _say('已经是第一集');
      } else if (!_edgeHinted &&
          metrics.pixels > metrics.maxScrollExtent + 40) {
        _edgeHinted = true;
        _say('已经是最后一集');
      }
    } else if (notification is ScrollEndNotification) {
      final page = (metrics.pixels / metrics.viewportDimension).round();
      if (_paging) setState(() => _paging = false);
      if (page != _session.index &&
          page >= 0 &&
          page < _session.detail.episodes.length) {
        unawaited(_session.play(page));
        // 切集时保持清屏状态：已清屏不把控制层弹回来；显示中则重计时。
        if (_visible) _scheduleHide();
      }
    }
    return false;
  }

  // 上下黑边空白区的手势：与视频区一致——点按切换播控显示/隐藏，
  // 上下滑翻页（和视频区的 PageView 同一套翻页，不各搞一套），长按加速。
  // 锁定态不响应。选集展开时不出现（下方是选集网格，手势归它），
  // 底部选集条本身不动。控制条现在是 Column 里的正常子项、落在
  // Expanded 下方，不占黑边手势区，两者不抢触摸。
  Widget _barGestures() {
    final locked = _session.locked;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (locked) {
          _say('已锁定，点屏幕显示锁图标');
          return;
        }
        _toggleControls();
      },
      onVerticalDragStart: locked ? null : (_) => _episodeDragOffset = 0,
      onVerticalDragUpdate: locked
          ? null
          : (details) => _episodeDragOffset += details.delta.dy,
      onVerticalDragEnd: locked ? null : (_) => _pageDragEnd(),
      onVerticalDragCancel: locked ? null : () => _episodeDragOffset = 0,
      onLongPressStart: locked ? null : (_) => _pressStart(),
      onLongPressEnd: locked ? null : (_) => _pressEnd(),
      onLongPressCancel: locked ? null : _pressEnd,
    );
  }

  // 三合一控制块中间的进度行：播控隐藏时也一直显示、实时更新，可拖动；
  // 用 active: true 的 PlaybackProgressBuilder 保证清屏时仍在走进度。
  Widget _bottomProgress() => PlaybackProgressBuilder(
    player: _session.player,
    active: true,
    builder: (context) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SizedBox(height: 20, child: _progressBar(context, thumb: 6)),
    ),
  );

  // 横版竖屏态：抖音式竖向翻页。页面只负责视频画面本身（当前集走
  // session.player，相邻集走预加载的 session.standby，没备好的页
  // 先显示“第X集”），落稳后调 _session.play；播控、弹幕开关等浮层
  // 仍在页面层只有一份，不跟着每页重复建。
  Widget _pagedVideo(BuildContext context) {
    final session = _session;
    return NotificationListener<ScrollNotification>(
      onNotification: _scrolled,
      child: PageView.builder(
        controller: _pages,
        scrollDirection: Axis.vertical,
        physics: session.locked
            ? const NeverScrollableScrollPhysics()
            : const _PagePhysics(),
        itemCount: session.detail.episodes.length,
        itemBuilder: _videoPage,
      ),
    );
  }

  Widget _videoPage(BuildContext context, int index) {
    final session = _session;
    final current = index == session.index;
    final player = current
        ? session.player
        : index == session.standbyIndex
        ? session.standby
        : null;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (player != null)
          // 换集时 300ms 交叉淡化（v1.5.1 那套）：加载中先淡出，
          // 新集首帧到了再淡入，不硬切黑闪。
          AnimatedOpacity(
            opacity: current && session.loading ? 0 : 1,
            duration: Motion.of(context, Motion.long),
            curve: Motion.standard,
            child: AnimatedSwitcher(
              duration: Motion.of(context, Motion.long),
              switchInCurve: Motion.standard,
              switchOutCurve: Motion.standard,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: PlayerVideo(
                key: ValueKey(player),
                handle: widget.handle,
                player: player,
                fit: session.videoFit,
              ),
            ),
          )
        else
          Center(
            child: Text(
              '第 ${session.detail.episodes[index].number} 集',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        if (current)
          DanmakuOverlay(
            controller: session.danmaku,
            video: session.videoSize,
            fit: session.videoFit,
            style: session.danmakuStyle,
          ),
      ],
    );
  }

  void _rotate(bool full) => unawaited(
    desktopPlatform
        ? setWindowFullScreen(!full)
        : AppDevice.setPlayerOrientation(
            full ? PlayerOrientation.portrait : PlayerOrientation.landscape,
          ),
  );

  void _back(bool full) {
    if (_session.locked) {
      _say('已锁定，点屏幕显示锁图标');
      return;
    }
    if (_panel != null) {
      setState(() => _panel = null);
      _scheduleHide();
    } else if (full) {
      _rotate(true);
    } else if (_selecting) {
      _select(false);
    }
  }

  void _openPanel(_Panel panel) {
    _hideTimer?.cancel();
    setState(() => _panel = panel);
  }

  void _closePanel() {
    setState(() => _panel = null);
    _scheduleHide();
  }

  void _select(bool selecting) => setState(() {
    _selecting = selecting;
    _selected.clear();
  });

  void _saveFailed() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('播放偏好未能保存，请重试')));
  }

  Future<void> _change(Future<void> Function() change) async {
    try {
      await change();
    } catch (_) {
      _saveFailed();
    }
  }

  Future<void> _openSettings() {
    _hideTimer?.cancel();
    return showPlayerSheet(
      context,
      (_) => PlaybackSettings(session: _session, onFailure: _saveFailed),
      dark: false,
    ).whenComplete(() {
      if (mounted) _scheduleHide();
    });
  }

  bool get _canDownload =>
      AppScope.of(context).repository.supportsDownloads &&
      widget.store.canDownload;

  void _download() {
    final detail = _session.detail;
    final episodes = [
      for (final index in _selected.toList()..sort()) detail.episodes[index],
    ];
    _select(false);
    unawaited(downloadEpisodes(context, widget.store, detail, episodes));
  }

  @override
  Widget build(BuildContext context) {
    final full = MediaQuery.orientationOf(context) == Orientation.landscape;
    final theme = Theme.of(context);
    final dark = playerTheme(context);
    final video = Theme(
      data: dark,
      child: Builder(builder: (context) => _video(context, full)),
    );
    return PopScope(
      canPop: !full && !_selecting && _panel == null && !_session.locked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back(full);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: full
            ? AppTheme.systemBars(Brightness.dark)
            : AppTheme.systemBars(theme.brightness).copyWith(
                statusBarIconBrightness: Brightness.light,
                statusBarBrightness: Brightness.dark,
              ),
        child: full
            ? Scaffold(backgroundColor: Colors.black, body: video)
            : Scaffold(
                backgroundColor: Colors.black,
                body: Theme(
                  data: dark,
                  child: Builder(
                    builder: (context) {
                      // 横版视频在竖屏里：默认在剩余空间里垂直居中（像红果那样），
                      // 点选集展开时平滑推到最上面，收起时同样平滑移回中间。
                      final expanded = _episodesExpanded || _selecting;
                      final locked = _session.locked;
                      // 控制条显隐跟视频里的浮层同一套：锁定、暂停等都算 pinned。
                      final controlsVisible =
                          !locked && (_visible || _pinned);
                      // 顶栏跟底部控制块同一套显隐：清屏时一起淡出，点按
                      // 唤出时一起回来；选集展开时顶栏仍隐藏。
                      final topVisible = controlsVisible && !expanded;
                      final videoHeight =
                          MediaQuery.sizeOf(context).width * 9 / 16;
                      return Stack(
                        children: [
                          Column(
                            children: [
                              ColoredBox(
                                color: Colors.black,
                                child: SizedBox(
                                  width: double.infinity,
                                  height: MediaQuery.paddingOf(
                                    context,
                                  ).top,
                                ),
                              ),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    // 上下黑边：16:9 视频居中后，剩余空间上下各一半。
                                    final barHeight = expanded
                                        ? 0.0
                                        : math.max(
                                            0.0,
                                            (constraints.maxHeight -
                                                    videoHeight) /
                                                2,
                                          );
                                    return Stack(
                                      children: [
                                        // 黑边手势区（只在选集没展开时）：与视频区同手势；
                                        // 展开时下方是选集网格，手势归它，这里不出现。
                                        if (barHeight > 0) ...[
                                          Positioned(
                                            top: 0,
                                            left: 0,
                                            right: 0,
                                            height: barHeight,
                                            child: _barGestures(),
                                          ),
                                          Positioned(
                                            bottom: 0,
                                            left: 0,
                                            right: 0,
                                            height: barHeight,
                                            child: _barGestures(),
                                          ),
                                        ],
                                        if (expanded)
                                          Positioned(
                                            top: videoHeight,
                                            left: 0,
                                            right: 0,
                                            bottom: 0,
                                            child: _details(context),
                                          ),
                                        AnimatedAlign(
                                          alignment: expanded
                                              ? Alignment.topCenter
                                              : Alignment.center,
                                          duration: Motion.long,
                                          curve: Motion.standard,
                                          child: AspectRatio(
                                            aspectRatio: 16 / 9,
                                            child: video,
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                              // 底部三合一控制块：控制行 + 进度行 + 选集行并进一个
                              // 液态玻璃块，各自行手势互不干扰。清屏时整块淡出
                              //（仍占位，布局不跳）；选集展开时控制行隐藏，进度行
                              // 和选集行留着（选集行是收起开关）；锁定时不响应。
                              // 展开时进度/选集行常驻（不管播控显隐），锁定后也留着
                              // 仅显示进度和当前集。
                              SafeArea(
                                top: false,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    12,
                                  ),
                                  child: IgnorePointer(
                                    ignoring:
                                        locked ||
                                        (!controlsVisible && !expanded),
                                    child: AnimatedOpacity(
                                      opacity:
                                          controlsVisible ||
                                                  expanded ||
                                                  locked
                                              ? 1
                                              : 0,
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      child: Listener(
                                        onPointerDown: (_) => _scheduleHide(),
                                        child: _controlBlock(context),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Positioned(
                            top: MediaQuery.paddingOf(context).top,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(
                              ignoring: !topVisible,
                              child: AnimatedOpacity(
                                opacity: topVisible ? 1 : 0,
                                duration: const Duration(milliseconds: 180),
                                child: Listener(
                                  onPointerDown: (_) => _scheduleHide(),
                                  child: _topBar(context),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
      ),
    );
  }

  Widget _video(BuildContext context, bool full) {
    final session = _session;
    final locked = session.locked;
    final visible = !locked && (_visible || _pinned);
    final sidePanel = switch (_panel) {
      final panel? when full && _sidePanel(panel) => _panelBody(context, panel),
      _ => null,
    };
    if (sidePanel != null && !_sidePanelShown) _sidePanelMount++;
    _sidePanelShown = sidePanel != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (full) ...[
          // 横屏全屏态不动：单画面 300ms 交叉淡化 + 弹幕 + 手势
          //（亮度/音量或按偏好切集）。PiP 走 session.player，不受影响。
          AnimatedSwitcher(
            duration: Motion.of(context, Motion.long),
            switchInCurve: Motion.standard,
            switchOutCurve: Motion.standard,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: PlayerVideo(
              key: ValueKey(session.player),
              handle: widget.handle,
              player: session.player,
              fit: session.videoFit,
            ),
          ),
          DanmakuOverlay(
            controller: session.danmaku,
            video: session.videoSize,
            fit: session.videoFit,
            style: session.danmakuStyle,
          ),
          SwipeControls(
            session: session,
            enabled: full && !locked,
            levels: session.store.playbackPreferences.swipeLevels,
            episodes: session.store.playbackPreferences.swipeEpisodes,
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: locked
                    ? null
                    : (details) =>
                          _tapUp(details, constraints.maxWidth, full),
                onLongPressStart: locked ? null : (_) => _pressStart(),
                onLongPressEnd: locked ? null : (_) => _pressEnd(),
                onLongPressCancel: locked ? null : _pressEnd,
              ),
            ),
          ),
        ] else
          // 横版竖屏态：抖音式竖向翻页。点按/双击/长按仍走同一套
          //（点按切播控、双击快进、长按加速），上下滑交给 PageView，
          // 不再是拖够 60px 才切；选集网格是视频下方的独立区域，
          // 滑它仍是滚动列表，不会走到这里。
          LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: locked
                  ? null
                  : (details) => _tapUp(details, constraints.maxWidth, full),
              onLongPressStart: locked ? null : (_) => _pressStart(),
              onLongPressEnd: locked ? null : (_) => _pressEnd(),
              onLongPressCancel: locked ? null : _pressEnd,
              child: _pagedVideo(context),
            ),
          ),
        FadePresence(
          duration: Motion.medium,
          child: session.ready && session.stalled
              ? const IgnorePointer(
                  child: Center(child: CircularProgressIndicator()),
                )
              : null,
        ),
        FadePresence(
          duration: Motion.medium,
          child: session.loading ? PlaybackLoading(session: session) : null,
        ),
        FadePresence(
          duration: Motion.medium,
          child: switch (session.error) {
            final error? => PlaybackFailure(session: session, error: error),
            null => null,
          },
        ),
        FadePresence(
          scaleFrom: .9,
          child: _streak != 0 ? _streakBadge(full) : null,
        ),
        // 悬浮控制条只在全屏态留在这里；竖屏分支的控制条已挪到视频
        // 下方黑边里（见 build 里竖屏分支 Column 的 _controlBlock）。
        if (full)
          IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Listener(
                onPointerDown: (_) => _scheduleHide(),
                child: _fullControls(context),
              ),
            ),
          ),
        if (full && !visible && session.store.playbackPreferences.progressLine)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 2,
            child: IgnorePointer(child: _thinProgress(context)),
          ),
        Positioned(
          left: 0,
          right: 0,
          top: full ? 24 : 12,
          child: FadePresence(
            child: session.boosting
                ? IgnorePointer(child: Center(child: _boostBadge()))
                : null,
          ),
        ),
        if (session.saveWarning case final warning?)
          Positioned(
            left: 12,
            right: 12,
            bottom: full ? 120 : 64,
            child: _saveWarning(warning),
          ),
        Positioned.fill(
          child: FadePresence(
            child: switch (_panel) {
              final panel? when full => GestureDetector(
                onTap: _closePanel,
                child: ColoredBox(
                  color: _sidePanel(panel)
                      ? const Color(0x4D000000)
                      : Colors.transparent,
                ),
              ),
              _ => null,
            },
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          bottom: 0,
          width: 360,
          child: FadePresence(
            // A fresh key on every show keeps reopen-during-fade from reusing
            // the closing panel's state, matching the old unmount behavior.
            key: ValueKey(_sidePanelMount),
            duration: Motion.long,
            slideFrom: const Offset(1, 0),
            child: sidePanel,
          ),
        ),
        if (_panel case final panel? when full)
          if (!_sidePanel(panel))
            Positioned(
              left: 0,
              top: 0,
              child: CompositedTransformFollower(
                link: _links[panel]!,
                showWhenUnlinked: false,
                targetAnchor: Alignment.topCenter,
                followerAnchor: Alignment.bottomCenter,
                offset: const Offset(0, -6),
                child: _popup(context, panel),
              ),
            ),
        FadePresence(
          duration: Motion.medium,
          child: _hint.isEmpty
              ? null
              : IgnorePointer(
                  child: Align(
                    alignment: const Alignment(0, -.5),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .72),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _hint,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        PlayerLockOverlay(
          locked: locked,
          alignments: [Alignment.centerLeft, Alignment.centerRight],
          padding: EdgeInsets.only(
            left: full
                ? math.max(MediaQuery.viewPaddingOf(context).left, 20)
                : 6,
            right: full
                ? math.max(MediaQuery.viewPaddingOf(context).right, 20)
                : 6,
          ),
          onUnlock: _unlock,
          onBlocked: () => _say('已锁定，点击锁图标解锁'),
        ),
      ],
    );
  }

  bool _sidePanel(_Panel panel) =>
      panel == _Panel.episodes || panel == _Panel.settings;

  // 竖屏分支视频下方的控制条（暂停、时间、弹幕、全屏）：液态玻璃胶囊，
  // 本来压在视频画面上，现挪到视频下方黑边里、进度条上面。
  // 下面是黑底，不再需要压在画面上那层底影。
  // 底部三合一控制块：控制行 + 进度行 + 选集行并进一个液态玻璃块。
  // 三行各自手势互不干扰：按钮照常点、进度条照常拖、选集行照常点开；
  // 选集展开时控制行隐藏，进度行和选集行留着（选集行是收起开关）。
  Widget _controlBlock(BuildContext context) {
    final session = _session;
    final expanded = _episodesExpanded || _selecting;
    return AdaptiveGlass(
      borderRadius: BorderRadius.circular(20),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 控制行：暂停、时间、弹幕、全屏；选集展开时隐藏。
          if (!expanded)
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  _playButton(size: 40, iconSize: 26),
                  const SizedBox(width: 4),
                  _clock(13),
                  const Spacer(),
                  if (session.danmakuSupported) _danmakuButton(context),
                  _icon(
                    Icons.fullscreen_rounded,
                    '全屏',
                    widget.onFullscreen ?? () => _rotate(false),
                    size: 40,
                  ),
                ],
              ),
            ),
          // 进度行：可拖动的进度条；受 progressLine 开关控制。
          // PlaybackProgressBuilder 的 active: true 保证清屏时进度仍在走。
          if (session.store.playbackPreferences.progressLine)
            _bottomProgress(),
          // 选集行：点开展开/收起选集网格。
          _episodeBar(context, session.detail.episodes.length, expanded),
        ],
      ),
    );
  }

  Widget _fullControls(BuildContext context) {
    final session = _session;
    final preferences = session.store.playbackPreferences;
    final padding = MediaQuery.viewPaddingOf(context);
    final left = math.max(padding.left, 20.0);
    final right = math.max(padding.right, 20.0);
    const shadow = [Shadow(color: Color(0x66000000), blurRadius: 2)];
    final ready = session.ready;
    return Stack(
      fit: StackFit.expand,
      children: [
        const IgnorePointer(
          child: Align(
            alignment: Alignment.topCenter,
            child: _Shade(height: 110, top: true),
          ),
        ),
        const IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: _Shade(height: 150, top: false),
          ),
        ),
        if (!desktopPlatform)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(left: left),
              child: PlayerLockButton(locked: false, onPressed: _lock),
            ),
          ),
        Positioned(
          left: left,
          right: right,
          top: 8,
          height: 56,
          child: Row(
            children: [
              _icon(Icons.arrow_back_rounded, '退出全屏', () => _rotate(true)),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.detail.drama.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        shadows: shadow,
                      ),
                    ),
                    Text(
                      session.episode.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .78),
                        fontSize: 12,
                        shadows: shadow,
                      ),
                    ),
                  ],
                ),
              ),
              FollowIcon(
                store: widget.store,
                drama: session.detail.drama,
                color: Colors.white,
                activeColor: Theme.of(context).colorScheme.primaryFixedDim,
                size: 22,
                extent: 44,
              ),
              const SizedBox(width: 8),
              if (preferences.showNetworkSpeed) ...[
                NetworkSpeedText(
                  session: session,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .78),
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 12),
              ],
              if (_battery case final battery?) ...[
                _batteryMark(battery),
                const SizedBox(width: 12),
              ],
              if (preferences.showClock)
                Text(
                  '${_two(_now.hour)}:${_two(_now.minute)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              const SizedBox(width: 4),
              if (session.danmakuSupported) _danmakuButton(context),
              if (widget.onMiniWindow case final onMiniWindow?)
                _icon(Icons.picture_in_picture_alt_rounded, '小窗', onMiniWindow),
              _icon(
                Icons.settings_rounded,
                '播放设置',
                () => _openPanel(_Panel.settings),
              ),
            ],
          ),
        ),
        Positioned(
          left: left + 8,
          right: right + 8,
          bottom: 60,
          height: 28,
          child: _progress(context, thumb: 8),
        ),
        Positioned(
          left: left,
          right: right,
          bottom: 8,
          height: 48,
          child: Row(
            children: [
              _playButton(size: 44, iconSize: 30),
              const SizedBox(width: 4),
              _clock(13),
              const SizedBox(width: 8),
              _icon(
                Icons.skip_previous_rounded,
                '上一集',
                session.hasPrevious
                    ? () => unawaited(session.previous())
                    : null,
                iconSize: 28,
              ),
              _icon(
                Icons.skip_next_rounded,
                '下一集',
                session.hasNext ? () => unawaited(session.next()) : null,
                iconSize: 28,
              ),
              const Spacer(),
              _icon(
                Icons.playlist_play_rounded,
                '选集',
                () => _openPanel(_Panel.episodes),
                iconSize: 28,
              ),
              CompositedTransformTarget(
                link: _links[_Panel.quality]!,
                child: _textButton(
                  session.qualityLabel,
                  '清晰度',
                  ready && !session.local
                      ? () => _openPanel(_Panel.quality)
                      : null,
                ),
              ),
              CompositedTransformTarget(
                link: _links[_Panel.speed]!,
                child: _textButton(
                  '${session.speed}x',
                  '倍速',
                  ready ? () => _openPanel(_Panel.speed) : null,
                  bold: true,
                ),
              ),
              CompositedTransformTarget(
                link: _links[_Panel.fit]!,
                child: _icon(
                  Icons.aspect_ratio_rounded,
                  '画面比例 · ${session.videoFit.label}',
                  () => _openPanel(_Panel.fit),
                  color: session.videoFit == VideoFit.auto
                      ? null
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
              _icon(Icons.fullscreen_exit_rounded, '退出全屏', () => _rotate(true)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _playButton({required double size, required double iconSize}) {
    final playing = !_session.paused;
    return _icon(
      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
      playing ? '暂停' : '播放',
      _session.ready ? _session.togglePlayback : null,
      size: size,
      iconSize: iconSize,
    );
  }

  Widget _clock(double fontSize) => PlaybackProgressBuilder(
    player: _session.player,
    active: _visible || _pinned,
    builder: (context) {
      final state = _session.player.state;
      final position = _seekValue != null
          ? Duration(milliseconds: _seekValue!.round())
          : state.position;
      return Text(
        '${formatClock(position)} / ${formatClock(state.duration)}',
        maxLines: 1,
        style: TextStyle(
          fontSize: fontSize,
          color: Colors.white.withValues(alpha: .86),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    },
  );

  Widget _danmakuButton(BuildContext context) {
    final enabled = _session.danmakuEnabled;
    return _icon(
      enabled ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
      enabled ? '关闭弹幕' : '打开弹幕',
      () => _change(_session.toggleDanmaku),
      color: enabled ? Theme.of(context).colorScheme.primary : null,
      size: 40,
    );
  }

  Widget _icon(
    IconData icon,
    String label,
    VoidCallback? onPressed, {
    double size = 44,
    double iconSize = 24,
    Color? color,
  }) => LiquidGlass(
    borderRadius: BorderRadius.circular(size / 2),
    blur: 14,
    child: IconButton(
      onPressed: onPressed,
      icon: ToggleIconSwitcher(child: Icon(icon, key: ValueKey(icon))),
      iconSize: iconSize,
      tooltip: label,
      color: color ?? Colors.white,
      disabledColor: Colors.white.withValues(alpha: .36),
      style: IconButton.styleFrom(
        fixedSize: Size.square(size),
        padding: EdgeInsets.zero,
      ),
    ),
  );

  Widget _textButton(
    String text,
    String label,
    VoidCallback? onPressed, {
    bool bold = false,
  }) => Semantics(
    label: label,
    button: true,
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        fixedSize: const Size.fromHeight(40),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white.withValues(alpha: .6),
        textStyle: TextStyle(
          fontSize: 14,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      child: Text(text),
    ),
  );

  Widget _progress(BuildContext context, {required double thumb}) =>
      PlaybackProgressBuilder(
        player: _session.player,
        active: _visible || _pinned,
        builder: (context) => _progressBar(context, thumb: thumb),
      );

  Widget _progressBar(BuildContext context, {required double thumb}) {
    final session = _session;
    final state = session.player.state;
    final duration = state.duration;
    final seekable = session.ready && duration > Duration.zero;
    final max = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final position = (_seekValue ?? state.position.inMilliseconds.toDouble())
        .clamp(0.0, max);
    final colors = Theme.of(context).colorScheme;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        padding: EdgeInsets.zero,
        activeTrackColor: colors.primary,
        thumbColor: colors.primary,
        // 未播的背景条透明：只留已播的线、缓冲的淡白线和拇指，
        // 已播/未播靠线本身分得清。
        inactiveTrackColor: Colors.transparent,
        secondaryActiveTrackColor: Colors.white.withValues(alpha: .4),
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumb),
        overlayShape: SliderComponentShape.noOverlay,
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      child: ContainedSlider(
        slider: Slider(
          value: position,
          max: max,
          secondaryTrackValue: state.buffer.inMilliseconds.toDouble().clamp(
            0.0,
            max,
          ),
          semanticFormatterCallback: (value) =>
              formatClock(Duration(milliseconds: value.round())),
          onChangeStart: seekable
              ? (value) {
                  _seekTimer?.cancel();
                  _seekTarget = null;
                  _hideTimer?.cancel();
                  setState(() {
                    _dragging = true;
                    _seekValue = value;
                  });
                }
              : null,
          onChanged: seekable
              ? (value) => setState(() => _seekValue = value)
              : null,
          onChangeEnd: (value) {
            _dragging = false;
            if (seekable) {
              _seekTarget = value;
              _seekTimer?.cancel();
              _seekTimer = Timer(const Duration(seconds: 2), () {
                if (mounted) setState(_endSeek);
              });
              unawaited(session.seekTo(Duration(milliseconds: value.round())));
              setState(() {});
            } else {
              setState(_endSeek);
            }
            _scheduleHide();
          },
        ),
      ),
    );
  }

  Widget _thinProgress(BuildContext context) => PlaybackProgressBuilder(
    player: _session.player,
    builder: (context) {
      final state = _session.player.state;
      final duration = state.duration.inMilliseconds;
      return LinearProgressIndicator(
        value: duration > 0 ? state.position.inMilliseconds / duration : 0,
        minHeight: 2,
        color: Theme.of(context).colorScheme.primary,
        backgroundColor: Colors.transparent,
      );
    },
  );

  Widget _streakBadge(bool full) {
    final forward = _streak > 0;
    return IgnorePointer(
      child: Align(
        alignment: Alignment(forward ? .75 : -.75, 0),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              Icon(
                forward
                    ? Icons.fast_forward_rounded
                    : Icons.fast_rewind_rounded,
                size: 20,
                color: Colors.white,
              ),
              Text(
                '${forward ? '快进' : '快退'} ${_streak.abs() * 10} 秒',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _boostBadge() => Container(
    height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        const Icon(Icons.fast_forward_rounded, size: 16, color: Colors.white),
        Text(
          '${_session.store.playbackPreferences.boostLabel}播放中',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _batteryMark(({int level, bool charging}) battery) {
    const levels = [
      Icons.battery_0_bar_rounded,
      Icons.battery_1_bar_rounded,
      Icons.battery_2_bar_rounded,
      Icons.battery_3_bar_rounded,
      Icons.battery_4_bar_rounded,
      Icons.battery_5_bar_rounded,
      Icons.battery_6_bar_rounded,
      Icons.battery_full_rounded,
    ];
    final level = battery.level.clamp(0, 100);
    return Semantics(
      label: '电量 $level%',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          Icon(
            battery.charging
                ? Icons.battery_charging_full_rounded
                : levels[(level * 7 / 100).round()],
            size: 18,
            color: Colors.white,
          ),
          Text(
            '$level%',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _saveWarning(String warning) => Material(
    color: const Color(0xE6322424),
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              warning,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: _session.saveProgress,
            child: const Text('重试保存'),
          ),
        ],
      ),
    ),
  );

  Widget _panelBody(BuildContext context, _Panel panel) {
    final colors = Theme.of(context).colorScheme;
    final right = MediaQuery.viewPaddingOf(context).right;
    final session = _session;
    final episodes = panel == _Panel.episodes;
    return Material(
      color: colors.surfaceContainerLow.withValues(alpha: .94),
      child: Padding(
        padding: EdgeInsets.only(right: right, top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              children: [
                Text(episodes ? '选集' : '播放设置', style: sheetTitle),
                Expanded(
                  child: Text(
                    episodes ? '共 ${session.detail.episodes.length} 集' : '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _closePanel,
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '关闭',
                ),
              ],
            ),
            Expanded(
              child: episodes
                  ? EpisodeGrid(
                      episodes: session.detail.episodes,
                      current: session.index,
                      selecting: false,
                      selected: const {},
                      touch: true,
                      onSelectionChanged: () {},
                      onPick: (index) {
                        _closePanel();
                        if (index != session.index) {
                          unawaited(session.play(index));
                        }
                      },
                    )
                  : PlaybackSettingsList(
                      session: session,
                      onFailure: _saveFailed,
                      onCast: () {
                        _closePanel();
                        unawaited(startCast(context, session));
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _popup(BuildContext context, _Panel panel) {
    final session = _session;
    return Material(
      color: const Color(0xE0141414),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: switch (panel) {
          _Panel.speed => _options<double>(
            values: playbackSpeeds.reversed.toList(),
            selected: session.speed,
            label: (value) => '${value}x',
            onSelected: (value) => _change(() => session.setSpeed(value)),
          ),
          _Panel.fit => _options<VideoFit>(
            values: VideoFit.values,
            selected: session.videoFit,
            label: (value) => value.label,
            onSelected: (value) => _change(() => session.setVideoFit(value)),
          ),
          _ => _options<int>(
            values: [...session.qualities, 0],
            selected: session.quality,
            label: (value) => value == 0 ? '自动' : '${value}P',
            onSelected: (value) => _change(() => session.setQuality(value)),
          ),
        },
      ),
    );
  }

  Widget _options<T>({
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required void Function(T) onSelected,
  }) {
    final colors = Theme.of(context).colorScheme;
    return IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final value in values)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                _closePanel();
                onSelected(value);
              },
              child: Container(
                height: 36,
                constraints: const BoxConstraints(minWidth: 72),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                child: Text(
                  label(value),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: value == selected
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: value == selected ? colors.primary : Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // 选集展开时视频下方的区域：多季条 + 选集网格（只在展开时挂载）。
  Widget _details(BuildContext context) {
    final session = _session;
    final seasons = session.detail.seasons;
    return Column(
      children: [
        if (seasons.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SeasonStrip(
              seasons: seasons,
              current: session.detail.drama.id,
              store: widget.store,
              metaSize: 13,
              tagSize: 12,
              sectionSize: 15,
              collapsed: false,
              currentStatus: '正在播放',
              onSelected: (season) => unawaited(_playSeason(season)),
            ),
          ),
        Expanded(child: _episodes(context)),
      ],
    );
  }

  // 顶部栏：固定在屏幕顶部左上角，像红果一样留着返回 + 当前集数。
  Widget _topBar(BuildContext context) {
    final session = _session;
    final episodeLabel = session.detail.episodes.isEmpty
        ? ''
        : '第${session.episode.number}集';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            AdaptiveGlassIconButton(
              onPressed: () => unawaited(Navigator.maybePop(context)),
              tooltip: '返回',
              child: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            ),
            const SizedBox(width: 2),
            Text(
              episodeLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (widget.onMiniWindow case final onMiniWindow?)
              AdaptiveGlassIconButton(
                onPressed: onMiniWindow,
                tooltip: '小窗',
                child: const Icon(
                  Icons.picture_in_picture_alt_rounded,
                  color: Colors.white,
                ),
              ),
            AdaptiveGlassIconButton(
              onPressed: _openSettings,
              tooltip: '播放设置',
              child: const Icon(Icons.settings_rounded, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  // 选集行（三合一控制块的最下面一行）：点开展开/收起选集网格。
  // 外层玻璃由 _controlBlock 统一给，这里只留 Material + InkWell
  //（LiquidGlass 里没有 Material，涟漪需要它）；文字是
  // “短剧名 · 全N集 · 第X集”，拿不到剧名回退显示“选集”。
  Widget _episodeBar(BuildContext context, int count, bool expanded) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (_selecting) _select(false);
          setState(() => _episodesExpanded = !expanded);
        },
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_session.detail.drama.title.isNotEmpty ? _session.detail.drama.title : '选集'} · 全$count集 · 第${_session.episode.number}集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_up_rounded,
                  size: 22,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _playSeason(DramaSeason season) async {
    if (_session.switchingSeason) return;
    if (!await _session.playSeason(season) && mounted) {
      _say('${season.label}切换失败，请稍后重试');
    }
  }

  Widget _episodes(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final session = _session;
    final episodes = session.detail.episodes;
    final drama = session.detail.drama;
    final all = _selected.length == episodes.length;
    final status = drama.releaseLabel == '状态未知'
        ? ''
        : '${drama.releaseLabel} · ';
    final header = SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _selecting
                    ? '已选 ${_selected.length} 集'
                    : '$status共 ${episodes.length} 集',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ),
            if (_canDownload && !_selecting)
              IconButton(
                onPressed: () => _select(true),
                icon: const Icon(Icons.download_rounded),
                tooltip: '下载选集',
              ),
          ],
        ),
      ),
    );
    return Column(
      children: [
        Expanded(
          child: EpisodeGrid(
            header: header,
            episodes: episodes,
            current: session.index,
            selecting: _selecting,
            selected: _selected,
            touch: true,
            onSelectionChanged: () => setState(() {}),
            onPick: (index) {
              if (index != session.index) unawaited(session.play(index));
            },
          ),
        ),
        if (_selecting)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => _select(false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    all
                        ? _selected.clear()
                        : _selected.addAll(
                            List.generate(episodes.length, (i) => i),
                          );
                  }),
                  child: Text(all ? '取消全选' : '全选'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _selected.isEmpty ? null : _download,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('下载'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

// 竖向翻页的手感（竖屏页同款）：比默认回弹更硬的弹簧，
// 手指拖动时视频跟着走，松手过半就翻过去、不到弹回来。
class _PagePhysics extends BouncingScrollPhysics {
  const _PagePhysics({super.parent});

  @override
  _PagePhysics applyTo(ScrollPhysics? ancestor) =>
      _PagePhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: .5, stiffness: 400, ratio: 1);
}

class _Shade extends StatelessWidget {
  const _Shade({required this.height, required this.top});
  final double height;
  final bool top;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.topCenter : Alignment.bottomCenter,
          end: top ? Alignment.bottomCenter : Alignment.topCenter,
          colors: const [Color(0x99000000), Color(0x00000000)],
        ),
      ),
    ),
  );
}
