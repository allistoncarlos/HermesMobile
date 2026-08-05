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
    func hasLiveSessionCookie() -> Bool {
        guard let cookies = urlSession.configuration.httpCookieStorage?.cookies(for: baseURL) else {
            return false
        }
        let names = Set(cookies.map(\.name))
        let at = ["hermes_session_at", "__Secure-hermes_session_at", "__Host-hermes_session_at"]
        let rt = ["hermes_session_rt", "__Secure-hermes_session_rt", "__Host-hermes_session_rt"]
        return at.contains(where: names.contains) || rt.contains(where: names.contains)
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
