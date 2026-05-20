import Foundation
import Combine

// MARK: - Message (UI layer — unchanged)

struct GigiMessage: Identifiable, Equatable {
    enum Role { case user, gigi, thinking, toolEvent }

    let id:        UUID
    let role:      Role
    var text:      String
    let timestamp: Date
    var isThinking: Bool

    init(role: Role, text: String, isThinking: Bool = false) {
        self.id         = UUID()
        self.role       = role
        self.text       = text
        self.timestamp  = Date()
        self.isThinking = isThinking
    }
}

// MARK: - TurnAnnotation
//
// Structured per-turn record paired with each user utterance in
// `contentsArray`. Built progressively: addUserTurn() appends a placeholder,
// annotateLastTurn() fills in the routing outcome once the router has
// decided. Used by `compactHistory(maxTurns:)` to produce a compressed
// summary that the FM router consumes instead of the raw transcript.
//
// Why this exists: passing flat-text history ("User: Who is Marco /
// Assistant: Marco is my brother") to Apple FM caused topic anchoring —
// the next turn ("Who is Einstein") inherited "Marco/Marcus" context and
// got mis-answered. Structured summaries strip the verbatim assistant
// response (the topic-carrier) while preserving intent + entity signal.

struct TurnAnnotation: Codable {
    let utterance: String
    var intent: String?       // tool/action dispatched (e.g. "recall", "make_call")
    var slot: String?         // primary extracted slot (e.g. "marco", "tesla news")
    var tier: String?         // memory | nlu_fast | regex | semantic | appleFM | fallback
    var success: Bool         // did the dispatch produce a non-empty, non-error result
    let timestamp: Date
}

// MARK: - GigiConversationMemory

@MainActor
final class GigiConversationMemory: ObservableObject {
    static let shared = GigiConversationMemory()

    // UI layer
    @Published private(set) var messages: [GigiMessage] = []
    private let maxTurns = 20

    // Gemini multi-turn history (native GigiContent[])
    private var contentsArray: [GigiContent] = []

    // Structured per-turn metadata, parallel to user turns in contentsArray.
    private var turnAnnotations: [TurnAnnotation] = []

    // MARK: - Pending clarification state
    //
    // When the router asks the user for a missing slot ("What do you want
    // to say to Marco?"), we stash enough context to consume the NEXT
    // utterance as that slot's value. TTL keeps stale state from
    // hijacking a fresh user request minutes later.

    struct PendingClarification {
        let intent: String                  // e.g. "send_message"
        let slot: String                    // e.g. "body"
        let partialParams: [String: String] // already-extracted slots (contact, platform)
        let timestamp: Date
    }

    private var pendingClarification: PendingClarification?
    private let pendingClarificationTTL: TimeInterval = 120  // 2 min

    func setPendingClarification(_ p: PendingClarification) {
        pendingClarification = p
    }

    /// Return + clear the pending clarification IF still fresh (within
    /// TTL). After this call the slot is cleared regardless — caller
    /// owns the decision whether to use it or fall through.
    func consumePendingClarification() -> PendingClarification? {
        guard let p = pendingClarification else { return nil }
        pendingClarification = nil
        guard Date().timeIntervalSince(p.timestamp) < pendingClarificationTTL else {
            return nil
        }
        return p
    }

    func clearPendingClarification() {
        pendingClarification = nil
    }

    // MARK: - Last-referent tracking (coreference)
    //
    // Names of the most recently mentioned entity per kind. Used by
    // `GigiAgentEngine.resolveCoreferences(text:)` to substitute pronouns
    // ("him", "her", "it", "there") with the actual referent BEFORE the
    // routing pipeline sees the utterance. Updated by the orchestrator
    // after each successful turn via `recordReferent(_:kind:)`.
    //
    // PERSISTED via UserDefaults so a kill+relaunch doesn't make GIGI
    // forget who "him" refers to. TTL'd: after 24h of no use, the
    // entries are dropped so an old conversation can't haunt a fresh
    // session days later. The disk write is tiny (~150 bytes).
    private static let referentUDKey = "gigi.coreference.lastReferentByKind"
    private static let referentTSUDKey = "gigi.coreference.referentTimestamps"
    private static let referentTTL: TimeInterval = 86_400  // 24h

