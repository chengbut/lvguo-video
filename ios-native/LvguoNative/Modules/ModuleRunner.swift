import Foundation
import JavaScriptCore

enum ModuleError: Error, CustomStringConvertible {
    case js(message: String, loginRequired: Bool)
    case bridge(String)

    var description: String {
        switch self {
        case .js(let message, _): return message
        case .bridge(let message): return message
        }
    }

    var loginRequired: Bool {
        if case .js(_, let required) = self { return required }
        return false
    }
}

/// host.* 桥的原生实现：与 JS 上下文无关，只依赖清单与状态目录，
/// 因此可以被 block 捕获而不与 JSContext 形成引用环。
/// 约定与 Go 核心 module_script.go / module_host.go 一一对应：
/// - 模块函数同步调用（返回 Promise 会被 invoker 拒绝），桥也同步阻塞；
/// - fetch/fetchText 先校验清单 hosts 声明（allowsHost），未声明直接抛错；
/// - 出错时抛出的 JS Error 带 status/body/blocked/oversized 属性（对应 Go 的 failResponse）。
final class ModuleHostBridge {
    let manifest: ModuleManifest
    private let stateDirectory: URL
    private(set) var logs: [String] = []
    private var cache: [String: (value: String, expires: Date?)] = [:]

    init(manifest: ModuleManifest, stateDirectory: URL) {
        self.manifest = manifest
        self.stateDirectory = stateDirectory
    }

    // MARK: - 基础工具

