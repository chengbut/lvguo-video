import Foundation

/// App 数据目录：与 ModuleStore 同一个位置
/// （Application Support/LvguoNative/），全 App 的落盘数据都放这里。
enum AppData {
    static var directory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("LvguoNative")
    }

    /// 旧 Flutter 版的 Application Support 根目录（Go 核心 dataDir 与
    /// LocalStore 文件库都在这一层），迁移时只读。
    static var legacySupportDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
    }

    static func readJSON(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func readJSONDictionary(_ url: URL) -> [String: Any]? {
        readJSON(url) as? [String: Any]
    }

    static func writeJSON(_ object: Any, to url: URL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func isoString(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// 兼容 Dart DateTime.toIso8601String 的输出（带/不带毫秒、带时区偏移）
    static func parseISODate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let date = isoFormatter.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // Dart 常见形态：2026-11-27T08:00:00.000（无时区，按本地时间理解）
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
        ] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
}

// MARK: - 设置

/// 播放设置：键名与 Flutter 版 PlaybackPreferences 的 JSON 一致
/// （users/<id>/settings.json 的 playback 子对象），迁移可直接对位。
/// 只搬与原生播放器相关的项：默认静音、自动连播、记录历史、
/// 保持常亮、跳过片头/片尾、倍速。
@MainActor
final class SettingsStore: ObservableObject {
    @Published var startMuted: Bool { didSet { save() } }
    @Published var autoAdvance: Bool { didSet { save() } }
    @Published var recordHistory: Bool { didSet { save() } }
    @Published var keepScreenAwake: Bool { didSet { save() } }
    @Published var skipIntroSeconds: Int { didSet { save() } }
    @Published var skipOutroSeconds: Int { didSet { save() } }
    @Published var speed: Double { didSet { save() } }

    private let file: URL
    private var loading = true

    init(dataDirectory: URL) {
        file = dataDirectory.appendingPathComponent("settings.json")
        let dict = AppData.readJSONDictionary(file) ?? [:]
        startMuted = JSON.dictBool(dict["startMuted"])
        autoAdvance = dict["autoAdvance"] == nil ? true : JSON.dictBool(dict["autoAdvance"])
        recordHistory = dict["recordHistory"] == nil ? true : JSON.dictBool(dict["recordHistory"])
        keepScreenAwake = dict["keepScreenAwake"] == nil ? true : JSON.dictBool(dict["keepScreenAwake"])
        skipIntroSeconds = JSON.dictInt(dict["skipIntroSeconds"])
        skipOutroSeconds = JSON.dictInt(dict["skipOutroSeconds"])
        let storedSpeed = (dict["speed"] as? NSNumber)?.doubleValue ?? 1.0
        speed = storedSpeed > 0 ? storedSpeed : 1.0
        loading = false
    }

    private func save() {
        guard !loading else { return }
        AppData.writeJSON([
            "startMuted": startMuted,
            "autoAdvance": autoAdvance,
            "recordHistory": recordHistory,
            "keepScreenAwake": keepScreenAwake,
            "skipIntroSeconds": skipIntroSeconds,
            "skipOutroSeconds": skipOutroSeconds,
            "speed": speed,
        ], to: file)
    }
}

// MARK: - 站源观看历史

/// 站源历史一条：字段语义对齐 Flutter 版 WatchEntry
/// （drama + 集号 + position/duration 秒 + updatedAt）。
struct StationHistoryEntry: Identifiable {
    var dramaId: String = ""       // "source:sourceId"
    var source: String = ""        // 模块 id
    var sourceId: String = ""
    var title: String = ""
    var coverURL: String = ""
    var totalEpisodes: Int = 0
    var episodeIndex: Int = 0      // 0 基下标（详情页集数列表位置）
    var episodeLabel: String = ""  // 集号文本（对应 WatchEntry.episode）
    var position: Double = 0
    var duration: Double = 0
    var updatedAt: Date = Date()

    var id: String { dramaId }
    var finished: Bool { duration > 1 && position >= duration - 1 }

    func toJSON() -> [String: Any] {
        [
            "dramaId": dramaId,
            "source": source,
            "sourceId": sourceId,
            "title": title,
            "coverURL": coverURL,
            "totalEpisodes": totalEpisodes,
            "episodeIndex": episodeIndex,
            "episodeLabel": episodeLabel,
            "position": position,
            "duration": duration,
            "updatedAt": AppData.isoString(updatedAt),
        ]
    }

    static func fromJSON(_ dict: [String: Any]) -> StationHistoryEntry? {
        var entry = StationHistoryEntry()
        entry.dramaId = JSON.dictString(dict["dramaId"])
        guard !entry.dramaId.isEmpty else { return nil }
        entry.source = JSON.dictString(dict["source"])
        entry.sourceId = JSON.dictString(dict["sourceId"])
        entry.title = JSON.dictString(dict["title"])
        entry.coverURL = JSON.dictString(dict["coverURL"])
        entry.totalEpisodes = JSON.dictInt(dict["totalEpisodes"])
        entry.episodeIndex = JSON.dictInt(dict["episodeIndex"])
        entry.episodeLabel = JSON.dictString(dict["episodeLabel"])
        entry.position = (dict["position"] as? NSNumber)?.doubleValue ?? 0
        entry.duration = (dict["duration"] as? NSNumber)?.doubleValue ?? 0
        entry.updatedAt = AppData.parseISODate(dict["updatedAt"]) ?? Date(timeIntervalSince1970: 0)
        return entry
    }

    var dramaItem: DramaItem {
        DramaItem(
            id: dramaId,
            source: source,
            sourceId: sourceId,
            title: title,
            desc: "",
            coverURL: coverURL,
            totalEpisodes: totalEpisodes
        )
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [StationHistoryEntry] = []

    private let file: URL
    static let limit = 300

    init(dataDirectory: URL) {
        file = dataDirectory.appendingPathComponent("history.json")
        if let rows = AppData.readJSON(file) as? [Any] {
            entries = rows
                .compactMap { ($0 as? [String: Any]).flatMap(StationHistoryEntry.fromJSON) }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func entry(forDramaId dramaId: String) -> StationHistoryEntry? {
        entries.first { $0.dramaId == dramaId }
    }

    func record(_ entry: StationHistoryEntry) {
        guard entry.position >= 0.1 || entry.duration > 0 else { return }
        var next = entries.filter { $0.dramaId != entry.dramaId }
        next.insert(entry, at: 0)
        entries = Array(next.prefix(Self.limit))
        save()
    }

    func remove(dramaId: String) {
        entries.removeAll { $0.dramaId == dramaId }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        AppData.writeJSON(entries.map { $0.toJSON() }, to: file)
    }
}
