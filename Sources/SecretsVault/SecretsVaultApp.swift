import SwiftUI
import AppKit
import Combine

@main
struct SecretsVaultApp: App {
    @StateObject private var store = VaultStore()
    @StateObject private var themes = ThemeManager()

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        }
    }

    var body: some Scene {
        WindowGroup("Secrets Vault") {
            ContentView()
                .environmentObject(store)
                .environmentObject(themes)
                .tint(themes.current.resolvedAccent)
                .preferredColorScheme(themes.current.colorScheme)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveNow()
                }
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Document") { store.addDocument(in: nil) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.phase != .unlocked)
                Button("Lock Vault") { store.lock() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(store.phase != .unlocked)
            }
        }
    }
}
