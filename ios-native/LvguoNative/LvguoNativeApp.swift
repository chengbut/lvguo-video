import SwiftUI

@main
struct LvguoNativeApp: App {
    init() {
        // 播放 / 画中画依赖 .playback 音频会话，尽早配置
        PlaybackEngine.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
