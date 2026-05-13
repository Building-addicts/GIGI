import Foundation

// MARK: - GigiHarnessClient + Phase 2 streaming
//
// Adds two new streaming endpoints used by the 5-path router:
//   - runLocalLLM  → Path 3 Ollama via SSE on /api/ios/local-llm/generate   (GATE 4)
//   - runClaudeCode → Path 4 Claude Code via WebSocket on /ws/ios/agent/claude (GATE 5)
//
// Both surface typed events through `AsyncStream` so the call site (router)
// can `for await event in ...` and pattern-match cleanly. Cancellation is
// supported via `cancelClaudeCode(runId:)` + AsyncStream termination.

// MARK: - LocalLLMEvent

enum LocalLLMEvent {
    case chunk(String)
    case done(latencyMs: Int)
    case error(String)
}

// MARK: - ClaudeEvent

enum ClaudeEvent {
    case thought(String)
    case toolUse(name: String, args: [String: Any])
    case textResponse(String)
    case confirmRequired(description: String, runId: String)
    case done(latencyMs: Int)
    case error(String)
}

// MARK: - Extension

@MainActor
extension GigiHarnessClient {

    // MARK: - Telemetry (Live Monitor visibility for on-device actions)
    //
    // Bug #012 fix (2026-05-12): native_tool / ask_clarification / reject
    // paths execute on-device and never reach the harness. The harness
    // live monitor at /live.html consequently shows nothing when the user
    // is exercising those paths. This fire-and-forget POST surfaces them.
    //
    // Calls are best-effort: any error is silently dropped so demo flow
    // doesn't slow down or fail because telemetry isn't available.

    /// Send a non-blocking telemetry event to the harness.
    /// The harness logs it as `[ios-telemetry] type · path=... · action=...`
    /// — visible in /live.html in real time.
    func postTelemetry(type: String,
                       path: String,
                       primaryAction: String = "",
                       userText: String = "",
                       elapsedMs: Int? = nil) {
        guard let cfg = Self.harnessConfigSnapshot() else { return }
        let urlString = cfg.baseURL.absoluteString.trimmingTrailingSlash + "/api/ios/telemetry"
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
        req.setValue(cfg.deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 2.0
        var payload: [String: Any] = [
            "type": type,
            "path": path,
            "primaryAction": primaryAction,
            "userText": userText.count > 80 ? String(userText.prefix(80)) : userText
        ]
        if let elapsedMs { payload["elapsedMs"] = elapsedMs }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        // Fire-and-forget — don't await, don't surface errors.
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    // MARK: - Phase 2 — Build Shortcut (Cherri pipeline)

    /// POST a Cherri DSL spec to the harness for compilation + signing on
    /// the Mac. Returns the signed .shortcut URL (hosted by harness with
    /// short TTL) ready to be opened via UIApplication.open(_:). Throws
    /// if harness is unreachable, the Mac signing failed, or the response
    /// is malformed.
    ///
    /// Payload: { title: String, dsl: String }
    /// Response: { url: String } on success, { error: String } on failure
    func postBuildShortcut(payload: [String: Any]) async throws -> [String: Any] {
        guard let cfg = Self.harnessConfigSnapshot() else {
            throw NSError(
                domain: "GigiHarnessClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Harness not paired"]
            )
        }
        let urlString = cfg.baseURL.absoluteString.trimmingTrailingSlash + "/api/ios/build-shortcut"
        guard let url = URL(string: urlString) else {
            throw NSError(
                domain: "GigiHarnessClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid harness URL"]
            )
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
        req.setValue(cfg.deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30.0  // Cherri compile + sign can take 5-10s
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(
                domain: "GigiHarnessClient",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"]
            )
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "GigiHarnessClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"]
            )
        }
        if http.statusCode >= 400 {
            let detail = (parsed["error"] as? String) ?? "HTTP \(http.statusCode)"
            throw NSError(
                domain: "GigiHarnessClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
        return parsed
    }

    // MARK: - Path 3 — Ollama SSE consumer

    /// Streams chunks from the harness Ollama bridge (Path 3).
    /// Endpoint: `POST /api/ios/local-llm/generate` with SSE response.
    func runLocalLLM(prompt: String, history: String = "") -> AsyncStream<LocalLLMEvent> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.yield(.error("client deallocated"))
                    continuation.finish()
                    return
                }
                let snapshot = Self.harnessConfigSnapshot()
                guard let cfg = snapshot else {
                    continuation.yield(.error("harness not paired"))
                    continuation.finish()
                    return
                }

