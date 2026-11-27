import SwiftUI
import UniformTypeIdentifiers

// MARK: - 玻璃设置页通用件

/// 设置分组页外壳：液态玻璃分组卡 + 主题种子色微渐变底，
/// 与 Flutter 版 GroupCard 的观感对位（用户定：能用原生
/// 液态玻璃的地方要用）。功能、条目、布局结构与原版一致。
struct SettingsGroupPage<Content: View>: View {
    let title: String
    @EnvironmentObject private var appearance: AppearanceStore
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
        }
        .background(
            LinearGradient(
                colors: [
                    appearance.themeColor.seed.opacity(0.10),
                    Color(.systemBackground),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 玻璃分组卡（对齐 Flutter GroupCard / LiquidGlass）
struct GlassSettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

struct SwitchSettingsRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
    }
}

struct MenuSettingsRow: View {
    let title: String
    var subtitle: String? = nil
    let options: [(String, String)]
    @Binding var selection: String
    var disabled: Bool = false
    /// 拦截选择（如选「手动代理」要先开编辑器）：返回 true 表示已处理
    var onSelect: ((String) -> Bool)? = nil

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                ForEach(options, id: \.0) { option in
                    Button(option.1) {
                        if onSelect?(option.0) == true { return }
                        selection = option.0
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentLabel)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .disabled(disabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .opacity(disabled ? 0.45 : 1)
    }

    private var currentLabel: String {
        options.first { $0.0 == selection }?.1 ?? ""
    }
}

struct ValueSettingsRow: View {
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var destructive: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(destructive ? .red : .primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

struct SettingsNote: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .padding(.horizontal, 16)
    }
}

/// 字节数格式，与 Flutter storageSize 一致
func storageSizeText(_ bytes: Int64) -> String {
    if bytes < 0 { return "暂不可用" }
    if bytes < 1 << 20 {
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }
    if bytes < 1 << 30 {
        return String(format: "%.1f MB", Double(bytes) / Double(1 << 20))
    }
    return String(format: "%.2f GB", Double(bytes) / Double(1 << 30))
}

// MARK: - 外观

struct AppearanceSettingsView: View {
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        SettingsGroupPage(title: "外观") {
            GlassSettingsCard {
                MenuSettingsRow(
                    title: "主题模式",
                    subtitle: AppearanceStore.themeModes
                        .first { $0.0 == appearance.themeMode }?.1,
                    options: AppearanceStore.themeModes,
                    selection: $appearance.themeMode
                )
                SettingsRowDivider()
                SwitchSettingsRow(
                    title: "纯黑深色模式",
                    subtitle: "深色时背景改为纯黑，适合 OLED 屏幕",
                    isOn: $appearance.pureBlack
                )
                SettingsRowDivider()
                // iOS 没有系统取色 API（Flutter 在 iOS 上同样
                // systemColorAvailable=false）：开关禁用，
                // 副标题用 Flutter 的原版文案
                SwitchSettingsRow(
                    title: "跟随系统取色",
                    subtitle: "本机不支持系统取色，使用预设色板",
                    isOn: .constant(false),
                    disabled: true
                )
                SettingsRowDivider()
                swatches
            }
            GlassSettingsCard {
                SwitchSettingsRow(
                    title: "在主页底栏显示历史",
                    subtitle: "关闭后仍可在「我的」里打开观看记录",
                    isOn: $appearance.historyTab
                )
                SettingsRowDivider()
                SwitchSettingsRow(
                    title: "在主页显示模糊封面按钮",
                    subtitle: "首页站源按钮左边显示眼睛按钮，点一下模糊封面，再点恢复",
                    isOn: $appearance.blurCoversButton
                )
                SettingsRowDivider()
                SwitchSettingsRow(
                    title: "模糊所有界面的封面",
                    subtitle: appearance.blurCoversButton
                        ? "关闭后只模糊首页的封面"
                        : "需先打开在主页显示模糊封面按钮",
                    isOn: Binding(
                        get: { appearance.blurCoversButton
                            && appearance.blurAllCovers },
                        set: { appearance.blurAllCovers = $0 }
                    ),
                    disabled: !appearance.blurCoversButton
                )
                SettingsRowDivider()
                MenuSettingsRow(
                    title: "开屏自动模糊封面",
                    subtitle: appearance.blurCoversButton
                        ? nil : "需先打开在主页显示模糊封面按钮",
                    options: AppearanceStore.blurLaunchModes,
                    selection: $appearance.blurCoversLaunch,
                    disabled: !appearance.blurCoversButton
                )
            }
            GlassSettingsCard {
                MenuSettingsRow(
                    title: "界面模式",
                    options: AppearanceStore.displayModes,
                    selection: $appearance.displayMode
                )
            }
        }
    }

    private var swatches: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("预设色板")
                Text("选一个种子色生成整套配色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible()), count: 4
                ),
                spacing: 12
            ) {
                ForEach(ThemeColorOption.allCases, id: \.rawValue) { option in
                    Button {
                        appearance.themeColorName = option.rawValue
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(
                                        option == .white
                                            ? Color.white : option.seed
                                    )
                                    .frame(width: 50, height: 50)
                                    .overlay(
                                        Circle().stroke(
                                            .secondary.opacity(
                                                option == .white ? 0.5 : 0
                                            ),
                                            lineWidth: 1
                                        )
                                    )
                                    .overlay(
                                        Circle().stroke(
                                            appearance.themeColorName
                                                == option.rawValue
                                                ? Color.primary : .clear,
                                            lineWidth: 2
                                        )
                                        .padding(-3)
                                    )
                                if appearance.themeColorName
                                    == option.rawValue {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(
                                            option == .white ? .black : .white
                                        )
                                        .font(.body.weight(.bold))
                                }
                            }
                            Text(option.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 弹幕

struct DanmakuSettingsView: View {
    @EnvironmentObject private var danmaku: DanmakuPreferencesStore

    var body: some View {
        SettingsGroupPage(title: "弹幕") {
            GlassSettingsCard {
                SwitchSettingsRow(
                    title: "显示弹幕",
                    subtitle: "与播放页的弹幕开关同步",
                    isOn: $danmaku.enabled
                )
            }
            GlassSettingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    DanmakuSettingsForm()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - 下载

struct DownloadSettingsView: View {
    @EnvironmentObject private var downloadPreferences:
        DownloadPreferencesStore
    @EnvironmentObject private var resourceSettings: ResourceSettingsStore
    @EnvironmentObject private var downloadManager: DownloadManager

    var body: some View {
        SettingsGroupPage(title: "下载") {
            GlassSettingsCard {
                MenuSettingsRow(
                    title: "默认画质",
                    subtitle: "指定画质不可用时，使用源站可用画质",
                    options: DownloadPreferencesStore.qualities
                        .map {
                            (String($0), $0 == 0 ? "自动（优先高清）" : "\($0)P")
                        },
                    selection: Binding(
                        get: { String(downloadPreferences.quality) },
                        set: { downloadPreferences.quality = Int($0) ?? 0 }
                    )
                )
                SettingsRowDivider()
                SwitchSettingsRow(
                    title: "默认包含 VIP 集",
                    subtitle: "VIP 集可能仅提供试看内容，下载前仍可调整选择",
                    isOn: $downloadPreferences.includeVip
                )
            }
            GlassSettingsCard {
                MenuSettingsRow(
                    title: "同时下载数量",
                    options: (1...6).map { ("\($0)", "\($0)") },
                    selection: Binding(
                        get: { String(resourceSettings.downloadConcurrency) },
                        set: {
                            resourceSettings.downloadConcurrency
                                = Int($0) ?? 2
                        }
                    )
                )
                SettingsRowDivider()
                SwitchSettingsRow(
                    title: "按站源分类保存",
                    subtitle: "新任务放入各站源的子目录，已有下载继续使用原位置",
                    isOn: $resourceSettings.downloadBySource
                )
                SettingsRowDivider()
                SwitchSettingsRow(
                    title: "仅 Wi-Fi 下载",
                    subtitle: "蜂窝网络下不启动新下载，单个请求也不走蜂窝",
                    isOn: $resourceSettings.wifiOnlyDownloads
                )
            }
            SettingsNote(
                text: "iOS 下载和媒体处理需要保持应用在前台；切到后台会暂停，回到前台后可继续。"
            )
        }
        .onChange(of: resourceSettings.downloadConcurrency) { _, _ in
            downloadManager.settingsChanged()
        }
        .onChange(of: resourceSettings.wifiOnlyDownloads) { _, _ in
            downloadManager.settingsChanged()
        }
    }
}

// MARK: - 存储

struct StorageUsage {
    var downloadsBytes: Int64 = 0
    var modulesBytes: Int64 = 0
    var cacheBytes: Int64 = 0
    var otherBytes: Int64 = 0
    var downloadFiles: Int = 0
    var freeBytes: Int64 = -1

    var totalBytes: Int64 {
        downloadsBytes + modulesBytes + cacheBytes + otherBytes
    }
}

enum StorageService {
    static func directorySize(_ url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    static func fileCount(_ url: URL) -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return 0 }
        var count = 0
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey]
            ))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    static var cachesDirectory: URL {
        FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
    }

    static func measure(
        dataDirectory: URL, downloadsDirectory: URL
    ) -> StorageUsage {
        var usage = StorageUsage()
        usage.downloadsBytes = directorySize(downloadsDirectory)
        usage.downloadFiles = fileCount(downloadsDirectory)
        let modules = directorySize(
            dataDirectory.appendingPathComponent("modules")
        ) + directorySize(
            dataDirectory.appendingPathComponent("module-state")
        )
        usage.modulesBytes = modules
        usage.cacheBytes = directorySize(cachesDirectory)
        let dataTotal = directorySize(dataDirectory)
        let downloadsInside = downloadsDirectory.path
            .hasPrefix(dataDirectory.path)
        let accounted = modules + (downloadsInside ? usage.downloadsBytes : 0)
        usage.otherBytes = max(0, dataTotal - accounted)
        if let values = try? dataDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityKey]
        ), let capacity = values.volumeAvailableCapacity {
            usage.freeBytes = Int64(capacity)
        }
        return usage
    }

    /// 清理缓存：URLCache（封面/目录/榜单的网络缓存）整清
    static func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(
            atPath: cachesDirectory.path
        )) ?? [] {
            try? fileManager.removeItem(
                at: cachesDirectory.appendingPathComponent(name)
            )
        }
    }

    /// 删除全部数据：清空数据目录与下载目录内容（目录本身保留）
    static func deleteAllData(dataDirectory: URL, downloadsBase: URL) {
        let fileManager = FileManager.default
        var roots = [dataDirectory]
        if downloadsBase.standardizedFileURL
            != dataDirectory.standardizedFileURL {
            roots.append(downloadsBase)
        }
        for root in roots {
            for name in (try? fileManager.contentsOfDirectory(
                atPath: root.path
            )) ?? [] {
                try? fileManager.removeItem(
                    at: root.appendingPathComponent(name)
                )
            }
        }
        clearCache()
    }
}

