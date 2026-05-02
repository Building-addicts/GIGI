import Foundation
import Combine
import SwiftUI

// MARK: - QuickTalkController
//
// Thin coordinator for one-shot voice commands:
//   tap/intent → listen → transcribe → agent → TTS → idle
//
// Wraps GigiSmartOrchestrator for the Quick Talk entry point.
// After TTS finishes, returns to fully idle (no wake word resume).

@MainActor
final class QuickTalkController: ObservableObject {
    static let shared = QuickTalkController()

    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case error(String)

        var isActive: Bool { self != .idle }

        var displayName: String {
            switch self {
            case .idle: return "Ready"
            case .listening: return "Listening"
            case .thinking: return "Thinking"
            case .speaking: return "Speaking"
            case .error: return "Needs Attention"
            }
        }
    }

    enum QuickTalkError: Error {
        case micPermissionDenied
        case sttFailed
        case networkError(String)
        case agentError(String)
    }

    @Published var phase: Phase = .idle
    @Published var transcript: String = ""
    @Published var response: String = ""

    /// When true, the controller chains another listening turn the moment
    /// GIGI finishes speaking, instead of returning to idle. Set by `start()`
    /// for hardware-trigger sessions; cleared by `stop()` and by spoken
    /// "stop" / "exit" / "fine" / "ferma" commands picked up in the
    /// transcript callback below.
    @Published var continuousMode: Bool = false

    private var startedAt: Date?

    private init() {
        GigiDebugLogger.log("QuickTalkController init START")
        // Observe orchestrator state to drive our phase
        GigiSmartOrchestrator.shared.onQuickTalkStateChange = { [weak self] newPhase in
            Task { @MainActor [weak self] in
                self?.phase = newPhase
            }
        }
        GigiSmartOrchestrator.shared.onQuickTalkTranscript = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transcript = text
                // Spoken exit phrases drop continuous mode so the next
                // .idle transition truly ends the session instead of
                // looping back into listening.
                if Self.isExitPhrase(text) {
                    self.continuousMode = false
                }
            }
        }
        GigiSmartOrchestrator.shared.onQuickTalkResponse = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.response = text
            }
        }
        GigiSmartOrchestrator.shared.onQuickTalkFinished = { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let elapsed = self.startedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
                QuickTalkCommandStore.shared.append(
                    transcript: self.transcript,
                    response: self.response,
                    durationMs: elapsed,
                    success: success
                )
                // Continuous-mode sessions chain straight back into a
                // listening turn so the user can keep talking without
                // re-triggering the Action Button. We only do this when
                // the previous turn actually completed (success), to
                // avoid hammering the orchestrator after a recoverable
                // error path. `stop()` and exit-phrase detection clear
                // continuousMode and route us through the normal idle
                // transition instead.
                if self.continuousMode && success {
                    self.transcript = ""
                    self.response = ""
                    self.startedAt = Date()
                    self.phase = .listening
                    GigiSmartOrchestrator.shared.startQuickTalk()
                } else {
                    self.continuousMode = false
                    self.phase = .idle
                }
            }
        }
        GigiDebugLogger.log("QuickTalkController init END")
    }

    /// Single-turn session. Used by the in-app Quick Talk button — fires one
    /// listening cycle and returns to idle.
    func start() {
        guard phase == .idle else { return }
        continuousMode = false
        transcript = ""
        response = ""
        startedAt = Date()
        phase = .listening
        GigiSmartOrchestrator.shared.startQuickTalk()
    }

    /// Multi-turn conversation session. Used by hardware triggers (Action
    /// Button, deeplink) so the user can keep talking back-and-forth until
    /// they tap stop or say an exit phrase.
    func startContinuous() {
        guard phase == .idle else { return }
        continuousMode = true
        transcript = ""
        response = ""
        startedAt = Date()
        phase = .listening
        GigiSmartOrchestrator.shared.startQuickTalk()
    }

    func stop() {
        continuousMode = false
        guard phase != .idle else { return }
        GigiSmartOrchestrator.shared.stopQuickTalk()
        phase = .idle
    }

    func interrupt() {
        GigiSpeechService.shared.stopSpeaking()
        continuousMode = false
        phase = .idle
    }

    private static func isExitPhrase(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        // Single-word triggers — must match exactly so a sentence containing
        // "stop" doesn't accidentally end the session.
        let exact: Set<String> = ["stop", "fine", "ferma", "basta", "exit", "quit", "bye"]
        if exact.contains(normalized) { return true }
        // Two-word polite forms.
        let prefixes = ["that's all", "that is all", "stop please", "fine grazie", "basta cosi", "basta così"]
        return prefixes.contains(where: { normalized.hasPrefix($0) })
    }
}