                let urlString = cfg.baseURL.absoluteString.trimmingTrailingSlash + "/api/ios/local-llm/generate"
                guard let url = URL(string: urlString) else {
                    continuation.yield(.error("invalid URL"))
                    continuation.finish()
                    return
                }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                let body: [String: Any] = [
                    "deviceId": cfg.deviceId,
                    "prompt": prompt,
                    "history": history
                ]
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)

                let started = Date()
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        GigiDebugLogger.log("GIGI runLocalLLM HTTP \(http.statusCode)")
                        continuation.yield(.error("HTTP \(http.statusCode) from local-llm endpoint"))
                        continuation.finish()
                        return
                    }
                    // Manual byte-buffer SSE parser (parser=manual-buffer-v1).
                    // Replaces Apple's URLSession.bytes.lines (AsyncLineSequence) because
                    // that API does NOT yield empty lines on CRLF-terminated streams from
                    // Cloudflare Tunnel — verified by 3 reinstalls all showing
                    // chunks emitted=0 with N event:/data: lines and zero empty separators.
                    // mattt/EventSource and Swift Forums SOAR-0010 confirm bytes.lines
                    // is not SSE-spec-compliant; the community uses manual byte parsing.
                    GigiDebugLogger.log("GIGI runLocalLLM connected · parser=manual-buffer-v1 to \(url.absoluteString)")
                    var buffer: [UInt8] = []
                    var totalBytes = 0
                    var chunksEmitted = 0
                    var eventsProcessed = 0

                    let dispatchEvent: ([UInt8]) -> Void = { eventBytes in
                        guard let evt = Self.parseSSEEvent(eventBytes) else { return }
                        eventsProcessed += 1
                        if eventsProcessed <= 10 {
                            GigiDebugLogger.log("GIGI runLocalLLM event[\(eventsProcessed)] name='\(evt.event)' dataLen=\(evt.data.count)")
                        }
                        Self.dispatchSSE(event: evt.event, data: evt.data, started: started, continuation: continuation)
                        if evt.event == "chunk" { chunksEmitted += 1 }
                    }

                    for try await byte in bytes {
                        buffer.append(byte)
                        totalBytes += 1
                        // Detect SSE event boundary at buffer tail (LF×2 or CRLF×2).
                        let n = buffer.count
                        var boundaryLen = 0
                        if n >= 2 && buffer[n-2] == 0x0A && buffer[n-1] == 0x0A {
                            boundaryLen = 2
                        } else if n >= 4
                            && buffer[n-4] == 0x0D && buffer[n-3] == 0x0A
                            && buffer[n-2] == 0x0D && buffer[n-1] == 0x0A {
                            boundaryLen = 4
                        }
                        if boundaryLen > 0 {
                            let eventBytes = Array(buffer[0..<(n - boundaryLen)])
                            buffer.removeAll(keepingCapacity: true)
                            dispatchEvent(eventBytes)
                        }
                    }
                    // Flush trailing event (no terminating boundary at EOF).
                    if !buffer.isEmpty {
                        dispatchEvent(Array(buffer))
                        buffer.removeAll()
                    }
                    GigiDebugLogger.log("GIGI runLocalLLM stream ended · parser=manual-buffer-v1 · bytes=\(totalBytes) events=\(eventsProcessed) chunks emitted=\(chunksEmitted)")
                    continuation.yield(.done(latencyMs: Int(Date().timeIntervalSince(started) * 1000)))
                    continuation.finish()
                } catch {
                    GigiDebugLogger.log("GIGI runLocalLLM EXCEPTION: \(error.localizedDescription)")
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    /// Parse a single SSE event from raw bytes. Spec-compliant: handles LF, CRLF,
    /// multi-line `data:` accumulation, last `event:` header wins, ignores comments.
    /// Returns nil if the chunk is empty or contains no recognizable fields.
    fileprivate static func parseSSEEvent(_ bytes: [UInt8]) -> (event: String, data: String)? {
        guard !bytes.isEmpty, let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        var eventName = ""
        var dataAccum = ""
        for rawLineSub in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            var line = String(rawLineSub)
            if line.hasSuffix("\r") { line = String(line.dropLast()) }
            if line.isEmpty || line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataAccum += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }
        if eventName.isEmpty && dataAccum.isEmpty { return nil }
        return (eventName.isEmpty ? "chunk" : eventName, dataAccum)
    }

    private static func dispatchSSE(
        event: String,
        data: String,
        started: Date,
        continuation: AsyncStream<LocalLLMEvent>.Continuation
    ) {
        // Try JSON first, fall back to raw text.
        let parsed = data.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        switch event {
        case "chunk":
            let text = (parsed?["text"] as? String) ?? data
            continuation.yield(.chunk(text))
        case "done":
            let latency = (parsed?["latencyMs"] as? Int) ?? Int(Date().timeIntervalSince(started) * 1000)
            continuation.yield(.done(latencyMs: latency))
        case "error":
            let msg = (parsed?["message"] as? String) ?? data
            continuation.yield(.error(msg))
        default:
            // Unknown event type: treat as chunk for forward-compat.
            continuation.yield(.chunk(data))
        }
    }

    // MARK: - Path 4 — Claude Code SSE consumer

    /// Streams events from a Claude Code subprocess spawned on the harness.
    /// Endpoint: `POST /api/ios/agent/claude` with SSE response.
    /// On error (endpoint not yet deployed), yields `.error(...)` so the
    /// router falls back to the legacy `GigiClaudeBridge.run()`.
    func runClaudeCode(prompt: String, mcpServers: [String] = []) -> AsyncStream<ClaudeEvent> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.yield(.error("client deallocated"))
                    continuation.finish()
                    return
                }
                guard let cfg = Self.harnessConfigSnapshot() else {
                    continuation.yield(.error("harness not paired"))
                    continuation.finish()
                    return
                }

                let urlString = cfg.baseURL.absoluteString.trimmingTrailingSlash + "/api/ios/agent/claude"
                guard let url = URL(string: urlString) else {
                    continuation.yield(.error("invalid claude URL"))
                    continuation.finish()
                    return
                }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                let payload: [String: Any] = [
                    "deviceId": cfg.deviceId,
                    "prompt": prompt,
                    "mcpServers": mcpServers
                ]
                req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

                let started = Date()
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        continuation.yield(.error("HTTP \(http.statusCode) from claude endpoint"))
                        continuation.finish()
                        return
                    }
                    // Same manual byte-buffer SSE parser as runLocalLLM.
                    var buffer: [UInt8] = []
                    let dispatchEvent: ([UInt8]) -> Void = { eventBytes in
                        guard let evt = Self.parseSSEEvent(eventBytes) else { return }
                        Self.dispatchClaudeSSE(
                            event: evt.event.isEmpty ? "unknown" : evt.event,
                            data: evt.data,
                            started: started,
                            continuation: continuation
                        )
                    }
                    for try await byte in bytes {
                        buffer.append(byte)
                        let n = buffer.count
                        var boundaryLen = 0
                        if n >= 2 && buffer[n-2] == 0x0A && buffer[n-1] == 0x0A {
                            boundaryLen = 2
                        } else if n >= 4
                            && buffer[n-4] == 0x0D && buffer[n-3] == 0x0A
                            && buffer[n-2] == 0x0D && buffer[n-1] == 0x0A {
                            boundaryLen = 4
                        }
                        if boundaryLen > 0 {
                            let eventBytes = Array(buffer[0..<(n - boundaryLen)])
                            buffer.removeAll(keepingCapacity: true)
                            dispatchEvent(eventBytes)
                        }
                    }
                    if !buffer.isEmpty {
                        dispatchEvent(Array(buffer))
                    }
                    continuation.yield(.done(latencyMs: Int(Date().timeIntervalSince(started) * 1000)))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    private static func dispatchClaudeSSE(
        event: String,
        data: String,
        started: Date,
        continuation: AsyncStream<ClaudeEvent>.Continuation
    ) {
        let parsed = data.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        switch event {
        case "thought", "thinking":
            continuation.yield(.thought((parsed?["text"] as? String) ?? data))
        case "tool_use", "toolUse":
            let name = (parsed?["name"] as? String) ?? ""
            let args = (parsed?["args"] as? [String: Any]) ?? [:]
            continuation.yield(.toolUse(name: name, args: args))
        case "text", "textResponse":
            continuation.yield(.textResponse((parsed?["text"] as? String) ?? data))
        case "confirm_required", "confirmRequired":
            let desc = (parsed?["description"] as? String) ?? "Action requires confirmation"
            let runId = (parsed?["runId"] as? String) ?? ""
            continuation.yield(.confirmRequired(description: desc, runId: runId))
        case "done":
            let latency = (parsed?["latencyMs"] as? Int) ?? Int(Date().timeIntervalSince(started) * 1000)
            continuation.yield(.done(latencyMs: latency))
        case "error":
            continuation.yield(.error((parsed?["message"] as? String) ?? data))
        default:
            break
        }
    }

    /// Cancel an in-flight Claude Code run by id.
    func cancelClaudeCode(runId: String) async {
        guard let cfg = Self.harnessConfigSnapshot() else { return }
        let urlString = cfg.baseURL.absoluteString.trimmingTrailingSlash + "/api/ios/agent/claude/cancel"
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["deviceId": cfg.deviceId, "runId": runId]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Probe the Claude Code path readiness. Returns true when the harness
    /// reports `available: true` on `/api/ios/agent/claude-status`. Used by
    /// `GigiModeDetector.probeClaudeCode`.
    func claudeCodeStatus() async -> Bool {
        guard let cfg = Self.harnessConfigSnapshot() else { return false }
        let urlString = cfg.baseURL.absoluteString.trimmingTrailingSlash + "/api/ios/agent/claude-status"
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return false }
            struct Envelope: Decodable { let ok: Bool; let data: Payload? }
            struct Payload: Decodable { let available: Bool }
            let env = try? JSONDecoder().decode(Envelope.self, from: data)
            return env?.data?.available == true
        } catch {
            return false
        }
    }

    /// Confirm or deny a `confirm_required` checkpoint.
    func confirmClaudeCode(runId: String, approved: Bool) async {
        guard let cfg = Self.harnessConfigSnapshot() else { return }
        let urlString = cfg.baseURL.absoluteString.trimmingTrailingSlash + "/api/ios/agent/confirm"
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["deviceId": cfg.deviceId, "runId": runId, "approved": approved]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Local LLM install / fix-automatically (2026-05-12 batch 4)

    struct OllamaInstallStatus: Decodable {
        let cliInstalled: Bool
        let daemonReachable: Bool
        let version: String?
        let installedModels: [String]
        let installedCompatibleModels: [String]
        let compatibleTiers: [String: String]   // tier name → model
        let nextAction: String                  // "install-ollama" | "start-ollama-daemon" | "pull-model" | "ready"
        let hostPlatform: String
    }

    enum OllamaSetupEvent {
        case thought(String)
        case progress(pct: Int, status: String)
        case done(status: String)
        case error(String)
    }

    /// Granular install status: CLI present? daemon reachable? compatible models?
    func ollamaInstallStatus() async -> OllamaInstallStatus? {
        guard let cfg = Self.harnessConfigSnapshot() else { return nil }
        let urlString = cfg.baseURL.absoluteString.trimmingTrailingSlash + "/api/ios/local-llm/install-status"
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
            struct Envelope: Decodable { let ok: Bool; let data: OllamaInstallStatus? }
            return (try? JSONDecoder().decode(Envelope.self, from: data))?.data
        } catch {
            return nil
        }
    }

    /// Install Ollama via platform-native package manager. Streams progress.
    func installOllama() -> AsyncStream<OllamaSetupEvent> {
        ollamaSetupStream(path: "/api/ios/local-llm/install-ollama", body: nil)
    }

    /// Pull a model via `ollama pull`. Streams progress (pct + status).
    func pullOllamaModel(_ model: String) -> AsyncStream<OllamaSetupEvent> {
        ollamaSetupStream(
            path: "/api/ios/local-llm/pull-model",
            body: ["model": model]
        )
    }

    /// Internal SSE consumer for install/pull. Translates server events to
    /// `OllamaSetupEvent` enum.
    private func ollamaSetupStream(path: String, body: [String: Any]?) -> AsyncStream<OllamaSetupEvent> {
        AsyncStream { continuation in
            Task {
                guard let cfg = Self.harnessConfigSnapshot() else {
                    continuation.yield(.error("Harness not paired"))
                    continuation.finish()
                    return
                }
                let urlString = cfg.baseURL.absoluteString.trimmingTrailingSlash + path
                guard let url = URL(string: urlString) else {
                    continuation.yield(.error("Invalid URL"))
                    continuation.finish()
                    return
                }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if let body {
                    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                }
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        continuation.yield(.error("HTTP \(http.statusCode)"))
                        continuation.finish()
                        return
                    }
                    var currentEvent = ""
                    var currentData = ""
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            if !currentData.isEmpty {
                                Self.dispatchOllamaEvent(event: currentEvent, data: currentData, continuation: continuation)
                            }
                            currentEvent = ""
                            currentData = ""
                        } else if line.hasPrefix("event:") {
                            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            currentData += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    private static func dispatchOllamaEvent(event: String, data: String, continuation: AsyncStream<OllamaSetupEvent>.Continuation) {
        let parsed = data.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        switch event {
        case "thought":
            continuation.yield(.thought((parsed?["text"] as? String) ?? data))
        case "progress":
            let pct = (parsed?["pct"] as? Int) ?? 0
            let status = (parsed?["status"] as? String) ?? ""
            continuation.yield(.progress(pct: pct, status: status))
        case "done":
            continuation.yield(.done(status: (parsed?["status"] as? String) ?? "done"))
        case "error":
            continuation.yield(.error((parsed?["message"] as? String) ?? data))
        default:
            break
        }
    }

    // MARK: - Local LLM status / hardware probe

    struct LocalLLMStatus: Decodable {
        let reachable: Bool
        let models: [String]?
        let currentTier: String?
    }

    func localLLMStatus() async -> LocalLLMStatus? {
        guard let cfg = Self.harnessConfigSnapshot() else { return nil }
        let urlString = cfg.baseURL.absoluteString.trimmingTrailingSlash + "/api/ios/local-llm/status"
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(cfg.secret)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
            // 2026-05-12 fix: server response is wrapped in {"ok":true,"data":{...}}.
            // Previous code tried to decode LocalLLMStatus from the top-level,
            // which failed silently → ollamaStatus stayed nil → Settings showed
            // "No data — tap refresh" while the install-status badge (which
            // properly unwraps Envelope) showed "Ollama ready". Now unified.
            struct Envelope: Decodable { let ok: Bool; let data: LocalLLMStatus? }
            return (try? JSONDecoder().decode(Envelope.self, from: data))?.data
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    fileprivate struct HarnessCfgSnapshot {
        let baseURL: URL
        let secret: String
        let deviceId: String
    }

    fileprivate static func harnessConfigSnapshot() -> HarnessCfgSnapshot? {
        guard let raw = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL),
              let url = URL(string: raw),
              let secret = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret),
              !secret.isEmpty else {
            return nil
        }
        let deviceId = GigiKeychain.load(forKey: GigiKeychain.Key.harnessDeviceID) ?? GigiHarnessClient.ensureDeviceId()
        return HarnessCfgSnapshot(baseURL: url, secret: secret, deviceId: deviceId)
    }
}

// MARK: - String helper

private extension String {
    var trimmingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
