import Foundation
import WatchConnectivity
#if os(iOS)
import UIKit
#endif

// ============================================================================
//  CompanionSync — o Apple Watch não alcança Tailscale/LAN; o iPhone é a ponte.
//  • Estado da sessão: applicationContext / sendMessage
//  • Voz: Watch grava → arquivo para o iPhone → STT/chat/TTS → áudio de volta
// ============================================================================

struct CompanionConfigSnapshot: Codable, Equatable {
    var baseURLString: String
    var sessionToken: String
    var username: String
    var canRestore: Bool
    var cookiesJSON: Data?
    var connection: String
    var statusMessage: String?
    var approvalMessage: String?
    var approvalSessionID: String?
    var approvalRequestID: String?

    enum CodingKeys: String, CodingKey {
        case baseURLString, sessionToken, username, canRestore, cookiesJSON
        case connection, statusMessage
        case approvalMessage, approvalSessionID, approvalRequestID
    }

    init(
        baseURLString: String,
        sessionToken: String,
        username: String,
        canRestore: Bool,
        cookiesJSON: Data? = nil,
        connection: String = "disconnected",
        statusMessage: String? = nil,
        approvalMessage: String? = nil,
        approvalSessionID: String? = nil,
        approvalRequestID: String? = nil
    ) {
        self.baseURLString = baseURLString
        self.sessionToken = sessionToken
        self.username = username
        self.canRestore = canRestore
        self.cookiesJSON = cookiesJSON
        self.connection = connection
        self.statusMessage = statusMessage
        self.approvalMessage = approvalMessage
        self.approvalSessionID = approvalSessionID
        self.approvalRequestID = approvalRequestID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try c.decodeIfPresent(String.self, forKey: .baseURLString) ?? ""
        sessionToken = try c.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        canRestore = try c.decodeIfPresent(Bool.self, forKey: .canRestore) ?? false
        cookiesJSON = try c.decodeIfPresent(Data.self, forKey: .cookiesJSON)
        connection = try c.decodeIfPresent(String.self, forKey: .connection) ?? "disconnected"
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
        approvalMessage = try c.decodeIfPresent(String.self, forKey: .approvalMessage)
        approvalSessionID = try c.decodeIfPresent(String.self, forKey: .approvalSessionID)
        approvalRequestID = try c.decodeIfPresent(String.self, forKey: .approvalRequestID)
    }
}

enum WatchTurnResult {
    case audio(SpokenAudio)
    case empty
    case stop
    case error(String)
}

@MainActor
final class CompanionSync: NSObject, ObservableObject {

    static let shared = CompanionSync()

    private static let contextKey = "hermes.config"

    #if os(iOS)
    weak var viewModel: HermesViewModel?
    #endif
    private var didActivate = false

    #if os(iOS)
    private var lastPushed: CompanionConfigSnapshot?
    private var pendingSnapshot: CompanionConfigSnapshot?
    private var watchTurnID: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    #if os(watchOS)
    @Published var phoneConnection: ConnectionState = .disconnected
    @Published var phoneDetail: String = ""
    @Published var phoneReachable = false
    @Published var didReceivePhoneState = false
    @Published var pendingApproval: PendingApproval?

    private var turnContinuation: CheckedContinuation<WatchTurnResult, Never>?
    private var turnID: String?
    private var turnSettled = false
    private var expectingAudio = false
    #endif

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        guard !didActivate else { return }
        didActivate = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    #if os(iOS)
    func bind(_ viewModel: HermesViewModel) {
        self.viewModel = viewModel
    }
    #endif

    #if os(watchOS)
    func bind() {
        applyContext(WCSession.isSupported() ? WCSession.default.receivedApplicationContext : [:])
        requestPhoneStatus()
    }
    #endif

    // MARK: - iPhone → Watch (estado)

