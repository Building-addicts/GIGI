import Foundation
import UIKit

// MARK: - AgentResult

struct AgentResult {
    let speech: String
    let executedTools: [String]
    let isFollowUp: Bool
    let costEstimate: Double       // USD estimate for this turn
    let requiresConfirm: ConfirmRequest?
    let isError: Bool
}

// MARK: - InterimEvent

enum InterimEvent {
    case thinking(iteration: Int)
    case toolStarted(name: String)
    case toolCompleted(name: String, result: String)
    case waitingForConfirmation(ConfirmRequest)
}

// MARK: - GigiAgentEngine

@MainActor
final class GigiAgentEngine {
    static let shared = GigiAgentEngine()

    // Whitelist of NLU labels eligible for the deterministic fast-path.
    // High-confidence (>=0.95) classifications skip the Groq round-trip and
    // dispatch straight to GigiActionBridge after the Force Claude gate.
    private static let fastPathIntents: Set<String> = [
        "ask_time", "ask_date", "torch_on", "torch_off", "make_call", "send_message",
        "navigate", "navigation", "set_timer", "set_alarm", "set_reminder",
        "toggle_wifi", "toggle_bluetooth", "media_play_pause", "media_next", "media_previous",
        "play_music", "open_app", "read_calendar", "read_week_calendar", "find_free_slot",
        "remember", "respond", "facetime", "facetime_audio"
    ]

    // MARK: - Config removed (2026-05-11, Groq removal):
    // maxIterations / fastTimeout / slowTimeout / costPerToken were
    // Groq agent-loop specific. The new 5-path plan adds path-specific
    // config (Apple FM context budget, Ollama timeout, Claude Code
    // subscription tracking) — see GATE 2-5 task plans.

    // MARK: - Pending confirmation state
    // Kept on the singleton so it survives the audio turn and brief backgrounding.
    // The app process staying alive is sufficient — if the app is killed, the user
    // must re-issue the command anyway.
    private(set) var pendingConfirmRequest: ConfirmRequest?
    private var pendingConfirmTool: (any GigiTool)?
    private var pendingConfirmArgs: [String: Any] = [:]

    // MARK: - Callbacks

    var onInterimEvent: ((InterimEvent) -> Void)?

    private init() {
        // Wire GigiClaudeBridge to conversation memory so stream events
        // can append `.thinking` / `.toolEvent` bubbles while Claude runs.
        // Both objects are singletons (@MainActor) so this reference is
        // stable for the process lifetime.
        GigiClaudeBridge.shared.memory = GigiConversationMemory.shared
    }

    // MARK: - Public API

