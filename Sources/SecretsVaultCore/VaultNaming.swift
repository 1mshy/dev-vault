import Foundation

/// File-name hygiene for vault names and exported markdown files.
public enum VaultNaming {

    /// Turns user input into a safe vault file stem: path separators and
    /// colons become dashes, surrounding whitespace and leading dots are
    /// dropped, and the result is capped at 60 characters. May be empty.
    public static func sanitizedVaultName(_ raw: String) -> String {
        clean(raw, maxLength: 60)
    }

    /// Like `sanitizedVaultName` for exported document and folder names:
    /// a longer cap, and never empty ("Untitled").
    public static func sanitizedFilename(_ name: String) -> String {
        let cleaned = clean(name, maxLength: 120)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Returns `base`, or "base 2", "base 3", … so names stay unique on a
    /// case-insensitive file system; records the result in `used`.
    public static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var name = base
        var n = 2
        while used.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        used.insert(name.lowercased())
        return name
    }

    private static func clean(_ raw: String, maxLength: Int) -> String {
        var cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        cleaned = String(cleaned.prefix(maxLength))
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned
    }
}
