import Foundation

// MARK: - GigiRequestRouter
//
// Phase 2 — the upfront 5-path router. Replaces the legacy 2-Gate flat
// (NLU fast-path → harness Claude bridge) with the architecture from
// `docs/plans/frolicking-stargazing-pancake.md` §3.
//
// Flow:
//   GigiAgentEngine.process(text:)
//     ├─ #if DEBUG: Brain Path Override (auto / appleFM / ollama / claude)
//     ├─ NLU fast-path (24 intents, on-device, <500ms)        — kept upstream
//     └─ GigiRequestRouter.shared.route(text:history:)        ← this file
//          ├─ Apple FM router via GigiFoundationSession.routeRequest()
//          │    └─ FoundationRouterDecision { path, action, slots, ... }
//          ├─ if Apple FM unavailable → GigiFallbackRouter (keyword-based)
//          └─ dispatchByPath:
//              ├─ native_tool       → dispatchNativeTool  (Apple FM Tools or bridge)
//              ├─ delegate_local    → dispatchDelegateLocal (Path 3 Ollama, GATE 4)
//              ├─ delegate_cloud    → dispatchDelegateCloud (Path 4 Claude Code, GATE 5)
//              ├─ ask_clarification → speak directSpeech
//              └─ reject            → speak directSpeech
//
// Mode-aware (GATE 7): when `gigi.user.mode` is set, the router disables
// paths not available in the selected mode and falls back accordingly.
//
// ADR-0007 — Hybrid 5-path router.

// MARK: - RouteResult

enum RouteResult {
    case spoken(String)                          // ready to TTS
    case actionInvoked(speech: String, tool: String)
    case error(String)
}

extension RouteResult {
    var asAgentResult: AgentResult {
        switch self {
        case .spoken(let text):
            return AgentResult(speech: text, executedTools: [], isFollowUp: false,
                               costEstimate: 0, requiresConfirm: nil, isError: false)
        case .actionInvoked(let speech, let tool):
            return AgentResult(speech: speech, executedTools: [tool], isFollowUp: false,
                               costEstimate: 0, requiresConfirm: nil, isError: false)
        case .error(let msg):
            return AgentResult(speech: msg, executedTools: [], isFollowUp: false,
                               costEstimate: 0, requiresConfirm: nil, isError: true)
        }
    }
}

// MARK: - GigiRequestRouter

@MainActor
final class GigiRequestRouter {
    static let shared = GigiRequestRouter()

    private let bridge = GigiActionBridge.shared
    private let harness = GigiHarnessClient.shared
    private let fallback = GigiFallbackRouter.shared

    private init() {}

    // MARK: - Entry point

    /// Routes a user utterance through the 5-path pipeline.
    /// Always returns a `RouteResult` — never throws. Errors are surfaced
    /// as `.error(message)` for the orchestrator to speak.
    func route(text: String, history: String = "") async -> RouteResult {
        // GATE 15 Step 0.5 — Conversational consent for active proposal card.
        //
        // When a ShortcutProposalCard is on screen, intercept simple
        // YES/NO confirmations BEFORE the normal routing fires. This lets
        // the user accept or dismiss the proposal by voice or chat without
        // tapping the card buttons — same UX pattern as the contact
        // disambiguation listener (ContactDisambiguationBubble).
        //
        // Guard against false positives: a long utterance that happens to
        // contain "yes" (e.g. "yes call mom from spotify") is NOT a consent —
        // fall through so the normal router can dispatch the actual intent.
        if let proposal = await MainActor.run(body: { GigiSmartOrchestrator.shared.shortcutProposal }) {
            let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = utterance.split { $0.isWhitespace }.count
            if wordCount > 0 && wordCount <= 4 {
                if Self.detectAffirmative(in: utterance) {
                    GigiDebugLogger.log("GIGI Router: proposal consent → CONFIRM via '\(utterance)'")
                    await MainActor.run { proposal.onConfirm() }
                    let speech = "Building '\(proposal.title)'..."
                    GigiConversationMemory.shared.addModelSpeech(speech)
                    return .actionInvoked(speech: speech, tool: "shortcut_proposal_confirm")
                }
                if Self.detectNegative(in: utterance) {
                    GigiDebugLogger.log("GIGI Router: proposal consent → CANCEL via '\(utterance)'")
                    await MainActor.run { proposal.onCancel() }
                    let speech = "Cancelled."
                    GigiConversationMemory.shared.addModelSpeech(speech)
                    return .actionInvoked(speech: speech, tool: "shortcut_proposal_cancel")
                }
            }
            // Card stays visible; user can still issue other intents.
        }

        // Bug #016 continuation — Pending clarification.
        //
        // If the previous turn was an override that asked the user for a
        // missing slot (e.g. "What do you want to say to Marco?"), use
        // THIS turn's text as that slot's value, complete the original
        // intent, and dispatch. The user can cancel with "no/cancel" or
        // implicitly by starting a new command verb (set/turn/call/...);
        // those cases fall through to the normal pipeline.
        if let pending = GigiConversationMemory.shared.consumePendingClarification() {
            if Self.detectNegative(in: text) {
                GigiDebugLogger.log("GIGI Router: pending clarification CANCELLED")
                let speech = "Cancelled."
                GigiConversationMemory.shared.addModelSpeech(speech)
                return .actionInvoked(speech: speech, tool: "\(pending.intent)_cancel")
            }
            if Self.looksLikeNewCommand(text) {
                GigiDebugLogger.log("GIGI Router: pending clarification SUPERSEDED by new command — falling through")
                // pending is already consumed; continue with normal routing
            } else {
                var params = pending.partialParams
                params[pending.slot] = text
                params["raw"] = text
                GigiDebugLogger.log("GIGI Router: pending clarification CONTINUED — intent=\(pending.intent) slot=\(pending.slot) value='\(text.prefix(40))'")
                let intent = GigiIntent(label: pending.intent, confidence: 1.0, params: params)
                let speech = await GigiActionBridge.shared.execute(intent)
                let finalSpeech = speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Done."
                    : speech
                GigiRouterTrace.shared.record(
                    utterance: text, tier: "clarification-continuation",
                    tool: pending.intent, confidence: 1.0, slot: params[pending.slot]
                )
                GigiConversationMemory.shared.addModelSpeech(finalSpeech)
                return .actionInvoked(speech: finalSpeech, tool: pending.intent)
            }
        }

        // GATE 9 polish — discovery intercept (Layer B preview, full impl GATE 10).
        // Discovery queries ("what can you do?", "cosa sai fare?", "help") are
        // handled BEFORE the semantic router because they need a curated
        // English overview response, not a tool dispatch.
        if detectDiscoveryQuery(in: text) {
            let speech = discoveryOverviewResponse()
            GigiDebugLogger.log("GIGI Router: discovery intercept → curated overview")
            GigiConversationMemory.shared.addModelSpeech(speech)
            return .spoken(speech)
        }

        // GATE 14.B.2 lite — Registered-Shortcut alias intercept.
        //
        // The user can register their own Apple Shortcuts in Settings with
        // natural-language aliases (e.g. Shortcut "accendi torcia" with
        // alias "open torch"). When the utterance matches any registered
        // alias literally, dispatch run_shortcut directly. Bypasses Apple
        // FM and the deterministic verb regex below — explicit user-
        // declared alias has highest priority.
        if let registered = GigiShortcutRegistry.shared.matchAlias(text) {
            GigiDebugLogger.log("GIGI Router: registered-alias match → '\(registered.name)' from utterance '\(text)'")
            GigiShortcutRegistry.shared.recordUse(name: registered.name)
            let speech = await GigiActionBridge.shared.execute(GigiIntent(
                label: "run_shortcut",
                confidence: 1.0,
                params: ["name": registered.name, "raw": registered.name, "input": ""]
            ))
            let finalSpeech = debugPrefix(
                routerSource: "alias",
                tool: "run_shortcut",
                confidence: 1.0,
                slot: registered.name
            ) + speech
            GigiRouterTrace.shared.record(
                utterance: text, tier: "alias",
                tool: "run_shortcut", confidence: 1.0, slot: registered.name
            )
            GigiConversationMemory.shared.addModelSpeech(finalSpeech)
            return .actionInvoked(speech: finalSpeech, tool: "run_shortcut")
        }

        // GATE 10.C tier-0 — Math expression detection.
        //
        // NLEmbedding word vectors don't index pure-number tokens, so
        // "What's 47 times 23" collapses to just {what, times} for the
        // semantic match — diluted similarity, falls through to Apple FM
        // which routes to delegate_local (LLM does arithmetic, slow + costly).
        //
        // Direct detection: if the utterance contains digit-operator-digit
        // patterns (or "X plus Y", "X times Y" etc.), dispatch calculate_math
        // directly. The expression evaluator handles the math via NSExpression
        // in microseconds. 100x faster than delegating to an LLM.
        if let mathExpression = detectMathExpression(in: text) {
            GigiDebugLogger.log("GIGI Router: tier-0 calculate_math → '\(mathExpression)'")
            let speech = await GigiActionBridge.shared.execute(GigiIntent(
                label: "calculate_math",
                confidence: 1.0,
                params: ["expression": mathExpression, "raw": mathExpression]
            ))
            let finalSpeech = debugPrefix(
                routerSource: "regex",
                tool: "calculate_math",
                confidence: 1.0,
                slot: mathExpression
            ) + speech
            GigiRouterTrace.shared.record(
                utterance: text, tier: "regex",
                tool: "calculate_math", confidence: 1.0, slot: mathExpression
            )
            GigiConversationMemory.shared.addModelSpeech(finalSpeech)
            return .actionInvoked(speech: finalSpeech, tool: "calculate_math")
        }

        // Phase 2 tier-0 — Explicit "build/create/make a shortcut" pattern.
        //
        // Option A (ADR-0014 follow-up): route DIRECTLY to the harness
        // Claude composer (bypass Apple FM). Apple FM on-device is
        // unreliable at structured JSON synthesis for multi-step shortcuts —
        // it frequently returns conversational apologies ("I'm sorry, but
        // I couldn't build the shortcut...") instead of invoking the tool.
        // Claude in the harness produces correct {title, actions[]} JSON
        // on the first try, then translates to Cherri DSL, signs, and
        // returns a URL. Trade-off: ~3-12s harness round-trip.
        if let description = detectBuildShortcutPattern(in: text) {
            GigiDebugLogger.log("GIGI Router: regex tier-0 build_shortcut → '\(description)' (via harness composer)")
            let speech = await GigiActionBridge.shared.composeShortcut(rawText: text)
            let withPrefix = debugPrefix(
                routerSource: "regex+claude",
                tool: "build_shortcut",
                confidence: 1.0,
                slot: description
            ) + speech
            GigiRouterTrace.shared.record(
                utterance: text, tier: "regex",
                tool: "build_shortcut", confidence: 1.0, slot: description, path: "harness"
            )
            GigiConversationMemory.shared.addModelSpeech(withPrefix)
            return .actionInvoked(speech: withPrefix, tool: "build_shortcut")
        }

        // GATE 9.A + GATE 15 fix — Explicit verb regex tier-0 fast-path.
        //
        // Restored after GATE 15 device test showed semantic router fails
        // for "Run X" where X is a single concrete word ("call", "mom",
        // "luce"). Word embedding averages bias toward the concrete word's
        // tool (make_call, homekit_on) and lose the run intent signal.
        //
        // Regex is precision-100 for explicit verbs (run/execute/launch/
        // trigger/esegui/lancia) — any text after the verb IS a Shortcut
        // name by definition. Semantic router stays as tier-1 fallback
        // for natural variants the regex doesn't cover.
        if let shortcutName = detectRunShortcutPattern(in: text) {
            GigiDebugLogger.log("GIGI Router: regex tier-0 run_shortcut → '\(shortcutName)'")
            let speech = await GigiActionBridge.shared.execute(GigiIntent(
                label: "run_shortcut",
                confidence: 1.0,
                params: ["name": shortcutName, "raw": shortcutName, "input": ""]
            ))
            let finalSpeech = debugPrefix(
                routerSource: "regex",
                tool: "run_shortcut",
                confidence: 1.0,
                slot: shortcutName
            ) + speech
            GigiRouterTrace.shared.record(
                utterance: text, tier: "regex",
                tool: "run_shortcut", confidence: 1.0, slot: shortcutName
            )
            GigiConversationMemory.shared.addModelSpeech(finalSpeech)
            return .actionInvoked(speech: finalSpeech, tool: "run_shortcut")
        }

        // GATE 15 — Smart Router semantic fast-path.
        //
        // Replaces the deterministic regex intercepts (run_shortcut,
        // web_search, etc.) with a single semantic-embedding match against a
        // curated catalog of trigger phrases per tool. NLEmbedding word
        // vectors via Accelerate (~5ms per query, fully on-device).
        //
        // On confident match (cosine ≥0.55, gap ≥0.05 vs runner-up):
        //   - dispatch the tool directly with the extracted slot
        //   - bypass Apple FM entirely (zero LLM tokens spent)
        //
        // On ambiguous or low-confidence: fall through to Apple FM —
        // no behavioral regression for queries the catalog doesn't cover.
        //
        // ADR-0012 — Smart Router Architecture.
        if let match = GigiSemanticRouter.shared.match(text) {

            // Special case Phase 2 (option A): semantic build_shortcut
            // routes to the harness Claude composer, same as tier-0 regex.
            // Apple FM is skipped — see comment above the tier-0 block.
            if match.toolName == "build_shortcut" {
                GigiDebugLogger.log("GIGI Router: semantic build_shortcut → harness composer (slot='\(match.slot)')")
                let speech = await GigiActionBridge.shared.composeShortcut(rawText: text)
                let withPrefix = debugPrefix(
                    routerSource: "semantic+claude",
                    tool: "build_shortcut",
                    confidence: match.confidence,
                    slot: match.slot
                ) + speech
                GigiRouterTrace.shared.record(
                    utterance: text, tier: "semantic",
                    tool: "build_shortcut", confidence: match.confidence,
                    slot: match.slot, path: "harness"
                )
                GigiConversationMemory.shared.addModelSpeech(withPrefix)
                return .actionInvoked(speech: withPrefix, tool: "build_shortcut")
            } else {
                let params = buildSemanticParams(for: match)
                let speech = await GigiActionBridge.shared.execute(GigiIntent(
                    label: match.toolName,
                    confidence: Double(match.confidence),
                    params: params
                ))
                let finalSpeech = debugPrefix(
                    routerSource: "semantic",
                    tool: match.toolName,
                    confidence: match.confidence,
                    slot: match.slot
                ) + speech
                GigiRouterTrace.shared.record(
                    utterance: text, tier: "semantic",
                    tool: match.toolName, confidence: match.confidence,
                    slot: match.slot
                )
                GigiConversationMemory.shared.addModelSpeech(finalSpeech)
                return .actionInvoked(speech: finalSpeech, tool: match.toolName)
            }
        }

        // Bug #017 (2026-05-15) — Pre-FM preference assertion intercept.
        //
        // Apple FM confidently mis-classifies "My default message platform
        // is WhatsApp" as native_tool(send_message) because of the
        // "message"/"WhatsApp" tokens. The post-FM Bug #015 override
        // doesn't fire because effectivePath is already native_tool.
        // Catch possessive assertions ("my X is Y") BEFORE Apple FM ever
        // sees them — these are unambiguously personal preferences.
        if let (subject, value) = Self.detectFactAssertion(in: text),
           Self.looksLikePreferenceAssertion(subject: subject) {
            GigiDebugLogger.log("GIGI Router: pre-FM preference assertion → bridge(remember). subject='\(subject)' value='\(value)'")
            let intent = GigiIntent(
                label: "remember",
                confidence: 1.0,
                params: ["contact": subject, "body": value, "raw": text]
            )
            let speech = await GigiActionBridge.shared.execute(intent)
            let finalSpeech = speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Got it. I'll remember that."
                : speech
            GigiRouterTrace.shared.record(
                utterance: text, tier: "preference-intercept",
                tool: "remember", confidence: 1.0, slot: subject
            )
            GigiConversationMemory.shared.annotateLastTurn(
                intent: "remember", slot: subject, tier: "preference-intercept", success: true
            )
            GigiConversationMemory.shared.addModelSpeech(finalSpeech)
            return .actionInvoked(speech: finalSpeech, tool: "remember")
        }

        // Mode gating (GATE 7) — read the selected operating mode and use
        // it to disable paths upfront. `.auto` (no mode set) keeps all paths.
        let mode = currentMode()

        // Latency anchor for the appleFM/fallback branch — measures from
        // the moment we commit to invoking the FM router (after every
        // tier-0 intercept has missed) until dispatch is decided.
        let fmStart = Date()

        // 1. Decide which router to use: Apple FM if available + mode allows
        //    Path 2; otherwise GigiFallbackRouter (rule-based keyword matching).
        let decision: FoundationRouterDecision
        if applefmAvailable && mode.allowsAppleFMRouter {
            #if canImport(FoundationModels)
            if #available(iOS 18.1, *) {
                do {
                    decision = try await GigiFoundationSession.shared.routeRequest(text: text, history: history)
                } catch {
                    GigiDebugLogger.log("GIGI Router: Apple FM failed (\(error.localizedDescription)) — falling back to keyword router.")
                    decision = fallback.classifyRequest(text: text)
                }
            } else {
                decision = fallback.classifyRequest(text: text)
            }
            #else
            decision = fallback.classifyRequest(text: text)
            #endif
        } else {
            decision = fallback.classifyRequest(text: text)
        }

