import SwiftUI

/// 详情页：模块 detail() 拉剧目信息与集数列表，
/// 点集 → resolveMedia() 拿播放计划 → PlayerPage 播放（headers 沿用一期注入）。
struct DramaDetailView: View {
    let provider: ModuleProvider
    let item: DramaItem

    @State private var drama: DramaItem?
    @State private var chapters: [ChapterItem] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var resolvingIndex: Int?
    @State private var playRequest: PlaybackRequest?
    @State private var showPlayer = false

    private var displayDrama: DramaItem { drama ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .glassEffect(
                            .regular.tint(.red.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
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
        .task { await loadDetail() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let playRequest {
                PlayerPage(request: playRequest)
            }
        }
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
            .frame(width: 96, height: 128)
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

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选集（\(chapters.count)）")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 76), spacing: 10)],
                spacing: 10
            ) {
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        Task { await play(chapter: chapter, index: index) }
                    } label: {
                        HStack(spacing: 4) {
                            if resolvingIndex == index {
                                ProgressView()
                                    .controlSize(.small)
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
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func play(chapter: ChapterItem, index: Int) async {
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
            if !plan.url.isEmpty, let url = URL(string: plan.url) {
                playRequest = PlaybackRequest(
                    url: url,
                    headers: plan.headers,
                    title: "\(displayDrama.title) · \(chapter.episodeLabel)"
                )
                showPlayer = true
            } else if !plan.playlistText.isEmpty {
                // 已知限制：模块只给 m3u8 文本（Go 侧走本地代理）时原生版暂不能直接播
                errorText = "模块只返回了播放列表文本，原生版暂不支持这类播放（已知限制）"
            } else {
                errorText = "模块没有返回可播放地址"
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
