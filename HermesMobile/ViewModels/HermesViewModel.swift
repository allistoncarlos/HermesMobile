import Foundation

// ============================================================================
//  HermesViewModel — orquestra autenticação, WebSocket JSON-RPC e chats
//  simultâneos (vários OpenChat sobre uma única conexão).
// ============================================================================

@MainActor
final class HermesViewModel: ObservableObject {

    @Published var config: ServerConfig

    // MARK: - Estado público (UI)
    @Published var connectionState: ConnectionState = .disconnected
    @Published var openChats: [OpenChat] = []
    @Published var activeChatID: String?
    @Published var sessions: [SessionSummary] = []
    @Published var serverVersion: String?
    @Published var statusMessage: String?
    @Published var authRequired: Bool = false
    @Published var passwordProviders: [AuthProviderInfo] = []
    @Published var showSidebar: Bool = false

    private var ws: HermesWebSocket?
    /// Cliente HTTP compartilhado (login, ticket WS, áudio STT/TTS).
    private(set) var httpClient: HermesClient?
    private var usesCookieAuth = false

    /// URL do WebSocket de TTS streaming (mesmo auth do `/api/ws`).
    func makeSpeakStreamURL() async throws -> URL {
        guard let client = httpClient else {
            throw HermesClientError(message: "Sem conexão com o servidor Hermes.")
        }
        return try await client.makeSpeakStreamURL(
            usesCookieAuth: usesCookieAuth,
            legacyToken: usesCookieAuth ? nil : config.sessionToken
        )
    }

    // MARK: - Init

    init(config: ServerConfig = ServerConfig()) {
        self.config = config
    }

    // MARK: - Computed (chat ativo)

    var activeChat: OpenChat? {
        guard let id = activeChatID else { return openChats.first }
        return openChats.first(where: { $0.id == id }) ?? openChats.first
    }

    var messages: [ChatMessage] { activeChat?.messages ?? [] }
    var sessionTitle: String { activeChat?.title ?? "Nova conversa" }
    var sessionModel: String? { activeChat?.model }
    var toolStatusText: String? { activeChat?.toolStatusText }
    var pendingApproval: PendingApproval? { activeChat?.pendingApproval }
    var hasPendingClarify: Bool { activeChat?.hasPendingClarify ?? false }
    var isStreaming: Bool { activeChat?.isStreaming ?? false }

    var canSend: Bool {
        connectionState == .connected && activeChat != nil
    }

    var serverAddress: String { config.baseURLString }

    var hasAttentionElsewhere: Bool {
        openChats.contains { chat in
            chat.id != activeChatID && (chat.needsAttention || chat.pendingApproval != nil || chat.hasPendingClarify)
        }
    }

    // MARK: - Conexão

    /// Conecta ao servidor. Se `username`/`password` forem passados e o servidor
    /// exigir auth, faz login cookie-based antes do WebSocket.
    func connect(username: String? = nil, password: String? = nil) async {
        connectionState = .connecting
        statusMessage = nil

        guard let base = ServerConfig.normalizedURL(from: config.baseURLString) else {
            connectionState = .failed("Endereço do servidor inválido.")
            return
        }

        let client = HermesClient(
            baseURL: base,
            sessionToken: config.sessionToken.isEmpty ? nil : config.sessionToken,
            urlSession: HermesHTTPSession.shared
        )
        httpClient = client

        let status: HermesStatus
        do {
            status = try await client.fetchStatus()
            serverVersion = status.version
            authRequired = status.authRequired == true
            usesCookieAuth = status.usesCookieAuth
        } catch {
            let msg = Self.describeConnectionError(error, base: base)
            statusMessage = msg
            connectionState = .failed(msg)
            return
        }

        if usesCookieAuth {
            let providers = (try? await client.fetchAuthProviders()) ?? []
            passwordProviders = providers.filter { $0.supportsPassword == true }
            if passwordProviders.isEmpty, let first = status.authProviders?.first {
                passwordProviders = [AuthProviderInfo(name: first, displayName: nil, supportsPassword: true)]
            }

            let user = (username ?? config.username).trimmingCharacters(in: .whitespacesAndNewlines)
            let pass = password ?? ""

            if !client.hasLiveSessionCookie() {
                if user.isEmpty || pass.isEmpty {
                    connectionState = .waitingAuth
                    statusMessage = "Este servidor exige login. Informe usuário e senha."
                    return
                }
                let provider = passwordProviders.first?.name ?? status.authProviders?.first ?? "basic"
                do {
                    _ = try await client.login(username: user, password: pass, provider: provider)
                    config.username = user
                } catch {
                    connectionState = .waitingAuth
                    statusMessage = error.localizedDescription
                    return
                }
            } else if !user.isEmpty {
                config.username = user
            }
        } else if status.authRequired == true {
            // Auth exigida mas sem fluxo cookie (token legado).
            if config.sessionToken.trimmingCharacters(in: .whitespaces).isEmpty {
                connectionState = .waitingAuth
                statusMessage = "Este servidor exige um token de sessão (X-Hermes-Session-Token)."
                return
            }
        }

        // Abre o WebSocket (ticket em modo gated, token legado caso contrário).
        do {
            try await openWebSocket(base: base, client: client)
        } catch {
            let msg = Self.describeConnectionError(error, base: base)
            statusMessage = msg
            connectionState = .failed(msg)
            return
        }

        openChats = []
        activeChatID = nil
        await createSession()
        await loadSessions()
    }

