import SwiftUI

// ============================================================================
//  ContentView — raiz da navegação.
// ============================================================================

struct ContentView: View {
    @EnvironmentObject private var vm: HermesViewModel
    @State private var didAttemptRestore = false

    var body: some View {
        NavigationStack {
            Group {
                switch vm.connectionState {
                case .connecting where shouldShowRestoreSplash:
                    // Evita flash da tela de login ao reabrir o app já autenticado.
                    restoreSplash
                case .disconnected, .failed, .waitingAuth, .connecting:
                    ServerSetupView()
                case .connected:
                    ChatView()
                }
            }
        }
        .task {
            guard !didAttemptRestore else { return }
            didAttemptRestore = true
            guard vm.connectionState == .disconnected,
                  vm.config.hasSavedConfig else { return }
            // Sempre tenta reconectar se houver servidor salvo.
            // `connect()` decide sozinho se precisa de senha/token ou se a sessão cookie ainda vale.
            await vm.connect()
        }
    }

    /// Splash enquanto restaura sessão salva (cookie, token ou login anterior).
    private var shouldShowRestoreSplash: Bool {
        vm.config.hasSavedConfig && (
            vm.config.canRestoreSession
            || !vm.config.sessionToken.isEmpty
            || !vm.config.username.isEmpty
        )
    }

    private var restoreSplash: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Entrando…")
                .font(.headline)
            if !vm.config.baseURLString.isEmpty {
                Text(vm.config.baseURLString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
