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
            GigiConversationMemory.shared.addModelSpeech(finalSpeech)
            return .actionInvoked(speech: finalSpeech, tool: match.toolName)
        }

        // Mode gating (GATE 7) — read the selected operating mode and use
        // it to disable paths upfront. `.auto` (no mode set) keeps all paths.
        let mode = currentMode()

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

        // Bug #012 fix (2026-05-12) — telemetry to harness Live Monitor.
        // For every router decision, fire-and-forget a telemetry event so the
        // live monitor at localhost:7777/live.html shows what the iPhone is
        // doing even when the path stays on-device. No-op when not paired.
        harness.postTelemetry(
            type: "router_decision",
            path: effectivePath,
            primaryAction: decision.primaryAction,
            userText: text
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

    /// Curated English overview shown when the user asks discovery queries.
    /// Static for GATE 9 — context-aware top-3 comes in GATE 10 Layer B.
    private func discoveryOverviewResponse() -> String {
        // Single multi-line response that surfaces the 7 categories with a
        // concrete example for each. Kept under 60 words so TTS stays under
        // 15 seconds. Always English per CLAUDE.md §Lingua hard rule.
        return """
        I can help with a few things. Try saying: 'set a timer for 5 minutes', \
        'what's the weather', 'call mom', 'send a message to Marco on WhatsApp', \
        'navigate home', 'play my morning playlist', or 'activate the cinema scene'. \
        I can also run any Shortcut you've made — just say 'run' followed by its name.
        """
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
        default:
            return ["raw": slot]
        }
    }

    // MARK: - DEPRECATED — regex intercepts (replaced by GigiSemanticRouter in GATE 15)
    //
    // These regex pattern matchers were the GATE 9 patch for Apple FM
    // mis-routing. Now superseded by the embedding-based semantic router
    // which scales without adding new patterns. Kept in source for reference
    // and potential rollback; not called from route().

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
