import SwiftUI

@main
struct LvguoNativeApp: App {
    /// 全 App 共享的存储：资源页管理、首页/详情/历史/下载消费同一份
    @StateObject private var moduleStore: ModuleStore
    @StateObject private var fileStore: FileSourceStore
    @StateObject private var historyStore: HistoryStore
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var downloadManager: DownloadManager

    init() {
        // 播放 / 画中画依赖 .playback 音频会话，尽早配置
        PlaybackEngine.configureAudioSession()
        // 首次启动数据迁移必须赶在任何 Store 读盘之前：
        // 把旧 Flutter 版容器里的数据（模块/历史/设置/文件源）
        // 合并进原生存储，只读旧数据、失败不毁数据。
        let dataDirectory = AppData.directory
        Migration.runIfNeeded(dataDirectory: dataDirectory)
        let modules = ModuleStore()
        let files = FileSourceStore(dataDirectory: dataDirectory)
        let downloads = DownloadManager(dataDirectory: dataDirectory)
        downloads.installResolvers(moduleStore: modules, fileStore: files)
        _moduleStore = StateObject(wrappedValue: modules)
        _fileStore = StateObject(wrappedValue: files)
        _historyStore = StateObject(wrappedValue: HistoryStore(dataDirectory: dataDirectory))
        _settingsStore = StateObject(wrappedValue: SettingsStore(dataDirectory: dataDirectory))
        _downloadManager = StateObject(wrappedValue: downloads)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(moduleStore)
                .environmentObject(fileStore)
                .environmentObject(historyStore)
                .environmentObject(settingsStore)
                .environmentObject(downloadManager)
        }
    }
}
