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
                    if phase == .active {
                        CompanionSync.shared.push(from: viewModel)
                    }
                }
        }
    }
}
