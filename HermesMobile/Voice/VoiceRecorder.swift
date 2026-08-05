import AVFoundation
import Foundation

// ============================================================================
//  VoiceRecorder — grava o microfone com VAD (silêncio) para enviar ao
//  STT nativo do Hermes (`POST /api/audio/transcribe`), igual ao desktop.
// ============================================================================

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {

    enum RecorderError: LocalizedError {
        case microphoneDenied
        case noInput
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Permissão de microfone negada. Ative em Ajustes → HermesMobile."
            case .noInput:
                return "Nenhum microfone disponível neste dispositivo."
            case .startFailed(let m):
                return m
            }
        }
    }

    struct Recording {
        let fileURL: URL
        let mimeType: String
        let dataURL: String
        let heardSpeech: Bool
        let duration: TimeInterval
    }

    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var heardSpeech = false

    /// Disparado após silêncio pós-fala (ou idle longo sem fala).
    var onSilence: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var fileURL: URL?
    private var mimeType: String = "audio/mp4"
    private var startedAt: Date?
    private var silenceStartedAt: Date?
    private var silenceTriggered = false

    /// Espelha o desktop Hermes (`silenceLevel: 0.075`, `silenceMs: 1250`).
    var speechThreshold: Float = 0.08
    var silenceMs: TimeInterval = 1.25
    var idleSilenceMs: TimeInterval = 12.0
    var maxSeconds: TimeInterval = 120

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    func start() throws {
        stop(discard: true)

        let permission = AVAudioApplication.shared.recordPermission
        switch permission {
        case .granted:
            break
        case .denied:
            throw RecorderError.microphoneDenied
        case .undetermined:
            throw RecorderError.startFailed("Permissão de microfone ainda não concedida.")
        @unknown default:
            throw RecorderError.microphoneDenied
        }

        try configureSession()

        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable else {
            throw RecorderError.noInput
        }

        // Tenta formatos em ordem de compatibilidade. AAC 16 kHz falha em
        // vários dispositivos/simuladores; 44.1 kHz e CAF/PCM são mais estáveis.
        var lastError: String = "Falha desconhecida ao abrir o microfone."
        for candidate in Self.formatCandidates() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hermes-voice-\(UUID().uuidString).\(candidate.ext)")
            do {
                let rec = try AVAudioRecorder(url: url, settings: candidate.settings)
                rec.isMeteringEnabled = true
                rec.delegate = self
                // prepareToRecord() pode retornar false sem impedir record().
                _ = rec.prepareToRecord()
                guard rec.record() else {
                    lastError = "AVAudioRecorder.record() retornou false (\(candidate.ext))."
                    try? FileManager.default.removeItem(at: url)
                    continue
                }

                fileURL = url
                mimeType = candidate.mime
                recorder = rec
                isRecording = true
                heardSpeech = false
                silenceTriggered = false
                silenceStartedAt = nil
                startedAt = Date()
                audioLevel = 0

                meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tickMeter() }
                }
                return
            } catch {
                lastError = error.localizedDescription
                try? FileManager.default.removeItem(at: url)
            }
        }

        throw RecorderError.startFailed("Não foi possível iniciar a gravação: \(lastError)")
    }

    /// Para e devolve o áudio pronto para `transcribe` (data URL base64).
    @discardableResult
    func stop(discard: Bool = false) -> Recording? {
        meterTimer?.invalidate()
        meterTimer = nil

        guard let rec = recorder else {
            isRecording = false
            audioLevel = 0
            if discard { cleanupOrphanFile() }
            return nil
        }

        let duration = rec.currentTime
        if rec.isRecording {
            rec.stop()
        }
        recorder = nil
        isRecording = false
        audioLevel = 0

        defer {
            if discard { cleanupOrphanFile() }
        }

        guard !discard, let url = fileURL else { return nil }
        // Pequeno yield: o arquivo AAC às vezes ainda não fechou no disco.
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            cleanupOrphanFile()
            return nil
        }

        let b64 = data.base64EncodedString()
        let result = Recording(
            fileURL: url,
            mimeType: mimeType,
            dataURL: "data:\(mimeType);base64,\(b64)",
            heardSpeech: heardSpeech,
            duration: duration
        )
        fileURL = nil
        return result
    }

    // MARK: - Session / formats

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()

        // Desativa antes de reconfigurar — evita falha quando o player TTS
        // deixou a sessão em modo spokenAudio.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        // `.default` é mais compatível que `.voiceChat` para AVAudioRecorder.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        )
        try? session.setPreferredSampleRate(44_100)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        try? session.overrideOutputAudioPort(.speaker)
    }

    private struct FormatCandidate {
        let ext: String
        let mime: String
        let settings: [String: Any]
    }

    private static func formatCandidates() -> [FormatCandidate] {
        [
            FormatCandidate(
                ext: "m4a",
                mime: "audio/mp4",
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
            ),
            FormatCandidate(
                ext: "m4a",
                mime: "audio/mp4",
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                ]
            ),
            FormatCandidate(
                ext: "wav",
                mime: "audio/wav",
                settings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            ),
        ]
    }

    private func cleanupOrphanFile() {
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
    }

    // MARK: - Meter / VAD

    private func tickMeter() {
        guard let rec = recorder, isRecording else { return }
        rec.updateMeters()
        let db = rec.averagePower(forChannel: 0)
        // Sem input real (simulador), averagePower fica em -120 e o orb não pulsa.
        let normalized = max(0, min(1, (db + 55) / 40))
        audioLevel = normalized

        let now = Date()
        if let startedAt, now.timeIntervalSince(startedAt) >= maxSeconds, !silenceTriggered {
            silenceTriggered = true
            onSilence?()
            return
        }

        if normalized >= speechThreshold {
            heardSpeech = true
            silenceStartedAt = nil
        } else if heardSpeech {
            if silenceStartedAt == nil { silenceStartedAt = now }
            if let silenceStartedAt,
               now.timeIntervalSince(silenceStartedAt) >= silenceMs,
               !silenceTriggered {
                silenceTriggered = true
                onSilence?()
            }
        } else if let startedAt,
                  now.timeIntervalSince(startedAt) >= idleSilenceMs,
                  !silenceTriggered {
            silenceTriggered = true
            onSilence?()
        }
    }
}

extension VoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            self.audioLevel = 0
        }
    }
}
