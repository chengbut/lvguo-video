import SwiftUI

/// 历史页：站源/文件源分段切换（对齐 Flutter 版信息架构）。
/// 站源历史按 今天 / 昨天 / 更早 分组（WatchPeriod 的口径），
/// 点一条直接取详情+取址续播；文件记录点回按定位符重新取址续播。
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
                    stationList
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

    @ViewBuilder
    private var stationList: some View {
        if historyStore.entries.isEmpty {
            ContentUnavailableView(
                "暂无站源历史",
                systemImage: "clock",
                description: Text("看过的剧会记在这里，点开就能接着播。")
            )
        } else {
            List {
                ForEach(Period.allCases, id: \.rawValue) { period in
                    let rows = historyStore.entries.filter { self.period(of: $0.updatedAt) == period }
                    if !rows.isEmpty {
                        Section(period.rawValue) {
                            ForEach(rows) { entry in
                                stationRow(entry)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func stationRow(_ entry: StationHistoryEntry) -> some View {
        Button {
            Task { await resumeStation(entry) }
        } label: {
            HStack(spacing: 12) {
                coverView(entry.coverURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text("第 \(entry.episodeLabel) 集 · \(progressText(entry.position, entry.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if entry.duration > 0 {
                        ProgressView(value: min(1, entry.position / entry.duration))
                            .tint(.green)
                    }
                }
                Spacer()
                if resumingId == entry.dramaId {
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
                historyStore.remove(dramaId: entry.dramaId)
            }
        }
    }

    private func coverView(_ coverURL: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
            if !coverURL.isEmpty, let url = URL(string: coverURL) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private func resumeStation(_ entry: StationHistoryEntry) async {
        notice = nil
        guard let provider = moduleStore.provider(for: entry.source) else {
            notice = "源模块「\(entry.source)」未安装或已停用，无法续播"
            return
        }
        resumingId = entry.dramaId
        defer { resumingId = nil }
        do {
            let detail = try await provider.detail(sourceId: entry.sourceId)
            let chapters = detail.chapters
            guard chapters.indices.contains(entry.episodeIndex) else {
                notice = "这一集已经不存在了"
                return
            }
            let drama = detail.drama
            let session = PlaybackSession()
            session.index = entry.episodeIndex
            session.canPrevious = entry.episodeIndex > 0
            session.canNext = entry.episodeIndex < chapters.count - 1
            session.onProgress = { [historyStore, settings] session, position, duration in
                guard settings.recordHistory else { return }
                var record = StationHistoryEntry()
                record.dramaId = drama.id
                record.source = drama.source.isEmpty ? provider.manifest.id : drama.source
                record.sourceId = drama.sourceId
                record.title = drama.title
                record.coverURL = drama.coverURL
                record.totalEpisodes = drama.totalEpisodes
                record.episodeIndex = session.index
                record.episodeLabel = chapters.indices.contains(session.index)
                    ? chapters[session.index].episodeLabel : "\(session.index + 1)"
                record.position = position
                record.duration = duration
                record.updatedAt = Date()
                historyStore.record(record)
            }
            func request(for index: Int, start: Double) async -> PlaybackRequest? {
                guard chapters.indices.contains(index) else { return nil }
                do {
                    let plan = try await provider.resolveMedia(
                        drama: drama, chapter: chapters[index],
                        index: index, total: chapters.count
                    )
                    guard !plan.url.isEmpty, let url = URL(string: plan.url) else { return nil }
                    return PlaybackRequest(
                        url: url, headers: plan.headers,
                        title: "\(drama.title) · \(chapters[index].episodeLabel)",
                        startPosition: start
                    )
                } catch {
                    return nil
                }
            }
            session.onNext = { session in
                let next = session.index + 1
                guard chapters.indices.contains(next) else { return nil }
                session.index = next
                session.canPrevious = true
                session.canNext = next < chapters.count - 1
                return await request(for: next, start: 0)
            }
            session.onPrevious = { session in
                let previous = session.index - 1
                guard chapters.indices.contains(previous) else { return nil }
                session.index = previous
                session.canPrevious = previous > 0
                session.canNext = true
                return await request(for: previous, start: 0)
            }
            guard let request = await request(
                for: entry.episodeIndex,
                start: entry.finished ? 0 : entry.position
            ) else {
                notice = "模块没有返回可播放地址"
                return
            }
            playSession = session
            playRequest = request
            showPlayer = true
        } catch {
            notice = error.localizedDescription
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