        // 2. Apply mode-based path remapping (GATE 7).
        var effectivePath = mode.remap(decision.path, capabilities: decision.requiredCapabilities)

        // 2.5 Bug #003 fix (2026-05-12) — defensive downgrade.
        // Apple FM router sometimes mis-routes knowledge Q&A as
        // delegate_cloud (e.g. "Explain Bayes theorem"). If path is
        // delegate_cloud but the user's text contains NO web/code/image
        // verb AND the router didn't claim any browser/code/vision
        // capability, downgrade to delegate_local. Saves a useless
        // Claude Code spawn (and a /login error if claude isn't logged in)
        // for queries that the local Ollama model can answer.
        if effectivePath == "delegate_cloud"
            && !Self.hasWebOrCodeOrImageVerb(text)
            && decision.requiredCapabilities.isEmpty {
            GigiDebugLogger.log("GIGI Router: delegate_cloud DOWNGRADED to delegate_local — no web/code/image verb in prompt")
            effectivePath = "delegate_local"
        }

        // 2.55 Bug #015 fix (2026-05-15) — fact-assertion override.
        // Apple FM sometimes routes bare fact assertions ("Sergio is my
        // brother", "My favorite color is blue") to delegate_local, where
        // Ollama just generates a conversational "Got it" without
        // persisting anything. Detect the pattern and force native_tool
        // remember with slots extracted from the regex match.
        if let (subject, value) = Self.detectFactAssertion(in: text),
           effectivePath == "delegate_local" || effectivePath == "ask_clarification" {
            GigiDebugLogger.log("GIGI Router: fact-assertion OVERRIDE — \(effectivePath) → bridge(remember). subject='\(subject)' value='\(value)'")
            // Dispatch directly via the bridge — DON'T re-route through
            // dispatchNativeTool, which would call Apple FM tool-calling
            // (Path A) and re-extract the subject from the raw text.
            // FM's re-extraction is unstable ("My favorite movie" can
            // collapse to just "movie"), which produces a save key that
            // doesn't match the subsequent recall query. Keeping the
            // regex-extracted slots is what makes round-trip work.
            let intent = GigiIntent(
                label: "remember",
                confidence: 1.0,
                params: ["contact": subject, "body": value, "raw": text]
            )
            let speech = await GigiActionBridge.shared.execute(intent)
            let finalSpeech = speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Got it. I'll remember that."
                : speech
            GigiRouterTrace.shared.record(
                utterance: text, tier: "regex-override",
                tool: "remember", confidence: 1.0, slot: subject
            )
            GigiConversationMemory.shared.annotateLastTurn(
                intent: "remember", slot: subject, tier: "regex-override", success: true
            )
            // Coreference: track the asserted subject so the next turn
            // can resolve "him/her" to it — but ONLY if the subject is
            // actually a person (not a preference like "my password").
            // smartKey returns "contact:..." for names, "pref:..." for
            // preferences. Only record on contact.
            if GigiMemory.smartKey(forSubject: subject).hasPrefix("contact:") {
                GigiConversationMemory.shared.recordReferent(subject, kind: "person")
            }
            GigiConversationMemory.shared.addModelSpeech(finalSpeech)
            return .actionInvoked(speech: finalSpeech, tool: "remember")
        }

