import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 文件源类型：
/// - tianyi / mobile：天翼云盘、中国移动云盘。两种接法：WebDAV 挂载
///   （Alist / CloudDrive2 转出地址）或原生登录（实验，见 [TianyiSourceClient]
///   / [MobileSourceClient]），由 [FileSource.mode] 区分。
/// - webdav：普通 WebDAV 服务器。
/// - http：单个媒体文件的直链拉取。
/// - ftp：FTP 服务器（纯 dart:io 手写客户端，见 [FtpSourceClient]）。
enum FileSourceType {
  tianyi('天翼云盘'),
  mobile('中国移动云盘'),
  webdav('WebDAV'),
  http('HTTP 拉取'),
  ftp('FTP');

  const FileSourceType(this.label);
  final String label;

  static FileSourceType byName(String name) => values.firstWhere(
    (type) => type.name == name,
    orElse: () => FileSourceType.webdav,
  );
}

/// 文件源的登录/挂载方式（存 [FileSource.mode]）：WebDAV 挂载。
const fileSourceModeWebDav = 'webdav';

/// 文件源的登录/挂载方式：原生登录（实验，仅天翼/中国移动）。
const fileSourceModeNative = 'native';

class FileSource {
  const FileSource({
    required this.id,
    required this.name,
    required this.type,
    this.server = '',
    this.username = '',
    this.password = '',
    this.url = '',
    this.mode = fileSourceModeWebDav,
    this.cookie = '',
    this.port = 0,
    this.path = '',
  });
  final String id;
  final String name;
  final FileSourceType type;
  final String server;
  final String username;
  final String password;
  final String url;

  /// 接入方式：[fileSourceModeWebDav]（默认）或 [fileSourceModeNative]。
  final String mode;

  /// 原生登录（实验）的凭据：天翼是 Cookie 整段；移动是 Authorization
  /// 里 Basic 后面的内容（或整段 Cookie，客户端按形态自动判断）。
  final String cookie;

  /// FTP 端口（0 = 默认 21）。
  final int port;

  /// FTP 初始目录（默认根目录）。
  final String path;

  /// 是否走原生登录（实验）：仅天翼/中国移动且 mode 为 native。
  bool get nativeMode =>
      (type == FileSourceType.tianyi || type == FileSourceType.mobile) &&
      mode == fileSourceModeNative;

  /// 是否走 WebDAV 客户端浏览（含天翼/移动的 WebDAV 挂载模式）。
  bool get usesWebDav =>
      !nativeMode &&
      type != FileSourceType.http &&
      type != FileSourceType.ftp;

  /// 卡片第二行显示的主机。
  String get host {
    if (nativeMode) {
      return type == FileSourceType.tianyi ? 'cloud.189.cn' : 'yun.139.com';
    }
    if (type == FileSourceType.ftp) {
      final effective = port == 0 ? 21 : port;
      return effective == 21 ? server : '$server:$effective';
    }
    final raw = usesWebDav ? server : url;
    final uri = Uri.tryParse(raw);
    return uri != null && uri.host.isNotEmpty ? uri.host : raw;
  }

  Map<String, String> get authHeaders {
    if (username.isEmpty) return const {};
    final token = base64Encode(utf8.encode('$username:$password'));
    return {'Authorization': 'Basic $token'};
  }

  /// 原生凭据做一次宽容清洗：去掉用户可能连带粘进来的 "Cookie:" 前缀
  /// 和首尾空白/引号。
  String get credential {
    var value = cookie.trim();
    if (value.toLowerCase().startsWith('cookie:')) {
      value = value.substring(7).trim();
    }
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1).trim();
    }
    return value;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'server': server,
    'username': username,
    'password': password,
    'url': url,
    'mode': mode,
    'cookie': cookie,
    'port': port,
    'path': path,
  };

  factory FileSource.fromJson(Map<String, dynamic> json) => FileSource(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    type: FileSourceType.byName(json['type'] as String? ?? ''),
    server: json['server'] as String? ?? '',
    username: json['username'] as String? ?? '',
    password: json['password'] as String? ?? '',
    url: json['url'] as String? ?? '',
    mode: json['mode'] as String? ?? fileSourceModeWebDav,
    cookie: json['cookie'] as String? ?? '',
    port: (json['port'] as num?)?.toInt() ?? 0,
    path: json['path'] as String? ?? '',
  );
}

/// 文件播放进度：以文件定位键为索引的独立记录。剧集历史（LocalStore
/// 的 WatchEntry）强校验站源，文件源塞不进去，所以文件播放单独存
/// 这里；除续播外，历史页的「文件」分组也读这份数据展示。
class FileProgress {
  const FileProgress({
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.title = '',
    this.sourceName = '',
    this.sourceId = '',
    this.url = '',
    this.ref = '',
  });
  final double position;
  final double duration;
  final DateTime updatedAt;

  /// 显示名（文件名）、来源文件源名/ID：历史页分组展示用。
  final String title;
  final String sourceName;
  final String sourceId;

  /// 最近一次取到的可播放地址（WebDAV/HTTP 是稳定地址；原生网盘是
  /// 临时地址，可能已过期，只作兜底）。
  final String url;

  /// 重新取址用的定位符：原生网盘是文件 ID，FTP 是绝对路径；
  /// WebDAV/HTTP 为空（地址本身就是定位符）。
  final String ref;

  bool get finished => duration > 1 && position >= duration - 1;

  Map<String, dynamic> toJson() => {
    'position': position,
    'duration': duration,
    'updatedAt': updatedAt.toIso8601String(),
    'title': title,
    'sourceName': sourceName,
    'sourceId': sourceId,
    'url': url,
    'ref': ref,
  };

  factory FileProgress.fromJson(Map<String, dynamic> json) => FileProgress(
    position: (json['position'] as num?)?.toDouble() ?? 0,
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    updatedAt: DateTime.tryParse('${json['updatedAt']}') ?? DateTime(2000),
    title: json['title'] as String? ?? '',
    sourceName: json['sourceName'] as String? ?? '',
    sourceId: json['sourceId'] as String? ?? '',
    url: json['url'] as String? ?? '',
    ref: json['ref'] as String? ?? '',
  );
}

