import KSPlayer
import SwiftUI
import UIKit

/// 软件内核（KSPlayer 的 FFmpeg 内核 KSMEPlayer）的
/// 播放表面：只负责出画面与把引擎的控制指令转给内核，
/// 控件层仍是播放页原有的那一套（引擎转发 play/pause/
/// seek/倍速，进度与状态由内核回调写回引擎）。
/// 取流路径（修复轮 7）：远端直链计划由引擎改走本机
/// 回环媒体代理（内核只打开 127.0.0.1，凭据头由代理
/// 在远端侧注入，见 PlaybackEngine.startSoftwareKernel
/// 与 LocalFileServer 的媒体代理）；本地文件、远端
/// 播放列表与代理不可用时的回退仍直连，此时凭据头
/// 经 KSOptions.appendHeader 传给 FFmpeg
/// （formatContext 的 headers 选项）。
///
/// FFmpeg 日志桥（修复轮 8）：KSPlayer 的 MEPlayerItem
/// 首次初始化时已用 av_log_set_callback 把 FFmpeg 的
/// av_log 全量转发进 KSLog（av_log 级别数值与 KSPlayer
/// 的 LogLevel 逐值对齐：error 16 / warning 24 /
/// info 32），出口是 KSOptions.logger（LogHandler
/// 协议，默认写系统日志）与 KSOptions.logLevel
/// （默认 .warning）。本桥把 logger 换成自家实现并
/// 把级别提到 .info：软件内核会话期间，av_log 转发
/// （来源文件固定为 MEPlayerItem.swift）按「FFmpeg：」
/// 前缀进播放调试日记——warning 及以上全量、info
/// 每会话前 100 行封顶、verbose 及以下不收、连续
/// 重复行折叠计数；KSPlayer 自身的 Swift 日志只收
/// error 及以上（前缀「KSPlayer：」，解码失败多走
/// 这条）。地址按宿主既有口径脱敏（完整地址替换成
/// 类型@主机），单行截断 300 字。
final class FFmpegDiaryLogHandler: LogHandler {
    static let shared = FFmpegDiaryLogHandler()

    private let lock = NSLock()
    private var sessionActive = false
    private var infoForwarded = 0
    private var lastLine: String?
    private var lastPrefix = ""
    private var repeatCount = 0
    private static let infoLimit = 100

    private init() {}

    /// 安装（幂等）：首次切软件内核时调用
    static func install() {
        KSOptions.logger = shared
        KSOptions.logLevel = .info
    }

    func beginSession() {
        lock.lock()
        flushRepeatsLocked()
        sessionActive = true
        infoForwarded = 0
        lastLine = nil
        repeatCount = 0
        lock.unlock()
    }

    func endSession() {
        lock.lock()
        flushRepeatsLocked()
        sessionActive = false
        lastLine = nil
        repeatCount = 0
        lock.unlock()
    }

    func log(
        level: LogLevel, message: CustomStringConvertible,
        file: String, function: String, line: UInt
    ) {
        // av_log 转发的调用点固定在 MEPlayerItem.swift
        // 的 av_log_set_callback 里；其余文件是
        // KSPlayer 自身的 Swift 日志
        let isFFmpeg = file == "MEPlayerItem.swift"
        let prefix: String
        if isFFmpeg {
            prefix = level.rawValue <= LogLevel.error.rawValue
                ? "FFmpeg(\(level.description))" : "FFmpeg"
        } else {
            guard level.rawValue <= LogLevel.error.rawValue else { return }
            prefix = "KSPlayer(\(level.description))"
        }
        lock.lock()
        defer { lock.unlock() }
        guard sessionActive else { return }
        if isFFmpeg {
            if level == .info {
                guard infoForwarded < Self.infoLimit else { return }
                infoForwarded += 1
            } else if level.rawValue > LogLevel.info.rawValue {
                return // verbose/debug/trace 不收
            }
        }
        var text = message.description
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        text = PlaybackEngine.sanitizeDiagnosticText(text)
            .replacingOccurrences(of: "\n", with: " ")
        if text.count > 300 {
            text = String(text.prefix(300)) + "…"
        }
        let entry = "\(prefix)：\(text)"
        if entry == lastLine {
            repeatCount += 1
            return
        }
        flushRepeatsLocked()
        lastLine = entry
        lastPrefix = prefix
        DiaryStore.shared.add(entry)
    }

