import SwiftUI

@main
struct LvguoNativeApp: App {
    /// 全 App 共享的存储：资源页管理、首页/详情/历史/下载消费同一份
    @StateObject private var moduleStore: ModuleStore
    @StateObject private var fileStore: FileSourceStore
    @StateObject private var historyStore: HistoryStore
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var downloadManager: DownloadManager
    @StateObject private var appearanceStore: AppearanceStore
    @StateObject private var resourceSettingsStore: ResourceSettingsStore
    @StateObject private var downloadPreferencesStore: DownloadPreferencesStore
    @StateObject private var danmakuPreferencesStore: DanmakuPreferencesStore
    @StateObject private var coverBlurState: CoverBlurState

    init() {
        // 播放 / 画中画依赖 .playback 音频会话，尽早配置
        PlaybackEngine.configureAudioSession()
        // 首次启动数据迁移必须赶在任何 Store 读盘之前：
        // 把旧 Flutter 版容器里的数据（模块/历史/设置/文件源）
        // 合并进原生存储，只读旧数据、失败不毁数据。
        let dataDirectory = AppData.directory
        Migration.runIfNeeded(dataDirectory: dataDirectory)
        DiaryStore.shared.add("应用启动")
        if let report = Migration.lastReport {
            DiaryStore.shared.add("旧版数据迁移：\(report.summary)")
        }
        let appearance = AppearanceStore(dataDirectory: dataDirectory)
        // 资源设置先于下载管理器建：它的 init 会把代理/下载
        // 策略同步进线程安全快照，各网络层建会话时读
        let resources = ResourceSettingsStore(dataDirectory: dataDirectory)
        let downloadPrefs = DownloadPreferencesStore(
            dataDirectory: dataDirectory
        )
        let modules = ModuleStore()
        let files = FileSourceStore(dataDirectory: dataDirectory)
        let downloads = DownloadManager(dataDirectory: dataDirectory)
        downloads.installResolvers(moduleStore: modules, fileStore: files)
        downloads.installSettings(
            resourceSettings: resources, downloadPreferences: downloadPrefs
        )
        downloads.settingsChanged()
        _moduleStore = StateObject(wrappedValue: modules)
        _fileStore = StateObject(wrappedValue: files)
        _historyStore = StateObject(wrappedValue: HistoryStore(dataDirectory: dataDirectory))
        _settingsStore = StateObject(wrappedValue: SettingsStore(dataDirectory: dataDirectory))
        _downloadManager = StateObject(wrappedValue: downloads)
        _appearanceStore = StateObject(wrappedValue: appearance)
        _resourceSettingsStore = StateObject(wrappedValue: resources)
        _downloadPreferencesStore = StateObject(wrappedValue: downloadPrefs)
        _danmakuPreferencesStore = StateObject(
            wrappedValue: DanmakuPreferencesStore(dataDirectory: dataDirectory)
        )
        _coverBlurState = StateObject(
            wrappedValue: CoverBlurState(appearance: appearance)
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(moduleStore)
                .environmentObject(fileStore)
                .environmentObject(historyStore)
                .environmentObject(settingsStore)
                .environmentObject(downloadManager)
                .environmentObject(appearanceStore)
                .environmentObject(resourceSettingsStore)
                .environmentObject(downloadPreferencesStore)
                .environmentObject(danmakuPreferencesStore)
                .environmentObject(coverBlurState)
        }
    }
}