    /// Entry point: processes one user utterance end-to-end.
    func process(text: String) async -> AgentResult {
        // Normalize Unicode smart-punctuation FIRST. iOS keyboards
        // autoreplace straight apostrophes/quotes with curly equivalents
        // (U+2019, U+2018, U+201C, U+201D) which silently break every
        // downstream regex that matches "who's", "X's", etc. Fix once
        // here so the entire pipeline sees ASCII.
        let text = Self.normalizeSmartPunctuation(text)
        GigiDebugLogger.log("GIGI agentEngine.process ENTRY: text='\(text.prefix(60))'")
        let mem = GigiConversationMemory.shared
        mem.addUserTurn(text)

        #if DEBUG
        // === D1 debug override (5-path plan testing harness) ===
        // Settings → Debug → Brain Path Override lets the dev force a specific
        // routing path. `.auto` falls through to the normal flow below.
        switch DebugBrainPath.current {
        case .auto:
            break  // fall through
        case .appleFM:
            return await processAppleFMOverride(text: text)
        case .ollama:
            return await processOllamaOverride(text: text)
        case .claude:
            // Treat as if Force Claude were on — handled by the existing gate below.
            return await processForceClaude(text: text, autoFallbackOnError: false)
                ?? AgentResult(speech: "Force Claude path returned no result.",
                               executedTools: [], isFollowUp: false,
                               costEstimate: 0, requiresConfirm: nil, isError: true)
        }
        #endif

        // === Gate 0.5: build_shortcut intent escape hatch ===
        //
        // The NLU fast-path matches "flashlight on" / "torch on" as
        // SUBSTRINGS. So "Build me a shortcut that turns the flashlight on,
        // waits 5 seconds, then turn it off" gets misclassified as
        // torch_on (confidence 0.99) and dispatched to bridge BEFORE the
        // proper router can detect the build_shortcut intent.
        //
        // Cheap escape: if the prompt contains an explicit build-shortcut
        // verb + the word "shortcut", skip the fast-path and go straight
        // to route() which has the canonical regex + composeShortcut.
        if Self.looksLikeBuildShortcut(text) {
            GigiDebugLogger.log("GIGI Agent: bypass fast-path — text looks like build_shortcut")
        } else {
            // Memory recall probe: if utterance is a "who is X / what is X /
            // tell me about X / recall X" query AND we have that X stored,
            // answer from memory directly. The user's own statement is
            // authoritative — never delegate to an LLM that may hallucinate
            // over our facts. On memory miss, fall through to the normal
            // routing pipeline so the LLM can still answer generic knowledge.
            if let memHit = await memoryRecallProbe(for: text) {
                return memHit
            }
            if let fastPath = await deterministicFastPath(for: text) {
                return fastPath
            }
        }

        // === Gate 2: 5-path router (GATE 2 lands here) ===
        //
        // GigiRequestRouter.route() runs the Apple FM upfront router (or
        // GigiFallbackRouter rule-based if Apple FM is unavailable / mode
        // disables it), gets a FoundationRouterDecision, and dispatches to
        // one of the 5 paths:
        //   - native_tool        → GigiActionBridge (instant)
        //   - delegate_local     → Ollama via harness SSE (Path 3, GATE 4)
        //   - delegate_cloud     → Claude Code via harness WS (Path 4, GATE 5)
        //                            (transitional: falls back to GigiClaudeBridge)
        //   - ask_clarification  → speak directSpeech
        //   - reject             → speak directSpeech
        //
        // Mode gating (GATE 7) is applied inside the router based on
        // UserDefaults("gigi.user.mode").

        // Structured compact history — replaces flat-text transcript.
        // Each prior turn is summarized as "Prev #N: user asked <intent>
        // of '<slot>'", which strips the verbatim assistant response (the
        // main vector for topic anchoring) while preserving intent/entity
        // signal. Empty on the first turn.
        // Replaces the older 6→3 turn flat-text limiter (Bug #013).
        let conversation = mem.compactHistory(maxTurns: 3)

        // Inject relevant user-profile memory (contacts, prefs, places) ahead
        // of the conversation transcript. Lets the FM router resolve names
        // and references that aren't in the recent turns ("call Marco" where
        // contact:marco was saved a week ago). No-op when the cache is empty
        // or no key matches the current utterance.
        let memContext = await GigiMemory.shared.contextString(for: text)
        let history: String
        if memContext.isEmpty {
            history = conversation
        } else if conversation.isEmpty {
            history = memContext
        } else {
            history = memContext + "\n\n" + conversation
        }

        let routeResult = await GigiRequestRouter.shared.route(text: text, history: history)
        let agentResult = routeResult.asAgentResult

        // Backfill the turn annotation using the most recent router trace
        // entry (every router branch records into GigiRouterTrace). This
        // turn now contributes a structured summary to the NEXT router
        // call's compactHistory(), instead of a verbatim assistant line.
        if let trace = GigiRouterTrace.shared.recent(count: 1).last {
            mem.annotateLastTurn(
                intent: trace.tool,
                slot: trace.slot,
                tier: trace.tier,
                success: !agentResult.isError
            )
        } else {
            mem.annotateLastTurn(
                intent: agentResult.executedTools.first,
                slot: nil,
                tier: nil,
                success: !agentResult.isError
            )
        }

        return agentResult
    }


    // MARK: - Deterministic NLU fast-path

