import Foundation

public struct VaultFolder: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct VaultDocument: Identifiable, Codable, Hashable {
    public var id: UUID
    public var title: String
    public var content: String
    public var folderID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when the document is moved to Recently Deleted; nil for live
    /// documents. Optional, so vaults written before this field decode fine.
    public var deletedAt: Date?

    public init(id: UUID = UUID(), title: String, content: String, folderID: UUID? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.folderID = folderID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// The decrypted contents of a vault file. Folder and document operations
/// live in `VaultData+Operations.swift`.
public struct VaultData: Codable {
    public var folders: [VaultFolder]
    public var documents: [VaultDocument]

    public init(folders: [VaultFolder] = [], documents: [VaultDocument] = []) {
        self.folders = folders
        self.documents = documents
    }

    public static func starter() -> VaultData {
        let passwords = VaultFolder(name: "Passwords")
        let dev = VaultFolder(name: "Dev Commands")
        let welcome = VaultDocument(
            title: "Welcome",
            content: """
            # Welcome to Secrets Vault

            Everything in this vault is encrypted on disk with **AES-256-GCM**. \
            The key is derived from your master password and never written anywhere.

            ## Tips

            - Documents are plain **markdown** — use the Edit / Preview toggle at the top right
            - Organize documents into folders; right-click a folder or document for actions
            - In Preview, code blocks get a copy button — handy for passwords and commands
            - Press ⌘N for a new document, ⌘L to lock the vault
            - Enable Touch ID in Settings (gear icon) to unlock with your fingerprint

            ## Example

            ```
            export DATABASE_URL="postgres://user:secret@localhost:5432/app"
            ```

            > The vault auto-locks after a period of inactivity (configurable in Settings).
            """,
            folderID: nil
        )
        return VaultData(folders: [passwords, dev], documents: [welcome])
    }
}
