import 'dart:async';

import 'package:flutter/material.dart';

import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'cast_page.dart';
import '../widgets/liquid_glass.dart';
import 'danmaku_settings.dart';

(Color, ThemeData)? _darkPlayerTheme;

ThemeData playerTheme(BuildContext context) {
  final theme = Theme.of(context);
  if (theme.brightness == Brightness.dark) return theme;
  final seed = theme.colorScheme.primary;
  if (_darkPlayerTheme case (final cached, final dark) when cached == seed) {
    return dark;
  }
  final dark = AppTheme.build(seed, Brightness.dark, television: false);
  _darkPlayerTheme = (seed, dark);
  return dark;
}

Future<void> showPlayerSheet(
  BuildContext context,
  WidgetBuilder builder, {
  bool dark = true,
  bool fitContent = false,
  Color? barrierColor,
}) {
  final theme = dark ? playerTheme(context) : Theme.of(context);
  final height = MediaQuery.sizeOf(context).height * .6;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    barrierColor: barrierColor,
    backgroundColor: Colors.transparent,
    constraints: fitContent
        ? BoxConstraints(maxHeight: height)
        : BoxConstraints.tightFor(height: height),
    builder: (context) => Theme(
      data: theme,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: theme.colorScheme.onSurface),
        child: _SheetEnter(
          child: LiquidGlass(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(28),
            ),
            // 比默认更透、磨砂更重：背后视频透出来，字仍可读。
            blur: 24,
            tint: 0.35,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    margin: const EdgeInsets.only(top: 10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Flexible(child: Builder(builder: builder)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 弹窗入场：跟随路由动画淡入 + 轻微上浮，收起时同样淡出。
/// 只做内容层的柔和过渡，弹窗本身的滑入滑出不动。
class _SheetEnter extends StatelessWidget {
  const _SheetEnter({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null) return child;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return Opacity(
          opacity: curved.value,
          child: Transform.translate(
            offset: Offset(0, (1 - curved.value) * 12),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(spacing: 8, children: children),
    ),
  );
}

const sheetTitle = TextStyle(fontSize: 20, fontWeight: FontWeight.w700);

class PlaybackSettings extends StatelessWidget {
  const PlaybackSettings({
    super.key,
    required this.session,
    required this.onFailure,
    this.onMiniWindow,
  });
  final PlaybackSession session;
  final VoidCallback onFailure;
  final VoidCallback? onMiniWindow;

  @override
  Widget build(BuildContext context) => Column(
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
        child: PlaybackSettingsList(
          session: session,
          onFailure: onFailure,
          onMiniWindow: onMiniWindow,
          onCast: () {
            final navigator = Navigator.of(context);
            navigator.pop();
            unawaited(startCast(navigator.context, session));
          },
        ),
      ),
    ],
  );
}

class PlaybackSettingsList extends StatelessWidget {
  const PlaybackSettingsList({
    super.key,
    required this.session,
    required this.onFailure,
    this.onMiniWindow,
    required this.onCast,
  });
  final PlaybackSession session;
  final VoidCallback onFailure;
  final VoidCallback? onMiniWindow;
  final VoidCallback onCast;

  Future<void> _change(Future<void> Function() change) async {
    try {
      await change();
    } catch (_) {
      onFailure();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final label = TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
        color: colors.onSurfaceVariant,
      );
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text('倍速', style: label),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final speed in playbackSpeeds)
                _GlassChoice(
                  label: '${speed}x',
                  selected: speed == session.speed,
                  onSelected: () => _change(() => session.setSpeed(speed)),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Text('清晰度', style: label),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: session.local
                ? [
                    _GlassChoice(
                      label: session.qualityLabel,
                      selected: true,
                      onSelected: null,
                    ),
                  ]
                : [
                    for (final quality in [...session.qualities, 0])
                      _GlassChoice(
                        label: quality == 0
                            ? (session.quality == 0
                                  ? session.qualityLabel
                                  : '自动')
                            : '${quality}P',
                        selected: quality == session.quality,
                        onSelected: session.ready
                            ? () => _change(() => session.setQuality(quality))
                            : null,
                      ),
                  ],
          ),
          if (!session.audio) ...[
            const SizedBox(height: 22),
            Text('画面比例', style: label),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final fit in VideoFit.values)
                  _GlassChoice(
                    label: fit.label,
                    selected: fit == session.videoFit,
                    onSelected: () => _change(() => session.setVideoFit(fit)),
                  ),
              ],
            ),
              const SizedBox(height: 22),
              Text('画面调节', style: label),
              const SizedBox(height: 4),
              _EqRow(
                label: '亮度',
                value: session.brightness,
                onChanged: (value) => session.setVideoEq(brightness: value),
              ),
              _EqRow(
                label: '对比度',
                value: session.contrast,
                onChanged: (value) => session.setVideoEq(contrast: value),
              ),
              _EqRow(
                label: '饱和度',
                value: session.saturation,
                onChanged: (value) => session.setVideoEq(saturation: value),
              ),
              const SizedBox(height: 22),
              Text('A-B 循环', style: label),
              const SizedBox(height: 12),
              Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: _GlassChoice(
                      label: session.loopA == null
                          ? '设 A 点'
                          : 'A ${_mmss(session.loopA!)}',
                      selected: session.loopA != null,
                      onSelected: () => _change(() => session.setLoopA()),
                    ),
                  ),
                  Expanded(
                    child: _GlassChoice(
                      label: session.loopB == null
                          ? '设 B 点'
                          : 'B ${_mmss(session.loopB!)}',
                      selected: session.loopActive,
                      onSelected: session.loopA == null
                          ? null
                          : () => _change(() => session.setLoopB()),
                    ),
                  ),
                  if (session.loopA != null || session.loopB != null)
                    _GlassChoice(
                      label: '清除',
                      selected: false,
                      onSelected: () => _change(() => session.clearLoop()),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              _ActionRow(
                icon: Icons.photo_camera_rounded,
                label: '截图',
                hint: '保存当前帧到应用文件',
                onTap: () async {
                  final path = await session.captureScreenshot();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(path == null ? '截图失败' : '已保存：$path'),
                    ),
                  );
                },
              ),
              if (session.subtitleTracks.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text('字幕延迟', style: label),
                const SizedBox(height: 4),
                _EqRow(
                  label: '延迟',
                  value: session.subtitleDelay,
                  min: -5,
                  max: 5,
                  format: (value) =>
                      '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}s',
                  onChanged: (value) => session.setSubtitleDelay(value),
                ),
              ],
          ],
          if (session.audioTracks.length > 1) ...[
            const SizedBox(height: 22),
            Text('音轨', style: label),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final track in session.audioTracks)
                  _GlassChoice(
                    label: track.title ?? track.id,
                    selected: session.audioTrackId == null
                        ? track.id == 'auto'
                        : track.id == session.audioTrackId,
                    onSelected: () =>
                        _change(() => session.setAudioTrackById(track.id)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 22),
          Text(sleepTimerLabel(session), style: label),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final choice in sleepChoices)
                _GlassChoice(
                  label: choice.label,
                  selected: choice.selected(session),
                  onSelected: () => choice.apply(session),
                ),
            ],
          ),
          if (session.danmakuSupported) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('弹幕'),
              value: session.danmakuEnabled,
              onChanged: (_) => _change(session.toggleDanmaku),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              shape: const Border(),
              collapsedShape: const Border(),
              leading: const Icon(Icons.text_fields_rounded),
              title: const Text('弹幕样式'),
              subtitle: Text(
                '字号、颜色、透明度、合并与显示区域',
                style: TextStyle(fontSize: 12, color: label.color),
              ),
              children: [
                DanmakuSettings(
                  session: session,
                  onFailure: onFailure,
                  dense: true,
                ),
              ],
            ),
          ],
          if (onMiniWindow case final onMiniWindow?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.picture_in_picture_alt_rounded),
              title: const Text('小窗播放'),
              onTap: onMiniWindow,
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_rounded),
            title: const Text('锁定屏幕'),
            onTap: () {
              Navigator.pop(context);
              session.setLocked(true);
            },
          ),
          if (castSupported)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cast_rounded),
              title: const Text('投屏'),
              onTap: onCast,
            ),
        ],
      );
    },
  );
}

