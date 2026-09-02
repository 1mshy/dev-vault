import Foundation
import SwiftUI
import AppKit
import CryptoKit
import LocalAuthentication
import SecretsVaultCore

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
    @Published var currentVaultName: String {
        didSet { UserDefaults.standard.set(currentVaultName, forKey: Self.currentVaultKey) }
    }
    @Published var availableVaults: [String] = []
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

    private static let legacyBiometricsKey = "biometricsEnabled"
    private static let autoLockKey = "autoLockMinutes"
    private static let currentVaultKey = "currentVault"

    /// Name of the vault a fresh install starts with, and the one the legacy
    /// single-vault file is migrated to.
    static let defaultVaultName = "Main"

    // MARK: - Vault files

    static var directoryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecretsVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for name: String) -> URL {
        directoryURL.appendingPathComponent("\(name).secrets")
    }

    /// The current vault's file on disk.
    var fileURL: URL { Self.fileURL(for: currentVaultName) }

    static func biometricsDefaultsKey(for name: String) -> String {
        "biometricsEnabled.\(name)"
    }

    /// Keychain account holding a vault's Touch ID key. The default vault
    /// keeps the pre-multi-vault account name so existing setups survive.
    static func keychainAccount(for name: String) -> String {
        name == defaultVaultName ? "vault-master-key" : "vault-master-key.\(name)"
    }

    private var keychainAccount: String { Self.keychainAccount(for: currentVaultName) }

    /// Every vault in the storage directory (file name without ".secrets"),
    /// sorted for display. Rotated backups (*.secrets.N) don't match.
    static func scanVaults() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "secrets" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// One-time migration: the pre-multi-vault "vault.secrets" file (and its
    /// backups and Touch ID flag) becomes the vault named `defaultVaultName`.
    private static func migrateLegacyVaultIfNeeded() {
        let fm = FileManager.default
        let legacy = directoryURL.appendingPathComponent("vault.secrets")
        let target = fileURL(for: defaultVaultName)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: target.path) else { return }
        try? fm.moveItem(at: legacy, to: target)
        for n in 1...backupCount {
            let from = legacy.appendingPathExtension("\(n)")
            let to = target.appendingPathExtension("\(n)")
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        // The global Touch ID flag becomes the migrated vault's flag.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: legacyBiometricsKey) != nil {
            defaults.set(defaults.bool(forKey: legacyBiometricsKey),
                         forKey: biometricsDefaultsKey(for: defaultVaultName))
            defaults.removeObject(forKey: legacyBiometricsKey)
        }
    }

    init() {
        Self.migrateLegacyVaultIfNeeded()
        let vaults = Self.scanVaults()
        let saved = UserDefaults.standard.string(forKey: Self.currentVaultKey)
        let name: String
        if let saved, vaults.contains(saved) {
            name = saved
        } else {
            name = vaults.first ?? Self.defaultVaultName
        }
        currentVaultName = name
        availableVaults = vaults
        biometricsEnabled = UserDefaults.standard.bool(forKey: Self.biometricsDefaultsKey(for: name))
        autoLockMinutes = (UserDefaults.standard.object(forKey: Self.autoLockKey) as? Int) ?? 10
        phase = FileManager.default.fileExists(atPath: Self.fileURL(for: name).path) ? .locked : .needsSetup
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
        // Vault window closed → lock the vault. Sheets, panels and borderless
        // transient windows (context menus, tooltips) don't count.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow,
                  !window.isSheet,
                  window.sheetParent == nil,
                  !(window is NSPanel),
                  window.styleMask.contains(.titled) else { return }
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

    /// True when `raw` sanitizes to a usable name no existing vault uses.
    func vaultNameAvailable(_ raw: String) -> Bool {
        let name = VaultNaming.sanitizedVaultName(raw)
        guard !name.isEmpty else { return false }
        return !FileManager.default.fileExists(atPath: Self.fileURL(for: name).path)
    }

    func refreshVaults() {
        availableVaults = Self.scanVaults()
    }

    /// Switches the login page to another (still locked) vault.
    func switchVault(to name: String) {
        guard phase != .unlocked else { return }
        guard FileManager.default.fileExists(atPath: Self.fileURL(for: name).path) else { return }
        key = nil
        envelope = nil
        currentVaultName = name
        biometricsEnabled = UserDefaults.standard.bool(forKey: Self.biometricsDefaultsKey(for: name))
        errorMessage = nil
        phase = .locked
        refreshVaults()
    }

    /// From the login page: show the create-vault screen for an extra vault.
    func beginNewVault() {
        guard phase == .locked else { return }
        phase = .needsSetup
    }

    /// Backs out of creating an extra vault, returning to the login page of
    /// the vault that was selected before.
    func cancelNewVault() {
        guard phase == .needsSetup,
              FileManager.default.fileExists(atPath: fileURL.path) else { return }
        biometricsEnabled = UserDefaults.standard.bool(forKey: Self.biometricsDefaultsKey(for: currentVaultName))
        errorMessage = nil
        phase = .locked
    }

    func createVault(named rawName: String, password: String) async {
        let name = VaultNaming.sanitizedVaultName(rawName)
        guard !name.isEmpty else {
            errorMessage = "Enter a name for the vault."
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.fileURL(for: name).path) else {
            errorMessage = "A vault named \u{201C}\(name)\u{201D} already exists."
            return
        }
        do {
            let env = CryptoService.newEnvelope()
            let newKey = try await Task.detached(priority: .userInitiated) {
                try CryptoService.deriveKey(password: password, envelope: env)
            }.value
            currentVaultName = name
            biometricsEnabled = UserDefaults.standard.bool(forKey: Self.biometricsDefaultsKey(for: name))
            key = newKey
            envelope = env
            data = VaultData.starter()
            try persist()
            refreshVaults()
            phase = .unlocked
            selectedDocumentID = data.documents.first?.id
            touchActivity()
            startAutoLockTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Permanently deletes the current vault, its backups, and its Touch ID
    /// key. Only possible while the vault is unlocked. Falls back to another
    /// vault's login page, or to setup when this was the last vault.
    func deleteCurrentVault() {
        guard phase == .unlocked else { return }
        saveTask?.cancel()
        let name = currentVaultName
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL)
        for n in 1...Self.backupCount {
            try? fm.removeItem(at: backupURL(n))
        }
        KeychainService.deleteKey(account: Self.keychainAccount(for: name))
        UserDefaults.standard.removeObject(forKey: Self.biometricsDefaultsKey(for: name))
        key = nil
        envelope = nil
        data = VaultData()
        selectedDocumentID = nil
        autoLockTimer?.invalidate()
        autoLockTimer = nil
        refreshVaults()
        if let next = availableVaults.first {
            currentVaultName = next
            biometricsEnabled = UserDefaults.standard.bool(forKey: Self.biometricsDefaultsKey(for: next))
            phase = .locked
        } else {
            currentVaultName = Self.defaultVaultName
            biometricsEnabled = false
            phase = .needsSetup
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
            let keyData = try await KeychainService.fetchKey(account: keychainAccount, reason: "unlock your vault")
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
    ///
    /// If pending changes cannot be written, the vault stays unlocked and the
    /// error is surfaced: discarding the in-memory copy would be the only way
    /// to lose data. The idle clock is reset so the auto-lock timer retries
    /// after another full idle period instead of re-alerting every tick.
    func lock(save: Bool = true) {
        guard phase == .unlocked else { return }
        saveTask?.cancel()
        if save && !saveNow() {
            touchActivity()
            return
        }
        key = nil
        data = VaultData()
        selectedDocumentID = nil
        phase = .locked
        autoLockTimer?.invalidate()
        autoLockTimer = nil
    }

    // MARK: - Persistence

    private func readEnvelope() throws -> VaultEnvelope {
        let raw = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(VaultEnvelope.self, from: raw)
    }

    private func persist() throws {
        guard let key, var env = envelope else { return }
        let plaintext = try JSONEncoder().encode(data)
        env.ciphertext = try CryptoService.encrypt(plaintext, key: key)
        envelope = env
        let envData = try JSONEncoder().encode(env)
        rotateBackups()
        try envData.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
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

    /// Writes the vault to disk immediately. Returns false, with
    /// `errorMessage` set, when the write failed.
    @discardableResult
    func saveNow() -> Bool {
        do {
            try persist()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
    //
    // The list/folder logic itself lives on `VaultData` (SecretsVaultCore) so
    // it can be unit-tested; the store adds selection handling and autosave.

    func documents(in folderID: UUID?) -> [VaultDocument] { data.documents(in: folderID) }

    func searchResults(_ query: String) -> [VaultDocument] { data.searchResults(query) }

    func addDocument(in folderID: UUID?) {
        guard phase == .unlocked else { return }
        let doc = data.addDocument(in: folderID)
        selectedDocumentID = doc.id
        scheduleSave()
    }

    /// Soft delete: the document moves to Recently Deleted, where it stays
    /// recoverable for `deletedRetentionDays` days.
    func deleteDocument(_ id: UUID) {
        guard data.softDelete(id) else { return }
        if selectedDocumentID == id { selectedDocumentID = nil }
        scheduleSave()
    }

    // MARK: - Recently Deleted

    /// Days a deleted document stays recoverable before automatic purge.
    static let deletedRetentionDays = 30

    var deletedDocuments: [VaultDocument] { data.deletedDocuments }

    func restoreDocument(_ id: UUID) {
        guard data.restore(id) else { return }
        scheduleSave()
    }

    /// Permanently removes a single document. Not undoable.
    func purgeDocument(_ id: UUID) {
        data.purge(id)
        if selectedDocumentID == id { selectedDocumentID = nil }
        scheduleSave()
    }

    /// Permanently removes everything in Recently Deleted. Not undoable.
    func emptyRecentlyDeleted() {
        if let sel = selectedDocumentID, data.document(sel)?.deletedAt != nil {
            selectedDocumentID = nil
        }
        data.emptyRecentlyDeleted()
        scheduleSave()
    }

    private func purgeExpiredDeleted() {
        if data.purgeExpiredDeleted(retentionDays: Self.deletedRetentionDays) > 0 {
            scheduleSave()
        }
    }

    func moveDocument(_ id: UUID, to folderID: UUID?) {
        guard data.move(id, to: folderID) else { return }
        scheduleSave()
    }

    func addFolder(named name: String) {
        guard data.addFolder(named: name) != nil else { return }
        scheduleSave()
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard data.renameFolder(id, to: name) else { return }
        scheduleSave()
    }

    func deleteFolder(_ id: UUID) {
        data.deleteFolder(id)
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
            let account = keychainAccount
            do {
                try await Task.detached { try KeychainService.storeKey(kd, account: account) }.value
                biometricsEnabled = true
            } catch {
                errorMessage = "Could not enable Touch ID: \(error.localizedDescription)"
                biometricsEnabled = false
            }
        } else {
            KeychainService.deleteKey(account: keychainAccount)
            biometricsEnabled = false
        }
        UserDefaults.standard.set(biometricsEnabled, forKey: Self.biometricsDefaultsKey(for: currentVaultName))
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
            let account = keychainAccount
            try await Task.detached { try KeychainService.storeKey(kd, account: account) }.value
        }
    }

    // MARK: - Backups

    /// Number of rotated backup copies kept alongside the vault file.
    static let backupCount = 5
    /// Minimum time between backup rotations, so a burst of auto-saves
    /// doesn't flush the whole backup history with near-identical copies.
    private static let backupMinInterval: TimeInterval = 5 * 60

    func backupURL(_ n: Int) -> URL {
        fileURL.appendingPathExtension("\(n)")
    }

    /// Existing backups, newest (.1) first, with their modification dates.
    func existingBackups() -> [(url: URL, date: Date)] {
        (1...Self.backupCount).compactMap { n in
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
        guard fm.fileExists(atPath: fileURL.path) else { return }
        guard force || Date().timeIntervalSince(lastBackupRotation) >= Self.backupMinInterval else { return }
        try? fm.removeItem(at: backupURL(Self.backupCount))
        for n in stride(from: Self.backupCount - 1, through: 1, by: -1) {
            let from = backupURL(n)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(at: from, to: backupURL(n + 1))
        }
        try? fm.copyItem(at: fileURL, to: backupURL(1))
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: backupURL(1).path)
        lastBackupRotation = Date()
    }

    /// Removes every rotated backup.
    private func deleteAllBackups() {
        for n in 1...Self.backupCount {
            try? FileManager.default.removeItem(at: backupURL(n))
        }
    }

    // MARK: - Export / import

    /// Saves an encrypted copy of the vault — the same format as the vault
    /// file, openable with this vault's master password. Returns success.
    func exportEncryptedVault(to url: URL) -> Bool {
        guard phase == .unlocked else { return false }
        guard saveNow() else { return false } // flush pending edits so the copy is current
        do {
            let raw = try Data(contentsOf: fileURL)
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
                let name = VaultNaming.uniqueName(VaultNaming.sanitizedFilename(folder.name), used: &usedDirNames)
                let sub = directory.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                folderURLs[folder.id] = sub
            }
            var written = 0
            var usedNames: [UUID?: Set<String>] = [:]
            for doc in data.documents where doc.deletedAt == nil {
                let dir = folderURLs[doc.folderID] ?? directory
                let base = VaultNaming.sanitizedFilename(doc.title.isEmpty ? "Untitled" : doc.title)
                let name = VaultNaming.uniqueName(base, used: &usedNames[doc.folderID, default: []])
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
        if phase == .unlocked, !saveNow() {
            return "Import cancelled: the current vault could not be saved first."
        }
        rotateBackups(force: true)
        do {
            try raw.write(to: fileURL, options: [.atomic])
        } catch {
            return "Import failed: \(error.localizedDescription)"
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
        // The Touch ID key in the keychain unlocks the replaced vault, not
        // the imported one — drop it.
        if biometricsEnabled {
            KeychainService.deleteKey(account: keychainAccount)
            biometricsEnabled = false
            UserDefaults.standard.set(false, forKey: Self.biometricsDefaultsKey(for: currentVaultName))
        }
        if phase == .unlocked {
            lock(save: false) // don't overwrite the imported file with old data
        } else {
            phase = .locked
        }
        return nil
    }
}
