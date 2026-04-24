import Foundation

// MARK: - GigiHarnessClient
//
// HTTP+WS client verso il backend 03_HARNESS (Node). Legge configurazione
// (baseURL + Bearer secret + deviceId) da Keychain. Retry esponenziale (3
// tentativi: 0.5s, 1s, 2s) su errori di rete. Se Keychain non è configurato,
// i metodi ritornano .failure(.notConfigured) senza toccare la rete.
//
// Endpoints gestiti (vedi server/api/ios-router.js):
//   POST /api/ios/agent/run        agentRun
//   POST /api/ios/agent/cancel     agentCancel
//   GET  /api/ios/session          sessionStatus
//   POST /api/ios/session/reset    sessionReset
//   POST /api/ios/memo             memoSnapshot
//   POST /api/ios/memory/put       memoryPut
//   POST /api/ios/memory/query     memoryQuery
//   DELETE /api/ios/memory/:id     memoryDelete
//   POST /api/ios/computer-use     computerUseStart
//   GET  /api/ios/computer-use/:id computerUseStatus
//   POST /api/ios/computer-use/:id/confirm computerUseConfirm
//   POST /api/ios/push/register    pushRegister
//   POST /api/ios/push/unregister  pushUnregister
//   WS   /ws/ios/stream            streamConnect
//   GET  /api/ios/health           health
//
// WebSocket (URLSessionWebSocketTask) per interim thoughts + tool calls in
// streaming. Riconnette su disconnect con exp backoff.

@MainActor
final class GigiHarnessClient {
    static let shared = GigiHarnessClient()
    private init() {}

    enum Error: Swift.Error, CustomStringConvertible {
        case notConfigured
        case badResponse(Int, String)
        case decodeFailed(Swift.Error)
        case transport(Swift.Error)
        case apiError(String, String)   // (code, message)

        var description: String {
            switch self {
            case .notConfigured: return "Harness non configurato (URL/secret mancanti)"
            case .badResponse(let s, let b): return "HTTP \(s): \(b.prefix(200))"
            case .decodeFailed(let e): return "decode: \(e.localizedDescription)"
            case .transport(let e):    return "network: \(e.localizedDescription)"
            case .apiError(let c, let m): return "\(c): \(m)"
            }
        }
    }

    // MARK: - Configuration

    struct Config {
        let baseURL: URL
        let secret: String
        let deviceId: String
    }