        // 2.56 Bug #016 fix (2026-05-15) — messaging-without-body override.
        // Apple FM occasionally routes "Send Marco a message" (no body)
        // to delegate_local, dumping the request to Ollama which has no
        // messaging tools and answers with a verbose apology. Detect
        // messaging-shape utterances missing a body indicator and force
        // ask_clarification with a sensible prompt.
        if let detected = Self.detectMessageWithoutBody(in: text) {
            // Relationship resolution: "my brother" → look up who that is.
            // If found, substitute. So "Send a message to my brother"
            // becomes "What do you want to say to Leo Corte?" not "to
            // My Brother?".
            let resolvedContact = (await Self.resolveContactFromMemory(detected)) ?? detected
            let contact = resolvedContact
            let directSpeech = "What do you want to say to \(contact)?"
            let platform = await Self.resolveMessagePlatform(forUtterance: text)
            GigiDebugLogger.log("GIGI Router: msg-without-body OVERRIDE — \(effectivePath) → ask_clarification, contact='\(contact)' (detected='\(detected)') platform='\(platform)'")
            GigiConversationMemory.shared.setPendingClarification(.init(
                intent: "send_message",
                slot: "body",
                partialParams: ["contact": contact, "platform": platform],
                timestamp: Date()
            ))
            // Track resolved contact as person referent so future "him"
            // works.
            GigiConversationMemory.shared.recordReferent(contact, kind: "person")
            GigiRouterTrace.shared.record(
                utterance: text, tier: "regex-override",
                tool: "ask_clarification", confidence: 1.0, slot: contact
            )
            GigiConversationMemory.shared.annotateLastTurn(
                intent: "ask_clarification", slot: contact, tier: "regex-override", success: true
            )
            GigiConversationMemory.shared.addModelSpeech(directSpeech)
            return .spoken(directSpeech)
        }

        // Bug #018 — messaging shape with unresolved pronoun.
        // "Send him a message" with no known person referent. We rejected
        // it in detectMessageWithoutBody (pronoun guard) — but rather
        // than fall through to Ollama, ask for the contact explicitly.
        // Then the next turn supplies the name, we save it as the
        // person referent, and re-run as if the user had typed the name.
        if Self.detectMessageWithUnresolvedContact(in: text) {
            let platform = await Self.resolveMessagePlatform(forUtterance: text)
            let directSpeech = "Who do you want to send a message to?"
            GigiDebugLogger.log("GIGI Router: msg-unresolved-contact OVERRIDE — \(effectivePath) → ask_clarification")
            GigiConversationMemory.shared.setPendingClarification(.init(
                intent: "send_message",
                slot: "contact",
                partialParams: ["platform": platform],
                timestamp: Date()
            ))
            GigiRouterTrace.shared.record(
                utterance: text, tier: "regex-override",
                tool: "ask_clarification", confidence: 1.0, slot: nil
            )
            GigiConversationMemory.shared.annotateLastTurn(
                intent: "ask_clarification", slot: nil, tier: "regex-override", success: true
            )
            GigiConversationMemory.shared.addModelSpeech(directSpeech)
            return .spoken(directSpeech)
        }

        // 2.6 Bug #014 fix (2026-05-15) — ask_clarification downgrade.
        // After turn-annotation refactor, Apple FM occasionally bounces
        // open-knowledge questions ("Who is Einstein?") to
        // ask_clarification with low confidence because it isn't sure
        // whether the entity is a contact or a public figure. Memory has
        // already been probed upstream (GigiAgentEngine.memoryRecallProbe)
        // and missed — so the safest fallback is delegate_local. Ollama
        // can always answer who/what/why/how knowledge queries.
        if effectivePath == "ask_clarification"
            && decision.confidence < 0.75
            && Self.looksLikeOpenKnowledgeQuery(text) {
            GigiDebugLogger.log("GIGI Router: ask_clarification DOWNGRADED to delegate_local — open knowledge query pattern (\(text.prefix(40)))")
            effectivePath = "delegate_local"
        }

        // Bug #012 fix (2026-05-12) — telemetry to harness Live Monitor.
        // For every router decision, fire-and-forget a telemetry event so the
        // live monitor at localhost:7777/live.html shows what the iPhone is
        // doing even when the path stays on-device. No-op when not paired.
        let fmElapsedMs = Int(Date().timeIntervalSince(fmStart) * 1000)
        harness.postTelemetry(
            type: "router_decision",
            path: effectivePath,
            primaryAction: decision.primaryAction,
            userText: text,
            elapsedMs: fmElapsedMs
        )
        // Pick a representative slot for the trace summary — first non-empty
        // among contact/taskText/body/destination/duration.
        let traceSlot: String? = {
            let s = decision.slots
            for v in [s.contact, s.taskText, s.body, s.destination, s.duration] where !v.isEmpty {
                return v
            }
            return nil
        }()
        GigiRouterTrace.shared.record(
            utterance: text,
            tier: applefmAvailable && mode.allowsAppleFMRouter ? "appleFM" : "fallback",
            tool: decision.primaryAction.isEmpty ? effectivePath : decision.primaryAction,
            confidence: Float(decision.confidence),
            slot: traceSlot,
            path: effectivePath,
            latencyMs: fmElapsedMs
        )

        // 3. Dispatch.
        let result: RouteResult
        switch effectivePath {
        case "native_tool":
            result = await dispatchNativeTool(decision: decision, originalText: text, history: history)
        case "delegate_local":
            result = await dispatchDelegateLocal(decision: decision, originalText: text, history: history)
        case "delegate_cloud":
            result = await dispatchDelegateCloud(decision: decision, originalText: text, history: history)
        case "ask_clarification":
            result = .spoken(decision.directSpeech.isEmpty
                ? "Could you say that another way?"
                : decision.directSpeech)
        case "reject":
            result = .spoken(decision.directSpeech.isEmpty
                ? "I can't help with that one."
                : decision.directSpeech)
        case "mode_blocked_local":
            result = .spoken("Local AI is disabled in this mode. Switch to Local-First or Full Power mode to enable Ollama.")
        case "mode_blocked_cloud":
            result = .spoken("Cloud mode is disabled in this mode. Switch to Apple Optimized or Full Power mode to enable Claude Code.")
        default:
            return .error("Unknown routing decision: \(effectivePath).")
        }

