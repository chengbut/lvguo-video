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
    /// 来源模块 id（站源播放时有值）：资源代理按它取单独代理设置
    var sourceId: String = ""
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

    /// 流式加载的逐任务状态：Range 透传、服务器忽略 Range 时
    /// 的丢字节对齐、播放列表正文嗅探（#EXTM3U）缓冲。
    private struct StreamingState {
        var request: AVAssetResourceLoadingRequest
        var entry: Entry
        var key: String
        var response: HTTPURLResponse?
        /// 本任务实际发出的 Range 起点（0 = 没发 Range）
        var requestedFrom: Int64 = 0
        /// 服务器对 Range 请求回 200 时要丢弃的响应前缀字节数
        var skipBytes: Int64 = 0
        /// 嗅探缓冲：判定是否播放列表前先攒住、不回数据
        var sniffBuffer = Data()
        var sniffDecided = false
        /// 已回给播放器的字节数（诊断计数）
        var respondedBytes: Int64 = 0
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var pending: [Int: StreamingState] = [:]
    private var wholeLoads: [Int: WholeLoad] = [:]
    /// 改写时记录的子资源角色（key → 改写后地址 → 角色），
    /// 供子请求诊断日志标注密钥/初始化段/媒体组等路径类型
    private var roles: [String: [String: String]] = [:]
    /// 分片成功计数（按 key）：日志采样，避免刷满日记
    private var segmentOKCounts: [String: Int] = [:]
    /// 内容信息 UTI 日志去重（按资源 key + 路径种类，
    /// 每种只记一行：contentInformation 实际填了什么 UTI
    /// 是 Cannot Open 排查的关键证据，不能靠猜）
    private var contentTypeLogged: Set<String> = []

    private func logContentTypeOnce(key: String, kind: String, line: String) {
        lock.lock()
        let inserted = contentTypeLogged.insert(key + kind).inserted
        lock.unlock()
        if inserted {
            DiaryStore.shared.add(line)
        }
    }

    /// 播放列表的内容类型：必须是系统注册的 UTI
    /// （UTType(filenameExtension:"m3u8") = com.apple.mpegurl）。
    /// 此前写死 "public.m3u8" 不是注册 UTI，AVPlayer 无法据此
    /// 认定资产是播放列表，是 Cannot Open 的头号嫌疑。
    static let playlistContentType =
        UTType(filenameExtension: "m3u8")?.identifier ?? "com.apple.mpegurl"

    /// 诊断用地址分类：只给路径类型与主机名，
    /// 不带路径明细、查询与签名参数。
    static func classify(_ url: URL?) -> String {
        guard let url else { return "无地址" }
        let host = url.host ?? "?"
        let kind: String
        switch url.pathExtension.lowercased() {
        case "m3u8": kind = "播放列表"
        case "ts": kind = "分片TS"
        case "m4s": kind = "分片fMP4"
        case "mp4", "m4v", "mov": kind = "媒体文件"
        case "aac", "mp3": kind = "音频"
        case "vtt": kind = "字幕"
        case "key": kind = "密钥"
        case "": kind = "无扩展名资源"
        default: kind = "其他(\(url.pathExtension.lowercased()))"
        }
        return "\(kind)@\(host)"
    }

    /// 播放请求走的会话：带资源设置里的代理（模块单独设置
    /// 优先，其次全局）。代理 generation 或来源变化时重建，
    /// 改完代理下一次播放即生效。
    private var sessionStorage: URLSession?
    private var sessionProxyKey = ""
    private var sessionSourceId = ""

    private var session: URLSession {
        let key = "\(ProxySettings.generation)|\(sessionSourceId)"
        if let sessionStorage, sessionProxyKey == key {
            return sessionStorage
        }
        sessionProxyKey = key
        sessionStorage?.invalidateAndCancel()
        let configuration = URLSessionConfiguration.default
        ProxySettings.configure(
            configuration,
            effective: ProxySettings.effective(
                forModule: sessionSourceId.isEmpty ? nil : sessionSourceId
            )
        )
        let created = URLSession(
            configuration: configuration, delegate: self, delegateQueue: nil
        )
        sessionStorage = created
        return created
    }

    /// 注册一份播放资源，返回放进资源 URL 的 key
    func register(_ entry: Entry, sourceId: String = "") -> String {
        sessionSourceId = sourceId
        let key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        lock.lock()
        entries[key] = entry
        lock.unlock()
        return key
    }

    func unregister(_ key: String) {
        lock.lock()
        entries.removeValue(forKey: key)
        roles.removeValue(forKey: key)
        segmentOKCounts.removeValue(forKey: key)
        contentTypeLogged = contentTypeLogged.filter { !$0.hasPrefix(key) }
        lock.unlock()
    }

    /// 子请求诊断描述：真实地址的类型/主机 + 改写时记录的角色
    private func requestDescription(key: String, wrapped: URL?, real: URL?) -> String {
        var text = Self.classify(real)
        lock.lock()
        let role = wrapped.flatMap { roles[key]?[$0.absoluteString] }
        lock.unlock()
        if let role {
            text += "（\(role)）"
        }
        return text
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
        var taskId = pending.first(where: { $0.value.request === loadingRequest })?.key
        if let found = taskId {
            pending.removeValue(forKey: found)
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
        let rewritten = rewritePlaylist(
            text, responseURL: entry.baseURL, key: key, entry: entry
        )
        DiaryStore.shared.add(
            "子请求 播放列表文本 → 本地合成（\(rewritten.summary)）"
        )
        let data = Data(rewritten.text.utf8)
        if let info = request.contentInformationRequest {
            info.contentType = Self.playlistContentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
            logContentTypeOnce(
                key: key, kind: "|text",
                line: "内容信息（文本播放列表）：UTI \(Self.playlistContentType)"
            )
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
        // Range 必须按 requestedOffset 发：新数据请求的
        // currentOffset 一开始就等于 requestedOffset，旧写法
        // 判 currentOffset == 0 导致偏移请求从不带 Range、
        // 整段数据被塞到错误偏移上，资产直接损坏打不开。
        var requestedFrom: Int64 = 0
        if let dataRequest = loadingRequest.dataRequest,
           !dataRequest.requestsAllDataToEndOfResource {
            let start = dataRequest.requestedOffset
            let length = dataRequest.requestedLength
            if start > 0 || length > 0 {
                requestedFrom = start
                if length > 0 {
                    request.setValue("bytes=\(start)-\(start + Int64(length) - 1)", forHTTPHeaderField: "Range")
                } else {
                    request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
                }
            }
        }
        let task = session.dataTask(with: request)
        lock.lock()
        pending[task.taskIdentifier] = StreamingState(
            request: loadingRequest, entry: entry, key: key,
            requestedFrom: requestedFrom
        )
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
        let state = pending[dataTask.taskIdentifier]
        let whole = wholeLoads[dataTask.taskIdentifier]
        lock.unlock()
        guard state != nil || whole != nil else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            completionHandler(.cancel)
            lock.lock()
            let failedState = pending.removeValue(forKey: dataTask.taskIdentifier)
            let failedWhole = wholeLoads.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            if let failedState {
                DiaryStore.shared.add(
                    "子请求 \(requestDescription(key: failedState.key, wrapped: failedState.request.request.url, real: response.url)) → HTTP \(http.statusCode)（失败）"
                )
            } else if let failedWhole {
                DiaryStore.shared.add(
                    "子请求 \(requestDescription(key: failedWhole.key, wrapped: failedWhole.request.request.url, real: response.url)) → HTTP \(http.statusCode)（失败）"
                )
            }
            (failedState?.request ?? failedWhole?.request)?.finishLoading(with: NSError(
                domain: "LvguoPlayback", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "媒体请求失败（HTTP \(http.statusCode)）"]
            ))
            return
        }
        if whole != nil {
            // 整表加载：先记下响应（最终地址是改写的解析基准），数据收齐后再回内容信息
            lock.lock()
            wholeLoads[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
            lock.unlock()
            completionHandler(.allow)
            return
        }
        guard var state, let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        state.response = http
        // 服务器没理会 Range（回 200 而非 206）：喂数据时先
        // 丢掉 requestedFrom 个字节，把偏移对齐回去，否则
        // 播放器拿到错位字节流、资产打不开
        if state.requestedFrom > 0, http.statusCode == 200 {
            state.skipBytes = state.requestedFrom
        }
        // 流式任务收到播放列表响应（无 .m3u8 后缀的列表地址）：
        // 此时数据还没开始流，转成整表模式以便改写地址。
        // 只对整表 200 转，206 分段的列表走正文嗅探后重拉整表。
        let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased()
        if http.statusCode == 200,
           mime.contains("mpegurl") || mime.contains("m3u8") {
            lock.lock()
            pending.removeValue(forKey: dataTask.taskIdentifier)
            wholeLoads[dataTask.taskIdentifier] = WholeLoad(
                request: state.request, entry: state.entry,
                key: state.key, response: http
            )
            lock.unlock()
            completionHandler(.allow)
            return
        }
        lock.lock()
        pending[dataTask.taskIdentifier] = state
        lock.unlock()
        guard let info = state.request.contentInformationRequest else {
            completionHandler(.allow)
            return
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if let type = UTType(mimeType: contentType) {
            info.contentType = type.identifier
            logContentTypeOnce(
                key: state.key, kind: "|stream",
                line: "内容信息：UTI \(type.identifier)（源 Content-Type \(contentType.isEmpty ? "无" : contentType)）"
            )
        } else {
            // 映射不出注册 UTI 就不填：AVPlayer 只能靠字节
            // 内容猜形态，这一行就是下次定位的证据
            logContentTypeOnce(
                key: state.key, kind: "|stream",
                line: "内容信息：未填 UTI（源 Content-Type \(contentType.isEmpty ? "无" : contentType) 无法映射为注册 UTI）"
            )
        }
        // 内容长度必须如实：206 时 expectedContentLength 只是
        // 本段长度，全长只认 Content-Range 的总数部分
        var length: Int64 = http.statusCode == 200 ? http.expectedContentLength : -1
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

    /// 正文嗅探：去掉 BOM 与空白后是否已能判定为播放列表。
    /// true = 是列表；false = 确定不是；nil = 字节还不够判定
    private static func sniffPlaylist(_ data: Data) -> Bool? {
        var bytes = [UInt8](data.prefix(32))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        var index = 0
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
        let magic = [UInt8]("#EXTM3U".utf8)
        var matched = 0
        while index < bytes.count, matched < magic.count {
            guard bytes[index] == magic[matched] else { return false }
            index += 1
            matched += 1
        }
        return matched == magic.count ? true : nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let isWhole = wholeLoads[dataTask.taskIdentifier] != nil
        if isWhole {
            wholeLoads[dataTask.taskIdentifier]?.data.append(data)
        }
        var state = pending[dataTask.taskIdentifier]
        lock.unlock()
        if isWhole { return }
        guard var state else { return }

        var chunk = data
        if !state.sniffDecided {
            state.sniffBuffer.append(chunk)
            let verdict = Self.sniffPlaylist(state.sniffBuffer)
            if verdict == nil, state.sniffBuffer.count < 4096 {
                // 还判不了：先攒着，等下一块数据
                lock.lock()
                pending[dataTask.taskIdentifier] = state
                lock.unlock()
                return
            }
            if verdict == true {
                if state.response?.statusCode == 200 {
                    // 播放列表被当普通资源流式发来（地址无 .m3u8
                    // 后缀且 Content-Type 含糊，这类 CDN 常见）：
                    // 转整表模式收齐、改写地址后再回，否则列表
                    // 里的子地址绕开代理或根本不被认成列表，
                    // 资产直接 Cannot Open
                    lock.lock()
                    pending.removeValue(forKey: dataTask.taskIdentifier)
                    wholeLoads[dataTask.taskIdentifier] = WholeLoad(
                        request: state.request, entry: state.entry,
                        key: state.key, data: state.sniffBuffer,
                        response: state.response
                    )
                    lock.unlock()
                    DiaryStore.shared.add(
                        "子请求 \(requestDescription(key: state.key, wrapped: state.request.request.url, real: state.response?.url)) 正文嗅探为播放列表，转整表改写"
                    )
                } else {
                    // 206 分段只拿到列表一截：取消本任务，
                    // 以整表方式重拉同一资源请求
                    let loadingRequest = state.request
                    let entry = state.entry
                    let key = state.key
                    let wrapped = state.request.request.url
                    lock.lock()
                    pending.removeValue(forKey: dataTask.taskIdentifier)
                    lock.unlock()
                    DiaryStore.shared.add(
                        "子请求 \(requestDescription(key: key, wrapped: wrapped, real: state.response?.url)) 分段响应嗅探为播放列表，改整表重拉"
                    )
                    dataTask.cancel()
                    if let wrapped {
                        startWholeLoad(
                            url: wrapped, entry: entry, key: key,
                            loadingRequest: loadingRequest
                        )
                    }
                }
                return
            }
            // 确定不是列表：把嗅探缓冲整段按流式回放
            state.sniffDecided = true
            chunk = state.sniffBuffer
            state.sniffBuffer = Data()
        }
        if state.skipBytes > 0 {
            let drop = min(Int64(chunk.count), state.skipBytes)
            state.skipBytes -= drop
            if drop > 0 {
                chunk = chunk.subdata(in: Int(drop)..<chunk.count)
            }
        }
        if !chunk.isEmpty, let dataRequest = state.request.dataRequest {
            dataRequest.respond(with: chunk)
            state.respondedBytes += Int64(chunk.count)
        }
        lock.lock()
        pending[dataTask.taskIdentifier] = state
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = pending.removeValue(forKey: task.taskIdentifier)
        let whole = wholeLoads.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let whole {
            finishWholeLoad(whole, response: task.response, error: error)
            return
        }
        guard let state else { return }
        let loadingRequest = state.request
        if let error {
            let nsError = error as NSError
            if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled {
                DiaryStore.shared.add(
                    "子请求 \(requestDescription(key: state.key, wrapped: loadingRequest.request.url, real: task.originalRequest?.url)) 传输失败：\(nsError.domain) \(nsError.code)"
                )
            }
            loadingRequest.finishLoading(with: error)
            return
        }
        // 嗅探没凑够字节任务就结束了（极短正文）：最后判定一次
        if !state.sniffDecided, !state.sniffBuffer.isEmpty {
            if Self.sniffPlaylist(state.sniffBuffer) == true {
                finishWholeLoad(
                    WholeLoad(
                        request: loadingRequest, entry: state.entry,
                        key: state.key, data: state.sniffBuffer,
                        response: state.response
                    ),
                    response: task.response, error: nil
                )
                return
            }
            var chunk = state.sniffBuffer
            if state.skipBytes > 0 {
                let drop = min(Int64(chunk.count), state.skipBytes)
                chunk = chunk.subdata(in: Int(drop)..<chunk.count)
            }
            if !chunk.isEmpty {
                loadingRequest.dataRequest?.respond(with: chunk)
            }
        }
        logStreamingCompletion(state, response: task.response)
        loadingRequest.finishLoading()
    }

    /// 流式子请求完成日志：分片只记首个与每 25 个，
    /// 其余类型逐个记，避免刷满 500 条日记环
    private func logStreamingCompletion(_ state: StreamingState, response: URLResponse?) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let description = requestDescription(
            key: state.key, wrapped: state.request.request.url,
            real: response?.url
        )
        if description.hasPrefix("分片") {
            lock.lock()
            let count = (segmentOKCounts[state.key] ?? 0) + 1
            segmentOKCounts[state.key] = count
            lock.unlock()
            if count == 1 || count % 25 == 0 {
                DiaryStore.shared.add(
                    "子请求 \(description) → \(status)（第 \(count) 个分片，\(state.respondedBytes) 字节）"
                )
            }
        } else {
            DiaryStore.shared.add(
                "子请求 \(description) → \(status)（\(state.respondedBytes) 字节）"
            )
        }
    }

    /// 整表加载收尾：改写地址 → 回内容信息（长度按改写后字节数）→ 回数据
    private func finishWholeLoad(_ whole: WholeLoad, response: URLResponse?, error: Error?) {
        let loadingRequest = whole.request
        if let error {
            let nsError = error as NSError
            if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled {
                DiaryStore.shared.add(
                    "子请求 \(requestDescription(key: whole.key, wrapped: loadingRequest.request.url, real: whole.response?.url)) 传输失败：\(nsError.domain) \(nsError.code)"
                )
            }
            loadingRequest.finishLoading(with: error)
            return
        }
        guard let text = String(data: whole.data, encoding: .utf8) else {
            // 解不开文本：把头两字节记下来（如 1F8B = 未被
            // URLSession 解压的 gzip 残留），下次一眼定位
            let magic = whole.data.prefix(2)
                .map { String(format: "%02X", $0) }.joined()
            DiaryStore.shared.add(
                "子请求 \(requestDescription(key: whole.key, wrapped: loadingRequest.request.url, real: whole.response?.url)) 播放列表不是文本（头字节 \(magic)，\(whole.data.count) 字节）"
            )
            loadingRequest.finishLoading(with: NSError(
                domain: "LvguoPlayback", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "播放列表不是文本"]
            ))
            return
        }
        // 内容校验（对齐 Go fetchMediaPlaylist）：200 回个
        // HTML 错误页时正文不是 #EXTM3U 开头，旧写法照样改写
        // 交给播放器，结果就是一句 Cannot Open；这里直接报明
        let trimmed = text
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#EXTM3U") else {
            DiaryStore.shared.add(
                "子请求 \(requestDescription(key: whole.key, wrapped: loadingRequest.request.url, real: whole.response?.url)) 播放列表内容无效（非 #EXTM3U 开头，前 40 字：\(PlaybackEngine.sanitizeDiagnosticText(String(trimmed.prefix(40))))）"
            )
            loadingRequest.finishLoading(with: NSError(
                domain: "LvguoPlayback", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "站源未返回有效的播放列表，链接可能已失效"]
            ))
            return
        }
        let finalURL = whole.response?.url ?? response?.url
        let rewritten = rewritePlaylist(
            text, responseURL: finalURL, key: whole.key, entry: whole.entry
        )
        let status = whole.response?.statusCode
            ?? (response as? HTTPURLResponse)?.statusCode ?? 0
        DiaryStore.shared.add(
            "子请求 \(requestDescription(key: whole.key, wrapped: loadingRequest.request.url, real: finalURL)) → \(status)，已改写（\(rewritten.summary)）"
        )
        let data = Data(rewritten.text.utf8)
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = Self.playlistContentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
            logContentTypeOnce(
                key: whole.key, kind: "|playlist",
                line: "内容信息（播放列表）：UTI \(Self.playlistContentType)"
            )
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
        let entry = pending[task.taskIdentifier]?.entry
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
    /// 返回改写后文本与诊断摘要（子地址构成、是否加密、
    /// 分片容器）；每个子地址的角色同时记进 roles，
    /// 供后续子请求日志标注密钥/初始化段/媒体组/变体。
    /// 覆盖面：独立行地址 + 任意标签的 URI="..." 属性
    /// （EXT-X-KEY / EXT-X-MAP / EXT-X-MEDIA / EXT-X-PART 等
    /// 都走同一条改写路径，漏改任一都会让该子请求绕开
    /// 代理裸奔、进而 Cannot Open）。
    func rewritePlaylist(
        _ text: String, responseURL: URL?, key: String, entry: Entry
    ) -> (text: String, summary: String) {
        let base = responseURL ?? entry.baseURL
        var wrappedRoles: [String: String] = [:]
        var counts = (total: 0, keys: 0, maps: 0, medias: 0, variants: 0)
        var hasEncryptionKey = false
        var container = ""
        var isMaster = false
        func wrap(_ raw: String, role: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return raw }
            if trimmed.hasPrefix("\(Self.scheme)://") { return trimmed }
            let resolved = base.flatMap { URL(string: trimmed, relativeTo: $0)?.absoluteURL }
                ?? URL(string: trimmed)
            guard let resolved else { return raw }
            let wrapped: String
            if let base, resolved.scheme == base.scheme, resolved.host == base.host,
               resolved.port == base.port {
                var components = URLComponents()
                components.scheme = Self.scheme
                components.host = key
                let path = Self.encodedPath(of: resolved)
                components.percentEncodedPath = path.isEmpty ? "/" : path
                components.percentEncodedQuery = Self.encodedQuery(of: resolved)
                wrapped = components.url?.absoluteString ?? raw
            } else {
                let encoded = Data(resolved.absoluteString.utf8).base64URLEncodedString()
                wrapped = "\(Self.scheme)://\(key)/_ext/\(encoded)"
            }
            if wrapped != raw {
                wrappedRoles[wrapped] = role
                counts.total += 1
                switch role {
                case "密钥": counts.keys += 1
                case "初始化段": counts.maps += 1
                case "媒体组": counts.medias += 1
                case "变体列表": counts.variants += 1
                default: break
                }
                if container.isEmpty {
                    switch resolved.pathExtension.lowercased() {
                    case "ts": container = "TS"
                    case "m4s", "mp4": container = "fMP4"
                    default: break
                    }
                }
            }
            return wrapped
        }
        var output: [String] = []
        var previousWasStreamInf = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF") { isMaster = true }
                if line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-SESSION-KEY"),
                   !line.contains("METHOD=NONE") {
                    hasEncryptionKey = true
                }
                if let range = line.range(of: "URI=\"") {
                    let rest = line[range.upperBound...]
                    if let end = rest.firstIndex(of: "\"") {
                        let uri = String(rest[..<end])
                        let head = String(line[..<range.upperBound])
                        let tail = String(rest[end...])
                        let role: String
                        if line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-SESSION-KEY") {
                            role = "密钥"
                        } else if line.hasPrefix("#EXT-X-MAP") {
                            role = "初始化段"
                        } else if line.hasPrefix("#EXT-X-MEDIA") {
                            role = "媒体组"
                        } else if line.hasPrefix("#EXT-X-PART") {
                            role = "分片"
                        } else {
                            role = "标签资源"
                        }
                        output.append(head + wrap(uri, role: role) + tail)
                        previousWasStreamInf = false
                        continue
                    }
                }
                output.append(rawLine)
                previousWasStreamInf = line.hasPrefix("#EXT-X-STREAM-INF")
            } else if line.isEmpty {
                output.append(rawLine)
            } else {
                output.append(wrap(line, role: previousWasStreamInf ? "变体列表" : "子资源"))
                previousWasStreamInf = false
            }
        }
        lock.lock()
        var existing = roles[key] ?? [:]
        existing.merge(wrappedRoles) { _, new in new }
        roles[key] = existing
        lock.unlock()
        var summaryParts = ["子地址 \(counts.total)"]
        if counts.variants > 0 { summaryParts.append("变体 \(counts.variants)") }
        if counts.keys > 0 { summaryParts.append("密钥 \(counts.keys)") }
        if counts.maps > 0 { summaryParts.append("初始化段 \(counts.maps)") }
        if counts.medias > 0 { summaryParts.append("媒体组 \(counts.medias)") }
        summaryParts.append(hasEncryptionKey ? "含加密KEY" : "无加密KEY")
        if isMaster { summaryParts.append("主列表") }
        if !container.isEmpty { summaryParts.append("分片容器 \(container)") }
        return (output.joined(separator: "\n"), summaryParts.joined(separator: " · "))
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

