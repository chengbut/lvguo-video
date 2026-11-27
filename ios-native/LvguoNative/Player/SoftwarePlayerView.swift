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

        func attach(
            container: SoftwarePlayerContainerView, request: PlaybackRequest,
            engine: PlaybackEngine, fit: VideoFitMode, muted: Bool
        ) {
            self.container = container
            self.engine = engine
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
                layer.set(
                    url: url,
                    options: SoftwarePlayerSurface.makeOptions(for: request)
                )
                container?.host(layer.player.view)
            }
        }

        func teardown() {
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
                reportFailure("软件内核打开失败")
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
        }

        @MainActor
        func player(layer: KSPlayerLayer, finish error: Error?) {
            if let error {
                reportFailure(error.localizedDescription)
            }
        }

        @MainActor
        func player(
            layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval
        ) {}

        /// 状态 error 与 finish(error) 可能先后各报一次：
        /// 引擎侧以 activeKernel 守门，这里再去重一层
        private func reportFailure(_ message: String) {
            guard !finished else { return }
            finished = true
            engine?.softwareKernelFailed(message)
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
    }
}

/// 承载内核渲染视图的容器：内核内部换播放器实例时
/// 渲染视图会变，host 负责把新的视图重新铺满
final class SoftwarePlayerContainerView: UIView {
    private weak var hostedView: UIView?

    func host(_ view: UIView?) {
        if hostedView === view { return }
        hostedView?.removeFromSuperview()
        hostedView = view
        guard let view else { return }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedView?.frame = bounds
    }
}
