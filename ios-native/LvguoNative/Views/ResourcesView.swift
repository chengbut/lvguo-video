import SwiftUI

/// 资源页：站源组 = 模块管理（安装 / 启用停用 / 设为当前 / 删除），
/// 文件源组 = 文件源管理（添加 / 打开 / 删除，与首页文件模式
/// 同一份数据）；播放测试保留一期公开测试流。
struct ResourcesView: View {
    @EnvironmentObject private var store: ModuleStore
    @EnvironmentObject private var fileStore: FileSourceStore
    @State private var showPlayer = false
    @State private var installURL = ""
    @State private var installing = false
    @State private var message: String?
    @State private var pendingDelete: InstalledModule?
    @State private var showAddFileSource = false
    @State private var pendingDeleteFileSource: FileSource?

    /// 公开测试流（Mux 官方测试 HLS），带一个示例头以证明 headers 注入路径
    private let testStream = PlaybackRequest(
        url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!,
        headers: ["User-Agent": "LvguoNative/0.1 (iOS)"],
        title: "公开测试流"
    )

    var body: some View {
        NavigationStack {
            List {
                Section("站源 · 模块管理") {
                    HStack {
                        TextField("模块包 URL（https://…/module.zip）", text: $installURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote)
                        Button {
                            Task { await installFromURL() }
                        } label: {
                            if installing {
                                ProgressView()
                            } else {
                                Text("安装")
                            }
                        }
                        .disabled(installURL.trimmingCharacters(in: .whitespaces).isEmpty || installing)
                    }
                    Button {
                        installSample()
                    } label: {
                        Label("安装内置示例模块（假数据）", systemImage: "puzzlepiece.extension")
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("已安装模块") {
                    if store.modules.isEmpty {
                        Text("还没有安装任何模块")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.modules) { module in
                        moduleRow(module)
                    }
                }

                Section("文件源") {
                    if fileStore.sources.isEmpty {
                        Text("还没有文件源")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(fileStore.sources) { source in
                        NavigationLink {
                            FileSourceOpenView(source: source)
                        } label: {
                            FileSourceRow(source: source)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                pendingDeleteFileSource = source
                            }
                        }
                    }
                    Button {
                        showAddFileSource = true
                    } label: {
                        Label("添加文件源", systemImage: "plus.circle")
                    }
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
            .sheet(isPresented: $showAddFileSource) {
                FileSourceTypePickerView()
            }
            .confirmationDialog(
                "删除文件源「\(pendingDeleteFileSource?.name ?? "")」？",
                isPresented: Binding(
                    get: { pendingDeleteFileSource != nil },
                    set: { if !$0 { pendingDeleteFileSource = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let target = pendingDeleteFileSource {
                        fileStore.remove(id: target.id)
                    }
                    pendingDeleteFileSource = nil
                }
                Button("取消", role: .cancel) { pendingDeleteFileSource = nil }
            } message: {
                Text("只删这个文件源的连接信息，网盘和服务器上的文件不受影响。")
            }
            .confirmationDialog(
                "删除模块「\(pendingDelete?.name ?? "")」？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let target = pendingDelete {
                        store.uninstall(target.id)
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
        }
    }

    private func moduleRow(_ module: InstalledModule) -> some View {
        let isCurrent = module.id == store.currentSourceId
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(module.name)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                    if isCurrent {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glassEffect(.regular.tint(.green.opacity(0.4)), in: Capsule())
                    }
                }
                Text("\(module.id) · v\(module.manifest?.version ?? "-")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !module.loadError.isEmpty {
                    Text(module.loadError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { module.enabled },
                    set: { store.setEnabled(module.id, $0) }
                )
            )
            .labelsHidden()
            Menu {
                Button("设为当前") { store.setCurrent(module.id) }
                    .disabled(isCurrent || !module.isUsable)
                Button("删除", role: .destructive) { pendingDelete = module }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
    }

    // MARK: - 安装

    private func installSample() {
        do {
            let manifest = try store.installSampleModule()
            store.setCurrent(manifest.id)
            message = "示例模块「\(manifest.name)」已安装并设为当前，去首页看分类列表。"
        } catch {
            message = "\(error)"
        }
    }

    private func installFromURL() async {
        installing = true
        defer { installing = false }
        do {
            let manifest = try await store.installFromURL(installURL)
            store.setCurrent(manifest.id)
            message = "模块「\(manifest.name)」安装成功，已设为当前。"
            installURL = ""
        } catch {
            message = "\(error)"
        }
    }
}
