import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../download_converter.dart';
import '../../merge_queue.dart';
import '../../download_overview.dart';
import '../../local_store.dart';
import '../app_scope.dart';
import '../downloads/downloads_page.dart';
import '../modules/modules_page.dart';
import '../shell/app_shell.dart';
import '../settings/settings_page.dart';
import '../widgets/fade_in.dart';
import '../widgets/focus_ring.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/page_header.dart';

class MinePage extends StatelessWidget {
  const MinePage({
    super.key,
    required this.store,
    required this.downloads,
    required this.converter,
    required this.merges,
    required this.entryFocus,
    required this.onExitUp,
  });
  final LocalStore store;
  final DownloadOverview downloads;
  final DownloadConverter converter;
  final MergeQueue merges;
  final FocusNode entryFocus;
  final VoidCallback onExitUp;

  @override
  Widget build(BuildContext context) => FadeInOnce(
    child: Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) => switch (AppScope.formFactorOf(context)) {
            FormFactor.phone => _phone(context),
            FormFactor.pad || FormFactor.window => _wide(context),
            FormFactor.television => _television(context),
          },
        ),
      ),
    ),
  );

  void _openDownloads(BuildContext context) => openPage<void>(
    context,
    (_) => DownloadsPage(
      store: store,
      downloads: downloads,
      converter: converter,
      merges: merges,
    ),
  );

  void _openModules(BuildContext context) =>
      openPage<void>(context, (_) => ModulesPage(store: store));

  void _openSettings(BuildContext context) =>
      openPage<void>(context, (_) => SettingsPage(store: store));

  Widget _entries(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 12,
    children: [
      if (store.canDownload)
        _Entry(
          icon: Icons.download_rounded,
          title: '下载',
          onTap: () => _openDownloads(context),
        ),
      _Entry(
        icon: Icons.extension_outlined,
        title: '模块',
        onTap: () => _openModules(context),
      ),
      _Entry(
        icon: Icons.settings_outlined,
        title: '设置',
        onTap: () => _openSettings(context),
      ),
    ],
  );

  Widget _phone(BuildContext context) {
    return ListView(
      // 末尾多留一个胶囊底栏的高度，最后一行能滑到胶囊上方。
      padding: EdgeInsets.only(bottom: 24 + capsuleBarClearance(context)),
      children: [
        const PageHeader(title: '我的'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _entries(context),
        ),
      ],
    );
  }

  Widget _wide(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const PageHeader(title: '我的'),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: _entries(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _television(BuildContext context) {
    const padding = EdgeInsets.fromLTRB(
      televisionInset,
      14,
      televisionInset,
      27,
    );
    final page = SingleChildScrollView(
      padding: padding,
      child: Row(
        spacing: 20,
        children: [
          Expanded(
            child: _TelevisionEntry(
              icon: Icons.extension_outlined,
              title: '模块',
              subtitle: '安装与管理站源模块',
              focusNode: entryFocus,
              onTap: () => _openModules(context),
            ),
          ),
          Expanded(
            child: _TelevisionEntry(
              icon: Icons.settings_outlined,
              title: '设置',
              subtitle: '外观、播放、站源与网络',
              onTap: () => _openSettings(context),
            ),
          ),
        ],
      ),
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is KeyUpEvent ||
            event.logicalKey != LogicalKeyboardKey.arrowUp) {
          return KeyEventResult.ignored;
        }
        final moved = FocusManager.instance.primaryFocus?.focusInDirection(
          TraversalDirection.up,
        );
        if (moved != true) onExitUp();
        return KeyEventResult.handled;
      },
      child: page,
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({required this.icon, required this.title, required this.onTap});
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 20,
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(20),
        child: Material(
          color: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 60,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  spacing: 14,
                  children: [
                    Icon(icon, size: 22, color: colors.onSurfaceVariant),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TelevisionEntry extends StatelessWidget {
  const _TelevisionEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
    this.focusNode,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 20,
      scale: 1,
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(20),
        child: Material(
          color: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            focusNode: focusNode,
            focusColor: Colors.transparent,
            onTap: onTap,
            child: SizedBox(
              height: 84,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  spacing: 16,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: primary
                            ? colors.primaryContainer
                            : colors.secondaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        icon,
                        size: primary ? 26 : 24,
                        color: primary
                            ? colors.onPrimaryContainer
                            : colors.onSecondaryContainer,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 2,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
