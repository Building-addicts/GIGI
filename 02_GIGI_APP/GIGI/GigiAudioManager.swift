import AVFoundation
import Combine
import Foundation
import Speech

// MARK: - AudioState

enum GigiAudioState: Equatable {
    case idle
    case wakeWordListening
    case recording
    case speaking
}

// MARK: - GigiAudioManager
//
// Single coordinator for all audio states. Replaces the dual-engine conflict
// between GigiWakeWordEngine and GigiVADEngine by enforcing a state machine:
//
//   idle ↔ wakeWordListening ↔ recording ↔ speaking
//
// Only one state is active at a time — zero conflicting sessions, zero heat.
// Existing callers (GigiSmartOrchestrator) keep their current API; this class
// sits underneath and manages the actual audio session transitions.

@MainActor
final class GigiAudioManager: ObservableObject {
    static let shared = GigiAudioManager()

    @Published private(set) var state: GigiAudioState = .idle {
        didSet { onStateChange?(oldValue, state) }
    }

    @Published private(set) var wakeWordEngineRunning = false
    @Published private(set) var lastWakeWordError: String?

    // Called whenever state transitions so observers can react
    var onStateChange: ((GigiAudioState, GigiAudioState) -> Void)?

    // When true (Presence Mode), skip screen-dark / low-power wake suppression
    // and use a shorter post-TTS resume delay.
    var presenceMode: Bool = false

    // Forwarded from the underlying engines
    var onTranscription:   ((String) -> Void)?
    var onSilenceDetected: (() -> Void)?
    var onListeningFailed: (() -> Void)?
    /// Fires the moment AVSpeechSynthesizer reports didFinish/didCancel. Subscribers run
    /// before the post-TTS delay + state transition. Used by the orchestrator to defer
    /// `completeWithDone` until TTS truly stops, so the .speaking pill stays visible.
    var onSpeakingFinished: (() -> Void)?

    private init() {
        wireEngines()
    }

    // MARK: - Public API

    /// Start passively listening for the wake word. Wake word is only allowed
    /// inside Presence Mode; outside Presence there is no second standalone path.
    func startWakeWordListening() {
        guard presenceMode else {
            print("GigiAudioManager: startWakeWord skipped — Presence inactive")
            return
        }
        guard state == .idle else {
            print("GigiAudioManager: startWakeWord skipped — state=\(state)")
            return
        }
        transition(to: .wakeWordListening)
    }

    /// Start recording user speech (after wake word or tap).
    func startRecording() {
        switch state {
        case .idle:
            transition(to: .recording)

        case .wakeWordListening:
            GigiWakeWordEngine.shared.stopMonitoringHard(reason: "recording requested")
            transition(to: .recording)

        case .speaking:
            beginBargeInRecording()

        case .recording:
            print("GigiAudioManager: startRecording skipped — already recording")
        }
    }