struct StorageSettingsView: View {
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var resourceSettings: ResourceSettingsStore

    @State private var usage: StorageUsage?
    @State private var cacheBytes: Int64?
    @State private var pendingLocation: String?
    @State private var confirmDeleteAll = false
    @State private var notice: String?
    @State private var errorText: String?

    private var dataDirectory: URL { AppData.directory }

    var body: some View {
        SettingsGroupPage(title: "存储") {
            GlassSettingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已使用 \(storageSizeText(usage?.totalBytes ?? 0))")
                        .font(.title3.weight(.semibold))
                    Text(
                        "剩余 \(storageSizeText(usage?.freeBytes ?? -1)) · "
                            + "\(usage?.downloadFiles ?? 0) 个下载文件"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                SettingsRowDivider()
                usageRow("下载", usage?.downloadsBytes)
                SettingsRowDivider()
                usageRow("模块", usage?.modulesBytes)
                SettingsRowDivider()
                usageRow("缓存", usage?.cacheBytes)
                SettingsRowDivider()
                usageRow("其他数据", usage?.otherBytes)
                SettingsRowDivider()
                ValueSettingsRow(
                    title: "当前下载目录",
                    subtitle: downloadManager.downloadsDirectory.path,
                    action: {
                        UIPasteboard.general.string =
                            downloadManager.downloadsDirectory.path
                        notice = "路径已复制"
                    }
                )
                SettingsRowDivider()
                MenuSettingsRow(
                    title: "下载位置",
                    subtitle: "更改后迁移已下载内容，下载会先暂停",
                    options: [
                        ("support", "应用内部存储"),
                        ("documents", "文件 App 可见目录"),
                    ],
                    selection: Binding(
                        get: { resourceSettings.downloadsLocation },
                        set: { _ in }
                    ),
                    onSelect: { value in
                        if value != resourceSettings.downloadsLocation {
                            pendingLocation = value
                        }
                        return true
                    }
                )
                SettingsRowDivider()
                ValueSettingsRow(title: "刷新用量") {
                    Task { await measure() }
                }
            }
            GlassSettingsCard {
                ValueSettingsRow(
                    title: "清理缓存",
                    subtitle: [
                        cacheBytes.map { "已用 \(storageSizeText($0))" },
                        "海报、目录和榜单会重新加载",
                    ].compactMap { $0 }.joined(separator: " · "),
                    action: {
                        StorageService.clearCache()
                        notice = "缓存已清理"
                        Task { await measure() }
                    }
                )
                SettingsRowDivider()
                ValueSettingsRow(
                    title: "删除全部数据",
                    subtitle: "删除用户、记录、设置、站源模块、缓存和已下载的视频，完成后退出应用",
                    destructive: true,
                    action: { confirmDeleteAll = true }
                )
            }
            if let errorText {
                SettingsNote(text: errorText, color: .red)
            }
            if let notice {
                SettingsNote(text: notice)
            }
        }
        .task { await measure() }
        .alert(
            "迁移已下载内容？",
            isPresented: Binding(
                get: { pendingLocation != nil },
                set: { if !$0 { pendingLocation = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingLocation = nil }
            Button("迁移") {
                if let target = pendingLocation {
                    relocate(to: target)
                }
                pendingLocation = nil
            }
        } message: {
            Text(
                "将下载目录里的全部内容迁移到"
                    + (pendingLocation == "documents"
                        ? "文件 App 可见目录" : "应用内部存储")
                    + "。下载会先暂停，复制成功后清理旧目录。请保证目标有足够空间。"
            )
        }
        .alert("删除全部数据？", isPresented: $confirmDeleteAll) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                StorageService.deleteAllData(
                    dataDirectory: dataDirectory,
                    downloadsBase: downloadManager.downloadsDirectory
                        .deletingLastPathComponent()
                )
                notice = "数据已删除，请从后台划掉应用后重新打开。"
                Task { await measure() }
            }
        } message: {
            Text(
                "将删除所有用户、追剧、观看记录、设置、已安装模块、缓存和已下载的视频，无法恢复。已导出到相册的视频保留。"
            )
        }
    }

