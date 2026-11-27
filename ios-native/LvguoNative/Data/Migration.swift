import Foundation

/// 首次启动数据迁移：把同容器内旧 Flutter 版的数据搬到原生存储。
///
/// 依据（全部来自 Flutter 版现行代码，不是猜测）：
/// - 两版同包名 com.lvguo.video、覆盖安装保留同一 App 容器；
///   Flutter 版没有用 App Group（ios/Runner 无 application-groups
///   授权），所以数据都在本容器内。
/// - Go 核心的 dataDir = path_provider 的 Application Support 目录
///   本身（core_bridge.dart initialize 传 directory: support.path）：
///   · 模块：<AppSupport>/modules/<id>/{manifest.json, main.js}
///     （module_loader.go：moduleRoot = dataDir/modules）
///   · 模块状态：<AppSupport>/module-<id>-<name>（provider_host.go
///     的 statePath 直接拼 dataDir 根，文件名 moduleStatePrefix）
/// - LocalStore 文件库在 <AppSupport>/store/（main.dart：
///   LocalFiles(support/store)；LocalFiles 按 name 读写并留
///   <name>.bak 备份，读取时主文件坏了用 .bak）：
///   · store/settings.json 的 sourceSwitches = {源id: 是否启用}
///   · store/users.json 的 active = 当前用户 id
///   · store/users/<id>/history.json = [WatchEntry]
///     （{drama:{id,source,sourceId,title,cover,episodes,…},
///       episode: 集号, position, duration, updatedAt}）
///   · store/users/<id>/settings.json = {source: 当前源id,
///     playback: {PlaybackPreferences 的 JSON}, recentSearches: […]}
/// - 文件源不在文件库里，在 SharedPreferences（file_sources.dart
///   FileSourceStore）：键 fileSources.v1（数组 JSON 字符串）与
///   fileProgress.v1（对象 JSON 字符串）。shared_preferences 在
///   iOS 上就是标准 UserDefaults、键加 "flutter." 前缀（落盘为
///   Library/Preferences/com.lvguo.video.plist），原生侧直接读
///   UserDefaults 即可，无需猜 plist 路径。
///
/// 纪律：只读旧数据、只写新位置，绝不删改旧文件；每类数据合并
/// 式写入（已有原生数据不覆盖），重复运行结果一致（幂等）；
/// 全部成功才写 migration-v1.json 标记，失败下次启动重试。
enum Migration {
    struct Report {
        var alreadyDone = false
        var modules = 0
        var moduleStates = 0
        var historyEntries = 0
        var fileSources = 0
        var fileProgress = 0
        /// 在旧版 UserDefaults 里实际读到的文件源/进度条数
        /// （不管有没有搬成功）——0 就是旧版根本没存过，
        /// 与「搬运失败」能一眼区分（真机首测判读用）
        var fileSourcesFound = 0
        var fileProgressFound = 0
        var settingsFilled = 0
        var errors: [String] = []

        var summary: String {
            // 计数常显（含 0）：截图上就能判读每类数据到底有没有
            var parts = [
                "模块 \(modules)",
                "历史 \(historyEntries)",
                "文件源 \(fileSources)",
            ]
            if fileSourcesFound != fileSources {
                parts.append("旧版存有 \(fileSourcesFound)")
            }
            if fileProgress > 0 {
                parts.append("文件进度 \(fileProgress)")
            }
            return parts.joined(separator: " · ")
        }
    }

    private static var cachedReport: Report?

    static var lastReport: Report? { cachedReport }

    static func markerURL(_ dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("migration-v1.json")
    }

