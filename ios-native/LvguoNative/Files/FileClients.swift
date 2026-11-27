import Foundation

/// 文件源客户端统一接口：浏览页只认这个接口，不感知底层是
/// WebDAV、FTP 还是原生网盘（与 Dart FileSourceClient 对齐）。
protocol FileSourceClient {
    /// 列 path 目录（nil = 源根目录）
    func list(_ path: String?) async throws -> [FileEntry]
    /// 取 entry 的可播放地址（原生网盘现取临时地址）
    func target(_ entry: FileEntry) async throws -> FilePlayTarget
    /// entry 的进度键：WebDAV 是解析后的完整 URL，FTP/原生是
    /// 「src:<源ID>:<类型>:<定位符>」
    func progressKey(_ entry: FileEntry) -> String
}

func createFileSourceClient(_ source: FileSource) -> FileSourceClient {
    if source.nativeMode {
        return source.type == .tianyi
            ? TianyiSourceClient(source: source)
            : MobileSourceClient(source: source)
    }
    if source.type == .ftp {
        return FtpSourceClient(source: source)
    }
    return WebDavSourceClient(source: source)
}

/// 带超时的共享会话（文件源请求统一 20 秒量级，与 Dart 一致）。
/// 全局代理（资源设置）通过 ProxySettings 快照接入：代理
/// generation 变化时重建会话，改完即生效。
enum FileNetwork {
    private static var cachedSession: URLSession?
    private static var cachedGeneration = -1
    private static let lock = NSLock()

    static var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        let generation = ProxySettings.generation
        if let cachedSession, cachedGeneration == generation {
            return cachedSession
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        ProxySettings.configure(
            config, effective: ProxySettings.effective(forModule: nil)
        )
        let created = URLSession(configuration: config)
        cachedSession = created
        cachedGeneration = generation
        return created
    }

    static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FileSourceFailure("服务器响应异常")
            }
            return (data, http)
        } catch let error as FileSourceFailure {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw FileSourceFailure("连接超时，请检查网络")
        } catch {
            throw FileSourceFailure("连不上服务器，请检查网络")
        }
    }
}

/// 原生网盘客户端共用的 JSON 请求：非 200、非 JSON、网络错误都翻成
/// FileSourceFailure，且带服务器原始返回片段（同 Dart jsonRequest）。
func jsonRequest(
    _ url: URL,
    method: String = "GET",
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = method
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
    }
    let (data, http) = try await FileNetwork.data(for: request)
    let text = String(data: data, encoding: .utf8) ?? ""
    guard http.statusCode == 200 else {
        throw FileSourceFailure("服务器返回 \(http.statusCode)：\(excerptText(text))")
    }
    if let decoded = try? JSONSerialization.jsonObject(with: data),
       let dict = decoded as? [String: Any] {
        return dict
    }
    throw FileSourceFailure("服务器返回了无法解析的内容：\(excerptText(text))")
}

// MARK: - WebDAV

/// 极简 WebDAV 客户端：只做 PROPFIND 列目录，响应 XML 去掉命名
/// 空间前缀后正则解析（逻辑逐项对齐 Dart WebDavClient）。
struct WebDavClient {
    let source: FileSource

    var base: URL {
        var server = source.server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !server.contains("://") {
            server = "http://" + server
        }
        return URL(string: server) ?? URL(string: "http://localhost")!
    }

    /// 把 href 拼成完整 URL：href 可能是服务器绝对路径、完整 URL
    /// （只取路径）、或相对路径（按源根目录所在目录解析）。href 是
    /// URL 编码形态，先解码再统一编码，避免中文/空格被二次编码。
    func resolve(_ href: String) -> URL {
        let baseURL = base
        var path = href
        if let parsed = URL(string: href), parsed.scheme != nil {
            path = parsed.path
        }
        if !path.hasPrefix("/") {
            var dir = baseURL.path
            if !dir.hasSuffix("/") {
                if let cut = dir.lastIndex(of: "/") {
                    dir = String(dir[...cut])
                } else {
                    dir = "/"
                }
            }
            path = dir + path
        }
        let decoded = path.removingPercentEncoding ?? path
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = decoded
        return components.url ?? baseURL
    }

