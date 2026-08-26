import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: VaultStore

    var body: some View {
        Group {
            switch store.phase {
            case .needsSetup:
                SetupView()
            case .locked:
                UnlockView()
            case .unlocked:
                MainView()
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .alert("Secrets Vault", isPresented: errorBinding) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}
