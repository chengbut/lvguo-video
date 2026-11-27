import Foundation

// MARK: - 天翼云盘原生（实验）

/// 天翼云盘原生客户端（实验性，未实测）：按 Alist 开源 189 驱动
/// 公开的网页版接口形态实现——Cookie 会话调 cloud.189.cn 的
/// listFiles.action 分页列目录、getFileDownloadUrl.action 现取
/// 下载地址（逐项对齐 Dart TianyiSourceClient）。
struct TianyiSourceClient: FileSourceClient {
    let source: FileSource

    var headers: [String: String] {
        [
            "Cookie": source.credential,
            "Referer": "https://cloud.189.cn/web/main/",
            "User-Agent": browserUserAgent,
            "Accept": "application/json, text/plain, */*",
        ]
    }

    func check(_ json: [String: Any]) throws {
        let code = json["res_code"]
        let isZero = (code as? NSNumber)?.intValue == 0 || (code as? String) == "0"
        if code != nil, !isZero {
            throw FileSourceFailure(
                "天翼云盘接口报错（res_code=\(JSON.dictString(code))）：\(JSON.dictString(json["res_message"]))"
            )
        }
    }

    func list(_ path: String?) async throws -> [FileEntry] {
        let folderId = path ?? "-11"
        var entries: [FileEntry] = []
        var page = 1
        while page <= 30 {
            var components = URLComponents(
                string: "https://cloud.189.cn/api/open/file/listFiles.action"
            )!
            components.queryItems = [
                URLQueryItem(name: "folderId", value: folderId),
                URLQueryItem(name: "pageNum", value: "\(page)"),
                URLQueryItem(name: "pageSize", value: "60"),
                URLQueryItem(name: "mediaType", value: "0"),
                URLQueryItem(name: "orderBy", value: "1"),
                URLQueryItem(name: "descending", value: "true"),
            ]
            let json = try await jsonRequest(components.url!, headers: headers)
            try check(json)
            guard let ao = json["fileListAO"] as? [String: Any] else {
                throw FileSourceFailure(
                    "天翼云盘返回结构异常（原始返回：\(excerptText(serializeJSON(json)))）"
                )
            }
            if let folders = ao["folderList"] as? [Any] {
                for row in folders {
                    guard let row = row as? [String: Any] else { continue }
                    entries.append(FileEntry(
                        name: JSON.dictString(row["name"]),
                        href: JSON.dictString(row["id"]),
                        isDirectory: true
                    ))
                }
            }
            var fileCount = 0
            if let files = ao["fileList"] as? [Any] {
                fileCount = files.count
                for row in files {
                    guard let row = row as? [String: Any] else { continue }
                    entries.append(FileEntry(
                        name: JSON.dictString(row["name"]),
                        href: JSON.dictString(row["id"]),
                        isDirectory: false,
                        size: (row["size"] as? NSNumber)?.int64Value ?? 0
                    ))
                }
            }
            if fileCount < 60 { break }
            page += 1
        }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.lowercased() < $1.name.lowercased()
        }
        return entries
    }

    func target(_ entry: FileEntry) async throws -> FilePlayTarget {
        var components = URLComponents(
            string: "https://cloud.189.cn/api/open/file/getFileDownloadUrl.action"
        )!
        components.queryItems = [URLQueryItem(name: "fileId", value: entry.href)]
        let json = try await jsonRequest(components.url!, headers: headers)
        try check(json)
        var url = JSON.dictString(json["fileDownloadUrl"])
        if url.isEmpty {
            var infoComponents = URLComponents(
                string: "https://cloud.189.cn/api/portal/getFileInfo.action"
            )!
            infoComponents.queryItems = [URLQueryItem(name: "fileId", value: entry.href)]
            let info = try await jsonRequest(infoComponents.url!, headers: headers)
            try check(info)
            url = JSON.dictString(info["downloadUrl"])
            if url.hasPrefix("//") { url = "https:" + url }
        }
        if url.isEmpty {
            throw FileSourceFailure(
                "天翼云盘没有返回下载地址（原始返回：\(excerptText(serializeJSON(json)))）"
            )
        }
        return FilePlayTarget(url: url)
    }

    func progressKey(_ entry: FileEntry) -> String {
        "src:\(source.id):189:\(entry.href)"
    }
}

