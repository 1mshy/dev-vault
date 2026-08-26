import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var store: VaultStore
    @State private var password = ""
    @State private var isWorking = false
    @State private var autoTried = false
    @FocusState private var focused: Bool

    private var canTouchID: Bool {
        store.biometricsEnabled && KeychainService.biometryAvailable
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 50))
                .foregroundStyle(Color.accentColor)
            Text("Secrets Vault")
                .font(.largeTitle.bold())
            Text("The vault is locked")
                .foregroundStyle(.secondary)

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
            if canTouchID && !autoTried {
                autoTried = true
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
