import AppKit

/// Flushes pending edits on quit and refuses to quit while they cannot be
/// written, so a full disk or a permissions problem never silently drops
/// the last changes. Covers ⌘Q, logout/shutdown and the updater's relaunch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `SecretsVaultApp` once the store exists.
    weak var store: VaultStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.phase == .unlocked else { return .terminateNow }
        return store.saveNow() ? .terminateNow : .terminateCancel
    }
}
