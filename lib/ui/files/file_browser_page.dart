import 'dart:async';

import 'package:flutter/material.dart';

import '../../file_sources.dart';
import '../shell/app_shell.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/status_view.dart';
import 'file_player_page.dart';

/// 文件浏览页：数据源是统一的 [FileSourceClient]（WebDAV / FTP /
/// 天翼·移动原生都走这个接口，页面不感知差异）。文件夹点一下
/// push 一层新的本页，顶部写当前路径；视频文件点击播放，同
/// 文件夹的全部视频组成播放列表传给播放页做上/下一。
class FileBrowserPage extends StatefulWidget {
  const FileBrowserPage({
    super.key,
    required this.source,
    required this.files,
    this.path,
    this.label,
  });
  final FileSource source;
  final FileSourceStore files;

  /// 当前目录的定位符（WebDAV 路径 / FTP 路径 / 原生文件夹 ID）；
  /// null 是源根目录。
  final String? path;

  /// 当前目录的显示名（原生网盘用文件夹名当路径标签）。
  final String? label;

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  late final FileSourceClient _client = createFileSourceClient(widget.source);
  List<FileEntry>? _entries;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _client.list(widget.path);
      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          _error = '$failure';
          _loading = false;
        });
      }
    }
  }

  String get _pathLabel {
    final label = widget.label;
    if (label != null && label.isNotEmpty) return label;
    final path = widget.path;
    if (path == null) return '/';
    try {
      return Uri.decodeComponent(path);
    } catch (_) {
      return path;
    }
  }

  void _openEntry(FileEntry entry) {
    if (entry.isDirectory) {
      openPage<void>(
        context,
        (_) => FileBrowserPage(
          source: widget.source,
          files: widget.files,
          path: entry.href,
          label: widget.source.nativeMode ? entry.name : null,
        ),
      );
      return;
    }
    if (!entry.isVideo) {
      ScaffoldMessenger.of(context).showSnackBar(
        glassSnackBar(context, '暂不支持播放这个文件类型'),
      );
      return;
    }
    final videos = [
      for (final candidate in _entries ?? const <FileEntry>[])
        if (candidate.isVideo) candidate,
    ];
    final index = videos.indexOf(entry);
    openPage<void>(
      context,
      (_) => FilePlayerPage(
        playlist: [
          for (final video in videos) _client.playItem(video),
        ],
        index: index < 0 ? 0 : index,
        files: widget.files,
        sourceName: widget.source.name,
        sourceId: widget.source.id,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: Text(widget.source.name)),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                _pathLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(child: _body(entries)),
          ],
        ),
      ),
    );
  }

  Widget _body(List<FileEntry>? entries) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null) {
      return StatusView(
        title: '无法打开这个文件源',
        message: error,
        icon: Icons.cloud_off_rounded,
        action: '重试',
        onAction: () => unawaited(_load()),
      );
    }
    if (entries == null || entries.isEmpty) {
      return const StatusView(
        title: '这个文件夹是空的',
        message: '没有可显示的文件夹或文件。',
        icon: Icons.folder_open_rounded,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + capsuleBarClearance(context)),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return _EntryTile(
            entry: entry,
            progress: entry.isVideo
                ? widget.files.progressFor(_client.progressKey(entry))
                : null,
            onTap: () => _openEntry(entry),
          );
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.progress,
    required this.onTap,
  });
  final FileEntry entry;
  final FileProgress? progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final progress = this.progress;
    final subtitle = entry.isDirectory
        ? '文件夹'
        : entry.isVideo
        ? [
            if (entry.size > 0) _sizeLabel(entry.size),
            if (progress != null && !progress.finished)
              '看到 ${_clock(progress.position)}',
          ].join(' · ')
        : '文件';
    return LiquidGlass(
      borderRadius: BorderRadius.circular(16),
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          minTileHeight: 60,
          leading: Icon(
            entry.isDirectory
                ? Icons.folder_rounded
                : entry.isVideo
                ? Icons.movie_rounded
                : Icons.insert_drive_file_outlined,
            color: entry.isDirectory
                ? colors.primary
                : colors.onSurfaceVariant,
          ),
          title: Text(
            entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(subtitle),
          trailing: Icon(
            entry.isDirectory
                ? Icons.chevron_right_rounded
                : Icons.play_circle_outline_rounded,
            color: colors.onSurfaceVariant,
          ),
          onTap: onTap,
        ),
      ),
    );
  }

  static String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  static String _clock(double seconds) {
    final total = seconds.round();
    final hours = total ~/ 3600;
    final minutes = total % 3600 ~/ 60;
    final rest = total % 60;
    String two(int part) => part.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(rest)}'
        : '${two(minutes)}:${two(rest)}';
  }
}
