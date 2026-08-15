import Foundation

// ============================================================================
//  VoiceModeController — loop nativo Hermes 0.20 (paridade com o Desktop):
//  grava → POST /api/audio/transcribe → prompt.submit →
//  WS /api/audio/speak-stream (deltas ao vivo) → fallback POST /api/audio/speak
// ============================================================================

@MainActor
final class VoiceModeController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case processing
        case speaking
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var assistantCaption: String = ""
    @Published private(set) var audioLevel: Float = 0
    @Published var isPresented: Bool = false

    private let recorder = VoiceRecorder()
    private let player = HermesSpeechPlayer()
    private weak var vm: HermesViewModel?
    private var waitTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var speakStream: HermesSpeakStream?
    private var isActive = false
    private var turnBusy = false

    private static let stopPhrases: Set<String> = [
        "parar", "pare", "stop", "cancela", "cancelar",
        "tchau", "adeus", "encerrar", "sair", "never mind", "goodbye",
    ]

    var statusLabel: String {
        switch phase {
        case .idle: return "Toque para falar"
        case .listening: return "Ouvindo… fale com o Hermes"
        case .transcribing: return "Transcrevendo no Hermes…"
        case .processing:
            if let tool = vm?.toolStatusText { return tool }
            return "Hermes pensando…"
        case .speaking: return "Hermes falando…"
        case .error(let m): return m
        }
    }

    // MARK: - Ciclo de vida

    func attach(_ viewModel: HermesViewModel) {
        vm = viewModel
    }

    func present() {
        guard !isPresented else { return }
        isPresented = true
        Task { await startSession() }
    }

    func dismiss() {
        #if os(watchOS)
        endSession()
        #else
        isPresented = false
        endSession()
        #endif
    }

    func startSession() async {
        endSession()
        isActive = true
        liveTranscript = ""
        assistantCaption = ""

        let granted = await VoiceRecorder.requestPermission()
        guard granted else {
            phase = .error("Permissão de microfone negada. Ative em Ajustes.")
            return
        }
        guard vm?.httpClient != nil else {
            phase = .error("Sem conexão com o servidor Hermes.")
            return
        }

        wireCallbacks()
        beginListening()
    }

    func endSession() {
        isActive = false
        turnBusy = false
        waitTask?.cancel()
        waitTask = nil
        levelTask?.cancel()
        levelTask = nil
        recorder.onSilence = nil
        player.onFinished = nil
        player.onInterrupted = nil
        speakStream?.stop()
        speakStream = nil
        _ = recorder.stop(discard: true)
        player.stop(interrupted: false)
        phase = .idle
        liveTranscript = ""
        audioLevel = 0
    }

    // MARK: - Controles

    func primaryAction() {
        switch phase {
        case .listening:
            Task { await finishTurn(force: true) }
        case .speaking:
            speakStream?.stop()
            speakStream = nil
            player.stop(interrupted: true)
            beginListening()
        case .processing, .transcribing:
            Task { await vm?.stopStreaming() }
            speakStream?.stop()
            speakStream = nil
            beginListening()
        case .error:
            Task { await startSession() }
        case .idle:
            Task { await startSession() }
        }
    }

    func resumeAfterApproval() {
        guard isActive else { return }
        if case .processing = phase {
            if vm?.isStreaming == true {
                waitTask?.cancel()
                waitTask = Task { [weak self] in
                    await self?.speakReplyDesktopStyle()
                }
            } else {
                beginListening()
            }
        }
    }

    // MARK: - Fluxo

    private func wireCallbacks() {
        recorder.onSilence = { [weak self] in
            Task { @MainActor in
                await self?.finishTurn(force: false)
            }
        }
        player.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.beginListening()
            }
        }
        player.onInterrupted = { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                if case .speaking = self.phase {
                    self.beginListening()
                }
            }
        }

        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                switch self.phase {
                case .listening:
                    self.audioLevel = self.recorder.audioLevel
                case .speaking:
                    self.audioLevel = max(0.25, self.audioLevel * 0.9 + 0.15)
                case .transcribing, .processing:
                    self.audioLevel = 0.12
                default:
                    break
                }
            }
        }
    }

    private func beginListening() {
        guard isActive else { return }
        waitTask?.cancel()
        speakStream?.stop()
        speakStream = nil
        player.stop(interrupted: false)
        _ = recorder.stop(discard: true)
        liveTranscript = ""
        assistantCaption = ""
        turnBusy = false
        phase = .listening

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard self.isActive, case .listening = self.phase else { return }
            do {
                try self.recorder.start()
            } catch {
                self.phase = .error(error.localizedDescription)
            }
        }
    }

    private func finishTurn(force: Bool) async {
        guard isActive, !turnBusy else { return }
        guard case .listening = phase else { return }
        turnBusy = true

        let recording = recorder.stop(discard: false)
        guard let recording else {
            turnBusy = false
            if isActive { beginListening() }
            return
        }

        if !force && !recording.heardSpeech {
            try? FileManager.default.removeItem(at: recording.fileURL)
            turnBusy = false
            beginListening()
            return
        }

        phase = .transcribing
        assistantCaption = ""
        liveTranscript = "…"

        guard let client = vm?.httpClient else {
            phase = .error("Sem conexão com o servidor Hermes.")
            turnBusy = false
            return
        }

        do {
            let transcript = try await client.transcribeAudio(
                dataURL: recording.dataURL,
                mimeType: recording.mimeType
            )
            try? FileManager.default.removeItem(at: recording.fileURL)
            guard isActive else { return }

            if transcript.isEmpty {
                liveTranscript = ""
                turnBusy = false
                beginListening()
                return
            }

            liveTranscript = transcript
            if Self.isStopCommand(transcript) {
                turnBusy = false
                dismiss()
                return
            }

            phase = .processing
            await vm?.send(transcript)
            await speakReplyDesktopStyle()
        } catch {
            try? FileManager.default.removeItem(at: recording.fileURL)
            phase = .error(error.localizedDescription)
            turnBusy = false
            if isActive {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if isActive { beginListening() }
            }
        }
    }

    /// Paridade com `use-voice-conversation.ts` → `openLiveSpeech` + fallback.
    private func speakReplyDesktopStyle() async {
        guard isActive, let vm else {
            turnBusy = false
            return
        }

        // Espera o turno começar.
        let started = Date()
        while !Task.isCancelled && isActive {
            if vm.isStreaming { break }
            if Date().timeIntervalSince(started) > 2.5 { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        if vm.pendingApproval != nil {
            phase = .processing
            assistantCaption = vm.pendingApproval?.message ?? "Aguardando aprovação…"
            turnBusy = false
            return
        }

        // Tenta stream TTS ao vivo (como o desktop).
        var streamOutcome: HermesSpeakStream.Outcome = .fallback
        if let url = try? await vm.makeSpeakStreamURL() {
            let stream = HermesSpeakStream(url: url)
            speakStream = stream
            phase = .speaking
            assistantCaption = "Gerando voz…"

            let runTask = Task { await stream.run() }
            var spokenLength = 0

            while !Task.isCancelled && isActive {
                let text = latestAssistantText(from: vm)
                if text.count > spokenLength {
                    let delta = String(text.dropFirst(spokenLength))
                    spokenLength = text.count
                    stream.append(delta)
                    if !text.isEmpty {
                        assistantCaption = text
                    }
                }
                if stream.didStartAudio {
                    phase = .speaking
                }
                if vm.pendingApproval != nil {
                    stream.stop()
                    break
                }
                if !vm.isStreaming {
                    // Flush final e encerra o turno de fala.
                    let finalText = latestAssistantText(from: vm)
                    if finalText.count > spokenLength {
                        stream.append(String(finalText.dropFirst(spokenLength)))
                        spokenLength = finalText.count
                        assistantCaption = finalText
                    }
                    stream.finish()
                    break
                }
                if let tool = vm.toolStatusText, !stream.didStartAudio {
                    assistantCaption = tool
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }

            streamOutcome = await runTask.value
            speakStream = nil

            if streamOutcome == .done {
                turnBusy = false
                if isActive { beginListening() }
                return
            }
        }

        // Fallback: POST /api/audio/speak com o texto completo (sanitizado).
        if vm.hasPendingClarify {
            let clarify = vm.messages.last(where: { $0.role == .system })?.text
                ?? "O Hermes pediu um esclarecimento."
            await speakViaPOST(clarify)
            return
        }
        if vm.pendingApproval != nil {
            phase = .processing
            assistantCaption = vm.pendingApproval?.message ?? "Aguardando aprovação…"
            turnBusy = false
            return
        }

        // Se o stream não rolou, ainda podemos estar no meio do turno — espera terminar.
        while !Task.isCancelled && isActive && vm.isStreaming {
            if let tool = vm.toolStatusText { assistantCaption = tool }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        let reply = latestAssistantText(from: vm)
        guard !reply.isEmpty else {
            turnBusy = false
            beginListening()
            return
        }
        await speakViaPOST(reply)
    }

    private func speakViaPOST(_ text: String) async {
        guard isActive else {
            turnBusy = false
            return
        }
        let speakable = SpeechSanitizer.sanitize(text)
        guard !speakable.isEmpty else {
            turnBusy = false
            beginListening()
            return
        }

        assistantCaption = text
        phase = .speaking
        audioLevel = 0.3

        guard let client = vm?.httpClient else {
            phase = .error("Sem conexão com o servidor Hermes.")
            turnBusy = false
            return
        }

        do {
            let audio = try await client.speakText(speakable)
            guard isActive else { return }
            try player.play(audio)
            turnBusy = false
            // onFinished → beginListening
        } catch {
            phase = .error("TTS do Hermes falhou: \(error.localizedDescription)")
            turnBusy = false
            if isActive {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if isActive { beginListening() }
            }
        }
    }

    private func latestAssistantText(from vm: HermesViewModel) -> String {
        vm.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text ?? ""
    }

    private static func isStopCommand(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
        return stopPhrases.contains(normalized)
    }
}
