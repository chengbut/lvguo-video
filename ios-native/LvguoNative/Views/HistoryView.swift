import SwiftUI

/// 历史页：站源/文件源分段切换（v2.0.0 定版的信息架构）。
/// 站源侧照搬 Flutter history_page.dart：搜索 + 来源筛选片 +
/// 今天/昨天/更早 分段的海报网格（封面 2:3、集数进度条、
/// 「看到第 X 集 / 共 Y 集」文案、来源标签），点条目进详情页，
/// 由详情页的「继续播放」按集号定位续播集——Flutter 就是这个
/// 流程。旧版在这里拿迁移来的数组下标直接定位并直接取址播放，
/// 集号与下标对不上时误报「这一集已经不存在了」，已废除。
/// 文件侧保持记录列表 + 按定位符重新取址续播。
struct HistoryView: View {
    @EnvironmentObject private var moduleStore: ModuleStore
    @EnvironmentObject private var historyStore: HistoryStore
    @EnvironmentObject private var fileStore: FileSourceStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var sourceKind: SourceKind = .station
    @State private var notice: String?
    @State private var resumingId: String?
    @State private var playRequest: PlaybackRequest?
    @State private var playSession: PlaybackSession?
    @State private var showPlayer = false
    @State private var query = ""
    @State private var sourceFilter = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GlassSegmentedControl(selection: $sourceKind)
                    .padding(.top, 8)
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                if sourceKind == .station {
                    stationContent
                } else {
                    fileList
                }
            }
            .navigationTitle("历史")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if sourceKind == .station {
                            Button("清空站源历史", role: .destructive) {
                                historyStore.clear()
                            }
                        } else {
                            Button("清空文件记录", role: .destructive) {
                                fileStore.clearProgress()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fullScreenCover(isPresented: $showPlayer) {
                if let playRequest {
                    PlayerPage(request: playRequest, session: playSession)
                }
            }
        }
    }

    // MARK: - 站源

    private enum Period: String, CaseIterable {
        case today = "今天"
        case yesterday = "昨天"
        case earlier = "更早"
    }

    private func period(of date: Date) -> Period {
        let calendar = Calendar.current
        let startToday = calendar.startOfDay(for: Date())
        if date >= startToday { return .today }
        if let startYesterday = calendar.date(byAdding: .day, value: -1, to: startToday),
           date >= startYesterday { return .yesterday }
        return .earlier
    }

    private var sourceOptions: [String] {
        var seen: [String] = []
        for entry in historyStore.entries where !seen.contains(entry.source) {
            seen.append(entry.source)
        }
        return seen
    }

    private func sourceName(_ sourceId: String) -> String {
        moduleStore.modules.first { $0.id == sourceId }?.name ?? sourceId
    }

    private func matches(_ entry: StationHistoryEntry) -> Bool {
        if !sourceFilter.isEmpty, entry.source != sourceFilter {
            return false
        }
        let keyword = query.trimmingCharacters(in: .whitespaces).lowercased()
        if keyword.isEmpty { return true }
        return entry.title.lowercased().contains(keyword)
            || sourceName(entry.source).lowercased().contains(keyword)
    }

    @ViewBuilder
    private var stationContent: some View {
        VStack(spacing: 12) {
            searchField
            if sourceOptions.count > 1 {
                sourceChips
            }
            stationGrid
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜片名、来源", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceChip(title: "全部来源", value: "")
                ForEach(sourceOptions, id: \.self) { sourceId in
                    sourceChip(title: sourceName(sourceId), value: sourceId)
                }
            }
            .padding(.horizontal)
        }
    }

    private func sourceChip(title: String, value: String) -> some View {
        let selected = sourceFilter == value
        return Button {
            sourceFilter = value
        } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(
            selected ? .regular.tint(.green.opacity(0.35)) : .regular,
            in: Capsule()
        )
    }

    @ViewBuilder
    private var stationGrid: some View {
        let visible = historyStore.entries.filter(matches)
        if historyStore.entries.isEmpty {
            ContentUnavailableView(
                "暂无观看记录",
                systemImage: "clock.arrow.circlepath",
                description: Text("从站源看过的剧会出现在这里。")
            )
        } else if visible.isEmpty {
            ContentUnavailableView(
                "没有匹配的观看记录",
                systemImage: "magnifyingglass",
                description: Text("换个关键词或来源试试。")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Period.allCases, id: \.rawValue) { period in
                        let rows = visible.filter { self.period(of: $0.updatedAt) == period }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(period.rawValue)
                                    .font(.headline)
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 104), spacing: 12)],
                                    spacing: 14
                                ) {
                                    ForEach(rows) { entry in
                                        NavigationLink {
                                            stationDestination(entry)
                                        } label: {
                                            HistoryPosterCell(
                                                entry: entry,
                                                sourceName: sourceName(entry.source)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button("删除记录", role: .destructive) {
                                                historyStore.remove(dramaId: entry.dramaId)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private func stationDestination(_ entry: StationHistoryEntry) -> some View {
        if let provider = moduleStore.provider(for: entry.source) {
            DramaDetailView(provider: provider, item: entry.dramaItem)
        } else {
            ContentUnavailableView(
                "源模块未安装或已停用",
                systemImage: "puzzlepiece.extension",
                description: Text("「\(sourceName(entry.source))」不在了，装回来才能接着看。")
            )
            .navigationTitle(entry.title)
        }
    }

    // MARK: - 文件

    @ViewBuilder
    private var fileList: some View {
        if fileStore.records.isEmpty {
            ContentUnavailableView(
                "暂无文件记录",
                systemImage: "clock",
                description: Text("播过的文件会记在这里，点开就能接着播。")
            )
        } else {
            List {
                ForEach(fileStore.records) { record in
                    fileRow(record)
                }
            }
            .listStyle(.plain)
        }
    }

    private func fileRow(_ record: FileHistoryRecord) -> some View {
        let progress = record.progress
        return Button {
            Task { await resumeFile(record) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "movieclapper")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress.title.isEmpty ? "文件" : progress.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text([
                        progress.sourceName,
                        progressText(progress.position, progress.duration),
                    ].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if progress.duration > 0 {
                        ProgressView(value: min(1, progress.position / progress.duration))
                            .tint(.green)
                    }
                }
                Spacer()
                if resumingId == record.key {
                    ProgressView()
                } else {
                    Image(systemName: "play.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) {
                fileStore.removeProgress(record.key)
            }
        }
    }

    private func progressText(_ position: Double, _ duration: Double) -> String {
        if duration > 1, position >= duration - 1 {
            return "已看完"
        }
        if position > 0 {
            return "看到 \(clockText(position))"
        }
        return "未开始"
    }

    private func resumeFile(_ record: FileHistoryRecord) async {
        notice = nil
        let progress = record.progress
        guard let source = fileStore.sourceById(progress.sourceId) else {
            notice = "这个文件源已被删除，无法续播"
            return
        }
        resumingId = record.key
        defer { resumingId = nil }
        let session = PlaybackSession()
        session.displayTitle = progress.title
        session.onRefresh = { [source] _ in
            // 恢复时重新取址（云盘/直链地址可能已过期）
            if source.type == .http {
                guard let url = URL(string: progress.url.isEmpty ? source.url : progress.url)
                else { return nil }
                return PlaybackRequest(url: url, title: progress.title)
            }
            let client = createFileSourceClient(source)
            let entry = FileEntry(
                name: progress.title,
                href: progress.ref.isEmpty ? progress.url : progress.ref,
                isDirectory: false
            )
            guard let target = try? await client.target(entry),
                  let url = URL(string: target.url) else { return nil }
            return PlaybackRequest(url: url, headers: target.headers, title: progress.title)
        }
        session.onProgress = { [fileStore, source] _, position, duration in
            fileStore.saveProgress(
                record.key,
                position: position,
                duration: duration,
                title: progress.title,
                sourceName: source.name,
                sourceId: source.id,
                ref: progress.ref
            )
        }
        do {
            let request: PlaybackRequest
            if source.type == .http {
                guard let url = URL(string: progress.url.isEmpty ? source.url : progress.url) else {
                    notice = "地址无效"
                    return
                }
                request = PlaybackRequest(
                    url: url, title: progress.title,
                    startPosition: progress.finished ? 0 : progress.position
                )
            } else {
                let client = createFileSourceClient(source)
                let entry = FileEntry(
                    name: progress.title,
                    href: progress.ref.isEmpty ? progress.url : progress.ref,
                    isDirectory: false
                )
                let target = try await client.target(entry)
                guard let url = URL(string: target.url) else {
                    notice = "播放地址无效"
                    return
                }
                request = PlaybackRequest(
                    url: url, headers: target.headers, title: progress.title,
                    startPosition: progress.finished ? 0 : progress.position
                )
            }
            playSession = session
            playRequest = request
            showPlayer = true
        } catch {
            notice = error.localizedDescription
        }
    }
}

/// 历史海报格，对齐 Flutter _HistoryPoster：封面 2:3、
/// 底部集数进度条、标题、进度文案、来源标签。
private struct HistoryPosterCell: View {
    let entry: StationHistoryEntry
    let sourceName: String

    private var progress: Double {
        guard entry.totalEpisodes > 0 else { return 0 }
        let episodeNumber = Int(entry.episodeLabel) ?? entry.episodeIndex + 1
        return min(1, Double(episodeNumber) / Double(entry.totalEpisodes))
    }

    private var caption: String {
        let episodeNumber = Int(entry.episodeLabel) ?? entry.episodeIndex + 1
        if entry.finished,
           entry.totalEpisodes <= 0 || episodeNumber >= entry.totalEpisodes {
            return "已看完"
        }
        if entry.totalEpisodes > 0 {
            return "看到第 \(episodeNumber) 集 / 共 \(entry.totalEpisodes) 集"
        }
        return "看到第 \(episodeNumber) 集"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)
                    if !entry.coverURL.isEmpty, let url = URL(string: entry.coverURL) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .foregroundStyle(.secondary)
                    }
                }
                .coverBlur(source: entry.source, explore: false)
                if entry.totalEpisodes > 0 {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.35))
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: proxy.size.width * progress)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(entry.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(sourceName)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12), in: Capsule())
                .foregroundStyle(.green)
                .lineLimit(1)
        }
    }
}
