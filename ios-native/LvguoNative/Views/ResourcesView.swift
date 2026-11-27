import SwiftUI
import UniformTypeIdentifiers

/// 资源页：站源组 = 模块管理（安装 / 启用停用 / 设为当前 / 卸载），
/// 文件源组 = 文件源管理（添加 / 打开 / 删除，与首页文件模式
/// 同一份数据）。文案对齐 Flutter modules_page.dart
/// （动作叫「卸载」不叫「删除」，空状态文案同 Flutter）。
struct ResourcesView: View {
    @EnvironmentObject private var store: ModuleStore
    @EnvironmentObject private var fileStore: FileSourceStore
    @State private var installURL = ""
    @State private var installing = false
    @State private var message: String?
    @State private var pendingDelete: InstalledModule?
    @State private var showAddFileSource = false
    @State private var pendingDeleteFileSource: FileSource?
    @State private var showAddModule = false
    @State private var showModuleFilePicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("站源 · 模块管理") {
                    // 添加入口对齐 Flutter modules_page：组头
                    // 「+ 添加」打开「添加站源模块」，里面
                    // 选择本地文件 / 输入下载地址两条路
                    // （修复轮 11 第 7 项；旧版只有一行内嵌
                    // URL 输入框，且顶部挂着示例模块入口，
                    // 第 8 项已一并移除）
                    Button {
                        showAddModule = true
                    } label: {
                        Label("添加模块", systemImage: "plus.circle")
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("已安装模块") {
                    if store.modules.isEmpty {
                        Text("还没有安装站源模块。点「添加模块」，选择本地文件或输入下载地址安装。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.modules) { module in
                        moduleRow(module)
                    }
                }

                Section("文件源") {
                    if fileStore.sources.isEmpty {
                        Text("还没有文件源。点「添加文件源」，把网盘或服务器挂进来。")
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
            }
            .navigationTitle("资源")
            .sheet(isPresented: $showAddFileSource) {
                FileSourceTypePickerView()
            }
            .sheet(isPresented: $showAddModule) {
                addModuleSheet
            }
            .fileImporter(
                isPresented: $showModuleFilePicker,
                allowedContentTypes: [.zip, .data],
                allowsMultipleSelection: false
            ) { result in
                handleModuleFilePick(result)
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
                "卸载站源「\(pendingDelete?.name ?? "")」？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("卸载", role: .destructive) {
                    if let target = pendingDelete {
                        store.uninstall(target.id)
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("该站源的追剧、观看记录和已下载视频会保留，但在重新安装前不再显示，正在下载的集会暂停。")
            }
        }
    }

    private func moduleRow(_ module: InstalledModule) -> some View {
        let isCurrent = module.id == store.currentSourceId
        // 动作呈现对齐 Flutter _InstalledCard（修复轮 11
        // 第 6 项）：「设为当前」「卸载」是卡片上的直达
        // 按钮，不再藏进省略号菜单；启用开关仍在行尾。
        // 「设为当前」只在可切换时出现（已启用且不是
        // 当前），「卸载」恒显示、走既有确认弹窗
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
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
            }
            HStack(spacing: 10) {
                if !isCurrent, module.enabled {
                    Button {
                        store.setCurrent(module.id)
                    } label: {
                        Label("设为当前", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!module.isUsable)
                }
                Button(role: .destructive) {
                    pendingDelete = module
                } label: {
                    Label("卸载", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
    }

    // MARK: - 安装

    /// 「添加站源模块」面板（修复轮 11 第 7 项）：两条
    /// 安装路与 Flutter 添加对话框一致——选择本地文件
    /// （文件导入 → installPackage，与 URL 安装同一条
    /// 安装链）/ 输入下载地址（installFromURL）
    private var addModuleSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showAddModule = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showModuleFilePicker = true
                        }
                    } label: {
                        Label("选择本地文件", systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("从「文件」里选模块包（.zip），包根目录或唯一一层文件夹里要有 manifest.json 和 main.js。")
                }
                Section("输入下载地址") {
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
                            Text("下载并安装")
                        }
                    }
                    .disabled(installURL.trimmingCharacters(in: .whitespaces).isEmpty || installing)
                }
                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("添加站源模块")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddModule = false }
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
    }

    private func handleModuleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let manifest = try store.installPackage(data: data)
                store.setCurrent(manifest.id)
                message = "模块「\(manifest.name)」安装成功，已设为当前。"
            } catch {
                message = "\(error)"
            }
        case .failure(let error):
            message = "读取文件失败：\(error.localizedDescription)"
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
            showAddModule = false
        } catch {
            message = "\(error)"
        }
    }
}