    #if os(iOS)
    func push(from vm: HermesViewModel) {
        activate()
        let approval = vm.pendingApproval
        pendingSnapshot = CompanionConfigSnapshot(
            baseURLString: vm.config.baseURLString,
            sessionToken: vm.config.sessionToken,
            username: vm.config.username,
            canRestore: vm.config.canRestoreSession,
            cookiesJSON: SessionCookieStore.exportData(),
            connection: vm.connectionState.wireValue,
            statusMessage: vm.statusMessage,
            approvalMessage: approval?.message,
            approvalSessionID: approval?.sessionID,
            approvalRequestID: approval?.requestID
        )
        flush()
    }

    func push(_ config: ServerConfig) {
        if let vm = viewModel {
            push(from: vm)
        } else {
            activate()
            pendingSnapshot = CompanionConfigSnapshot(
                baseURLString: config.baseURLString,
                sessionToken: config.sessionToken,
                username: config.username,
                canRestore: config.canRestoreSession,
                cookiesJSON: SessionCookieStore.exportData()
            )
            flush()
        }
    }

    private func flush() {
        guard WCSession.isSupported() else { return }
        guard let snapshot = pendingSnapshot else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard snapshot != lastPushed else { return }
        lastPushed = snapshot
        guard let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }
        let payload: [String: Any] = [Self.contextKey: json]
        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in }
        }
    }

    private func sendWatch(_ payload: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in }
        } else {
            session.transferUserInfo(payload)
        }
    }
    #endif

    // MARK: - Watch → iPhone

    #if os(watchOS)
    func requestPhoneStatus() {
        activate()
        phoneReachable = WCSession.isSupported() && WCSession.default.isReachable
        sendCommand(["cmd": "ensureConnected"], expectReply: true)
    }

    func sendCommand(_ payload: [String: Any], expectReply: Bool = false) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if expectReply, session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                Task { @MainActor in self?.applyStatusReply(reply) }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor in self?.phoneReachable = false }
            })
        } else if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in }
        } else {
            session.transferUserInfo(payload)
        }
    }

    func sendVoiceTurn(recording: VoiceRecorder.Recording) async -> WatchTurnResult {
        activate()
        let session = WCSession.default
        guard session.activationState == .activated else {
            return .error("Relógio ainda não pareou com o iPhone.")
        }

        if let cont = turnContinuation {
            turnContinuation = nil
            turnSettled = true
            cont.resume(returning: .error("Turno substituído."))
        }
        turnSettled = false

        let id = UUID().uuidString
        turnID = id
        turnSettled = false
        expectingAudio = false

        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-turn-\(id).m4a")
        do {
            if FileManager.default.fileExists(atPath: stable.path) {
                try FileManager.default.removeItem(at: stable)
            }
            try FileManager.default.copyItem(at: recording.fileURL, to: stable)
        } catch {
            return .error("Não foi possível preparar o áudio.")
        }
        try? FileManager.default.removeItem(at: recording.fileURL)

        if session.isReachable {
            sendCommand(["cmd": "ensureConnected"], expectReply: true)
        }

        _ = session.transferFile(stable, metadata: [
            "kind": "voice.turn",
            "mime": recording.mimeType,
            "turn": id,
        ])

        return await withCheckedContinuation { cont in
            self.turnContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                await MainActor.run {
                    self?.settleTurn(.error("Tempo esgotado aguardando o iPhone."))
                }
            }
        }
    }

    func respondApproval(allow: Bool) {
        sendCommand(["cmd": "approval", "allow": allow], expectReply: true)
    }

    private func applyStatusReply(_ reply: [String: Any]) {
        phoneReachable = true
        didReceivePhoneState = true
        let wire = reply["connection"] as? String ?? "disconnected"
        let status = reply["status"] as? String
        let url = reply["url"] as? String ?? ""
        phoneConnection = ConnectionState.from(wire: wire, message: status)
        phoneDetail = (status?.isEmpty == false ? status : url) ?? url
        if let message = reply["approvalMessage"] as? String, !message.isEmpty {
            pendingApproval = PendingApproval(
                sessionID: reply["approvalSessionID"] as? String ?? "",
                message: message,
                requestID: reply["approvalRequestID"] as? String
            )
        } else if reply["connection"] != nil {
            pendingApproval = nil
        }
    }

    private func applyContext(_ context: [String: Any]) {
        guard let json = context[Self.contextKey] as? String,
              let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CompanionConfigSnapshot.self, from: data)
        else { return }
        didReceivePhoneState = true
        phoneConnection = ConnectionState.from(wire: snapshot.connection, message: snapshot.statusMessage)
        phoneDetail = snapshot.statusMessage?.isEmpty == false
            ? (snapshot.statusMessage ?? snapshot.baseURLString)
            : snapshot.baseURLString
        if let message = snapshot.approvalMessage, !message.isEmpty {
            pendingApproval = PendingApproval(
                sessionID: snapshot.approvalSessionID ?? "",
                message: message,
                requestID: snapshot.approvalRequestID
            )
        } else {
            pendingApproval = nil
        }
    }

    private func handleWatchMessage(_ message: [String: Any]) {
        if message[Self.contextKey] != nil {
            applyContext(message)
            return
        }
        let kind = message["kind"] as? String
        let turn = message["turn"] as? String
        guard turn == nil || turn == turnID else { return }

        switch kind {
        case "voice.phase":
            break
        case "voice.transcript":
            break
        case "voice.caption":
            break
        case "voice.approval":
            if let text = message["message"] as? String {
                pendingApproval = PendingApproval(
                    sessionID: message["session"] as? String ?? "",
                    message: text,
                    requestID: message["request"] as? String
                )
            }
        case "voice.stop":
            settleTurn(.stop)
        case "voice.done":
            let hasAudio = message["hasAudio"] as? Bool ?? false
            let empty = message["empty"] as? Bool ?? false
            if empty {
                settleTurn(.empty)
            } else if hasAudio {
                expectingAudio = true
            } else {
                settleTurn(.empty)
            }
        case "voice.error":
            settleTurn(.error(message["message"] as? String ?? "Falha no iPhone."))
        default:
            break
        }

        NotificationCenter.default.post(name: .hermesWatchVoiceEvent, object: message)
    }

    private func settleTurn(_ result: WatchTurnResult) {
        guard !turnSettled else { return }
        turnSettled = true
        expectingAudio = false
        turnID = nil
        let cont = turnContinuation
        turnContinuation = nil
        cont?.resume(returning: result)
    }
    #endif
}

