import AVFoundation
import Foundation

// ============================================================================
//  HermesSpeakStream — WebSocket `/api/audio/speak-stream` (Hermes Desktop 0.20).
//
//  Protocolo:
//    client → {"text":"..."} | {"done":true} | {"stop":true}
//    server → {"type":"start","sample_rate":N} | frames PCM int16 | {"type":"end"|"fallback"}
// ============================================================================

@MainActor
final class HermesSpeakStream: NSObject {

    enum Outcome: Equatable {
        /// Áudio tocou até o fim (ou foi interrompido depois de começar).
        case done
        /// Sem streaming — caller deve usar `POST /api/audio/speak`.
        case fallback
    }

    private(set) var didStartAudio = false

    private let url: URL
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var sampleRate: Double = 24_000
    private var carry = Data()
    private var finishedSending = false
    private var settled = false
    private var receivedEnd = false
    private var pendingBuffers = 0
    private var pendingSends: [Data] = []
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(url: URL, urlSession: URLSession = HermesHTTPSession.shared) {
        self.url = url
        self.urlSession = urlSession
        super.init()
    }

    /// Conecta, processa o stream e resolve quando o áudio terminar (ou fallback).
    func run() async -> Outcome {
        await withCheckedContinuation { cont in
            self.continuation = cont
            let ws = urlSession.webSocketTask(with: url)
            self.task = ws
            ws.resume()
            self.receiveNext()
        }
    }

    func append(_ text: String) {
        guard !text.isEmpty, !finishedSending, !settled else { return }
        sendJSON(["text": text])
    }

    func finish() {
        guard !finishedSending, !settled else { return }
        finishedSending = true
        sendJSON(["done": true])
    }

    func stop() {
        guard !settled else { return }
        sendJSON(["stop": true])
        settle(didStartAudio ? .done : .fallback)
    }

    // MARK: - Wire

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let str = String(data: data, encoding: .utf8) else { return }
        guard let task, task.state == .running else {
            pendingSends.append(data)
            return
        }
        flushPending(using: task)
        task.send(.string(str)) { _ in }
    }

    private func flushPending(using task: URLSessionWebSocketTask) {
        let backlog = pendingSends
        pendingSends.removeAll()
        for data in backlog {
            if let str = String(data: data, encoding: .utf8) {
                task.send(.string(str)) { _ in }
            }
        }
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.settled else { return }
                switch result {
                case .failure:
                    self.settle(self.didStartAudio ? .done : .fallback)
                case .success(let message):
                    self.handle(message)
                    if !self.settled {
                        self.receiveNext()
                    }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            // Pode ser JSON em Data ou PCM binário. Se parecer JSON, trata como tal.
            if let text = String(data: data, encoding: .utf8), text.first == "{" {
                handleJSONText(text)
            } else {
                schedulePCM(data)
            }
        case .string(let text):
            handleJSONText(text)
        @unknown default:
            break
        }
    }

    private func handleJSONText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "start":
            if let rate = obj["sample_rate"] as? Double {
                sampleRate = rate
            } else if let rate = obj["sample_rate"] as? Int {
                sampleRate = Double(rate)
            }
            prepareEngine()
            if let task {
                flushPending(using: task)
            }
        case "end":
            receivedEnd = true
            checkDrain()
        case "fallback":
            settle(didStartAudio ? .done : .fallback)
        default:
            break
        }
    }

    // MARK: - Audio

    private func prepareEngine() {
        if engine != nil { return }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        audioFormat = format

        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: format)

        do {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try session.setActive(true)
            try? session.overrideOutputAudioPort(.speaker)
            try eng.start()
            node.play()
            engine = eng
            playerNode = node
        } catch {
            settle(.fallback)
        }
    }

    private func schedulePCM(_ data: Data) {
        if engine == nil { prepareEngine() }
        guard let playerNode, let format = audioFormat else { return }

        var bytes = carry
        bytes.append(data)
        let usable = bytes.count - (bytes.count % 2)
        if usable < bytes.count {
            carry = Data(bytes.suffix(from: usable))
            bytes = Data(bytes.prefix(usable))
        } else {
            carry = Data()
        }
        guard usable >= 2 else { return }

        let sampleCount = usable / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let channel = buffer.floatChannelData?[0] else { return }

        bytes.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                channel[i] = Float(src[i]) / Float(Int16.max)
            }
        }

        pendingBuffers += 1
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                self.checkDrain()
            }
        }

        if !didStartAudio {
            didStartAudio = true
        }
    }

    private func checkDrain() {
        guard receivedEnd, pendingBuffers == 0, !settled else { return }
        // Pequeno folga para o hardware drenar o último buffer.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.settle(.done)
        }
    }

    private func settle(_ outcome: Outcome) {
        guard !settled else { return }
        settled = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
        audioFormat = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: outcome)
    }
}
