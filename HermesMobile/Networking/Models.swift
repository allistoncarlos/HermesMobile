import Foundation

// ============================================================================
//  Modelos de dados do HermesMobile
//  Implementa o protocolo JSON-RPC/WebSocket do backend Hermes Agent
//  (mesmo protocolo usado pelo app desktop via /api/ws).
// ============================================================================

/// Um valor JSON preservado de forma tolerante. Decodifica qualquer payload
/// da API sem quebrar quando o servidor adiciona campos novos.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "valor JSON desconhecido")) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

/// Papel de uma mensagem exibida no chat.
enum ChatRole: String, Codable {
    case user
    case assistant
    case system
}

/// Quem falou na conversa (usuário, Hermes, ou um bot/perfil como Atlas).
struct ChatSpeaker: Equatable, Sendable {
    var key: String
    var displayName: String

    static let user = ChatSpeaker(key: "user", displayName: "Você")
    static let hermes = ChatSpeaker(key: "hermes", displayName: "Hermes")

    static func assistantFallback(profile: String?) -> ChatSpeaker {
        let trimmed = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.lowercased() == "default" {
            return .hermes
        }
        return ChatSpeaker(key: trimmed.lowercased(), displayName: Self.prettyName(trimmed))
    }

    static func prettyName(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return "Hermes" }
        return cleaned.split(separator: " ").map { part in
            guard let first = part.first else { return String(part) }
            return String(first).uppercased() + part.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Extrai o falante do payload do gateway / histórico.
    static func resolve(
        from payload: JSONValue?,
        sessionID: String = "",
        profiles: [String: AgentProfileInfo] = [:],
        fallback: ChatSpeaker = .hermes
    ) -> ChatSpeaker {
        let obj = payload?.objectValue ?? [:]
        let keyFields = [
            "profile", "profile_name", "profile_id",
            "agent", "agent_name", "agent_id",
            "speaker", "speaker_id", "speaker_name",
            "bot", "bot_name", "bot_id",
            "persona", "from_profile", "source_profile",
        ]
        var key: String?
        for field in keyFields {
            if let value = obj[field]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                key = value
                break
            }
        }
        if key == nil, let sidKey = profileKey(fromSessionID: sessionID) {
            key = sidKey
        }
        let nameFields = ["display_name", "speaker_name", "bot_name", "title", "label"]
        var name: String?
        for field in nameFields {
            if let value = obj[field]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                name = value
                break
            }
        }
        // `name` em subagent.* costuma ser a ferramenta; só usa se parecer um perfil.
        if name == nil, let raw = obj["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw.count <= 40, !raw.contains("."), !raw.contains("_task") {
            name = raw
            if key == nil { key = raw }
        }
        if let goal = obj["goal"]?.stringValue, key == nil || name == nil {
            if let inferred = inferBot(from: goal), key == nil { key = inferred }
        }
        guard let resolvedKey = key?.lowercased(), !resolvedKey.isEmpty else {
            return fallback
        }
        if resolvedKey == "user" { return .user }
        if ["assistant", "hermes", "default", "system"].contains(resolvedKey) {
            return profiles["default"].map {
                ChatSpeaker(key: $0.name, displayName: $0.displayName)
            } ?? fallback
        }
        if let profile = profiles[resolvedKey] {
            return ChatSpeaker(key: profile.name, displayName: name ?? profile.displayName)
        }
        return ChatSpeaker(key: resolvedKey, displayName: name ?? prettyName(resolvedKey))
    }

    static func profileKey(fromSessionID sid: String) -> String? {
        let first = sid.split(whereSeparator: { $0 == "/" || $0 == ":" }).first.map(String.init) ?? sid
        let cleaned = first
            .replacingOccurrences(of: "@session", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "@/ "))
        guard !cleaned.isEmpty,
              cleaned.lowercased() != "default",
              cleaned.count < 48,
              cleaned.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))) != nil
        else { return nil }
        if cleaned.contains("_") && cleaned.rangeOfCharacter(from: .decimalDigits) != nil && cleaned.count > 16 {
            return nil
        }
        return cleaned.lowercased()
    }

    static func inferBot(from text: String) -> String? {
        if let match = text.range(of: #"@([A-Za-z][A-Za-z0-9_-]{1,31})"#, options: .regularExpression) {
            let raw = String(text[match]).dropFirst()
            return String(raw).lowercased()
        }
        return nil
    }

    /// Prefixo típico do Bot Mode: `Message from 🤖 Atlas (@atlas): ...`
    static func strippingDeliveryPrefix(_ text: String) -> (speaker: ChatSpeaker?, body: String) {
        let pattern = #"^(?:Message from|Mensagem de)\s+(?:[^\n(]*\s+)?\(@?([A-Za-z0-9_-]+)\)\s*:\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let keyRange = Range(match.range(at: 1), in: text) else {
            return (nil, text)
        }
        let key = String(text[keyRange])
        let body = String(text[Range(match.range, in: text)!.upperBound...])
        return (ChatSpeaker(key: key.lowercased(), displayName: prettyName(key)), body)
    }
}

