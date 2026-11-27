import SwiftUI

/// 详情页：模块 detail() 拉剧目信息与集数列表，
/// 点集 → resolveMedia() 拿播放计划 → PlayerPage 播放（headers 沿用一期注入）。
/// 播放进度写站源历史（可续播），播完按设置自动连播下一集；
/// 「下载」模式下点集改为入队下载（走 resolveMedia 取址）。
struct DramaDetailView: View {
    let provider: ModuleProvider
    let item: DramaItem

    @EnvironmentObject private var historyStore: HistoryStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var downloads: DownloadManager

    @State private var drama: DramaItem?
    @State private var chapters: [ChapterItem] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var message: String?
    @State private var resolvingIndex: Int?
    @State private var playRequest: PlaybackRequest?
    @State private var playSession: PlaybackSession?
    @State private var showPlayer = false
    @State private var downloadMode = false
    @State private var selectedGroup = 0
    @State private var errorExpanded = false

    /// 头部展示的剧目：detail() 的结果优先，但封面/标题/总集数/
    /// 简介在 detail 里为空时回落到列表页传进来的 item——
    /// Flutter 版头部一直用传入的剧目、只从 detail 取选集；
    /// 旧版整体替换会把已有的封面弄丢（真机首测实证）。
    private var displayDrama: DramaItem {
        guard var merged = drama else { return item }
        if merged.coverURL.isEmpty { merged.coverURL = item.coverURL }
        if merged.title.isEmpty { merged.title = item.title }
        if merged.totalEpisodes <= 0 { merged.totalEpisodes = item.totalEpisodes }
        if merged.desc.isEmpty { merged.desc = item.desc }
        if merged.sourceId.isEmpty { merged.sourceId = item.sourceId }
        return merged
    }

