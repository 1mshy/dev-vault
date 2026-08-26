import SwiftUI
import AppKit

struct SetupView: View {
    @EnvironmentObject var store: VaultStore
    @State private var password = ""
    @State private var confirm = ""
    @State private var isWorking = false

    private var valid: Bool { password.count >= 8 && password == confirm }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Secrets Vault")
                .font(.largeTitle.bold())
            Text("Create a master password to encrypt your vault.")
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                SecureField("Master password (min 8 characters)", text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField("Confirm password", text: $confirm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if valid { create() } }
            }
            .frame(width: 300)
            .disabled(isWorking)

            if !password.isEmpty && password.count < 8 {
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

            Button("Import Existing Vault…") { importExisting() }
                .buttonStyle(.link)
                .disabled(isWorking)

            Text("Your vault is encrypted with AES-256. The master password cannot be recovered — if you forget it, the vault contents are lost.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(width: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func create() {
        guard valid, !isWorking else { return }
        isWorking = true
        let pw = password
        Task {
            await store.createVault(password: pw)
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
