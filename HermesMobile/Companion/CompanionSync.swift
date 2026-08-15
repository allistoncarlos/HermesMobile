import Foundation
import WatchConnectivity

// ============================================================================
//  CompanionSync — replica URL, token e cookies do iPhone para o Apple Watch
//  via WatchConnectivity (applicationContext).
// ============================================================================

struct CompanionConfigSnapshot: Codable, Equatable {
    var baseURLString: String
    var sessionToken: String
    var username: String
    var canRestore: Bool
    var cookiesJSON: Data?
}

@MainActor
final class CompanionSync: NSObject, ObservableObject {

    static let shared = CompanionSync()

    private static let contextKey = "hermes.config"
    private static let defaultsKey = "hermes.companionSnapshot"

    weak var viewModel: HermesViewModel?
    #if os(iOS)
    private var lastPushed: CompanionConfigSnapshot?
    private var pendingSnapshot: CompanionConfigSnapshot?
    #endif
    #if os(watchOS)
    private var lastApplied: CompanionConfigSnapshot?
    #endif
    private var didActivate = false

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        guard !didActivate else { return }
        didActivate = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func bind(_ viewModel: HermesViewModel) {
        self.viewModel = viewModel
        #if os(watchOS)
        if let stored = loadStoredSnapshot() {
            apply(stored, to: viewModel, reason: "stored")
        }
        let context = WCSession.isSupported() ? WCSession.default.receivedApplicationContext : [:]
        handle(context)
        #endif
    }

    #if os(iOS)
    func push(_ config: ServerConfig) {
        activate()
        pendingSnapshot = CompanionConfigSnapshot(
            baseURLString: config.baseURLString,
            sessionToken: config.sessionToken,
            username: config.username,
            canRestore: config.canRestoreSession,
            cookiesJSON: SessionCookieStore.exportData()
        )
        flush()
    }

    private func flush() {
        guard WCSession.isSupported() else { return }
        guard let snapshot = pendingSnapshot else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard snapshot != lastPushed else { return }
        lastPushed = snapshot
        send(snapshot)
    }

    private func send(_ snapshot: CompanionConfigSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }
        let payload: [String: Any] = [Self.contextKey: json]
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in }
        }
    }
    #endif

    // MARK: - Wire

    private func handle(_ context: [String: Any]) {
        guard let json = context[Self.contextKey] as? String,
              let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CompanionConfigSnapshot.self, from: data)
        else { return }

        persist(snapshot)
        #if os(watchOS)
        if let viewModel {
            apply(snapshot, to: viewModel, reason: "watch")
        } else {
            lastApplied = snapshot
        }
        #endif
    }

    private func persist(_ snapshot: CompanionConfigSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    #if os(watchOS)
    private func apply(_ snapshot: CompanionConfigSnapshot, to vm: HermesViewModel, reason: String) {
        _ = reason
        guard snapshot != lastApplied else { return }
        lastApplied = snapshot

        let previousURL = vm.config.baseURLString
        vm.config.baseURLString = snapshot.baseURLString
        vm.config.sessionToken = snapshot.sessionToken
        vm.config.username = snapshot.username
        vm.config.canRestoreSession = snapshot.canRestore

        if let cookies = snapshot.cookiesJSON {
            SessionCookieStore.importData(cookies)
            if let url = ServerConfig.normalizedURL(from: snapshot.baseURLString) {
                SessionCookieStore.restore(for: url)
            } else {
                SessionCookieStore.restore()
            }
        } else if snapshot.baseURLString.trimmingCharacters(in: .whitespaces).isEmpty {
            SessionCookieStore.clear()
        }

        let urlChanged = previousURL != snapshot.baseURLString
        let hasConfig = vm.config.hasSavedConfig

        if !hasConfig {
            vm.disconnect()
            return
        }

        switch vm.connectionState {
        case .connected where !urlChanged:
            break
        default:
            Task { await vm.connect() }
        }
    }
    #endif

    #if os(watchOS)
    private func loadStoredSnapshot() -> CompanionConfigSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CompanionConfigSnapshot.self, from: data)
    }
    #endif
}

extension CompanionSync: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            #if os(iOS)
            self.flush()
            #else
            self.handle(session.receivedApplicationContext)
            #endif
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.handle(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.handle(message) }
    }
}
