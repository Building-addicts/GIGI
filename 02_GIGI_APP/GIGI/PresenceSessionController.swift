import Foundation
import Combine
import SwiftUI

// MARK: - PresenceSessionController
//
// Manages a long-lived Presence Mode session:
//   start → wake word / VAD cycle → STT → agent → TTS → return to sleeping
//
// Bypasses wake word suppression rules (screen dark, low power)
// since the user explicitly started a Presence session.

@MainActor
final class PresenceSessionController: ObservableObject {
    static let shared = PresenceSessionController()

    enum PresenceState: Equatable {
        case inactive
        case sleeping       // wake word active, quiet
        case listening      // VAD recording
        case thinking       // agent processing
        case speaking       // TTS playback
        case muted          // explicitly muted by user
        case error(String)

        static func == (lhs: PresenceState, rhs: PresenceState) -> Bool {
            switch (lhs, rhs) {
            case (.inactive, .inactive), (.sleeping, .sleeping),
                 (.listening, .listening), (.thinking, .thinking),
                 (.speaking, .speaking), (.muted, .muted): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var state: PresenceState = .inactive
    @Published var lastTranscript: String = ""
    @Published var sessionDuration: TimeInterval = 0

    var isActive: Bool { state != .inactive }
    var inactivityTimeout: TimeInterval = 300   // 5 min default

    private var sessionId: String = ""
    private var sessionStartedAt: Date?
    private var inactivityTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?

    private init() {
        observeOrchestrator()
        observeDynamicIslandCommands()
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard state == .inactive else { return }
        sessionId = UUID().uuidString
        sessionStartedAt = Date()
        state = .sleeping
        sessionDuration = 0

        GigiSmartOrchestrator.shared.isPresenceActive = true
        GigiAudioManager.shared.presenceMode = true

        startDurationTimer()
        resetInactivityTimer()

        Task { await GigiLiveActivityController.shared.startPresenceActivity(sessionId: sessionId) }
        GigiAudioManager.shared.startWakeWordListening()

        GigiDebugLogger.log("PresenceSessionController: session started \(sessionId)")
    }

    func stopSession() {
        guard state != .inactive else { return }
        state = .inactive
        sessionStartedAt = nil

        GigiSmartOrchestrator.shared.isPresenceActive = false
        GigiAudioManager.shared.presenceMode = false

        inactivityTask?.cancel()
        durationTask?.cancel()
        GigiAudioManager.shared.stopAll()

        Task { await GigiLiveActivityController.shared.endPresenceActivity() }
        GigiDebugLogger.log("PresenceSessionController: session stopped")
    }

    func mute() {
        guard isActive, state != .muted else { return }
        GigiAudioManager.shared.stopAll()
        state = .muted
        inactivityTask?.cancel()
        Task { await GigiLiveActivityController.shared.updatePresence(state: .thinking, message: "Muted") }
    }

    func unmute() {
        guard state == .muted else { return }
        state = .sleeping
        resetInactivityTimer()
        GigiAudioManager.shared.startWakeWordListening()
        Task { await GigiLiveActivityController.shared.updatePresence(state: .listening, message: "Listening…") }
    }

    func handleBargeIn() {
        guard state == .speaking else { return }
        GigiSpeechService.shared.stopSpeaking()
        GigiAudioManager.shared.stopAll()
        state = .listening
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            GigiAudioManager.shared.startRecording()
        }
    }

    // MARK: - State observation (driven by GigiSmartOrchestrator)

    private func observeDynamicIslandCommands() {
        GigiPresenceAppGroup.observeCommands { [weak self] cmd in
            guard let self else { return }
            switch cmd {
            case .mute:   self.mute()
            case .unmute: self.unmute()
            case .stop:   self.stopSession()
            }
        }
    }

    private func observeOrchestrator() {
        GigiAudioManager.shared.onStateChange = { [weak self] _, newState in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                switch newState {
                case .recording:
                    self.state = .listening
                    self.resetInactivityTimer()
                    await GigiLiveActivityController.shared.updatePresence(state: .listening, message: "Listening…")
                case .speaking:
                    self.state = .speaking
                    await GigiLiveActivityController.shared.updatePresence(state: .speaking, message: "Speaking…")
                case .wakeWordListening:
                    if self.state != .muted {
                        self.state = .sleeping
                        await GigiLiveActivityController.shared.updatePresence(state: .sleeping, message: "Ready")
                    }
                case .idle:
                    break
                }
            }
        }

        // Wire transcript for display
        let existingOnTranscription = GigiAudioManager.shared.onTranscription
        GigiAudioManager.shared.onTranscription = { [weak self] text in
            existingOnTranscription?(text)
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.lastTranscript = text
                self.state = .thinking
                await GigiLiveActivityController.shared.updatePresence(state: .thinking, message: "Thinking…", transcript: text)
            }
        }
    }

    // MARK: - Inactivity timer

    private func resetInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(inactivityTimeout * 1_000_000_000))
            await MainActor.run {
                guard self.isActive, self.state != .muted else { return }
                GigiDebugLogger.log("PresenceSessionController: inactivity timeout")
                self.stopSession()
            }
        }
    }

    private func startDurationTimer() {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { [weak self] in
                    guard let self, let start = self.sessionStartedAt else { return }
                    self.sessionDuration = Date().timeIntervalSince(start)
                }
            }
        }
    }
}
