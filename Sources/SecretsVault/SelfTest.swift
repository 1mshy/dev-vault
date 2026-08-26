import Foundation

/// Headless crypto sanity check, run with `SecretsVault --selftest`.
/// Verifies Argon2id determinism, AES-GCM round-trip, wrong-key rejection,
/// and legacy (v1/PBKDF2) envelope decoding.
enum SelfTest {
    static func runAndExit() -> Never {
        do {
            var env = CryptoService.newEnvelope()
            let key1 = try CryptoService.deriveKey(password: "correct horse battery", envelope: env)
            let key2 = try CryptoService.deriveKey(password: "correct horse battery", envelope: env)
            guard CryptoService.keyData(key1) == CryptoService.keyData(key2) else {
                print("SELFTEST FAIL: Argon2id derivation not deterministic"); exit(1)
            }
            let plain = Data("vault-selftest-payload".utf8)
            env.ciphertext = try CryptoService.encrypt(plain, key: key1)
            let out = try CryptoService.decrypt(env.ciphertext, key: key1)
            guard out == plain else {
                print("SELFTEST FAIL: AES-GCM round-trip mismatch"); exit(1)
            }
            let wrongKey = try CryptoService.deriveKey(password: "wrong password", envelope: env)
            if (try? CryptoService.decrypt(env.ciphertext, key: wrongKey)) != nil {
                print("SELFTEST FAIL: wrong key decrypted the vault"); exit(1)
            }
            // Legacy v1 envelope must decode and derive via PBKDF2.
            let saltB64 = Data(repeating: 0, count: 32).base64EncodedString()
            let legacyJSON = "{\"version\":1,\"salt\":\"\(saltB64)\",\"iterations\":1000,\"ciphertext\":\"\"}"
            let legacy = try JSONDecoder().decode(VaultEnvelope.self, from: Data(legacyJSON.utf8))
            guard legacy.effectiveKDF == .pbkdf2 else {
                print("SELFTEST FAIL: legacy envelope did not map to PBKDF2"); exit(1)
            }
            _ = try CryptoService.deriveKey(password: "x", envelope: legacy)
            print("SELFTEST OK")
            exit(0)
        } catch {
            print("SELFTEST FAIL: \(error)")
            exit(1)
        }
    }
}
