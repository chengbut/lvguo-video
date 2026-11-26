import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../file_sources.dart';
import '../shell/app_shell.dart';
import '../widgets/focus_ring.dart';
import '../widgets/form_text_field.dart';
import '../widgets/group_card.dart';
import '../widgets/liquid_glass.dart';
import 'cloud_login_page.dart';
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
                        if (source.nativeMode)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colors.tertiaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '原生 · 实验',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colors.onTertiaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      source.nativeMode
                          ? '原生登录（实验） · ${source.host}'
                          : source.host,
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

/// 打开一个文件源：HTTP 拉取直接播那条直链；其余进文件浏览页
/// （底层走统一的 FileSourceClient，页面不感知协议差异）。
void openFileSource(
  BuildContext context, {
  required FileSource source,
  required FileSourceStore files,
}) {
  if (source.type == FileSourceType.http) {
    openPage<void>(
      context,
      (_) => FilePlayerPage(
        playlist: [
          FilePlayItem(
            title: source.name,
            progressKey: source.url,
            ref: '',
            loadTarget: () async => FilePlayTarget(url: source.url),
          ),
        ],
        index: 0,
        files: files,
        sourceName: source.name,
        sourceId: source.id,
      ),
    );
    return;
  }
  openPage<void>(
    context,
    (_) => FileBrowserPage(source: source, files: files),
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
/// 拉取、FTP），再进对应表单页，保存后回到列表。
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
                  FileSourceType.mobile => '网页登录（实验）/ WebDAV 挂载',
                  FileSourceType.webdav => 'WebDAV 服务器',
                  FileSourceType.http => '单个媒体文件的直链地址',
                  FileSourceType.ftp => 'FTP 服务器',
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

/// 文件源卡片列表（资源页文件源组、首页文件源模式共用同一份数据）。
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
          child: Text('还没有文件源。点右上角「+ 添加文件源」，把网盘或服务器挂进来。'),
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

/// 添加文件源的表单页：
/// - 天翼/中国移动：顶部二选一「原生登录（实验）/ WebDAV 挂载」，
///   默认 WebDAV。原生模式主路径是内嵌官方网页登录（抓 Cookie 存
///   凭据），粘贴凭据是备用入口；WebDAV 模式是服务器地址表单。
/// - WebDAV：名称、服务器地址、用户名、密码。
/// - FTP：名称、主机、端口、用户名、密码、初始目录。
/// - HTTP 拉取：名称 + 直链地址。
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
  final _cookie = TextEditingController();
  final _port = TextEditingController(text: '21');
  final _path = TextEditingController(text: '/');
  bool _native = false;
  bool _loggedIn = false;
  String? _error;

  bool get _cloud =>
      widget.type == FileSourceType.tianyi ||
      widget.type == FileSourceType.mobile;

  bool get _webViewSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void dispose() {
    _name.dispose();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _url.dispose();
    _cookie.dispose();
    _port.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _openLogin() async {
    final result = await openPage<CloudLoginResult>(
      context,
      (_) => CloudLoginPage(type: widget.type),
    );
    if (result == null || !mounted) return;
    setState(() {
      _cookie.text = result.credential;
      _loggedIn = true;
      _error = null;
    });
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }
    final type = widget.type;
    if (_cloud && _native) {
      final credential = _cookie.text.trim();
      if (credential.isEmpty) {
        setState(() => _error = '请先网页登录，或粘贴凭据（备用方式）');
        return;
      }
      Navigator.pop(
        context,
        FileSource(
          id: newFileSourceId(),
          name: name,
          type: type,
          mode: fileSourceModeNative,
          cookie: credential,
        ),
      );
      return;
    }
    if (type == FileSourceType.ftp) {
      final host = _server.text.trim();
      if (host.isEmpty) {
        setState(() => _error = '请填写 FTP 主机');
        return;
      }
      final port = int.tryParse(_port.text.trim()) ?? 21;
      if (port < 1 || port > 65535) {
        setState(() => _error = '端口不合法');
        return;
      }
      Navigator.pop(
        context,
        FileSource(
          id: newFileSourceId(),
          name: name,
          type: type,
          server: host,
          username: _username.text.trim(),
          password: _password.text,
          port: port,
          path: _path.text.trim().isEmpty ? '/' : _path.text.trim(),
        ),
      );
      return;
    }
    if (type == FileSourceType.http) {
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
          type: type,
          url: url,
        ),
      );
      return;
    }
    // WebDAV 类（含天翼/移动的挂载模式）。
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
        type: type,
        server: server,
        username: _username.text.trim(),
        password: _password.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.type;
    final theme = Theme.of(context);
    final hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Scaffold(
      appBar: AppBar(title: Text('添加${type.label}')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            FormTextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '例如：我的天翼云盘',
              ),
            ),
            const SizedBox(height: 16),
            if (_cloud) ...[
              GlassSegmentedControl(
                labels: const ['原生登录（实验）', 'WebDAV 挂载'],
                selected: _native ? 0 : 1,
                onSelected: (index) =>
                    setState(() => _native = index == 0),
              ),
              const SizedBox(height: 16),
              if (_native) ..._nativeFields(hintStyle) else ...[
                Text(
                  '通过 WebDAV 挂载（可用 Alist / CloudDrive2 转出地址）',
                  style: hintStyle,
                ),
                const SizedBox(height: 16),
                ..._webDavFields(),
              ],
            ] else if (type == FileSourceType.webdav)
              ..._webDavFields()
            else if (type == FileSourceType.ftp)
              ..._ftpFields()
            else
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

  List<Widget> _webDavFields() => [
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
  ];

  List<Widget> _ftpFields() => [
    FormTextField(
      controller: _server,
      url: true,
      decoration: const InputDecoration(
        labelText: '主机',
        hintText: '192.168.1.5 或 ftp.example.com',
      ),
    ),
    const SizedBox(height: 16),
    FormTextField(
      controller: _port,
      decoration: const InputDecoration(labelText: '端口'),
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
    const SizedBox(height: 16),
    FormTextField(
      controller: _path,
      decoration: const InputDecoration(
        labelText: '初始目录',
        hintText: '/',
      ),
    ),
  ];

  List<Widget> _nativeFields(TextStyle? hintStyle) {
    final tianyi = widget.type == FileSourceType.tianyi;
    return [
      Text(
        tianyi
            ? '实验功能：在官方网页里登录你的天翼云盘，登录成功后自动读取登录状态保存。接口按公开形态实现，未经实测。'
            : '实验功能：在官方网页里登录你的中国移动云盘，登录成功后自动读取登录状态保存。接口按公开形态实现，未经实测。',
        style: hintStyle,
      ),
      const SizedBox(height: 12),
      if (_webViewSupported)
        FilledButton.icon(
          onPressed: () => unawaited(_openLogin()),
          icon: Icon(
            _loggedIn ? Icons.check_circle_rounded : Icons.login_rounded,
          ),
          label: Text(_loggedIn ? '已登录，点此重新登录' : '打开官方网页登录'),
        )
      else
        Text('当前平台不支持内置网页登录，请用下方备用粘贴方式。', style: hintStyle),
      const SizedBox(height: 16),
      FormTextField(
        controller: _cookie,
        maxLines: 4,
        decoration: InputDecoration(
          labelText: tianyi ? 'Cookie（备用粘贴）' : 'Authorization / Cookie（备用粘贴）',
          hintText: tianyi
              ? '在电脑浏览器登录 cloud.189.cn 网页版，开发者工具 → 网络里复制请求头 Cookie 整段粘贴'
              : '在电脑浏览器登录 yun.139.com 网页版，开发者工具 → 网络找 hcy/file/list 请求，复制 Authorization 里 Basic 后面的内容',
        ),
      ),
    ];
  }
}
