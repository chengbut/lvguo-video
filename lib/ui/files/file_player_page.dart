import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../app_device.dart';
import '../../file_sources.dart';
import '../../picture_in_picture.dart';
import '../../playback_preferences.dart' show playbackSpeeds;
import '../player/fade_presence.dart';
import '../player/playback_sheets.dart';
import '../widgets/liquid_glass.dart';

/// 长按加速的倍速：和剧集播放的默认 boostSpeed 一致（2.0）。
const _boostRate = 2.0;

/// 文件源专用播放页：用和剧集播放同一个引擎（media_kit/mpv）直接
/// 打开 URL 播放。剧集播放页只认站源解析出的播放计划、没有裸 URL
/// 入口，所以文件源单独一页，但功能尽量与主播放器看齐：横屏全屏、
/// 左亮度/右音量滑动、横滑拖进度、倍速（点选 + 长按加速）、播放
/// 设置（画面调节/截图/音轨/字幕/字幕延迟/A-B 循环）、同文件夹
/// 上/下一、画中画。进度按条目键存 FileSourceStore 续播。
class FilePlayerPage extends StatefulWidget {
  const FilePlayerPage({
    super.key,
    required this.playlist,
    required this.index,
    required this.files,
    required this.sourceName,
    required this.sourceId,
  });

  /// 同文件夹的全部视频（上/下一在里面切换）。
  final List<FilePlayItem> playlist;
  final int index;
  final FileSourceStore files;
  final String sourceName;
  final String sourceId;

  @override
  State<FilePlayerPage> createState() => _FilePlayerPageState();
}

class _FilePlayerPageState extends State<FilePlayerPage> {
  final _player = Player(
    configuration: const PlayerConfiguration(
      bufferSize: 64 * 1024 * 1024,
      logLevel: MPVLogLevel.error,
    ),
  );
  late final _controller = VideoController(_player);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _pip = PictureInPicture.instance;
  late final bool _pipActiveAtEntry = _pip.active;
  Timer? _saveTimer;
  Timer? _hideTimer;
  late int _index = widget.index.clamp(0, widget.playlist.length - 1);
  bool _controls = true;
  bool _playing = false;
  bool _buffering = true;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;
  String _currentUrl = '';
  double _rate = 1.0;
  bool _boosting = false;
  double _rateBeforeBoost = 1.0;
  Tracks? _tracks;
  String? _audioTrackId;
  String? _subtitleTrackId;
  double _brightness = 0;
  double _contrast = 0;
  double _saturation = 0;
  double _subtitleDelay = 0;
  Duration? _loopA;
  Duration? _loopB;
  // 手势状态：横滑拖进度、竖滑调亮度/音量（与主播放器同一套算法）。
  int? _seekFrom;
  double _seekOffset = 0;
  bool? _levelIsBrightness;
  double? _levelValue;
  double _levelPending = 0;
  bool _handedToPip = false;

  FilePlayItem get _item => widget.playlist[_index];
  bool get _hasPrevious => _index > 0;
  bool get _hasNext => _index < widget.playlist.length - 1;