/// 历史页「文件」分组的一行：进度键 + 记录本体。
class FileHistoryRecord {
  const FileHistoryRecord({required this.key, required this.progress});
  final String key;
  final FileProgress progress;
}

class FileSourceStore extends ChangeNotifier {
  FileSourceStore._(this._preferences) {
    _load();
  }

  static FileSourceStore? _shared;

  /// 全 App 共用一份：资源页和发现页文件源模式读的是同一份数据。
  static FileSourceStore instance(SharedPreferences preferences) =>
      _shared ??= FileSourceStore._(preferences);

  static const _sourcesKey = 'fileSources.v1';
  static const _progressKey = 'fileProgress.v1';

  final SharedPreferences _preferences;
  List<FileSource> _sources = [];
  Map<String, FileProgress> _progress = {};

  List<FileSource> get sources => List.unmodifiable(_sources);

  FileSource? sourceById(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  /// 全部文件播放记录，按最近播放倒序（历史页「文件」分组用）。
  List<FileHistoryRecord> get records {
    final rows = [
      for (final entry in _progress.entries)
        FileHistoryRecord(key: entry.key, progress: entry.value),
    ]..sort((a, b) => b.progress.updatedAt.compareTo(a.progress.updatedAt));
    return rows;
  }

  void _load() {
    try {
      final raw = _preferences.getString(_sourcesKey);
      if (raw != null) {
        final rows = jsonDecode(raw) as List;
        _sources = [
          for (final row in rows)
            FileSource.fromJson(Map<String, dynamic>.from(row as Map)),
        ];
      }
    } catch (_) {
      _sources = [];
    }
    try {
      final raw = _preferences.getString(_progressKey);
      if (raw != null) {
        final rows = jsonDecode(raw) as Map;
        _progress = {
          for (final entry in rows.entries)
            entry.key: FileProgress.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
        };
      }
    } catch (_) {
      _progress = {};
    }
  }

  Future<void> _saveSources() async {
    await _preferences.setString(
      _sourcesKey,
      jsonEncode([for (final source in _sources) source.toJson()]),
    );
    notifyListeners();
  }

  Future<void> add(FileSource source) async {
    _sources = [..._sources, source];
    await _saveSources();
  }

  Future<void> remove(String id) async {
    _sources = [for (final source in _sources) if (source.id != id) source];
    await _saveSources();
  }

  FileProgress? progressFor(String key) => _progress[key];

  Future<void> _saveProgressMap() async {
    await _preferences.setString(
      _progressKey,
      jsonEncode({
        for (final entry in _progress.entries) entry.key: entry.value.toJson(),
      }),
    );
    notifyListeners();
  }

  Future<void> saveProgress(
    String key, {
    required double position,
    required double duration,
    String? title,
    String? sourceName,
    String? sourceId,
    String? url,
    String? ref,
  }) async {
    final previous = _progress[key];
    _progress = {
      ..._progress,
      key: FileProgress(
        position: position,
        duration: duration,
        updatedAt: DateTime.now(),
        title: title ?? previous?.title ?? '',
        sourceName: sourceName ?? previous?.sourceName ?? '',
        sourceId: sourceId ?? previous?.sourceId ?? '',
        url: url ?? previous?.url ?? '',
        ref: ref ?? previous?.ref ?? '',
      ),
    };
    // 只留最近 300 条，和剧集历史一个量级。
    if (_progress.length > 300) {
      final sorted = _progress.entries.toList()
        ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
      _progress = Map.fromEntries(sorted.take(300));
    }
    await _saveProgressMap();
  }

  Future<void> removeProgress(String key) async {
    if (!_progress.containsKey(key)) return;
    _progress = {..._progress}..remove(key);
    await _saveProgressMap();
  }

  Future<void> clearProgress() async {
    if (_progress.isEmpty) return;
    _progress = {};
    await _saveProgressMap();
  }
}

String newFileSourceId() => '${DateTime.now().microsecondsSinceEpoch}';

/// 文件源目录里的一项：文件夹或文件。[href] 是定位符——WebDAV 是
/// 服务器绝对路径（URL 编码形态），FTP 是绝对路径（原始形态），
/// 原生网盘是文件/文件夹 ID；name 是显示名。
class FileEntry {
  const FileEntry({
    required this.name,
    required this.href,
    required this.isDirectory,
    this.contentType = '',
    this.size = 0,
  });
  final String name;
  final String href;
  final bool isDirectory;
  final String contentType;
  final int size;

  bool get isVideo {
    if (isDirectory) return false;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return contentType.startsWith('video/');
    return videoExtensions.contains(name.substring(dot + 1).toLowerCase());
  }
}

/// 旧名兼容（v2.0.0 的浏览页按这个名字写的）。
typedef WebDavEntry = FileEntry;

const videoExtensions = {
  'mp4',
  'mkv',
  'mov',
  'avi',
  'ts',
  'm3u8',
  'webm',
  'flv',
  'rmvb',
};

/// 一次取址结果：可直接交给播放器的地址 + 请求头。原生网盘的地址
/// 有时效，所以每次点播现取，不缓存。
class FilePlayTarget {
  const FilePlayTarget({required this.url, this.headers = const {}});
  final String url;
  final Map<String, String> headers;
}

/// 播放页的一个条目：标题 + 进度键 + 定位符 + 现取地址的回调。
/// 浏览页把当前文件夹的全部视频做成一个列表传给播放页做上/下一。
class FilePlayItem {
  const FilePlayItem({
    required this.title,
    required this.progressKey,
    required this.ref,
    required this.loadTarget,
  });
  final String title;
  final String progressKey;
  final String ref;
  final Future<FilePlayTarget> Function() loadTarget;
}

/// 文件源客户端统一接口：浏览页只认这个接口，不感知底层是
/// WebDAV、FTP 还是原生网盘。
abstract class FileSourceClient {
  /// 列 [path] 目录（null = 源根目录）。
  Future<List<FileEntry>> list(String? path);

