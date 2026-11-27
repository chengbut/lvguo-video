import CFNetwork
import Foundation
import SwiftUI

// MARK: - 代理（线程安全快照）

/// 代理配置的线程安全快照：ResourceSettingsStore 每次保存时
/// 同步到这里，各网络层（模块 fetch / 播放资源代理 / 文件源 /
/// 下载）建 URLSession 时读它。generation 每次变更递增，
/// 长寿会话据此判断要不要重建——代理改完不用重启即生效。
enum ProxySettings {
    struct Effective {
        var mode: String = "auto"   // auto / direct / manual
        var url: String = ""
    }

    private static let lock = NSLock()
    private static var mode = "auto"
    private static var url = ""
    private static var perSource: [String: Effective] = [:]
    private static var generationValue = 0

    static var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    static func update(
        mode: String, url: String, perSource: [String: Effective]
    ) {
        lock.lock()
        self.mode = mode
        self.url = url
        self.perSource = perSource
        generationValue += 1
        lock.unlock()
    }

    /// 某模块的有效代理：有单独设置用单独的，否则全局。
    static func effective(forModule moduleId: String?) -> Effective {
        lock.lock()
        defer { lock.unlock() }
        if let moduleId, let override = perSource[moduleId] {
            return override
        }
        return Effective(mode: mode, url: url)
    }

    /// 把有效代理写进 URLSessionConfiguration。
    /// auto 不动 connectionProxyDictionary（跟随系统）；
    /// direct 写空字典（明确不走代理）；manual 按地址协议
    /// 写 HTTP/HTTPS 或 SOCKS 条目。地址无效时按 direct 处理，
    /// 不让坏地址把全部请求打挂。
    static func configure(
        _ configuration: URLSessionConfiguration, effective: Effective
    ) {
        switch effective.mode {
        case "direct":
            configuration.connectionProxyDictionary = [:]
        case "manual":
            configuration.connectionProxyDictionary =
                dictionary(from: effective.url) ?? [:]
        default:
            break
        }
    }

    static func dictionary(from urlString: String) -> [String: Any]? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty else { return nil }
        let scheme = (components.scheme ?? "http").lowercased()
        let port = components.port ?? (scheme == "https" ? 443 : 1080)
        if scheme == "socks5" || scheme == "socks" {
            return [
                "SOCKSEnable": true,
                "SOCKSProxy": host,
                "SOCKSPort": port,
            ]
        }
        return [
            "HTTPEnable": true,
            "HTTPProxy": host,
            "HTTPPort": port,
            "HTTPSEnable": true,
            "HTTPSProxy": host,
            "HTTPSPort": port,
        ]
    }

    /// 「自动」模式下给设置页看的系统代理状态（对齐 Flutter
    /// systemProxyStatus：读系统静态代理配置并摘要）。
    static func systemStatusText() -> String {
        guard let unmanaged = CFNetworkCopySystemProxySettings() else {
            return "使用系统静态代理；未配置时使用环境变量或直连"
        }
        let raw = unmanaged.takeRetainedValue() as NSDictionary
        func value(_ key: String) -> Any? { raw.object(forKey: key) }
        func endpoint(_ prefix: String) -> String? {
            let enabled = (value("\(prefix)Enable") as? NSNumber)?.intValue ?? 0
            guard enabled != 0,
                  let host = value("\(prefix)Proxy") as? String, !host.isEmpty
            else { return nil }
            let port = (value("\(prefix)Port") as? NSNumber)?.intValue ?? 0
            return port > 0 ? "\(host):\(port)" : host
        }
        let parts = ["HTTP", "HTTPS", "SOCKS"].compactMap(endpoint)
        if parts.isEmpty {
            return "使用系统静态代理；未配置时使用环境变量或直连"
        }
        return "系统代理：\(parts.joined(separator: " · "))"
    }
}

/// 下载网络策略快照（仅 Wi-Fi 下载）：ResourceSettingsStore
/// 保存时同步到这里，DownloadManager 与 FTP 通道读取。
enum DownloadPolicy {
    private static let lock = NSLock()
    private static var wifiOnly = false

    static var wifiOnlyDownloads: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wifiOnly
    }

    static func update(wifiOnly: Bool) {
        lock.lock()
        self.wifiOnly = wifiOnly
        lock.unlock()
    }
}

// MARK: - 旧版设置种子（只读）

/// 首次启动时从旧 Flutter 版 LocalStore 文件里读外观/下载
/// 偏好做种子（只读旧文件、只写新文件，与 Migration 同纪律）。
/// 原生自己的文件已存在时不调用。
enum LegacySettingsSeed {
    static func globalSettings() -> [String: Any]? {
        let storeRoot = AppData.legacySupportDirectory
            .appendingPathComponent("store")
        return readStoreFile(storeRoot.appendingPathComponent("settings.json"))
            as? [String: Any]
    }

