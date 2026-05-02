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

// MARK: - GigiConversationMemory

@MainActor
final class GigiConversationMemory: ObservableObject {
    static let shared = GigiConversationMemory()

    // UI layer
    @Published private(set) var messages: [GigiMessage] = []
    private let maxTurns = 20

    // Gemini multi-turn history (native GigiContent[])
    private var contentsArray: [GigiContent] = []

    // Session persistence
    private let udKey          = "gigi.session.contents"
    private let udTimestampKey = "gigi.session.timestamp"
    private let sessionTTL: TimeInterval = 3600  // 1 hour

    // Token budget (8k tokens ≈ 32k chars at 4 chars/token)
    private let tokenBudget     = 8_000
    private let toolResultLimit = 500   // chars before truncation

    private init() {
        // Auto-restore recent session on launch
        if let restored = loadIfRecentSession() {
            contentsArray = restored
        }
    }

    // MARK: - UI helpers (backward compat)

    func addUser(_ text: String) {
        messages.append(GigiMessage(role: .user, text: text))
        trimIfNeeded()
    }

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
        UserDefaults.standard.removeObject(forKey: udKey)
        UserDefaults.standard.removeObject(forKey: udTimestampKey)
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
    func addUserTurn(_ text: String) {
        // Sync to UI-facing @Published messages so observers (e.g. live task
        // extraction sink in PresenceSessionController) fire on every voice
        // turn, including those routed through GigiAgentEngine. Without this
        // the harness-route turns updated only the LLM history (contentsArray)
        // while leaving the @Published messages array untouched.
        messages.append(GigiMessage(role: .user, text: text))
        contentsArray.append(.user(text))
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
