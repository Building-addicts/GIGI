import Foundation

// MARK: - Router Pipeline Framework
//
// Refactor #6 — Declarative Tier Pipeline.
//
// The legacy `GigiRequestRouter.route()` is a 530-LOC chain of `if` blocks
// where the order of dispatch is implicit in the source-line ordering of 16
// inlined tiers. This file introduces a declarative alternative: each tier is
// a `RouterTier` struct, the route order is an array of structs, and the
// runner is a simple loop over that array.
//
// Migration is incremental. Step 1 (this file) defines only the framework
// types — no tiers have been migrated yet. `route()` still works as before;
// the runner will be wired in starting from Step 2 (math + discovery tiers).
//
// Design choices (see chat 2026-05-17 handoff §7-§8):
//   - Tiers live in a dedicated file (not nested in GigiRequestRouter).
//   - Tiers receive an `unowned router` reference so they can call helpers
//     that remain private to the router class.
//   - Debug-prefix wrapping stays inside each tier (status quo): the runner
//     does not wrap results — only the final DispatchTier reproduces the
//     existing post-dispatch `prependDebug` behaviour.

// MARK: - RouterContext

/// Mutable state threaded through the tier pipeline for a single routing pass.
///
/// Pre-FM tiers (math, discovery, alias, ...) only read `text`/`history`/
/// `mode`/`applefmAvailable`. The `FMDecisionTier` populates `decision`,
/// `effectivePath` and `fmStart`; post-FM override tiers read or mutate
/// `effectivePath`; the final `DispatchTier` consumes the populated decision.
struct RouterContext {
    /// Raw user utterance (already trimmed/normalised upstream by the agent).
    let text: String

    /// Optional transcript context (last N turns verbatim) used by
    /// `dispatchDelegateLocal` for topic coreference.
    let history: String

    /// Snapshot of the user-selected operating mode at the start of the pass.
    /// `auto` keeps every path enabled; restricted modes disable Path 2/3/4
    /// and route through `mode.remap` after the FM decision.
    let mode: GigiMode

    /// Snapshot of Apple FM availability at the start of the pass. Captured
    /// once so the FM and post-FM tiers see a consistent value.
    let applefmAvailable: Bool

    /// Set by `FMDecisionTier` once the FM (or fallback) router has produced
    /// a decision. Nil for the pre-FM tier window.
    var decision: FoundationRouterDecision?

    /// Set by `FMDecisionTier` (after `mode.remap`), mutated by
    /// `CloudDowngradeTier`, `CompoundCommandTier` and `ClarificationDowngradeTier`,
    /// consumed by `DispatchTier`.
    var effectivePath: String?

    /// Latency anchor for the FM branch — captured by `FMDecisionTier`
    /// immediately before invoking the FM session, read by the telemetry
    /// emitter inside `DispatchTier`.
    var fmStart: Date?
}

// MARK: - TierOutcome

/// The three possible results of evaluating a `RouterTier`.
enum TierOutcome {
    /// The tier did not apply to this utterance; continue with the next tier.
    case `pass`

    /// The tier mutated `RouterContext` (e.g. downgraded `effectivePath`) and
    /// the pipeline should continue. Functionally identical to `.pass` for the
    /// runner — distinct for tracing/logging clarity.
    case mutate

    /// The tier handled the utterance fully; the pipeline returns this
    /// `RouteResult` to the caller immediately.
    case terminal(RouteResult)
}

// MARK: - RouterTier

/// A single step in the declarative routing pipeline. Tiers are evaluated in
/// array order; the first `.terminal` outcome short-circuits the loop.
///
/// All evaluation runs on `@MainActor` because the existing helpers
/// (`GigiActionBridge`, `GigiConversationMemory`, FM session) are
/// main-actor-isolated.
@MainActor
protocol RouterTier {
    /// Short identifier used in trace/debug logging. Match the legacy comment
    /// keywords where possible (`"math"`, `"alias"`, `"semantic"`, ...).
    var name: String { get }

    /// Evaluate this tier against the current context. Implementations should
    /// either return `.pass` quickly when they do not apply, mutate `ctx` and
    /// return `.mutate`, or perform the dispatch and return `.terminal`.
    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome
}

// MARK: - Pipeline runner

