import AVFoundation
import AVKit
import KSPlayer
import SwiftUI
import UIKit

// MARK: - 软件内核画中画桥（修复轮 11）

/// 软件内核小窗桥：KSMEPlayer 自带一个基于
/// AVSampleBufferDisplayLayer 的 PiP 控制器
/// （KSPictureInPictureController，AVPictureInPictureController
/// 子类，内容源是 MetalPlayView 的 displayLayer——内核
/// 在 options.isUseDisplayLayer 成立时逐帧把解码帧
/// enqueue 进该层）。本桥只做三件事：接管该控制器的
/// delegate（不用 KSPlayerLayer 的 pipStart——它会把
/// delegate 抢成 layer 自己且其恢复回调不调
/// completionHandler，与本页 fullScreenCover 形态冲突）、
/// 观察 isPictureInPicturePossible、转发开始/停止/失败。
/// 帧供给的前提是内核走 displayLayer 渲染通路；若真机
/// 上 displayLayer 没帧，系统会报 failedToStart，本桥
/// 如实记日记并回调页面 toast，不假装成功。
///
/// 控制器会被内核中途整只替换（修复轮 12，KSPlayer
/// 2.3.4 源码实证）：MetalPlayView 在格式描述变化时
/// 换掉 displayView，KSMEPlayer 的 DisplayLayerDelegate
/// .change 随即把 _pipController 换成一只全新的
/// KSPictureInPictureController。修复轮 11 的桥只在
/// attach 与 readyToPlay 抓一次、且弱持有——旧控制器
/// 被替换后桥指向失效（弱引用变 nil），新控制器没人
/// 接 delegate、没人观察 isPossible、自动启动标志也
/// 丢在旧控制器上，真机表现为小窗按钮不出现/点了
/// 没反应。改法：桥不认死一只控制器——coordinator
/// 注入 controllerProvider 现取现用，并在每次内核
/// 状态/进度回调里调 refreshController() 核对身份，
/// 变了就重新接管（delegate + KVO + 自动启动标志）。
///
/// 修复轮 13（1.6 真机：播放页没有小窗按钮、切后台不
/// 自动进小窗）：轮 12 的接管救不回 possible——桥接管
/// 的那只内核控制器是在 makeUIView 阶段首访懒建的，
/// 绑的是尚未入窗的 displayLayer；此后桥只做身份核
/// 对、从不重建，而同一内核跨集复用同一 videoOutput，
/// 这只「出生太早」的控制器就是整场唯一一只，
/// possible 终生为 false（按钮以它为显隐条件、自动
/// 兜底也以它为门槛，两个症状同源）。改法：桥不再借
/// 内核的控制器，改为在渲染视图已上屏后用内核当前
/// displayLayer 自建一只 AVPictureInPictureController
/// （回放委托经转发代理回到 KSMEPlayer 本体），图层
/// 被换就按新图层重建；possible 的每次变化、自建
/// 时刻的图层状态、系统第一次回放状态查询都进日记，
/// 下一轮真机能一锤定音。
/// 小窗回放委托的转发代理（修复轮 13）：系统靠
/// AVPictureInPictureSampleBufferPlaybackDelegate
/// 的查询（时间轴、是否暂停）完成对 sampleBuffer
/// 型小窗的可用性评估。KSMEPlayer 本体已实现这些
/// 方法（均为 public），代理只转发，并记下系统第
/// 一次来查询的时刻——这是「系统确实在评估这只
/// 控制器」的一手证据；内核已拆除时返回安全缺省
/// （无限时间轴 + 已暂停），不假造播放状态
final class SoftwarePiPPlaybackDelegateProxy:
    NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    weak var player: KSMEPlayer?
    private var queryLogged = false

    private func noteQueryIfNeeded() {
        guard !queryLogged else { return }
        queryLogged = true
        DiaryStore.shared.add("小窗系统已开始查询回放状态（控制器进入评估）")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        noteQueryIfNeeded()
        player?.pictureInPictureController(
            pictureInPictureController, setPlaying: playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        noteQueryIfNeeded()
        guard let player else {
            return CMTimeRange(
                start: .negativeInfinity, duration: .positiveInfinity)
        }
        return player.pictureInPictureControllerTimeRangeForPlayback(
            pictureInPictureController)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        noteQueryIfNeeded()
        guard let player else { return true }
        return player.pictureInPictureControllerIsPlaybackPaused(
            pictureInPictureController)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        player?.pictureInPictureController(
            pictureInPictureController,
            didTransitionToRenderSize: newRenderSize)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime
    ) async {
        guard let player else { return }
        await player.pictureInPictureController(
            pictureInPictureController, skipByInterval: skipInterval)
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        player?
            .pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
                pictureInPictureController) ?? false
    }
}

