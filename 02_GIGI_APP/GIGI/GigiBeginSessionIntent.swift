import AppIntents
import AVFoundation
import Foundation
import Speech
import os.log

// MARK: - GigiBeginSessionIntent
//
// Step 1 of the Action Button → Dynamic Island → Orchestrator Shortcut chain.
//
// Triggered by the "Talk To Gigi" Shortcut. Brings the Dynamic Island down
// in `.listening` phase, opens an audio session + SFSpeechRecognizer in
// the background (premium path), and returns the transcript to the
// Shortcut for Step 2 (`GigiOrchestratorIntent`).
//
// Important: `openAppWhenRun = false`. The whole point of this flow is
// that the GIGI app stays in background while the user keeps using
// Instagram, WhatsApp, an active call — only the DI banner is visible.
//
// Spike #146 validates whether the premium path works on physical
// device. If the spike comes back negative for the fully-terminated
// scenario, this intent's body becomes a thin wrapper that surfaces the
// system Dictate Text UI fallback. For now we ship the premium path.

@available(iOS 16.0, *)
struct GigiBeginSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Begin GIGI Session"
    static var description = IntentDescription("Bring up the GIGI Dynamic Island banner and capture user speech in background.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Capture Duration (seconds)", default: 6.0)
    var duration: Double

    @Parameter(title: "Locale", default: "en-US")
    var localeIdentifier: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let log = Logger(subsystem: "com.killsiri.GIGI", category: "begin-session")
        let startedAt = Date()
        log.info("begin.start duration=\(self.duration, privacy: .public)s locale=\(self.localeIdentifier, privacy: .public)")

        await MainActor.run {
            // Fire-and-forget descend; we don't block on the LiveActivity result.
            Task { await GigiLiveActivityController.shared.descendForListening() }
        }

        guard try await SessionAuth.ensure(log: log) else {
            await MainActor.run {
                Task { await GigiLiveActivityController.shared.showError(message: "Microphone or Speech access denied") }
            }
            return .result(value: "")
        }

        do {
            let transcript = try await BackgroundSpeechCapture.run(
                duration: duration,
                locale: localeIdentifier,
                onLevel: { level in
                    Task { @MainActor in
                        await GigiLiveActivityController.shared.updateAudioLevel(level)
                    }
                },
                log: log
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            log.info("begin.ok elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s len=\(transcript.count, privacy: .public)")
            return .result(value: transcript)
        } catch {
            let elapsed = Date().timeIntervalSince(startedAt)
            log.error("begin.fail elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s err=\(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                Task { await GigiLiveActivityController.shared.showError(message: "Listening failed") }
            }
            return .result(value: "")
        }
    }
}

// MARK: - Permission gate

@available(iOS 16.0, *)
private enum SessionAuth {
    static func ensure(log: Logger) async throws -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        if speech != .authorized {
            log.error("auth.speech denied=\(String(describing: speech), privacy: .public)")
            return false
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        if !mic {
            log.error("auth.mic denied")
            return false
        }
        return true
    }
}

// MARK: - Background capture

@available(iOS 16.0, *)
private enum BackgroundSpeechCapture {

    enum CaptureError: LocalizedError {
        case recognizerUnavailable
        case sessionFailed(String)
        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable: return "SFSpeechRecognizer unavailable"
            case .sessionFailed(let msg): return msg
            }
        }
    }

    static func run(duration: Double,
                    locale: String,
                    onLevel: @escaping (Float) -> Void,
                    log: Logger) async throws -> String {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw CaptureError.sessionFailed(error.localizedDescription)
        }

        let engine = AVAudioEngine()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable else {
            try? session.setActive(false)
            throw CaptureError.recognizerUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            let level = audioLevel(buffer: buffer)
            onLevel(level)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            try? session.setActive(false)
            throw CaptureError.sessionFailed(error.localizedDescription)
        }

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    resumed = true
                    cont.resume(throwing: error)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                request.endAudio()
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                if !resumed, task.state == .running { task.finish() }
            }
        }
    }

    /// RMS-based level computation, normalized to 0.0–1.0 with mild
    /// headroom expansion so quiet speech still moves the waveform bars.
    private static func audioLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLen = Int(buffer.frameLength)
        guard frameLen > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frameLen {
            let s = samples[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frameLen))
        // Map -50 dBFS .. -5 dBFS → 0 .. 1
        let db = 20 * log10(max(rms, 1e-7))
        let clamped = max(-50, min(-5, db))
        let norm = (clamped + 50) / 45
        return Float(norm)
    }
}
