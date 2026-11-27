import Foundation
import JavaScriptCore

enum ModuleError: Error, CustomStringConvertible, LocalizedError {
    case js(message: String, loginRequired: Bool)
    case bridge(String)

    var description: String {
        switch self {
        case .js(let message, _): return message
        case .bridge(let message): return message
        }
    }

    /// 必须实现 LocalizedError：否则 localizedDescription 只剩
    /// 「The operation couldn't be completed. (…ModuleError error 0.)」，
    /// JS 异常原文到不了 UI（真机首测实证）。
    var errorDescription: String? { description }

    var loginRequired: Bool {
        if case .js(_, let required) = self { return required }
        return false
    }
}

/// 模块级共享状态：同一模块的全部运行时实例共用一份
/// （对齐 Go jsProvider——cache/日志/reserve 票据/exclusive
/// 锁都是 provider 级，实例只是 JS 虚拟机的个数）。
final class ModuleSharedState {
    var cache: [String: (value: String, expires: Date?)] = [:]
    var logs: [String] = []
    var ticketCounter = 0
    var issuedTickets = Set<Int>()
    /// host.exclusive 的跨实例串行锁（递归锁：嵌套 exclusive
    /// 时不自锁死；Go 的 channel 信号量嵌套会死锁，此处放宽）
    let exclusiveLock = NSRecursiveLock()
    let lock = NSLock()
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
    let shared: ModuleSharedState

    var logs: [String] {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.logs
    }

    init(
        manifest: ModuleManifest, stateDirectory: URL,
        shared: ModuleSharedState = ModuleSharedState()
    ) {
        self.manifest = manifest
        self.stateDirectory = stateDirectory
        self.shared = shared
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
        shared.lock.lock()
        shared.logs.append(message)
        if shared.logs.count > 200 {
            shared.logs.removeFirst(shared.logs.count - 200)
        }
        shared.lock.unlock()
        print("[Module \(manifest.id)] \(message)")
    }

    // MARK: - 同步 HTTP（在 JS 执行线程上阻塞等待，与 goja 的同步语义一致）

    private enum FetchOutcome {
        case success(Data, HTTPURLResponse)
        case failure(String)
    }

    /// 重定向闸门，对齐 Go Fetch 的策略：
    /// - followRedirects=true：跟随全部跳转（URLSession 默认行为）；
    /// - false（模块没声明时的 Go 默认）：只跟同源跳转，跨源跳转
    ///   把 3xx 响应本身交回模块（Go 是直接报「重定向地址异常」，
    ///   这里交回响应让模块能读 Location 自己处理，是更宽容的近似）。
    private final class RedirectGate: NSObject, URLSessionTaskDelegate {
        let sameOriginOnly: Bool

        init(sameOriginOnly: Bool) {
            self.sameOriginOnly = sameOriginOnly
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard sameOriginOnly,
                  let from = task.originalRequest?.url,
                  let to = request.url,
                  !Self.sameOrigin(from, to) else {
                completionHandler(request)
                return
            }
            completionHandler(nil)
        }

