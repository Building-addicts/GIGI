import Foundation

extension Notification.Name {
    static let gigiHarnessPairingDidChange = Notification.Name("gigiHarnessPairingDidChange")
}

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
            case .notConfigured: return "Harness not configured (URL/secret missing)"
            case .badResponse(let s, let b): return "HTTP \(s): \(Self.summarize(body: b, status: s))"
            case .decodeFailed(let e): return "decode: \(e.localizedDescription)"
            case .transport(let e):
                if Self.isLocalNetworkProhibited(e) {
                    return "network: Local Network permission denied. Enable Local Network for GIGI in iOS Settings."
                }
                return "network: \(e.localizedDescription)"
            case .apiError(let c, let m): return "\(c): \(m)"
            }
        }

        /// Strips HTML tags from a Cloudflare error page so we don't dump
        /// `<!DOCTYPE html><!--[if lt IE 7]>…` in the user UI. Keeps the
        /// short error text (e.g. "Origin DNS error", "Tunnel error") and
        /// adds a hint when the status hints at a stale tunnel URL.
        private static func summarize(body: String, status: Int) -> String {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            // If response wasn't HTML, return the first 200 chars verbatim
            guard trimmed.lowercased().contains("<html") || trimmed.lowercased().hasPrefix("<!doctype") else {
                return String(trimmed.prefix(200))
            }
            // Cloudflare 5xx error pages have <title>...</title> with a clear summary
            if let titleRange = trimmed.range(of: "<title>", options: .caseInsensitive),
               let endRange = trimmed.range(of: "</title>", options: .caseInsensitive),
               titleRange.upperBound < endRange.lowerBound {
                let title = String(trimmed[titleRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if status == 530 || status == 502 || status == 521 || status == 522 {
                    return "\(title) — tunnel not responding, regenerate the QR from localhost:7777/setup"
                }
                return title
            }
            // Fallback: strip tags blindly
            let plain = trimmed.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if status == 530 {
                return "tunnel unreachable (530) — regenerate the QR"
            }
            return String(plain.prefix(160))
        }

        fileprivate static func isLocalNetworkProhibited(_ error: Swift.Error) -> Bool {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorNotConnectedToInternet {
                let text = "\(ns.userInfo)"
                return text.localizedCaseInsensitiveContains("Local network prohibited")
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                let text = "\(underlying.userInfo)"
                return text.localizedCaseInsensitiveContains("Local network prohibited")
            }
            return false
        }
    }

    // MARK: - Configuration

    struct Config {
        let baseURL: URL
        let secret: String
        let deviceId: String
    }

    enum HarnessPairingState: Equatable {
        case missingBaseURL
        case invalidBaseURL(String)
        case missingSecret
        case configured(baseURL: URL)

        var isConfigured: Bool {
            if case .configured = self { return true }
            return false
        }

        var debugLabel: String {
            switch self {
            case .missingBaseURL:
                return "missing base URL"
            case .invalidBaseURL(let raw):
                return "invalid base URL: \(raw)"
            case .missingSecret:
                return "missing secret"
            case .configured(let baseURL):
                return "configured: \(baseURL.absoluteString)"
            }
        }
    }

    private struct PairingSnapshot {
        let state: HarnessPairingState
        let baseURL: URL?
        let secret: String?
    }

    private static func pairingSnapshot() -> PairingSnapshot {
        guard let rawURL = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            return PairingSnapshot(state: .missingBaseURL, baseURL: nil, secret: nil)
        }

        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return PairingSnapshot(state: .invalidBaseURL(rawURL), baseURL: nil, secret: nil)
        }

        guard let secret = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            return PairingSnapshot(state: .missingSecret, baseURL: url, secret: nil)
        }

        return PairingSnapshot(state: .configured(baseURL: url), baseURL: url, secret: secret)
    }

    var pairingState: HarnessPairingState { Self.pairingSnapshot().state }

    /// Full base URL of the paired harness, or nil if not configured.
    /// Used by `HarnessStatusCard` to expose "Copy full URL" without
    /// stretching access to the secret.
    var pairedBaseURL: URL? { Self.pairingSnapshot().baseURL }

    private var cfg: Config? {
        let snapshot = Self.pairingSnapshot()
        guard snapshot.state.isConfigured,
              let url = snapshot.baseURL,
              let secret = snapshot.secret else { return nil }
        let deviceId = GigiKeychain.load(forKey: GigiKeychain.Key.harnessDeviceID) ?? Self.ensureDeviceId()
        return Config(baseURL: url, secret: secret, deviceId: deviceId)
    }

    var isConfigured: Bool { pairingState.isConfigured }

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

    func agentRun(
        text: String,
        domain: String? = nil,
        schema: String? = nil,
        stream: Bool = false
    ) async -> Result<AgentResult, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        var body: [String: Any] = ["deviceId": c.deviceId, "text": text, "stream": stream]
        if let d = domain { body["domain"] = d }
        if let s = schema { body["schema"] = s }
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

    // MARK: - Diagnostics (Phase 6 — diagnostic-driven pair flow)

    /// One row of the diagnostics report. Mirrors checks.js CheckResult.
    struct DiagnosticsCheck: Decodable, Identifiable, Equatable {
        let id: String
        let label: String
        let severity: String      // "critical" | "warning" | "info"
        let ok: Bool
        let hint: String?
        let action: String?
        // Whether the harness has a registered auto-fixer for this id.
        // Defaults to false on older harness builds via Decodable.
        let autoFixable: Bool?
    }

    // MARK: - Autofix (P6.10/6.11)

    struct AutofixOneResult: Decodable, Equatable {
        let id: String
        let fixed: Bool
        let detail: String?
        let needsUser: String?
        let needsRepair: Bool?
        let error: String?
    }

    struct AutofixSummary: Decodable, Equatable {
        let fixedCount: Int
        let needsUserCount: Int
        let errorCount: Int
        let total: Int
        let elapsed_ms: Int
    }

    struct AutofixReport: Decodable, Equatable {
        let results: [AutofixOneResult]
        let summary: AutofixSummary
    }

    /// POST /api/setup/autofix with the given checkIds. Use `["all"]` to
    /// run every registered fixer.
    func autofix(checkIds: [String]) async -> Result<AutofixReport, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        return await postJSON(
            path: "/api/setup/autofix",
            body: ["checkIds": checkIds],
            as: AutofixReport.self,
            cfg: c
        )
    }

    /// Clears the pair fully — used after a secret rotation autofix that
    /// returned needsRepair:true. The iOS app then prompts the user to
    /// scan a fresh QR.
    func clearPair() {
        GigiKeychain.delete(forKey: GigiKeychain.Key.harnessBaseURL)
        GigiKeychain.delete(forKey: GigiKeychain.Key.harnessSecret)
        lastDiagnostics = nil
        lastDiagnosticsAt = nil
    }

    struct DiagnosticsCounts: Decodable, Equatable {
        struct Pair: Decodable, Equatable { let ok: Int; let total: Int }
        let critical: Pair
        let warning: Pair
        let info: Pair
    }

    struct DiagnosticsSummary: Decodable, Equatable {
        let allCriticalOk: Bool
        let counts: DiagnosticsCounts
    }

    struct DiagnosticsReport: Decodable, Equatable {
        let generatedAt: String
        let elapsedMs: Int
        let summary: DiagnosticsSummary
        let checks: [DiagnosticsCheck]
    }

    /// Calls `GET /api/setup/diagnostics`. The harness caches its own
    /// response for 5s — pass `forceRefresh: true` to bypass.
    func diagnostics(forceRefresh: Bool = false) async -> Result<DiagnosticsReport, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        let path = forceRefresh ? "/api/setup/diagnostics?refresh=1" : "/api/setup/diagnostics"
        return await getJSON(path: path, as: DiagnosticsReport.self, cfg: c)
    }

    /// Snapshot of the most recent diagnostics report. Set by the
    /// SetupDiagnosticView poll loop; consumed by `isReady`. Stays nil
    /// until the first successful diagnostic call after pair.
    private(set) var lastDiagnostics: DiagnosticsReport?
    private var lastDiagnosticsAt: Date?

    /// Updates the in-memory snapshot. Called by the diagnostic view on
    /// each successful poll. The TTL pattern (5min) is enforced by the
    /// `isReady` reader rather than by us discarding old reports.
    func cacheDiagnostics(_ report: DiagnosticsReport) {
        lastDiagnostics = report
        lastDiagnosticsAt = Date()
    }

    /// True iff the harness is paired AND the last diagnostics snapshot
    /// (taken within the last 5 minutes) reports allCriticalOk == true.
    /// Used by MainTabView to hide the "Connect to your harness" banner
    /// and by the chat input gate.
    var isReady: Bool {
        guard isConfigured,
              let snap = lastDiagnostics,
              let at = lastDiagnosticsAt,
              Date().timeIntervalSince(at) < 5 * 60
        else { return false }
        return snap.summary.allCriticalOk
    }

    func health() async -> Result<HealthInfo, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        return await getJSON(path: "/api/ios/health", as: HealthInfo.self, cfg: c)
    }

    /// Boolean wrapper around `health()` for the reachability monitor.
    func pingHealth() async -> Bool {
        if case .success = await health() { return true }
        return false
    }

    // MARK: - Status snapshot (Phase 6C — rich Settings card)

    struct StatusSnapshot: Decodable, Equatable {
        let tunnelMode: String
        let publicUrlRedacted: String?
        let lastRequestAt: String?
        let requestsLastHour: Int
        let uptimeSeconds: Int
    }

    /// GET /api/ios/status — used by `HarnessStatusCard` in Settings.
    func statusSnapshot() async -> Result<StatusSnapshot, Error> {
        guard let c = cfg else { return .failure(.notConfigured) }
        return await getJSON(path: "/api/ios/status", as: StatusSnapshot.self, cfg: c)
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

        let backoffs: [UInt64] = [0, 1_000, 2_000, 4_000]    // ms — exponential 1s/2s/4s per #16 AC
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
                if Self.Error.isLocalNetworkProhibited(error) {
                    return .failure(lastError)
                }
                continue
            }
        }
        return .failure(lastError)
    }

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
    private var streamFailures = 0
    private var lastFailureLogAt: Date?

    /// Heartbeat period. Cloudflare Tunnel free tier closes idle WebSockets
    /// after 100s; 60s leaves a comfortable margin. Tailscale and LAN don't
    /// enforce idle limits but the extra ping is cheap and harmless.
    private let pingIntervalSec: UInt64 = 60
    private var pingTask: Task<Void, Never>?
    private var missedPongs = 0

    func connect(onEvent: @escaping EventHandler, resetBackoff: Bool = true) {
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
        startHeartbeat()
        if resetBackoff {
            reconnectMs = 500
            streamFailures = 0
            lastFailureLogAt = nil
        }
    }

    func disconnect() {
        keepOpen = false
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Heartbeat (Cloudflare-friendly keepalive)

    private func startHeartbeat() {
        stopHeartbeat()
        missedPongs = 0
        pingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.keepOpen, self.task != nil {
                try? await Task.sleep(nanoseconds: self.pingIntervalSec * 1_000_000_000)
                guard !Task.isCancelled, self.keepOpen, let t = self.task else { return }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    t.sendPing { [weak self] error in
                        guard let self else { cont.resume(); return }
                        if error != nil {
                            self.missedPongs += 1
                            GigiDebugLogger.log("GigiHarnessStream ping failed · miss=\(self.missedPongs)")
                            if self.missedPongs >= 2 {
                                self.reconnect()
                            }
                        } else {
                            self.missedPongs = 0
                        }
                        cont.resume()
                    }
                }
            }
        }
    }

    private func stopHeartbeat() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func reconnect() {
        guard keepOpen else { return }
        let handler = onEvent
        disconnect()
        keepOpen = true
        if let h = handler { connect(onEvent: h, resetBackoff: false) }
    }

    private func readLoop() async {
        guard let t = task else { return }
        while t === task, keepOpen {
            do {
                let msg = try await t.receive()
                streamFailures = 0
                lastFailureLogAt = nil
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
                streamFailures += 1
                if shouldLogStreamFailure() {
                    let detail = GigiHarnessClient.Error.isLocalNetworkProhibited(error)
                        ? "Local Network permission denied"
                        : error.localizedDescription
                    GigiDebugLogger.log("GigiHarnessStream recv error: \(detail) · failure=\(streamFailures) nextRetryMs=\(reconnectMs)")
                }
                if GigiHarnessClient.Error.isLocalNetworkProhibited(error) {
                    keepOpen = false
                    stopHeartbeat()
                    task?.cancel(with: .goingAway, reason: nil)
                    task = nil
                    return
                }
                if keepOpen {
                    try? await Task.sleep(nanoseconds: reconnectMs * 1_000_000)
                    reconnectMs = min(reconnectMs * 2, 30_000)
                    let handler = onEvent
                    disconnect()
                    if let h = handler { connect(onEvent: h, resetBackoff: false) }
                }
                return
            }
        }
    }

    private func shouldLogStreamFailure() -> Bool {
        if streamFailures <= 3 { lastFailureLogAt = Date(); return true }
        let now = Date()
        if let lastFailureLogAt, now.timeIntervalSince(lastFailureLogAt) < 60 {
            return false
        }
        lastFailureLogAt = now
        return true
    }

    private static func makeWebSocketURL() -> URL? {
        guard let baseRaw = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL),
              let baseURL = URL(string: baseRaw) else { return nil }
        let deviceId = GigiHarnessClient.ensureDeviceId()
        var comps = URLComponents()
        comps.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        comps.host = baseURL.host
        comps.port = baseURL.port
        comps.path = "/ws/ios/stream"
        comps.queryItems = [
            URLQueryItem(name: "deviceId", value: deviceId)
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
