import Foundation

// ============================================================================
//  HermesLaunchActions — pedido pendente de “abrir em voz” (Siri / App Intent).
// ============================================================================

extension Notification.Name {
    static let hermesStartVoice = Notification.Name("hermes.startVoice")
}

@MainActor
final class HermesLaunchActions {
    static let shared = HermesLaunchActions()

    /// True até a UI consumir (abrir modo voz).
    private(set) var wantsVoiceSession = false

    private init() {}

    func requestStartVoice() {
        wantsVoiceSession = true
        NotificationCenter.default.post(name: .hermesStartVoice, object: nil)
    }

    func clearVoiceRequest() {
        wantsVoiceSession = false
    }
}