  /// 取 [entry] 的可播放地址（原生网盘现取临时地址）。
  Future<FilePlayTarget> target(FileEntry entry);

  /// [entry] 的进度键：WebDAV 是解析后的完整 URL，FTP/原生是
  /// 「src:<源ID>:<类型>:<定位符>」，保证换地址也能续上同一条进度。
  String progressKey(FileEntry entry);

  /// 把一个视频条目包成播放页要的 [FilePlayItem]。
  FilePlayItem playItem(FileEntry entry) => FilePlayItem(
    title: entry.name,
    progressKey: progressKey(entry),
    ref: entry.href,
    loadTarget: () => target(entry),
  );
}

FileSourceClient createFileSourceClient(FileSource source) {
  if (source.nativeMode) {
    return source.type == FileSourceType.tianyi
        ? TianyiSourceClient(source)
        : MobileSourceClient(source);
  }
  if (source.type == FileSourceType.ftp) return FtpSourceClient(source);
  return WebDavSourceClient(source);
}

class FileSourceFailure implements Exception {
  FileSourceFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

String excerptText(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 180 ? flat : '${flat.substring(0, 180)}…';
}

/// 原生网盘客户端共用的 JSON 请求：非 200、非 JSON、网络错误都翻成
/// [FileSourceFailure]，且带上服务器原始返回片段方便调试。
Future<Map<String, dynamic>> jsonRequest(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  Object? body,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 20));
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(
      const Duration(seconds: 25),
    );
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw FileSourceFailure(
        '服务器返回 ${response.statusCode}：${excerptText(text)}',
      );
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 落到下面的统一报错。
    }
    throw FileSourceFailure('服务器返回了无法解析的内容：${excerptText(text)}');
  } on FileSourceFailure {
    rethrow;
  } on SocketException {
    throw FileSourceFailure('连不上服务器，请检查网络');
  } on TimeoutException {
    throw FileSourceFailure('连接超时，请检查网络');
  } finally {
    client.close(force: true);
  }
}

const _browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

// ---------------------------------------------------------------------------
// WebDAV
// ---------------------------------------------------------------------------

/// 极简 WebDAV 客户端：只做 PROPFIND 列目录。dart:io 的 HttpClient
/// 直接发 PROPFIND 方法，响应 XML 去掉命名空间前缀后正则解析，
/// 不引任何新依赖。
class WebDavClient {
  WebDavClient(this.source);
  final FileSource source;

  Uri get _base {
    var server = source.server.trim();
    if (!server.contains('://')) server = 'http://$server';
    return Uri.parse(server);
  }

