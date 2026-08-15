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
                case .connected:
                    ChatView()
                case .connecting where shouldShowRestoreSplash:
                    restoreSplash
                case .disconnected where shouldShowRestoreSplash && !didAttemptRestore:
                    restoreSplash
                case .disconnected, .failed, .waitingAuth, .connecting:
                    ServerSetupView()
                }
            }
        }
        .task {
            guard !didAttemptRestore else { return }
            didAttemptRestore = true
            guard vm.config.hasSavedConfig else { return }
            switch vm.connectionState {
            case .disconnected, .connecting:
                await vm.connect()
            default:
                break
            }
        }
    }

    /// Splash enquanto restaura sessão salva (cookie, token ou login anterior).
    private var shouldShowRestoreSplash: Bool {
        vm.config.hasSavedConfig && vm.config.hasRestorableAuth
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
