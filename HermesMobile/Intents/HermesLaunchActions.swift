import Foundation

// ============================================================================
//  HermesLaunchActions — pedidos pendentes de Siri / App Intent / lock screen.
// ============================================================================

extension Notification.Name {
    static let hermesStartVoice = Notification.Name("hermes.startVoice")
    static let hermesStopVoice = Notification.Name("hermes.stopVoice")
}

@MainActor
final class HermesLaunchActions {
    static let shared = HermesLaunchActions()

    /// True até a UI consumir (abrir modo voz).
    private(set) var wantsVoiceSession = false
    /// True até a UI consumir (encerrar modo voz).
    private(set) var wantsStopVoice = false
    /// Perfil/bot pedido pela complication, Siri ou atalho (`default`, `atlas`…).
    private(set) var voiceProfileName: String?

    private init() {}

    func requestStartVoice(profile: String? = nil) {
        wantsStopVoice = false
        wantsVoiceSession = true
        let trimmed = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        voiceProfileName = trimmed.isEmpty ? nil : trimmed.lowercased()
        WatchComplicationStore.setPendingVoiceProfile(voiceProfileName)
        NotificationCenter.default.post(name: .hermesStartVoice, object: voiceProfileName)
    }

    func restorePendingVoiceIfNeeded() {
        guard !wantsVoiceSession else { return }
        guard let pending = WatchComplicationStore.pendingVoiceProfile(), !pending.isEmpty else { return }
        wantsStopVoice = false
        wantsVoiceSession = true
        voiceProfileName = pending
    }

    func consumeVoiceRequest() -> String? {
        let profile = voiceProfileName ?? WatchComplicationStore.consumePendingVoiceProfile()
        wantsVoiceSession = false
        voiceProfileName = nil
        WatchComplicationStore.setPendingVoiceProfile(nil)
        return profile
    }

    func clearVoiceRequest() {
        _ = consumeVoiceRequest()
    }

    func requestStopVoice() {
        wantsVoiceSession = false
        voiceProfileName = nil
        wantsStopVoice = true
        WatchComplicationStore.setPendingVoiceProfile(nil)
        NotificationCenter.default.post(name: .hermesStopVoice, object: nil)
    }

    func clearStopRequest() {
        wantsStopVoice = false
    }
}
