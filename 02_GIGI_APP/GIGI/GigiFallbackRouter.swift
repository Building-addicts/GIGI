import Foundation

// MARK: - GigiFallbackRouter
//
// Rule-based router for devices that cannot run Apple Foundation Models
// (iPhone <15 Pro, iOS <26, Apple Intelligence disabled or model assets
// not yet downloaded) AND for users in "Minimal" mode who want to skip
// the Apple FM round-trip. Produces the same `FoundationRouterDecision`
// shape so the dispatcher logic in `GigiRequestRouter` is identical.
//
// Coverage:
//   - native_tool   → 15 canonical actions matched by keyword tables.
//   - delegate_local → reasoning keywords (explain / summarize / rephrase).
//   - delegate_cloud → browser/code keywords (search the web / write code).
//   - reject        → known illegal/nonsense markers.
//   - ask_clarification → no match + utterance too short.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.8 + §9
// ADR-0009 (Hardware targets and modes).

@MainActor
final class GigiFallbackRouter {
    static let shared = GigiFallbackRouter()

    private init() {}

    // MARK: - Keyword tables

    /// Keywords → canonical action. Match is case-insensitive, substring.
    /// Order matters: first match wins, so put more specific entries first.
    private static let nativeKeywordTable: [(action: String, keywords: [String])] = [
        ("set_timer",      ["timer", "countdown", "remind me in", "alert me in"]),
        ("set_alarm",      ["alarm", "wake me", "wake up at", "set an alarm"]),
        ("set_reminder",   ["remind me to", "reminder", "remember to"]),
        ("send_message",   ["text ", "send a text", "message ", "whatsapp", "imessage", "send an sms", "text my"]),
        ("make_call",      ["call ", "phone ", "dial ", "ring "]),
        ("facetime",       ["facetime"]),
        ("navigate",       ["navigate to", "directions to", "take me to", "drive to", "route to"]),
        ("play_music",     ["play ", "music", "song", "playlist", "spotify"]),
        ("open_app",       ["open ", "launch ", "start the app"]),
        ("weather",        ["weather", "forecast", "temperature outside", "is it raining"]),
        ("read_calendar",  ["calendar", "my schedule", "what's on today", "my events"]),
        ("find_free_slot", ["free slot", "free time", "when am i free", "available slot"]),
        ("read_email",     ["email", "inbox", "latest mail", "read my mail"]),
        ("homekit_on",     ["turn on the", "switch on", "lights on"]),
        ("homekit_off",    ["turn off the", "switch off", "lights off"]),
    ]

    private static let reasoningKeywords = [
        "explain", "summarize", "summary of", "rephrase", "rewrite",
        "what does", "define", "translate", "shorter version", "in three sentences",
        "make this professional", "make this shorter", "outline"
    ]

    private static let browserKeywords = [
        "search the web", "google", "wikipedia", "look up online", "find online",
        "browse", "open the page", "fetch from", "scrape", "web search"
    ]

    private static let codeKeywords = [
        "write a script", "python", "javascript", "swift code",
        "fix this code", "regex for", "shell command", "bash one-liner"
    ]

    private static let rejectKeywords = [
        "buy bitcoin", "buy stocks", "wire money", "send eth",
        "hack ", "exploit ", "ddos", "brute force", "crack the"
    ]

    // MARK: - classifyRequest

    /// Map a user utterance to a `FoundationRouterDecision` without
    /// involving Apple FM. Confidence is lower than Apple FM (0.55-0.85),
    /// reflecting that this is a degraded path.
    func classifyRequest(text: String) -> FoundationRouterDecision {
        let lower = text.lowercased()

        // 1. Reject keywords (highest precedence — never let through).
        if Self.rejectKeywords.contains(where: { lower.contains($0) }) {
            return decision(
                path: "reject",
                confidence: 0.85,
                reason: "fallback: reject keyword",
                directSpeech: "I can't help with that one."
            )
        }

        // 2. Native tool keyword match.
        for entry in Self.nativeKeywordTable {
            if entry.keywords.contains(where: { lower.contains($0) }) {
                let slots = extractSlots(from: text, action: entry.action)
                return decision(
                    path: "native_tool",
                    primaryAction: entry.action,
                    confidence: 0.75,
                    reason: "fallback: keyword \(entry.keywords[0].trimmingCharacters(in: .whitespaces))",
                    slots: slots
                )
            }
        }

        // 3. Browser / code → delegate_cloud.
        if Self.browserKeywords.contains(where: { lower.contains($0) }) {
            return decision(
                path: "delegate_cloud",
                confidence: 0.7,
                complexity: 65,
                capabilities: ["browser", "web_search"],
                reason: "fallback: browser keyword",
                delegatePrompt: text
            )
        }
        if Self.codeKeywords.contains(where: { lower.contains($0) }) {
            return decision(
                path: "delegate_cloud",
                confidence: 0.7,
                complexity: 55,
                capabilities: ["code"],
                reason: "fallback: code keyword",
                delegatePrompt: text
            )
        }

        // 4. Reasoning → delegate_local.
        if Self.reasoningKeywords.contains(where: { lower.contains($0) }) {
            return decision(
                path: "delegate_local",
                confidence: 0.65,
                complexity: 30,
                reason: "fallback: reasoning keyword",
                delegatePrompt: text
            )
        }

        // 5. Too short → ask_clarification.
        let words = lower.split(whereSeparator: { $0.isWhitespace })
        if words.count <= 2 {
            return decision(
                path: "ask_clarification",
                confidence: 0.4,
                reason: "fallback: utterance too short",
                directSpeech: "Could you say a bit more about what you'd like?"
            )
        }

        // 6. Default fallback → delegate_cloud (the safest landing).
        return decision(
            path: "delegate_cloud",
            confidence: 0.55,
            complexity: 50,
            reason: "fallback: default to cloud",
            delegatePrompt: text
        )
    }

