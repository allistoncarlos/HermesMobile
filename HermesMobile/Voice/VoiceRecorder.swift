import AVFoundation
import Foundation

// ============================================================================
//  VoiceRecorder — grava o microfone com VAD (endpointing) para enviar ao
//  STT nativo do Hermes (`POST /api/audio/transcribe`), igual ao desktop.
//  Detecta fim de fala com piso de ruído adaptativo + histerese + silêncio pós-fala.
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
                #if os(watchOS)
                return "Permissão de microfone negada. Ative em Ajustes no Apple Watch."
                #else
                return "Permissão de microfone negada. Ative em Ajustes → HermesMobile."
                #endif
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
    /// True enquanto o VAD considera que há fala ativa.
    @Published private(set) var isHearingSpeech = false
    /// 0…1 progresso do silêncio pós-fala até o endpoint automático.
    @Published private(set) var silenceProgress: Float = 0

    /// Disparado após silêncio pós-fala (ou idle longo sem fala).
    var onSilence: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var fileURL: URL?
    private var mimeType: String = "audio/mp4"
    private var startedAt: Date?
    private var silenceStartedAt: Date?
    private var speechStartedAt: Date?
    private var silenceTriggered = false
    private var smoothedLevel: Float = 0
    private var noiseFloor: Float = 0.03
    private var calibrating = true

    /// Silêncio contínuo após fala suficiente para fechar o turno (handsfree).
    var silenceMs: TimeInterval = 0.95
    /// Tempo mínimo de fala contínua antes de permitir endpoint.
    var minSpeechMs: TimeInterval = 0.28
    /// Janela inicial para medir o piso de ruído ambiente.
    var calibrateMs: TimeInterval = 0.45
    #if os(watchOS)
    var idleSilenceMs: TimeInterval = 10.0
    var maxSeconds: TimeInterval = 60
    #else
    var idleSilenceMs: TimeInterval = 14.0
    var maxSeconds: TimeInterval = 120
    #endif

    private let levelEMA: Float = 0.38
    private let enterMargin: Float = 0.11
    private let exitMargin: Float = 0.055
    private let absoluteFloor: Float = 0.02
    private let absoluteCeiling: Float = 0.18

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(iOS 17.0, watchOS 10.0, *) {
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }

    func start() throws {
        stop(discard: true)

        if #available(iOS 17.0, watchOS 10.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                break
            case .denied:
                throw RecorderError.microphoneDenied
            case .undetermined:
                throw RecorderError.startFailed("Permissão de microfone ainda não concedida.")
            @unknown default:
                throw RecorderError.microphoneDenied
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                break
            case .denied:
                throw RecorderError.microphoneDenied
            case .undetermined:
                throw RecorderError.startFailed("Permissão de microfone ainda não concedida.")
            @unknown default:
                throw RecorderError.microphoneDenied
            }
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
                isHearingSpeech = false
                silenceProgress = 0
                silenceTriggered = false
                silenceStartedAt = nil
                speechStartedAt = nil
                startedAt = Date()
                audioLevel = 0
                smoothedLevel = 0
                noiseFloor = 0.03
                calibrating = true

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
            silenceProgress = 0
            isHearingSpeech = false
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
        silenceProgress = 0
        isHearingSpeech = false

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


    private func configureSession() throws {
        try HermesAudioSession.activatePlayAndRecord()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredSampleRate(44_100)
        try? session.setPreferredIOBufferDuration(0.02)
        #endif
    }

    private struct FormatCandidate {
        let ext: String
        let mime: String
        let settings: [String: Any]
    }

    private static func formatCandidates() -> [FormatCandidate] {
        let aac16 = FormatCandidate(
            ext: "m4a",
            mime: "audio/mp4",
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
        )
        let wav16 = FormatCandidate(
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
        )
        #if os(watchOS)
        return [aac16, wav16]
        #else
        return [
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
            aac16,
            wav16,
        ]
        #endif
    }

    private func cleanupOrphanFile() {
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
    }


    private func tickMeter() {
        guard let rec = recorder, isRecording else { return }
        rec.updateMeters()
        let db = rec.averagePower(forChannel: 0)
        // Sem input real (simulador), averagePower fica em -120 e o orb não pulsa.
        let raw = max(0, min(1, (db + 55) / 40))
        smoothedLevel = smoothedLevel * (1 - levelEMA) + raw * levelEMA
        audioLevel = smoothedLevel

        let now = Date()
        guard let startedAt else { return }

        if now.timeIntervalSince(startedAt) >= maxSeconds, !silenceTriggered {
            fireSilence()
            return
        }

        // Calibra piso de ruído nos primeiros frames (sem fala ainda).
        if calibrating {
            let elapsed = now.timeIntervalSince(startedAt)
            noiseFloor = min(absoluteCeiling, max(noiseFloor, smoothedLevel))
            if elapsed >= calibrateMs {
                calibrating = false
                noiseFloor = min(absoluteCeiling, max(absoluteFloor, noiseFloor))
            }
        }

        let enterThreshold = min(0.55, noiseFloor + enterMargin)
        let exitThreshold = min(enterThreshold - 0.02, max(absoluteFloor, noiseFloor + exitMargin))

        if smoothedLevel >= enterThreshold {
            if !isHearingSpeech {
                isHearingSpeech = true
                speechStartedAt = now
            }
            heardSpeech = true
            silenceStartedAt = nil
            silenceProgress = 0
            // Ambiente ruidoso: sobe o piso lentamente para não “grudar” em fala.
            if !calibrating {
                noiseFloor = min(absoluteCeiling, noiseFloor * 0.995 + smoothedLevel * 0.005)
            }
        } else if isHearingSpeech, smoothedLevel < exitThreshold {
            isHearingSpeech = false
            silenceStartedAt = now
        } else if heardSpeech, !isHearingSpeech {
            if silenceStartedAt == nil { silenceStartedAt = now }
            let speechOK: Bool = {
                guard let speechStartedAt else { return true }
                return now.timeIntervalSince(speechStartedAt) >= minSpeechMs
            }()
            if let silenceStartedAt, speechOK {
                let silentFor = now.timeIntervalSince(silenceStartedAt)
                silenceProgress = Float(min(1, silentFor / silenceMs))
                if silentFor >= silenceMs, !silenceTriggered {
                    fireSilence()
                    return
                }
            }
        } else if !heardSpeech,
                  now.timeIntervalSince(startedAt) >= idleSilenceMs,
                  !silenceTriggered {
            fireSilence()
            return
        } else {
            silenceProgress = 0
        }
    }

    private func fireSilence() {
        silenceTriggered = true
        silenceProgress = 1
        isHearingSpeech = false
        onSilence?()
    }
}

extension VoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            self.audioLevel = 0
            self.silenceProgress = 0
            self.isHearingSpeech = false
        }
    }
}