    /// Natural barge-in: user asked to listen while GIGI is speaking.
    /// We suppress the normal post-TTS completion callback, reset the audio session,
    /// then open VAD recording after a short hardware-settle delay.
    private func beginBargeInRecording() {
        print("GigiAudioManager: speaking → recording requested (barge-in)")
        suppressNextSpeakingFinished = true
        bargeInTask?.cancel()

        // Release TTS ownership now; AVSpeechSynthesizer.didCancel may arrive later and
        // will be ignored once by notifySpeakingFinished().
        GigiAudioSequestrator.shared.notifySpeechFinished()
        transition(to: .idle)

        bargeInTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.state == .idle else {
                print("GigiAudioManager: barge-in recording skipped — state=\(self.state)")
                return
            }
            self.transition(to: .recording)
        }
    }

    /// Stop recording and return to idle (wake word will auto-resume if enabled).
    func stopRecording() {
        guard state == .recording else { return }
        GigiVADEngine.shared.stopListening()
        transition(to: .idle)
    }

    /// Notify that TTS has started.
    func notifySpeakingStarted() {
        if state == .recording { GigiVADEngine.shared.stopListening() }
        // Wake word MUST stop before TTS starts — both fight for the audio session.
        // Running .record category (wake word) while .playAndRecord (TTS) is active
        // causes OSStatus -50 / "Failed to set properties" and a tight restart loop.
        GigiWakeWordEngine.shared.stopMonitoringHard()
        transition(to: .speaking)
        GigiAudioSequestrator.shared.notifySpeechStarted()
    }

    /// Window after TTS during which we listen directly (no "hey gigi" required).
    /// Quiet rooms never trip GigiVADEngine's `hasSpeechStarted` gate — without this
    /// timer the mic would stay open until the Presence 5-min inactivity timeout.
    private static let presenceFollowUpWindow: TimeInterval = 8.0
    private var followUpTimeoutTask: Task<Void, Never>?
    private var suppressNextSpeakingFinished = false
    private var bargeInTask: Task<Void, Never>?

    var debugSnapshot: [String: String] {
        [
            "state": "\(state)",
            "presenceMode": "\(presenceMode)",
            "wakeWordEngineRunning": "\(wakeWordEngineRunning)",
            "lastWakeWordError": lastWakeWordError ?? "none"
        ]
    }

    /// Notify that TTS finished.
    /// In Presence Mode, transitions DIRECTLY to recording for an immediate follow-up
    /// (no "hey gigi" required). If the user stays silent for ~8s, fall back to
    /// wake-word standby — still inside the Presence session.
    func notifySpeakingFinished() {
        if suppressNextSpeakingFinished {
            suppressNextSpeakingFinished = false
            if state == .speaking { transition(to: .idle) }
            GigiDebugLogger.voiceEvent("audio.speakingFinishSuppressed", nil, dataForTrace())
            print("GigiAudioManager: speaking finish suppressed for barge-in")
            return
        }

        // Fire orchestrator callback first so pill can flip to .done before we hand
        // back to wake-word or follow-up recording. Order matters: the post-TTS delay
        // below must not race with completeWithDone visuals.
        onSpeakingFinished?()
        GigiAudioSequestrator.shared.notifySpeechFinished()
        transition(to: .idle)
        let delayNs: UInt64 = presenceMode ? 600_000_000 : 300_000_000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self else { return }
            if self.presenceMode {
                Task {
                    await GigiLiveActivityController.shared.updatePresence(
                        state: .listening,
                        message: "Listening for a follow-up"
                    )
                }
                self.startRecording()
                self.scheduleFollowUpTimeout()
            } else {
                self.resumeWakeWordIfEnabled()
            }
        }
    }

    private func scheduleFollowUpTimeout() {
        followUpTimeoutTask?.cancel()
        GigiDebugLogger.voiceEvent("audio.followUpWindowStarted", nil, dataForTrace())
        followUpTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.presenceFollowUpWindow * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // User actually spoke → VAD fired → state already moved off .recording. No-op.
            guard self.state == .recording else { return }
            print("GigiAudioManager: presence follow-up window elapsed — back to wake-word standby")
            GigiDebugLogger.voiceEvent("audio.followUpWindowElapsed", nil, self.dataForTrace())
            self.stopRecording()
            self.resumeWakeWordIfEnabled()
        }
    }

    /// Hard stop — resets to idle without resuming wake word.
    func stopAll() {
        GigiWakeWordEngine.shared.stopMonitoringHard()
        GigiVADEngine.shared.stopListening()
        transition(to: .idle)
    }

    // MARK: - Private

    private func transition(to newState: GigiAudioState) {
        print("GigiAudioManager: \(state) → \(newState)")
        GigiDebugLogger.voiceEvent("audio.transition", nil, ["from": "\(state)", "to": "\(newState)", "presenceMode": "\(presenceMode)"])
        // Any transition out of .recording invalidates the Presence follow-up window.
        if state == .recording, newState != .recording {
            followUpTimeoutTask?.cancel()
            followUpTimeoutTask = nil
        }
        state = newState
        applyState()
    }

    private func applyState() {
        switch state {
        case .idle:
            break

        case .wakeWordListening:
            // WakeWordEngine manages its own session; we just let it run
            GigiWakeWordEngine.shared.applyPreferredState()

        case .recording:
            GigiVADEngine.shared.startListening()

        case .speaking:
            // Session managed by GigiAudioSequestrator via notifySpeakingStarted
            break
        }
    }

    private func resumeWakeWordIfEnabled() {
        print("GigiAudioManager: resumeWakeWordIfEnabled — presence=\(presenceMode)")
        GigiDebugLogger.voiceEvent("audio.resumeWakeWordIfEnabled", nil, dataForTrace())
        if presenceMode { startWakeWordListening() }
    }

    private func dataForTrace() -> [String: String] {
        debugSnapshot
    }

    private func wireEngines() {
        // Wake word engine lifecycle → keep AudioManager state honest.
        let wake = GigiWakeWordEngine.shared
        wake.onMonitoringStarted = { [weak self] in
            guard let self else { return }
            self.wakeWordEngineRunning = true
            self.lastWakeWordError = nil
        }
        wake.onMonitoringStopped = { [weak self] reason in
            guard let self else { return }
            self.wakeWordEngineRunning = false
            if self.state == .wakeWordListening {
                print("GigiAudioManager: wake engine stopped while state=wakeWordListening — reason=\(reason ?? "none")")
                self.transition(to: .idle)
            }
        }
        wake.onMonitoringFailed = { [weak self] message in
            guard let self else { return }
            self.wakeWordEngineRunning = false
            self.lastWakeWordError = message
            Task { await GigiLiveActivityController.shared.showError(message: "Audio problem — tap to retry") }
            if self.state == .wakeWordListening {
                print("GigiAudioManager: wake engine failed — resetting audio state to idle: \(message)")
                self.transition(to: .idle)
            }
        }

        GigiVADEngine.shared.onTranscription = { [weak self] text in
            guard let self, self.state == .recording else { return }
            self.transition(to: .idle)
            self.onTranscription?(text)
        }

        GigiVADEngine.shared.onSilenceDetected = { [weak self] in
            self?.onSilenceDetected?()
        }

        GigiVADEngine.shared.onListeningFailed = { [weak self] in
            guard let self, self.state == .recording else { return }
            self.transition(to: .idle)
            self.resumeWakeWordIfEnabled()
            self.onListeningFailed?()
        }
    }
}