    // MARK: - Slot extraction (best-effort)

    private static func emptySlots() -> ActionSlots {
        ActionSlots(
            contact: "", body: "", destination: "", date: "", time: "",
            taskText: "", duration: "", label: "", appName: "", query: "", platform: ""
        )
    }

    private func extractSlots(from text: String, action: String) -> ActionSlots {
        var s = Self.emptySlots()
        let lower = text.lowercased()

        // Duration for timer
        if action == "set_timer" {
            if let m = lower.range(of: #"(\d+)\s*(minute|minutes|hour|hours|second|seconds)"#, options: .regularExpression) {
                s.duration = String(text[m])
            }
        }

        // Time for alarm
        if action == "set_alarm" {
            if let m = lower.range(of: #"(\d{1,2}):?(\d{2})?\s*(am|pm)?"#, options: .regularExpression) {
                s.time = String(text[m])
            }
        }

        // Contact for call/message/facetime — naive "to <name>" or "call <name>" extraction.
        if action == "make_call" || action == "send_message" || action == "facetime" {
            if let r = lower.range(of: #"(?:call|text|message|facetime)\s+([a-z]+(?:\s+[a-z]+){0,2})"#, options: .regularExpression) {
                let captured = String(text[r])
                let words = captured.split(separator: " ").dropFirst()
                s.contact = words.joined(separator: " ")
            }
        }

        // Destination for navigate
        if action == "navigate" {
            if let r = lower.range(of: #"(?:to|toward)\s+(.+)"#, options: .regularExpression) {
                let captured = String(text[r])
                let cleaned = captured.replacingOccurrences(of: #"^(to|toward)\s+"#, with: "", options: .regularExpression)
                s.destination = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Open app — capture the trailing word
        if action == "open_app" {
            if let r = lower.range(of: #"open\s+([a-z][a-z\s]+)"#, options: .regularExpression) {
                let captured = String(text[r]).replacingOccurrences(of: "open ", with: "")
                s.appName = captured.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // HomeKit accessory
        if action == "homekit_on" || action == "homekit_off" {
            if let r = lower.range(of: #"(?:turn\s+(?:on|off)\s+(?:the\s+)?)([a-z][a-z\s]+)"#, options: .regularExpression) {
                let captured = String(text[r])
                    .replacingOccurrences(of: #"^turn\s+(on|off)\s+(the\s+)?"#, with: "", options: .regularExpression)
                s.taskText = captured.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Weather location: capture words after "in"
        if action == "weather" {
            if let r = lower.range(of: #"in\s+([a-z][a-z\s]+)"#, options: .regularExpression) {
                let captured = String(text[r]).replacingOccurrences(of: "in ", with: "")
                s.query = captured.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return s
    }

    // MARK: - Cloud-session continuity (2026-05-22)

    /// Builds a `delegate_cloud` decision for a follow-up reply to an OPEN
    /// cloud task (e.g. answering the agent's mid-order "cold or hot?"). The
    /// harness resumes the SAME Claude session by deviceId (`continuous_session`),
    /// so the agent keeps its browser + in-flight order state — the raw reply is
    /// all it needs. Browser capability is attached so the resumed agent always
    /// has its tools. Used by `CloudFollowUpTier`.
    func cloudContinuation(prompt: String) -> FoundationRouterDecision {
        decision(
            path: "delegate_cloud",
            confidence: 0.95,
            complexity: 70,
            capabilities: ["browser"],
            reason: "cloud follow-up continuation",
            delegatePrompt: prompt
        )
    }

    // MARK: - Helpers

    private func decision(
        path: String,
        primaryAction: String = "",
        confidence: Double = 0.7,
        complexity: Int = 0,
        capabilities: [String] = [],
        reason: String = "",
        slots: ActionSlots? = nil,
        directSpeech: String = "",
        delegatePrompt: String = ""
    ) -> FoundationRouterDecision {
        let resolvedSlots = slots ?? Self.emptySlots()
        #if canImport(FoundationModels)
        return FoundationRouterDecision(
            path: path,
            primaryAction: primaryAction,
            confidence: confidence,
            complexityEstimate: complexity,
            requiredCapabilities: capabilities,
            reason: reason,
            slots: resolvedSlots,
            directSpeech: directSpeech,
            delegatePrompt: delegatePrompt
        )
        #else
        var d = FoundationRouterDecision()
        d.path = path
        d.primaryAction = primaryAction
        d.confidence = confidence
        d.complexityEstimate = complexity
        d.requiredCapabilities = capabilities
        d.reason = reason
        d.slots = resolvedSlots
        d.directSpeech = directSpeech
        d.delegatePrompt = delegatePrompt
        return d
        #endif
    }
}
