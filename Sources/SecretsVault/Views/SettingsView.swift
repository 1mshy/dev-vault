import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordStatus: String?
    @State private var passwordChangeSucceeded = false
    @State private var isChanging = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
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
                Section("Storage") {
                    LabeledContent("Vault file", value: VaultStore.fileURL.path)
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
        .frame(width: 480, height: 520)
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
}
