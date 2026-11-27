import SwiftUI

/// 首页：站源模式接当前模块的真实数据（分类 + 列表），
/// 文件源模式列出已配置的文件源（与资源页同一份数据），
/// 点开进浏览页 / HTTP 直链直接播（对齐 Flutter 版信息架构）。
struct HomeView: View {
    @EnvironmentObject private var store: ModuleStore
    @EnvironmentObject private var fileStore: FileSourceStore
    @State private var sourceKind: SourceKind = .station

    @State private var categories: [CatalogCategory] = []
    @State private var selectedCategory = ""
    @State private var items: [DramaItem] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GlassSegmentedControl(selection: $sourceKind)
                    if sourceKind == .station {
                        stationContent
                    } else {
                        fileContent
                    }
                }
                .padding()
            }
            .navigationTitle("首页")
            .toolbar {
                if sourceKind == .station {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SearchView()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
            .task(id: store.currentSourceId) {
                await reloadFromModule()
            }
        }
    }

    // MARK: - 站源模式

    @ViewBuilder
    private var stationContent: some View {
        if store.currentModule == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("还没有可用的站源模块")
                    .font(.headline)
                Text(store.providerError() ?? "去「资源」页从 URL 安装一个模块，或先装内置示例模块验证链路。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular.tint(.green.opacity(0.10)), in: RoundedRectangle(cornerRadius: 20))
        } else {
            if !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories) { category in
                            Button {
                                guard selectedCategory != category.id else { return }
                                selectedCategory = category.id
                                Task { await loadFirstPage() }
                            } label: {
                                Text(category.name)
                                    .font(.subheadline.weight(
                                        selectedCategory == category.id ? .semibold : .regular
                                    ))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(
                                selectedCategory == category.id
                                    ? .regular.tint(.green.opacity(0.35))
                                    : .regular,
                                in: Capsule()
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let errorText {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button("重试") { Task { await reloadFromModule() } }
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .glassEffect(.regular.tint(.red.opacity(0.08)), in: RoundedRectangle(cornerRadius: 16))
            }

            if loading && items.isEmpty {
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if items.isEmpty && errorText == nil && !loading {
                Text("这个分类暂时没有内容")
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
                            DramaCell(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if hasMore {
                    Button {
                        Task { await loadNextPage() }
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
    }

    @ViewBuilder
    private var fileContent: some View {
        if fileStore.sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("还没有文件源")
                    .font(.headline)
                Text("去「资源」页添加 WebDAV / FTP / HTTP 直链，或天翼 / 移动云盘。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular.tint(.green.opacity(0.10)), in: RoundedRectangle(cornerRadius: 20))
        } else {
            VStack(spacing: 10) {
                ForEach(fileStore.sources) { source in
                    NavigationLink {
                        FileSourceOpenView(source: source)
                    } label: {
                        FileSourceRow(source: source)
                            .padding(14)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    // MARK: - 数据加载

    @MainActor
    private func reloadFromModule() async {
        categories = []
        items = []
        selectedCategory = ""
        errorText = nil
        guard let provider = store.currentProvider() else {
            if let message = store.providerError() {
                errorText = message
            }
            return
        }
        loading = true
        defer { loading = false }
        do {
            categories = try await provider.categories()
            selectedCategory = categories.first?.id ?? ""
            if !selectedCategory.isEmpty {
                // loadFirstPage 自己管理 loading，这里先放下外层标记避免叠加
                loading = false
                await loadFirstPage()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func loadFirstPage() async {
        guard let provider = store.currentProvider(), !selectedCategory.isEmpty else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let result = try await provider.catalogPage(page: 1, category: selectedCategory)
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
    private func loadNextPage() async {
        guard let provider = store.currentProvider(), hasMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = page + 1
            let result = try await provider.catalogPage(page: next, category: selectedCategory)
            items.append(contentsOf: result.items)
            page = next
            hasMore = result.hasMore
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 列表格子：封面 + 标题 + 集数（封面为空时用玻璃占位）
private struct DramaCell: View {
    let item: DramaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.quaternary)
                if !item.coverURL.isEmpty, let cover = URL(string: item.coverURL) {
                    AsyncImage(url: cover) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
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
