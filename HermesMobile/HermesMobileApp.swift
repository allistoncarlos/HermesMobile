import SwiftUI

@main
struct HermesMobileApp: App {
    @StateObject private var viewModel: HermesViewModel

    init() {
        let config = ServerConfig()
        _viewModel = StateObject(wrappedValue: HermesViewModel(config: config))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
