import AVFoundation
import CallKit
import Foundation
import Speech
import UIKit
import UserNotifications

// MARK: - GigiWakeWordEngine
//
// Always-on wake word using only native Apple frameworks — no external SDK required.
// Uses SFSpeechRecognizer (en-US, on-device) + AVAudioEngine to stream mic audio.
// Triggers on: "hey gigi", "ok gigi", "hi gigi", or plain "gigi".
//
// Battery strategy:
//   • taskHint = .unspecified → Apple loads a lightweight model (not the full dictation LM)
//   • contextualStrings biases the decoder toward our keywords → faster + more accurate
//   • addsPunctuation = false → skips the punctuation model entirely
//   • bufferSize 512 → halved from 1024, sufficient for keyword detection
//   • restart interval: 50s (Apple task limit is ~60s)
//     Restart is gap-free: audio engine tap stays alive, only the SFSpeech request is swapped.
//   • App inactive > 2 min → full stop; resumes when app becomes active again
//     (UIScreen.main.brightness is unreliable — it keeps the user's set value
//      even after auto-lock, so brightness-based detection never fires)
//   • Low Power Mode → full stop; resumes when LPM deactivates
//   • Pauses automatically during calls (CallKit) and while GIGI is processing.
//   • requiresOnDeviceRecognition = true → avoids pinning the cellular/Wi-Fi radio
//     in high-power state 24/7 from continuous audio streaming to Apple servers.
//   • Locale fixed to en-US — market is US/English; Locale.current causes acoustic
//     model mismatch when device is set to another language.

@MainActor
final class GigiWakeWordEngine {
    static let shared = GigiWakeWordEngine()
    static let userDefaultsEnabledKey = "gigi.wakeWord.enabled"

    private(set) var isMonitoring = false

    var onMonitoringStarted: (() -> Void)?
    var onMonitoringStopped: ((String?) -> Void)?
    var onMonitoringFailed: ((String) -> Void)?

    private let audioEngine       = AVAudioEngine()
    private var recognizer:       SFSpeechRecognizer?
    private var recognitionReq:   SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask:  SFSpeechRecognitionTask?
    private var restartTimer:     Task<Void, Never>?
    private var screenDarkTimer:  Task<Void, Never>?   // fires 2 min after screen goes dark

    // Exponential backoff for rapid-failure restart loops
    private var consecutiveFailures = 0
    private let maxConsecutiveFailuresBeforeStop = 5
    private var useOnDeviceRecognition = true

    private var callObserver:         CXCallObserver?
    private var callObserverDelegate: WakeWordCallObserverDelegate?

    // Wake keywords (lowercased). Longer phrases first — reduces false positives on bare "gigi".
    // Italian variants included: en-US acoustic model maps "ehi"→"hey", but contextualStrings
    // biases the decoder so the Italian forms are also recognized directly.
    private let keywords = ["hey gigi", "ok gigi", "hi gigi", "ehi gigi", "ciao gigi", "dai gigi", "gigi"]

    private init() {
        // en-US fixed: Locale.current causes acoustic model mismatch when device language differs
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
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
        // Backward-compatible API: this toggle now means "GIGI always available".
        // Wake word is not a standalone mode anymore; it only runs inside Presence Mode.
        PresenceSessionController.shared.setAlwaysAvailable(enabled)
    }

    func applyPreferredState() {
        Task { await applyPreferredStateAsync() }
    }

    // MARK: - Internal state management

