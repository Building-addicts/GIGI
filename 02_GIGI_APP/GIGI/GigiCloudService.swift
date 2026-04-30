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

    // Provider switch: NVIDIA NIM (build.nvidia.com). Same OpenAI-compatible
    // API as Groq, just different host + model IDs. Bearer key still read via
    // GigiConfig.groqAPIKey (Info.plist slot reused — value is the NVIDIA key).
    private let groqEndpoint = "https://integrate.api.nvidia.com/v1/chat/completions"
    private let agentModel   = "meta/llama-3.3-70b-instruct"  // main agent loop (NVIDIA NIM)
    private let fastModel    = "meta/llama-3.1-8b-instruct"   // NLU / quick tasks (NVIDIA NIM)

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
        req.timeoutInterval = 30  // NVIDIA NIM cold start can hit 5-10s on free tier

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

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    // MARK: - NLU / Brain pipeline (Groq)

    func processWithGroq(_ text: String, history: String) async -> GigiAgentResponse? {
        let apiKey = GigiConfig.groqAPIKey
        guard !apiKey.isEmpty else { return nil }

        let prompt = history.isEmpty
            ? text
            : "--- Conversation history ---\n\(history)\n--- End history ---\n\nCurrent message: \(text)"

        do {
            let injectedSystem = await GigiUserProfile.shared.injectMVPContext(into: GigiFoundationAgent.systemPrompt)
            GigiDebugLogger.log("LLM[groq-nlu] systemPrompt prefix=\(injectedSystem.prefix(80))")
            let raw = try await callGroqRaw(
                system: injectedSystem,
                user: prompt,
                model: agentModel,
                maxTokens: 512,
                temperature: 0.2
            )
            return GigiFoundationAgent.parse(raw: raw)
        } catch {
            print("GIGI Groq NLU error: \(error.localizedDescription)")
            return nil
        }
    }

    // Legacy alias used by GigiBrainPipeline
    func processWithGemini(_ text: String, history: String) async -> GigiAgentResponse? {
        await processWithGroq(text, history: history)
    }

    // MARK: - NLU intent classification

    func classifyIntent(_ text: String) async -> GigiIntent? {
        let apiKey = GigiConfig.groqAPIKey
        guard !apiKey.isEmpty else {
            print("GIGI NLU [Groq]: API key missing — using local fallback")
            return nil
        }

        let system = nluSystemPrompt()
        let user   = "User input: \"\(text)\""

        do {
            let raw = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.callGroqRaw(system: system, user: user,
                                               model: self.fastModel, maxTokens: 300, temperature: 0.0)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    throw GigiCloudError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            return parseIntentJSON(raw, originalText: text)
        } catch GigiCloudError.timeout {
            print("GIGI NLU [Groq]: timeout — local fallback")
            return nil
        } catch {
            print("GIGI NLU [Groq]: \(error.localizedDescription)")
            return nil
        }
    }

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
        req.timeoutInterval = 20  // NVIDIA NIM cold start tolerance
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

    // MARK: - Context cache stub (Groq has no cache — kept for API compat)

    func createContextCache(systemPrompt: String = "", tools: [FunctionDeclaration]) async -> String? {
        return nil
    }

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
        req.timeoutInterval = 25  // NVIDIA NIM cold start tolerance

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
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
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

    // MARK: - NLU system prompt + parser (unchanged from Gemini version)

    private func nluSystemPrompt() -> String {
        """
        You are the NLU engine of GIGI, an iOS voice assistant. English only.
        Analyze the text and return ONLY valid JSON, no extra text:

        {"intent":"<label>","params":{"contact":"","body":"","platform":"","destination":"","query":"","app":"","text":"","title":"","date":"","time":"","restaurant":"","guests":""}}

        Available intents (pick the most precise):
        navigation      → wants to go somewhere / navigate
        play_music      → wants to listen to music or an artist
        make_call       → wants to call someone
        send_message    → wants to send a message (WhatsApp, iMessage, SMS)
        set_reminder    → wants a reminder
        create_event    → wants to create a calendar event
        ask_time        → asking the current time
        ask_date        → asking today's date
        weather         → asking about weather / forecast
        open_app        → wants to open a specific app
        torch_on        → turn on the flashlight
        torch_off       → turn off the flashlight
        toggle_wifi     → enable/disable wifi
        toggle_bluetooth → enable/disable bluetooth
        set_alarm       → set an alarm
        search_web      → search something online
        read_news       → read/listen to news on a topic
        order_food      → order food from a restaurant via delivery
        book_restaurant → book a table at a restaurant
        ask_cloud       → generic question / historical fact (use when no other intent fits)
        remember        → save a fact about a person/thing
        recall          → ask what is known about someone

        Param rules:
        - contact: person's name (e.g. "mom", "John", "Sara Smith")
        - body: message text to send
        - platform: "whatsapp", "imessage", "telegram" — empty if not specified
        - destination: place/address
        - query: artist/song for play_music, or search query for search_web
        - app: app name to open
        - text: reminder text
        - title: event title
        - date: "tomorrow", "monday", "april 15"
        - time: HH:MM format
        """
    }

    private func parseIntentJSON(_ raw: String, originalText: String) -> GigiIntent? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return nil }
        let jsonString = String(raw[start...end])
        guard let data = jsonString.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intentLabel = obj["intent"] as? String
        else { return nil }

        var params: [String: String] = ["raw": originalText]
        if let rawParams = obj["params"] as? [String: Any] {
            for (k, v) in rawParams {
                let s = (v as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { params[k] = s }
            }
        }
        return GigiIntent(label: intentLabel, confidence: 0.97, params: params)
    }
}

// MARK: - Errors

enum GigiCloudError: Error {
    case invalidURL
    case missingAPIKey
    case httpError(Int, String)
    case emptyResponse
    case timeout
}
