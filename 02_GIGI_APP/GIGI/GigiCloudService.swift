import Foundation

// MARK: - JSONAny — arbitrary JSON value

struct JSONAny: Codable {
    nonisolated(unsafe) let value: Any

    nonisolated init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self)             { value = s; return }
        if let d = try? c.decode(Double.self)             { value = d; return }
        if let b = try? c.decode(Bool.self)               { value = b; return }
        if let arr = try? c.decode([JSONAny].self)        { value = arr.map(\.value); return }
        if let obj = try? c.decode([String: JSONAny].self){ value = obj.mapValues(\.value); return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String: try c.encode(s)
        case let i as Int:    try c.encode(i)
        case let d as Double: try c.encode(d)
        case let b as Bool:   try c.encode(b)
        default:              try c.encodeNil()
        }
    }
}

// MARK: - Multi-turn content types (internal format, persisted)

struct FunctionCallBlock: Codable {
    let name: String
    let args: [String: JSONAny]

    var asArgs: [String: Any] { args.mapValues(\.value) }
}

struct FunctionCallPayload: Codable {
    let name: String
    let args: [String: JSONAny]
}

struct FunctionResponsePayload: Codable {
    let name: String
    let response: [String: String]
}

struct GigiPart: Codable {
    let text: String?
    let functionCall: FunctionCallPayload?
    let functionResponse: FunctionResponsePayload?

    static func text(_ t: String) -> GigiPart {
        GigiPart(text: t, functionCall: nil, functionResponse: nil)
    }

    static func functionCall(_ block: FunctionCallBlock) -> GigiPart {
        GigiPart(text: nil,
                 functionCall: FunctionCallPayload(name: block.name, args: block.args),
                 functionResponse: nil)
    }

    static func functionResponse(name: String, result: String) -> GigiPart {
        GigiPart(text: nil, functionCall: nil,
                 functionResponse: FunctionResponsePayload(name: name, response: ["result": result]))
    }

    enum CodingKeys: String, CodingKey { case text, functionCall, functionResponse }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let t  = text             { try c.encode(t,  forKey: .text) }
        if let fc = functionCall     { try c.encode(fc, forKey: .functionCall) }
        if let fr = functionResponse { try c.encode(fr, forKey: .functionResponse) }
    }
}

struct GigiContent: Codable {
    let role: String   // "user" | "model"
    let parts: [GigiPart]

    static func user(_ text: String) -> GigiContent {
        GigiContent(role: "user", parts: [.text(text)])
    }

    static func model(functionCalls: [FunctionCallBlock]) -> GigiContent {
        GigiContent(role: "model", parts: functionCalls.map { .functionCall($0) })
    }

    static func toolResults(_ results: [(name: String, value: String, error: String?)]) -> GigiContent {
        let parts = results.map { r in
            GigiPart.functionResponse(name: r.name, result: r.error.map { "ERROR: \($0)" } ?? r.value)
        }
        return GigiContent(role: "user", parts: parts)
    }

    static func model(text: String) -> GigiContent {
        GigiContent(role: "model", parts: [.text(text)])
    }
}

struct GigiLLMResponse {
    let text: String?
    let functionCalls: [FunctionCallBlock]
    let finishReason: String

    var hasFunctionCalls: Bool { !functionCalls.isEmpty }
    var hasText: Bool          { !(text ?? "").isEmpty }
}

// MARK: - GigiCloudService (Groq backend)

final class GigiCloudService {
    static let shared = GigiCloudService()

    private let groqEndpoint = "https://api.groq.com/openai/v1/chat/completions"
    private let agentModel   = "llama-3.3-70b-versatile"  // main agent loop
    private let fastModel    = "llama-3.1-8b-instant"     // NLU / quick tasks

    private init() {}

    // MARK: - Agent: function calling (called by GigiAgentEngine)

