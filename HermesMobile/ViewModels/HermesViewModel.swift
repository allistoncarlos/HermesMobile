import Foundation

// ============================================================================
//  HermesViewModel — orquestra autenticação, WebSocket JSON-RPC e chats
//  simultâneos (vários OpenChat sobre uma única conexão).
// ============================================================================

@MainActor
final class HermesViewModel: ObservableObject {

    @Published var config: ServerConfig

    @Published var connectionState: ConnectionState = .disconnected
    @Published var openChats: [OpenChat] = []
    @Published var activeChatID: String?
    @Published var sessions: [SessionSummary] = []
    @Published var serverVersion: String?
    @Published var statusMessage: String?
    @Published var authRequired: Bool = false
    @Published var passwordProviders: [AuthProviderInfo] = []
    @Published var showSidebar: Bool = false
    /// Só true após logout, “trocar servidor” ou senha inválida — aí a UI de login aparece.
    @Published var needsManualAuth: Bool = false
    /// Perfis/bots do gateway (`profiles.list`), indexados pelo nome.
    @Published var profilesByName: [String: AgentProfileInfo] = [:]
    /// Bytes de avatar por perfil (PNG/JPEG/WebP).
    @Published var avatarDataByProfile: [String: Data] = [:]
    /// Chats em grupo sincronizados do desktop (Vegapunk e afins).
    @Published var groupRooms: [GroupRoom] = []
    /// IDs fixados no drawer (`group::vegapunk`, `bot::atlas`, session id).
    @Published var pinnedIDs: [String] = []
    /// Chamado quando o assistente completa uma mensagem (para TTS em background).
    var onAssistantMessageComplete: ((String) -> Void)?

    /// App em foreground (atualizado pelo HermesMobileApp via scenePhase).
    var isAppForeground: Bool = true {
        didSet {
            #if os(iOS)
            HermesNotifier.shared.setForeground(isAppForeground)
            #endif
        }
    }

    private var ws: HermesWebSocket?
    /// Cliente HTTP compartilhado (login, ticket WS, áudio STT/TTS).
    private(set) var httpClient: HermesClient?
    private var usesCookieAuth = false
    /// Impede `connect()` reentrante (Watch + splash), sem abortar o restore
    /// que já inicia em `.connecting`.
    private var connectInFlight = false
    /// Evita loop de reconnect automático em queda de WS.
    private var autoReconnectInFlight = false
    private static let pinnedIDsKey = "hermes.drawerPinnedIDs"
    #if os(iOS)
    /// Hold de BackgroundRuntime enquanto algum chat está em streaming.
    private var turnBackgroundHeld = false
    #endif
    /// session_id de um bot em background → chat onde a fala deve aparecer.
    private var childSessionParents: [String: String] = [:]

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


    init(config: ServerConfig = ServerConfig()) {
        self.config = config
        if let url = ServerConfig.normalizedURL(from: config.baseURLString) {
            SessionCookieStore.restore(for: url)
        } else {
            SessionCookieStore.restore()
        }
        pinnedIDs = UserDefaults.standard.stringArray(forKey: Self.pinnedIDsKey) ?? []
        if config.hasSavedConfig && config.hasRestorableAuth {
            connectionState = .connecting
        }
        #if os(iOS)
        HermesNotifier.shared.configure()
        HermesNotifier.shared.onOpenChat = { [weak self] sessionID in
            Task { @MainActor in
                guard let self else { return }
                if let existing = self.openChats.first(where: {
                    $0.id == sessionID || $0.storedSessionID == sessionID
                }) {
                    await self.selectChat(existing.id)
                } else {
                    await self.resumeSession(
                        SessionSummary(id: sessionID, title: "Conversa", startedAt: nil, source: nil, isActive: false)
                    )
                }
            }
        }
        // Touch device id early so Fase 2 registration has a stable id.
        _ = HermesDeviceIdentity.deviceId
        #endif
    }


    var activeChat: OpenChat? {
        guard let id = activeChatID else { return openChats.first }
        return openChats.first(where: { $0.id == id }) ?? openChats.first
    }

    var messages: [ChatMessage] { activeChat?.messages ?? [] }
    var sessionTitle: String { activeChat?.title ?? "Nova conversa" }
    var sessionSubtitle: String? {
        if let sub = activeChat?.subtitle, !sub.isEmpty { return sub }
        if activeChat?.kind != .group { return activeChat?.model }
        return nil
    }
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


    /// Conecta ao servidor. Com cookies AT/RT salvos, renova via refresh token.
    /// Senha só é usada no momento do login (não é persistida).
    func connect(username: String? = nil, password: String? = nil) async {
        #if os(watchOS)
        return
        #else
        guard !connectInFlight else { return }
        connectInFlight = true
        defer { connectInFlight = false }
        connectionState = .connecting
        statusMessage = nil

        if let username {
            let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { config.username = trimmed }
        }

        guard let base = ServerConfig.normalizedURL(from: config.baseURLString) else {
            connectionState = .failed("Endereço do servidor inválido.")
            needsManualAuth = true
            syncCompanion()
            return
        }

        let client = HermesClient(
            baseURL: base,
            sessionToken: config.sessionToken.isEmpty ? nil : config.sessionToken,
            urlSession: HermesHTTPSession.shared
        )
        httpClient = client
        client.restorePersistedCookies()

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
            syncCompanion()
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
            let provider = passwordProviders.first?.name ?? status.authProviders?.first ?? "basic"

            if client.hasLiveSessionCookie() || client.hasLiveRefreshToken() {
                do {
                    try await client.ensureFreshSession()
                    markSessionRestorable(client: client)
                } catch {
                    if Self.isAuthFailure(error) {
                        // RT morto — tenta login com senha desta vez, se o usuário digitou.
                        if user.isEmpty || pass.isEmpty {
                            needsManualAuth = true
                            connectionState = .waitingAuth
                            statusMessage = "Sessão expirada. Informe usuário e senha para entrar de novo."
                            syncCompanion()
                            return
                        }
                        do {
                            _ = try await client.login(username: user, password: pass, provider: provider)
                            if !user.isEmpty { config.username = user }
                            markSessionRestorable(client: client)
                        } catch {
                            needsManualAuth = true
                            connectionState = .waitingAuth
                            statusMessage = error.localizedDescription
                            syncCompanion()
                            return
                        }
                    } else {
                        let msg = Self.describeConnectionError(error, base: base)
                        statusMessage = msg
                        connectionState = .failed(msg)
                        syncCompanion()
                        return
                    }
                }
            } else {
                guard !user.isEmpty, !pass.isEmpty else {
                    needsManualAuth = true
                    connectionState = .waitingAuth
                    statusMessage = "Este servidor exige login. Informe usuário e senha."
                    syncCompanion()
                    return
                }
                do {
                    _ = try await client.login(username: user, password: pass, provider: provider)
                    config.username = user
                    markSessionRestorable(client: client)
                } catch {
                    needsManualAuth = true
                    connectionState = .waitingAuth
                    statusMessage = error.localizedDescription
                    syncCompanion()
                    return
                }
            }
        } else if status.authRequired == true {
            if config.sessionToken.trimmingCharacters(in: .whitespaces).isEmpty {
                needsManualAuth = true
                connectionState = .waitingAuth
                statusMessage = "Este servidor exige um token de sessão (X-Hermes-Session-Token)."
                syncCompanion()
                return
            }
        }

