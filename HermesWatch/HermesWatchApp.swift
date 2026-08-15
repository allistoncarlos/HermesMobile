import SwiftUI

@main
struct HermesWatchApp: App {
    @StateObject private var viewModel: HermesViewModel
    @StateObject private var voice = VoiceModeController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CompanionSync.shared.activate()
        let config = ServerConfig()
        let vm = HermesViewModel(config: config)
        _viewModel = StateObject(wrappedValue: vm)
        CompanionSync.shared.bind(vm)
    }

    var body: some Scene {
        WindowGroup {
            WatchVoiceView(voice: voice)
                .environmentObject(viewModel)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        CompanionSync.shared.bind(viewModel)
                    }
                }
        }
    }
}
