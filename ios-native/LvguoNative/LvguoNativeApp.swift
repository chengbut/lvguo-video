import SwiftUI

@main
struct LvguoNativeApp: App {
    /// 模块存储全 App 共享：资源页管理、首页/详情消费同一个当前模块
    @StateObject private var moduleStore = ModuleStore()

    init() {
        // 播放 / 画中画依赖 .playback 音频会话，尽早配置
        PlaybackEngine.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(moduleStore)
        }
    }
}
