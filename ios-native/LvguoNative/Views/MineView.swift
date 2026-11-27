import SwiftUI

/// 我的：照搬 Flutter mine_page.dart 的结构——页头下一列
/// 设置分组入口卡，点开进各自的子页。原生目前只落地了「播放」
/// 一组（键义与选项对齐 PlaybackPreferences），其余分组
/// （外观/弹幕/下载/存储/代理/诊断）原生尚无对应系统，
/// 不摆假入口，差距记在 README 已知限制里。
/// 「数据」保留迁移状态行：文件源计数常显，方便截图判读迁移。
struct MineView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var moduleStore: ModuleStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("播放")
                                Text("倍速、静音、跳过片头片尾、手势与显示")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "play.circle")
                                .foregroundStyle(.green)
                        }
                    }
                }
                Section("数据") {
                    HStack {
                        Label("旧版数据迁移", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text(migrationSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("关于") {
                    Label("绿果视频（原生版）", systemImage: "info.circle")
                    Text("SwiftUI + AVPlayer + JavaScriptCore 全量原生重写，与 Flutter 版同包名覆盖安装、数据互通迁移。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
        }
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