/// Perfil/bot conhecido no gateway (`profiles.list`).
struct AgentProfileInfo: Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var displayName: String
    var summary: String?
    var hasAvatar: Bool
    var accentHex: String?
    var isDefault: Bool = false
    var lastSessionID: String? = nil
    var canonicalSessionID: String? = nil
    var lastPreview: String? = nil
    /// Pin vindo do desktop (`ui_meta['hermes-bots'].pinned`).
    var isPinnedOnServer: Bool = false
}

/// Avatar em memória para um perfil.
struct ProfileAvatar: Equatable, Sendable {
    var imageData: Data
}

/// Uma chamada de ferramenta (tool) executada pelo agente durante o turno.
struct ToolCall: Identifiable, Equatable {
    let id: UUID
    var name: String
    var status: String   // "running" | "done" | "error"
    var summary: String?

    init(id: UUID = UUID(), name: String, status: String, summary: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.summary = summary
    }
}

/// Tipo de anexo no composer / bolha do usuário.
enum AttachmentKind: String, Equatable, Sendable {
    case image
    case file
}

/// Um arquivo ou imagem anexado à mensagem (estilo ChatGPT).
struct ChatAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: AttachmentKind
    var filename: String
    var mimeType: String
    /// Bytes brutos (enviados via `image.attach_bytes` / `file.attach`).
    /// Pode ficar vazio depois do upload — a bolha só precisa do preview.
    var data: Data
    /// Preview local compacto (imagens); nil para arquivos genéricos.
    var previewData: Data?

    init(
        id: UUID = UUID(),
        kind: AttachmentKind,
        filename: String,
        mimeType: String,
        data: Data,
        previewData: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.previewData = previewData
    }

    /// Igualdade barata: não compara bytes (evita travar o SwiftUI no streaming).
    static func == (lhs: ChatAttachment, rhs: ChatAttachment) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.filename == rhs.filename
            && lhs.mimeType == rhs.mimeType
            && lhs.data.count == rhs.data.count
            && lhs.previewData?.count == rhs.previewData?.count
    }

    var dataURL: String {
        let b64 = data.base64EncodedString()
        return "data:\(mimeType);base64,\(b64)"
    }

    var isPDF: Bool {
        mimeType == "application/pdf" || filename.lowercased().hasSuffix(".pdf")
    }

    var isVideo: Bool {
        mimeType.hasPrefix("video/")
    }

    /// Cópia só para UI: mantém thumbnail e descarta o payload pesado.
    func forDisplay() -> ChatAttachment {
        ChatAttachment(
            id: id,
            kind: kind,
            filename: filename,
            mimeType: mimeType,
            data: Data(),
            previewData: previewData
        )
    }
}

/// Uma bolha de mensagem no chat.
struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var role: ChatRole
    var text: String
    var attachments: [ChatAttachment]
    var reasoning: String?      // conteúdo do bloco de raciocínio (thinking)
    var tools: [ToolCall]
    var status: String?         // "streaming" | "complete" | "error"
    var isStreaming: Bool
    /// Identificador estável do falante (`atlas`, `hermes`, `user`…).
    var speakerKey: String
    /// Nome exibido acima da bolha (conversa em grupo).
    var speakerName: String

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        attachments: [ChatAttachment] = [],
        reasoning: String? = nil,
        tools: [ToolCall] = [],
        status: String? = nil,
        isStreaming: Bool = false,
        speaker: ChatSpeaker? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.reasoning = reasoning
        self.tools = tools
        self.status = status
        self.isStreaming = isStreaming
        let resolved = speaker ?? (role == .user ? .user : .hermes)
        self.speakerKey = resolved.key
        self.speakerName = resolved.displayName
    }

    var speaker: ChatSpeaker {
        ChatSpeaker(key: speakerKey, displayName: speakerName)
    }
}

/// Resumo de uma conversa existente na lista de sessões.
struct SessionSummary: Identifiable, Equatable {
    let id: String              // stored_session_id
    var title: String
    var startedAt: Date?
    var source: String?
    var isActive: Bool
    var preview: String? = nil
}

/// Tipo de conversa no drawer (sessão normal, grupo WhatsApp-like, DM de bot).
enum ChatKind: String, Equatable, Sendable {
    case direct
    case group
    case bot
}

/// Membro de um chat em grupo sincronizado do desktop.
struct GroupMember: Equatable, Identifiable, Sendable {
    var id: String { key }
    var key: String
    var displayName: String

    /// Handle usado em @menções (`@atlas`).
    var mentionHandle: String {
        let raw = key.lowercased().replacingOccurrences(of: " ", with: "")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(raw.unicodeScalars.filter { allowed.contains($0) })
    }
}

