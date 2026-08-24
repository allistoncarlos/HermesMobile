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

    @Parameter(title: "Perfil")
    var profileName: String?

    init() {
        self.profileName = nil
    }

    init(profileName: String?) {
        self.profileName = profileName
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        HermesLaunchActions.shared.requestStartVoice(profile: profileName)
        return .result(dialog: "Abrindo o Hermes em modo de voz.")
    }
}

/// Marca o intent como gravação de áudio (indicador + prioridade em background).
#if !WIDGET_EXTENSION
extension StartHermesVoiceIntent: AudioRecordingIntent {}
#endif

/// Toque num slot da complication: abre o Watch já em fala ativa naquele perfil.
struct OpenHermesVoiceProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Falar com um perfil do Hermes"
    static var description = IntentDescription(
        "Abre o Hermes no Apple Watch com a fala ativa no perfil escolhido."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Perfil")
    var profileName: String

    init() {
        self.profileName = "default"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Falar com \(\.$profileName)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        HermesLaunchActions.shared.requestStartVoice(profile: profileName)
        return .result()
    }
}

#if os(watchOS) && !WIDGET_EXTENSION
extension OpenHermesVoiceProfileIntent: AudioRecordingIntent {}
#endif

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

#if !WIDGET_EXTENSION
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
#endif