extension GigiRequestRouter {
    /// Sequentially evaluates `tiers` against `ctx`. Returns the first
    /// terminal outcome's `RouteResult`, or `nil` if every tier returned
    /// `.pass`/`.mutate` — the caller decides what to do with the empty
    /// case (during the migration, fall through to the legacy chain;
    /// once Step 9 ships, the DispatchTier guarantees a terminal).
    func runPipeline(_ tiers: [RouterTier], ctx: inout RouterContext) async -> RouteResult? {
        for tier in tiers {
            switch await tier.evaluate(&ctx) {
            case .pass, .mutate:
                continue
            case .terminal(let result):
                return result
            }
        }
        return nil
    }
}

// MARK: - Step 5 migrated tiers (stateful pre-FM)

/// GATE 15 Step 0.5 — Conversational consent for an active ShortcutProposal
/// card on screen. Lets the user accept/dismiss the proposal by voice or
/// chat without tapping the card. Short utterances only (1-4 words) to
/// avoid catching "yes call mom from spotify" as consent. Long utterances
/// fall through (.pass) so the normal pipeline can dispatch the real intent
/// while the card stays visible.
struct ProposalConsentTier: RouterTier {
    let name = "proposal_consent"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let proposal = GigiSmartOrchestrator.shared.shortcutProposal else { return .pass }
        let utterance = ctx.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = utterance.split { $0.isWhitespace }.count
        guard wordCount > 0 && wordCount <= 4 else { return .pass }

        if GigiRequestRouter.detectAffirmative(in: utterance) {
            GigiDebugLogger.log("GIGI Router: proposal consent → CONFIRM via '\(utterance)'")
            proposal.onConfirm()
            let speech = "Building '\(proposal.title)'..."
            GigiConversationMemory.shared.addModelSpeech(speech)
            return .terminal(.actionInvoked(speech: speech, tool: "shortcut_proposal_confirm"))
        }
        if GigiRequestRouter.detectNegative(in: utterance) {
            GigiDebugLogger.log("GIGI Router: proposal consent → CANCEL via '\(utterance)'")
            proposal.onCancel()
            let speech = "Cancelled."
            GigiConversationMemory.shared.addModelSpeech(speech)
            return .terminal(.actionInvoked(speech: speech, tool: "shortcut_proposal_cancel"))
        }
        return .pass
    }
}

/// Consumes a `pendingWorldAction` proposal staged by the world-action
/// propose-first guard. Sits right after ProposalConsentTier so confirmation
/// routing happens BEFORE the FM router sees the utterance and risks
/// re-classifying it as a fresh, unrelated request.
///
/// Classification is delegated to an on-device FM call
/// (`resolveConfirmation`) that returns one of four kinds: confirm, reject,
/// modify, unrelated. Regex affirmative/negative matchers are kept ONLY as
/// a fallback for when Apple FM is unavailable or errors out — they don't
/// understand "modify" turns ("yes but make it spicy") and they reject
/// anything > 4 words even when it's a clear confirmation.
struct WorldActionConsentTier: RouterTier {
    let name = "world_action_consent"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        let mem = GigiConversationMemory.shared
        guard let proposal = mem.peekPendingWorldAction() else { return .pass }
        let utterance = ctx.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return .pass }

        // Primary path: on-device FM classification.
        #if canImport(FoundationModels)
        if #available(iOS 18.1, *),
           let decision = await GigiFoundationSession.shared.resolveConfirmation(
                userReply: utterance,
                proposalSummary: proposal.summary
           ) {
            switch decision.kind {
            case "confirm":
                _ = mem.consumePendingWorldAction()
                GigiDebugLogger.log("GIGI Router: world-action CONFIRM (fm) → brief='\(proposal.executionBrief.prefix(80))'")
                return .terminal(await router.executeConfirmedWorldAction(proposal))
            case "modify":
                _ = mem.consumePendingWorldAction()
                let brief = decision.modificationBrief.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveBrief = brief.isEmpty ? proposal.executionBrief : brief
                GigiDebugLogger.log("GIGI Router: world-action MODIFY (fm) → brief='\(effectiveBrief.prefix(80))'")
                let modified = GigiConversationMemory.WorldActionProposal(
                    kind: proposal.kind,
                    summary: proposal.summary,
                    executionBrief: effectiveBrief,
                    originalText: utterance,
                    timestamp: Date()
                )
                return .terminal(await router.executeConfirmedWorldAction(modified))
            case "reject":
                mem.clearPendingWorldAction()
                let speech = decision.directSpeech.isEmpty ? "Cancelled." : decision.directSpeech
                mem.addModelSpeech(speech)
                GigiDebugLogger.log("GIGI Router: world-action REJECT (fm)")
                return .terminal(.actionInvoked(speech: speech, tool: "world_action_cancel"))
            case "unrelated":
                // Drop the stale proposal and let the normal pipeline handle
                // the new request. If the user wanted both, they can repeat.
                mem.clearPendingWorldAction()
                GigiDebugLogger.log("GIGI Router: world-action UNRELATED (fm) — dropping pending proposal, falling through")
                return .pass
            default:
                GigiDebugLogger.log("GIGI Router: world-action FM returned unknown kind='\(decision.kind)' — falling back to regex")
            }
        }
        #endif

        // Fallback: regex matchers (only short utterances, same constraint
        // as ProposalConsentTier — long replies fall through so the normal
        // pipeline can dispatch them).
        let wordCount = utterance.split { $0.isWhitespace }.count
        guard wordCount > 0 && wordCount <= 4 else { return .pass }
        if GigiRequestRouter.detectAffirmative(in: utterance) {
            _ = mem.consumePendingWorldAction()
            GigiDebugLogger.log("GIGI Router: world-action CONFIRM (regex) → brief='\(proposal.executionBrief.prefix(80))'")
            return .terminal(await router.executeConfirmedWorldAction(proposal))
        }
        if GigiRequestRouter.detectNegative(in: utterance) {
            mem.clearPendingWorldAction()
            let speech = "Cancelled."
            mem.addModelSpeech(speech)
            GigiDebugLogger.log("GIGI Router: world-action CANCEL (regex)")
            return .terminal(.actionInvoked(speech: speech, tool: "world_action_cancel"))
        }
        return .pass
    }
}

