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
//  2. Open/reuse a WebSocket stream to the harness (Phase 1.4), translate
//     `claude_event` frames into `.thinking` / `.toolEvent` bubbles in
//     GigiConversationMemory, and resume the awaiting async call on the
//     final `speech` or `done` event.
//  3. Produce a `ToolResult` compatible with the existing tool pipeline.
//
// Phase 1.3 status: SKELETON ONLY.
// - `run(task:context:)` returns a stub success so the wiring compiles.
// - `buildContextSnapshot()` is implemented and testable.
// - `stream` is declared but not yet connected — that happens in Phase 1.4.

@MainActor
final class GigiClaudeBridge {
    static let shared = GigiClaudeBridge()
    private init() {}

    // MARK: - State

    /// Lazily created on first `run()` (Phase 1.4). Held here so we can reuse
    /// one stream per app session instead of opening/closing per turn.
    private var stream: GigiHarnessStream?

    /// Reference to the conversation memory so the bridge can append
    /// `.thinking` / `.toolEvent` bubbles as stream events arrive.
    /// Set by AgentEngine during its init / first use (Phase 1.6).
    weak var memory: GigiConversationMemory?

    // MARK: - Public entry (stub)

    /// Entry point called from `AskClaudeTool.execute(...)` (Phase 1.5) and
    /// from `GigiAgentEngine.process(...)` when Force Claude is on (Phase 2.3).
    ///
    /// Phase 1.3: returns a stub result. The real WebSocket-driven flow
    /// lives in Phase 1.4.
    func run(task: String, context: String?) async -> ToolResult {
        let snapshot = await buildContextSnapshot()
        GigiDebugLogger.log("GigiClaudeBridge.run stub — task='\(task.prefix(60))' ctx=\(context?.count ?? 0)B snapshot=\(snapshot.count)B")
        return ToolResult.success("(GigiClaudeBridge stub — Phase 1.4 will wire the harness)", tokenEstimate: 50)
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
