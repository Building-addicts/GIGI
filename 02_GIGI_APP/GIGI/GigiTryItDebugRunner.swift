import AVFoundation
import Foundation
import Speech
import os.log

// MARK: - GigiTryItDebugRunner
//
// DEBUG-ONLY scaffolding for issue #151. Wires together the same pieces
// of issue #147 (`GigiBeginSessionIntent` + `GigiOrchestratorIntent`)
// in-process so a Settings button can run the full chain end-to-end
// without going through the iOS Shortcut.
//
// REMOVE post-MVP. See issue #151 for the cleanup follow-up.
//
// Differences vs the production AppIntent path:
//   - Runs in the foreground app process, not via Shortcut runtime.
//   - Always uses on-device speech recognizer if available.
//   - Surfaces the final marker as a `Result` for SwiftUI to alert.

@MainActor
final class GigiTryItDebugRunner {

    static let shared = GigiTryItDebugRunner()

    private let log = Logger(subsystem: "com.killsiri.GIGI", category: "tryit-debug")
    private var inFlight = false

    enum DebugError: LocalizedError {
        case alreadyRunning
        case permissionDenied(String)
        case recognizerUnavailable
        case sessionFailed(String)
        case orchestratorFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:           return "Already running"
            case .permissionDenied(let m):  return "Permission denied: \(m)"
            case .recognizerUnavailable:    return "Speech recognizer unavailable"
            case .sessionFailed(let m):     return "Audio session failed: \(m)"
            case .orchestratorFailed(let m):return "Orchestrator: \(m)"
            }
        }
    }

    struct Outcome {
        let transcript: String
        let marker: String
        let elapsedTotal: TimeInterval
    }

    /// Full chain: descend DI → capture audio → orchestrator → return marker.
    /// Caller surfaces `Outcome.marker` (or `Error.localizedDescription`) in
    /// a SwiftUI alert.
    func run(captureDuration: Double = 6.0,
             locale: String = "en-US") async throws -> Outcome {
        guard !inFlight else { throw DebugError.alreadyRunning }
        inFlight = true
        defer { inFlight = false }

        let started = Date()
        log.info("tryit.start duration=\(captureDuration, privacy: .public)s locale=\(locale, privacy: .public)")

        try await ensurePermissions()

        await GigiLiveActivityController.shared.descendForListening()

        let transcript = try await capture(duration: captureDuration, locale: locale)
        log.info("tryit.transcript len=\(transcript.count, privacy: .public)")

        await GigiLiveActivityController.shared.transitionToThinking(transcript: transcript)

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await GigiLiveActivityController.shared.completeWithDone(message: "Empty", dismissAfter: 1)
            throw DebugError.orchestratorFailed("empty transcript")
        }

        let marker: String
        do {
            let contacts = await GigiOrchestratorClient.contactSnapshot()
            marker = try await GigiOrchestratorClient.route(
                transcript: trimmed,
                contacts: contacts,
                locale: locale
            )
        } catch {
            await GigiLiveActivityController.shared.completeWithDone(message: "Failed", dismissAfter: 1)
            throw DebugError.orchestratorFailed(error.localizedDescription)
        }

        let elapsed = Date().timeIntervalSince(started)
        log.info("tryit.ok elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s marker=\(marker, privacy: .public)")

        let summary = String(marker.prefix(24))
        await GigiLiveActivityController.shared.completeWithDone(message: summary, dismissAfter: 3)

        return Outcome(transcript: trimmed, marker: marker, elapsedTotal: elapsed)
    }

    // MARK: - Permissions

    private func ensurePermissions() async throws {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        if speech != .authorized {
            throw DebugError.permissionDenied("speech (\(speech.rawValue))")
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        if !mic { throw DebugError.permissionDenied("microphone") }
    }

    // MARK: - Inline speech capture (mirrors GigiBeginSessionIntent)

    private func capture(duration: Double, locale: String) async throws -> String {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw DebugError.sessionFailed(error.localizedDescription)
        }

        let engine = AVAudioEngine()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable else {
            try? session.setActive(false)
            throw DebugError.recognizerUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            let level = Self.audioLevel(buffer: buffer)
            Task { @MainActor in
                await GigiLiveActivityController.shared.updateAudioLevel(level)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            try? session.setActive(false)
            throw DebugError.sessionFailed(error.localizedDescription)
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

    private static func audioLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLen = Int(buffer.frameLength)
        guard frameLen > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frameLen { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(frameLen))
        let db = 20 * log10(max(rms, 1e-7))
        let clamped = max(-50, min(-5, db))
        return Float((clamped + 50) / 45)
    }
}
