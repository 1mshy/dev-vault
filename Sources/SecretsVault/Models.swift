import Foundation

struct VaultFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}

struct VaultDocument: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var content: String
    var folderID: UUID?
    var createdAt = Date()
    var updatedAt = Date()
    /// Set when the document is moved to Recently Deleted; nil for live
    /// documents. Optional, so vaults written before this field decode fine.
    var deletedAt: Date?
}

struct VaultData: Codable {
    var folders: [VaultFolder] = []
    var documents: [VaultDocument] = []

    static func starter() -> VaultData {
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
