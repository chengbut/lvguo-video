import AVFoundation
import Combine
import Foundation
import UIKit
import UniformTypeIdentifiers

/// 一个可选画质（对应模块播放计划里的一个 variant）：
/// 自带地址/播放列表文本/请求头，切换画质与恢复时的
/// 「备用线路」都直接用它重开，不必再问模块。
struct PlaybackVariant {
    var quality: Int = 0
    var url: URL? = nil
    var playlistText: String? = nil
    var headers: [String: String] = [:]

    var label: String { quality > 0 ? "\(quality)P" : "默认" }

    var isPlayable: Bool { url != nil || playlistText != nil }
}

/// 一次播放请求：与 Flutter 版 PlaybackPlan 对齐。
/// url 与 playlistText 至少有一个：只有播放列表文本时
/// （模块只回 m3u8 文本）经资源代理在本地合成播放。
struct PlaybackRequest {
    var url: URL? = nil
    var playlistText: String? = nil
    var headers: [String: String] = [:]
    var title: String = ""
    /// 续播起始位置（秒），0 = 从头
    var startPosition: Double = 0
    /// 全部可选画质（含当前），多于 1 个时播放页才显示清晰度入口
    var variants: [PlaybackVariant] = []
    /// 当前画质（variants 里对应项的 quality；0 = 自动/默认）
    var quality: Int = 0
    /// 本地文件（下载目录里的文件）：失败文案与「改为在线播放」按本地处理
    var isLocal: Bool = false
    /// 计划声明的时长（秒，模块 durationMs）：用于识别「提前结束」
    var expectedDuration: Double = 0

    var isPlayable: Bool { url != nil || playlistText != nil }

    /// 换到另一个画质变体（保留起始位置/标题等会话信息）
    func withVariant(_ variant: PlaybackVariant) -> PlaybackRequest {
        var copy = self
        copy.url = variant.url
        copy.playlistText = variant.playlistText
        copy.headers = variant.headers
        copy.quality = variant.quality
        return copy
    }
}

// MARK: - 带头资源代理

