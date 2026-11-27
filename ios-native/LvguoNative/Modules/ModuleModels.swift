import Foundation

/// 模块返回的宽松 JSON 的取值助手：与 Go 核心 models.go 的处理方式对齐
/// （字段类型不固定，字符串/数字/对象都可能出现）。
enum JSON {
    static func dictString(_ value: Any?) -> String {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }

    static func dictInt(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let text as String:
            return Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
        default:
            return 0
        }
    }

    static func dictInt64(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let text as String:
            return Int64(text.trimmingCharacters(in: .whitespaces)) ?? 0
        default:
            return 0
        }
    }

    static func dictBool(_ value: Any?) -> Bool {
        (value as? Bool) ?? false
    }

    static func dictStringArray(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { item in
            (item as? String) ?? (item as? NSNumber)?.stringValue
        }
    }

    /// 对应 Go 的 NativeText：字符串直接用；对象取 url/src/cover/image/pic；
    /// 数组取第一个能取到的文本。
    static func nativeText(_ value: Any?) -> String {
        switch value {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let dict as [String: Any]:
            for key in ["url", "src", "cover", "image", "pic"] {
                let text = nativeText(dict[key])
                if !text.isEmpty {
                    return text
                }
            }
            return ""
        case let array as [Any]:
            for entry in array {
                let text = nativeText(entry)
                if !text.isEmpty {
                    return text
                }
            }
            return ""
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }
}

struct CatalogCategory: Identifiable, Equatable {
    var id: String
    var name: String

    static func parseList(_ value: Any?) -> [CatalogCategory] {
        if let array = value as? [Any] {
            return array.compactMap { item in
                guard let dict = item as? [String: Any] else { return nil }
                return CatalogCategory(
                    id: JSON.dictString(dict["id"]),
                    name: JSON.dictString(dict["name"])
                )
            }
        }
        // Go Categories 还接受 {items: [...], incomplete: bool} 形状
        if let dict = value as? [String: Any], let array = dict["items"] as? [Any] {
            return parseList(array)
        }
        return []
    }
}

/// 首页/搜索的一条剧目：字段对应 Go 的 Drama
struct DramaItem: Identifiable, Equatable {
    var id: String = ""        // "source:sourceId"
    var source: String = ""
    var sourceId: String = ""
    var title: String = ""
    var desc: String = ""
    var coverURL: String = ""
    var totalEpisodes: Int = 0

    private static let coverKeys = [
        "cover", "coverUrl", "cover_url", "image", "imageUrl", "image_url",
        "img", "pic", "picture", "poster", "thumb", "thumbnail",
    ]
    private static let episodeKeys = [
        "totalEpisode", "total_episode", "chapterCount", "chapter_count",
        "episodeCount", "episode_count", "total", "episodes",
    ]

    static func parse(_ dict: [String: Any], fallbackSource: String) -> DramaItem {
        var item = DramaItem()
        item.source = JSON.dictString(dict["source"]).isEmpty
            ? fallbackSource
            : JSON.dictString(dict["source"])
        item.sourceId = JSON.dictString(dict["sourceId"])
        item.id = JSON.dictString(dict["id"]).isEmpty
            ? "\(item.source):\(item.sourceId)"
            : JSON.dictString(dict["id"])
        let title = JSON.dictString(dict["title"])
        let name = JSON.dictString(dict["name"])
        item.title = !title.isEmpty ? title : (!name.isEmpty ? name : "短剧")
        let desc = JSON.dictString(dict["desc"])
        item.desc = !desc.isEmpty ? desc : JSON.dictString(dict["intro"])
        for key in coverKeys {
            let cover = JSON.nativeText(dict[key])
            if !cover.isEmpty {
                item.coverURL = cover
                break
            }
        }
        for key in episodeKeys {
            if dict[key] != nil {
                item.totalEpisodes = JSON.dictInt(dict[key])
                break
            }
        }
        return item
    }
}

/// 一集：字段对应 Go 的 Chapter。raw 保留原始 JSON 字典，
/// resolveMedia 时按 Go Task.chapter 的形状原样回传给模块。
struct ChapterItem: Identifiable {
    var id: String = ""
    var title: String = ""
    var episodeLabel: String = ""
    var videoUrl: String = ""
    var referer: String = ""
    var pageUrl: String = ""
    var mediaSize: Int64 = 0
    var mediaType: String = ""
    var raw: [String: Any] = [:]

    static func parse(_ dict: [String: Any], index: Int) -> ChapterItem {
        var item = ChapterItem()
        item.id = JSON.dictString(dict["id"])
        item.title = JSON.dictString(dict["title"])
        item.videoUrl = JSON.dictString(dict["videoUrl"])
        item.referer = JSON.dictString(dict["referer"])
        item.pageUrl = JSON.dictString(dict["pageUrl"])
        item.mediaSize = JSON.dictInt64(dict["mediaSize"])
        item.mediaType = JSON.dictString(dict["mediaType"])
        item.episodeLabel = episodeString(dict["currentEpisode"], fallback: index + 1)
        if item.title.isEmpty {
            item.title = "第 \(item.episodeLabel) 集"
        }
        item.raw = dict
        return item
    }

