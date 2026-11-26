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
/// 实测风险（未实测）：Android 的 Cookie 解析对含 '=' 的值历史上
/// 有过截断问题；移动云盘的 Authorization 若只存在于请求头生成
/// 逻辑而非 Cookie/localStorage，可能抓不到，此时探活会失败、
/// 页面停留在报错状态，用户可改走备用粘贴。
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
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            if (!mounted) return;
            final loggedIn = _tianyi
                ? url.contains('cloud.189.cn/web/main')
                : url.contains('yun.139.com') && !url.contains('login');
            if (loggedIn) {
              setState(() => _status = '检测到已进入网盘页面，点右上角「完成」读取登录状态。');
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(_home));
    _controller = controller;
  }

  /// 读 Cookie 存储里该服务域名下的全部 Cookie，拼成 Cookie 头。
  Future<String> _readCookies() async {
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
    return [for (final e in byName.entries) '${e.key}=${e.value}'].join('; ');
  }

  /// 移动云盘的 Authorization 可能存在 localStorage 里：扫一遍，
  /// 找键名带 auth/token 且值够长的，当候选凭据。
  Future<String?> _readStoredToken() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final raw = await controller.runJavaScriptReturningResult(
        '(function(){var out={};try{for(var i=0;i<localStorage.length;i++)'
        '{var k=localStorage.key(i);out[k]=localStorage.getItem(k);}}catch(e){}'
        'return JSON.stringify(out);})()',
      );
      var text = '$raw';
      if (text.startsWith('"')) {
        text = jsonDecode(text) as String;
      }
      final map = jsonDecode(text);
      if (map is! Map) return null;
      for (final entry in map.entries) {
        final key = '${entry.key}'.toLowerCase();
        var value = '${entry.value}'.trim();
        if (!key.contains('auth') && !key.contains('token')) continue;
        if (value.startsWith('Basic ')) value = value.substring(6).trim();
        if (value.length >= 16) return value;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在读取登录状态并验证…';
    });
    try {
      final cookie = await _readCookies();
      final candidates = <String>[
        if (!_tianyi) ...[?await _readStoredToken()],
        if (cookie.isNotEmpty) cookie,
      ];
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
