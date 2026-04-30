import AppIntents
import Foundation
import os.log

// MARK: - GigiOrchestratorIntent
//
// Step 2 of the Action Button → DI → Orchestrator → Shortcut chain.
//
// Receives a transcript (output of `GigiBeginSessionIntent` step 1),
// transitions the Dynamic Island to `.thinking`, calls the cloud LLM
// directly via `GigiOrchestratorClient` (no harness), and returns a
// single line — either a marker (CALL: / SMS: / SYS: / OPEN:) consumed
// by the existing IF-prefix routing in the Shortcut, or a plain text
// answer that the Shortcut speaks via its TTS branch.
//
// Failure mode: on any error, returns "GIGI was unreachable" so the
// Shortcut's plain-text branch can speak it instead of crashing the
// chain.

@available(iOS 16.0, *)
struct GigiOrchestratorIntent: AppIntent {
    static var title: LocalizedStringResource = "Route via GIGI Orchestrator"
    static var description = IntentDescription("Send the transcript to the GIGI cloud router and return the action marker.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Transcript")
    var transcript: String

    @Parameter(title: "Locale", default: "en-US")
    var localeIdentifier: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let log = Logger(subsystem: "com.killsiri.GIGI", category: "orchestrator-intent")
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.warning("orch.empty_transcript")
            return .result(value: "I didn't catch that — try again.")
        }

        await MainActor.run {
            Task { await GigiLiveActivityController.shared.transitionToThinking(transcript: trimmed) }
        }

        let started = Date()
        do {
            let contacts = await GigiOrchestratorClient.contactSnapshot()
            let marker = try await GigiOrchestratorClient.route(
                transcript: trimmed,
                contacts: contacts,
                locale: localeIdentifier
            )
            let elapsed = Date().timeIntervalSince(started)
            log.info("orch.ok elapsed=\(String(format: "%.3f", elapsed), privacy: .public)s len=\(marker.count, privacy: .public)")
            return .result(value: marker)
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            log.error("orch.fail elapsed=\(String(format: "%.3f", elapsed), privacy: .public)s err=\(error.localizedDescription, privacy: .public)")
            return .result(value: "GIGI was unreachable.")
        }
    }
}
