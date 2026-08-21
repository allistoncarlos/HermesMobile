import SwiftUI

// ============================================================================
//  ServerSetupView — endereço do servidor + login usuário/senha (cookie auth)
//  ou token legado opcional. Visual alinhado ao chat estilo ChatGPT.
// ============================================================================

struct ServerSetupView: View {
    @EnvironmentObject private var vm: HermesViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ScrollView {
                VStack(spacing: landscape ? 18 : 24) {
                    hero(compact: landscape)

                    formFields
                        .frame(maxWidth: HermesTheme.chatMaxWidth)

                    connectButton
                        .frame(maxWidth: HermesTheme.chatMaxWidth)

                    if let msg = displayedStatusMessage {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(vm.connectionState == .waitingAuth || isFailed ? .orange : .secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: HermesTheme.chatMaxWidth)
                    }
                    if let version = vm.serverVersion {
                        Text("Servidor Hermes v\(version)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if !landscape {
                        helpCard
                            .frame(maxWidth: HermesTheme.chatMaxWidth)
                    }
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 40 : 20)
                .padding(.vertical, landscape ? 16 : 20)
                .frame(maxWidth: .infinity)
            }
            .background(HermesTheme.chatBackground.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarHidden(true)
        .onAppear {
            urlText = vm.serverAddress
            username = vm.config.username
            password = ""
            token = vm.config.sessionToken
        }
    }

    private func hero(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 10) {
            ZStack {
                Circle()
                    .fill(HermesTheme.assistantAvatarFill)
                    .frame(width: compact ? 56 : 72, height: compact ? 56 : 72)
                Image(systemName: "sparkles")
                    .font(.system(size: compact ? 22 : 28, weight: .semibold))
                    .foregroundStyle(HermesTheme.assistantAvatarForeground)
            }
            Text("Hermes")
                .font(compact ? .title2.bold() : .largeTitle.bold())
            Text("Conecte-se ao seu agente de qualquer lugar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, compact ? 8 : 24)
    }

    private var formFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("Endereço do servidor")
            TextField("http://192.168.1.50:9119", text: $urlText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .url)
                .padding(14)
                .background(fieldBackground)

            fieldLabel("Usuário")
            TextField("admin", text: $username)
                .textInputAutocapitalization(.never)
                .textContentType(.username)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .username)
                .padding(14)
                .background(fieldBackground)

            HStack {
                fieldLabel("Senha")
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
            .padding(14)
            .background(fieldBackground)

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
                    .background(fieldBackground)
                    Text("Use token só se o servidor não tiver login por senha. Em Tailscale com basic auth, use usuário e senha.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private var connectButton: some View {
        Button {
            focusedField = nil
            Task { await connect() }
        } label: {
            HStack {
                if isConnecting || vm.connectionState == .connecting {
                    ProgressView()
                }
                Text((isConnecting || vm.connectionState == .connecting) ? "Conectando…" : "Continuar")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting || vm.connectionState == .connecting)
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Como conectar")
                .font(.headline)
            Text("• Informe o endereço do Hermes (ex.: via Tailscale).\n• Se o servidor exigir auth (basic), use usuário e senha do dashboard.\n• O app obtém um ticket WebSocket após o login — igual ao web dashboard.\n• Várias conversas podem ficar abertas ao mesmo tempo.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.secondarySystemBackground))
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
        // Senha só viaja nesta tentativa — nunca vai para o Keychain.
        await vm.connect(
            username: user.isEmpty ? nil : user,
            password: password.isEmpty ? nil : password
        )
    }
}