        static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
            func port(_ url: URL) -> Int {
                if let port = url.port { return port }
                return url.scheme == "https" ? 443 : 80
            }
            return a.scheme == b.scheme
                && a.host == b.host
                && port(a) == port(b)
        }
    }

    private lazy var followSession = URLSession(
        configuration: .default,
        delegate: RedirectGate(sameOriginOnly: false),
        delegateQueue: nil
    )
    private lazy var sameOriginSession = URLSession(
        configuration: .default,
        delegate: RedirectGate(sameOriginOnly: true),
        delegateQueue: nil
    )

    private func perform(
        _ request: URLRequest, timeout: TimeInterval, followRedirects: Bool = true
    ) -> FetchOutcome {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: FetchOutcome = .failure("请求未完成")
        let session = followRedirects ? followSession : sameOriginSession
        let task = session.dataTask(with: request) { data, response, error in
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
        // 带 ticket 的请求先消费名额（Go takeReservation：一次性，
        // 不存在直接报「站源请求名额已失效」）
        let ticket = JSON.dictInt(payload["ticket"])
        if ticket > 0 {
            shared.lock.lock()
            let consumed = shared.issuedTickets.remove(ticket) != nil
            shared.lock.unlock()
            if !consumed {
                return envelope(["error": "站源请求名额已失效"])
            }
        }
        let timeoutMs = JSON.dictInt(payload["timeoutMs"])
        request.timeoutInterval = timeoutMs > 0 ? Double(timeoutMs) / 1000.0 : 30
        let limitValue = JSON.dictInt(payload["limit"])
        let limit = limitValue > 0 ? limitValue : 4 << 20
        let binary = JSON.dictBool(payload["binary"])
        let anyStatus = JSON.dictBool(payload["anyStatus"])
        let followRedirects = JSON.dictBool(payload["followRedirects"])
        let acceptStatus = (payload["acceptStatus"] as? [Any] ?? [])
            .map { JSON.dictInt($0) }

        switch perform(
            request, timeout: request.timeoutInterval, followRedirects: followRedirects
        ) {
        case .failure(let message):
            return envelope(["error": "\(manifest.name)连接失败：\(message)"])
        case .success(let data, let response):
            let status = response.statusCode
            var headers: [String: [String]] = [:]
            for (key, value) in response.allHeaderFields {
                headers[String(describing: key)] = ["\(value)"]
            }
            // Go：超限只回 Oversized 标记与错误，不带正文与状态码
            if data.count > limit {
                return envelope([
                    "error": "\(manifest.name)返回的数据过大或读取失败",
                    "oversized": true,
                ])
            }
            // 拦截判定（Go catalogResponseBlockReason）：命中后
            // 除非 anyStatus，否则与非 2xx 一样按失败处理，
            // 错误文案走 catalogResponseError 的格式
            let reason = Self.blockReason(
                headers: response.allHeaderFields, body: data
            )
            let blocked = !reason.isEmpty
            let acceptedByList = !blocked && acceptStatus.contains(status)
                && (try? JSONSerialization.jsonObject(with: data)) != nil
            let acceptable = anyStatus || acceptedByList
                || ((200...299).contains(status) && !blocked)
            guard acceptable else {
                return envelope([
                    "error": Self.responseErrorText(
                        host: host, status: status, reason: reason
                    ),
                    "status": status,
                    "bodyText": String(decoding: data, as: UTF8.self),
                    "blocked": blocked,
                ])
            }
            var result: [String: Any] = [
                "status": status, "headers": headers, "blocked": blocked,
            ]
            if binary {
                result["bodyB64"] = data.base64EncodedString()
            } else {
                result["bodyText"] = String(decoding: data, as: UTF8.self)
            }
            return envelope(result)
        }
    }

    /// 响应拦截判定，逐行对齐 Go catalogResponseBlockReason：
    /// 只看正文前 64KB（小写后子串匹配）与 Cf-Mitigated 头，
    /// 返回拦截原因（空串 = 未拦截）。
    static func blockReason(headers: [AnyHashable: Any], body: Data) -> String {
        let page = String(decoding: body.prefix(64 * 1024), as: UTF8.self)
            .lowercased()
        var cfMitigated = ""
        for (key, value) in headers
        where String(describing: key).lowercased() == "cf-mitigated" {
            cfMitigated = "\(value)"
        }
        if page.contains("cloudflare"),
           page.contains("sorry, you have been blocked")
            || page.contains("you are unable to access") {
            return "Cloudflare 拒绝了当前请求"
        }
        if cfMitigated.lowercased() == "challenge"
            || page.contains("_cf_chl_opt")
            || (page.contains("<title>just a moment") && page.contains("cloudflare")) {
            return "站点要求浏览器验证，当前请求无法通过"
        }
        return ""
    }

    /// Go catalogResponseError 的文案：host HTTP 状态[：拦截原因]
    static func responseErrorText(host: String, status: Int, reason: String) -> String {
        reason.isEmpty
            ? "\(host) HTTP \(status)"
            : "\(host) HTTP \(status)：\(reason)"
    }

    // MARK: - host.reserve（请求名额：Go 侧是限流票据，原生无限制器，
    // 只做地址校验 + 发号，fetch 时一次性消费，语义对模块等价；
    // 票据是 provider 级，同模块全部实例共用一份）

    func reserveEnvelope(_ json: String) -> String {
        guard let payload = parsePayload(json) else {
            return envelope(["error": "请求参数无效"])
        }
        let urlString = JSON.dictString(payload["url"])
        guard let url = URL(string: urlString),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return envelope(["error": "请求地址无效"])
        }
        guard manifest.allowsHost(host) else {
            return envelope(["error": "模块清单未声明访问 \(host)"])
        }
        shared.lock.lock()
        shared.ticketCounter += 1
        let ticket = shared.ticketCounter
        shared.issuedTickets.insert(ticket)
        shared.lock.unlock()
        return envelope(["ticket": ticket])
    }

    /// Go 核心的默认 UA（config_defaults.go UserAgent）
    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 " +
        "Mobile/15E148 Safari/604.1"

    // MARK: - host.fetchText

    /// 逐项对齐 Go fetchProviderRequest（FetchText 的底层）：
    /// 候选 = 主地址 + mirrors（未声明 hosts 的镜像被过滤、
    /// 去重）；多候选时每个只试 1 次、单次超时 5 秒，单候选
    /// 时试 cfg.Retries 次（默认 2)、超时 ProviderTimeout
    /// 12 秒，重试前按尝试序号秒数退避；被拦截或 4xx（408
    /// 除外）立即放弃当前候选；多候选全败的错误文案带
    /// 「已尝试 N 个域名」。
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
        var referer = JSON.dictString(payload["referer"])
        if referer.isEmpty { referer = urlString }
        let userAgent = JSON.dictString(payload["userAgent"])
        let cookie = JSON.dictString(payload["cookie"])
        let noCache = JSON.dictBool(payload["noCache"])
        let body = JSON.dictString(payload["body"])
        var candidates = [urlString]
        for mirror in payload["mirrors"] as? [Any] ?? [] {
            let mirrorString = JSON.dictString(mirror)
            if let mirrorURL = URL(string: mirrorString),
               let mirrorHost = mirrorURL.host,
               manifest.allowsHost(mirrorHost),
               !candidates.contains(mirrorString) {
                candidates.append(mirrorString)
            }
        }
        let multiple = candidates.count > 1
        let attemptsPerCandidate = multiple ? 1 : 2
        let timeout: TimeInterval = multiple ? 5 : 12
        var lastError = "请求失败"
        var tried = 0
        for candidate in candidates {
            guard let candidateURL = URL(string: candidate) else { continue }
            for attempt in 1...attemptsPerCandidate {
                tried += 1
                if attempt > 1 {
                    Thread.sleep(forTimeInterval: Double(attempt))
                }
                var request = URLRequest(url: candidateURL)
                request.httpMethod = body.isEmpty ? "GET" : "POST"
                request.timeoutInterval = timeout
                request.setValue(
                    userAgent.isEmpty ? Self.defaultUserAgent : userAgent,
                    forHTTPHeaderField: "User-Agent"
                )
                request.setValue(referer, forHTTPHeaderField: "Referer")
                request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
                if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
                if noCache { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
                if !body.isEmpty {
                    request.httpBody = Data(body.utf8)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                }
                var abandonCandidate = false
                switch perform(request, timeout: timeout) {
                case .failure(let message):
                    lastError = message
                case .success(let data, let response):
                    let status = response.statusCode
                    let reason = Self.blockReason(
                        headers: response.allHeaderFields, body: data
                    )
                    if (200...299).contains(status), reason.isEmpty {
                        return envelope([
                            "body": String(decoding: data, as: UTF8.self),
                            "url": response.url?.absoluteString ?? candidate,
                        ])
                    }
                    lastError = Self.responseErrorText(
                        host: candidateURL.host ?? host, status: status, reason: reason
                    )
                    if !reason.isEmpty
                        || (400..<500).contains(status) && status != 408 {
                        abandonCandidate = true
                    }
                }
                if abandonCandidate { break }
            }
        }
        if multiple {
            return envelope([
                "error": "站源请求失败：已尝试 \(tried) 个域名，最后错误：\(lastError)"
            ])
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
            // 对齐 Go fetchMediaPlaylist：恰好 200、未被拦截、
            // 不超 4MB、正文（去 BOM/空白后）以 #EXTM3U 开头，
            // 否则分别报 catalogResponseError / PlaylistError 文案
            if data.count > 4 << 20 {
                return envelope(["error": "播放列表过大或读取失败"])
            }
            let reason = Self.blockReason(
                headers: response.allHeaderFields, body: data
            )
            guard response.statusCode == 200, reason.isEmpty else {
                return envelope(["error": Self.responseErrorText(
                    host: url.host ?? "", status: response.statusCode, reason: reason
                )])
            }
            let playlist = String(decoding: data, as: UTF8.self)
            let trimmed = playlist
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#EXTM3U") else {
                return envelope(["error": "站源未返回有效的播放列表，链接可能已失效"])
            }
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

    // MARK: - host.prepareWebMedia / finishMedia

    /// 拉播放列表原文（带凭据头），失败把具体错误带回来
    /// （对齐 Go fetchMediaPlaylist 的错误原文，不再吞成一句
    /// 「拉取失败」）。说明：Go 的 fetchMediaPlaylist 本身也是
    /// 单地址直拉（doMediaRequest 无域名轮换），多候选轮换只
    /// 存在于文本抓取 fetchProviderRequest——已在 fetchText
    /// 里对齐，故这里单地址即与 Go 等价。
    private func fetchPlaylistRaw(
        urlString: String, referer: String, credentials: MediaCredentials?
    ) -> (playlist: String, finalURL: String, error: String?) {
        guard let url = URL(string: urlString) else {
            return ("", "", "播放列表地址无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        var effectiveReferer = referer
        if let credentials {
            if !credentials.cookie.isEmpty {
                request.setValue(credentials.cookie, forHTTPHeaderField: "Cookie")
            }
            if !credentials.userAgent.isEmpty {
                request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
            }
            if !credentials.origin.isEmpty {
                request.setValue(credentials.origin, forHTTPHeaderField: "Origin")
            }
            if effectiveReferer.isEmpty {
                effectiveReferer = credentials.referer
            }
        }
        if !effectiveReferer.isEmpty {
            request.setValue(effectiveReferer, forHTTPHeaderField: "Referer")
        }
        switch perform(request, timeout: 30) {
        case .failure(let message):
            return ("", "", message)
        case .success(let data, let response):
            if data.count > 4 << 20 {
                return ("", "", "播放列表过大或读取失败")
            }
            let reason = Self.blockReason(
                headers: response.allHeaderFields, body: data
            )
            guard response.statusCode == 200, reason.isEmpty else {
                return ("", "", Self.responseErrorText(
                    host: url.host ?? "", status: response.statusCode, reason: reason
                ))
            }
            return (
                playlist: String(decoding: data, as: UTF8.self),
                finalURL: response.url?.absoluteString ?? urlString,
                error: nil
            )
        }
    }

    /// 对齐 Go prepareWebProviderMedia / finishProviderMedia：
    /// 地址必须是 http(s) 且无 userinfo；.m3u8 时拉列表回填
    /// playlist/url/durationMs 并校验 #EXTM3U。两者的报错文案
    /// 在 Go 里不同（连空格/标点都不一样），按 finish 标志分别用。
    func webMediaEnvelope(_ json: String, sourceName: String, finish: Bool) -> String {
        guard var media = parsePayload(json) else {
            return envelope(["error": "播放信息无效"])
        }
        let urlString = JSON.dictString(media["url"])
        let parsed = URL(string: urlString)
        let isMediaURL = parsed != nil
            && (parsed!.scheme == "http" || parsed!.scheme == "https")
            && !(parsed!.host ?? "").isEmpty
            && parsed!.user == nil && parsed!.password == nil
        guard isMediaURL, let url = parsed else {
            return envelope(["error": finish
                ? "\(sourceName) 未返回有效播放地址，请刷新章节或确认站点访问权限"
                : "\(sourceName)未返回有效播放地址，请刷新详情后重试"])
        }
        if url.path.lowercased().hasSuffix(".m3u8") {
            let credentials = MediaCredentials.parse(media["credentials"])
            let fetched = fetchPlaylistRaw(
                urlString: urlString,
                referer: JSON.dictString(media["referer"]),
                credentials: credentials
            )
            if let fetchError = fetched.error {
                return envelope(["error": finish
                    ? "获取播放列表失败: \(fetchError)"
                    : "获取\(sourceName)播放列表失败：\(fetchError)"])
            }
            let trimmed = fetched.playlist
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#EXTM3U") else {
                return envelope(["error": finish
                    ? "站点未返回有效 M3U8，可能需要登录或链接已失效"
                    : "\(sourceName)播放列表无效，请重新解析播放"])
            }
            media["playlist"] = fetched.playlist
            media["url"] = fetched.finalURL
            var seconds = 0.0
            for line in fetched.playlist.split(separator: "\n") {
                if line.hasPrefix("#EXTINF:") {
                    let raw = line.dropFirst("#EXTINF:".count)
                        .split(separator: ",").first ?? ""
                    seconds += Double(raw) ?? 0
                }
            }
            if seconds > 0 {
                media["durationMs"] = Int(seconds * 1000)
            }
        }
        return envelope(["media": media])
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
        // 对齐 Go LoadState：状态文件不存在返回空串、不报错
        //（模块首次运行先读后写是常态，报错会把整条链路打断）
        let file = stateFileURL(name)
        guard let data = try? Data(contentsOf: file) else {
            return envelope(["value": ""])
        }
        return envelope(["value": String(decoding: data, as: UTF8.self)])
    }

    /// 返回空串表示成功，否则是错误信息（shim 负责抛错）
    func saveState(_ name: String, _ value: String) -> String {
        // 对齐 Go SaveState：空值 = 删除状态文件
        if value.isEmpty {
            try? FileManager.default.removeItem(at: stateFileURL(name))
            return ""
        }
        do {
            try Data(value.utf8).write(to: stateFileURL(name))
            return ""
        } catch {
            return "状态保存失败"
        }
    }

    // MARK: - host.cacheGet / cacheSet（内存缓存，语义同 Go moduleCache）

    func cacheGetEnvelope(_ key: String) -> String {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        if let entry = shared.cache[key] {
            if let expires = entry.expires, expires < Date() {
                shared.cache[key] = nil
            } else {
                return envelope(["value": entry.value])
            }
        }
        return envelope(["value": NSNull()])
    }

    func cacheSet(_ key: String, _ value: String, _ ttlMs: Double) {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        // Go：空值即删键
        if value.isEmpty {
            shared.cache[key] = nil
            return
        }
        let expires = ttlMs > 0 ? Date().addingTimeInterval(ttlMs / 1000.0) : nil
        shared.cache[key] = (value: value, expires: expires)
    }

    // MARK: - host 加密/摘要（入参出参均为 base64）

    func cryptoEnvelope(_ op: String, _ a: String, _ b: String, _ c: String, _ d: String) -> String {
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
            case "aesGcmSeal", "aesGcmOpen":
                guard let key = bytes(a), let nonce = bytes(b),
                      let data = bytes(c), let extra = bytes(d) else {
                    throw CryptoUtils.CryptoError.message("Base64 内容无效")
                }
                result = op == "aesGcmSeal"
                    ? try CryptoUtils.aesGcmSeal(key: key, nonce: nonce, plain: data, extra: extra)
                    : try CryptoUtils.aesGcmOpen(key: key, nonce: nonce, sealed: data, extra: extra)
            case "ecdhP256":
                guard let privateKey = bytes(a), let publicKey = bytes(b) else {
                    throw CryptoUtils.CryptoError.message("Base64 内容无效")
                }
                result = try CryptoUtils.ecdhP256(privateKey: privateKey, publicKey: publicKey)
            case "hkdfSha256":
                // d 是十进制长度字符串（不是 base64），与 Go 的 length 参数对应
                guard let secret = bytes(a), let salt = bytes(b), let info = bytes(c),
                      let length = Int(d) else {
                    throw CryptoUtils.CryptoError.message("Base64 内容无效")
                }
                result = try CryptoUtils.hkdfSha256(
                    secret: secret, salt: salt, info: info, length: length
                )
            default:
                throw CryptoUtils.CryptoError.message("未知的加密操作 \(op)")
            }
            return envelope(["result": result.base64EncodedString()])
        } catch {
            return envelope(["error": "\(error)"])
        }
    }

    func ecdhKeyPairEnvelope() -> String {
        do {
            let pair = try CryptoUtils.ecdhP256KeyPair()
            return envelope([
                "privateKey": pair.privateKey.base64EncodedString(),
                "publicKey": pair.publicKey.base64EncodedString(),
            ])
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
function __crypto(op, a, b, c, d) {
  var env = JSON.parse(__host_crypto(op, a || '', b || '', c || '', d || ''));
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

var __crcTable = null;
function __crc32(data) {
  if (!__crcTable) {
    __crcTable = [];
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      __crcTable[n] = c >>> 0;
    }
  }
  var crc = 0xFFFFFFFF;
  for (var i = 0; i < data.length; i++) {
    crc = __crcTable[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}
function __gzipBytes(data) {
  // stored（不压缩）deflate 块包 gzip 格式：输出是合法 gzip，
  // 只是体积不减小；对应 Go gzip 的语义（内容一致）足够模块用。
  var out = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff];
  var offset = 0;
  do {
    var chunk = Math.min(65535, data.length - offset);
    var last = offset + chunk >= data.length;
    out.push(last ? 1 : 0, chunk & 0xff, (chunk >> 8) & 0xff,
      (~chunk) & 0xff, ((~chunk) >> 8) & 0xff);
    for (var i = 0; i < chunk; i++) out.push(data[offset + i]);
    offset += chunk;
  } while (offset < data.length);
  var crc = __crc32(data);
  out.push(crc & 0xff, (crc >> 8) & 0xff, (crc >> 16) & 0xff, (crc >> 24) & 0xff);
  var size = data.length >>> 0;
  out.push(size & 0xff, (size >> 8) & 0xff, (size >> 16) & 0xff, (size >> 24) & 0xff);
  return new Uint8Array(out);
}
var __INFLATE_LIMIT = 20 * 1024 * 1024;
function __inflateTo(data, out) {
  var pos = 0;
  var bitBuffer = 0;
  var bitCount = 0;
  function readBit() {
    if (bitCount === 0) {
      if (pos >= data.length) throw new Error('gzip 内容无效');
      bitBuffer = data[pos++];
      bitCount = 8;
    }
    var bit = bitBuffer & 1;
    bitBuffer >>= 1;
    bitCount--;
    return bit;
  }
  function readBits(count) {
    var value = 0;
    for (var i = 0; i < count; i++) value |= readBit() << i;
    return value;
  }
  function buildHuffman(lengths) {
    var maxBits = 0;
    var i;
    for (i = 0; i < lengths.length; i++) {
      if (lengths[i] > maxBits) maxBits = lengths[i];
    }
    var counts = [];
    for (i = 0; i <= maxBits; i++) counts.push(0);
    for (i = 0; i < lengths.length; i++) {
      if (lengths[i]) counts[lengths[i]]++;
    }
    var offsets = [0, 0];
    for (i = 1; i <= maxBits; i++) offsets[i + 1] = offsets[i] + counts[i];
    var symbols = new Array(lengths.length);
    var next = offsets.slice();
    for (i = 0; i < lengths.length; i++) {
      if (lengths[i]) symbols[next[lengths[i]]++] = i;
    }
    return { counts: counts, symbols: symbols, maxBits: maxBits };
  }
  function decodeSymbol(huffman) {
    var code = 0;
    var first = 0;
    var index = 0;
    for (var len = 1; len <= huffman.maxBits; len++) {
      code |= readBit();
      var count = huffman.counts[len] || 0;
      if (code - first < count) return huffman.symbols[index + (code - first)];
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    throw new Error('gzip 内容无效');
  }
  var lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
  var lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
  var distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289,
    16385, 24577];
  var distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
  function inflateBlock(litHuffman, distHuffman) {
    for (;;) {
      var symbol = decodeSymbol(litHuffman);
      if (symbol < 256) {
        out.push(symbol);
      } else if (symbol === 256) {
        return;
      } else {
        var idx = symbol - 257;
        if (idx >= 29) throw new Error('gzip 内容无效');
        var length = lengthBase[idx] + readBits(lengthExtra[idx]);
        var distSymbol = decodeSymbol(distHuffman);
        if (distSymbol >= 30) throw new Error('gzip 内容无效');
        var dist = distBase[distSymbol] + readBits(distExtra[distSymbol]);
        if (dist > out.length) throw new Error('gzip 内容无效');
        var start = out.length - dist;
        for (var i = 0; i < length; i++) out.push(out[start + i]);
      }
      if (out.length > __INFLATE_LIMIT) throw new Error('解压后内容过大');
    }
  }
  for (;;) {
    var bfinal = readBits(1);
    var btype = readBits(2);
    if (btype === 0) {
      bitCount = 0;
      if (pos + 4 > data.length) throw new Error('gzip 内容无效');
      var len = data[pos] | (data[pos + 1] << 8);
      pos += 4;
      if (pos + len > data.length) throw new Error('gzip 内容无效');
      for (var i = 0; i < len; i++) out.push(data[pos + i]);
      pos += len;
      if (out.length > __INFLATE_LIMIT) throw new Error('解压后内容过大');
    } else if (btype === 1 || btype === 2) {
      var litHuffman;
      var distHuffman;
      if (btype === 1) {
        var fixedLit = [];
        var s;
        for (s = 0; s < 288; s++) {
          fixedLit.push(s < 144 ? 8 : s < 256 ? 9 : s < 280 ? 7 : 8);
        }
        var fixedDist = [];
        for (s = 0; s < 32; s++) fixedDist.push(5);
        litHuffman = buildHuffman(fixedLit);
        distHuffman = buildHuffman(fixedDist);
      } else {
        var hlit = readBits(5) + 257;
        var hdist = readBits(5) + 1;
        var hclen = readBits(4) + 4;
        var order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
        var codeLengths = [];
        var ci;
        for (ci = 0; ci < 19; ci++) codeLengths.push(0);
        for (ci = 0; ci < hclen; ci++) codeLengths[order[ci]] = readBits(3);
        var codeHuffman = buildHuffman(codeLengths);
        var lengths = [];
        while (lengths.length < hlit + hdist) {
          var sym = decodeSymbol(codeHuffman);
          if (sym < 16) {
            lengths.push(sym);
          } else if (sym === 16) {
            if (lengths.length === 0) throw new Error('gzip 内容无效');
            var prev = lengths[lengths.length - 1];
            var repeat = 3 + readBits(2);
            for (var r = 0; r < repeat; r++) lengths.push(prev);
          } else if (sym === 17) {
            var zeros = 3 + readBits(3);
            for (var z = 0; z < zeros; z++) lengths.push(0);
          } else {
            var zeros2 = 11 + readBits(7);
            for (var z2 = 0; z2 < zeros2; z2++) lengths.push(0);
          }
        }
        if (lengths.length !== hlit + hdist) throw new Error('gzip 内容无效');
        litHuffman = buildHuffman(lengths.slice(0, hlit));
        distHuffman = buildHuffman(lengths.slice(hlit));
      }
      inflateBlock(litHuffman, distHuffman);
    } else {
      throw new Error('gzip 内容无效');
    }
    if (bfinal) break;
  }
  return pos;
}
function __gunzipBytes(data) {
  var out = [];
  var p = 0;
  var members = 0;
  while (p < data.length) {
    if (p + 18 > data.length || data[p] !== 0x1f || data[p + 1] !== 0x8b
        || data[p + 2] !== 8) {
      throw new Error('gzip 内容无效');
    }
    var flags = data[p + 3];
    p += 10;
    if (flags & 4) {
      if (p + 2 > data.length) throw new Error('gzip 内容无效');
      p += 2 + (data[p] | (data[p + 1] << 8));
    }
    if (flags & 8) {
      while (p < data.length && data[p] !== 0) p++;
      p++;
    }
    if (flags & 16) {
      while (p < data.length && data[p] !== 0) p++;
      p++;
    }
    if (flags & 2) p += 2;
    if (p > data.length) throw new Error('gzip 内容无效');
    p += __inflateTo(data.subarray(p), out);
    p += 8;
    if (p > data.length) throw new Error('gzip 内容无效');
    members++;
  }
  if (members === 0) throw new Error('gzip 内容无效');
  return new Uint8Array(out);
}
var __HTML_ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  copy: '©', reg: '®', trade: '™', hellip: '…', mdash: '—', ndash: '–',
  lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”', laquo: '«', raquo: '»',
  times: '×', divide: '÷', plusmn: '±', deg: '°', micro: 'µ', para: '¶',
  middot: '·', bull: '•', dagger: '†', permil: '‰', prime: '′', Prime: '″',
  euro: '€', pound: '£', yen: '¥', cent: '¢', curren: '¤', sect: '§',
  uml: '¨', ordf: 'ª', ordm: 'º', iexcl: '¡', iquest: '¿', szlig: 'ß',
  agrave: 'à', aacute: 'á', acirc: 'â', atilde: 'ã', auml: 'ä', aring: 'å',
  aelig: 'æ', ccedil: 'ç', egrave: 'è', eacute: 'é', ecirc: 'ê', euml: 'ë',
  igrave: 'ì', iacute: 'í', icirc: 'î', iuml: 'ï', ntilde: 'ñ', ograve: 'ò',
  oacute: 'ó', ocirc: 'ô', otilde: 'õ', ouml: 'ö', oslash: 'ø', ugrave: 'ù',
  uacute: 'ú', ucirc: 'û', uuml: 'ü', yacute: 'ý', yuml: 'ÿ'
};
function __decodeEntities(text) {
  return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]+);/g, function (match, body) {
    if (body.charAt(0) === '#') {
      var code;
      if (body.charAt(1) === 'x' || body.charAt(1) === 'X') {
        code = parseInt(body.substring(2), 16);
      } else {
        code = parseInt(body.substring(1), 10);
      }
      if (isNaN(code) || code <= 0 || code > 0x10FFFF) return match;
      if (code > 0xFFFF) {
        code -= 0x10000;
        return String.fromCharCode(0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF));
      }
      return String.fromCharCode(code);
    }
    var named = __HTML_ENTITIES[body] || __HTML_ENTITIES[body.toLowerCase()];
    return named === undefined ? match : named;
  });
}
function __parseHtml(text) {
  // 对齐 Go host.parseHtml：返回 golang.org/x/net/html 的树形状
  // {tag?, attrs?, text?, children?}，根是文档节点（只有 children）。
  // 树构建是 HTML5 算法的子集：处理常见标签、自动闭合与
  // html/head/body 合成，极端畸形页面与 Go 结果可能有出入。
  if (text.length > 8 * 1024 * 1024) throw new Error('网页内容过大');
  var voidTags = { area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1,
    input: 1, link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1 };
  var rawTags = { script: 1, style: 1 };
  var rcdataTags = { title: 1, textarea: 1 };
  var headTags = { base: 1, link: 1, meta: 1, noscript: 1, script: 1,
    style: 1, template: 1, title: 1 };
  var pClosers = { address: 1, article: 1, aside: 1, blockquote: 1, div: 1,
    dl: 1, fieldset: 1, footer: 1, form: 1, h1: 1, h2: 1, h3: 1, h4: 1,
    h5: 1, h6: 1, header: 1, hr: 1, main: 1, nav: 1, ol: 1, p: 1, pre: 1,
    section: 1, table: 1, ul: 1 };
  function makeElement(tag, attrs) {
    return { tag: tag, attrs: attrs || {}, children: [], text: null };
  }
  function makeText(value) {
    return { tag: null, attrs: null, children: null, text: value };
  }
  var forest = [];
  var stack = [];
  function currentChildren() {
    return stack.length ? stack[stack.length - 1].children : forest;
  }
  function appendText(value) {
    if (!value) return;
    var children = currentChildren();
    var last = children[children.length - 1];
    if (last && last.text !== null) {
      last.text += value;
    } else {
      children.push(makeText(value));
    }
  }
  function closeOpenTag(tag) {
    for (var i = stack.length - 1; i >= 0; i--) {
      if (stack[i].tag === tag) {
        stack.length = i;
        return true;
      }
    }
    return false;
  }
  var i = 0;
  var length = text.length;
  while (i < length) {
    var lt = text.indexOf('<', i);
    if (lt === -1) {
      appendText(__decodeEntities(text.substring(i)));
      break;
    }
    if (lt > i) appendText(__decodeEntities(text.substring(i, lt)));
    if (text.startsWith('<!--', lt)) {
      var commentEnd = text.indexOf('-->', lt + 4);
      i = commentEnd === -1 ? length : commentEnd + 3;
      continue;
    }
    var marker = text.charAt(lt + 1);
    if (marker === '!' || marker === '?') {
      var declEnd = text.indexOf('>', lt + 2);
      i = declEnd === -1 ? length : declEnd + 1;
      continue;
    }
    if (marker === '/') {
      var closeEnd = text.indexOf('>', lt + 2);
      if (closeEnd === -1) break;
      var closeName = text.substring(lt + 2, closeEnd)
        .trim().split(/\s+/)[0].toLowerCase();
      if (closeName && !voidTags[closeName]) closeOpenTag(closeName);
      i = closeEnd + 1;
      continue;
    }
    if (!/[a-zA-Z]/.test(marker)) {
      appendText('<');
      i = lt + 1;
      continue;
    }
    var j = lt + 1;
    var tagName = '';
    while (j < length && !/[\s/>]/.test(text.charAt(j))) {
      tagName += text.charAt(j).toLowerCase();
      j++;
    }
    var attrs = {};
    var selfClosing = false;
    while (j < length) {
      while (j < length && /\s/.test(text.charAt(j))) j++;
      if (j >= length) break;
      var ch = text.charAt(j);
      if (ch === '>') { j++; break; }
      if (ch === '/') {
        if (text.charAt(j + 1) === '>') {
          selfClosing = true;
          j += 2;
          break;
        }
        j++;
        continue;
      }
      var attrName = '';
      while (j < length && !/[\s=/>]/.test(text.charAt(j))) {
        attrName += text.charAt(j).toLowerCase();
        j++;
      }
      while (j < length && /\s/.test(text.charAt(j))) j++;
      var attrValue = '';
      if (text.charAt(j) === '=') {
        j++;
        while (j < length && /\s/.test(text.charAt(j))) j++;
        var quote = text.charAt(j);
        if (quote === '"' || quote === "'") {
          var quoteEnd = text.indexOf(quote, j + 1);
          if (quoteEnd === -1) {
            attrValue = text.substring(j + 1);
            j = length;
          } else {
            attrValue = text.substring(j + 1, quoteEnd);
            j = quoteEnd + 1;
          }
        } else {
          var valueStart = j;
          while (j < length && !/[\s>]/.test(text.charAt(j))) j++;
          attrValue = text.substring(valueStart, j);
        }
      }
      if (attrName) {
        // 重复属性后胜：对齐 Go moduleHTMLTree 把 Attr 列表
        // 顺序写进 map 的覆盖结果
        attrs[attrName] = __decodeEntities(attrValue);
      }
    }
    i = j;
    // 自动闭合：按 HTML5 的作用域规则向上查找要关的元素
    //（不只看栈顶；stoppers 是作用域边界），对齐 x/net/html
    // 对常见页面的树形状。foster parenting 等极端情形仍有
    // 出入，见 README 对齐表。
    function closeUpTo(tags, stoppers) {
      for (var s = stack.length - 1; s >= 0; s--) {
        if (tags[stack[s].tag]) { stack.length = s; return true; }
        if (stoppers[stack[s].tag]) return false;
      }
      return false;
    }
    var scopeStop = { html: 1, body: 1, table: 1, td: 1, th: 1, caption: 1 };
    if (pClosers[tagName]) {
      closeUpTo({ p: 1 }, { html: 1, body: 1, table: 1, td: 1, th: 1,
        caption: 1, button: 1 });
    }
    if (tagName === 'li') {
      closeUpTo({ li: 1 }, { ul: 1, ol: 1, html: 1, body: 1, table: 1,
        td: 1, th: 1, caption: 1 });
    } else if (tagName === 'dt' || tagName === 'dd') {
      closeUpTo({ dt: 1, dd: 1 }, { dl: 1, html: 1, body: 1 });
    } else if (tagName === 'td' || tagName === 'th') {
      closeUpTo({ td: 1, th: 1 }, { tr: 1, table: 1, html: 1, body: 1 });
    } else if (tagName === 'tr') {
      closeUpTo({ tr: 1 }, { table: 1, html: 1, body: 1 });
    } else if (tagName === 'tbody' || tagName === 'thead' || tagName === 'tfoot') {
      closeUpTo({ tbody: 1, thead: 1, tfoot: 1 }, { table: 1, html: 1, body: 1 });
    } else if (tagName === 'option') {
      closeUpTo({ option: 1 }, { select: 1, html: 1, body: 1 });
    } else if (tagName === 'optgroup') {
      closeUpTo({ option: 1 }, { select: 1, html: 1, body: 1 });
      closeUpTo({ optgroup: 1 }, { select: 1, html: 1, body: 1 });
    } else if (tagName === 'a') {
      closeUpTo({ a: 1 }, scopeStop);
    } else if (tagName === 'button') {
      closeUpTo({ button: 1 }, scopeStop);
    } else if (/^h[1-6]$/.test(tagName)) {
      var topNow = stack[stack.length - 1];
      if (topNow && /^h[1-6]$/.test(topNow.tag)) stack.pop();
    }
    // 表格隐含包装：tr 直接在 table 下要包 tbody，
    // td/th 缺行时补 tbody+tr 或 tr（x/net/html 同）
    var parentNow = stack[stack.length - 1];
    if (tagName === 'tr' && parentNow && parentNow.tag === 'table') {
      var tbodyEl = makeElement('tbody', {});
      parentNow.children.push(tbodyEl);
      stack.push(tbodyEl);
    } else if ((tagName === 'td' || tagName === 'th') && parentNow) {
      if (parentNow.tag === 'table') {
        var tbodyEl2 = makeElement('tbody', {});
        parentNow.children.push(tbodyEl2);
        stack.push(tbodyEl2);
        var trEl2 = makeElement('tr', {});
        tbodyEl2.children.push(trEl2);
        stack.push(trEl2);
      } else if (parentNow.tag === 'tbody' || parentNow.tag === 'thead'
          || parentNow.tag === 'tfoot') {
        var trEl3 = makeElement('tr', {});
        parentNow.children.push(trEl3);
        stack.push(trEl3);
      }
    }
    var element = makeElement(tagName, attrs);
    currentChildren().push(element);
    if (voidTags[tagName] || selfClosing) continue;
    if (rawTags[tagName] || rcdataTags[tagName]) {
      var closePattern = '</' + tagName;
      var closeAt = text.toLowerCase().indexOf(closePattern, i);
      var rawText = closeAt === -1 ? text.substring(i) : text.substring(i, closeAt);
      if (rawText) {
        element.children.push(makeText(
          rcdataTags[tagName] ? __decodeEntities(rawText) : rawText));
      }
      if (closeAt === -1) {
        i = length;
      } else {
        var rawCloseEnd = text.indexOf('>', closeAt + closePattern.length);
        i = rawCloseEnd === -1 ? length : rawCloseEnd + 1;
      }
      continue;
    }
    stack.push(element);
  }
  // 合成 html/head/body（Go 的解析器总是产出这三层）
  var htmlElement = null;
  for (var f = 0; f < forest.length; f++) {
    if (forest[f].tag === 'html') { htmlElement = forest[f]; break; }
  }
  if (!htmlElement) {
    htmlElement = makeElement('html', {});
    var headElement = makeElement('head', {});
    var bodyElement = makeElement('body', {});
    var inHead = true;
    for (var m = 0; m < forest.length; m++) {
      var node = forest[m];
      if (inHead && node.tag && headTags[node.tag]) {
        headElement.children.push(node);
      } else if (node.tag === 'head') {
        for (var h = 0; h < node.children.length; h++) {
          headElement.children.push(node.children[h]);
        }
      } else if (node.tag === 'body') {
        inHead = false;
        for (var b = 0; b < node.children.length; b++) {
          bodyElement.children.push(node.children[b]);
        }
      } else {
        if (node.text !== null && node.text.trim() === '') continue;
        inHead = false;
        bodyElement.children.push(node);
      }
    }
    htmlElement.children = [headElement, bodyElement];
  } else {
    var hasHead = false;
    var hasBody = false;
    for (var k = 0; k < htmlElement.children.length; k++) {
      if (htmlElement.children[k].tag === 'head') hasHead = true;
      if (htmlElement.children[k].tag === 'body') hasBody = true;
    }
    if (!hasHead) htmlElement.children.unshift(makeElement('head', {}));
    if (!hasBody) htmlElement.children.push(makeElement('body', {}));
  }
  function convert(node) {
    if (node.text !== null) return { text: node.text };
    var out = {};
    if (node.tag) out.tag = node.tag;
    if (node.attrs) {
      var keys = Object.keys(node.attrs);
      if (keys.length) out.attrs = node.attrs;
    }
    if (node.children && node.children.length) {
      out.children = node.children.map(convert);
    }
    return out;
  }
  return { children: [convert(htmlElement)] };
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
      acceptStatus: request.acceptStatus || [],
      followRedirects: !!request.followRedirects,
      ticket: request.ticket || 0,
      background: !!request.background,
      direct: !!request.direct
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
  exclusive: function (fn) {
    // 跨实例串行（Go 的 provider 级信号量）：原生锁在桥侧持有
    __host_exclusiveBegin();
    try { return fn(); } finally { __host_exclusiveEnd(); }
  },
  prepareWebMedia: function (media, sourceName) {
    var env = JSON.parse(__host_webMedia(
      JSON.stringify(media || {}), String(sourceName || ''), 'prepare'));
    if (env.error) { throw new Error(env.error); }
    return env.media;
  },
  finishMedia: function (media) {
    var env = JSON.parse(__host_webMedia(
      JSON.stringify(media || {}), __hostObject.source, 'finish'));
    if (env.error) { throw new Error(env.error); }
    return env.media;
  },
  reserve: function (request) {
    request = request || {};
    var env = JSON.parse(__host_reserve(JSON.stringify({
      url: String(request.url || ''),
      lane: request.lane || '',
      background: !!request.background
    })));
    if (env.error) { throw new Error(env.error); }
    return env.ticket;
  },
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
  aesGcmSeal: function (key, nonce, plain, extra) {
    return __crypto('aesGcmSeal',
      __b64encode(__toBytes(key)), __b64encode(__toBytes(nonce)),
      __b64encode(__toBytes(plain)),
      __b64encode(extra === null || extra === undefined ? new Uint8Array(0) : __toBytes(extra)));
  },
  aesGcmOpen: function (key, nonce, sealed, extra) {
    return __crypto('aesGcmOpen',
      __b64encode(__toBytes(key)), __b64encode(__toBytes(nonce)),
      __b64encode(__toBytes(sealed)),
      __b64encode(extra === null || extra === undefined ? new Uint8Array(0) : __toBytes(extra)));
  },
  ecdhP256KeyPair: function () {
    var env = JSON.parse(__host_ecdhKeyPair());
    if (env.error) { throw new Error(env.error); }
    return {
      privateKey: __b64decode(env.privateKey || ''),
      publicKey: __b64decode(env.publicKey || '')
    };
  },
  ecdhP256: function (privateKey, publicKey) {
    return __crypto('ecdhP256',
      __b64encode(__toBytes(privateKey)), __b64encode(__toBytes(publicKey)));
  },
  hkdfSha256: function (secret, salt, info, length) {
    return __crypto('hkdfSha256',
      __b64encode(__toBytes(secret)), __b64encode(__toBytes(salt)),
      __b64encode(__toBytes(info)), String(length));
  },
  gzip: function (data) { return __gzipBytes(__toBytes(data)); },
  gunzip: function (data) { return __gunzipBytes(__toBytes(data)); },
  parseHtml: function (text) { return __parseHtml(String(text)); },
  sleep: function (milliseconds) { __host_sleep(milliseconds || 0); }
};
"""#

// MARK: - 模块运行时

/// 一个已安装模块的 JS 运行时实例：与 Go jsInstance 对应。
/// 模块代码按 Go 的方式包装：(function(module, exports, host) { <main.js> })，
/// 调用走同款 invoker（参数 JSON 编码、结果 JSON 回收、异步函数拒绝）。
/// 每个实例的 JS 执行串行化到自己的队列；桥里的网络请求同步
/// 阻塞该队列，与 goja 的同步语义一致。同模块最多 4 个实例
/// 由 ModuleRuntimePool 管理（对齐 Go moduleInstanceLimit）。
final class ModuleRuntime {
    let manifest: ModuleManifest
    private let bridge: ModuleHostBridge
    private let context: JSContext
    private var invoker: JSValue!
    private let queue = DispatchQueue(label: "lvguo.module.runtime")
    private var exceptionMessage: String?
    private var exceptionLoginRequired = false

    init(
        manifest: ModuleManifest, code: String, stateDirectory: URL,
        shared: ModuleSharedState = ModuleSharedState()
    ) throws {
        self.manifest = manifest
        let bridge = ModuleHostBridge(
            manifest: manifest, stateDirectory: stateDirectory, shared: shared
        )
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
        let cryptoBlock: @convention(block) (String, String, String, String, String) -> String = { op, a, b, c, d in
            bridge.cryptoEnvelope(op, a, b, c, d)
        }
        context.setObject(cryptoBlock, forKeyedSubscript: "__host_crypto" as NSString)
        let ecdhKeyPairBlock: @convention(block) () -> String = {
            bridge.ecdhKeyPairEnvelope()
        }
        context.setObject(ecdhKeyPairBlock, forKeyedSubscript: "__host_ecdhKeyPair" as NSString)
        let reserveBlock: @convention(block) (String) -> String = { json in
            bridge.reserveEnvelope(json)
        }
        context.setObject(reserveBlock, forKeyedSubscript: "__host_reserve" as NSString)
        let webMediaBlock: @convention(block) (String, String, String) -> String = { json, sourceName, kind in
            bridge.webMediaEnvelope(json, sourceName: sourceName, finish: kind == "finish")
        }
        context.setObject(webMediaBlock, forKeyedSubscript: "__host_webMedia" as NSString)
        let randomBlock: @convention(block) (Double) -> String = { count in
            bridge.randomBytesEnvelope(Int(count))
        }
        context.setObject(randomBlock, forKeyedSubscript: "__host_randomBytes" as NSString)
        let exclusiveBeginBlock: @convention(block) () -> Void = {
            shared.exclusiveLock.lock()
        }
        context.setObject(
            exclusiveBeginBlock, forKeyedSubscript: "__host_exclusiveBegin" as NSString
        )
        let exclusiveEndBlock: @convention(block) () -> Void = {
            shared.exclusiveLock.unlock()
        }
        context.setObject(
            exclusiveEndBlock, forKeyedSubscript: "__host_exclusiveEnd" as NSString
        )

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

// MARK: - 运行时池（多实例）

/// 模块运行时池：对齐 Go jsProvider 的实例模型——同模块最多
/// 4 个实例并行（moduleInstanceLimit = 4），调用先借空闲
/// 实例、未达上限就新建、达上限则排队等待。首页与详情可以
/// 同时各占一个实例跑，不再互相排队。provider 级状态
/// （缓存/票据/日志/exclusive 锁）由 ModuleSharedState 一份
/// 共享，与 Go 的结构一致。
/// 与 Go 的剩余差异：Go 的单次调用有 60 秒超时并可中断
/// goja 虚拟机（moduleCallTimeout + Interrupt）；JSContext
/// 没有公开的脚本中断 API，原生侧无法等价实现，见 README。
final class ModuleRuntimePool {
    let manifest: ModuleManifest
    private let code: String
    private let stateDirectory: URL
    private let shared = ModuleSharedState()
    private let limit = 4
    private var idle: [ModuleRuntime] = []
    private var created = 0
    private var waiters: [CheckedContinuation<ModuleRuntime, Error>] = []
    private let lock = NSLock()

    init(manifest: ModuleManifest, code: String, stateDirectory: URL) {
        self.manifest = manifest
        self.code = code
        self.stateDirectory = stateDirectory
    }

    func call(_ function: String, arguments: [Any]) async throws -> Any? {
        let runtime = try await acquire()
        defer { release(runtime) }
        return try await runtime.call(function, arguments: arguments)
    }

    func recentLogs() -> [String] {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.logs
    }

    private func acquire() async throws -> ModuleRuntime {
        lock.lock()
        if let runtime = idle.popLast() {
            lock.unlock()
            return runtime
        }
        if created < limit {
            created += 1
            lock.unlock()
            do {
                return try ModuleRuntime(
                    manifest: manifest, code: code,
                    stateDirectory: stateDirectory, shared: shared
                )
            } catch {
                lock.lock()
                created -= 1
                let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
                lock.unlock()
                waiter?.resume(throwing: error)
                throw error
            }
        }
        lock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let runtime = idle.popLast() {
                lock.unlock()
                continuation.resume(returning: runtime)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func release(_ runtime: ModuleRuntime) {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: runtime)
            return
        }
        idle.append(runtime)
        lock.unlock()
    }
}