    private var lastReferentByKind: [String: String] = {
        if let dict = UserDefaults.standard.dictionary(forKey: "gigi.coreference.lastReferentByKind") as? [String: String] {
            return dict
        }
        return [:]
    }()

    private var referentTimestamps: [String: Date] = {
        if let raw = UserDefaults.standard.dictionary(forKey: "gigi.coreference.referentTimestamps") as? [String: Double] {
            return raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
        return [:]
    }()

    /// Save the entity mentioned in the last successful turn so the next
    /// turn can resolve a coreference pronoun against it. Kind is one of
    /// "person", "place", "thing". Pass an empty name to clear that slot.
    /// Persists to UserDefaults so coreference survives app kill.
    /// Person names are Title-Cased so display is always proper-noun-ish.
    func recordReferent(_ name: String, kind: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            lastReferentByKind.removeValue(forKey: kind)
            referentTimestamps.removeValue(forKey: kind)
        } else {
            // Normalize person names to Title Case so future displays
            // ("What do you want to say to Leo Corte?") look clean
            // regardless of what casing the user originally typed.
            let normalized: String
            if kind == "person" {
                normalized = GigiRequestRouter.titleCaseName(trimmed)
            } else {
                normalized = trimmed
            }
            lastReferentByKind[kind] = normalized
            referentTimestamps[kind] = Date()
        }
        persistReferentState()
    }

