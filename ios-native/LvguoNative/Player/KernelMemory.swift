import Foundation

/// 播放内核：系统内核 = AVPlayer（主内核，系统画中画、
/// 画面调节等原生能力齐全）；软件内核 = KSPlayer 的
/// FFmpeg 内核 KSMEPlayer（兜底 AVPlayer 不认的容器）。
enum PlaybackKernel: String {
    case avplayer
    case software

    var displayName: String {
        switch self {
        case .avplayer: return "系统内核"
        case .software: return "软件内核"
        }
    }
}

/// 按来源记住「上次哪个内核播成功了」，落盘
/// kernel-memory.json（与 settings.json 同目录）。
/// 记忆键以来源（模块）id 为主，来源为空时用主机名。
/// 「播成功」的判定在引擎侧：进入 ready 且播放位置
/// 确实推进过，不是「打开没报错」就算数；软件内核
/// 再加首帧渲染证据与视图上屏校验（修复轮 6，其
/// 位置是墙钟推算、与渲染无关，曾出现假阳性）。
/// 诊断页可查看与清除（方便排查路由是否符合预期）。
final class KernelMemoryStore: ObservableObject {
    static let shared = KernelMemoryStore()

    /// 记忆键 → 内核（rawValue）。键形如 "src:<模块id>"
    /// 或 "host:<主机名>"
    @Published private(set) var entries: [String: String] = [:]

    private var fileURL: URL {
        AppData.directory.appendingPathComponent("kernel-memory.json")
    }

    private init() {
        if let dict = AppData.readJSONDictionary(fileURL) {
            entries = dict.compactMapValues { $0 as? String }
        }
    }

    /// 播放请求的记忆键：来源 id 优先，其次主机名；
    /// 都没有（如本地文件）返回空串 = 不记
    static func key(for request: PlaybackRequest) -> String {
        if !request.sourceId.isEmpty {
            return "src:\(request.sourceId)"
        }
        if let host = request.url?.host, !host.isEmpty {
            return "host:\(host)"
        }
        return ""
    }

    /// 展示用来源名（去掉键前缀）
    static func displaySource(forKey key: String) -> String {
        if key.hasPrefix("src:") { return String(key.dropFirst(4)) }
        if key.hasPrefix("host:") { return String(key.dropFirst(5)) }
        return key
    }

    func kernel(for request: PlaybackRequest) -> PlaybackKernel? {
        let key = Self.key(for: request)
        guard !key.isEmpty, let raw = entries[key] else { return nil }
        return PlaybackKernel(rawValue: raw)
    }

    /// 记下某来源播成功的内核。返回是否发生了变化
    /// （含首次记录）；无键可记时返回 false
    @discardableResult
    func record(_ kernel: PlaybackKernel, for request: PlaybackRequest) -> Bool {
        let key = Self.key(for: request)
        guard !key.isEmpty else { return false }
        guard entries[key] != kernel.rawValue else { return false }
        entries[key] = kernel.rawValue
        AppData.writeJSON(entries, to: fileURL)
        return true
    }

    func clearAll() {
        entries = [:]
        AppData.writeJSON(entries, to: fileURL)
    }

    /// 诊断页展示行（按来源名排序）
    var displayEntries: [(key: String, source: String, kernel: PlaybackKernel)] {
        entries
            .compactMap { key, raw in
                PlaybackKernel(rawValue: raw).map {
                    (key: key, source: Self.displaySource(forKey: key), kernel: $0)
                }
            }
            .sorted { $0.source < $1.source }
    }
}
