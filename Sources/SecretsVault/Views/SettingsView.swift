import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var themes: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordStatus: String?
    @State private var passwordChangeSucceeded = false
    @State private var isChanging = false
    @State private var showMarkdownWarning = false
    @State private var showImportConfirm = false
    @State private var transferStatus: String?
    @State private var transferSucceeded = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Appearance") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 12) {
                        ForEach(Theme.all) { theme in
                            Button {
                                themes.themeID = theme.id
                            } label: {
                                ThemeSwatch(theme: theme, isSelected: theme.id == themes.themeID)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    Text("Themes apply instantly and are remembered across launches. System follows the macOS appearance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Security") {
                    Toggle("Unlock with Touch ID", isOn: biometricsBinding)
                        .disabled(!KeychainService.biometryAvailable)
                    if !KeychainService.biometryAvailable {
                        Text("Touch ID is not available on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Auto-lock after", selection: $store.autoLockMinutes) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("30 minutes").tag(30)
                        Text("Never").tag(0)
                    }
                    Text("The vault also locks when the screen locks, the Mac sleeps, or the vault window closes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Change Master Password") {
                    SecureField("Current password", text: $currentPassword)
                    SecureField("New password (min 8 characters)", text: $newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                    HStack(spacing: 10) {
                        Button("Change Password") { change() }
                            .disabled(isChanging
                                      || currentPassword.isEmpty
                                      || newPassword.count < 8
                                      || newPassword != confirmPassword)
                        if isChanging {
                            ProgressView().controlSize(.small)
                        }
                        if let status = passwordStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(passwordChangeSucceeded ? Color.green : Color.red)
                        }
                    }
                    if !newPassword.isEmpty && newPassword.count < 8 {
                        Text("Use at least 8 characters.")
                            .font(.caption).foregroundStyle(.orange)
                    } else if !confirmPassword.isEmpty && newPassword != confirmPassword {
                        Text("Passwords don't match.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Export & Import") {
                    Button("Export Encrypted Copy…") { exportEncrypted() }
                    Text("A copy of the vault file, still encrypted with your master password — for moving to another Mac or keeping an off-machine backup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Export as Plain Markdown…") { showMarkdownWarning = true }
                    Text("Writes every document as an unencrypted .md file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Import Vault…") { showImportConfirm = true }
                    Text("Replaces this vault with an exported copy or a rotated backup, then locks the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let status = transferStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(transferSucceeded ? Color.green : Color.red)
                    }
                }
                Section("Storage") {
                    LabeledContent("Vault file", value: VaultStore.fileURL.path)
                    LabeledContent("Backups", value: backupSummary)
                    Text("Before each overwrite the previous vault file is rotated into vault.secrets.1…\(VaultStore.backupCount) next to the vault (at most once every 5 minutes). Recently Deleted documents are purged after \(VaultStore.deletedRetentionDays) days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([VaultStore.fileURL])
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
        .alert("Export Unencrypted Markdown?", isPresented: $showMarkdownWarning) {
            Button("Export Anyway", role: .destructive) { exportMarkdown() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every document — including any passwords and secrets — will be written to disk as plain, unencrypted text. Anyone with access to the exported files can read everything. Only continue if you understand the risk.")
        }
        .alert("Replace This Vault?", isPresented: $showImportConfirm) {
            Button("Choose File…", role: .destructive) { chooseAndImportVault() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The imported vault replaces the current one and the app locks. You will need the imported vault's master password to unlock it. The current vault is kept as backup 1 (vault.secrets.1).")
        }
    }

    private var biometricsBinding: Binding<Bool> {
        Binding(
            get: { store.biometricsEnabled },
            set: { newValue in
                Task { await store.setBiometrics(newValue) }
            }
        )
    }

    private func change() {
        isChanging = true
        passwordStatus = nil
        let cur = currentPassword
        let new = newPassword
        Task {
            let error = await store.changePassword(current: cur, new: new)
            isChanging = false
            if let error {
                passwordChangeSucceeded = false
                passwordStatus = error
            } else {
                passwordChangeSucceeded = true
                passwordStatus = "Password changed."
                currentPassword = ""
                newPassword = ""
                confirmPassword = ""
            }
        }
    }

    private static var dateStamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: Date())
    }

    private var backupSummary: String {
        let backups = VaultStore.existingBackups()
        guard let newest = backups.first else { return "None yet" }
        return "\(backups.count) of \(VaultStore.backupCount) · newest \(newest.date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func exportEncrypted() {
        let panel = NSSavePanel()
        panel.title = "Export Encrypted Vault"
        panel.nameFieldStringValue = "SecretsVault-\(Self.dateStamp).secrets"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transferSucceeded = store.exportEncryptedVault(to: url)
        transferStatus = transferSucceeded ? "Encrypted copy exported." : nil
    }

    private func exportMarkdown() {
        let panel = NSOpenPanel()
        panel.title = "Export as Plain Markdown"
        panel.message = "Choose where to create the (unencrypted) export folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = url.appendingPathComponent("Secrets Vault Export \(Self.dateStamp)", isDirectory: true)
        if let count = store.exportMarkdown(to: dir) {
            transferSucceeded = true
            transferStatus = "\(count) document\(count == 1 ? "" : "s") exported as plain markdown."
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else {
            transferStatus = nil
        }
    }

    private func chooseAndImportVault() {
        let panel = NSOpenPanel()
        panel.title = "Import Vault"
        panel.message = "Choose a Secrets Vault export or a rotated backup (vault.secrets.1…\(VaultStore.backupCount))."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let error = store.importVault(from: url) {
            transferSucceeded = false
            transferStatus = error
        } else {
            dismiss() // the vault is locked now; the unlock screen takes over
        }
    }
}

// MARK: - Theme swatch

private struct ThemeSwatch: View {
    let theme: Theme
    let isSelected: Bool
    @Environment(\.colorScheme) private var systemScheme

    private var isDark: Bool { (theme.colorScheme ?? systemScheme) == .dark }

    private var previewBackground: Color {
        theme.windowBackground ?? (isDark ? Color(hex: 0x1E1E1E) : Color(hex: 0xF2F2F7))
    }

    private var previewText: Color {
        theme.textPrimary ?? (isDark ? .white : .black)
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(previewBackground)
                VStack(alignment: .leading, spacing: 4) {
                    Circle()
                        .fill(theme.resolvedAccent)
                        .frame(width: 10, height: 10)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(previewText.opacity(0.85))
                        .frame(width: 36, height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill((theme.textSecondary ?? previewText).opacity(0.45))
                        .frame(width: 24, height: 4)
                }
                .padding(9)
            }
            .frame(height: 54)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? theme.resolvedAccent : Color.primary.opacity(0.15),
                                  lineWidth: isSelected ? 2 : 1)
            )
            Text(theme.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
        .help(theme.name)
    }
}
