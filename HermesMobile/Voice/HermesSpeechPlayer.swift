import AVFoundation
import Foundation

// ============================================================================
//  HermesSpeechPlayer — toca o áudio retornado por `POST /api/audio/speak`
//  (TTS nativo do servidor Hermes: Edge, OpenAI, ElevenLabs, …).
// ============================================================================

@MainActor
final class HermesSpeechPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {

    @Published private(set) var isSpeaking = false
    @Published private(set) var progress: Double = 0

    var onFinished: (() -> Void)?
    var onInterrupted: (() -> Void)?

    private var player: AVAudioPlayer?
    private var tempURL: URL?
    private var progressTimer: Timer?
    private var wasInterrupted = false
    private var holdingBackground = false
    private var resumeObserver: NSObjectProtocol?

    func play(_ audio: SpokenAudio) throws {
        stop(interrupted: false)

        try HermesAudioSession.activatePlayAndRecord()
        #if os(iOS)
        retainBackground()
        installResumeObserver()
        #endif

        let ext = Self.fileExtension(for: audio.mimeType)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-tts-\(UUID().uuidString).\(ext)")
        try audio.data.write(to: url)
        tempURL = url

        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.prepareToPlay()
        guard p.play() else {
            cleanupFile()
            releaseBackground()
            throw HermesClientError(message: "Não foi possível reproduzir o áudio do Hermes.")
        }
        player = p
        isSpeaking = true
        wasInterrupted = false
        progress = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        }
    }

    func stop(interrupted: Bool = true) {
        progressTimer?.invalidate()
        progressTimer = nil
        removeResumeObserver()
        if let player, player.isPlaying {
            wasInterrupted = interrupted
            player.stop()
        }
        player = nil
        isSpeaking = false
        progress = 0
        cleanupFile()
        releaseBackground()
        if interrupted {
            onInterrupted?()
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.removeResumeObserver()
            self.isSpeaking = false
            self.progress = 1
            self.player = nil
            self.cleanupFile()
            self.releaseBackground()
            if self.wasInterrupted {
                self.onInterrupted?()
            } else {
                self.onFinished?()
            }
        }
    }

    // MARK: - Helpers

    #if os(iOS)
    private func retainBackground() {
        guard !holdingBackground else { return }
        holdingBackground = true
        BackgroundRuntime.shared.retain(reason: "Hermes falando")
    }

    private func releaseBackground() {
        guard holdingBackground else { return }
        holdingBackground = false
        BackgroundRuntime.shared.release()
    }

    private func installResumeObserver() {
        removeResumeObserver()
        resumeObserver = NotificationCenter.default.addObserver(
            forName: .hermesAudioShouldResume,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, !player.isPlaying else { return }
                HermesAudioSession.reassertIfNeeded()
                player.play()
            }
        }
    }

    private func removeResumeObserver() {
        if let resumeObserver {
            NotificationCenter.default.removeObserver(resumeObserver)
            self.resumeObserver = nil
        }
    }
    #else
    private func releaseBackground() {}
    private func removeResumeObserver() {}
    #endif

    private func cleanupFile() {
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        tempURL = nil
    }

    private static func fileExtension(for mime: String) -> String {
        switch mime.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/wave", "audio/x-wav": return "wav"
        case "audio/ogg", "audio/opus": return "ogg"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/flac": return "flac"
        default: return "mp3"
        }
    }
}
