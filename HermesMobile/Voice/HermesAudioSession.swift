import AVFoundation

// ============================================================================
//  HermesAudioSession — categoria playAndRecord compatível com iOS e watchOS.
// ============================================================================

enum HermesAudioSession {

    static func activatePlayAndRecord() throws {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        #if os(watchOS)
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
        #else
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        )
        try session.setActive(true)
        try? session.overrideOutputAudioPort(.speaker)
        #endif
    }
}
