import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'drama_feed.dart';
import 'local_store.dart';
import 'models.dart';
import 'ranking_models.dart';
import 'source_catalog.dart';

const recommendTab = CatalogCategory('app:recommend', '推荐');

CatalogCategory rankingTab(RankingBoard board) =>
    CatalogCategory('app:rank:${board.id}', board.name);

class ExploreFeed extends ChangeNotifier {
  ExploreFeed(this.repository, this.store) {
    store.addListener(_storeChanged);
    repository.catalogUpdates.addListener(_metadataChanged);
    _open();
  }
  final AppRepository repository;
  final LocalStore store;
  SourceCatalog? _catalog;
  CatalogCategory _tab = CatalogCategory.all;
  DramaFeed? _feed;
  final _feeds = <String, DramaFeed>{};
  final _rankings = <String, Map<String, int>>{};
  bool _disposed = false;

  SourceSite? get source => _catalog?.source;
  DramaFeed? get feed => _feed;
  CatalogCategory get tab => _tab;
  bool get recommending => _tab.id == recommendTab.id;

  List<CatalogCategory> get tabs {
    final catalog = _catalog;
    if (catalog == null) return const [];
    final all = catalog.categories.first;
    // 只留推荐 + 模块给的前 3 个榜单；全部与分类 tab 隐藏（代码保留，
    // 只是界面上不显示），榜单少于 2 个时保留全部，避免发现页被掏空。
    final boards = catalog.boards.take(3).toList();
    return [
      if (catalog.recommends) recommendTab,
      if (boards.length < 2) all,
      for (final board in boards) rankingTab(board),
    ];
  }

  int? rankOf(Drama drama) => rankIn(_tab, drama);
  WatchEntry? get resume => resumeIn(_tab);
  Drama? get featured => featuredIn(_tab);
  List<Drama> get items => itemsIn(_tab);

  DramaFeed feedOf(CatalogCategory tab) => _feeds[tab.id] ?? _create(tab);

  int? rankIn(CatalogCategory tab, Drama drama) => _rankings[tab.id]?[drama.id];

  WatchEntry? resumeIn(CatalogCategory tab) {
    final source = this.source;
    if (source == null || tab.id != tabs.first.id) return null;
    return store.history
        .where((entry) => entry.drama.source == source.id)
        .firstOrNull;
  }

  Drama? featuredIn(CatalogCategory tab) =>
      tab.id == recommendTab.id && resumeIn(tab) == null
      ? _orderedRecommendItems().firstOrNull
      : null;

  List<Drama> itemsIn(CatalogCategory tab) {
    final items = tab.id == recommendTab.id
        ? _orderedRecommendItems()
        : _feeds[tab.id]?.items ?? const <Drama>[];
    return featuredIn(tab) == null ? items : items.skip(1).toList();
  }

  // 换一换后的推荐展示顺序（null 表示按模块原顺序展示）。
  List<Drama>? _shuffled;
  // 上一批换出来的剧 id，下次抽样时排除，避免连续两次重复。
  Set<String> _lastBatchIds = {};
  bool _shuffling = false;
  bool get shuffling => _shuffling;

  List<Drama> _orderedRecommendItems() {
    final items = _feeds[recommendTab.id]?.items ?? const <Drama>[];
    final shuffled = _shuffled;
    if (shuffled == null) return items;
    final known = {for (final drama in shuffled) drama.id};
    return [
      ...shuffled,
      // 后加载/加载更多的内容跟在后面，不丢内容。
      for (final drama in items)
        if (known.add(drama.id)) drama,
    ];
  }

  /// 换一换：本地随机重排推荐。
  ///
  /// 随机池优先用源模块的榜单（现成的热度数据），按排名加权抽样——越热
  /// 的剧出现概率越高；没有榜单时退回普通随机。每次抽出的这一批排除
  /// 上一批刚展示过的；池子不够大时允许重叠，但顺序仍会打乱。
  Future<void> shuffleRecommendations() async {
    final catalog = _catalog;
    if (catalog == null || !recommending || _shuffling) return;
    _shuffling = true;
    _notify();
    try {
      final weighted = <({Drama drama, double weight})>[];
      final seen = <String>{};
      for (final board in catalog.boards.take(3)) {
        try {
          final page = await catalog.ranking(board, page: 1);
          final count = page.items.length;
          for (final item in page.items) {
            if (item.drama.id.isEmpty || !seen.add(item.drama.id)) continue;
            weighted.add((
              drama: item.drama,
              weight: (count - item.rank + 1).toDouble(),
            ));
          }
        } catch (_) {}
      }
      // 当前推荐列表作补充池，基础权重。
      final feed = _feeds[recommendTab.id];
      if (feed != null) {
        for (final drama in feed.items) {
          if (seen.add(drama.id)) weighted.add((drama: drama, weight: 1));
        }
      }
      if (weighted.isEmpty) return;
      final fresh = weighted
          .where((entry) => !_lastBatchIds.contains(entry.drama.id))
          .toList();
      final candidates = fresh.isNotEmpty ? fresh : weighted;
      final feedCount = feed?.items.length ?? 0;
      final batchSize = (feedCount > 0 ? feedCount : 20).clamp(10, 20);
      final batch = _weightedSample(candidates, batchSize);
      if (batch.isEmpty) return;
      _lastBatchIds = {for (final drama in batch) drama.id};
      _shuffled = batch;
    } finally {
      _shuffling = false;
      _notify();
    }
  }

