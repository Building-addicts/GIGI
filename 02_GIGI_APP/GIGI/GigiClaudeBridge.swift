import Foundation

// MARK: - GigiClaudeBridge
//
// Coordinator between GIGI's agent loop and the Claude harness backend.
// Invoked by AgentEngine when Groq's LLM calls the `ask_claude` tool, or
// directly by SettingsView's Force-Claude toggle (Phase 2).
//
// Responsibilities:
//  1. Assemble a compact "user snapshot" (profile + calendar + memories)
//     and push it with every task so Claude has context without needing
//     a reverse-query protocol (Phase 3 will add that).
//  2. Open/reuse a WebSocket stream to the harness, translate Claude CLI
//     event frames into `.thinking` / `.toolEvent` bubbles in
//     GigiConversationMemory.
//  3. Produce a `ToolResult` compatible with the existing tool pipeline.
//
// Claude CLI event schema (as forwarded verbatim by the harness under
// `claude_event.event`):
//   type=system,    subtype=init          → session kicked off
//   type=assistant, message.content = [
//       {type: "text", text: "…"}              → streamed reasoning  → .thinking
//       {type: "tool_use", id, name, input}    → Claude invokes a tool → .toolEvent (running)
//   ]
//   type=user,      message.content = [
//       {type: "tool_result", tool_use_id, content}  → tool finished  → updateToolEvent
//   ]
//   type=result                            → final message (also comes through HTTP response)
//
// The outer WebSocket envelope adds a `type` of its own:
//   {type: "claude_event", runId, event: <claude-cli-event>}
//   {type: "done", runId, session_id}
//   {type: "cancelled", runId}

@MainActor
final class GigiClaudeBridge {
    static let shared = GigiClaudeBridge()
    private init() {}

    // MARK: - State

    /// Lazy long-lived WebSocket. Opened on first `run()`, kept alive for
    /// subsequent turns. `GigiHarnessStream` already auto-reconnects with
    /// exponential backoff on disconnect.
    private var stream: GigiHarnessStream?

    /// Reference to the conversation memory so the bridge can append
    /// `.thinking` / `.toolEvent` bubbles as stream events arrive.
    /// Set by `GigiAgentEngine` on first invocation (Phase 1.6).
    weak var memory: GigiConversationMemory?

    /// Maps Claude CLI `tool_use.id` → `GigiMessage.id` of the running tool-event
    /// bubble, so we can transition it from "running" → "done" when the
    /// matching `tool_result` event arrives.
    private var toolBubbleIdByToolUseId: [String: UUID] = [:]

    // MARK: - Public entry

    /// Entry point called from `AskClaudeTool.execute(...)` (Phase 1.5) and
    /// from `GigiAgentEngine.process(...)` when Force Claude is on (Phase 2.3).
    ///
    /// Flow:
    ///  1. Build the context snapshot and prepend it to the task.
    ///  2. Ensure the WebSocket stream is up (so events can flow in while
    ///     the HTTP call is in flight).
    ///  3. POST /api/ios/agent/run with stream=true — await the final
    ///     HTTP response. The harness finishes the HTTP call only after
    ///     Claude terminates, so on resume we have the authoritative
    ///     final text in `AgentResult.result`.
    ///  4. Translate harness error cases into user-visible Italian strings
    ///     per AC-5 of the plan.
    func run(task: String, context: String?) async -> ToolResult {
        let snapshot = await buildContextSnapshot()
        let composedTask = composeTaskPayload(snapshot: snapshot, task: task, extra: context)

        ensureStreamConnected()

        GigiDebugLogger.log("GigiClaudeBridge.run → task='\(task.prefix(60))' ctx=\(context?.count ?? 0)B snapshot=\(snapshot.count)B")

        let result = await GigiHarnessClient.shared.agentRun(text: composedTask, stream: true)
        switch result {
        case .success(let agentResult):
            let finalText = agentResult.result.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = (agentResult.usage?.output_tokens ?? 0) + (agentResult.usage?.input_tokens ?? 0)
            return ToolResult.success(finalText.isEmpty ? "(Claude returned empty response)" : finalText,
                                      tokenEstimate: max(tokens, 50))

        case .failure(let err):
            SoundEngine.play(.error)
            let message = Self.userFacingError(for: err)
            GigiDebugLogger.log("GigiClaudeBridge error — \(err)")
            return ToolResult.failure(message)
        }
    }