    private var historyEntry: StationHistoryEntry? {
        historyStore.entry(forDramaId: displayDrama.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let errorText {
                    errorNotice(errorText)
                }
                if let message {
                    notice(message, isError: false)
                }
                if loading && chapters.isEmpty {
                    ProgressView("正在加载详情…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    episodeList
                }
            }
            .padding()
        }
        .navigationTitle(displayDrama.title)
        .navigationBarTitleDisplayMode(.inline)
        // 全屏 push（对齐 Flutter：详情页在壳外全屏呈现）：
        // 隐藏底部 tab bar，否则详情页底部胶囊会与 tab bar
        // 双层叠加（真机 1.2 截图实证）
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if !chapters.isEmpty {
                bottomCapsule
            }
        }
        .task { await loadDetail() }
        .onChange(of: errorText) { _, _ in errorExpanded = false }
        .fullScreenCover(isPresented: $showPlayer) {
            if let playRequest {
                PlayerPage(request: playRequest, session: playSession)
            }
        }
    }

    private func notice(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(isError ? .red : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glassEffect(
                .regular.tint(isError ? .red.opacity(0.08) : .green.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 16)
            )
    }

    /// 错误卡（修复轮 3 改可折叠）：模块取流失败会把整条
    /// 尝试链拼成一段长文（签名/App/网页/官网各路径），默认
    /// 只显示首个失败原因，点「展开全文」看完整原文——展开
    /// 后是原文一字不删，透出原则不变。
    private func errorNotice(_ text: String) -> some View {
        let summary = Self.errorSummary(text)
        let collapsible = summary != text
        return VStack(alignment: .leading, spacing: 8) {
            Text(errorExpanded || !collapsible ? text : summary)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            if collapsible {
                Button {
                    errorExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(errorExpanded ? "收起" : "展开全文")
                        Image(systemName: errorExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(
            .regular.tint(.red.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    /// 摘要 = 首个失败原因：优先第一行；单行长文取第一个
    /// 「；」之前的段落（模块错误链正是以「；」拼接各路径）；
    /// 段落仍过长时截到 90 字（仅折叠态的显示截断，展开
    /// 全文不受影响）。
    static func errorSummary(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? text
        var summary = firstLine
        if summary.count > 90,
           let cut = summary.firstIndex(of: "；"),
           cut != summary.startIndex {
            summary = String(summary[..<cut])
        }
        if summary.count > 90 {
            summary = String(summary.prefix(90)) + "…"
        }
        return summary
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.quaternary)
                if !displayDrama.coverURL.isEmpty, let cover = URL(string: displayDrama.coverURL) {
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
            .frame(width: 100, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 6) {
                Text(displayDrama.title)
                    .font(.headline)
                if displayDrama.totalEpisodes > 0 {
                    Text("共 \(displayDrama.totalEpisodes) 集")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !displayDrama.desc.isEmpty {
                    Text(displayDrama.desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular.tint(.green.opacity(0.08)), in: RoundedRectangle(cornerRadius: 20))
    }

    /// 续播目标集下标：按历史里的集号在最新选集里匹配
    /// （HistoryResume，与 Flutter resumeEpisodeIndex 一致）；
    /// 没有历史时从第一集开始。
    private var resumeIndex: Int? {
        guard !chapters.isEmpty else { return nil }
        guard let entry = historyEntry else { return 0 }
        let episodeNumber = Int(entry.episodeLabel) ?? entry.episodeIndex + 1
        return HistoryResume.chapterIndex(
            chapters: chapters, episodeNumber: episodeNumber, finished: entry.finished
        )
    }

    /// 底部悬浮胶囊，照搬 Flutter 详情页：左「下载选集」开关，
    /// 右主按钮（继续播放 / 重播 / 播放 · 第 N 集）。
    private var bottomCapsule: some View {
        HStack(spacing: 10) {
            Button {
                downloadMode.toggle()
                message = downloadMode ? "下载模式：点一集就下载这一集" : nil
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: downloadMode ? "checkmark" : "arrow.down.circle")
                    Text(downloadMode ? "完成" : "下载选集")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())

            Button {
                guard let index = resumeIndex else { return }
                Task { await play(chapter: chapters[index], index: index) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text(mainPlayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.green.opacity(0.30)), in: Capsule())
            .disabled(resolvingIndex != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var mainPlayTitle: String {
        guard let index = resumeIndex else { return "播放" }
        let label = chapters[index].episodeLabel
        guard let entry = historyEntry else {
            return "播放 · 第 \(label) 集"
        }
        if entry.finished {
            return "重播 · 第 \(label) 集"
        }
        return "继续播放 · 第 \(label) 集"
    }

    /// 每组集数（对齐 Flutter episodeGroupSize = 30）
    private static let groupSize = 30

    private var groupCount: Int {
        (chapters.count + Self.groupSize - 1) / Self.groupSize
    }

    private func groupLabel(_ group: Int) -> String {
        let start = group * Self.groupSize
        let end = min(chapters.count, start + Self.groupSize) - 1
        guard chapters.indices.contains(start), chapters.indices.contains(end) else {
            return ""
        }
        let first = chapters[start].episodeLabel
        let last = chapters[end].episodeLabel
        return first == last ? first : "\(first)-\(last)"
    }

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(downloadMode ? "点选要下载的集数（\(chapters.count)）" : "选集（\(chapters.count)）")
                .font(.subheadline.weight(.semibold))
            if groupCount > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<groupCount, id: \.self) { group in
                            Button {
                                selectedGroup = group
                            } label: {
                                Text(groupLabel(group))
                                    .font(.footnote.weight(
                                        selectedGroup == group ? .semibold : .regular
                                    ))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(
                                selectedGroup == group
                                    ? .regular.tint(.green.opacity(0.35))
                                    : .regular,
                                in: Capsule()
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            let start = min(selectedGroup, max(0, groupCount - 1)) * Self.groupSize
            let end = min(chapters.count, start + Self.groupSize)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 76), spacing: 10)],
                spacing: 10
            ) {
                ForEach(Array(chapters[start..<end].enumerated()), id: \.offset) { offset, chapter in
                    let index = start + offset
                    Button {
                        if downloadMode {
                            Task { await enqueueDownload(chapter: chapter, index: index) }
                        } else {
                            Task { await play(chapter: chapter, index: index) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if resolvingIndex == index {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            if downloadMode {
                                Image(systemName: "arrow.down")
                                    .font(.caption2)
                            }
                            Text(chapter.episodeLabel)
                                .font(.footnote)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(resolvingIndex != nil)
                }
            }
            if chapters.isEmpty && !loading {
                Text("模块没有返回集数")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 数据

    private func loadDetail() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await provider.detail(sourceId: item.sourceId)
            drama = result.drama
            chapters = result.chapters
            // 默认停在续播集所在的那一组（Flutter 同）
            if let index = resumeIndex {
                selectedGroup = index / Self.groupSize
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func makeEntry(index: Int, position: Double, duration: Double) -> StationHistoryEntry {
        var entry = StationHistoryEntry()
        entry.dramaId = displayDrama.id
        entry.source = displayDrama.source.isEmpty ? provider.manifest.id : displayDrama.source
        entry.sourceId = displayDrama.sourceId
        entry.title = displayDrama.title
        entry.coverURL = displayDrama.coverURL
        entry.totalEpisodes = displayDrama.totalEpisodes
        entry.episodeIndex = index
        entry.episodeLabel = chapters.indices.contains(index)
            ? chapters[index].episodeLabel : "\(index + 1)"
        entry.position = position
        entry.duration = duration
        entry.updatedAt = Date()
        return entry
    }

    /// 组装一次播放会话：进度回调写历史，上下集/选集 handler
    /// 自行推进 session.index 并重新取址；取址失败把原始错误
    /// 写进 session.lastError，播放页会原样透出（不再静默吞掉）。
    private func makeSession(startIndex: Int) -> PlaybackSession {
        let session = PlaybackSession()
        session.index = startIndex
        session.canPrevious = startIndex > 0
        session.canNext = startIndex < chapters.count - 1
        session.displayTitle = displayDrama.title
        session.episodeLabels = chapters.map(\.episodeLabel)
        session.onProgress = { [self] session, position, duration in
            guard settings.recordHistory else { return }
            let entry = makeEntry(index: session.index, position: position, duration: duration)
            historyStore.record(entry)
        }
        session.onNext = { [self] session in
            let next = session.index + 1
            guard chapters.indices.contains(next) else { return nil }
            session.index = next
            session.canPrevious = true
            session.canNext = next < chapters.count - 1
            return await resolveRequest(index: next, startPosition: 0, session: session)
        }
        session.onPrevious = { [self] session in
            let previous = session.index - 1
            guard chapters.indices.contains(previous) else { return nil }
            session.index = previous
            session.canPrevious = previous > 0
            session.canNext = true
            return await resolveRequest(index: previous, startPosition: 0, session: session)
        }
        session.onSelectEpisode = { [self] session, index in
            guard chapters.indices.contains(index) else { return nil }
            session.index = index
            session.canPrevious = index > 0
            session.canNext = index < chapters.count - 1
            return await resolveRequest(index: index, startPosition: 0, session: session)
        }
        session.onRefresh = { [self] session in
            await resolveRequest(index: session.index, startPosition: 0, session: session)
        }
        return session
    }

    private func resolveRequest(
        index: Int, startPosition: Double, session: PlaybackSession
    ) async -> PlaybackRequest? {
        guard chapters.indices.contains(index) else { return nil }
        do {
            let plan = try await provider.resolveMedia(
                drama: displayDrama,
                chapter: chapters[index],
                index: index,
                total: chapters.count
            )
            guard let request = requestFromPlan(
                plan,
                title: "\(displayDrama.title) · \(chapters[index].episodeLabel)",
                start: startPosition
            ) else {
                session.lastError = "模块没有返回可播放地址"
                return nil
            }
            return request
        } catch {
            session.lastError = error.localizedDescription
            return nil
        }
    }

    /// 播放计划 → 播放请求：地址型与播放列表文本型都可播
    /// （文本型经播放引擎的资源代理在本地合成），全部画质
    /// 变体随请求带走，供清晰度切换与备用线路恢复使用。
    private func requestFromPlan(
        _ plan: MediaPlan, title: String, start: Double
    ) -> PlaybackRequest? {
        guard plan.isPlayable else { return nil }
        let variants = plan.variants.filter(\.isPlayable).map { variant in
            PlaybackVariant(
                quality: variant.quality,
                url: URL(string: variant.url),
                playlistText: variant.playlistText.isEmpty ? nil : variant.playlistText,
                headers: variant.headers
            )
        }
        return PlaybackRequest(
            url: URL(string: plan.url),
            playlistText: plan.playlistText.isEmpty ? nil : plan.playlistText,
            headers: plan.headers,
            title: title,
            startPosition: start,
            variants: variants,
            quality: plan.quality,
            expectedDuration: Double(plan.durationMs) / 1000
        )
    }

    private func play(chapter: ChapterItem, index: Int, startPosition: Double? = nil) async {
        resolvingIndex = index
        errorText = nil
        defer { resolvingIndex = nil }
        do {
            let plan = try await provider.resolveMedia(
                drama: displayDrama,
                chapter: chapter,
                index: index,
                total: chapters.count
            )
            // 续播点（对齐 Flutter _startAt）：显式传入优先；
            // 否则只有「正是历史里那一集（按集号比对）且没看完」
            // 才带进度，其余从头播
            var start = startPosition ?? 0
            if startPosition == nil,
               let entry = historyEntry, !entry.finished,
               Int(chapter.episodeLabel) != nil,
               Int(chapter.episodeLabel) == Int(entry.episodeLabel) {
                start = entry.position
            }
            if let request = requestFromPlan(
                plan,
                title: "\(displayDrama.title) · \(chapter.episodeLabel)",
                start: start
            ) {
                playSession = makeSession(startIndex: index)
                playRequest = request
                showPlayer = true
            } else {
                errorText = "模块没有返回可播放地址"
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func enqueueDownload(chapter: ChapterItem, index: Int) async {
        resolvingIndex = index
        defer { resolvingIndex = nil }
        do {
            _ = try await downloads.enqueueStation(
                provider: provider,
                drama: displayDrama,
                chapter: chapter,
                index: index,
                total: chapters.count
            )
            message = "已加入下载：第 \(chapter.episodeLabel) 集（在「下载」页看进度）"
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 秒数 → m:ss / h:mm:ss（与 Flutter 版 _clock 同格式）
func clockText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let rest = total % 60
    func two(_ part: Int) -> String { String(format: "%02d", part) }
    return hours > 0
        ? "\(hours):\(two(minutes)):\(two(rest))"
        : "\(two(minutes)):\(two(rest))"
}