    private func persistReferentState() {
        UserDefaults.standard.set(lastReferentByKind, forKey: Self.referentUDKey)
        let raw = referentTimestamps.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: Self.referentTSUDKey)
    }

    /// Most recent referent of a given kind, or nil if it expired (TTL)
    /// or was never recorded. Person referents are returned in Title
    /// Case; legacy lowercase entries get retroactively normalized on
    /// read so old data doesn't look broken after the casing fix.
    func lastReferent(kind: String) -> String? {
        guard let raw = lastReferentByKind[kind] else { return nil }
        // TTL check: if the entry is older than referentTTL, drop it.
        if let ts = referentTimestamps[kind],
           Date().timeIntervalSince(ts) > Self.referentTTL {
            lastReferentByKind.removeValue(forKey: kind)
            referentTimestamps.removeValue(forKey: kind)
            persistReferentState()
            return nil
        }
        // Entries written before the TTL was added have no timestamp.
        // Treat as expired so old test-data referents don't stick forever.
        if referentTimestamps[kind] == nil {
            lastReferentByKind.removeValue(forKey: kind)
            persistReferentState()
            return nil
        }
        if kind == "person" {
            let titled = GigiRequestRouter.titleCaseName(raw)
            if titled != raw {
                lastReferentByKind[kind] = titled
                persistReferentState()
            }
            return titled
        }
        return raw
    }

    // Session persistence
    private let udKey          = "gigi.session.contents"
    private let udTimestampKey = "gigi.session.timestamp"
    private let sessionTTL: TimeInterval = 3600  // 1 hour

    // Token budget (8k tokens ≈ 32k chars at 4 chars/token)
    private let tokenBudget     = 8_000
    private let toolResultLimit = 500   // chars before truncation

    // #54 — periodic task extraction trigger (every 2 user turns).
    // Lives here (not in PresenceSessionController) so it fires for every user turn
    // — voice or chat — independent of Presence Mode (post-MVP).
    private var taskExtractionTurnCounter = 0
    private var taskExtractionTask: Task<Void, Never>?

    private init() {
        // Auto-restore disabled: when the app is killed and reopened, the
        // UI starts empty but the LLM-facing `contentsArray` used to be
        // restored from UserDefaults (1h TTL). That hidden history caused
        // the FM router and Ollama to anchor on stale topics (e.g. asking
        // "Who is Einstein?" right after a Marco conversation returned an
        // answer about Marco). Stored *facts* still survive via GigiMemory
        // disk persistence — the conversation transcript does not.
        //
        // If brief-backgrounding survival is needed later, restore as a
        // separate "soft history" surface that's NOT included in
        // `contents()` returned to the LLM.
    }

    // MARK: - UI helpers (backward compat)

    func addUser(_ text: String) {
        messages.append(GigiMessage(role: .user, text: text))
        trimIfNeeded()

        // #54 — fire task extraction every 2 user turns. Cancel any in-flight
        // extractor task so we never have two extracts racing on the same memory.
        taskExtractionTurnCounter += 1
        if taskExtractionTurnCounter % 2 == 0 {
            taskExtractionTask?.cancel()
            let transcript = recentUserTranscript(turns: 6)
            taskExtractionTask = Task {
                await GigiTaskExtractor.shared.extract(from: transcript)
            }
        }
    }

    /// Last `turns` user transcripts joined as a bulletted multi-line string.
    /// Used by GigiTaskExtractor periodic trigger (#54).
    func recentUserTranscript(turns: Int = 6) -> String {
        messages
            .filter { $0.role == .user }
            .suffix(turns)
            .map { "- \($0.text)" }
            .joined(separator: "\n")
    }

    func addThinking() -> UUID {
        let msg = GigiMessage(role: .gigi, text: "", isThinking: true)
        messages.append(msg)
        return msg.id
    }

    func resolveThinking(id: UUID, with text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx] = GigiMessage(role: .gigi, text: text)
    }

    func addGigi(_ text: String) {
        if let idx = messages.lastIndex(where: { $0.role == .gigi && $0.isThinking }) {
            messages[idx] = GigiMessage(role: .gigi, text: text)
        } else {
            messages.append(GigiMessage(role: .gigi, text: text))
        }
    }

    // MARK: - Claude bridge stream (Phase 1)

    /// Append a streaming Claude thought as a separate `.thinking` bubble.
    /// Different from `addThinking()` — that one is a placeholder on a .gigi message.
    @discardableResult
    func addThought(_ text: String) -> UUID {
        let msg = GigiMessage(role: .thinking, text: text)
        messages.append(msg)
        trimIfNeeded()
        return msg.id
    }

    /// Append a tool-event bubble (e.g. `browser_navigate: running`). Returns id so
    /// the caller can later transition the status from running → done via `updateToolEvent`.
    @discardableResult
    func addToolEvent(name: String, status: String) -> UUID {
        let msg = GigiMessage(role: .toolEvent, text: "\(name): \(status)")
        messages.append(msg)
        trimIfNeeded()
        return msg.id
    }

    /// Mutate an existing tool-event bubble (e.g. from "running" to "done" or to a
    /// short result summary). Safe no-op if the id is no longer in the list.
    func updateToolEvent(id: UUID, status: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id && $0.role == .toolEvent }) else { return }
        let current = messages[idx].text
        let name = current.split(separator: ":", maxSplits: 1).first.map(String.init) ?? current
        var updated = messages[idx]
        updated.text = "\(name): \(status)"
        messages[idx] = updated
    }

    func clear() {
        messages.removeAll()
        contentsArray.removeAll()
        turnAnnotations.removeAll()
        lastReferentByKind.removeAll()
        referentTimestamps.removeAll()
        pendingClarification = nil
        UserDefaults.standard.removeObject(forKey: udKey)
        UserDefaults.standard.removeObject(forKey: udTimestampKey)
        UserDefaults.standard.removeObject(forKey: Self.referentUDKey)
        UserDefaults.standard.removeObject(forKey: Self.referentTSUDKey)
    }

    /// Returns the most recent assistant (.gigi) message text, verbatim, if
    /// any. Used by the router to give Apple FM a single-turn context for
    /// follow-up disambiguation ("Go", "Yes", "Send it") without the
    /// multi-turn topic-anchoring drift that motivated `compactHistory`
    /// (Bug #013). One last assistant turn is enough for follow-up
    /// interpretation and does NOT cause runaway anchoring.
    func lastAssistantTurnVerbatim() -> String? {
        let last = messages
            .last(where: { $0.role == .gigi && !$0.isThinking && !$0.text.isEmpty })
        return last?.text
    }

    // Legacy string context (used by v2 path — keep until Phase 1.8 removes it)
    func contextString(maxTurns: Int = 10) -> String {
        let recent = messages
            .filter { !$0.isThinking && !$0.text.isEmpty && $0.role != .thinking && $0.role != .toolEvent }
            .suffix(maxTurns * 2)
        return recent.map { ($0.role == .user ? "[User]" : "[GIGI]") + " " + $0.text }
                     .joined(separator: "\n")
    }

    // MARK: - Native Gemini content API (v3 path)

    /// Call at the START of each agent turn, before invoking agentLoop.
    /// Also appends a placeholder TurnAnnotation that the orchestrator
    /// fills in via `annotateLastTurn(...)` once routing has decided.
    func addUserTurn(_ text: String) {
        contentsArray.append(.user(text))
        turnAnnotations.append(TurnAnnotation(
            utterance: text,
            intent: nil,
            slot: nil,
            tier: nil,
            success: false,
            timestamp: Date()
        ))
        // Keep parallel array bounded — drop the oldest if we exceed 2× UI maxTurns.
        if turnAnnotations.count > maxTurns * 2 {
            turnAnnotations.removeFirst(turnAnnotations.count - maxTurns * 2)
        }
    }

    /// Update the most-recent user turn's annotation with the routing
    /// outcome. Safe to call multiple times — last call wins (so a late
    /// post-dispatch annotation overrides an early pre-dispatch one).
    /// No-op if there is no user turn yet.
    func annotateLastTurn(intent: String?, slot: String?, tier: String?, success: Bool) {
        guard let last = turnAnnotations.indices.last else { return }
        if let v = intent  { turnAnnotations[last].intent  = v }
        if let v = slot    { turnAnnotations[last].slot    = v }
        if let v = tier    { turnAnnotations[last].tier    = v }
        turnAnnotations[last].success = success
    }

    /// Compressed structured summary of the last `maxTurns` user turns.
    /// Replaces raw-transcript history when feeding the FM router: the
    /// verbatim assistant response is the main cause of topic anchoring,
    /// so we drop it and surface only the intent/slot signal.
    ///
    /// Format (one line per turn, oldest first):
    ///   "Prev #N: user asked <intent> of '<slot>' [(failed)]"
    /// Falls back to a truncated raw utterance for turns not yet annotated.
    /// Returns empty string when there are no prior turns.
    func compactHistory(maxTurns: Int = 3) -> String {
        guard maxTurns > 0, !turnAnnotations.isEmpty else { return "" }
        // Skip the very last entry — that's the CURRENT turn the router
        // is about to decide. We summarize what happened BEFORE it.
        let prior = turnAnnotations.dropLast()
        guard !prior.isEmpty else { return "" }
        let recent = Array(prior.suffix(maxTurns))
        let lines: [String] = recent.enumerated().map { idx, ann in
            let position = recent.count - idx   // 1 = most recent prior
            if let intent = ann.intent, !intent.isEmpty {
                let slotPart = (ann.slot?.isEmpty == false) ? " of '\(ann.slot!)'" : ""
                let successPart = ann.success ? "" : " (failed)"
                return "Prev #\(position): user asked \(intent)\(slotPart)\(successPart)"
            }
            // Not yet annotated — fall back to a short verbatim form.
            let truncated = ann.utterance.count > 60
                ? String(ann.utterance.prefix(60)) + "…"
                : ann.utterance
            return "Prev #\(position): user said '\(truncated)'"
        }
        return lines.joined(separator: "\n")
    }

    /// Call when Gemini responds with function calls.
    func addModelTurn(calls: [FunctionCallBlock]) {
        guard !calls.isEmpty else { return }
        contentsArray.append(.model(functionCalls: calls))
    }

    /// Call after tool execution results are ready.
    func addToolResults(_ results: [(name: String, result: String)]) {
        guard !results.isEmpty else { return }
        let tuples = results.map { (name: $0.name, value: $0.result, error: String?.none) }
        contentsArray.append(.toolResults(tuples))
    }

    /// Call when Gemini returns the final text response.
    func addModelSpeech(_ text: String) {
        guard !text.isEmpty else { return }
        contentsArray.append(.model(text: text))
        saveSession()
    }

    /// Returns history for next Gemini call. Applies token pruning + tool result truncation.
    /// System prompt stays in `systemInstruction` (immortal, never in this array).
    func contents(pruningIfNeeded: Bool = true) -> [GigiContent] {
        guard pruningIfNeeded else { return contentsArray }
        return pruned(contentsArray)
    }

    // MARK: - Pruning

    private func pruned(_ raw: [GigiContent]) -> [GigiContent] {
        // Truncate long tool results first (cheap, reduces tokens without losing turns)
        let truncated = raw.map { truncateLongToolResults($0) }

        // Walk backwards summing tokens; keep newest turns that fit in budget
        var budget = tokenBudget
        var keepFrom = truncated.count
        for i in stride(from: truncated.count - 1, through: 0, by: -1) {
            let cost = estimateTokens(truncated[i])
            if budget - cost < 0 { break }
            budget  -= cost
            keepFrom = i
        }

        guard keepFrom > 0 else { return truncated }

        // Prepend a summary placeholder so Gemini knows context was cut
        let droppedCount = keepFrom
        let summary = GigiContent.user(
            "[Note: \(droppedCount) earlier turn(s) omitted to fit context window. Summary: prior conversation covered user requests handled by GIGI.]"
        )
        return [summary] + Array(truncated[keepFrom...])
    }

    private func estimateTokens(_ content: GigiContent) -> Int {
        var charCount = 0
        for part in content.parts {
            charCount += part.text?.count ?? 0
            if let fc = part.functionCall {
                charCount += fc.name.count + "\(fc.args)".count
            }
            if let fr = part.functionResponse {
                charCount += fr.name.count + "\(fr.response)".count
            }
        }
        return max(1, charCount / 4)
    }

    private func truncateLongToolResults(_ content: GigiContent) -> GigiContent {
        let newParts = content.parts.map { part -> GigiPart in
            guard let fr = part.functionResponse else { return part }
            let result = fr.response["result"] ?? ""
            guard result.count > toolResultLimit else { return part }
            let trimmed = String(result.prefix(toolResultLimit)) + "… [truncated]"
            return GigiPart.functionResponse(name: fr.name, result: trimmed)
        }
        return GigiContent(role: content.role, parts: newParts)
    }

    // MARK: - Session persistence (UserDefaults + 1h TTL)

    func saveSession() {
        guard let data = try? JSONEncoder().encode(contentsArray) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: udTimestampKey)
    }

    func loadIfRecentSession() -> [GigiContent]? {
        let ts = UserDefaults.standard.double(forKey: udTimestampKey)
        guard ts > 0,
              Date().timeIntervalSince1970 - ts < sessionTTL,
              let data     = UserDefaults.standard.data(forKey: udKey),
              let contents = try? JSONDecoder().decode([GigiContent].self, from: data)
        else { return nil }
        return contents
    }

    // MARK: - Private UI trim

    private func trimIfNeeded() {
        let turns = messages.filter { !$0.isThinking && $0.role != .thinking && $0.role != .toolEvent }
        if turns.count > maxTurns * 2 {
            messages.removeFirst(turns.count - maxTurns * 2)
        }
    }
}