// MARK: - 媒体格式探针

/// 直链计划的格式指纹探针：计划生成（load）时用宿主传输
/// 对目标发一次 bytes=0-15 的 Range 请求（带计划凭据头、
/// 走应用代理设置），按文件头魔数判定容器。
/// 背景（1.3 build 3 真机深日志）：直链文件被 AVPlayer
/// 在解析文件头阶段以「媒体损坏」拒收，代理/直连一致、
/// 确定性复现——先把容器钉死：若是 FLV/Matroska，
/// AVFoundation 根本不支持，换多少次地址都没用；
/// 若是标准 MP4，则要查品牌/编码/盒子结构。
/// 探针只读 16 字节，失败不阻断播放流程。
final class MediaFormatProbe: NSObject, URLSessionDataDelegate {
    enum Support {
        /// 容器本身是 AVPlayer 认的（MP4 系 ftyp）
        case supported
        /// AVPlayer 完全不支持（FLV / Matroska）
        case unsupported
        /// 判不出，或容器支持情况不单一（MPEG-TS / 未知）
        case unknown
    }

    struct Verdict {
        var status: Int
        var contentType: String
        var headHex: String
        var container: String
        var support: Support

        /// 日记行：状态 / Content-Type 原文 / 头 16 字节 / 判定
        var diaryLine: String {
            let supportText: String
            switch support {
            case .supported: supportText = "系统播放器支持的容器"
            case .unsupported: supportText = "系统播放器不支持"
            case .unknown: supportText = "支持情况待定"
            }
            return "格式探针：状态 \(status) · Content-Type "
                + "\(contentType.isEmpty ? "无" : contentType) · 头字节 "
                + "\(headHex) · 判定容器 \(container)（\(supportText)）"
        }