    /// 在任何 Store 初始化之前调用（LvguoNativeApp.init）。
    @discardableResult
    static func runIfNeeded(dataDirectory: URL) -> Report {
        if let cachedReport { return cachedReport }
        var report = Report()
        let marker = markerURL(dataDirectory)
        if FileManager.default.fileExists(atPath: marker.path) {
            report.alreadyDone = true
            // 把标记里的计数读回来，重启后「我的」页仍能判读
            if let saved = AppData.readJSONDictionary(marker) {
                report.modules = JSON.dictInt(saved["modules"])
                report.moduleStates = JSON.dictInt(saved["moduleStates"])
                report.historyEntries = JSON.dictInt(saved["history"])
                report.fileSources = JSON.dictInt(saved["fileSources"])
                report.fileProgress = JSON.dictInt(saved["fileProgress"])
                report.fileSourcesFound = JSON.dictInt(saved["fileSourcesFound"])
                report.fileProgressFound = JSON.dictInt(saved["fileProgressFound"])
            }
            cachedReport = report
            return report
        }
        let support = AppData.legacySupportDirectory
        do { report.modules = try migrateModules(support: support, dataDirectory: dataDirectory) }
        catch { report.errors.append("模块：\(error.localizedDescription)") }
        do { report.moduleStates = try migrateModuleStates(support: support, dataDirectory: dataDirectory) }
        catch { report.errors.append("模块状态：\(error.localizedDescription)") }
        do {
            let outcome = try migrateStoreFiles(support: support, dataDirectory: dataDirectory)
            report.historyEntries = outcome.history
            report.settingsFilled = outcome.settings
        } catch { report.errors.append("历史/设置：\(error.localizedDescription)") }
        do {
            let outcome = try migrateFileSources(dataDirectory: dataDirectory)
            report.fileSources = outcome.sources
            report.fileProgress = outcome.progress
            report.fileSourcesFound = outcome.sourcesFound
            report.fileProgressFound = outcome.progressFound
        } catch { report.errors.append("文件源：\(error.localizedDescription)") }

        if report.errors.isEmpty {
            AppData.writeJSON([
                "version": 1,
                "at": AppData.isoString(Date()),
                "modules": report.modules,
                "moduleStates": report.moduleStates,
                "history": report.historyEntries,
                "fileSources": report.fileSources,
                "fileProgress": report.fileProgress,
                "fileSourcesFound": report.fileSourcesFound,
                "fileProgressFound": report.fileProgressFound,
            ], to: marker)
        }
        cachedReport = report
        return report
    }

    // MARK: - 模块与模块状态