    /// Cheap pre-flight check: does the user message look like an explicit
    /// "build/create/make a shortcut that …" request? If yes, the fast-path
    /// must be skipped because the inner description ("turns the flashlight
    /// on", "set a 5 min timer", …) would otherwise be mis-fired as a
    /// concrete tool by the NLU substring rules.
    ///
    /// Mirrors GigiRequestRouter.detectBuildShortcutPattern (same verb set)
    /// but only returns a boolean — the router still runs the canonical
    /// extraction afterward.
    /// Normalize the user's input by replacing smart punctuation that
    /// iOS keyboards introduce automatically (curly apostrophes/quotes,
    /// en/em dashes, NBSPs) with their ASCII equivalents. Idempotent.
    static func normalizeSmartPunctuation(_ text: String) -> String {
        var s = text
        // Apostrophes
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")  // right single quote
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")  // left single quote
        s = s.replacingOccurrences(of: "\u{02BC}", with: "'")  // modifier letter apostrophe
        // Quotation marks
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"") // left double quote
        s = s.replacingOccurrences(of: "\u{201D}", with: "\"") // right double quote
        // Dashes
        s = s.replacingOccurrences(of: "\u{2013}", with: "-")  // en dash
        s = s.replacingOccurrences(of: "\u{2014}", with: "-")  // em dash
        // Non-breaking space
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        // Ellipsis
        s = s.replacingOccurrences(of: "\u{2026}", with: "...")
        return s
    }

    static func looksLikeBuildShortcut(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        let pattern = #"^(?:build|make|create|compose|design|generate|costruisci|crea|fammi|componi|genera)\s+(?:\w+\s+){0,2}(?:short ?cut|scorciatoia)s?\b"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Memory recall probe
    //
    // Authoritative-memory short-circuit: when the user asks "who is Marco" /
    // "what is the wifi password" / "tell me about Sakura" and that key
    // exists in GigiMemory, return the stored value directly. Without this,
    // the FM router would route to delegate_local (Ollama) which doesn't
    // see the memory and hallucinates a generic encyclopaedic answer.
    //
    // Cache miss → return nil, let the router handle it as a knowledge query.

    /// Lightweight heuristic: does the utterance look like a question or
    /// recall-shaped request? Used as a guard before the content-match
    /// fallback so we don't accidentally recall on imperative statements
    /// like "call Marco" (which mentions Marco but is an action, not a
    /// recall).
    private static func looksLikeRecallQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        if t.hasSuffix("?") { return true }
        let questionStarters = [
            "what ", "what's ", "whats ", "where ", "where's ", "wheres ",
            "who ", "who's ", "whos ", "when ", "when's ", "whens ",
            "why ", "why's ", "whys ", "how ", "how's ", "hows ",
            "which ", "whose ",
            "tell me ", "show me", "remind me ", "do you know ", "do you remember ",
            "che ", "chi ", "cosa ", "cos'è ", "cose ", "dove ", "quando ",
            "perché ", "perche ", "come ", "dimmi ", "ricordami "
        ]
        return questionStarters.contains { t.hasPrefix($0) }
    }

    private func memoryRecallProbe(for text: String) async -> AgentResult? {
        let intent = GigiNLUEngine.shared.classify(text)
        var query: String
        var matchedValue: String?
        var matchedKey: String?

        // Path 1 — NLU classified as `recall` (canonical triggers like
        // "who is", "what's", "tell me about"). Do the canonical lookup.
        if intent.label == "recall" {
            query = (intent.params["query"] ?? intent.params["raw"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "?.,;:!"))
            guard !query.isEmpty else { return nil }
            matchedValue = await GigiMemory.shared.recallResolving(query)
            if matchedValue == nil {
                GigiDebugLogger.log("GIGI Agent: memory-probe MISS (NLU path) for '\(query)' — trying entity match")
            }
        } else {
            query = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "?.,;:!"))
        }

        // Path 2 — Entity-aware fallback. If the utterance looks like a
        // question and contains tokens that match a known cache key, fire
        // recall regardless of NLU classification. This catches typos and
        // unanticipated phrasings ("what my password", "tell me the wifi
        // password", "remind me my netflix password").
        if matchedValue == nil, Self.looksLikeRecallQuestion(text) {
            if let hit = await GigiMemory.shared.findByContentMatch(in: text) {
                matchedKey = hit.key
                matchedValue = hit.value
                // Use the key suffix as the query for nice speech output.
                let suffix = hit.key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? hit.key
                query = suffix
                GigiDebugLogger.log("GIGI Agent: memory-probe HIT (entity match) key='\(hit.key)'")
            }
        }

        guard let value = matchedValue else {
            GigiDebugLogger.log("GIGI Agent: memory-probe final MISS for '\(query)' — falling through to router")
            return nil
        }
        _ = matchedKey // referenced for clarity above

        // Flip first-person to second-person on BOTH sides so GIGI speaks
        // back coherently: user asked "my password" → GIGI says "your
        // password is hi124", not "my password is hi124".
        let subjectFlipped = GigiMemory.flipFirstPerson(query)
        let subjectCap = subjectFlipped.prefix(1).uppercased() + subjectFlipped.dropFirst()
        let valueFlipped = GigiMemory.flipFirstPerson(value)
        var speech = "\(subjectCap) is \(valueFlipped)."
        #if DEBUG
        speech = "[memory recall 1.00 '\(query)']\n" + speech
        #endif

        GigiDebugLogger.log("GIGI Agent: memory-probe HIT '\(query)' → '\(value.prefix(40))'")
        GigiRouterTrace.shared.record(
            utterance: text,
            tier: "memory",
            tool: "recall",
            confidence: 1.0,
            slot: query
        )
        GigiConversationMemory.shared.annotateLastTurn(
            intent: "recall", slot: query, tier: "memory", success: true
        )
        GigiConversationMemory.shared.addModelSpeech(speech)
        return AgentResult(
            speech:          speech,
            executedTools:   ["recall"],
            isFollowUp:      false,
            costEstimate:    0,
            requiresConfirm: nil,
            isError:         false
        )
    }

    private func deterministicFastPath(for text: String) async -> AgentResult? {
        let intent = GigiNLUEngine.shared.classify(text)
        guard intent.confidence >= 0.95,
              Self.fastPathIntents.contains(intent.label) else {
            return nil
        }

        GigiDebugLogger.log("GIGI fast-path: \(intent.label) (\(String(format: "%.2f", intent.confidence)))")

        let speech: String
        var executedTools: [String] = []
        if intent.label == "respond" {
            // GigiBrainPipeline.localSpeech moved to GigiFoundationAgent on 2026-05-11
            // (GigiBrainPipeline archived to _legacy/, was structural zombie).
            speech = GigiFoundationAgent.localSpeech(for: intent)
        } else {
            let bridgeResult = await GigiActionDispatcher.shared.bridge.execute(intent)
            if intent.label == "make_call", bridgeResult.hasPrefix("Calling ") {
                let contact = intent.params["contact"] ?? ""
                if !contact.isEmpty { await GigiMemory.shared.touchContactIfKnown(contact) }
            }
            speech = bridgeResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? GigiFoundationAgent.localSpeech(for: intent)
                : bridgeResult
            executedTools = [intent.label]
        }

        let nluSlot = intent.params["contact"] ?? intent.params["query"] ?? intent.params["text"]
        GigiRouterTrace.shared.record(
            utterance: text,
            tier: "nlu_fast",
            tool: intent.label,
            confidence: Float(intent.confidence),
            slot: nluSlot
        )
        GigiConversationMemory.shared.annotateLastTurn(
            intent: intent.label, slot: nluSlot, tier: "nlu_fast", success: true
        )
        GigiConversationMemory.shared.addModelSpeech(speech)
        return AgentResult(
            speech:          speech,
            executedTools:   executedTools,
            isFollowUp:      false,
            costEstimate:    0,
            requiresConfirm: nil,
            isError:         false
        )
    }

    // MARK: - Pending confirmation API (used by GigiSmartOrchestrator)

    /// Called by the orchestrator when the user explicitly confirms a destructive
    /// action that is pending in `pendingConfirmRequest`. Executes the tool and
    /// clears state.
    func confirmAndContinue() async -> AgentResult {
        guard let request = pendingConfirmRequest,
              let tool    = pendingConfirmTool else {
            return AgentResult(
                speech:          "Nothing pending confirmation.",
                executedTools:   [],
                isFollowUp:      false,
                costEstimate:    0,
                requiresConfirm: nil,
                isError:         false
            )
        }

        // Clear pending state before execution to prevent double-confirm
        let argsSnapshot = pendingConfirmArgs
        pendingConfirmRequest = nil
        pendingConfirmTool    = nil
        pendingConfirmArgs    = [:]

        let result = await tool.execute(args: argsSnapshot)
        let speech = result.error.map { "Couldn't complete that: \($0)" } ?? result.value

        GigiConversationMemory.shared.addModelSpeech(speech)

        return AgentResult(
            speech:          speech,
            executedTools:   [request.action],
            isFollowUp:      false,
            costEstimate:    0,  // Claude via subscription, no marginal API cost
            requiresConfirm: nil,
            isError:         result.error != nil
        )
    }

    /// Called by the orchestrator when the user's response is anything but a
    /// clear confirmation — cancels the pending action and (if it was a
    /// computer-use job) signals rejection to the harness.
    func cancelConfirmation() {
        if let jobId = pendingConfirmArgs["computerUseJobId"] as? String, !jobId.isEmpty {
            Task { await GigiComputerUse.shared.reject(jobId: jobId) }
        }
        pendingConfirmRequest = nil
        pendingConfirmTool    = nil
        pendingConfirmArgs    = [:]
    }

    #if DEBUG
    // MARK: - D1 Brain Path Override helpers (5-path plan testing harness)

    /// Path 2 (Apple FM) stub via existing GigiFoundationAgent.
    /// On unsupported devices, falls through to a graceful error.
    private func processAppleFMOverride(text: String) async -> AgentResult {
        guard GigiFoundationAgent.isSupported else {
            return AgentResult(
                speech: "Apple Foundation Models not available on this device. Need iOS 18.1+ with Apple Intelligence.",
                executedTools: [],
                isFollowUp: false,
                costEstimate: 0,
                requiresConfirm: nil,
                isError: true
            )
        }
        let history = GigiConversationMemory.shared.contents(pruningIfNeeded: true)
        let historyString = history.suffix(6).map { c in
            let role = c.role == "user" ? "User" : "Assistant"
            let text = c.parts.compactMap { $0.text }.joined(separator: " ")
            return "\(role): \(text)"
        }.joined(separator: "\n")
        guard let response = await GigiFoundationAgent.shared.process(text: text, history: historyString) else {
            return AgentResult(
                speech: "Apple Foundation Models returned no result for this query.",
                executedTools: [],
                isFollowUp: false,
                costEstimate: 0,
                requiresConfirm: nil,
                isError: true
            )
        }
        return AgentResult(
            speech: response.speech,
            executedTools: response.action.isEmpty ? [] : [response.action],
            isFollowUp: !response.followUp.isEmpty,
            costEstimate: 0,  // on-device, no $ cost
            requiresConfirm: nil,
            isError: false
        )
    }

    /// Path 3 (Ollama) — forces the request through GigiHarnessClient.runLocalLLM
    /// bypassing the router. Mirrors GigiRequestRouter.dispatchDelegateLocal
    /// minus the cost-aware fallback logic (the override is explicit so we
    /// honor it strictly).
    /// 2026-05-12 fix: was returning a hardcoded "Path 3 Ollama is not
    /// configured yet" stub from the GATE 4 scaffold; GATE 4.9 left this
    /// helper unmigrated. Replaced with real consumer.
    private func processOllamaOverride(text: String) async -> AgentResult {
        guard GigiHarnessClient.shared.isConfigured else {
            return AgentResult(
                speech: "Brain path Ollama requires a paired harness. Pair it from Settings.",
                executedTools: [], isFollowUp: false, costEstimate: 0,
                requiresConfirm: nil, isError: true
            )
        }
        let history = GigiConversationMemory.shared
            .contents(pruningIfNeeded: true).suffix(6).map { c in
                let role = c.role == "user" ? "User" : "Assistant"
                let t = c.parts.compactMap { $0.text }.joined(separator: " ")
                return "\(role): \(t)"
            }.joined(separator: "\n")

        var fullText = ""
        var sawError: String?
        for await event in GigiHarnessClient.shared.runLocalLLM(prompt: text, history: history) {
            switch event {
            case .chunk(let s):
                fullText += s
            case .done(let latencyMs):
                GigiDebugLogger.log("GIGI Override Ollama: done in \(latencyMs)ms · chunks=\(fullText.count) chars")
            case .error(let msg):
                sawError = msg
                GigiDebugLogger.log("GIGI Override Ollama: error \(msg)")
            }
        }
        let speech = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if speech.isEmpty {
            return AgentResult(
                speech: sawError.map { "Ollama failed: \($0)" } ?? "Ollama returned no answer. Try again or switch to Auto.",
                executedTools: [], isFollowUp: false, costEstimate: 0,
                requiresConfirm: nil, isError: true
            )
        }
        GigiConversationMemory.shared.addModelSpeech(speech)
        return AgentResult(
            speech: speech, executedTools: ["ollama"], isFollowUp: false,
            costEstimate: 0, requiresConfirm: nil, isError: false
        )
    }

    /// Legacy alias — kept for any caller that still references the stub.
    private func ollamaStubResult() -> AgentResult {
        AgentResult(
            speech: "Path 3 Ollama override now uses the harness — call processOllamaOverride(text:) instead.",
            executedTools: [], isFollowUp: false, costEstimate: 0,
            requiresConfirm: nil, isError: true
        )
    }

    /// Path 4 (Claude Code) — same effect as forceClaude=true.
    /// Returns nil if the harness is not paired and autoFallback is requested.
    private func processForceClaude(text: String, autoFallbackOnError: Bool) async -> AgentResult? {
        guard GigiHarnessClient.shared.isConfigured else {
            return AgentResult(
                speech: "Brain path Claude requires a paired harness. Pair it from Settings.",
                executedTools: [],
                isFollowUp: false,
                costEstimate: 0,
                requiresConfirm: nil,
                isError: true
            )
        }
        let result = await GigiClaudeBridge.shared.run(task: text, context: nil)
        if let err = result.error {
            return AgentResult(
                speech: err,
                executedTools: [],
                isFollowUp: false,
                costEstimate: 0,
                requiresConfirm: nil,
                isError: true
            )
        }
        return AgentResult(
            speech: result.value,
            executedTools: ["ask_claude"],
            isFollowUp: false,
            costEstimate: 0,  // Claude via subscription, no marginal API cost
            requiresConfirm: nil,
            isError: false
        )
    }
    #endif
}