    func callWithFunctions(
        systemInstruction: String? = nil,
        contents: [GigiContent],
        tools: [FunctionDeclaration],
        cacheId: String? = nil,  // ignored — Groq has no context cache
        model: String? = nil     // nil = default agentModel; pass fastModel for 429 fallback
    ) async throws -> GigiLLMResponse {
        let apiKey = GigiConfig.groqAPIKey
        guard !apiKey.isEmpty else { throw GigiCloudError.missingAPIKey }

        // Sub #52: always inject MVPPreferences at the top, regardless of
        // whether the caller supplied a custom systemInstruction. Agent loop
        // and planner pass their own task-specific prompts, but the MVP
        // demo requires their replies to also reflect user preferences
        // (tone, VIP names, food, routine hints, ...).
        let baseSystem = systemInstruction ?? GigiFoundationAgent.systemPrompt
        let resolvedSystem = await GigiUserProfile.shared.injectMVPContext(into: baseSystem)
        GigiDebugLogger.log("LLM[groq] systemPrompt prefix=\(resolvedSystem.prefix(80))")
        let messages = buildMessages(system: resolvedSystem, contents: contents)
        let toolsJSON = buildToolsJSON(tools)

        var req = URLRequest(url: URL(string: groqEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15

        var body: [String: Any] = [
            "model":       model ?? agentModel,
            "messages":    messages,
            "max_tokens":  1024,
            "temperature": 0.1
        ]
        if !toolsJSON.isEmpty {
            body["tools"]       = toolsJSON
            body["tool_choice"] = "auto"
        }

        print("GIGI Groq request: model=\(model ?? agentModel) tools=\(toolsJSON.count) tool_choice=\(body["tool_choice"] ?? "n/a") msgs=\(messages.count)")

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        GigiDebugLogger.log("Groq request: model=\(model ?? agentModel) messages=\(messages.count) tools=\(tools.count)")

        return try await withThrowingTaskGroup(of: GigiLLMResponse.self) { group in
            group.addTask {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw GigiCloudError.httpError(http.statusCode, body)
                }
                return try self.parseGroqResponse(from: data)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 13_000_000_000)
                throw GigiCloudError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // processWithGroq removed (2026-05-11, zombie audit): was the old NLU brain
    // pipeline level 2, no call sites since cascade replacement. Kept in git
    // history if needed for reactivation.

    // MARK: - Task extraction (Sub #14 1/3)

    func extractTasksRaw(transcript: String) async throws -> String {
        let system = """
        You are a task extraction engine. Extract ALL actionable tasks the user mentioned.
        Output ONLY a JSON array, no prose, no markdown fences.
        Each task: {"title": "short imperative phrase", "deadline": "today 18:00"?, "vipContact": "name"?}.
        Examples:
        - "reply to Fede and prepare the meeting" → [{"title":"Reply to Fede","vipContact":"Fede"},{"title":"Prepare the meeting"}]
        - "no tasks here" → []
        Rules:
        - title MUST be in English, imperative form (Reply, Prepare, Book, Send...).
        - deadline ONLY if explicitly mentioned by user.
        - vipContact ONLY if a person name is mentioned.
        - If no tasks: return [].
        """
        return try await callGroqRaw(
            system: system,
            user: "TRANSCRIPT:\n\(transcript)",
            model: fastModel,
            maxTokens: 400,
            temperature: 0.0
        )
    }

    // MARK: - NLU intent classification

    // classifyIntent + nluSystemPrompt + parseIntentJSON removed (2026-05-11,
    // zombie audit): NLU intent classification migrated entirely to local
    // GigiNLUEngine (Gate 2 fast-path). No call sites remain for Groq NLU.
    // Kept in git history for reactivation if/when cloud NLU is reconsidered.

    // MARK: - Chat (generic question, no OAuth needed with Groq)

    func ask(_ text: String) async throws -> String {
        try await callGroqRaw(
            system: "You are GIGI, a voice assistant on iPhone. Reply in 1-3 short sentences. No markdown. Be direct and helpful.",
            user: text,
            model: agentModel,
            maxTokens: 200,
            temperature: 0.7
        )
    }

    /// Same Groq path as `ask(_:)` but with a caller-supplied system prompt.
    /// Used by `GigiFallbackEngine.runComplexQuery` so the offline-mode
    /// instructions can override the default agent persona.
    ///
    /// Routes through `fastModel` (llama-3.1-8b-instant) by default rather
    /// than `agentModel`. Two reasons: (1) free-tier Groq splits quotas
    /// per model, so when the agent loop has saturated the 70B TPM the
    /// fallback can still serve answers from the 8B; (2) the fallback is
    /// already a degraded path, and AC5 of #63 demands a voiced reply
    /// within 8 seconds — the smaller model is materially faster.
    func askRaw(system: String, user: String) async throws -> String {
        try await callGroqRaw(
            system: system,
            user: user,
            model: fastModel,
            maxTokens: 220,
            temperature: 0.5
        )
    }

    // MARK: - News summarization

    func summarizeNews(text: String, topic: String) async -> String {
        let apiKey = GigiConfig.groqAPIKey
        guard !apiKey.isEmpty else { return String(text.prefix(200)) }

        let system = "You are GIGI, a voice assistant. Summarize these news headlines about \"\(topic)\" in 2-3 spoken sentences. No markdown, natural spoken English only."
        do {
            return try await callGroqRaw(system: system, user: String(text.prefix(2000)),
                                         model: fastModel, maxTokens: 200, temperature: 0.4)
        } catch {
            return String(text.prefix(200))
        }
    }

    // MARK: - Key diagnostic (SettingsView "Test Connection")

    func testKey(_ key: String) async -> String {
        var req = URLRequest(url: URL(string: groqEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": fastModel,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 5
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 { return "✓ Connected (Groq)" }
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }
                    .flatMap { $0["message"] as? String }
                    ?? (String(data: data, encoding: .utf8) ?? "").prefix(80).description
                return "✗ \(http.statusCode): \(msg)"
            }
            return "✗ No HTTP response"
        } catch {
            return "✗ \(error.localizedDescription)"
        }
    }

    // createContextCache stub removed (2026-05-11, zombie audit): Groq has no
    // context cache API, the stub returned nil and had zero call sites. Was
    // a Gemini-era API compat placeholder.

    // MARK: - Private: HTTP

    private func callGroqRaw(
        system: String,
        user: String,
        model: String,
        maxTokens: Int,
        temperature: Double
    ) async throws -> String {
        var req = URLRequest(url: URL(string: groqEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(GigiConfig.groqAPIKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ],
            "max_tokens":  maxTokens,
            "temperature": temperature
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GigiCloudError.httpError(http.statusCode, body)
        }
        return try extractGroqText(from: data)
    }

    // MARK: - Private: GigiContent → OpenAI messages

    private func buildMessages(system: String, contents: [GigiContent]) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": system]]

        // Track tool call IDs assigned in the previous model turn
        var lastCallIds: [Int: String] = [:]  // partIndex → callId

        for content in contents {
            let hasToolCalls     = content.parts.contains { $0.functionCall != nil }
            let hasToolResponses = content.parts.contains { $0.functionResponse != nil }
            let textParts        = content.parts.compactMap(\.text)

            if content.role == "model" && hasToolCalls {
                lastCallIds = [:]
                var toolCalls: [[String: Any]] = []
                for (i, part) in content.parts.enumerated() {
                    guard let fc = part.functionCall else { continue }
                    let callId = "call_\(fc.name)_\(i)"
                    lastCallIds[i] = callId
                    let argsAny  = fc.args.mapValues { $0.value }
                    let argsJson = (try? JSONSerialization.data(withJSONObject: argsAny))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolCalls.append([
                        "id": callId, "type": "function",
                        "function": ["name": fc.name, "arguments": argsJson]
                    ])
                }
                var msg: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
                if let t = textParts.first, !t.isEmpty { msg["content"] = t }
                messages.append(msg)

            } else if content.role == "user" && hasToolResponses {
                for (i, part) in content.parts.enumerated() {
                    guard let fr = part.functionResponse else { continue }
                    let callId = lastCallIds[i] ?? "call_\(fr.name)_\(i)"
                    messages.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": fr.response["result"] ?? ""
                    ])
                }
                lastCallIds = [:]

            } else if content.role == "model" && !textParts.isEmpty {
                let joined = textParts.joined(separator: " ")
                if !joined.isEmpty { messages.append(["role": "assistant", "content": joined]) }

            } else if content.role == "user" && !textParts.isEmpty {
                let joined = textParts.joined(separator: " ")
                if !joined.isEmpty { messages.append(["role": "user", "content": joined]) }
            }
        }

        return messages
    }

