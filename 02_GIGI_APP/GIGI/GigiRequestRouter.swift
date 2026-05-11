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
        switch effectivePath {
        case "native_tool":
            return await dispatchNativeTool(decision: decision, originalText: text, history: history)
        case "delegate_local":
            return await dispatchDelegateLocal(decision: decision, originalText: text, history: history)
        case "delegate_cloud":
            return await dispatchDelegateCloud(decision: decision, originalText: text, history: history)
        case "ask_clarification":
            return .spoken(decision.directSpeech.isEmpty
                ? "Could you say that another way?"
                : decision.directSpeech)
        case "reject":
            return .spoken(decision.directSpeech.isEmpty
                ? "I can't help with that one."
                : decision.directSpeech)
        case "mode_blocked_local":
            return .spoken("Local AI is disabled in this mode. Switch to Local-First or Full Power mode to enable Ollama.")
        case "mode_blocked_cloud":
            return .spoken("Cloud mode is disabled in this mode. Switch to Apple Optimized or Full Power mode to enable Claude Code.")
        default:
            return .error("Unknown routing decision: \(effectivePath).")
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
        let prompt = decision.delegatePrompt.isEmpty ? originalText : decision.delegatePrompt

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
        if params["raw"] == nil       { params["raw"]         = originalText }
        return params
    }

    // MARK: - Mode gating (GATE 7)

    private func currentMode() -> GigiMode {
        let raw = UserDefaults.standard.string(forKey: "gigi.user.mode") ?? GigiMode.fullPower.rawValue
        return GigiMode(rawValue: raw) ?? .fullPower
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