    private var cfg: Config? {
        guard let raw = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL),
              let url = URL(string: raw),
              let secret = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret),
              !secret.isEmpty else { return nil }
        let deviceId = GigiKeychain.load(forKey: GigiKeychain.Key.harnessDeviceID) ?? Self.ensureDeviceId()
        return Config(baseURL: url, secret: secret, deviceId: deviceId)
    }

    var isConfigured: Bool { cfg != nil }

    static func ensureDeviceId() -> String {
        if let existing = GigiKeychain.load(forKey: GigiKeychain.Key.harnessDeviceID), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        GigiKeychain.save(fresh, forKey: GigiKeychain.Key.harnessDeviceID)
        return fresh
    }

    // MARK: - Public API

    struct AgentResult: Decodable {
        let result: String
        let session_id: String?
        let session_new: Bool?
        let runId: String?
        let usage: AnthropicUsage?
    }

    struct AnthropicUsage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
    }

    func agentRun(text: String, stream: Bool = false) async -> Result<AgentResult, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        let body: [String: Any] = ["deviceId": c.deviceId, "text": text, "stream": stream]
        return await postJSON(path: "/api/ios/agent/run", body: body, as: AgentResult.self, cfg: c)
    }

    func agentCancel(runId: String) async -> Result<Bool, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        let body: [String: Any] = ["deviceId": c.deviceId, "runId": runId]
        struct Payload: Decodable { let cancelled: Bool }
        let r: Result<Payload, Error> = await postJSON(path: "/api/ios/agent/cancel", body: body, as: Payload.self, cfg: c)
        return r.map { $0.cancelled }
    }

    struct SessionInfo: Decodable {
        let active: Bool
        let session_id: String?
        let last_active_at: Int64?
        let started_at: Int64?
    }

    func sessionStatus() async -> Result<SessionInfo, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        return await getJSON(path: "/api/ios/session?deviceId=\(c.deviceId.urlEncoded)", as: SessionInfo.self, cfg: c)
    }

    func sessionReset() async -> Result<Bool, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        struct Payload: Decodable { let reset: Bool }
        let r: Result<Payload, Error> = await postJSON(path: "/api/ios/session/reset", body: ["deviceId": c.deviceId], as: Payload.self, cfg: c)
        return r.map { $0.reset }
    }

    func memoSnapshot(reason: String = "manual") async -> Result<Bool, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        struct Payload: Decodable { let ok: Bool }
        let r: Result<Payload, Error> = await postJSON(path: "/api/ios/memo", body: ["deviceId": c.deviceId, "reason": reason], as: Payload.self, cfg: c)
        return r.map { $0.ok }
    }

    struct MemoryEntry: Decodable {
        let id: String
        let userId: String
        let text: String
        let tags: [String]
        let ts: Int64
        let score: Double?
    }

    func memoryPut(text: String, tags: [String] = []) async -> Result<MemoryEntry, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        let body: [String: Any] = ["deviceId": c.deviceId, "text": text, "tags": tags]
        return await postJSON(path: "/api/ios/memory/put", body: body, as: MemoryEntry.self, cfg: c)
    }

    func memoryQuery(_ q: String, limit: Int = 10) async -> Result<[MemoryEntry], Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        struct Payload: Decodable { let results: [MemoryEntry] }
        let body: [String: Any] = ["deviceId": c.deviceId, "q": q, "limit": limit]
        let r: Result<Payload, Error> = await postJSON(path: "/api/ios/memory/query", body: body, as: Payload.self, cfg: c)
        return r.map { $0.results }
    }

    func memoryDelete(id: String) async -> Result<Bool, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        let path = "/api/ios/memory/\(id.urlEncoded)?deviceId=\(c.deviceId.urlEncoded)"
        struct Payload: Decodable { let removed: Bool }
        let r: Result<Payload, Error> = await sendJSON(method: "DELETE", path: path, body: nil, as: Payload.self, cfg: c)
        return r.map { $0.removed }
    }

    struct ComputerUseJob: Decodable {
        let id: String
        let deviceId: String
        let task: String
        let status: String
        let created_at: Int64
        let updated_at: Int64
        let confirm_required: ConfirmDetails?
        let result: String?
        let error: String?
        struct ConfirmDetails: Decodable {
            let reason: String
            let at: Int64
        }
    }

    func computerUseStart(task: String) async -> Result<String, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        struct Payload: Decodable { let jobId: String }
        let body: [String: Any] = ["deviceId": c.deviceId, "task": task]
        let r: Result<Payload, Error> = await postJSON(path: "/api/ios/computer-use", body: body, as: Payload.self, cfg: c)
        return r.map { $0.jobId }
    }

    func computerUseStatus(jobId: String) async -> Result<ComputerUseJob, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        return await getJSON(path: "/api/ios/computer-use/\(jobId.urlEncoded)", as: ComputerUseJob.self, cfg: c)
    }

    func computerUseConfirm(jobId: String, approved: Bool) async -> Result<Bool, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        struct Payload: Decodable { let status: String; let approved: Bool }
        let r: Result<Payload, Error> = await postJSON(path: "/api/ios/computer-use/\(jobId.urlEncoded)/confirm", body: ["approved": approved], as: Payload.self, cfg: c)
        return r.map { $0.approved }
    }

    func pushRegister(apnsToken: String, platform: String = "ios", bundleId: String? = nil) async -> Result<Bool, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        var body: [String: Any] = ["deviceId": c.deviceId, "apnsToken": apnsToken, "platform": platform]
        if let b = bundleId { body["bundleId"] = b }
        struct Payload: Decodable { let registered: Bool }
        let r: Result<Payload, Error> = await postJSON(path: "/api/ios/push/register", body: body, as: Payload.self, cfg: c)
        return r.map { $0.registered }
    }

    func pushUnregister() async -> Result<Bool, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        struct Payload: Decodable { let unregistered: Bool }
        let r: Result<Payload, Error> = await postJSON(path: "/api/ios/push/unregister", body: ["deviceId": c.deviceId], as: Payload.self, cfg: c)
        return r.map { $0.unregistered }
    }

    struct HealthInfo: Decodable { let pid: Int; let uptime_s: Int }

    func health() async -> Result<HealthInfo, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        return await getJSON(path: "/api/ios/health", as: HealthInfo.self, cfg: c)
    }

    // MARK: - Transport

    private func getJSON<T: Decodable>(path: String, as: T.Type, cfg: Config) async -> Result<T, Error> {
        await sendJSON(method: "GET", path: path, body: nil, as: T.self, cfg: cfg)
    }

    private func postJSON<T: Decodable>(path: String, body: [String: Any], as: T.Type, cfg: Config) async -> Result<T, Error> {
        let data = (try? JSONSerialization.data(withJSONObject: body))
        return await sendJSON(method: "POST", path: path, body: data, as: T.self, cfg: cfg)
    }

    private func sendJSON<T: Decodable>(method: String, path: String, body: Data?, as: T.Type, cfg: Config) async -> Result<T, Error> {
        guard let url = URL(string: path, relativeTo: cfg.baseURL) else {
            return .failure(.badResponse(0, "URL non valido"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let backoffs: [UInt64] = [0, 500, 1_000, 2_000]    // ms — primo tentativo senza attesa, poi 0.5s, 1s, 2s
        var lastError: Error = .transport(URLError(.unknown))

        for delayMs in backoffs {
            if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
            do {
                let (respData, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    lastError = .badResponse(0, "risposta non HTTP")
                    continue
                }
                if http.statusCode >= 500 {
                    lastError = .badResponse(http.statusCode, String(data: respData, encoding: .utf8) ?? "")
                    continue    // retry 5xx
                }
                return Self.decodeEnvelope(respData, as: T.self, status: http.statusCode)
            } catch {
                lastError = .transport(error)
                continue
            }
        }
        return .failure(lastError)
    }

    /// Risposta JSON comune dal server (`{ ok, data?, error? }`). Non può stare dentro
    /// `decodeEnvelope` perché Swift vieta tipi generici annidati in funzioni generiche.
    private struct Envelope<D: Decodable>: Decodable {
        let ok: Bool
        let data: D?
        let error: ErrorDetail?
        struct ErrorDetail: Decodable { let code: String; let message: String }
    }

    private static func decodeEnvelope<T: Decodable>(_ data: Data, as: T.Type, status: Int) -> Result<T, Error> {
        do {
            let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
            if env.ok, let d = env.data { return .success(d) }
            if let e = env.error { return .failure(.apiError(e.code, e.message)) }
            return .failure(.badResponse(status, String(data: data, encoding: .utf8) ?? ""))
        } catch {
            return .failure(.decodeFailed(error))
        }
    }
}

// MARK: - WebSocket stream

@MainActor
final class GigiHarnessStream: NSObject {
    typealias EventHandler = (_ event: [String: Any]) -> Void

    private var task: URLSessionWebSocketTask?
    private var onEvent: EventHandler?
    private var keepOpen = false
    private var reconnectMs: UInt64 = 500

    func connect(onEvent: @escaping EventHandler) {
        guard let wsURL = Self.makeWebSocketURL() else {
            GigiDebugLogger.log("GigiHarnessStream: URL WebSocket non disponibile")
            return
        }
        self.onEvent = onEvent
        self.keepOpen = true
        var req = URLRequest(url: wsURL)
        if let secret = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret), !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        task = session.webSocketTask(with: req)
        task?.resume()
        Task { await readLoop() }
        reconnectMs = 500
    }

    func disconnect() {
        keepOpen = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func readLoop() async {
        guard let t = task else { return }
        while t === task, keepOpen {
            do {
                let msg = try await t.receive()
                switch msg {
                case .string(let s):
                    if let d = s.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        onEvent?(obj)
                    }
                case .data(let d):
                    if let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        onEvent?(obj)
                    }
                @unknown default: break
                }
            } catch {
                GigiDebugLogger.log("GigiHarnessStream recv error: \(error.localizedDescription)")
                if keepOpen {
                    try? await Task.sleep(nanoseconds: reconnectMs * 1_000_000)
                    reconnectMs = min(reconnectMs * 2, 30_000)
                    let handler = onEvent
                    disconnect()
                    if let h = handler { connect(onEvent: h) }
                }
                return
            }
        }
    }

    private static func makeWebSocketURL() -> URL? {
        guard let baseRaw = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL),
              let baseURL = URL(string: baseRaw) else { return nil }
        let deviceId = GigiHarnessClient.ensureDeviceId()
        guard let secret = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret) else { return nil }
        var comps = URLComponents()
        comps.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        comps.host = baseURL.host
        comps.port = baseURL.port
        comps.path = "/ws/ios/stream"
        comps.queryItems = [
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "token", value: secret)
        ]
        return comps.url
    }
}

// MARK: - Helpers

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
