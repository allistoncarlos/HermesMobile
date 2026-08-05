import Foundation

// ============================================================================
//  Camada HTTP — status, login cookie-based e mint de ticket WebSocket.
// ============================================================================

struct HermesClientError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class HermesClient {

    let baseURL: URL
    /// Token legado opcional (X-Hermes-Session-Token) para loopback / --insecure.
    let sessionToken: String?
    /// Sessão HTTP com cookie jar compartilhado (auth gated).
    let urlSession: URLSession

    private let sessionHeader = "X-Hermes-Session-Token"

    var sendToken: Bool { !(sessionToken?.isEmpty ?? true) }

    init(baseURL: URL, sessionToken: String? = nil, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.urlSession = urlSession
    }

    // MARK: - URL helpers

    private func endpoint(_ path: String) throws -> URL {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HermesClientError(message: "URL base inválida.")
        }
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        comps.path = normalized
        comps.query = nil
        comps.fragment = nil
        guard let url = comps.url else {
            throw HermesClientError(message: "Não foi possível montar \(path).")
        }
        return url
    }

    private func applyAuthHeaders(to request: inout URLRequest) {
        if sendToken, let token = sessionToken {
            request.setValue(token, forHTTPHeaderField: sessionHeader)
        }
    }

    // MARK: - Status / health

    func fetchStatus() async throws -> HermesStatus {
        var request = URLRequest(url: try endpoint("/api/status"))
        request.timeoutInterval = 12
        applyAuthHeaders(to: &request)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError(message: "Resposta inválida do servidor.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HermesClientError(message: "Erro HTTP \(http.statusCode) ao consultar o servidor.")
        }
        return try JSONDecoder().decode(HermesStatus.self, from: data)
    }

    func fetchAuthProviders() async throws -> [AuthProviderInfo] {
        var request = URLRequest(url: try endpoint("/api/auth/providers"))
        request.timeoutInterval = 12
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let decoded = try JSONDecoder().decode(AuthProvidersResponse.self, from: data)
        return decoded.providers
    }

    func isReachable() async -> Bool {
        guard let url = try? endpoint("/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (_, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return false
        }
        return true
    }

    // MARK: - Auth (cookie)

    /// Login usuário/senha. Persiste cookies no jar da `urlSession`.
    @discardableResult
    func login(username: String, password: String, provider: String = "basic") async throws -> PasswordLoginResponse {
        var request = URLRequest(url: try endpoint("/auth/password-login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "provider": provider,
            "username": username,
            "password": password,
            "next": "",
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError(message: "Resposta inválida no login.")
        }
        switch http.statusCode {
        case 200..<300:
            if data.isEmpty {
                return PasswordLoginResponse(next: "/")
            }
            return (try? JSONDecoder().decode(PasswordLoginResponse.self, from: data))
                ?? PasswordLoginResponse(next: "/")
        case 401:
            throw HermesClientError(message: "Usuário ou senha inválidos.")
        case 429:
            throw HermesClientError(message: "Muitas tentativas. Aguarde um momento e tente de novo.")
        default:
            throw HermesClientError(message: "Falha no login (HTTP \(http.statusCode)).")
        }
    }

    /// Verifica se já existe sessão cookie válida (AT ou RT).
    /// Checa `cookies(for:)` e, como fallback, o jar inteiro filtrado pelo host —
    /// `cookies(for:)` às vezes falha com diferenças de path/trailing slash.
    func hasLiveSessionCookie() -> Bool {
        let sessionNames: Set<String> = [
            "hermes_session_at", "__Secure-hermes_session_at", "__Host-hermes_session_at",
            "hermes_session_rt", "__Secure-hermes_session_rt", "__Host-hermes_session_rt",
        ]
        let storage = urlSession.configuration.httpCookieStorage
        if let cookies = storage?.cookies(for: baseURL),
           cookies.contains(where: { sessionNames.contains($0.name) }) {
            return true
        }
        // Fallback sem path trailing: tenta a URL sem barra final.
        if var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
            while comps.path.hasSuffix("/") { comps.path.removeLast() }
            if comps.path.isEmpty { comps.path = "/" }
            if let alt = comps.url,
               let cookies = storage?.cookies(for: alt),
               cookies.contains(where: { sessionNames.contains($0.name) }) {
                return true
            }
        }
        guard let host = baseURL.host?.lowercased(), let all = storage?.cookies else {
            return false
        }
        return all.contains { cookie in
            sessionNames.contains(cookie.name)
            && cookie.domain.lowercased().hasSuffix(host.trimmingPrefix("."))
        }
    }

    /// Mint de ticket single-use para upgrade WebSocket em modo gated.
    func mintWsTicket() async throws -> String {
        var request = URLRequest(url: try endpoint("/api/auth/ws-ticket"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        applyAuthHeaders(to: &request)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError(message: "Resposta inválida ao pedir ticket WS.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw HermesClientError(message: "Sessão expirada. Faça login novamente.")
            }
            throw HermesClientError(message: "Não foi possível obter ticket WS (HTTP \(http.statusCode)).")
        }
        let decoded = try JSONDecoder().decode(WSTicketResponse.self, from: data)
        guard !decoded.ticket.isEmpty else {
            throw HermesClientError(message: "Ticket WS vazio.")
        }
        return decoded.ticket
    }

    func logout() async {
        guard let url = try? endpoint("/auth/logout") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        _ = try? await urlSession.data(for: request)
        clearCookies()
    }

    func clearCookies() {
        guard let storage = urlSession.configuration.httpCookieStorage else { return }
        for cookie in storage.cookies(for: baseURL) ?? [] {
            storage.deleteCookie(cookie)
        }
        // Também limpa variantes globais do jar se existirem.
        if let all = storage.cookies {
            for cookie in all where cookie.domain.contains(baseURL.host ?? "") {
                storage.deleteCookie(cookie)
            }
        }
    }

    // MARK: - Áudio nativo (Hermes 0.20+)

    /// STT via `POST /api/audio/transcribe` (mesmo endpoint do desktop).
    /// Retorna transcript vazio quando não há fala (silêncio) — não é erro.
    func transcribeAudio(dataURL: String, mimeType: String) async throws -> String {
        var request = URLRequest(url: try endpoint("/api/audio/transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request)
        let body: [String: String] = [
            "data_url": dataURL,
            "mime_type": mimeType,
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError(message: "Resposta inválida na transcrição.")
        }
        if !(200..<300).contains(http.statusCode) {
            let detail = Self.errorDetail(from: data) ?? "HTTP \(http.statusCode)"
            throw HermesClientError(message: "Transcrição falhou: \(detail)")
        }
        let decoded = try JSONDecoder().decode(AudioTranscriptionResponse.self, from: data)
        return decoded.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// URL autenticada para `wss?…/api/audio/speak-stream` (ticket ou token).
    func makeSpeakStreamURL(usesCookieAuth: Bool, legacyToken: String?) async throws -> URL {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HermesClientError(message: "URL base inválida.")
        }
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/api/audio/speak-stream"
        comps.fragment = nil

        if usesCookieAuth {
            let ticket = try await mintWsTicket()
            comps.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        } else if let tok = legacyToken?.trimmingCharacters(in: .whitespacesAndNewlines), !tok.isEmpty {
            comps.queryItems = [URLQueryItem(name: "token", value: tok)]
        } else {
            comps.queryItems = nil
        }

        guard let url = comps.url else {
            throw HermesClientError(message: "URL do speak-stream inválida.")
        }
        return url
    }

    /// TTS via `POST /api/audio/speak` — áudio gerado pelo provider configurado no servidor (Edge, etc.).
    func speakText(_ text: String) async throws -> SpokenAudio {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HermesClientError(message: "Texto vazio para TTS.")
        }
        var request = URLRequest(url: try endpoint("/api/audio/speak"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(["text": trimmed])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError(message: "Resposta inválida no TTS.")
        }
        if !(200..<300).contains(http.statusCode) {
            let detail = Self.errorDetail(from: data) ?? "HTTP \(http.statusCode)"
            throw HermesClientError(message: "TTS falhou: \(detail)")
        }
        let decoded = try JSONDecoder().decode(AudioSpeakResponse.self, from: data)
        guard let audio = Self.decodeDataURL(decoded.dataURL) else {
            throw HermesClientError(message: "Áudio TTS inválido.")
        }
        return SpokenAudio(data: audio, mimeType: decoded.mimeType ?? "audio/mpeg", provider: decoded.provider)
    }

    private static func errorDetail(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let detail = obj["detail"] as? String { return detail }
        if let msg = obj["message"] as? String { return msg }
        if let err = obj["error"] as? String { return err }
        return nil
    }

    /// Decodifica `data:audio/mpeg;base64,…` → bytes.
    static func decodeDataURL(_ dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let encoded = String(dataURL[dataURL.index(after: comma)...])
        return Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters])
    }
}

/// Resposta de `POST /api/audio/transcribe`.
struct AudioTranscriptionResponse: Decodable {
    let ok: Bool?
    let transcript: String
    let provider: String?

    enum CodingKeys: String, CodingKey {
        case ok, transcript, provider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
    }
}

/// Resposta de `POST /api/audio/speak`.
struct AudioSpeakResponse: Decodable {
    let ok: Bool?
    let dataURL: String
    let mimeType: String?
    let provider: String?

    enum CodingKeys: String, CodingKey {
        case ok, provider
        case dataURL = "data_url"
        case mimeType = "mime_type"
    }
}

struct SpokenAudio {
    let data: Data
    let mimeType: String
    let provider: String?
}

// MARK: - Shared cookie-aware session factory

enum HermesHTTPSession {
    /// URLSession com cookie storage persistente, compartilhada pelo app.
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
}
