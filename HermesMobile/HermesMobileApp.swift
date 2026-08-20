import SwiftUI

@main
struct HermesMobileApp: App {
    @StateObject private var viewModel: HermesViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let config = ServerConfig()
        let vm = HermesViewModel(config: config)
        _viewModel = StateObject(wrappedValue: vm)
        CompanionSync.shared.activate()
        CompanionSync.shared.bind(vm)
        CompanionSync.shared.push(from: vm)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onChange(of: scenePhase) { _, phase in
                    #if os(iOS)
                    BackgroundRuntime.shared.handleScenePhase(phase)
                    if phase == .background || phase == .inactive {
                        HermesAudioSession.reassertIfNeeded()
                    }
                    let foreground = (phase == .active)
                    viewModel.isAppForeground = foreground
                    HermesNotifier.shared.setForeground(foreground)
                    HermesNotifier.shared.activeChatID = viewModel.activeChatID
                    if phase == .background || phase == .inactive {
                        viewModel.ensureBackgroundHoldForActiveTurns()
                    }
                    if phase == .active {
                        CompanionSync.shared.push(from: viewModel)
                        HermesAudioSession.reassertIfNeeded()
                    }
                    #endif
                }
                .onChange(of: viewModel.activeChatID) { _, id in
                    #if os(iOS)
                    HermesNotifier.shared.activeChatID = id
                    #endif
                }
        }
    }
}
