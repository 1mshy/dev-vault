import SwiftUI
import AppKit

struct SetupView: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var themes: ThemeManager
    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var isWorking = false

    private var theme: Theme { themes.current }

    /// True on first launch, when no vault exists yet.
    private var isFirstVault: Bool { store.availableVaults.isEmpty }

    private var nameOK: Bool { store.vaultNameAvailable(name) }
    private var valid: Bool { nameOK && password.count >= 8 && password == confirm }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(theme.resolvedAccent)
            Text(isFirstVault ? "Welcome to Secrets Vault" : "Create a New Vault")
                .font(.largeTitle.bold())
                .foregroundStyle(theme.resolvedTextPrimary)
            Text(isFirstVault
                 ? "Create a master password to encrypt your vault."
                 : "Each vault is a separate encrypted file with its own master password.")
                .foregroundStyle(theme.resolvedTextSecondary)

            VStack(spacing: 10) {
                TextField("Vault name", text: $name)
                    .textFieldStyle(.roundedBorder)
                SecureField("Master password (min 8 characters)", text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField("Confirm password", text: $confirm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if valid { create() } }
            }
            .frame(width: 300)
            .disabled(isWorking)

            if !name.isEmpty && !nameOK {
                Text("This vault name is already in use or invalid.")
                    .font(.caption).foregroundStyle(.orange)
            } else if !password.isEmpty && password.count < 8 {
                Text("Use at least 8 characters.")
                    .font(.caption).foregroundStyle(.orange)
            } else if !confirm.isEmpty && password != confirm {
                Text("Passwords don't match.")
                    .font(.caption).foregroundStyle(.orange)
            }

            Button {
                create()
            } label: {
                if isWorking {
                    ProgressView().controlSize(.small).frame(minWidth: 120)
                } else {
                    Text("Create Vault").frame(minWidth: 120)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!valid || isWorking)

            if isFirstVault {
                Button("Import Existing Vault…") { importExisting() }
                    .buttonStyle(.link)
                    .disabled(isWorking)
            } else {
                Button("Cancel") { store.cancelNewVault() }
                    .buttonStyle(.link)
                    .disabled(isWorking)
            }

            Text("Your vault is encrypted with AES-256. The master password cannot be recovered — if you forget it, the vault contents are lost.")
                .font(.caption)
                .foregroundStyle(theme.resolvedTextTertiary)
                .multilineTextAlignment(.center)
                .frame(width: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if isFirstVault && name.isEmpty {
                name = VaultStore.defaultVaultName
            }
        }
    }

    private func create() {
        guard valid, !isWorking else { return }
        isWorking = true
        let vaultName = name
        let pw = password
        Task {
            await store.createVault(named: vaultName, password: pw)
            isWorking = false
        }
    }

    private func importExisting() {
        let panel = NSOpenPanel()
        panel.title = "Import Vault"
        panel.message = "Choose a Secrets Vault export (.secrets) copied from another Mac."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let error = store.importVault(from: url) {
            store.errorMessage = error
        }
    }
}
