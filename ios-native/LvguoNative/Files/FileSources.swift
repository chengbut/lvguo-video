import Foundation

/// 文件源类型：与 Flutter 版 FileSourceType 一一对应（name 即落盘值）。
enum FileSourceType: String, CaseIterable, Identifiable {
    case tianyi
    case mobile
    case quark
    case webdav
    case http
    case ftp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tianyi: return "天翼云盘"
        case .mobile: return "中国移动云盘"
        case .quark: return "夸克网盘"
        case .webdav: return "WebDAV"
        case .http: return "HTTP 拉取"
        case .ftp: return "FTP"
        }
    }

    static func byName(_ name: String) -> FileSourceType {
        FileSourceType(rawValue: name) ?? .webdav
    }
}

/// 文件源的接入方式（FileSource.mode 的两个取值，与 Dart 常量一致）
enum FileSourceMode {
    static let webDav = "webdav"
    static let native = "native"
}

/// 一个文件源：字段与 JSON 形状与 Dart FileSource.toJson 完全一致，
/// 迁移时可直接搬运。
struct FileSource: Identifiable, Equatable {
    var id: String
    var name: String
    var type: FileSourceType
    var server: String = ""
    var username: String = ""
    var password: String = ""
    var url: String = ""
    var mode: String = FileSourceMode.webDav
    /// 原生登录凭据：天翼/夸克是 Cookie 整段；移动是 authorization 令牌
    /// （或整段 Cookie，客户端按形态自动判断）。
    var cookie: String = ""
    var port: Int = 0
    var path: String = ""

    /// 仅天翼/移动/夸克且 mode 为 native 时走原生客户端
    var nativeMode: Bool {
        (type == .tianyi || type == .mobile || type == .quark)
            && mode == FileSourceMode.native
    }

    var usesWebDav: Bool {
        !nativeMode && type != .http && type != .ftp
    }

    var host: String {
        if nativeMode {
            switch type {
            case .tianyi: return "cloud.189.cn"
            case .quark: return "pan.quark.cn"
            default: return "yun.139.com"
            }
        }
        if type == .ftp {
            let effective = port == 0 ? 21 : port
            return effective == 21 ? server : "\(server):\(effective)"
        }
        let raw = usesWebDav ? server : url
        if let uri = URL(string: raw), let host = uri.host, !host.isEmpty {
            return host
        }
        return raw
    }

    var authHeaders: [String: String] {
        guard !username.isEmpty else { return [:] }
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }

    /// 原生凭据宽容清洗：去掉 "Cookie:" 前缀与首尾空白/引号（同 Dart）
    var credential: String {
        var value = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    func toJSON() -> [String: Any] {
        [
            "id": id, "name": name, "type": type.rawValue,
            "server": server, "username": username, "password": password,
            "url": url, "mode": mode, "cookie": cookie,
            "port": port, "path": path,
        ]
    }

    static func fromJSON(_ dict: [String: Any]) -> FileSource {
        FileSource(
            id: JSON.dictString(dict["id"]),
            name: JSON.dictString(dict["name"]),
            type: FileSourceType.byName(JSON.dictString(dict["type"])),
            server: JSON.dictString(dict["server"]),
            username: JSON.dictString(dict["username"]),
            password: JSON.dictString(dict["password"]),
            url: JSON.dictString(dict["url"]),
            mode: JSON.dictString(dict["mode"]).isEmpty
                ? FileSourceMode.webDav : JSON.dictString(dict["mode"]),
            cookie: JSON.dictString(dict["cookie"]),
            port: JSON.dictInt(dict["port"]),
            path: JSON.dictString(dict["path"])
        )
    }
}

/// 文件播放进度：字段与 Dart FileProgress.toJson 完全一致。
struct FileProgress {
    var position: Double = 0
    var duration: Double = 0
    var updatedAt: Date = Date()
    var title: String = ""
    var sourceName: String = ""
    var sourceId: String = ""
    var url: String = ""
    var ref: String = ""

    var finished: Bool { duration > 1 && position >= duration - 1 }

    func toJSON() -> [String: Any] {
        [
            "position": position, "duration": duration,
            "updatedAt": AppData.isoString(updatedAt),
            "title": title, "sourceName": sourceName, "sourceId": sourceId,
            "url": url, "ref": ref,
        ]
    }

    static func fromJSON(_ dict: [String: Any]) -> FileProgress {
        var progress = FileProgress()
        progress.position = (dict["position"] as? NSNumber)?.doubleValue ?? 0
        progress.duration = (dict["duration"] as? NSNumber)?.doubleValue ?? 0
        progress.updatedAt = AppData.parseISODate(dict["updatedAt"]) ?? Date(timeIntervalSince1970: 0)
        progress.title = JSON.dictString(dict["title"])
        progress.sourceName = JSON.dictString(dict["sourceName"])
        progress.sourceId = JSON.dictString(dict["sourceId"])
        progress.url = JSON.dictString(dict["url"])
        progress.ref = JSON.dictString(dict["ref"])
        return progress
    }
}

/// 历史页「文件」分组的一行：进度键 + 记录本体（同 Dart FileHistoryRecord）
struct FileHistoryRecord: Identifiable {
    var key: String
    var progress: FileProgress
    var id: String { key }
}

/// 文件源与文件播放进度的存储：原生侧落盘为
/// LvguoNative/file-sources.json（数组）与 file-progress.json（键→记录），
/// 内容形状与 Flutter 版 SharedPreferences 里的
/// fileSources.v1 / fileProgress.v1 一致，迁移即格式搬运。
@MainActor
final class FileSourceStore: ObservableObject {
    @Published private(set) var sources: [FileSource] = []
    @Published private(set) var progress: [String: FileProgress] = [:]

