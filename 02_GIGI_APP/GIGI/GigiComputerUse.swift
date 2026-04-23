import Foundation

// MARK: - GigiComputerUse
//
// Client iOS → backend /api/computer-use (Claude Sonnet + Playwright).
// Full implementation: Phase 5 of TASK_PLAN_V3.md.
// Stub here unblocks compilation for GigiToolRegistry (Phase 1.1).

@MainActor
final class GigiComputerUse {
    static let shared = GigiComputerUse()
    private init() {}

    /// Execute a browser automation task on the backend.
    /// Returns: result string, or "CONFIRM_REQUIRED: <summary>", or "ERROR: <reason>".
    func execute(task: String) async -> String {
        // TODO Phase 5 — POST to backend /api/computer-use
        // For now: surface the task to the user so they can act manually.
        print("GigiComputerUse (stub): \(task)")
        return "Computer Use not yet implemented. Task: \(task)"
    }
}