    // MARK: - Stream wiring

    private func ensureStreamConnected() {
        if stream != nil { return }
        let s = GigiHarnessStream()
        toolBubbleIdByToolUseId.removeAll(keepingCapacity: true)
        s.connect { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleStreamEvent(event)
            }
        }
        stream = s
    }

    private func handleStreamEvent(_ event: [String: Any]) {
        guard let envelopeType = event["type"] as? String else { return }
        switch envelopeType {
        case "claude_event":
            if let inner = event["event"] as? [String: Any] {
                translateClaudeEvent(inner)
            }
        case "done":
            // Flush any orphan running tool bubbles so they don't stay stuck
            // at "running" forever (happens rarely, e.g. if the tool_result
            // event is merged with the final result output).
            for id in toolBubbleIdByToolUseId.values {
                memory?.updateToolEvent(id: id, status: "done")
            }
            toolBubbleIdByToolUseId.removeAll(keepingCapacity: true)
        case "cancelled":
            for id in toolBubbleIdByToolUseId.values {
                memory?.updateToolEvent(id: id, status: "cancelled")
            }
            toolBubbleIdByToolUseId.removeAll(keepingCapacity: true)
            memory?.addThought("task cancellato")
        default:
            break
        }
    }

    private func translateClaudeEvent(_ ev: [String: Any]) {
        guard let type = ev["type"] as? String else { return }
        switch type {
        case "system":
            // init event — skip, we don't narrate session boot to the user
            break

        case "assistant":
            guard let message = ev["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for item in content {
                guard let itemType = item["type"] as? String else { continue }
                switch itemType {
                case "text":
                    if let text = item["text"] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        memory?.addThought(trimmed)
                    }
                case "tool_use":
                    guard let name = item["name"] as? String,
                          let toolUseId = item["id"] as? String else { continue }
                    if let bubble = memory?.addToolEvent(name: name, status: "running") {
                        toolBubbleIdByToolUseId[toolUseId] = bubble
                    }
                default:
                    break
                }
            }

        case "user":
            // Contains tool_result blocks. Claude CLI emits them even without
            // actually executing tools (e.g. its own Bash runs).
            guard let message = ev["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for item in content {
                guard let itemType = item["type"] as? String, itemType == "tool_result",
                      let toolUseId = item["tool_use_id"] as? String else { continue }
                if let bubble = toolBubbleIdByToolUseId[toolUseId] {
                    memory?.updateToolEvent(id: bubble, status: "done")
                    toolBubbleIdByToolUseId.removeValue(forKey: toolUseId)
                }
            }

        case "result":
            // Final result also arrives via HTTP response — nothing to surface
            // in the UI from here (the caller's await will unblock).
            break

        default:
            break
        }
    }

    // MARK: - Error translation (AC-5)

    private static func userFacingError(for err: GigiHarnessClient.Error) -> String {
        switch err {
        case .notConfigured:
            return "Configura il pairing in Settings → Harness"
        case .transport:
            var msg = "Harness irraggiungibile. Verifica che il server sia acceso"
            // If the paired URL is a Tailscale CGNAT address, the most likely
            // cause is Tailscale being off on either side rather than the
            // harness being down per se.
            if let url = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL),
               url.contains("://100.") {
                msg += ". Controlla Tailscale attivo su PC e iPhone."
            }
            return msg
        case .badResponse(let status, _):
            if status == 401 { return "Secret non più valido. Ri-pair dal Panel." }
            return "Harness errore HTTP \(status)"
        case .apiError(let code, let message):
            return "Harness: \(code) — \(message)"
        case .decodeFailed:
            return "Harness: risposta non leggibile"
        }
    }

    // MARK: - Payload composition

    private func composeTaskPayload(snapshot: String, task: String, extra: String?) -> String {
        var parts: [String] = []
        if !snapshot.isEmpty { parts.append(snapshot) }
        parts.append("TASK: \(task)")
        if let extra, !extra.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("EXTRA: \(extra)")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Context snapshot (Phase 1 push model)

    /// Assembles the "user snapshot" blob Claude receives at the top of
    /// every task. Kept small (hard cap ~8 KB) so it doesn't dominate the
    /// prompt budget. Sections produced:
    ///   - USER SNAPSHOT (name, email, phone, city)
    ///   - CALENDAR (next 7 days, via ReadWeekCalendarTool)
    ///   - RECENT MEMORIES (prefs / contacts / places from GigiMemory cache)
    ///
    /// Location is intentionally omitted here to avoid a fresh CoreLocation
    /// prompt mid-turn. It can be added in Phase 3 when we have a proper
    /// CLLocationManager helper that only uses cached fixes.
    func buildContextSnapshot() async -> String {
        var sections: [String] = []

        // --- Profile ---
        let profile = await GigiUserProfile.shared.load()
        var profileLines: [String] = []
        if !profile.name.isEmpty { profileLines.append("Name: \(profile.name)") }
        if !profile.email.isEmpty { profileLines.append("Email: \(profile.email)") }
        if !profile.phone.isEmpty { profileLines.append("Phone: \(profile.phone)") }
        if !profile.city.isEmpty || !profile.country.isEmpty {
            let loc = [profile.city, profile.country].filter { !$0.isEmpty }.joined(separator: ", ")
            if !loc.isEmpty { profileLines.append("City: \(loc)") }
        }
        if !profileLines.isEmpty {
            sections.append("USER SNAPSHOT\n=============\n" + profileLines.joined(separator: "\n"))
        }

        // --- Calendar (reuses the existing tool so we get the same format
        //     Groq would see when calling read_week_calendar) ---
        let calResult = await ReadWeekCalendarTool().execute(args: [:])
        if let err = calResult.error, !err.isEmpty {
            sections.append("CALENDAR (next 7 days)\n=======================\n(unavailable: \(err))")
        } else if !calResult.value.isEmpty {
            sections.append("CALENDAR (next 7 days)\n=======================\n" + calResult.value)
        }

        // --- Memories: top N per high-value category ---
        let prefs    = await GigiMemory.shared.recallAll(category: "pref")
        let contacts = await GigiMemory.shared.recallAll(category: "contact")
        let places   = await GigiMemory.shared.recallAll(category: "place")
        var memLines: [String] = []
        for (k, v) in prefs.sorted(by: { $0.key < $1.key }).prefix(4) {
            memLines.append("- \(k) = \(v)")
        }
        for (k, v) in contacts.sorted(by: { $0.key < $1.key }).prefix(3) {
            memLines.append("- \(k) = \(v)")
        }
        for (k, v) in places.sorted(by: { $0.key < $1.key }).prefix(3) {
            memLines.append("- \(k) = \(v)")
        }
        if !memLines.isEmpty {
            sections.append("RECENT MEMORIES\n===============\n" + memLines.joined(separator: "\n"))
        }

        let full = sections.joined(separator: "\n\n")
        // Hard cap at 8 KB. Calendar is the most verbose section — it's last-but-one,
        // so a simple prefix-truncate is acceptable for Phase 1. Phase 1.7 prompt work
        // can refine if real data blows the budget.
        if full.count > 8000 {
            return String(full.prefix(8000)) + "\n\n[truncated at 8KB]"
        }
        return full
    }
}
