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
        print("GIGI agentEngine.process ENTRY: text='\(text.prefix(60))'")
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
            return ollamaStubResult()
        case .claude:
            // Treat as if Force Claude were on — handled by the existing gate below.
            return await processForceClaude(text: text, autoFallbackOnError: false)
                ?? AgentResult(speech: "Force Claude path returned no result.",
                               executedTools: [], isFollowUp: false,
                               costEstimate: 0, requiresConfirm: nil, isError: true)
        }
        #endif

        // === Gate 1: deterministic NLU fast-path ===
        // 24 intent whitelist on-device (timer, call, message, navigate, etc.).
        // Confidence ≥0.95 → direct dispatch via GigiActionDispatcher.
        if let fastPath = await deterministicFastPath(for: text) {
            return fastPath
        }

        // === Gate 2: delegate to Claude (harness) ===
        //
        // Groq was removed from the main flow on 2026-05-11 (this commit).
        // Until GATE 2 of the 5-path plan introduces the Apple FM router upfront,
        // every non-NLU query is routed to the harness Claude bridge — the same
        // bridge that previously powered the Force Claude toggle (now hidden
        // behind #if DEBUG).
        //
        // This collapses the old 3-Gate flat (Force Claude → NLU → Groq agentLoop)
        // into a clean 2-gate (NLU → Claude). Behavior is equivalent to having
        // Force Claude permanently ON.
        //
        // Required: harness paired. When not paired the user gets a friendly
        // message asking to configure pairing from Settings.

        if !GigiHarnessClient.shared.isConfigured {
            return AgentResult(
                speech: "Pair the harness from Settings to enable the AI brain.",
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
            costEstimate: 0,
            requiresConfirm: nil,
            isError: false
        )
    }


    // MARK: - Deterministic NLU fast-path

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

    /// Path 3 (Ollama) stub — surfaces "not configured" until the harness wires it up.
    private func ollamaStubResult() -> AgentResult {
        AgentResult(
            speech: "Path 3 Ollama is not configured yet. Set up the harness Ollama bridge to enable this path. See docs/plans/frolicking-stargazing-pancake.md §3.",
            executedTools: [],
            isFollowUp: false,
            costEstimate: 0,
            requiresConfirm: nil,
            isError: true
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
