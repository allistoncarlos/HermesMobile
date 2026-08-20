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
    #if os(iOS)
    private weak var vm: HermesViewModel?
    private var speakStream: HermesSpeakStream?
    #endif
    private var waitTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var isActive = false
    private var turnBusy = false
    private var holdingSessionBackground = false
    private var standaloneSpeakTask: Task<Void, Never>?

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
            #if os(iOS)
            if let tool = vm?.toolStatusText { return tool }
            #endif
            return "Hermes pensando…"
        case .speaking: return "Hermes falando…"
        case .error(let m): return m
        }
    }

    // MARK: - Ciclo de vida

    #if os(iOS)
    func attach(_ viewModel: HermesViewModel) {
        vm = viewModel
    }
    #endif

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
        #if os(iOS)
        retainSessionBackground(reason: "Modo voz Hermes")
        try? HermesAudioSession.activatePlayAndRecord()
        #endif

        let granted = await VoiceRecorder.requestPermission()
        guard granted else {
            phase = .error("Permissão de microfone negada. Ative em Ajustes.")
            return
        }
        #if os(watchOS)
        CompanionSync.shared.requestPhoneStatus()
        for _ in 0..<10 {
            if case .connected = CompanionSync.shared.phoneConnection { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard case .connected = CompanionSync.shared.phoneConnection else {
            phase = .error("Abra o Hermes no iPhone e mantenha-o por perto.")
            isActive = false
            return
        }
        #else
        guard vm?.httpClient != nil else {
            phase = .error("Sem conexão com o servidor Hermes.")
            return
        }
        #endif

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
        standaloneSpeakTask?.cancel()
        standaloneSpeakTask = nil
        recorder.onSilence = nil
        player.onFinished = nil
        player.onInterrupted = nil
        #if os(iOS)
        speakStream?.stop()
        speakStream = nil
        #endif
        _ = recorder.stop(discard: true)
        player.stop(interrupted: false)
        phase = .idle
        liveTranscript = ""
        audioLevel = 0
        releaseSessionBackground()
    }

    /// Fala disparada pelo servidor (chat / turno em background) sem abrir o modo voz.
    /// Se o loop de voz já estiver ativo, ignora (ele mesmo fala a resposta).
    func speakServerPush(_ text: String) {
        #if os(watchOS)
        return
        #else
        guard let vm, vm.config.speakRepliesAutomatically else { return }
        if isActive {
            switch phase {
            case .listening, .transcribing, .processing, .speaking:
                return
            default:
                break
            }
        }
        let speakable = SpeechSanitizer.sanitize(text)
        guard !speakable.isEmpty else { return }

        standaloneSpeakTask?.cancel()
        standaloneSpeakTask = Task { [weak self] in
            await self?.speakStandalone(speakable)
        }
        #endif
    }

    #if os(iOS)
    private func speakStandalone(_ text: String) async {
        guard let client = vm?.httpClient else { return }
        retainSessionBackground(reason: "Hermes falando")
        defer {
            if !isActive { releaseSessionBackground() }
        }
        do {
            try HermesAudioSession.activatePlayAndRecord()
            let audio = try await client.speakText(text)
            guard !Task.isCancelled else { return }
            try player.play(audio)
            // Aguarda o fim do áudio sem voltar ao loop de escuta.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let previousFinished = player.onFinished
                let previousInterrupted = player.onInterrupted
                player.onFinished = {
                    previousFinished?()
                    cont.resume()
                }
                player.onInterrupted = {
                    previousInterrupted?()
                    cont.resume()
                }
            }
        } catch {
            // Silencioso: falha de TTS no push não deve derrubar o chat.
        }
    }

    private func retainSessionBackground(reason: String) {
        guard !holdingSessionBackground else { return }
        holdingSessionBackground = true
        BackgroundRuntime.shared.retain(reason: reason)
    }

    private func releaseSessionBackground() {
        guard holdingSessionBackground else { return }
        holdingSessionBackground = false
        BackgroundRuntime.shared.release()
    }
    #else
    private func releaseSessionBackground() {}
    #endif

    // MARK: - Controles

    func primaryAction() {
        switch phase {
        case .listening:
            Task { await finishTurn(force: true) }
        case .speaking:
            #if os(iOS)
            speakStream?.stop()
            speakStream = nil
            #endif
            player.stop(interrupted: true)
            beginListening()
        case .processing, .transcribing:
            #if os(watchOS)
            CompanionSync.shared.sendCommand(["cmd": "stop"])
            #else
            Task { await vm?.stopStreaming() }
            speakStream?.stop()
            speakStream = nil
            #endif
            beginListening()
        case .error:
            Task { await startSession() }
        case .idle:
            Task { await startSession() }
        }
    }

    func resumeAfterApproval() {
        guard isActive else { return }
        #if os(watchOS)
        phase = .processing
        assistantCaption = "Continuando…"
        return
        #else
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
        #endif
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
        #if os(iOS)
        speakStream?.stop()
        speakStream = nil
        #endif
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

        #if os(watchOS)
        await finishTurnViaPhone(recording)
        return
        #else
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
        #endif
    }

    #if os(watchOS)
    private func finishTurnViaPhone(_ recording: VoiceRecorder.Recording) async {
        let observer = NotificationCenter.default.addObserver(
            forName: .hermesWatchVoiceEvent,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let payload = note.object as? [String: Any] ?? [:]
            Task { @MainActor in
                self?.applyPhoneVoiceEvent(payload)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = await CompanionSync.shared.sendVoiceTurn(recording: recording)
        guard isActive else { return }

        switch result {
        case .audio(let spoken):
            phase = .speaking
            do {
                try player.play(spoken)
                turnBusy = false
            } catch {
                phase = .error(error.localizedDescription)
                turnBusy = false
                beginListening()
            }
        case .empty:
            liveTranscript = ""
            turnBusy = false
            beginListening()
        case .stop:
            turnBusy = false
            dismiss()
        case .error(let message):
            phase = .error(message)
            turnBusy = false
            if isActive {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if isActive { beginListening() }
            }
        }
    }

    private func applyPhoneVoiceEvent(_ message: [String: Any]) {
        guard isActive else { return }
        switch message["kind"] as? String {
        case "voice.transcript":
            if let text = message["text"] as? String {
                liveTranscript = text
            }
            phase = .processing
        case "voice.caption":
            if let text = message["text"] as? String {
                assistantCaption = text
            }
            phase = .processing
        case "voice.phase":
            let p = message["phase"] as? String
            if let text = message["text"] as? String, !text.isEmpty {
                assistantCaption = text
            }
            switch p {
            case "transcribing": phase = .transcribing
            case "speaking": phase = .speaking
            default: phase = .processing
            }
        case "voice.approval":
            phase = .processing
            assistantCaption = message["message"] as? String ?? "Aguardando aprovação…"
        default:
            break
        }
    }
    #endif

    #if os(iOS)
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
    #endif

    static func isStopCommand(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
        return stopPhrases.contains(normalized)
    }
}