/// Chat em grupo (Vegapunk, etc.) espelhado do `ui_meta` do perfil default.
struct GroupRoom: Equatable, Identifiable, Sendable {
    var id: String { "group::\(name.lowercased())" }
    var name: String
    var members: [GroupMember]
    var messages: [ChatMessage]
    var preview: String?
    var lastActivity: Date?
    var imageDataURL: String?
    /// Pin vindo do snapshot do grupo no gateway, se existir.
    var isPinnedOnServer: Bool = false
}

struct DrawerPinItem: Identifiable {
    enum Kind { case group, bot, direct }
    let id: String
    var title: String
    var subtitle: String?
    var kind: Kind
    var room: GroupRoom?
    var bot: AgentProfileInfo?
    var session: SessionSummary?
}

/// Conversa aberta no cliente (pode haver várias ao mesmo tempo).
struct OpenChat: Identifiable, Equatable {
    let id: String              // session_id ao vivo
    var storedSessionID: String?
    var title: String
    var model: String?
    var messages: [ChatMessage]
    var isStreaming: Bool
    var toolStatusText: String?
    var pendingApproval: PendingApproval?
    var hasPendingClarify: Bool
    var pendingClarifyID: String?
    var lastAssistantIndex: Int?
    /// session_id de subagentes cujo transcript entra neste chat.
    var linkedSessionIDs: [String]
    var needsAttention: Bool    // badge quando outro chat pede ação / termina
    var kind: ChatKind
    var subtitle: String?
    var lastActivity: Date?
    /// Sessão gateway usada para envio quando `id` é sintético (`group::` / `bot::`).
    var backingSessionID: String?

    init(
        id: String,
        storedSessionID: String? = nil,
        title: String = "Nova conversa",
        model: String? = nil,
        messages: [ChatMessage] = [],
        isStreaming: Bool = false,
        toolStatusText: String? = nil,
        pendingApproval: PendingApproval? = nil,
        hasPendingClarify: Bool = false,
        pendingClarifyID: String? = nil,
        lastAssistantIndex: Int? = nil,
        linkedSessionIDs: [String] = [],
        needsAttention: Bool = false,
        kind: ChatKind = .direct,
        subtitle: String? = nil,
        lastActivity: Date? = nil,
        backingSessionID: String? = nil
    ) {
        self.id = id
        self.storedSessionID = storedSessionID
        self.title = title
        self.model = model
        self.messages = messages
        self.isStreaming = isStreaming
        self.toolStatusText = toolStatusText
        self.pendingApproval = pendingApproval
        self.hasPendingClarify = hasPendingClarify
        self.pendingClarifyID = pendingClarifyID
        self.lastAssistantIndex = lastAssistantIndex
        self.linkedSessionIDs = linkedSessionIDs
        self.needsAttention = needsAttention
        self.kind = kind
        self.subtitle = subtitle
        self.lastActivity = lastActivity
        self.backingSessionID = backingSessionID
    }
}

/// Resposta do POST /api/auth/ws-ticket.
struct WSTicketResponse: Decodable {
    let ticket: String
    let ttlSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case ticket
        case ttlSeconds = "ttl_seconds"
    }
}

/// Resposta do POST /auth/password-login.
struct PasswordLoginResponse: Decodable {
    let next: String?
}

/// Resposta do POST /auth/native/refresh (rotação AT/RT para apps nativos).
struct NativeRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: TimeInterval?
    let provider: String?
    let userId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case provider
        case userId = "user_id"
    }
}

/// Resposta de GET /api/auth/providers.
struct AuthProvidersResponse: Decodable {
    let providers: [AuthProviderInfo]
}

struct AuthProviderInfo: Decodable, Equatable {
    let name: String
    let displayName: String?
    let supportsPassword: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case supportsPassword = "supports_password"
    }
}

/// Resultado do GET /api/status — usado para detectar se o servidor exige auth.
struct HermesStatus: Decodable {
    let version: String?
    let authRequired: Bool?
    let authProviders: [String]?
    let authFlows: [String]?
    let profiles: [String]?
    let activeAgents: Int?

    enum CodingKeys: String, CodingKey {
        case version, profiles
        case authRequired = "auth_required"
        case authProviders = "auth_providers"
        case authFlows = "auth_flows"
        case activeAgents = "active_agents"
    }

    var usesCookieAuth: Bool {
        authRequired == true && (authFlows?.contains("cookie") == true || authProviders?.isEmpty == false)
    }
}

/// Uma aprovação pendente (o agente pediu permissão para executar/continuar).
struct PendingApproval: Equatable {
    var sessionID: String
    var message: String
    var requestID: String?
}

/// Estado geral da conexão com o servidor.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case waitingAuth
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let msg) = self { return msg }
        return nil
    }
}

struct HermesClientError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SpokenAudio {
    let data: Data
    let mimeType: String
    let provider: String?
}

// Helper: extrai um texto de um payload JSON.
extension JSONValue {
    func text(for key: String) -> String? {
        self[key]?.stringValue
    }
}
