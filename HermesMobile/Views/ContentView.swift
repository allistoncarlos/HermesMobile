import SwiftUI

// ============================================================================
//  ContentView — raiz da navegação.
// ============================================================================

struct ContentView: View {
    @EnvironmentObject private var vm: HermesViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch vm.connectionState {
                case .disconnected, .failed, .waitingAuth, .connecting:
                    // Mantém a tela de setup durante .connecting para o spinner
                    // e a mensagem de erro permanecerem visíveis.
                    ServerSetupView()
                case .connected:
                    ChatView()
                }
            }
        }
        .task {
            guard vm.connectionState == .disconnected,
                  vm.config.hasSavedConfig,
                  let base = ServerConfig.normalizedURL(from: vm.config.baseURLString) else { return }
            let client = HermesClient(baseURL: base, urlSession: HermesHTTPSession.shared)
            if client.hasLiveSessionCookie() || !vm.config.sessionToken.isEmpty {
                await vm.connect()
            }
        }
    }
}
