import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 文件源类型：天翼云盘 / 中国移动云盘 / WebDAV 三者都走 WebDAV 挂载
/// （天翼、移动由 Alist / CloudDrive2 转出 WebDAV 地址后填进来），
/// http 是单个媒体文件的直链拉取。
enum FileSourceType {
  tianyi('天翼云盘'),
  mobile('中国移动云盘'),
  webdav('WebDAV'),
  http('HTTP 拉取');

  const FileSourceType(this.label);
  final String label;

  bool get isWebDav => this != FileSourceType.http;

  static FileSourceType byName(String name) => values.firstWhere(
    (type) => type.name == name,
    orElse: () => FileSourceType.webdav,
  );
}

class FileSource {
  const FileSource({
    required this.id,
    required this.name,
    required this.type,
    this.server = '',
    this.username = '',
    this.password = '',
    this.url = '',
  });
  final String id;
  final String name;
  final FileSourceType type;
  final String server;
  final String username;
  final String password;
  final String url;

  /// 卡片第二行显示的主机：WebDAV 类取服务器主机，HTTP 类取直链主机。
  String get host {
    final raw = type.isWebDav ? server : url;
    final uri = Uri.tryParse(raw);
    return uri != null && uri.host.isNotEmpty ? uri.host : raw;
  }

  Map<String, String> get authHeaders {
    if (username.isEmpty) return const {};
    final token = base64Encode(utf8.encode('$username:$password'));
    return {'Authorization': 'Basic $token'};
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'server': server,
    'username': username,
    'password': password,
    'url': url,
  };

  factory FileSource.fromJson(Map<String, dynamic> json) => FileSource(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    type: FileSourceType.byName(json['type'] as String? ?? ''),
    server: json['server'] as String? ?? '',
    username: json['username'] as String? ?? '',
    password: json['password'] as String? ?? '',
    url: json['url'] as String? ?? '',
  );
}

/// 文件播放进度：以文件 URL 为键的独立记录。剧集历史（LocalStore 的
/// WatchEntry）强绑定站源剧集，文件源塞不进去，所以文件源的续播单独
/// 存这里，不进历史页列表，只在再次打开同一文件时恢复进度。
class FileProgress {
  const FileProgress({
    required this.position,
    required this.duration,
    required this.updatedAt,
  });
  final double position;
  final double duration;
  final DateTime updatedAt;
  bool get finished => duration > 1 && position >= duration - 1;

  Map<String, dynamic> toJson() => {
    'position': position,
    'duration': duration,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory FileProgress.fromJson(Map<String, dynamic> json) => FileProgress(
    position: (json['position'] as num?)?.toDouble() ?? 0,
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    updatedAt: DateTime.tryParse('${json['updatedAt']}') ?? DateTime(2000),
  );
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

  FileProgress? progressFor(String url) => _progress[url];

  Future<void> saveProgress(
    String url, {
    required double position,
    required double duration,
  }) async {
    _progress = {
      ..._progress,
      url: FileProgress(
        position: position,
        duration: duration,
        updatedAt: DateTime.now(),
      ),
    };
    // 只留最近 300 条，和剧集历史一个量级。
    if (_progress.length > 300) {
      final sorted = _progress.entries.toList()
        ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
      _progress = Map.fromEntries(sorted.take(300));
    }
    await _preferences.setString(
      _progressKey,
      jsonEncode({
        for (final entry in _progress.entries) entry.key: entry.value.toJson(),
      }),
    );
  }
}

String newFileSourceId() => '${DateTime.now().microsecondsSinceEpoch}';

/// WebDAV 目录里的一项：文件夹或文件。href 是服务器返回的绝对路径
/// （URL 编码形态），name 是解码后的显示名。
class WebDavEntry {
  const WebDavEntry({
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

  /// 拼某个 href（服务器返回的绝对路径）对应的完整 URL。
  Uri resolve(String href) {
    final base = _base;
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: href,
    );
  }

  /// 列 [href] 目录（null 表示源根目录，即服务器地址本身）。
  Future<List<WebDavEntry>> list(String? href) async {
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
      return parsePropfind(body, currentHref: target.path);
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
  /// <href>，再逐个 <response> 块取字段；当前目录自身那条跳过。
  static List<WebDavEntry> parsePropfind(
    String xml, {
    required String currentHref,
  }) {
    final plain = xml.replaceAllMapped(
      RegExp(r'<(/?)[A-Za-z0-9]+:'),
      (match) => '<${match[1]}',
    );
    String field(String block, String tag) {
      final match = RegExp('<$tag>([^<]*)</$tag>').firstMatch(block);
      return match == null ? '' : match.group(1)!.trim();
    }

    final entries = <WebDavEntry>[];
    for (final match in RegExp(
      r'<response>(.*?)</response>',
      dotAll: true,
    ).allMatches(plain)) {
      final block = match.group(1)!;
      final href = field(block, 'href');
      if (href.isEmpty) continue;
      // 服务器返回的当前目录路径可能带/不带结尾斜杠，两种都算自身。
      final self = href == currentHref || '$href/' == currentHref ||
          href == '$currentHref/';
      if (self) continue;
      final isDirectory = block.contains('<collection');
      var name = field(block, 'displayname');
      if (name.isEmpty) {
        final decoded = Uri.decodeComponent(href);
        final trimmed = decoded.endsWith('/')
            ? decoded.substring(0, decoded.length - 1)
            : decoded;
        name = trimmed.split('/').last;
      } else {
        try {
          name = Uri.decodeComponent(name);
        } catch (_) {}
      }
      entries.add(
        WebDavEntry(
          name: name,
          href: href,
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

class FileSourceFailure implements Exception {
  FileSourceFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