final class SoftwarePiPBridge: NSObject, ObservableObject,
    AVPictureInPictureControllerDelegate {
    @Published var isPossible = false
    @Published var isActive = false
    var onStopped: (() -> Void)?
    var onFailed: ((String) -> Void)?
    /// coordinator 注册的延迟拆除（小窗中退出页面时
    /// teardown 先挂起，小窗关闭后由托管方调用）
    var deferredTeardownHandler: (() -> Void)?
    /// 小窗源的现取现用来源（coordinator 注入）：返回
    /// 当前软件内核的 displayLayer 与内核本体；渲染
    /// 视图未上屏（不在 window 内 / frame 为零）时
    /// 返回 nil——控制器只在图层入窗后才自建（修复
    /// 轮 13，见类头注释）
    var sourceProvider:
        (() -> (layer: AVSampleBufferDisplayLayer, player: KSMEPlayer)?)?
    /// 切后台自动进小窗（修复轮 12）：由播放页按
    /// 「自动画中画」设置同步到桥自建的控制器；按新
    /// 图层重建控制器时在 buildController 里补上，
    /// 状态回调里再调 refreshAutoStart() 复核
    var autoStartEnabled = false {
        didSet { refreshAutoStart() }
    }
    private var controller: AVPictureInPictureController?
    private let playbackProxy = SoftwarePiPPlaybackDelegateProxy()
    private var possibleObservation: NSKeyValueObservation?
    private var startWatchdog: DispatchWorkItem?
    private var lastStartManual = false

    /// 核对小窗源（coordinator 在入窗、内核状态/进度
    /// 回调里高频调用）：源未就绪（未上屏）直接返回；
    /// 没有控制器就自建一只；内核换掉 displayLayer
    /// （格式描述变化）就按新图层重建——旧控制器绑
    /// 的是已不在画面里的旧图层，继续用必然落空。
    /// 小窗进行中不重建（不亲手拆正在播的小窗）
    func refreshController() {
        guard let source = sourceProvider?() else { return }
        playbackProxy.player = source.player
        if let controller,
           controller.contentSource?.sampleBufferDisplayLayer
               === source.layer {
            return
        }
        guard !isActive else { return }
        buildController(source: source)
    }

    private func buildController(
        source: (layer: AVSampleBufferDisplayLayer, player: KSMEPlayer)
    ) {
        teardownController()
        playbackProxy.player = source.player
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: source.layer,
            playbackDelegate: playbackProxy
        )
        let created = AVPictureInPictureController(
            contentSource: contentSource)
        created.delegate = self
        created.canStartPictureInPictureAutomaticallyFromInline
            = autoStartEnabled
        controller = created
        possibleObservation = created.observe(
            \AVPictureInPictureController.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self, weak layer = source.layer] controller, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let value = controller.isPictureInPicturePossible
                guard value != self.isPossible else { return }
                self.isPossible = value
                DiaryStore.shared.add(
                    "软件内核小窗 possible 变为 \(value)"
                        + "（图层状态 \(layer?.status.rawValue ?? -1)）"
                )
            }
        }
        isPossible = created.isPictureInPicturePossible
        DiaryStore.shared.add(
            "软件内核小窗桥已自建控制器"
                + "（supported=\(AVPictureInPictureController.isPictureInPictureSupported())"
                + " possible=\(isPossible)"
                + " 图层状态 \(source.layer.status.rawValue)"
                + " 时长 \(Int(source.player.duration)) 秒）"
        )
    }

    private func teardownController() {
        startWatchdog?.cancel()
        startWatchdog = nil
        possibleObservation = nil
        controller?.delegate = nil
        controller = nil
    }

    /// 把自动启动标志以本 App 设置为准刷到当前控制器
    func refreshAutoStart() {
        controller?.canStartPictureInPictureAutomaticallyFromInline
            = autoStartEnabled
    }

    func start() { start(manual: true) }

    /// 启动小窗：possible 为 false 也照样调系统启动
    /// （KVO 值可能滞后于系统内部状态）——成败由
    /// delegate 回调与 1.2 秒看门狗兜底：手动启动
    /// 失败/无响应才经 onFailed 给页面 toast，后台
    /// 自动兜底的失败只记日记、不打扰用户
    func start(manual: Bool) {
        refreshController()
        guard let controller else {
            DiaryStore.shared.add(
                "软件内核小窗启动请求但控制器未就绪（源未上屏）")
            if manual { onFailed?("小窗暂不可用") }
            return
        }
        lastStartManual = manual
        DiaryStore.shared.add(
            "软件内核小窗启动请求（manual=\(manual) possible=\(isPossible)）")
        controller.startPictureInPicture()
        startWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.isActive else { return }
            DiaryStore.shared.add(
                "软件内核小窗启动 1.2 秒无响应（possible=\(self.isPossible)）")
            if self.lastStartManual {
                self.onFailed?("小窗暂不可用")
            }
        }
        startWatchdog = watchdog
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.2, execute: watchdog)
    }

    func stop() {
        DiaryStore.shared.add("软件内核小窗停止请求")
        controller?.stopPictureInPicture()
    }

    func runDeferredTeardown() {
        deferredTeardownHandler?()
        deferredTeardownHandler = nil
    }

    func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        DiaryStore.shared.add("软件内核小窗即将开始")
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        startWatchdog?.cancel()
        isActive = true
        DiaryStore.shared.add("软件内核小窗已开始")
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        startWatchdog?.cancel()
        isActive = false
        DiaryStore.shared.add("软件内核小窗已关闭")
        onStopped?()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        startWatchdog?.cancel()
        let nsError = error as NSError
        DiaryStore.shared.add(
            "软件内核小窗启动失败：\(error.localizedDescription)"
                + "（\(nsError.domain) \(nsError.code)）"
        )
        if lastStartManual {
            onFailed?("小窗启动失败，请重试")
        }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
            completionHandler: @escaping (Bool) -> Void
    ) {
        // 播放页仍以 fullScreenCover 呈现着，直接恢复即可
        completionHandler(true)
    }
}

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
/// 每会话前 100 行封顶、verbose 及以下不收、同类
/// 行折叠计数；KSPlayer 自身的 Swift 日志只收
/// error 及以上（前缀「KSPlayer：」，解码失败多走
/// 这条）。地址按宿主既有口径脱敏（完整地址替换成
/// 类型@主机），单行截断 300 字。
/// 折叠口径（修复轮 9 收紧）：旧版只折叠逐字相同的
/// 连续行，而 build 8 真机的 NAL 错误每条数字都不同
/// （「Invalid NAL unit size (1489824395 > 407)」）、
/// 还两类交替出现，折叠完全失效、把 500 条日记环
/// 刷爆并挤掉关键行。新版按「数字归一化后的文本」
/// 认同类：同类只落首条，其余计数，计数在下一条
/// 不同日志落盘前、会话结束时、以及冲到
/// 100/1000/10000 时各补一行汇总。
final class FFmpegDiaryLogHandler: LogHandler {
    static let shared = FFmpegDiaryLogHandler()