/// AVAssetResourceLoaderDelegate：把带 credentials 头的媒体
/// 请求全部收回自己手里发（自定义 scheme lvguo-media）。
/// 这是黑屏根因修复的核心：AVURLAsset 的
/// AVURLAssetHTTPHeaderFieldsKey 只作用于第一个请求，HLS 的
/// 变体列表与分片都不继承，CDN 按 Cookie/UA/Referer 鉴权时
/// 分片直接 403、画面永远黑。现在的做法：
/// - 播放列表与分片请求都经 delegate → 用 URLSession 带头重发；
/// - 播放列表响应做地址改写：相对/绝对地址统一改回自定义
///   scheme，保证后续每一个子请求都回到 delegate；
/// - 只有播放列表文本的计划：首个请求直接回文本（相对地址
///   按 Go NativeURL 的规则对 base 地址解析后再改写）。
final class PlaybackResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    static let scheme = "lvguo-media"

    struct Entry {
        var baseURL: URL?
        var headers: [String: String]
        var playlistText: String?
    }

    /// 整表加载（播放列表）：先下完、改写地址、再整表回给播放器，
    /// 保证 contentLength 与改写后的字节数一致。
    private struct WholeLoad {
        var request: AVAssetResourceLoadingRequest
        var entry: Entry
        var key: String
        var data = Data()
        var response: HTTPURLResponse?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var pending: [Int: AVAssetResourceLoadingRequest] = [:]
    private var pendingEntry: [Int: Entry] = [:]
    private var wholeLoads: [Int: WholeLoad] = [:]
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    /// 注册一份播放资源，返回放进资源 URL 的 key
    func register(_ entry: Entry) -> String {
        let key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        lock.lock()
        entries[key] = entry
        lock.unlock()
        return key
    }

    func unregister(_ key: String) {
        lock.lock()
        entries.removeValue(forKey: key)
        lock.unlock()
    }

    /// URL 的已编码路径/查询（经 URLComponents 取，
    /// 不直接用 URL 的 percentEncoded* 成员，兼容性更稳）
    static func encodedPath(of url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedPath ?? url.path
    }

    static func encodedQuery(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedQuery
    }

    /// 资源 URL：lvguo-media://<key><原路径>?<原查询>
    static func assetURL(key: String, original: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = key
        let path = encodedPath(of: original)
        components.percentEncodedPath = path.isEmpty ? "/" : path
        components.percentEncodedQuery = encodedQuery(of: original)
        return components.url ?? original
    }

    /// 纯文本计划的资源 URL（没有原始地址时用固定路径）
    static func textAssetURL(key: String) -> URL {
        URL(string: "\(scheme)://\(key)/playlist.m3u8")!
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              url.scheme == Self.scheme,
              let key = url.host else {
            return false
        }
        lock.lock()
        let entry = entries[key]
        lock.unlock()
        guard let entry else {
            loadingRequest.finishLoading(with: NSError(
                domain: "LvguoPlayback", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "播放资源已失效"]
            ))
            return true
        }
        // 纯文本计划：根播放列表请求直接回文本
        if let text = entry.playlistText, isRootRequest(url, entry: entry) {
            servePlaylistText(text, entry: entry, key: key, request: loadingRequest)
            return true
        }
        // 播放列表走整表加载（改写地址后再回），其余流式直通；
        // 无 .m3u8 后缀的播放列表在响应到达时按 Content-Type
        // 再转整表模式（见 didReceive response 的处理）
        if url.path.lowercased().hasSuffix(".m3u8") {
            startWholeLoad(url: url, entry: entry, key: key, loadingRequest: loadingRequest)
        } else {
            startRemoteLoad(url: url, entry: entry, key: key, loadingRequest: loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.lock()
        var taskId = pending.first(where: { $0.value === loadingRequest })?.key
        if let found = taskId {
            pending.removeValue(forKey: found)
            pendingEntry.removeValue(forKey: found)
        }
        if taskId == nil {
            taskId = wholeLoads.first(where: { $0.value.request === loadingRequest })?.key
            if let found = taskId {
                wholeLoads.removeValue(forKey: found)
            }
        }
        lock.unlock()
        if let taskId {
            session.getAllTasks { tasks in
                tasks.first { $0.taskIdentifier == taskId }?.cancel()
            }
        }
    }

    private func isRootRequest(_ url: URL, entry: Entry) -> Bool {
        guard let base = entry.baseURL else { return true }
        return url.path == base.path
    }

    // MARK: 文本播放列表

    private func servePlaylistText(
        _ text: String, entry: Entry, key: String,
        request: AVAssetResourceLoadingRequest
    ) {
        let rewritten = Self.rewritePlaylist(
            text, responseURL: entry.baseURL, key: key, entry: entry
        )
        let data = Data(rewritten.utf8)
        if let info = request.contentInformationRequest {
            info.contentType = "public.m3u8"
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        if let dataRequest = request.dataRequest {
            dataRequest.respond(with: data)
        }
        request.finishLoading()
    }

    // MARK: 远程加载

    private func startRemoteLoad(
        url: URL, entry: Entry, key: String,
        loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let realURL = realURL(for: url, entry: entry) else {
            loadingRequest.finishLoading(with: NSError(
                domain: "LvguoPlayback", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "播放地址无效"]
            ))
            return
        }
        var request = URLRequest(url: realURL)
        for (name, value) in entry.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let dataRequest = loadingRequest.dataRequest,
           !dataRequest.requestsAllDataToEndOfResource {
            let start = dataRequest.requestedOffset
            let length = dataRequest.requestedLength
            if dataRequest.currentOffset == 0, start > 0 || length > 0 {
                if length > 0 {
                    request.setValue("bytes=\(start)-\(start + Int64(length) - 1)", forHTTPHeaderField: "Range")
                } else {
                    request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
                }
            }
        }
        let task = session.dataTask(with: request)
        lock.lock()
        pending[task.taskIdentifier] = loadingRequest
        pendingEntry[task.taskIdentifier] = entry
        lock.unlock()
        task.resume()
    }

    private func startWholeLoad(
        url: URL, entry: Entry, key: String,
        loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let realURL = realURL(for: url, entry: entry) else {
            loadingRequest.finishLoading(with: NSError(
                domain: "LvguoPlayback", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "播放地址无效"]
            ))
            return
        }
        var request = URLRequest(url: realURL)
        for (name, value) in entry.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.dataTask(with: request)
        lock.lock()
        wholeLoads[task.taskIdentifier] = WholeLoad(
            request: loadingRequest, entry: entry, key: key
        )
        lock.unlock()
        task.resume()
    }

    /// 资源 URL → 真实 URL：/_ext/<base64url> 形态是改写时
    /// 塞进来的跨源绝对地址；其余按 base 地址同源换 scheme。
    private func realURL(for url: URL, entry: Entry) -> URL? {
        if url.path.hasPrefix("/_ext/") {
            let encoded = String(url.path.dropFirst("/_ext/".count))
            if let data = Data(base64URLEncoded: encoded),
               let text = String(data: data, encoding: .utf8),
               let target = URL(string: text) {
                return target
            }
            return nil
        }
        guard let base = entry.baseURL else { return nil }
        var components = URLComponents()
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        components.percentEncodedPath = Self.encodedPath(of: url)
        components.percentEncodedQuery = Self.encodedQuery(of: url)
        return components.url
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let streaming = pending[dataTask.taskIdentifier]
        let whole = wholeLoads[dataTask.taskIdentifier]
        lock.unlock()
        guard streaming != nil || whole != nil else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            completionHandler(.cancel)
            lock.lock()
            let failedStreaming = pending.removeValue(forKey: dataTask.taskIdentifier)
            pendingEntry.removeValue(forKey: dataTask.taskIdentifier)
            let failedWhole = wholeLoads.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            (failedStreaming ?? failedWhole?.request)?.finishLoading(with: NSError(
                domain: "LvguoPlayback", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "媒体请求失败（HTTP \(http.statusCode)）"]
            ))
            return
        }
        if let whole = whole {
            // 整表加载：先记下响应（最终地址是改写的解析基准），数据收齐后再回内容信息
            lock.lock()
            wholeLoads[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
            lock.unlock()
            _ = whole
            completionHandler(.allow)
            return
        }
        // 流式任务收到播放列表响应（无 .m3u8 后缀的列表地址）：
        // 此时数据还没开始流，转成整表模式以便改写地址
        if let streaming,
           let http = response as? HTTPURLResponse {
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                .lowercased()
            if mime.contains("mpegurl") || mime.contains("m3u8") {
                lock.lock()
                pending.removeValue(forKey: dataTask.taskIdentifier)
                let entry = pendingEntry.removeValue(forKey: dataTask.taskIdentifier)
                if let entry {
                    wholeLoads[dataTask.taskIdentifier] = WholeLoad(
                        request: streaming, entry: entry,
                        key: dataTask.originalRequest?.url?.host ?? "",
                        response: http
                    )
                }
                lock.unlock()
                completionHandler(.allow)
                return
            }
        }
        guard let loadingRequest = streaming,
              let info = loadingRequest.contentInformationRequest,
              let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first.map(String.init) ?? ""
        if let type = UTType(mimeType: mime.trimmingCharacters(in: .whitespaces)) {
            info.contentType = type.identifier
        }
        var length: Int64 = http.expectedContentLength
        var byteRangeSupported = false
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let value = Int64(total) {
            length = value
            byteRangeSupported = true
        } else if http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes" {
            byteRangeSupported = true
        }
        if length >= 0 { info.contentLength = length }
        info.isByteRangeAccessSupported = byteRangeSupported
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let streaming = pending[dataTask.taskIdentifier]
        let isWhole = wholeLoads[dataTask.taskIdentifier] != nil
        if isWhole {
            wholeLoads[dataTask.taskIdentifier]?.data.append(data)
        }
        lock.unlock()
        if isWhole { return }
        guard let streaming, let dataRequest = streaming.dataRequest else { return }
        dataRequest.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let streaming = pending.removeValue(forKey: task.taskIdentifier)
        pendingEntry.removeValue(forKey: task.taskIdentifier)
        let whole = wholeLoads.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let whole {
            finishWholeLoad(whole, response: task.response, error: error)
            return
        }
        guard let streaming else { return }
        if let error {
            streaming.finishLoading(with: error)
            return
        }
        streaming.finishLoading()
    }

    /// 整表加载收尾：改写地址 → 回内容信息（长度按改写后字节数）→ 回数据
    private func finishWholeLoad(_ whole: WholeLoad, response: URLResponse?, error: Error?) {
        let loadingRequest = whole.request
        if let error {
            loadingRequest.finishLoading(with: error)
            return
        }
        guard let text = String(data: whole.data, encoding: .utf8) else {
            loadingRequest.finishLoading(with: NSError(
                domain: "LvguoPlayback", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "播放列表不是文本"]
            ))
            return
        }
        let finalURL = whole.response?.url ?? response?.url
        let rewritten = Self.rewritePlaylist(
            text, responseURL: finalURL, key: whole.key, entry: whole.entry
        )
        let data = Data(rewritten.utf8)
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = "public.m3u8"
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        if let dataRequest = loadingRequest.dataRequest {
            let start = Int(dataRequest.requestedOffset)
            if start > 0, start < data.count {
                dataRequest.respond(with: data.subdata(in: start..<data.count))
            } else if start == 0 {
                dataRequest.respond(with: data)
            }
        }
        loadingRequest.finishLoading()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 跳转时系统会丢掉部分自定义头：把资源头重新贴回去
        lock.lock()
        let entry = pendingEntry[task.taskIdentifier]
            ?? wholeLoads[task.taskIdentifier]?.entry
        lock.unlock()
        var request = request
        if let entry {
            for (name, value) in entry.headers where request.value(forHTTPHeaderField: name) == nil {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        completionHandler(request)
    }

    // MARK: 播放列表改写

    /// 把播放列表里的每个子地址改写成自定义 scheme 地址：
    /// 相对地址先对响应真实地址解析（对齐 Go NativeURL），
    /// 同源的走 /<path> 形态，跨源的走 /_ext/<base64url> 形态，
    /// 保证所有子请求都回到 delegate 并带上资源头。
    static func rewritePlaylist(
        _ text: String, responseURL: URL?, key: String, entry: Entry
    ) -> String {
        let base = responseURL ?? entry.baseURL
        func wrap(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return raw }
            if trimmed.hasPrefix("\(scheme)://") { return trimmed }
            let resolved = base.flatMap { URL(string: trimmed, relativeTo: $0)?.absoluteURL }
                ?? URL(string: trimmed)
            guard let resolved else { return raw }
            if let base, resolved.scheme == base.scheme, resolved.host == base.host,
               resolved.port == base.port {
                var components = URLComponents()
                components.scheme = scheme
                components.host = key
                let path = encodedPath(of: resolved)
                components.percentEncodedPath = path.isEmpty ? "/" : path
                components.percentEncodedQuery = encodedQuery(of: resolved)
                return components.url?.absoluteString ?? raw
            }
            let encoded = Data(resolved.absoluteString.utf8).base64URLEncodedString()
            return "\(scheme)://\(key)/_ext/\(encoded)"
        }
        var output: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                if let range = line.range(of: "URI=\"") {
                    let rest = line[range.upperBound...]
                    if let end = rest.firstIndex(of: "\"") {
                        let uri = String(rest[..<end])
                        let head = String(line[..<range.upperBound])
                        let tail = String(rest[end...])
                        output.append(head + wrap(uri) + tail)
                        continue
                    }
                }
                output.append(rawLine)
            } else if line.isEmpty {
                output.append(rawLine)
            } else {
                output.append(wrap(line))
            }
        }
        return output.joined(separator: "\n")
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var value = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        self.init(base64Encoded: value)
    }
}

