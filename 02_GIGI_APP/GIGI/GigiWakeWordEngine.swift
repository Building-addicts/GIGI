import AVFoundation
import CallKit
import Foundation
import Speech
import UIKit

// MARK: - GigiWakeWordEngine
//
// Always-on wake word using only native Apple frameworks — no external SDK required.
// Uses SFSpeechRecognizer + AVAudioEngine to stream mic audio.
// Triggers on: "hey gigi", "ok gigi", "hi gigi", or plain "gigi".
//
// Battery strategy:
//   • taskHint = .unspecified → Apple loads a lightweight model (not the full dictation LM)
//   • contextualStrings biases the decoder toward our keywords → faster + more accurate
//   • addsPunctuation = false → skips the punctuation model entirely
//   • bufferSize 512 → halved from 1024, sufficient for keyword detection
//   • restart interval: 50s (Apple task limit is ~60s)
//   • App inactive > 2 min → full stop; resumes when app becomes active again
//     (UIScreen.main.brightness is unreliable — it keeps the user's set value
//      even after auto-lock, so brightness-based detection never fires)
//   • Low Power Mode → full stop; resumes when LPM deactivates
//   • Pauses automatically during calls (CallKit) and while GIGI is processing.
//   • requiresOnDeviceRecognition = true → avoids pinning the cellular/Wi-Fi radio
//     in high-power state 24/7 from continuous audio streaming to Apple servers.

@MainActor
final class GigiWakeWordEngine {
    static let shared = GigiWakeWordEngine()
    static let userDefaultsEnabledKey = "gigi.wakeWord.enabled"

    private(set) var isMonitoring = false

    private let audioEngine       = AVAudioEngine()
    private var recognizer:       SFSpeechRecognizer?
    private var recognitionReq:   SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask:  SFSpeechRecognitionTask?
    private var restartTimer:     Task<Void, Never>?
    private var screenDarkTimer:  Task<Void, Never>?   // fires 2 min after screen goes dark

    // Exponential backoff for rapid-failure restart loops
    private var consecutiveFailures = 0

    private var callObserver:         CXCallObserver?
    private var callObserverDelegate: WakeWordCallObserverDelegate?

    // Wake keywords (lowercased). Longer phrases first to avoid false positives on "gigi".
    private let keywords = ["hey gigi", "ok gigi", "hi gigi", "ehi gigi", "ciao gigi", "dai gigi", "gigi"]

    private init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
        recognizer?.defaultTaskHint = .unspecified  // lighter model than .dictation

        let obs = CXCallObserver()
        let del = WakeWordCallObserverDelegate()
        del.engine = self
        obs.setDelegate(del, queue: .main)
        callObserver         = obs
        callObserverDelegate = del

