import AppIntents
import Foundation

// ============================================================================
//  StartHermesVoiceIntent — “Hey Siri, Hermes” / “Falar com o Hermes”.
//  Abre o app e pede modo de voz com sessão nova.
// ============================================================================

struct StartHermesVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Falar com o Hermes"
    static var description = IntentDescription(
        "Abre o Hermes com uma nova sessão e o modo de voz ativo."
    )
    /// Traz o app à frente (iPhone ou Watch, conforme onde a Siri rodou).
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        HermesLaunchActions.shared.requestStartVoice()
        return .result()
    }
}

struct HermesShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartHermesVoiceIntent(),
            phrases: [
                "\(.applicationName)",
                "Falar com \(.applicationName)",
                "Abrir \(.applicationName)",
                "Ouvir \(.applicationName)",
                "Modo voz do \(.applicationName)",
                "Conversar com \(.applicationName)",
                "Falar com o \(.applicationName)",
                "Abrir o \(.applicationName)",
                "Ouvir o \(.applicationName)",
            ],
            shortTitle: "Falar com Hermes",
            systemImageName: "waveform.circle.fill"
        )
    }
}
