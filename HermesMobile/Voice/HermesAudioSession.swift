import AVFoundation
import Foundation

#if os(iOS)
import UIKit
#endif

// ============================================================================
//  HermesAudioSession — sessão de áudio pensada para continuar com a tela
//  bloqueada / app em segundo plano (UIBackgroundModes = audio).
// ============================================================================

enum HermesAudioSession {

    #if os(iOS)
    private static var didInstallObservers = false
    #endif

    /// Ativa play+record para o loop de voz (microfone + TTS).
    static func activatePlayAndRecord() throws {
        let session = AVAudioSession.sharedInstance()

        #if os(watchOS)
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
        #else
        installObserversIfNeeded()
        // Sem `.mixWithOthers`: o iOS precisa tratar o app como “áudio ativo”
        // para não suspender o processo ao ir para background / lock screen.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .defaultToSpeaker,
                .allowBluetooth,
                .allowBluetoothA2DP,
                .duckOthers,
            ]
        )
        try session.setActive(true, options: [])
        try? session.overrideOutputAudioPort(.speaker)
        #endif
    }

    /// Reforça a sessão ao entrar em background (lock / outro app).
    static func reassertIfNeeded() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playAndRecord {
                try activatePlayAndRecord()
            } else {
                try session.setActive(true, options: [])
            }
        } catch {
            // Melhor esforço — o caller pode tentar de novo no próximo play.
        }
        #endif
    }

    #if os(iOS)
    private static func installObserversIfNeeded() {
        guard !didInstallObservers else { return }
        didInstallObservers = true

        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            guard
                let info = note.userInfo,
                let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }

            switch type {
            case .began:
                break
            case .ended:
                let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    reassertIfNeeded()
                    NotificationCenter.default.post(name: .hermesAudioShouldResume, object: nil)
                }
            @unknown default:
                break
            }
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { _ in
            reassertIfNeeded()
        }
    }
    #endif
}

extension Notification.Name {
    static let hermesAudioShouldResume = Notification.Name("hermes.audio.shouldResume")
}
