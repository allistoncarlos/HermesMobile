import Foundation
import Security

// ============================================================================
//  ServerConfig — endereço do servidor Hermes e credenciais.
//  URL e username em UserDefaults; token legado no Keychain.
//  Cookies de sessão ficam no HTTPCookieStorage (via HermesHTTPSession).
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

    /// Sessão já estabelecida com sucesso neste dispositivo (para auto-reconnect).
    var canRestoreSession: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.canRestore) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.canRestore) }
    }

    private enum Keys {
        static let baseURL  = "hermes.serverBaseURL"
        static let token    = "hermes.sessionToken"
        static let username = "hermes.username"
        static let canRestore = "hermes.canRestoreSession"
    }

    init() {
        self.baseURLString = UserDefaults.standard.string(forKey: Keys.baseURL) ?? ""
        self.sessionToken  = KeychainHelper.read(key: Keys.token) ?? ""
        self.username      = UserDefaults.standard.string(forKey: Keys.username) ?? ""
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
    }
}

// ============================================================================
//  Pequeno helper de Keychain para guardar o token de forma segura.
// ============================================================================

enum KeychainHelper {

    static func save(token: String, forKey key: String) {
        guard !token.isEmpty else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