    /// 折叠的重复行补一行计数（须持锁调用）
    private func flushRepeatsLocked() {
        guard repeatCount > 0, lastLine != nil else {
            repeatCount = 0
            return
        }
        let count = repeatCount
        repeatCount = 0
        DiaryStore.shared.add("\(lastPrefix)：（上一条重复 \(count) 次）")
    }
}

/// 挂载链（修复轮 6 审计，KSPlayer 2.3.4 源码核实）：
/// KSMEPlayer 在 init 里就建好 videoOutput
/// （默认 MetalPlayView），player.view 即它；本 App
/// 强制 firstPlayerType = KSMEPlayer 且 secondPlayerType
/// = nil，player 实例不中途更换，渲染视图恒为同一
/// MetalPlayView。旧版 host() 只用 frame + autoresizing
/// 挂一次、无约束、无入窗复核，也没有任何「帧真的
/// 渲染了」的证据——1.4 真机出现解码时钟在走、画面
/// 全黑而日记记「播成功」。本轮改：约束钉满容器、
/// 入窗时复核挂载、首帧以 MetalPlayView.pixelBuffer
/// 非空为证（public private(set)，拿到解码帧才置位），
/// 视图状态（window/frame/hidden/父链）进日记取证。
struct SoftwarePlayerSurface: UIViewRepresentable {
    let request: PlaybackRequest
    let engine: PlaybackEngine
    let fit: VideoFitMode
    let muted: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SoftwarePlayerContainerView {
        let container = SoftwarePlayerContainerView()
        context.coordinator.attach(
            container: container, request: request,
            engine: engine, fit: fit, muted: muted
        )
        return container
    }

    func updateUIView(_ container: SoftwarePlayerContainerView, context: Context) {
        context.coordinator.update(request: request, fit: fit)
    }

    static func dismantleUIView(
        _ container: SoftwarePlayerContainerView, coordinator: Coordinator
    ) {
        coordinator.teardown()
    }

    /// 画面比例 → 内核 contentMode 的近似映射：
    /// KSPlayer 的渲染视图只支持这三种缩放，4:3 / 16:9
    /// 等固定比例盒子没有对应实现，按等比适配处理
    static func contentMode(for fit: VideoFitMode) -> UIView.ContentMode {
        switch fit {
        case .crop: return .scaleAspectFill
        case .stretch: return .scaleToFill
        default: return .scaleAspectFit
        }
    }

    private static func makeOptions(for request: PlaybackRequest) -> KSOptions {
        let options = KSOptions()
        // 凭据头（Referer/User-Agent/Cookie 等）整体透传
        options.appendHeader(request.headers)
        if request.startPosition > 0 {
            options.startPlayTime = request.startPosition
        }
        // 锁屏/控制中心远程控制不由内核抢（与系统内核
        // 路径行为一致：本 App 未接远程控制）
        options.registerRemoteControll = false
        return options
    }

    final class Coordinator: NSObject, KSPlayerLayerDelegate, SoftwareKernelControlling {
        private var layer: KSPlayerLayer?
        private weak var container: SoftwarePlayerContainerView?
        private weak var engine: PlaybackEngine?
        private var currentURL: URL?
        private var finished = false
        /// 首帧证据已报（每段内容一次，换址重置）
        private var firstFrameReported = false
        /// 流信息已报（修复轮 8，每段内容一次，换址重置）
        private var trackInfoReported = false
        /// state .error 先于 finish(error) 到达（KSPlayerLayer
        /// 先置 state 再发 finish）：先到的 .error 不抢报，
        /// 留 0.5 秒等带真错误的 finish，超时才报笼统文案
        private var pendingErrorWork: DispatchWorkItem?
        private var windowAttachLogged = false
        /// 暂停指令来源标记（修复轮 7）：引擎经
        /// kernelPause 下达的暂停置位，内核状态回调
        /// 报 paused 时消费——区分「App 指令暂停」与
        /// 「内核自身触发的 paused」（build 6 真机出现
        /// 状态自行变 paused 而触发者不明）
        private var appCommandedPause = false

