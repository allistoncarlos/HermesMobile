import Foundation
import WatchKit

// ============================================================================
//  WatchRuntimeSession — mantém a conversa viva com o braço abaixado
//  (tela apagada), em vez de encerrar no onDisappear.
// ============================================================================

@MainActor
final class WatchRuntimeSession: NSObject, WKExtendedRuntimeSessionDelegate {
    static let shared = WatchRuntimeSession()

    private var session: WKExtendedRuntimeSession?
    private var wantsRunning = false

    private override init() {
        super.init()
    }

    func startIfNeeded() {
        wantsRunning = true
        if let session, session.state == .running || session.state == .scheduled {
            return
        }
        let next = WKExtendedRuntimeSession()
        next.delegate = self
        session = next
        next.start()
        try? HermesAudioSession.activatePlayAndRecord()
    }

    func stop() {
        wantsRunning = false
        session?.invalidate()
        session = nil
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            // Renova se a conversa ainda estiver ativa.
            guard self.wantsRunning else { return }
            self.session = nil
            self.startIfNeeded()
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        Task { @MainActor in
            if self.session === extendedRuntimeSession {
                self.session = nil
            }
            guard self.wantsRunning else { return }
            // Erro transitório / expiração — tenta de novo se ainda estamos em sessão de voz.
            if reason != .none {
                self.startIfNeeded()
            }
        }
    }
}