    static func userSettings() -> [String: Any]? {
        let storeRoot = AppData.legacySupportDirectory
            .appendingPathComponent("store")
        var activeId = "default"
        if let users = readStoreFile(storeRoot.appendingPathComponent("users.json"))
            as? [String: Any],
           let active = users["active"] as? String, !active.isEmpty {
            activeId = active
        }
        return readStoreFile(
            storeRoot.appendingPathComponent("users")
                .appendingPathComponent(activeId)
                .appendingPathComponent("settings.json")
        ) as? [String: Any]
    }

    private static func readStoreFile(_ url: URL) -> Any? {
        if let value = AppData.readJSON(url) { return value }
        return AppData.readJSON(URL(fileURLWithPath: url.path + ".bak"))
    }
}

// MARK: - 外观

/// 主题色板：与 Flutter theme_color.dart 的 ThemeColor 逐项
/// 一致（name / label / 种子色）。原生用种子色作全局 tint
/// （SwiftUI 没有 Material 的整套配色生成，见 README 对齐表）。
enum ThemeColorOption: String, CaseIterable {
    case white
    case orange
    case rose
    case amber
    case teal
    case blue
    case violet

    var label: String {
        switch self {
        case .white: return "白色"
        case .orange: return "暖橙"
        case .rose: return "玫红"
        case .amber: return "琥珀"
        case .teal: return "青绿"
        case .blue: return "海蓝"
        case .violet: return "蓝紫"
        }
    }

    var seed: Color {
        switch self {
        case .white: return Color(red: 1, green: 1, blue: 1)
        case .orange: return Color(red: 1, green: 0.4, blue: 0.31)
        case .rose: return Color(red: 0.76, green: 0.33, blue: 0.52)
        case .amber: return Color(red: 0.7, green: 0.44, blue: 0)
        case .teal: return Color(red: 0, green: 0.61, blue: 0.52)
        case .blue: return Color(red: 0, green: 0.54, blue: 0.82)
        case .violet: return Color(red: 0.47, green: 0.44, blue: 0.84)
        }
    }
}

/// 外观设置：键名与 Flutter LocalStore 的全局设置一致
/// （themeMode / pureBlack / followSystemColor / themeColor /
/// displayMode / historyTab / blurCoversButton /
/// blurCoversLaunch / blurAllCovers），单独落盘 appearance.json。
@MainActor
final class AppearanceStore: ObservableObject {
    @Published var themeMode: String { didSet { save() } }
    @Published var pureBlack: Bool { didSet { save() } }
    @Published var followSystemColor: Bool { didSet { save() } }
    @Published var themeColorName: String { didSet { save() } }
    @Published var displayMode: String { didSet { save() } }
    @Published var historyTab: Bool { didSet { save() } }
    @Published var blurCoversButton: Bool { didSet { save() } }
    @Published var blurCoversLaunch: String { didSet { save() } }
    @Published var blurAllCovers: Bool { didSet { save() } }

    private let file: URL
    private var loading = true

    static let themeModes: [(String, String)] = [
        ("light", "浅色"), ("dark", "深色"), ("system", "跟随系统"),
    ]
    static let displayModes: [(String, String)] = [
        ("auto", "自动识别设备"), ("television", "电视"),
        ("phone", "手机"), ("pad", "平板"),
    ]
    static let blurLaunchModes: [(String, String)] = [
        ("off", "关闭"), ("adult", "仅限制级"), ("all", "全部"),
    ]

    init(dataDirectory: URL) {
        file = dataDirectory.appendingPathComponent("appearance.json")
        var dict = AppData.readJSONDictionary(file)
        if dict == nil {
            dict = LegacySettingsSeed.globalSettings()
        }
        let source = dict ?? [:]
        let mode = JSON.dictString(source["themeMode"])
        themeMode = Self.themeModes.contains { $0.0 == mode } ? mode : "system"
        pureBlack = JSON.dictBool(source["pureBlack"])
        followSystemColor = source["followSystemColor"] == nil
            ? true : JSON.dictBool(source["followSystemColor"])
        let colorName = JSON.dictString(source["themeColor"])
        themeColorName = ThemeColorOption(rawValue: colorName)?.rawValue
            ?? ThemeColorOption.orange.rawValue
        let display = JSON.dictString(source["displayMode"])
        displayMode = Self.displayModes.contains { $0.0 == display }
            ? display : "auto"
        historyTab = source["historyTab"] == nil
            ? true : JSON.dictBool(source["historyTab"])
        blurCoversButton = JSON.dictBool(source["blurCoversButton"])
        let launch = JSON.dictString(source["blurCoversLaunch"])
        if Self.blurLaunchModes.contains(where: { $0.0 == launch }) {
            blurCoversLaunch = launch
        } else if source["blurCoversLaunch"] == nil,
                  JSON.dictBool(source["blurCoversOnLaunch"]) {
            blurCoversLaunch = "all"
        } else {
            blurCoversLaunch = "off"
        }
        blurAllCovers = source["blurAllCovers"] == nil
            ? true : JSON.dictBool(source["blurAllCovers"])
        loading = false
        if AppData.readJSONDictionary(file) == nil, dict != nil {
            save()
        }
    }