    private let sourcesFile: URL
    private let progressFile: URL
    static let progressLimit = 300

    init(dataDirectory: URL) {
        sourcesFile = dataDirectory.appendingPathComponent("file-sources.json")
        progressFile = dataDirectory.appendingPathComponent("file-progress.json")
        if let rows = AppData.readJSON(sourcesFile) as? [Any] {
            sources = rows.compactMap { ($0 as? [String: Any]).map(FileSource.fromJSON) }
        }
        if let dict = AppData.readJSON(progressFile) as? [String: Any] {
            var loaded: [String: FileProgress] = [:]
            for (key, value) in dict {
                if let row = value as? [String: Any] {
                    loaded[key] = FileProgress.fromJSON(row)
                }
            }
            progress = loaded
        }
    }

    func sourceById(_ id: String) -> FileSource? {
        sources.first { $0.id == id }
    }

    /// 全部文件播放记录，按最近播放倒序（历史页「文件」分组用）
    var records: [FileHistoryRecord] {
        progress
            .map { FileHistoryRecord(key: $0.key, progress: $0.value) }
            .sorted { $0.progress.updatedAt > $1.progress.updatedAt }
    }

    func add(_ source: FileSource) {
        sources.append(source)
        saveSources()
    }

    func remove(id: String) {
        sources.removeAll { $0.id == id }
        saveSources()
    }

    func progressFor(_ key: String) -> FileProgress? {
        progress[key]
    }

    func saveProgress(
        _ key: String,
        position: Double,
        duration: Double,
        title: String? = nil,
        sourceName: String? = nil,
        sourceId: String? = nil,
        url: String? = nil,
        ref: String? = nil
    ) {
        let previous = progress[key]
        var record = FileProgress()
        record.position = position
        record.duration = duration
        record.updatedAt = Date()
        record.title = title ?? previous?.title ?? ""
        record.sourceName = sourceName ?? previous?.sourceName ?? ""
        record.sourceId = sourceId ?? previous?.sourceId ?? ""
        record.url = url ?? previous?.url ?? ""
        record.ref = ref ?? previous?.ref ?? ""
        progress[key] = record
        if progress.count > Self.progressLimit {
            let sorted = progress.sorted { $0.value.updatedAt > $1.value.updatedAt }
            progress = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.progressLimit).map { ($0.key, $0.value) })
        }
        saveProgressMap()
    }

    func removeProgress(_ key: String) {
        guard progress.removeValue(forKey: key) != nil else { return }
        saveProgressMap()
    }

    func clearProgress() {
        guard !progress.isEmpty else { return }
        progress = [:]
        saveProgressMap()
    }

    private func saveSources() {
        AppData.writeJSON(sources.map { $0.toJSON() }, to: sourcesFile)
    }

    private func saveProgressMap() {
        AppData.writeJSON(
            progress.mapValues { $0.toJSON() }, to: progressFile
        )
    }
}

func newFileSourceId() -> String {
    "\(Int(Date().timeIntervalSince1970 * 1_000_000))"
}

/// 文件源目录里的一项：href 是定位符——WebDAV 是服务器绝对路径
/// （URL 编码形态），FTP 是绝对路径（原始形态），原生网盘是文件 ID。
struct FileEntry: Identifiable, Equatable {
    var name: String
    var href: String
    var isDirectory: Bool
    var contentType: String = ""
    var size: Int64 = 0

    var id: String { href.isEmpty ? name : href }

    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "avi", "ts", "m3u8", "webm", "flv", "rmvb",
    ]

    var isVideo: Bool {
        if isDirectory { return false }
        guard let dot = name.lastIndex(of: ".") else {
            return contentType.hasPrefix("video/")
        }
        let ext = name[name.index(after: dot)...].lowercased()
        return Self.videoExtensions.contains(ext)
    }
}

/// 一次取址结果：可直接交给播放器的地址 + 请求头。
/// 原生网盘的地址有时效，每次点播现取，不缓存。
struct FilePlayTarget {
    var url: String
    var headers: [String: String] = [:]
}

/// 文件源错误：文案直接展示给用户，尽量带服务器原始返回片段（同 Dart）。
struct FileSourceFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// 把服务器返回压成一行短摘（同 Dart excerptText）
func excerptText(_ text: String) -> String {
    let flat = text
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return flat.count <= 180 ? flat : String(flat.prefix(180)) + "…"
}

let browserUserAgent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