    private func envelope(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"error":"内部错误"}"#
        }
        return text
    }

    private func parsePayload(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
        print("[Module \(manifest.id)] \(message)")
    }

    // MARK: - 同步 HTTP（在 JS 执行线程上阻塞等待，与 goja 的同步语义一致）

    private enum FetchOutcome {
        case success(Data, HTTPURLResponse)
        case failure(String)
    }

    private func perform(_ request: URLRequest, timeout: TimeInterval) -> FetchOutcome {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: FetchOutcome = .failure("请求未完成")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                outcome = .success(data ?? Data(), http)
            } else {
                outcome = .failure("响应无效")
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 10) == .timedOut {
            task.cancel()
            return .failure("请求超时")
        }
        return outcome
    }

    // MARK: - host.fetch

    func fetchEnvelope(_ json: String) -> String {
        guard let payload = parsePayload(json) else {
            return envelope(["error": "请求参数无效"])
        }
        let urlString = JSON.dictString(payload["url"])
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return envelope(["error": "请求地址无效"])
        }
        guard manifest.allowsHost(host) else {
            return envelope(["error": "模块清单未声明访问 \(host)"])
        }
        var request = URLRequest(url: url)
        let method = JSON.dictString(payload["method"]).uppercased()
        request.httpMethod = method.isEmpty ? "GET" : method
        if let headers = payload["headers"] as? [String: Any] {
            for (name, value) in headers {
                request.setValue(JSON.dictString(value), forHTTPHeaderField: name)
            }
        }
        if let bodyText = payload["bodyText"] as? String {
            request.httpBody = Data(bodyText.utf8)
        } else if let bodyB64 = payload["bodyB64"] as? String,
                  let body = Data(base64Encoded: bodyB64) {
            request.httpBody = body
        }
        let timeoutMs = JSON.dictInt(payload["timeoutMs"])
        request.timeoutInterval = timeoutMs > 0 ? Double(timeoutMs) / 1000.0 : 30
        let limitValue = JSON.dictInt(payload["limit"])
        let limit = limitValue > 0 ? limitValue : 4 << 20
        let binary = JSON.dictBool(payload["binary"])
        let anyStatus = JSON.dictBool(payload["anyStatus"])
        let acceptStatus = (payload["acceptStatus"] as? [Any] ?? [])
            .map { JSON.dictInt($0) }

        switch perform(request, timeout: request.timeoutInterval) {
        case .failure(let message):
            return envelope(["error": message])
        case .success(let data, let response):
            let status = response.statusCode
            var headers: [String: [String]] = [:]
            for (key, value) in response.allHeaderFields {
                headers[String(describing: key)] = ["\(value)"]
            }
            if data.count > limit {
                return envelope([
                    "error": "响应内容过大",
                    "status": status,
                    "bodyText": String(decoding: data.prefix(limit), as: UTF8.self),
                    "oversized": true,
                ])
            }
            let acceptable = anyStatus
                || acceptStatus.contains(status)
                || (200...399).contains(status)
            guard acceptable else {
                return envelope([
                    "error": "HTTP \(status)",
                    "status": status,
                    "bodyText": String(decoding: data, as: UTF8.self),
                ])
            }
            var result: [String: Any] = ["status": status, "headers": headers]
            if binary {
                result["bodyB64"] = data.base64EncodedString()
            } else {
                result["bodyText"] = String(decoding: data, as: UTF8.self)
            }
            return envelope(result)
        }
    }

    // MARK: - host.fetchText

    func fetchTextEnvelope(_ json: String) -> String {
        guard let payload = parsePayload(json) else {
            return envelope(["error": "请求参数无效"])
        }
        let urlString = JSON.dictString(payload["url"])
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return envelope(["error": "请求地址无效"])
        }
        guard manifest.allowsHost(host) else {
            return envelope(["error": "模块清单未声明访问 \(host)"])
        }
        let referer = JSON.dictString(payload["referer"])
        let userAgent = JSON.dictString(payload["userAgent"])
        let cookie = JSON.dictString(payload["cookie"])
        let body = JSON.dictString(payload["body"])
        // Go 侧：镜像地址逐个过滤未声明 hosts，主地址未声明直接报错
        var candidates = [urlString]
        for mirror in payload["mirrors"] as? [Any] ?? [] {
            let mirrorString = JSON.dictString(mirror)
            if let mirrorURL = URL(string: mirrorString),
               let mirrorHost = mirrorURL.host,
               manifest.allowsHost(mirrorHost) {
                candidates.append(mirrorString)
            }
        }
        var lastError = "请求失败"
        for candidate in candidates {
            guard let candidateURL = URL(string: candidate) else { continue }
            var request = URLRequest(url: candidateURL)
            request.httpMethod = body.isEmpty ? "GET" : "POST"
            request.timeoutInterval = 30
            if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
            if !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if !body.isEmpty { request.httpBody = Data(body.utf8) }
            switch perform(request, timeout: 30) {
            case .failure(let message):
                lastError = message
            case .success(let data, let response):
                if (200...299).contains(response.statusCode) {
                    return envelope([
                        "body": String(decoding: data, as: UTF8.self),
                        "url": response.url?.absoluteString ?? candidate,
                    ])
                }
                lastError = "HTTP \(response.statusCode)"
            }
        }
        return envelope(["error": lastError])
    }

    // MARK: - host.fetchPlaylist

    func fetchPlaylistEnvelope(_ json: String) -> String {
        guard let payload = parsePayload(json) else {
            return envelope(["error": "请求参数无效"])
        }
        let urlString = JSON.dictString(payload["url"])
        guard let url = URL(string: urlString) else {
            return envelope(["error": "请求地址无效"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        var referer = JSON.dictString(payload["referer"])
        if let credentials = MediaCredentials.parse(payload["credentials"]) {
            if !credentials.cookie.isEmpty {
                request.setValue(credentials.cookie, forHTTPHeaderField: "Cookie")
            }
            if !credentials.userAgent.isEmpty {
                request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
            }
            if !credentials.origin.isEmpty {
                request.setValue(credentials.origin, forHTTPHeaderField: "Origin")
            }
            if referer.isEmpty {
                referer = credentials.referer
            }
        }
        if !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        switch perform(request, timeout: 30) {
        case .failure(let message):
            return envelope(["error": message])
        case .success(let data, let response):
            guard (200...299).contains(response.statusCode) else {
                return envelope(["error": "HTTP \(response.statusCode)"])
            }
            let playlist = String(decoding: data, as: UTF8.self)
            // 与 Go M3u8Duration 一致：累加 #EXTINF 秒数
            var seconds = 0.0
            for line in playlist.split(separator: "\n") {
                if line.hasPrefix("#EXTINF:") {
                    let raw = line.dropFirst("#EXTINF:".count)
                        .split(separator: ",").first ?? ""
                    seconds += Double(raw) ?? 0
                }
            }
            return envelope([
                "playlist": playlist,
                "url": response.url?.absoluteString ?? urlString,
                "durationMs": Int(seconds * 1000),
            ])
        }
    }

    // MARK: - host.parseUrl / resolveUrl

    func parseUrlEnvelope(_ raw: String) -> String {
        guard let components = URLComponents(string: raw),
              let url = components.url else {
            return envelope(["error": "地址无效"])
        }
        var host = components.host ?? ""
        if let port = components.port {
            host += ":\(port)"
        }
        return envelope([
            "scheme": components.scheme ?? "",
            "host": host,
            "hostname": components.host ?? "",
            "port": components.port.map { String($0) } ?? "",
            "path": components.percentEncodedPath,
            "query": components.percentEncodedQuery ?? "",
            "fragment": components.fragment ?? "",
            "userInfo": components.user != nil,
            "href": url.absoluteString,
        ])
    }

    func resolveUrl(_ base: String, _ ref: String) -> String {
        guard let baseURL = URL(string: base) else { return "" }
        return URL(string: ref, relativeTo: baseURL)?.absoluteURL.absoluteString ?? ""
    }

    // MARK: - host.loadState / saveState（落盘键与 Go 一致：module-<id>-<name>）

    private func stateFileURL(_ name: String) -> URL {
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return stateDirectory.appendingPathComponent("module-\(manifest.id)-\(safeName)")
    }

    func loadStateEnvelope(_ name: String) -> String {
        let file = stateFileURL(name)
        guard let data = try? Data(contentsOf: file) else {
            return envelope(["error": "状态不存在"])
        }
        return envelope(["value": String(decoding: data, as: UTF8.self)])
    }

    /// 返回空串表示成功，否则是错误信息（shim 负责抛错）
    func saveState(_ name: String, _ value: String) -> String {
        do {
            try Data(value.utf8).write(to: stateFileURL(name))
            return ""
        } catch {
            return "状态保存失败"
        }
    }

    // MARK: - host.cacheGet / cacheSet（内存缓存，语义同 Go moduleCache）

    func cacheGetEnvelope(_ key: String) -> String {
        if let entry = cache[key] {
            if let expires = entry.expires, expires < Date() {
                cache[key] = nil
            } else {
                return envelope(["value": entry.value])
            }
        }
        return envelope(["value": NSNull()])
    }

    func cacheSet(_ key: String, _ value: String, _ ttlMs: Double) {
        // Go：空值即删键
        if value.isEmpty {
            cache[key] = nil
            return
        }
        let expires = ttlMs > 0 ? Date().addingTimeInterval(ttlMs / 1000.0) : nil
        cache[key] = (value: value, expires: expires)
    }

    // MARK: - host 加密/摘要（入参出参均为 base64）

    func cryptoEnvelope(_ op: String, _ a: String, _ b: String, _ c: String) -> String {
        func bytes(_ text: String) -> Data? {
            if text.isEmpty { return Data() }
            if let data = Data(base64Encoded: text) { return data }
            var padded = text
            while padded.count % 4 != 0 { padded += "=" }
            return Data(base64Encoded: padded)
        }
        do {
            let result: Data
            switch op {
            case "md5":
                guard let data = bytes(a) else { throw CryptoUtils.CryptoError.message("Base64 内容无效") }
                result = CryptoUtils.md5(data)
            case "sha256":
                guard let data = bytes(a) else { throw CryptoUtils.CryptoError.message("Base64 内容无效") }
                result = CryptoUtils.sha256(data)
            case "sha512":
                guard let data = bytes(a) else { throw CryptoUtils.CryptoError.message("Base64 内容无效") }
                result = CryptoUtils.sha512(data)
            case "aesCbcEncrypt", "aesCbcDecrypt":
                guard let key = bytes(a), let iv = bytes(b), let data = bytes(c) else {
                    throw CryptoUtils.CryptoError.message("Base64 内容无效")
                }
                result = try CryptoUtils.aesCbc(
                    key: key, iv: iv, data: data, encrypt: op == "aesCbcEncrypt"
                )
            default:
                throw CryptoUtils.CryptoError.message("未知的加密操作 \(op)")
            }
            return envelope(["result": result.base64EncodedString()])
        } catch {
            return envelope(["error": "\(error)"])
        }
    }

    func randomBytesEnvelope(_ count: Int) -> String {
        do {
            let data = try CryptoUtils.randomBytes(count)
            return envelope(["result": data.base64EncodedString()])
        } catch {
            return envelope(["error": "\(error)"])
        }
    }
}

// MARK: - JS shim

/// 在模块代码之前求值：把 __host_* 原生函数组装成 Go 约定的 `host` 对象。
/// 字节类入参/出参（加密、编码）在 JS 侧与 base64 之间转换，
/// 原生侧只处理字符串，避免 JSValue 类型数组的逐元素桥接开销与不确定性。
private let moduleHostShim = #"""
var __b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function __b64encode(u8) {
  var out = '';
  for (var i = 0; i < u8.length; i += 3) {
    var a = u8[i];
    var b = i + 1 < u8.length ? u8[i + 1] : 0;
    var c = i + 2 < u8.length ? u8[i + 2] : 0;
    var n = (a << 16) | (b << 8) | c;
    out += __b64chars[(n >> 18) & 63] + __b64chars[(n >> 12) & 63]
      + (i + 1 < u8.length ? __b64chars[(n >> 6) & 63] : '=')
      + (i + 2 < u8.length ? __b64chars[n & 63] : '=');
  }
  return out;
}
function __b64decode(text) {
  var clean = String(text).replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  for (var i = 0; i < clean.length; i += 4) {
    var c0 = __b64chars.indexOf(clean[i]);
    var c1 = __b64chars.indexOf(clean[i + 1]);
    var has2 = i + 2 < clean.length && clean[i + 2] !== '=';
    var has3 = i + 3 < clean.length && clean[i + 3] !== '=';
    var c2 = has2 ? __b64chars.indexOf(clean[i + 2]) : 0;
    var c3 = has3 ? __b64chars.indexOf(clean[i + 3]) : 0;
    var n = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
    out.push((n >> 16) & 255);
    if (has2) out.push((n >> 8) & 255);
    if (has3) out.push(n & 255);
  }
  return new Uint8Array(out);
}
function __utf8Encode(text) {
  var out = [];
  var str = String(text);
  for (var i = 0; i < str.length; i++) {
    var code = str.charCodeAt(i);
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
    } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length) {
      var low = str.charCodeAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        var cp = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
          0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
        i++;
      } else {
        out.push(0xEF, 0xBF, 0xBD);
      }
    } else if (code >= 0xDC00 && code <= 0xDFFF) {
      out.push(0xEF, 0xBF, 0xBD);
    } else {
      out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
    }
  }
  return new Uint8Array(out);
}
function __utf8Decode(u8) {
  var out = '';
  var i = 0;
  while (i < u8.length) {
    var b = u8[i];
    var cp;
    if (b < 0x80) { cp = b; i += 1; }
    else if (b >= 0xC2 && b <= 0xDF && i + 1 < u8.length) {
      cp = ((b & 0x1F) << 6) | (u8[i + 1] & 0x3F); i += 2;
    } else if (b >= 0xE0 && b <= 0xEF && i + 2 < u8.length) {
      cp = ((b & 0x0F) << 12) | ((u8[i + 1] & 0x3F) << 6) | (u8[i + 2] & 0x3F); i += 3;
    } else if (b >= 0xF0 && b <= 0xF4 && i + 3 < u8.length) {
      cp = ((b & 0x07) << 18) | ((u8[i + 1] & 0x3F) << 12)
        | ((u8[i + 2] & 0x3F) << 6) | (u8[i + 3] & 0x3F); i += 4;
    } else { cp = 0xFFFD; i += 1; }
    if (cp > 0xFFFF) {
      cp -= 0x10000;
      out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
    } else {
      out += String.fromCharCode(cp);
    }
  }
  return out;
}
function __toBytes(value) {
  if (typeof value === 'string') return __utf8Encode(value);
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (Array.isArray(value)) return new Uint8Array(value);
  throw new TypeError('需要字符串或字节数组');
}
function __hexEncode(u8) {
  var out = '';
  for (var i = 0; i < u8.length; i++) {
    var h = u8[i].toString(16);
    out += (h.length === 1 ? '0' : '') + h;
  }
  return out;
}
function __hexDecode(text) {
  var clean = String(text).trim();
  if (clean.length % 2 !== 0) throw new Error('十六进制内容无效');
  var out = new Uint8Array(clean.length / 2);
  for (var i = 0; i < out.length; i++) {
    var v = parseInt(clean.substr(i * 2, 2), 16);
    if (isNaN(v)) throw new Error('十六进制内容无效');
    out[i] = v;
  }
  return out;
}
function __crypto(op, a, b, c) {
  var env = JSON.parse(__host_crypto(op, a || '', b || '', c || ''));
  if (env.error) throw new Error(env.error);
  return __b64decode(env.result || '');
}
function __throwFetchError(env) {
  var e = new Error(env.error || '请求失败');
  e.status = env.status || 0;
  e.body = env.bodyText !== undefined ? env.bodyText : (env.body || '');
  e.blocked = !!env.blocked;
  e.oversized = !!env.oversized;
  e.backoff = false;
  throw e;
}
function __preserveIntegers(text) {
  text = String(text);
  var out = '';
  var inString = false;
  var escaped = false;
  var i = 0;
  while (i < text.length) {
    var ch = text.charAt(i);
    if (inString) {
      out += ch;
      if (escaped) { escaped = false; }
      else if (ch === '\\') { escaped = true; }
      else if (ch === '"') { inString = false; }
      i += 1;
      continue;
    }
    if (ch === '"') { inString = true; out += ch; i += 1; continue; }
    if (ch === '-' || (ch >= '0' && ch <= '9')) {
      var end = i + 1;
      while (end < text.length && '0123456789+-.eE'.indexOf(text.charAt(end)) >= 0) { end += 1; }
      var token = text.substring(i, end);
      var plain = token.indexOf('.') < 0 && token.indexOf('e') < 0
        && token.indexOf('E') < 0 && token.indexOf('+') < 0;
      if (plain) {
        var big = null;
        try { big = BigInt(token); } catch (err) { big = null; }
        if (big === null || big > 9007199254740991n || big < -9007199254740991n) {
          out += '"' + token + '"';
          i = end;
          continue;
        }
      }
      out += token;
      i = end;
      continue;
    }
    out += ch;
    i += 1;
  }
  return out;
}