        /// 失败页一行摘要
        var pageLine: String { "格式探针：\(container) 格式" }
    }

    /// 魔数判定：FLV = 46 4C 56；MP4 = 偏移 4 处 ftyp；
    /// MPEG-TS = 首字节 47；Matroska = 1A 45 DF A3
    static func detectContainer(_ bytes: [UInt8]) -> (name: String, support: Support) {
        if bytes.count >= 3, bytes[0] == 0x46, bytes[1] == 0x4C, bytes[2] == 0x56 {
            return ("FLV", .unsupported)
        }
        if bytes.count >= 4, bytes[0] == 0x1A, bytes[1] == 0x45,
           bytes[2] == 0xDF, bytes[3] == 0xA3 {
            return ("Matroska", .unsupported)
        }
        if bytes.count >= 8,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return ("MP4", .supported)
        }
        if bytes.first == 0x47 {
            return ("MPEG-TS", .unknown)
        }
        return ("未知", .unknown)
    }

    private var session: URLSession?
    private var received = Data()
    private var status = 0
    private var contentType = ""
    private var finished = false
    private let completion: (Verdict?) -> Void

    private init(completion: @escaping (Verdict?) -> Void) {
        self.completion = completion
    }

    static func start(
        url: URL, headers: [String: String], sourceId: String,
        completion: @escaping (Verdict?) -> Void
    ) -> MediaFormatProbe {
        let probe = MediaFormatProbe(completion: completion)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        let configuration = URLSessionConfiguration.ephemeral
        ProxySettings.configure(
            configuration,
            effective: ProxySettings.effective(
                forModule: sourceId.isEmpty ? nil : sourceId
            )
        )
        let session = URLSession(
            configuration: configuration, delegate: probe, delegateQueue: nil
        )
        probe.session = session
        session.dataTask(with: request).resume()
        return probe
    }

    private func makeVerdict() -> Verdict {
        let bytes = [UInt8](received.prefix(16))
        let (name, support) = Self.detectContainer(bytes)
        return Verdict(
            status: status,
            contentType: contentType,
            headHex: bytes.map { String(format: "%02X", $0) }
                .joined(separator: " "),
            container: name,
            support: support
        )
    }

    private func finish(_ verdict: Verdict?) {
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()
        session = nil
        let completion = self.completion
        DispatchQueue.main.async { completion(verdict) }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        received.append(data)
        if received.count >= 16 {
            finish(makeVerdict())
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // 判定 ftyp 需要 8 字节；不足 8 字节算探针失败
        // （上层只记一行失败，不阻断播放）
        finish(received.count >= 8 ? makeVerdict() : nil)
    }
}

// MARK: - MP4 结构探针

/// MP4 结构探针（修复轮 6，日志级）：格式探针判定
/// 为 MP4 后，分段拉取解析盒子结构——ftyp 主品牌/
/// 兼容品牌、moov 位置、各轨道 stsd 首条目的编码
/// 类型与视频分辨率——解释 AVPlayer 在盒子/编码层
/// 拒收（-12848）的深层原因、给后续对齐轮留档。
/// 本轮只记日记，不据此改路由。
/// 步骤：先拉头部 64KB 解析顶层盒子；moov 盒头不在
/// 头部（或在头部但盒身被截断）时，按 Content-Range
/// 总长拉尾部 128KB 再定位解析。任一步失败只记一行
/// 结论，绝不阻断播放。
final class MP4StructureProbe: NSObject, URLSessionDataDelegate {
    private static let headBytes = 65536
    private static let tailBytes = 131072

    private var session: URLSession?
    private var received = Data()
    private var totalLength: Int64 = -1
    private var status = 0
    /// 头部/尾部两次拉取各自的 HTTP 状态（修复轮 7）：
    /// moov 定位失败要能区分是尾部被 403 拒了还是
    /// 真不在窗口内，旧版只留一个 status 且收尾行不带
    private var headStatus = 0
    private var tailStatus = 0
    private var stage = 0 // 0 = 头部，1 = 尾部
    private var finished = false
    private let url: URL
    private let headers: [String: String]
    private let sourceId: String
    private let completion: (String) -> Void
    private var headSummary = ""

