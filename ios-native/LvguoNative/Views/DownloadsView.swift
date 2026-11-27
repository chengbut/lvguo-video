import SwiftUI

/// 下载页：任务列表（进度/完成/失败/删除），下完点开本地播放。
/// 任务重试时由 DownloadManager 的取址器重新取址（App 启动
/// 时在 installResolvers 里注入：站源 resolveMedia、文件源
/// 定位符取址、FTP 走 RETR 通道）。
struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager

    @State private var playRequest: PlaybackRequest?
    @State private var showPlayer = false
    @State private var notice: String?
    @State private var pendingDelete: DownloadJob?
    @State private var tab = 0

    /// 页签对齐 Flutter downloads_page.dart：「下载中 N」「已下载 N」
    /// （Flutter 还有「合并 N」，原生没有合并功能，不摆假页签）
    private var activeJobs: [DownloadJob] {
        downloads.jobs.filter { $0.state != "completed" }
    }

    private var completedJobs: [DownloadJob] {
        downloads.jobs.filter { $0.state == "completed" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("下载分类", selection: $tab) {
                    Text("下载中 \(activeJobs.count)").tag(0)
                    Text("已下载 \(completedJobs.count)").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                let visible = tab == 0 ? activeJobs : completedJobs
                if visible.isEmpty {
                    ContentUnavailableView(
                        tab == 0 ? "暂无下载中的任务" : "暂无已下载",
                        systemImage: "arrow.down.circle",
                        description: Text("在详情页点「下载选集」选集数，或在文件浏览页点下载按钮。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if let notice {
                            Text(notice)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visible) { job in
                            jobRow(job)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("下载")
            .fullScreenCover(isPresented: $showPlayer) {
                if let playRequest {
                    PlayerPage(request: playRequest)
                }
            }
            .confirmationDialog(
                "删除下载「\(pendingDelete?.title ?? "")」？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let target = pendingDelete {
                        downloads.delete(target)
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
        }
    }

    private func jobRow(_ job: DownloadJob) -> some View {
        HStack(spacing: 12) {
            Image(systemName: job.kind == "station" ? "tv" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle(job))
                    .font(.caption)
                    .foregroundStyle(job.state == "failed" ? .red : .secondary)
                    .lineLimit(2)
                if job.state == "downloading" || job.state == "queued" {
                    ProgressView(value: job.progress)
                        .tint(.green)
                }
            }
            Spacer()
            switch job.state {
            case "completed":
                Button {
                    play(job)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            case "failed":
                Button {
                    downloads.retry(job)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.title2)
                }
                .buttonStyle(.plain)
            default:
                EmptyView()
            }
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) { pendingDelete = job }
        }
    }

    private func subtitle(_ job: DownloadJob) -> String {
        var parts = [job.subtitle, job.stateLabel]
        if job.state == "failed", !job.error.isEmpty {
            parts.append(job.error)
        }
        if job.state == "downloading" {
            if job.isHLS, job.hlsTotal > 0 {
                parts.append("分片 \(job.hlsDone)/\(job.hlsTotal)")
            } else if job.bytes > 0 {
                parts.append(sizeLabel(job.bytes))
            }
        }
        if job.state == "completed", job.bytes > 0 {
            parts.append(sizeLabel(job.bytes))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func play(_ job: DownloadJob) {
        if job.isHLS {
            guard let url = LocalFileServer.shared.url(
                jobId: job.id, fileName: "playlist.m3u8",
                root: downloads.downloadsDirectory
            ) else {
                notice = "本地播放服务启动失败"
                return
            }
            playRequest = PlaybackRequest(
                url: url, title: "\(job.title) \(job.subtitle)"
            )
            showPlayer = true
            return
        }
        guard let fileURL = downloads.localFileURL(job) else {
            notice = "本地文件不存在，可能已被删除"
            return
        }
        playRequest = PlaybackRequest(
            url: fileURL, title: "\(job.title) \(job.subtitle)"
        )
        showPlayer = true
    }
}
