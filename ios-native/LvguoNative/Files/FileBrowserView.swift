import SwiftUI

/// 文件浏览页：数据源是统一的 FileSourceClient（WebDAV / FTP /
/// 天翼·移动原生都走这个接口，页面不感知差异）。文件夹点一下
/// 进一层，顶部写当前路径；视频文件点击播放，同文件夹的全部
/// 视频组成播放列表供播放页做上/下一（对齐 Flutter
/// FileBrowserPage）。视频行另有下载按钮（文件源文件下载）。
struct FileBrowserView: View {
    let source: FileSource
    var path: String? = nil
    var label: String? = nil

    @EnvironmentObject private var fileStore: FileSourceStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var entries: [FileEntry]?
    @State private var errorText: String?
    @State private var loading = true
    @State private var notice: String?
    @State private var playRequest: PlaybackRequest?
    @State private var playSession: PlaybackSession?
    @State private var showPlayer = false

    private var client: FileSourceClient { createFileSourceClient(source) }

    private var pathLabel: String {
        if let label, !label.isEmpty { return label }
        guard let path else { return "/" }
        return path.removingPercentEncoding ?? path
    }

    var body: some View {
        Group {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                ContentUnavailableView {
                    Label("无法打开这个文件源", systemImage: "cloud.slash")
                } description: {
                    Text(errorText)
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else if let entries, entries.isEmpty {
                ContentUnavailableView(
                    "这个文件夹是空的",
                    systemImage: "folder",
                    description: Text("没有可显示的文件夹或文件。")
                )
            } else if let entries {
                List {
                    if let notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
                .listStyle(.plain)
                .refreshable { await load() }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(pathLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let playRequest {
                PlayerPage(request: playRequest, session: playSession)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: FileEntry) -> some View {
        if entry.isDirectory {
            NavigationLink {
                FileBrowserView(
                    source: source,
                    path: entry.href,
                    label: source.nativeMode ? entry.name : nil
                )
            } label: {
                entryLabel(entry, progress: nil)
            }
        } else {
            HStack {
                Button {
                    if entry.isVideo {
                        Task { await play(entry) }
                    } else {
                        notice = "暂不支持播放这个文件类型"
                    }
                } label: {
                    entryLabel(
                        entry,
                        progress: entry.isVideo
                            ? fileStore.progressFor(client.progressKey(entry)) : nil
                    )
                }
                .buttonStyle(.plain)
                if entry.isVideo {
                    Button {
                        Task { await enqueueDownload(entry) }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func entryLabel(_ entry: FileEntry, progress: FileProgress?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory
                ? "folder.fill"
                : (entry.isVideo ? "movieclapper" : "doc"))
                .foregroundStyle(entry.isDirectory ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle(entry, progress: progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: entry.isDirectory ? "chevron.right" : "play.circle")
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func subtitle(_ entry: FileEntry, progress: FileProgress?) -> String {
        if entry.isDirectory { return "文件夹" }
        if entry.isVideo {
            var parts: [String] = []
            if entry.size > 0 { parts.append(sizeLabel(entry.size)) }
            if let progress, !progress.finished, progress.position > 0 {
                parts.append("看到 \(clockText(progress.position))")
            }
            return parts.isEmpty ? "视频" : parts.joined(separator: " · ")
        }
        return "文件"
    }

    // MARK: - 数据与播放

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            entries = try await client.list(path)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 组装文件播放会话：同文件夹全部视频为列表，进度按
    /// progressKey 写 FileSourceStore（对齐 Flutter FilePlayerPage
    /// 的记录方式：标题/来源名/来源ID/最近地址/定位符）
    private func makeSession(videos: [FileEntry], startIndex: Int) -> PlaybackSession {
        let session = PlaybackSession()
        let client = self.client
        session.index = startIndex
        session.canPrevious = startIndex > 0
        session.canNext = startIndex < videos.count - 1
        session.displayTitle = videos.indices.contains(startIndex)
            ? videos[startIndex].name : source.name
        session.episodeLabels = videos.map(\.name)
        session.onProgress = { [fileStore, source] session, position, duration in
            guard videos.indices.contains(session.index) else { return }
            let entry = videos[session.index]
            fileStore.saveProgress(
                client.progressKey(entry),
                position: position,
                duration: duration,
                title: entry.name,
                sourceName: source.name,
                sourceId: source.id,
                ref: entry.href
            )
        }
        func request(for index: Int) async -> PlaybackRequest? {
            guard videos.indices.contains(index) else { return nil }
            let entry = videos[index]
            do {
                let target = try await client.target(entry)
                fileStore.saveProgress(
                    client.progressKey(entry),
                    position: fileStore.progressFor(client.progressKey(entry))?.position ?? 0,
                    duration: fileStore.progressFor(client.progressKey(entry))?.duration ?? 0,
                    title: entry.name,
                    sourceName: source.name,
                    sourceId: source.id,
                    url: target.url,
                    ref: entry.href
                )
                guard let url = URL(string: target.url) else { return nil }
                return PlaybackRequest(url: url, headers: target.headers, title: entry.name)
            } catch {
                return nil
            }
        }
        session.onNext = { session in
            let next = session.index + 1
            guard videos.indices.contains(next) else { return nil }
            session.index = next
            session.canPrevious = true
            session.canNext = next < videos.count - 1
            session.displayTitle = videos[next].name
            return await request(for: next)
        }
        session.onPrevious = { session in
            let previous = session.index - 1
            guard videos.indices.contains(previous) else { return nil }
            session.index = previous
            session.canPrevious = previous > 0
            session.canNext = true
            session.displayTitle = videos[previous].name
            return await request(for: previous)
        }
        session.onSelectEpisode = { session, index in
            guard videos.indices.contains(index) else { return nil }
            session.index = index
            session.canPrevious = index > 0
            session.canNext = index < videos.count - 1
            session.displayTitle = videos[index].name
            return await request(for: index)
        }
        session.onRefresh = { session in
            await request(for: session.index)
        }
        return session
    }

    private func play(_ entry: FileEntry) async {
        let videos = (entries ?? []).filter { $0.isVideo }
        let index = videos.firstIndex(of: entry) ?? 0
        do {
            let target = try await client.target(entry)
            guard let url = URL(string: target.url) else {
                notice = "播放地址无效"
                return
            }
            var start: Double = 0
            if let progress = fileStore.progressFor(client.progressKey(entry)),
               !progress.finished {
                start = progress.position
            }
            playSession = makeSession(videos: videos, startIndex: index)
            playRequest = PlaybackRequest(
                url: url, headers: target.headers,
                title: entry.name, startPosition: start
            )
            showPlayer = true
        } catch {
            notice = error.localizedDescription
        }
    }

    private func enqueueDownload(_ entry: FileEntry) async {
        do {
            _ = try await downloads.enqueueFile(source: source, entry: entry)
            notice = "已加入下载：\(entry.name)（在「下载」页看进度）"
        } catch {
            notice = error.localizedDescription
        }
    }
}

/// 文件大小标签（对齐 Flutter _sizeLabel）
func sizeLabel(_ bytes: Int64) -> String {
    let gb = 1024.0 * 1024 * 1024
    let mb = 1024.0 * 1024
    if Double(bytes) >= gb {
        return String(format: "%.1f GB", Double(bytes) / gb)
    }
    if Double(bytes) >= mb {
        return String(format: "%.0f MB", Double(bytes) / mb)
    }
    return String(format: "%.0f KB", Double(bytes) / 1024)
}

/// 打开一个文件源：HTTP 拉取直接播那条直链；其余进文件浏览页
/// （对齐 Flutter openFileSource）
struct FileSourceOpenView: View {
    let source: FileSource

    @EnvironmentObject private var fileStore: FileSourceStore
    @State private var playRequest: PlaybackRequest?
    @State private var playSession: PlaybackSession?
    @State private var showPlayer = false
    @State private var errorText: String?

    var body: some View {
        if source.type == .http {
            VStack(spacing: 16) {
                Image(systemName: "link")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(source.name)
                    .font(.headline)
                Text(source.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    playHttp()
                } label: {
                    Label("播放", systemImage: "play.fill")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.glass)
            }
            .padding()
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showPlayer) {
                if let playRequest {
                    PlayerPage(request: playRequest, session: playSession)
                }
            }
        } else {
            FileBrowserView(source: source)
        }
    }

    private func playHttp() {
        guard let url = URL(string: source.url) else {
            errorText = "地址无效"
            return
        }
        let session = PlaybackSession()
        session.displayTitle = source.name
        session.onRefresh = { [source] _ in
            guard let url = URL(string: source.url) else { return nil }
            return PlaybackRequest(url: url, title: source.name)
        }
        session.onProgress = { [fileStore, source] _, position, duration in
            fileStore.saveProgress(
                source.url,
                position: position,
                duration: duration,
                title: source.name,
                sourceName: source.name,
                sourceId: source.id,
                url: source.url,
                ref: ""
            )
        }
        var start: Double = 0
        if let progress = fileStore.progressFor(source.url), !progress.finished {
            start = progress.position
        }
        playSession = session
        playRequest = PlaybackRequest(
            url: url, title: source.name, startPosition: start
        )
        showPlayer = true
    }
}
