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

    private var startedAt: Date?

    private init() {
        // Observe orchestrator state to drive our phase
        GigiSmartOrchestrator.shared.onQuickTalkStateChange = { [weak self] newPhase in
            Task { @MainActor [weak self] in
                self?.phase = newPhase
            }
        }
        GigiSmartOrchestrator.shared.onQuickTalkTranscript = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.transcript = text
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
                self.phase = .idle
            }
        }
    }

    func start() {
        guard phase == .idle else { return }
        transcript = ""
        response = ""
        startedAt = Date()
        phase = .listening
        GigiSmartOrchestrator.shared.startQuickTalk()
    }

    func stop() {
        guard phase != .idle else { return }
        GigiSmartOrchestrator.shared.stopQuickTalk()
        phase = .idle
    }

    func interrupt() {
        GigiSpeechService.shared.stopSpeaking()
        phase = .idle
    }
}
