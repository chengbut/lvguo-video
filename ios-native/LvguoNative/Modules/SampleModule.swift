import Foundation

/// 内置示例模块（jsexample）：内容与 Flutter 版
/// native/module_example/jsexample 完全一致（假数据、不联网），
/// 只用于验证模块主链路（安装 → 分类 → 列表 → 详情 → 选集）。
/// 注意：示例的 resolveMedia 按原样抛错「只有假数据，不能播放」，
/// 播放链路的端到端验证需要用户安装真实模块后走 resolveMedia → AVPlayer。
enum SampleModule {
    static let manifestJSON = """
{
  "id": "jsexample",
  "name": "JS 示例",
  "version": "1.0.0",
  "description": "纯 JS 模块示例，使用假数据演示模块协议",
  "runtime": "js",
  "api": 1,
  "hosts": [],
  "capabilities": ["search"],
  "adult": false,
  "allowEmptyCatalog": true
}
"""

    static let mainJS = """
function item(category, index) {
  var titles = {
    romance: ['心动信号', '夏日恋人', '总裁的秘密', '缘分天空'],
    suspense: ['迷雾追踪', '暗夜行者', '无声证词', '午夜回声']
  };
  var names = titles[category] || titles.romance;
  return {
    id: category + '-' + index,
    sourceId: category + '-' + index,
    title: names[index % names.length] + ' ' + (index + 1),
    desc: 'JS 示例模块生成的假数据',
    cover: '',
    totalEpisode: 8,
    score: '8.' + (index % 10)
  };
}

function validCategory(category) {
  return category === 'romance' || category === 'suspense';
}

function categories() {
  return [
    { id: 'romance', name: '言情' },
    { id: 'suspense', name: '悬疑' }
  ];
}

function catalogPage(page, category) {
  if (!validCategory(category)) throw new Error('分类无效');
  if (page < 1 || page > 3) return { items: [], hasMore: false };
  var items = [];
  for (var i = 0; i < 12; i++) items.push(item(category, (page - 1) * 12 + i));
  return { items: items, hasMore: page < 3 };
}

function search(page, query) {
  var normalized = String(query || '').trim();
  if (!normalized || page !== 1) return { items: [], hasMore: false };
  return {
    items: [
      {
        id: 'search-1',
        sourceId: 'search-1',
        title: normalized,
        desc: 'JS 示例搜索结果',
        cover: '',
        totalEpisode: 8
      }
    ],
    hasMore: false
  };
}

function detail(sourceId) {
  if (!sourceId) throw new Error('缺少短剧 ID');
  var category = String(sourceId).split('-')[0];
  if (!validCategory(category)) category = 'romance';
  var chapters = [];
  for (var i = 1; i <= 8; i++) {
    chapters.push({
      id: sourceId + '-' + i,
      title: '第' + i + '集',
      currentEpisode: i,
      videoUrl: ''
    });
  }
  var found = item(category, 0);
  found.id = sourceId;
  found.sourceId = sourceId;
  return { drama: found, chapters: chapters };
}

function resolveMedia() {
  throw new Error('JS 示例模块只有假数据，不能播放');
}

exports.validCategory = validCategory;
exports.categories = categories;
exports.catalogPage = catalogPage;
exports.search = search;
exports.detail = detail;
exports.resolveMedia = resolveMedia;
"""
}
