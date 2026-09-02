import Foundation

/// Document and folder operations on the decrypted vault contents.
///
/// Pure value mutations with no persistence, selection or UI concerns, so
/// they can be unit-tested directly. `VaultStore` wraps them with selection
/// handling and autosave.
public extension VaultData {

    // MARK: Queries

    /// Live (not deleted) documents directly inside `folderID` (nil = root),
    /// sorted by title.
    func documents(in folderID: UUID?) -> [VaultDocument] {
        documents
            .filter { $0.deletedAt == nil && $0.folderID == folderID }
            .sorted(by: Self.byTitle)
    }

    /// Live documents whose title or content contains `query`
    /// (case-insensitive), sorted by title. Blank queries match nothing.
    func searchResults(_ query: String) -> [VaultDocument] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return documents
            .filter { $0.deletedAt == nil }
            .filter { $0.title.localizedCaseInsensitiveContains(q) || $0.content.localizedCaseInsensitiveContains(q) }
            .sorted(by: Self.byTitle)
    }

    /// Documents in Recently Deleted, most recently deleted first.
    var deletedDocuments: [VaultDocument] {
        documents
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    func document(_ id: UUID) -> VaultDocument? {
        documents.first { $0.id == id }
    }

    // MARK: Documents

    /// Appends an empty, untitled document to `folderID` and returns it.
    @discardableResult
    mutating func addDocument(in folderID: UUID?) -> VaultDocument {
        let doc = VaultDocument(title: "", content: "", folderID: folderID)
        documents.append(doc)
        return doc
    }

    /// Soft delete: moves the document to Recently Deleted. Returns false
    /// when no such document exists.
    @discardableResult
    mutating func softDelete(_ id: UUID, at date: Date = Date()) -> Bool {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return false }
        documents[idx].deletedAt = date
        return true
    }

    /// Brings a document back from Recently Deleted. If its folder was
    /// deleted in the meantime it lands in the root. Returns false when no
    /// such document exists.
    @discardableResult
    mutating func restore(_ id: UUID) -> Bool {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return false }
        documents[idx].deletedAt = nil
        if let folderID = documents[idx].folderID,
           !folders.contains(where: { $0.id == folderID }) {
            documents[idx].folderID = nil
        }
        return true
    }

    /// Permanently removes a single document. Not undoable.
    mutating func purge(_ id: UUID) {
        documents.removeAll { $0.id == id }
    }

    /// Permanently removes everything in Recently Deleted. Not undoable.
    mutating func emptyRecentlyDeleted() {
        documents.removeAll { $0.deletedAt != nil }
    }

    /// Permanently removes documents deleted more than `retentionDays`
    /// before `now`. Returns how many were removed.
    @discardableResult
    mutating func purgeExpiredDeleted(retentionDays: Int, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let before = documents.count
        documents.removeAll {
            guard let deletedAt = $0.deletedAt else { return false }
            return deletedAt < cutoff
        }
        return before - documents.count
    }

    /// Moves a document into `folderID` (nil = root). Returns false when no
    /// such document exists.
    @discardableResult
    mutating func move(_ id: UUID, to folderID: UUID?) -> Bool {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return false }
        documents[idx].folderID = folderID
        return true
    }

    // MARK: Folders

    /// Adds a folder with the trimmed name. Blank names are rejected (nil).
    @discardableResult
    mutating func addFolder(named name: String) -> VaultFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let folder = VaultFolder(name: trimmed)
        folders.append(folder)
        return folder
    }

    /// Renames a folder to the trimmed name. Blank names and unknown IDs
    /// are rejected (false).
    @discardableResult
    mutating func renameFolder(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let idx = folders.firstIndex(where: { $0.id == id }) else { return false }
        folders[idx].name = trimmed
        return true
    }

    /// Removes a folder; its documents (live and deleted) move to the root.
    mutating func deleteFolder(_ id: UUID) {
        for i in documents.indices where documents[i].folderID == id {
            documents[i].folderID = nil
        }
        folders.removeAll { $0.id == id }
    }

    private static func byTitle(_ a: VaultDocument, _ b: VaultDocument) -> Bool {
        a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
}