/// Bug #016 continuation — consume a slot the previous turn asked for, fill
/// the original intent, and dispatch. Three outcomes:
///   - User said "no/cancel" → emit cancel speech (.terminal)
///   - User started a new command (verb like "set/call/turn") → SUPERSEDED:
///     pending was consumed but we fall through (.pass) so normal routing
///     can dispatch the new command instead
///   - Otherwise → fill the slot with the user's text and dispatch (.terminal)
struct PendingClarificationTier: RouterTier {
    let name = "pending_clarification"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let pending = GigiConversationMemory.shared.consumePendingClarification() else { return .pass }

        if GigiRequestRouter.detectNegative(in: ctx.text) {
            GigiDebugLogger.log("GIGI Router: pending clarification CANCELLED")
            let speech = "Cancelled."
            GigiConversationMemory.shared.addModelSpeech(speech)
            return .terminal(.actionInvoked(speech: speech, tool: "\(pending.intent)_cancel"))
        }
        if GigiRequestRouter.looksLikeNewCommand(ctx.text) {
            GigiDebugLogger.log("GIGI Router: pending clarification SUPERSEDED by new command — falling through")
            return .pass
        }

        var params = pending.partialParams
        params[pending.slot] = ctx.text
        params["raw"] = ctx.text
        GigiDebugLogger.log("GIGI Router: pending clarification CONTINUED — intent=\(pending.intent) slot=\(pending.slot) value='\(ctx.text.prefix(40))'")
        let intent = GigiIntent(label: pending.intent, confidence: 1.0, params: params)
        let speech = await GigiActionBridge.shared.execute(intent)
        let finalSpeech = speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Done."
            : speech
        GigiRouterTrace.shared.record(
            utterance: ctx.text, tier: "clarification-continuation",
            tool: pending.intent, confidence: 1.0, slot: params[pending.slot]
        )
        GigiConversationMemory.shared.addModelSpeech(finalSpeech)
        return .terminal(.actionInvoked(speech: finalSpeech, tool: pending.intent))
    }
}

// MARK: - Step 2 migrated tiers

/// Discovery intercept — matches "what can you do?", "help", "cosa sai fare?"
/// and emits a curated overview. See `GigiRequestRouter.detectDiscoveryQuery`.
struct DiscoveryQueryTier: RouterTier {
    let name = "discovery"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard router.detectDiscoveryQuery(in: ctx.text) else { return .pass }
        let speech = router.discoveryOverviewResponse()
        GigiDebugLogger.log("GIGI Router: discovery intercept → curated overview")
        GigiConversationMemory.shared.addModelSpeech(speech)
        return .terminal(.spoken(speech))
    }
}

