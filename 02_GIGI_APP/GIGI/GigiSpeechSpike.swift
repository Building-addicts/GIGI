import AppIntents
import AVFoundation
import Foundation
import Speech

// MARK: - GigiSpeechSpike (#146)
//
// Throwaway AppIntent prototype to verify whether SFSpeechRecognizer can
// transcribe live mic audio when iOS launches us via a Shortcut with
// openAppWhenRun = false. If this works in scenario C (fully-terminated)
// we ship the premium Action Button path; otherwise we fall back to the
// Shortcut's Dictate Text step.
//
// Keep this file out of production once the spike conclusion lands in
// docs/research/bg-speech-recognizer-spike.md.

@available(iOS 16.0, *)
struct GigiSpeechSpike: AppIntent {
    static var title: LocalizedStringResource = "GIGI · Speech spike"
    static var description = IntentDescription("Internal probe — measures whether background SFSpeechRecognizer is allowed.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let started = Date()
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            return .result(value: "spike: recognizer unavailable")
        }

        let authStatus = await Self.requestSpeechAuth()
        guard authStatus == .authorized else {
            return .result(value: "spike: speech auth = \(authStatus.rawValue)")
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return .result(value: "spike: session activate failed — \(error.localizedDescription)")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        let engine = AVAudioEngine()
        let format = engine.inputNode.inputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            request.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            return .result(value: "spike: engine start failed — \(error.localizedDescription)")
        }

        let transcript: String = await withCheckedContinuation { continuation in
            var resumed = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                } else if error != nil {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: "spike: error \(error!.localizedDescription)")
                    }
                }
            }
            // Hard cap: stop after 6s regardless of finality so the AppIntent
            // never approaches the 30s system ceiling during the experiment.
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                task.finish()
                request.endAudio()
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                if !resumed {
                    resumed = true
                    continuation.resume(returning: "spike: timeout 6s, no final result")
                }
            }
        }

        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        return .result(value: "spike OK — t=\(elapsed)ms transcript=\"\(transcript)\"")
    }

    private static func requestSpeechAuth() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }
}
