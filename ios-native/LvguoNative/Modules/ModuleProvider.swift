import Foundation

/// 模块导出函数的类型化封装（对应 Go provider 的 App 侧入口）：
/// categories / catalogPage / search / detail / resolveMedia / account。
/// 每个方法都走运行时池的 call（JSON 约定），结果按 Go models 的宽容解析。
struct ModuleProvider {
    let pool: ModuleRuntimePool

    var manifest: ModuleManifest { pool.manifest }

    /// categories(force) → 分类数组或 {items, incomplete}（Go parseModuleCategories）
    func categories(force: Bool = false) async throws -> [CatalogCategory] {
        let result = try await pool.call("categories", arguments: [force])
        return CatalogCategory.parseList(result)
            .filter { !$0.id.isEmpty }
            .map { category in
                CatalogCategory(
                    id: category.id,
                    name: category.name.isEmpty ? category.id : category.name
                )
            }
    }

    /// catalogPage(page, category) → {items, hasMore, warning}（Go moduleCatalogPage）
    func catalogPage(page: Int, category: String) async throws -> DramaPage {
        let result = try await pool.call(
            "catalogPage", arguments: [page, category]
        )
        return DramaPage.parse(result, fallbackSource: manifest.id)
    }

    /// search(page, query) → 同 catalogPage 的分页结构
    func search(page: Int, query: String) async throws -> DramaPage {
        let result = try await pool.call("search", arguments: [page, query])
        return DramaPage.parse(result, fallbackSource: manifest.id)
    }

    /// detail(sourceId) → {drama, chapters}（Go moduleDetail）
    func detail(sourceId: String) async throws -> (drama: DramaItem, chapters: [ChapterItem]) {
        let result = try await pool.call("detail", arguments: [sourceId])
        guard let object = result as? [String: Any] else {
            throw ModuleError.bridge("模块详情格式无效")
        }
        let drama = DramaItem.parse(
            object["drama"] as? [String: Any] ?? [:],
            fallbackSource: manifest.id
        )
        let chapters = (object["chapters"] as? [Any] ?? []).enumerated().compactMap {
            index, raw -> ChapterItem? in
            guard let dict = raw as? [String: Any] else { return nil }
            return ChapterItem.parse(dict, index: index)
        }
        return (drama, chapters)
    }

    /// 播放/弹幕共用的 task 结构（Go Task）：
    /// dramaId / dramaTitle / chapter / index / total
    static func mediaTask(
        drama: DramaItem, chapter: ChapterItem, index: Int, total: Int
    ) -> [String: Any] {
        [
            "dramaId": drama.id,
            "dramaTitle": drama.title,
            "chapter": chapter.raw,
            "index": index,
            "total": total,
            "outPath": "",
            "releaseStatus": ""
        ]
    }

    /// resolveMedia(task) → 播放计划（Go moduleResolveMedia + nativePlan）
    /// task 字段与 Go Task 一致：dramaId / dramaTitle / chapter / index / total。
    func resolveMedia(
        drama: DramaItem, chapter: ChapterItem, index: Int, total: Int
    ) async throws -> MediaPlan {
        let task = Self.mediaTask(
            drama: drama, chapter: chapter, index: index, total: total
        )
        let result = try await pool.call("resolveMedia", arguments: [task])
        guard let media = result as? [String: Any] else {
            throw ModuleError.bridge("模块播放结果格式无效")
        }
        return MediaPlan.parse(media)
    }

    /// account(command, payload) → 账号命令（资源页暂未用到，保留接口）
    func account(command: String, payload: Any?) async throws -> Any? {
        try await pool.call("account", arguments: [command, payload ?? NSNull()])
    }

    /// 模块是否声明弹幕能力（manifest capabilities 含 danmaku，
    /// 与 Go module_capabilities 的 DanmakuProvider 判定一致）
    var supportsDanmaku: Bool {
        manifest.capabilities.contains("danmaku")
    }

    /// danmakuIds(task) → {series, video}（Go jsProvider.DanmakuIDs：
    /// quickCall 语义，任何失败都按「无弹幕」返回 nil，不打断播放）
    func danmakuIDs(
        task: [String: Any]
    ) async -> (series: String, video: String)? {
        guard supportsDanmaku else { return nil }
        guard let result = try? await pool.call(
            "danmakuIds", arguments: [task]
        ), let dict = result as? [String: Any] else { return nil }
        let series = JSON.dictString(dict["series"])
        let video = JSON.dictString(dict["video"])
        guard !series.isEmpty, !video.isEmpty else { return nil }
        return (series, video)
    }

    /// danmaku(series, video, startMS, durationMS) → DanmakuPage
    /// （Go jsProvider.Danmaku：{episodeId, items[{id,text,timeMs}],
    /// startMs, nextMs, total}）
    func danmaku(
        series: String, video: String, startMS: Int64, durationMS: Int64
    ) async throws -> DanmakuPage {
        let result = try await pool.call(
            "danmaku", arguments: [series, video, startMS, durationMS]
        )
        guard let dict = result as? [String: Any] else {
            throw ModuleError.bridge("模块弹幕格式无效")
        }
        var page = DanmakuPage()
        page.items = (dict["items"] as? [Any] ?? []).compactMap { raw in
            guard let entry = raw as? [String: Any] else { return nil }
            let text = JSON.dictString(entry["text"])
            guard !text.isEmpty else { return nil }
            var item = DanmakuItem(
                id: JSON.dictString(entry["id"]),
                text: text,
                timeMS: JSON.dictInt64(entry["timeMs"])
            )
            if item.id.isEmpty {
                item.id = "\(item.timeMS)-\(text)"
            }
            return item
        }
        page.nextMS = JSON.dictInt64(dict["nextMs"])
        page.total = JSON.dictInt64(dict["total"])
        return page
    }
}
