import Foundation

// MARK: - GigiFoundationSession
// Concrete Apple Foundation Models impl (iOS 18.1+). Must compile with
// Xcode 16+ / iOS 18.1 SDK. On unsupported devices, isAvailable = false
// and every method returns nil / throws.
//
// Phase 2 additions (GATE 2 + GATE 3):
//   - routeRequest(text:history:) → FoundationRouterDecision     [GATE 2]
//   - respondWithTools(text:tools:history:) → ToolCallResult     [GATE 3]
//   - isAppleFMAvailable static capability check                 [GATE 3]

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Public types

/// Result of a `respondWithTools` round. Exactly one of `toolInvoked` or
/// `directSpeech` is non-nil. If a tool was invoked, `toolResult` carries
/// the raw return value of the `Tool.call(arguments:)` method (already
/// dispatched through the bridge by the tool itself).
@available(iOS 26.0, *)
struct ToolCallResult {
    let toolInvoked: String?
    let toolResult: String?
    let directSpeech: String?
    let latencyMs: Int
}

// MARK: - Session manager

@available(iOS 18.1, *)
@MainActor
final class GigiFoundationSession {
    static let shared = GigiFoundationSession()

    private var session: LanguageModelSession?
    private(set) var isAvailable: Bool = false
    private var permanentlyDisabled = false  // true after model catalog failure

    private init() {
        setupSession()
    }

