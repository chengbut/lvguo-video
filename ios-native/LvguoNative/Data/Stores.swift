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
/// 覆盖与原生播放器相关的全部项：倍速、自动连播（仅字段与播放
/// 逻辑，Flutter 设置页没有这个开关条目）、记录历史、保持常亮、
/// 跳过片头/片尾、默认静音、双击快进、滑动调节、时钟/网速显示、
/// 长按倍速、自动画中画、默认画面比例。
/// 弹幕一组与 preload/backgroundPlayback 等 mpv 专属项不在此列
/// （JS 模块源在 Flutter 版同样不支持弹幕，见 README 对齐表）。
@MainActor
final class SettingsStore: ObservableObject {
    @Published var startMuted: Bool { didSet { save() } }
    @Published var autoAdvance: Bool { didSet { save() } }
    @Published var recordHistory: Bool { didSet { save() } }
    @Published var keepScreenAwake: Bool { didSet { save() } }
    @Published var skipIntroSeconds: Int { didSet { save() } }
    @Published var skipOutroSeconds: Int { didSet { save() } }
    @Published var speed: Double { didSet { save() } }
    @Published var doubleTapSeek: Bool { didSet { save() } }
    @Published var swipeLevels: Bool { didSet { save() } }
    @Published var swipeEpisodes: Bool { didSet { save() } }
    @Published var showClock: Bool { didSet { save() } }
    @Published var showNetworkSpeed: Bool { didSet { save() } }
    @Published var autoPictureInPicture: Bool { didSet { save() } }
    @Published var boostSpeed: Double { didSet { save() } }
    @Published var videoFit: String { didSet { save() } }
    /// 自动画中画默认开的一次性迁移标记（修复轮 13）：
    /// 随 save() 一起落盘；缺失时把 autoPictureInPicture
    /// 强制置 true 一次并写标记，之后以用户设置为准
    private var autoPipDefaultV2Applied: Bool

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
        doubleTapSeek = dict["doubleTapSeek"] == nil ? true : JSON.dictBool(dict["doubleTapSeek"])
        swipeLevels = dict["swipeLevels"] == nil ? true : JSON.dictBool(dict["swipeLevels"])
        swipeEpisodes = JSON.dictBool(dict["swipeEpisodes"])
        showClock = dict["showClock"] == nil ? true : JSON.dictBool(dict["showClock"])
        showNetworkSpeed = dict["showNetworkSpeed"] == nil ? true : JSON.dictBool(dict["showNetworkSpeed"])
        // 修复轮 12 用户拍板：自动画中画默认开（仅键缺失时生效，已存设置不受影响）
        // 修复轮 13 一次性迁移：1.6 的「默认开」对从 1.5 覆盖
        // 安装、已存过 autoPictureInPicture=false 的用户不生效
        // （键已存在、走的不是缺省分支）——迁移标记缺失时
        // 强制置 true 一次并立即落盘写标记；标记在时以用户
        // 后来改的设置为准，不再干预
        let pipMigrationApplied = dict["autoPipDefaultV2Applied"] != nil
        autoPipDefaultV2Applied = pipMigrationApplied
        if pipMigrationApplied {
            autoPictureInPicture = dict["autoPictureInPicture"] == nil ? true : JSON.dictBool(dict["autoPictureInPicture"])
        } else {
            autoPictureInPicture = true
            autoPipDefaultV2Applied = true
        }
        let storedBoost = (dict["boostSpeed"] as? NSNumber)?.doubleValue ?? 2.0
        boostSpeed = storedBoost > 0 ? storedBoost : 2.0
        let storedFit = JSON.dictString(dict["videoFit"])
        videoFit = VideoFitMode(rawValue: storedFit) != nil ? storedFit : VideoFitMode.auto.rawValue
        loading = false
        if !pipMigrationApplied {
            // 迁移结果（值 + 标记）立即落盘，保证「只强制一次」
            save()
        }
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
            "doubleTapSeek": doubleTapSeek,
            "swipeLevels": swipeLevels,
            "swipeEpisodes": swipeEpisodes,
            "showClock": showClock,
            "showNetworkSpeed": showNetworkSpeed,
            "autoPictureInPicture": autoPictureInPicture,
            "autoPipDefaultV2Applied": autoPipDefaultV2Applied,
            "boostSpeed": boostSpeed,
            "videoFit": videoFit,
        ], to: file)
    }
}

/// 画面比例，对齐 Flutter VideoFit（name 与 label 逐项一致）
enum VideoFitMode: String, CaseIterable {
    case auto
    case stretch
    case crop
    case fitWidth
    case fitHeight
    case original
    case ratio4x3
    case ratio16x9

    var label: String {
        switch self {
        case .auto: return "自动"
        case .stretch: return "拉伸"
        case .crop: return "裁切"
        case .fitWidth: return "等宽"
        case .fitHeight: return "等高"
        case .original: return "原始"
        case .ratio4x3: return "4:3"
        case .ratio16x9: return "16:9"
        }
    }
}

/// 续播集匹配，逐行对齐 Flutter follow_state.dart 的 resumeEpisodeIndex：
/// 按「集号」在最新选集里找位置——先精确匹配集号；没有精确的，
/// 取第一个集号更大的；再没有（看到的是旧的当前集）取它本身；
/// 都没有则最后一集。绝不能用迁移来的数组下标直接定位：
/// 集号与数组位置并不总是一一对应，下标越界正是真机首测
/// 「这一集已经不存在了」的根因。
enum HistoryResume {
    /// 返回目标集在 chapters 中的下标；chapters 为空返回 nil。
    /// 集号取 ChapterItem.episodeLabel 的整数值（对应 Go 的
    /// Chapter.currentEpisode / Flutter 的 episode.number），
    /// 非数字标签（如「番外」）不参与匹配，与 Flutter 一致。
    static func chapterIndex(
        chapters: [ChapterItem], episodeNumber: Int, finished: Bool
    ) -> Int? {
        guard !chapters.isEmpty else { return nil }
        var foundCurrent: Int?
        for (index, chapter) in chapters.enumerated() {
            let label = chapter.episodeLabel.trimmingCharacters(in: .whitespaces)
            guard let number = Int(label) else { continue }
            if number == episodeNumber {
                if !finished {
                    return index
                }
                foundCurrent = index
            } else if number > episodeNumber, foundCurrent == nil {
                return index
            }
        }
        if let foundCurrent {
            return foundCurrent
        }
        return chapters.count - 1
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