var __hostObject = {
  source: '',
  dramaId: function (sourceId) {
    return __hostObject.source + ':' + String(sourceId).trim();
  },
  chapterId: function (sourceId, key) {
    return __hostObject.source + ':' + String(sourceId).trim() + ':' + String(key).trim();
  },
  fetch: function (request) {
    request = request || {};
    var payload = {
      method: request.method || 'GET',
      url: String(request.url || ''),
      headers: request.headers || {},
      timeoutMs: request.timeoutMs || 0,
      limit: request.limit || 0,
      binary: !!request.binary,
      anyStatus: !!request.anyStatus,
      acceptStatus: request.acceptStatus || []
    };
    if (request.body !== undefined && request.body !== null) {
      if (typeof request.body === 'string') { payload.bodyText = request.body; }
      else { payload.bodyB64 = __b64encode(__toBytes(request.body)); }
    }
    var env = JSON.parse(__host_fetch(JSON.stringify(payload)));
    if (env.error) { __throwFetchError(env); }
    return {
      status: env.status,
      headers: env.headers || {},
      body: payload.binary ? __b64decode(env.bodyB64 || '') : (env.bodyText || ''),
      blocked: !!env.blocked,
      oversized: !!env.oversized
    };
  },
  fetchText: function (request) {
    request = request || {};
    var env = JSON.parse(__host_fetchText(JSON.stringify({
      url: String(request.url || ''),
      referer: request.referer || '',
      userAgent: request.userAgent || '',
      cookie: request.cookie || '',
      noCache: !!request.noCache,
      body: request.body || '',
      mirrors: request.mirrors || []
    })));
    if (env.error) { throw new Error(env.error); }
    return { body: env.body || '', url: env.url || '' };
  },
  fetchPlaylist: function (request) {
    request = request || {};
    var env = JSON.parse(__host_fetchPlaylist(JSON.stringify({
      url: String(request.url || ''),
      referer: request.referer || '',
      credentials: request.credentials || null
    })));
    if (env.error) { throw new Error(env.error); }
    return {
      playlist: env.playlist || '',
      url: env.url || '',
      durationMs: env.durationMs || 0
    };
  },
  parseUrl: function (raw) {
    var env = JSON.parse(__host_parseUrl(String(raw)));
    if (env.error) { throw new Error(env.error); }
    return env;
  },
  resolveUrl: function (base, ref) {
    var resolved = __host_resolveUrl(String(base), String(ref));
    if (!resolved) { throw new Error('地址无效'); }
    return resolved;
  },
  preferredSite: function () { return ''; },
  exclusive: function (fn) { return fn(); },
  prepareWebMedia: function (media) { return media; },
  finishMedia: function (media) { return media; },
  reserve: function () { throw new Error('reserve 桥暂未实现'); },
  loadState: function (name) {
    var env = JSON.parse(__host_loadState(String(name)));
    if (env.error) { throw new Error(env.error); }
    return env.value;
  },
  saveState: function (name, value) {
    var err = __host_saveState(String(name), String(value));
    if (err) { throw new Error(err); }
  },
  log: function (message) { __host_log(String(message)); },
  retries: function () { return 2; },
  maxPages: function () { return 50; },
  catalogContext: function () { return { more: false, background: false }; },
  isKnown: function () { return false; },
  reportProgress: function () {},
  cacheGet: function (key) {
    var env = JSON.parse(__host_cacheGet(String(key)));
    return env.value === undefined ? null : env.value;
  },
  cacheSet: function (key, value, ttl) {
    __host_cacheSet(
      String(key),
      value === null || value === undefined ? '' : String(value),
      ttl || 0
    );
  },
  preserveIntegers: __preserveIntegers,
  utf8Encode: function (text) { return __utf8Encode(String(text)); },
  utf8Decode: function (data) { return __utf8Decode(__toBytes(data)); },
  hexEncode: function (data) { return __hexEncode(__toBytes(data)); },
  hexDecode: function (text) { return __hexDecode(text); },
  base64Encode: function (data) { return __b64encode(__toBytes(data)); },
  base64Decode: function (text) { return __b64decode(String(text)); },
  md5: function (data) { return __crypto('md5', __b64encode(__toBytes(data))); },
  sha256: function (data) { return __crypto('sha256', __b64encode(__toBytes(data))); },
  sha512: function (data) { return __crypto('sha512', __b64encode(__toBytes(data))); },
  randomBytes: function (size) {
    var env = JSON.parse(__host_randomBytes(size));
    if (env.error) { throw new Error(env.error); }
    return __b64decode(env.result || '');
  },
  aesCbcEncrypt: function (key, iv, data) {
    return __crypto('aesCbcEncrypt',
      __b64encode(__toBytes(key)), __b64encode(__toBytes(iv)), __b64encode(__toBytes(data)));
  },
  aesCbcDecrypt: function (key, iv, data) {
    return __crypto('aesCbcDecrypt',
      __b64encode(__toBytes(key)), __b64encode(__toBytes(iv)), __b64encode(__toBytes(data)));
  },
  sleep: function (milliseconds) { __host_sleep(milliseconds || 0); }
};
"""#

// MARK: - 模块运行时

/// 一个已安装模块的 JS 运行时：与 Go jsProvider 的单实例对应。
/// 模块代码按 Go 的方式包装：(function(module, exports, host) { <main.js> })，
/// 调用走同款 invoker（参数 JSON 编码、结果 JSON 回收、异步函数拒绝）。
/// 全部 JS 执行串行化到一条队列；桥里的网络请求同步阻塞该队列，
/// 与 goja 的同步语义一致（Go 侧最多 4 实例，这里 1 个，差异见 README）。
final class ModuleRuntime {
    let manifest: ModuleManifest
    private let bridge: ModuleHostBridge
    private let context: JSContext
    private var invoker: JSValue!
    private let queue = DispatchQueue(label: "lvguo.module.runtime")
    private var exceptionMessage: String?
    private var exceptionLoginRequired = false

    init(manifest: ModuleManifest, code: String, stateDirectory: URL) throws {
        self.manifest = manifest
        let bridge = ModuleHostBridge(manifest: manifest, stateDirectory: stateDirectory)
        self.bridge = bridge
        guard let context = JSContext() else {
            throw ModuleError.bridge("JSContext 创建失败")
        }
        self.context = context

        context.exceptionHandler = { [weak self] _, exception in
            guard let self, let exception else { return }
            var message = exception.toString() ?? "模块异常"
            var loginRequired = false
            if exception.isObject {
                if let detail = exception.objectForKeyedSubscript("message"),
                   !detail.isUndefined, !detail.isNull,
                   let text = detail.toString() {
                    message = text
                }
                if let flag = exception.objectForKeyedSubscript("loginRequired"),
                   flag.isBoolean {
                    loginRequired = flag.toBool()
                }
            }
            self.exceptionMessage = message
            self.exceptionLoginRequired = loginRequired
        }

        // 注入 __host_* 原生函数（签名只用字符串/数值，保证桥接稳定）
        let fetchBlock: @convention(block) (String) -> String = { json in
            bridge.fetchEnvelope(json)
        }
        context.setObject(fetchBlock, forKeyedSubscript: "__host_fetch" as NSString)
        let fetchTextBlock: @convention(block) (String) -> String = { json in
            bridge.fetchTextEnvelope(json)
        }
        context.setObject(fetchTextBlock, forKeyedSubscript: "__host_fetchText" as NSString)
        let fetchPlaylistBlock: @convention(block) (String) -> String = { json in
            bridge.fetchPlaylistEnvelope(json)
        }
        context.setObject(fetchPlaylistBlock, forKeyedSubscript: "__host_fetchPlaylist" as NSString)
        let parseUrlBlock: @convention(block) (String) -> String = { raw in
            bridge.parseUrlEnvelope(raw)
        }
        context.setObject(parseUrlBlock, forKeyedSubscript: "__host_parseUrl" as NSString)
        let resolveUrlBlock: @convention(block) (String, String) -> String = { base, ref in
            bridge.resolveUrl(base, ref)
        }
        context.setObject(resolveUrlBlock, forKeyedSubscript: "__host_resolveUrl" as NSString)
        let loadStateBlock: @convention(block) (String) -> String = { name in
            bridge.loadStateEnvelope(name)
        }
        context.setObject(loadStateBlock, forKeyedSubscript: "__host_loadState" as NSString)
        let saveStateBlock: @convention(block) (String, String) -> String = { name, value in
            bridge.saveState(name, value)
        }
        context.setObject(saveStateBlock, forKeyedSubscript: "__host_saveState" as NSString)
        let cacheGetBlock: @convention(block) (String) -> String = { key in
            bridge.cacheGetEnvelope(key)
        }
        context.setObject(cacheGetBlock, forKeyedSubscript: "__host_cacheGet" as NSString)
        let cacheSetBlock: @convention(block) (String, String, Double) -> Void = { key, value, ttl in
            bridge.cacheSet(key, value, ttl)
        }
        context.setObject(cacheSetBlock, forKeyedSubscript: "__host_cacheSet" as NSString)
        let logBlock: @convention(block) (String) -> Void = { message in
            bridge.appendLog(message)
        }
        context.setObject(logBlock, forKeyedSubscript: "__host_log" as NSString)
        let sleepBlock: @convention(block) (Double) -> Void = { milliseconds in
            // 对应 Go moduleSleepLimit：单次最长 60 秒
            let clamped = min(max(milliseconds, 0), 60_000)
            Thread.sleep(forTimeInterval: clamped / 1000.0)
        }
        context.setObject(sleepBlock, forKeyedSubscript: "__host_sleep" as NSString)
        let cryptoBlock: @convention(block) (String, String, String, String) -> String = { op, a, b, c in
            bridge.cryptoEnvelope(op, a, b, c)
        }
        context.setObject(cryptoBlock, forKeyedSubscript: "__host_crypto" as NSString)
        let randomBlock: @convention(block) (Double) -> String = { count in
            bridge.randomBytesEnvelope(Int(count))
        }
        context.setObject(randomBlock, forKeyedSubscript: "__host_randomBytes" as NSString)

        // shim 建好 host 对象并写入源标识（id 已通过清单正则校验，可安全内插）
        context.evaluateScript(moduleHostShim)
        context.evaluateScript("__hostObject.source = '\(manifest.id)';")
        if let message = exceptionMessage {
            throw ModuleError.js(message: message, loginRequired: false)
        }

        // 与 Go parseModule 相同的包装方式加载模块代码
        let wrapperSource = "(function(module, exports, host) {\n" + code + "\n})"
        guard let wrapper = context.evaluateScript(wrapperSource),
              !wrapper.isUndefined, !wrapper.isNull else {
            throw ModuleError.js(
                message: exceptionMessage ?? "模块代码加载失败", loginRequired: false
            )
        }
        guard let moduleObject = context.evaluateScript("({ exports: {} })"),
              let exports = moduleObject.objectForKeyedSubscript("exports"),
              let hostObject = context.objectForKeyedSubscript("__hostObject") else {
            throw ModuleError.bridge("模块上下文初始化失败")
        }
        exceptionMessage = nil
        _ = wrapper.call(withArguments: [moduleObject, exports, hostObject])
        if let message = exceptionMessage {
            throw ModuleError.js(message: message, loginRequired: exceptionLoginRequired)
        }
        guard let liveExports = moduleObject.objectForKeyedSubscript("exports") else {
            throw ModuleError.bridge("模块 exports 丢失")
        }
        // 与 Go moduleInvoker 相同的调用器
        let invokerSource = """
        (function(exports) {
            return function(name, encoded) {
                var target = exports[name];
                if (typeof target !== 'function') throw new Error('模块未导出函数 ' + name);
                var result = target.apply(exports, JSON.parse(encoded));
                if (result instanceof Promise) throw new Error('模块函数 ' + name + ' 不能是异步函数');
                return JSON.stringify(result === undefined ? null : result);
            };
        })
        """
        guard let factory = context.evaluateScript(invokerSource),
              let bound = factory.call(withArguments: [liveExports]),
              !bound.isUndefined, !bound.isNull else {
            throw ModuleError.bridge("模块调用器绑定失败")
        }
        invoker = bound
    }

    /// 调用一个模块导出函数：参数/结果都走 JSON（同 Go call）。
    /// 在运行时串行队列上同步执行（含桥里的阻塞网络请求），故做成 async 抛出到后台。
    func call(_ function: String, arguments: [Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try invokeSync(function, arguments))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func invokeSync(_ function: String, _ arguments: [Any]) throws -> Any? {
        let argsData = try JSONSerialization.data(withJSONObject: arguments)
        let argsString = String(decoding: argsData, as: UTF8.self)
        exceptionMessage = nil
        exceptionLoginRequired = false
        let result = invoker.call(withArguments: [function, argsString])
        if let message = exceptionMessage {
            throw ModuleError.js(message: message, loginRequired: exceptionLoginRequired)
        }
        guard let result, !result.isUndefined, !result.isNull else {
            return nil
        }
        let text = result.toString() ?? "null"
        if text == "null" {
            return nil
        }
        return try JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [.allowFragments]
        )
    }

    func recentLogs() -> [String] {
        bridge.logs
    }
}
