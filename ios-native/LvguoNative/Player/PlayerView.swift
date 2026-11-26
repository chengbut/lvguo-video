import AVKit
import SwiftUI

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

/// 播放页：进入即加载并自动播放。
/// 注意：关闭时才 pause——若在 PiP 进行中因页面消失就暂停，会把画中画一起掐断
/// （Flutter 版 PiP 不稳的一个典型坑，原生版从结构上避免）。
struct PlayerPage: View {
    let request: PlaybackRequest
    @StateObject private var engine = PlaybackEngine()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            PlayerView(player: engine.player)
                .ignoresSafeArea()
            HStack {
                Button {
                    engine.pause()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(10)
                }
                .buttonStyle(.glass)
                Spacer()
                Text(engine.statusText)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
            }
            .padding()
        }
        .onAppear {
            PlaybackEngine.configureAudioSession()
            engine.load(request, autoplay: true)
        }
    }
}
