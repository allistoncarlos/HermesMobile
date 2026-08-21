import AVFoundation
import Foundation

#if os(iOS)
import MediaPlayer
import SwiftUI
import UIKit

// ============================================================================
//  BackgroundRuntime — mantém o app vivo o bastante para o Hermes falar
//  (e receber o fim do turno) com a tela bloqueada ou em outro app.
//  Expõe controles na tela de bloqueio / Central de Controle (Now Playing).
// ============================================================================

@MainActor
final class BackgroundRuntime {
    static let shared = BackgroundRuntime()

    private var task = UIBackgroundTaskIdentifier.invalid
    private var holders = 0
    private var nowPlayingActive = false
    private var remoteCommandsInstalled = false
    private var latestTitle = "Hermes"
    private var latestSubtitle = "Modo de voz"

    private init() {}

    /// Incrementa o “hold” de background (voz ativa, TTS, turno em processamento).
    func retain(reason: String) {
        holders += 1
        HermesAudioSession.reassertIfNeeded()
        beginTaskIfNeeded(named: reason)
        installRemoteCommandsIfNeeded()
        publishNowPlaying(title: "Hermes", subtitle: reason)
    }

    func release() {
        holders = max(0, holders - 1)
        if holders == 0 {
            endTaskIfNeeded()
            clearNowPlaying()
        }
    }

    /// Atualiza o cartão Now Playing (lock screen) sem alterar o hold.
    func updateNowPlaying(status: String) {
        guard holders > 0 else { return }
        publishNowPlaying(title: "Hermes", subtitle: status)
    }

    /// App foi para background: reforça sessão se ainda houver hold.
    func handleScenePhase(_ phase: ScenePhase) {
        guard holders > 0 else { return }
        switch phase {
        case .background, .inactive:
            HermesAudioSession.reassertIfNeeded()
            beginTaskIfNeeded(named: "hermes.scene.background")
            publishNowPlaying(title: latestTitle, subtitle: latestSubtitle)
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

    private func publishNowPlaying(title: String, subtitle: String) {
        latestTitle = title
        latestSubtitle = subtitle
        if !nowPlayingActive {
            UIApplication.shared.beginReceivingRemoteControlEvents()
            try? AVAudioSession.sharedInstance().setActive(true)
            nowPlayingActive = true
        }
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = subtitle
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if nowPlayingActive {
            UIApplication.shared.endReceivingRemoteControlEvents()
            nowPlayingActive = false
        }
    }

    private func installRemoteCommandsIfNeeded() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false

        center.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: .hermesVoiceRemotePlay, object: nil)
            return .success
        }
        center.pauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .hermesVoiceRemotePause, object: nil)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .hermesVoiceRemoteToggle, object: nil)
            return .success
        }
        center.stopCommand.addTarget { _ in
            NotificationCenter.default.post(name: .hermesVoiceRemoteStop, object: nil)
            return .success
        }
    }
}

extension Notification.Name {
    static let hermesVoiceRemotePlay = Notification.Name("hermes.voice.remote.play")
    static let hermesVoiceRemotePause = Notification.Name("hermes.voice.remote.pause")
    static let hermesVoiceRemoteToggle = Notification.Name("hermes.voice.remote.toggle")
    static let hermesVoiceRemoteStop = Notification.Name("hermes.voice.remote.stop")
}
#endif