    private func usageRow(_ title: String, _ bytes: Int64?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(bytes.map(storageSizeText) ?? "…")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func measure() async {
        let data = dataDirectory
        let downloads = downloadManager.downloadsDirectory
        let result = await Task.detached {
            StorageService.measure(
                dataDirectory: data, downloadsDirectory: downloads
            )
        }.value
        usage = result
        cacheBytes = result.cacheBytes
    }

    private func relocate(to location: String) {
        let base = ResourceSettingsStore.downloadsBaseDirectory(
            dataDirectory: dataDirectory, location: location
        )
        do {
            try downloadManager.relocateDownloads(toBase: base)
            resourceSettings.downloadsLocation = location
            notice = "已迁移到"
                + (location == "documents" ? "文件 App 可见目录" : "应用内部存储")
            Task { await measure() }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 代理

private struct ProxyEditorTarget: Identifiable {
    var moduleId: String?     // nil = 全局
    var name: String
    var initial: String
    var id: String { moduleId ?? "__global__" }
}

struct ProxySettingsView: View {
    @EnvironmentObject private var resourceSettings: ResourceSettingsStore
    @EnvironmentObject private var moduleStore: ModuleStore

    @State private var editorTarget: ProxyEditorTarget?
    @State private var systemStatus = ""

    private static let modes: [(String, String)] = [
        ("auto", "自动"), ("direct", "直连"), ("manual", "手动代理"),
    ]
    private static let sourceModes: [(String, String)] = [
        ("follow", "跟随全局"), ("auto", "自动"),
        ("direct", "直连"), ("manual", "手动代理"),
    ]

    var body: some View {
        SettingsGroupPage(title: "代理") {
            if resourceSettings.proxyMode == "manual",
               !resourceSettings.proxyUrl.isEmpty,
               ProxySettings.dictionary(from: resourceSettings.proxyUrl)
                   == nil {
                SettingsNote(
                    text: "代理地址格式无效，当前按直连处理",
                    color: .red
                )
            }
            GlassSettingsCard {
                MenuSettingsRow(
                    title: "连接方式",
                    subtitle: resourceSettings.proxyMode == "auto"
                        ? systemStatus : nil,
                    options: Self.modes,
                    selection: $resourceSettings.proxyMode,
                    onSelect: { value in
                        if value == "manual" {
                            editorTarget = ProxyEditorTarget(
                                moduleId: nil, name: "全局",
                                initial: resourceSettings.proxyUrl
                            )
                            return true
                        }
                        return false
                    }
                )
                if resourceSettings.proxyMode == "manual" {
                    SettingsRowDivider()
                    ValueSettingsRow(
                        title: "代理地址",
                        subtitle: "支持 HTTP、HTTPS、SOCKS5",
                        value: resourceSettings.proxyUrl.isEmpty
                            ? "未设置" : "已设置",
                        action: {
                            editorTarget = ProxyEditorTarget(
                                moduleId: nil, name: "全局",
                                initial: resourceSettings.proxyUrl
                            )
                        }
                    )
                }
            }
            if !moduleStore.modules.filter(\.isUsable).isEmpty {
                SettingsNote(
                    text: "站源单独设置后，该站源的请求、播放与下载优先使用这里的方式"
                )
                GlassSettingsCard {
                    ForEach(
                        Array(
                            moduleStore.modules.filter(\.isUsable)
                                .enumerated()
                        ),
                        id: \.element.id
                    ) { index, module in
                        if index > 0 { SettingsRowDivider() }
                        MenuSettingsRow(
                            title: module.name,
                            options: Self.sourceModes,
                            selection: Binding(
                                get: {
                                    resourceSettings
                                        .sourceProxies[module.id]?.mode
                                        ?? "follow"
                                },
                                set: { _ in }
                            ),
                            onSelect: { value in
                                selectSourceMode(value, for: module)
                                return true
                            }
                        )
                        if resourceSettings.sourceProxies[module.id]?.mode
                            == "manual" {
                            ValueSettingsRow(
                                title: "\(module.name) · 代理地址",
                                value: "已设置",
                                action: {
                                    editorTarget = ProxyEditorTarget(
                                        moduleId: module.id,
                                        name: module.name,
                                        initial: resourceSettings
                                            .sourceProxies[module.id]?.url
                                            ?? ""
                                    )
                                }
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            systemStatus = ProxySettings.systemStatusText()
        }
        .sheet(item: $editorTarget) { target in
            ProxyAddressEditor(target: target) { address in
                saveProxyAddress(address, for: target)
            }
        }
    }

    private func selectSourceMode(_ mode: String, for module: InstalledModule) {
        switch mode {
        case "follow":
            resourceSettings.sourceProxies[module.id] = nil
        case "manual":
            editorTarget = ProxyEditorTarget(
                moduleId: module.id, name: module.name,
                initial: resourceSettings.sourceProxies[module.id]?.url ?? ""
            )
        default:
            resourceSettings.sourceProxies[module.id] =
                SourceProxySetting(mode: mode)
        }
    }

    private func saveProxyAddress(
        _ address: String, for target: ProxyEditorTarget
    ) {
        if let moduleId = target.moduleId {
            resourceSettings.sourceProxies[moduleId] =
                SourceProxySetting(mode: "manual", url: address)
        } else {
            resourceSettings.proxyMode = "manual"
            resourceSettings.proxyUrl = address
        }
    }
}

private struct ProxyAddressEditor: View {
    let target: ProxyEditorTarget
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://127.0.0.1:7890", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("支持 HTTP、HTTPS、SOCKS5")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(target.moduleId == nil
                        ? "代理地址" : "\(target.name) · 代理地址")
                }
            }
            .navigationTitle("代理地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmed = address.trimmingCharacters(
                            in: .whitespaces
                        )
                        if !trimmed.isEmpty {
                            onSave(trimmed)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { address = target.initial }
        }
        .presentationBackground(.ultraThinMaterial)
    }
}

// MARK: - 诊断

struct DiagnosticsView: View {
    @EnvironmentObject private var moduleStore: ModuleStore
    @EnvironmentObject private var downloadManager: DownloadManager
    @ObservedObject private var kernelMemory = KernelMemoryStore.shared

    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var notice: String?
    @State private var errorText: String?

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        return version.isEmpty ? "版本未知" : "版本 \(version)"
    }

    private var migrationSummary: String {
        if let report = Migration.lastReport {
            return report.summary
        }
        let marker = Migration.markerURL(moduleStore.dataDirectory)
        return FileManager.default.fileExists(atPath: marker.path)
            ? "已迁移" : "未执行"
    }

    var body: some View {
        SettingsGroupPage(title: "诊断") {
            GlassSettingsCard {
                ValueSettingsRow(
                    title: "绿果视频（原生版）", value: versionText
                )
                SettingsRowDivider()
                ValueSettingsRow(
                    title: "旧版数据迁移", value: migrationSummary
                )
                SettingsRowDivider()
                ValueSettingsRow(
                    title: "模块状态",
                    value: "已安装 \(moduleStore.modules.count) 个"
                        + (moduleStore.currentModule.map {
                            " · 当前：\($0.name)"
                        } ?? "")
                )
                SettingsRowDivider()
                ValueSettingsRow(
                    title: "下载任务",
                    value: "共 \(downloadManager.jobs.count) 个 · 进行中 "
                        + "\(downloadManager.jobs.filter { $0.state == "downloading" || $0.state == "converting" }.count) 个"
                )
            }
            GlassSettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("内核记忆")
                            .foregroundStyle(.primary)
                        Spacer()
                        if !kernelMemory.entries.isEmpty {
                            Button("清除") {
                                kernelMemory.clearAll()
                            }
                            .font(.subheadline)
                        }
                    }
                    Text("每个来源上次播成功用的内核，下次播放优先用它；播不起来会自动换另一个并更新记忆")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if kernelMemory.displayEntries.isEmpty {
                        Text("暂无记录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(kernelMemory.displayEntries, id: \.key) { entry in
                            HStack {
                                Text(entry.source)
                                    .font(.subheadline)
                                Spacer()
                                Text(entry.kernel.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            GlassSettingsCard {
                NavigationLink {
                    PlaybackDiaryView()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("播放调试日记")
                                .foregroundStyle(.primary)
                            Text("查看并复制应用运行与播放器的详细事件日志")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            GlassSettingsCard {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("导出备份")
                                    .foregroundStyle(.primary)
                                Text("包含本地用户、追剧、观看记录、设置、站源开关和已安装模块，不含视频文件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    ValueSettingsRow(
                        title: "导出备份",
                        subtitle: "包含本地用户、追剧、观看记录、设置、站源开关和已安装模块，不含视频文件",
                        action: {
                            do {
                                exportURL = try BackupService.exportArchive(
                                    dataDirectory: AppData.directory
                                )
                                notice = "备份已生成，点一次「导出备份」即可分享"
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    )
                }
                SettingsRowDivider()
                ValueSettingsRow(
                    title: "恢复备份",
                    subtitle: "替换本机的用户、追剧、观看记录、设置和站源开关，已下载视频保留，完成后重启应用生效",
                    action: { showImporter = true }
                )
            }
            if let errorText {
                SettingsNote(text: errorText, color: .red)
            }
            if let notice {
                SettingsNote(text: notice)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.zip]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    let count = try BackupService.restore(
                        archiveURL: url, dataDirectory: AppData.directory
                    )
                    notice = "已恢复 \(count) 个文件，请从后台划掉应用后重新打开"
                } catch {
                    errorText = error.localizedDescription
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }
}

/// 播放调试日记页，对齐 Flutter DiaryView：失败行标红，
/// 可复制全部、导出文本、清空。
struct PlaybackDiaryView: View {
    @ObservedObject private var diary = DiaryStore.shared
    @State private var exportURL: URL?

    private static let failurePattern = try? NSRegularExpression(
        pattern: "err|fail|exception|异常|失败", options: [.caseInsensitive]
    )

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppVersion.display)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if diary.entries.isEmpty {
                        Text("暂无记录")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(
                        Array(diary.entries.enumerated()), id: \.offset
                    ) { index, entry in
                        Text(entry)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(
                                isFailure(entry) ? .red : .primary
                            )
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onAppear {
                if let last = diary.entries.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .navigationTitle("播放调试日记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = diary.fullText
                } label: {
                    Label("复制全部", systemImage: "doc.on.doc")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("lvguo-diary.txt")
                        try? diary.fullText.write(
                            to: url, atomically: true, encoding: .utf8
                        )
                        exportURL = url
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    diary.clear()
                    exportURL = nil
                } label: {
                    Label("清空", systemImage: "trash")
                }
            }
        }
    }

    private func isFailure(_ entry: String) -> Bool {
        let range = NSRange(entry.startIndex..., in: entry)
        return Self.failurePattern?.firstMatch(in: entry, range: range)
            != nil
    }
}
