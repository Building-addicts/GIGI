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
                        continuation.yield(.error("HTTP \(http.statusCode) from local-llm endpoint"))
                        continuation.finish()
                        return
                    }
                    var currentEvent = ""
                    var currentData = ""
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // Dispatch one SSE event
                            let event = currentEvent.isEmpty ? "chunk" : currentEvent
                            if !currentData.isEmpty {
                                Self.dispatchSSE(event: event, data: currentData, started: started, continuation: continuation)
                            }
                            currentEvent = ""
                            currentData = ""
                        } else if line.hasPrefix("event:") {
                            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let chunk = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            currentData += chunk
                        }
                        // ignore comment lines (start with ":") and other fields
                    }
                    // Flush any remaining event at stream end.
                    if !currentData.isEmpty {
                        Self.dispatchSSE(event: currentEvent.isEmpty ? "chunk" : currentEvent,
                                         data: currentData, started: started, continuation: continuation)
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
                    var currentEvent = ""
                    var currentData = ""
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            if !currentData.isEmpty {
                                Self.dispatchClaudeSSE(
                                    event: currentEvent.isEmpty ? "unknown" : currentEvent,
                                    data: currentData,
                                    started: started,
                                    continuation: continuation
                                )
                            }
                            currentEvent = ""
                            currentData = ""
                        } else if line.hasPrefix("event:") {
                            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            currentData += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        }
                    }
                    if !currentData.isEmpty {
                        Self.dispatchClaudeSSE(
                            event: currentEvent.isEmpty ? "unknown" : currentEvent,
                            data: currentData,
                            started: started,
                            continuation: continuation
                        )
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
            return try? JSONDecoder().decode(LocalLLMStatus.self, from: data)
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