    private init(
        url: URL, headers: [String: String], sourceId: String,
        completion: @escaping (String) -> Void
    ) {
        self.url = url
        self.headers = headers
        self.sourceId = sourceId
        self.completion = completion
    }

    static func start(
        url: URL, headers: [String: String], sourceId: String,
        completion: @escaping (String) -> Void
    ) -> MP4StructureProbe {
        let probe = MP4StructureProbe(
            url: url, headers: headers, sourceId: sourceId,
            completion: completion
        )
        probe.fetch(range: "bytes=0-\(headBytes - 1)")
        return probe
    }

    private func fetch(range: String) {
        session?.finishTasksAndInvalidate()
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(range, forHTTPHeaderField: "Range")
        let configuration = URLSessionConfiguration.ephemeral
        ProxySettings.configure(
            configuration,
            effective: ProxySettings.effective(
                forModule: sourceId.isEmpty ? nil : sourceId
            )
        )
        received = Data()
        let session = URLSession(
            configuration: configuration, delegate: self, delegateQueue: nil
        )
        self.session = session
        session.dataTask(with: request).resume()
    }

    private func finish(_ line: String) {
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()
        session = nil
        let completion = self.completion
        DispatchQueue.main.async { completion(line) }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            if stage == 0 {
                headStatus = http.statusCode
            } else {
                tailStatus = http.statusCode
            }
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let total = range.split(separator: "/").last,
               let value = Int64(total) {
                totalLength = value
            } else if http.statusCode == 200 {
                totalLength = http.expectedContentLength
            }
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        received.append(data)
    }

    /// 尾部拉取状态文案：0 = 响应都没拿到（传输层失败）
    private var tailStatusText: String {
        tailStatus > 0 ? "状态 \(tailStatus)" : "未拿到响应"
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            if stage == 0 {
                finish("结构探针：头部拉取失败（\(nsError.domain) \(nsError.code)）")
            } else {
                finish("结构探针：\(headSummary) · 尾部拉取失败（\(tailStatusText)，\(nsError.domain) \(nsError.code)）")
            }
            return
        }
        let bytes = [UInt8](received)
        if stage == 0 {
            guard let parsed = Self.parseTopLevel(bytes, baseOffset: 0) else {
                finish("结构探针：头部未见 ftyp（状态 \(status)，\(bytes.count) 字节）")
                return
            }
            headSummary = parsed.summary
            if parsed.moovParsed {
                finish("结构探针：\(parsed.summary)")
                return
            }
            // moov 不在头部窗口内：总长已知且文件比头部
            // 窗口大时拉尾部再找；否则就此收尾
            guard totalLength > Int64(bytes.count) else {
                finish("结构探针：\(parsed.summary) · moov 未在头部窗口内定位（头部拉取状态 \(headStatus)，总长 \(totalLength)）")
                return
            }
            stage = 1
            let start = max(0, totalLength - Int64(Self.tailBytes))
            fetch(range: "bytes=\(start)-\(totalLength - 1)")
        } else {
            let base = max(0, totalLength - Int64(bytes.count))
            if let parsed = Self.parseTopLevel(bytes, baseOffset: Int(base)),
               parsed.moovFound {
                finish("结构探针：\(headSummary) · \(parsed.moovSummary)（尾部拉取\(tailStatusText)，\(bytes.count) 字节）")
            } else {
                finish("结构探针：\(headSummary) · moov 未在尾部窗口内定位到盒头（尾部拉取\(tailStatusText)，\(bytes.count) 字节）")
            }
        }
    }

    // MARK: 盒子解析（纯函数，只读字节）

    private struct TopLevel {
        var summary = ""
        var moovFound = false
        var moovParsed = false
        var moovSummary = ""
    }

    private struct Box {
        var type: String
        var start: Int // 盒头在整个文件中的偏移
        var size: Int // 含盒头的总长（解析范围内截断时为窗口剩余）
        var header: Int // 盒头长（8 或 16）
        var truncated: Bool
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> Int {
        let hi = u32(bytes, offset)
        let lo = u32(bytes, offset + 4)
        return hi << 32 | lo
    }

    private static func typeName(_ bytes: [UInt8], _ offset: Int) -> String {
        guard offset >= 0, offset + 4 <= bytes.count else { return "" }
        return String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }

    /// 扫描一段字节里的顶层盒子（from/to 是字节数组下标）
    private static func scanBoxes(
        _ bytes: [UInt8], from: Int, to: Int, baseOffset: Int
    ) -> [Box] {
        var boxes: [Box] = []
        var cursor = from
        while cursor + 8 <= to {
            var size = u32(bytes, cursor)
            let type = typeName(bytes, cursor + 4)
            var header = 8
            if size == 1 {
                size = u64(bytes, cursor + 8)
                header = 16
            } else if size == 0 {
                size = to - cursor
            }
            guard size >= header, !type.isEmpty else { break }
            let available = to - cursor
            boxes.append(Box(
                type: type, start: baseOffset + cursor,
                size: min(size, available), header: header,
                truncated: size > available
            ))
            if size > available { break }
            cursor += size
        }
        return boxes
    }

    private static func parseTopLevel(
        _ bytes: [UInt8], baseOffset: Int
    ) -> TopLevel? {
        let boxes = scanBoxes(bytes, from: 0, to: bytes.count, baseOffset: baseOffset)
        guard let ftyp = boxes.first, ftyp.type == "ftyp" else { return nil }
        var result = TopLevel()
        // ftyp 内容：主品牌(4) + 次版本(4) + 兼容品牌(每 4)
        let contentStart = ftyp.start - baseOffset + ftyp.header
        let contentEnd = ftyp.start - baseOffset + ftyp.size
        var brands: [String] = []
        if contentStart + 4 <= bytes.count {
            brands.append("主品牌 \(typeName(bytes, contentStart))")
        }
        var compatibles: [String] = []
        var cursor = contentStart + 8
        while cursor + 4 <= contentEnd, cursor + 4 <= bytes.count {
            let brand = typeName(bytes, cursor)
            if !brand.isEmpty { compatibles.append(brand) }
            cursor += 4
        }
        if !compatibles.isEmpty {
            brands.append("兼容 \(compatibles.joined(separator: "/"))")
        }
        result.summary = "ftyp \(brands.joined(separator: " · "))"
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            return result
        }
        result.moovFound = true
        let moovLocal = moov.start - baseOffset
        let location = baseOffset == 0 ? "头部" : "尾部"
        if moov.truncated {
            result.moovSummary = "moov 在\(location)（偏移 \(moov.start)，盒身超出窗口未完整解析）"
            return result
        }
        let tracks = parseMoov(
            bytes, from: moovLocal + moov.header,
            to: moovLocal + moov.size, baseOffset: baseOffset
        )
        result.moovParsed = true
        result.moovSummary = "moov 在\(location)（偏移 \(moov.start)）"
            + (tracks.isEmpty ? "" : " · \(tracks.joined(separator: " · "))")
        result.summary += " · \(result.moovSummary)"
        return result
    }

    /// 解析 moov 内的 trak：hdlr 定轨道类型，stsd 首
    /// 条目给编码类型，视频条目另带宽高
    private static func parseMoov(
        _ bytes: [UInt8], from: Int, to: Int, baseOffset: Int
    ) -> [String] {
        var lines: [String] = []
        for trak in scanBoxes(bytes, from: from, to: to, baseOffset: baseOffset)
        where trak.type == "trak" && !trak.truncated {
            let trakStart = trak.start - baseOffset
            guard let mdia = scanBoxes(
                bytes, from: trakStart + trak.header,
                to: trakStart + trak.size, baseOffset: baseOffset
            ).first(where: { $0.type == "mdia" && !$0.truncated }) else { continue }
            let mdiaStart = mdia.start - baseOffset
            let mdiaChildren = scanBoxes(
                bytes, from: mdiaStart + mdia.header,
                to: mdiaStart + mdia.size, baseOffset: baseOffset
            )
            var handler = ""
            if let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }) {
                // hdlr 内容：版本/标志(4) + pre_defined(4) + handler(4)
                let at = hdlr.start - baseOffset + hdlr.header + 8
                handler = typeName(bytes, at)
            }
            guard let minf = mdiaChildren.first(
                where: { $0.type == "minf" && !$0.truncated }
            ) else { continue }
            let minfStart = minf.start - baseOffset
            guard let stbl = scanBoxes(
                bytes, from: minfStart + minf.header,
                to: minfStart + minf.size, baseOffset: baseOffset
            ).first(where: { $0.type == "stbl" && !$0.truncated }) else { continue }
            let stblStart = stbl.start - baseOffset
            guard let stsd = scanBoxes(
                bytes, from: stblStart + stbl.header,
                to: stblStart + stbl.size, baseOffset: baseOffset
            ).first(where: { $0.type == "stsd" }) else { continue }
            // stsd 内容：版本/标志(4) + 条目数(4) + 条目
            // （条目：长(4) + 类型(4) + 内容）
            let entryAt = stsd.start - baseOffset + stsd.header + 8
            guard entryAt + 8 <= bytes.count else { continue }
            let codec = typeName(bytes, entryAt + 4)
            switch handler {
            case "vide":
                // 视觉样本条目：宽在条目头 +32、高 +34
                var line = "视频 \(codec)"
                if entryAt + 36 <= bytes.count {
                    let width = u16(bytes, entryAt + 32)
                    let height = u16(bytes, entryAt + 34)
                    if width > 0, height > 0 {
                        line += " \(width)×\(height)"
                    }
                }
                lines.append(line)
            case "soun":
                lines.append("音频 \(codec)")
            default:
                lines.append("轨道(\(handler.isEmpty ? "?" : handler)) \(codec)")
            }
        }
        return lines
    }
}