    private let lock = NSLock()
    private var sessionActive = false
    private var infoForwarded = 0
    /// 已落盘过的折叠键（前缀 + 数字归一化文本）
    private var writtenFoldKeys: Set<String> = []
    /// 折叠键 → 被压住的重复次数
    private var foldCounts: [String: Int] = [:]
    /// 折叠键 → 首条的前缀与原文（汇总行引用）
    private var foldHeads: [String: (prefix: String, sample: String)] = [:]
    private static let infoLimit = 100

    private init() {}

    /// 安装（幂等）：首次切软件内核时调用
    static func install() {
        KSOptions.logger = shared
        KSOptions.logLevel = .info
    }

    func beginSession() {
        lock.lock()
        flushFoldsLocked()
        sessionActive = true
        infoForwarded = 0
        writtenFoldKeys.removeAll()
        foldHeads.removeAll()
        lock.unlock()
    }

    func endSession() {
        lock.lock()
        flushFoldsLocked()
        sessionActive = false
        writtenFoldKeys.removeAll()
        foldHeads.removeAll()
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
        // 同类折叠（修复轮 9）：数字归一化后同键的行
        // 只落首条，其余计数——NAL 类错误每条数字都
        // 不同、逐字折叠对它无效
        let foldKey = "\(prefix)|\(Self.foldKeyText(text))"
        if writtenFoldKeys.contains(foldKey) {
            let count = (foldCounts[foldKey] ?? 0) + 1
            foldCounts[foldKey] = count
            if count == 100 || count == 1000 || count == 10000 {
                writeFoldSummaryLocked(key: foldKey, count: count)
                foldCounts[foldKey] = 0
            }
            return
        }
        flushFoldsLocked()
        writtenFoldKeys.insert(foldKey)
        foldHeads[foldKey] = (prefix, text)
        DiaryStore.shared.add("\(prefix)：\(text)")
    }

