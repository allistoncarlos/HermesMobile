import AVFoundation
import Foundation

#if os(iOS)
import MediaPlayer
import SwiftUI
import UIKit

// ============================================================================
//  BackgroundRuntime — mantém o app vivo o bastante para o Hermes falar
//  (e receber o fim do turno) com a tela bloqueada ou em outro app.
// ============================================================================

@MainActor
final class BackgroundRuntime {
    static let shared = BackgroundRuntime()

    private var task = UIBackgroundTaskIdentifier.invalid
    private var holders = 0
    private var nowPlayingActive = false

    private init() {}

    /// Incrementa o “hold” de background (voz ativa, TTS, turno em processamento).
    func retain(reason: String) {
        holders += 1
        HermesAudioSession.reassertIfNeeded()
        beginTaskIfNeeded(named: reason)
        publishNowPlaying(title: reason)
    }

    func release() {
        holders = max(0, holders - 1)
        if holders == 0 {
            endTaskIfNeeded()
            clearNowPlaying()
        }
    }

    /// App foi para background: reforça sessão se ainda houver hold.
    func handleScenePhase(_ phase: ScenePhase) {
        guard holders > 0 else { return }
        switch phase {
        case .background, .inactive:
            HermesAudioSession.reassertIfNeeded()
            beginTaskIfNeeded(named: "hermes.scene.background")
        case .active:
            HermesAudioSession.reassertIfNeeded()
        @unknown default:
            break
        }
    }

    private func beginTaskIfNeeded(named name: String) {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.endTaskIfNeeded()
            }
        }
    }

    private func endTaskIfNeeded() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    private func publishNowPlaying(title: String) {
        if !nowPlayingActive {
            UIApplication.shared.beginReceivingRemoteControlEvents()
            try? AVAudioSession.sharedInstance().setActive(true)
            nowPlayingActive = true
        }
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = "Hermes"
        info[MPMediaItemPropertyArtist] = title
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if nowPlayingActive {
            UIApplication.shared.endReceivingRemoteControlEvents()
            nowPlayingActive = false
        }
    }
}
#endif