    /// 对应 Go Chapter.EpisodeString：字符串原样、数字取整、都没有用序号兜底
    static func episodeString(_ value: Any?, fallback: Int) -> String {
        if let text = value as? String,
           !text.trimmingCharacters(in: .whitespaces).isEmpty {
            return text.trimmingCharacters(in: .whitespaces)
        }
        if let number = value as? NSNumber, number.doubleValue > 0 {
            return String(Int(number.doubleValue))
        }
        return String(fallback)
    }
}

struct DramaPage {
    var items: [DramaItem] = []
    var hasMore: Bool = false
    var warning: String = ""

    static func parse(_ value: Any?, fallbackSource: String) -> DramaPage {
        guard let dict = value as? [String: Any] else { return DramaPage() }
        var page = DramaPage()
        page.items = (dict["items"] as? [Any] ?? []).compactMap { entry in
            (entry as? [String: Any]).map {
                DramaItem.parse($0, fallbackSource: fallbackSource)
            }
        }
        page.hasMore = JSON.dictBool(dict["hasMore"])
        page.warning = JSON.dictString(dict["warning"])
        return page
    }
}

struct MediaCredentials {
    var cookie: String = ""
    var origin: String = ""
    var referer: String = ""
    var userAgent: String = ""
    var expiresMs: Int64 = 0

    static func parse(_ value: Any?) -> MediaCredentials? {
        guard let dict = value as? [String: Any] else { return nil }
        var credentials = MediaCredentials()
        credentials.cookie = JSON.dictString(dict["cookie"])
        credentials.origin = JSON.dictString(dict["origin"])
        credentials.referer = JSON.dictString(dict["referer"])
        credentials.userAgent = JSON.dictString(dict["userAgent"])
        credentials.expiresMs = JSON.dictInt64(dict["expiresMs"])
        return credentials
    }
}

/// 播放计划里的一个画质变体：字段与 Go ProviderMedia 的
/// url/playlist/credentials/referer 一一对应，凭据头在解析时
/// 就地展开（变体缺凭据时回落到外层凭据，同 Go/Dart）。
struct MediaVariant {
    var quality: Int = 0
    var url: String = ""
    var playlistText: String = ""
    var headers: [String: String] = [:]
    var durationMs: Int64 = 0

    var isPlayable: Bool { !url.isEmpty || !playlistText.isEmpty }
}

/// resolveMedia 的结果 → 播放计划（对应 Dart 侧 PlaybackPlan）。
/// 全部变体都保留：播放页的清晰度切换与恢复时的「备用线路」
/// 直接用变体重开，不必再问模块。
struct MediaPlan {
    var url: String = ""
    var headers: [String: String] = [:]
    var quality: Int = 0
    var qualities: [Int] = []
    /// 模块只回了内嵌播放列表文本、没有 URL 时非空（经本地代理播放）
    var playlistText: String = ""
    var durationMs: Int64 = 0
    var variants: [MediaVariant] = []

    var isPlayable: Bool { !url.isEmpty || !playlistText.isEmpty }

    /// 一个媒体字典（外层或某个变体）→ 变体：凭据展开成请求头
    private static func variant(
        from dict: [String: Any], fallback: [String: Any]?
    ) -> MediaVariant {
        var source = dict
        if source["credentials"] == nil, let fallback {
            source["credentials"] = fallback["credentials"]
        }
        if JSON.dictString(source["referer"]).isEmpty, let fallback {
            source["referer"] = fallback["referer"]
        }
        var variant = MediaVariant()
        variant.quality = JSON.dictInt(source["quality"])
        variant.url = JSON.dictString(source["url"])
        variant.playlistText = JSON.dictString(source["playlist"])
        variant.durationMs = JSON.dictInt64(source["durationMs"])
        var referer = JSON.dictString(source["referer"])
        if let credentials = MediaCredentials.parse(source["credentials"]) {
            if !credentials.cookie.isEmpty {
                variant.headers["Cookie"] = credentials.cookie
            }
            if !credentials.userAgent.isEmpty {
                variant.headers["User-Agent"] = credentials.userAgent
            }
            if !credentials.origin.isEmpty {
                variant.headers["Origin"] = credentials.origin
            }
            if !credentials.referer.isEmpty {
                referer = credentials.referer
            }
        }
        if !referer.isEmpty {
            variant.headers["Referer"] = referer
        }
        return variant
    }

    static func parse(_ media: [String: Any]) -> MediaPlan {
        var plan = MediaPlan()
        let rawVariants = media["variants"] as? [[String: Any]] ?? []
        plan.variants = rawVariants.map { variant(from: $0, fallback: media) }
        plan.qualities = plan.variants.map(\.quality).sorted(by: >)
        // 选画质最高且可播的变体（对齐原逻辑：先看带 URL 的，
        // 其次带播放列表文本的）；变体都不可用时回落到外层字段
        let chosen = plan.variants
            .filter { !$0.url.isEmpty }
            .max(by: { $0.quality < $1.quality })
            ?? plan.variants
                .filter { !$0.playlistText.isEmpty }
                .max(by: { $0.quality < $1.quality })
        let outer = variant(from: media, fallback: nil)
        let effective = chosen ?? outer
        plan.url = effective.url
        plan.playlistText = effective.playlistText
        plan.quality = effective.quality
        plan.durationMs = effective.durationMs
        plan.headers = effective.headers
        if plan.variants.isEmpty {
            plan.variants = [outer]
        }
        return plan
    }
}
