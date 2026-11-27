import Foundation

/// 播放调试日记，对齐 Flutter DiaryService：内存环形日志
/// （上限 500 条，条目格式 [HH:mm:ss.S] 消息），应用事件、
/// 模块日志、播放与下载失败都汇到这里，诊断页可查看、
/// 复制、导出与清空。不落盘（与 Flutter 一致，重启清空）。
final class DiaryStore: ObservableObject {
    static let shared = DiaryStore()

    @Published private(set) var entries: [String] = []

    static let limit = 500

    private init() {}

    var fullText: String { entries.joined(separator: "\n") }

    func add(_ message: String) {
        let entry = "[\(Self.clock(Date()))] \(message)"
        if Thread.isMainThread {
            append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.append(entry)
            }
        }
    }

    func clear() {
        entries = []
    }

    private func append(_ entry: String) {
        entries.append(entry)
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    private static func clock(_ date: Date) -> String {
        let components = Calendar.current.dateComponents(
            [.hour, .minute, .second, .nanosecond], from: date
        )
        return String(
            format: "%02d:%02d:%02d.%d",
            components.hour ?? 0, components.minute ?? 0,
            components.second ?? 0, (components.nanosecond ?? 0) / 100_000_000
        )
    }
}