  List<Drama> _weightedSample(
    List<({Drama drama, double weight})> entries,
    int count,
  ) {
    final pool = List.of(entries);
    final result = <Drama>[];
    final random = math.Random();
    while (result.length < count && pool.isNotEmpty) {
      var total = 0.0;
      for (final entry in pool) total += entry.weight;
      var roll = random.nextDouble() * total;
      var picked = pool.length - 1;
      for (var i = 0; i < pool.length; i++) {
        roll -= pool[i].weight;
        if (roll <= 0) {
          picked = i;
          break;
        }
      }
      result.add(pool.removeAt(picked).drama);
    }
    return result;
  }

  void select(String id) {
    if (id == _tab.id) return;
    final tab = tabs.where((tab) => tab.id == id).firstOrNull;
    if (tab != null) _select(tab);
  }

  Future<void> refresh() async {
    // 下拉刷新向模块要新一批，换一换的旧顺序作废。
    _shuffled = null;
    _lastBatchIds = {};
    final catalog = _catalog;
    if (catalog == null) return;
    if (catalog.categories.length == 1) {
      unawaited(_loadCategories(catalog, force: true));
    }
    await _feed?.reload(force: true);
  }

  void _open() {
    final id = store.source;
    if (id == _catalog?.source.id) return;
    unawaited(repository.cancelCatalog());
    unawaited(repository.cancelRecommendations());
    _dropFeeds();
    if (id.isEmpty) {
      _catalog = null;
      return;
    }
    final catalog = _catalog = SourceCatalog(repository, SourceSite.byId(id));
    _select(catalog.recommends ? recommendTab : CatalogCategory.all);
    unawaited(_loadCategories(catalog));
  }

  Future<void> _loadCategories(
    SourceCatalog catalog, {
    bool force = false,
  }) async {
    try {
      await catalog.loadCategories(force: force);
    } catch (_) {}
    if (_disposed || catalog != _catalog) return;
    _prefetch();
    _notify();
    // 榜单加载后，当前 tab 可能已被隐藏（全部/分类），切到第一个可见 tab。
    if (tabs.isNotEmpty && !tabs.any((tab) => tab.id == _tab.id)) {
      _select(tabs.first);
    }
  }

  void _select(CatalogCategory tab) {
    if (recommending) unawaited(repository.cancelRecommendations());
    _tab = tab;
    final kept = _feeds[tab.id];
    final feed = _feed = kept ?? _create(tab);
    if (feed.items.isEmpty && !feed.loading) unawaited(feed.reload());
    _prefetch();
    _notify();
  }

  DramaFeed _create(CatalogCategory tab) {
    final catalog = _catalog!;
    final board = catalog.boards
        .where((board) => rankingTab(board).id == tab.id)
        .firstOrNull;
    final ranks = _rankings[tab.id] = <String, int>{};
    final feed = _feeds[tab.id] = tab.id == recommendTab.id
        ? DramaFeed(
            cumulative: true,
            load: (page, force) =>
                _saved(catalog.recommendations(more: page > 1, force: force)),
          )
        : board != null
        ? DramaFeed(
            load: (page, force) =>
                _saved(_ranking(catalog, board, ranks, page, force)),
          )
        : DramaFeed(
            cached: () => catalog.cached(tab),
            load: (page, force) => _saved(
              catalog.fetch(tab, page: page, lane: _lane(tab), force: force),
            ),
          );
    unawaited(feed.reload());
    feed.addListener(_feedChanged);
    return feed;
  }

  String _lane(CatalogCategory tab) {
    if (tab.id == _tab.id) return '';
    final tabs = this.tabs;
    final index = tabs.indexWhere((item) => item.id == tab.id);
    final current = tabs.indexWhere((item) => item.id == _tab.id);
    return index < current ? 'behind' : 'ahead';
  }

  void _feedChanged() {
    _prefetch();
    _notify();
  }

  void _prefetch() {
    final feed = _feed;
    if (feed == null ||
        feed.loading ||
        feed.loadingMore ||
        feed.items.isEmpty ||
        feed.error.isNotEmpty) {
      return;
    }
    final tabs = this.tabs;
    final index = tabs.indexWhere((tab) => tab.id == _tab.id);
    if (index < 0) return;
    for (final neighbor in [index - 1, index + 1]) {
      if (neighbor < 0 || neighbor >= tabs.length) continue;
      final tab = tabs[neighbor];
      if (_feeds.containsKey(tab.id)) continue;
      _create(tab);
    }
  }

  Future<CatalogPage> _ranking(
    SourceCatalog catalog,
    RankingBoard board,
    Map<String, int> ranks,
    int page,
    bool force,
  ) async {
    final result = await catalog.ranking(board, page: page, force: force);
    for (final item in result.items) {
      ranks[item.drama.id] = item.rank;
    }
    return CatalogPage(
      [for (final item in result.items) item.drama],
      hasMore: result.hasMore,
      warning: result.warning,
      page: result.page,
    );
  }

  Future<CatalogPage> _saved(Future<CatalogPage> request) async {
    final page = await request;
    unawaited(store.refreshDramas(page.items).catchError((Object _) {}));
    return page;
  }

  void _storeChanged() {
    _open();
    _notify();
  }

  void _metadataChanged() {
    final drama = repository.catalogUpdates.latest;
    if (drama == null || drama.source != source?.id) return;
    _catalog?.remember([drama]);
    for (final feed in _feeds.values) {
      feed.update(drama);
    }
    unawaited(store.refreshDrama(drama).catchError((Object _) {}));
  }

  void _dropFeeds() {
    _shuffled = null;
    _lastBatchIds = {};
    for (final feed in _feeds.values) {
      feed.dispose();
    }
    _feeds.clear();
    _rankings.clear();
    _feed = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_storeChanged);
    repository.catalogUpdates.removeListener(_metadataChanged);
    _dropFeeds();
    unawaited(repository.cancelCatalog());
    unawaited(repository.cancelRecommendations());
    super.dispose();
  }
}
