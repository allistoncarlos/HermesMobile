import SwiftUI

// ============================================================================
//  ServerSetupView — endereço do servidor + login usuário/senha (cookie auth)
//  ou token legado opcional.
// ============================================================================

struct ServerSetupView: View {
    @EnvironmentObject private var vm: HermesViewModel
    @State private var urlText: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var token: String = ""
    @State private var showPassword = false
    @State private var showToken = false
    @State private var showAdvanced = false
    @State private var isConnecting = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case url, username, password, token
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "ellipsis.message.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                    Text("HermesMobile")
                        .font(.largeTitle.bold())
                    Text("Conecte-se ao seu agente Hermes de qualquer lugar.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Endereço do servidor")
                        .font(.subheadline.weight(.medium))
                    TextField("http://192.168.1.50:9119", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .url)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))

                    Text("Usuário")
                        .font(.subheadline.weight(.medium))
                    TextField("admin", text: $username)
                        .textInputAutocapitalization(.never)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))

                    HStack {
                        Text("Senha")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                    }
                    Group {
                        if showPassword {
                            TextField("Senha do dashboard", text: $password)
                        } else {
                            SecureField("Senha do dashboard", text: $password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))

                    DisclosureGroup("Opções avançadas", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Token de sessão (legado)")
                                    .font(.footnote)
                                Spacer()
                                Button {
                                    showToken.toggle()
                                } label: {
                                    Image(systemName: showToken ? "eye.slash" : "eye")
                                }
                            }
                            Group {
                                if showToken {
                                    TextField("Somente loopback / --insecure", text: $token)
                                } else {
                                    SecureField("Somente loopback / --insecure", text: $token)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                            Text("Use token só se o servidor não tiver login por senha. Em Tailscale com basic auth, use usuário e senha.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                }

                Button {
                    focusedField = nil
                    Task { await connect() }
                } label: {
                    HStack {
                        if isConnecting || vm.connectionState == .connecting {
                            ProgressView()
                        }
                        Text((isConnecting || vm.connectionState == .connecting) ? "Conectando…" : "Conectar")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting || vm.connectionState == .connecting)

                if let msg = displayedStatusMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(vm.connectionState == .waitingAuth || isFailed ? .orange : .secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
                if let version = vm.serverVersion {
                    Text("Servidor Hermes v\(version)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Como conectar")
                        .font(.headline)
                    Text("• Informe o endereço do Hermes (ex.: via Tailscale).\n• Se o servidor exigir auth (basic), use usuário e senha do dashboard.\n• O app obtém um ticket WebSocket após o login — igual ao web dashboard.\n• Várias conversas podem ficar abertas ao mesmo tempo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            }
            .padding(20)
        }
        .onAppear {
            urlText = vm.serverAddress
            username = vm.config.username
            token = vm.config.sessionToken
        }
    }

    private var isFailed: Bool {
        if case .failed = vm.connectionState { return true }
        return false
    }

    private var displayedStatusMessage: String? {
        if let msg = vm.statusMessage, !msg.isEmpty { return msg }
        if case .failed(let msg) = vm.connectionState { return msg }
        return nil
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        vm.config.baseURLString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.config.sessionToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        await vm.connect(username: user.isEmpty ? nil : user, password: password.isEmpty ? nil : password)
    }
}
