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
    static let alwaysAvailableKey = GigiWakeWordEngine.userDefaultsEnabledKey

    static var isAlwaysAvailableEnabled: Bool {
        UserDefaults.standard.bool(forKey: alwaysAvailableKey)
    }

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
    var isAlwaysAvailableEnabled: Bool { Self.isAlwaysAvailableEnabled }
    var inactivityTimeout: TimeInterval = 300   // legacy non-always-available sessions only

    private var sessionId: String = ""
    private var sessionStartedAt: Date?
    private var inactivityTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var standaloneMuted = false

    private init() {
        GigiDebugLogger.log("PresenceSessionController init START")
        observeOrchestrator()
        GigiDebugLogger.log("PresenceSessionController observeOrchestrator OK")
        observeDynamicIslandCommands()
        GigiDebugLogger.log("PresenceSessionController init END")
    }

    // MARK: - Session lifecycle

    func setAlwaysAvailable(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.alwaysAvailableKey)
        if enabled {
            startSession(persistPreference: false)
        } else {
            stopSession(disablePreference: false)
        }
    }

    func syncAlwaysAvailablePreference() {
        if Self.isAlwaysAvailableEnabled {
            startSession(persistPreference: false)
        } else if isActive {
            stopSession(disablePreference: false)
        } else {
            GigiAudioManager.shared.stopAll()
            Task { await GigiLiveActivityController.shared.startPersistentPill() }
        }
    }

    func startSession(persistPreference: Bool = true) {
        if persistPreference {
            UserDefaults.standard.set(true, forKey: Self.alwaysAvailableKey)
        }
        if state != .inactive {
            GigiSmartOrchestrator.shared.isPresenceActive = true
            GigiAudioManager.shared.presenceMode = true
            if state != .muted {
                GigiAudioManager.shared.startWakeWordListening()
                Task {
                    await GigiLiveActivityController.shared.updatePresence(
                        state: .sleeping,
                        message: "Ready — say Hey GIGI"
                    )
                }
            }
            return
        }

        sessionId = UUID().uuidString
        sessionStartedAt = Date()
        state = .sleeping
        sessionDuration = 0
        standaloneMuted = false

        GigiSmartOrchestrator.shared.isPresenceActive = true
        GigiAudioManager.shared.presenceMode = true

        startDurationTimer()
        resetInactivityTimer()

        Task {
            // Presence Mode is now the single owner of the Dynamic Island when
            // "GIGI always available" is on. The old monitoring pill is stopped
            // first so there are never two activities fighting for the island.
            await GigiLiveActivityController.shared.stopPersistentPill()
            await GigiLiveActivityController.shared.startPresenceActivity(sessionId: sessionId)
            await MainActor.run {
                GigiAudioManager.shared.startWakeWordListening()
            }
        }

        GigiDebugLogger.log("PresenceSessionController: always-available session started \(sessionId)")
    }

    func stopSession(disablePreference: Bool = true) {
        if disablePreference {
            UserDefaults.standard.set(false, forKey: Self.alwaysAvailableKey)
        }
        guard state != .inactive else {
            GigiSmartOrchestrator.shared.isPresenceActive = false
            GigiAudioManager.shared.presenceMode = false
            GigiAudioManager.shared.stopAll()
            Task { await GigiLiveActivityController.shared.setIslandLocked(false) }
            return
        }
        state = .inactive
        sessionStartedAt = nil
        standaloneMuted = false

        GigiSmartOrchestrator.shared.isPresenceActive = false
        GigiAudioManager.shared.presenceMode = false

        inactivityTask?.cancel()
        durationTask?.cancel()
        GigiAudioManager.shared.stopAll()

        Task {
            await GigiLiveActivityController.shared.setIslandLocked(false)
            await GigiLiveActivityController.shared.endPresenceActivity()
            // Keep a passive island entry point, but no wake-word engine runs outside Presence.
            await GigiLiveActivityController.shared.startPersistentPill()
        }
        GigiDebugLogger.log("PresenceSessionController: always-available session stopped")
    }

    func mute() {
        guard isActive, state != .muted else { return }
        GigiAudioManager.shared.stopAll()
        state = .muted
        inactivityTask?.cancel()
        Task { await GigiLiveActivityController.shared.updatePresence(state: .muted, message: "Muted — tap Mute to resume") }
    }

    func unmute() {
        guard state == .muted else { return }
        state = .sleeping
        resetInactivityTimer()
        GigiAudioManager.shared.startWakeWordListening()
        Task { await GigiLiveActivityController.shared.updatePresence(state: .sleeping, message: "Ready — say Hey GIGI") }
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
            case .start:
                self.startSession()
            case .mute:
                self.toggleMuteFromIsland()
            case .unmute:
                self.unmuteFromIsland()
            case .stop:
                self.stopFromIsland()
            case .lockIsland:
                self.lockIslandFromIsland()
            case .unlockIsland:
                self.unlockIslandFromIsland()
            }
        }
    }

    private func lockIslandFromIsland() {
        // User-pinned Dynamic Island is a session-scoped hold: it keeps the Live
        // Activity from visually falling back to Ready and keeps Presence timers awake.
        inactivityTask?.cancel()
        Task { await GigiLiveActivityController.shared.setIslandLocked(true) }
        if isActive, state != .muted {
            GigiAudioManager.shared.presenceMode = true
            GigiAudioManager.shared.startWakeWordListening()
        }
    }

    private func unlockIslandFromIsland() {
        Task {
            await GigiLiveActivityController.shared.setIslandLocked(false)
            await reconcileIslandAfterUnlock()
        }
    }

    private func reconcileIslandAfterUnlock() async {
        if isActive {
            resetInactivityTimer()
            switch state {
            case .sleeping:
                await GigiLiveActivityController.shared.updatePresence(state: .sleeping, message: "Ready — say Hey GIGI")
            case .listening:
                await GigiLiveActivityController.shared.updatePresence(state: .listening, message: "I heard you")
            case .thinking:
                await GigiLiveActivityController.shared.updatePresence(state: .thinking, message: "Thinking about it", transcript: lastTranscript)
            case .speaking:
                await GigiLiveActivityController.shared.updatePresence(state: .speaking, message: "Say GIGI or tap to interrupt")
            case .muted:
                await GigiLiveActivityController.shared.updatePresence(state: .muted, message: "Muted — tap Mute to resume")
            case .inactive:
                await GigiLiveActivityController.shared.updateMonitoringPill(state: .sleeping, message: "Ready — say Hey GIGI")
            case .error(let message):
                await GigiLiveActivityController.shared.updatePresence(state: .error, message: message)
            }
            return
        }

        await GigiLiveActivityController.shared.updateMonitoringPill(
            state: .sleeping,
            message: standaloneMuted ? "Muted — tap Mute to resume" : "Ready — say Hey GIGI"
        )
    }

    private func toggleMuteFromIsland() {
        if isActive {
            state == .muted ? unmute() : mute()
            return
        }

        if standaloneMuted {
            unmuteFromIsland()
        } else {
            standaloneMuted = true
            GigiAudioManager.shared.stopAll()
            Task {
                await GigiLiveActivityController.shared.updateMonitoringPill(
                    state: .muted,
                    message: "Muted — tap Mute to resume"
                )
            }
        }
    }

    private func unmuteFromIsland() {
        if isActive {
            unmute()
            return
        }
        standaloneMuted = false
        GigiAudioManager.shared.startWakeWordListening()
        Task {
            await GigiLiveActivityController.shared.updateMonitoringPill(
                state: .sleeping,
                message: "Ready — say Hey GIGI"
            )
        }
    }

    private func stopFromIsland() {
        standaloneMuted = false
        Task { await GigiLiveActivityController.shared.setIslandLocked(false) }
        if isActive {
            stopSession()
            return
        }
        GigiSpeechService.shared.stopSpeaking()
        GigiAudioManager.shared.stopAll()
        Task {
            await GigiLiveActivityController.shared.updateMonitoringPill(
                state: .sleeping,
                message: "Stopped — tap GIGI to restart"
            )
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
                    await GigiLiveActivityController.shared.updatePresence(
                        state: .listening,
                        message: "I heard you"
                    )
                case .speaking:
                    self.state = .speaking
                case .wakeWordListening:
                    if self.state != .muted {
                        self.state = .sleeping
                        await GigiLiveActivityController.shared.updatePresence(state: .sleeping, message: "Ready — say Hey GIGI")
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
                await GigiLiveActivityController.shared.updatePresence(state: .thinking, message: "Thinking about it", transcript: text)
            }
        }
    }

    // MARK: - Inactivity timer

    private func resetInactivityTimer() {
        inactivityTask?.cancel()
        // In always-available mode GIGI must stay Ready all day. Silence only returns
        // the audio state to wake-word standby; it must not end the Presence session.
        guard !Self.isAlwaysAvailableEnabled else { return }
        // Dynamic Island lock is also explicit user intent to keep this session alive
        // until unlock; do not let the legacy inactivity timeout tear down wake word.
        guard !GigiLiveActivityController.shared.isIslandLocked else { return }
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
