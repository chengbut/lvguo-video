import 'dart:async';

import 'package:flutter/material.dart';

import '../../file_sources.dart';
import '../shell/app_shell.dart';
import '../widgets/focus_ring.dart';
import '../widgets/form_text_field.dart';
import '../widgets/group_card.dart';
import 'file_browser_page.dart';
import 'file_player_page.dart';

ButtonStyle _cardButton(ColorScheme colors, {bool primary = false}) =>
    FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      backgroundColor: primary ? colors.primaryContainer : null,
      foregroundColor: primary ? colors.onPrimaryContainer : null,
    );

/// 文件源卡片：排版和站源模块卡一致——第一行名称 + 类型小标记，
/// 第二行主机，底部「打开」「删除」。点卡片 = 打开。
class FileSourceCard extends StatelessWidget {
  const FileSourceCard({
    super.key,
    required this.source,
    required this.onOpen,
    required this.onDelete,
  });
  final FileSource source;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final meta = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
      height: 1.35,
    );
    return GroupCard(
      children: [
        InkWell(
          onTap: onOpen,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      spacing: 8,
                      children: [
                        Flexible(
                          child: Text(
                            source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: 18,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors.secondaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            source.type.label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSecondaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      source.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: meta,
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                indent: 18,
                endIndent: 18,
                color: colors.outlineVariant.withValues(alpha: 0.6),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(
                  spacing: 8,
                  children: [
                    const Spacer(),
                    FocusRing(
                      radius: 20,
                      child: FilledButton.tonalIcon(
                        style: _cardButton(colors, primary: true),
                        onPressed: onOpen,
                        icon: const Icon(Icons.folder_open_rounded),
                        label: const Text('打开'),
                      ),
                    ),
                    FocusRing(
                      radius: 20,
                      child: FilledButton.tonalIcon(
                        style: _cardButton(colors),
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text('删除'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 打开一个文件源：WebDAV 类进文件浏览页；HTTP 拉取直接播那条直链。
void openFileSource(
  BuildContext context, {
  required FileSource source,
  required FileSourceStore files,
}) {
  if (source.type.isWebDav) {
    openPage<void>(
      context,
      (_) => FileBrowserPage(source: source, files: files),
    );
    return;
  }
  openPage<void>(
    context,
    (_) => FilePlayerPage(
      title: source.name,
      url: source.url,
      headers: const {},
      files: files,
    ),
  );
}

Future<void> confirmDeleteFileSource(
  BuildContext context, {
  required FileSource source,
  required FileSourceStore files,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('删除 ${source.name}？'),
      content: const Text('只删这个文件源的连接信息，网盘和服务器上的文件不受影响。'),
      actions: [
        FocusRing(
          radius: 20,
          child: TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
        ),
        FocusRing(
          radius: 20,
          child: FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ),
      ],
    ),
  );
  if (accepted == true) await files.remove(source.id);
}

/// 添加文件源：先选类型（顺序固定：天翼、中国移动、WebDAV、HTTP
/// 拉取），再进对应表单页，保存后回到列表。
Future<void> addFileSource(
  BuildContext context, {
  required FileSourceStore files,
}) async {
  final type = await showDialog<FileSourceType>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('添加文件源'),
      children: [
        for (final type in FileSourceType.values)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, type),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(type.label),
              subtitle: Text(
                switch (type) {
                  FileSourceType.tianyi ||
                  FileSourceType.mobile => '通过 WebDAV 挂载',
                  FileSourceType.webdav => 'WebDAV 服务器',
                  FileSourceType.http => '单个媒体文件的直链地址',
                },
              ),
            ),
          ),
      ],
    ),
  );
  if (type == null || !context.mounted) return;
  final created = await openPage<FileSource>(
    context,
    (_) => FileSourceFormPage(type: type),
  );
  if (created != null) await files.add(created);
}

/// 文件源卡片列表（资源页文件源组、发现页文件源模式共用同一份数据）。
class FileSourceCards extends StatelessWidget {
  const FileSourceCards({super.key, required this.files});
  final FileSourceStore files;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: files,
    builder: (context, _) {
      final sources = files.sources;
      if (sources.isEmpty) {
        return const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text('还没有文件源。点右上角「+ 添加文件源」，把网盘或 WebDAV 挂进来。'),
        );
      }
      return Column(
        spacing: 12,
        children: [
          for (final source in sources)
            FileSourceCard(
              source: source,
              onOpen: () =>
                  openFileSource(context, source: source, files: files),
              onDelete: () => unawaited(
                confirmDeleteFileSource(
                  context,
                  source: source,
                  files: files,
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// 添加文件源的表单页：WebDAV 类（天翼/中国移动/WebDAV）是名称、
/// 服务器地址、用户名、密码；天翼和中国移动在顶部多一行小字说明
/// 走 WebDAV 挂载。HTTP 拉取是名称 + 直链地址。
class FileSourceFormPage extends StatefulWidget {
  const FileSourceFormPage({super.key, required this.type});
  final FileSourceType type;

  @override
  State<FileSourceFormPage> createState() => _FileSourceFormPageState();
}

class _FileSourceFormPageState extends State<FileSourceFormPage> {
  final _name = TextEditingController();
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _url = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }
    if (widget.type.isWebDav) {
      final server = _server.text.trim();
      if (server.isEmpty) {
        setState(() => _error = '请填写服务器地址');
        return;
      }
      Navigator.pop(
        context,
        FileSource(
          id: newFileSourceId(),
          name: name,
          type: widget.type,
          server: server,
          username: _username.text.trim(),
          password: _password.text,
        ),
      );
      return;
    }
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请填写媒体文件直链地址');
      return;
    }
    Navigator.pop(
      context,
      FileSource(
        id: newFileSourceId(),
        name: name,
        type: widget.type,
        url: url,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.type;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('添加${type.label}')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (type == FileSourceType.tianyi ||
                type == FileSourceType.mobile)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  '通过 WebDAV 挂载（可用 Alist / CloudDrive2 转出地址）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            FormTextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '例如：我的天翼云盘',
              ),
            ),
            const SizedBox(height: 16),
            if (type.isWebDav) ...[
              FormTextField(
                controller: _server,
                url: true,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'http://192.168.1.5:5244/dav',
                ),
              ),
              const SizedBox(height: 16),
              FormTextField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 16),
              FormTextField(
                controller: _password,
                obscure: true,
                decoration: const InputDecoration(labelText: '密码'),
              ),
            ] else
              FormTextField(
                controller: _url,
                url: true,
                decoration: const InputDecoration(
                  labelText: '媒体文件直链',
                  hintText: 'https://…/movie.mp4',
                ),
              ),
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Text(error, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: _submit, child: const Text('保存')),
          ],
        ),
      ),
    );
  }
}
