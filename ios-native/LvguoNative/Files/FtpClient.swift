import Foundation
import Network

/// FTP 客户端（对齐 Dart FtpSourceClient）：每次操作开一条新连接
/// （USER/PASS 登录、PASV 被动模式、LIST 解析 Unix/DOS 两种格式），
/// 用完即断。播放走 ftp://user:pass@host/path 形式交给播放器。
struct FtpSourceClient: FileSourceClient {
    let source: FileSource

    var port: Int { source.port == 0 ? 21 : source.port }

    var rootPath: String {
        var path = source.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return "/" }
        if !path.hasPrefix("/") { path = "/" + path }
        if path.count > 1, path.hasSuffix("/") { path = String(path.dropLast()) }
        return path
    }

    func list(_ path: String?) async throws -> [FileEntry] {
        let dir = path ?? rootPath
        let connection = try await FtpConnection.connect(
            host: source.server.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: source.username,
            password: source.password
        )
        do {
            let lines = try await connection.list(dir)
            await connection.close()
            return Self.parseFtpList(lines, dir: dir)
        } catch {
            await connection.close()
            throw error
        }
    }

    func target(_ entry: FileEntry) async throws -> FilePlayTarget {
        FilePlayTarget(url: playUrl(entry.href))
    }

    func progressKey(_ entry: FileEntry) -> String {
        "src:\(source.id):ftp:\(entry.href)"
    }

    /// ftp:// 播放地址：账号密码做 URL 编码，路径逐段编码
    func playUrl(_ path: String) -> String {
        var components = URLComponents()
        components.scheme = "ftp"
        if !source.username.isEmpty {
            components.user = source.username
            components.password = source.password
        }
        components.host = source.server.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = port == 21 ? nil : port
        components.path = "/" + path.split(separator: "/").joined(separator: "/")
        return components.string ?? "ftp://\(source.server)\(path)"
    }

    /// 把文件下载到本地（PASV + RETR；供下载模块用）
    func download(
        _ entry: FileEntry, to destination: URL,
        progress: @escaping (Int64) -> Void
    ) async throws {
        let connection = try await FtpConnection.connect(
            host: source.server.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: source.username,
            password: source.password
        )
        do {
            try await connection.download(path: entry.href, to: destination, progress: progress)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    /// 解析 LIST 输出（Unix 为主，兼 DOS；对齐 Dart parseFtpList）
    static func parseFtpList(_ lines: [String], dir: String) -> [FileEntry] {
        let unixPattern =
            #"^([bcdlps-])[\wxsStT-]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+"# +
            #"\w{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})\s+(.+)$"#
        let dosPattern =
            #"^\d{2}-\d{2}-\d{2,4}\s+\d{1,2}:\d{2}\s*(?:AM|PM)\s+(<DIR>|\d+)\s+(.+)$"#
        let unix = try! NSRegularExpression(pattern: unixPattern)
        let dos = try! NSRegularExpression(pattern: dosPattern, options: [.caseInsensitive])
        var entries: [FileEntry] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            var name: String?
            var isDirectory = false
            var size: Int64 = 0
            let range = NSRange(line.startIndex..., in: line)
            if let match = unix.firstMatch(in: line, range: range),
               let typeRange = Range(match.range(at: 1), in: line),
               let sizeRange = Range(match.range(at: 2), in: line),
               let nameRange = Range(match.range(at: 3), in: line) {
                isDirectory = line[typeRange] == "d"
                size = Int64(line[sizeRange]) ?? 0
                var value = String(line[nameRange])
                if let arrow = value.range(of: " -> ") {
                    value = String(value[..<arrow.lowerBound])
                }
                name = value
            } else if let match = dos.firstMatch(in: line, range: range),
                      let kindRange = Range(match.range(at: 1), in: line),
                      let nameRange = Range(match.range(at: 2), in: line) {
                isDirectory = line[kindRange].uppercased() == "<DIR>"
                size = Int64(line[kindRange]) ?? 0
                name = String(line[nameRange])
            } else {
                continue
            }
            guard let entryName = name, !entryName.isEmpty,
                  entryName != ".", entryName != ".." else { continue }
            entries.append(FileEntry(
                name: entryName,
                href: dir == "/" ? "/\(entryName)" : "\(dir)/\(entryName)",
                isDirectory: isDirectory,
                size: size
            ))
        }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.lowercased() < $1.name.lowercased()
        }
        return entries
    }
}

// MARK: - 线通道：把 NWConnection 包成「按行读 / 整包读」