/// Tier-0 math expression detection. Pure digit/operator patterns are
/// dispatched to `calculate_math` directly so we don't burn an LLM call on
/// arithmetic the NSExpression evaluator handles in microseconds.
struct MathExpressionTier: RouterTier {
    let name = "math"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let mathExpression = router.detectMathExpression(in: ctx.text) else { return .pass }
        GigiDebugLogger.log("GIGI Router: tier-0 calculate_math → '\(mathExpression)'")
        let speech = await GigiActionBridge.shared.execute(GigiIntent(
            label: "calculate_math",
            confidence: 1.0,
            params: ["expression": mathExpression, "raw": mathExpression]
        ))
        let finalSpeech = router.debugPrefix(
            routerSource: "regex",
            tool: "calculate_math",
            confidence: 1.0,
            slot: mathExpression
        ) + speech
        GigiRouterTrace.shared.record(
            utterance: ctx.text, tier: "regex",
            tool: "calculate_math", confidence: 1.0, slot: mathExpression
        )
        GigiConversationMemory.shared.addModelSpeech(finalSpeech)
        return .terminal(.actionInvoked(speech: finalSpeech, tool: "calculate_math"))
    }
}

// MARK: - Step 3 migrated tiers

/// Registered Shortcut alias intercept. The user can register Apple Shortcuts
/// with natural-language aliases in Settings — explicit user-declared aliases
/// have the highest priority among regex/Apple-FM dispatch paths.
struct RegisteredAliasTier: RouterTier {
    let name = "alias"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let registered = GigiShortcutRegistry.shared.matchAlias(ctx.text) else { return .pass }
        GigiDebugLogger.log("GIGI Router: registered-alias match → '\(registered.name)' from utterance '\(ctx.text)'")
        GigiShortcutRegistry.shared.recordUse(name: registered.name)
        let speech = await GigiActionBridge.shared.execute(GigiIntent(
            label: "run_shortcut",
            confidence: 1.0,
            params: ["name": registered.name, "raw": registered.name, "input": ""]
        ))
        let finalSpeech = router.debugPrefix(
            routerSource: "alias",
            tool: "run_shortcut",
            confidence: 1.0,
            slot: registered.name
        ) + speech
        GigiRouterTrace.shared.record(
            utterance: ctx.text, tier: "alias",
            tool: "run_shortcut", confidence: 1.0, slot: registered.name
        )
        GigiConversationMemory.shared.addModelSpeech(finalSpeech)
        return .terminal(.actionInvoked(speech: finalSpeech, tool: "run_shortcut"))
    }
}

/// Tier-0 "build/create/make a shortcut" regex. Routes DIRECTLY to the harness
/// Claude composer (bypassing Apple FM) — FM on-device returns conversational
/// apologies for structured JSON synthesis of multi-step shortcuts.
/// Trade-off: ~3-12s harness round-trip per ADR-0014 follow-up.
struct BuildShortcutRegexTier: RouterTier {
    let name = "build_shortcut_regex"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let description = router.detectBuildShortcutPattern(in: ctx.text) else { return .pass }
        GigiDebugLogger.log("GIGI Router: regex tier-0 build_shortcut → '\(description)' (via harness composer)")
        let speech = await GigiActionBridge.shared.composeShortcut(rawText: ctx.text)
        let withPrefix = router.debugPrefix(
            routerSource: "regex+claude",
            tool: "build_shortcut",
            confidence: 1.0,
            slot: description
        ) + speech
        GigiRouterTrace.shared.record(
            utterance: ctx.text, tier: "regex",
            tool: "build_shortcut", confidence: 1.0, slot: description, path: "harness"
        )
        GigiConversationMemory.shared.addModelSpeech(withPrefix)
        return .terminal(.actionInvoked(speech: withPrefix, tool: "build_shortcut"))
    }
}