    private static func migrateModules(support: URL, dataDirectory: URL) throws -> Int {
        let legacyRoot = support.appendingPathComponent("modules")
        let newRoot = dataDirectory.appendingPathComponent("modules")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: legacyRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return 0 }
        var copied = 0
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(
                forKeys: [.isDirectoryKey]
            ))?.isDirectory ?? false
            guard isDirectory, !entry.lastPathComponent.hasPrefix(".") else { continue }
            let manifest = entry.appendingPathComponent("manifest.json")
            let main = entry.appendingPathComponent("main.js")
            guard FileManager.default.fileExists(atPath: manifest.path),
                  FileManager.default.fileExists(atPath: main.path) else { continue }
            let destination = newRoot.appendingPathComponent(entry.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try FileManager.default.createDirectory(
                at: newRoot, withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: entry, to: destination)
            copied += 1
        }
        return copied
    }

    private static func migrateModuleStates(support: URL, dataDirectory: URL) throws -> Int {
        let stateDirectory = dataDirectory.appendingPathComponent("module-state")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: support, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return 0 }
        var copied = 0
        for entry in entries where entry.lastPathComponent.hasPrefix("module-") {
            let isFile = (try? entry.resourceValues(
                forKeys: [.isRegularFileKey]
            ))?.isRegularFile ?? false
            guard isFile else { continue }
            let destination = stateDirectory.appendingPathComponent(entry.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try FileManager.default.createDirectory(
                at: stateDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: entry, to: destination)
            copied += 1
        }
        return copied
    }

    // MARK: - LocalStore 文件库（历史 / 设置 / 当前源）

    /// LocalFiles 的读法：主文件优先，解析失败用 <name>.bak
    private static func readStoreFile(_ url: URL) -> Any? {
        if let value = AppData.readJSON(url) { return value }
        return AppData.readJSON(URL(fileURLWithPath: url.path + ".bak"))
    }

    private static func migrateStoreFiles(
        support: URL, dataDirectory: URL
    ) throws -> (history: Int, settings: Int) {
        let storeRoot = support.appendingPathComponent("store")
        var historyCount = 0
        var settingsCount = 0

        // 当前用户 id（users.json 的 active）
        var activeId = "default"
        if let users = readStoreFile(storeRoot.appendingPathComponent("users.json"))
            as? [String: Any],
           let active = users["active"] as? String, !active.isEmpty {
            activeId = active
        }
        let userDirectory = storeRoot
            .appendingPathComponent("users")
            .appendingPathComponent(activeId)

        // 历史：users/<id>/history.json 的 [WatchEntry]
        if let rows = readStoreFile(userDirectory.appendingPathComponent("history.json"))
            as? [Any] {
            historyCount = mergeHistory(rows: rows, dataDirectory: dataDirectory)
        }

        // 用户设置：当前源 + playback 子对象 + 最近搜索
        var currentSource = ""
        var playback: [String: Any] = [:]
        if let settings = readStoreFile(userDirectory.appendingPathComponent("settings.json"))
            as? [String: Any] {
            currentSource = JSON.dictString(settings["source"])
            playback = settings["playback"] as? [String: Any] ?? [:]
            if let searches = settings["recentSearches"] as? [Any] {
                let texts = searches.compactMap { $0 as? String }
                let file = dataDirectory.appendingPathComponent("recent-searches.json")
                if !texts.isEmpty, !FileManager.default.fileExists(atPath: file.path) {
                    AppData.writeJSON(texts, to: file)
                }
            }
        }
        settingsCount = fillSettings(playback: playback, dataDirectory: dataDirectory)

        // 全局设置：sourceSwitches → library.json 的 disabled；
        // 当前源 → library.json 的 current（仅补空缺，不覆盖）
        var disabled: [String] = []
        if let global = readStoreFile(storeRoot.appendingPathComponent("settings.json"))
            as? [String: Any],
           let switches = global["sourceSwitches"] as? [String: Any] {
            disabled = switches.filter { ($0.value as? Bool) == false }.map { $0.key }
        }
        fillLibrary(current: currentSource, disabled: disabled, dataDirectory: dataDirectory)
        return (historyCount, settingsCount)
    }

    private static func mergeHistory(rows: [Any], dataDirectory: URL) -> Int {
        let file = dataDirectory.appendingPathComponent("history.json")
        var byId: [String: StationHistoryEntry] = [:]
        if let existing = AppData.readJSON(file) as? [Any] {
            for row in existing {
                if let dict = row as? [String: Any],
                   let entry = StationHistoryEntry.fromJSON(dict) {
                    byId[entry.dramaId] = entry
                }
            }
        }
        var migrated = 0
        for row in rows {
            guard let row = row as? [String: Any],
                  let drama = row["drama"] as? [String: Any] else { continue }
            var entry = StationHistoryEntry()
            entry.source = JSON.dictString(drama["source"])
            entry.sourceId = JSON.dictString(drama["sourceId"])
            entry.dramaId = JSON.dictString(drama["id"]).isEmpty
                ? "\(entry.source):\(entry.sourceId)" : JSON.dictString(drama["id"])
            guard !entry.dramaId.isEmpty, entry.dramaId != ":" else { continue }
            entry.title = JSON.dictString(drama["title"])
            entry.coverURL = JSON.dictString(drama["cover"])
            entry.totalEpisodes = JSON.dictInt(drama["episodes"])
            let episode = JSON.dictInt(row["episode"])
            entry.episodeIndex = max(0, episode - 1)
            entry.episodeLabel = episode > 0 ? "\(episode)" : ""
            entry.position = (row["position"] as? NSNumber)?.doubleValue ?? 0
            entry.duration = (row["duration"] as? NSNumber)?.doubleValue ?? 0
            entry.updatedAt = AppData.parseISODate(row["updatedAt"]) ?? Date(timeIntervalSince1970: 0)
            if let existing = byId[entry.dramaId], existing.updatedAt >= entry.updatedAt {
                continue
            }
            byId[entry.dramaId] = entry
            migrated += 1
        }
        let merged = byId.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(HistoryStore.limit)
        AppData.writeJSON(merged.map { $0.toJSON() }, to: file)
        return migrated
    }

    /// playback 子对象 → 原生 settings.json（只补缺失的键）
    private static func fillSettings(playback: [String: Any], dataDirectory: URL) -> Int {
        guard !playback.isEmpty else { return 0 }
        let file = dataDirectory.appendingPathComponent("settings.json")
        var settings = AppData.readJSONDictionary(file) ?? [:]
        let boolKeys = ["startMuted", "autoAdvance", "recordHistory", "keepScreenAwake"]
        let intKeys = ["skipIntroSeconds", "skipOutroSeconds"]
        var filled = 0
        for key in boolKeys {
            if settings[key] == nil, let value = playback[key] as? Bool {
                settings[key] = value
                filled += 1
            }
        }
        for key in intKeys {
            if settings[key] == nil, let value = playback[key] as? NSNumber {
                settings[key] = value.intValue
                filled += 1
            }
        }
        if settings["speed"] == nil, let value = playback["speed"] as? NSNumber {
            settings["speed"] = value.doubleValue
            filled += 1
        }
        if filled > 0 {
            AppData.writeJSON(settings, to: file)
        }
        return filled
    }

    private static func fillLibrary(current: String, disabled: [String], dataDirectory: URL) {
        let file = dataDirectory.appendingPathComponent("library.json")
        var library = AppData.readJSONDictionary(file) ?? [:]
        var changed = false
        if JSON.dictString(library["current"]).isEmpty, !current.isEmpty {
            library["current"] = current
            changed = true
        }
        let existingDisabled = Set(JSON.dictStringArray(library["disabled"]))
        let merged = existingDisabled.union(disabled)
        if merged != existingDisabled {
            library["disabled"] = Array(merged)
            changed = true
        }
        if changed {
            AppData.writeJSON(library, to: file)
        }
    }

    // MARK: - 文件源（SharedPreferences → UserDefaults）

    private static func migrateFileSources(
        dataDirectory: URL
    ) throws -> (sources: Int, progress: Int, sourcesFound: Int, progressFound: Int) {
        let defaults = UserDefaults.standard
        var sourceCount = 0
        var progressCount = 0
        var sourcesFound = 0
        var progressFound = 0

        // fileSources.v1：原生侧没有文件源时才整体搬入
        if let raw = defaults.string(forKey: "flutter.fileSources.v1"),
           let data = raw.data(using: .utf8),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            sourcesFound = rows.count
            let file = dataDirectory.appendingPathComponent("file-sources.json")
            let existing = (AppData.readJSON(file) as? [Any]) ?? []
            if existing.isEmpty {
                let valid = rows.filter {
                    (($0 as? [String: Any]).map { !JSON.dictString($0["id"]).isEmpty }) ?? false
                }
                if !valid.isEmpty {
                    AppData.writeJSON(valid, to: file)
                    sourceCount = valid.count
                }
            } else {
                sourceCount = existing.count
            }
        }

        // fileProgress.v1：按进度键合并，updatedAt 新的胜出
        if let raw = defaults.string(forKey: "flutter.fileProgress.v1"),
           let data = raw.data(using: .utf8),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            progressFound = rows.count
            let file = dataDirectory.appendingPathComponent("file-progress.json")
            var merged = (AppData.readJSON(file) as? [String: Any]) ?? [:]
            for (key, value) in rows {
                guard let row = value as? [String: Any] else { continue }
                if let existing = merged[key] as? [String: Any] {
                    let existingDate = AppData.parseISODate(existing["updatedAt"])
                    let newDate = AppData.parseISODate(row["updatedAt"])
                    if let existingDate, let newDate, existingDate >= newDate {
                        continue
                    }
                }
                merged[key] = row
                progressCount += 1
            }
            if progressCount > 0 {
                AppData.writeJSON(merged, to: file)
            }
        }
        return (sourceCount, progressCount, sourcesFound, progressFound)
    }
}