  /// 把一个 href 拼成完整 URL。href 可能是：服务器绝对路径（多半
  /// 是这种）、完整 URL（只取它的路径）、或相对路径（按源根目录
  /// 所在目录解析）。href 是 URL 编码形态，这里先解码再交给
  /// [Uri] 统一编码，避免中文/空格被二次编码（%25）。
  Uri resolve(String href) {
    final base = _base;
    var path = href;
    final parsed = Uri.tryParse(href);
    if (parsed != null && parsed.hasScheme) path = parsed.path;
    if (!path.startsWith('/')) {
      var dir = base.path;
      if (!dir.endsWith('/')) {
        final cut = dir.lastIndexOf('/');
        dir = cut >= 0 ? dir.substring(0, cut + 1) : '/';
      }
      path = '$dir$path';
    }
    String decoded;
    try {
      decoded = Uri.decodeComponent(path);
    } catch (_) {
      decoded = path;
    }
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: decoded,
    );
  }

  /// 列 [href] 目录（null 表示源根目录，即服务器地址本身）。
  Future<List<FileEntry>> list(String? href) async {
    final target = href == null ? _base : resolve(href);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .openUrl('PROPFIND', target)
          .timeout(const Duration(seconds: 20));
      request.headers.set('Depth', '1');
      for (final entry in source.authHeaders.entries) {
        request.headers.set(entry.key, entry.value);
      }
      request.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
      request.write(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<propfind xmlns="DAV:"><prop>'
        '<displayname/><resourcetype/><getcontenttype/><getcontentlength/>'
        '</prop></propfind>',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 401) {
        throw FileSourceFailure('账号或密码不正确（服务器返回 401）');
      }
      if (response.statusCode != 207 && response.statusCode != 200) {
        throw FileSourceFailure('服务器返回 ${response.statusCode}，无法列出目录');
      }
      return parsePropfind(body, target: target);
    } on FileSourceFailure {
      rethrow;
    } on SocketException {
      throw FileSourceFailure('连不上服务器，请检查地址和网络');
    } on TimeoutException {
      throw FileSourceFailure('连接超时，请检查地址和网络');
    } finally {
      client.close(force: true);
    }
  }

  /// 解析 multistatus 响应。先把 <D:href> 这类带前缀的标签统一成
  /// <href>，再逐个 <response> 块取字段。每条 href 先归一成绝对
  /// 路径（相对路径按本次请求目录解析），当前目录自身那条跳过——
  /// 自身判断在解码后比较，忽略结尾斜杠差异。
  static List<FileEntry> parsePropfind(String xml, {required Uri target}) {
    final plain = xml.replaceAllMapped(
      RegExp(r'<(/?)[A-Za-z0-9]+:'),
      (match) => '<${match[1]}',
    );
    String field(String block, String tag) {
      final match = RegExp('<$tag>([^<]*)</$tag>').firstMatch(block);
      return match == null ? '' : match.group(1)!.trim();
    }

    String normalize(String path) {
      var value = path;
      try {
        value = Uri.decodeComponent(value);
      } catch (_) {
        // 解不开就按原样比。
      }
      if (value.length > 1 && value.endsWith('/')) {
        value = value.substring(0, value.length - 1);
      }
      return value;
    }

    final selfPath = normalize(target.path);
    final entries = <FileEntry>[];
    for (final match in RegExp(
      r'<response>(.*?)</response>',
      dotAll: true,
    ).allMatches(plain)) {
      final block = match.group(1)!;
      final rawHref = field(block, 'href');
      if (rawHref.isEmpty) continue;
      var path = rawHref;
      final parsed = Uri.tryParse(rawHref);
      if (parsed != null && parsed.hasScheme) path = parsed.path;
      if (!path.startsWith('/')) {
        var dir = target.path;
        if (!dir.endsWith('/')) {
          final cut = dir.lastIndexOf('/');
          dir = cut >= 0 ? dir.substring(0, cut + 1) : '/';
        }
        path = '$dir$path';
      }
      if (normalize(path) == selfPath) continue;
      final isDirectory = block.contains('<collection');
      var name = field(block, 'displayname');
      if (name.isEmpty) {
        final decoded = normalize(path);
        name = decoded.split('/').last;
      } else {
        try {
          name = Uri.decodeComponent(name);
        } catch (_) {}
      }
      entries.add(
        FileEntry(
          name: name,
          href: path,
          isDirectory: isDirectory,
          contentType: field(block, 'getcontenttype'),
          size: int.tryParse(field(block, 'getcontentlength')) ?? 0,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }
}

/// WebDAV 客户端的统一接口包装（含天翼/移动的 WebDAV 挂载模式）。
class WebDavSourceClient implements FileSourceClient {
  WebDavSourceClient(this.source) : _dav = WebDavClient(source);
  final FileSource source;
  final WebDavClient _dav;

  @override
  Future<List<FileEntry>> list(String? path) => _dav.list(path);

  @override
  Future<FilePlayTarget> target(FileEntry entry) async => FilePlayTarget(
    url: _dav.resolve(entry.href).toString(),
    headers: source.authHeaders,
  );

  @override
  String progressKey(FileEntry entry) => _dav.resolve(entry.href).toString();

  @override
  FilePlayItem playItem(FileEntry entry) => FilePlayItem(
    title: entry.name,
    progressKey: progressKey(entry),
    ref: entry.href,
    loadTarget: () => target(entry),
  );
}

// ---------------------------------------------------------------------------
// FTP（纯 dart:io Socket 手写最小客户端）
// ---------------------------------------------------------------------------

/// FTP 浏览客户端：每次列目录开一条新连接（USER/PASS 登录、PASV
/// 被动模式、LIST 解析 Unix/DOS 两种格式），用完即断，简单可靠。
/// 播放走 ftp://user:pass@host/path 形式交给播放器（mpv/ffmpeg 的
/// libavformat 自带 ftp 协议）。
class FtpSourceClient implements FileSourceClient {
  FtpSourceClient(this.source);
  final FileSource source;

  int get _port => source.port == 0 ? 21 : source.port;

  String get rootPath {
    var path = source.path.trim();
    if (path.isEmpty) return '/';
    if (!path.startsWith('/')) path = '/$path';
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  @override
  Future<List<FileEntry>> list(String? path) async {
    final dir = path ?? rootPath;
    final connection = await _FtpConnection.connect(
      host: source.server.trim(),
      port: _port,
      username: source.username,
      password: source.password,
    );
    try {
      final lines = await connection.list(dir);
      return parseFtpList(lines, dir: dir);
    } finally {
      await connection.close();
    }
  }

  @override
  Future<FilePlayTarget> target(FileEntry entry) async =>
      FilePlayTarget(url: playUrl(entry.href));

  @override
  String progressKey(FileEntry entry) =>
      'src:${source.id}:ftp:${entry.href}';

  @override
  FilePlayItem playItem(FileEntry entry) => FilePlayItem(
    title: entry.name,
    progressKey: progressKey(entry),
    ref: entry.href,
    loadTarget: () => target(entry),
  );

  /// ftp:// 播放地址：账号密码做 URL 编码，路径逐段编码。
  String playUrl(String path) {
    final userInfo = source.username.isEmpty
        ? null
        : '${Uri.encodeComponent(source.username)}:${Uri.encodeComponent(source.password)}';
    return Uri(
      scheme: 'ftp',
      userInfo: userInfo,
      host: source.server.trim(),
      port: _port == 21 ? null : _port,
      pathSegments: [
        for (final segment in path.split('/'))
          if (segment.isNotEmpty) segment,
      ],
    ).toString();
  }

  /// 解析 LIST 输出（Unix 格式为主，兼 DOS 格式）。[dir] 是本次列
  /// 的目录，条目的 href 拼成绝对路径（原始形态，不编码）。
  static List<FileEntry> parseFtpList(List<String> lines, {required String dir}) {
    final unix = RegExp(
      r'^([bcdlps-])[\wxsStT-]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+'
      r'\w{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})\s+(.+)$',
    );
    final dos = RegExp(
      r'^\d{2}-\d{2}-\d{2,4}\s+\d{1,2}:\d{2}\s*(?:AM|PM)\s+'
      r'(<DIR>|\d+)\s+(.+)$',
      caseSensitive: false,
    );
    final entries = <FileEntry>[];
    for (final raw in lines) {
      final line = raw.trimRight();
      String? name;
      var isDirectory = false;
      var size = 0;
      final unixMatch = unix.firstMatch(line);
      if (unixMatch != null) {
        isDirectory = unixMatch.group(1) == 'd';
        size = int.tryParse(unixMatch.group(2)!) ?? 0;
        name = unixMatch.group(3)!;
        // 软链接写作 "name -> target"，只取名字、按文件处理。
        final arrow = name.indexOf(' -> ');
        if (arrow >= 0) name = name.substring(0, arrow);
      } else {
        final dosMatch = dos.firstMatch(line);
        if (dosMatch == null) continue;
        isDirectory = dosMatch.group(1)!.toUpperCase() == '<DIR>';
        size = int.tryParse(dosMatch.group(1)!) ?? 0;
        name = dosMatch.group(2)!;
      }
      if (name.isEmpty || name == '.' || name == '..') continue;
      entries.add(
        FileEntry(
          name: name,
          href: dir == '/' ? '/$name' : '$dir/$name',
          isDirectory: isDirectory,
          size: size,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }
}

class _FtpLineQueue {
  final _pending = <String>[];
  final _waiters = <Completer<String>>[];
  Object? _failure;

  void add(String line) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(line);
    } else {
      _pending.add(line);
    }
  }

  void fail(Object error) {
    _failure = error;
    for (final waiter in _waiters) {
      waiter.completeError(error);
    }
    _waiters.clear();
  }

  Future<String> next() {
    final failure = _failure;
    if (failure != null) return Future.error(failure);
    if (_pending.isNotEmpty) return Future.value(_pending.removeAt(0));
    final completer = Completer<String>();
    _waiters.add(completer);
    return completer.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw FileSourceFailure('FTP 服务器响应超时'),
    );
  }
}

class _FtpConnection {
  _FtpConnection._(this._socket, this._queue);
  final Socket _socket;
  final _FtpLineQueue _queue;

  static Future<_FtpConnection> connect({
    required String host,
    required int port,
    required String username,
    required String password,
  }) async {
    Socket socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 15),
      );
    } on SocketException {
      throw FileSourceFailure('连不上 FTP 服务器，请检查主机和网络');
    }
    socket.encoding = utf8;
    final queue = _FtpLineQueue();
    final subscription = utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          queue.add,
          onError: (Object error) =>
              queue.fail(FileSourceFailure('FTP 连接出错：$error')),
          onDone: () => queue.fail(FileSourceFailure('FTP 连接已断开')),
        );
    final connection = _FtpConnection._(socket, queue);
    try {
      await connection._expect(const {220});
      final user = await connection._command(
        'USER ${username.isEmpty ? 'anonymous' : username}',
        ok: null,
      );
      if (user == 331) {
        connection._expect2(
          await connection._raw('PASS $password'),
          const {230},
          '账号或密码不正确',
        );
      } else if (user != 230) {
        throw FileSourceFailure('FTP 登录失败（服务器返回 $user）');
      }
      // UTF8 路径与二进制传输：个别服务器不支持，失败就忽略。
      await connection._command('OPTS UTF8 ON', ok: null);
      await connection._command('TYPE I', ok: null);
      return connection;
    } catch (_) {
      unawaited(subscription.cancel());
      socket.destroy();
      rethrow;
    }
  }

  Future<(int, String)> _readResponse() async {
    final first = await _queue.next();
    final match = RegExp(r'^(\d{3})([ -])').firstMatch(first);
    if (match == null) {
      throw FileSourceFailure('FTP 服务器响应异常：${excerptText(first)}');
    }
    final code = int.parse(match.group(1)!);
    final lines = [first];
    if (match.group(2) == '-') {
      while (true) {
        final line = await _queue.next();
        lines.add(line);
        if (line.startsWith('$code ')) break;
      }
    }
    return (code, lines.join('\n'));
  }

  Future<int> _raw(String command) async {
    _socket.write('$command\r\n');
    final (code, _) = await _readResponse();
    return code;
  }

  /// 发命令并读响应；ok 为 null 表示不校验状态码。
  Future<int> _command(String command, {required Set<int>? ok}) async {
    final code = await _raw(command);
    if (ok != null && !ok.contains(code)) {
      throw FileSourceFailure('FTP 命令被拒绝（$code）：$command');
    }
    return code;
  }

  Future<void> _expect(Set<int> ok) async {
    final (code, text) = await _readResponse();
    if (!ok.contains(code)) {
      throw FileSourceFailure('FTP 服务器返回 $code：${excerptText(text)}');
    }
  }

  void _expect2(int code, Set<int> ok, String hint) {
    if (!ok.contains(code)) {
      throw FileSourceFailure('$hint（服务器返回 $code）');
    }
  }

  /// PASV + LIST [dir]，返回数据连接里的原始行。
  Future<List<String>> list(String dir) async {
    final (code, text) = await () async {
      _socket.write('PASV\r\n');
      return _readResponse();
    }();
    if (code != 227) {
      throw FileSourceFailure('FTP 服务器不支持被动模式（返回 $code）');
    }
    final pasv = RegExp(
      r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)',
    ).firstMatch(text);
    if (pasv == null) {
      throw FileSourceFailure('FTP 被动模式响应无法解析：${excerptText(text)}');
    }
    final tupleHost = [
      pasv.group(1),
      pasv.group(2),
      pasv.group(3),
      pasv.group(4),
    ].join('.');
    final dataPort =
        int.parse(pasv.group(5)!) * 256 + int.parse(pasv.group(6)!);
    final dataHost = tupleHost == '0.0.0.0'
        ? _socket.remoteAddress.address
        : tupleHost;
    Socket data;
    try {
      data = await Socket.connect(
        dataHost,
        dataPort,
        timeout: const Duration(seconds: 15),
      );
    } on SocketException {
      throw FileSourceFailure('FTP 数据连接失败，请检查网络/防火墙');
    }
    final collected = utf8.decoder
        .bind(data)
        .transform(const LineSplitter())
        .toList();
    _socket.write('LIST $dir\r\n');
    final (prelim, prelimText) = await _readResponse();
    if (prelim != 150 && prelim != 125 && prelim != 226 && prelim != 250) {
      data.destroy();
      throw FileSourceFailure(
        'FTP 列目录失败（$prelim）：${excerptText(prelimText)}',
      );
    }
    final lines = await collected.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw FileSourceFailure('FTP 数据传输超时'),
    );
    if (prelim == 150 || prelim == 125) {
      final (done, doneText) = await _readResponse();
      if (done != 226 && done != 250) {
        throw FileSourceFailure(
          'FTP 列目录未完成（$done）：${excerptText(doneText)}',
        );
      }
    }
    return lines;
  }

  Future<void> close() async {
    try {
      _socket.write('QUIT\r\n');
      await _readResponse().timeout(const Duration(seconds: 3));
    } catch (_) {
      // 断开阶段的错误无所谓。
    }
    _socket.destroy();
  }
}

