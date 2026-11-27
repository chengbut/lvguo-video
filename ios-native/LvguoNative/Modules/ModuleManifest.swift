import Foundation

/// 模块清单：与 Go 核心 `ModuleManifest`（native/core/module_loader.go）同构。
/// 模块包 = zip（manifest.json + main.js，位于包根目录或唯一一层文件夹内），
/// 安装后落盘为 modules/<id>/manifest.json + main.js（见 ModuleStore）。
struct ModuleManifest: Equatable {
    var id: String = ""
    var name: String = ""
    var version: String = ""
    var description: String = ""
    var runtime: String = ""
    var api: Int = 0
    var hosts: [String] = []
    var capabilities: [String] = []
    /// Go 侧为 *bool：缺失即校验失败，原生侧用 Optional 保留这一语义
    var adult: Bool? = nil
    var allowEmptyCatalog: Bool = false
    var group: String = ""
    var groupName: String = ""
    var entryName: String = ""
    var baseUrl: String = ""
    var mediaAuthPaths: [String] = []

    static let apiVersion = 1
    static let knownCapabilities: Set<String> = [
        "search", "account", "suggestions", "recommendations", "danmaku",
        "devices", "rankings", "seasons", "cover", "metadata", "catalogState",
        "mediaAuth",
    ]
    /// Go moduleIDPattern：^[a-z0-9][a-z0-9_-]{0,31}$
    private static let idPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9][a-z0-9_-]{0,31}$"
    )

    static func parse(_ data: Data) throws -> ModuleManifest {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ModuleValidationError(message: "manifest.json 无法解析")
        }
        guard let dict = object as? [String: Any] else {
            throw ModuleValidationError(message: "manifest.json 无法解析")
        }
        return try parse(dict)
    }

    static func parse(_ dict: [String: Any]) throws -> ModuleManifest {
        var manifest = ModuleManifest()
        manifest.id = JSON.dictString(dict["id"])
        manifest.name = JSON.dictString(dict["name"])
        manifest.version = JSON.dictString(dict["version"])
        manifest.description = JSON.dictString(dict["description"])
        manifest.runtime = JSON.dictString(dict["runtime"])
        manifest.api = JSON.dictInt(dict["api"])
        manifest.hosts = JSON.dictStringArray(dict["hosts"])
        manifest.capabilities = JSON.dictStringArray(dict["capabilities"])
        if let adult = dict["adult"] as? Bool {
            manifest.adult = adult
        }
        manifest.allowEmptyCatalog = JSON.dictBool(dict["allowEmptyCatalog"])
        manifest.group = JSON.dictString(dict["group"])
        manifest.groupName = JSON.dictString(dict["groupName"])
        manifest.entryName = JSON.dictString(dict["entryName"])
        manifest.baseUrl = JSON.dictString(dict["baseUrl"])
        manifest.mediaAuthPaths = JSON.dictStringArray(dict["mediaAuthPaths"])
        try manifest.validate()
        return manifest
    }

    /// 与 Go parseModule 的校验一一对应（错误文案沿用 Go 侧中文）
    func validate() throws {
        let range = NSRange(id.startIndex..., in: id)
        guard Self.idPattern.firstMatch(in: id, range: range) != nil else {
            throw ModuleValidationError(
                message: "模块标识只能用小写字母、数字、下划线和连字符，最长 32 个字符"
            )
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModuleValidationError(message: "模块缺少名称")
        }
        guard runtime == "js" else {
            throw ModuleValidationError(message: "不支持的模块运行时 \(runtime)")
        }
        guard api == Self.apiVersion else {
            throw ModuleValidationError(
                message: "模块接口版本为 \(api)，当前应用支持 \(Self.apiVersion)"
            )
        }
        guard adult != nil else {
            throw ModuleValidationError(message: "模块缺少 adult 声明")
        }
        for capability in capabilities {
            guard Self.knownCapabilities.contains(capability) else {
                throw ModuleValidationError(message: "未知的模块能力 \(capability)")
            }
        }
        let hasMediaAuth = capabilities.contains("mediaAuth")
        guard hasMediaAuth == !mediaAuthPaths.isEmpty else {
            throw ModuleValidationError(message: "媒体鉴权能力与 mediaAuthPaths 须同时声明")
        }
        for path in mediaAuthPaths {
            guard path.hasPrefix("/") else {
                throw ModuleValidationError(message: "mediaAuthPaths 的每一项须以 / 开头")
            }
        }
    }

    /// 与 Go allowsHost 对应：精确匹配或 `*.` 通配后缀
    func allowsHost(_ host: String) -> Bool {
        let host = host.lowercased()
        for rawPattern in hosts {
            let pattern = rawPattern
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1)) // 保留前导点
                if host.hasSuffix(suffix) {
                    return true
                }
            } else if !pattern.isEmpty, pattern == host {
                return true
            }
        }
        return false
    }
}

struct ModuleValidationError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}