        // App lifecycle: stop wake word ~2min after the app becomes inactive
        // (screen lock, app switched away). This is the ONLY reliable signal —
        // UIScreen.main.brightness keeps the user's set value even when locked,
        // so brightness-based detection never fires on auto-lock → wake word
        // would run 24/7 in the background, burning battery.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppInactive() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppActive() }
        }

        // Low Power Mode: stop immediately when enabled, resume when disabled
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyPreferredState() }
        }
    }

    // MARK: - App lifecycle dark timer

    private func handleAppActive() {
        // App foregrounded — cancel pending dark-timer and resume wake word
        screenDarkTimer?.cancel()
        screenDarkTimer = nil
        applyPreferredState()
    }

    private func handleAppInactive() {
        // App left foreground (locked, switched away) — wait 2 minutes before
        // cutting wake word to handle quick glances / app switches.
        guard screenDarkTimer == nil else { return }
        screenDarkTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)  // 2 minutes
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.screenDarkTimer = nil
                if self.isMonitoring {
                    print("GIGI WakeWord: app inactive 2 min — pausing to save battery")
                    self.stopMonitoringHard()
                }
            }
        }
    }

    // MARK: - Public API

    func setUserEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.userDefaultsEnabledKey)
        enabled ? applyPreferredState() : stopMonitoringHard()
    }

    func applyPreferredState() {
        Task { await applyPreferredStateAsync() }
    }

    // MARK: - Internal state management

    private func applyPreferredStateAsync() async {
        // Default to enabled when key was never set (fresh install)
        let isEnabled = UserDefaults.standard.object(forKey: Self.userDefaultsEnabledKey) as? Bool ?? true
        guard isEnabled else {
            stopMonitoringHard(); return
        }
        guard !shouldSuppressWake() else {
            stopMonitoringHard(); return
        }
        startMonitoringIfNeeded()
    }

    private func shouldSuppressWake() -> Bool {
        let o = GigiSmartOrchestrator.shared
        if o.isThinking || o.isListening || hasActivePhoneCall() { return true }
        // Presence Mode: user explicitly started a session — bypass battery/screen suppressions
        if o.isPresenceActive { return false }
        // Low Power Mode: don't run continuous neural inference
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        return false
    }

    private func hasActivePhoneCall() -> Bool {
        callObserver?.calls.contains(where: { !$0.hasEnded }) == true
    }

    // MARK: - Start / Stop

    private func startMonitoringIfNeeded() {
        guard !isMonitoring else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    print("GIGI WakeWord: speech recognition not authorized")
                    return
                }
                self?.beginListeningCycle()
            }
        }
    }

    private func beginListeningCycle() {
        guard !isMonitoring else { return }
        isMonitoring = true
        consecutiveFailures = 0
        startRecognitionTask()
        scheduleRestart()
        print("GIGI WakeWord: listening for 'Hey GIGI' ✓")
    }

    // Wake word audio session: must use .playAndRecord to be compatible with
    // GigiAudioSequestrator. Using .record conflicts when TTS or VAD switches to
    // .playAndRecord → OSStatus -50 + "Failed to set properties" errors.
    // .mixWithOthers: don't duck Spotify while passively listening — only duck during active recording.
    @discardableResult
    private func activateWakeSession() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                // .voiceChat: matches GigiAudioSequestrator → no hardware renegotiation
                // on wake → VAD handoff. .measurement disables echo cancellation / AGC /
                // speech DSP and keeps the ADC in high-fidelity mode — more power draw.
                mode: .voiceChat,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            return true
        } catch {
            print("GIGI WakeWord: session activate error — \(error.localizedDescription)")
            return false
        }
    }

    private func deactivateWakeSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("GIGI WakeWord: session deactivate error — \(error.localizedDescription)")
        }
    }

    private func startRecognitionTask() {
        guard let recognizer, recognizer.isAvailable else { return }

        // Bail if session activation fails (e.g. non-interruptible call in progress).
        // Proceeding after a failed setActive() leaves the engine in a state where
        // inputNode.outputFormat returns a stale format → installTap NSException crash.
        guard activateWakeSession() else {
            print("GIGI WakeWord: session not available — skipping tap install")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { [weak self] in
                    guard let self, self.isMonitoring, !self.shouldSuppressWake() else { return }
                    self.startRecognitionTask()
                }
            }
            return
        }

        // Reset stale hardware format — same fix as GigiVADEngine.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = false     // skip punctuation model — not needed for keywords
        req.contextualStrings = keywords  // bias decoder toward our phrases → faster + more accurate
        // Force on-device: server-based recognition streams audio to Apple continuously,
        // pinning the cellular/Wi-Fi radio in high-power state 24/7 (~1.5W). On-device
        // costs slightly more CPU (~0.3W) but lets the radio sleep. Huge net win for
        // always-on keyword spotting. Falls back to no-op if device can't run it.
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        recognitionReq = req

        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handleResult(result, error: error) }
        }

        let inputNode = audioEngine.inputNode

        // Use nil format: AVAudioEngine infers the hardware's actual native format at tap-install time.
        // Explicit format after reset() returns stale data → mismatch → uncatchable NSException.
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            self?.recognitionReq?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("GIGI WakeWord: audio engine error — \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            recognitionReq?.endAudio()
            recognitionReq  = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            deactivateWakeSession()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { [weak self] in
                    guard let self, self.isMonitoring, !self.shouldSuppressWake() else { return }
                    self.startRecognitionTask()
                }
            }
        }
    }

    private func stopRecognitionTask() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
        recognitionReq?.endAudio()
        recognitionReq  = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        deactivateWakeSession()
    }

    // Restart before the ~60s Apple task limit. Fixed 50s — we no longer gate on
    // UIScreen.main.brightness (unreliable: keeps the user's set value even when
    // locked). App inactivity already halts wake word via handleAppInactive, so
    // this interval only applies while the app is active.
    private func scheduleRestart() {
        restartTimer?.cancel()
        let interval: UInt64 = 50_000_000_000
        restartTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            guard let self, !Task.isCancelled, self.isMonitoring else { return }
            await MainActor.run {
                self.stopRecognitionTask()
                self.startRecognitionTask()
                self.scheduleRestart()
            }
        }
    }

    private var currentScreenBrightness: CGFloat {
        if let screen = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.screen })
            .first {
            return screen.brightness
        }
        return 1
    }

    func stopMonitoringHard() {
        guard isMonitoring else { return }
        isMonitoring = false  // set before cancel to block spurious restart callbacks
        restartTimer?.cancel()
        restartTimer = nil
        screenDarkTimer?.cancel()
        screenDarkTimer = nil
        stopRecognitionTask()
        print("GIGI WakeWord: stopped")
    }

    // MARK: - Keyword detection

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        guard isMonitoring else { return }

        if let error {
            consecutiveFailures += 1
            // Exponential backoff: 1.5s → 3s → 6s → 15s → 30s cap.
            // Prevents the "No speech detected" tight loop that burns CPU/battery.
            let cooldownNs: UInt64
            switch consecutiveFailures {
            case 1:     cooldownNs = 1_500_000_000   // 1.5s
            case 2:     cooldownNs = 3_000_000_000   // 3s
            case 3:     cooldownNs = 6_000_000_000   // 6s
            case 4:     cooldownNs = 15_000_000_000  // 15s
            default:    cooldownNs = 30_000_000_000  // 30s — something is wrong, back off hard
            }
            print("GIGI WakeWord: task ended (\(error.localizedDescription)) — restart in \(cooldownNs/1_000_000_000)s (failure #\(consecutiveFailures))")
            stopRecognitionTask()
            guard isMonitoring else { return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: cooldownNs)
                await MainActor.run { [weak self] in
                    guard let self, self.isMonitoring, !self.shouldSuppressWake() else { return }
                    self.startRecognitionTask()
                }
            }
            return
        }

        guard let text = result?.bestTranscription.formattedString.lowercased() else { return }

        for keyword in keywords {
            if text.hasSuffix(keyword) || text.contains(keyword + " ") || text == keyword {
                print("GIGI WakeWord: detected '\(keyword)' in '\(text)'")
                handleWakeDetection()
                return
            }
        }
    }

    private func handleWakeDetection() {
        consecutiveFailures = 0
        stopMonitoringHard()
        GigiAudioSequestrator.shared.prewarmBluetooth()
        SoundEngine.play(.wakeWord)
        GigiSmartOrchestrator.shared.startListening()
    }
}

// MARK: - CallKit observer

private final class WakeWordCallObserverDelegate: NSObject, CXCallObserverDelegate {
    weak var engine: GigiWakeWordEngine?

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor [weak self] in
            if call.hasEnded {
                // Call ended — delay restart to let audio hardware settle before
                // the wake word engine tries to seize the audio session.
                // Interruption.ended also fires with its own 1.5s delay; whichever
                // arrives second is a no-op because isMonitoring will already be true.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            self?.engine?.applyPreferredState()
        }
    }
}
