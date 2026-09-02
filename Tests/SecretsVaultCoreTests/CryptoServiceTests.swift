import XCTest
import CryptoKit
import SecretsVaultCore

final class CryptoServiceTests: XCTestCase {

    /// Argon2id at libsodium's minimum cost so the suite stays fast. The
    /// production parameters are exercised once in
    /// `testProductionEnvelopeRoundTrip`.
    private func fastEnvelope(salt: Data? = nil) -> VaultEnvelope {
        VaultEnvelope(version: 2, kdf: .argon2id,
                      salt: salt ?? CryptoService.randomSalt(count: CryptoService.argon2SaltBytes),
                      iterations: 1, memLimitBytes: 8 * 1024 * 1024, ciphertext: Data())
    }

    private func bytes(_ key: SymmetricKey) -> Data { CryptoService.keyData(key) }

    // MARK: Key derivation

    func testArgon2DerivationIsDeterministic() throws {
        let env = fastEnvelope()
        let a = try CryptoService.deriveKey(password: "correct horse battery", envelope: env)
        let b = try CryptoService.deriveKey(password: "correct horse battery", envelope: env)
        XCTAssertEqual(bytes(a), bytes(b))
        XCTAssertEqual(bytes(a).count, 32)
    }

    func testDifferentPasswordsGiveDifferentKeys() throws {
        let env = fastEnvelope()
        let a = try CryptoService.deriveKey(password: "password one", envelope: env)
        let b = try CryptoService.deriveKey(password: "password two", envelope: env)
        XCTAssertNotEqual(bytes(a), bytes(b))
    }

    func testDifferentSaltsGiveDifferentKeys() throws {
        let a = try CryptoService.deriveKey(password: "same", envelope: fastEnvelope())
        let b = try CryptoService.deriveKey(password: "same", envelope: fastEnvelope())
        XCTAssertNotEqual(bytes(a), bytes(b))
    }

    func testArgon2RejectsWrongSaltLength() {
        XCTAssertThrowsError(try CryptoService.deriveArgon2id(
            password: "x", salt: Data(repeating: 1, count: 8), opsLimit: 1, memLimitBytes: 8 * 1024 * 1024))
    }

    func testPBKDF2IsDeterministicAndSaltSensitive() throws {
        let salt = Data(repeating: 7, count: 32)
        let a = try CryptoService.derivePBKDF2(password: "legacy", salt: salt, iterations: 1_000)
        let b = try CryptoService.derivePBKDF2(password: "legacy", salt: salt, iterations: 1_000)
        let c = try CryptoService.derivePBKDF2(password: "legacy", salt: Data(repeating: 8, count: 32), iterations: 1_000)
        XCTAssertEqual(bytes(a), bytes(b))
        XCTAssertNotEqual(bytes(a), bytes(c))
    }

    // MARK: AES-GCM

    func testEncryptDecryptRoundTrip() throws {
        let key = try CryptoService.deriveKey(password: "pw", envelope: fastEnvelope())
        let plain = Data("vault payload with unicode ✓ and \0 bytes".utf8)
        let sealed = try CryptoService.encrypt(plain, key: key)
        XCTAssertNotEqual(sealed, plain)
        XCTAssertEqual(try CryptoService.decrypt(sealed, key: key), plain)
    }

    func testEncryptionUsesFreshNonces() throws {
        let key = try CryptoService.deriveKey(password: "pw", envelope: fastEnvelope())
        let plain = Data("same plaintext".utf8)
        XCTAssertNotEqual(try CryptoService.encrypt(plain, key: key),
                          try CryptoService.encrypt(plain, key: key))
    }