// ---------------------------------------------------------------------------
// 天翼云盘原生（实验）
// ---------------------------------------------------------------------------

/// 天翼云盘原生客户端（实验性，未实测）：按 Alist 开源 189 驱动
/// 公开的网页版接口形态实现——Cookie 会话调 cloud.189.cn 的
/// listFiles.action 分页列目录、getFileDownloadUrl.action 现取
/// 下载地址。接口/字段若与官方现状有出入，报错会带服务器原文。
class TianyiSourceClient implements FileSourceClient {
  TianyiSourceClient(this.source);
  final FileSource source;

  Map<String, String> get _headers => {
    'Cookie': source.credential,
    'Referer': 'https://cloud.189.cn/web/main/',
    'User-Agent': _browserUserAgent,
    'Accept': 'application/json, text/plain, */*',
  };

  void _check(Map<String, dynamic> json) {
    final code = json['res_code'];
    if (code != null && code != 0 && code != '0') {
      throw FileSourceFailure(
        '天翼云盘接口报错（res_code=$code）：${json['res_message'] ?? ''}',
      );
    }
  }

  @override
  Future<List<FileEntry>> list(String? path) async {
    final folderId = path ?? '-11';
    final entries = <FileEntry>[];
    var page = 1;
    while (page <= 30) {
      final uri = Uri.https('cloud.189.cn', '/api/open/file/listFiles.action', {
        'folderId': folderId,
        'pageNum': '$page',
        'pageSize': '60',
        'mediaType': '0',
        'orderBy': '1',
        'descending': 'true',
      });
      final json = await jsonRequest(uri, headers: _headers);
      _check(json);
      final ao = json['fileListAO'];
      if (ao is! Map) {
        throw FileSourceFailure(
          '天翼云盘返回结构异常（原始返回：${excerptText(jsonEncode(json))}）',
        );
      }
      final folders = ao['folderList'];
      if (folders is List) {
        for (final row in folders) {
          if (row is! Map) continue;
          entries.add(
            FileEntry(
              name: '${row['name'] ?? ''}',
              href: '${row['id'] ?? ''}',
              isDirectory: true,
            ),
          );
        }
      }
      final files = ao['fileList'];
      var fileCount = 0;
      if (files is List) {
        fileCount = files.length;
        for (final row in files) {
          if (row is! Map) continue;
          entries.add(
            FileEntry(
              name: '${row['name'] ?? ''}',
              href: '${row['id'] ?? ''}',
              isDirectory: false,
              size: (row['size'] as num?)?.toInt() ?? 0,
            ),
          );
        }
      }
      if (fileCount < 60) break;
      page++;
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<FilePlayTarget> target(FileEntry entry) async {
    final uri = Uri.https(
      'cloud.189.cn',
      '/api/open/file/getFileDownloadUrl.action',
      {'fileId': entry.href},
    );
    final json = await jsonRequest(uri, headers: _headers);
    _check(json);
    var url = '${json['fileDownloadUrl'] ?? ''}';
    if (url.isEmpty) {
      // 新版门户接口兜底：getFileInfo.action 返回 downloadUrl。
      final infoUri = Uri.https('cloud.189.cn', '/api/portal/getFileInfo.action', {
        'fileId': entry.href,
      });
      final info = await jsonRequest(infoUri, headers: _headers);
      _check(info);
      url = '${info['downloadUrl'] ?? ''}';
      if (url.startsWith('//')) url = 'https:$url';
    }
    if (url.isEmpty) {
      throw FileSourceFailure(
        '天翼云盘没有返回下载地址（原始返回：${excerptText(jsonEncode(json))}）',
      );
    }
    return FilePlayTarget(url: url);
  }

  @override
  String progressKey(FileEntry entry) => 'src:${source.id}:189:${entry.href}';

  @override
  FilePlayItem playItem(FileEntry entry) => FilePlayItem(
    title: entry.name,
    progressKey: progressKey(entry),
    ref: entry.href,
    loadTarget: () => target(entry),
  );
}

// ---------------------------------------------------------------------------
// 中国移动云盘原生（实验）
// ---------------------------------------------------------------------------

/// 中国移动云盘原生客户端（实验性，未实测）：按 OpenList 官方驱动
/// drivers/139 的 personal_new（新个人云）形态实现——先向
/// user-njs.yun.139.com/user/route/qryRoutePolicy 查账号专属的个人云
/// 节点地址（源码 `requestRoute` / `Init`），再在该节点上调
/// /file/list 列目录、/file/getDownloadUrl 现取下载地址（源码
/// `personalPost` → `newRequest`、`personalGetFiles`、
/// `personalGetLink`）。请求体是明文 JSON，不做加密；鉴权靠
/// Authorization: Basic <令牌>，另加 Mcloud-Sign 签名头（源码
/// `calSign`：请求体先 encodeURIComponent、字符排序、base64 后与
/// 时间戳+随机串一起三轮 MD5）。令牌本体是 yun.139.com 下名为
/// authorization 的 Cookie 的值，与 OpenList 里手填的 Authorization
/// 是同一个东西（base64 串，解码后以冒号分段、第二段是账号名，
/// 路由查询要用，见源码 `refreshToken` 的解析）；凭据若是整段
/// Cookie 串，先从里面抠出 authorization 项再当令牌用。
/// 之前两套形态的实测结论：hcy 网关（hcy/file/list）明文报
/// 01000008、按 `yun139EncryptedRequest` 加 AES 信封换两把公开
/// 密钥仍报 01000008，已整段删除，不再保留双形态。
class MobileSourceClient implements FileSourceClient {
  MobileSourceClient(this.source);
  final FileSource source;

  /// 路由查询失败时的回退节点（OpenList 是初始化直接失败；这里回退
  /// 到已知的个人云节点域名继续，让真正的接口报错透出给用户）。
  static const _defaultHost = 'https://personal-kd-njs.yun.139.com';
  static const _routeUrl =
      'https://user-njs.yun.139.com/user/route/qryRoutePolicy';

  /// 按令牌缓存路由查询下发的个人云节点，避免每次列目录都查一遍。
  static final _hostCache = <String, String>{};

  /// 凭据是整段 Cookie 串时，抠其中名为 authorization 的一项。
  String? get _cookieToken {
    final value = source.credential;
    if (!value.contains('=')) return null;
    for (final part in value.split(';')) {
      final cut = part.indexOf('=');
      if (cut <= 0) continue;
      if (part.substring(0, cut).trim().toLowerCase() == 'authorization') {
        final token = part.substring(cut + 1).trim();
        if (token.isNotEmpty) return token;
      }
    }
    return null;
  }

  /// 实际使用的令牌：去掉可能带上的 "Basic " 前缀（OpenList 的
  /// `credentialState` 明确要求 Authorization 值本身不带 Basic 前缀，
  /// 前缀由发请求时统一加）。
  String get _token {
    var token = (_cookieToken ?? source.credential).trim();
    if (token.toLowerCase().startsWith('basic ')) {
      token = token.substring(6).trim();
    }
    return token;
  }

  /// 从令牌解出账号名（对齐 OpenList `refreshToken` 对 Authorization
  /// 的解析：base64 解码后以 ":" 分段，第二段是账号）。解不出返回
  /// null，此时跳过路由查询、直接用回退节点。
  String? get _account {
    try {
      final decoded = utf8.decode(
        base64Decode(base64.normalize(_token)),
        allowMalformed: true,
      );
      final splits = decoded.split(':');
      if (splits.length >= 3 && splits[1].isNotEmpty) return splits[1];
    } catch (_) {
      // 令牌不是预期的 base64 分段形态。
    }
    return null;
  }

  static String _md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  /// 对齐 OpenList `encodeURIComponent`（util.go）：JS 语义的
  /// encodeURIComponent——UTF-8 字节逐个处理，只保留 A-Za-z0-9 与
  /// - _ . ! ~ * ' ( )，其余一律 %XX（大写十六进制，空格为 %20）。
  static String _encodeURIComponent(String input) {
    final buffer = StringBuffer();
    for (final byte in utf8.encode(input)) {
      final unreserved =
          (byte >= 0x41 && byte <= 0x5A) || // A-Z
          (byte >= 0x61 && byte <= 0x7A) || // a-z
          (byte >= 0x30 && byte <= 0x39) || // 0-9
          byte == 0x2D || // -
          byte == 0x5F || // _
          byte == 0x2E || // .
          byte == 0x21 || // !
          byte == 0x7E || // ~
          byte == 0x2A || // *
          byte == 0x27 || // '
          byte == 0x28 || // (
          byte == 0x29; // )
      if (unreserved) {
        buffer.writeCharCode(byte);
      } else {
        buffer.write('%');
        buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return buffer.toString();
  }

  /// 对齐 OpenList `calSign`（util.go）：body 先 encodeURIComponent，
  /// 再按字符排序、整体 base64，MD5 后拼上 "ts:randStr" 的 MD5，
  /// 拼接串再 MD5 并转大写。
  static String _calSign(String body, String ts, String randStr) {
    final chars = _encodeURIComponent(body).split('')..sort();
    final b64 = base64Encode(utf8.encode(chars.join()));
    final res = _md5Hex(b64) + _md5Hex('$ts:$randStr');
    return _md5Hex(res).toUpperCase();
  }

  /// 签名用的时间戳，格式与源码 `time.Now().Format("2006-01-02
  /// 15:04:05")` 一致（本地时间）。
  static String _timestamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  /// 签名用的随机串（源码 `random.String(16)`；随机串本身随签名头
  /// 明文发送，服务端用同一串重算签名，字符集不影响验证）。
  static String _randomString(int length) {
    const charset =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final random = Random.secure();
    return List<String>.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }

  /// 请求体的规范序列化：对象键字典序递归排序、紧凑输出——与 Go
  /// encoding/json 对 map 的输出一致。签名与实际发送共用同一份
  /// 字符串，保证签的就是发的。
  static String _canonicalJson(Object? value) {
    if (value == null) return 'null';
    if (value is String) return jsonEncode(value);
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) {
      if (value is int) return '$value';
      final d = value.toDouble();
      if (d == d.truncateToDouble() && d.abs() < 1e15) return '${d.toInt()}';
      return '$d';
    }
    if (value is List) {
      return '[${value.map(_canonicalJson).join(',')}]';
    }
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      final pairs = keys.map(
        (k) => '${jsonEncode(k)}:${_canonicalJson(value[k])}',
      );
      return '{${pairs.join(',')}}';
    }
    return jsonEncode(value);
  }

  /// 带 Mcloud-Sign 的 POST 发送：[body] 是已规范序列化的字符串
  /// （签它、发它）。[route] 为 true 时用源码 `requestRoute` 的小写
  /// 头组，否则用 `newRequest` 的头组（两组在源码里本就不同，原样
  /// 对齐）。错误处理与 [jsonRequest] 一致——非 200 / 非 JSON /
  /// 网络错误都翻成带原始返回片段的 [FileSourceFailure]。
  Future<Map<String, dynamic>> _signedPost(
    Uri uri,
    String body, {
    required bool route,
  }) async {
    final ts = _timestamp();
    final randStr = _randomString(16);
    final sign = '$ts,$randStr,${_calSign(body, ts, randStr)}';
    final headers = route
        ? <String, String>{
            'Accept': 'application/json, text/plain, */*',
            'CMS-DEVICE': 'default',
            'Authorization': 'Basic $_token',
            'mcloud-channel': '1000101',
            'mcloud-client': '10701',
            'mcloud-sign': sign,
            'mcloud-version': '7.14.0',
            'Origin': 'https://yun.139.com',
            'Referer': 'https://yun.139.com/w/',
            'x-DeviceInfo':
                '||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||',
            'x-huawei-channelSrc': '10000034',
            'x-inner-ntwk': '2',
            'x-m4c-caller': 'PC',
            'x-m4c-src': '10002',
            'x-SvcType': '1',
            'Inner-Hcy-Router-Https': '1',
            'User-Agent': _browserUserAgent,
          }
        : <String, String>{
            'Accept': 'application/json, text/plain, */*',
            'Authorization': 'Basic $_token',
            'Caller': 'web',
            'Cms-Device': 'default',
            'Mcloud-Channel': '1000101',
            'Mcloud-Client': '10701',
            'Mcloud-Route': '001',
            'Mcloud-Sign': sign,
            'Mcloud-Version': '7.14.0',
            'x-DeviceInfo':
                '||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||',
            'x-huawei-channelSrc': '10000034',
            'x-inner-ntwk': '2',
            'x-m4c-caller': 'PC',
            'x-m4c-src': '10002',
            'x-SvcType': '1',
            'X-Yun-Api-Version': 'v1',
            'X-Yun-App-Channel': '10000034',
            'X-Yun-Channel-Source': '10000034',
            'X-Yun-Client-Info':
                '||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||dW5kZWZpbmVk||',
            'X-Yun-Module-Type': '100',
            'X-Yun-Svc-Type': '1',
            'User-Agent': _browserUserAgent,
          };
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .openUrl('POST', uri)
          .timeout(const Duration(seconds: 20));
      headers.forEach(request.headers.set);
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw FileSourceFailure(
          '服务器返回 ${response.statusCode}：${excerptText(text)}',
        );
      }
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        // 落到下面的统一报错。
      }
      throw FileSourceFailure('服务器返回了无法解析的内容：${excerptText(text)}');
    } on FileSourceFailure {
      rethrow;
    } on SocketException {
      throw FileSourceFailure('连不上服务器，请检查网络');
    } on TimeoutException {
      throw FileSourceFailure('连接超时，请检查网络');
    } finally {
      client.close(force: true);
    }
  }

  /// 查账号专属的个人云节点（源码 `Init` 里的 Query Route Policy）：
  /// 向 user-njs 查路由策略，取 modName 为 personal 的 httpsUrl。
  /// 查询失败不拦路，回退 [_defaultHost] 继续，真正的接口报错由
  /// 随后的 list 透出。
  Future<String> _resolveHost() async {
    final token = _token;
    final cached = _hostCache[token];
    if (cached != null) return cached;
    var host = _defaultHost;
    final account = _account;
    if (account != null) {
      try {
        final json = await _signedPost(
          Uri.parse(_routeUrl),
          _canonicalJson({
            'userInfo': {
              'userType': 1,
              'accountType': 1,
              'accountName': account,
            },
            'modAddrType': 1,
          }),
          route: true,
        );
        _check(json);
        final data = json['data'];
        final policies = data is Map ? data['routePolicyList'] : null;
        if (policies is List) {
          for (final item in policies) {
            if (item is Map && item['modName'] == 'personal') {
              final url = '${item['httpsUrl'] ?? ''}'.replaceAll(
                RegExp(r'/+$'),
                '',
              );
              if (url.isNotEmpty) host = url;
            }
          }
        }
      } catch (_) {
        // 路由查询失败不拦路：用回退节点继续。
      }
    }
    return _hostCache[token] = host;
  }

  /// personal_new 的一次业务请求（源码 `personalPost`）。
  Future<Map<String, dynamic>> _personalPost(
    String path,
    Map<String, dynamic> body,
  ) async {
    final host = await _resolveHost();
    return _signedPost(
      Uri.parse('$host$path'),
      _canonicalJson(body),
      route: false,
    );
  }

  void _check(Map<String, dynamic> json) {
    final ok =
        json['success'] == true || json['code'] == 0 || json['code'] == '0';
    if (!ok) {
      throw FileSourceFailure(
        '中国移动云盘接口报错：${json['message'] ?? json['msg'] ?? ''}'
        '（原始返回：${excerptText(jsonEncode(json))}）',
      );
    }
  }

  @override
  Future<List<FileEntry>> list(String? path) async {
    // personal_new 的根目录 id 是 "/"（源码 Init 的 RootFolderID
    // 默认值）；子目录用条目自身的 fileId 作 path 传入。
    final parentId = (path == null || path.isEmpty) ? '/' : path;
    final entries = <FileEntry>[];
    var cursor = '';
    // 游标分页（源码 personalGetFiles）：nextPageCursor 为空即止。
    for (var page = 0; page < 200; page++) {
      final json = await _personalPost('/file/list', {
        'imageThumbnailStyleList': ['Small', 'Large'],
        'orderBy': 'updated_at',
        'orderDirection': 'DESC',
        'pageInfo': {'pageCursor': cursor, 'pageSize': 100},
        'parentFileId': parentId,
      });
      _check(json);
      final data = json['data'];
      final items = data is Map ? data['items'] : null;
      if (items is! List) {
        throw FileSourceFailure(
          '中国移动云盘返回结构异常（原始返回：${excerptText(jsonEncode(json))}）',
        );
      }
      for (final row in items) {
        if (row is! Map) continue;
        entries.add(
          FileEntry(
            name: '${row['name'] ?? ''}',
            href: '${row['fileId'] ?? ''}',
            isDirectory: row['type'] == 'folder',
            size: (row['size'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      final next = data is Map ? data['nextPageCursor'] : null;
      if (next is! String || next.isEmpty) break;
      cursor = next;
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<FilePlayTarget> target(FileEntry entry) async {
    // 源码 personalGetLink：cdnSwitch 为真用 cdnUrl，否则用 url。
    final json = await _personalPost('/file/getDownloadUrl', {
      'fileId': entry.href,
    });
    _check(json);
    final data = json['data'];
    var url = '';
    if (data is Map) {
      final cdnUrl = '${data['cdnUrl'] ?? ''}';
      if (data['cdnSwitch'] == true && cdnUrl.isNotEmpty) {
        url = cdnUrl;
      } else {
        url = '${data['url'] ?? ''}';
      }
    }
    if (url.isEmpty) {
      throw FileSourceFailure(
        '中国移动云盘没有返回下载地址（原始返回：${excerptText(jsonEncode(json))}）',
      );
    }
    return FilePlayTarget(url: url);
  }

  @override
  String progressKey(FileEntry entry) => 'src:${source.id}:139:${entry.href}';

  @override
  FilePlayItem playItem(FileEntry entry) => FilePlayItem(
    title: entry.name,
    progressKey: progressKey(entry),
    ref: entry.href,
    loadTarget: () => target(entry),
  );
}
