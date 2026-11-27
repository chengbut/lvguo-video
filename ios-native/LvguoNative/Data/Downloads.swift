import AVFoundation
import Foundation
import Network

/// 一个下载任务：站源集数或文件源文件。落盘形状自成一份
/// （downloads.json），文件放在 downloads/<id>/ 目录里。
struct DownloadJob: Identifiable {
    var id: String
    var kind: String = "station"       // station / file
    var title: String = ""
    var subtitle: String = ""           // 集号文本或文件名
    var fileName: String = ""           // 完成后的本地文件名（HLS 未合并时为 playlist.m3u8，合并后为 media.mp4）
    var isHLS: Bool = false
    /// 状态集对齐 Flutter DownloadJob：queued / downloading /
    /// converting（HLS 合并处理中）/ paused / completed / failed
    /// （Flutter 还有瞬态 removing，原生删除是本地同步操作，无此态）
    var state: String = "queued"
    /// 附加说明（如 HLS 合并失败后按分片形式保存的原因）
    var note: String = ""
    var bytes: Int64 = 0
    var total: Int64 = 0                // 未知为 0
    var hlsDone: Int = 0
    var hlsTotal: Int = 0
    var error: String = ""
    var createdAt: Date = Date()
    // 站源重取址信息
    var moduleId: String = ""
    var dramaJSON: String = ""
    var chapterJSON: String = ""
    var episodeIndex: Int = 0
    var episodeTotal: Int = 0
    // 文件源重取址信息
    var fileSourceId: String = ""
    var fileRef: String = ""
    // 已解析地址（首次入队时解析，作兜底）
    var resolvedURL: String = ""
    var resolvedHeadersJSON: String = ""
    /// 按站源分类保存时的子目录名（站源 = 模块 id，文件源 = 源 id）；
    /// 空 = 直接放在 downloads 根下（旧任务与未开启分类时）
    var sourceGroup: String = ""

    var progress: Double {
        if state == "completed" { return 1 }
        if isHLS, hlsTotal > 0 { return Double(hlsDone) / Double(hlsTotal) }
        if total > 0 { return min(1, Double(bytes) / Double(total)) }
        return 0
    }

    var stateLabel: String {
        // 文案逐项对齐 Flutter models.dart 的 stateLabel
        switch state {
        case "queued": return "等待下载"
        case "downloading": return "正在下载"
        case "converting": return "正在处理"
        case "paused": return "已暂停"
        case "completed": return "已下载"
        case "failed": return "下载失败"
        default: return "等待更新"
        }
    }

    func toJSON() -> [String: Any] {
        [
            "id": id, "kind": kind, "title": title, "subtitle": subtitle,
            "fileName": fileName, "isHLS": isHLS, "state": state,
            "note": note,
            "bytes": bytes, "total": total,
            "hlsDone": hlsDone, "hlsTotal": hlsTotal,
            "error": error, "createdAt": AppData.isoString(createdAt),
            "moduleId": moduleId, "dramaJSON": dramaJSON,
            "chapterJSON": chapterJSON, "episodeIndex": episodeIndex,
            "episodeTotal": episodeTotal,
            "fileSourceId": fileSourceId, "fileRef": fileRef,
            "resolvedURL": resolvedURL, "resolvedHeadersJSON": resolvedHeadersJSON,
            "sourceGroup": sourceGroup,
        ]
    }

    static func fromJSON(_ dict: [String: Any]) -> DownloadJob? {
        var job = DownloadJob(id: JSON.dictString(dict["id"]))
        guard !job.id.isEmpty else { return nil }
        job.kind = JSON.dictString(dict["kind"]).isEmpty ? "station" : JSON.dictString(dict["kind"])
        job.title = JSON.dictString(dict["title"])
        job.subtitle = JSON.dictString(dict["subtitle"])
        job.fileName = JSON.dictString(dict["fileName"])
        job.isHLS = JSON.dictBool(dict["isHLS"])
        job.note = JSON.dictString(dict["note"])
        job.state = JSON.dictString(dict["state"])
        if job.state == "downloading" || job.state == "converting" {
            job.state = "queued"  // 重启后重新排队（合并会重跑）
        }
        job.bytes = JSON.dictInt64(dict["bytes"])
        job.total = JSON.dictInt64(dict["total"])
        job.hlsDone = JSON.dictInt(dict["hlsDone"])
        job.hlsTotal = JSON.dictInt(dict["hlsTotal"])
        job.error = JSON.dictString(dict["error"])
        job.createdAt = AppData.parseISODate(dict["createdAt"]) ?? Date()
        job.moduleId = JSON.dictString(dict["moduleId"])
        job.dramaJSON = JSON.dictString(dict["dramaJSON"])
        job.chapterJSON = JSON.dictString(dict["chapterJSON"])
        job.episodeIndex = JSON.dictInt(dict["episodeIndex"])
        job.episodeTotal = JSON.dictInt(dict["episodeTotal"])
        job.fileSourceId = JSON.dictString(dict["fileSourceId"])
        job.fileRef = JSON.dictString(dict["fileRef"])
        job.resolvedURL = JSON.dictString(dict["resolvedURL"])
        job.resolvedHeadersJSON = JSON.dictString(dict["resolvedHeadersJSON"])
        job.sourceGroup = JSON.dictString(dict["sourceGroup"])
        return job
    }
}

