import 'dart:io';

import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../resource_settings_editor.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import 'appearance_settings.dart';
import 'settings_sections.dart';

Future<void> openProxySettings(BuildContext context, LocalStore store) =>
    openPage<void>(context, (_) => _ProxySettingsPage(store: store));

class _ProxySettingsPage extends StatefulWidget {
  const _ProxySettingsPage({required this.store});
  final LocalStore store;

  @override
  State<_ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends State<_ProxySettingsPage> {
  ResourceSettingsEditor? _editor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _editor ??= ResourceSettingsEditor(
      AppScope.of(context).repository,
      widget.store,
    )..load();
  }

  @override
  void dispose() {
    _editor?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(SettingsGroup.proxy.label)),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SettingsSection(
          group: SettingsGroup.proxy,
          store: widget.store,
          editor: _editor!,
          open: (title, body) => _openFullPage(context, title, body),
        ),
      ],
    ),
  );
}

void _openFullPage(BuildContext context, String title, WidgetBuilder body) =>
    openPage<void>(
      context,
      (context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: body(context),
      ),
    );

/// 各设置组的副标题（原来设置页列表用的那份，抽出来给我的页里的设置入口共用）。
String settingsGroupSummary(
  BuildContext context,
  LocalStore store,
  SettingsGroup group,
) {
  final scope = AppScope.of(context);
  return switch (group) {
    SettingsGroup.appearance => [
      themeModes[store.themeMode],
      scope.systemColorAvailable && store.followSystemColor
          ? '系统取色'
          : store.themeColor.label,
      displayModes[platformDisplayMode(store.displayMode)],
    ].join(' · '),
    SettingsGroup.playback => '倍速、清晰度、解码与手势',
    SettingsGroup.danmaku => '字号、颜色、显示区域与屏蔽词',
    SettingsGroup.slacking => Platform.isWindows ? '老板键、小窗贴边隐藏' : '老板键',
    SettingsGroup.download =>
      Platform.isAndroid ? '默认画质、同时下载数量、自动导出' : '默认画质、VIP 集、同时下载数量',
    SettingsGroup.storage => '下载目录、清理缓存、删除全部数据',
    SettingsGroup.proxy => '连接方式、代理地址',
    SettingsGroup.about =>
      scope.version.isEmpty ? '版本未知' : '版本 ${scope.version}',
    SettingsGroup.diagnostics => '播放调试日记、备份与恢复',
  };
}

/// 直接打开某一设置组的独立页面（我的页里的设置入口点进去就是它，
/// 和原来从设置列表点进去的子页面是同一个 SettingsSection）。
class SettingsGroupPage extends StatefulWidget {
  const SettingsGroupPage({
    super.key,
    required this.store,
    required this.group,
  });
  final LocalStore store;
  final SettingsGroup group;

  @override
  State<SettingsGroupPage> createState() => _SettingsGroupPageState();
}

class _SettingsGroupPageState extends State<SettingsGroupPage> {
  ResourceSettingsEditor? _editor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _editor ??= ResourceSettingsEditor(
      AppScope.of(context).repository,
      widget.store,
    )..load();
  }

  @override
  void dispose() {
    _editor?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.group.label)),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SettingsSection(
          group: widget.group,
          store: widget.store,
          editor: _editor!,
          open: (title, body) => _openFullPage(context, title, body),
        ),
      ],
    ),
  );
}