// MARK: - 播放引擎

/// AVPlayer 播放引擎。恢复策略对齐 Flutter 版 playback_recovery：
/// 预算 maxAttempts 6 / maxRefreshes 3，退避 0.8/1.5/2.5/4/6 秒，
/// 先重新取地址、再切备用线路、最后报错（症状文案同 Flutter）。
/// 另保留三路即时自愈：外部暂停自动恢复、卡顿通知后重播、
/// 音频中断结束后续播（都受 intentToPlay 门控）。
final class PlaybackEngine: ObservableObject {
    let player = AVPlayer()
    let resourceLoader = PlaybackResourceLoader()

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var isStalled = false
    @Published private(set) var loadingMessage = "正在准备播放"
    @Published private(set) var failureText = ""
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var bufferedPosition: Double = 0
    @Published private(set) var presentationSize: CGSize = .zero
    @Published private(set) var networkSpeedText = ""
    @Published private(set) var audioOptions: [TrackOption] = []
    @Published private(set) var subtitleOptions: [TrackOption] = []

    struct TrackOption: Identifiable, Equatable {
        var id: String
        var title: String
        var selected: Bool
    }

    /// 进度回调（约每 5 秒一次 + 暂停/结束时）：供历史记录用
    var onProgress: ((Double, Double) -> Void)?
    /// 播放结束回调：供自动连播用
    var onEnded: (() -> Void)?
    /// 到达片尾阈值回调（skipOutroSeconds > 0 时）：提前切下一集
    var onOutroReached: (() -> Void)?
    /// 恢复取址：(症状, 第几次尝试) → 新的播放请求；nil 表示无路可走
    var onRecover: ((String, Int) async -> PlaybackRequest?)?

