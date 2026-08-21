import Foundation
import Security

// ============================================================================
//  ServerConfig — endereço do servidor Hermes e credenciais.
//  URL e username em UserDefaults; token legado e cookies de sessão no Keychain.
//  O HTTPCookieStorage sozinho não sobrevive ao fechar o app (session cookie / IP Tailscale).
// ============================================================================

final class ServerConfig: ObservableObject {

    @Published var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: Keys.baseURL) }
    }

    /// Token legado (loopback / --insecure). Opcional.
    @Published var sessionToken: String {
        didSet { KeychainHelper.save(token: sessionToken, forKey: Keys.token) }
    }

    /// Último username usado no login (não guarda a senha).
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: Keys.username) }
    }

    /// Fala respostas do servidor automaticamente (chat + background), sem pedir de novo.
    var speakRepliesAutomatically: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.speakAuto) == nil { return true }
            return UserDefaults.standard.bool(forKey: Keys.speakAuto)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.speakAuto) }
    }

    /// Sessão já estabelecida com sucesso neste dispositivo (para auto-reconnect).
    var canRestoreSession: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.canRestore) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.canRestore) }
    }

    private enum Keys {
        static let baseURL  = "hermes.serverBaseURL"
        static let token    = "hermes.sessionToken"
        static let username = "hermes.username"
        /// Legado — senha não é mais persistida; só limpa o Keychain.
        static let password = "hermes.dashboardPassword"
        static let canRestore = "hermes.canRestoreSession"
        static let speakAuto = "hermes.speakRepliesAutomatically"
    }

    init() {
        self.baseURLString = UserDefaults.standard.string(forKey: Keys.baseURL) ?? ""
        self.sessionToken  = KeychainHelper.read(key: Keys.token) ?? ""
        self.username      = UserDefaults.standard.string(forKey: Keys.username) ?? ""
        // Migração: remove senha que versões anteriores guardavam no Keychain.
        KeychainHelper.save(token: "", forKey: Keys.password)
        // Recoloca cookies de sessão (AT/RT) no jar HTTP antes de qualquer request.
        if let url = Self.normalizedURL(from: baseURLString) {
            SessionCookieStore.restore(for: url)
        } else {
            SessionCookieStore.restore()
        }
    }

    /// Normaliza a entrada: garante scheme e path trailing "/".
    static func normalizedURL(from string: String) -> URL? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        guard var url = URL(string: s) else { return nil }
        if url.absoluteString.hasSuffix("/") == false {
            // appendingPathComponent("") adiciona "/" sem percent-encoding indevido.
            if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                if !comps.path.hasSuffix("/") {
                    comps.path += "/"
                }
                url = comps.url ?? url
            }
        }
        return url
    }

    var hasSavedConfig: Bool {
        !baseURLString.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func clear() {
        baseURLString = ""
        sessionToken = ""
        username = ""
        canRestoreSession = false
        KeychainHelper.save(token: "", forKey: Keys.password)
        SessionCookieStore.clear()
    }

    /// Credenciais locais suficientes para reentrar sem pedir senha (cookies AT/RT ou token legado).
    var hasRestorableAuth: Bool {
        canRestoreSession
            || SessionCookieStore.hasPersistedCookies
            || !sessionToken.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// ============================================================================
//  Pequeno helper de Keychain para guardar o token de forma segura.
// ============================================================================

enum KeychainHelper {

    static func save(token: String, forKey key: String) {
        save(data: token.isEmpty ? nil : Data(token.utf8), forKey: key)
    }

    static func save(data: Data?, forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let data, !data.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func readData(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func read(key: String) -> String? {
        guard let data = readData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// ============================================================================
//  SessionCookieStore — persiste cookies Hermes (AT/RT) no Keychain.
//  O HTTPCookieStorage do iOS descarta session cookies e, em hosts IP
//  (Tailscale), frequentemente não grava o jar em disco ao matar o app.
// ============================================================================

enum SessionCookieStore {

    private static let keychainKey = "hermes.sessionCookies"
    /// Fallback local quando o cookie vem sem Expires/Max-Age.
    private static let localFallbackTTL: TimeInterval = 30 * 24 * 60 * 60

    static let sessionNames: Set<String> = [
        "hermes_session_at", "__Secure-hermes_session_at", "__Host-hermes_session_at",
        "hermes_session_rt", "__Secure-hermes_session_rt", "__Host-hermes_session_rt",
        "hermes_session_provider", "__Secure-hermes_session_provider", "__Host-hermes_session_provider",
    ]

    private static let accessTokenNames: Set<String> = [
        "hermes_session_at", "__Secure-hermes_session_at", "__Host-hermes_session_at",
    ]
    private static let refreshTokenNames: Set<String> = [
        "hermes_session_rt", "__Secure-hermes_session_rt", "__Host-hermes_session_rt",
    ]
    private static let providerNames: Set<String> = [
        "hermes_session_provider", "__Secure-hermes_session_provider", "__Host-hermes_session_provider",
    ]

    private struct Record: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: TimeInterval?
        var secure: Bool
        var httpOnly: Bool
    }

    static var hasPersistedCookies: Bool {
        load().contains { !$0.value.isEmpty && !isExpired($0) }
    }

    static var hasPersistedRefreshToken: Bool {
        load().contains {
            refreshTokenNames.contains($0.name) && !$0.value.isEmpty && !isExpired($0)
        }
    }

    /// Valor atual do refresh token (cookie ou Keychain).
    static func refreshTokenValue() -> String? {
        let live = load().first {
            refreshTokenNames.contains($0.name) && !$0.value.isEmpty && !isExpired($0)
        }
        return live?.value
    }

    static func providerHint() -> String? {
        load().first {
            providerNames.contains($0.name) && !$0.value.isEmpty && !isExpired($0)
        }?.value
    }

    /// Grava AT/RT devolvidos por `POST /auth/native/refresh` no jar + Keychain.
    static func applyNativeTokens(
        accessToken: String,
        refreshToken: String,
        expiresAt: TimeInterval?,
        provider: String?,
        into storage: HTTPCookieStorage? = HTTPCookieStorage.shared,
        for url: URL
    ) {
        guard let storage else { return }
        let host = url.host ?? ""
        let path = "/"
        let atExpires = expiresAt ?? Date().addingTimeInterval(12 * 60 * 60).timeIntervalSince1970
        let rtExpires = Date().addingTimeInterval(localFallbackTTL).timeIntervalSince1970
        let secure = url.scheme?.lowercased() == "https"

        func setCookie(name: String, value: String, expires: TimeInterval) {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .path: path,
                .originURL: url,
                .expires: Date(timeIntervalSince1970: expires),
                .maximumAge: String(max(0, Int(expires - Date().timeIntervalSince1970))),
            ]
            if !host.isEmpty { props[.domain] = host }
            if secure { props[.secure] = "TRUE" }
            props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            if let cookie = HTTPCookie(properties: props) {
                storage.setCookie(cookie)
            }
        }

        // Remove variantes antigas do mesmo host antes de gravar bare names.
        for cookie in storage.cookies ?? [] {
            let isOurs = accessTokenNames.contains(cookie.name)
                || refreshTokenNames.contains(cookie.name)
                || providerNames.contains(cookie.name)
            if isOurs, hostMatches(cookie.domain, host: host.lowercased()) {
                storage.deleteCookie(cookie)
            }
        }

        setCookie(name: "hermes_session_at", value: accessToken, expires: atExpires)
        if !refreshToken.isEmpty {
            setCookie(name: "hermes_session_rt", value: refreshToken, expires: rtExpires)
        }
        if let provider, !provider.isEmpty {
            setCookie(name: "hermes_session_provider", value: provider, expires: rtExpires)
        }
        persist(from: storage, host: host)
    }

    /// Snapshot JSON para sincronizar a sessão com o Apple Watch.
    static func exportData() -> Data? {
        let live = load().filter { !$0.value.isEmpty && !isExpired($0) }
        guard !live.isEmpty else { return nil }
        return try? JSONEncoder().encode(live)
    }

    static func importData(_ data: Data) {
        guard let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        let live = records.filter { !$0.value.isEmpty && !isExpired($0) }
        live.isEmpty ? KeychainHelper.save(data: nil, forKey: keychainKey) : save(live)
    }

    static func persist(from storage: HTTPCookieStorage? = HTTPCookieStorage.shared, host: String? = nil) {
        let wantedHost = normalizedHost(host)
        let cookies = (storage?.cookies ?? []).filter { cookie in
            guard sessionNames.contains(cookie.name), !cookie.value.isEmpty else { return false }
            guard let wantedHost else { return true }
            return hostMatches(cookie.domain, host: wantedHost)
        }
        guard !cookies.isEmpty else { return }
        let records = cookies.map { cookie in
            Record(
                name: cookie.name,
                value: cookie.value,
                domain: cookie.domain,
                path: cookie.path.isEmpty ? "/" : cookie.path,
                expires: cookie.expiresDate?.timeIntervalSince1970
                    ?? Date().addingTimeInterval(localFallbackTTL).timeIntervalSince1970,
                secure: cookie.isSecure,
                httpOnly: cookie.isHTTPOnly
            )
        }
        save(records)
    }

    static func restore(into storage: HTTPCookieStorage? = HTTPCookieStorage.shared, for url: URL? = nil) {
        guard let storage else { return }
        let records = load()
        let live = records.filter { !$0.value.isEmpty && !isExpired($0) }
        for record in live {
            guard let cookie = makeCookie(record, for: url) else { continue }
            storage.setCookie(cookie)
        }
        if live.count != records.count {
            live.isEmpty ? KeychainHelper.save(data: nil, forKey: keychainKey) : save(live)
        }
    }

    static func clear(from storage: HTTPCookieStorage? = HTTPCookieStorage.shared, host: String? = nil) {
        if let storage {
            let wantedHost = normalizedHost(host)
            for cookie in storage.cookies ?? [] {
                let isSession = sessionNames.contains(cookie.name)
                let matchesHost = wantedHost.map { hostMatches(cookie.domain, host: $0) } ?? true
                if isSession && matchesHost {
                    storage.deleteCookie(cookie)
                }
            }
        }
        KeychainHelper.save(data: nil, forKey: keychainKey)
    }

    static func clear() {
        clear(from: HTTPCookieStorage.shared, host: nil)
    }

    static func hostMatches(_ cookieDomain: String, host: String) -> Bool {
        let domain = normalizedHost(cookieDomain) ?? ""
        if domain.isEmpty { return true }
        return domain == host
            || host.hasSuffix("." + domain)
            || domain.hasSuffix("." + host)
    }


    private static func load() -> [Record] {
        guard let data = KeychainHelper.readData(key: keychainKey) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func save(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        KeychainHelper.save(data: data, forKey: keychainKey)
    }

    private static func isExpired(_ record: Record) -> Bool {
        guard let expires = record.expires else { return false }
        return expires <= Date().timeIntervalSince1970
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let trimmed = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func makeCookie(_ record: Record, for url: URL?) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: record.name,
            .value: record.value,
            .path: record.path.isEmpty ? "/" : record.path,
        ]
        if let url {
            props[.originURL] = url
        } else if !record.domain.isEmpty {
            props[.domain] = record.domain
        }
        if let expires = record.expires {
            props[.expires] = Date(timeIntervalSince1970: expires)
            props[.maximumAge] = String(max(0, Int(expires - Date().timeIntervalSince1970)))
        }
        // Cookie Secure em URL http:// (Tailscale) não é enviado pelo URLSession.
        if record.secure, (url?.scheme?.lowercased() == "https" || url == nil) {
            props[.secure] = "TRUE"
        }
        if record.httpOnly {
            props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        return HTTPCookie(properties: props)
    }
}