    // MARK: - Private: FunctionDeclaration → Groq tools JSON

    private func buildToolsJSON(_ tools: [FunctionDeclaration]) -> [[String: Any]] {
        tools.map { decl in
            let props = decl.parameters.properties.mapValues { prop -> [String: Any] in
                var d: [String: Any] = [
                    "type":        prop.type.lowercased(),
                    "description": prop.description
                ]
                if let ev = prop.enumValues { d["enum"] = ev }
                return d
            }
            return [
                "type": "function",
                "function": [
                    "name":        decl.name,
                    "description": decl.description,
                    "parameters":  [
                        "type":       "object",
                        "properties": props,
                        "required":   decl.parameters.required
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }
    }

    // MARK: - Private: parse Groq response

    private nonisolated func parseGroqResponse(from data: Data) throws -> GigiLLMResponse {
        guard let json    = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first   = choices.first,
              let message = first["message"] as? [String: Any]
        else { throw GigiCloudError.emptyResponse }

        let finishReason = first["finish_reason"] as? String ?? "stop"
        let text         = message["content"] as? String

        var functionCalls: [FunctionCallBlock] = []
        let toolCalls = message["tool_calls"] as? [[String: Any]]
        let rawJSON = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        Task { @MainActor in
            GigiDebugLogger.log("Groq response: finish=\(finishReason) tool_calls=\(toolCalls?.count ?? 0) raw=\(String(rawJSON.prefix(2000)))")
        }

        if let toolCalls {
            for tc in toolCalls {
                guard let fn      = tc["function"] as? [String: Any],
                      let name    = fn["name"] as? String,
                      let argsStr = fn["arguments"] as? String,
                      let argsData = argsStr.data(using: .utf8),
                      let argsObj  = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                else { continue }

                let args = argsObj.compactMapValues { v -> JSONAny? in
                    switch v {
                    case let s as String: return JSONAny(s)
                    case let d as Double: return JSONAny(d)
                    case let i as Int:    return JSONAny(i)
                    case let b as Bool:   return JSONAny(b)
                    default:              return JSONAny(String(describing: v))
                    }
                }
                functionCalls.append(FunctionCallBlock(name: name, args: args))
            }
        }

        print("GIGI Groq response: finish_reason=\(finishReason) content_len=\(text?.count ?? 0) tool_calls=\(functionCalls.count)")

        return GigiLLMResponse(
            text:          (text?.isEmpty ?? true) ? nil : text,
            functionCalls: functionCalls,
            finishReason:  finishReason
        )
    }

    private func extractGroqText(from data: Data) throws -> String {
        guard let json    = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text    = message["content"] as? String, !text.isEmpty
        else { throw GigiCloudError.emptyResponse }
        return text
    }

    // nluSystemPrompt() + parseIntentJSON() removed (2026-05-11, zombie audit):
    // were used only by classifyIntent() above, which is also removed. Local
    // GigiNLUEngine + Gate 2 fast-path covers intent classification now.
}

// MARK: - Errors

enum GigiCloudError: Error {
    case invalidURL
    case missingAPIKey
    case httpError(Int, String)
    case emptyResponse
    case timeout
}
