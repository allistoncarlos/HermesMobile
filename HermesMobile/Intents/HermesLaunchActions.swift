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

    private init() {}

    func requestStartVoice() {
        wantsStopVoice = false
        wantsVoiceSession = true
        NotificationCenter.default.post(name: .hermesStartVoice, object: nil)
    }

    func clearVoiceRequest() {
        wantsVoiceSession = false
    }

    func requestStopVoice() {
        wantsVoiceSession = false
        wantsStopVoice = true
        NotificationCenter.default.post(name: .hermesStopVoice, object: nil)
    }

    func clearStopRequest() {
        wantsStopVoice = false
    }
}