/// Tier-0 explicit verb regex for `run_shortcut`. Captures imperative
/// phrasings like "run X", "execute X", "launch X", "esegui X", where X is a
/// Shortcut name by definition (regex precision-100 by construction).
/// Semantic-router stays as the natural-language fallback for variants the
/// regex doesn't cover.
struct RunShortcutRegexTier: RouterTier {
    let name = "run_shortcut_regex"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let shortcutName = router.detectRunShortcutPattern(in: ctx.text) else { return .pass }
        GigiDebugLogger.log("GIGI Router: regex tier-0 run_shortcut → '\(shortcutName)'")
        let speech = await GigiActionBridge.shared.execute(GigiIntent(
            label: "run_shortcut",
            confidence: 1.0,
            params: ["name": shortcutName, "raw": shortcutName, "input": ""]
        ))
        let finalSpeech = router.debugPrefix(
            routerSource: "regex",
            tool: "run_shortcut",
            confidence: 1.0,
            slot: shortcutName
        ) + speech
        GigiRouterTrace.shared.record(
            utterance: ctx.text, tier: "regex",
            tool: "run_shortcut", confidence: 1.0, slot: shortcutName
        )
        GigiConversationMemory.shared.addModelSpeech(finalSpeech)
        return .terminal(.actionInvoked(speech: finalSpeech, tool: "run_shortcut"))
    }
}

// MARK: - Step 6 migrated tier (FM decision)

/// Apple FM router (or rule-based fallback when FM unavailable or disabled
/// by mode). Snapshots fmStart for the telemetry latency anchor, populates
/// `ctx.decision`, applies `mode.remap` to compute `ctx.effectivePath`, then
/// returns `.mutate` so downstream post-FM tiers can override either field.
struct FMDecisionTier: RouterTier {
    let name = "fm_decision"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        ctx.fmStart = Date()

        let decision: FoundationRouterDecision
        if ctx.applefmAvailable && ctx.mode.allowsAppleFMRouter {
            #if canImport(FoundationModels)
            if #available(iOS 18.1, *) {
                do {
                    decision = try await GigiFoundationSession.shared.routeRequest(text: ctx.text, history: ctx.history)
                } catch {
                    GigiDebugLogger.log("GIGI Router: Apple FM failed (\(error.localizedDescription)) — falling back to keyword router.")
                    decision = GigiFallbackRouter.shared.classifyRequest(text: ctx.text)
                }
            } else {
                decision = GigiFallbackRouter.shared.classifyRequest(text: ctx.text)
            }
            #else
            decision = GigiFallbackRouter.shared.classifyRequest(text: ctx.text)
            #endif
        } else {
            decision = GigiFallbackRouter.shared.classifyRequest(text: ctx.text)
        }

        ctx.decision = decision
        ctx.effectivePath = ctx.mode.remap(decision.path, capabilities: decision.requiredCapabilities)
        return .mutate
    }
}

// MARK: - Step 8 final tier (dispatch)

/// Always-terminal tier that consumes the populated context: emits telemetry
/// + trace, dispatches on `effectivePath` via the router's bridge helpers,
/// then prepends the `[appleFM ...]` debug prefix to the final speech.
///
/// This is the tail of the pipeline — placed last so every preceding tier
/// has had a chance to short-circuit (.terminal) or mutate (`effectivePath`).
struct DispatchTier: RouterTier {
    let name = "dispatch"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let decision = ctx.decision,
              let effectivePath = ctx.effectivePath,
              let fmStart = ctx.fmStart else {
            return .terminal(.error("DispatchTier: router context not populated"))
        }

        // Telemetry to harness Live Monitor (Bug #012). No-op when not paired.
        let fmElapsedMs = Int(Date().timeIntervalSince(fmStart) * 1000)
        router.harness.postTelemetry(
            type: "router_decision",
            path: effectivePath,
            primaryAction: decision.primaryAction,
            userText: ctx.text,
            elapsedMs: fmElapsedMs
        )
        // First non-empty slot for the trace summary.
        let traceSlot: String? = {
            let s = decision.slots
            for v in [s.contact, s.taskText, s.body, s.destination, s.duration] where !v.isEmpty {
                return v
            }
            return nil
        }()
        GigiRouterTrace.shared.record(
            utterance: ctx.text,
            tier: ctx.applefmAvailable && ctx.mode.allowsAppleFMRouter ? "appleFM" : "fallback",
            tool: decision.primaryAction.isEmpty ? effectivePath : decision.primaryAction,
            confidence: Float(decision.confidence),
            slot: traceSlot,
            path: effectivePath,
            latencyMs: fmElapsedMs
        )

        let result: RouteResult
        switch effectivePath {
        case "native_tool":
            result = await router.dispatchNativeTool(decision: decision, originalText: ctx.text, history: ctx.history)
        case "delegate_local":
            result = await router.dispatchDelegateLocal(decision: decision, originalText: ctx.text, history: ctx.history)
        case "delegate_cloud":
            result = await router.dispatchDelegateCloud(decision: decision, originalText: ctx.text, history: ctx.history)
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
            return .terminal(.error("Unknown routing decision: \(effectivePath)."))
        }