extension Notification.Name {
    static let hermesWatchVoiceEvent = Notification.Name("hermes.watch.voice.event")
}

extension ConnectionState {
    var wireValue: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .waitingAuth: return "waitingAuth"
        case .failed: return "failed"
        }
    }

    static func from(wire: String, message: String?) -> ConnectionState {
        switch wire {
        case "connected": return .connected
        case "connecting": return .connecting
        case "waitingAuth": return .waitingAuth
        case "failed": return .failed(message ?? "Falha ao conectar.")
        default: return .disconnected
        }
    }
}

extension CompanionSync: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            #if os(iOS)
            self.flush()
            #else
            self.phoneReachable = session.isReachable
            self.applyContext(session.receivedApplicationContext)
            self.requestPhoneStatus()
            #endif
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            #if os(watchOS)
            self.phoneReachable = session.isReachable
            if session.isReachable { self.requestPhoneStatus() }
            #else
            if session.isReachable, let vm = self.viewModel {
                self.push(from: vm)
            }
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            #if os(watchOS)
            self.applyContext(applicationContext)
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            #if os(iOS)
            _ = await self.handlePhoneCommand(message)
            #else
            self.handleWatchMessage(message)
            #endif
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            #if os(iOS)
            let reply = await self.handlePhoneCommand(message)
            replyHandler(reply)
            #else
            self.handleWatchMessage(message)
            replyHandler([:])
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            #if os(iOS)
            _ = await self.handlePhoneCommand(userInfo)
            #else
            self.handleWatchMessage(userInfo)
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let kind = file.metadata?["kind"] as? String ?? ""
        let mime = file.metadata?["mime"] as? String ?? "audio/mp4"
        let turn = file.metadata?["turn"] as? String ?? ""
        let ext = mime.contains("wav") ? "wav" : "m4a"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-wc-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: file.fileURL, to: dest)
        Task { @MainActor in
            #if os(iOS)
            await self.handleIncomingWatchFile(url: dest, kind: kind, mime: mime, turn: turn)
            #else
            self.handleIncomingPhoneFile(url: dest, kind: kind, mime: mime, turn: turn)
            #endif
        }
    }
}