/// 软件内核控制通道：引擎在软件内核模式下把
/// play/pause/seek/倍速/静音/截图转发给实际的内核
/// 表面（SoftwarePlayerView 装载时注册，卸载时注销），
/// 播放页原有的控件层因此对两个内核都成立。
protocol SoftwareKernelControlling: AnyObject {
    func kernelPlay()
    func kernelPause()
    func kernelSeek(to seconds: Double)
    func kernelSetRate(_ rate: Float)
    func kernelSetMuted(_ muted: Bool)
    func kernelSnapshot() async -> CGImage?
    /// 首帧是否已真正渲染（渲染视图拿到过解码帧；
    /// 位置推进是墙钟推算、与渲染无关，不能单独作数）
    func kernelHasRenderedFrame() -> Bool
    /// 渲染视图是否已上屏（在 window 内、frame 非零、未隐藏）
    func kernelIsPresented() -> Bool
    /// 视图状态一句话（window/frame/hidden/父链），供日记取证
    func kernelViewStateDescription() -> String
    /// 强制重挂渲染视图（在播但未上屏时的一次自愈）
    func kernelRehost()
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
    /// 本次 load 是否走了资源代理、是否已试过直连兜底，
    /// 以及代理路径的失败原文（最终报错时与直连错误合并呈现）
    private var currentLoadUsedProxy = false
    private var triedDirectFallback = false
    private var proxyFailureRaw = ""
    /// 格式探针（直链计划）：结果供失败分类与失败页文案
    private var probeVerdict: MediaFormatProbe.Verdict?
    private var activeProbe: MediaFormatProbe?
    /// 本次 load 是否由恢复阶梯触发：恢复链内的 load
    /// 不重置格式失败计数与定性（新签名地址每轮都不同，
    /// 不能靠地址变化判断是不是新的一轮用户播放）
    private var inRecoveryChain = false
    /// 「媒体损坏/格式不受支持」类失败已用掉的确认重取
    /// 次数（上限 1：确定性失败不进恢复阶梯风暴重试）
    private var formatFailureRetries = 0
    /// 本轮失败链中已确认的格式类定性（代理/直连任一
    /// 路径命中即成立，最终报错按格式类呈现）
    private var chainFormatFatal = false
    /// 双内核路由状态：当前活动内核与软件内核的请求
    /// （播放页据此换表面）；本链试过哪个内核、是否
    /// 已确认播成功并写过内核记忆，都在这里记账
    @Published private(set) var activeKernel: PlaybackKernel = .avplayer
    @Published private(set) var softwareRequest: PlaybackRequest?
    weak var softwareControl: SoftwareKernelControlling?
    private var triedSoftwareThisChain = false
    private var triedAVPlayerThisChain = false
    private var chainSuccessRecorded = false
    private var lastProgressCallbackAt = Date.distantPast
    // 软件内核可观测（修复轮 6）：状态日志去重、就绪
    // 时刻、首帧证据、未上屏标记、心跳节流；每次软件
    // 内核尝试（startSoftwareKernel）重置
    private var softwareLastStateName = ""
    private var softwareReadyAt: Date?
    private var softwareFirstFrameSeen = false
    private var softwareNotPresentedLogged = false
    private var softwareLastHeartbeatAt = Date.distantPast
    /// 回环媒体代理（修复轮 7）：软件内核本次打开用的
    /// 注册 token，换打开/换内核时延迟注销（等旧表面
    /// 拆除，避免其在途回环请求先撞 404）
    private var softwareProxyToken: String?
    /// 缓冲首次越过 0 已记日记（每次软件内核尝试重置）
    private var softwareBufferedLogged = false
    /// MP4 结构探针（修复轮 6，日志级）：格式探针判定
    /// 为 MP4 时并发跑，结果只进日记、不改路由
    private var activeStructureProbe: MP4StructureProbe?
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
        if !inRecoveryChain {
            // 新的一次用户播放：格式失败计数、定性与
            // 探针结果全部重置；恢复链内的重开保留
            formatFailureRetries = 0
            chainFormatFatal = false
            probeVerdict = nil
            triedSoftwareThisChain = false
            triedAVPlayerThisChain = false
            chainSuccessRecorded = false
        }
        inRecoveryChain = false
        if !recovering {
            loadingMessage = "正在准备播放"
        }
        phase = .loading

        if let loaderKey {
            resourceLoader.unregister(loaderKey)
            self.loaderKey = nil
        }
        triedDirectFallback = false
        proxyFailureRaw = ""
        currentLoadUsedProxy = false
        DiaryStore.shared.add("播放计划：\(Self.planSummary(request))")
        // 直链计划：并发发一次 16 字节格式探针（不阻断
        // 播放），结果进日记；失败定性与失败页摘要用它
        activeProbe = nil
        if let url = request.url, request.playlistText == nil, !request.isLocal,
           url.scheme == "http" || url.scheme == "https" {
            activeProbe = MediaFormatProbe.start(
                url: url, headers: request.headers, sourceId: request.sourceId
            ) { [weak self] verdict in
                guard let self, generation == self.loadGeneration else { return }
                if let verdict {
                    self.probeVerdict = verdict
                    DiaryStore.shared.add(verdict.diaryLine)
                    // MP4 结构探针（修复轮 6）：解析 ftyp
                    // 品牌 / moov 位置 / 轨道编码，解释
                    // 系统内核 -12848 拒收的深层原因；
                    // 只记日记，不据此改路由
                    if verdict.container == "MP4", let probeURL = request.url {
                        self.activeStructureProbe = MP4StructureProbe.start(
                            url: probeURL, headers: request.headers,
                            sourceId: request.sourceId
                        ) { line in
                            DiaryStore.shared.add(line)
                        }
                    }
                    // 探针晚于最终失败到达时，补进失败页
                    if self.phase == .failed,
                       !self.failureText.contains("格式探针") {
                        self.failureText += "\n\(verdict.pageLine)"
                    }
                    // 探针分流（只作首次定性：该来源没有
                    // 内核记忆、本链还没试过软件内核时）：
                    // 判定容器不受支持就不等系统内核失败，
                    // 直接切软件内核，省一轮注定失败的尝试
                    if verdict.support == .unsupported,
                       self.activeKernel == .avplayer,
                       self.phase != .ready,
                       !self.triedSoftwareThisChain,
                       KernelMemoryStore.shared.kernel(for: request) == nil,
                       let current = self.currentRequest,
                       current.url != nil {
                        DiaryStore.shared.add(
                            "路由：探针判定 \(verdict.container) 不受系统内核支持，切软件内核"
                        )
                        var routed = current
                        if self.currentTime > 1 {
                            routed.startPosition = self.currentTime
                        }
                        self.startSoftwareKernel(routed, generation: generation)
                    }
                } else {
                    DiaryStore.shared.add("格式探针：失败（未拿到文件头）")
                }
            }
        }