        do {
            try await openWebSocket(base: base, client: client)
        } catch {
            if usesCookieAuth, Self.isAuthFailure(error) {
                let recovered = await refreshCookieSessionAndOpenSocket(
                    base: base,
                    client: client,
                    username: username,
                    password: password
                )
                if !recovered { return }
            } else {
                let msg = Self.describeConnectionError(error, base: base)
                statusMessage = msg
                connectionState = .failed(msg)
                syncCompanion()
                return
            }
        }

        needsManualAuth = false
        openChats = []
        activeChatID = nil
        await createSession()
        await loadSessions()
        await loadProfiles()
        syncCompanion()
        #if os(iOS)
        await HermesNotifier.shared.requestAuthorizationIfNeeded()
        syncNotifierContext()
        #endif
        #endif
    }

    /// AT/ticket expirado: renova com RT (`/auth/native/refresh`). Senha só se o RT morreu.
    @discardableResult
    private func refreshCookieSessionAndOpenSocket(
        base: URL,
        client: HermesClient,
        username: String? = nil,
        password: String? = nil
    ) async -> Bool {
        if client.hasLiveRefreshToken() {
            do {
                _ = try await client.refreshSession()
                markSessionRestorable(client: client)
                try await openWebSocket(base: base, client: client)
                return true
            } catch {
                if !Self.isAuthFailure(error) {
                    let msg = Self.describeConnectionError(error, base: base)
                    statusMessage = msg
                    connectionState = .failed(msg)
                    syncCompanion()
                    return false
                }
                // RT rejeitado — cai para senha se disponível nesta tentativa.
            }
        }

        let user = (username ?? config.username).trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password ?? ""
        guard !user.isEmpty, !pass.isEmpty else {
            needsManualAuth = true
            connectionState = .waitingAuth
            statusMessage = "Sessão expirada. Informe usuário e senha para entrar de novo."
            syncCompanion()
            return false
        }

        let provider = passwordProviders.first?.name ?? "basic"
        do {
            client.clearCookies()
            _ = try await client.login(username: user, password: pass, provider: provider)
            config.username = user
            markSessionRestorable(client: client)
            try await openWebSocket(base: base, client: client)
            return true
        } catch {
            needsManualAuth = true
            connectionState = .waitingAuth
            statusMessage = Self.isInvalidCredentials(error)
                ? error.localizedDescription
                : "Sessão expirada. Informe usuário e senha para entrar de novo."
            syncCompanion()
            return false
        }
    }

    private func markSessionRestorable(client: HermesClient) {
        config.canRestoreSession = true
        SessionCookieStore.persist(
            from: client.urlSession.configuration.httpCookieStorage,
            host: client.baseURL.host
        )
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
            try await client.ensureFreshSession()
            let ticket = try await client.mintWsTicket()
            comps.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
            markSessionRestorable(client: client)
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
                guard self.connectionState == .connected || self.connectionState == .connecting else { return }
                self.connectionState = .disconnected
                self.statusMessage = "Conexão com o servidor encerrada."
                self.syncCompanion()
                await self.autoReconnectIfPossible()
                #if os(iOS)
                // Só alerta se não reconectou — queda por lock/suspend costuma
                // ser recuperável quando ainda há hold de turno.
                if case .connected = self.connectionState { return }
                HermesNotifier.shared.notifyConnectionLost(message: "Conexão com o servidor encerrada.")
                #endif
            }
        }
        try socket.connect()
        self.ws = socket
    }

    /// Reconecta sozinho após queda de rede — sem voltar à tela de login.
    private func autoReconnectIfPossible() async {
        guard !needsManualAuth else { return }
        guard config.hasSavedConfig, config.hasRestorableAuth else { return }
        guard !autoReconnectInFlight, !connectInFlight else { return }
        autoReconnectInFlight = true
        defer { autoReconnectInFlight = false }
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard connectionState == .disconnected || connectionState.isFailed else { return }
        await connect()
    }

    #if os(iOS)
    private func syncCompanion() {
        CompanionSync.shared.push(from: self)
    }
    #else
    private func syncCompanion() {}
    #endif

    func disconnect() {
        ws?.disconnect()
        ws = nil
        connectionState = .disconnected
        openChats = []
        activeChatID = nil
    }

    /// Sai e limpa cookies/tokens — única forma de voltar ao formulário de login de propósito.
    func logout() async {
        await httpClient?.logout()
        config.canRestoreSession = false
        SessionCookieStore.clear()
        needsManualAuth = true
        disconnect()
        statusMessage = "Sessão encerrada."
        syncCompanion()
    }

    /// Abre o setup para trocar servidor.
    func presentServerSetup() {
        disconnect()
        needsManualAuth = true
        statusMessage = nil
        syncCompanion()
    }


    private func createSession() async {
        guard let ws else { return }
        do {
            let result = try await ws.call(method: "session.create", params: ["cols": .number(80)])
            if let sid = result["session_id"]?.stringValue {
                let stored = result["stored_session_id"]?.stringValue ?? sid
                let chat = OpenChat(id: sid, storedSessionID: stored, title: "Nova conversa")
                openChats.append(chat)
                activeChatID = sid
                #if os(iOS)
                syncNotifierContext()
                #endif
                if !connectionIsError() {
                    connectionState = .connected
                    if let client = httpClient {
                        markSessionRestorable(client: client)
                    } else {
                        config.canRestoreSession = true
                    }
                    syncCompanion()
                }
            }
        } catch {
            connectionState = .failed(error.localizedDescription)
            syncCompanion()
        }
    }

    func newSession() async {
        // Já existe conversa em branco → só ativa ela (não empilha várias "Nova conversa").
        if let blank = openChats.first(where: { Self.isBlankChat($0) }) {
            await selectChat(blank.id)
            return
        }

        guard let ws else { return }
        do {
            let result = try await ws.call(method: "session.create", params: ["cols": .number(80)])
            if let sid = result["session_id"]?.stringValue {
                let stored = result["stored_session_id"]?.stringValue ?? sid
                // Remove outras abertas em branco antes de adicionar.
                pruneBlankOpenChats(keeping: nil)
                let chat = OpenChat(id: sid, storedSessionID: stored, title: "Nova conversa")
                openChats.append(chat)
                activeChatID = sid
                showSidebar = false
                #if os(iOS)
                syncNotifierContext()
                #endif
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
        #if os(iOS)
        syncNotifierContext()
        #endif
        // Ativa a sessão no servidor (se suportado).
        if let ws {
            _ = try? await ws.call(method: "session.activate", params: ["session_id": .string(id)])
        }
    }

    #if os(iOS)
    private func syncNotifierContext() {
        HermesNotifier.shared.activeChatID = activeChatID
        HermesNotifier.shared.setForeground(isAppForeground)
    }

    /// Mantém o processo vivo (áudio + background task) enquanto o agente responde.
    private func updateTurnBackgroundHold() {
        let streaming = openChats.contains(where: \.isStreaming)
        if streaming, !turnBackgroundHeld {
            BackgroundRuntime.shared.retain(reason: "Hermes processando")
            turnBackgroundHeld = true
        } else if !streaming, turnBackgroundHeld {
            BackgroundRuntime.shared.release()
            turnBackgroundHeld = false
        }
    }

    /// Chamado no lock / background: reforça o hold se ainda há turno aberto.
    func ensureBackgroundHoldForActiveTurns() {
        updateTurnBackgroundHold()
        if turnBackgroundHeld {
            HermesAudioSession.reassertIfNeeded()
        }
    }
    #endif

    func closeChat(_ id: String) {
        Task { await closeLiveSessionOnServer(id) }
        openChats.removeAll { $0.id == id }
        if activeChatID == id {
            activeChatID = openChats.first?.id
        }
        #if os(iOS)
        syncNotifierContext()
        #endif
    }

    /// Arquiva no servidor e remove da lista / abertas.
    func archiveSession(storedID: String) async {
        let open = openChats.filter {
            $0.storedSessionID == storedID || $0.id == storedID
        }
        for chat in open {
            closeChat(chat.id)
        }
        do {
            if let client = httpClient {
                try await client.setSessionArchived(id: storedID, archived: true)
            } else if let ws {
                // Fallback: alguns gateways só têm delete; archive via REST é o caminho preferido.
                _ = try? await ws.call(
                    method: "session.archive",
                    params: ["session_id": .string(storedID), "archived": .bool(true)]
                )
            }
            sessions.removeAll { $0.id == storedID }
            await ensureActiveChatExists()
            await loadSessions()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Exclui permanentemente no servidor.
    func deleteSession(storedID: String) async {
        let open = openChats.filter {
            $0.storedSessionID == storedID || $0.id == storedID
        }
        for chat in open {
            closeChat(chat.id)
        }
        do {
            if let client = httpClient {
                try await client.deleteStoredSession(id: storedID)
            } else if let ws {
                _ = try await ws.call(
                    method: "session.delete",
                    params: ["session_id": .string(storedID)]
                )
            }
            sessions.removeAll { $0.id == storedID }
            await ensureActiveChatExists()
            await loadSessions()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Arquiva/exclui a partir de um chat aberto (usa stored id quando houver).
    func archiveOpenChat(_ chat: OpenChat) async {
        let sid = chat.storedSessionID ?? chat.id
        if Self.isBlankChat(chat) {
            closeChat(chat.id)
            await ensureActiveChatExists()
            return
        }
        await archiveSession(storedID: sid)
    }

    func deleteOpenChat(_ chat: OpenChat) async {
        let sid = chat.storedSessionID ?? chat.id
        if Self.isBlankChat(chat) {
            closeChat(chat.id)
            await ensureActiveChatExists()
            return
        }
        await deleteSession(storedID: sid)
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
                        let (prefixSpeaker, body) = ChatSpeaker.strippingDeliveryPrefix(text)
                        let speaker: ChatSpeaker
                        if role == .user {
                            speaker = .user
                        } else if let prefixSpeaker {
                            speaker = prefixSpeaker
                        } else {
                            speaker = ChatSpeaker.resolve(
                                from: m,
                                sessionID: sid,
                                profiles: profilesByName,
                                fallback: .hermes
                            )
                        }
                        if role == .assistant || role == .system {
                            chat.messages.append(ChatMessage(role: role, text: body, speaker: speaker))
                        } else {
                            chat.messages.append(ChatMessage(role: role, text: text, speaker: speaker))
                        }
                    }
                }
            }
            if chat.messages.isEmpty {
                chat.messages.append(ChatMessage(role: .system, text: "Conversa em andamento no servidor."))
            }
            // Ao retomar histórico, fecha conversas em branco ociosas.
            pruneBlankOpenChats(keeping: sid)
            if let idx = openChats.firstIndex(where: { $0.id == sid }) {
                openChats[idx] = chat
            } else {
                openChats.append(chat)
            }
            activeChatID = sid
            showSidebar = false
            #if os(iOS)
            syncNotifierContext()
            #endif
            _ = try? await ws.call(method: "session.activate", params: ["session_id": .string(sid)])
        } catch {
            statusMessage = "Erro ao abrir a conversa: \(error.localizedDescription)"
        }
    }


    /// Conversa sem mensagens de usuário (ainda não começou de verdade).
    static func isBlankChat(_ chat: OpenChat) -> Bool {
        if chat.kind != .direct { return false }
        return !chat.messages.contains { $0.role == .user }
            && !chat.isStreaming
            && chat.pendingApproval == nil
            && !chat.hasPendingClarify
    }

    /// Remove abertas em branco, opcionalmente preservando um id.
    private func pruneBlankOpenChats(keeping keepID: String?) {
        let victims = openChats.filter { Self.isBlankChat($0) && $0.id != keepID }
        for chat in victims {
            Task { await closeLiveSessionOnServer(chat.id) }
        }
        openChats.removeAll { chat in
            Self.isBlankChat(chat) && chat.id != keepID
        }
        if let active = activeChatID, !openChats.contains(where: { $0.id == active }) {
            activeChatID = openChats.first?.id
        }
    }

    private func closeLiveSessionOnServer(_ id: String) async {
        guard let ws else { return }
        _ = try? await ws.call(method: "session.close", params: ["session_id": .string(id)])
    }

    /// Garante que sempre haja uma conversa ativa após arquivar/excluir.
    private func ensureActiveChatExists() async {
        if activeChatID != nil, openChats.contains(where: { $0.id == activeChatID }) {
            return
        }
        if let first = openChats.first {
            activeChatID = first.id
            return
        }
        await newSession()
    }


    private static let attachTimeoutSeconds: TimeInterval = 120

    func send(_ rawText: String, attachments: [ChatAttachment] = []) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), let ws, var chat = mutableActiveChat() else { return }

        if chat.hasPendingClarify {
            guard !text.isEmpty else { return }
            await respondClarify(text)
            return
        }

        do {
            if chat.kind == .group || chat.kind == .bot {
                chat = try await ensureBackingSession(chat)
            }
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        let rpcSessionID = chat.backingSessionID ?? chat.id

        // Bolha do usuário só guarda preview leve — bytes completos ficam só no upload.
        let displayAttachments = attachments.map { $0.forDisplay() }
        chat.messages.append(ChatMessage(role: .user, text: text, attachments: displayAttachments, speaker: .user))
        let assistant = ChatMessage(role: .assistant, text: "", status: "streaming", isStreaming: true, speaker: .hermes)
        chat.messages.append(assistant)
        chat.lastAssistantIndex = chat.messages.count - 1
        chat.toolStatusText = attachments.isEmpty ? "Pensando…" : "Enviando anexos…"
        chat.isStreaming = true
        chat.needsAttention = false
        commit(chat)
        statusMessage = nil

        do {
            var promptText = try await uploadAttachments(attachments, sessionID: rpcSessionID, visibleText: text)
            if chat.kind == .group {
                let members = chat.subtitle ?? ""
                promptText = "[Chat em grupo: \(chat.title). Participantes: \(members)]\n\n" + promptText
            }
            if var updated = self.chat(for: chat.id) {
                updated.toolStatusText = "Pensando…"
                commit(updated)
            }
            _ = try await ws.call(
                method: "prompt.submit",
                params: ["session_id": .string(rpcSessionID), "text": .string(promptText)],
                timeoutSeconds: Self.attachTimeoutSeconds
            )
        } catch {
            finishTurn(sessionID: chat.id, error: error.localizedDescription)
        }
    }

    /// Faz upload remoto dos anexos (`image.attach_bytes` / `file.attach` / `pdf.attach`)
    /// e monta o texto do prompt com as refs `@file:` quando necessário.
    private func uploadAttachments(
        _ attachments: [ChatAttachment],
        sessionID: String,
        visibleText: String
    ) async throws -> String {
        guard let ws else {
            throw HermesClientError(message: "WebSocket desconectado.")
        }

        var fileRefs: [String] = []
        var hasImage = false
        let total = attachments.count

        for (index, attachment) in attachments.enumerated() {
            setToolStatus(
                sessionID: sessionID,
                "Enviando \(index + 1)/\(total): \(attachment.filename)…"
            )

            switch attachment.kind {
            case .image:
                hasImage = true
                let b64 = await Self.base64Encode(attachment.data)
                let result = try await ws.call(
                    method: "image.attach_bytes",
                    params: [
                        "session_id": .string(sessionID),
                        "content_base64": .string(b64),
                        "filename": .string(attachment.filename),
                    ],
                    timeoutSeconds: Self.attachTimeoutSeconds
                )
                if result["attached"]?.boolValue == false {
                    let msg = result["message"]?.stringValue ?? "Falha ao anexar \(attachment.filename)"
                    throw HermesClientError(message: msg)
                }

            case .file:
                if attachment.isPDF {
                    do {
                        let b64 = await Self.base64Encode(attachment.data)
                        let result = try await ws.call(
                            method: "pdf.attach",
                            params: [
                                "session_id": .string(sessionID),
                                "content_base64": .string(b64),
                                "filename": .string(attachment.filename),
                            ],
                            timeoutSeconds: Self.attachTimeoutSeconds
                        )
                        // pdf.attach renderiza páginas como imagens enfileiradas.
                        if result["attached"]?.boolValue == false {
                            throw HermesClientError(message: result["message"]?.stringValue ?? "Falha ao anexar PDF")
                        }
                        hasImage = true
                    } catch {
                        if let ref = try await attachFile(attachment, sessionID: sessionID, ws: ws) {
                            fileRefs.append(ref)
                        }
                    }
                } else if let ref = try await attachFile(attachment, sessionID: sessionID, ws: ws) {
                    fileRefs.append(ref)
                }
            }
        }

        let parts = [fileRefs.joined(separator: "\n"), visibleText].filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: "\n\n")
        }
        if hasImage {
            return "O que você vê nesta imagem?"
        }
        if !attachments.isEmpty {
            throw HermesClientError(message: "Não foi possível preparar o anexo para envio.")
        }
        return visibleText
    }

    private func attachFile(
        _ attachment: ChatAttachment,
        sessionID: String,
        ws: HermesWebSocket
    ) async throws -> String? {
        let dataURL = await Task.detached(priority: .userInitiated) {
            attachment.dataURL
        }.value
        let result = try await ws.call(
            method: "file.attach",
            params: [
                "session_id": .string(sessionID),
                "path": .string(attachment.filename),
                "name": .string(attachment.filename),
                "data_url": .string(dataURL),
            ],
            timeoutSeconds: Self.attachTimeoutSeconds
        )
        if result["attached"]?.boolValue == false {
            let msg = result["message"]?.stringValue ?? "Falha ao anexar \(attachment.filename)"
            throw HermesClientError(message: msg)
        }
        guard let ref = result["ref_text"]?.stringValue, !ref.isEmpty else {
            throw HermesClientError(message: "Servidor não retornou referência para \(attachment.filename).")
        }
        return ref
    }

    private static func base64Encode(_ data: Data) async -> String {
        await Task.detached(priority: .userInitiated) {
            data.base64EncodedString()
        }.value
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


    func respondApproval(allow: Bool) async {
        guard let ws, var chat = mutableActiveChat(), let approval = chat.pendingApproval else { return }
        chat.pendingApproval = nil
        commit(chat)
        syncCompanion()
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


    private func handle(_ event: HermesEvent) {
        // Eventos globais sem sessão.
        if event.type == "gateway.ready" {
            if !connectionIsError() {
                connectionState = .connected
            }
            Task { await loadProfiles() }
            return
        }

        let originalSID = event.sessionID
        rememberSessionLinks(event)
        let sid = resolveTargetSession(event)
        // Se não temos chat para esse session_id, ignora (exceto se for o ativo implícito).
        guard !sid.isEmpty, chatIndex(for: sid) != nil || !openChats.isEmpty else {
            if originalSID.isEmpty, let active = activeChatID {
                handle(event, for: active, originalSessionID: originalSID)
            }
            return
        }

        let target = sid.isEmpty ? (activeChatID ?? "") : sid
        guard !target.isEmpty else { return }
        handle(event, for: target, originalSessionID: originalSID)
    }

    private func handle(_ event: HermesEvent, for sessionID: String, originalSessionID: String? = nil) {
        let origin = originalSessionID ?? event.sessionID
        // Bots em background: não abrir um chat novo na sidebar — fala no thread atual.
        if chatIndex(for: sessionID) == nil {
            if shouldJoinActiveThread(event, sessionID: sessionID), let active = activeChatID {
                handle(event, for: active, originalSessionID: origin)
                return
            }
            openChats.append(OpenChat(id: sessionID, title: "Conversa"))
        }
        guard var chat = chat(for: sessionID) else { return }
        let isBackground = sessionID != activeChatID
        let speaker = ChatSpeaker.resolve(
            from: event.payload,
            sessionID: origin,
            profiles: profilesByName,
            fallback: .hermes
        )

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
            ensureAssistantBubble(in: &chat, speaker: speaker)
            chat.toolStatusText = nil

        case "message.delta":
            if let text = event.payload["text"]?.stringValue {
                appendToAssistant(&chat, text, speaker: speaker)
                chat.toolStatusText = nil
            }

        case "reasoning.delta":
            if let text = event.payload["text"]?.stringValue {
                appendReasoning(&chat, text, speaker: speaker)
                let assistantTextEmpty: Bool = {
                    guard let i = chat.lastAssistantIndex, i < chat.messages.count else { return true }
                    return chat.messages[i].text.isEmpty
                }()
                chat.toolStatusText = assistantTextEmpty ? "Raciocinando…" : nil
            }

        case "message.complete":
            if let text = event.payload["text"]?.stringValue, !text.isEmpty {
                let (prefixSpeaker, body) = ChatSpeaker.strippingDeliveryPrefix(text)
                setAssistantText(&chat, body, speaker: prefixSpeaker ?? speaker)
            }
            let status = event.payload["status"]?.stringValue ?? "complete"
            markAssistant(&chat, status: status)
            chat.isStreaming = false
            chat.lastAssistantIndex = nil
            chat.toolStatusText = nil
            if isBackground { chat.needsAttention = true }
            if status == "error" {
                chat.messages.append(ChatMessage(role: .system, text: "⚠️ O agente reportou um erro."))
                #if os(iOS)
                HermesNotifier.shared.notifyError(
                    sessionID: sessionID,
                    message: "O agente reportou um erro."
                )
                #endif
            } else {
                let spoken = chat.messages.last(where: { $0.role == .assistant })?.text
                    ?? event.payload["text"]?.stringValue
                    ?? ""
                let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if config.speakRepliesAutomatically {
                        onAssistantMessageComplete?(trimmed)
                    }
                    #if os(iOS)
                    let title = chat.title.isEmpty ? "Hermes" : chat.title
                    HermesNotifier.shared.notifyReplyReady(
                        sessionID: sessionID,
                        title: title,
                        body: trimmed
                    )
                    #endif
                }
            }

        case "tool.start":
            if let name = event.payload["name"]?.stringValue {
                let call = ToolCall(name: name, status: "running")
                ensureAssistantBubble(in: &chat, speaker: speaker)
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
            #if os(iOS)
            HermesNotifier.shared.notifyApproval(sessionID: sessionID, message: message)
            #endif
            commit(chat)
            syncCompanion()
            return

        case "clarify.pending", "clarify.request", "clarify":
            let clarifyText = event.payload["title"]?.stringValue
                ?? event.payload["prompt"]?.stringValue
                ?? event.payload["message"]?.stringValue
            if let text = clarifyText {
                chat.messages.append(ChatMessage(role: .system, text: "❓ \(text)"))
            }
            chat.pendingClarifyID = event.payload["clarify_id"]?.stringValue
            chat.hasPendingClarify = true
            if isBackground { chat.needsAttention = true }
            #if os(iOS)
            HermesNotifier.shared.notifyClarify(
                sessionID: sessionID,
                message: clarifyText ?? "O Hermes precisa de uma resposta."
            )
            #endif

        case "error", "turn.error":
            let msg = event.payload["message"]?.stringValue ?? "Erro no agente."
            chat.isStreaming = false
            chat.lastAssistantIndex = nil
            chat.messages.append(ChatMessage(role: .system, text: "⚠️ \(msg)"))
            if isBackground { chat.needsAttention = true }
            else { statusMessage = msg }
            #if os(iOS)
            HermesNotifier.shared.notifyError(sessionID: sessionID, message: msg)
            #endif

        case "session.complete", "turn.end":
            chat.isStreaming = false
            chat.lastAssistantIndex = nil
            chat.toolStatusText = nil
            if isBackground { chat.needsAttention = true }

        case "subagent.start", "subagent.started", "background.start",
             "delegation.start", "delegate.start":
            var botSpeaker = speaker
            if botSpeaker.key == "hermes" {
                let goal = event.payload["goal"]?.stringValue
                    ?? event.payload["task"]?.stringValue
                    ?? event.payload["label"]?.stringValue
                if let goal, let inferred = ChatSpeaker.inferBot(from: goal) {
                    botSpeaker = ChatSpeaker.resolve(
                        from: nil,
                        sessionID: inferred,
                        profiles: profilesByName,
                        fallback: ChatSpeaker(key: inferred, displayName: ChatSpeaker.prettyName(inferred))
                    )
                } else if let label = event.payload["label"]?.stringValue, !label.isEmpty {
                    botSpeaker = ChatSpeaker(key: label.lowercased(), displayName: ChatSpeaker.prettyName(label))
                }
            }
            ensureAssistantBubble(in: &chat, speaker: botSpeaker, forceNew: true)
            if let goal = event.payload["goal"]?.stringValue ?? event.payload["task"]?.stringValue {
                chat.toolStatusText = "\(botSpeaker.displayName): \(goal)"
            } else {
                chat.toolStatusText = "\(botSpeaker.displayName) está trabalhando…"
            }
            chat.isStreaming = true
            if let child = event.payload["child_session_id"]?.stringValue
                ?? event.payload["session_id"]?.stringValue {
                if !chat.linkedSessionIDs.contains(child) {
                    chat.linkedSessionIDs.append(child)
                }
                childSessionParents[child] = chat.id
            }

        case "subagent.delta", "subagent.text", "subagent.message", "background.delta":
            if let text = event.payload["text"]?.stringValue ?? event.payload["delta"]?.stringValue {
                appendToAssistant(&chat, text, speaker: speaker, forceNewIfIdle: true)
            }

        case "subagent.thinking", "subagent.reasoning":
            if let text = event.payload["text"]?.stringValue {
                appendReasoning(&chat, text, speaker: speaker, forceNewIfIdle: true)
            }

        case "subagent.tool", "subagent.progress":
            if let name = event.payload["name"]?.stringValue
                ?? event.payload["tool"]?.stringValue
                ?? event.payload["tool_name"]?.stringValue {
                let call = ToolCall(name: name, status: "running")
                ensureAssistantBubble(in: &chat, speaker: speaker, forceNew: false)
                if let i = chat.lastAssistantIndex, i < chat.messages.count,
                   !chat.messages[i].tools.contains(where: { $0.name == name && $0.status == "running" }) {
                    chat.messages[i].tools.append(call)
                }
                chat.toolStatusText = "\(speaker.displayName) · \(name)"
            }

        case "subagent.complete", "subagent.done", "background.complete",
             "delegation.complete", "delegate.complete":
            let raw = event.payload["summary"]?.stringValue
                ?? event.payload["text"]?.stringValue
                ?? event.payload["result"]?.stringValue
            if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let (_, body) = ChatSpeaker.strippingDeliveryPrefix(raw)
                setAssistantText(&chat, body, speaker: speaker)
            }
            markAssistant(&chat, status: event.payload["status"]?.stringValue ?? "complete")
            chat.toolStatusText = nil
            if isBackground { chat.needsAttention = true }
            #if os(iOS)
            if let preview = event.payload["summary"]?.stringValue ?? event.payload["text"]?.stringValue {
                let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    HermesNotifier.shared.notifyReplyReady(
                        sessionID: sessionID,
                        title: speaker.displayName,
                        body: trimmed
                    )
                }
            }
            #endif

        default:
            break
        }

        commit(chat)
    }


    private func chatIndex(for id: String) -> Int? {
        openChats.firstIndex(where: {
            $0.id == id || $0.backingSessionID == id || $0.linkedSessionIDs.contains(id)
        })
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
            #if os(iOS)
            updateTurnBackgroundHold()
            #endif
            return
        }
        openChats[i] = chat
        #if os(iOS)
        updateTurnBackgroundHold()
        #endif
    }

    private func setToolStatus(sessionID: String, _ text: String?) {
        guard var chat = chat(for: sessionID) else { return }
        chat.toolStatusText = text
        commit(chat)
    }

    private func clearAttention(for id: String) {
        guard var chat = chat(for: id) else { return }
        chat.needsAttention = false
        commit(chat)
    }

    private func ensureAssistantBubble(in chat: inout OpenChat, speaker: ChatSpeaker = .hermes, forceNew: Bool = false) {
        if !forceNew,
           let i = chat.messages.lastIndex(where: {
               $0.role == .assistant && $0.speakerKey == speaker.key && $0.isStreaming
           }) {
            chat.lastAssistantIndex = i
            var m = chat.messages[i]
            m.status = "streaming"
            m.isStreaming = true
            if m.speakerName.isEmpty { m.speakerName = speaker.displayName }
            chat.messages[i] = m
            return
        }
        let a = ChatMessage(role: .assistant, text: "", status: "streaming", isStreaming: true, speaker: speaker)
        chat.messages.append(a)
        chat.lastAssistantIndex = chat.messages.count - 1
    }

    private func appendToAssistant(_ chat: inout OpenChat, _ text: String, speaker: ChatSpeaker = .hermes, forceNewIfIdle: Bool = false) {
        ensureAssistantBubble(in: &chat, speaker: speaker, forceNew: false)
        guard let i = chat.lastAssistantIndex, i < chat.messages.count else { return }
        if forceNewIfIdle, chat.messages[i].speakerKey != speaker.key {
            ensureAssistantBubble(in: &chat, speaker: speaker, forceNew: true)
        }
        guard let idx = chat.lastAssistantIndex, idx < chat.messages.count else { return }
        chat.messages[idx].text += text
        chat.messages[idx].isStreaming = true
        chat.messages[idx].status = "streaming"
    }

    private func appendReasoning(_ chat: inout OpenChat, _ text: String, speaker: ChatSpeaker = .hermes, forceNewIfIdle: Bool = false) {
        ensureAssistantBubble(in: &chat, speaker: speaker, forceNew: false)
        if forceNewIfIdle, let i = chat.lastAssistantIndex, chat.messages[i].speakerKey != speaker.key {
            ensureAssistantBubble(in: &chat, speaker: speaker, forceNew: true)
        }
        guard let i = chat.lastAssistantIndex, i < chat.messages.count else { return }
        chat.messages[i].reasoning = (chat.messages[i].reasoning ?? "") + text
    }

    private func setAssistantText(_ chat: inout OpenChat, _ text: String, speaker: ChatSpeaker = .hermes) {
        ensureAssistantBubble(in: &chat, speaker: speaker)
        guard let i = chat.lastAssistantIndex, i < chat.messages.count else { return }
        chat.messages[i].text = text
        chat.messages[i].speakerKey = speaker.key
        chat.messages[i].speakerName = speaker.displayName
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
        if let i = chat.lastAssistantIndex, i < chat.messages.count {
            if chat.messages[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (chat.messages[i].reasoning ?? "").isEmpty,
               chat.messages[i].tools.isEmpty {
                chat.messages.remove(at: i)
            } else {
                chat.messages[i].isStreaming = false
                chat.messages[i].status = error == nil ? "complete" : "error"
            }
        }
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

    private static func isAuthFailure(_ error: Error) -> Bool {
        if let hermes = error as? HermesClientError {
            let msg = hermes.message.lowercased()
            return msg.contains("sessão expirada") || msg.contains("401")
        }
        return false
    }

    private static func isInvalidCredentials(_ error: Error) -> Bool {
        if let hermes = error as? HermesClientError {
            let msg = hermes.message.lowercased()
            return msg.contains("usuário ou senha") || msg.contains("inválid")
        }
        return false
    }

    /// Mensagens legíveis para falhas de rede / ATS / auth.
    private static func describeConnectionError(_ error: Error, base: URL) -> String {
        let ns = error as NSError
        let urlError = error as? URLError
        let code = urlError?.code ?? URLError.Code(rawValue: ns.code)

        switch code {
        case .appTransportSecurityRequiresSecureConnection:
            #if os(watchOS)
            return "O watchOS bloqueou HTTP (ATS). Confirme NSAllowsArbitraryLoads. URL: \(base.absoluteString)"
            #else
            return "O iOS bloqueou HTTP (ATS). Confirme que o app foi recompilado com NSAllowsArbitraryLoads. URL: \(base.absoluteString)"
            #endif
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

    // MARK: - Perfis / bots em background

    func avatarData(for speakerKey: String) -> Data? {
        avatarDataByProfile[speakerKey]
            ?? avatarDataByProfile[speakerKey.lowercased()]
    }


    // MARK: - Drawer: grupos, bots e pins

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    func togglePin(_ id: String) {
        if let idx = pinnedIDs.firstIndex(of: id) {
            pinnedIDs.remove(at: idx)
        } else {
            pinnedIDs.insert(id, at: 0)
        }
        UserDefaults.standard.set(pinnedIDs, forKey: Self.pinnedIDsKey)
    }

    var drawerBots: [AgentProfileInfo] {
        profilesByName.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func pinKey(forBot name: String) -> String { "bot::\(name.lowercased())" }

    func refreshRoster() async {
        await loadProfiles()
    }

    func openGroupRoom(_ room: GroupRoom) async {
        if let existing = openChats.first(where: { $0.id == room.id }) {
            var updated = existing
            updated.messages = room.messages
            updated.subtitle = room.members.map(\.displayName).joined(separator: ", ")
            updated.lastActivity = room.lastActivity
            commit(updated)
            await selectChat(room.id)
            return
        }
        pruneBlankOpenChats(keeping: room.id)
        let chat = OpenChat(
            id: room.id,
            title: room.name,
            messages: room.messages,
            kind: .group,
            subtitle: room.members.map(\.displayName).joined(separator: ", "),
            lastActivity: room.lastActivity
        )
        openChats.append(chat)
        await selectChat(room.id)
    }

    func openBotProfile(_ profile: AgentProfileInfo) async {
        let key = pinKey(forBot: profile.name)
        if let existing = openChats.first(where: { $0.id == key || $0.kind == .bot && $0.title == profile.displayName }) {
            await selectChat(existing.id)
            return
        }
        if let sid = profile.canonicalSessionID ?? profile.lastSessionID, !sid.isEmpty {
            await resumeSession(SessionSummary(id: sid, title: profile.displayName, startedAt: nil, source: profile.name, isActive: false))
            if var chat = openChats.first(where: { $0.id == sid || $0.storedSessionID == sid }) {
                chat.kind = .bot
                chat.subtitle = profile.summary
                commit(chat)
            }
            return
        }
        pruneBlankOpenChats(keeping: key)
        var chat = OpenChat(id: key, title: profile.displayName, kind: .bot, subtitle: profile.summary)
        do {
            chat = try await ensureBackingSession(chat)
        } catch {
            statusMessage = error.localizedDescription
        }
        if let i = openChats.firstIndex(where: { $0.id == chat.id }) {
            openChats[i] = chat
        } else {
            openChats.append(chat)
        }
        await selectChat(chat.id)
    }

    private func ensureBackingSession(_ chat: OpenChat) async throws -> OpenChat {
        var chat = chat
        if let sid = chat.backingSessionID, !sid.isEmpty { return chat }
        guard let ws else { throw HermesClientError(message: "Sem conexão com o servidor.") }
        var params: [String: JSONValue] = ["cols": .number(80)]
        if chat.kind == .bot {
            let name = chat.id.hasPrefix("bot::") ? String(chat.id.dropFirst(5)) : chat.title.lowercased()
            params["profile"] = .string(name)
        }
        let result: JSONValue
        do {
            result = try await ws.call(method: "session.create", params: params)
        } catch {
            if params["profile"] != nil {
                result = try await ws.call(method: "session.create", params: ["cols": .number(80)])
            } else {
                throw error
            }
        }
        guard let sid = result["session_id"]?.stringValue else {
            throw HermesClientError(message: "O servidor não devolveu session_id.")
        }
        chat.backingSessionID = sid
        chat.storedSessionID = result["stored_session_id"]?.stringValue ?? sid
        if !chat.linkedSessionIDs.contains(sid) {
            chat.linkedSessionIDs.append(sid)
        }
        childSessionParents[sid] = chat.id
        commit(chat)
        return chat
    }

    private func parseGroupRooms(from profiles: [JSONValue]) -> [GroupRoom] {
        var rooms: [GroupRoom] = []
        for row in profiles {
            let meta = row["ui_meta"] ?? row["ui_meta"] ?? row["meta"]
            let blob = meta?["hermes-bots-groups"]
                ?? meta?["hermes-bots-groups"]
                ?? row["hermes-bots-groups"]
            guard let blob else { continue }
            rooms.append(contentsOf: Self.rooms(fromSyncBlob: blob))
        }
        var unique: [String: GroupRoom] = [:]
        for room in rooms { unique[room.id] = room }
        return unique.values.sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    private static func rooms(fromSyncBlob blob: JSONValue) -> [GroupRoom] {
        let root = blob.objectValue ?? [:]
        var dict = root["rooms"]?.objectValue ?? [:]
        if dict.isEmpty, let arr = root["rooms"]?.arrayValue {
            for item in arr {
                let name = item["name"]?.stringValue ?? ""
                if !name.isEmpty { dict[name] = item }
            }
        }
        if dict.isEmpty {
            dict = root.filter { key, value in
                key != "version" && key != "deleted" && key != "updatedAt" && value.objectValue != nil
            }
        }
        var rooms: [GroupRoom] = []
        for (key, value) in dict {
            guard let obj = value.objectValue else { continue }
            let name = obj["name"]?.stringValue
                ?? key.split(separator: ":").last.map(String.init)
                ?? key
            guard !name.isEmpty else { continue }
            let members: [GroupMember] = (obj["members"]?.arrayValue ?? []).compactMap { item in
                let n = item["name"]?.stringValue ?? item["handle"]?.stringValue ?? ""
                guard !n.isEmpty else { return nil }
                return GroupMember(key: n.lowercased(), displayName: ChatSpeaker.prettyName(n))
            }
            let log = obj["log"] ?? obj["messages"]
            let messages: [ChatMessage] = (log?.arrayValue ?? []).compactMap { entry in
                Self.message(fromGroupLog: entry)
            }
            let last = messages.last
            let preview: String? = {
                guard let last else { return members.isEmpty ? nil : "\(members.count) bots" }
                if last.role == .user { return last.text }
                return "\(last.speakerName): \(last.text)"
            }()
            let lastAt: Date? = {
                if let n = obj["updatedAt"]?.number ?? obj["updated_at"]?.number {
                    return Date(timeIntervalSince1970: n > 20_000_000_000 ? n / 1000 : n)
                }
                return nil
            }()
            rooms.append(GroupRoom(
                name: name,
                members: members,
                messages: messages,
                preview: preview,
                lastActivity: lastAt,
                imageDataURL: obj["image"]?.stringValue
            ))
        }
        return rooms
    }

    private static func message(fromGroupLog entry: JSONValue) -> ChatMessage? {
        let text = entry["text"]?.stringValue ?? entry["content"]?.stringValue ?? ""
        guard !text.isEmpty else { return nil }
        let from = entry["from"]
        let kind = from?["kind"]?.stringValue ?? entry["kind"]?.stringValue ?? ""
        let name = from?["name"]?.stringValue ?? entry["name"]?.stringValue ?? ""
        let isUser = kind == "user" || name.lowercased() == "you" || name.lowercased() == "você"
        let speaker: ChatSpeaker = isUser
            ? .user
            : ChatSpeaker(key: name.lowercased(), displayName: ChatSpeaker.prettyName(name.isEmpty ? "Bot" : name))
        return ChatMessage(role: isUser ? .user : .assistant, text: text, speaker: speaker)
    }

    private func loadProfiles() async {
        guard let ws else { return }
        var result: JSONValue?
        for method in ["profiles.list", "profile.list"] {
            if let value = try? await ws.call(method: method, params: ["include_sessions": .bool(true)]) {
                result = value
                break
            }
        }
        if result == nil {
            for method in ["profiles.list", "profile.list"] {
                if let value = try? await ws.call(method: method, params: [:]) {
                    result = value
                    break
                }
            }
        }
        guard let result else { return }
        let rows = result["profiles"]?.arrayValue
            ?? result["items"]?.arrayValue
            ?? result.arrayValue
            ?? []
        var map: [String: AgentProfileInfo] = [:]
        for row in rows {
            guard let name = row["name"]?.stringValue ?? row["id"]?.stringValue, !name.isEmpty else { continue }
            let display = row["display_name"]?.stringValue
                ?? row["title"]?.stringValue
                ?? ChatSpeaker.prettyName(name)
            let meta = row["ui_meta"] ?? row["meta"]
            let last = row["last_session"]
            let canonical = row["canonical_session"]
            let botsMeta = meta?["hermes-bots"] ?? meta?["hermes-bots"]
            let info = AgentProfileInfo(
                name: name.lowercased(),
                displayName: botsMeta?["title"]?.stringValue ?? display,
                summary: row["description"]?.stringValue ?? row["summary"]?.stringValue,
                hasAvatar: row["has_avatar"]?.boolValue == true
                    || meta?["avatar"] != nil
                    || meta?["avatar_url"] != nil,
                accentHex: meta?["accent"]?.stringValue ?? meta?["color"]?.stringValue,
                isDefault: row["is_default"]?.boolValue == true,
                lastSessionID: last?["id"]?.stringValue ?? last?["resolved_id"]?.stringValue,
                canonicalSessionID: canonical?["resolved_id"]?.stringValue ?? canonical?["id"]?.stringValue,
                lastPreview: last?["preview"]?.stringValue ?? canonical?["preview"]?.stringValue
            )
            map[info.name] = info
            if let dataURL = meta?["avatar"]?.stringValue ?? meta?["avatar_data"]?.stringValue,
               let data = Self.data(fromDataURL: dataURL) {
                avatarDataByProfile[info.name] = data
            }
        }
        profilesByName = map
        groupRooms = parseGroupRooms(from: rows)
        if pinnedIDs.isEmpty {
            for room in groupRooms where room.name.lowercased().contains("vegapunk") {
                togglePin(room.id)
            }
        }
        for profile in map.values where profile.hasAvatar && avatarDataByProfile[profile.name] == nil {
            await fetchAvatar(for: profile.name)
        }
    }

    private func fetchAvatar(for profileName: String) async {
        guard let ws else { return }
        for method in ["profiles.get_asset", "profile.get_asset"] {
            guard let result = try? await ws.call(
                method: method,
                params: ["name": .string(profileName), "asset": .string("avatar")]
            ) else { continue }
            if result["found"]?.boolValue == false { return }
            if let url = result["data"]?.stringValue ?? result["data_url"]?.stringValue,
               let data = Self.data(fromDataURL: url) {
                avatarDataByProfile[profileName] = data
                return
            }
        }
    }

    private static func data(fromDataURL string: String) -> Data? {
        if let range = string.range(of: "base64,") {
            return Data(base64Encoded: String(string[range.upperBound...]))
        }
        return Data(base64Encoded: string)
    }

    private func rememberSessionLinks(_ event: HermesEvent) {
        let payload = event.payload
        let parent = payload["parent_session_id"]?.stringValue
            ?? payload["parent_id"]?.stringValue
        let child = payload["child_session_id"]?.stringValue
            ?? payload["subagent_session_id"]?.stringValue
        if let parent, chatIndex(for: parent) != nil {
            if !event.sessionID.isEmpty {
                childSessionParents[event.sessionID] = parent
            }
            if let child {
                childSessionParents[child] = parent
            }
        } else if let child, !event.sessionID.isEmpty {
            childSessionParents[child] = event.sessionID
        }
    }

    private func resolveTargetSession(_ event: HermesEvent) -> String {
        let sid = event.sessionID
        if let parent = event.payload["parent_session_id"]?.stringValue ?? event.payload["parent_id"]?.stringValue,
           chatIndex(for: parent) != nil {
            return parent
        }
        if chatIndex(for: sid) != nil { return sid }
        if let parent = childSessionParents[sid] { return parent }
        if shouldJoinActiveThread(event, sessionID: sid), let active = activeChatID {
            if !sid.isEmpty { childSessionParents[sid] = active }
            return active
        }
        return sid
    }

    private func shouldJoinActiveThread(_ event: HermesEvent, sessionID: String) -> Bool {
        if event.type.hasPrefix("subagent.")
            || event.type.hasPrefix("subagent.")
            || event.type.hasPrefix("background.")
            || event.type.hasPrefix("delegation.")
            || event.type.hasPrefix("delegate.") {
            return true
        }
        if event.payload["parent_session_id"] != nil
            || event.payload["child_session_id"] != nil
            || event.payload["subagent_id"] != nil {
            return true
        }
        if let key = ChatSpeaker.profileKey(fromSessionID: sessionID),
           key != "hermes",
           profilesByName[key] != nil {
            return true
        }
        return false
    }
}