#if os(iOS)
extension CompanionSync {
    fileprivate func handlePhoneCommand(_ message: [String: Any]) async -> [String: Any] {
        let cmd = message["cmd"] as? String
        guard let vm = viewModel else {
            return statusReply(ok: false, extra: ["error": "Abra o Hermes no iPhone."])
        }

        switch cmd {
        case "ensureConnected":
            if vm.connectionState != .connected {
                await vm.connect()
            }
            return statusReply(ok: vm.connectionState == .connected)

        case "newSession":
            if vm.connectionState != .connected {
                await vm.connect()
            }
            if vm.connectionState == .connected {
                await vm.newSession()
            }
            return statusReply(ok: vm.connectionState == .connected)

        case "stop":
            await vm.stopStreaming()
            return statusReply(ok: true)

        case "approval":
            let allow = message["allow"] as? Bool ?? false
            await vm.respondApproval(allow: allow)
            if let turn = watchTurnID {
                await finishWatchTurnAfterApproval(turn: turn)
            }
            return statusReply(ok: true)

        default:
            if message[Self.contextKey] != nil {
                return statusReply(ok: true)
            }
            return statusReply(ok: true)
        }
    }

    private func statusReply(ok: Bool, extra: [String: Any] = [:]) -> [String: Any] {
        var reply: [String: Any] = [
            "ok": ok,
            "connection": viewModel?.connectionState.wireValue ?? "disconnected",
            "status": viewModel?.statusMessage ?? "",
            "url": viewModel?.config.baseURLString ?? "",
        ]
        if let approval = viewModel?.pendingApproval {
            reply["approvalMessage"] = approval.message
            reply["approvalSessionID"] = approval.sessionID
            reply["approvalRequestID"] = approval.requestID ?? ""
        }
        for (k, v) in extra { reply[k] = v }
        return reply
    }

    fileprivate func handleIncomingWatchFile(url: URL, kind: String, mime: String, turn: String) async {
        guard kind == "voice.turn" else { return }
        await runWatchVoiceTurn(fileURL: url, mime: mime, turn: turn)
        try? FileManager.default.removeItem(at: url)
    }

    private func runWatchVoiceTurn(fileURL: URL, mime: String, turn: String) async {
        watchTurnID = turn
        beginBackground()
        defer { endBackground() }

        guard let vm = viewModel else {
            sendWatch(["kind": "voice.error", "turn": turn, "message": "Abra o Hermes no iPhone."])
            return
        }
        if vm.connectionState != .connected {
            await vm.connect()
        }
        guard vm.connectionState == .connected, let client = vm.httpClient else {
            sendWatch(["kind": "voice.error", "turn": turn, "message": "Entre no Hermes pelo iPhone primeiro."])
            return
        }

        sendWatch(["kind": "voice.phase", "turn": turn, "phase": "transcribing"])

        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            sendWatch(["kind": "voice.error", "turn": turn, "message": "Áudio vazio."])
            return
        }
        let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"