        // 双内核路由：有记忆先用记忆的内核；没记忆先走
        // 系统内核，探针分流与失败换内核在后续环节处理。
        // 只有播放列表文本、没有地址的计划进不了软件
        // 内核（KSPlayer 需要真实地址），固定系统内核
        let memoryKernel = KernelMemoryStore.shared.kernel(for: request)
        if let memoryKernel {
            DiaryStore.shared.add(
                "路由：来源已记住\(memoryKernel.displayName)，优先使用"
            )
        }
        if memoryKernel == .software, request.url != nil {
            startSoftwareKernel(request, generation: generation)
            return
        }
        installAVPlayer(request, generation: generation)
    }

    /// 系统内核打开：组装 AVURLAsset（带头走资源代理）
    /// 并装上 item 状态观察
    private func installAVPlayer(_ request: PlaybackRequest, generation: Int) {
        releaseSoftwareProxy()
        activeKernel = .avplayer
        softwareRequest = nil
        triedAVPlayerThisChain = true
        let asset: AVURLAsset
        let needsProxy = !request.headers.isEmpty || request.playlistText != nil
        if needsProxy, request.isPlayable {
            currentLoadUsedProxy = true
            let key = resourceLoader.register(PlaybackResourceLoader.Entry(
                baseURL: request.url,
                headers: request.headers,
                playlistText: request.playlistText
            ), sourceId: request.sourceId)
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

        installItem(asset: asset, generation: generation)
    }

    /// 建 AVPlayerItem 并装上状态观察（首载与直连兜底共用）
    private func installItem(asset: AVURLAsset, generation: Int) {
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
                    self.formatFailureRetries = 0
                    self.chainFormatFatal = false
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
                    self.logItemDiagnostics(
                        item, stage: self.triedDirectFallback ? "直连" : "代理"
                    )
                    let formatFatal = Self.isFormatFatalError(
                        item.error.map { $0 as NSError }
                    ) || self.failureIsFormatFatal
                    if formatFatal {
                        self.chainFormatFatal = true
                    }
                    if formatFatal, !self.triedSoftwareThisChain,
                       let request = self.currentRequest, request.url != nil {
                        // 系统内核格式拒收且软件内核还没
                        // 试过：直连兜底对同一文件必然同
                        // 错，跳过它，直接换软件内核
                        DiaryStore.shared.add("路由：系统内核格式拒收，换软件内核")
                        var routed = request
                        if self.currentTime > 1 {
                            routed.startPosition = self.currentTime
                        }
                        self.startSoftwareKernel(routed, generation: generation)
                        return
                    }
                    if self.currentLoadUsedProxy, !self.triedDirectFallback,
                       let request = self.currentRequest,
                       request.url != nil, !request.isLocal {
                        // 打开失败兜底（恢复阶梯新增一档）：绕开
                        // 资源代理，AVURLAsset 带 headers 直连再
                        // 试一次；直连也失败才进恢复预算
                        self.triedDirectFallback = true
                        self.proxyFailureRaw = raw
                        DiaryStore.shared.add("代理打开失败，改走直链+请求头重试：\(raw)")
                        self.installDirectFallback(generation: generation)
                    } else if !self.proxyFailureRaw.isEmpty {
                        self.handleFailure(
                            reason: "open_exception",
                            raw: "代理打开失败：\(self.proxyFailureRaw)；直连打开失败：\(raw)",
                            formatFatal: formatFatal
                        )
                    } else {
                        self.handleFailure(
                            reason: "open_exception", raw: raw,
                            formatFatal: formatFatal
                        )
                    }
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

    /// 「媒体损坏 / 格式不受支持」类确定性失败判定：
    /// AVFoundation -11829（AVErrorFileFailedToParse，
    /// 失败原因 "This media may be damaged."）/ -11828
    /// （AVErrorFileFormatNotRecognized，格式无法识别）/
    /// -11853（数据无法解析），或错误链中带 NSOSStatus
    /// -12848（1.3 build 3 真机实测的 -11829 组合）。
    /// 这类失败发生在解析文件头阶段，与网络、地址新旧
    /// 无关：同一计划重取多少次结果都一样，不进恢复
    /// 阶梯风暴重试（见 handleFailure 的格式分支）。
    static func isFormatFatalError(_ error: NSError?) -> Bool {
        guard let error else { return false }
        if error.domain == AVFoundationErrorDomain,
           error.code == -11829 || error.code == -11828 || error.code == -11853 {
            return true
        }
        var current: NSError? = error
        while let item = current {
            if item.code == -12848 { return true }
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// 本次失败是否已定性为格式类：本链任一路径的错误
    /// 命中分类，或探针判定容器不受系统播放器支持
    private var failureIsFormatFatal: Bool {
        chainFormatFatal || probeVerdict?.support == .unsupported
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

    /// 直连兜底：绕开资源代理，AVURLAsset 带 headers 直接打开。
    /// 凭据头只作用于首个请求，对直链文件与简单源有效；同时
    /// 它也是对照实验——直连能开，问题就锁定在代理层。
    private func installDirectFallback(generation: Int) {
        guard let request = currentRequest, let url = request.url else { return }
        var options: [String: Any] = [:]
        if !request.headers.isEmpty {
            // 键名即 AVURLAssetHTTPHeaderFieldsKey：该常量在本
            // SDK 的 Swift 导入里不可见（一期已踩过），用字面量
            options["AVURLAssetHTTPHeaderFieldsKey"] = request.headers
        }
        let asset = AVURLAsset(url: url, options: options)
        phase = .loading
        installItem(asset: asset, generation: generation)
    }

    // MARK: 软件内核（双内核路由）

    /// 切到软件内核打开：停掉系统内核的 item 防双声，
    /// 播放页按 softwareRequest 换上软件内核表面。
    /// 30 秒没就绪按软件内核失败处理（看门狗）
    private func startSoftwareKernel(_ request: PlaybackRequest, generation: Int) {
        guard request.url != nil else { return }
        triedSoftwareThisChain = true
        activeKernel = .software
        softwareLastStateName = ""
        softwareReadyAt = nil
        softwareFirstFrameSeen = false
        softwareNotPresentedLogged = false
        softwareLastHeartbeatAt = Date.distantPast
        softwareBufferedLogged = false
        // 软件内核改走本机回环代理取流（修复轮 7）：
        // KSPlayer/FFmpeg 自有网络层在真机上打开这类
        // CDN 地址后缓冲恒 0（build 6 实证），而 App
        // 自有传输对同一地址完全正常——远端直链计划
        // 一律先注册到 LocalFileServer 的媒体代理，
        // 内核只打开 127.0.0.1，凭据头由代理在远端
        // 侧注入，软件表面拿到的请求因此清空头。
        // 本地文件与远端播放列表（.m3u8）不走代理：
        // 前者无需取流，后者 FFmpeg 要按列表里的地址
        // 自行拉分片、且它直连时凭据头是全局生效的
        releaseSoftwareProxy()
        var routed = request
        if !request.isLocal, let url = request.url,
           url.scheme == "http" || url.scheme == "https" {
            if url.path.lowercased().hasSuffix(".m3u8") {
                DiaryStore.shared.add(
                    "路由：软件内核打开播放列表地址，直连取流（回环代理只覆盖直链媒体）"
                )
            } else if let proxy = LocalFileServer.shared.registerMediaProxy(
                url: url, headers: request.headers,
                sourceId: request.sourceId
            ) {
                softwareProxyToken = proxy.token
                routed.url = proxy.url
                routed.headers = [:]
                DiaryStore.shared.add(
                    "路由：软件内核改走本机回环代理取流（远端 \(PlaybackResourceLoader.classify(url))）"
                )
            } else {
                DiaryStore.shared.add("软件内核回环代理不可用，回退直链打开")
            }
        }
        softwareRequest = routed
        phase = .loading
        if !recovering {
            loadingMessage = "正在用软件内核打开"
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self,
                  generation == self.loadGeneration,
                  self.activeKernel == .software,
                  self.phase == .loading else { return }
            self.softwareKernelFailed("软件内核加载超时（30 秒没有开始播放）")
        }
    }

    /// 注销本次软件内核的回环代理注册：延迟 5 秒执行，
    /// 等旧软件表面拆除、其内核停稳，避免在途回环
    /// 请求先撞上 404 误报失败
    private func releaseSoftwareProxy() {
        guard let token = softwareProxyToken else { return }
        softwareProxyToken = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            LocalFileServer.shared.unregisterMediaProxy(token: token)
        }
    }

    /// 软件内核失败分类（修复轮 6）：错误对象全文里
    /// 辨认——FFmpeg 的 HTTP 错误经 av_strerror 给出
    /// 「Server returned 403 Forbidden (access denied)」
    /// 类原文（底层 AVError 的 message），挂在
    /// KSPlayerErrorDomain 错误的 NSUnderlyingErrorKey 上
    enum SoftwareFailureKind: Equatable {
        case http(Int)
        case network
        case format
        case other

        var diaryText: String {
            switch self {
            case .http(let code): return "HTTP \(code)"
            case .network: return "网络类"
            case .format: return "格式类"
            case .other: return "未分类"
            }
        }
    }

    static func classifySoftwareFailure(
        error: NSError?, message: String
    ) -> SoftwareFailureKind {
        var texts: [String] = [message]
        var domains: [String] = []
        var topDomain = ""
        var topCode = 0
        var current = error
        var isTop = true
        while let item = current {
            domains.append(item.domain)
            if isTop {
                topDomain = item.domain
                topCode = item.code
                isTop = false
            }
            texts.append(item.localizedDescription)
            if let underlying = item.userInfo[NSUnderlyingErrorKey] as? NSError {
                current = underlying
            } else if let underlying = item.userInfo[NSUnderlyingErrorKey] {
                // AVError 等非 NSError 底层错误：描述里
                // 带 FFmpeg 原始码与 av_strerror 文本
                texts.append(String(describing: underlying))
                current = nil
            } else {
                current = nil
            }
        }
        let joined = texts.joined(separator: " ").lowercased()
        if let regex = try? NSRegularExpression(
            pattern: "server returned\\s+(\\d{3})"
        ), let match = regex.firstMatch(
            in: joined, range: NSRange(joined.startIndex..., in: joined)
        ), let range = Range(match.range(at: 1), in: joined),
           let code = Int(joined[range]) {
            return .http(code)
        }
        if domains.contains(NSURLErrorDomain)
            || joined.contains("timed out") || joined.contains("timeout")
            || joined.contains("connection") || joined.contains("network")
            || joined.contains("unreachable") || joined.contains("could not resolve")
            || joined.contains("nodename") || joined.contains("offline") {
            return .network
        }
        if joined.contains("invalid data") || joined.contains("moov atom not found")
            || joined.contains("decoder not found")
            || joined.contains("demuxer not found")
            || joined.contains("could not find codec")
            || joined.contains("unsupported") {
            return .format
        }
        // KSPlayerErrorDomain 的码：5 = formatFindStreamInfo、
        // 9 = codecContextFindDecoder、17 = videoTracksUnplayable
        if topDomain.contains("KSPlayer"), [5, 9, 17].contains(topCode) {
            return .format
        }
        return .other
    }

    /// 软件内核错误的完整原文（失败页呈现用）：
    /// 域/码/描述 + 底层错误（含 FFmpeg 原始码与文本）
    static func softwareErrorText(_ error: NSError) -> String {
        var text = "\(error.domain) code \(error.code)：\(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] {
            text += "（底层：\(sanitizedDiagnosticValue(underlying))）"
        }
        return text
    }

    /// 软件内核失败的错误全文落盘（与系统内核侧
    /// logItemDiagnostics 同格式，地址脱敏）
    private func logSoftwareError(_ error: NSError) {
        DiaryStore.shared.add(
            "播放器错误[软件]：\(error.domain) code \(error.code)"
        )
        for (key, value) in error.userInfo.sorted(by: { $0.key < $1.key }) {
            if key == NSLocalizedDescriptionKey { continue }
            DiaryStore.shared.add(
                "  \(key) = \(Self.sanitizedDiagnosticValue(value))"
            )
        }
    }

    /// 软件内核失败（无错误对象的看门狗路径）：超时与
    /// 卡死按网络类处理——重新取址是唯一可用的解法，
    /// 且受恢复预算约束不会无限重试
    func softwareKernelFailed(_ message: String) {
        softwareKernelFailed(message: message, error: nil, forcedKind: .network)
    }

    /// 软件内核失败（coordinator 回调，带错误对象）：
    /// 先分类再进与系统内核相同的闭环（修复轮 6）：
    /// HTTP/网络类——这类 CDN 的签名地址逐请求被拒是
    /// 已知特性，同一地址换内核同样被拒，不换内核，
    /// 走恢复阶梯重新取址（退避与预算沿用）；格式类
    /// 才换另一个内核；未分类沿旧行为（没试过系统
    /// 内核先换它）；双内核都败或预算耗尽才落失败
    /// 页，失败页呈现软件内核的真实错误原文
    func softwareKernelFailed(message: String, error: NSError?) {
        softwareKernelFailed(message: message, error: error, forcedKind: nil)
    }

    private func softwareKernelFailed(
        message: String, error: NSError?, forcedKind: SoftwareFailureKind?
    ) {
        guard activeKernel == .software else { return }
        let kind = forcedKind
            ?? Self.classifySoftwareFailure(error: error, message: message)
        DiaryStore.shared.add("软件内核失败（\(kind.diaryText)）：\(message)")
        if let error {
            logSoftwareError(error)
        }
        let fullText = error.map { Self.softwareErrorText($0) } ?? message
        switch kind {
        case .http, .network:
            handleFailure(
                reason: "open_exception", raw: fullText, formatFatal: false
            )
        case .format:
            if !triedAVPlayerThisChain {
                swapToAVPlayerAfterSoftwareFailure()
            } else {
                handleFailure(
                    reason: "open_exception", raw: fullText, formatFatal: true
                )
            }
        case .other:
            if !triedAVPlayerThisChain {
                swapToAVPlayerAfterSoftwareFailure()
            } else {
                handleFailure(
                    reason: "open_exception", raw: fullText,
                    formatFatal: chainFormatFatal
                )
            }
        }
    }

    /// 软件内核失败后换系统内核同计划再试（表面随
    /// activeKernel 翻转被播放页 dismantle）
    private func swapToAVPlayerAfterSoftwareFailure() {
        releaseSoftwareProxy()
        softwareRequest = nil
        activeKernel = .avplayer
        guard var current = currentRequest else { return }
        DiaryStore.shared.add("路由：软件内核失败，换系统内核")
        if currentTime > 1 {
            current.startPosition = currentTime
        }
        installAVPlayer(current, generation: loadGeneration)
    }

    /// 软件内核状态变化（coordinator 转发 KSPlayerState
    /// 的 description）：全程进日记（修复轮 6），连续
    /// 重复状态去重，避免 buffering 抖动刷满日记环
    func noteSoftwareState(_ name: String) {
        guard activeKernel == .software else { return }
        guard name != softwareLastStateName else { return }
        softwareLastStateName = name
        DiaryStore.shared.add("软件内核状态：\(name)")
    }

    /// 软件内核首帧已渲染（coordinator 以渲染视图
    /// 拿到解码帧为准）：记一行视图状态作上屏证据
    func noteSoftwareFirstFrame() {
        guard activeKernel == .software, !softwareFirstFrameSeen else { return }
        softwareFirstFrameSeen = true
        DiaryStore.shared.add(
            "软件内核首帧已渲染（视图状态：\(softwareControl?.kernelViewStateDescription() ?? "无视图")）"
        )
    }

    /// 软件内核已就绪（出画面前一步）：置 ready，
    /// 真正的「播成功」要等位置推进后才记（见
    /// recordChainSuccessIfNeeded）
    func noteSoftwareReady() {
        guard activeKernel == .software else { return }
        if softwareReadyAt == nil {
            softwareReadyAt = Date()
        }
        phase = .ready
        isStalled = false
    }

    func noteSoftwareBuffering(_ buffering: Bool) {
        guard activeKernel == .software else { return }
        isStalled = buffering && intentToPlay
    }

    /// 软件内核播放结束：与系统内核同一套收尾
    /// （进度落盘 + 连播回调由播放页的接线处理）
    func noteSoftwareEnded() {
        guard activeKernel == .software else { return }
        if duration > 0 {
            onProgress?(duration, duration)
        }
        let expected = currentRequest?.expectedDuration ?? 0
        if expected > 0, duration > 0, expected - currentTime > 30,
           phase != .failed {
            handleFailure(reason: "early_completion", raw: lastRawError)
            return
        }
        onEnded?()
    }

    /// 软件内核进度回调（约每秒一次）：写回引擎状态，
    /// 顺带做成功判定、进度落盘节流、片尾/A-B 检查
    /// 与卡顿看门狗（与系统内核 tick 同口径）
    func noteSoftwareProgress(
        time: Double, duration: Double, buffered: Double, playing: Bool
    ) {
        guard activeKernel == .software else { return }
        currentTime = time
        if duration.isFinite, duration > 0 {
            self.duration = duration
        }
        bufferedPosition = buffered
        isPlaying = playing
        // 缓冲首次越过 0 单独记一行（修复轮 7）：build 6
        // 的故障形态正是缓冲恒 0，这一跃迁是取流活
        // 过来的最早证据，与恒 0 挂起一眼可分
        if buffered > 0, !softwareBufferedLogged {
            softwareBufferedLogged = true
            DiaryStore.shared.add(
                "软件内核缓冲推进：已缓冲 \(Int(buffered)) 秒（位置 \(Int(time)) / 总长 \(Int(duration))）"
            )
        }
        if time > lastPosition + 0.25 {
            lastPosition = time
            lastProgressAt = Date()
        }
        recordChainSuccessIfNeeded(kernel: .software, position: time)
        // 呈现检查（修复轮 6）：已就绪 5 秒后仍未满足
        // 上屏条件（首帧已渲染 + 视图在 window 内且
        // frame 非零）→ 明确记「在播但画面未上屏」并
        // 触发一次重挂自愈，与「真失败」区分开
        if phase == .ready, !softwareNotPresentedLogged,
           let readyAt = softwareReadyAt,
           Date().timeIntervalSince(readyAt) > 5,
           !(softwareFirstFrameSeen
             && (softwareControl?.kernelIsPresented() ?? false)) {
            softwareNotPresentedLogged = true
            DiaryStore.shared.add(
                "软件内核在播但画面未上屏（视图状态：\(softwareControl?.kernelViewStateDescription() ?? "无视图")）"
            )
            softwareControl?.kernelRehost()
        }
        // 心跳（每 10 秒一行）：软件内核不再是黑箱，
        // 挂起时能看到位置停在哪、呈现状态如何
        if Date().timeIntervalSince(softwareLastHeartbeatAt) > 10 {
            softwareLastHeartbeatAt = Date()
            let presented = softwareFirstFrameSeen
                && (softwareControl?.kernelIsPresented() ?? false)
            DiaryStore.shared.add(
                "软件内核心跳：位置 \(Int(time)) / 总长 \(Int(duration)) · 缓冲 \(Int(buffered)) · \(presented ? "已上屏" : "未上屏")"
            )
        }
        if Date().timeIntervalSince(lastProgressCallbackAt) > 5 {
            lastProgressCallbackAt = Date()
            onProgress?(currentTime, self.duration)
        }
        if outroThreshold > 0, !outroFired,
           self.duration > 0, self.duration - time <= outroThreshold, time > 0 {
            outroFired = true
            onOutroReached?()
        }
        if let a = abA, let b = abB, time >= b {
            seek(to: a)
        }
        if intentToPlay, phase == .ready,
           Date().timeIntervalSince(lastProgressAt) > 20 {
            lastProgressAt = Date()
            softwareKernelFailed("软件内核画面长时间没有进度")
        }
    }

    /// 「播成功」的统一判定：进入 ready 且播放位置已
    /// 越过起始位置 1 秒以上（不是打开没报错就算数）。
    /// 命中后把内核按来源记住（变化才落盘与记日记）。
    /// 软件内核再加严（修复轮 6）：其位置是墙钟推算
    /// （MEPlayerItem.currentPlaybackTime = 时钟 - 起始
    /// 时刻，与帧渲染无关），1.4 真机出现过「记了播
    /// 成功、画面全黑」的假阳性——必须同时有首帧
    /// 渲染证据且渲染视图真在 window 内、frame 非零
    private func recordChainSuccessIfNeeded(
        kernel: PlaybackKernel, position: Double
    ) {
        guard !chainSuccessRecorded, phase == .ready,
              let request = currentRequest else { return }
        guard position > request.startPosition + 1 else { return }
        if kernel == .software {
            guard softwareFirstFrameSeen,
                  softwareControl?.kernelIsPresented() ?? false else { return }
        }
        chainSuccessRecorded = true
        if KernelMemoryStore.shared.record(kernel, for: request) {
            DiaryStore.shared.add(
                "路由：\(kernel.displayName)播成功，已记住（来源 \(KernelMemoryStore.displaySource(forKey: KernelMemoryStore.key(for: request)))）"
            )
        }
    }

    /// 播放计划摘要（诊断用）：类型/主机/变体数/加密与
    /// 凭据头的名字，不含地址明细与任何头的值
    static func planSummary(_ request: PlaybackRequest) -> String {
        var parts: [String] = []
        parts.append(request.playlistText != nil ? "类型 播放列表文本" : "类型 直链")
        parts.append("主机 \(request.url?.host ?? "无")")
        parts.append("变体 \(max(request.variants.count, 1))")
        if let text = request.playlistText {
            let encrypted = text.contains("#EXT-X-KEY")
                && !text.contains("METHOD=NONE")
            parts.append(encrypted ? "含加密KEY" : "无加密KEY")
        }
        parts.append(request.headers.isEmpty
            ? "凭据头 无"
            : "凭据头 \(request.headers.keys.sorted().joined(separator: "/"))")
        if request.isLocal { parts.append("本地文件") }
        if request.expectedDuration > 0 {
            parts.append("声明时长 \(Int(request.expectedDuration))s")
        }
        return parts.joined(separator: " · ")
    }

    /// 播放失败的底层诊断落盘：NSError 全量（地址脱敏）、
    /// errorLog 事件列表、accessLog 末条。此前日记只有一句
    /// Cannot Open，无法判断断在哪一层，这轮补齐。
    private func logItemDiagnostics(_ item: AVPlayerItem, stage: String) {
        if let error = item.error as NSError? {
            DiaryStore.shared.add(
                "播放器错误[\(stage)]：\(error.domain) code \(error.code)"
            )
            for (key, value) in error.userInfo.sorted(by: { $0.key < $1.key }) {
                if key == NSLocalizedDescriptionKey { continue }
                DiaryStore.shared.add(
                    "  \(key) = \(Self.sanitizedDiagnosticValue(value))"
                )
            }
        }
        if let events = item.errorLog()?.events, !events.isEmpty {
            DiaryStore.shared.add("错误日志（共 \(events.count) 条，记最近 8 条）：")
            for event in events.suffix(8) {
                let uri = PlaybackResourceLoader.classify(
                    event.uri.flatMap { URL(string: $0) }
                )
                let server = event.serverAddress ?? "-"
                let status = event.errorStatusCode
                let domain = event.errorDomain
                var line = "  \(uri) 服务器 \(server) HTTP \(status) \(domain)"
                if let comment = event.errorComment, !comment.isEmpty {
                    line += " \(Self.sanitizeDiagnosticText(comment))"
                }
                DiaryStore.shared.add(line)
            }
        }
        if let access = item.accessLog()?.events.last {
            // 访问日志事件没有错误码字段，记地址类型与流量即可
            DiaryStore.shared.add(
                "访问日志末条：\(PlaybackResourceLoader.classify(access.uri.flatMap { URL(string: $0) }))，已下载 \(access.numberOfBytesTransferred) 字节，卡顿 \(access.numberOfStalls) 次"
            )
        }
    }

    private static func sanitizedDiagnosticValue(_ value: Any) -> String {
        if let error = value as? NSError {
            return "\(error.domain) code \(error.code)"
        }
        let text = sanitizeDiagnosticText(String(describing: value))
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }

    private static let diagnosticURLPattern = try? NSRegularExpression(
        pattern: "https?://[^\\s\"'<>]+"
    )

    /// 把文本里的完整地址替换成「类型@主机」，避免把带
    /// 签名参数的地址写进日记
    static func sanitizeDiagnosticText(_ text: String) -> String {
        guard let diagnosticURLPattern else { return text }
        var result = ""
        var lastEnd = text.startIndex
        diagnosticURLPattern.enumerateMatches(
            in: text, range: NSRange(text.startIndex..., in: text)
        ) { match, _, _ in
            guard let match,
                  let range = Range(match.range, in: text) else { return }
            result += text[lastEnd..<range.lowerBound]
            result += PlaybackResourceLoader.classify(
                URL(string: String(text[range]))
            )
            lastEnd = range.upperBound
        }
        result += text[lastEnd...]
        return result
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
        if activeKernel == .software {
            softwareControl?.kernelPlay()
            softwareControl?.kernelSetRate(playbackRate)
            isPlaying = true
            return
        }
        player.rate = playbackRate
    }

    func pause() {
        intentToPlay = false
        if activeKernel == .software {
            softwareControl?.kernelPause()
            isPlaying = false
            onProgress?(currentTime, duration)
            return
        }
        player.pause()
        onProgress?(currentTime, duration)
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        lastProgressAt = Date()
        if activeKernel == .software {
            currentTime = target
            softwareControl?.kernelSeek(to: target)
            return
        }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
        )
    }

    /// 长按倍速的临时速率：只改当前内核的实际速率，
    /// 不动 playbackRate（松手后由调用方恢复为常速值）
    func applyTransientRate(_ rate: Float) {
        if activeKernel == .software {
            softwareControl?.kernelSetRate(rate)
        } else {
            player.rate = rate
        }
    }

    func togglePlayPause() {
        if activeKernel == .software {
            if isPlaying { pause() } else { play() }
            return
        }
        if player.timeControlStatus == .playing || intentToPlay && isStalled {
            pause()
        } else {
            play()
        }
    }

    var isPaused: Bool { !intentToPlay }

    // MARK: 恢复（对齐 Flutter PlaybackRecovery）

    private func handleFailure(reason: String, raw: String, formatFatal: Bool = false) {
        lastFailureReason = reason
        lastRawError = raw
        guard !recovering, phase != .failed else { return }
        if formatFatal || failureIsFormatFatal {
            // 确定性失败（媒体损坏/格式不受支持）：同一
            // 计划最多再重取 1 次确认，不进 6 次恢复阶梯。
            // 1.3 build 3 真机实测：同一计划被整体重试
            // 十余次、每次错误完全相同，纯属风暴重试
            chainFormatFatal = true
            guard formatFailureRetries < 1, onRecover != nil else {
                failNow(reason: reason, raw: raw)
                return
            }
            formatFailureRetries += 1
            recoveryAttempts += 1
            if recoveryRefreshes < 3 { recoveryRefreshes += 1 }
            loadingMessage = "正在重新获取播放地址确认"
            phase = .loading
            scheduleRecovery(reason: reason, raw: raw, attempt: recoveryAttempts)
            return
        }
        guard recoveryAttempts < 6, onRecover != nil else {
            failNow(reason: reason, raw: raw)
            return
        }
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        let isRefresh = recoveryRefreshes < 3
        if isRefresh { recoveryRefreshes += 1 }
        loadingMessage = isRefresh ? "正在重新获取播放地址" : "正在切换备用线路"
        phase = .loading
        scheduleRecovery(reason: reason, raw: raw, attempt: attempt)
    }

    /// 恢复阶梯的一次取址调度（普通失败与格式类确认
    /// 共用）：退避后问 onRecover 要新计划，拿到就重开
    /// （标记恢复链，load 不重置格式失败计数）；拿不到
    /// 时普通失败继续阶梯、格式类直接报错。
    private func scheduleRecovery(reason: String, raw: String, attempt: Int) {
        recovering = true
        let backoff: [Double] = [0.8, 1.5, 2.5, 4.0, 6.0, 6.0]
        let delay = backoff[min(attempt - 1, backoff.count - 1)]
        let keepPosition = currentTime
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            let recover = self.onRecover
            let fresh = await recover?(reason, attempt)
            self.recovering = false
            if var fresh {
                if keepPosition > 1 {
                    fresh.startPosition = keepPosition
                }
                self.inRecoveryChain = true
                self.load(fresh, autoplay: true, isSwitch: false)
            } else if self.chainFormatFatal {
                self.failNow(reason: reason, raw: raw)
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
        if let item = player.currentItem, item.error == nil {
            // 超时/卡死类失败没有 item.error，补记错误日志事件，
            // 否则日记里同样只剩一句症状文案
            logItemDiagnostics(item, stage: "未打开")
        }
        let symptom: String
        switch reason {
        case "position_stalled_20s": symptom = "画面长时间没有进度"
        case "early_completion": symptom = "视频提前结束"
        case "open_exception": symptom = "视频打开失败"
        case "swap_no_start": symptom = "切集后没有开始播放"
        default: symptom = "播放器报错"
        }
        let isLocal = currentRequest?.isLocal ?? false
        var text: String
        if let verdict = probeVerdict, verdict.support == .unsupported, !isLocal {
            // 容器已定性为系统播放器不支持：直接写明
            // 格式，不再用笼统的「视频打开失败」掩盖定性
            text = "该视频是 \(verdict.container) 格式，系统播放器不支持此格式。"
        } else if failureIsFormatFatal, reason == "open_exception", !isLocal {
            text = "视频打开失败（文件格式不受支持或文件头损坏），"
                + "自动恢复未成功。重复获取地址不会改变结果，可换一集或选择其他清晰度。"
        } else {
            text = symptom + (isLocal
                ? "，本地视频没能播放。可重试或重新下载，也可以改为在线播放。"
                : "，自动恢复未成功。可重试、换一集或选择其他清晰度。")
        }
        if let verdict = probeVerdict {
            text += "\n\(verdict.pageLine)"
        }
        if !raw.isEmpty {
            text += "\n原始错误：\(raw)"
        }
        failureText = text
        DiaryStore.shared.add("播放失败：\(text)")
    }

    /// 用户退出播放页（播放页 onDisappear 调用）：
    /// 把「没等完就退出」与「真失败」在日记里区分开
    /// （修复轮 6：1.4 真机三集无成功无失败行，事后
    /// 无法判断是挂起还是用户提前退出）
    func notePlayerPageExited() {
        let phaseText: String
        switch phase {
        case .idle: phaseText = "idle"
        case .loading: phaseText = "loading"
        case .ready: phaseText = "ready"
        case .failed: phaseText = "failed"
        }
        DiaryStore.shared.add(
            "用户退出播放页（当时状态：\(activeKernel.displayName) · 阶段 \(phaseText) · 位置 \(Int(currentTime)) / 总长 \(Int(duration))）"
        )
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
        // 软件内核模式下系统内核无 item，周期观察者
        // 仍会以 0 时刻回调：直接返回，避免覆盖软件
        // 内核写回的进度（其进度走 noteSoftwareProgress）
        guard activeKernel == .avplayer else { return }
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
        recordChainSuccessIfNeeded(kernel: .avplayer, position: position)
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
        if activeKernel == .software {
            // 软件内核：取内核的当前帧接口（FFmpeg 解码帧）
            guard let image = await softwareControl?.kernelSnapshot() else {
                throw NSError(domain: "LvguoPlayback", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "当前没有在播的画面"])
            }
            return try Self.saveScreenshotPNG(UIImage(cgImage: image))
        }
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
        return try Self.saveScreenshotPNG(UIImage(cgImage: result.image))
    }

    private static func saveScreenshotPNG(_ image: UIImage) throws -> String {
        guard let data = image.pngData() else {
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
            let formatFatal = Self.isFormatFatalError(
                error.map { $0 as NSError }
            ) || self.failureIsFormatFatal
            if formatFatal {
                self.chainFormatFatal = true
            }
            self.handleFailure(
                reason: "open_exception",
                raw: error?.localizedDescription ?? self.lastRawError,
                formatFatal: formatFatal
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
