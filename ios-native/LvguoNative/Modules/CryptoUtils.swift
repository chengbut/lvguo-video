import CommonCrypto
import CryptoKit
import Foundation

/// 模块桥的加解密/摘要工具：对应 Go module_host.go 的同名 host 函数。
/// 字节在桥上以 base64 字符串过境（见 ModuleRunner 的 shim），这里只管 Data。
enum CryptoUtils {
    enum CryptoError: Error, CustomStringConvertible, LocalizedError {
        case message(String)
        var description: String {
            switch self {
            case .message(let text): return text
            }
        }
        var errorDescription: String? { description }
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

    // MARK: - AES-GCM（对应 Go moduleGCM + aesGcmSeal/Open）

    /// Go 的 Seal 返回 ciphertext||tag（不带 nonce）；CryptoKit 的
    /// SealedBox 分开给 ciphertext 与 tag，这里拼回 Go 的形状。
    static func aesGcmSeal(key: Data, nonce: Data, plain: Data, extra: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count) else {
            throw CryptoError.message("AES 密钥长度无效")
        }
        guard nonce.count == 12 else {
            throw CryptoError.message("AES-GCM 随机数长度无效")
        }
        do {
            let box = try AES.GCM.seal(
                plain,
                using: SymmetricKey(data: key),
                nonce: AES.GCM.Nonce(data: nonce),
                authenticating: extra
            )
            return box.ciphertext + box.tag
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.message("AES-GCM 加密失败")
        }
    }

    static func aesGcmOpen(key: Data, nonce: Data, sealed: Data, extra: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count) else {
            throw CryptoError.message("AES 密钥长度无效")
        }
        guard nonce.count == 12 else {
            throw CryptoError.message("AES-GCM 随机数长度无效")
        }
        guard sealed.count >= 16 else {
            throw CryptoError.message("AES-GCM 校验失败")
        }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: sealed.dropLast(16),
                tag: sealed.suffix(16)
            )
            return try AES.GCM.open(
                box, using: SymmetricKey(data: key), authenticating: extra
            )
        } catch {
            throw CryptoError.message("AES-GCM 校验失败")
        }
    }

    // MARK: - ECDH P-256（对应 Go ecdhP256KeyPair / ecdhP256）

    /// Go 的公钥 Bytes() 是 SEC1 未压缩点（0x04 前缀 + X + Y，65 字节），
    /// CryptoKit 的 rawRepresentation 是 X + Y（64 字节），互转时增删前缀；
    /// 私钥两边都是 32 字节标量。协商结果两边都是共享点的 X 坐标。
    static func ecdhP256KeyPair() throws -> (privateKey: Data, publicKey: Data) {
        let key = P256.KeyAgreement.PrivateKey()
        return (
            privateKey: key.rawRepresentation,
            publicKey: Data([0x04]) + key.publicKey.rawRepresentation
        )
    }

    static func ecdhP256(privateKey: Data, publicKey: Data) throws -> Data {
        let privateKeyObject: P256.KeyAgreement.PrivateKey
        do {
            privateKeyObject = try P256.KeyAgreement.PrivateKey(
                rawRepresentation: privateKey
            )
        } catch {
            throw CryptoError.message("ECDH 私钥无效")
        }
        var publicRaw = publicKey
        if publicRaw.count == 65, publicRaw.first == 0x04 {
            publicRaw = publicRaw.dropFirst()
        }
        let publicKeyObject: P256.KeyAgreement.PublicKey
        do {
            publicKeyObject = try P256.KeyAgreement.PublicKey(
                rawRepresentation: publicRaw
            )
        } catch {
            throw CryptoError.message("ECDH 公钥无效")
        }
        do {
            let secret = try privateKeyObject.sharedSecretFromKeyAgreement(
                with: publicKeyObject
            )
            return secret.withUnsafeBytes { Data($0) }
        } catch {
            throw CryptoError.message("ECDH 协商失败")
        }
    }

    // MARK: - HKDF-SHA256（对应 Go hkdfSha256）

    static func hkdfSha256(secret: Data, salt: Data, info: Data, length: Int) throws -> Data {
        guard length >= 1, length <= 1024 else {
            throw CryptoError.message("HKDF 长度无效")
        }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
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
