import SwiftUI

/// 我的：播放设置（键义与选项对齐 Flutter 版 PlaybackPreferences
/// 的设置页）+ 数据迁移状态 + 关于。
struct MineView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var moduleStore: ModuleStore

    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.1, 1.25, 1.5, 2.0, 3.0]
    private static let introOptions: [(Int, String)] = [
        (0, "关闭"), (5, "5 秒"), (10, "10 秒"), (15, "15 秒"), (30, "30 秒"),
    ]
    private static let outroOptions: [(Int, String)] = [
        (0, "关闭"), (10, "10 秒"), (30, "30 秒"), (60, "60 秒"), (90, "90 秒"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("播放") {
                    Picker("默认倍速", selection: $settings.speed) {
                        ForEach(Self.speeds, id: \.self) { speed in
                            Text("\(speed)x").tag(speed)
                        }
                    }
                    Toggle(isOn: $settings.startMuted) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("默认静音播放")
                            Text("打开后每次进播放先静音，点音量按钮恢复声音")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $settings.autoAdvance) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动连播")
                            Text("一集播完自动播放下一集")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                }
                Section("数据") {
                    HStack {
                        Label("旧版数据迁移", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text(migrationSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
