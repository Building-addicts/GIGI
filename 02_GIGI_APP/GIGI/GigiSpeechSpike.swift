import AppIntents
import AVFoundation
import Foundation
import Speech
import os.log

// MARK: - GigiSpeechSpike
//
// SPIKE intent for issue #146 — verify whether SFSpeechRecognizer can capture
// audio when this AppIntent is triggered by a Shortcut while the GIGI app is
// fully backgrounded or terminated. Must run with `openAppWhenRun: false` to
// prove the premium UX path (no app foreground at any time).
//
// Three test scenarios to validate manually on physical device:
//   A. App in foreground — baseline (should always succeed)
//   B. App in background non-killed
//   C. App fully terminated (run Shortcut from springboard / Action Button)
//
// Findings recorded in docs/research/bg-speech-recognizer-spike.md.

@available(iOS 16.0, *)
struct GigiSpeechSpike: AppIntent {
    static var title: LocalizedStringResource = "GIGI Speech Spike"
    static var description = IntentDescription("Diagnostic spike for background speech capture (issue #146).")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Capture Duration (seconds)", default: 4.0)
    var duration: Double

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let log = Logger(subsystem: "com.killsiri.GIGI", category: "speech-spike")
        let startTime = Date()
        log.info("spike.start duration=\(self.duration, privacy: .public)s")

        guard try await ensureAuthorization(log: log) else {
            let msg = "DENIED:permissions"
            await GigiSpeechSpikeRecorder.shared.append(line: "\(Self.iso(startTime)) \(msg)")
            return .result(value: msg)
        }

        do {
            let transcript = try await captureTranscript(duration: duration, log: log)
            let elapsed = Date().timeIntervalSince(startTime)
            let line = "\(Self.iso(startTime)) OK transcript=\(transcript.prefix(120)) elapsed=\(String(format: "%.2f", elapsed))s"
            await GigiSpeechSpikeRecorder.shared.append(line: line)
            log.info("spike.ok transcript_len=\(transcript.count, privacy: .public)")
            return .result(value: transcript)
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            let line = "\(Self.iso(startTime)) FAIL error=\(error.localizedDescription) elapsed=\(String(format: "%.2f", elapsed))s"
            await GigiSpeechSpikeRecorder.shared.append(line: line)
            log.error("spike.fail error=\(error.localizedDescription, privacy: .public)")
            return .result(value: "FAIL:\(error.localizedDescription)")
        }
    }

    private func ensureAuthorization(log: Logger) async throws -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        if speech != .authorized {
            log.error("spike.auth.speech denied=\(String(describing: speech), privacy: .public)")
            return false
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        if !mic {
            log.error("spike.auth.mic denied")
            return false
        }
        return true
    }

    private func captureTranscript(duration: Double, log: Logger) async throws -> String {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        log.info("spike.audio.session.activated")

        let engine = AVAudioEngine()
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw SpikeError.recognizerUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            log.info("spike.recognizer.on_device=true")
        } else {
            log.warning("spike.recognizer.on_device=false")
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        return try await withCheckedThrowingContinuation { cont in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    cont.resume(throwing: error)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                request.endAudio()
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                if task.state == .running {
                    task.finish()
                }
            }
        }
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

// MARK: - SpikeError

private enum SpikeError: LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "SFSpeechRecognizer unavailable for en-US"
        }
    }
}

// MARK: - Recorder (durable findings log in App Group)

private actor GigiSpeechSpikeRecorder {
    static let shared = GigiSpeechSpikeRecorder()

    private let url: URL? = {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.gigi.presence") else {
            return nil
        }
        return container.appendingPathComponent("speech-spike.log")
    }()

    func append(line: String) {
        guard let url else { return }
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(payload)
            }
        } else {
            try? payload.write(to: url)
        }
    }
}
