import CommonCrypto
import Foundation

/// 模块桥的加解密/摘要工具：对应 Go module_host.go 的同名 host 函数。
/// 字节在桥上以 base64 字符串过境（见 ModuleRunner 的 shim），这里只管 Data。
enum CryptoUtils {
    enum CryptoError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    static func md5(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { pointer in
            _ = CC_MD5(pointer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }

    static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { pointer in
            _ = CC_SHA256(pointer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }

    static func sha512(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        data.withUnsafeBytes { pointer in
            _ = CC_SHA512(pointer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }

    /// AES-CBC，无填充——与 Go moduleCBC 一致：数据长度必须是 16 的倍数，
    /// 需要填充的模块在 JS 侧自己做（Go 侧同样不垫）。
    static func aesCbc(key: Data, iv: Data, data: Data, encrypt: Bool) throws -> Data {
        guard [16, 24, 32].contains(key.count) else {
            throw CryptoError.message("AES 密钥长度无效")
        }
        guard iv.count == kCCBlockSizeAES128, data.count % kCCBlockSizeAES128 == 0 else {
            throw CryptoError.message("AES 向量或数据长度无效")
        }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputPointer in
            data.withUnsafeBytes { dataPointer in
                key.withUnsafeBytes { keyPointer in
                    iv.withUnsafeBytes { ivPointer in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyPointer.baseAddress, key.count,
                            ivPointer.baseAddress,
                            dataPointer.baseAddress, data.count,
                            outputPointer.baseAddress, outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw CryptoError.message("AES 运算失败（\(status)）")
        }
        output.count = outputLength
        return output
    }

    static func randomBytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= 1024 else {
            throw CryptoError.message("随机字节数无效")
        }
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { pointer in
            SecRandomCopyBytes(kSecRandomDefault, count, pointer.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw CryptoError.message("随机字节生成失败")
        }
        return data
    }
}