/// 一条 NWConnection 的行通道：所有可变状态只在内部串行队列上动。
/// 控制连接走行模式（lineHandler 逐行投递），数据连接走整包模式
/// （readAllData 收全部字节直到对端关闭）。
private final class FtpLineChannel {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "lvguo.ftp.channel")
    private var buffer = Data()
    private var lines: [String] = []
    private var waiters: [(UUID, CheckedContinuation<String, Error>)] = []
    private var dataWaiter: CheckedContinuation<Data, Error>?
    private var dataChunks: [Data] = []
    private var streamHandler: ((Data) -> Void)?
    private var streamWaiter: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var closed = false
    private var startResumed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.queue.async {
                        if !self.startResumed {
                            self.startResumed = true
                            continuation.resume()
                        }
                    }
                    self.receiveLoop()
                case .failed:
                    self.queue.async {
                        self.fail(FileSourceFailure("FTP 连接已断开"))
                        if !self.startResumed {
                            self.startResumed = true
                            continuation.resume(
                                throwing: FileSourceFailure("连不上 FTP 服务器，请检查主机和网络")
                            )
                        }
                    }
                case .cancelled:
                    self.queue.async { self.markClosed() }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.queue.async { self.ingest(data) }
            }
            if isComplete || error != nil {
                self.queue.async { self.markClosed() }
                return
            }
            self.receiveLoop()
        }
    }

    private func ingest(_ data: Data) {
        if streamWaiter != nil {
            streamHandler?(data)
            return
        }
        if dataWaiter != nil {
            dataChunks.append(data)
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            var line = String(data: lineData, encoding: .utf8) ?? ""
            if line.hasSuffix("\r") { line = String(line.dropLast()) }
            if waiters.isEmpty {
                lines.append(line)
            } else {
                waiters.removeFirst().1.resume(returning: line)
            }
        }
    }

    private func markClosed() {
        if closed { return }
        closed = true
        if let waiter = dataWaiter {
            dataWaiter = nil
            waiter.resume(returning: dataChunks.reduce(Data(), +))
            dataChunks = []
        }
        if let waiter = streamWaiter {
            streamWaiter = nil
            streamHandler = nil
            waiter.resume()
        }
        fail(FileSourceFailure("FTP 连接已断开"))
    }

    private func fail(_ error: Error) {
        if failure == nil { failure = error }
        let pending = waiters
        waiters.removeAll()
        for (_, waiter) in pending {
            waiter.resume(throwing: error)
        }
        if let waiter = dataWaiter {
            dataWaiter = nil
            waiter.resume(throwing: error)
        }
        if let waiter = streamWaiter {
            streamWaiter = nil
            streamHandler = nil
            waiter.resume(throwing: error)
        }
    }

    func nextLine(timeout: TimeInterval = 25) async throws -> String {
        let id = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async {
                if let failure = self.failure {
                    continuation.resume(throwing: failure)
                    return
                }
                if !self.lines.isEmpty {
                    continuation.resume(returning: self.lines.removeFirst())
                    return
                }
                if self.closed {
                    continuation.resume(throwing: FileSourceFailure("FTP 连接已断开"))
                    return
                }
                self.waiters.append((id, continuation))
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self,
                          let index = self.waiters.firstIndex(where: { $0.0 == id })
                    else { return }
                    self.waiters.remove(at: index)
                    continuation.resume(throwing: FileSourceFailure("FTP 服务器响应超时"))
                }
            }
        }
    }

    /// 数据连接：收全部字节直到对端关闭
    func readAllData() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                if let failure = self.failure {
                    continuation.resume(throwing: failure)
                    return
                }
                if self.closed {
                    continuation.resume(returning: Data())
                    return
                }
                self.dataChunks = []
                self.dataWaiter = continuation
            }
        }
    }

    /// 数据连接：逐块回调收到的字节，直到对端关闭（下载大文件用）
    func streamData(_ onChunk: @escaping (Data) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if let failure = self.failure {
                    continuation.resume(throwing: failure)
                    return
                }
                if self.closed {
                    continuation.resume()
                    return
                }
                self.streamHandler = onChunk
                self.streamWaiter = continuation
            }
        }
    }

    func send(_ text: String) {
        connection.send(
            content: Data(text.utf8),
            completion: .contentProcessed { _ in }
        )
    }

    func cancel() {
        connection.cancel()
    }
}

// MARK: - 连接（登录 + 命令）

final class FtpConnection {
    private let channel: FtpLineChannel
    /// 控制连接的服务器地址：PASV 回 0.0.0.0 时回退用它
    private let serverHost: String

    private init(channel: FtpLineChannel, serverHost: String) {
        self.channel = channel
        self.serverHost = serverHost
    }

