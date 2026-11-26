import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../file_sources.dart';
import '../widgets/liquid_glass.dart';

/// 文件源专用播放页：直接打开一个 URL（带请求头）播放。
///
/// 全 App 的剧集播放页（PlaybackPage/PlaybackSession）只能播站源模块
/// 解析出的播放计划，没有“给我一个 URL 直接播”的入口，所以文件源
/// 在这里用同一个播放引擎（media_kit/mpv）单独开一页：播放/暂停、
/// 进度条、快进快退，进度按 URL 存进 FileSourceStore 实现续播；
/// 不带弹幕、选集、画中画这些剧集功能。
class FilePlayerPage extends StatefulWidget {
  const FilePlayerPage({
    super.key,
    required this.title,
    required this.url,
    required this.headers,
    required this.files,
  });
  final String title;
  final String url;
  final Map<String, String> headers;
  final FileSourceStore files;

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
  Timer? _saveTimer;
  Timer? _hideTimer;
  bool _controls = true;
  bool _playing = false;
  bool _buffering = true;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    final saved = widget.files.progressFor(widget.url);
    final start = saved != null && !saved.finished && saved.position > 5
        ? Duration(milliseconds: (saved.position * 1000).round())
        : null;
    _subscriptions.addAll([
      _player.stream.playing.listen((value) {
        if (mounted) setState(() => _playing = value);
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
        if (mounted) setState(() => _completed = value);
      }),
      _player.stream.error.listen((error) {
        if (mounted && error.isNotEmpty) setState(() => _error = error);
      }),
    ]);
    unawaited(
      _player.open(
        Media(widget.url, httpHeaders: widget.headers, start: start),
      ),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _armHideTimer();
  }

  @override
  void dispose() {
    _saveProgress();
    _saveTimer?.cancel();
    _hideTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  void _saveProgress() {
    final duration = _player.state.duration.inMilliseconds / 1000;
    if (duration <= 0) return;
    unawaited(
      widget.files
          .saveProgress(
            widget.url,
            position: _player.state.position.inMilliseconds / 1000,
            duration: duration,
          )
          .catchError((Object _) {}),
    );
  }

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
    unawaited(_player.playOrPause());
    _armHideTimer();
  }

  void _seek(double seconds) {
    final target = Duration(milliseconds: (seconds * 1000).round());
    unawaited(_player.seek(target));
    _armHideTimer();
  }

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
            AnimatedOpacity(
              opacity: _controls ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_controls,
                child: _overlay(),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 28,
          children: [
            LiquidGlassIconButton(
              size: 52,
              onPressed: () =>
                  _seek((_position - const Duration(seconds: 10)).inSeconds
                      .toDouble()
                      .clamp(0, double.infinity)),
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
                  _seek((_position + const Duration(seconds: 10)).inSeconds
                      .toDouble()),
              child: const Icon(
                Icons.forward_10_rounded,
                color: Colors.white,
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
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
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
                      onChanged: max > 0 ? _seek : null,
                    ),
                  ),
                  Text(
                    _clock(_duration),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
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