/// 用户暂停信号：run 收尾时据此把任务转 paused 而不是 failed
struct DownloadPausedError: Error {}

/// 下载管理：按资源设置的并发数执行（默认 2），进度落盘，
/// 失败可重试（站源重试会重新走 resolveMedia 取址，凭据
/// 过期也能自愈）。仅 Wi-Fi 打开时蜂窝网络下不启动新任务、
/// 单个请求也禁止走蜂窝。
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []

    private(set) var downloadsDirectory: URL
    private let jobsFile: URL
    /// 正在跑的任务集合（并发泵）：pump 按 downloadConcurrency 上限补位
    private var runningIds: Set<String> = []
    private var runTasks: [String: Task<Void, Never>] = [:]
    /// 被用户暂停的在跑任务：run 收尾时据此转 paused 而不是 failed
    private var pauseRequested: Set<String> = []
    /// 资源设置 / 下载偏好（App 启动时 installSettings 注入）
    private(set) var resourceSettings: ResourceSettingsStore?
    private(set) var downloadPreferences: DownloadPreferencesStore?
    /// 当前网络是否走 Wi-Fi（NWPathMonitor 维护，未知时 nil）
    private let pathMonitor = NWPathMonitor()
    private var pathIsWiFi: Bool?
    private lazy var sessionDelegate = DownloadSessionDelegate(manager: self)
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        // 直链下载走全局代理（委托会话全局共享；HLS 路径按模块代理）
        ProxySettings.configure(
            config, effective: ProxySettings.effective(forModule: nil)
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: queue)
    }()

    /// 站源重新取址（App 启动时 installResolvers 注入）
    var stationResolver: ((DownloadJob) async -> (url: String, headers: [String: String])?)?
    /// 文件源重新取址（App 启动时 installResolvers 注入）
    var fileResolver: ((DownloadJob) async -> (url: String, headers: [String: String])?)?

    init(dataDirectory: URL) {
        // 下载位置（存储页可改）：support 应用内部 / documents
        // 文件 App 可见，落盘在 resource-settings.json，init 时直读
        let resourceDict = AppData.readJSONDictionary(
            dataDirectory.appendingPathComponent("resource-settings.json")
        ) ?? [:]
        let location = JSON.dictString(resourceDict["downloadsLocation"])
            == "documents" ? "documents" : "support"
        let base = ResourceSettingsStore.downloadsBaseDirectory(
            dataDirectory: dataDirectory, location: location
        )
        downloadsDirectory = base.appendingPathComponent("downloads")
        jobsFile = dataDirectory.appendingPathComponent("downloads.json")
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                guard let self, self.pathIsWiFi != wifi else { return }
                self.pathIsWiFi = wifi
                self.pump()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "lvguo.download.path"))
        try? FileManager.default.createDirectory(
            at: downloadsDirectory, withIntermediateDirectories: true
        )
        if let rows = AppData.readJSON(jobsFile) as? [Any] {
            jobs = rows
                .compactMap { ($0 as? [String: Any]).flatMap(DownloadJob.fromJSON) }
                .map { job -> DownloadJob in
                    // 上次进程退出时还在下的，重启后重新排队
                    var job = job
                    if job.state == "downloading" || job.state == "converting" {
                        job.state = "queued"
                    }
                    return job
                }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// App 启动时注入取址器并启动泵：站源走模块 resolveMedia，
    /// 文件源按定位符重新取址，FTP 文件走 RETR 流式通道。
    func installResolvers(moduleStore: ModuleStore, fileStore: FileSourceStore) {
        stationResolver = { job in
            guard let provider = moduleStore.provider(for: job.moduleId),
                  let dramaData = job.dramaJSON.data(using: .utf8),
                  let dramaDict = try? JSONSerialization.jsonObject(with: dramaData) as? [String: Any],
                  let chapterData = job.chapterJSON.data(using: .utf8),
                  let chapterDict = try? JSONSerialization.jsonObject(with: chapterData) as? [String: Any]
            else { return nil }
            let drama = DramaItem.parse(dramaDict, fallbackSource: job.moduleId)
            let chapter = ChapterItem.parse(chapterDict, index: job.episodeIndex)
            do {
                let plan = try await provider.resolveMedia(
                    drama: drama, chapter: chapter,
                    index: job.episodeIndex, total: job.episodeTotal
                )
                guard !plan.url.isEmpty else { return nil }
                return (plan.url, plan.headers)
            } catch {
                return nil
            }
        }
        fileResolver = { job in
            guard let source = fileStore.sourceById(job.fileSourceId),
                  !(source.type == .ftp && !source.nativeMode) else { return nil }
            let entry = FileEntry(name: job.title, href: job.fileRef, isDirectory: false)
            do {
                let target = try await createFileSourceClient(source).target(entry)
                return (target.url, target.headers)
            } catch {
                return nil
            }
        }
        ftpDownloader = { job, destination, progress in
            guard let source = fileStore.sourceById(job.fileSourceId),
                  source.type == .ftp, !source.nativeMode else {
                throw FileSourceFailure("文件源不存在或不是 FTP")
            }
            let entry = FileEntry(name: job.title, href: job.fileRef, isDirectory: false)
            try await FtpSourceClient(source: source).download(
                entry, to: destination, progress: progress
            )
        }
        pump()
    }

    func jobDirectory(_ id: String) -> URL {
        if let job = jobs.first(where: { $0.id == id }),
           !job.sourceGroup.isEmpty {
            return downloadsDirectory
                .appendingPathComponent(job.sourceGroup)
                .appendingPathComponent(id)
        }
        return downloadsDirectory.appendingPathComponent(id)
    }

    /// App 启动时注入资源设置与下载偏好（并发/画质/VIP/
    /// 分类保存都读它们，改完即生效）
    func installSettings(
        resourceSettings: ResourceSettingsStore,
        downloadPreferences: DownloadPreferencesStore
    ) {
        self.resourceSettings = resourceSettings
        self.downloadPreferences = downloadPreferences
    }

    /// 设置页改了并发/仅 Wi-Fi 后调用：重新补位排队任务
    func settingsChanged() {
        pump()
    }

    /// 迁移下载目录（存储页「更改下载位置」）：有在跑任务时
    /// 拒绝（先暂停全部），其余整体搬目录并切换根路径。
    func relocateDownloads(toBase base: URL) throws {
        let target = base.appendingPathComponent("downloads")
        if target.standardizedFileURL == downloadsDirectory.standardizedFileURL {
            return
        }
        guard runningIds.isEmpty else {
            throw FileSourceFailure("有正在下载的任务，请先暂停全部下载再迁移")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: target, withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: downloadsDirectory.path) {
            for name in try fileManager.contentsOfDirectory(
                atPath: downloadsDirectory.path
            ) {
                let from = downloadsDirectory.appendingPathComponent(name)
                let to = target.appendingPathComponent(name)
                if fileManager.fileExists(atPath: to.path) {
                    try fileManager.removeItem(at: to)
                }
                try fileManager.moveItem(at: from, to: to)
            }
        }
        downloadsDirectory = target
    }

    func localFileURL(_ job: DownloadJob) -> URL? {
        guard job.state == "completed", !job.fileName.isEmpty else { return nil }
        let url = jobDirectory(job.id).appendingPathComponent(job.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 入队

    @discardableResult
    func enqueueStation(
        provider: ModuleProvider,
        drama: DramaItem,
        chapter: ChapterItem,
        index: Int,
        total: Int
    ) async throws -> DownloadJob {
        let plan = try await provider.resolveMedia(
            drama: drama, chapter: chapter, index: index, total: total
        )
        // 下载画质偏好（「我的 → 下载」的默认画质）：指定画质
        // 有对应变体就用它；没有时就近选（不高于指定的最高，
        // 全都更高时取最低）；0 = 自动，用模块的默认计划
        var chosenURL = plan.url
        var chosenHeaders = plan.headers
        if let wanted = downloadPreferences?.quality, wanted != 0 {
            let usable = plan.variants.filter { !$0.url.isEmpty }
            if let exact = usable.first(where: { $0.quality == wanted }) {
                chosenURL = exact.url
                chosenHeaders = exact.headers
            } else if !usable.isEmpty {
                let sorted = usable.sorted { $0.quality < $1.quality }
                let pick = sorted.last { $0.quality <= wanted } ?? sorted[0]
                chosenURL = pick.url
                chosenHeaders = pick.headers
            }
        }
        guard !chosenURL.isEmpty, URL(string: chosenURL) != nil else {
            throw FileSourceFailure(
                plan.playlistText.isEmpty
                    ? "模块没有返回可下载地址"
                    : "模块只返回了播放列表文本，暂不支持下载"
            )
        }
        var job = DownloadJob(id: Self.newId())
        job.kind = "station"
        job.title = drama.title
        job.subtitle = chapter.episodeLabel.isEmpty
            ? "第 \(index + 1) 集" : "第 \(chapter.episodeLabel) 集"
        job.moduleId = provider.manifest.id
        if resourceSettings?.downloadBySource == true {
            job.sourceGroup = Self.sanitizedGroup(provider.manifest.id)
        }
        job.dramaJSON = serializeJSON([
            "id": drama.id, "source": drama.source, "sourceId": drama.sourceId,
            "title": drama.title, "cover": drama.coverURL,
            "episodes": drama.totalEpisodes,
        ])
        job.chapterJSON = serializeJSON(chapter.raw)
        job.episodeIndex = index
        job.episodeTotal = total
        applyResolved(&job, url: chosenURL, headers: chosenHeaders)
        jobs.insert(job, at: 0)
        save()
        pump()
        return job
    }

    @discardableResult
    func enqueueFile(source: FileSource, entry: FileEntry) async throws -> DownloadJob {
        var job = DownloadJob(id: Self.newId())
        job.kind = "file"
        job.title = entry.name
        job.subtitle = source.name
        job.fileName = entry.name
        job.fileSourceId = source.id
        job.fileRef = entry.href
        job.total = entry.size
        if resourceSettings?.downloadBySource == true {
            job.sourceGroup = Self.sanitizedGroup(source.id)
        }
        if source.type != .ftp || source.nativeMode {
            let target = try await createFileSourceClient(source).target(entry)
            applyResolved(&job, url: target.url, headers: target.headers)
        }
        jobs.insert(job, at: 0)
        save()
        pump()
        return job
    }

    /// 分类子目录名清洗（模块/源 id 一般已安全，兜底处理）
    static func sanitizedGroup(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "_" : cleaned
    }

    private func applyResolved(_ job: inout DownloadJob, url: String, headers: [String: String]) {
        job.resolvedURL = url
        job.resolvedHeadersJSON = serializeJSON(headers)
        job.isHLS = URL(string: url)?.pathExtension.lowercased() == "m3u8"
        if !job.isHLS, job.fileName.isEmpty {
            job.fileName = URL(string: url)?.lastPathComponent ?? "video"
        }
        if job.isHLS {
            job.fileName = "playlist.m3u8"
        }
    }

    // MARK: - 操作

    func retry(_ job: DownloadJob) {
        update(job.id) { target in
            target.state = "queued"
            target.error = ""
            target.note = ""
            target.bytes = 0
            target.hlsDone = 0
        }
        pump()
    }

    /// 暂停（对齐 Flutter 的 pause）：排队中的直接转 paused；
    /// 正在下的取消当前传输、转 paused（HLS 已落盘分片保留，
    /// 继续时跳过；普通文件重新下）。例外：FTP 下载走自实现
    /// 通道、无法中途取消，暂停对它在传完当前文件后以
    /// 「已完成」落地（不会误标 paused）。
    func pause(_ job: DownloadJob) {
        guard job.state == "queued" || job.state == "downloading" else { return }
        if job.state == "queued" {
            update(job.id) { $0.state = "paused" }
            return
        }
        pauseRequested.insert(job.id)
        sessionDelegate.cancelTask(jobId: job.id)
        runTasks[job.id]?.cancel()
    }

    /// 继续（对齐 Flutter 的 resume：paused/failed 都可继续）
    func resume(_ job: DownloadJob) {
        guard job.state == "paused" || job.state == "failed" else { return }
        update(job.id) { target in
            target.state = "queued"
            target.error = ""
        }
        pump()
    }

    func pauseAll() {
        for job in jobs where job.state == "queued" || job.state == "downloading" {
            pause(job)
        }
    }

    func resumeAll() {
        for job in jobs where job.state == "paused" || job.state == "failed" {
            resume(job)
        }
    }

    /// 本地播放失败时的在线回退请求（站源重新取址 / 文件源
    /// 重新 target），供播放页的「改为在线播放」与恢复取址用
    func fallbackRequest(for job: DownloadJob) async -> PlaybackRequest? {
        if job.kind == "station", let stationResolver,
           let resolved = await stationResolver(job),
           let url = URL(string: resolved.url) {
            return PlaybackRequest(
                url: url, headers: resolved.headers,
                title: "\(job.title) \(job.subtitle)"
            )
        }
        if job.kind == "file", let fileResolver,
           let resolved = await fileResolver(job),
           let url = URL(string: resolved.url) {
            return PlaybackRequest(
                url: url, headers: resolved.headers, title: job.title
            )
        }
        return nil
    }

    func delete(_ job: DownloadJob) {
        sessionDelegate.cancel(jobId: job.id)
        sessionDelegate.cancelTask(jobId: job.id)
        pauseRequested.remove(job.id)
        runTasks[job.id]?.cancel()
        jobs.removeAll { $0.id == job.id }
        try? FileManager.default.removeItem(at: jobDirectory(job.id))
        save()
        // 正在下的被删时，run 收尾会清 runningIds 并推进队列
    }

    // MARK: - 执行

    /// 仅 Wi-Fi 下载的闸门：打开且当前明确不在 Wi-Fi 上时
    /// 不启动新任务（已在跑的由单请求 allowsCellularAccess 约束）
    private var networkAllowsDownloads: Bool {
        !DownloadPolicy.wifiOnlyDownloads || (pathIsWiFi ?? true)
    }

    private func pump() {
        guard networkAllowsDownloads else { return }
        let limit = max(1, resourceSettings?.downloadConcurrency ?? 2)
        while runningIds.count < limit {
            guard let next = jobs.first(where: { $0.state == "queued" })
            else { return }
            runningIds.insert(next.id)
            update(next.id) { $0.state = "downloading"; $0.error = "" }
            runTasks[next.id] = Task { [weak self] in
                await self?.run(next.id)
            }
        }
    }

    private func run(_ jobId: String) async {
        guard let job = jobs.first(where: { $0.id == jobId }) else {
            runningIds.remove(jobId)
            runTasks.removeValue(forKey: jobId)
            pump()
            return
        }
        do {
            if job.kind == "file", await isFtpJob(job) {
                try await runFtp(job)
            } else if job.isHLS {
                try await runHLS(job)
            } else {
                try await runDirect(job)
            }
            // HLS 下载完先合并为单文件（converting 态），再标完成
            if job.isHLS {
                await convertHLS(jobId)
            }
            pauseRequested.remove(jobId)
            update(jobId) { target in
                target.state = "completed"
                target.error = ""
                if target.total > 0 { target.bytes = target.total }
            }
        } catch {
            if pauseRequested.remove(jobId) != nil || error is DownloadPausedError {
                update(jobId) { target in
                    target.state = "paused"
                    target.error = ""
                }
            } else {
                update(jobId) { target in
                    target.state = "failed"
                    target.error = error.localizedDescription
                }
                DiaryStore.shared.add(
                    "下载失败：\(job.title) \(job.subtitle)："
                        + error.localizedDescription
                )
            }
        }
        runningIds.remove(jobId)
        runTasks.removeValue(forKey: jobId)
        pump()
    }

    /// HLS 合并为单文件（对齐 Flutter/Go 的合并形态）：用
    /// AVAssetExportSession 直通导出 media.mp4，成功后删分片
    /// 与播放列表。某些编码（如 AV1、AC-3 音频）直通导出会
    /// 失败——那种情况保留分片形式，原因写进 job.note 在
    /// 下载页透出（见 README 对齐表）。
    private func convertHLS(_ jobId: String) async {
        update(jobId) { $0.state = "converting" }
        let directory = jobDirectory(jobId)
        guard let playlistURL = LocalFileServer.shared.url(
            jobId: jobId, fileName: "playlist.m3u8", root: downloadsDirectory
        ) else {
            update(jobId) { $0.note = "本地播放服务启动失败，已按分片形式保存" }
            return
        }
        let asset = AVURLAsset(url: playlistURL)
        guard let exporter = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        ) else {
            update(jobId) { $0.note = "无法创建合并导出，已按分片形式保存" }
            return
        }
        let output = directory.appendingPathComponent("media.mp4")
        try? FileManager.default.removeItem(at: output)
        do {
            try await exporter.export(to: output, as: .mp4)
            let size = (try? FileManager.default.attributesOfItem(
                atPath: output.path
            ))?[.size] as? Int64 ?? 0
            for name in (try? FileManager.default.contentsOfDirectory(
                atPath: directory.path
            )) ?? [] where name != "media.mp4" {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(name)
                )
            }
            update(jobId) { target in
                target.fileName = "media.mp4"
                target.isHLS = false
                target.bytes = size
                target.note = ""
            }
        } catch {
            update(jobId) { target in
                target.note = "合并为单文件失败（\(error.localizedDescription)），已按分片形式保存"
            }
        }
    }

    private func isFtpJob(_ job: DownloadJob) async -> Bool {
        // FTP 的 RETR 下载不能走 HTTP：由 fileResolver 所在页面判定
        // 不便，这里按解析地址为空且 kind=file 粗判，再由 runFtp
        // 内部用 fileFtpDownloader 注入完成（见下）。
        job.kind == "file" && ftpDownloader != nil && job.resolvedURL.isEmpty
    }

    /// FTP 下载执行体（由持有 FileSourceStore 的页面注入，
    /// 避免 DownloadManager 反向依赖文件源存储）
    var ftpDownloader: ((DownloadJob, URL, @escaping (Int64) -> Void) async throws -> Void)?

    private func runFtp(_ job: DownloadJob) async throws {
        guard let ftpDownloader else {
            throw FileSourceFailure("FTP 下载通道未就绪")
        }
        let directory = jobDirectory(job.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(job.fileName)
        try await ftpDownloader(job, destination) { [weak self] written in
            Task { @MainActor [weak self] in
                self?.update(job.id, persist: false) { $0.bytes = written }
            }
        }
    }

    /// 普通文件：URLSession 下载（带进度、带请求头）
    private func runDirect(_ job: DownloadJob) async throws {
        var current = job
        if current.resolvedURL.isEmpty {
            guard let resolver = fileResolver,
                  let resolved = await resolver(current) else {
                throw FileSourceFailure("无法取得下载地址")
            }
            applyResolved(&current, url: resolved.url, headers: resolved.headers)
            update(current.id) { target in
                target.resolvedURL = current.resolvedURL
                target.resolvedHeadersJSON = current.resolvedHeadersJSON
                target.isHLS = current.isHLS
                target.fileName = current.fileName
            }
        }
        guard let url = URL(string: current.resolvedURL) else {
            throw FileSourceFailure("下载地址无效")
        }
        var request = URLRequest(url: url)
        request.allowsCellularAccess = !DownloadPolicy.wifiOnlyDownloads
        for (key, value) in current.resolvedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let directory = jobDirectory(job.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            current.fileName.isEmpty ? "video" : current.fileName
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionDelegate.register(
                jobId: job.id,
                destination: destination,
                continuation: continuation
            )
            let task = session.downloadTask(with: request)
            sessionDelegate.attach(task: task, jobId: job.id)
            task.resume()
        }
    }

    /// HLS：拉播放列表 → （主列表选最高码率）→ 逐分片下载拼接
    /// 成本地目录（分片文件 + 改写后的 playlist.m3u8），播放走
    /// 本地 HTTP 服务（见 LocalFileServer）。
    private func runHLS(_ job: DownloadJob) async throws {
        var current = job
        // 站源重试时优先重新取址（凭据可能已过期）
        if current.kind == "station",
           let resolver = stationResolver,
           let resolved = await resolver(current) {
            applyResolved(&current, url: resolved.url, headers: resolved.headers)
            update(current.id) { target in
                target.resolvedURL = current.resolvedURL
                target.resolvedHeadersJSON = current.resolvedHeadersJSON
            }
        }
        guard let playlistURL = URL(string: current.resolvedURL) else {
            throw FileSourceFailure("播放列表地址无效")
        }
        let headers = current.resolvedHeaders
        var playlist = try await fetchText(
            playlistURL, headers: headers, moduleId: job.moduleId
        )
        var mediaURL = playlistURL
        if playlist.contains("#EXT-X-STREAM-INF") {
            guard let variant = Self.pickVariant(playlist, base: playlistURL) else {
                throw FileSourceFailure("播放列表里没有可用的清晰度")
            }
            mediaURL = variant
            playlist = try await fetchText(
                variant, headers: headers, moduleId: job.moduleId
            )
        }
        if playlist.contains("METHOD="), !playlist.contains("METHOD=NONE") {
            throw FileSourceFailure("加密的播放列表暂不支持下载")
        }
        let directory = jobDirectory(job.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var rewrittenLines: [String] = []
        var segments: [(url: URL, fileName: String)] = []
        var segmentIndex = 0
        var initFileName: String?
        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = Self.attributeValue(line, key: "URI"),
                   let initURL = URL(string: uri, relativeTo: mediaURL) {
                    initFileName = "init.mp4"
                    segments.append((initURL.absoluteURL, initFileName!))
                    rewrittenLines.append("#EXT-X-MAP:URI=\"\(initFileName!)\"")
                    continue
                }
            }
            if line.hasPrefix("#") || line.isEmpty {
                rewrittenLines.append(rawLine)
                continue
            }
            guard let segmentURL = URL(string: line, relativeTo: mediaURL) else {
                continue
            }
            segmentIndex += 1
            let ext = segmentURL.pathExtension.isEmpty ? "ts" : segmentURL.pathExtension
            let fileName = String(format: "seg-%05d.%@", segmentIndex, ext)
            segments.append((segmentURL.absoluteURL, fileName))
            rewrittenLines.append(fileName)
        }
        guard segmentIndex > 0 else {
            throw FileSourceFailure("播放列表里没有分片")
        }
        // 断点续传：已完整落盘的分片先计数（分片都是原子写，
        // 存在且非空即完整），循环里直接跳过
        func existingSize(_ fileName: String) -> Int64 {
            let path = directory.appendingPathComponent(fileName).path
            let size = (try? FileManager.default.attributesOfItem(
                atPath: path
            ))?[.size] as? Int64 ?? 0
            return size
        }
        var done = 0
        var totalBytes: Int64 = 0
        for (_, fileName) in segments where fileName != initFileName {
            let size = existingSize(fileName)
            if size > 0 {
                done += 1
                totalBytes += size
            }
        }
        update(job.id) { target in
            target.hlsTotal = segmentIndex
            target.hlsDone = done
            target.bytes = totalBytes
        }
        for (url, fileName) in segments {
            if pauseRequested.contains(job.id) || Task.isCancelled {
                throw DownloadPausedError()
            }
            let destination = directory.appendingPathComponent(fileName)
            if existingSize(fileName) > 0 {
                continue
            }
            let (data, http) = try await fetchData(
                Self.request(url, headers: headers), moduleId: job.moduleId
            )
            guard (200...299).contains(http.statusCode) else {
                throw FileSourceFailure("分片下载失败（HTTP \(http.statusCode)）")
            }
            // 原子写：临时文件写完再改名，半截分片不算已完成
            let temp = directory.appendingPathComponent(fileName + ".part")
            try data.write(to: temp)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            totalBytes += Int64(data.count)
            if fileName != initFileName {
                done += 1
            }
            let snapshot = (done, totalBytes)
            update(job.id, persist: false) { target in
                target.hlsDone = snapshot.0
                target.bytes = snapshot.1
            }
        }
        try rewrittenLines.joined(separator: "\n")
            .write(to: directory.appendingPathComponent("playlist.m3u8"),
                   atomically: true, encoding: .utf8)
        update(job.id) { $0.fileName = "playlist.m3u8" }
    }

    private static func request(_ url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// HLS 拉取用的会话：按（代理 generation + 模块）缓存，
    /// 代理改动自动换新会话；全局代理对文件源任务同样生效。
    private var dataSessions: [String: URLSession] = [:]

    private func dataSession(moduleId: String) -> URLSession {
        let key = "\(ProxySettings.generation)|\(moduleId)"
        if let existing = dataSessions[key] { return existing }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        ProxySettings.configure(
            config,
            effective: ProxySettings.effective(
                forModule: moduleId.isEmpty ? nil : moduleId
            )
        )
        let created = URLSession(configuration: config)
        dataSessions[key] = created
        return created
    }

    private func fetchData(
        _ request: URLRequest, moduleId: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.allowsCellularAccess = !DownloadPolicy.wifiOnlyDownloads
        let (data, response) = try await dataSession(moduleId: moduleId)
            .data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FileSourceFailure("服务器响应异常")
        }
        return (data, http)
    }

    private func fetchText(
        _ url: URL, headers: [String: String], moduleId: String = ""
    ) async throws -> String {
        let (data, http) = try await fetchData(
            Self.request(url, headers: headers), moduleId: moduleId
        )
        guard (200...299).contains(http.statusCode) else {
            throw FileSourceFailure("播放列表拉取失败（HTTP \(http.statusCode)）")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw FileSourceFailure("播放列表不是文本")
        }
        return text
    }

    /// 主播放列表里按 BANDWIDTH 选最高的变体
    private static func pickVariant(_ playlist: String, base: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        let lines = playlist.components(separatedBy: .newlines)
        for index in lines.indices {
            let line = lines[index]
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }
            let bandwidth = Int(attributeValue(line, key: "BANDWIDTH") ?? "") ?? 0
            var cursor = index + 1
            while cursor < lines.count {
                let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                cursor += 1
                if candidate.isEmpty || candidate.hasPrefix("#") { continue }
                if let url = URL(string: candidate, relativeTo: base)?.absoluteURL {
                    if best == nil || bandwidth > best!.bandwidth {
                        best = (bandwidth, url)
                    }
                }
                break
            }
        }
        return best?.url
    }

    private static func attributeValue(_ line: String, key: String) -> String? {
        guard let range = line.range(of: "\(key)=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            let inner = rest.dropFirst()
            if let end = inner.firstIndex(of: "\"") {
                return String(inner[..<end])
            }
            return String(inner)
        }
        return rest.split(separator: ",").first.map(String.init)
    }

    // MARK: - 状态维护

    private func update(
        _ id: String, persist: Bool = true, _ mutate: (inout DownloadJob) -> Void
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        mutate(&job)
        jobs[index] = job
        if persist { save() }
    }

    fileprivate func downloadProgress(jobId: String, written: Int64, total: Int64) {
        update(jobId, persist: false) { target in
            target.bytes = written
            if total > 0 { target.total = total }
        }
    }

    private func save() {
        AppData.writeJSON(jobs.map { $0.toJSON() }, to: jobsFile)
    }

    static func newId() -> String {
        "\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }
}