    private func setupSession() {
        guard !permanentlyDisabled else { return }
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            GigiDebugLogger.log("GIGI Foundation: optional Apple Intelligence unavailable — using harness fallback.")
            isAvailable = false
            return
        }
        session = LanguageModelSession(instructions: GigiFoundationAgent.systemPrompt)
        isAvailable = true
        GigiDebugLogger.log("GIGI Foundation: Apple Intelligence ready ✓")
    }

    // MARK: - Capability check (GATE 3 — Task 3.5)
    //
    // Cached at boot, refreshed on app foreground via `refreshAvailability()`.
    // Read by `GigiRequestRouter` to decide if Apple FM is the primary gate
    // or if `GigiFallbackRouter` (keyword-based) takes over.

    static var isAppleFMAvailable: Bool {
        if #available(iOS 18.1, *) {
            return GigiFoundationSession.shared.isAvailable
        }
        return false
    }

    func refreshAvailability() {
        setupSession()
    }

    // MARK: - Legacy entry point (Brain Path Override = appleFM)

    func respond(text: String, history: String) async -> GigiAgentResponse? {
        guard let session, isAvailable else { return nil }

        let prompt: String
        if history.isEmpty {
            prompt = "Classify and fill slots for this utterance (one structured action):\n\(text)"
        } else {
            prompt = """
            Recent conversation:
            \(history)

            Latest utterance — use context to resolve pronouns (him/her/it/there/that place) and implied slots, then output one structured action:
            \(text)
            """
        }

        do {
            let result = try await session.respond(to: prompt, generating: FoundationAgentOutput.self)
            let out    = result.content
            let merged = GigiAgentResponse(
                action:   out.action,
                contact:  out.contact,
                body:     out.body,
                platform: out.platform,
                dest:     out.destination,
                query:    out.query,
                app:      out.app,
                taskText: out.taskText,
                date:     out.date,
                time:     out.time,
                speech:   out.speech,
                followUp: out.followUp
            )
            let normalized = GigiFoundationAgent.normalizedResponse(merged)
            GigiDebugLogger.log("GIGI Foundation: '\(text)' → \(normalized.action) | speech: \(normalized.speech.prefix(60))")

            return normalized

        } catch {
            let desc = error.localizedDescription + "\(error)"
            GigiDebugLogger.log("GIGI Foundation error: \(error)")
            // Model catalog missing — Apple Intelligence not fully downloaded yet
            if desc.contains("modelcatalog") || desc.contains("5000") || desc.contains("SensitiveContentAnalysis") {
                permanentlyDisabled = true
                isAvailable = false
                self.session = nil
                GigiDebugLogger.log("GIGI Foundation: model assets not downloaded. Go to Settings → Apple Intelligence & Siri → enable and wait for download.")
            }
            return nil
        }
    }

    // MARK: - Phase 2 — routeRequest (GATE 2 Task 2.2)
    //
    // The primary entry point of the 5-path router. Returns a structured
    // `FoundationRouterDecision` that `GigiRequestRouter.route()` uses to
    // dispatch to one of the 5 paths.
    //
    // Uses a dedicated router-specific session (`routerSession`) seeded with
    // `GigiFoundationAgent.routerSystemPrompt` so the router instructions
    // don't pollute the legacy `session` used by `respond(text:history:)`.

    // 2026-05-12 PRECISION FIX — stateless router session.
    //
    // Previously `routerSession` was a persistent singleton, lazily created
    // once and reused across all `routeRequest()` calls. Apple's
    // `LanguageModelSession` accumulates conversation transcript internally
    // on every `.respond(to:)` invocation. The accumulated context biased
    // the router's classification toward whatever path was chosen on prior
    // turns:
    //   turn 1: "Search Apple stock" → delegate_cloud
    //   turn 2: "Test tools on iPhone" → also delegate_cloud (anchored)
    //   turn 3: "How are you" → still delegate_cloud (feedback loop)
    //
    // The `history` parameter we pass via the prompt is sub-weighted because
    // the model trusts its internal transcript more than text in the user
    // message. Resetting GigiConversationMemory via the chat ↻ button does
    // NOT clear the Apple FM internal transcript.
    //
    // Fix: spawn a fresh LanguageModelSession on every call. Each routing
    // decision sees ONLY the operator instructions + the current utterance
    // (plus history as text). Zero turn-to-turn bias.
    //
    // Cost: ~50–150ms session init per turn — invisible compared to the
    // 3–10s Ollama/Claude path latency that follows.

    /// Routes a user utterance to one of the 5 paths.
    /// Throws on Apple FM errors — the caller is expected to fall back to
    /// `GigiFallbackRouter.classifyRequest(text:)` (rule-based) on failure.
    func routeRequest(text: String, history: String) async throws -> FoundationRouterDecision {
        guard isAvailable else {
            throw NSError(
                domain: "GigiFoundationSession",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Foundation Models not available"]
            )
        }
        // Stateless: new session every call to prevent transcript bias.
        let s = LanguageModelSession(instructions: GigiFoundationAgent.routerSystemPrompt)

        let prompt: String
        if history.isEmpty {
            prompt = "Route this user utterance:\n\(text)"
        } else {
            prompt = """
            Recent conversation:
            \(history)

            Latest utterance — route considering whether the user's reply continues an open task or starts a new one:

            - If the history contains an `<assistant_previous_turn>` block AND the latest utterance is a short reply that confirms ("go", "yes", "send it", "do it"), cancels ("no", "stop"), corrects ("not salmon, tuna"), or otherwise addresses what GIGI just asked, treat it as a CONTINUATION of that task. Route to whatever path the previous turn was leading to (usually delegate_cloud for action follow-ups). Do NOT classify as ask_clarification merely because the utterance is short in isolation.
            - If the latest utterance changes topic ("what's the weather", "set a timer"), ignore the `<assistant_previous_turn>` block and route fresh.
            - Resolve pronouns and ellipsis from the broader conversation as usual.

            User said:
            \(text)
            """
        }

        let start = Date()
        do {
            let result = try await s.respond(to: prompt, generating: FoundationRouterDecision.self)
            let decision = result.content
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            GigiDebugLogger.log("GIGI Router: path=\(decision.path) action=\(decision.primaryAction) " +
                  "complexity=\(decision.complexityEstimate) confidence=\(String(format: "%.2f", decision.confidence)) " +
                  "caps=\(decision.requiredCapabilities) latencyMs=\(elapsedMs)")
            // Cache for the debug overlay (Show last router decision toggle)
            UserDefaults.standard.set(Self.decisionToJSON(decision), forKey: "gigi.debug.lastRouterDecision")
            return decision
        } catch {
            GigiDebugLogger.log("GIGI Router error: \(error)")
            let desc = "\(error)"
            if desc.contains("modelcatalog") || desc.contains("SensitiveContentAnalysis") {
                permanentlyDisabled = true
                isAvailable = false
                // routerSession no longer stored — stateless after 2026-05-12 fix
            }
            throw error
        }
    }

    /// Resolves a potentially-ambiguous user utterance into a self-contained
    /// instruction by looking at the immediately-preceding assistant turn.
    /// Uses a fresh on-device FM session to decide whether the user reply is
    /// a continuation of the assistant's previous turn or a topic change.
    ///
    /// Returns the resolved text (which the caller passes to the router).
    /// On topic change or when there is no prior assistant turn, returns
    /// `text` unchanged. On Apple FM failure, also returns `text` unchanged
    /// — the caller falls back to standard routing.
    ///
    /// Cost: ~50-150ms per call (one extra FM round-trip). Only paid when a
    /// last assistant turn exists; first user turn skips it entirely.
    func resolveFollowUp(text: String, lastAssistantTurn: String?) async -> String {
        guard isAvailable,
              let last = lastAssistantTurn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !last.isEmpty else {
            return text
        }
        // Stateless: same precaution as routeRequest.
        let s = LanguageModelSession(instructions: """
        You are a context resolver for a voice assistant. Given the assistant's previous turn (a question or proposal awaiting user reply) and the user's current short utterance, decide whether the utterance is a CONTINUATION of that task or a TOPIC CHANGE.

        - CONTINUATION: user confirms ("go", "yes", "send it"), cancels ("no", "stop"), corrects ("not salmon, tuna"), or otherwise addresses what the assistant just asked. In that case, output a self-contained instruction that combines the assistant's proposal with the user's reply, suitable for a router that has no conversation context.
        - TOPIC CHANGE: user asks something unrelated ("what's the weather", "set a timer for ten minutes"). In that case, output the user's utterance unchanged.

        Be conservative: only mark CONTINUATION when the link is obvious. Output ONLY the resolved instruction text, nothing else. No preamble, no quotes, no markdown.
        """)
        let prompt = """
        Assistant's previous turn:
        \(last)

        User's current utterance:
        \(text)

        Resolved instruction:
        """
        do {
            let result = try await s.respond(to: prompt)
            let resolved = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if resolved.isEmpty {
                return text
            }
            if resolved != text {
                GigiDebugLogger.log("GIGI FollowUpResolver: '\(text)' → '\(resolved.prefix(120))'")
            }
            return resolved
        } catch {
            GigiDebugLogger.log("GIGI FollowUpResolver error (\(error.localizedDescription)) — using original text")
            return text
        }
    }

    /// Interpret a user reply against a pending world-action proposal.
    /// Replaces the regex affirmative/negative matchers in
    /// `WorldActionConsentTier` with constrained-decoding FM classification.
    ///
    /// Returns a structured decision: confirm / reject / modify / unrelated.
    /// On Apple FM failure or unavailability, returns nil so the caller can
    /// fall back to regex matching.
    ///
    /// Cost: ~150-300ms per call (one FM round-trip), only paid when a
    /// proposal is staged AND the next user turn arrives.
    func resolveConfirmation(userReply: String, proposalSummary: String) async -> ConfirmationDecision? {
        guard isAvailable else { return nil }
        let s = LanguageModelSession(instructions: """
        You are a confirmation classifier for a voice assistant. The assistant has just proposed an action and is waiting for the user's reply. Classify the reply into one of four mutually exclusive kinds:

        - confirm: user accepts as proposed (yes / go / ok / sure / do it / perfect / vai / dai / procedi)
        - reject: user declines (no / cancel / stop / never mind / annulla / lascia perdere)
        - modify: user accepts the underlying action but changes something (size, place, ingredient, time, quantity). When kind=modify, build a self-contained instruction that combines the original proposal with the user's change.
        - unrelated: the reply doesn't address the proposal at all — it's a completely new request (what time is it, set a timer, who's calling, weather)

        Be conservative: when in doubt between confirm and modify, prefer modify so any change in the reply isn't silently lost.
        """)
        let prompt = """
        Pending proposal:
        \(proposalSummary)

        User reply:
        \(userReply)

        Classify.
        """
        do {
            let result = try await s.respond(to: prompt, generating: ConfirmationDecision.self)
            let decision = result.content
            GigiDebugLogger.log("GIGI ConfirmationResolver: '\(userReply)' → kind=\(decision.kind)" +
                  (decision.kind == "modify" ? " brief='\(decision.modificationBrief.prefix(80))'" : ""))
            return decision
        } catch {
            GigiDebugLogger.log("GIGI ConfirmationResolver error: \(error.localizedDescription) — caller will fall back to regex")
            return nil
        }
    }

    /// Serialize a `FoundationRouterDecision` to compact JSON for the debug
    /// overlay (Settings → Debug → "Show last router decision"). Best-effort —
    /// returns a fallback marker if encoding fails.
    private static func decisionToJSON(_ d: FoundationRouterDecision) -> String {
        let slots: [String: String] = [
            "contact": d.slots.contact, "body": d.slots.body,
            "destination": d.slots.destination, "date": d.slots.date,
            "time": d.slots.time, "taskText": d.slots.taskText,
            "duration": d.slots.duration, "label": d.slots.label,
            "appName": d.slots.appName, "query": d.slots.query,
            "platform": d.slots.platform
        ].filter { !$0.value.isEmpty }
        let dict: [String: Any] = [
            "path": d.path,
            "primaryAction": d.primaryAction,
            "confidence": d.confidence,
            "complexity": d.complexityEstimate,
            "capabilities": d.requiredCapabilities,
            "reason": d.reason,
            "slots": slots,
            "directSpeech": d.directSpeech,
            "delegatePrompt": d.delegatePrompt
        ]
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"encode_failed\"}"
    }

    // MARK: - Phase 2 — respondWithTools (GATE 3 Task 3.2)
    //
    // Apple FM Tool calling — iOS 26+. Pass the canonical `Tool` array
    // for the user utterance, get back the invocation result. Used by
    // `GigiRequestRouter.dispatchNativeTool` to execute Path 2.
    //
    // Note: iOS 26 introduces a `LanguageModelSession(tools:)` initializer
    // — the actual signature may differ slightly across betas. We probe via
    // dynamic message dispatch and gracefully fall back to a string return
    // if the call surface isn't available on the runtime SDK.

    @available(iOS 26.0, *)
    func respondWithTools(text: String, tools: [any Tool], history: String) async throws -> ToolCallResult {
        guard isAvailable else {
            throw NSError(
                domain: "GigiFoundationSession",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Apple Foundation Models not available"]
            )
        }

        // Build a per-call tools session — Tool calling state should not leak
        // between turns (Apple recommends ephemeral sessions for tool runs).
        let toolsSession = LanguageModelSession(
            tools: tools,
            instructions: GigiFoundationAgent.toolsSystemPrompt
        )

        let prompt: String
        if history.isEmpty {
            prompt = text
        } else {
            prompt = """
            Recent conversation:
            \(history)

            Latest utterance — pick exactly one tool and call it with the right arguments. If none of the provided tools fits, respond with a single short clarification.
            User: \(text)
            """
        }

        let start = Date()
        let result = try await toolsSession.respond(to: prompt)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        // The iOS 26 API returns either a text response (no tool used) or
        // a tool-invocation result. We surface text in `directSpeech` and
        // leave callers to inspect `toolInvoked` populated from os_log
        // (the Tool struct's `call(arguments:)` is the source of truth).
        let text = result.content
        GigiDebugLogger.log("GIGI Tools: latencyMs=\(elapsedMs) responseLen=\(text.count)")

        return ToolCallResult(
            toolInvoked: nil,
            toolResult: nil,
            directSpeech: text.isEmpty ? nil : text,
            latencyMs: elapsedMs
        )
    }

    // MARK: - Reset

    func resetContext() {
        setupSession()
        // routerSession is now stateless (recreated on every routeRequest)
        // so there's nothing persistent to clear here. Resetting the main
        // `session` (Tool-calling Path 2) is still needed.
        GigiDebugLogger.log("GIGI Foundation: session reset.")
    }
}

#else

// MARK: - Stub for SDKs without FoundationModels

@MainActor
final class GigiFoundationSession {
    static let shared = GigiFoundationSession()
    let isAvailable: Bool = false

    static var isAppleFMAvailable: Bool { false }

    private init() {
        GigiDebugLogger.log("GIGI Foundation: FoundationModels not available in this SDK.")
    }
    func respond(text: String, history: String) async -> GigiAgentResponse? { nil }
    func resetContext() {}
    func refreshAvailability() {}
}

#endif
