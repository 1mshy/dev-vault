import Foundation
import Security
import CryptoKit
import CommonCrypto

/// On-disk file format: JSON envelope around the AES-GCM ciphertext.
struct VaultEnvelope: Codable {
    var version: Int
    var salt: Data
    var iterations: Int
    var ciphertext: Data
}

enum CryptoError: Error, LocalizedError {
    case keyDerivationFailed
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .keyDerivationFailed: return "Key derivation failed."
        case .encryptionFailed: return "Could not encrypt the vault."
        case .decryptionFailed: return "Could not decrypt the vault. Wrong password?"
        }
    }
}

enum CryptoService {
    static let defaultIterations = 600_000

    static func randomSalt(count: Int = 32) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// PBKDF2-HMAC-SHA256 -> 256-bit AES key.
    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let passwordBytes: [Int8] = password.utf8.map { Int8(bitPattern: $0) }
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes, passwordBytes.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations),
            &derived, derived.count
        )
        guard status == Int32(kCCSuccess) else { throw CryptoError.keyDerivationFailed }
        return SymmetricKey(data: Data(derived))
    }

    static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.encryptionFailed }
        return combined
    }

    static func decrypt(_ combined: Data, key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
