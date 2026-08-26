import AVFoundation
import Foundation

#if os(iOS)
import UIKit
#endif

// ============================================================================
//  HermesAudioSession — sessão de áudio no estilo WhatsApp (voice note):
//  - TTS / reprodução → `.playback` (volume/mute/rota do carro A2DP ok)
//  - Microfone → `.playAndRecord` só enquanto grava
//  - Sem forçar speaker nem modo `.voiceChat` (HFP / “chamada”)
// ============================================================================

enum HermesAudioSession {

    enum Mode: Equatable {
        case playback
        case playAndRecord
    }

    #if os(iOS)
    private static var didInstallObservers = false
    /// Modo que o app pretende manter enquanto estiver “segurando” áudio.
    private static var preferredMode: Mode?
    #endif

    /// Reprodução de TTS / speak-stream (equivalente a ouvir um áudio no WhatsApp).
    static func activatePlayback() throws {
        #if os(watchOS)
        try activatePlayAndRecord()
        #else
        preferredMode = .playback
        installObserversIfNeeded()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        // Limpa override residual de sessões antigas (speaker forçado).
        try? session.overrideOutputAudioPort(.none)
        try session.setActive(true, options: [])
        #endif
    }

    /// Microfone + eventual monitor local (só no loop de escuta / gravação).
    static func activatePlayAndRecord() throws {
        let session = AVAudioSession.sharedInstance()

        #if os(watchOS)
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
        #else
        preferredMode = .playAndRecord
        installObserversIfNeeded()
        // `.default` (não `.voiceChat`): evita rota de “chamada” HFP na multimídia.
        // `.defaultToSpeaker` é só preferência sem BT/carro — sem override forçado.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [
                .defaultToSpeaker,
                .allowBluetooth,
                .allowBluetoothA2DP,
            ]
        )
        try? session.overrideOutputAudioPort(.none)
        try session.setActive(true, options: [])
        #endif
    }

    /// Reforça a sessão no modo já escolhido (lock / interrupção / background).
    /// Não ativa áudio do zero — evita “capturar” a multimídia fora do modo voz/TTS.
    static func reassertIfNeeded() {
        #if os(iOS)
        guard let mode = preferredMode else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            switch mode {
            case .playback:
                if session.category != .playback {
                    try activatePlayback()
                } else {
                    try session.setActive(true, options: [])
                }
            case .playAndRecord:
                if session.category != .playAndRecord {
                    try activatePlayAndRecord()
                } else {
                    try session.setActive(true, options: [])
                }
            }
        } catch {
            // Melhor esforço — o caller pode tentar de novo no próximo play.
        }
        #endif
    }

    /// Libera a sessão para o sistema / carro voltar a controlar volume e mute.
    static func deactivate() {
        #if os(iOS)
        preferredMode = nil
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.none)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
            // Só reativa se ainda temos um modo intencional (voz/TTS).
            reassertIfNeeded()
        }
    }
    #endif
}

extension Notification.Name {
    static let hermesAudioShouldResume = Notification.Name("hermes.audio.shouldResume")
}
