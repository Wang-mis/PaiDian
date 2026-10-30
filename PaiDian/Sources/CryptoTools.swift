import Foundation
import CryptoKit
import CommonCrypto
import Security

enum CryptoTools {
    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func aes(_ data: Data, mode: String, key: Data, iv: Data, pkcs7: Bool? = nil) throws -> Data {
        guard key.count == 16, ["aes-128-cbc", "aes-128-ecb"].contains(mode), mode == "aes-128-ecb" || iv.count == 16 else { throw AppFailure.make("不支持的 AES 参数", code: "unsupportedAPI", module: "crypto") }
        var output = Data(count: data.count + kCCBlockSizeAES128); var length = 0
        let padding = pkcs7 ?? (mode == "aes-128-cbc")
        guard padding || data.count % 16 == 0 else { throw AppFailure.make("AES-ECB 无填充模式需要完整分组",module:"crypto") }
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions((padding ? kCCOptionPKCS7Padding : 0) | (mode == "aes-128-ecb" ? kCCOptionECBMode : 0)), keyBytes.baseAddress, key.count, iv.isEmpty ? nil : ivBytes.baseAddress, input.baseAddress, data.count, out.baseAddress, capacity, &length)
        } } } }
        guard status == kCCSuccess else { throw AppFailure.make("AES 加密失败", module: "crypto") }; output.count = length; return output
    }
    static func random(_ count: Int) throws -> Data {
        guard (0...65_536).contains(count) else { throw AppFailure.make("随机数据长度无效", module: "crypto") }
        var bytes = [UInt8](repeating: 0, count: count); guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw AppFailure.make("生成随机数据失败", module: "crypto") }; return Data(bytes)
    }
    static func rsa(_ data: Data, pem: String) throws -> Data {
        let base64 = pem.replacingOccurrences(of:"-----BEGIN PUBLIC KEY-----",with:"").replacingOccurrences(of:"-----END PUBLIC KEY-----",with:"").replacingOccurrences(of:"-----BEGIN RSA PUBLIC KEY-----",with:"").replacingOccurrences(of:"-----END RSA PUBLIC KEY-----",with:"").filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: base64) else { throw AppFailure.make("RSA 公钥无效", module: "crypto") }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        var key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error)
        if key == nil, let raw = unwrapSPKI(der) { key = SecKeyCreateWithData(raw as CFData, attributes as CFDictionary, &error) }
        guard let key else { throw AppFailure.make("无法读取 RSA 公钥", module: "crypto") }
        let size = SecKeyGetBlockSize(key); guard data.count <= size else { throw AppFailure.make("RSA 输入过长", module: "crypto") }
        let padded = Data(repeating: 0, count: size - data.count) + data
        guard let output = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, padded as CFData, &error) else { throw AppFailure.make("RSA 加密失败", module: "crypto") }
        return output as Data
    }
    private static func unwrapSPKI(_ data: Data) -> Data? {
        let bytes = [UInt8](data); var cursor = 0
        func tlv() -> (UInt8, Range<Int>)? {
            guard cursor + 2 <= bytes.count else { return nil }; let tag = bytes[cursor]; cursor += 1; var length = Int(bytes[cursor]); cursor += 1
            if length & 128 != 0 { let count = length & 127; guard count > 0 && count <= 4 && cursor + count <= bytes.count else { return nil }; length = 0; for _ in 0..<count { length = length * 256 + Int(bytes[cursor]); cursor += 1 } }
            guard cursor + length <= bytes.count else { return nil }; let range = cursor..<(cursor + length); cursor += length; return (tag, range)
        }
        guard let outer = tlv(), outer.0 == 0x30 else { return nil }; cursor = outer.1.lowerBound
        guard let algorithm = tlv(), algorithm.0 == 0x30, let bits = tlv(), bits.0 == 3, bits.1.count > 1, bytes[bits.1.lowerBound] == 0 else { return nil }
        return Data(bytes[(bits.1.lowerBound + 1)..<bits.1.upperBound])
    }
}
