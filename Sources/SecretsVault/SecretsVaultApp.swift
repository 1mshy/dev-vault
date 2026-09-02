import SwiftUI
import AppKit

@main
struct SecretsVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .onAppear { appDelegate.store = store }   // save-or-veto on quit
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

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(themes)
                .tint(themes.current.resolvedAccent)
                .preferredColorScheme(themes.current.colorScheme)
        }
    }
}
