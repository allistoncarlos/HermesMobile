import AppIntents
import Foundation

// ============================================================================
//  StartHermesVoiceIntent — “Hey Siri, Hermes” / “Falar com o Hermes”.
//  Abre o app e inicia o modo de voz (funciona a partir da tela bloqueada,
//  Action Button, Atalhos e Spotlight). AudioRecordingIntent sinaliza ao
//  sistema que o app vai gravar — útil com a tela bloqueada.
// ============================================================================

struct StartHermesVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Falar com o Hermes"
    static var description = IntentDescription(
        "Abre o Hermes com uma nova sessão e o modo de voz handsfree ativo."
    )
    /// Traz o app à frente (iPhone ou Watch, conforme onde a Siri rodou).
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        HermesLaunchActions.shared.requestStartVoice()
        return .result(dialog: "Abrindo o Hermes em modo de voz.")
    }
}

/// Marca o intent como gravação de áudio (indicador + prioridade em background).
extension StartHermesVoiceIntent: AudioRecordingIntent {}

struct StopHermesVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Parar o Hermes"
    static var description = IntentDescription(
        "Encerra o modo de voz handsfree do Hermes."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        HermesLaunchActions.shared.requestStopVoice()
        return .result(dialog: "Encerrando o modo de voz.")
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
                "Handsfree do \(.applicationName)",
                "Escutar o \(.applicationName)",
            ],
            shortTitle: "Falar com Hermes",
            systemImageName: "waveform.circle.fill"
        )
        AppShortcut(
            intent: StopHermesVoiceIntent(),
            phrases: [
                "Parar \(.applicationName)",
                "Parar o \(.applicationName)",
                "Encerrar \(.applicationName)",
                "Encerrar o \(.applicationName)",
                "Sair do \(.applicationName)",
            ],
            shortTitle: "Parar Hermes",
            systemImageName: "stop.circle.fill"
        )
    }
}
