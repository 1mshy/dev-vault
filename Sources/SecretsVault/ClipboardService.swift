import AppKit

/// Copies secrets to the clipboard with hygiene:
/// - marks the pasteboard item as concealed (`org.nspasteboard.ConcealedType`)
///   so well-behaved clipboard managers skip it
/// - auto-clears the clipboard after `clearDelay` seconds, unless the user
///   has copied something else in the meantime
@MainActor
enum ClipboardService {
    static let clearDelay: TimeInterval = 30

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static var clearTask: Task<Void, Never>?
    private static var ownedChangeCount = -1

    static func copyConcealed(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string, concealedType], owner: nil)
        pasteboard.setString(string, forType: .string)
        pasteboard.setString("1", forType: concealedType)
        ownedChangeCount = pasteboard.changeCount

        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(clearDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Clear only if the clipboard still holds what we put there.
            if NSPasteboard.general.changeCount == ownedChangeCount {
                NSPasteboard.general.clearContents()
            }
        }
    }
}
