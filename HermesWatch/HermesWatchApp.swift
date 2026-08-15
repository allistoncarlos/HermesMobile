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
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        CompanionSync.shared.bind()
                    }
                }
        }
    }
}
