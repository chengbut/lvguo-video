import Foundation

/// 模块导出函数的类型化封装（对应 Go provider 的 App 侧入口）：
/// categories / catalogPage / search / detail / resolveMedia / account。
/// 每个方法都走 ModuleRuntime.call（JSON 约定），结果按 Go models 的宽容解析。
struct ModuleProvider {
    let runtime: ModuleRuntime

    var manifest: ModuleManifest { runtime.manifest }

    /// categories(force) → 分类数组或 {items, incomplete}（Go parseModuleCategories）
    func categories(force: Bool = false) async throws -> [CatalogCategory] {
        let result = try await runtime.call("categories", arguments: [force])
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
        let result = try await runtime.call(
            "catalogPage", arguments: [page, category]
        )
        return DramaPage.parse(result, fallbackSource: manifest.id)
    }

    /// search(page, query) → 同 catalogPage 的分页结构
    func search(page: Int, query: String) async throws -> DramaPage {
        let result = try await runtime.call("search", arguments: [page, query])
        return DramaPage.parse(result, fallbackSource: manifest.id)
    }

    /// detail(sourceId) → {drama, chapters}（Go moduleDetail）
    func detail(sourceId: String) async throws -> (drama: DramaItem, chapters: [ChapterItem]) {
        let result = try await runtime.call("detail", arguments: [sourceId])
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

    /// resolveMedia(task) → 播放计划（Go moduleResolveMedia + nativePlan）
    /// task 字段与 Go Task 一致：dramaId / dramaTitle / chapter / index / total。
    func resolveMedia(
        drama: DramaItem, chapter: ChapterItem, index: Int, total: Int
    ) async throws -> MediaPlan {
        let task: [String: Any] = [
            "dramaId": drama.id,
            "dramaTitle": drama.title,
            "chapter": chapter.raw,
            "index": index,
            "total": total,
            "outPath": "",
            "releaseStatus": "",
            "downloadQuality": ""
        ]
        let result = try await runtime.call("resolveMedia", arguments: [task])
        guard let media = result as? [String: Any] else {
            throw ModuleError.bridge("模块播放结果格式无效")
        }
        return MediaPlan.parse(media)
    }

    /// account(command, payload) → 账号命令（资源页暂未用到，保留接口）
    func account(command: String, payload: Any?) async throws -> Any? {
        try await runtime.call("account", arguments: [command, payload ?? NSNull()])
    }
}
