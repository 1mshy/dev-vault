import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var themes: ThemeManager
    @State private var password = ""
    @State private var isWorking = false
    @FocusState private var focused: Bool

    private var theme: Theme { themes.current }

    private var canTouchID: Bool {
        store.biometricsEnabled && KeychainService.biometryAvailable
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 50))
                .foregroundStyle(theme.resolvedAccent)
            Text("Secrets Vault")
                .font(.largeTitle.bold())
                .foregroundStyle(theme.resolvedTextPrimary)
            Text("The vault is locked")
                .foregroundStyle(theme.resolvedTextSecondary)

            SecureField("Master password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($focused)
                .onSubmit { unlock() }
                .disabled(isWorking)

            HStack(spacing: 10) {
                Button {
                    unlock()
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small).frame(minWidth: 90)
                    } else {
                        Text("Unlock").frame(minWidth: 90)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty || isWorking)

                if canTouchID {
                    Button {
                        touchID()
                    } label: {
                        Label("Touch ID", systemImage: "touchid")
                    }
                    .disabled(isWorking)
                    .help("Unlock with Touch ID")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
        .task {
            // Auto-prompt Touch ID only once per app launch (startup).
            if canTouchID && !store.hasAutoPromptedBiometrics {
                store.hasAutoPromptedBiometrics = true
                isWorking = true
                await store.unlockWithBiometrics()
                isWorking = false
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty, !isWorking else { return }
        isWorking = true
        let pw = password
        Task {
            await store.unlock(password: pw)
            isWorking = false
            password = ""
            if store.phase != .unlocked { focused = true }
        }
    }

    private func touchID() {
        isWorking = true
        Task {
            await store.unlockWithBiometrics()
            isWorking = false
        }
    }
}