    /// 列 href 目录（nil 表示源根目录，即服务器地址本身）
    func list(_ href: String?) async throws -> [FileEntry] {
        let target = href == nil ? base : resolve(href!)
        var request = URLRequest(url: target)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        for (key, value) in source.authHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(
            "application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data(
            ("<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
             "<propfind xmlns=\"DAV:\"><prop>" +
             "<displayname/><resourcetype/><getcontenttype/><getcontentlength/>" +
             "</prop></propfind>").utf8
        )
        let (data, http) = try await FileNetwork.data(for: request)
        if http.statusCode == 401 {
            throw FileSourceFailure("账号或密码不正确（服务器返回 401）")
        }
        guard http.statusCode == 207 || http.statusCode == 200 else {
            throw FileSourceFailure("服务器返回 \(http.statusCode)，无法列出目录")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return Self.parsePropfind(body, target: target)
    }

    /// 解析 multistatus 响应（对齐 Dart parsePropfind）
    static func parsePropfind(_ xml: String, target: URL) -> [FileEntry] {
        let plain = xml.replacingOccurrences(
            of: "<(/?)[A-Za-z0-9]+:", with: "<$1",
            options: .regularExpression
        )
        func field(_ block: String, _ tag: String) -> String {
            guard let regex = try? NSRegularExpression(
                pattern: "<\(tag)>([^<]*)</\(tag)>"
            ) else { return "" }
            let range = NSRange(block.startIndex..., in: block)
            guard let match = regex.firstMatch(in: block, range: range),
                  let valueRange = Range(match.range(at: 1), in: block) else {
                return ""
            }
            return String(block[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func normalize(_ path: String) -> String {
            var value = path.removingPercentEncoding ?? path
            if value.count > 1, value.hasSuffix("/") {
                value = String(value.dropLast())
            }
            return value
        }
        let selfPath = normalize(target.path)
        var entries: [FileEntry] = []
        guard let blockRegex = try? NSRegularExpression(
            pattern: "<response>(.*?)</response>", options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let fullRange = NSRange(plain.startIndex..., in: plain)
        for match in blockRegex.matches(in: plain, range: fullRange) {
            guard let blockRange = Range(match.range(at: 1), in: plain) else { continue }
            let block = String(plain[blockRange])
            let rawHref = field(block, "href")
            if rawHref.isEmpty { continue }
            var path = rawHref
            if let parsed = URL(string: rawHref), parsed.scheme != nil {
                path = parsed.path
            }
            if !path.hasPrefix("/") {
                var dir = target.path
                if !dir.hasSuffix("/") {
                    if let cut = dir.lastIndex(of: "/") {
                        dir = String(dir[...cut])
                    } else {
                        dir = "/"
                    }
                }
                path = dir + path
            }
            if normalize(path) == selfPath { continue }
            let isDirectory = block.contains("<collection")
            var name = field(block, "displayname")
            if name.isEmpty {
                name = normalize(path).split(separator: "/").last.map(String.init) ?? ""
            } else {
                name = name.removingPercentEncoding ?? name
            }
            entries.append(FileEntry(
                name: name,
                href: path,
                isDirectory: isDirectory,
                contentType: field(block, "getcontenttype"),
                size: Int64(field(block, "getcontentlength")) ?? 0
            ))
        }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.lowercased() < $1.name.lowercased()
        }
        return entries
    }
}

/// WebDAV 客户端的统一接口包装（含天翼/移动的 WebDAV 挂载模式）
struct WebDavSourceClient: FileSourceClient {
    let source: FileSource
    private let dav: WebDavClient

    init(source: FileSource) {
        self.source = source
        self.dav = WebDavClient(source: source)
    }

    func list(_ path: String?) async throws -> [FileEntry] {
        try await dav.list(path)
    }

    func target(_ entry: FileEntry) async throws -> FilePlayTarget {
        FilePlayTarget(url: dav.resolve(entry.href).absoluteString, headers: source.authHeaders)
    }

    func progressKey(_ entry: FileEntry) -> String {
        dav.resolve(entry.href).absoluteString
    }
}