    static func connect(
        host: String, port: Int, username: String, password: String
    ) async throws -> FtpConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw FileSourceFailure("FTP 端口无效")
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: nwPort, using: .tcp
        )
        let channel = FtpLineChannel(connection: connection)
        let ftp = FtpConnection(channel: channel, serverHost: host)
        do {
            try await channel.start()
            try await ftp.expect([220])
            let user = try await ftp.raw("USER \(username.isEmpty ? "anonymous" : username)")
            if user == 331 {
                let pass = try await ftp.raw("PASS \(password)")
                if pass != 230 {
                    throw FileSourceFailure("账号或密码不正确（服务器返回 \(pass)）")
                }
            } else if user != 230 {
                throw FileSourceFailure("FTP 登录失败（服务器返回 \(user)）")
            }
            _ = try? await ftp.raw("OPTS UTF8 ON")
            _ = try? await ftp.raw("TYPE I")
            return ftp
        } catch {
            channel.cancel()
            throw error
        }
    }

    private func readResponse(timeout: TimeInterval = 25) async throws -> (Int, String) {
        let first = try await channel.nextLine(timeout: timeout)
        let pattern = try! NSRegularExpression(pattern: #"^(\d{3})([ -])"#)
        let range = NSRange(first.startIndex..., in: first)
        guard let match = pattern.firstMatch(in: first, range: range),
              let codeRange = Range(match.range(at: 1), in: first),
              let sepRange = Range(match.range(at: 2), in: first),
              let code = Int(first[codeRange]) else {
            throw FileSourceFailure("FTP 服务器响应异常：\(excerptText(first))")
        }
        var lines = [first]
        if first[sepRange] == "-" {
            while true {
                let line = try await channel.nextLine(timeout: timeout)
                lines.append(line)
                if line.hasPrefix("\(code) ") { break }
            }
        }
        return (code, lines.joined(separator: "\n"))
    }

    private func raw(_ command: String) async throws -> Int {
        channel.send(command + "\r\n")
        return try await readResponse().0
    }

    private func expect(_ ok: Set<Int>) async throws {
        let (code, text) = try await readResponse()
        if !ok.contains(code) {
            throw FileSourceFailure("FTP 服务器返回 \(code)：\(excerptText(text))")
        }
    }

    /// PASV 开数据连接。元组里的地址是 0.0.0.0（或 0. 开头
    /// 的不可路由地址）时回退到控制连接的服务器地址——不少
    /// NAT 后的 FTP 服务器会回这种占位地址（对齐 Flutter 版
    /// B 段偏差清单余项，本轮补齐）。
    private func openData() async throws -> FtpLineChannel {
        channel.send("PASV\r\n")
        let (code, text) = try await readResponse()
        guard code == 227 else {
            throw FileSourceFailure("FTP 服务器不支持被动模式（返回 \(code)）")
        }
        let pattern = try! NSRegularExpression(
            pattern: #"\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)"#
        )
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else {
            throw FileSourceFailure("FTP 被动模式响应无法解析：\(excerptText(text))")
        }
        func group(_ index: Int) -> Int {
            let r = Range(match.range(at: index), in: text)!
            return Int(text[r]) ?? 0
        }
        var dataHost = [group(1), group(2), group(3), group(4)]
            .map(String.init).joined(separator: ".")
        if dataHost == "0.0.0.0" || dataHost.hasPrefix("0.") {
            dataHost = serverHost
        }
        let dataPort = group(5) * 256 + group(6)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(dataPort)) else {
            throw FileSourceFailure("FTP 数据端口无效")
        }
        let dataConnection = NWConnection(
            host: NWEndpoint.Host(dataHost), port: nwPort, using: .tcp
        )
        let dataChannel = FtpLineChannel(connection: dataConnection)
        try await dataChannel.start()
        return dataChannel
    }

    func list(_ dir: String) async throws -> [String] {
        let data = try await openData()
        channel.send("LIST \(dir)\r\n")
        let (prelim, prelimText) = try await readResponse()
        guard [150, 125, 226, 250].contains(prelim) else {
            data.cancel()
            throw FileSourceFailure("FTP 列目录失败（\(prelim)）：\(excerptText(prelimText))")
        }
        let bytes = try await data.readAllData()
        if prelim == 150 || prelim == 125 {
            let (done, doneText) = try await readResponse()
            guard [226, 250].contains(done) else {
                throw FileSourceFailure("FTP 列目录未完成（\(done)）：\(excerptText(doneText))")
            }
        }
        let text = String(data: bytes, encoding: .utf8) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
    }

    func download(
        path: String, to destination: URL,
        progress: @escaping (Int64) -> Void
    ) async throws {
        let data = try await openData()
        channel.send("RETR \(path)\r\n")
        let (prelim, prelimText) = try await readResponse()
        guard [150, 125, 226, 250].contains(prelim) else {
            data.cancel()
            throw FileSourceFailure("FTP 下载失败（\(prelim)）：\(excerptText(prelimText))")
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            data.cancel()
            throw FileSourceFailure("本地文件创建失败")
        }
        var written: Int64 = 0
        var writeFailed = false
        try await data.streamData { chunk in
            do {
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress(written)
            } catch {
                writeFailed = true
            }
        }
        try? handle.close()
        if writeFailed {
            throw FileSourceFailure("本地文件写入失败")
        }
        if prelim == 150 || prelim == 125 {
            let (done, doneText) = try await readResponse()
            guard [226, 250].contains(done) else {
                throw FileSourceFailure("FTP 下载未完成（\(done)）：\(excerptText(doneText))")
            }
        }
    }

    func close() async {
        channel.send("QUIT\r\n")
        _ = try? await readResponse(timeout: 3)
        channel.cancel()
    }
}
