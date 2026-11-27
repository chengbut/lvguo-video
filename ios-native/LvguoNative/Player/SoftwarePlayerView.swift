import KSPlayer
import SwiftUI
import UIKit

/// 软件内核（KSPlayer 的 FFmpeg 内核 KSMEPlayer）的
/// 播放表面：只负责出画面与把引擎的控制指令转给内核，
/// 控件层仍是播放页原有的那一套（引擎转发 play/pause/
/// seek/倍速，进度与状态由内核回调写回引擎）。
/// 凭据头经 KSOptions.appendHeader 传给 FFmpeg
/// （formatContext 的 headers 选项），与系统内核的
/// 资源代理是两条独立的带头路径。
///
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
        /// state .error 先于 finish(error) 到达（KSPlayerLayer
        /// 先置 state 再发 finish）：先到的 .error 不抢报，
        /// 留 0.5 秒等带真错误的 finish，超时才报笼统文案
        private var pendingErrorWork: DispatchWorkItem?
        private var windowAttachLogged = false

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
                pendingErrorWork?.cancel()
                layer.set(
                    url: url,
                    options: SoftwarePlayerSurface.makeOptions(for: request)
                )
                container?.host(layer.player.view)
            }
        }

        func teardown() {
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
            engine?.noteSoftwareState(state.description)
            switch state {
            case .readyToPlay:
                engine?.noteSoftwareReady()
            case .buffering:
                engine?.noteSoftwareBuffering(true)
            case .bufferFinished, .paused:
                engine?.noteSoftwareBuffering(false)
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

        // MARK: SoftwareKernelControlling

        func kernelPlay() {
            layer?.player.play()
        }

        func kernelPause() {
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