    var themeColor: ThemeColorOption {
        ThemeColorOption(rawValue: themeColorName) ?? .orange
    }

    /// 主题模式 → SwiftUI 配色（system 时为 nil = 跟随系统）
    var colorScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func save() {
        guard !loading else { return }
        AppData.writeJSON([
            "themeMode": themeMode,
            "pureBlack": pureBlack,
            "followSystemColor": followSystemColor,
            "themeColor": themeColorName,
            "displayMode": displayMode,
            "historyTab": historyTab,
            "blurCoversButton": blurCoversButton,
            "blurCoversLaunch": blurCoversLaunch,
            "blurAllCovers": blurAllCovers,
        ], to: file)
    }
}

// MARK: - 封面模糊（会话状态）

/// 封面模糊的会话状态，对齐 Flutter CoverBlurScope：
/// 初始值 = 显示按钮时取「开屏自动模糊」模式，否则关闭；
/// 首页眼睛按钮在 关闭 ↔ 全部 之间切换。判定规则与
/// CoverBlurScope.blurs 一致：enabled && (explore || everywhere)
/// && (mode == all || (mode == adult && 该源为限制级))。
@MainActor
final class CoverBlurState: ObservableObject {
    @Published var mode: String

    init(appearance: AppearanceStore) {
        mode = appearance.blurCoversButton
            ? appearance.blurCoversLaunch : "off"
    }

    func toggle() {
        mode = mode == "off" ? "all" : "off"
    }

    func blurs(
        sourceIsAdult: Bool, explore: Bool, appearance: AppearanceStore
    ) -> Bool {
        guard appearance.blurCoversButton else { return false }
        guard explore || appearance.blurAllCovers else { return false }
        switch mode {
        case "all": return true
        case "adult": return sourceIsAdult
        default: return false
        }
    }
}

// MARK: - 资源设置（代理 + 下载行为）

struct SourceProxySetting {
    var mode: String = "follow"   // follow / auto / direct / manual
    var url: String = ""
}

/// 资源设置：字段与 Flutter ResourceSettings 对齐
/// （proxyMode / proxyUrl / downloadConcurrency /
/// downloadBySource / sourceProxies），落盘 resource-settings.json。
/// 额外两项是原生侧补充：wifiOnlyDownloads（用户点名要的
/// 「仅 Wi-Fi 下载」）与 downloadsLocation（iOS 存储页的
/// 下载位置选择：support 应用内部 / documents 文件 App 可见）。
@MainActor
final class ResourceSettingsStore: ObservableObject {
    @Published var proxyMode: String { didSet { save() } }
    @Published var proxyUrl: String { didSet { save() } }
    @Published var downloadConcurrency: Int { didSet { save() } }
    @Published var downloadBySource: Bool { didSet { save() } }
    @Published var wifiOnlyDownloads: Bool { didSet { save() } }
    @Published var downloadsLocation: String { didSet { save() } }
    /// 自定义下载文件夹（修复轮 11 第 9 项）：security-scoped
    /// 书签（base64）与显示名；downloadsLocation == "custom"
    /// 时生效，解析失败回落 support 并在存储页/日记提示
    @Published var downloadsFolderBookmark: String { didSet { save() } }
    @Published var downloadsFolderName: String { didSet { save() } }
    @Published var sourceProxies: [String: SourceProxySetting] {
        didSet { save() }
    }

    private let file: URL
    private var loading = true

    init(dataDirectory: URL) {
        file = dataDirectory.appendingPathComponent("resource-settings.json")
        let dict = AppData.readJSONDictionary(file) ?? [:]
        let mode = JSON.dictString(dict["proxyMode"])
        proxyMode = ["auto", "direct", "manual"].contains(mode) ? mode : "auto"
        proxyUrl = JSON.dictString(dict["proxyUrl"])
        let concurrency = JSON.dictInt(dict["downloadConcurrency"])
        downloadConcurrency = (1...6).contains(concurrency) ? concurrency : 2
        downloadBySource = JSON.dictBool(dict["downloadBySource"])
        wifiOnlyDownloads = JSON.dictBool(dict["wifiOnlyDownloads"])
        let location = JSON.dictString(dict["downloadsLocation"])
        downloadsLocation = ["documents", "custom"].contains(location)
            ? location : "support"
        downloadsFolderBookmark = JSON.dictString(dict["downloadsFolderBookmark"])
        downloadsFolderName = JSON.dictString(dict["downloadsFolderName"])
        var proxies: [String: SourceProxySetting] = [:]
        if let raw = dict["sourceProxies"] as? [String: Any] {
            for (key, value) in raw {
                guard let entry = value as? [String: Any] else { continue }
                var setting = SourceProxySetting()
                let entryMode = JSON.dictString(entry["mode"])
                setting.mode = ["follow", "auto", "direct", "manual"]
                    .contains(entryMode) ? entryMode : "follow"
                setting.url = JSON.dictString(entry["url"])
                if setting.mode != "follow" {
                    proxies[key] = setting
                }
            }
        }
        sourceProxies = proxies
        loading = false
        syncProxySnapshot()
    }

