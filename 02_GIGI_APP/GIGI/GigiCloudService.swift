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

// MARK: - GigiCloudService (Groq removed 2026-05-11)
//
// The Groq backend (HTTP wrapper, agent loop function calling, NLU
// classification, Q&A, news summarization, task extraction) has been removed
// from the main flow. GigiAgentEngine.process() now routes every non-NLU
// query directly to the harness Claude bridge — see GigiAgentEngine.swift
// Gate 2.
//
// This thin shell remains to keep external callers compiling without behavior
// (DashboardView/SettingsView testKey, GigiActionBridge.summarizeNews,
// GigiTaskExtractor.extractTasksRaw, GigiFallbackEngine.askRaw). All methods
// return a graceful "feature unavailable" outcome — the proper replacement
// for each one lands in a later GATE:
//
//   - extractTasksRaw → Apple FM in GATE 3 (Path 2 native tool calling)
//   - summarizeNews   → Apple FM + Path 4 in GATE 5 (read_news tool)
//   - askRaw          → harness Claude (already used by Force Claude path)
//   - testKey         → no longer needed once Groq UI is removed
//
// The full Groq implementation is preserved in git history; revert this file
// to commit bdc393a^ if you need to study it.

@MainActor
final class GigiCloudService {
    static let shared = GigiCloudService()

    private init() {}

    // MARK: - Stub: task extraction (chiamato da GigiTaskExtractor)

    func extractTasksRaw(transcript: String) async throws -> String {
        // Empty JSON array — TaskExtractor will detect no tasks.
        // Replaced by Apple FM in GATE 3 (see plan §3.6).
        return "[]"
    }

    // MARK: - Stub: Q&A fallback (chiamato da GigiFallbackEngine)

    func askRaw(system: String, user: String) async throws -> String {
        throw GigiCloudError.featureUnavailable(
            "Cloud Q&A removed during 5-path migration. Use harness Claude (Force Claude) instead."
        )
    }

    func ask(_ text: String) async throws -> String {
        try await askRaw(system: "", user: text)
    }

    // MARK: - Stub: news summarization (chiamato da GigiActionBridge per read_news)

    func summarizeNews(text: String, topic: String) async -> String {
        // No-LLM passthrough — return first 200 chars of raw headlines.
        // Apple FM will replace this in GATE 3.
        return String(text.prefix(200))
    }

    // MARK: - Stub: connection test (Dashboard / Settings UI)

    func testKey(_ key: String) async -> String {
        return "Groq removed — using harness Claude as primary brain."
    }
}

// MARK: - Errors

enum GigiCloudError: Error {
    case invalidURL
    case missingAPIKey
    case httpError(Int, String)
    case emptyResponse
    case timeout
    case featureUnavailable(String)
}