    private func applyPreferredStateAsync() async {
        // Wake word is only valid inside Presence Mode. This prevents the old
        // standalone wake-word path from racing the Presence/Live Activity pipeline.
        let presenceActive = GigiSmartOrchestrator.shared.isPresenceActive
        guard presenceActive else {
            stopMonitoringHard(reason: "presence inactive")
            return
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

        logDiagnostics(prefix: "startMonitoring")

        let micPermission = currentMicPermission()
        if micPermission == .denied {
            failBeforeMonitoring("Microphone permission denied — enable it in Settings → GIGI → Microphone.")
            return
        }
        if micPermission == .undetermined {
            requestMicPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.startMonitoringIfNeeded()
                    } else {
                        self.failBeforeMonitoring("Microphone permission denied — enable it in Settings → GIGI → Microphone.")
                    }
                }
            }
            return
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if status == .authorized {
                        self.beginListeningCycle()
                    } else {
                        self.failBeforeMonitoring("Speech recognition permission denied — enable it in Settings → GIGI → Speech Recognition.")
                    }
                }
            }
            return
        }

        guard speechStatus == .authorized else {
            failBeforeMonitoring("Speech recognition unavailable: authorization=\(speechStatus.rawValue).")
            return
        }

        beginListeningCycle()
    }

    private func beginListeningCycle() {
        guard !isMonitoring else { return }
        isMonitoring = true
        consecutiveFailures = 0
        useOnDeviceRecognition = true
        guard startRecognitionTask() else { return }
        scheduleRestart()
        onMonitoringStarted?()
        print("GIGI WakeWord: listening for 'Hey GIGI' ✓")
        // Start persistent Dynamic Island pill. Idempotent — no-op if already showing.
        Task { await GigiLiveActivityController.shared.startWakeWordMonitoring() }
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
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
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

    @discardableResult
    private func startRecognitionTask() -> Bool {
        guard let recognizer else {
            failMonitoring("Speech recognizer could not be created for en-US.")
            return false
        }
        guard recognizer.isAvailable else {
            retryRecognition(reason: "Speech recognizer temporarily unavailable")
            return false
        }

        // Bail if session activation fails (e.g. non-interruptible call in progress).
        // Proceeding after a failed setActive() leaves the engine in a state where
        // inputNode.outputFormat returns a stale format → installTap NSException crash.
        guard activateWakeSession() else {
            retryRecognition(reason: "Audio session activation failed")
            return false
        }

        // Reset stale hardware format — same fix as GigiVADEngine.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()

        let req = makeRecognitionRequest(for: recognizer)
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
            retryRecognition(
                reason: "Audio engine start failed: \(error.localizedDescription)",
                countsTowardFailure: !isTransientAudioEngineStartError(error)
            )
            return false
        }
        logDiagnostics(prefix: "recognitionTaskStarted")
        return true
    }

    private func makeRecognitionRequest(for recognizer: SFSpeechRecognizer) -> SFSpeechAudioBufferRecognitionRequest {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = false     // skip punctuation model — not needed for keywords
        req.contextualStrings = keywords  // bias decoder toward our phrases → faster + more accurate
        if useOnDeviceRecognition, recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        return req
    }

    private func retryRecognition(reason: String, countsTowardFailure: Bool = true) {
        if countsTowardFailure {
            consecutiveFailures += 1
            if consecutiveFailures >= maxConsecutiveFailuresBeforeStop {
                failMonitoring("Wake word unavailable after \(consecutiveFailures) retries. Last error: \(reason)")
                return
            }
        } else {
            consecutiveFailures = 0
        }
        let retryIndex = countsTowardFailure ? consecutiveFailures : 1
        let cooldownNs = cooldown(for: retryIndex)
        let suffix = countsTowardFailure ? "failure #\(consecutiveFailures)" : "routine restart"
        print("GIGI WakeWord: \(reason) — restart in \(cooldownNs/1_000_000_000)s (\(suffix))")
        stopRecognitionTask()
        scheduleRecognitionRetry(after: cooldownNs)
    }

    private func scheduleRecognitionRetry(after cooldownNs: UInt64) {
        guard isMonitoring else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: cooldownNs)
            await MainActor.run { [weak self] in
                guard let self, self.isMonitoring, !self.shouldSuppressWake() else { return }
                _ = self.startRecognitionTask()
            }
        }
    }

    private enum MicPermissionState: String {
        case undetermined
        case denied
        case granted
        case unknown
    }

    private func currentMicPermission() -> MicPermissionState {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined: return .undetermined
            case .denied: return .denied
            case .granted: return .granted
            @unknown default: return .unknown
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .undetermined: return .undetermined
            case .denied: return .denied
            case .granted: return .granted
            @unknown default: return .unknown
            }
        }
    }

    private func requestMicPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(completion)
        }
    }

    private func cooldown(for failureCount: Int) -> UInt64 {
        switch failureCount {
        case 1:     return 1_500_000_000
        case 2:     return 3_000_000_000
        case 3:     return 6_000_000_000
        case 4:     return 15_000_000_000
        default:    return 30_000_000_000
        }
    }

    private func failBeforeMonitoring(_ message: String) {
        print("GIGI WakeWord: failed before monitoring — \(message)")
        onMonitoringFailed?(message)
    }

    private func failMonitoring(_ message: String) {
        print("GIGI WakeWord: failed — \(message)")
        isMonitoring = false
        restartTimer?.cancel()
        restartTimer = nil
        screenDarkTimer?.cancel()
        screenDarkTimer = nil
        stopRecognitionTask()
        onMonitoringFailed?(message)
    }

    private func shouldFallbackFromOnDevice(_ error: Error) -> Bool {
        guard useOnDeviceRecognition else { return false }
        let ns = error as NSError
        return ns.domain == "kAFAssistantErrorDomain" && ns.code == 1107
    }

    private func isNoSpeechDetected(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110
    }

    private func isTransientAudioEngineStartError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "com.apple.coreaudio.avfaudio" && ns.code == 2003329396
    }

    private func describeRecognitionError(_ error: Error) -> String {
        let ns = error as NSError
        return "domain=\(ns.domain) code=\(ns.code) description=\(error.localizedDescription)"
    }

    private func logDiagnostics(prefix: String) {
        let speechStatus = SFSpeechRecognizer.authorizationStatus().rawValue
        let mic = currentMicPermission().rawValue
        let available = recognizer?.isAvailable == true
        let supportsOnDevice = recognizer?.supportsOnDeviceRecognition == true
        print("GIGI WakeWord diagnostics [\(prefix)]: speechAuth=\(speechStatus) micPermission=\(mic) recognizerAvailable=\(available) supportsOnDevice=\(supportsOnDevice) useOnDevice=\(useOnDeviceRecognition)")
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
    //
    // Gap-free restart: the audio engine tap stays alive; only the SFSpeech request
    // is swapped. This eliminates the ~300-500ms blind window of the old stop+start approach.
    private func scheduleRestart() {
        restartTimer?.cancel()
        let interval: UInt64 = 50_000_000_000
        restartTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            guard let self, !Task.isCancelled, self.isMonitoring else { return }
            await MainActor.run {
                self.softRestartRecognitionTask()
                self.scheduleRestart()
            }
        }
    }

    // Swap only the SFSpeech request — engine and tap stay alive, zero audio gap.
    private func softRestartRecognitionTask() {
        guard isMonitoring, let recognizer, recognizer.isAvailable else { return }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionReq?.endAudio()

        let req = makeRecognitionRequest(for: recognizer)
        recognitionReq = req
        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handleResult(result, error: error) }
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

    func stopMonitoringHard(reason: String? = nil) {
        guard isMonitoring else { return }
        isMonitoring = false  // set before cancel to block spurious restart callbacks
        restartTimer?.cancel()
        restartTimer = nil
        screenDarkTimer?.cancel()
        screenDarkTimer = nil
        stopRecognitionTask()
        print("GIGI WakeWord: stopped")
        onMonitoringStopped?(reason)
    }

    // MARK: - Keyword detection

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        guard isMonitoring else { return }

        if let error {
            let detail = describeRecognitionError(error)
            if isNoSpeechDetected(error) {
                retryRecognition(reason: "No speech detected", countsTowardFailure: false)
                return
            }
            if shouldFallbackFromOnDevice(error) {
                useOnDeviceRecognition = false
                consecutiveFailures = 0
                print("GIGI WakeWord: on-device recognizer failed (\(detail)) — falling back to server recognition for this session")
                stopRecognitionTask()
                scheduleRecognitionRetry(after: 1_500_000_000)
                return
            }
            retryRecognition(reason: "Speech task ended: \(detail)")
            return
        }

        guard let text = result?.bestTranscription.formattedString.lowercased() else { return }

        for keyword in keywords {
            if matchesKeyword(text, keyword: keyword) {
                print("GIGI WakeWord: detected '\(keyword)' in '\(text)'")
                handleWakeDetection()
                return
            }
        }
    }

    // Word-boundary match: prevents "luigi" or "biologi" from triggering bare "gigi".
    // Checks: exact match, keyword at start/end of sentence (with space), or mid-sentence.
    private func matchesKeyword(_ text: String, keyword: String) -> Bool {
        if text == keyword { return true }
        if text.hasPrefix(keyword + " ") { return true }
        if text.hasSuffix(" " + keyword) { return true }
        if text.contains(" " + keyword + " ") { return true }
        return false
    }

    private func handleWakeDetection() {
        consecutiveFailures = 0
        stopMonitoringHard()
        GigiAudioSequestrator.shared.prewarmBluetooth()
        let isForeground = UIApplication.shared.applicationState == .active
        if isForeground {
            SoundEngine.play(.wakeWord)
            Task { await GigiLiveActivityController.shared.beginListening() }
        } else {
            scheduleWakeNotification()
            Task { await GigiLiveActivityController.shared.descendForListening() }
        }
        // Delay VAD start so the earcon and AVAudioSession route changes settle
        // before SoundEngine.didFinishPlaying() calls setActive(false) on the shared session.
        // Without this delay, didFinishPlaying() deactivates the session mid-VAD setup.
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            GigiSmartOrchestrator.shared.startListening()
        }
    }

    private func scheduleWakeNotification() {
        let content = UNMutableNotificationContent()
        content.title = "GIGI"
        content.body = "I heard you"
        content.sound = .default
        content.userInfo = ["type": "gigi-wake", "source": "wake-word"]

        let request = UNNotificationRequest(
            identifier: "gigi.wake.detected",
            content: content,
            trigger: nil
        )
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
        center.add(request) { error in
            if let error {
                GigiDebugLogger.log("Wake notification failed: \(error.localizedDescription)")
            } else {
                GigiDebugLogger.log("Wake notification scheduled")
            }
        }
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
