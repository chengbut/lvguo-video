import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../file_sources.dart';

/// 网盘内嵌网页登录的返回结果：抓到的凭据（天翼是 Cookie 整段，
/// 移动优先是 Authorization 里 Basic 后面的内容）。
class CloudLoginResult {
  const CloudLoginResult({required this.credential});
  final String credential;
}

/// 网易爆米花式的内嵌网页登录（实验）：在 App 里打开官方网页版
/// 登录页，用户自己输账号/短信验证码完成登录，点「完成」后用
/// webview_flutter 的 Cookie 管理器读该域名的全部 Cookie（系统
/// Cookie 存储，含 HttpOnly），再拿文件列表接口实际探活——探活
/// 通过才算登录成功。桌面端没有 WebView 实现，页面直接提示改用
/// 备用粘贴方式。
///
/// 移动云盘令牌的来源（据 cloud139 README 与 Alist 139 驱动文档）：
/// 就是 yun.139.com 域名下名为 `authorization` 的 Cookie 的值，
/// 请求时放在 `Authorization: Basic <该值>` 头里；hcy 接口不认
/// 整段 Cookie 头，所以必须把这一项单独抠出来当凭据。另外再全量
/// 扫 localStorage/sessionStorage（含嵌套 JSON）兜底，逐个探活。
///
/// 实测风险（未实测）：Android 的 Cookie 解析对含 '=' 的值历史上
/// 有过截断问题，所以管理器与 document.cookie 两路都读、互相补。
class CloudLoginPage extends StatefulWidget {
  const CloudLoginPage({super.key, required this.type});

  /// 只支持天翼云盘 / 中国移动云盘。
  final FileSourceType type;

  @override
  State<CloudLoginPage> createState() => _CloudLoginPageState();
}

class _CloudLoginPageState extends State<CloudLoginPage> {
  WebViewController? _controller;
  bool _busy = false;
  String _status = '在官方页面里完成登录，然后点右上角「完成」。';

  bool get _supported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  bool get _tianyi => widget.type == FileSourceType.tianyi;

  String get _home => _tianyi ? 'https://cloud.189.cn/' : 'https://yun.139.com/';