        // GATE 15 — DEBUG-only routing diagnostic. Prepends a one-line tag
        // showing which router fired so the user can immediately see what
        // dispatched. Stripped in release builds via `#if DEBUG` in
        // `debugPrefix()`.
        let primaryAction = decision.primaryAction.isEmpty ? effectivePath : decision.primaryAction
        let prefix = router.debugPrefix(
            routerSource: "appleFM",
            tool: primaryAction,
            confidence: Float(decision.confidence)
        )
        let wrapped = prefix.isEmpty ? result : router.prependDebug(prefix, to: result)
        return .terminal(wrapped)
    }
}

// MARK: - Step 7 migrated tiers (post-FM overrides)

/// Bug #003 defensive downgrade — Apple FM occasionally routes knowledge Q&A
/// to delegate_cloud when there's no web/code/image verb in the utterance and
/// no declared browser/code/vision capability. Saves a useless Claude Code
/// spawn (and a /login error if claude isn't logged in) by downgrading to
/// delegate_local, where Ollama can answer.
struct CloudDowngradeTier: RouterTier {
    let name = "cloud_downgrade"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let decision = ctx.decision, ctx.effectivePath == "delegate_cloud" else { return .pass }
        guard !GigiRequestRouter.hasWebOrCodeOrImageVerb(ctx.text),
              decision.requiredCapabilities.isEmpty else { return .pass }
        GigiDebugLogger.log("GIGI Router: delegate_cloud DOWNGRADED to delegate_local — no web/code/image verb in prompt")
        ctx.effectivePath = "delegate_local"
        return .mutate
    }
}

/// Compound-command override (2026-05-17) — Apple FM sometimes treats
/// "<X> is <state> <imperative> <object>" as a pure fact assertion and picks
/// native_tool(remember). Example: "my car is broken find the nearest
/// mechanic" — FM misses the embedded imperative. Downgrade to delegate_local
/// so Ollama can respond to the task.
struct CompoundCommandTier: RouterTier {
    let name = "compound_command"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let decision = ctx.decision,
              ctx.effectivePath == "native_tool",
              decision.primaryAction == "remember",
              GigiRequestRouter.containsEmbeddedImperative(in: ctx.text) else { return .pass }
        GigiDebugLogger.log("GIGI Router: native_tool(remember) DOWNGRADED to delegate_local — embedded imperative in '\(ctx.text)'")
        ctx.effectivePath = "delegate_local"
        return .mutate
    }
}

/// Bug #015 fact-assertion override — Apple FM sometimes routes bare fact
/// assertions ("Sergio is my brother") to delegate_local, where Ollama
/// generates "Got it" without persisting anything. Detect the regex pattern
/// and dispatch native remember directly through the bridge (NOT through
/// Apple FM tool-calling, which can re-extract subjects unstably).
struct FactAssertionTier: RouterTier {
    let name = "fact_assertion"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let path = ctx.effectivePath,
              path == "delegate_local" || path == "ask_clarification",
              let (subject, value) = GigiRequestRouter.detectFactAssertion(in: ctx.text) else { return .pass }
        GigiDebugLogger.log("GIGI Router: fact-assertion OVERRIDE — \(path) → bridge(remember). subject='\(subject)' value='\(value)'")
        let intent = GigiIntent(
            label: "remember",
            confidence: 1.0,
            params: ["contact": subject, "body": value, "raw": ctx.text]
        )
        let speech = await GigiActionBridge.shared.execute(intent)
        let finalSpeech = speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Got it. I'll remember that."
            : speech
        GigiRouterTrace.shared.record(
            utterance: ctx.text, tier: "regex-override",
            tool: "remember", confidence: 1.0, slot: subject
        )
        GigiConversationMemory.shared.annotateLastTurn(
            intent: "remember", slot: subject, tier: "regex-override", success: true
        )
        // Coreference: track the asserted subject so the next turn can
        // resolve "him/her" to it — but only if the subject is a person.
        if GigiMemory.smartKey(forSubject: subject).hasPrefix("contact:") {
            GigiConversationMemory.shared.recordReferent(subject, kind: "person")
        }
        GigiConversationMemory.shared.addModelSpeech(finalSpeech)
        return .terminal(.actionInvoked(speech: finalSpeech, tool: "remember"))
    }
}