    func testWrongKeyIsRejected() throws {
        let env = fastEnvelope()
        let right = try CryptoService.deriveKey(password: "right", envelope: env)
        let wrong = try CryptoService.deriveKey(password: "wrong", envelope: env)
        let sealed = try CryptoService.encrypt(Data("secret".utf8), key: right)
        XCTAssertThrowsError(try CryptoService.decrypt(sealed, key: wrong)) { error in
            XCTAssertEqual(error as? CryptoError, .decryptionFailed)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let key = try CryptoService.deriveKey(password: "pw", envelope: fastEnvelope())
        var sealed = try CryptoService.encrypt(Data("secret".utf8), key: key)
        let middle = sealed.startIndex + sealed.count / 2
        sealed[middle] ^= 0x01
        XCTAssertThrowsError(try CryptoService.decrypt(sealed, key: key))
    }

    func testTruncatedCiphertextIsRejected() throws {
        let key = try CryptoService.deriveKey(password: "pw", envelope: fastEnvelope())
        let sealed = try CryptoService.encrypt(Data("secret".utf8), key: key)
        XCTAssertThrowsError(try CryptoService.decrypt(sealed.dropLast(1), key: key))
        XCTAssertThrowsError(try CryptoService.decrypt(Data(), key: key))
    }

    // MARK: Envelope format

    func testNewEnvelopeUsesArgon2Defaults() {
        let env = CryptoService.newEnvelope()
        XCTAssertEqual(env.version, 2)
        XCTAssertEqual(env.kdf, .argon2id)
        XCTAssertEqual(env.effectiveKDF, .argon2id)
        XCTAssertEqual(env.salt.count, CryptoService.argon2SaltBytes)
        XCTAssertEqual(env.iterations, CryptoService.argon2OpsLimit)
        XCTAssertEqual(env.memLimitBytes, CryptoService.argon2MemLimitBytes)
        XCTAssertTrue(env.ciphertext.isEmpty)
    }

    func testLegacyEnvelopeWithoutKDFFieldDecodesAsPBKDF2() throws {
        let saltB64 = Data(repeating: 0, count: 32).base64EncodedString()
        let json = #"{"version":1,"salt":"\#(saltB64)","iterations":1000,"ciphertext":""}"#
        let legacy = try JSONDecoder().decode(VaultEnvelope.self, from: Data(json.utf8))
        XCTAssertNil(legacy.kdf)
        XCTAssertEqual(legacy.effectiveKDF, .pbkdf2)
        XCTAssertNil(legacy.memLimitBytes)
        XCTAssertEqual(legacy.iterations, 1000)
        XCTAssertNoThrow(try CryptoService.deriveKey(password: "x", envelope: legacy))
    }

    func testEnvelopeJSONRoundTrip() throws {
        var env = fastEnvelope()
        env.ciphertext = Data([1, 2, 3])
        let data = try JSONEncoder().encode(env)
        let back = try JSONDecoder().decode(VaultEnvelope.self, from: data)
        XCTAssertEqual(back.version, env.version)
        XCTAssertEqual(back.kdf, env.kdf)
        XCTAssertEqual(back.salt, env.salt)
        XCTAssertEqual(back.iterations, env.iterations)
        XCTAssertEqual(back.memLimitBytes, env.memLimitBytes)
        XCTAssertEqual(back.ciphertext, env.ciphertext)
        // The on-disk KDF tag is the stable string, not the Swift case name.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""kdf":"argon2id""#))
    }

    func testProductionEnvelopeRoundTrip() throws {
        var env = CryptoService.newEnvelope()
        let key = try CryptoService.deriveKey(password: "correct horse battery staple", envelope: env)
        let plain = Data("production parameters".utf8)
        env.ciphertext = try CryptoService.encrypt(plain, key: key)
        let again = try CryptoService.deriveKey(password: "correct horse battery staple", envelope: env)
        XCTAssertEqual(try CryptoService.decrypt(env.ciphertext, key: again), plain)
    }

    func testRandomSaltVaries() {
        XCTAssertNotEqual(CryptoService.randomSalt(count: 16), CryptoService.randomSalt(count: 16))
        XCTAssertEqual(CryptoService.randomSalt(count: 16).count, 16)
    }
}