/// 把 JSON 对象重新序列化成字符串（报错摘录用）
func serializeJSON(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value),
          let text = String(data: data, encoding: .utf8) else {
        return "\(value)"
    }
    return text
}

// MARK: - 中国移动云盘原生（实验）

/// 中国移动云盘原生客户端（实验性）：按 OpenList 官方驱动
/// drivers/139 的 personal_new 形态实现，逐项对齐 Dart
/// MobileSourceClient——先查路由节点（qryRoutePolicy），再在该
/// 节点上调 /file/list 与 /file/getDownloadUrl；请求体明文 JSON，
/// 鉴权靠 Authorization: Basic <令牌> + Mcloud-Sign 签名头
/// （calSign：encodeURIComponent → 字符排序 → base64 后与
/// 时间戳+随机串一起三轮 MD5）。令牌本体是 yun.139.com 下名为
/// authorization 的 Cookie 值（base64，解码后冒号分段、第二段
/// 是账号名，路由查询要用）。
struct MobileSourceClient: FileSourceClient {
    let source: FileSource

    static let defaultHost = "https://personal-kd-njs.yun.139.com"
    static let routeURL = "https://user-njs.yun.139.com/user/route/qryRoutePolicy"

    /// 按令牌缓存路由下发的个人云节点
    private static var hostCache: [String: String] = [:]
    private static let hostCacheLock = NSLock()

    /// 凭据是整段 Cookie 串时，抠其中名为 authorization 的一项
    var cookieToken: String? {
        let value = source.credential
        guard value.contains("=") else { return nil }
        for part in value.split(separator: ";") {
            guard let cut = part.firstIndex(of: "=") else { continue }
            let name = part[..<cut].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "authorization" {
                let token = part[part.index(after: cut)...]
                    .trimmingCharacters(in: .whitespaces)
                if !token.isEmpty { return token }
            }
        }
        return nil
    }