typedef SleepChoice = ({
  String label,
  bool Function(PlaybackSession) selected,
  void Function(PlaybackSession) apply,
});

final List<SleepChoice> sleepChoices = [
  (
    label: '关闭',
    selected: (session) =>
        session.sleepMinutes == 0 && !session.sleepAtEpisodeEnd,
    apply: (session) => session.setSleepTimer(),
  ),
  (
    label: '播完本集',
    selected: (session) => session.sleepAtEpisodeEnd,
    apply: (session) => session.setSleepTimer(episodeEnd: true),
  ),
  for (final minutes in const [15, 30, 60, 90])
    (
      label: '$minutes 分钟',
      selected: (session) => session.sleepMinutes == minutes,
      apply: (session) => session.setSleepTimer(minutes: minutes),
    ),
];

String sleepTimerLabel(PlaybackSession session) {
  if (session.sleepAtEpisodeEnd) return '定时停止 · 本集播完后暂停';
  final at = session.sleepAt;
  if (at == null) return '定时停止';
  final time =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  return '定时停止 · $time 暂停';
}

/// 玻璃小胶囊：选中时亮面高亮 + 白色细边，未选中半透明磨砂。
/// 点选时标签轻微缩放淡入反馈（AnimatedScale + AnimatedOpacity）。
class _GlassChoice extends StatelessWidget {
  const _GlassChoice({
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
    return AnimatedContainer(
      duration: Motion.short,
      curve: Curves.easeOutCubic,
      alignment: Alignment.center,
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
            child: AnimatedScale(
              scale: selected ? 1.05 : 1,
              duration: Motion.short,
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: enabled ? 1 : .45,
                duration: Motion.short,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: selected
                        ? colors.onSecondaryContainer
                        : colors.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _mmss(Duration value) {
  final total = value.inSeconds;
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

/// 画面调节/字幕延迟的滑杆行：显示值由本组件自己持有，
/// 因为 setVideoEq/setSubtitleDelay 只下发 mpv 属性、不通知重建，
/// 拖动时不触发整页重建。
class _EqRow extends StatefulWidget {
  const _EqRow({
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
  State<_EqRow> createState() => _EqRowState();
}

class _EqRowState extends State<_EqRow> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  void didUpdateWidget(covariant _EqRow oldWidget) {
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

/// 单行操作（截图）：图标 + 名称 + 右侧说明，点击整行触发。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String hint;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 20, color: colors.onSurface),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(fontSize: 14, color: colors.onSurface),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hint,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
