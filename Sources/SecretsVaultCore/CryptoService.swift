import Foundation
import Security
import CryptoKit
import CommonCrypto
import Sodium

public enum KDF: String, Codable {
    case pbkdf2 = "pbkdf2-hmac-sha256"
    case argon2id = "argon2id"
}

/// On-disk file format: JSON envelope around the AES-GCM ciphertext.
/// v1 files have no `kdf`/`memLimitBytes` fields and use PBKDF2;
/// v2 files use Argon2id. v1 vaults are migrated on password unlock.
public struct VaultEnvelope: Codable {
    public var version: Int
    public var kdf: KDF?
    public var salt: Data
    public var iterations: Int      // PBKDF2 iterations, or Argon2id opsLimit
    public var memLimitBytes: Int?  // Argon2id only
    public var ciphertext: Data

    public init(version: Int, kdf: KDF?, salt: Data, iterations: Int,
                memLimitBytes: Int?, ciphertext: Data) {
        self.version = version
        self.kdf = kdf
        self.salt = salt
        self.iterations = iterations
        self.memLimitBytes = memLimitBytes
        self.ciphertext = ciphertext
    }

    public var effectiveKDF: KDF { kdf ?? .pbkdf2 }
}

public enum CryptoError: Error, LocalizedError {
    case keyDerivationFailed
    case encryptionFailed
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .keyDerivationFailed: return "Key derivation failed."
        case .encryptionFailed: return "Could not encrypt the vault."
        case .decryptionFailed: return "Could not decrypt the vault. Wrong password?"
        }
    }
}

public enum CryptoService {
    // Legacy (v1) parameters.
    public static let pbkdf2Iterations = 600_000

    // Argon2id parameters — libsodium "moderate": ops 3, 256 MB.
    public static let argon2OpsLimit = 3
    public static let argon2MemLimitBytes = 268_435_456
    public static let argon2SaltBytes = 16

    private static let sodium = Sodium()

    public static func randomSalt(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// A fresh v2 (Argon2id) envelope with empty ciphertext.
    public static func newEnvelope() -> VaultEnvelope {
        VaultEnvelope(
            version: 2,
            kdf: .argon2id,
            salt: randomSalt(count: argon2SaltBytes),
            iterations: argon2OpsLimit,
            memLimitBytes: argon2MemLimitBytes,
            ciphertext: Data()
        )
    }

    public static func deriveKey(password: String, envelope: VaultEnvelope) throws -> SymmetricKey {
        switch envelope.effectiveKDF {
        case .pbkdf2:
            return try derivePBKDF2(password: password,
                                    salt: envelope.salt,
                                    iterations: envelope.iterations)
        case .argon2id:
            return try deriveArgon2id(password: password,
                                      salt: envelope.salt,
                                      opsLimit: envelope.iterations,
                                      memLimitBytes: envelope.memLimitBytes ?? argon2MemLimitBytes)
        }
    }

    public static func deriveArgon2id(password: String, salt: Data, opsLimit: Int, memLimitBytes: Int) throws -> SymmetricKey {
        guard salt.count == argon2SaltBytes,
              let out = sodium.pwHash.hash(outputLength: 32,
                                           passwd: Array(password.utf8),
                                           salt: [UInt8](salt),
                                           opsLimit: opsLimit,
                                           memLimit: memLimitBytes,
                                           alg: .Argon2ID13) else {
            throw CryptoError.keyDerivationFailed
        }
        return SymmetricKey(data: Data(out))
    }

    /// Legacy PBKDF2-HMAC-SHA256 (v1 vaults only).
    public static func derivePBKDF2(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
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

    public static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.encryptionFailed }
        return combined
    }

    public static func decrypt(_ combined: Data, key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    public static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
