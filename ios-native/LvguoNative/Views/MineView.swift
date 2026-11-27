import SwiftUI

/// 我的：照搬 Flutter mine_page.dart 的结构——页头下一列
/// 设置分组入口卡（液态玻璃卡，与原版 _Entry 的 LiquidGlass
/// 对位），点开进各自的子页。分组与原版设置页同序：
/// 外观 / 播放 / 弹幕 / 下载 / 存储 / 代理 / 诊断（摸鱼组是
/// 桌面端专属，iOS 上原版也不显示）。底栏历史页签被外观
/// 设置关掉时，这里补一个观看记录入口（原版语义）。
/// 「数据」保留迁移状态行：文件源计数常显，方便截图判读迁移。
struct MineView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var moduleStore: ModuleStore
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var downloadPreferences:
        DownloadPreferencesStore
    @EnvironmentObject private var resourceSettings: ResourceSettingsStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    entry(
                        icon: "paintpalette",
                        title: "外观",
                        subtitle: appearanceSummary
                    ) {
                        AppearanceSettingsView()
                    }
                    entry(
                        icon: "play.circle",
                        title: "播放",
                        subtitle: "倍速、静音、跳过片头片尾、手势与显示"
                    ) {
                        PlaybackSettingsView()
                    }
                    entry(
                        icon: "captions.bubble",
                        title: "弹幕",
                        subtitle: "字号、颜色、显示区域与屏蔽词"
                    ) {
                        DanmakuSettingsView()
                    }
                    entry(
                        icon: "arrow.down.circle",
                        title: "下载",
                        subtitle: "默认画质、VIP 集、同时下载数量"
                    ) {
                        DownloadSettingsView()
                    }
                    entry(
                        icon: "folder",
                        title: "存储",
                        subtitle: "下载目录、清理缓存、删除全部数据"
                    ) {
                        StorageSettingsView()
                    }
                    entry(
                        icon: "globe",
                        title: "代理",
                        subtitle: "连接方式、代理地址"
                    ) {
                        ProxySettingsView()
                    }
                    entry(
                        icon: "list.bullet.clipboard",
                        title: "诊断",
                        subtitle: "播放调试日记、备份与恢复"
                    ) {
                        DiagnosticsView()
                    }
                    if !appearance.historyTab {
                        entry(
                            icon: "clock.arrow.circlepath",
                            title: "观看记录",
                            subtitle: "底栏历史页签已关闭，从这里打开"
                        ) {
                            HistoryView()
                        }
                    }
                    migrationCard
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
            .navigationTitle("我的")
        }
    }

    private var appearanceSummary: String {
        let mode = AppearanceStore.themeModes
            .first { $0.0 == appearance.themeMode }?.1 ?? "跟随系统"
        let display = AppearanceStore.displayModes
            .first { $0.0 == appearance.displayMode }?.1 ?? "自动识别设备"
        return [mode, appearance.themeColor.label, display]
            .joined(separator: " · ")
    }

    private func entry<Destination: View>(
        icon: String, title: String, subtitle: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 72)
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private var migrationCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text("旧版数据迁移")
            Spacer()
            Text(migrationSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }

    private var migrationSummary: String {
        if let report = Migration.lastReport {
            return report.summary
        }
        let marker = Migration.markerURL(moduleStore.dataDirectory)
        return FileManager.default.fileExists(atPath: marker.path) ? "已迁移" : "未执行"
    }
}

/// 倍速显示：用普通字符串拼（Swift 字符串插值给最短形，
/// 1.0 → "1.0"），与 Dart 的 '${speed}x' 一致。
/// 绝不能直接写进 Text 的插值——那会按 %f 输出 "1.000000x"。
func speedLabel(_ speed: Double) -> String {
    "\(speed)x"
}

/// 播放设置子页：内容与 Flutter 设置页「播放」组一致。
struct PlaybackSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.1, 1.25, 1.5, 2.0, 3.0]
    private static let introOptions: [(Int, String)] = [
        (0, "关闭"), (5, "5 秒"), (10, "10 秒"), (15, "15 秒"), (30, "30 秒"),
    ]
    private static let outroOptions: [(Int, String)] = [
        (0, "关闭"), (10, "10 秒"), (30, "30 秒"), (60, "60 秒"), (90, "90 秒"),
    ]

    var body: some View {
        List {
            Picker("默认倍速", selection: $settings.speed) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text(speedLabel(speed)).tag(speed)
                }
            }
            .pickerStyle(.inline)
            Toggle(isOn: $settings.startMuted) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("默认静音播放")
                    Text("打开后每次进播放先静音，点音量按钮恢复声音")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // 注意：Flutter 设置页没有「自动连播」开关条目——
            // 只有 PlaybackPreferences.autoAdvance 字段（默认开）
            // 与播放逻辑。按先照搬原则此处不摆开关，字段与
            // 默认值在 SettingsStore 里保留、行为不变。
            Picker("跳过片头", selection: $settings.skipIntroSeconds) {
                ForEach(Self.introOptions, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            Picker("跳过片尾", selection: $settings.skipOutroSeconds) {
                ForEach(Self.outroOptions, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            Toggle(isOn: $settings.keepScreenAwake) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("播放时保持屏幕常亮")
                    Text("播放中禁止自动熄屏，退出播放后恢复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $settings.recordHistory) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("记录观看历史")
                    Text("关闭后不再保存观看进度与历史")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("手势与显示") {
                Toggle("双击快进 / 快退", isOn: $settings.doubleTapSeek)
                Toggle("滑动调节亮度 / 音量", isOn: $settings.swipeLevels)
                Toggle("滑动切换集数", isOn: $settings.swipeEpisodes)
                Toggle("显示时钟", isOn: $settings.showClock)
                Toggle("显示网速", isOn: $settings.showNetworkSpeed)
                Toggle("自动画中画", isOn: $settings.autoPictureInPicture)
                Picker("长按倍速", selection: $settings.boostSpeed) {
                    ForEach([1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { speed in
                        Text(speedLabel(speed)).tag(speed)
                    }
                }
                Picker("默认画面比例", selection: $settings.videoFit) {
                    ForEach(VideoFitMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            }
        }
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
    }
}
