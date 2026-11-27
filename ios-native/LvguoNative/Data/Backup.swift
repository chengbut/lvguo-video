import Foundation

/// 最小 ZIP 写出器（store 不压缩）：备份导出用。格式与
/// ZipArchive 读取器互通（本机导出即可本机恢复）。
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func add(name: String, contents: Data) {
        let nameBytes = [UInt8](name.utf8)
        let crc = Self.crc32(contents)
        let offset = UInt32(body.count)
        let (dosTime, dosDate) = Self.dosDateTime(Date())

        var local = Data()
        local.appendUInt32(0x0403_4b50)
        local.appendUInt16(20)              // version needed
        local.appendUInt16(0x0800)          // UTF-8 filename flag
        local.appendUInt16(0)               // method: store
        local.appendUInt16(dosTime)
        local.appendUInt16(dosDate)
        local.appendUInt32(crc)
        local.appendUInt32(UInt32(contents.count))
        local.appendUInt32(UInt32(contents.count))
        local.appendUInt16(UInt16(nameBytes.count))
        local.appendUInt16(0)               // extra length
        local.append(contentsOf: nameBytes)
        body.append(local)
        body.append(contents)

        var record = Data()
        record.appendUInt32(0x0201_4b50)
        record.appendUInt16(20)             // version made by
        record.appendUInt16(20)             // version needed
        record.appendUInt16(0x0800)
        record.appendUInt16(0)
        record.appendUInt16(dosTime)
        record.appendUInt16(dosDate)
        record.appendUInt32(crc)
        record.appendUInt32(UInt32(contents.count))
        record.appendUInt32(UInt32(contents.count))
        record.appendUInt16(UInt16(nameBytes.count))
        record.appendUInt16(0)              // extra
        record.appendUInt16(0)              // comment
        record.appendUInt16(0)              // disk number
        record.appendUInt16(0)              // internal attrs
        record.appendUInt32(0)              // external attrs
        record.appendUInt32(offset)
        record.append(contentsOf: nameBytes)
        central.append(record)
        count += 1
    }

    func finish() -> Data {
        var result = body
        let centralOffset = UInt32(result.count)
        result.append(central)
        var end = Data()
        end.appendUInt32(0x0605_4b50)
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(count)
        end.appendUInt16(count)
        end.appendUInt32(UInt32(central.count))
        end.appendUInt32(centralOffset)
        end.appendUInt16(0)
        result.append(end)
        return result
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = max(1980, components.year ?? 1980)
        let dosTime = UInt16(
            ((components.hour ?? 0) << 11)
                | ((components.minute ?? 0) << 5)
                | ((components.second ?? 0) / 2)
        )
        let dosDate = UInt16(
            ((year - 1980) << 9)
                | ((components.month ?? 1) << 5)
                | (components.day ?? 1)
        )
        return (dosTime, dosDate)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
        return crc
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 2))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 4))
    }
}

/// 备份与恢复，对齐 Flutter 诊断组的导出/恢复备份：
/// 包含设置、外观、资源与下载偏好、弹幕偏好、历史、文件源、
/// 已安装模块与模块状态、下载任务记录；不含已下载的视频
/// 文件（与 Flutter 一致）。恢复后需重启应用生效。
enum BackupService {
    static let manifestName = "lvguo-backup.json"

    enum BackupError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    /// 导出到临时目录，返回 zip 文件 URL（供系统分享）。
    static func exportArchive(dataDirectory: URL) throws -> URL {
        var writer = ZipWriter()
        let manifest: [String: Any] = [
            "app": "lvguo-native",
            "version": 1,
            "createdAt": AppData.isoString(Date()),
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys]
        ) {
            writer.add(name: manifestName, contents: data)
        }
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: dataDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw BackupError.message("无法读取数据目录")
        }
        let rootPath = dataDirectory.path
        for case let fileURL as URL in enumerator {
            let relative = String(
                fileURL.path.dropFirst(rootPath.count + 1)
            )
            // 下载的媒体文件不进备份（任务记录 downloads.json 在根目录，会被包含）
            if relative.hasPrefix("downloads/") { continue }
            guard let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            writer.add(name: relative, contents: data)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "lvguo-backup-\(formatter.string(from: Date())).zip"
            )
        try writer.finish().write(to: target, options: [.atomic])
        return target
    }

    /// 从备份 zip 恢复：先整体解到暂存目录校验，再逐文件
    /// 覆盖回数据目录（下载媒体目录不动）。返回恢复文件数。
    @discardableResult
    static func restore(archiveURL: URL, dataDirectory: URL) throws -> Int {
        let accessed = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { archiveURL.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: archiveURL)
        let archive = try ZipArchive(data: data)
        guard let manifestEntry = archive.entries.first(
            where: { $0.name == manifestName }
        ), let manifestData = try? archive.extract(manifestEntry),
           let manifest = (try? JSONSerialization.jsonObject(
               with: manifestData
           )) as? [String: Any],
           JSON.dictString(manifest["app"]) == "lvguo-native" else {
            throw BackupError.message("这不是绿果视频（原生版）的备份文件")
        }
        let fileManager = FileManager.default
        var restored = 0
        for entry in archive.entries {
            let name = entry.name
            if name == manifestName { continue }
            // 防目录穿越：名字必须留在数据目录内
            let destination = dataDirectory.appendingPathComponent(name)
            let rootPath = dataDirectory.standardizedFileURL.path
            guard destination.standardizedFileURL.path
                .hasPrefix(rootPath + "/") else { continue }
            if name.hasPrefix("downloads/") { continue }
            let contents = try archive.extract(entry)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: destination, options: [.atomic])
            restored += 1
        }
        guard restored > 0 else {
            throw BackupError.message("备份里没有可恢复的数据")
        }
        return restored
    }
}