    /// 折叠键文本：连续数字串归一成一个 #，其余原样
    private static func foldKeyText(_ text: String) -> String {
        var result = ""
        var inDigits = false
        for character in text {
            if character.isNumber {
                if !inDigits { result.append("#") }
                inDigits = true
            } else {
                result.append(character)
                inDigits = false
            }
        }
        return result
    }

    /// 一条折叠汇总（须持锁调用）：前缀 + 次数 + 首条原文
    private func writeFoldSummaryLocked(key: String, count: Int) {
        guard let head = foldHeads[key] else { return }
        var sample = head.sample
        if sample.count > 120 {
            sample = String(sample.prefix(120)) + "…"
        }
        DiaryStore.shared.add(
            "\(head.prefix)：（同类日志重复 \(count) 次，已折叠，首条：\(sample)）"
        )
    }

    /// 把所有待汇总的折叠计数落盘（须持锁调用）
    private func flushFoldsLocked() {
        for key in foldCounts.keys.sorted() {
            guard let count = foldCounts[key], count > 0 else { continue }
            writeFoldSummaryLocked(key: key, count: count)
        }
        foldCounts.removeAll()
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
    let pipBridge: SoftwarePiPBridge

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SoftwarePlayerContainerView {
        let container = SoftwarePlayerContainerView()
        context.coordinator.attach(
            container: container, request: request,
            engine: engine, fit: fit, muted: muted,
            pipBridge: pipBridge
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
        // 计划自带 CENC 密钥（修复轮 10）：经 KSPlayer
        // 的 formatContextOptions 进 avformat_open_input
        // 的选项字典，即 FFmpeg mov 解复用器的标准
        // decryption_key 选项——与老版 mpv 的
        // demuxer-lavf-o decryption_key= 同一口子。
        // 红线：值只进选项字典，绝不进日记/失败页
        if !request.decryptionKeyHex.isEmpty {
            options.formatContextOptions["decryption_key"] = request.decryptionKeyHex
        }
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
        /// 软件内核小窗桥（修复轮 11 建桥，轮 13 改为
        /// 桥自建控制器，见 SoftwarePiPBridge 类头注释）
        private weak var pipBridge: SoftwarePiPBridge?

        func attach(
            container: SoftwarePlayerContainerView, request: PlaybackRequest,
            engine: PlaybackEngine, fit: VideoFitMode, muted: Bool,
            pipBridge: SoftwarePiPBridge
        ) {
            self.container = container
            self.engine = engine
            self.pipBridge = pipBridge
            pipBridge.deferredTeardownHandler = { [weak self] in
                self?.teardownNow()
            }
            container.onWindowAttached = { [weak self] in
                guard let self else { return }
                // 入窗复核：渲染视图必须在容器里且被约束
                // 钉满；不在就补挂，并把视图状态记进日记
                if let view = self.layer?.player.view {
                    self.container?.host(view)
                }
                // 小窗控制器只在图层入窗后自建（修复轮 13）：
                // 入窗这一刻正是源就绪的时刻，立即核对一次
                self.pipBridge?.refreshController()
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
            // 小窗桥的小窗源（修复轮 13）：桥自建控制器
            // 需要内核当前的 displayLayer 与内核本体；
            // 渲染视图未上屏时返回 nil、桥不建控制器
            // （桥弱持有 coordinator 的 layer，不成环）
            pipBridge.sourceProvider = { [weak self] in
                guard let self,
                      let mePlayer = self.layer?.player as? KSMEPlayer,
                      let displayLayer = mePlayer.videoOutput?.displayLayer,
                      self.kernelIsPresented()
                else { return nil }
                return (layer: displayLayer, player: mePlayer)
            }
            container.host(layer.player.view)
            layer.player.contentMode = SoftwarePlayerSurface.contentMode(for: fit)
            layer.player.isMuted = muted
            layer.player.playbackRate = engine.playbackRate
            engine.softwareControl = self
            attachPiPController()
        }

        /// 催小窗桥核对小窗源（修复轮 13）：桥自建
        /// 控制器，源未上屏时核对是无操作；attach 时
        /// 与就绪时各催一次，之后的核对由入窗回调与
        /// 状态/进度回调里的 refreshController 驱动
        private func attachPiPController() {
            pipBridge?.refreshController()
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
            // 小窗进行中退出播放页（修复轮 11）：内核
            // 不能停——小窗的帧源就是这个 layer。拆除
            // 延迟到小窗关闭，由 PlaybackKeepAlive 经
            // 小窗桥的 deferredTeardownHandler 回调
            // teardownNow；页面还在时小窗不会 active 到
            // 这里（恢复 UI 走 delegate completionHandler）
            if pipBridge?.isActive == true {
                DiaryStore.shared.add(
                    "软件内核小窗进行中退出播放页，内核拆除延迟到小窗关闭"
                )
                return
            }
            teardownNow()
        }

        func teardownNow() {
            FFmpegDiaryLogHandler.shared.endSession()
            pendingErrorWork?.cancel()
            // 小窗桥的小窗源随会话结束摘除（修复轮 12
            // 设立、轮 13 沿用）：桥可能被 PlaybackKeepAlive
            // 继续持有到小窗关闭，摘除后它的 start/stop
            // 只落在已自建的当前控制器上，不再探到新会话
            pipBridge?.sourceProvider = nil
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
            // 小窗源核对（修复轮 12 设立、轮 13 改自建）：
            // 内核换 displayLayer 时桥按新图层重建自家
            // 控制器，每次状态回调都核对一次；自动启动
            // 标志随之以本 App 设置为准刷新到桥的控制器
            pipBridge?.refreshController()
            pipBridge?.refreshAutoStart()
            // paused 不走通用状态行：要带触发来源（见下）
            if state != .paused {
                engine?.noteSoftwareState(state.description)
            }
            switch state {
            case .readyToPlay:
                reportTrackInfoIfNeeded(layer: layer)
                attachPiPController()
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
            // 进度回调约 10 次/秒：顺带核对小窗源
            // （修复轮 12 设立、轮 13 改自建）——格式
            // 描述变化引起的图层更换发生在两帧之间，
            // 不等状态回调也能及时按新图层重建控制器
            pipBridge?.refreshController()
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
            // 画面自然尺寸发布给引擎（修复轮 11）：播放页
            // 据此算软件内核的画面矩形锚定弹幕层
            engine?.noteSoftwarePresentationSize(player.naturalSize)
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
