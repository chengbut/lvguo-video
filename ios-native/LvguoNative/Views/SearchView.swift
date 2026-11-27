import SwiftUI

/// 搜索页：在当前站源中搜索（对齐 Flutter SearchPage 的形态：
/// 搜索框 + 最近搜索 + 结果网格进详情），走 ModuleProvider.search。
struct SearchView: View {
    @EnvironmentObject private var store: ModuleStore
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var items: [DramaItem] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorText: String?
    @State private var recents: [String] = []

    private var recentsFile: URL {
        store.dataDirectory.appendingPathComponent("recent-searches.json")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if submittedQuery.isEmpty {
                    recentsSection
                } else if loading && items.isEmpty {
                    ProgressView("正在搜索…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if let errorText, items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("搜索失败")
                            .font(.headline)
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if items.isEmpty {
                    Text("没有找到相关内容")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else if let provider = store.currentProvider() {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 104), spacing: 12)],
                        spacing: 14
                    ) {
                        ForEach(items) { item in
                            NavigationLink {
                                DramaDetailView(provider: provider, item: item)
                            } label: {
                                SearchDramaCell(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if hasMore {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            if loadingMore {
                                ProgressView()
                            } else {
                                Text("加载更多")
                                    .font(.subheadline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: Capsule())
                    }
                }
            }
            .padding()
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: store.currentModule.map { Text("在 \($0.name) 中搜索") } ?? Text("搜索")
        )
        .onSubmit(of: .search) {
            Task { await submit() }
        }
        .onAppear {
            recents = (AppData.readJSON(recentsFile) as? [Any])?
                .compactMap { $0 as? String } ?? []
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if store.currentModule == nil {
            Text(store.providerError() ?? "还没有可用的站源模块，先去「资源」页安装。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近搜索")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("清除") {
                        recents = []
                        AppData.writeJSON([String](), to: recentsFile)
                    }
                    .font(.caption)
                }
                FlowChips(items: recents) { text in
                    query = text
                    Task { await submit() }
                }
            }
        } else {
            Text("输入关键词搜索当前站源的内容")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func submit() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.currentProvider() != nil else { return }
        submittedQuery = text
        if !recents.contains(text) {
            recents.insert(text, at: 0)
            recents = Array(recents.prefix(20))
            AppData.writeJSON(recents, to: recentsFile)
        }
        await loadFirst()
    }

    @MainActor
    private func loadFirst() async {
        guard let provider = store.currentProvider() else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let result = try await provider.search(page: 1, query: submittedQuery)
            items = result.items
            page = 1
            hasMore = result.hasMore
            if !result.warning.isEmpty {
                errorText = result.warning
            }
        } catch {
            errorText = error.localizedDescription
            items = []
            hasMore = false
        }
    }

    @MainActor
    private func loadMore() async {
        guard let provider = store.currentProvider(), hasMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = page + 1
            let result = try await provider.search(page: next, query: submittedQuery)
            items.append(contentsOf: result.items)
            page = next
            hasMore = result.hasMore
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 简单的流式标签布局（最近搜索）
private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 72), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(items, id: \.self) { item in
                Button(item) { onTap(item) }
                    .font(.footnote)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
            }
        }
    }
}

/// 搜索结果格子（与首页 DramaCell 同形态）
private struct SearchDramaCell: View {
    let item: DramaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.quaternary)
                if !item.coverURL.isEmpty, let cover = URL(string: item.coverURL) {
                    AsyncImage(url: cover) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(item.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.totalEpisodes > 0 {
                Text("共 \(item.totalEpisodes) 集")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
