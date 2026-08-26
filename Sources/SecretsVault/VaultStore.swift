import Foundation
import SwiftUI
import AppKit
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
    private var lastBackupRotation = Date.distantPast
    private var autoLockTimer: Timer?
    private var lastActivity = Date()
    private var observers: [NSObjectProtocol] = []

    /// True once the automatic Touch ID prompt has fired for this app launch.
    /// After a re-lock (idle timeout, screen lock, manual lock) the user must
    /// click the Touch ID button instead of being prompted automatically.
    var hasAutoPromptedBiometrics = false

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
        installSecurityObservers()
    }

    // MARK: - System lock triggers & capture protection

    private func installSecurityObservers() {
        let lockIfNeeded: () -> Void = { [weak self] in
            Task { @MainActor in self?.lock() }
        }
        // Screen locked → lock the vault.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { _ in lockIfNeeded() })
        // Mac going to sleep / displays sleeping → lock the vault.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { _ in lockIfNeeded() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main) { _ in lockIfNeeded() })
        // Vault window closed → lock the vault (sheets and panels don't count).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow,
                  !window.isSheet,
                  window.sheetParent == nil,
                  !(window is NSPanel) else { return }
            lockIfNeeded()
        })
        // Exclude every app window from screenshots and screen sharing.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { note in
            (note.object as? NSWindow)?.sharingType = .none
        })
    }

    // MARK: - Setup / unlock / lock

    func createVault(password: String) async {
        do {
            let env = CryptoService.newEnvelope()
            let newKey = try await Task.detached(priority: .userInitiated) {
                try CryptoService.deriveKey(password: password, envelope: env)
            }.value
            key = newKey
            envelope = env
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
                try CryptoService.deriveKey(password: password, envelope: env)
            }.value
            try completeUnlock(env: env, candidate: derived)
            // Transparently upgrade legacy PBKDF2 vaults to Argon2id.
            if env.effectiveKDF != .argon2id {
                do {
                    try await rekey(password: password)
                } catch {
                    errorMessage = "Vault KDF upgrade failed: \(error.localizedDescription)"
                }
            }
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
        purgeExpiredDeleted()
        phase = .unlocked
        selectedDocumentID = data.documents
            .filter { $0.deletedAt == nil }
            .max(by: { $0.updatedAt < $1.updatedAt })?.id
        touchActivity()
        startAutoLockTimer()
    }

    /// Locks the vault. Pass `save: false` to discard in-memory state
    /// without writing it back (used after an import replaces the file).
    func lock(save: Bool = true) {
        guard phase == .unlocked else { return }
        saveTask?.cancel()
        if save { saveNow() }
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
        rotateBackups()
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
            .filter { $0.deletedAt == nil && $0.folderID == folderID }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func searchResults(_ query: String) -> [VaultDocument] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return data.documents
            .filter { $0.deletedAt == nil }
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

    /// Soft delete: the document moves to Recently Deleted, where it stays
    /// recoverable for `deletedRetentionDays` days.
    func deleteDocument(_ id: UUID) {
        guard let idx = data.documents.firstIndex(where: { $0.id == id }) else { return }
        data.documents[idx].deletedAt = Date()
        if selectedDocumentID == id { selectedDocumentID = nil }
        scheduleSave()
    }

    // MARK: - Recently Deleted

    /// Days a deleted document stays recoverable before automatic purge.
    static let deletedRetentionDays = 30

    var deletedDocuments: [VaultDocument] {
        data.documents
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    func restoreDocument(_ id: UUID) {
        guard let idx = data.documents.firstIndex(where: { $0.id == id }) else { return }
        data.documents[idx].deletedAt = nil
        // If its folder was deleted in the meantime, restore to Documents.
        if let folderID = data.documents[idx].folderID,
           !data.folders.contains(where: { $0.id == folderID }) {
            data.documents[idx].folderID = nil
        }
        scheduleSave()
    }

    /// Permanently removes a single document. Not undoable.
    func purgeDocument(_ id: UUID) {
        data.documents.removeAll { $0.id == id }
        if selectedDocumentID == id { selectedDocumentID = nil }
        scheduleSave()
    }

    /// Permanently removes everything in Recently Deleted. Not undoable.
    func emptyRecentlyDeleted() {
        if let sel = selectedDocumentID,
           data.documents.first(where: { $0.id == sel })?.deletedAt != nil {
            selectedDocumentID = nil
        }
        data.documents.removeAll { $0.deletedAt != nil }
        scheduleSave()
    }

    private func purgeExpiredDeleted() {
        let cutoff = Date().addingTimeInterval(-Double(Self.deletedRetentionDays) * 86_400)
        let before = data.documents.count
        data.documents.removeAll {
            guard let deletedAt = $0.deletedAt else { return false }
            return deletedAt < cutoff
        }
        if data.documents.count != before { scheduleSave() }
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
                try CryptoService.deriveKey(password: current, envelope: env)
            }.value
            guard CryptoService.keyData(checkKey) == CryptoService.keyData(existingKey) else {
                return "Current password is incorrect."
            }
            try await rekey(password: new)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Re-encrypts the vault under a fresh Argon2id envelope derived from
    /// `password`, and refreshes the Touch ID keychain entry if enabled.
    private func rekey(password: String) async throws {
        let env = CryptoService.newEnvelope()
        let newKey = try await Task.detached(priority: .userInitiated) {
            try CryptoService.deriveKey(password: password, envelope: env)
        }.value
        key = newKey
        envelope = env
        try persist()
        // Existing backups are encrypted under the previous password/KDF;
        // keeping them around would silently undermine the change.
        deleteAllBackups()
        if biometricsEnabled {
            let kd = CryptoService.keyData(newKey)
            try await Task.detached { try KeychainService.storeKey(kd) }.value
        }
    }

    // MARK: - Backups

    /// Number of rotated backup copies kept alongside the vault file.
    static let backupCount = 5
    /// Minimum time between backup rotations, so a burst of auto-saves
    /// doesn't flush the whole backup history with near-identical copies.
    private static let backupMinInterval: TimeInterval = 5 * 60

    static func backupURL(_ n: Int) -> URL {
        fileURL.appendingPathExtension("\(n)")
    }

    /// Existing backups, newest (.1) first, with their modification dates.
    static func existingBackups() -> [(url: URL, date: Date)] {
        (1...backupCount).compactMap { n in
            let url = backupURL(n)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return (url: url, date: date)
        }
    }

    /// Rotates the current (known-good) vault file into vault.secrets.1 … .N
    /// before it is overwritten, so one corrupted write can never destroy the
    /// only copy. Skipped while the last rotation is recent, unless `force`d.
    private func rotateBackups(force: Bool = false) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.fileURL.path) else { return }
        guard force || Date().timeIntervalSince(lastBackupRotation) >= Self.backupMinInterval else { return }
        try? fm.removeItem(at: Self.backupURL(Self.backupCount))
        for n in stride(from: Self.backupCount - 1, through: 1, by: -1) {
            let from = Self.backupURL(n)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(at: from, to: Self.backupURL(n + 1))
        }
        try? fm.copyItem(at: Self.fileURL, to: Self.backupURL(1))
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: Self.backupURL(1).path)
        lastBackupRotation = Date()
    }

    /// Removes every rotated backup.
    private func deleteAllBackups() {
        for n in 1...Self.backupCount {
            try? FileManager.default.removeItem(at: Self.backupURL(n))
        }
    }

    // MARK: - Export / import

    /// Saves an encrypted copy of the vault — the same format as the vault
    /// file, openable with this vault's master password. Returns success.
    func exportEncryptedVault(to url: URL) -> Bool {
        guard phase == .unlocked else { return false }
        saveNow() // flush pending edits so the copy is current
        do {
            let raw = try Data(contentsOf: Self.fileURL)
            try raw.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
            return true
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Writes every document (except Recently Deleted) into `directory` as
    /// PLAIN, UNENCRYPTED .md files mirroring the folder structure.
    /// Returns the number of files written, or nil on failure.
    func exportMarkdown(to directory: URL) -> Int? {
        guard phase == .unlocked else { return nil }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var folderURLs: [UUID?: URL] = [nil: directory]
            var usedDirNames: Set<String> = []
            for folder in data.folders {
                let name = Self.uniqueName(Self.sanitizedFilename(folder.name), used: &usedDirNames)
                let sub = directory.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                folderURLs[folder.id] = sub
            }
            var written = 0
            var usedNames: [UUID?: Set<String>] = [:]
            for doc in data.documents where doc.deletedAt == nil {
                let dir = folderURLs[doc.folderID] ?? directory
                let base = Self.sanitizedFilename(doc.title.isEmpty ? "Untitled" : doc.title)
                let name = Self.uniqueName(base, used: &usedNames[doc.folderID, default: []])
                let fileURL = dir.appendingPathComponent(name).appendingPathExtension("md")
                try Data(doc.content.utf8).write(to: fileURL, options: [.atomic])
                written += 1
            }
            return written
        } catch {
            errorMessage = "Markdown export failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Replaces the vault file with the contents of `url` — a previous
    /// encrypted export, or a rotated backup. The current vault, if any, is
    /// flushed and force-rotated into backup 1 first. On success the vault
    /// locks; the imported vault's own master password unlocks it.
    /// Returns nil on success, otherwise a user-facing error message.
    func importVault(from url: URL) -> String? {
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            return "Could not read the file: \(error.localizedDescription)"
        }
        guard let env = try? JSONDecoder().decode(VaultEnvelope.self, from: raw),
              !env.salt.isEmpty, !env.ciphertext.isEmpty else {
            return "That file is not a valid Secrets Vault export."
        }
        if phase == .unlocked { saveNow() }
        rotateBackups(force: true)
        do {
            try raw.write(to: Self.fileURL, options: [.atomic])
        } catch {
            return "Import failed: \(error.localizedDescription)"
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.fileURL.path)
        // The Touch ID key in the keychain unlocks the replaced vault, not
        // the imported one — drop it.
        if biometricsEnabled {
            KeychainService.deleteKey()
            biometricsEnabled = false
            UserDefaults.standard.set(false, forKey: Self.biometricsKey)
        }
        if phase == .unlocked {
            lock(save: false) // don't overwrite the imported file with old data
        } else {
            phase = .locked
        }
        return nil
    }

    private static func sanitizedFilename(_ name: String) -> String {
        var cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        cleaned = String(cleaned.prefix(120))
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Returns `base`, or "base 2", "base 3", … so names stay unique on a
    /// case-insensitive file system; records the result in `used`.
    private static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var name = base
        var n = 2
        while used.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        used.insert(name.lowercased())
        return name
    }
}