  @override
  void initState() {
    super.initState();
    if (!_supported) {
      _status = '内置网页登录只支持手机端，这个平台请用备用粘贴方式。';
      return;
    }
    // WebView 配置要点（实测教训）：移动/天翼登录页的短信验证码
    // 接口会按 UA 与浏览器指纹拦截，WebView 默认 UA（带 App 标识
    // 的那串）会被拒发验证码，所以统一设成标准 iPhone Safari
    // UA；登录页全靠 JS，JavaScript 必须开；Cookie 必须可写可
    // 读且持久——webview_flutter 默认控制器在 iOS 走 WKWebView
    // 的默认（持久化）数据存储、Android 走 WebView 默认 Cookie
    // 管理，本页没有设置任何无痕/拦截 Cookie 的选项，登录态能
    // 落盘并被 WebViewCookieManager 读到，不要改成无痕配置。
    final controller = WebViewController()
      ..setUserAgent(
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
        'Mobile/15E148 Safari/604.1',
      )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            if (!mounted) return;
            unawaited(_refreshLoginHint(url));
          },
        ),
      )
      ..loadRequest(Uri.parse(_home));
    _controller = controller;
  }

  /// URL 是否还在登录页：路径/参数里带 login/passport/signin
  /// 等登录标记。注意移动云盘是单页应用，登录表单就渲染在不带
  /// login 字样的壳 URL 里，所以这一步只能排除明显的登录页，
  /// 最终判断必须再叠加关键 Cookie 是否存在（见下）。
  static bool _looksLikeLoginPage(String url) {
    final lower = url.toLowerCase();
    return lower.contains('login') ||
        lower.contains('passport') ||
        lower.contains('signin');
  }

  int _hintSeq = 0;

  /// 页面加载完后刷新底部提示：只有「不在登录页」且「关键
  /// Cookie 已存在」才提示已进入网盘——移动查名为 authorization
  /// 的 Cookie（登录成功后才种下，见类注释）；天翼客户端用整段
  /// Cookie 头、没有单一关键项，退而求其次用「在 cloud.189.cn
  /// 域内 + Cookie 表非空」。只凭 URL 判断会把还停在登录表单的
  /// 单页壳 URL 误报成已登录（2026-11-27 实测踩过）。
  Future<void> _refreshLoginHint(String url) async {
    final seq = ++_hintSeq;
    if (_busy) return;
    if (_looksLikeLoginPage(url)) {
      setState(
        () => _status = '请先在页面里完成登录，成功进入网盘后再点右上角「完成」。',
      );
      return;
    }
    final cookieMap = await _readCookieMap();
    if (!mounted || seq != _hintSeq || _busy) return;
    final hasKeyCookie = _tianyi
        ? url.contains('cloud.189.cn') && cookieMap.isNotEmpty
        : cookieMap.keys.any((name) => name.toLowerCase() == 'authorization');
    setState(() {
      _status = hasKeyCookie
          ? '检测到已进入网盘页面，点右上角「完成」读取登录状态。'
          : '请先在页面里完成登录，成功进入网盘后再点右上角「完成」。';
    });
  }

  /// 读 Cookie 存储里该服务域名下的全部 Cookie，返回名称 → 值。
  Future<Map<String, String>> _readCookieMap() async {
    final manager = WebViewCookieManager();
    final byName = <String, String>{};
    final domains = _tianyi
        ? const ['https://cloud.189.cn/', 'https://api.cloud.189.cn/']
        : const [
            'https://yun.139.com/',
            'https://personal-kd-njs.yun.139.com/',
            'https://caiyun.139.com/',
          ];
    for (final domain in domains) {
      try {
        final cookies = await manager.getCookies(domain: Uri.parse(domain));
        for (final cookie in cookies) {
          if (cookie.name.isNotEmpty) byName[cookie.name] = cookie.value;
        }
      } catch (_) {
        // 某个域名读不到不算致命，继续拼其他域名的。
      }
    }
    // 再补一遍 JS 能看到的 document.cookie（非 HttpOnly 部分），
    // 覆盖 Cookie 管理器按域名过滤可能漏掉的当前页 Cookie。
    final controller = _controller;
    if (controller != null) {
      try {
        final raw = await controller.runJavaScriptReturningResult(
          'document.cookie',
        );
        for (final part in '$raw'.replaceAll('"', '').split(';')) {
          final cut = part.indexOf('=');
          if (cut > 0) {
            byName.putIfAbsent(
              part.substring(0, cut).trim(),
              () => part.substring(cut + 1).trim(),
            );
          }
        }
      } catch (_) {}
    }
    return byName;
  }

  /// 把 Cookie 表拼成 Cookie 头（天翼用整段 Cookie 探活）。
  String _cookieHeader(Map<String, String> byName) =>
      [for (final e in byName.entries) '${e.key}=${e.value}'].join('; ');

  static String _stripBasic(String value) =>
      value.startsWith('Basic ') ? value.substring(6).trim() : value;

  /// 移动云盘令牌兜底扫描：localStorage + sessionStorage 逐键看，
  /// 键名带 auth/token 的直接收；值是 JSON 的递归挖里面键名带
  /// auth/token 的字符串字段。返回全部候选（已去 Basic 前缀）。
  Future<List<String>> _readStoredTokens() async {
    final controller = _controller;
    if (controller == null) return const [];
    try {
      final raw = await controller.runJavaScriptReturningResult(
        '(function(){var out=[];var seen={};'
        'function push(v){if(typeof v!=="string")return;v=v.trim();'
        'if(v.length>=16&&!seen[v]){seen[v]=1;out.push(v);}}'
        'function walk(k,v){if(typeof v==="string"){'
        'if(/auth|token/i.test(k))push(v);}'
        'else if(v&&typeof v==="object"){for(var kk in v)walk(kk,v[kk]);}}'
        'function scan(store){if(!store)return;'
        'for(var i=0;i<store.length;i++){var k=store.key(i);'
        'var raw=store.getItem(k);if(raw==null)continue;'
        'try{walk(k,JSON.parse(raw));}catch(e){}'
        'if(/auth|token/i.test(k))push(raw);}}'
        'try{scan(localStorage);}catch(e){}'
        'try{scan(sessionStorage);}catch(e){}'
        'return JSON.stringify(out);})()',
      );
      var text = '$raw';
      if (text.startsWith('"')) {
        final decoded = jsonDecode(text);
        if (decoded is String) text = decoded;
      }
      final list = jsonDecode(text);
      if (list is! List) return const [];
      return [
        for (final item in list)
          if ('$item'.trim().length >= 16) _stripBasic('$item'.trim()),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在读取登录状态并验证…';
    });
    try {
      final cookieMap = await _readCookieMap();
      final cookie = _cookieHeader(cookieMap);
      final candidates = <String>[];
      void addCandidate(String? value) {
        final v = value?.trim() ?? '';
        if (v.isNotEmpty && !candidates.contains(v)) candidates.add(v);
      }

      if (!_tianyi) {
        // 移动令牌首选 authorization Cookie 的值（见类注释的来源
        // 说明）；其次 storage 全量扫描的候选；整段 Cookie 垫底——
        // MobileSourceClient 也会再从整段里抠 authorization 项。
        for (final e in cookieMap.entries) {
          if (e.key.toLowerCase() == 'authorization') {
            addCandidate(_stripBasic(e.value.trim()));
          }
        }
        for (final token in await _readStoredTokens()) {
          addCandidate(token);
        }
      }
      addCandidate(cookie);
      if (candidates.isEmpty) {
        setState(() {
          _busy = false;
          _status = '没有读到任何登录信息，可能还没登录成功，或登录态存在读不到的地方。可以再试一次，或返回用备用粘贴方式。';
        });
        return;
      }
      Object? lastError;
      for (final credential in candidates) {
        final probe = FileSource(
          id: 'login-probe',
          name: widget.type.label,
          type: widget.type,
          mode: fileSourceModeNative,
          cookie: credential,
        );
        try {
          await createFileSourceClient(probe).list(null);
          if (!mounted) return;
          Navigator.pop(context, CloudLoginResult(credential: credential));
          return;
        } catch (error) {
          lastError = error;
        }
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '读到了登录信息，但接口验证没通过：$lastError。可以再试一次，或返回用备用粘贴方式。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '读取登录状态失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: Text('登录${widget.type.label}（实验）'),
        actions: [
          TextButton(
            onPressed: _supported && !_busy ? () => unawaited(_finish()) : null,
            child: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('完成'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: controller == null
                ? const Center(child: Text('此平台不支持内置网页登录'))
                : WebViewWidget(controller: controller),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Text(
                _status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