    var outroThreshold: Double = 0
    private var outroFired = false
    var playbackRate: Float = 1.0

    private(set) var currentRequest: PlaybackRequest?
    private var pendingStartPosition: Double = 0
    private var progressTick = 0
    private var intentToPlay = false
    private var wasPlayingBeforeInterruption = false

    // 恢复预算（Flutter PlaybackRecoveryBudget）
    private var recoveryAttempts = 0
    private var recoveryRefreshes = 0
    private var recovering = false
    private var lastFailureReason = "open_exception"
    private var lastRawError = ""

    // 看门狗状态
    private var loadGeneration = 0
    private var loadStartedAt = Date()
    private var loadWasSwitch = false
    private var lastPosition: Double = 0
    private var lastProgressAt = Date()
    private var timedOut = false

    // 画面调节与 A-B 循环
    private var eqBrightness = 0
    private var eqContrast = 0
    private var eqSaturation = 0
    @Published private(set) var abA: Double?
    @Published private(set) var abB: Double?

    private var loaderKey: String?
    private var itemStatusObservation: NSKeyValueObservation?
    private var presentationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var speedTick = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeControlObservation = player.observe(\AVPlayer.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = player.timeControlStatus == .playing
                self.isStalled = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    && self.intentToPlay
                if player.timeControlStatus == .paused,
                   self.intentToPlay,
                   player.currentItem?.status == .readyToPlay,
                   !self.recovering {
                    // 非用户意图的暂停（路由变化 / 系统回收等）：恢复播放
                    self.play()
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.tick(time)
        }
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("[Playback] audio session error: \(error)")
        }
    }

    // MARK: 加载

    /// loadKind：initial 首载 / switch 切集（超时按 swap_no_start 归因）
    func load(_ request: PlaybackRequest, autoplay: Bool = true, isSwitch: Bool = false) {
        loadGeneration += 1
        let generation = loadGeneration
        intentToPlay = autoplay
        currentRequest = request
        pendingStartPosition = request.startPosition
        outroFired = false
        progressTick = 0
        currentTime = 0
        duration = 0
        bufferedPosition = 0
        presentationSize = .zero
        lastPosition = 0
        lastProgressAt = Date()
        loadStartedAt = Date()
        loadWasSwitch = isSwitch
        timedOut = false
        failureText = ""
        if !recovering {
            loadingMessage = "正在准备播放"
        }
        phase = .loading

        if let loaderKey {
            resourceLoader.unregister(loaderKey)
            self.loaderKey = nil
        }

        let asset: AVURLAsset
        let needsProxy = !request.headers.isEmpty || request.playlistText != nil
        if needsProxy, request.isPlayable {
            let key = resourceLoader.register(PlaybackResourceLoader.Entry(
                baseURL: request.url,
                headers: request.headers,
                playlistText: request.playlistText
            ))
            loaderKey = key
            let assetURL: URL
            if let url = request.url {
                assetURL = PlaybackResourceLoader.assetURL(key: key, original: url)
            } else {
                assetURL = PlaybackResourceLoader.textAssetURL(key: key)
            }
            asset = AVURLAsset(url: assetURL)
            asset.resourceLoader.setDelegate(
                resourceLoader, queue: DispatchQueue(label: "lvguo.playback.loader")
            )
        } else if let url = request.url {
            asset = AVURLAsset(url: url)
        } else {
            failNow(reason: "open_exception", raw: "没有可播放的地址")
            return
        }

        let item = AVPlayerItem(asset: asset)
        applyVideoEQ(to: item)
        itemStatusObservation = item.observe(\AVPlayerItem.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                switch item.status {
                case .readyToPlay:
                    self.phase = .ready
                    self.recoveryAttempts = 0
                    self.recoveryRefreshes = 0
                    self.refreshTracks(item)
                    if self.pendingStartPosition > 1 {
                        let target = self.pendingStartPosition
                        self.pendingStartPosition = 0
                        self.player.seek(
                            to: CMTime(seconds: target, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
                        ) { _ in
                            if self.intentToPlay { self.play() }
                        }
                    } else if self.intentToPlay {
                        self.play()
                    }
                case .failed:
                    let raw = Self.rawErrorText(item)
                    self.handleFailure(reason: "open_exception", raw: raw)
                default:
                    break
                }
            }
        }
        presentationObservation = item.observe(\AVPlayerItem.presentationSize, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.presentationSize = item.presentationSize
            }
        }
        observeItemNotifications(item)
        player.replaceCurrentItem(with: item)
        scheduleLoadTimeout(generation: generation)
    }

    /// AVPlayerItem 失败时的系统错误原文（含错误日志里的底层原因）
    static func rawErrorText(_ item: AVPlayerItem) -> String {
        var text = item.error?.localizedDescription ?? "未知错误"
        if let event = item.errorLog()?.events.last,
           let comment = event.errorComment, !comment.isEmpty,
           !text.contains(comment) {
            text += "（\(comment)）"
        }
        return text
    }

    /// 加载看门狗：30 秒没就绪且毫无进度 → 超时失败，不许无限转圈
    private func scheduleLoadTimeout(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self,
                  generation == self.loadGeneration,
                  self.phase == .loading,
                  self.player.currentItem?.status != .readyToPlay else { return }
            self.timedOut = true
            self.handleFailure(
                reason: self.loadWasSwitch ? "swap_no_start" : "open_exception",
                raw: "加载超时（30 秒没有开始播放）"
            )
        }
    }

    // MARK: 播放控制

    func play() {
        intentToPlay = true
        player.rate = playbackRate
    }

    func pause() {
        intentToPlay = false
        player.pause()
        onProgress?(currentTime, duration)
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        lastProgressAt = Date()
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
        )
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing || intentToPlay && isStalled {
            pause()
        } else {
            play()
        }
    }

    var isPaused: Bool { !intentToPlay }

    // MARK: 恢复（对齐 Flutter PlaybackRecovery）

    private func handleFailure(reason: String, raw: String) {
        lastFailureReason = reason
        lastRawError = raw
        guard !recovering, phase != .failed else { return }
        guard recoveryAttempts < 6, let onRecover else {
            failNow(reason: reason, raw: raw)
            return
        }
        recovering = true
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        let isRefresh = recoveryRefreshes < 3
        if isRefresh { recoveryRefreshes += 1 }
        loadingMessage = isRefresh ? "正在重新获取播放地址" : "正在切换备用线路"
        phase = .loading
        let backoff: [Double] = [0.8, 1.5, 2.5, 4.0, 6.0, 6.0]
        let delay = backoff[min(attempt - 1, backoff.count - 1)]
        let keepPosition = currentTime
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            let fresh = await onRecover(reason, attempt)
            self.recovering = false
            if var fresh {
                if keepPosition > 1 {
                    fresh.startPosition = keepPosition
                }
                self.load(fresh, autoplay: true, isSwitch: false)
            } else if self.recoveryAttempts < 6 {
                self.handleFailure(reason: reason, raw: raw)
            } else {
                self.failNow(reason: reason, raw: raw)
            }
        }
    }

    private func failNow(reason: String, raw: String) {
        intentToPlay = false
        player.pause()
        phase = .failed
        let symptom: String
        switch reason {
        case "position_stalled_20s": symptom = "画面长时间没有进度"
        case "early_completion": symptom = "视频提前结束"
        case "open_exception": symptom = "视频打开失败"
        case "swap_no_start": symptom = "切集后没有开始播放"
        default: symptom = "播放器报错"
        }
        let isLocal = currentRequest?.isLocal ?? false
        var text = symptom + (isLocal
            ? "，本地视频没能播放。可重试或重新下载，也可以改为在线播放。"
            : "，自动恢复未成功。可重试、换一集或选择其他清晰度。")
        if !raw.isEmpty {
            text += "\n原始错误：\(raw)"
        }
        failureText = text
    }

    /// 手动重试：清恢复预算，重新走取址（没有取址器时重开当前请求）
    func retryFromUI(fromStart: Bool) {
        recoveryAttempts = 0
        recoveryRefreshes = 0
        recovering = false
        let position = fromStart ? 0 : currentTime
        if let onRecover {
            recovering = true
            loadingMessage = "正在重新获取播放地址"
            phase = .loading
            Task { [weak self] in
                let fresh = await onRecover("manual_retry", 0)
                guard let self else { return }
                self.recovering = false
                if var fresh {
                    fresh.startPosition = position
                    self.load(fresh, autoplay: true)
                } else if var current = self.currentRequest {
                    current.startPosition = position
                    self.load(current, autoplay: true)
                }
            }
        } else if var current = currentRequest {
            current.startPosition = position
            load(current, autoplay: true)
        }
    }

    // MARK: 周期 tick（进度 / 缓冲 / 网速 / 卡顿看门狗 / 片尾 / A-B）

    private func tick(_ time: CMTime) {
        let position = time.seconds.isFinite ? time.seconds : 0
        currentTime = position
        if let item = player.currentItem {
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite {
                duration = itemDuration
            }
            if let range = item.loadedTimeRanges.last?.timeRangeValue {
                bufferedPosition = (range.start + range.duration).seconds
            }
        }
        progressTick += 1
        if progressTick % 10 == 0 {
            onProgress?(currentTime, duration)
        }
        speedTick += 1
        if speedTick % 2 == 0 {
            updateNetworkSpeed()
        }
        // 位置推进监测：意图播放且已就绪时，位置 20 秒不动 = 卡死
        if position > lastPosition + 0.25 {
            lastPosition = position
            lastProgressAt = Date()
        }
        if intentToPlay, phase == .ready, !recovering,
           Date().timeIntervalSince(lastProgressAt) > 20 {
            lastProgressAt = Date()
            handleFailure(reason: "position_stalled_20s", raw: lastRawError)
        }
        if outroThreshold > 0, !outroFired,
           duration > 0, duration - position <= outroThreshold, position > 0 {
            outroFired = true
            onOutroReached?()
        }
        if let a = abA, let b = abB, position >= b {
            seek(to: a)
        }
    }

    private func updateNetworkSpeed() {
        guard let event = player.currentItem?.accessLog()?.events.last else {
            networkSpeedText = ""
            return
        }
        let bytesPerSecond = event.observedBitrate / 8
        guard bytesPerSecond > 0 else {
            networkSpeedText = ""
            return
        }
        if bytesPerSecond >= 1024 * 1024 {
            networkSpeedText = String(format: "%.1f MB/s", bytesPerSecond / 1024 / 1024)
        } else {
            networkSpeedText = String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
    }

    // MARK: 音轨 / 字幕

    private func refreshTracks(_ item: AVPlayerItem) {
        let asset = item.asset
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            let current = item.currentMediaSelection.selectedMediaOption(in: group)
            audioOptions = group.options.map { option in
                TrackOption(
                    id: "audio-\(group.options.firstIndex(of: option) ?? 0)",
                    title: option.displayName,
                    selected: option == current
                )
            }
        } else {
            audioOptions = []
        }
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            let current = item.currentMediaSelection.selectedMediaOption(in: group)
            var options = [TrackOption(id: "sub-off", title: "关闭", selected: current == nil)]
            for (index, option) in group.options.enumerated() {
                options.append(TrackOption(
                    id: "sub-\(index)",
                    title: option.displayName,
                    selected: option == current
                ))
            }
            subtitleOptions = options
        } else {
            subtitleOptions = []
        }
    }

    func selectAudioTrack(id: String) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
              let index = Int(id.dropFirst("audio-".count)),
              group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
        refreshTracks(item)
    }

    func selectSubtitle(id: String) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        if id == "sub-off" {
            item.select(nil, in: group)
        } else if let index = Int(id.dropFirst("sub-".count)),
                  group.options.indices.contains(index) {
            item.select(group.options[index], in: group)
        }
        refreshTracks(item)
    }

    // MARK: 画面调节（CIColorControls 视频合成）

    func setVideoEQ(brightness: Int, contrast: Int, saturation: Int) {
        eqBrightness = brightness
        eqContrast = contrast
        eqSaturation = saturation
        if let item = player.currentItem {
            applyVideoEQ(to: item)
        }
    }

    private func applyVideoEQ(to item: AVPlayerItem) {
        if eqBrightness == 0, eqContrast == 0, eqSaturation == 0 {
            item.videoComposition = nil
            return
        }
        let brightness = eqBrightness
        let contrast = eqContrast
        let saturation = eqSaturation
        item.videoComposition = AVMutableVideoComposition(
            asset: item.asset, applyingCIFiltersWithHandler: { request in
                guard let filter = CIFilter(name: "CIColorControls") else {
                    request.finish(with: request.sourceImage, context: nil)
                    return
                }
                filter.setValue(request.sourceImage, forKey: kCIInputImageKey)
                filter.setValue(Double(brightness) / 200.0, forKey: kCIInputBrightnessKey)
                filter.setValue(1.0 + Double(contrast) / 100.0, forKey: kCIInputContrastKey)
                filter.setValue(1.0 + Double(saturation) / 100.0, forKey: kCIInputSaturationKey)
                request.finish(with: filter.outputImage ?? request.sourceImage, context: nil)
            }
        )
    }

    // MARK: A-B 循环

    func setPointA() { abA = currentTime; if let b = abB, b <= currentTime { abB = nil } }
    func setPointB() { if abA != nil { abB = currentTime } }
    func clearAB() { abA = nil; abB = nil }

    // MARK: 截图

    /// 保存当前帧到应用文件（对齐 Flutter 截图：成功回路径，失败抛错）
    func captureScreenshot() async throws -> String {
        guard let item = player.currentItem else {
            throw NSError(domain: "LvguoPlayback", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "当前没有在播的画面"])
        }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let result = try await generator.image(
            at: CMTime(seconds: currentTime, preferredTimescale: 600)
        )
        let image = result.image
        guard let data = UIImage(cgImage: image).pngData() else {
            throw NSError(domain: "LvguoPlayback", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "截图编码失败"])
        }
        let directory = AppData.directory.appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent(
            "shot-\(Int(Date().timeIntervalSince1970)).png"
        )
        try data.write(to: file)
        return file.path
    }

    // MARK: 通知（结束 / 卡顿即时自愈 / 音频中断）

    private func observeItemNotifications(_ item: AVPlayerItem) {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        let center = NotificationCenter.default

        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.duration > 0 {
                self.onProgress?(self.duration, self.duration)
            }
            // 提前结束：计划时长明显长于实际播完位置 → 走恢复而不是连播
            let expected = self.currentRequest?.expectedDuration ?? 0
            if expected > 0, self.duration > 0, expected - self.currentTime > 30,
               self.phase != .failed {
                self.handleFailure(reason: "early_completion", raw: self.lastRawError)
                return
            }
            self.onEnded?()
        })

        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.handleFailure(
                reason: "open_exception",
                raw: error?.localizedDescription ?? self.lastRawError
            )
        })

        // 播放卡顿：等 1 秒让缓冲恢复，再自动续播（即时自愈，
        // 真卡死由 20 秒位置看门狗升级到恢复预算）
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.intentToPlay else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.intentToPlay, !self.recovering else { return }
                self.play()
            }
        })

        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = self.intentToPlay
            case .ended:
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if self.wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                    self.play()
                }
            @unknown default:
                break
            }
        })
    }
}
