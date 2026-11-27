import Foundation

/// 最小 ZIP 读取器：模块安装包用（对应 Go archive/zip 在 module_install.go 的用法）。
/// 只支持 store(0) 与 deflate(8) 两种条目；deflate 解压为内置的纯 Swift inflate，
/// 不依赖第三方库。包体积上限由调用方控制（Go 侧为 8MB）。
struct ZipArchive {
    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var dataOffset: Int
        var encrypted: Bool
    }

    enum ZipError: Error, CustomStringConvertible, LocalizedError {
        case message(String)
        var description: String {
            switch self {
            case .message(let text): return text
            }
        }
        var errorDescription: String? { description }
    }

    private let bytes: [UInt8]
    let entries: [Entry]

    init(data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        self.entries = try Self.parseCentralDirectory(bytes)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    private static func parseCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        // EOCD 记录在文件尾（最长 22 + 65535 注释），从后向前找签名 0x06054b50
        let tail = max(0, bytes.count - 22 - 65_535)
        var eocd = -1
        var index = bytes.count - 22
        while index >= tail {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B,
               bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                eocd = index
                break
            }
            index -= 1
        }
        guard eocd >= 0 else {
            throw ZipError.message("安装包不是有效的 zip 文件")
        }
        let total = u16(bytes, eocd + 10)
        var cursor = u32(bytes, eocd + 16)
        var entries: [Entry] = []
        for _ in 0..<total {
            guard cursor + 46 <= bytes.count,
                  bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4B,
                  bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else {
                throw ZipError.message("安装包不是有效的 zip 文件")
            }
            let flags = u16(bytes, cursor + 8)
            let method = UInt16(u16(bytes, cursor + 10))
            var compressed = u32(bytes, cursor + 20)
            var uncompressed = u32(bytes, cursor + 24)
            let nameLength = u16(bytes, cursor + 28)
            let extraLength = u16(bytes, cursor + 30)
            let commentLength = u16(bytes, cursor + 32)
            var localOffset = u32(bytes, cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else {
                throw ZipError.message("安装包不是有效的 zip 文件")
            }
            let nameBytes = Array(bytes[nameStart..<nameStart + nameLength])
            // 与 Go modulePackageFiles 一致：反斜杠转正斜杠，只剥一层前导 "./"
            var name = String(decoding: nameBytes, as: UTF8.self)
                .replacingOccurrences(of: "\\", with: "/")
            if name.hasPrefix("./") {
                name = String(name.dropFirst(2))
            }
            // ZIP64 扩展字段（0x0001）：按需覆盖 0xFFFFFFFF 占位值
            var extraCursor = nameStart + nameLength
            let extraEnd = extraCursor + extraLength
            while extraCursor + 4 <= extraEnd {
                let fieldId = u16(bytes, extraCursor)
                let fieldSize = u16(bytes, extraCursor + 2)
                if fieldId == 0x0001 {
                    var valueCursor = extraCursor + 4
                    func take64() -> Int {
                        defer { valueCursor += 8 }
                        return u32(bytes, valueCursor) | u32(bytes, valueCursor + 4) << 32
                    }
                    if uncompressed == 0xFFFF_FFFF { uncompressed = take64() }
                    if compressed == 0xFFFF_FFFF { compressed = take64() }
                    if localOffset == 0xFFFF_FFFF { localOffset = take64() }
                }
                extraCursor += 4 + fieldSize
            }
            // 本地头：跳过签名+固定字段+文件名+扩展字段得到数据起点
            guard localOffset + 30 <= bytes.count,
                  bytes[localOffset] == 0x50, bytes[localOffset + 1] == 0x4B,
                  bytes[localOffset + 2] == 0x03, bytes[localOffset + 3] == 0x04 else {
                throw ZipError.message("安装包不是有效的 zip 文件")
            }
            let localName = u16(bytes, localOffset + 26)
            let localExtra = u16(bytes, localOffset + 28)
            let dataOffset = localOffset + 30 + localName + localExtra
            entries.append(Entry(
                name: name,
                method: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                dataOffset: dataOffset,
                encrypted: flags & 0x1 != 0
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    func extract(_ entry: Entry) throws -> Data {
        guard !entry.encrypted else {
            throw ZipError.message("安装包里的文件经过加密，无法读取")
        }
        guard entry.dataOffset + entry.compressedSize <= bytes.count else {
            throw ZipError.message("安装包不是有效的 zip 文件")
        }
        let packed = Array(bytes[entry.dataOffset..<entry.dataOffset + entry.compressedSize])
        switch entry.method {
        case 0:
            return Data(packed)
        case 8:
            guard let plain = Inflate.decompress(packed, expectedSize: entry.uncompressedSize),
                  plain.count == entry.uncompressedSize else {
                throw ZipError.message("无法解压安装包里的文件")
            }
            return Data(plain)
        default:
            throw ZipError.message("安装包用了不支持的压缩方式（\(entry.method)）")
        }
    }
}

/// RFC 1951 DEFLATE 解压（puff 式 Huffman 解码）。
enum Inflate {
    private final class BitReader {
        let data: [UInt8]
        var index = 0
        var bitBuffer = 0
        var bitCount = 0
        var exhausted = false

        init(_ data: [UInt8]) { self.data = data }

        func bits(_ need: Int) -> Int {
            while bitCount < need {
                guard index < data.count else {
                    exhausted = true
                    return 0
                }
                bitBuffer |= Int(data[index]) << bitCount
                index += 1
                bitCount += 8
            }
            let value = bitBuffer & ((1 << need) - 1)
            bitBuffer >>= need
            bitCount -= need
            return value
        }

        func alignToByte() {
            bitBuffer = 0
            bitCount = 0
        }

        func byte() -> Int {
            guard index < data.count else {
                exhausted = true
                return 0
            }
            defer { index += 1 }
            return Int(data[index])
        }
    }

    private struct Huffman {
        var counts: [Int]   // 每码长（1...15）的符号数，下标 0 不用
        var symbols: [Int]  // 按（码长、原序）排列的符号

        /// 拒绝过订阅码；不完整码允许（使用未定义的码字会在解码时失败），
        /// 与 puff 对动态距离码的处理一致。
        init?(lengths: [Int]) {
            var counts = [Int](repeating: 0, count: 16)
            for length in lengths {
                guard length >= 0, length <= 15 else { return nil }
                counts[length] += 1
            }
            var left = 1
            for length in 1...15 {
                left <<= 1
                left -= counts[length]
                if left < 0 { return nil }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 {
                offsets[length + 1] = offsets[length] + counts[length]
            }
            var symbols = [Int](repeating: 0, count: lengths.count - counts[0])
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
            self.counts = counts
            self.symbols = symbols
        }

        func decode(_ reader: BitReader) -> Int {
            var code = 0
            var first = 0
            var index = 0
            for length in 1...15 {
                code |= reader.bits(1)
                if reader.exhausted { return -1 }
                let count = counts[length]
                if code - count < first {
                    return symbols[index + (code - first)]
                }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            return -1
        }
    }

    private static let lengthBase = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtra = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    private static let distanceBase = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577,
    ]
    private static let distanceExtra = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
    private static let codeLengthOrder = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    static func decompress(_ input: [UInt8], expectedSize: Int) -> [UInt8]? {
        let reader = BitReader(input)
        var output: [UInt8] = []
        if expectedSize > 0 {
            output.reserveCapacity(expectedSize)
        }
        while true {
            let isFinal = reader.bits(1)
            let blockType = reader.bits(2)
            if reader.exhausted { return nil }
            switch blockType {
            case 0:
                reader.alignToByte()
                let length = reader.byte() | reader.byte() << 8
                let complement = reader.byte() | reader.byte() << 8
                guard length == (~complement & 0xFFFF) else { return nil }
                for _ in 0..<length {
                    output.append(UInt8(reader.byte()))
                    if reader.exhausted { return nil }
                }
            case 1:
                var literalLengths = [Int](repeating: 0, count: 288)
                for i in 0..<144 { literalLengths[i] = 8 }
                for i in 144..<256 { literalLengths[i] = 9 }
                for i in 256..<280 { literalLengths[i] = 7 }
                for i in 280..<288 { literalLengths[i] = 8 }
                guard let literals = Huffman(lengths: literalLengths),
                      let distances = Huffman(lengths: [Int](repeating: 5, count: 30)),
                      inflateBlock(reader, literals, distances, &output) else {
                    return nil
                }
            case 2:
                guard let tables = dynamicTables(reader),
                      inflateBlock(reader, tables.literals, tables.distances, &output) else {
                    return nil
                }
            default:
                return nil
            }
            if expectedSize > 0, output.count > expectedSize { return nil }
            if isFinal == 1 { break }
        }
        return output
    }

    private static func dynamicTables(
        _ reader: BitReader
    ) -> (literals: Huffman, distances: Huffman)? {
        let literalCount = reader.bits(5) + 257
        let distanceCount = reader.bits(5) + 1
        let codeCount = reader.bits(4) + 4
        var codeLengths = [Int](repeating: 0, count: 19)
        for i in 0..<codeCount {
            codeLengths[codeLengthOrder[i]] = reader.bits(3)
        }
        guard let codeHuffman = Huffman(lengths: codeLengths) else { return nil }
        var lengths = [Int](repeating: 0, count: literalCount + distanceCount)
        var index = 0
        while index < lengths.count {
            let symbol = codeHuffman.decode(reader)
            switch symbol {
            case 0...15:
                lengths[index] = symbol
                index += 1
            case 16:
                guard index > 0 else { return nil }
                let previous = lengths[index - 1]
                let repeatCount = reader.bits(2) + 3
                for _ in 0..<repeatCount {
                    guard index < lengths.count else { return nil }
                    lengths[index] = previous
                    index += 1
                }
            case 17:
                index += reader.bits(3) + 3
            case 18:
                index += reader.bits(7) + 11
            default:
                return nil
            }
            if index > lengths.count { return nil }
        }
        guard let literals = Huffman(lengths: Array(lengths[..<literalCount])),
              let distances = Huffman(lengths: Array(lengths[literalCount...])) else {
            return nil
        }
        return (literals, distances)
    }

    private static func inflateBlock(
        _ reader: BitReader,
        _ literals: Huffman,
        _ distances: Huffman,
        _ output: inout [UInt8]
    ) -> Bool {
        while true {
            let symbol = literals.decode(reader)
            if symbol < 0 { return false }
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return true
            } else {
                let lengthIndex = symbol - 257
                guard lengthIndex < lengthBase.count else { return false }
                let length = lengthBase[lengthIndex] + reader.bits(lengthExtra[lengthIndex])
                let distanceSymbol = distances.decode(reader)
                guard distanceSymbol >= 0, distanceSymbol < distanceBase.count else {
                    return false
                }
                let distance = distanceBase[distanceSymbol]
                    + reader.bits(distanceExtra[distanceSymbol])
                guard distance <= output.count else { return false }
                var from = output.count - distance
                for _ in 0..<length {
                    output.append(output[from])
                    from += 1
                }
            }
            if reader.exhausted { return false }
        }
    }
}
