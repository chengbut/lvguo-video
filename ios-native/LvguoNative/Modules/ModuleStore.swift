import Foundation

/// 已安装模块在资源页的一行
struct InstalledModule: Identifiable {
    var directoryName: String
    var manifest: ModuleManifest?
    var loadError: String = ""
    var enabled: Bool = true

    var id: String { manifest?.id ?? directoryName }
    var name: String { manifest?.name ?? directoryName }
    var isUsable: Bool { manifest != nil }
}

/// 模块存储与管理：布局与 Go 核心一致（<dataDir>/modules/<id>/manifest.json + main.js），
/// 便于三期做数据迁移。原生侧的数据目录固定为
/// Application Support/LvguoNative/，其下：
///   modules/<id>/manifest.json, main.js   —— 已安装模块（同 Go 的 moduleRoot）
///   module-state/module-<id>-<name>       —— host.loadState/saveState 的落盘文件
///   library.json                          —— 管理状态 {current, disabled}
/// library.json 形状刻意保持简单键值，三期迁移时与 Flutter 侧 LocalStore 对照转换。
@MainActor
final class ModuleStore: ObservableObject {
    @Published private(set) var modules: [InstalledModule] = []
    @Published private(set) var currentSourceId: String = ""

    let dataDirectory: URL
    var modulesDirectory: URL { dataDirectory.appendingPathComponent("modules") }
    var stateDirectory: URL { dataDirectory.appendingPathComponent("module-state") }
    private var libraryFile: URL { dataDirectory.appendingPathComponent("library.json") }
    private var disabledIds: Set<String> = []
    private var runtimes: [String: ModuleRuntime] = [:]
    private var providers: [String: ModuleProvider] = [:]
    private var runtimeErrors: [String: String] = [:]