    private func openWebSocket(base: URL, client: HermesClient) async throws {
        ws?.disconnect()
        ws = nil

        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw HermesClientError(message: "URL inválida.")
        }
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/api/ws"
        comps.fragment = nil

        var tokenForHeader: String? = nil
        if usesCookieAuth {
            let ticket = try await client.mintWsTicket()
            comps.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        } else {
            comps.queryItems = nil
            let tok = config.sessionToken.trimmingCharacters(in: .whitespaces)
            if !tok.isEmpty {
                tokenForHeader = tok
                comps.queryItems = [URLQueryItem(name: "token", value: tok)]
            }
        }

        guard let wsURL = comps.url else {
            throw HermesClientError(message: "URL do WebSocket inválida.")
        }

        let socket = HermesWebSocket(
            url: wsURL,
            sessionToken: usesCookieAuth ? nil : tokenForHeader,
            urlSession: HermesHTTPSession.shared
        )
        socket.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        socket.onClose = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.connectionState == .connected || self.connectionState == .connecting {
                    self.connectionState = .disconnected
                    self.statusMessage = "Conexão com o servidor encerrada."
                }
            }
        }
        try socket.connect()
        self.ws = socket
    }

    func disconnect() {
        ws?.disconnect()
        ws = nil
        connectionState = .disconnected
        openChats = []
        activeChatID = nil
    }

    func logout() async {
        await httpClient?.logout()
        disconnect()
        statusMessage = "Sessão encerrada."
    }

    // MARK: - Sessões / chats abertos

    private func createSession() async {
        guard let ws else { return }
        do {
            let result = try await ws.call(method: "session.create", params: ["cols": .number(80)])
            if let sid = result["session_id"]?.stringValue {
                let stored = result["stored_session_id"]?.stringValue ?? sid
                let chat = OpenChat(id: sid, storedSessionID: stored, title: "Nova conversa")
                openChats.append(chat)
                activeChatID = sid
                if !connectionIsError() {
                    connectionState = .connected
                }
            }
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func newSession() async {
        guard let ws else { return }
        do {
            let result = try await ws.call(method: "session.create", params: ["cols": .number(80)])
            if let sid = result["session_id"]?.stringValue {
                let stored = result["stored_session_id"]?.stringValue ?? sid
                let chat = OpenChat(id: sid, storedSessionID: stored, title: "Nova conversa")
                openChats.append(chat)
                activeChatID = sid
                showSidebar = false
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func selectChat(_ id: String) async {
        guard openChats.contains(where: { $0.id == id }) else { return }
        activeChatID = id
        clearAttention(for: id)
        showSidebar = false
        // Ativa a sessão no servidor (se suportado).
        if let ws {
            _ = try? await ws.call(method: "session.activate", params: ["session_id": .string(id)])
        }
    }

    func closeChat(_ id: String) {
        openChats.removeAll { $0.id == id }
        if activeChatID == id {
            activeChatID = openChats.first?.id
        }
    }

    func loadSessions() async {
        guard let ws else { return }
        do {
            let result = try await ws.call(method: "session.list", params: ["limit": .number(50)])
            var list: [JSONValue] = []
            if let arr = result["sessions"]?.arrayValue {
                list = arr
            } else if let arr = result.arrayValue {
                list = arr
            }
            let summaries: [SessionSummary] = list.compactMap { item in
                guard let obj = item.objectValue else { return nil }
                let id = (obj["id"] ?? obj["stored_session_id"] ?? obj["session_id"])?.stringValue ?? ""
                guard !id.isEmpty else { return nil }
                let title = (obj["title"] ?? obj["name"])?.stringValue ?? "Conversa"
                let started = (obj["started_at"] ?? obj["created_at"])?.number.map { Date(timeIntervalSince1970: $0) }
                let source = obj["source"]?.stringValue
                let active = (obj["is_active"] ?? obj["active"])?.boolValue ?? false
                return SessionSummary(id: id, title: title, startedAt: started, source: source, isActive: active)
            }
            sessions = summaries
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func resumeSession(_ summary: SessionSummary) async {
        // Se já estiver aberta (por stored id ou id), só foca.
        if let existing = openChats.first(where: {
            $0.id == summary.id || $0.storedSessionID == summary.id
        }) {
            await selectChat(existing.id)
            return
        }

        guard let ws else { return }
        do {
            let result = try await ws.call(
                method: "session.resume",
                params: ["session_id": .string(summary.id), "cols": .number(80)]
            )
            let sid = result["session_id"]?.stringValue ?? summary.id
            var chat = OpenChat(
                id: sid,
                storedSessionID: summary.id,
                title: summary.title
            )
            if let infoModel = result["info"]?["model"]?.stringValue {
                chat.model = infoModel
            }
            if let msgs = result["messages"]?.arrayValue {
                for m in msgs {
                    if let text = m["content"]?.stringValue ?? m["text"]?.stringValue,
                       let roleRaw = m["role"]?.stringValue {
                        let role = ChatRole(rawValue: roleRaw) ?? .assistant
                        chat.messages.append(ChatMessage(role: role, text: text))
                    }
                }
            }
            if chat.messages.isEmpty {
                chat.messages.append(ChatMessage(role: .system, text: "Conversa em andamento no servidor."))
            }
            // Evita duplicar se resume devolveu um id já aberto.
            if let idx = openChats.firstIndex(where: { $0.id == sid }) {
                openChats[idx] = chat
            } else {
                openChats.append(chat)
            }
            activeChatID = sid
            showSidebar = false
            _ = try? await ws.call(method: "session.activate", params: ["session_id": .string(sid)])
        } catch {
            statusMessage = "Erro ao abrir a conversa: \(error.localizedDescription)"
        }
    }

    // MARK: - Envio de mensagem

    func send(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let ws, var chat = mutableActiveChat() else { return }

        if chat.hasPendingClarify {
            await respondClarify(text)
            return
        }

        chat.messages.append(ChatMessage(role: .user, text: text))
        let assistant = ChatMessage(role: .assistant, text: "", status: "streaming", isStreaming: true)
        chat.messages.append(assistant)
        chat.lastAssistantIndex = chat.messages.count - 1
        chat.toolStatusText = nil
        chat.isStreaming = true
        chat.needsAttention = false
        commit(chat)
        statusMessage = nil

        do {
            _ = try await ws.call(
                method: "prompt.submit",
                params: ["session_id": .string(chat.id), "text": .string(text)]
            )
        } catch {
            finishTurn(sessionID: chat.id, error: error.localizedDescription)
        }
    }

    func stopStreaming() async {
        guard let ws, let chat = activeChat else { return }
        do {
            _ = try await ws.call(method: "session.interrupt", params: ["session_id": .string(chat.id)])
        } catch {
            // ignora
        }
        finishTurn(sessionID: chat.id, error: nil)
    }

    // MARK: - Aprovações e esclarecimentos

    func respondApproval(allow: Bool) async {
        guard let ws, var chat = mutableActiveChat(), let approval = chat.pendingApproval else { return }
        chat.pendingApproval = nil
        commit(chat)
        let choice = allow ? "allow" : "deny"
        do {
            var params: [String: JSONValue] = [
                "session_id": .string(approval.sessionID),
                "choice": .string(choice),
            ]
            if let rid = approval.requestID {
                params["approval_id"] = .string(rid)
            }
            _ = try await ws.call(method: "approval.respond", params: params)
        } catch {
            statusMessage = "Erro ao responder: \(error.localizedDescription)"
        }
    }

    func respondClarify(_ answer: String, allow: Bool = true) async {
        guard let ws, var chat = mutableActiveChat() else { return }
        let sid = chat.id
        let clarifyID = chat.pendingClarifyID
        chat.pendingClarifyID = nil
        chat.hasPendingClarify = false
        commit(chat)

        var params: [String: JSONValue] = [
            "session_id": .string(sid),
            "response": .string(answer),
        ]
        if let cid = clarifyID {
            params["clarify_id"] = .string(cid)
        }
        if !allow {
            params["cancel"] = .bool(true)
        }
        do {
            _ = try await ws.call(method: "clarify.respond", params: params)
        } catch {
            statusMessage = "Erro ao responder: \(error.localizedDescription)"
        }
    }

    // MARK: - Processamento de eventos

    private func handle(_ event: HermesEvent) {
        // Eventos globais sem sessão.
        if event.type == "gateway.ready" {
            if !connectionIsError() {
                connectionState = .connected
            }
            return
        }

        let sid = event.sessionID
        // Se não temos chat para esse session_id, ignora (exceto se for o ativo implícito).
        guard !sid.isEmpty, chatIndex(for: sid) != nil || openChats.isEmpty == false else {
            // Tenta associar a eventos sem session em chat ativo.
            if sid.isEmpty, let active = activeChatID {
                handle(event, for: active)
            }
            return
        }

        let target = sid.isEmpty ? (activeChatID ?? "") : sid
        guard !target.isEmpty else { return }
        handle(event, for: target)
    }

    private func handle(_ event: HermesEvent, for sessionID: String) {
        // Garante que o chat existe ou cria um stub se o servidor emitir em sessão nova.
        if chatIndex(for: sessionID) == nil {
            openChats.append(OpenChat(id: sessionID, title: "Conversa"))
        }
        guard var chat = chat(for: sessionID) else { return }
        let isBackground = sessionID != activeChatID

        switch event.type {
        case "session.info":
            if let model = event.payload["model"]?.stringValue {
                chat.model = model
            }
            if let title = event.payload["pending_title"]?.stringValue ?? event.payload["title"]?.stringValue,
               !title.isEmpty {
                chat.title = title
            }

        case "turn.start":
            chat.isStreaming = true
            if isBackground { chat.needsAttention = true }

        case "message.start":
            ensureAssistantBubble(in: &chat)

        case "message.delta":
            if let text = event.payload["text"]?.stringValue {
                appendToAssistant(&chat, text)
            }

        case "reasoning.delta":
            if let text = event.payload["text"]?.stringValue {
                appendReasoning(&chat, text)
            }

        case "message.complete":
            if let text = event.payload["text"]?.stringValue, !text.isEmpty {
                setAssistantText(&chat, text)
            }
            let status = event.payload["status"]?.stringValue ?? "complete"
            markAssistant(&chat, status: status)
            chat.isStreaming = false
            chat.lastAssistantIndex = nil
            if isBackground { chat.needsAttention = true }
            if status == "error" {
                chat.messages.append(ChatMessage(role: .system, text: "⚠️ O agente reportou um erro."))
            }

        case "tool.start":
            if let name = event.payload["name"]?.stringValue {
                let call = ToolCall(name: name, status: "running")
                ensureAssistantBubble(in: &chat)
                if let i = chat.lastAssistantIndex, i < chat.messages.count {
                    chat.messages[i].tools.append(call)
                }
                chat.toolStatusText = "Usando \(name)…"
            }

        case "tool.complete":
            if let name = event.payload["name"]?.stringValue {
                updateTool(&chat, name: name, status: "done", summary: event.payload["summary"]?.stringValue)
            }
            chat.toolStatusText = nil

        case "tool.output_risk":
            chat.toolStatusText = "⚠️ Saída de ferramenta com risco potencial."

        case "status.update":
            if let text = event.payload["text"]?.stringValue, !isBackground {
                statusMessage = text
            }

        case "approval.request":
            let message = event.payload["message"]?.stringValue
                ?? event.payload["summary"]?.stringValue
                ?? event.payload["description"]?.stringValue
                ?? "O agente solicita aprovação."
            chat.pendingApproval = PendingApproval(
                sessionID: sessionID,
                message: message,
                requestID: event.payload["approval_id"]?.stringValue
            )
            if isBackground { chat.needsAttention = true }

        case "clarify.pending", "clarify.request", "clarify":
            if let text = event.payload["title"]?.stringValue
                ?? event.payload["prompt"]?.stringValue
                ?? event.payload["message"]?.stringValue {
                chat.messages.append(ChatMessage(role: .system, text: "❓ \(text)"))
            }
            chat.pendingClarifyID = event.payload["clarify_id"]?.stringValue
            chat.hasPendingClarify = true
            if isBackground { chat.needsAttention = true }

        case "error", "turn.error":
            let msg = event.payload["message"]?.stringValue ?? "Erro no agente."
            chat.isStreaming = false
            chat.lastAssistantIndex = nil
            chat.messages.append(ChatMessage(role: .system, text: "⚠️ \(msg)"))
            if isBackground { chat.needsAttention = true }
            else { statusMessage = msg }

        case "session.complete", "turn.end":
            chat.isStreaming = false
            chat.lastAssistantIndex = nil
            chat.toolStatusText = nil
            if isBackground { chat.needsAttention = true }

        default:
            break
        }

        commit(chat)
    }

    // MARK: - Helpers de chat

    private func chatIndex(for id: String) -> Int? {
        openChats.firstIndex(where: { $0.id == id })
    }

    private func chat(for id: String) -> OpenChat? {
        guard let i = chatIndex(for: id) else { return nil }
        return openChats[i]
    }

    private func mutableActiveChat() -> OpenChat? {
        guard let id = activeChatID ?? openChats.first?.id else { return nil }
        return chat(for: id)
    }

    private func commit(_ chat: OpenChat) {
        guard let i = chatIndex(for: chat.id) else {
            openChats.append(chat)
            return
        }
        openChats[i] = chat
    }

    private func clearAttention(for id: String) {
        guard var chat = chat(for: id) else { return }
        chat.needsAttention = false
        commit(chat)
    }

    private func ensureAssistantBubble(in chat: inout OpenChat) {
        if chat.lastAssistantIndex == nil {
            let a = ChatMessage(role: .assistant, text: "", status: "streaming", isStreaming: true)
            chat.messages.append(a)
            chat.lastAssistantIndex = chat.messages.count - 1
        } else if let i = chat.lastAssistantIndex, i < chat.messages.count {
            var m = chat.messages[i]
            m.status = "streaming"
            m.isStreaming = true
            chat.messages[i] = m
        }
    }

    private func appendToAssistant(_ chat: inout OpenChat, _ text: String) {
        ensureAssistantBubble(in: &chat)
        guard let i = chat.lastAssistantIndex, i < chat.messages.count else { return }
        chat.messages[i].text += text
        chat.messages[i].isStreaming = true
        chat.messages[i].status = "streaming"
    }

    private func appendReasoning(_ chat: inout OpenChat, _ text: String) {
        ensureAssistantBubble(in: &chat)
        guard let i = chat.lastAssistantIndex, i < chat.messages.count else { return }
        chat.messages[i].reasoning = (chat.messages[i].reasoning ?? "") + text
    }

    private func setAssistantText(_ chat: inout OpenChat, _ text: String) {
        ensureAssistantBubble(in: &chat)
        guard let i = chat.lastAssistantIndex, i < chat.messages.count else { return }
        chat.messages[i].text = text
    }

    private func markAssistant(_ chat: inout OpenChat, status: String) {
        guard let i = chat.lastAssistantIndex, i < chat.messages.count else { return }
        chat.messages[i].status = status
        chat.messages[i].isStreaming = false
    }

    private func updateTool(_ chat: inout OpenChat, name: String, status: String, summary: String?) {
        guard let i = chat.lastAssistantIndex, i < chat.messages.count else { return }
        for idx in chat.messages[i].tools.indices where chat.messages[i].tools[idx].name == name {
            chat.messages[i].tools[idx].status = status
            if let summary {
                chat.messages[i].tools[idx].summary = summary
            }
        }
    }

    private func finishTurn(sessionID: String, error: String?) {
        guard var chat = chat(for: sessionID) else { return }
        chat.isStreaming = false
        chat.lastAssistantIndex = nil
        chat.toolStatusText = nil
        if let error {
            if sessionID == activeChatID {
                statusMessage = error
            } else {
                chat.needsAttention = true
            }
            chat.messages.append(ChatMessage(role: .system, text: "⚠️ \(error)"))
        }
        commit(chat)
    }

    private func connectionIsError() -> Bool {
        if case .failed = connectionState { return true }
        return false
    }

    /// Mensagens legíveis para falhas de rede / ATS / auth.
    private static func describeConnectionError(_ error: Error, base: URL) -> String {
        let ns = error as NSError
        let urlError = error as? URLError
        let code = urlError?.code ?? URLError.Code(rawValue: ns.code)

        switch code {
        case .appTransportSecurityRequiresSecureConnection:
            return "O iOS bloqueou HTTP (ATS). Confirme que o app foi recompilado com NSAllowsArbitraryLoads. URL: \(base.absoluteString)"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "Não foi possível alcançar \(base.host ?? base.absoluteString). Verifique Tailscale/rede e se o Hermes está no ar."
        case .timedOut:
            return "Tempo esgotado ao conectar em \(base.absoluteString)."
        case .notConnectedToInternet:
            return "Sem conexão com a internet / Tailscale."
        default:
            if let hermes = error as? HermesClientError {
                return hermes.message
            }
            return "Não foi possível falar com o servidor (\(base.absoluteString)): \(error.localizedDescription)"
        }
    }
}
