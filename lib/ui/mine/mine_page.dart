import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../download_converter.dart';
import '../../merge_queue.dart';
import '../../download_overview.dart';
import '../../local_store.dart';
import '../app_scope.dart';
import '../downloads/downloads_page.dart';
import '../shell/app_shell.dart';
import '../settings/settings_page.dart';
import '../settings/settings_sections.dart';
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

  void _openSettingsGroup(BuildContext context, SettingsGroup group) =>
      openPage<void>(
        context,
        (_) => SettingsGroupPage(store: store, group: group),
      );

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
      // 原设置页的 8 个组，按设置页里的顺序排在「下载」后面；
      // 点进去是直开子页面的 SettingsGroupPage，和原来一样。
      // 注意这里的「下载」是下载设置（默认画质、VIP 集、同时下载数量），
      // 上面那个「下载」是下载管理（已下载的剧），目的地不同，两个都留着，
      // 副标题能区分。
      for (final group in SettingsGroup.values)
        if (group.visible)
          _Entry(
            icon: group.icon,
            title: group.label,
            subtitle: settingsGroupSummary(context, store, group),
            onTap: () => _openSettingsGroup(context, group),
          ),
    ],
  );

  Widget _phone(BuildContext context) {
    return ListView(
      // 末尾多留一个胶囊底栏的高度，最后一行能滑到胶囊上方。
      // 40 的余量：末卡滑到底时卡底离胶囊顶还有一段空隙，不会贴着盖住。
      padding: EdgeInsets.only(bottom: 40 + capsuleBarClearance(context)),
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
    // 电视端没有设置列表页了：8 个设置组卡片排成 Wrap，
    // 一行排不下自动换行（卡片宽 320，1080p 上一行 5 张）。
    // 模块入口已删（底栏已有模块键），焦点落在第一张设置组卡片上。
    final groups = [
      for (final group in SettingsGroup.values)
        if (group.visible) group,
    ];
    final page = SingleChildScrollView(
      padding: padding,
      child: Wrap(
        spacing: 20,
        runSpacing: 20,
        children: [
          for (final (index, group) in groups.indexed)
            SizedBox(
              width: 320,
              child: _TelevisionEntry(
                icon: group.icon,
                title: group.label,
                subtitle: settingsGroupSummary(context, store, group),
                focusNode: index == 0 ? entryFocus : null,
                onTap: () => _openSettingsGroup(context, group),
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
  const _Entry({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final subtitle = this.subtitle;
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
              height: subtitle == null ? 60 : 72,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  spacing: 14,
                  children: [
                    Icon(icon, size: 22, color: colors.onSurfaceVariant),
                    Expanded(
                      child: subtitle == null
                          ? Text(
                              title,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
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
