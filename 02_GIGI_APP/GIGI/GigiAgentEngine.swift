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
    //
    // POLICY: only SINGLE-SLOT or near-deterministic intents belong here.
    // Multi-slot ambiguous intents (send_message: contact + body + platform;
    // set_reminder: task + date + time; send_email: contact + subject +
    // body) are routed via Apple FM Tool calling instead, where
    // constrained-decoding @Generable extraction handles arbitrary sentence
    // structures — including post-coreference utterances like "send Marco
    // a message saying hi" that the NLU regex would mis-split.
    //
    // Removed 2026-05-15: send_message, set_reminder.
    private static let fastPathIntents: Set<String> = [
        "ask_time", "ask_date", "torch_on", "torch_off", "make_call",
        "navigate", "navigation", "set_timer", "set_alarm",
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

    /// Last normalized + coreference-resolved user utterance. Exposed to
    /// downstream tools (e.g. FMSendMessageTool) that need to validate
    /// Apple FM's slot extraction against the actual user text.
    static var currentUserUtterance: String = ""

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
        let normalized = Self.normalizeSmartPunctuation(text)
        let mem = GigiConversationMemory.shared
        // Coreference resolution — replace 3rd-person pronouns
        // (him/her/them/it/there) with the last referent of that kind.
        // Done BEFORE all routing tiers so every classifier sees the
        // resolved entity, not the pronoun. Conservative: only fires
        // when a referent of the matching kind was recorded.
        let resolved = Self.resolveCoreferences(normalized, memory: mem)
        if resolved != normalized {
            GigiDebugLogger.log("GIGI Agent: coreference resolved '\(normalized.prefix(60))' → '\(resolved.prefix(60))'")
        }
        let text = resolved
        Self.currentUserUtterance = text
        GigiDebugLogger.log("GIGI agentEngine.process ENTRY: text='\(text.prefix(60))'")

        // Pending clarification continuation — MUST run BEFORE the fast-path
        // and probe, otherwise "Hi" would get caught as a greeting (`respond`)
        // and the user's answer to "What do you want to say to Marco?" gets
        // lost. The router-side check still runs as a defense-in-depth for
        // non-fast-path turns.
        if let agentResult = await consumePendingClarificationIfAny(text: text) {
            mem.addUserTurn(text)
            return agentResult
        }
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
            // Refactor #6 Step 10 — Run the deterministic tier-0 pipeline
            // (math, alias, discovery, regex shortcuts, semantic catalog)
            // BEFORE the memory probe. Architectural fix for the over-match
            // bug where "what is 42 times 11" was intercepted by a garbage
            // memory key `contact:42 times 11`. Math is categorically NOT a
            // recall query — its rightful tier (MathExpressionTier) now wins
            // because tier-0 runs first.
            if let tier0 = await GigiRequestRouter.shared.runTier0(text: text) {
                return tier0.asAgentResult
            }

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

        // Persistent world-action memory (commit 4): inject the user's most
        // recent confirmed orders / purchases / bookings so the on-device
        // FM can propose "same as last time" without needing memory of its
        // own. Read-only — only Claude cloud writes here, so the local FM
        // cannot inject fabricated preferences.
        let pastOrdersContext = await GigiPersistentMemory.shared.contextString(limit: 5)

        // Task-state-aware follow-up disambiguation: pass the immediately
        // preceding assistant turn verbatim so Apple FM can interpret short
        // confirmations ("Go", "Yes", "Send it") as continuations of an
        // open task. Bug #013's compactHistory still strips multi-turn
        // history; only the single most recent assistant message is added
        // here, which is not enough to cause topic anchoring drift.
        let lastAssistant = mem.lastAssistantTurnVerbatim()
        var historyParts: [String] = []
        if !memContext.isEmpty { historyParts.append(memContext) }
        if !pastOrdersContext.isEmpty { historyParts.append(pastOrdersContext) }
        if !conversation.isEmpty { historyParts.append(conversation) }
        if let last = lastAssistant {
            historyParts.append("<assistant_previous_turn>\n\(last)\n</assistant_previous_turn>")
        }
        let history = historyParts.joined(separator: "\n\n")

        // Intelligent follow-up resolution: when there is a previous assistant
        // turn, run a small FM call to decide if the user reply continues the
        // open task or changes topic. On continuation, the model returns a
        // self-contained instruction (e.g. "Go" → "stage the salmon avocado
        // edamame mango bowl with spicy mayo on rice at Nana Poke Chiavari
        // via Just Eat"). On topic change, returns the text unchanged. This
        // unblocks short follow-ups that the small on-device router model
        // can't reliably interpret from history alone.
        var routerInputText = text
        #if canImport(FoundationModels)
        // Skip resolveFollowUp when a world-action proposal is pending: a
        // short "go" / "yes" / "no" needs to arrive RAW at the consent tier.
        // The FM resolver would otherwise rewrite "go" into a long instruction
        // based on the @Guide examples, which (a) hides the affirmative from
        // the matcher and (b) lets the FM hallucinate specifics that were
        // never in the original user request.
        let hasPendingWorldAction = mem.peekPendingWorldAction() != nil
        // Also skip when the utterance is ALREADY a clear, self-contained
        // command ("send a message to ...", "set a reminder ...", "call ..."):
        // resolveFollowUp is meant for SHORT replies ("go", "yes"). Letting it
        // rewrite a full command lets the FM splice in the previous assistant
        // turn (incl. its "[appleFM send_message 0.75]" debug prefix), e.g.
        // "Send a message to Armando batta saying he is late" -> "send_message
        // 0.75 Armando batta saying he is late", which loses the " to " marker
        // and breaks contact extraction.
        if #available(iOS 18.1, *), lastAssistant != nil, !hasPendingWorldAction,
           !GigiRequestRouter.looksLikeNewCommand(text) {
            routerInputText = await GigiFoundationSession.shared.resolveFollowUp(
                text: text,
                lastAssistantTurn: lastAssistant
            )
        }
        #endif

        let routeResult = await GigiRequestRouter.shared.route(text: routerInputText, history: history)
        let agentResult = routeResult.asAgentResult

        // Backfill the turn annotation using the most recent router trace
        // entry (every router branch records into GigiRouterTrace). This
        // turn now contributes a structured summary to the NEXT router
        // call's compactHistory(), instead of a verbatim assistant line.
        let traceEntry = GigiRouterTrace.shared.recent(count: 1).last
        let resolvedIntent = traceEntry?.tool ?? agentResult.executedTools.first
        let resolvedSlot   = traceEntry?.slot
        let resolvedTier   = traceEntry?.tier
        mem.annotateLastTurn(
            intent:  resolvedIntent,
            slot:    resolvedSlot,
            tier:    resolvedTier,
            success: !agentResult.isError
        )

        // Coreference bookkeeping: if the dispatched intent surfaced an
        // entity, remember it so the next turn can resolve pronouns
        // against it. Only on success — failures leave the previous
        // referent in place.
        // remember/recall need special handling: the subject can be a
        // person, a preference, or a thing — pref subjects MUST NOT
        // overwrite lastReferent[person] (otherwise the next "him"
        // resolves to "my default message platform" etc.).
        if !agentResult.isError,
           let intent = resolvedIntent,
           let slot = resolvedSlot, !slot.isEmpty {
            let kind: String?
            if intent == "remember" || intent == "recall" {
                kind = Self.referentKindForRememberRecall(subject: slot)
            } else {
                kind = Self.referentKind(for: intent)
            }
            if let k = kind {
                mem.recordReferent(slot, kind: k)
            }
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
    // MARK: - Pending clarification continuation

    /// If the previous turn left a pending clarification (e.g. "What do
    /// you want to say to Marco?"), consume the current utterance as the
    /// missing slot value and dispatch the completed intent. Returns nil
    /// to let normal processing continue when:
    ///   - there is no pending clarification
    ///   - the user issued a clear new command (set/turn/call/who/...)
    /// Returns an AgentResult when:
    ///   - the user cancelled (no/cancel/abort/...)
    ///   - the utterance was consumed as the slot value and dispatched.
    private func consumePendingClarificationIfAny(text: String) async -> AgentResult? {
        guard let pending = GigiConversationMemory.shared.consumePendingClarification() else {
            return nil
        }
        if GigiRequestRouter.detectNegative(in: text) {
            GigiDebugLogger.log("GIGI Agent: pending clarification CANCELLED")
            let speech = "Cancelled."
            GigiConversationMemory.shared.addModelSpeech(speech)
            return AgentResult(speech: speech, executedTools: ["\(pending.intent)_cancel"],
                               isFollowUp: false, costEstimate: 0,
                               requiresConfirm: nil, isError: false)
        }
        if GigiRequestRouter.looksLikeNewCommand(text) {
            GigiDebugLogger.log("GIGI Agent: pending clarification SUPERSEDED by new command")
            return nil
        }

        // Chain: if we just filled the `contact` slot of send_message,
        // the body is still missing. Clean filler prefixes ("To leo
        // corte" → "Leo Corte"), resolve relationships ("my brother" →
        // the saved name), save as person referent, and ask for body.
        if pending.intent == "send_message" && pending.slot == "contact" {
            let rawContact = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = await GigiRequestRouter.resolveContactFromMemory(rawContact)
            let cleaned = GigiRequestRouter.cleanContactName(rawContact)
            let contact: String
            if let r = resolved, !r.isEmpty {
                contact = r
            } else if !cleaned.isEmpty {
                contact = cleaned
            } else {
                contact = rawContact
            }
            GigiConversationMemory.shared.recordReferent(contact, kind: "person")
            let platform = pending.partialParams["platform"] ?? "imessage"
            let speech = "What do you want to say to \(contact)?"
            GigiConversationMemory.shared.setPendingClarification(.init(
                intent: "send_message",
                slot: "body",
                partialParams: ["contact": contact, "platform": platform],
                timestamp: Date()
            ))
            GigiDebugLogger.log("GIGI Agent: pending chained — contact='\(contact)' → asking for body")
            GigiConversationMemory.shared.addModelSpeech(speech)
            return AgentResult(speech: speech, executedTools: [],
                               isFollowUp: true, costEstimate: 0,
                               requiresConfirm: nil, isError: false)
        }

        var params = pending.partialParams
        params[pending.slot] = text
        params["raw"] = text
        let intent = GigiIntent(label: pending.intent, confidence: 1.0, params: params)
        let speech = await GigiActionBridge.shared.execute(intent)
        let finalSpeech = speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Done."
            : speech
        GigiDebugLogger.log("GIGI Agent: pending CONTINUED intent=\(pending.intent) slot=\(pending.slot) value='\(text.prefix(40))'")
        GigiRouterTrace.shared.record(
            utterance: text, tier: "clarification-continuation",
            tool: pending.intent, confidence: 1.0, slot: params[pending.slot]
        )
        GigiConversationMemory.shared.addModelSpeech(finalSpeech)
        return AgentResult(speech: finalSpeech, executedTools: [pending.intent],
                           isFollowUp: false, costEstimate: 0,
                           requiresConfirm: nil, isError: false)
    }

    // MARK: - Coreference resolver
    //
    // Substitutes 3rd-person pronouns (him/her/them/it/there) with the
    // last referent of the matching kind, tracked by
    // GigiConversationMemory. Runs after smart-punctuation normalization
    // and BEFORE every routing tier, so all downstream classifiers see
    // the resolved text. Conservative: only substitutes when the pronoun
    // appears as a whole word and a referent of the right kind exists.

    private static let pronounToKind: [(pattern: String, kind: String)] = [
        (#"\bhim\b"#,      "person"),
        (#"\bher\b"#,      "person"),
        (#"\bhe\b"#,       "person"),
        (#"\bshe\b"#,      "person"),
        (#"\bthem\b"#,     "person"),
        (#"\bthey\b"#,     "person"),
        (#"\bit\b"#,       "thing"),
        (#"\bthere\b"#,    "place")
    ]

    static func resolveCoreferences(_ text: String, memory: GigiConversationMemory) -> String {
        var resolved = text
        // Bug fix 2026-05-19 E2E-2: when the utterance already names an entity
        // explicitly (e.g. "Search Valentino Rossi and tell me how many
        // championships he won"), DO NOT substitute pronouns with stale
        // referents — "he" obviously refers to the freshly-named subject, not
        // to whoever happened to be lastReferent from a previous turn.
        // Heuristic: a TitleCased multi-word proper noun (e.g. "Valentino Rossi",
        // "Nikola Tesla", "Inter Milan") within the same utterance shadows
        // person-kind pronoun resolution. Place/thing pronouns ("it",
        // "there") are unaffected by this guard.
        let personEntityRegex = #"\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}\b"#
        // Also treat a single capitalized name right after a recipient marker
        // ("to Leo", "call Marco", "ask Sarah") as an explicit person, so
        // "send a message to Leo corte asking if he's on" does NOT rewrite
        // "he" into a stale (possibly garbled) referent — "he" obviously = Leo.
        // The multi-word TitleCase regex above misses "Leo corte" (lowercase
        // 2nd word), which let a bad referent ("Ready For Leo") corrupt the
        // utterance before routing.
        let recipientNameRegex = #"\b(?:to|call|text|message|tell|ask|with|for|of)\s+[A-Z][a-z]+"#
        let hasExplicitPersonName = text.range(of: personEntityRegex, options: .regularExpression) != nil
            || text.range(of: recipientNameRegex, options: .regularExpression) != nil

        for (pattern, kind) in pronounToKind {
            if kind == "person", hasExplicitPersonName {
                continue
            }
            guard let referent = memory.lastReferent(kind: kind), !referent.isEmpty else { continue }
            guard resolved.range(of: pattern, options: .regularExpression) != nil else { continue }
            // Whole-word, case-insensitive replacement.
            resolved = resolved.replacingOccurrences(
                of: pattern,
                with: referent,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return resolved
    }

    /// Maps a dispatched intent's slot to a coreference entity kind so
    /// the next turn can resolve "him/her/it/there" against it.
    /// Returns nil for intents that don't surface a referent.
    private static func referentKind(for intent: String) -> String? {
        switch intent {
        case "make_call", "send_message", "facetime", "facetime_audio":
            return "person"
        case "navigate", "navigation", "weather":
            return "place"
        case "play_music", "open_app", "set_timer", "set_alarm", "set_reminder":
            return "thing"
        default:
            // remember/recall are intentionally absent here — the subject
            // could be a person ("Marco"), a preference ("my password"),
            // or a thing ("the wifi password"). Callers must use
            // `referentKindForRememberRecall(subject:)` to inspect the
            // actual subject and decide.
            return nil
        }
    }

    /// remember/recall variant — inspects the subject to decide whether
    /// the referent should be tracked as a person (so "him/her" resolves
    /// to it) or skipped entirely (preferences/things shouldn't
    /// overwrite the last person referent).
    private static func referentKindForRememberRecall(subject: String) -> String? {
        let key = GigiMemory.smartKey(forSubject: subject)
        if key.hasPrefix("contact:") { return "person" }
        // pref:/place:/etc — don't pollute the person slot.
        return nil
    }

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
        if let kind = Self.referentKind(for: "recall") {
            GigiConversationMemory.shared.recordReferent(query, kind: kind)
        }
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
        // For `remember`, NLU passes the FULL body ("Marco is my brother")
        // as params["text"], not the subject. Parse it via
        // parseRememberKeyValue to recover the actual subject ("Marco")
        // so coreference resolves "him" → "Marco", not "him" → "Marco is
        // my brother". Only record as person referent when the parsed
        // key is a contact (NOT pref:/place:/etc — those shouldn't
        // overwrite lastReferent[person]).
        if intent.label == "remember" {
            let body = intent.params["text"] ?? intent.params["raw"] ?? ""
            if let (key, _) = GigiMemory.parseRememberKeyValue(contact: "", body: body) {
                let subjectRaw = key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
                let subject = subjectRaw.prefix(1).uppercased() + subjectRaw.dropFirst()
                if key.hasPrefix("contact:") {
                    GigiConversationMemory.shared.recordReferent(String(subject), kind: "person")
                }
            }
        } else if let kind = Self.referentKind(for: intent.label),
                  let slot = nluSlot, !slot.isEmpty {
            GigiConversationMemory.shared.recordReferent(slot, kind: kind)
        }
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