    /// 下载目录的根（不含 downloads 子目录名）：位置选择决定
    /// 下载内容放在 App 支持目录还是文档目录。
    static func downloadsBaseDirectory(
        dataDirectory: URL, location: String
    ) -> URL {
        if location == "documents" {
            let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first ?? dataDirectory
            return documents.appendingPathComponent("LvguoNative")
        }
        return dataDirectory
    }

    /// 自定义下载文件夹的书签解析（修复轮 11 第 9 项）：
    /// 成功返回文件夹 URL 与书签是否已过期（过期时地址
    /// 仍可用，但建议用户重新选择以刷新书签）；解析
    /// 失败返回 nil，调用方回落默认位置并如实提示
    static func resolveDownloadsFolder(
        bookmarkBase64: String
    ) -> (url: URL, stale: Bool)? {
        guard let data = Data(base64Encoded: bookmarkBase64),
              !data.isEmpty else {
            return nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        return (url, stale)
    }

    /// 由文件夹 URL 现做书签（存储页选完文件夹时调用，
    /// 调用方须正持有该 URL 的 security-scoped 访问）
    static func makeDownloadsFolderBookmark(_ url: URL) -> String? {
        (try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        ))?.base64EncodedString()
    }

    private func save() {
        guard !loading else { return }
        var proxies: [String: Any] = [:]
        for (key, setting) in sourceProxies where setting.mode != "follow" {
            var entry: [String: Any] = ["mode": setting.mode]
            if setting.mode == "manual" {
                entry["url"] = setting.url
            }
            proxies[key] = entry
        }
        AppData.writeJSON([
            "proxyMode": proxyMode,
            "proxyUrl": proxyUrl,
            "downloadConcurrency": downloadConcurrency,
            "downloadBySource": downloadBySource,
            "wifiOnlyDownloads": wifiOnlyDownloads,
            "downloadsLocation": downloadsLocation,
            "downloadsFolderBookmark": downloadsFolderBookmark,
            "downloadsFolderName": downloadsFolderName,
            "sourceProxies": proxies,
        ], to: file)
        syncProxySnapshot()
    }

    private func syncProxySnapshot() {
        var perSource: [String: ProxySettings.Effective] = [:]
        for (key, setting) in sourceProxies where setting.mode != "follow" {
            perSource[key] = ProxySettings.Effective(
                mode: setting.mode, url: setting.url
            )
        }
        ProxySettings.update(
            mode: proxyMode, url: proxyUrl, perSource: perSource
        )
        DownloadPolicy.update(wifiOnly: wifiOnlyDownloads)
    }
}

// MARK: - 下载偏好

/// 下载偏好：与 Flutter DownloadPreferences 一致
/// （quality ∈ {0,1080,720,480}，includeVip），落盘
/// download-preferences.json，首次从旧版用户设置种子。
@MainActor
final class DownloadPreferencesStore: ObservableObject {
    @Published var quality: Int { didSet { save() } }
    @Published var includeVip: Bool { didSet { save() } }

    private let file: URL
    private var loading = true

    static let qualities = [0, 1080, 720, 480]

    init(dataDirectory: URL) {
        file = dataDirectory.appendingPathComponent(
            "download-preferences.json"
        )
        var dict = AppData.readJSONDictionary(file)
        if dict == nil,
           let user = LegacySettingsSeed.userSettings(),
           let seeded = user["downloadPreferences"] as? [String: Any] {
            dict = seeded
        }
        let source = dict ?? [:]
        let storedQuality = JSON.dictInt(source["quality"])
        quality = Self.qualities.contains(storedQuality) ? storedQuality : 0
        includeVip = JSON.dictBool(source["includeVip"])
        loading = false
        if AppData.readJSONDictionary(file) == nil, dict != nil {
            save()
        }
    }

    var qualityLabel: String {
        quality == 0 ? "自动 · 优先高清" : "\(quality)P"
    }

    private func save() {
        guard !loading else { return }
        AppData.writeJSON([
            "quality": quality,
            "includeVip": includeVip,
        ], to: file)
    }
}