extension DownloadJob {
    var resolvedHeaders: [String: String] {
        guard let data = resolvedHeadersJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in dict {
            headers[key] = JSON.dictString(value)
        }
        return headers
    }
}

/// URLSession 下载进度/完成回调：完成时必须在回调内同步搬走
/// 临时文件（回调返回后系统会删），所以目的地在注册时就定好。
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private struct Pending {
        var destination: URL
        var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]       // taskIdentifier → Pending
    private var jobByTask: [Int: String] = [:]
    private var taskByJob: [String: Int] = [:]
    private weak var manager: DownloadManager?

    init(manager: DownloadManager) {
        self.manager = manager
    }

    func register(jobId: String, destination: URL, continuation: CheckedContinuation<Void, Error>) {
        // task 还没建，先用 jobId 占位，attach 时再落 taskIdentifier
        lock.lock()
        pendingByJob[jobId] = Pending(destination: destination, continuation: continuation)
        lock.unlock()
    }

    private var pendingByJob: [String: Pending] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]

    func attach(task: URLSessionDownloadTask, jobId: String) {
        lock.lock()
        tasks[jobId] = task
        if let entry = pendingByJob.removeValue(forKey: jobId) {
            pending[task.taskIdentifier] = entry
            jobByTask[task.taskIdentifier] = jobId
            taskByJob[jobId] = task.taskIdentifier
        }
        lock.unlock()
    }

    /// 真正取消在跑的下载任务（暂停/删除用）：取消后
    /// didCompleteWithError 会把错误抛回 run 的等待点
    func cancelTask(jobId: String) {
        lock.lock()
        let task = tasks[jobId]
        lock.unlock()
        task?.cancel()
    }

    func cancel(jobId: String) {
        lock.lock()
        let identifier = taskByJob[jobId]
        lock.unlock()
        // 任务对象不在手边：靠 manager 侧把 job 标删，回调到达时
        // 找不到 job 就丢弃结果。这里只清占位。
        if identifier == nil {
            lock.lock()
            if let entry = pendingByJob.removeValue(forKey: jobId) {
                entry.continuation.resume(throwing: FileSourceFailure("下载已取消"))
            }
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let entry = pending.removeValue(forKey: downloadTask.taskIdentifier)
        let jobId = jobByTask.removeValue(forKey: downloadTask.taskIdentifier)
        if let jobId {
            taskByJob.removeValue(forKey: jobId)
            tasks.removeValue(forKey: jobId)
        }
        lock.unlock()
        guard let entry else { return }
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            entry.continuation.resume(
                throwing: FileSourceFailure("服务器返回 \(http.statusCode)")
            )
            return
        }
        do {
            if FileManager.default.fileExists(atPath: entry.destination.path) {
                try FileManager.default.removeItem(at: entry.destination)
            }
            try FileManager.default.moveItem(at: location, to: entry.destination)
            entry.continuation.resume()
        } catch {
            entry.continuation.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let jobId = jobByTask[downloadTask.taskIdentifier]
        lock.unlock()
        guard let jobId, let manager else { return }
        Task { @MainActor in
            manager.downloadProgress(
                jobId: jobId,
                written: totalBytesWritten,
                total: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        let jobId = jobByTask.removeValue(forKey: task.taskIdentifier)
        if let jobId {
            taskByJob.removeValue(forKey: jobId)
            tasks.removeValue(forKey: jobId)
        }
        lock.unlock()
        entry?.continuation.resume(throwing: error)
    }
}

// MARK: - 本地 HLS 播放服务

/// 极简本地 HTTP 服务：把下载目录挂到 http://127.0.0.1:<port>/
/// 供 AVPlayer 播本地 HLS（本地 m3u8 文件 AVPlayer 不直接吃，
/// 走回环 HTTP 是通行做法）。只绑回环、只做 GET、路径防穿越。
final class LocalFileServer {
    static let shared = LocalFileServer()

    private var listener: NWListener?
    private var root: URL?
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "lvguo.localserver")

    private init() {}

    /// 启动（已启动则直接返回基址）。root 是 downloads 目录，
    /// 播放地址形如 <base>/<jobId>/playlist.m3u8。
    func start(root: URL) -> String? {
        if let listener, listener.state == .ready, port != 0 {
            return "http://127.0.0.1:\(port)"
        }
        self.root = root
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            let created = try NWListener(using: parameters)
            created.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.port = created.port?.rawValue ?? 0
                }
            }
            created.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            created.start(queue: queue)
            listener = created
            // 端口在 ready 后才知道，稍等一拍（回环启动很快）
            let deadline = Date().addingTimeInterval(1.5)
            while port == 0, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            return port == 0 ? nil : "http://127.0.0.1:\(port)"
        } catch {
            return nil
        }
    }

    func url(jobId: String, fileName: String, root: URL) -> URL? {
        guard let base = start(root: root) else { return nil }
        return URL(string: "\(base)/\(jobId)/\(fileName)")
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
            [weak self] data, _, _, error in
            guard let self else { return }
            var combined = buffer
            if let data { combined.append(data) }
            if combined.range(of: Data("\r\n\r\n".utf8)) == nil, error == nil,
               combined.count < 65536 {
                self.receiveRequest(connection, buffer: combined)
                return
            }
            self.respond(connection, request: combined)
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        guard let root,
              let text = String(data: request, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\r\n").first else {
            connection.cancel()
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            send(connection, status: "405 Method Not Allowed", body: Data())
            return
        }
        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }
        let decoded = path.removingPercentEncoding ?? path
        let relative = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = root.appendingPathComponent(relative)
        // 防目录穿越：解析后必须仍在 root 之内
        let rootPath = root.standardizedFileURL.path
        guard fileURL.standardizedFileURL.path.hasPrefix(rootPath),
              let data = try? Data(contentsOf: fileURL) else {
            send(connection, status: "404 Not Found", body: Data())
            return
        }
        let contentType: String
        switch fileURL.pathExtension.lowercased() {
        case "m3u8": contentType = "application/vnd.apple.mpegurl"
        case "ts": contentType = "video/mp2t"
        case "mp4", "m4v": contentType = "video/mp4"
        case "mp3": contentType = "audio/mpeg"
        default: contentType = "application/octet-stream"
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\n" +
            "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(data)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(_ connection: NWConnection, status: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
