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

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        attachments: [ChatAttachment] = [],
        reasoning: String? = nil,
        tools: [ToolCall] = [],
        status: String? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.reasoning = reasoning
        self.tools = tools
        self.status = status
        self.isStreaming = isStreaming
    }
}

/// Resumo de uma conversa existente na lista de sessões.
struct SessionSummary: Identifiable, Equatable {
    let id: String              // stored_session_id
    var title: String
    var startedAt: Date?
    var source: String?
    var isActive: Bool
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
    var needsAttention: Bool    // badge quando outro chat pede ação / termina

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
        needsAttention: Bool = false
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
        self.needsAttention = needsAttention
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