        func attach(
            container: SoftwarePlayerContainerView, request: PlaybackRequest,
            engine: PlaybackEngine, fit: VideoFitMode, muted: Bool
        ) {
            self.container = container
            self.engine = engine
            container.onWindowAttached = { [weak self] in
                guard let self else { return }
                // 入窗复核：渲染视图必须在容器里且被约束
                // 钉满；不在就补挂，并把视图状态记进日记
                if let view = self.layer?.player.view {
                    self.container?.host(view)
                }
                if !self.windowAttachLogged {
                    self.windowAttachLogged = true
                    DiaryStore.shared.add(
                        "软件视图已入窗（\(self.kernelViewStateDescription())）"
                    )
                }
            }
            guard let url = request.url else { return }
            // 强制 FFmpeg 内核：不让 KSPlayerLayer 先试
            // 它自带的 AVPlayer 实现（那正是拒收这类
            // 格式的内核），也不启用它的二线自动切换，
            // 失败统一回引擎走双内核路由
            KSOptions.firstPlayerType = KSMEPlayer.self
            KSOptions.secondPlayerType = nil
            let layer = KSPlayerLayer(
                url: url, isAutoPlay: true,
                options: SoftwarePlayerSurface.makeOptions(for: request),
                delegate: self
            )
            self.layer = layer
            currentURL = url
            finished = false
            firstFrameReported = false
            trackInfoReported = false
            container.host(layer.player.view)
            layer.player.contentMode = SoftwarePlayerSurface.contentMode(for: fit)
            layer.player.isMuted = muted
            layer.player.playbackRate = engine.playbackRate
            engine.softwareControl = self
        }

        func update(request: PlaybackRequest, fit: VideoFitMode) {
            guard let layer else { return }
            layer.player.contentMode = SoftwarePlayerSurface.contentMode(for: fit)
            if let url = request.url, url != currentURL {
                currentURL = url
                finished = false
                firstFrameReported = false
                trackInfoReported = false
                pendingErrorWork?.cancel()
                layer.set(
                    url: url,
                    options: SoftwarePlayerSurface.makeOptions(for: request)
                )
                container?.host(layer.player.view)
            }
        }

        func teardown() {
            FFmpegDiaryLogHandler.shared.endSession()
            pendingErrorWork?.cancel()
            if let engine, engine.softwareControl === self {
                engine.softwareControl = nil
            }
            layer?.stop()
            layer = nil
        }

        // MARK: KSPlayerLayerDelegate

        @MainActor
        func player(layer: KSPlayerLayer, state: KSPlayerState) {
            container?.host(layer.player.view)
            // paused 不走通用状态行：要带触发来源（见下）
            if state != .paused {
                engine?.noteSoftwareState(state.description)
            }
            switch state {
            case .readyToPlay:
                reportTrackInfoIfNeeded(layer: layer)
                engine?.noteSoftwareReady()
            case .buffering:
                engine?.noteSoftwareBuffering(true)
            case .bufferFinished:
                engine?.noteSoftwareBuffering(false)
            case .paused:
                engine?.noteSoftwareBuffering(false)
                let byApp = appCommandedPause
                appCommandedPause = false
                engine?.noteSoftwareState(
                    "paused（\(byApp ? "App 指令" : "内核自身触发")）"
                )
            case .playedToTheEnd:
                engine?.noteSoftwareEnded()
            case .error:
                scheduleGenericErrorReport()
            default:
                break
            }
        }

        @MainActor
        func player(
            layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval
        ) {
            engine?.noteSoftwareProgress(
                time: currentTime, duration: totalTime,
                buffered: layer.player.playableTime,
                playing: layer.player.isPlaying
            )
            // 首帧证据：MetalPlayView 拿到并处理了解码
            // 帧后 pixelBuffer 才非空；位置推进是墙钟
            // 推算、与渲染无关，不能单独作数
            if !firstFrameReported, kernelHasRenderedFrame() {
                firstFrameReported = true
                engine?.noteSoftwareFirstFrame()
            }
        }

        @MainActor
        func player(layer: KSPlayerLayer, finish error: Error?) {
            if let error {
                pendingErrorWork?.cancel()
                reportFailure(
                    message: error.localizedDescription,
                    error: error as NSError
                )
            }
        }

        @MainActor
        func player(
            layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval
        ) {}

        /// .error 状态先到时延迟抢报：等带真错误的
        /// finish（KSPlayerLayer 随后就发），等不到
        /// 才用笼统文案
        private func scheduleGenericErrorReport() {
            guard !finished else { return }
            pendingErrorWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.reportFailure(message: "软件内核打开失败", error: nil)
            }
            pendingErrorWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        /// 状态 error 与 finish(error) 可能先后各报一次：
        /// 引擎侧以 activeKernel 守门，这里再去重一层
        private func reportFailure(message: String, error: NSError?) {
            guard !finished else { return }
            finished = true
            engine?.softwareKernelFailed(message: message, error: error)
        }