    /// 实际令牌：去掉可能带上的 "Basic " 前缀
    var token: String {
        var value = (cookieToken ?? source.credential)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("basic ") {
            value = String(value.dropFirst(6))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    /// 从令牌解出账号名（base64 解码后冒号分段，第二段是账号）
    var account: String? {
        var normalized = token
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        let splits = decoded.split(separator: ":", omittingEmptySubsequences: false)
        if splits.count >= 3, !splits[1].isEmpty {
            return String(splits[1])
        }
        return nil
    }

    static func md5Hex(_ input: String) -> String {
        CryptoUtils.md5(Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// JS 语义的 encodeURIComponent：只保留 A-Za-z0-9 与
    /// - _ . ! ~ * ' ( )，其余字节一律 %XX（大写十六进制）
    static func encodeURIComponent(_ input: String) -> String {
        var result = ""
        for byte in input.utf8 {
            let unreserved =
                (byte >= 0x41 && byte <= 0x5A) ||
                (byte >= 0x61 && byte <= 0x7A) ||
                (byte >= 0x30 && byte <= 0x39) ||
                byte == 0x2D || byte == 0x5F || byte == 0x2E ||
                byte == 0x21 || byte == 0x7E || byte == 0x2A ||
                byte == 0x27 || byte == 0x28 || byte == 0x29
            if unreserved {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// calSign：body 先 encodeURIComponent、字符排序、整体 base64，
    /// MD5 后拼 "ts:randStr" 的 MD5，拼接串再 MD5 转大写
    static func calSign(_ body: String, _ ts: String, _ randStr: String) -> String {
        let sorted = encodeURIComponent(body).map { String($0) }.sorted().joined()
        let b64 = Data(sorted.utf8).base64EncodedString()
        let res = md5Hex(b64) + md5Hex("\(ts):\(randStr)")
        return md5Hex(res).uppercased()
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    static func randomString(_ length: Int) -> String {
        let charset = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard let data = try? CryptoUtils.randomBytes(length) else {
            return String((0..<length).map { _ in charset.randomElement()! })
        }
        return String(data.map { charset[Int($0) % charset.count] })
    }

    /// 请求体的规范序列化：对象键字典序递归排序、紧凑输出，
    /// 与 Go encoding/json 对 map 的输出一致（对齐 Dart
    /// _canonicalJson）；签名与实际发送共用同一份字符串。
    static func canonicalJson(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let text = value as? String { return escapeJsonString(text) }
        // 注意：NSNumber 与 Bool 之间能互相桥接转换，必须用
        // CFBoolean 的类型标识区分，否则整数 1 会被误判成 true。
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 1e15 {
                return "\(Int64(double))"
            }
            return "\(double)"
        }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let array = value as? [Any] {
            return "[" + array.map { canonicalJson($0) }.joined(separator: ",") + "]"
        }
        if let dict = value as? [String: Any] {
            let keys = dict.keys.sorted()
            let pairs = keys.map { "\(escapeJsonString($0)):\(canonicalJson(dict[$0]))" }
            return "{" + pairs.joined(separator: ",") + "}"
        }
        return escapeJsonString("\(value)")
    }

    /// Dart jsonEncode 的字符串转义：引号、反斜杠与控制字符，
    /// 非 ASCII 原样输出（不做 \u 转义）
    static func escapeJsonString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x08: result += "\\b"
            case 0x0C: result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// 带 Mcloud-Sign 的 POST：body 是已规范序列化的字符串
    /// （签它、发它）。route 为 true 时用源码 requestRoute 的
    /// 小写头组，否则用 newRequest 的头组（原样对齐 Dart）。
    func signedPost(_ url: URL, body: String, route: Bool) async throws -> [String: Any] {
        let ts = Self.timestamp()
        let randStr = Self.randomString(16)
        let sign = "\(ts),\(randStr),\(Self.calSign(body, ts, randStr))"
        let headers: [String: String]
        if route {
            headers = [
                "Accept": "application/json, text/plain, */*",
                "CMS-DEVICE": "default",
                "Authorization": "Basic \(token)",
                "mcloud-channel": "1000101",
                "mcloud-client": "10701",
                "mcloud-sign": sign,
                "mcloud-version": "7.14.0",
                "Origin": "https://yun.139.com",
                "Referer": "https://yun.139.com/w/",
                "x-DeviceInfo": "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||",
                "x-huawei-channelSrc": "10000034",
                "x-inner-ntwk": "2",
                "x-m4c-caller": "PC",
                "x-m4c-src": "10002",
                "x-SvcType": "1",
                "Inner-Hcy-Router-Https": "1",
                "User-Agent": browserUserAgent,
            ]
        } else {
            headers = [
                "Accept": "application/json, text/plain, */*",
                "Authorization": "Basic \(token)",
                "Caller": "web",
                "Cms-Device": "default",
                "Mcloud-Channel": "1000101",
                "Mcloud-Client": "10701",
                "Mcloud-Route": "001",
                "Mcloud-Sign": sign,
                "Mcloud-Version": "7.14.0",
                "x-DeviceInfo": "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||",
                "x-huawei-channelSrc": "10000034",
                "x-inner-ntwk": "2",
                "x-m4c-caller": "PC",
                "x-m4c-src": "10002",
                "x-SvcType": "1",
                "X-Yun-Api-Version": "v1",
                "X-Yun-App-Channel": "10000034",
                "X-Yun-Channel-Source": "10000034",
                "X-Yun-Client-Info": "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||dW5kZWZpbmVk||",
                "X-Yun-Module-Type": "100",
                "X-Yun-Svc-Type": "1",
                "User-Agent": browserUserAgent,
            ]
        }
        return try await jsonRequest(
            url, method: "POST", headers: headers, body: Data(body.utf8)
        )
    }

    /// 查账号专属的个人云节点：取路由策略里 modName 为 personal
    /// 的 httpsUrl。查询失败不拦路，回退默认节点继续（对齐 Dart）
    func resolveHost() async -> String {
        let currentToken = token
        Self.hostCacheLock.lock()
        let cached = Self.hostCache[currentToken]
        Self.hostCacheLock.unlock()
        if let cached { return cached }
        var host = Self.defaultHost
        if let account {
            let body = Self.canonicalJson([
                "userInfo": [
                    "userType": 1,
                    "accountType": 1,
                    "accountName": account,
                ] as [String: Any],
                "modAddrType": 1,
            ])
            if let json = try? await signedPost(
                URL(string: Self.routeURL)!, body: body, route: true
            ), (try? check(json)) != nil {
                let data = json["data"] as? [String: Any]
                let policies = data?["routePolicyList"] as? [Any] ?? []
                for item in policies {
                    guard let item = item as? [String: Any],
                          JSON.dictString(item["modName"]) == "personal" else { continue }
                    var url = JSON.dictString(item["httpsUrl"])
                    while url.hasSuffix("/") { url = String(url.dropLast()) }
                    if !url.isEmpty { host = url }
                }
            }
        }
        Self.hostCacheLock.lock()
        Self.hostCache[currentToken] = host
        Self.hostCacheLock.unlock()
        return host
    }

    func personalPost(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let host = await resolveHost()
        return try await signedPost(
            URL(string: host + path)!,
            body: Self.canonicalJson(body),
            route: false
        )
    }

    func check(_ json: [String: Any]) throws {
        let ok = json["success"] as? Bool == true
            || (json["code"] as? NSNumber)?.intValue == 0
            || (json["code"] as? String) == "0"
        if !ok {
            let message = JSON.dictString(json["message"]).isEmpty
                ? JSON.dictString(json["msg"]) : JSON.dictString(json["message"])
            throw FileSourceFailure(
                "中国移动云盘接口报错：\(message)（原始返回：\(excerptText(serializeJSON(json)))）"
            )
        }
    }

    func list(_ path: String?) async throws -> [FileEntry] {
        let parentId = (path == nil || path!.isEmpty) ? "/" : path!
        var entries: [FileEntry] = []
        var cursor = ""
        for _ in 0..<200 {
            let json = try await personalPost("/file/list", [
                "imageThumbnailStyleList": ["Small", "Large"],
                "orderBy": "updated_at",
                "orderDirection": "DESC",
                "pageInfo": ["pageCursor": cursor, "pageSize": 100] as [String: Any],
                "parentFileId": parentId,
            ])
            try check(json)
            let data = json["data"] as? [String: Any]
            guard let items = data?["items"] as? [Any] else {
                throw FileSourceFailure(
                    "中国移动云盘返回结构异常（原始返回：\(excerptText(serializeJSON(json)))）"
                )
            }
            for row in items {
                guard let row = row as? [String: Any] else { continue }
                entries.append(FileEntry(
                    name: JSON.dictString(row["name"]),
                    href: JSON.dictString(row["fileId"]),
                    isDirectory: JSON.dictString(row["type"]) == "folder",
                    size: (row["size"] as? NSNumber)?.int64Value ?? 0
                ))
            }
            let next = data?["nextPageCursor"] as? String ?? ""
            if next.isEmpty { break }
            cursor = next
        }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.lowercased() < $1.name.lowercased()
        }
        return entries
    }

    func target(_ entry: FileEntry) async throws -> FilePlayTarget {
        let json = try await personalPost("/file/getDownloadUrl", [
            "fileId": entry.href,
        ])
        try check(json)
        let data = json["data"] as? [String: Any]
        var url = ""
        if let data {
            let cdnUrl = JSON.dictString(data["cdnUrl"])
            if data["cdnSwitch"] as? Bool == true, !cdnUrl.isEmpty {
                url = cdnUrl
            } else {
                url = JSON.dictString(data["url"])
            }
        }
        if url.isEmpty {
            throw FileSourceFailure(
                "中国移动云盘没有返回下载地址（原始返回：\(excerptText(serializeJSON(json)))）"
            )
        }
        return FilePlayTarget(url: url)
    }

    func progressKey(_ entry: FileEntry) -> String {
        "src:\(source.id):139:\(entry.href)"
    }
}