/// Bug #12 reminder-verb upgrade — Apple FM mis-classifies "Remind me to X"
/// and the colloquial "Remember me to X" as delegate_local because the verb
/// "remember" overlaps with GIGI's memory verb. The NLU fast-path catches
/// canonical "remind me to" upstream but has no trigger for "remember me to",
/// so that phrasing always reaches the router. When FM has settled on
/// delegate_local / ask_clarification AND the utterance starts with the
/// reminder pattern, force native_tool(set_reminder) with taskText extracted
/// from the suffix. Ollama cannot create iOS reminders; this override is the
/// safety net for Apple FM's @Guide-non-binding behaviour.
struct ReminderUpgradeTier: RouterTier {
    let name = "reminder_upgrade"
    unowned let router: GigiRequestRouter

    private static let triggers = [
        "remember me to ",
        "remind me to ",
        "ricordami di ",
    ]

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let path = ctx.effectivePath,
              path == "delegate_local" || path == "ask_clarification" else { return .pass }
        let lowered = ctx.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trigger = Self.triggers.first(where: { lowered.hasPrefix($0) }) else { return .pass }

        // Preserve original-case task body (strip the trigger length, then trim).
        let trimmed = ctx.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(trimmed.dropFirst(trigger.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .pass }

        GigiDebugLogger.log("GIGI Router: reminder-verb OVERRIDE — \(path) → bridge(set_reminder). taskText='\(body)' trigger='\(trigger)'")
        let intent = GigiIntent(
            label: "set_reminder",
            confidence: 1.0,
            params: ["text": body, "raw": ctx.text]
        )
        let speech = await GigiActionBridge.shared.execute(intent)
        let finalSpeech = speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Reminder set: \(body)."
            : speech
        GigiRouterTrace.shared.record(
            utterance: ctx.text, tier: "regex-override",
            tool: "set_reminder", confidence: 1.0, slot: body
        )
        GigiConversationMemory.shared.annotateLastTurn(
            intent: "set_reminder", slot: body, tier: "regex-override", success: true
        )
        GigiConversationMemory.shared.addModelSpeech(finalSpeech)
        return .terminal(.actionInvoked(speech: finalSpeech, tool: "set_reminder"))
    }
}

/// Bug #016 messaging-without-body override — "Send Marco a message" with no
/// body gets routed by FM to delegate_local; Ollama can't send messages, so
/// it answers with a verbose apology. Detect messaging-shape utterances
/// without a body indicator and ask for the body explicitly, setting up a
/// pending clarification slot that PendingClarificationTier consumes next turn.
struct MessageWithoutBodyTier: RouterTier {
    let name = "message_without_body"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let detected = GigiRequestRouter.detectMessageWithoutBody(in: ctx.text) else { return .pass }
        let resolvedContact = (await GigiRequestRouter.resolveContactFromMemory(detected)) ?? detected
        let contact = resolvedContact
        let directSpeech = "What do you want to say to \(contact)?"
        let platform = await GigiRequestRouter.resolveMessagePlatform(forUtterance: ctx.text)
        GigiDebugLogger.log("GIGI Router: msg-without-body OVERRIDE — \(ctx.effectivePath ?? "?") → ask_clarification, contact='\(contact)' (detected='\(detected)') platform='\(platform)'")
        GigiConversationMemory.shared.setPendingClarification(.init(
            intent: "send_message",
            slot: "body",
            partialParams: ["contact": contact, "platform": platform],
            timestamp: Date()
        ))
        GigiConversationMemory.shared.recordReferent(contact, kind: "person")
        GigiRouterTrace.shared.record(
            utterance: ctx.text, tier: "regex-override",
            tool: "ask_clarification", confidence: 1.0, slot: contact
        )
        GigiConversationMemory.shared.annotateLastTurn(
            intent: "ask_clarification", slot: contact, tier: "regex-override", success: true
        )
        GigiConversationMemory.shared.addModelSpeech(directSpeech)
        return .terminal(.spoken(directSpeech))
    }
}

