import AVKit
import SwiftUI
import UIKit

/// AVPlayerViewController 的 SwiftUI 包装：
/// 用系统控制器 = 系统播放 UI + 系统画中画（PiP 由系统托管，不再自研帧拷贝）。
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

/// 播放会话：由调用方（详情页 / 文件浏览页）持有，把「当前播的
/// 是哪一集/哪个文件」的知识留在调用方，播放页只负责在进度
/// 回调、播完、点上下集时喊它。index 由 handler 自行维护，
/// canNext/canPrevious 供播放页渲染按钮（handler 更新后播放页
/// 靠 currentRequest 变化重渲染读取）。
final class PlaybackSession {
    var index: Int = 0
    var canNext: Bool = false
    var canPrevious: Bool = false
    var onProgress: ((PlaybackSession, Double, Double) -> Void)?
    var onNext: ((PlaybackSession) async -> PlaybackRequest?)?
    var onPrevious: ((PlaybackSession) async -> PlaybackRequest?)?
}

/// 播放页：进入即加载并自动播放，应用播放设置（默认静音、
/// 默认倍速、保持常亮、跳过片头/片尾——键义同 Flutter 版
/// PlaybackPreferences）。
/// 注意：关闭时才 pause——若在 PiP 进行中因页面消失就暂停，会把画中画一起掐断
/// （Flutter 版 PiP 不稳的一个典型坑，原生版从结构上避免）。
struct PlayerPage: View {
    let request: PlaybackRequest
    var session: PlaybackSession? = nil

    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var engine = PlaybackEngine()
    @Environment(\.dismiss) private var dismiss
    @State private var currentRequest: PlaybackRequest?
    @State private var switching = false

    private var activeRequest: PlaybackRequest { currentRequest ?? request }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            PlayerView(player: engine.player)
                .ignoresSafeArea()
            HStack {
                Button {
                    saveProgressNow()
                    engine.pause()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(10)
                }
                .buttonStyle(.glass)
                if let session, session.canPrevious {
                    Button {
                        Task { await switchEpisode(previous: true) }
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.headline)
                            .padding(10)
                    }
                    .buttonStyle(.glass)
                    .disabled(switching)
                }
                Spacer()
                Text(engine.statusText)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                if let session, session.canNext {
                    Button {
                        Task { await switchEpisode(previous: false) }
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.headline)
                            .padding(10)
                    }
                    .buttonStyle(.glass)
                    .disabled(switching)
                }
            }
            .padding()
        }
        .onAppear {
            PlaybackEngine.configureAudioSession()
            engine.playbackRate = Float(settings.speed)
            engine.outroThreshold = settings.autoAdvance
                ? Double(settings.skipOutroSeconds) : 0
            if settings.startMuted {
                engine.player.isMuted = true
            }
            if settings.keepScreenAwake {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            wireEngine()
            engine.load(effectiveRequest(request), autoplay: true)
        }
        .onDisappear {
            if settings.keepScreenAwake {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    /// 跳过片头：起始位置不足片头秒数时抬到片头结束处
    private func effectiveRequest(_ base: PlaybackRequest) -> PlaybackRequest {
        var result = base
        let intro = Double(settings.skipIntroSeconds)
        if intro > 0, result.startPosition < intro {
            result.startPosition = intro
        }
        return result
    }

    private func wireEngine() {
        if let session {
            engine.onProgress = { position, duration in
                session.onProgress?(session, position, duration)
            }
        }
        engine.onEnded = {
            guard settings.autoAdvance else { return }
            Task { await switchEpisode(previous: false) }
        }
        engine.onOutroReached = {
            guard settings.autoAdvance else { return }
            Task { await switchEpisode(previous: false) }
        }
    }

    private func saveProgressNow() {
        guard engine.duration > 0 || engine.currentTime > 0,
              let session else { return }
        session.onProgress?(session, engine.currentTime, engine.duration)
    }

    private func switchEpisode(previous: Bool) async {
        guard let session, !switching else { return }
        switching = true
        defer { switching = false }
        saveProgressNow()
        let next = previous
            ? await session.onPrevious?(session)
            : await session.onNext?(session)
        guard let next else { return }
        currentRequest = next
        engine.load(effectiveRequest(next), autoplay: true)
    }
}