    static let packageLimit = 8 << 20    // Go modulePackageBytes
    static let manifestLimit = 64 << 10  // Go moduleManifestBytes
    static let entryLimit = 4 << 20      // Go moduleEntryBytes

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        dataDirectory = support.appendingPathComponent("LvguoNative")
        try? FileManager.default.createDirectory(
            at: modulesDirectory, withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true
        )
        loadLibraryState()
        reload()
    }

    // MARK: - 列表与状态

    func reload() {
        var loaded: [InstalledModule] = []
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: modulesDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !entry.lastPathComponent.hasPrefix(".") else {
                continue
            }
            var module = InstalledModule(directoryName: entry.lastPathComponent)
            let manifestURL = entry.appendingPathComponent("manifest.json")
            let codeURL = entry.appendingPathComponent("main.js")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? ModuleManifest.parse(data) {
                if manifest.id != entry.lastPathComponent {
                    module.loadError = "模块文件夹名应与标识 \(manifest.id) 一致"
                } else if !FileManager.default.fileExists(atPath: codeURL.path) {
                    module.loadError = "模块缺少 main.js"
                } else {
                    module.manifest = manifest
                }
            } else if let data = try? Data(contentsOf: manifestURL) {
                // 解析失败时把校验错误带出来给用户看
                do {
                    _ = try ModuleManifest.parse(data)
                } catch {
                    module.loadError = "\(error)"
                }
            } else {
                module.loadError = "模块缺少 manifest.json"
            }
            module.enabled = !disabledIds.contains(module.id)
            loaded.append(module)
        }
        modules = loaded
        if currentModule == nil {
            currentSourceId = loaded.first(where: { $0.enabled && $0.isUsable })?.id ?? ""
        }
    }

    var currentModule: InstalledModule? {
        modules.first { $0.id == currentSourceId && $0.enabled && $0.isUsable }
    }

    func setCurrent(_ id: String) {
        guard modules.contains(where: { $0.id == id && $0.isUsable }) else { return }
        currentSourceId = id
        saveLibraryState()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if enabled {
            disabledIds.remove(id)
        } else {
            disabledIds.insert(id)
        }
        saveLibraryState()
        reload()
    }

    func uninstall(_ id: String) {
        let directory = modulesDirectory.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: directory)
        runtimes[id] = nil
        providers[id] = nil
        runtimeErrors[id] = nil
        disabledIds.remove(id)
        saveLibraryState()
        reload()
    }

    // MARK: - 安装

    /// 从 URL 下载模块包（zip）并安装，返回装好的清单。
    func installFromURL(_ urlString: String) async throws -> ModuleManifest {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw ModuleValidationError(message: "模块包地址无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ModuleValidationError(message: "模块包下载失败（HTTP \(http.statusCode)）")
        }
        return try installPackage(data: data)
    }

    /// 安装一个 zip 包：包根目录或唯一一层文件夹里放 manifest.json + main.js
    /// （与 Go modulePackageFiles 一致）。
    @discardableResult
    func installPackage(data: Data) throws -> ModuleManifest {
        guard data.count <= Self.packageLimit else {
            throw ModuleValidationError(message: "安装包超过 8 MB")
        }
        let archive = try ZipArchive(data: data)
        var prefixes: [String] = []
        for entry in archive.entries {
            if entry.name == "manifest.json" {
                prefixes.append("")
            } else if entry.name.hasSuffix("/manifest.json"),
                      entry.name.dropLast("manifest.json".count).filter({ $0 == "/" }).count == 1 {
                prefixes.append(String(entry.name.dropLast("manifest.json".count)))
            }
        }
        guard prefixes.count == 1, let prefix = prefixes.first else {
            throw ModuleValidationError(
                message: "安装包根目录或唯一的文件夹里应有 manifest.json 和 main.js"
            )
        }
        func entryData(_ name: String, limit: Int) throws -> Data {
            guard let entry = archive.entries.first(where: { $0.name == prefix + name }) else {
                throw ModuleValidationError(message: "安装包里缺少 \(name)")
            }
            let data = try archive.extract(entry)
            guard data.count <= limit else {
                throw ModuleValidationError(message: "\(name) 超过 \(limit >> 10) KB")
            }
            return data
        }
        let manifestData = try entryData("manifest.json", limit: Self.manifestLimit)
        let manifest = try ModuleManifest.parse(manifestData)
        let codeData = try entryData("main.js", limit: Self.entryLimit)
        let directory = modulesDirectory.appendingPathComponent(manifest.id)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"))
        try codeData.write(to: directory.appendingPathComponent("main.js"))
        runtimes[manifest.id] = nil
        providers[manifest.id] = nil
        runtimeErrors[manifest.id] = nil
        reload()
        return manifest
    }

    /// 安装内置示例模块（jsexample，纯假数据、不访问网络，
    /// 与 Flutter 仓库 native/module_example 里的示例逐字一致），
    /// 用于离线验证「安装 → 首页 → 详情」整条链路。
    @discardableResult
    func installSampleModule() throws -> ModuleManifest {
        let manifest = try ModuleManifest.parse(Data(SampleModule.manifestJSON.utf8))
        let directory = modulesDirectory.appendingPathComponent(manifest.id)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try Data(SampleModule.manifestJSON.utf8)
            .write(to: directory.appendingPathComponent("manifest.json"))
        try Data(SampleModule.mainJS.utf8)
            .write(to: directory.appendingPathComponent("main.js"))
        reload()
        return manifest
    }

    // MARK: - 运行时

    /// 当前站源的调用入口；没有可用模块时返回 nil。
    func currentProvider() -> ModuleProvider? {
        guard let module = currentModule else { return nil }
        return provider(for: module.id)
    }

    /// 任意已安装可用模块的调用入口（历史续播、下载重试按条目
    /// 自带的模块 id 取，不要求它就是当前模块）。
    func provider(for id: String) -> ModuleProvider? {
        guard let module = modules.first(where: { $0.id == id && $0.enabled && $0.isUsable }),
              let manifest = module.manifest else {
            return nil
        }
        if let provider = providers[manifest.id] {
            return provider
        }
        let codeURL = modulesDirectory
            .appendingPathComponent(manifest.id)
            .appendingPathComponent("main.js")
        guard let code = try? String(contentsOf: codeURL, encoding: .utf8) else {
            return nil
        }
        do {
            let runtime = try ModuleRuntime(
                manifest: manifest, code: code, stateDirectory: stateDirectory
            )
            let provider = ModuleProvider(runtime: runtime)
            runtimes[manifest.id] = runtime
            providers[manifest.id] = provider
            runtimeErrors[manifest.id] = nil
            return provider
        } catch {
            runtimeErrors[manifest.id] = "\(error)"
            return nil
        }
    }

    /// 最近一次创建当前模块运行时失败的原因（供首页展示诊断）
    func providerError() -> String? {
        guard let module = currentModule else { return nil }
        return runtimeErrors[module.id]
    }

    // MARK: - 管理状态落盘

    private func loadLibraryState() {
        guard let data = try? Data(contentsOf: libraryFile),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        currentSourceId = JSON.dictString(dict["current"])
        disabledIds = Set(JSON.dictStringArray(dict["disabled"]))
    }

    private func saveLibraryState() {
        let dict: [String: Any] = [
            "current": currentSourceId,
            "disabled": Array(disabledIds),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: libraryFile)
        }
    }
}