/// Bug #018 — messaging shape with unresolved pronoun. "Send him a message"
/// when no known person referent exists. Rather than fall through to Ollama
/// (which can't send messages anyway), ask for the contact explicitly so the
/// next turn can supply it.
struct UnresolvedContactTier: RouterTier {
    let name = "unresolved_contact"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard GigiRequestRouter.detectMessageWithUnresolvedContact(in: ctx.text) else { return .pass }
        let platform = await GigiRequestRouter.resolveMessagePlatform(forUtterance: ctx.text)
        let directSpeech = "Who do you want to send a message to?"
        GigiDebugLogger.log("GIGI Router: msg-unresolved-contact OVERRIDE — \(ctx.effectivePath ?? "?") → ask_clarification")
        GigiConversationMemory.shared.setPendingClarification(.init(
            intent: "send_message",
            slot: "contact",
            partialParams: ["platform": platform],
            timestamp: Date()
        ))
        GigiRouterTrace.shared.record(
            utterance: ctx.text, tier: "regex-override",
            tool: "ask_clarification", confidence: 1.0, slot: nil
        )
        GigiConversationMemory.shared.annotateLastTurn(
            intent: "ask_clarification", slot: nil, tier: "regex-override", success: true
        )
        GigiConversationMemory.shared.addModelSpeech(directSpeech)
        return .terminal(.spoken(directSpeech))
    }
}

/// Bug #014 ask_clarification downgrade — Apple FM occasionally bounces
/// open-knowledge questions ("Who is Einstein?") to ask_clarification with
/// low confidence because it isn't sure whether the entity is a contact or a
/// public figure. Memory has already been probed upstream and missed, so the
/// safest fallback is delegate_local — Ollama can always answer
/// who/what/why/how knowledge queries.
struct ClarificationDowngradeTier: RouterTier {
    let name = "clarification_downgrade"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let decision = ctx.decision,
              ctx.effectivePath == "ask_clarification",
              decision.confidence < 0.75,
              GigiRequestRouter.looksLikeOpenKnowledgeQuery(ctx.text) else { return .pass }
        GigiDebugLogger.log("GIGI Router: ask_clarification DOWNGRADED to delegate_local — open knowledge query pattern (\(ctx.text.prefix(40)))")
        ctx.effectivePath = "delegate_local"
        return .mutate
    }
}

// MARK: - Step 4 migrated tier

/// GATE 15 Smart Router semantic fast-path. NLEmbedding word vectors match
/// the utterance against a curated catalog of trigger phrases per tool. On a
/// confident match (cosine ≥0.55, gap ≥0.05) the tool is dispatched directly,
/// bypassing Apple FM. Two dispatch sub-paths:
///   - `build_shortcut` → harness Claude composer (same trade-off as the
///     regex tier — FM on-device can't synthesise the multi-step JSON).
///   - Everything else → `GigiActionBridge.execute` with params derived from
///     `router.buildSemanticParams(for:)`.
///
/// ADR-0012 — Smart Router Architecture.
struct SemanticRouterTier: RouterTier {
    let name = "semantic"
    unowned let router: GigiRequestRouter

    func evaluate(_ ctx: inout RouterContext) async -> TierOutcome {
        guard let match = GigiSemanticRouter.shared.match(ctx.text) else { return .pass }

        if match.toolName == "build_shortcut" {
            GigiDebugLogger.log("GIGI Router: semantic build_shortcut → harness composer (slot='\(match.slot)')")
            let speech = await GigiActionBridge.shared.composeShortcut(rawText: ctx.text)
            let withPrefix = router.debugPrefix(
                routerSource: "semantic+claude",
                tool: "build_shortcut",
                confidence: match.confidence,
                slot: match.slot
            ) + speech
            GigiRouterTrace.shared.record(
                utterance: ctx.text, tier: "semantic",
                tool: "build_shortcut", confidence: match.confidence,
                slot: match.slot, path: "harness"
            )
            GigiConversationMemory.shared.addModelSpeech(withPrefix)
            return .terminal(.actionInvoked(speech: withPrefix, tool: "build_shortcut"))
        }

        let params = router.buildSemanticParams(for: match)
        let speech = await GigiActionBridge.shared.execute(GigiIntent(
            label: match.toolName,
            confidence: Double(match.confidence),
            params: params
        ))
        let finalSpeech = router.debugPrefix(
            routerSource: "semantic",
            tool: match.toolName,
            confidence: match.confidence,
            slot: match.slot
        ) + speech
        GigiRouterTrace.shared.record(
            utterance: ctx.text, tier: "semantic",
            tool: match.toolName, confidence: match.confidence,
            slot: match.slot
        )
        GigiConversationMemory.shared.addModelSpeech(finalSpeech)
        return .terminal(.actionInvoked(speech: finalSpeech, tool: match.toolName))
    }
}
