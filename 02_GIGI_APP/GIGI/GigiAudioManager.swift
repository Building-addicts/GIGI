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
final class GigiAudioManager {
    static let shared = GigiAudioManager()

    private(set) var state: GigiAudioState = .idle {
        didSet { onStateChange?(oldValue, state) }
    }

    // Called whenever state transitions so observers can react
    var onStateChange: ((GigiAudioState, GigiAudioState) -> Void)?

    // Forwarded from the underlying engines
    var onWakeWordDetected: (() -> Void)?
    var onTranscription:    ((String) -> Void)?
    var onSilenceDetected:  (() -> Void)?
    var onListeningFailed:  (() -> Void)?

    private init() {
        wireEngines()
    }

    // MARK: - Public API

    /// Start passively listening for the wake word. No-op if already active.
    func startWakeWordListening() {
        guard state == .idle else {
            print("GigiAudioManager: startWakeWord skipped — state=\(state)")
            return
        }
        transition(to: .wakeWordListening)
    }

    /// Start recording user speech (after wake word or tap).
    func startRecording() {
        let allowed: Set<GigiAudioState> = [.idle, .wakeWordListening]
        guard allowed.contains(state) else {
            print("GigiAudioManager: startRecording skipped — state=\(state)")
            return
        }
        if state == .wakeWordListening {
            GigiWakeWordEngine.shared.stopMonitoringHard()
        }
        transition(to: .recording)
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

    /// Notify that TTS finished. Resumes wake word if enabled.
    func notifySpeakingFinished() {
        GigiAudioSequestrator.shared.notifySpeechFinished()
        transition(to: .idle)
        // Small delay: let the audio hardware settle after TTS before seizing mic again
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.resumeWakeWordIfEnabled()
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
        let isEnabled = UserDefaults.standard.object(
            forKey: GigiWakeWordEngine.userDefaultsEnabledKey
        ) as? Bool ?? true
        if isEnabled { startWakeWordListening() }
    }

    private func wireEngines() {
        // Wake word detected → trigger recording
        _ = GigiWakeWordEngine.shared // ensure init
        // WakeWordEngine calls GigiSmartOrchestrator.startListening() directly on detection.
        // We intercept by observing state changes from the orchestrator.
        // The orchestrator already calls startRecording path via startListening().
        // No additional wiring needed here — see GigiSmartOrchestrator.startListening().

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