        // GATE 15 — DEBUG-only routing diagnostic. Prepends a one-line tag
        // showing which router fired (appleFM path + primaryAction) so the
        // user can immediately see what got dispatched. Stripped in release
        // builds via `#if DEBUG` in `debugPrefix()`.
        let primaryAction = decision.primaryAction.isEmpty ? effectivePath : decision.primaryAction
        let prefix = debugPrefix(
            routerSource: "appleFM",
            tool: primaryAction,
            confidence: Float(decision.confidence)
        )
        return prefix.isEmpty ? result : prependDebug(prefix, to: result)
    }

    /// Internal helper — re-wraps a RouteResult with the given debug prefix
    /// prepended to the speech, preserving the case (.spoken / .actionInvoked /
    /// .error). No-op when prefix is empty (release build).
    // MARK: - GATE 15 Step 0.5 — Conversational consent matchers

    /// Whole-word match for affirmative consent on a pending Shortcut
    /// proposal card. EN + IT. Case-insensitive. Whole-word so "yes I
    /// want to call mom" still matches — caller gates by ≤4 word length
    /// to keep false positives down.
    static func detectAffirmative(in text: String) -> Bool {
        let lowered = text.lowercased()
        let words = [
            "yes", "yeah", "yep", "yup", "sure", "ok", "okay",
            "go", "do it", "build", "build it", "make it", "let's go",
            "sì", "si", "vai", "fallo", "crealo", "certo", "dai",
            "facciamolo", "procedi", "ok vai", "vai vai"
        ]
        for w in words {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b"
            if lowered.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// Whole-word match for negative consent (dismiss / cancel) on a
    /// pending Shortcut proposal card. Mirror of `detectAffirmative`.
    static func detectNegative(in text: String) -> Bool {
        let lowered = text.lowercased()
        let words = [
            "no", "nope", "nah", "cancel", "abort", "dismiss", "skip", "stop",
            "annulla", "lascia stare", "non importa", "fermati", "non farlo",
            "lascia perdere", "non ora"
        ]
        for w in words {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b"
            if lowered.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    private func prependDebug(_ prefix: String, to result: RouteResult) -> RouteResult {
        switch result {
        case .spoken(let s):
            return .spoken(prefix + s)
        case .actionInvoked(let s, let tool):
            return .actionInvoked(speech: prefix + s, tool: tool)
        case .error(let msg):
            return .error(prefix + msg)
        }
    }

    // MARK: - Availability cache

    private var applefmAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 18.1, *) {
            return GigiFoundationSession.shared.isAvailable
        }
        #endif
        return false
    }

    // MARK: - Dispatch: native_tool (Path 2)
    //
    // Two execution modes depending on capability + feature flag:
    //
    // (A) "Pure Apple FM Tool calling" — iOS 26+ and matching FMTool exists:
    //     Pass the user text + the single matching tool to Apple FM via
    //     `respondWithTools`. Apple FM does the slot extraction + invokes
    //     `tool.call(arguments:)`, which internally dispatches to
    //     GigiActionBridge.execute. Latency 1-2s but slot quality is best
    //     (constrained decoding). Toggled by `gigi.feature.path2_apple_fm_tools`
    //     UserDefaults (default true on iOS 26+).
    //
    // (B) "Slot-extracted bridge path" — iOS <26, no matching FMTool, or
    //     feature flag off: take `decision.slots` already populated by the
    //     router itself, map to GigiIntent params, dispatch directly via
    //     GigiActionBridge.execute. Latency 80-200ms (no extra Apple FM
    //     round-trip).
    //
    // Both paths converge to the same bridge + speech logic.

    private func dispatchNativeTool(
        decision: FoundationRouterDecision,
        originalText: String,
        history: String
    ) async -> RouteResult {
        let action = decision.primaryAction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else {
            // Router gave us native_tool but no action — fall through to
            // delegate_cloud as the safest recovery.
            return await dispatchDelegateCloud(decision: decision, originalText: originalText, history: history)
        }

        // (A) Pure Apple FM Tool calling path.
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), appleFMToolsEnabled() {
            if let tool = GigiFoundationToolRegistry.tool(for: action) {
                let prompt = decision.delegatePrompt.isEmpty ? originalText : decision.delegatePrompt
                do {
                    let result = try await GigiFoundationSession.shared.respondWithTools(
                        text: prompt,
                        tools: [tool],
                        history: history
                    )
                    let speech = result.directSpeech?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let final = speech.isEmpty
                        ? GigiFoundationAgent.localSpeech(for: GigiIntent(label: action, confidence: 1.0, params: [:]))
                        : speech
                    GigiDebugLogger.log("GIGI Router → native_tool[FM]: action=\(action) latencyMs=\(result.latencyMs)")
                    GigiConversationMemory.shared.addModelSpeech(final)
                    return .actionInvoked(speech: final, tool: action)
                } catch {
                    GigiDebugLogger.log("GIGI Router: respondWithTools failed (\(error.localizedDescription)) — falling back to slot bridge.")
                    // Fall through to (B).
                }
            }
        }
        #endif

        // (B) Slot-extracted bridge path.
        let params = paramsFromSlots(decision.slots, action: action, originalText: originalText)
        let intent = GigiIntent(label: action, confidence: max(0.9, decision.confidence), params: params)

        GigiDebugLogger.log("GIGI Router → native_tool[bridge]: action=\(action) params=\(params)")
        let speech = await bridge.execute(intent)
        let final = speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? GigiFoundationAgent.localSpeech(for: intent)
            : speech
        GigiConversationMemory.shared.addModelSpeech(final)
        return .actionInvoked(speech: final, tool: action)
    }

    /// Read the runtime feature flag for the pure Apple FM Tool calling path.
    /// Default `true` on iOS 26+ when not explicitly disabled. Setting to
    /// false disables (A) and forces (B) bridge path for all native_tool
    /// dispatches — useful for A/B testing accuracy + latency trade-off.
    private func appleFMToolsEnabled() -> Bool {
        let key = "gigi.feature.path2_apple_fm_tools"
        if UserDefaults.standard.object(forKey: key) == nil {
            return true   // default on
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    // MARK: - Dispatch: delegate_local (Path 3 — Ollama)

    private func dispatchDelegateLocal(
        decision: FoundationRouterDecision,
        originalText: String,
        history: String
    ) async -> RouteResult {
        // Cost-aware safety net: if the router said delegate_local but the
        // capabilities require a browser, bump up to cloud.
        let caps = Set(decision.requiredCapabilities)
        if !caps.isDisjoint(with: ["browser", "code", "vision", "web_search"]) {
            GigiDebugLogger.log("GIGI Router: delegate_local upgraded to delegate_cloud (capabilities=\(decision.requiredCapabilities))")
            return await dispatchDelegateCloud(decision: decision, originalText: originalText, history: history)
        }

        let prompt = decision.delegatePrompt.isEmpty ? originalText : decision.delegatePrompt

        guard harness.isConfigured else {
            return .error("Local AI needs a paired harness. Pair the harness from Settings to enable Ollama.")
        }

        GigiDebugLogger.log("GIGI Router → delegate_local: prompt=\(prompt.prefix(80))")
        var fullText = ""
        var sawError: String?
        for await event in harness.runLocalLLM(prompt: prompt, history: history) {
            switch event {
            case .chunk(let text):
                fullText += text
            case .done(let latencyMs):
                GigiDebugLogger.log("GIGI Router: delegate_local done in \(latencyMs)ms")
            case .error(let msg):
                sawError = msg
            }
        }

        if let err = sawError, fullText.isEmpty {
            // Ollama unreachable → soft fallback to delegate_cloud if mode allows.
            let mode = currentMode()
            if mode.allowsCloud, harness.isConfigured {
                GigiDebugLogger.log("GIGI Router: Ollama unavailable (\(err)) — falling back to Claude Code.")
                return await dispatchDelegateCloud(decision: decision, originalText: originalText, history: history)
            }
            return .error("Local AI failed: \(err)")
        }

        let speech = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        GigiConversationMemory.shared.addModelSpeech(speech)
        return .spoken(speech.isEmpty ? "I couldn't think that through. Try rephrasing." : speech)
    }

    // MARK: - Dispatch: delegate_cloud (Path 4 — Claude Code)

    private func dispatchDelegateCloud(
        decision: FoundationRouterDecision,
        originalText: String,
        history: String
    ) async -> RouteResult {
        // Bug #014 fix (2026-05-12): prepend a [User context: …] header to
        // every delegate_cloud prompt so Claude knows the user's country,
        // locale, and timezone. Without this, Claude defaults to UK/London
        // for "JustEat", US for "Amazon", etc. — extremely visible failure.
        // The harness operator manual (`.claude-sandbox/CLAUDE.md`) instructs
        // Claude to parse this header and localize the response.
        let rawPrompt = decision.delegatePrompt.isEmpty ? originalText : decision.delegatePrompt
        let prompt = Self.prependUserContext(to: rawPrompt)

        guard harness.isConfigured else {
            return .error("Cloud AI needs a paired harness. Pair it from Settings to enable Claude Code.")
        }

        // Phase 2 transitional: use the existing GigiClaudeBridge.run() path
        // until GATE 5 wires GigiHarnessClient.runClaudeCode with MCP support.
        // This keeps continuity — every delegate_cloud query still produces a
        // response — while the new streaming endpoint is being built out.
        GigiDebugLogger.log("GIGI Router → delegate_cloud: prompt=\(prompt.prefix(80)) caps=\(decision.requiredCapabilities)")

        // Try the new streaming runClaudeCode first; fall back to the legacy
        // bridge if the new endpoint is not yet deployed on the harness.
        var collected = ""
        var streamingFailed = false
        // 2026-05-12 defensive fix: Apple FM occasionally classifies "search the
        // web" / "look up X" / "cerca su internet" as delegate_cloud but forgets
        // to set requiredCapabilities=[browser]. Without browser MCP, Claude
        // Code spawns toolless and produces hollow text answers. Since any
        // delegate_cloud is likely to need the web (otherwise FM would pick
        // delegate_local), always attach harness-browser. Claude can ignore it
        // when not needed — the cost is zero.
        let needsBrowser = decision.requiredCapabilities.contains("browser")
            || decision.requiredCapabilities.contains("web_search")
            || decision.path == "delegate_cloud"
        let mcpServers: [String] = needsBrowser ? ["harness-browser"] : []
        GigiDebugLogger.log("GIGI Router → delegate_cloud mcp=\(mcpServers) caps=\(decision.requiredCapabilities)")

        for await event in harness.runClaudeCode(prompt: prompt, mcpServers: mcpServers) {
            switch event {
            case .thought(let t):
                GigiDebugLogger.log("GIGI ClaudeEvent thought: \(t.prefix(60))")
            case .toolUse(let name, _):
                GigiDebugLogger.log("GIGI ClaudeEvent tool_use: \(name)")
            case .textResponse(let t):
                collected += t
            case .confirmRequired:
                // Phase 2: confirm gating UI is in GATE 5 (ConfirmComputerUseSheet).
                // For now, auto-cancel destructive actions until UI ships.
                return .spoken("Action needs confirmation — confirmation UI lands in GATE 5.")
            case .done(let latencyMs):
                GigiDebugLogger.log("GIGI Router: delegate_cloud done in \(latencyMs)ms")
            case .error(let msg):
                GigiDebugLogger.log("GIGI Router: delegate_cloud streaming failed (\(msg)) — falling back to legacy bridge.")
                streamingFailed = true
            }
        }

        if streamingFailed || collected.isEmpty {
            let result = await GigiClaudeBridge.shared.run(task: prompt, context: nil)
            if let err = result.error {
                return .error(err)
            }
            collected = result.value
        }

        // Bug #002 fix (2026-05-12): refuse to concatenate Claude CLI error
        // strings into the response. The harness propagates "/login" stderr
        // verbatim when claude.exe isn't authenticated.
        // Bug #003 fix (2026-05-12): instead of returning a hard error,
        // fail-soft by retrying the same prompt on Ollama (delegate_local).
        // Most knowledge queries that wound up here mis-routed by Apple FM
        // can be answered by the local model. The tester sees an answer
        // instead of a cryptic "/login" message.
        if Self.looksLikeClaudeAuthError(collected) {
            GigiDebugLogger.log("GIGI Router: Claude auth error — fail-soft retry on Ollama (delegate_local).")
            // Construct a synthetic decision to reuse dispatchDelegateLocal
            var fallbackDecision = decision
            fallbackDecision.path = "delegate_local"
            fallbackDecision.requiredCapabilities = []
            if fallbackDecision.delegatePrompt.isEmpty {
                fallbackDecision.delegatePrompt = originalText
            }
            return await dispatchDelegateLocal(
                decision: fallbackDecision,
                originalText: originalText,
                history: history
            )
        }

        // GATE 6 — 2-turn callback (Path 4 → Path 2) for killer demos like
        // "Search Wikipedia and create a note about Tesla". After Path 4
        // returns the research summary, detect a follow-up action verb in
        // the original utterance + dispatch a native_tool with the summary.
        if let callback = detectFollowUpAction(originalText: originalText) {
            GigiDebugLogger.log("GIGI Router: 2-turn callback detected → \(callback.action) with summary len=\(collected.count)")
            let secondaryDecision = makeSecondaryDecision(
                action: callback.action,
                title: callback.title ?? defaultTitle(for: originalText),
                body: collected
            )
            let callbackResult = await dispatchNativeTool(
                decision: secondaryDecision,
                originalText: "callback: \(callback.action)",
                history: history
            )
            // Speech: primary summary + secondary confirmation, joined.
            switch callbackResult {
            case .actionInvoked(let secondarySpeech, let tool):
                let combined = "\(collected.trimmingCharacters(in: .whitespacesAndNewlines)) \(secondarySpeech)"
                GigiConversationMemory.shared.addModelSpeech(combined)
                return .actionInvoked(speech: combined, tool: "claude+\(tool)")
            case .spoken(let secondarySpeech):
                let combined = "\(collected.trimmingCharacters(in: .whitespacesAndNewlines)) \(secondarySpeech)"
                GigiConversationMemory.shared.addModelSpeech(combined)
                return .spoken(combined)
            case .error:
                // Fall through to primary-only result.
                break
            }
        }

        GigiConversationMemory.shared.addModelSpeech(collected)
        return .actionInvoked(speech: collected, tool: "ask_claude")
    }

    // MARK: - GATE 6 — multi-step follow-up detection

    private struct FollowUpAction {
        let action: String     // canonical action name
        let title: String?     // optional pre-extracted title
    }

    /// Bug #014 helper: prepend a [User context: …] header to delegate_cloud
    /// prompts. The .claude-sandbox/CLAUDE.md operator manual instructs Claude
    /// to parse this header and localize responses (justeat.it vs just-eat.co.uk,
    /// "near me" defaults to user's country, etc.). Pulls Locale.current —
    /// no GPS, so works without location permission.
    private static func prependUserContext(to prompt: String) -> String {
        let locale = Locale.current
        let country = locale.region?.identifier ?? "unknown"
        let language = locale.language.languageCode?.identifier ?? "en"
        let timezone = TimeZone.current.identifier
        let header = "[User context: country=\(country), locale=\(language)_\(country), timezone=\(timezone)]\n"
        return header + prompt
    }

    /// Bug #003 helper: detect web/code/image verbs in the user's text.
    /// Used to defensively downgrade delegate_cloud → delegate_local when
    /// Apple FM mis-routes a pure knowledge question to the cloud.
    private static let webVerbs = [
        "search ", "look up", "find online", "find the latest", "browse",
        "fetch", "scrape", "get the latest", "what's the latest",
        "what's the current", "what's today's", "what's this week's",
        "check the web", "go to ", "navigate to ", "open ",
        "current price", "today's news", "latest news"
    ]
    private static let codeVerbs = [
        "write a script", "write a python", "write code", "implement ",
        "fix this code", "fix the code", "debug ", "refactor "
    ]
    private static let imageVerbs = [
        "read this image", "what's in the screenshot", "describe this image",
        "what's in this photo", "analyze this picture"
    ]

    private static func hasWebOrCodeOrImageVerb(_ text: String) -> Bool {
        let lower = text.lowercased()
        return webVerbs.contains(where: { lower.contains($0) })
            || codeVerbs.contains(where: { lower.contains($0) })
            || imageVerbs.contains(where: { lower.contains($0) })
    }

    /// Bug #014 helper: detect open-knowledge question patterns that
    /// should NEVER end at ask_clarification — Ollama can always answer
    /// them, and bouncing back "Who is Einstein?" verbatim is the worst
    /// UX. Patterns are intentionally narrow: prefix-anchored question
    /// stem + a copula or interrogative verb, so we don't accidentally
    /// match imperatives like "explain to me how to set a timer".
    /// Resolves the messaging platform for an utterance using priority:
    /// 1. Verbatim mention in the user's text (whatsapp/telegram/sms/imessage)
    /// 2. User-saved preference (`pref:default_message_platform`)
    /// 3. Fallback to imessage
    /// Single source of truth shared by Bug #016 override and FMSendMessageTool.
    static func resolveMessagePlatform(forUtterance text: String) async -> String {
        let lower = text.lowercased()
        if lower.contains("whatsapp") || lower.contains("whats app") { return "whatsapp" }
        if lower.contains("telegram") { return "telegram" }
        if lower.contains(" sms") || lower.hasPrefix("sms ") || lower.contains("text message") { return "sms" }
        if lower.contains("imessage") { return "imessage" }
        if let pref = await GigiMemory.shared.recall("pref:default_message_platform"),
           ["whatsapp", "telegram", "sms", "imessage"].contains(pref.lowercased()) {
            return pref.lowercased()
        }
        return "imessage"
    }

    /// Relationship resolution: given a contact phrase like "my brother",
    /// "my mom", "my boss", look up the user-saved value in GigiMemory
    /// and return it Title-Cased. Falls back to:
    ///   - pref:<rest_underscored>     (canonical smartKey shape)
    ///   - pref:<rest as-is>
    ///   - contact:<rest>              (legacy contacts saved that way)
    ///   - person:<rest>
    ///   - findByContentMatch          (Jaccard token overlap)
    /// Returns nil if nothing matches. Caller decides whether to ask
    /// for clarification or fall through to Contacts search.
    static func resolveContactFromMemory(_ contactPhrase: String) async -> String? {
        let lower = contactPhrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.hasPrefix("my ") else { return nil }
        let rest = String(lower.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        let underscored = rest.replacingOccurrences(of: " ", with: "_")
        let candidates = [
            "pref:\(underscored)",
            "pref:\(rest)",
            "contact:\(rest)",
            "person:\(rest)"
        ]
        for k in candidates {
            if let val = await GigiMemory.shared.recall(k), !val.isEmpty {
                return Self.titleCaseName(val)
            }
        }
        // Last-resort fuzzy lookup using tokens shared with the cache.
        if let hit = await GigiMemory.shared.findByContentMatch(in: contactPhrase) {
            return Self.titleCaseName(hit.value)
        }
        return nil
    }

    /// Strip filler words ("to", "a", "an", "the", pronouns like "it/him/her")
    /// from the start of a string AND apply Title Case so proper-noun
    /// names always look right ("leo corte" → "Leo Corte", regardless of
    /// what the user typed). Multi-pass: "it to leo" → "Leo". Idempotent.
    static func cleanContactName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let removable = [
            "to ", "a ", "an ", "the ",
            "it ", "this ", "that ",
            "him ", "her ", "them ",
            "for "
        ]
        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for p in removable where lower.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return Self.titleCaseName(s)
    }

    /// Title Case for proper-noun-like names: each word's first letter
    /// uppercased, the rest lowercased. Preserves single-letter words
    /// and hyphenated parts. Idempotent.
    static func titleCaseName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // Split on whitespace, capitalize each word, join with single spaces.
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let cased = parts.map { word -> String in
            // Handle hyphenated parts ("jean-paul" → "Jean-Paul")
            let subParts = word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            let casedSubs = subParts.map { sub -> String in
                guard let first = sub.first else { return sub }
                return String(first).uppercased() + sub.dropFirst().lowercased()
            }
            return casedSubs.joined(separator: "-")
        }
        return cased.joined(separator: " ")
    }

    /// Bug #018 helper: same shape as detectMessageWithoutBody but the
    /// contact slot is an unresolved pronoun (no person referent yet).
    /// Used to ask "Who do you want to send a message to?".
    static func detectMessageWithUnresolvedContact(in text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        let verbs = ["send ", "text ", "message ", "whatsapp ", "imessage ", "telegram ", "sms "]
        guard verbs.contains(where: { t.hasPrefix($0) }) else { return false }
        // Mention any pronoun anywhere in the residue.
        let pronouns = [" him", " her", " them", " he ", " she ", " they ", " someone", " anyone"]
        if pronouns.contains(where: { t.contains($0) }) { return true }
        // Also handle "Send a message" (no contact, no pronoun) — open
        // request that needs both contact AND body. Treated the same.
        let openShapes = ["send a message", "send a text", "send a whatsapp",
                          "send a telegram", "send an sms"]
        if openShapes.contains(where: { t == $0 || t.hasPrefix($0 + " ") || t.hasSuffix(" " + $0) }) {
            return true
        }
        return false
    }

    /// Bug #017 helper: detect a possessive / preference-shaped subject
    /// ("my password", "my favorite movie", "my default platform").
    /// Used to force `remember` BEFORE Apple FM router runs, since FM
    /// often misclassifies these as send_message / delegate_local.
    static func looksLikePreferenceAssertion(subject: String) -> Bool {
        let s = subject.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        if s.hasPrefix("my ") { return true }
        let prefKeywords = ["default ", "preferred ", "favorite ", "favourite "]
        return prefKeywords.contains(where: { s.contains($0) })
    }

    /// Bug #016 helper: detect that the user started a new command
    /// instead of supplying the missing slot value the previous turn
    /// asked for. Heuristic: prefix matches a strong command verb /
    /// question word. When true, the pending clarification is dropped
    /// and the new utterance is processed via the normal pipeline.
    static func looksLikeNewCommand(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let starters = [
            "set ", "turn ", "call ", "text ", "send ", "message ", "whatsapp ",
            "imessage ", "telegram ", "play ", "open ", "launch ", "navigate ",
            "drive ", "forget ", "remember ", "remind ",
            "who ", "who's ", "whos ", "what ", "what's ", "whats ",
            "where ", "where's ", "when ", "when's ", "why ", "how ",
            "tell me ", "find ", "search ", "look up ", "show me ",
            "weather ", "time ", "date "
        ]
        return starters.contains { t.hasPrefix($0) }
    }

    /// Bug #016 helper: detect a messaging-shape request that is missing
    /// a body indicator. Used to override Apple FM's tendency to bail
    /// to delegate_local on "Send X a message" instead of asking the
    /// user what to say. Returns the extracted contact name.
    ///
    /// Detection rules:
    /// 1. Starts with a messaging verb (send / text / message / whatsapp
    ///    / imessage / telegram / sms).
    /// 2. Does NOT contain a body indicator (saying / telling / tell /
    ///    told / to say / and say / with the message / that says /
    ///    writing).
    /// 3. Does NOT contain ":" or quoted span (would imply explicit body).
    static func detectMessageWithoutBody(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        let verbs = ["send ", "text ", "message ", "whatsapp ", "imessage ", "telegram ", "sms "]
        guard verbs.contains(where: { t.hasPrefix($0) }) else { return nil }
        let bodyIndicators = [
            " saying ", " telling ", " tell ", " told ",
            " to say ", " and say ", " with the message ", " that says ",
            " writing ", " write "
        ]
        for ind in bodyIndicators where t.contains(ind) { return nil }
        if t.contains(":") || t.contains("\"") { return nil }
        // Extract contact: trim verb, optional fillers, then take the
        // residue. Cap at 40 chars to avoid feedback when the utterance
        // is something pathological.
        var rest = t
        for v in verbs where rest.hasPrefix(v) {
            rest = String(rest.dropFirst(v.count))
            break
        }
        let prefixFillers = [
            "a message on whatsapp to ", "a message on imessage to ",
            "a message on telegram to ", "a message on sms to ",
            "a whatsapp to ", "a telegram to ", "a text to ",
            "a message to ", "a text ",
            "message to ", "text to ", "to "
        ]
        for f in prefixFillers where rest.hasPrefix(f) {
            rest = String(rest.dropFirst(f.count))
            break
        }
        let trailingFillers = [
            " a message on whatsapp", " a message on telegram",
            " a message", " a text", " a whatsapp", " a telegram", " a sms"
        ]
        for f in trailingFillers where rest.hasSuffix(f) {
            rest = String(rest.dropLast(f.count))
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        // Multi-pass strip of filler words / pronouns + Title Case:
        // "it to leo corte" → "Leo Corte".
        rest = Self.cleanContactName(rest)
        guard !rest.isEmpty, rest.count <= 40 else { return nil }
        // Reject if cleaning left only a pronoun (no actual contact name).
        let pronouns: Set<String> = [
            "him", "her", "them", "it", "he", "she", "they", "there",
            "someone", "anyone", "nobody"
        ]
        if pronouns.contains(rest.lowercased()) { return nil }
        return rest
    }

    /// Bug #015 helper: detect a bare "X is/are/= Y" fact assertion in EN
    /// or IT. Returns (subject, value) split on the copula. Used to
    /// override Apple FM's tendency to route assertions to delegate_local
    /// (which can't persist).
    ///
    /// Detection avoids common interrogatives: leading who/what/where/
    /// when/why/how/whose are NOT assertions — they're questions.
    static func detectFactAssertion(in text: String) -> (subject: String, value: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        // Bail if it's a question — these start with WH-words.
        let interrogativePrefixes = [
            "who ", "who's ", "whos ",
            "what ", "what's ", "whats ",
            "where ", "where's ", "wheres ",
            "when ", "when's ", "whens ",
            "why ", "why's ", "whys ",
            "how ", "how's ", "hows ",
            "which ", "whose ",
            "chi ", "che ", "cosa ", "cos'è ", "cose ", "dove ", "quando ", "perché ", "perche ", "come "
        ]
        if interrogativePrefixes.contains(where: { lower.hasPrefix($0) }) { return nil }
        if lower.hasSuffix("?") { return nil }

        // Try copulas in priority order. The first three are unambiguous
        // EN/IT fact-assertion copulas; "=" is an explicit assignment.
        let copulas = [
            " is ", " are ", " was ", " were ",
            " è ", " e' ",
            " sono ", " sei ",
            " means ", " equals ",
            " = "
        ]
        for sep in copulas {
            guard let range = t.range(of: sep, options: .caseInsensitive) else { continue }
            let left = String(t[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(t[range.upperBound...]).trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            guard !left.isEmpty, !right.isEmpty,
                  left.count <= 60, right.count <= 200 else { continue }
            // Discard if the left side is an interrogative pronoun ("who is X" passed bail above only because we matched " is "; defend again).
            if interrogativePrefixes.contains(where: { left.lowercased().hasPrefix($0.trimmingCharacters(in: .whitespaces) + " ") || left.lowercased() == $0.trimmingCharacters(in: .whitespaces) }) {
                return nil
            }
            return (subject: left, value: right)
        }
        return nil
    }

    static func looksLikeOpenKnowledgeQuery(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Each WH-stem accepts:
        //   - full form: "who is", "who are", "who was", "who were"
        //   - contraction: "who's"
        //   - typo without apostrophe: "whos"
        let patterns = [
            #"^who(?:\s+(?:is|are|was|were)|'s|s)\s+"#,
            #"^what(?:\s+(?:is|are|was|were|do|does|did)|'s|s)\s+"#,
            #"^explain\s+"#,
            #"^how(?:\s+(?:does|do|did|to|can|could)|'s|s)\s+"#,
            #"^why(?:\s+(?:is|are|was|were|do|does|did)|'s|s)\s+"#,
            #"^tell\s+me\s+about\s+"#,
            #"^when(?:\s+(?:was|were|did|is|are|do|does)|'s|s)\s+"#,
            #"^where(?:\s+(?:is|are|was|were|did|do|does)|'s|s)\s+"#
        ]
        for p in patterns {
            if t.range(of: p, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// Bug #002 helper: detect Claude CLI authentication errors that the
    /// harness propagates verbatim from claude.exe stderr. These look like
    /// legitimate text in the SSE stream but are actually setup failures
    /// the user can't recover from inside the iPhone app.
    private static func looksLikeClaudeAuthError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("not logged in")
            || lower.contains("please run /login")
            || lower.contains("claude /login")
            || lower.hasPrefix("error: not authenticated")
            || lower.hasPrefix("authentication required")
    }

    /// Detect "research + action" patterns in the user's original utterance.
    /// Returns the secondary action to dispatch after Path 4 returns.
    ///
    /// Bug #002 fix (2026-05-12): requires a research verb to COEXIST with
    /// the action verb. Previously "create a note titled test with body
    /// hello world" matched the action verb alone — GATE 6 fired even
    /// though there was no Path 4 research to chain. Combined with router
    /// mis-classification to delegate_cloud, this produced a hybrid
    /// bubble: Claude "/login" error + native success concatenated.
    /// Now: GATE 6 only fires when the utterance clearly chains research
    /// (search/look up/find/get/research) → action (note/reminder/email).
    private static let researchVerbs = [
        "search", "look up", "find ", "research", "get the", "browse",
        "fetch", "check the web", "tell me about", "what's the latest"
    ]

    private func detectFollowUpAction(originalText: String) -> FollowUpAction? {
        let t = originalText.lowercased()

        // Precondition: must have a research verb. Otherwise the user is
        // requesting a pure native action — let dispatchNativeTool handle it.
        guard Self.researchVerbs.contains(where: { t.contains($0) }) else {
            return nil
        }

        // Note patterns
        let notePatterns = [
            "create a note", "save a note", "make a note",
            "save it to a note", "save this as a note",
            "and note", "save to notes", "write a note"
        ]
        if notePatterns.contains(where: { t.contains($0) }) {
            return FollowUpAction(action: "create_note", title: nil)
        }

        // Reminder patterns
        let reminderPatterns = [
            "and remind me", "set a reminder", "create a reminder",
            "remind me to", "remind me about"
        ]
        if reminderPatterns.contains(where: { t.contains($0) }) {
            return FollowUpAction(action: "set_reminder", title: nil)
        }

        // Email draft patterns
        let emailPatterns = [
            "draft an email", "send an email", "and email me",
            "compose an email"
        ]
        if emailPatterns.contains(where: { t.contains($0) }) {
            return FollowUpAction(action: "send_message", title: nil)
        }

        return nil
    }

    /// Build a synthetic `FoundationRouterDecision` for the secondary turn.
    /// Bypasses Apple FM (no extra round-trip) — we already know the action
    /// and we have the body from Path 4's response.
    private func makeSecondaryDecision(action: String, title: String, body: String) -> FoundationRouterDecision {
        let slots = makeSlots(title: title, body: body)
        #if canImport(FoundationModels)
        return FoundationRouterDecision(
            path: "native_tool",
            primaryAction: action,
            confidence: 1.0,
            complexityEstimate: 10,
            requiredCapabilities: [],
            reason: "GATE 6 multi-step callback",
            slots: slots,
            directSpeech: "",
            delegatePrompt: ""
        )
        #else
        var d = FoundationRouterDecision()
        d.path = "native_tool"
        d.primaryAction = action
        d.confidence = 1.0
        d.complexityEstimate = 10
        d.requiredCapabilities = []
        d.reason = "GATE 6 multi-step callback"
        d.slots = slots
        return d
        #endif
    }

    private func makeSlots(title: String, body: String) -> ActionSlots {
        #if canImport(FoundationModels)
        return ActionSlots(
            contact: "", body: body, destination: "", date: "", time: "",
            taskText: title, duration: "", label: "", appName: "",
            query: "", platform: ""
        )
        #else
        var s = ActionSlots()
        s.body = body
        s.taskText = title
        return s
        #endif
    }

    /// Best-effort title extraction from the user's prompt when the router
    /// did not pre-extract one. Picks the most informative noun-ish phrase.
    private func defaultTitle(for originalText: String) -> String {
        let t = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try to extract "about X" pattern: "create a note about X"
        if let r = t.range(of: #"about\s+([A-Za-z][A-Za-z\s']{2,40})"#, options: .regularExpression) {
            let captured = String(t[r])
                .replacingOccurrences(of: #"^about\s+"#, with: "", options: .regularExpression)
            return captured.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        }
        // Try "for X" pattern: "remind me for X"
        if let r = t.range(of: #"for\s+([A-Za-z][A-Za-z\s']{2,40})"#, options: .regularExpression) {
            let captured = String(t[r])
                .replacingOccurrences(of: #"^for\s+"#, with: "", options: .regularExpression)
            return captured.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        }
        // Fallback: first 6 words of the prompt
        let words = t.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? "GIGI note" : String(words).capitalized
    }

    // MARK: - Slot → params mapping

    private func paramsFromSlots(_ slots: ActionSlots, action: String, originalText: String) -> [String: String] {
        var params: [String: String] = [:]
        if !slots.contact.isEmpty     { params["contact"]     = slots.contact }
        if !slots.body.isEmpty        { params["body"]        = slots.body }
        if !slots.destination.isEmpty { params["destination"] = slots.destination }
        if !slots.date.isEmpty        { params["date"]        = slots.date }
        if !slots.time.isEmpty        { params["time"]        = slots.time }
        if !slots.taskText.isEmpty {
            params["text"]      = slots.taskText
            params["title"]     = slots.taskText
            params["taskText"]  = slots.taskText
            params["accessory"] = slots.taskText
        }
        if !slots.duration.isEmpty {
            params["text"]     = slots.duration
            params["taskText"] = slots.duration
            params["raw"]      = slots.duration
        }
        if !slots.label.isEmpty       { params["label"]       = slots.label }
        if !slots.appName.isEmpty     { params["app"]         = slots.appName }
        if !slots.query.isEmpty       { params["query"]       = slots.query }
        if !slots.platform.isEmpty    { params["platform"]    = slots.platform }
        // Bug #011 fix: web_order_food bridge path reads `service` (not `app`)
        // — map appName to BOTH app and service so the bridge handler finds it
        // when Apple FM falls back to slot extraction (path B).
        if action == "web_order_food" && !slots.appName.isEmpty {
            params["service"] = slots.appName.lowercased()
        }
        if params["raw"] == nil       { params["raw"]         = originalText }
        return params
    }

    // MARK: - Mode gating (GATE 7)

    private func currentMode() -> GigiMode {
        let raw = UserDefaults.standard.string(forKey: "gigi.user.mode") ?? GigiMode.fullPower.rawValue
        return GigiMode(rawValue: raw) ?? .fullPower
    }

    // MARK: - Discovery query detection (GATE 9 polish, Layer B preview)

    /// Detects "what can you do" / "help" / "cosa sai fare" type queries
    /// that should NOT go through Apple FM tool calling (which mis-routes
    /// them as ask_clarification with echoed input). Returns true if the
    /// utterance is an unambiguous discovery / help request.
    ///
    /// Layer B in GATE 10 will upgrade this to context-aware top-3 suggestions
    /// (different responses by time-of-day, location, recent activity). For
    /// now this provides a curated static overview to fix the echo bug.
    private func detectDiscoveryQuery(in text: String) -> Bool {
        let t = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!.,"))
        guard !t.isEmpty else { return false }

        // Exact-match high-confidence discovery utterances (case-insensitive,
        // punctuation-stripped).
        let exactMatches: Set<String> = [
            // English
            "what can you do", "what can you help with", "what do you do",
            "what are your capabilities", "what are your features",
            "help", "help me", "what's possible", "what is possible",
            "how do i use you", "how do i use this", "how can i use you",
            "what can gigi do", "show me what you can do",
            "tell me what you can do", "what can i ask you",
            "what can i ask", "what can i say",
            // Italian
            "cosa sai fare", "cosa puoi fare", "che cosa sai fare",
            "che cosa puoi fare", "aiuto", "aiutami",
            "cosa puoi farmi fare", "cosa posso chiederti",
            "cosa posso dirti", "come ti uso",
            "dimmi cosa sai fare", "fammi vedere cosa sai fare"
        ]
        if exactMatches.contains(t) { return true }

        // Prefix matches: "how do i ..." that DON'T match a specific tool
        // are too ambiguous to intercept — leave to Apple FM. Same with
        // generic "tell me about" queries.
        // (intentionally narrow scope to avoid false positives)

        return false
    }

    /// Context-aware discovery response (GATE 10.D Layer B).
    ///
    /// Replaces the GATE 9 static overview. Picks 3-5 suggestions that
    /// match the current context (time-of-day, recent activity). Always
    /// English per CLAUDE.md §Lingua hard rule.
    ///
    /// Context signals used:
    ///   - Hour of day → morning / midday / afternoon / evening / night
    ///   - Recently registered Shortcuts → reference them when present
    ///   - Number of registered alias Shortcuts → boost meta capability
    ///     awareness ("you have N custom Shortcuts...")
    private func discoveryOverviewResponse() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let registeredCount = GigiShortcutRegistry.shared.shortcuts.count

        let intro: String
        let suggestions: [String]

        switch hour {
        case 5..<10:  // Morning (5am - 10am)
            intro = "Good morning. Try saying:"
            suggestions = [
                "'read my calendar for today'",
                "'what's the weather'",
                "'set Focus to Work'",
                "'turn off bedroom lights'"
            ]
        case 10..<14:  // Late morning / lunch (10am - 2pm)
            intro = "A few useful things you can ask me:"
            suggestions = [
                "'set a timer for 5 minutes'",
                "'navigate to my next meeting'",
                "'send a WhatsApp to Marco'",
                "'create event lunch with Sara tomorrow at 1pm'"
            ]
        case 14..<18:  // Afternoon (2pm - 6pm)
            intro = "Try saying:"
            suggestions = [
                "'play my afternoon playlist'",
                "'call mom'",
                "'add to my note ideas: <something>'",
                "'set a reminder to take a break in 1 hour'"
            ]
        case 18..<22:  // Evening (6pm - 10pm)
            intro = "Evening menu:"
            suggestions = [
                "'navigate home'",
                "'activate the cinema scene'",
                "'set alarm for 7am'",
                "'order pizza on Deliveroo'"
            ]
        default:  // Night (10pm - 5am)
            intro = "Night time. Try saying:"
            suggestions = [
                "'set Focus to Sleep'",
                "'turn off all lights'",
                "'set alarm for 7am'",
                "'goodnight scene'"
            ]
        }

        // Add the meta capability hint when the user has at least one
        // registered Shortcut alias — gives credit to the power-user
        // setup and reinforces the alias pattern.
        let metaHint: String
        if registeredCount > 0 {
            metaHint = " You also have \(registeredCount) custom Shortcut\(registeredCount == 1 ? "" : "s") registered — say any of their aliases."
        } else {
            metaHint = " I can also run any Apple Shortcut you've made — just say 'run' followed by its name."
        }

        return "\(intro) \(suggestions.joined(separator: ", ")). Ask me anything else, too —\(metaHint)"
    }

    // MARK: - Debug overlay (DEBUG-only, GATE 15)

    /// Prepends a one-line debug tag to the response speech showing which
    /// routing source decided and with what confidence. Only active in DEBUG
    /// builds — production users never see this. Format:
    /// `[semantic web_search 0.67 'best ramen'] Searching for ...`
    private func debugPrefix(
        routerSource: String,
        tool: String,
        confidence: Float,
        slot: String? = nil
    ) -> String {
        #if DEBUG
        let conf = String(format: "%.2f", confidence)
        let slotPart: String
        if let s = slot, !s.isEmpty, s.count <= 40 {
            slotPart = " '\(s)'"
        } else {
            slotPart = ""
        }
        return "[\(routerSource) \(tool) \(conf)\(slotPart)]\n"
        #else
        return ""
        #endif
    }

    // MARK: - Semantic router parameter mapping (GATE 15)

    /// Maps a `SemanticMatch` to the params dictionary expected by
    /// `GigiActionBridge.execute(GigiIntent)`. Each tool has a different
    /// parameter contract — this centralizes the slot → param key mapping.
    private func buildSemanticParams(for match: SemanticMatch) -> [String: String] {
        let slot = match.slot
        switch match.toolName {
        case "web_search":
            return ["query": slot, "raw": slot]
        case "run_shortcut":
            return ["name": slot, "raw": slot, "input": ""]
        case "set_homekit_scene":
            return ["scene": slot, "sceneName": slot, "raw": slot]
        case "open_app":
            return ["app": slot, "raw": slot]
        case "play_music":
            return ["track": slot, "raw": slot]
        case "navigate":
            return ["destination": slot, "raw": slot]
        case "make_call", "facetime", "send_message":
            return ["contact": slot, "raw": slot]
        case "create_note":
            return ["title": slot, "raw": slot]
        case "weather":
            return ["location": slot, "raw": slot]
        case "set_timer", "set_alarm", "set_reminder":
            return ["text": slot, "duration": slot, "time": slot, "raw": slot]
        case "homekit_on":
            return ["accessory": slot, "raw": slot]
        case "homekit_off":
            return ["accessory": slot, "raw": slot]
        case "read_calendar", "read_email", "find_free_slot":
            return ["raw": slot]
        case "web_order_food":
            return ["service": "", "query": slot, "raw": slot]
        case "read_clipboard", "get_device_battery":
            // No arguments; tool is invocation-only.
            return [:]
        case "toggle_flashlight":
            // Slot may contain explicit state token ("on"/"off"/"accendi"/etc.)
            // — pass through; bridge normalizes.
            return ["state": slot, "raw": slot]
        case "define_word":
            return ["word": slot, "raw": slot]
        case "calculate_math":
            return ["expression": slot, "raw": slot]
        case "translate_text":
            // translate_text has TWO logical slots: text + targetLanguage.
            // Parse "<text> to <lang>" / "<text> in <lang>" pattern at the
            // tail of the slot — covers EN ("good morning to italian") and
            // IT ("buongiorno in giapponese") variants.
            let (txt, lang) = parseTranslateSlot(slot)
            return ["text": txt, "targetLanguage": lang, "raw": slot]
        case "create_calendar_event":
            // Should NOT normally reach here — create_calendar_event is
            // removed from the semantic catalog so it falls through to
            // Apple FM which parses title/date/time via @Generable. If we
            // somehow get here (catalog drift), defer parsing to the
            // bridge with the full slot as title and let parseDateTime
            // surface a "today at noon" fallback.
            return ["title": slot, "date": "today", "time": "noon", "raw": slot]
        case "add_to_note":
            // Smart split on ':' or '-' separator — common user pattern is
            // "<note_title>: <content>" (e.g. "work: idea Q3 Macros") or
            // "<note_title> - <content>". Falls back to (empty title, full
            // slot as content) when no separator present.
            let (title, content) = parseAddToNoteSlot(slot)
            return ["noteTitle": title, "content": content, "raw": slot]
        case "build_shortcut":
            // Semantic-path fallback. The proper path is tier-0
            // detectBuildShortcutPattern which delegates to Apple FM with
            // FMBuildShortcutTool for structured Arguments extraction.
            // If we end up here it means the regex didn't match but the
            // semantic centroid did. Best-effort: pass the slot as the
            // description and an empty actionsJSON; the bridge will return
            // a parse error and the user will rephrase. (Apple FM via
            // tool dispatch is preferred but unreachable from this code
            // path — buildSemanticParams is called for direct bridge
            // execution, not for Apple FM tool calling.)
            return ["title": "GIGI Shortcut", "actionsJSON": "[]", "raw": slot]
        default:
            return ["raw": slot]
        }
    }

    // MARK: - Math expression detection (GATE 10.C tier-0)

    /// Returns the math expression if `text` is clearly a math query that
    /// should bypass Apple FM / LLM and go straight to NSExpression.
    /// Returns nil otherwise (let semantic / Apple FM handle).
    ///
    /// Recognized patterns:
    ///   - Pure numeric expressions with operators: "47 * 23", "100/8", "2^10"
    ///   - Natural-language math: "what's 47 times 23", "47 plus 23",
    ///     "15% of 200", "quanto fa 100 diviso 8"
    ///   - Common math verbs: "calculate", "compute", "evaluate", "quanto fa"
    private func detectMathExpression(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }

        // Strip common leading verbs that don't add semantic info
        let leadingPrefixes = [
            "what's ", "whats ", "what is ",
            "how much is ", "how much makes ",
            "calculate the ", "calculate ",
            "compute the ", "compute ",
            "evaluate ",
            "quanto fa ", "quanto è ",
            "calcola il ", "calcola "
        ]
        var stripped = t
        for prefix in leadingPrefixes where stripped.hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
            break  // only one prefix
        }

        // Trim trailing "?" / "."
        stripped = stripped
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Now check: does the remaining string contain (a) at least 2 numbers
        // and (b) at least one math operator (literal or natural-language)?
        let digitCount = stripped.filter { $0.isNumber }.count
        guard digitCount >= 2 else { return nil }

        let mathOperators: [String] = [
            "+", "-", "*", "/", "%", "^", "**",
            " plus ", " minus ", " times ", " time ", " divided by ", " over ", " x ",
            " multiplied by ", " moltiplicato per ",
            " più ", " meno ", " per ", " diviso ", " mod "
        ]
        let hasOperator = mathOperators.contains { stripped.contains($0) }

        // Percentage / square-root short forms (single-operand patterns)
        let isPercentage = stripped.range(of: #"\d+(?:\.\d+)?\s*%"#, options: .regularExpression) != nil
        let isSqrt = stripped.contains("sqrt(") || stripped.contains("square root")

        guard hasOperator || isPercentage || isSqrt else { return nil }

        return stripped
    }

    // MARK: - add_to_note slot split helper (GATE 10.A bug fix)

    /// Smart split of "<note_title>: <content>" or "<note_title> - <content>"
    /// patterns. Returns (noteTitle, content). When no separator is present,
    /// returns ("", slot) so the bridge surfaces "your note" generically.
    ///
    /// Examples:
    ///   "work: idea Q3 Macros"     → ("work", "idea Q3 Macros")
    ///   "shopping - buy milk eggs" → ("shopping", "buy milk eggs")
    ///   "idea Q3 Macros"           → ("", "idea Q3 Macros")
    ///   "ideas: meeting takeaways" → ("ideas", "meeting takeaways")
    private func parseAddToNoteSlot(_ slot: String) -> (title: String, content: String) {
        let trimmed = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }

        // Try ':' first (more deliberate), then ' - ' (common alternative)
        let separators: [String] = [":", " - ", " — ", " – "]
        for sep in separators {
            if let r = trimmed.range(of: sep) {
                let titlePart = String(trimmed[trimmed.startIndex..<r.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let contentPart = String(trimmed[r.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Title must be a short noun (≤ 4 words) to count — guards
                // against splitting on ':' in URLs or timestamps.
                let titleWordCount = titlePart.split(separator: " ").count
                if !titlePart.isEmpty, !contentPart.isEmpty, titleWordCount <= 4 {
                    return (titlePart, contentPart)
                }
            }
        }
        return ("", trimmed)
    }

    // MARK: - translate_text slot split helper (GATE 10.C bug fix)

    /// Parses "<text> to <lang>" / "<text> in <lang>" patterns out of the
    /// translate_text slot. Returns (text, langKeyword) tuple. Falls back
    /// to (raw, "") if no "to/in <lang>" tail is present.
    ///
    /// Examples:
    ///   "good morning to italian"     → ("good morning", "italian")
    ///   "buongiorno in giapponese"    → ("buongiorno",   "giapponese")
    ///   "good morning to italia"      → ("good morning", "italia") —
    ///       "italia" still maps via the bridge language map.
    private func parseTranslateSlot(_ slot: String) -> (text: String, lang: String) {
        let trimmed = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }

        // Find the LAST " to " / " in " / " into " marker (last occurrence
        // — user might say "translate 'to be or not to be' to italian"
        // where intermediate "to" is text, final "to" is the target).
        let separators = [" into ", " to ", " in "]
        var bestSeparatorRange: Range<String.Index>?
        for sep in separators {
            if let r = trimmed.range(of: sep, options: [.caseInsensitive, .backwards]) {
                if bestSeparatorRange == nil || r.upperBound > bestSeparatorRange!.upperBound {
                    bestSeparatorRange = r
                }
            }
        }

        guard let sepRange = bestSeparatorRange else {
            return (trimmed, "")
        }

        let textPart = String(trimmed[trimmed.startIndex..<sepRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let langPart = String(trimmed[sepRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))

        if textPart.isEmpty || langPart.isEmpty {
            return (trimmed, "")
        }
        return (textPart, langPart)
    }

    // MARK: - build_shortcut explicit-authoring pattern detection (Phase 2)

    /// Returns the natural-language description of the Shortcut the user
    /// wants to build, when `text` matches an unambiguous build-shortcut
    /// pattern. Returns nil otherwise.
    ///
    /// Apple FM constrained decoding biases toward concrete tools when the
    /// inner description contains tool-like keywords ("turn on torch" →
    /// homekit_on; "create event" → create_calendar_event; etc.). The
    /// regex short-circuits these.
    ///
    /// Recognized patterns (case-insensitive, leading verbs):
    ///   - "build me a shortcut that <description>"
    ///   - "build a shortcut that <description>"
    ///   - "make me a shortcut that <description>"
    ///   - "create a shortcut that <description>"
    ///   - "compose a shortcut that <description>"
    ///   - "design a shortcut that <description>"
    ///   - Italian: "fammi uno shortcut che <description>"
    ///   - Italian: "crea uno shortcut che <description>"
    ///   - Italian: "componi uno shortcut che <description>"
    ///
    /// Returns the description portion (e.g. "turns on the torch and waits
    /// 5 seconds"), with leading "that/which/who/who" filler stripped.
    private func detectBuildShortcutPattern(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }

        // PERMISSIVE regex: <build-verb> [optional 1-2 filler words like
        // 'me/a/the/one' or autocorrect typos] 'shortcut' [optional 'that'/
        // 'which'/etc] <description>. Catches:
        //   build me a shortcut that X    ← canonical
        //   build a shortcut that X       ← skip 'me'
        //   build be a shortcut X         ← autocorrect typo 'me' → 'be'
        //   build the shortcut X          ← article variant
        //   build shortcut X              ← no article
        //   make/create/design/compose/generate/costruisci/fammi/crea/...
        //
        // Group 2 captures the description (rest of the utterance).
        let pattern = #"^(?:build|make|create|compose|design|generate|costruisci|crea|fammi|componi|genera)\s+(?:\w+\s+){0,2}(?:short ?cut|scorciatoia)s?\s+(?:that\s+|which\s+|to\s+|for\s+|per\s+|che\s+)?(.+)$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(t.startIndex..<t.endIndex, in: t)
        guard let match = regex.firstMatch(in: t, options: [], range: nsRange),
              let descRange = Range(match.range(at: 1), in: t) else {
            return nil
        }
        let desc = String(t[descRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return desc.isEmpty ? nil : desc
    }

    // MARK: - Tier-0 regex intercepts (HYBRID with GigiSemanticRouter — GATE 15 fix)
    //
    // After GATE 15 device test surfaced regression on "Run call" / "Run mom"
    // (semantic router word-embedding bias toward concrete tools), the regex
    // pattern matchers were restored as a tier-0 deterministic fast-path
    // BEFORE the semantic router. They are 100% precision for explicit verb
    // prefixes (run/execute/launch/trigger/esegui/lancia) — any text after
    // the verb IS the Shortcut name by definition. Semantic router stays as
    // tier-1 fallback for natural-language variants the regex doesn't cover.
    //
    // detectWebSearchPattern is still NOT called from route() — web_search
    // semantics narrowed to explicit "Safari/phone" intent per ADR-0013;
    // generic research queries delegate_cloud via Apple FM.

    /// Returns the Shortcut name if `text` matches an unambiguous run-shortcut
    /// trigger pattern; otherwise nil. Apple FM constrained decoding often
    /// mis-routes "run accendi torcia" to homekit_on or set_timer because the
    /// inner words bias toward those tools — we short-circuit explicit
    /// invocations to bypass that.
    ///
    /// Recognized patterns (case-insensitive):
    ///   - "run <name>"
    ///   - "execute <name>"
    ///   - "launch <name>"
    ///   - "trigger <name>"
    ///   - "esegui <name>"            (IT)
    ///   - "lancia <name>"            (IT)
    ///   - "<name> shortcut"          (trailing keyword)
    ///   - "run my <name>"            (possessive variant)
    ///
    /// Returns the cleaned name (trailing/leading whitespace stripped, the
    /// word "shortcut" removed if present at the start or end).
    private func detectRunShortcutPattern(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }

        // Leading-verb patterns. Order matters: longer prefixes first.
        let leadingPrefixes: [String] = [
            "run my ", "execute my ", "launch my ", "trigger my ",
            "esegui il ", "esegui la ", "esegui lo ", "esegui i ", "esegui le ",
            "lancia il ", "lancia la ", "lancia lo ", "lancia ",
            "run the ", "execute the ", "launch the ", "trigger the ",
            "run ", "execute ", "launch ", "trigger ",
            "esegui "
        ]
        for prefix in leadingPrefixes {
            if t.hasPrefix(prefix) {
                let raw = String(t.dropFirst(prefix.count))
                return cleanShortcutName(raw)
            }
        }

        // Trailing keyword pattern: "<name> shortcut" / "<name> scorciatoia"
        let trailingKeywords = [" shortcut", " scorciatoia"]
        for kw in trailingKeywords {
            if t.hasSuffix(kw), t.count > kw.count {
                let raw = String(t.dropLast(kw.count))
                return cleanShortcutName(raw)
            }
        }

        return nil
    }

    // MARK: - web_search pattern detection (GATE 9.C)

    /// Returns the search query if `text` matches an unambiguous web-search
    /// trigger pattern; otherwise nil. Apple FM tends to route "search the web
    /// for X" to delegate_cloud (Claude answers directly) instead of web_search
    /// (open Safari with query). We short-circuit explicit search intents.
    ///
    /// Recognized patterns (case-insensitive):
    ///   - "search the web for <query>"
    ///   - "search the web <query>"
    ///   - "search online for <query>"
    ///   - "look up <query> online"
    ///   - "look up <query> on the web"
    ///   - "find <query> online"
    ///   - "find <query> on the web"
    ///   - "google <query>"
    ///   - "google for <query>"
    ///   - "search google for <query>"
    ///   - Italian: "cerca su web <query>", "cerca online <query>",
    ///     "cerca su google <query>", "cerca <query> su google",
    ///     "cerca <query> online"
    private func detectWebSearchPattern(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }

        // Leading-prefix patterns. Order matters: longer prefixes first.
        let leadingPrefixes: [String] = [
            // English — most specific first
            "search the web for ", "search the web ",
            "search web for ", "search web ",
            "search the internet for ", "search internet for ",
            "search online for ", "search online ",
            "search google for ", "search on google for ",
            "search for ",
            "look up the ", "look up ",
            "find online ", "find on the web ",
            "google for ", "google ",
            // Italian
            "cerca sul web ", "cerca su web ", "cerca web ",
            "cerca su internet ", "cerca internet ",
            "cerca su google ", "cerca google ",
            "cerca online ",
            "cerca per ", "cercami "
        ]
        for prefix in leadingPrefixes {
            if t.hasPrefix(prefix), t.count > prefix.count {
                let raw = String(t.dropFirst(prefix.count))
                return cleanSearchQuery(raw)
            }
        }

        // Trailing-keyword patterns: "<query> online" / "<query> on the web"
        // Only if the utterance also starts with a search-ish verb (look/find/search),
        // OR contains "online" / "on the web" at the very end.
        let trailingKeywords = [" online", " on the web", " on google", " su google", " online"]
        for kw in trailingKeywords {
            if t.hasSuffix(kw), t.count > kw.count {
                let raw = String(t.dropLast(kw.count))
                let firstWord = raw.split(separator: " ").first.map(String.init) ?? ""
                // Only accept if the prefix verb is a search-ish action.
                let searchVerbs: Set<String> = ["look", "find", "search", "cerca", "cercami", "trovami"]
                if searchVerbs.contains(firstWord) {
                    // Strip the verb too
                    let rest = String(raw.dropFirst(firstWord.count)).trimmingCharacters(in: .whitespaces)
                    // Also strip "up" / "for" if present
                    let stripped = rest
                        .replacingOccurrences(of: "^up ", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "^for ", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "^per ", with: "", options: .regularExpression)
                    return cleanSearchQuery(stripped)
                }
            }
        }

        return nil
    }

    /// Normalizes a web search query — strips quotes, common filler words at
    /// edges, trims whitespace.
    private func cleanSearchQuery(_ raw: String) -> String? {
        var s = raw
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading filler if it survived prefix matching
        let fillerLead = ["for ", "the ", "a "]
        for f in fillerLead where s.hasPrefix(f) {
            s = String(s.dropFirst(f.count))
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Normalizes a candidate Shortcut name extracted from the utterance.
    /// Strips a leading/trailing "shortcut"/"scorciatoia" if still present,
    /// removes filler quotes, trims whitespace. Returns nil if empty.
    private func cleanShortcutName(_ raw: String) -> String? {
        var s = raw
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading "shortcut " or trailing " shortcut" if present
        let fillerLead = ["shortcut ", "scorciatoia ", "the shortcut "]
        for f in fillerLead where s.hasPrefix(f) {
            s = String(s.dropFirst(f.count))
        }
        let fillerTrail = [" shortcut", " scorciatoia"]
        for f in fillerTrail where s.hasSuffix(f) {
            s = String(s.dropLast(f.count))
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

// MARK: - Compatibility shim

#if !canImport(FoundationModels)

// On SDKs without FoundationModels, FoundationRouterDecision still needs to
// exist as a plain struct so the rest of the router compiles. ActionSlots /
// FoundationRouterDecision @Generable definitions in GigiFoundationContracts
// are wrapped in `#if canImport(FoundationModels)` — provide a parallel
// non-Generable mirror here so the router file builds either way.

struct ActionSlots {
    var contact: String = ""
    var body: String = ""
    var destination: String = ""
    var date: String = ""
    var time: String = ""
    var taskText: String = ""
    var duration: String = ""
    var label: String = ""
    var appName: String = ""
    var query: String = ""
    var platform: String = ""
}

struct FoundationRouterDecision {
    var path: String = "delegate_cloud"
    var primaryAction: String = ""
    var confidence: Double = 0
    var complexityEstimate: Int = 50
    var requiredCapabilities: [String] = []
    var reason: String = ""
    var slots: ActionSlots = ActionSlots()
    var directSpeech: String = ""
    var delegatePrompt: String = ""
}

#endif
