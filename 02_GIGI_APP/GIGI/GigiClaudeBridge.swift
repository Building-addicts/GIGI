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
        // Pre-flight (Issue #63 AC1): if diagnostics has already declared the
        // harness offline, skip the harness round-trip entirely and serve the
        // turn from the local Groq path. Avoids wasting the user's 1-2s on a
        // call we already know will fail.
        if GigiBrainDiagnostics.shared.harnessStatus == .offline {
            GigiDebugLogger.log("ClaudeBridge path=fallback (pre-flight: harnessStatus=offline) task='\(task.prefix(60))'")
            return await runFallback(task: task, context: context)
        }

        let harnessResult = await runViaHarness(task: task, context: context)
        if harnessResult.error != nil {
            // AC2: harness call failed mid-turn → degrade gracefully to local
            // path instead of bubbling the error up to the user.
            GigiDebugLogger.log("ClaudeBridge path=fallback (harness call failed, retrying via local) task='\(task.prefix(60))'")
            return await runFallback(task: task, context: context)
        }
        return harnessResult
    }

    private func runViaHarness(task: String, context: String?) async -> ToolResult {
        let snapshot = await buildContextSnapshot(forTask: task)
        let composedTask = composeTaskPayload(snapshot: snapshot, task: task, extra: context)

        ensureStreamConnected()

        GigiDebugLogger.log("ClaudeBridge path=harness → task='\(task.prefix(60))' ctx=\(context?.count ?? 0)B snapshot=\(snapshot.count)B")

        let result = await GigiHarnessClient.shared.agentRun(text: composedTask, stream: true)
        switch result {
        case .success(let agentResult):
            let finalText = agentResult.result.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = (agentResult.usage?.output_tokens ?? 0) + (agentResult.usage?.input_tokens ?? 0)
            GigiBrainDiagnostics.shared.recordTurnPath(.harness)
            return ToolResult.success(finalText.isEmpty ? "(Claude returned an empty response)" : finalText,
                                      tokenEstimate: max(tokens, 50))

        case .failure(let err):
            // Note: SoundEngine.play(.error) and userFacingError(...) intentionally
            // moved to runFallback's terminal branch — when the harness fails we
            // try the local path first, and only emit the error chime if that
            // also fails.
            GigiDebugLogger.log("ClaudeBridge harness error — \(err)")
            return ToolResult.failure(Self.userFacingError(for: err))
        }
    }

    private func runFallback(task: String, context: String?) async -> ToolResult {
        // Mark the path *before* the call so the UI pill reflects fallback
        // mode even when the local Groq attempt itself fails (e.g. rate-limit
        // 429). The pill is a "we tried the local brain" signal, not a
        // "succeeded" signal — keeps the demo audience honest about state.
        GigiBrainDiagnostics.shared.recordTurnPath(.fallback)

        if let text = await GigiFallbackEngine.shared.runComplexQuery(task: task, context: context) {
            GigiDebugLogger.log("ClaudeBridge path=fallback OK (len=\(text.count))")
            return ToolResult.success(text, tokenEstimate: 100)
        }
        // Local path also failed — surface a hard error, since at this point
        // both Claude (cloud agent) and Groq (local LLM) are unreachable.
        SoundEngine.play(.error)
        GigiDebugLogger.log("ClaudeBridge path=fallback FAILED — local Groq unreachable too")
        return ToolResult.failure("I'm offline and can't reach my fallback brain either. Please check your connection.")
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
            memory?.addThought("task cancelled")
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
            return "Configure pairing in Settings → Harness"
        case .transport:
            var msg = "Harness unreachable. Make sure the server is running"
            // If the paired URL is a Tailscale CGNAT address, the most likely
            // cause is Tailscale being off on either side rather than the
            // harness being down per se.
            if let url = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL),
               url.contains("://100.") {
                msg += ". Check that Tailscale is active on both PC and iPhone."
            }
            return msg
        case .badResponse(let status, _):
            if status == 401 { return "Secret no longer valid. Re-pair from the Panel." }
            return "Harness HTTP error \(status)"
        case .apiError(let code, let message):
            return "Harness: \(code) — \(message)"
        case .decodeFailed:
            return "Harness: unreadable response"
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
    func buildContextSnapshot(forTask task: String = "") async -> String {
        var sections: [String] = []

        // --- MVP Preferences (sub #52) — first so they sit at the top of the
        //     8 KB snapshot Claude sees, where attention is highest ---
        let mvpPrefs = await GigiUserProfile.shared.mvpPreferencesContext()
        if !mvpPrefs.isEmpty {
            sections.append(mvpPrefs)
            GigiDebugLogger.log("LLM[bridge] systemPrompt prefix=\(mvpPrefs.prefix(80))")
        }

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
        //
        // Bug fix 2026-05-19: previously injected the top N alphabetical
        // entries from each category regardless of whether they related to
        // the current task. That pulled stale referents (e.g. "contact:sergio
        // = my brother") into the Claude Code prompt and caused false-recall
        // bleed in its responses. New rules:
        //   1. SKIP entries whose key looks like garbage from fact-assertion
        //      mis-detection (key length > 30 chars, or contains punctuation
        //      that isn't space/underscore/dash).
        //   2. PREFER entries whose key (stripped of `pref:`/`contact:`/
        //      `place:` prefix) appears as a substring of the current task
        //      lowercased. Other entries are only included when relevance
        //      yields nothing — and even then, capped tighter.
        let prefs    = await GigiMemory.shared.recallAll(category: "pref")
        let contacts = await GigiMemory.shared.recallAll(category: "contact")
        let places   = await GigiMemory.shared.recallAll(category: "place")
        let memLines = Self.selectMemoryLines(
            task: task,
            prefs: prefs,
            contacts: contacts,
            places: places
        )
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

    /// Filter + rank memory entries for prompt injection.
    /// Rules: drop garbage keys (too long / weird punctuation), then take
    /// entries whose key appears in the task text first, then top up with a
    /// small number of generic high-signal entries.
    static func selectMemoryLines(
        task: String,
        prefs: [String: String],
        contacts: [String: String],
        places: [String: String]
    ) -> [String] {
        // Tokenize the task into word set so relevance checks use word
        // boundaries, not substring (otherwise "i" matches every utterance).
        let taskWords: Set<String> = {
            let separators = CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters)
            return Set(
                task.lowercased()
                    .components(separatedBy: separators)
                    .filter { !$0.isEmpty }
            )
        }()

        func isGarbage(_ key: String) -> Bool {
            // Strip the category prefix (e.g. "contact:sergio" -> "sergio").
            let raw = key.split(separator: ":").dropFirst().joined(separator: ":")
            if raw.isEmpty { return true }
            if raw.count > 30 { return true }
            // Reject too short to be meaningful (single char like "i" came
            // from a mis-classified assertion).
            if raw.count < 2 { return true }
            // Allow letters / digits / space / underscore / dash / dot.
            // Reject keys with commas, question marks, mid-sentence punctuation
            // — those came from mis-classified assertions.
            let allowed = CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: " _-."))
            if raw.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                return true
            }
            // Reject multi-word keys longer than 4 words — likely a sentence.
            if raw.split(whereSeparator: { $0 == " " }).count > 4 { return true }
            return false
        }

        func keyName(_ key: String) -> String {
            String(key.split(separator: ":").dropFirst().joined(separator: ":"))
        }

        func isRelevant(_ key: String) -> Bool {
            let name = keyName(key).lowercased().replacingOccurrences(of: "_", with: " ")
            guard !name.isEmpty else { return false }
            // Word-boundary match: every token of the key must appear as a
            // standalone word in the task. Avoids "i" matching everything
            // and "tesla" inside "telescope".
            let nameTokens = name.split(whereSeparator: { $0.isWhitespace })
                                 .map(String.init)
            guard !nameTokens.isEmpty else { return false }
            return nameTokens.allSatisfy { taskWords.contains($0) }
        }

        let cleanPrefs    = prefs.filter    { !isGarbage($0.key) }
        let cleanContacts = contacts.filter { !isGarbage($0.key) }
        let cleanPlaces   = places.filter   { !isGarbage($0.key) }

        var lines: [String] = []
        var seen = Set<String>()
        func add(_ entry: (key: String, value: String)) {
            guard !seen.contains(entry.key) else { return }
            seen.insert(entry.key)
            lines.append("- \(entry.key) = \(entry.value)")
        }

        // Pass 1 — entries explicitly mentioned in the task. No cap.
        for e in cleanPrefs    where isRelevant(e.key) { add(e) }
        for e in cleanContacts where isRelevant(e.key) { add(e) }
        for e in cleanPlaces   where isRelevant(e.key) { add(e) }

        // Pass 2 — generic top-up. Conservative: only a couple of preferences,
        // and NO blind contact dump (the recurring source of false-recall).
        if lines.count < 4 {
            for e in cleanPrefs.sorted(by: { $0.key < $1.key }).prefix(3) { add(e) }
        }

        return lines
    }
}
