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

    /// Nome amigável (UIDevice / fallback).
    static var deviceName: String {
        if let saved = UserDefaults.standard.string(forKey: nameKey), !saved.isEmpty {
            return saved
        }
        let name = UIDevice.current.name
        let label = name.isEmpty ? "iPhone" : name
        UserDefaults.standard.set(label, forKey: nameKey)
        return label
    }

    static var platform: String { "ios" }
}
