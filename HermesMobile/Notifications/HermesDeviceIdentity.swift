import Foundation
import UIKit

// ============================================================================
//  HermesDeviceIdentity — deviceId estável (Fase 2: registro APNs /api/devices).
// ============================================================================

enum HermesDeviceIdentity {

    private static let keychainKey = "hermes.deviceId"
    private static let nameKey = "hermes.deviceName"

    /// UUID persistente deste instalação do app.
    static var deviceId: String {
        if let existing = KeychainHelper.read(key: keychainKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        KeychainHelper.save(token: id, forKey: keychainKey)
        return id
    }

    /// Nome amigável do dispositivo. Desde o iOS 16 `UIDevice.name` devolve só "iPhone"/"iPad"
    /// (sem o entitlement da Apple), então o nome genérico ganha um sufixo curto do deviceId
    /// para dispositivos diferentes não colidirem. O usuário pode renomear (`setDeviceName`).
    static var deviceName: String {
        if let saved = UserDefaults.standard.string(forKey: nameKey), !saved.isEmpty {
            return saved
        }
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = ["", "iphone", "ipad", "ipod touch", "ipod"]
        if generic.contains(name.lowercased()) {
            let base = name.isEmpty ? "iOS" : name
            return "\(base)-\(String(deviceId.replacingOccurrences(of: "-", with: "").prefix(4)).lowercased())"
        }
        return name
    }

    /// Renomeia (vazio = volta ao padrão).
    static func setDeviceName(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: nameKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: nameKey)
        }
    }

    /// `source` enviado ao servidor em `session.create` / `session.resume`:
    /// `ios.<nome-do-dispositivo>` (ex.: `ios.iPhone-de-Alliston`). O servidor grava o
    /// valor como veio, então cada aparelho fica identificável (Android virá como `android.<nome>`).
    static var sourceTag: String {
        "\(platform).\(sanitizedName(deviceName))"
    }

    /// Espaços viram `-`; mantém letras, números, `-`, `_` e `.`; remove o resto.
    static func sanitizedName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var out = ""
        for scalar in raw.unicodeScalars {
            if scalar == " " { out.append("-") }
            else if allowed.contains(scalar) { out.unicodeScalars.append(scalar) }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return out.isEmpty ? "device" : out
    }

    static var platform: String { "ios" }
}
