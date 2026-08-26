import Foundation
import SwiftUI
import CryptoKit
import LocalAuthentication

@MainActor
final class VaultStore: ObservableObject {

    enum Phase: Equatable {
        case needsSetup
        case locked
        case unlocked
    }

    @Published var phase: Phase
    @Published var data = VaultData()
    @Published var selectedDocumentID: UUID?
    @Published var errorMessage: String?
    @Published var biometricsEnabled: Bool
    @Published var autoLockMinutes: Int {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: Self.autoLockKey) }
    }

    private var key: SymmetricKey?
    private var envelope: VaultEnvelope?
    private var saveTask: Task<Void, Never>?
    private var autoLockTimer: Timer?
    private var lastActivity = Date()

    private static let biometricsKey = "biometricsEnabled"
    private static let autoLockKey = "autoLockMinutes"

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecretsVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vault.secrets")
    }

    init() {
        biometricsEnabled = UserDefaults.standard.bool(forKey: Self.biometricsKey)
        autoLockMinutes = (UserDefaults.standard.object(forKey: Self.autoLockKey) as? Int) ?? 10
        phase = FileManager.default.fileExists(atPath: Self.fileURL.path) ? .locked : .needsSetup
    }

    // MARK: - Setup / unlock / lock

    func createVault(password: String) async {
        do {
            let salt = CryptoService.randomSalt()
            let iterations = CryptoService.defaultIterations
            let newKey = try await Task.detached(priority: .userInitiated) {
                try CryptoService.deriveKey(password: password, salt: salt, iterations: iterations)
            }.value
            key = newKey
            envelope = VaultEnvelope(version: 1, salt: salt, iterations: iterations, ciphertext: Data())
            data = VaultData.starter()
            try persist()
            phase = .unlocked
            selectedDocumentID = data.documents.first?.id
            touchActivity()
            startAutoLockTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlock(password: String) async {
        do {
            let env = try readEnvelope()
            let derived = try await Task.detached(priority: .userInitiated) {
                try CryptoService.deriveKey(password: password, salt: env.salt, iterations: env.iterations)
            }.value
            try completeUnlock(env: env, candidate: derived)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlockWithBiometrics() async {
        guard biometricsEnabled else { return }
        do {
            let env = try readEnvelope()
            let keyData = try await KeychainService.fetchKey(reason: "unlock your vault")
            try completeUnlock(env: env, candidate: SymmetricKey(data: keyData))
        } catch KeychainError.userCanceled {
            // The user dismissed the Touch ID prompt; not an error.
        } catch let e as LAError where e.code == .userCancel || e.code == .systemCancel || e.code == .appCancel {
            // Same: dismissal, not failure.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func completeUnlock(env: VaultEnvelope, candidate: SymmetricKey) throws {
        let plaintext = try CryptoService.decrypt(env.ciphertext, key: candidate)
        let decoded = try JSONDecoder().decode(VaultData.self, from: plaintext)
        key = candidate
        envelope = env
        data = decoded
        phase = .unlocked
        selectedDocumentID = decoded.documents.max(by: { $0.updatedAt < $1.updatedAt })?.id
        touchActivity()
        startAutoLockTimer()
    }

    func lock() {
        guard phase == .unlocked else { return }
        saveTask?.cancel()
        saveNow()
        key = nil
        data = VaultData()
        selectedDocumentID = nil
        phase = .locked
        autoLockTimer?.invalidate()
        autoLockTimer = nil
    }

    // MARK: - Persistence

    private func readEnvelope() throws -> VaultEnvelope {
        let raw = try Data(contentsOf: Self.fileURL)
        return try JSONDecoder().decode(VaultEnvelope.self, from: raw)
    }

    private func persist() throws {
        guard let key, var env = envelope else { return }
        let plaintext = try JSONEncoder().encode(data)
        env.ciphertext = try CryptoService.encrypt(plaintext, key: key)
        envelope = env
        let envData = try JSONEncoder().encode(env)
        try envData.write(to: Self.fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.fileURL.path)
    }

    func scheduleSave() {
        touchActivity()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try persist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Auto-lock

    func touchActivity() {
        lastActivity = Date()
    }

    private func startAutoLockTimer() {
        autoLockTimer?.invalidate()
        autoLockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAutoLock() }
        }
    }

    private func checkAutoLock() {
        guard phase == .unlocked, autoLockMinutes > 0 else { return }
        if Date().timeIntervalSince(lastActivity) >= Double(autoLockMinutes * 60) {
            lock()
        }
    }

    // MARK: - Documents & folders

    func documents(in folderID: UUID?) -> [VaultDocument] {
        data.documents
            .filter { $0.folderID == folderID }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func searchResults(_ query: String) -> [VaultDocument] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return data.documents
            .filter { $0.title.localizedCaseInsensitiveContains(q) || $0.content.localizedCaseInsensitiveContains(q) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func addDocument(in folderID: UUID?) {
        guard phase == .unlocked else { return }
        let doc = VaultDocument(title: "Untitled", content: "", folderID: folderID)
        data.documents.append(doc)
        selectedDocumentID = doc.id
        scheduleSave()
    }

    func deleteDocument(_ id: UUID) {
        data.documents.removeAll { $0.id == id }
        if selectedDocumentID == id { selectedDocumentID = nil }
        scheduleSave()
    }

    func moveDocument(_ id: UUID, to folderID: UUID?) {
        guard let idx = data.documents.firstIndex(where: { $0.id == id }) else { return }
        data.documents[idx].folderID = folderID
        scheduleSave()
    }

    func addFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        data.folders.append(VaultFolder(name: trimmed))
        scheduleSave()
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let idx = data.folders.firstIndex(where: { $0.id == id }) else { return }
        data.folders[idx].name = trimmed
        scheduleSave()
    }

    func deleteFolder(_ id: UUID) {
        for i in data.documents.indices where data.documents[i].folderID == id {
            data.documents[i].folderID = nil
        }
        data.folders.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Security settings

    func setBiometrics(_ enabled: Bool) async {
        if enabled {
            guard let key else {
                errorMessage = "Unlock the vault first."
                return
            }
            let kd = CryptoService.keyData(key)
            do {
                try await Task.detached { try KeychainService.storeKey(kd) }.value
                biometricsEnabled = true
            } catch {
                errorMessage = "Could not enable Touch ID: \(error.localizedDescription)"
                biometricsEnabled = false
            }
        } else {
            KeychainService.deleteKey()
            biometricsEnabled = false
        }
        UserDefaults.standard.set(biometricsEnabled, forKey: Self.biometricsKey)
    }

    /// Returns nil on success, otherwise a user-facing error message.
    func changePassword(current: String, new: String) async -> String? {
        guard let env = envelope, let existingKey = key else { return "Vault is locked." }
        do {
            let checkKey = try await Task.detached { [env] in
                try CryptoService.deriveKey(password: current, salt: env.salt, iterations: env.iterations)
            }.value
            guard CryptoService.keyData(checkKey) == CryptoService.keyData(existingKey) else {
                return "Current password is incorrect."
            }
            let salt = CryptoService.randomSalt()
            let iterations = CryptoService.defaultIterations
            let newKey = try await Task.detached {
                try CryptoService.deriveKey(password: new, salt: salt, iterations: iterations)
            }.value
            key = newKey
            envelope = VaultEnvelope(version: 1, salt: salt, iterations: iterations, ciphertext: Data())
            try persist()
            if biometricsEnabled {
                let kd = CryptoService.keyData(newKey)
                try await Task.detached { try KeychainService.storeKey(kd) }.value
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
