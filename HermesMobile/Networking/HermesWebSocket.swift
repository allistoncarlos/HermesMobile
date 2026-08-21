import Foundation

// ============================================================================
//  HermesWebSocket — cliente JSON-RPC 2.0 sobre WebSocket.
//
//  Conecta em /api/ws (o mesmo endpoint que o app desktop e a aba de chat do
//  dashboard usam). Em modo gated usa ?ticket= (single-use); em loopback
//  pode usar header X-Hermes-Session-Token / ?token=.
// ============================================================================

/// Um evento de streaming emitido pelo servidor durante um turno.
struct HermesEvent: Equatable {
    let type: String
    let sessionID: String
    let payload: JSONValue
}

/// Erro retornado pelo servidor numa requisição JSON-RPC.
struct RPCError: Error, CustomStringConvertible, LocalizedError {
    let code: Int
    let message: String
    var description: String { "\(message) (código \(code))" }
    var errorDescription: String? { description }
}

/// Erro de transporte/parse.
struct WSClientError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class HermesWebSocket: @unchecked Sendable {

    private let url: URL
    private let sessionToken: String?
    private let urlSession: URLSession

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var nextID: Int = 1
    private var continuations: [Int: CheckedContinuation<Result<JSONValue, Error>, Never>] = [:]
    private var reading = false
    private var didClose: (() -> Void)?

    /// Chamado para cada evento de streaming recebido (contexto: thread de leitura).
    var onEvent: ((HermesEvent) -> Void)?

    /// Chamado quando a conexão encerra por qualquer motivo.
    var onClose: (() -> Void)?

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return task?.state == .running
    }

    init(url: URL, sessionToken: String? = nil, urlSession: URLSession = .shared) {
        self.url = url
        self.sessionToken = sessionToken
        self.urlSession = urlSession
    }


    /// Abre o WebSocket e inicia o loop de leitura.
    func connect() throws {
        var request = URLRequest(url: url)
        if let token = sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        request.timeoutInterval = 30

        let wsTask = urlSession.webSocketTask(with: request)
        lock.lock()
        self.task = wsTask
        self.reading = true
        self.didClose = onClose
        lock.unlock()
        wsTask.resume()
        startPingLoop()

        Task.detached { [weak self] in
            await self?.readLoop()
        }
    }

    /// Keepalive: evita idle timeout do proxy/SO enquanto o app está em background.
    private func startPingLoop() {
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self else { return }
                self.lock.lock()
                let t = self.task
                let alive = t?.state == .running
                self.lock.unlock()
                guard alive, let t else { return }
                t.sendPing { _ in }
            }
        }
    }

    private func readLoop() async {
        while true {
            let t: URLSessionWebSocketTask?
            lock.lock(); t = task; lock.unlock()
            guard let t, t.state == .running else { break }

            do {
                let message = try await t.receive()
                switch message {
                case .string(let text):
                    handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handle(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                break
            }
        }

        lock.lock()
        reading = false
        let pending = continuations
        continuations.removeAll()
        let close = didClose
        lock.unlock()

        let err = WSClientError(message: "Conexão encerrada.")
        for (_, cont) in pending {
            cont.resume(returning: .failure(err))
        }
        close?()
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = obj.objectValue else {
            return
        }

        // Resposta a uma requisição nossa (tem "id").
        if let idValue = object["id"], idValue != .null,
           let id = idValue.number.map(Int.init) {
            if let result = object["result"] {
                resolve(id: id, result: .success(result))
            } else if let err = object["error"]?.objectValue {
                let code = err["code"]?.number.map(Int.init) ?? -1
                let msg = err["message"]?.stringValue ?? "Erro desconhecido"
                resolve(id: id, result: .failure(RPCError(code: code, message: msg)))
            }
            return
        }

        // Evento de streaming.
        if object["method"]?.stringValue == "event",
           let params = object["params"]?.objectValue {
            let type = params["type"]?.stringValue ?? ""
            let sessionID = params["session_id"]?.stringValue ?? ""
            let payload = params["payload"] ?? .null
            onEvent?(HermesEvent(type: type, sessionID: sessionID, payload: payload))
        }
    }


    /// Envia uma requisição JSON-RPC e aguarda a resposta (corresponde ao `id`).
    /// - Parameter timeoutSeconds: se > 0, falha com timeout em vez de esperar para sempre
    ///   (importante em uploads grandes de anexo).
    @discardableResult
    func call(
        method: String,
        params: [String: JSONValue] = [:],
        timeoutSeconds: TimeInterval = 0
    ) async throws -> JSONValue {
        let id: Int
        lock.lock()
        guard let task, reading else {
            lock.unlock()
            throw WSClientError(message: "WebSocket desconectado.")
        }
        id = nextID
        nextID += 1
        lock.unlock()

        // Encode em background — payloads de anexo (base64) travam a UI no MainActor.
        let text = try await Task.detached(priority: .userInitiated) {
            let request: JSONValue = .object([
                "jsonrpc": .string("2.0"),
                "id": .number(Double(id)),
                "method": .string(method),
                "params": .object(params),
            ])
            let data = try JSONEncoder().encode(request)
            guard let text = String(data: data, encoding: .utf8) else {
                throw WSClientError(message: "Não foi possível codificar a mensagem.")
            }
            return text
        }.value

        if timeoutSeconds <= 0 {
            return try await sendAndWait(id: id, text: text)
        }

        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await self.sendAndWait(id: id, text: text)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self.resolve(
                    id: id,
                    result: .failure(WSClientError(message: "Tempo esgotado ao chamar \(method)."))
                )
                throw WSClientError(message: "Tempo esgotado ao chamar \(method).")
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func sendAndWait(id: Int, text: String) async throws -> JSONValue {
        try await withCheckedContinuation { (cont: CheckedContinuation<Result<JSONValue, Error>, Never>) in
            lock.lock()
            continuations[id] = cont
            let t = self.task
            lock.unlock()
            guard let t else {
                self.resolve(id: id, result: .failure(WSClientError(message: "WebSocket desconectado.")))
                return
            }
            t.send(.string(text)) { error in
                if let error {
                    self.resolve(id: id, result: .failure(error))
                }
            }
        }.get()
    }

    private func resolve(id: Int, result: Result<JSONValue, Error>) {
        lock.lock()
        guard let cont = continuations.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        cont.resume(returning: result)
    }

    func disconnect() {
        lock.lock()
        reading = false
        let t = task
        task = nil
        didClose = nil
        lock.unlock()
        t?.cancel(with: .goingAway, reason: nil)
    }

    deinit {
        task?.cancel(with: .goingAway, reason: nil)
    }
}
