import SwiftUI

// ============================================================================
//  ContentView — raiz da navegação.
//  Com URL + senha/cookie/token salvos, NÃO mostra login: restaura ou reconecta.
//  Login só após logout, “trocar servidor” ou credenciais inválidas.
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
                case .connecting where shouldStayOnSessionUI:
                    restoreSplash
                case .disconnected where shouldStayOnSessionUI && !didAttemptRestore:
                    restoreSplash
                case .disconnected where shouldStayOnSessionUI:
                    reconnectPane
                case .failed where shouldStayOnSessionUI:
                    reconnectPane
                case .disconnected, .failed, .waitingAuth, .connecting:
                    ServerSetupView()
                }
            }
        }
        .task {
            guard !didAttemptRestore else { return }
            didAttemptRestore = true
            guard vm.config.hasSavedConfig, vm.config.hasRestorableAuth, !vm.needsManualAuth else { return }
            switch vm.connectionState {
            case .disconnected, .connecting:
                await vm.connect()
            default:
                break
            }
        }
    }

    /// Mantém fora do formulário de login enquanto há como reentrar sozinho.
    private var shouldStayOnSessionUI: Bool {
        vm.config.hasSavedConfig
            && vm.config.hasRestorableAuth
            && !vm.needsManualAuth
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

    private var reconnectPane: some View {
        VStack(spacing: 16) {
            if vm.connectionState == .connecting {
                ProgressView()
                    .controlSize(.large)
                Text("Reconectando…")
                    .font(.headline)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Sem conexão")
                    .font(.headline)
                if let msg = vm.statusMessage ?? vm.connectionState.failureMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                Button {
                    Task { await vm.connect() }
                } label: {
                    Text("Tentar de novo")
                        .fontWeight(.semibold)
                        .frame(maxWidth: 220)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button("Trocar servidor") {
                    vm.presentServerSetup()
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: reconnectTaskID) {
            guard shouldStayOnSessionUI else { return }
            if case .disconnected = vm.connectionState {
                await vm.connect()
            }
        }
    }

    private var reconnectTaskID: String {
        "\(vm.connectionState)-\(vm.needsManualAuth)"
    }
}
