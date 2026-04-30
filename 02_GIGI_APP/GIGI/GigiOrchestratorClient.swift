import Foundation
import os.log

// MARK: - GigiOrchestratorClient
//
// Direct iOS → cloud LLM router (no harness, no proxy). Sends a transcript
// and contact roster to the chosen provider, receives back a single line
// matching the marker grammar (CALL: / SMS: / SYS: / OPEN: / plain text).
//
// Provider pick + system prompt v1 documented in
// docs/research/orchestrator-llm-pick.md. Default Groq llama-3.3-70b
// (~150-300 ms P50). Anthropic Haiku swappable as fallback.
//
// Error policy: fail loud. No retry on a routing call — the user spoke
// once; a retry only adds latency. On failure, callers surface a plain
// "Couldn't reach GIGI" via the Confirm intent.

@available(iOS 16.0, *)
enum GigiOrchestratorClient {

    enum Provider: String {
        case groq
        case anthropic
    }

    enum ClientError: LocalizedError {
        case missingAPIKey(Provider)
        case invalidResponse
        case httpError(Int, String)
        case emptyMarker

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let p): return "Missing API key for \(p.rawValue)"
            case .invalidResponse:      return "Orchestrator returned invalid response"
            case .httpError(let code, let body): return "Orchestrator HTTP \(code): \(body.prefix(120))"
            case .emptyMarker:          return "Orchestrator returned empty output"
            }
        }
    }

    struct Contact {
        let name: String
        let phone: String  // E.164
        let lastContacted: Date?
    }

    static let logger = Logger(subsystem: "com.killsiri.GIGI", category: "orchestrator-client")

    /// Routes a user transcript via the configured LLM. Returns a single
    /// trimmed line: marker (CALL:/SMS:/SYS:/OPEN:) or plain text answer.
    static func route(transcript: String,
                      contacts: [Contact],
                      locale: String = Locale.current.identifier,
                      provider: Provider = .groq,
                      timeout: TimeInterval = 4.0) async throws -> String {
        let systemPrompt = buildSystemPrompt(contacts: contacts, locale: locale)
        switch provider {
        case .groq:
            return try await callGroq(systemPrompt: systemPrompt,
                                      transcript: transcript,
                                      timeout: timeout)
        case .anthropic:
            return try await callAnthropic(systemPrompt: systemPrompt,
                                           transcript: transcript,
                                           timeout: timeout)
        }
    }

    // MARK: - Provider: Groq (OpenAI-compatible)

    private static func callGroq(systemPrompt: String,
                                 transcript: String,
                                 timeout: TimeInterval) async throws -> String {
        guard let key = GigiKeychain.load(forKey: GigiKeychain.Key.groqAPIKey),
              !key.isEmpty else {
            throw ClientError.missingAPIKey(.groq)
        }
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw ClientError.invalidResponse
        }
        let body: [String: Any] = [
            "model": "llama-3.3-70b-versatile",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript]
            ],
            "max_tokens": 100,
            "temperature": 0.0,
            "stop": ["\n"]
        ]
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(started)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.httpError(http.statusCode, payload)
        }
        let marker = try parseOpenAIChat(data: data)
        logger.info("groq.ok elapsed=\(String(format: "%.3f", elapsed), privacy: .public)s marker_len=\(marker.count, privacy: .public)")
        return marker
    }

    // MARK: - Provider: Anthropic Messages API (fallback)

    private static func callAnthropic(systemPrompt: String,
                                      transcript: String,
                                      timeout: TimeInterval) async throws -> String {
        guard let key = GigiKeychain.load(forKey: "anthropic_api_key"),
              !key.isEmpty else {
            throw ClientError.missingAPIKey(.anthropic)
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ClientError.invalidResponse
        }
        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 100,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": transcript]
            ],
            "temperature": 0.0,
            "stop_sequences": ["\n"]
        ]
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(started)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.httpError(http.statusCode, payload)
        }
        let marker = try parseAnthropicMessage(data: data)
        logger.info("anthropic.ok elapsed=\(String(format: "%.3f", elapsed), privacy: .public)s marker_len=\(marker.count, privacy: .public)")
        return marker
    }

    // MARK: - Response parsing

    private static func parseOpenAIChat(data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ClientError.invalidResponse
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ClientError.emptyMarker }
        return trimmed
    }

    private static func parseAnthropicMessage(data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]] else {
            throw ClientError.invalidResponse
        }
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ClientError.emptyMarker }
        return trimmed
    }

    // MARK: - System prompt (v1 from docs/research/orchestrator-llm-pick.md)

    private static func buildSystemPrompt(contacts: [Contact], locale: String) -> String {
        let rosterLines = contacts.prefix(50).map { c -> String in
            let dateStr: String
            if let d = c.lastContacted {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
                dateStr = f.string(from: d)
            } else {
                dateStr = "n/a"
            }
            return "  - \(c.name) | \(c.phone) | \(dateStr)"
        }.joined(separator: "\n")
        let roster = rosterLines.isEmpty ? "  (empty roster)" : rosterLines
        return """
        You are GIGI's command router. The user is speaking to you in English or
        Italian and expects you to either trigger a device action (via marker) or
        answer briefly in plain text.

        Your output is read by a strict parser. Output EXACTLY ONE line, no prefix,
        no explanation, no quotes, no markdown.

        # Marker grammar (preferred when applicable)

        CALL:<E.164 phone>
          - Use when the user wants to call a contact or a phone number.
          - Resolve contact names against the roster below. If multiple matches,
            pick the most-recently contacted; if none, return plain text:
            "No contact named X".

        SMS:<E.164 phone>|<message body in user's language>
          - Use when the user wants to text/send a message.
          - Same resolution rules as CALL. Body keeps original language. Strip the
            leading verb. Body must not contain '|' characters; replace with ', '.

        SYS:<command>:<param>
          - Catalog: torch:on|off, volume:0..100, brightness:0..100, wifi:on|off,
            bluetooth:on|off, airplane:on|off, dnd:on|off, silent:on|off,
            lpm:on|off, screenshot:, music:play|pause|next|prev, weather:,
            location:, alarm:HH:MM

        OPEN:<url scheme>
          - Common: spotify:// instagram:// youtube:// maps:// whatsapp://
          - Search variants: spotify:search:<query> youtube:search:<query>
            amazon:search:<query>

        # Plain text fallback

        If the user is asking a chat-style question (joke, time, fact, opinion,
        follow-up), or the request is ambiguous, output a short plain-text answer
        (≤ 140 characters, in the user's language). Never prefix with "Answer:".

        # Hard rules

        1. Output ONE line. No leading/trailing whitespace. No markdown. No quotes.
        2. If unsure whether a marker fits, prefer plain text.
        3. Never invent phone numbers. If contact resolution fails: "No contact named X".
        4. Never include thoughts. Only the result.
        5. Volumes/brightness must be integers 0-100. Clamp out-of-range.

        # Contact roster

        \(roster)

        # Locale hint

        User spoken language tag: \(locale)
        """
    }
}

// MARK: - Bridge from GigiContactsEngine cache

@available(iOS 16.0, *)
extension GigiOrchestratorClient {
    /// Snapshot of recent contacts for prompt injection. Pulled from
    /// GigiContactsEngine cache; capped to 50 most-recently used so
    /// input tokens stay bounded.
    static func contactSnapshot(limit: Int = 50) async -> [Contact] {
        // Best-effort: GigiContactsEngine doesn't currently expose a
        // bulk getter; return empty for now and let resolution happen
        // post-marker via existing logic. v2 of #147 will plug a real
        // exporter.
        _ = limit
        return []
    }
}
