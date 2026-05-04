// MARK: - GigiTryItDebugRunner (#151)
//
// DEBUG ONLY — In-process replay of the Action Button → DI → Orchestrator
// flow that #143 ships through Shortcuts. Lets the dev validate the
// orchestrator + DI waveform without first rebuilding the Shortcut (#148).
//
// Remove after epic #143 closes — open a follow-up "Remove debug Try-It
// scaffolding" sub-issue at that time.

import AVFoundation
import Foundation
import Speech

@MainActor
final class GigiTryItDebugRunner: ObservableObject {
    static let shared = GigiTryItDebugRunner()
    private init() {}

    @Published var lastResult: String = ""
    @Published var lastError: String? = nil
    @Published var isRunning: Bool = false

    /// Runs the full flow: descend DI → capture 4s audio → transcribe →
    /// hit orchestrator → return marker / plain text → dismiss DI.
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        lastError = nil

        guard let key = GigiKeychain.load(forKey: GigiKeychain.Key.groqAPIKey), !key.isEmpty else {
            lastError = "Missing Groq API key. Open Settings → Orchestrator Keys."
            return
        }

        await GigiLiveActivityController.shared.beginListening()

        let transcript = await captureTranscript()
        guard !transcript.isEmpty else {
            lastError = "No speech captured."
            await GigiLiveActivityController.shared.endImmediately()
            return
        }

        await GigiLiveActivityController.shared.transitionToThinking(transcript: transcript)

        do {
            let answer = try await GigiCloudService.shared.ask(transcript)
            lastResult = answer
            await GigiLiveActivityController.shared.transitionToSpeaking(message: answer.prefix(80).description)
        } catch {
            lastError = "Orchestrator error: \(error.localizedDescription)"
        }

        try? await Task.sleep(nanoseconds: 800_000_000)
        await GigiLiveActivityController.shared.endImmediately()
    }

    private func captureTranscript() async -> String {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { return "" }

        let auth = await Self.authorizeSpeech()
        guard auth == .authorized else { return "" }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = false

        let engine = AVAudioEngine()
        let format = engine.inputNode.inputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            req.append(buf)
        }
        engine.prepare()
        try? engine.start()

        let transcript: String = await withCheckedContinuation { cont in
            var resumed = false
            let task = recognizer.recognitionTask(with: req) { result, _ in
                if let result, result.isFinal, !resumed {
                    resumed = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                task.finish()
                req.endAudio()
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                if !resumed {
                    resumed = true
                    cont.resume(returning: "")
                }
            }
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return transcript
    }

    private static func authorizeSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
    }
}
