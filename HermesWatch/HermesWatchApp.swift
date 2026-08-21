import SwiftUI

@main
struct HermesWatchApp: App {
    @StateObject private var voice = VoiceModeController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CompanionSync.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchVoiceView(voice: voice)
                .onAppear {
                    CompanionSync.shared.bind()
                    Task { await fulfillSiriVoiceLaunchIfNeeded() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        CompanionSync.shared.bind()
                        Task { await fulfillSiriVoiceLaunchIfNeeded() }
                    }
                    // Braço abaixado → inactive/background: só reforça áudio,
                    // não encerra a sessão de voz.
                    if phase == .inactive || phase == .background {
                        try? HermesAudioSession.activatePlayAndRecord()
                        if case .idle = voice.phase {
                            // nada
                        } else {
                            WatchRuntimeSession.shared.startIfNeeded()
                        }
                    }
                }
                .onChange(of: CompanionSync.shared.phoneConnection) { _, _ in
                    Task { await fulfillSiriVoiceLaunchIfNeeded() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .hermesStartVoice)) { _ in
                    Task { await fulfillSiriVoiceLaunchIfNeeded() }
                }
        }
    }

    /// Siri no Watch: pede sessão nova no iPhone e liga o microfone.
    @MainActor
    private func fulfillSiriVoiceLaunchIfNeeded() async {
        guard HermesLaunchActions.shared.wantsVoiceSession else { return }
        guard case .connected = CompanionSync.shared.phoneConnection else { return }
        HermesLaunchActions.shared.clearVoiceRequest()
        CompanionSync.shared.sendCommand(["cmd": "newSession"], expectReply: true)
        // Pequeno atraso para o iPhone criar a sessão antes do primeiro turno.
        try? await Task.sleep(nanoseconds: 400_000_000)
        await voice.startSession()
    }
}