        do {
            let transcript = try await client.transcribeAudio(dataURL: dataURL, mimeType: mime)
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                sendWatch(["kind": "voice.done", "turn": turn, "hasAudio": false, "empty": true])
                return
            }
            sendWatch(["kind": "voice.transcript", "turn": turn, "text": trimmed])

            if VoiceModeController.isStopCommand(trimmed) {
                sendWatch(["kind": "voice.stop", "turn": turn])
                return
            }

            sendWatch(["kind": "voice.phase", "turn": turn, "phase": "processing"])
            await vm.send(trimmed)
            await speakWatchReply(turn: turn, vm: vm, client: client)
        } catch {
            sendWatch(["kind": "voice.error", "turn": turn, "message": error.localizedDescription])
        }
    }

    private func finishWatchTurnAfterApproval(turn: String) async {
        guard let vm = viewModel, let client = vm.httpClient else { return }
        await speakWatchReply(turn: turn, vm: vm, client: client)
    }

    private func speakWatchReply(turn: String, vm: HermesViewModel, client: HermesClient) async {
        let started = Date()
        while vm.isStreaming && Date().timeIntervalSince(started) < 90 {
            if let approval = vm.pendingApproval {
                sendWatch([
                    "kind": "voice.approval",
                    "turn": turn,
                    "message": approval.message,
                    "session": approval.sessionID,
                    "request": approval.requestID ?? "",
                ])
                push(from: vm)
                return
            }
            if let tool = vm.toolStatusText {
                sendWatch(["kind": "voice.caption", "turn": turn, "text": tool])
            } else if let text = latestAssistant(vm), !text.isEmpty {
                sendWatch(["kind": "voice.caption", "turn": turn, "text": text])
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        if let approval = vm.pendingApproval {
            sendWatch([
                "kind": "voice.approval",
                "turn": turn,
                "message": approval.message,
                "session": approval.sessionID,
                "request": approval.requestID ?? "",
            ])
            push(from: vm)
            return
        }

        let reply = latestAssistant(vm) ?? ""
        let speakable = SpeechSanitizer.sanitize(reply)
        guard !speakable.isEmpty else {
            sendWatch(["kind": "voice.done", "turn": turn, "hasAudio": false])
            return
        }

        sendWatch(["kind": "voice.phase", "turn": turn, "phase": "speaking", "text": reply])
        do {
            let audio = try await client.speakText(speakable)
            let ext: String
            switch audio.mimeType.lowercased() {
            case "audio/wav", "audio/wave", "audio/x-wav": ext = "wav"
            case "audio/mp4", "audio/m4a", "audio/aac": ext = "m4a"
            default: ext = "mp3"
            }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("watch-tts-\(turn).\(ext)")
            try audio.data.write(to: out)
            WCSession.default.transferFile(out, metadata: [
                "kind": "voice.audio",
                "turn": turn,
                "mime": audio.mimeType,
            ])
            sendWatch(["kind": "voice.done", "turn": turn, "hasAudio": true, "text": reply])
        } catch {
            sendWatch(["kind": "voice.error", "turn": turn, "message": "TTS falhou: \(error.localizedDescription)"])
        }
    }

    private func latestAssistant(_ vm: HermesViewModel) -> String? {
        vm.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text
    }

    private func beginBackground() {
        endBackground()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "hermes.watch.voice") { [weak self] in
            Task { @MainActor in
                self?.endBackground()
            }
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
#endif

#if os(watchOS)
extension CompanionSync {
    fileprivate func handleIncomingPhoneFile(url: URL, kind: String, mime: String, turn: String) {
        guard kind == "voice.audio" else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard turn == turnID || turnID == nil else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            settleTurn(.error("Áudio do Hermes chegou vazio."))
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.removeItem(at: url)
        settleTurn(.audio(SpokenAudio(data: data, mimeType: mime, provider: nil)))
    }
}
#endif