  @override
  void initState() {
    super.initState();
    _pip.addListener(_pipChanged);
    _pip.onAction = _pipAction;
    _subscriptions.addAll([
      _player.stream.playing.listen((value) {
        if (mounted) setState(() => _playing = value);
        _syncPip();
      }),
      _player.stream.buffering.listen((value) {
        if (mounted) setState(() => _buffering = value);
      }),
      _player.stream.position.listen((value) {
        if (mounted) setState(() => _position = value);
      }),
      _player.stream.duration.listen((value) {
        if (mounted) setState(() => _duration = value);
      }),
      _player.stream.completed.listen((value) {
        if (!mounted) return;
        setState(() => _completed = value);
        if (value && _hasNext) unawaited(_step(1));
      }),
      _player.stream.error.listen((error) {
        if (mounted && error.isNotEmpty) setState(() => _error = error);
      }),
      _player.stream.tracks.listen((tracks) {
        if (mounted) setState(() => _tracks = tracks);
      }),
      _player.stream.rate.listen((rate) {
        if (mounted && !_boosting) setState(() => _rate = rate);
      }),
    ]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        AppDevice.setPlayerOrientation(PlayerOrientation.lockedLandscape),
      );
    });
    unawaited(_loadItem());
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _armHideTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ).catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    _saveProgress();
    _saveTimer?.cancel();
    _hideTimer?.cancel();
    _pip.removeListener(_pipChanged);
    if (Platform.isIOS && _pip.active) {
      // iOS 画中画还在播：播放器不能销毁，交给保活持有者，等画中画
      // 停了再释放（不走 PlaybackHost 那套剧集会话保活）。
      _handedToPip = true;
      _FilePipKeepAlive.hold(_player, _controller);
    } else {
      if (_pip.onAction == _pipAction) _pip.onAction = null;
      _pip.clear();
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      unawaited(_player.dispose());
    }
    unawaited(AppDevice.releaseOrientation());
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
      ).catchError((Object _) {}),
    );
    unawaited(AppDevice.resetBrightness());
    super.dispose();
  }

  // ---------------------------------------------------------- 画中画

  double get _aspectRatio {
    final width = _player.state.width ?? 0;
    final height = _player.state.height ?? 0;
    return width > 0 && height > 0 ? width / height : 16 / 9;
  }

  void _syncPip() {
    _pip.update(
      aspectRatio: _aspectRatio,
      playing: _playing,
      hasPrevious: _hasPrevious,
      hasNext: _hasNext,
      iosPlayer: _player,
      autoEnter: false,
    );
  }

  void _pipChanged() {
    if (!mounted) return;
    // iOS 画中画在本页打开期间激活：退回浏览页，播放器在 dispose
    // 里交保活持有者，小窗继续播（与剧集页同款行为）。
    if (Platform.isIOS &&
        !_pipActiveAtEntry &&
        _pip.active &&
        ModalRoute.of(context)?.isCurrent == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      });
    }
    setState(() {});
  }

  void _pipAction(String action) {
    switch (action) {
      case 'play':
        if (!_player.state.playing) unawaited(_player.play());
      case 'pause':
        if (_player.state.playing) unawaited(_player.pause());
      case 'toggle':
        unawaited(_player.playOrPause());
      case 'previous':
        if (_hasPrevious) unawaited(_step(-1));
      case 'next':
        if (_hasNext) unawaited(_step(1));
    }
  }

  // ---------------------------------------------------------- 条目切换

  Future<void> _loadItem() async {
    final item = _item;
    setState(() {
      _buffering = true;
      _completed = false;
      _error = null;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    await _clearLoop(notify: false);
    try {
      final target = await item.loadTarget();
      _currentUrl = target.url;
      final saved = widget.files.progressFor(item.progressKey);
      final start = saved != null && !saved.finished && saved.position > 5
          ? Duration(milliseconds: (saved.position * 1000).round())
          : null;
      await _player.open(
        Media(target.url, httpHeaders: target.headers, start: start),
      );
      _syncPip();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _step(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= widget.playlist.length) return;
    _saveProgress();
    _endBoost();
    setState(() => _index = next);
    await _loadItem();
    _armHideTimer();
  }

  void _saveProgress() {
    if (_handedToPip) return;
    final duration = _player.state.duration.inMilliseconds / 1000;
    if (duration <= 0) return;
    final item = _item;
    unawaited(
      widget.files
          .saveProgress(
            item.progressKey,
            position: _player.state.position.inMilliseconds / 1000,
            duration: duration,
            title: item.title,
            sourceName: widget.sourceName,
            sourceId: widget.sourceId,
            url: _currentUrl,
            ref: item.ref,
          )
          .catchError((Object _) {}),
    );
  }

  // ---------------------------------------------------------- 手势

  void _armHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) setState(() => _controls = false);
    });
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    if (_controls) _armHideTimer();
  }

  void _togglePlay() {
    if (_completed) {
      unawaited(_player.seek(Duration.zero).then((_) => _player.play()));
    } else {
      unawaited(_player.playOrPause());
    }
    _armHideTimer();
  }

  void _seekTo(Duration target) {
    unawaited(_player.seek(target));
    _armHideTimer();
  }

  int get _seekTargetMs => (_seekFrom! + _seekOffset)
      .round()
      .clamp(0, _duration.inMilliseconds);

  void _seekStart(DragStartDetails _) {
    if (_duration <= Duration.zero) return;
    setState(() {
      _seekFrom = _position.inMilliseconds;
      _seekOffset = 0;
    });
  }

  void _seekUpdate(DragUpdateDetails details) {
    if (_seekFrom == null) return;
    final span = _duration.inMilliseconds.clamp(0, 120000);
    final offset =
        _seekOffset + details.delta.dx / context.size!.width * span;
    setState(
      () => _seekOffset = offset
          .clamp(-_seekFrom!, _duration.inMilliseconds - _seekFrom!)
          .toDouble(),
    );
  }

  void _seekEnd(DragEndDetails _) {
    if (_seekFrom == null) return;
    final target = _seekTargetMs;
    setState(() => _seekFrom = null);
    _seekTo(Duration(milliseconds: target));
  }

  Future<void> _levelStart(DragStartDetails details) async {
    final brightness = details.localPosition.dx < context.size!.width / 2;
    setState(() {
      _levelIsBrightness = brightness;
      _levelValue = null;
      _levelPending = 0;
    });
    final value = await (brightness
        ? AppDevice.brightness()
        : AppDevice.volume());
    if (!mounted || _levelIsBrightness != brightness || _levelValue != null) {
      return;
    }
    if (value == null) {
      setState(() => _levelIsBrightness = null);
      return;
    }
    _applyLevel(value + _levelPending);
  }

  void _levelUpdate(DragUpdateDetails details) {
    if (_levelIsBrightness == null) return;
    final delta = -details.delta.dy / context.size!.height;
    final value = _levelValue;
    if (value != null) {
      _applyLevel(value + delta);
    } else {
      _levelPending += delta;
    }
  }

  void _applyLevel(double value) {
    final next = value.clamp(0.0, 1.0);
    setState(() => _levelValue = next);
    unawaited(
      _levelIsBrightness == true
          ? AppDevice.setBrightness(next)
          : AppDevice.setVolume(next),
    );
  }

  void _levelEnd() {
    if (_levelIsBrightness != null) {
      setState(() {
        _levelIsBrightness = null;
        _levelValue = null;
      });
    }
  }

  void _boostStart() {
    if (_boosting || _completed || _duration <= Duration.zero) return;
    _rateBeforeBoost = _rate;
    setState(() => _boosting = true);
    unawaited(_player.setRate(_boostRate));
    unawaited(HapticFeedback.selectionClick());
  }

  void _endBoost() {
    if (!_boosting) return;
    setState(() => _boosting = false);
    unawaited(_player.setRate(_rateBeforeBoost));
  }

  // ---------------------------------------------------------- 设置面板

  Future<void> _setRate(double rate) async {
    setState(() => _rate = rate);
    await _player.setRate(rate);
  }

  Future<void> _setProperty(String name, String value) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty(name, value);
    }
  }

  Future<void> _setVideoEq() async {
    await _setProperty('brightness', _brightness.toStringAsFixed(0));
    await _setProperty('contrast', _contrast.toStringAsFixed(0));
    await _setProperty('saturation', _saturation.toStringAsFixed(0));
  }

  Future<void> _setLoopPoint(String property, Duration position) =>
      _setProperty(
        property,
        (position.inMilliseconds / 1000).toStringAsFixed(2),
      );

  Future<void> _clearLoop({bool notify = true}) async {
    if (_loopA == null && _loopB == null) return;
    if (notify) {
      setState(() {
        _loopA = null;
        _loopB = null;
      });
    } else {
      _loopA = null;
      _loopB = null;
    }
    await _setProperty('ab-loop-a', 'no');
    await _setProperty('ab-loop-b', 'no');
  }

  Future<void> _screenshot() async {
    String? path;
    try {
      final bytes = await _player.screenshot(format: 'image/jpeg');
      if (bytes != null) {
        final directory = await getApplicationDocumentsDirectory();
        final now = DateTime.now();
        String two(int part) => part.toString().padLeft(2, '0');
        final stamp =
            '${now.year}${two(now.month)}${two(now.day)}-'
            '${two(now.hour)}${two(now.minute)}${two(now.second)}';
        final file = File('${directory.path}/lvguo-screenshot-$stamp.jpg');
        await file.writeAsBytes(bytes);
        path = file.path;
      }
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      glassSnackBar(context, path == null ? '截图失败' : '已保存：$path'),
    );
  }

  void _showSpeedSheet() {
    unawaited(
      showPlayerSheet(
        context,
        (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              children: [
                const Expanded(child: Text('倍速', style: sheetTitle)),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '关闭',
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final speed in playbackSpeeds)
                    _Choice(
                      label: '${speed}x',
                      selected: speed == _rate,
                      onSelected: () {
                        Navigator.pop(context);
                        unawaited(_setRate(speed));
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
        fitContent: true,
      ),
    );
    _armHideTimer();
  }

  void _showSettingsSheet() {
    unawaited(
      showPlayerSheet(
        context,
        (_) => StatefulBuilder(
          builder: (context, setSheetState) {
            final tracks = _tracks ?? _player.state.tracks;
            void refresh() {
              setSheetState(() {});
              setState(() {});
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetHeader(
                  children: [
                    const Expanded(child: Text('播放设置', style: sheetTitle)),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                      tooltip: '关闭',
                    ),
                  ],
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _sectionLabel(context, '倍速'),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final speed in playbackSpeeds)
                            _Choice(
                              label: '${speed}x',
                              selected: speed == _rate,
                              onSelected: () {
                                unawaited(_setRate(speed));
                                refresh();
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      _sectionLabel(context, '画面调节'),
                      const SizedBox(height: 4),
                      _SliderRow(
                        label: '亮度',
                        value: _brightness,
                        onChanged: (value) {
                          _brightness = value;
                          unawaited(_setVideoEq());
                        },
                      ),
                      _SliderRow(
                        label: '对比度',
                        value: _contrast,
                        onChanged: (value) {
                          _contrast = value;
                          unawaited(_setVideoEq());
                        },
                      ),
                      _SliderRow(
                        label: '饱和度',
                        value: _saturation,
                        onChanged: (value) {
                          _saturation = value;
                          unawaited(_setVideoEq());
                        },
                      ),
                      const SizedBox(height: 22),
                      _sectionLabel(context, 'A-B 循环'),
                      const SizedBox(height: 12),
                      Row(
                        spacing: 8,
                        children: [
                          Expanded(
                            child: _Choice(
                              label: _loopA == null
                                  ? '设 A 点'
                                  : 'A ${_clock(_loopA!)}',
                              selected: _loopA != null,
                              onSelected: () {
                                setState(() => _loopA = _position);
                                unawaited(
                                  _setLoopPoint('ab-loop-a', _position),
                                );
                                refresh();
                              },
                            ),
                          ),
                          Expanded(
                            child: _Choice(
                              label: _loopB == null
                                  ? '设 B 点'
                                  : 'B ${_clock(_loopB!)}',
                              selected: _loopB != null,
                              onSelected: _loopA == null
                                  ? null
                                  : () {
                                      setState(() => _loopB = _position);
                                      unawaited(
                                        _setLoopPoint('ab-loop-b', _position),
                                      );
                                      refresh();
                                    },
                            ),
                          ),
                          if (_loopA != null || _loopB != null)
                            _Choice(
                              label: '清除',
                              selected: false,
                              onSelected: () {
                                unawaited(_clearLoop());
                                refresh();
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.photo_camera_rounded),
                        title: const Text('截图'),
                        subtitle: const Text('保存当前帧到应用文件'),
                        onTap: () {
                          Navigator.pop(context);
                          unawaited(_screenshot());
                        },
                      ),
                      if (tracks.audio.length > 1) ...[
                        const SizedBox(height: 22),
                        _sectionLabel(context, '音轨'),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final track in tracks.audio)
                              _Choice(
                                label: track.title ?? track.id,
                                selected: _audioTrackId == null
                                    ? track.id == 'auto'
                                    : track.id == _audioTrackId,
                                onSelected: () {
                                  _audioTrackId = track.id == 'auto'
                                      ? null
                                      : track.id;
                                  unawaited(_player.setAudioTrack(track));
                                  refresh();
                                },
                              ),
                          ],
                        ),
                      ],
                      if (tracks.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 22),
                        _sectionLabel(context, '字幕'),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final track in tracks.subtitle)
                              _Choice(
                                label:
                                    track.title ??
                                    track.language ??
                                    (track.id == 'no' ? '关闭' : track.id),
                                selected: _subtitleTrackId == null
                                    ? track.id == 'no'
                                    : track.id == _subtitleTrackId,
                                onSelected: () {
                                  _subtitleTrackId = track.id == 'no'
                                      ? null
                                      : track.id;
                                  unawaited(_player.setSubtitleTrack(track));
                                  refresh();
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 22),
                        _sectionLabel(context, '字幕延迟'),
                        const SizedBox(height: 4),
                        _SliderRow(
                          label: '延迟',
                          value: _subtitleDelay,
                          min: -5,
                          max: 5,
                          format: (value) =>
                              '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}s',
                          onChanged: (value) {
                            _subtitleDelay = value;
                            unawaited(
                              _setProperty(
                                'sub-delay',
                                value.toStringAsFixed(1),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    _armHideTimer();
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final colors = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
        color: colors.onSurfaceVariant,
      ),
    );
  }

  // ---------------------------------------------------------- 界面

  static String _clock(Duration value) {
    final total = value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = total % 3600 ~/ 60;
    final seconds = total % 60;
    String two(int part) => part.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        onHorizontalDragStart: _seekStart,
        onHorizontalDragUpdate: _seekUpdate,
        onHorizontalDragEnd: _seekEnd,
        onHorizontalDragCancel: () => setState(() => _seekFrom = null),
        onVerticalDragStart: (details) => unawaited(_levelStart(details)),
        onVerticalDragUpdate: _levelUpdate,
        onVerticalDragEnd: (_) => _levelEnd(),
        onVerticalDragCancel: _levelEnd,
        onLongPressStart: (_) => _boostStart(),
        onLongPressEnd: (_) => _endBoost(),
        onLongPressCancel: _endBoost,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Video(
              controller: _controller,
              controls: NoVideoControls,
              fill: Colors.black,
            ),
            if (_buffering && error == null)
              const Center(child: CircularProgressIndicator()),
            if (error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    '播放失败：$error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            FadePresence(child: _badge()),
            AnimatedOpacity(
              opacity: _controls ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(ignoring: !_controls, child: _overlay()),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _badge() {
    if (_seekFrom != null) {
      return _badgeShell(
        Text.rich(
          TextSpan(
            text: _clock(Duration(milliseconds: _seekTargetMs)),
            children: [
              TextSpan(
                text: ' / ${_clock(_duration)}',
                style: TextStyle(color: Colors.white.withValues(alpha: .6)),
              ),
            ],
          ),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      );
    }
    final level = _levelValue;
    if (_levelIsBrightness != null && level != null) {
      return _badgeShell(
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            Icon(
              _levelIsBrightness == true
                  ? Icons.brightness_6_rounded
                  : level == 0
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              size: 22,
              color: Colors.white,
            ),
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                value: level,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
                color: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: .25),
              ),
            ),
          ],
        ),
      );
    }
    if (_boosting) {
      return _badgeShell(
        const Text(
          '${_boostRate}x 加速中',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return null;
  }

  Widget _badgeShell(Widget child) => IgnorePointer(
    child: Align(
      alignment: const Alignment(0, -.4),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(12),
        blur: 14,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: child,
      ),
    ),
  );

  Widget _overlay() {
    final theme = Theme.of(context);
    final max = _duration.inSeconds.toDouble();
    final value = _position.inSeconds.toDouble().clamp(0, max > 0 ? max : 0);
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              children: [
                LiquidGlassIconButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_pip.available && (Platform.isIOS || Platform.isAndroid))
                  LiquidGlassIconButton(
                    tooltip: '画中画',
                    onPressed: () {
                      _syncPip();
                      unawaited(_pip.enter(_aspectRatio));
                    },
                    child: const Icon(
                      Icons.picture_in_picture_alt_rounded,
                      color: Colors.white,
                    ),
                  ),
                const SizedBox(width: 8),
                LiquidGlassIconButton(
                  tooltip: '播放设置',
                  onPressed: _showSettingsSheet,
                  child: const Icon(Icons.tune_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 20,
          children: [
            LiquidGlassIconButton(
              size: 52,
              tooltip: '上一个',
              onPressed: _hasPrevious ? () => unawaited(_step(-1)) : null,
              child: Icon(
                Icons.skip_previous_rounded,
                color: _hasPrevious ? Colors.white : Colors.white38,
              ),
            ),
            LiquidGlassIconButton(
              size: 52,
              onPressed: () => _seekTo(
                _position - const Duration(seconds: 10) < Duration.zero
                    ? Duration.zero
                    : _position - const Duration(seconds: 10),
              ),
              child: const Icon(Icons.replay_10_rounded, color: Colors.white),
            ),
            LiquidGlassIconButton(
              size: 64,
              onPressed: _togglePlay,
              child: Icon(
                _completed
                    ? Icons.replay_rounded
                    : _playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
            LiquidGlassIconButton(
              size: 52,
              onPressed: () =>
                  _seekTo(_position + const Duration(seconds: 10)),
              child: const Icon(
                Icons.forward_10_rounded,
                color: Colors.white,
              ),
            ),
            LiquidGlassIconButton(
              size: 52,
              tooltip: '下一个',
              onPressed: _hasNext ? () => unawaited(_step(1)) : null,
              child: Icon(
                Icons.skip_next_rounded,
                color: _hasNext ? Colors.white : Colors.white38,
              ),
            ),
          ],
        ),
        const Spacer(),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: LiquidGlass(
              borderRadius: BorderRadius.circular(20),
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 10),
              child: Row(
                children: [
                  Text(
                    _clock(_position),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  Expanded(
                    child: Slider(
                      value: value.toDouble(),
                      max: max > 0 ? max : 1,
                      onChanged: max > 0
                          ? (seconds) => _seekTo(
                              Duration(seconds: seconds.round()),
                            )
                          : null,
                    ),
                  ),
                  Text(
                    _clock(_duration),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  TextButton(
                    onPressed: _showSpeedSheet,
                    child: Text(
                      _boosting ? '${_boostRate}x' : '${_rate}x',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// iOS 画中画保活持有者：文件播放页退页时画中画还在播，播放器
/// 交到这里继续活着；画中画停掉后释放。只保活一个（新的一次会
/// 先释放旧的）。画中画里的播放/暂停通过 PictureInPicture.onAction
/// 转给它，上/下一没有列表上下文，不处理。
class _FilePipKeepAlive {
  static Player? _player;
  static VideoController? _controller;
  static StreamSubscription<bool>? _playing;
  static bool _listening = false;

  static void hold(Player player, VideoController controller) {
    release();
    _player = player;
    _controller = controller;
    PictureInPicture.instance.onAction = (action) {
      final current = _player;
      if (current == null) return;
      switch (action) {
        case 'play':
          if (!current.state.playing) unawaited(current.play());
        case 'pause':
          if (current.state.playing) unawaited(current.pause());
        case 'toggle':
          unawaited(current.playOrPause());
      }
    };
    _playing = player.stream.playing.listen((playing) {
      PictureInPicture.instance.update(
        aspectRatio: _ratio(player),
        playing: playing,
        hasPrevious: false,
        hasNext: false,
        iosPlayer: player,
        autoEnter: false,
      );
    });
    if (!_listening) {
      _listening = true;
      PictureInPicture.instance.addListener(() {
        if (!PictureInPicture.instance.active && _player != null) release();
      });
    }
  }

  static double _ratio(Player player) {
    final width = player.state.width ?? 0;
    final height = player.state.height ?? 0;
    return width > 0 && height > 0 ? width / height : 16 / 9;
  }

  static void release() {
    final player = _player;
    if (player == null) return;
    _player = null;
    _controller = null;
    unawaited(_playing?.cancel());
    _playing = null;
    PictureInPicture.instance.onAction = null;
    PictureInPicture.instance.clear();
    unawaited(player.dispose());
  }
}

/// 设置面板里的玻璃小胶囊选项（与 playback_sheets 的同名组件同款，
/// 那个是私有的，这里本地一份）。
class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final bool selected;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onSelected != null;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: selected
            ? colors.secondaryContainer.withValues(alpha: .8)
            : Colors.white.withValues(alpha: .1),
        border: Border.all(
          color: selected
              ? Colors.white.withValues(alpha: .6)
              : Colors.white.withValues(alpha: .18),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onSelected,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? colors.onSecondaryContainer
                    : colors.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置面板的滑杆行：显示值自己持有，拖动只下发属性不整页重建
/// （与 playback_sheets 的 _EqRow 同款逻辑）。
class _SliderRow extends StatefulWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = -100,
    this.max = 100,
    this.format,
  });
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final String Function(double value)? format;

  @override
  State<_SliderRow> createState() => _SliderRowState();
}

class _SliderRowState extends State<_SliderRow> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  void didUpdateWidget(covariant _SliderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final format = widget.format ?? (value) => value.round().toString();
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(
            widget.label,
            style: TextStyle(fontSize: 13, color: colors.onSurface),
          ),
        ),
        Expanded(
          child: Slider(
            value: _value,
            min: widget.min,
            max: widget.max,
            onChanged: (value) {
              setState(() => _value = value);
              widget.onChanged(value);
            },
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            format(_value),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
