import Foundation

// MARK: - GigiOrchestratorSessionStore

struct GigiOrchestratorSessionSnapshot: Equatable {
    let id: String
    let startedAt: Date
    var lastInput: String?
    var lastResult: String?
    var lastRoute: GigiShortcutCommandResult.Route?
    var confirmation: String?
}

actor GigiOrchestratorSessionStore {
    static let shared = GigiOrchestratorSessionStore()

    private var sessions: [String: GigiOrchestratorSessionSnapshot] = [:]

    func begin() -> String {
        let id = "gigi-\(UUID().uuidString.prefix(8))"
        sessions[id] = GigiOrchestratorSessionSnapshot(
            id: id,
            startedAt: Date(),
            lastInput: nil,
            lastResult: nil,
            lastRoute: nil,
            confirmation: nil
        )
        pruneOldSessions(now: Date())
        return id
    }

    func record(sessionID: String, input: String, result: GigiShortcutCommandResult) {
        var snapshot = sessions[sessionID] ?? GigiOrchestratorSessionSnapshot(
            id: sessionID,
            startedAt: Date(),
            lastInput: nil,
            lastResult: nil,
            lastRoute: nil,
            confirmation: nil
        )
        snapshot.lastInput = input
        snapshot.lastResult = result.shortcutValue
        snapshot.lastRoute = result.route
        sessions[sessionID] = snapshot
        pruneOldSessions(now: Date())
    }

    func confirm(sessionID: String, result: String, confirmation: String) {
        var snapshot = sessions[sessionID] ?? GigiOrchestratorSessionSnapshot(
            id: sessionID,
            startedAt: Date(),
            lastInput: nil,
            lastResult: result,
            lastRoute: nil,
            confirmation: nil
        )
        snapshot.lastResult = result
        snapshot.confirmation = confirmation
        sessions[sessionID] = snapshot
        pruneOldSessions(now: Date())
    }

    private func pruneOldSessions(now: Date) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.startedAt) < 600 }
    }
}

// MARK: - GigiOrchestratorClient
//
// Shared background orchestrator boundary for Shortcut/AppIntent flows. Both the
// legacy `Process speech with GIGI` intent and the advanced Begin → Orchestrator
// → Confirm chain call here, so deterministic SYS/CALL/SMS/OPEN routing and
// brain fallback stay in one place.

enum GigiOrchestratorClient {
    static func resolve(text raw: String, sessionID: String? = nil) async -> GigiShortcutCommandResult {
        let result = await resolveValue(text: raw)
        if let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await GigiOrchestratorSessionStore.shared.record(sessionID: sessionID, input: raw, result: result)
        }
        return result
    }

    private static func resolveValue(text raw: String) async -> GigiShortcutCommandResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return GigiShortcutCommandResult(shortcutValue: "I didn't catch anything. Try again.", route: .fallback)
        }

        if let local = await GigiShortcutOrchestrator.resolveLocal(text: trimmed) {
            return local
        }

        let harnessResult = await withTimeout(seconds: 5) {
            await GigiHarnessClient.shared.agentRun(text: trimmed)
        }

        switch harnessResult {
        case .success(.success(let agent)):
            let answer = agent.result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty {
                return GigiShortcutCommandResult(shortcutValue: answer, route: .harness)
            }
        case .success(.failure(let err)):
            if let cloud = await cloudFallback(text: trimmed) {
                return cloud
            }
            return GigiShortcutCommandResult(shortcutValue: userFacingFallback(for: err), route: .fallback)
        case .failure:
            if let cloud = await cloudFallback(text: trimmed) {
                return cloud
            }
            return GigiShortcutCommandResult(
                shortcutValue: "GIGI's Mac brain timed out. I can still run phone actions; for open questions, check the connection or add a cloud brain key in Settings.",
                route: .fallback
            )
        }

        if let cloud = await cloudFallback(text: trimmed) {
            return cloud
        }
        return GigiShortcutCommandResult(shortcutValue: "GIGI didn't return anything. Try again.", route: .fallback)
    }

    private enum TimeoutError: Error {
        case timedOut
    }

    private static func cloudFallback(text: String) async -> GigiShortcutCommandResult? {
        guard !GigiConfig.groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        do {
            let answer = try await withThrowingTimeout(seconds: 5) {
                try await GigiCloudService.shared.ask(text)
            }.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return nil }
            return GigiShortcutCommandResult(shortcutValue: answer, route: .cloud)
        } catch {
            return nil
        }
    }

    private static func withTimeout<T>(seconds: UInt64, operation: @escaping () async -> T) async -> Result<T, Error> {
        await withTaskGroup(of: Result<T, Error>.self) { group in
            group.addTask {
                .success(await operation())
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return .failure(TimeoutError.timedOut)
            }
            let result = await group.next() ?? .failure(TimeoutError.timedOut)
            group.cancelAll()
            return result
        }
    }

    private static func withThrowingTimeout<T>(seconds: UInt64, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw TimeoutError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func userFacingFallback(for err: GigiHarnessClient.Error) -> String {
        switch err {
        case .notConfigured:
            return "I'm running without the Mac brain. I can still run phone actions like flashlight, volume, calls, messages, and shortcuts. For open questions, open GIGI and pair it with your Mac or add a cloud brain key in Settings."
        case .transport:
            return "I couldn't reach GIGI's Mac brain. Phone actions still work; for open questions, check the connection and try again."
        case .badResponse(let status, _):
            if status == 401 || status == 403 {
                return "GIGI needs to be re-paired. Open the app to refresh the connection."
            } else if status == 429 {
                return "GIGI is rate limited right now. Try again in a moment."
            } else {
                return "GIGI's Mac brain returned an error. Phone actions still work; try the open question again later."
            }
        case .apiError(let code, _):
            if code == "RATE_LIMITED" {
                return "GIGI is rate limited right now. Try again in a moment."
            } else if code == "UNAUTHORIZED" {
                return "GIGI needs to be re-paired. Open the app to refresh the connection."
            } else {
                return "Something went wrong on GIGI's brain side. Phone actions still work; try again later."
            }
        case .decodeFailed:
            return "GIGI's reply was unreadable. Try again."
        }
    }
}
