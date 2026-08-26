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
    /// Progresso 0…1 do silêncio pós-fala (endpoint automático).
    @Published private(set) var silenceProgress: Float = 0
    @Published private(set) var isHearingSpeech = false
    @Published var isPresented: Bool = false

    private let recorder = VoiceRecorder()
    private let player = HermesSpeechPlayer()
    #if os(iOS)
    private weak var vm: HermesViewModel?
    private var speakStream: HermesSpeakStream?
    private var remoteObservers: [NSObjectProtocol] = []
    #endif
    private var waitTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var isActive = false
    private var turnBusy = false
    private var holdingSessionBackground = false
    private var standaloneSpeakTask: Task<Void, Never>?
    private var awaitingVoiceApproval = false
    private var approvalPromptTries = 0
    private var lastNowPlayingStatus = ""

    private static let stopPhrases: Set<String> = [
        "parar", "pare", "stop", "cancela", "cancelar",
        "tchau", "adeus", "encerrar", "sair", "never mind", "goodbye",
    ]
    private static let approvePhrases: Set<String> = [
        "sim", "yes", "aprovar", "aprova", "permite", "permitir",
        "ok", "okay", "pode", "pode sim", "confirma", "confirmar",
        "aceito", "aceitar", "vai", "pode ir",
    ]
    private static let denyPhrases: Set<String> = [
        "não", "nao", "no", "negar", "nega", "recusar", "recusa",
        "bloquear", "rejeitar", "rejeita",
    ]

    var statusLabel: String {
        switch phase {
        case .idle:
            return "Handsfree — Siri ou toque para começar"
        case .listening:
            #if os(iOS)
            if awaitingVoiceApproval {
                return "Diga “sim” ou “não” para a aprovação"
            }
            #endif
            if isHearingSpeech {
                return "Ouvindo… pare de falar para enviar"
            }
            if silenceProgress > 0.15 {
                return "Enviando quando o silêncio completar…"
            }
            return "Ouvindo… fale à vontade"
        case .transcribing: return "Transcrevendo no Hermes…"
        case .processing:
            #if os(iOS)
            if awaitingVoiceApproval {
                return "Aguardando sua aprovação por voz…"
            }
            if let tool = vm?.toolStatusText { return tool }
            #endif
            return "Hermes pensando…"
        case .speaking: return "Hermes falando…"
        case .error(let m): return m
        }
    }


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
        silenceProgress = 0
        isHearingSpeech = false
        awaitingVoiceApproval = false
        approvalPromptTries = 0
        #if os(iOS)
        retainSessionBackground(reason: "Ouvindo o Hermes")
        try? HermesAudioSession.activatePlayAndRecord()
        installRemoteObservers()
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
        awaitingVoiceApproval = false
        approvalPromptTries = 0
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
        removeRemoteObservers()
        #endif
        _ = recorder.stop(discard: true)
        player.stop(interrupted: false)
        phase = .idle
        liveTranscript = ""
        audioLevel = 0
        silenceProgress = 0
        isHearingSpeech = false
        releaseSessionBackground()
        #if os(iOS)
        HermesAudioSession.deactivate()
        #endif
    }

    /// Interrompe TTS de “Ler em Voz Alta” (não encerra o modo voz handsfree).
    func stopReadAloud() {
        standaloneSpeakTask?.cancel()
        standaloneSpeakTask = nil
        #if os(iOS)
        guard !isActive else { return }
        speakStream?.stop()
        speakStream = nil
        player.stop(interrupted: true)
        releaseSessionBackground()
        HermesAudioSession.deactivate()
        #endif
    }

    /// Fala disparada pelo servidor (chat / turno em background) sem abrir o modo voz.
    /// Se o loop de voz já estiver ativo, ignora (ele mesmo fala a resposta).
    func speakServerPush(_ text: String) {
        #if os(watchOS)
        return
        #else
        guard let vm, vm.speakRepliesAutomatically else { return }
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
            if !isActive {
                releaseSessionBackground()
                HermesAudioSession.deactivate()
            }
        }
        do {
            let audio = try await client.speakText(text)
            guard !Task.isCancelled else { return }
            guard vm?.speakRepliesAutomatically == true else { return }
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
        if holdingSessionBackground {
            BackgroundRuntime.shared.updateNowPlaying(status: reason)
            return
        }
        holdingSessionBackground = true
        BackgroundRuntime.shared.retain(reason: reason)
    }

    private func releaseSessionBackground() {
        guard holdingSessionBackground else { return }
        holdingSessionBackground = false
        BackgroundRuntime.shared.release()
    }

    private func refreshNowPlaying() {
        guard holdingSessionBackground else { return }
        let status = statusLabel
        guard status != lastNowPlayingStatus else { return }
        lastNowPlayingStatus = status
        BackgroundRuntime.shared.updateNowPlaying(status: status)
    }

    private func installRemoteObservers() {
        removeRemoteObservers()
        let center = NotificationCenter.default
        remoteObservers = [
            center.addObserver(forName: .hermesVoiceRemoteToggle, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.primaryAction() }
            },
            center.addObserver(forName: .hermesVoiceRemotePause, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleRemotePause() }
            },
            center.addObserver(forName: .hermesVoiceRemotePlay, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleRemotePlay() }
            },
            center.addObserver(forName: .hermesVoiceRemoteStop, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            },
            center.addObserver(forName: .hermesAudioShouldResume, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleAudioResume() }
            },
        ]
    }

    private func removeRemoteObservers() {
        let center = NotificationCenter.default
        for obs in remoteObservers {
            center.removeObserver(obs)
        }
        remoteObservers = []
    }

    private func handleRemotePause() {
        switch phase {
        case .listening:
            Task { await finishTurn(force: true) }
        case .speaking, .processing, .transcribing:
            primaryAction()
        default:
            break
        }
    }

    private func handleRemotePlay() {
        switch phase {
        case .idle, .error:
            Task { await startSession() }
        case .listening:
            break
        default:
            primaryAction()
        }
    }

    private func handleAudioResume() {
        guard isActive else { return }
        HermesAudioSession.reassertIfNeeded()
        if case .listening = phase, !recorder.isRecording {
            beginListening()
        }
    }
    #else
    private func releaseSessionBackground() {}
    private func refreshNowPlaying() {}
    #endif


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
        awaitingVoiceApproval = false
        approvalPromptTries = 0
        if case .processing = phase {
            if vm?.isStreaming == true {
                waitTask?.cancel()
                waitTask = Task { [weak self] in
                    await self?.speakReplyDesktopStyle()
                }
            } else {
                beginListening()
            }
        } else {
            waitTask?.cancel()
            waitTask = Task { [weak self] in
                await self?.speakReplyDesktopStyle()
            }
        }
        #endif
    }


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
                    self.silenceProgress = self.recorder.silenceProgress
                    self.isHearingSpeech = self.recorder.isHearingSpeech
                    self.refreshNowPlaying()
                case .speaking:
                    self.audioLevel = max(0.25, self.audioLevel * 0.9 + 0.15)
                    self.silenceProgress = 0
                    self.isHearingSpeech = false
                case .transcribing, .processing:
                    self.audioLevel = 0.12
                    self.silenceProgress = 0
                    self.isHearingSpeech = false
                    self.refreshNowPlaying()
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
        if !awaitingVoiceApproval {
            assistantCaption = ""
        }
        turnBusy = false
        silenceProgress = 0
        isHearingSpeech = false
        phase = .listening
        refreshNowPlaying()

        Task { @MainActor in
            // Folga curta para o TTS/eco do alto-falante não virar “fala”.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard self.isActive, case .listening = self.phase else { return }
            do {
                try HermesAudioSession.activatePlayAndRecord()
                try self.recorder.start()
                self.refreshNowPlaying()
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
            #if os(iOS)
            if awaitingVoiceApproval || vm?.pendingApproval != nil {
                if Self.isStopCommand(transcript) {
                    turnBusy = false
                    dismiss()
                    return
                }
                await handleVoiceApprovalReply(transcript)
                return
            }
            #endif

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
            await presentVoiceApproval(vm.pendingApproval!)
            return
        }

        // Tenta stream TTS ao vivo (como o desktop).
        var streamOutcome: HermesSpeakStream.Outcome = .fallback
        if let url = try? await vm.makeSpeakStreamURL() {
            let stream = HermesSpeakStream(url: url)
            speakStream = stream
            phase = .speaking
            assistantCaption = "Gerando voz…"
            refreshNowPlaying()

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

            if vm.pendingApproval != nil {
                await presentVoiceApproval(vm.pendingApproval!)
                return
            }

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
            await presentVoiceApproval(vm.pendingApproval!)
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
        refreshNowPlaying()

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

    /// Anuncia a aprovação e volta a ouvir — handsfree total (sim/não).
    private func presentVoiceApproval(_ approval: PendingApproval) async {
        guard isActive else {
            turnBusy = false
            return
        }
        awaitingVoiceApproval = true
        approvalPromptTries += 1
        phase = .processing
        assistantCaption = approval.message
        refreshNowPlaying()

        let prompt: String
        if approvalPromptTries <= 1 {
            prompt = "Preciso da sua aprovação. \(approval.message). Diga sim para aprovar, ou não para negar."
        } else {
            prompt = "Ainda aguardando. Diga sim para aprovar, ou não para negar."
        }

        turnBusy = false
        await speakPromptThenListen(prompt)
    }

    private func handleVoiceApprovalReply(_ transcript: String) async {
        guard let vm else {
            turnBusy = false
            beginListening()
            return
        }

        if Self.isApproveCommand(transcript) {
            awaitingVoiceApproval = false
            approvalPromptTries = 0
            phase = .processing
            assistantCaption = "Aprovado. Continuando…"
            turnBusy = false
            await vm.respondApproval(allow: true)
            resumeAfterApproval()
            return
        }

        if Self.isDenyCommand(transcript) {
            awaitingVoiceApproval = false
            approvalPromptTries = 0
            phase = .processing
            assistantCaption = "Negado."
            turnBusy = false
            await vm.respondApproval(allow: false)
            await speakPromptThenListen("Ok, neguei a ação.")
            return
        }

        if approvalPromptTries >= 3 {
            // Mantém o banner tocável e continua ouvindo.
            turnBusy = false
            beginListening()
            return
        }

        if let approval = vm.pendingApproval {
            await presentVoiceApproval(approval)
        } else {
            awaitingVoiceApproval = false
            turnBusy = false
            beginListening()
        }
    }

    /// Fala um prompt sem reentrar no fluxo de resposta do agente; ao terminar, escuta.
    private func speakPromptThenListen(_ text: String) async {
        guard isActive, let client = vm?.httpClient else {
            turnBusy = false
            beginListening()
            return
        }
        let speakable = SpeechSanitizer.sanitize(text)
        guard !speakable.isEmpty else {
            turnBusy = false
            beginListening()
            return
        }

        phase = .speaking
        refreshNowPlaying()
        do {
            let audio = try await client.speakText(speakable)
            guard isActive else { return }
            try player.play(audio)
            // onFinished → beginListening
        } catch {
            turnBusy = false
            beginListening()
        }
    }
    #endif

    static func isStopCommand(_ text: String) -> Bool {
        let normalized = Self.normalizeVoiceCommand(text)
        return stopPhrases.contains(normalized)
    }

    static func isApproveCommand(_ text: String) -> Bool {
        let normalized = Self.normalizeVoiceCommand(text)
        if approvePhrases.contains(normalized) { return true }
        let tokens = normalized.split(separator: " ").map(String.init)
        return tokens.contains(where: { approvePhrases.contains($0) })
            && !tokens.contains(where: { denyPhrases.contains($0) })
    }

    static func isDenyCommand(_ text: String) -> Bool {
        let normalized = Self.normalizeVoiceCommand(text)
        if denyPhrases.contains(normalized) { return true }
        let tokens = normalized.split(separator: " ").map(String.init)
        return tokens.contains(where: { denyPhrases.contains($0) })
    }

    private static func normalizeVoiceCommand(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
