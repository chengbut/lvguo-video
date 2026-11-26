import SwiftUI

struct ResourcesView: View {
    @State private var showPlayer = false
    @State private var moduleOutput = ""
    @State private var moduleLogs: [String] = []

    /// 公开测试流（Mux 官方测试 HLS），带一个示例头以证明 headers 注入路径
    private let testStream = PlaybackRequest(
        url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!,
        headers: ["User-Agent": "LvguoNative/0.1 (iOS)"],
        title: "公开测试流"
    )

    var body: some View {
        NavigationStack {
            List {
                Section("站源") {
                    Label("JS 模块系统（二期接入）", systemImage: "puzzlepiece.extension")
                    Button {
                        runSampleModule()
                    } label: {
                        Label("运行示例模块", systemImage: "play.rectangle")
                    }
                    if !moduleOutput.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("模块返回")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(moduleOutput)
                                .font(.system(.footnote, design: .monospaced))
                            if !moduleLogs.isEmpty {
                                Text(moduleLogs.joined(separator: "\n"))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("文件源") {
                    Label("WebDAV / FTP / HTTP（二期）", systemImage: "externaldrive")
                    Label("天翼云盘 / 移动云盘（二期）", systemImage: "cloud")
                }
                Section("播放测试") {
                    Button {
                        showPlayer = true
                    } label: {
                        Label("测试播放（公开测试流）", systemImage: "play.circle")
                    }
                }
            }
            .navigationTitle("资源")
            .fullScreenCover(isPresented: $showPlayer) {
                PlayerPage(request: testStream)
            }
        }
    }

    private func runSampleModule() {
        let result = ModuleRunner().run(source: ModuleRunner.sampleModule)
        moduleOutput = result.output
        moduleLogs = result.logs
    }
}