        /// 内核选中的流信息（修复轮 8，就绪时打一次）：
        /// 编码名、像素格式、分辨率、帧率、码率都在
        /// FFmpegAssetTrack 的 description 里（经
        /// MediaPlayerTrack 协议取到）；「无视频流」
        /// 或编码为空本身就是定性结论
        private func reportTrackInfoIfNeeded(layer: KSPlayerLayer) {
            guard !trackInfoReported else { return }
            trackInfoReported = true
            let player = layer.player
            var parts: [String] = []
            let videos = player.tracks(mediaType: .video)
            if videos.isEmpty {
                parts.append("无视频流")
            }
            for (index, track) in videos.enumerated() {
                parts.append(
                    "视频\(index)：\(track.description)"
                        + "（\(track.isEnabled ? "已选" : "未选")）"
                )
            }
            for (index, track) in player.tracks(mediaType: .audio).enumerated() {
                parts.append(
                    "音频\(index)：\(track.description)"
                        + "（\(track.isEnabled ? "已选" : "未选")）"
                )
            }
            let subtitles = player.tracks(mediaType: .subtitle)
            if !subtitles.isEmpty {
                parts.append("字幕 \(subtitles.count) 条")
            }
            DiaryStore.shared.add(
                "软件内核流信息：\(parts.joined(separator: " · "))"
                    + " · 总长 \(Int(player.duration)) 秒"
            )
        }

        // MARK: SoftwareKernelControlling

        func kernelPlay() {
            appCommandedPause = false
            layer?.player.play()
        }

        func kernelPause() {
            appCommandedPause = true
            layer?.player.pause()
        }

        func kernelSeek(to seconds: Double) {
            layer?.player.seek(time: seconds) { _ in }
        }

        func kernelSetRate(_ rate: Float) {
            layer?.player.playbackRate = rate
        }

        func kernelSetMuted(_ muted: Bool) {
            layer?.player.isMuted = muted
        }

        func kernelSnapshot() async -> CGImage? {
            await layer?.player.thumbnailImageAtCurrentTime()
        }

        /// 首帧是否已真正渲染：渲染视图拿到过解码帧
        func kernelHasRenderedFrame() -> Bool {
            (layer?.player.view as? MetalPlayView)?.pixelBuffer != nil
        }

        /// 渲染视图是否已上屏：在 window 内、frame
        /// 非零、未隐藏（不含帧证据，帧证据单独查）
        func kernelIsPresented() -> Bool {
            guard let view = layer?.player.view else { return false }
            return view.window != nil
                && !view.isHidden
                && view.frame.width > 0 && view.frame.height > 0
        }

        /// 视图状态一句话（取证用）：window 有无 /
        /// frame / hidden / alpha / 父视图链
        func kernelViewStateDescription() -> String {
            guard let view = layer?.player.view else { return "渲染视图不存在" }
            var chain: [String] = []
            var node: UIView? = view
            while let current = node, chain.count < 6 {
                chain.append(String(describing: type(of: current)))
                node = current.superview
            }
            let frame = "\(Int(view.frame.width))×\(Int(view.frame.height))"
            return "window \(view.window != nil ? "有" : "无") · frame \(frame)"
                + " · hidden \(view.isHidden) · alpha \(String(format: "%.2f", view.alpha))"
                + " · 父链 \(chain.joined(separator: " ← "))"
        }

        /// 强制重挂渲染视图（在播但未上屏时的一次自愈）
        func kernelRehost() {
            guard let view = layer?.player.view else { return }
            container?.host(view, force: true)
            DiaryStore.shared.add(
                "软件视图重挂自愈（\(kernelViewStateDescription())）"
            )
        }
    }
}

/// 承载内核渲染视图的容器：以约束把渲染视图钉满
/// （旧版 frame + autoresizing 在容器首帧 bounds 为
/// 零时挂入、后续布局不保证跟随，是上屏链的薄弱点）。
/// 内核内部换渲染视图时 host 换挂新视图。
final class SoftwarePlayerContainerView: UIView {
    private weak var hostedView: UIView?
    /// 容器入窗回调（coordinator 注册）：入窗时复核挂载
    var onWindowAttached: (() -> Void)?

    func host(_ view: UIView?, force: Bool = false) {
        if !force, hostedView === view, view?.superview === self {
            return
        }
        hostedView?.removeFromSuperview()
        hostedView = view
        guard let view else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            onWindowAttached?()
        }
    }
}
