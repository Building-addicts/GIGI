import Foundation
import AVFoundation
import Accelerate
import Speech

// MARK: - GigiVADEngine
// Voice Activity Detection + Speech-to-Text.
//
// Pipeline:
//   1. AVAudioEngine cattura i buffer audio
//   2. Buffer → SFSpeechAudioBufferRecognitionRequest (STT parziale in live)
//   3. Buffer → analyzeAudio (silence detection, soglia dB adattiva)
//   4. Silenzio rilevato → stopAudioCapture() (fine feed audio, NON cancella il task STT)
//   5. SFSpeechRecognizer completa → isFinal=true → onTranscription?(text)
//
// Adaptive silence threshold (2.2.1):
//   0–2 parole → 0.8s   (comandi rapidi: "torcia on")
//   3–8 parole → 1.2s   (comandi medi)
//   9+ parole  → 1.8s   (dettatura lunga)
//   +0.5s se ultima parola è congiunzione/connettivo → protegge pause di riflessione
//
// Noise gate: silence timer si azzera solo dopo ≥100 ms di audio continuo —
//   evita reset da picchi brevi (porta, colpo, tosse).

class GigiVADEngine {
    static let shared = GigiVADEngine()

    private let audioEngine          = AVAudioEngine()
    private var silenceDuration: TimeInterval       = 0
    private var consecutiveSpeechDuration: TimeInterval = 0  // noise gate accumulator
    private let silenceThreshold: Float             = -45.0
    private let noiseSpikeGate: TimeInterval        = 0.10   // ignore bursts shorter than 100 ms
    private var requiredSilence: TimeInterval       = 0.8    // updated dynamically by adaptive threshold
    private var lastWordCount: Int                  = 0      // debounce: skip recalc if count unchanged

    private var isCapturing          = false   // true durante la registrazione audio
    private var isWaitingForFinal    = false   // true dopo silence, aspetta isFinal
    private var hasSpeechStarted     = false   // true dopo prima burst di parlato confermata (≥100ms)

    // en-US fixed: market is US/English; Locale.current causes acoustic model mismatch
    private let speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest:  SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask:     SFSpeechRecognitionTask?
    private var latestTranscription  = ""

    // Callbacks
    var onSilenceDetected:  (() -> Void)?
    var onTranscription:    ((String) -> Void)?
    var onListeningFailed:  (() -> Void)?  // fired when STT returns error with empty transcript

    private init() {}

    // MARK: - Start

    func startListening() {
        GigiDebugLogger.log("GigiVADEngine.startListening")
        guard !isCapturing, !isWaitingForFinal else { 
            GigiDebugLogger.log("startListening aborted: isCapturing=\(isCapturing), isWaitingForFinal=\(isWaitingForFinal)")
            return 
        }

        let status = SFSpeechRecognizer.authorizationStatus()
        GigiDebugLogger.log("SFSpeechRecognizer auth status: \(status.rawValue)")

        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] newStatus in
                GigiDebugLogger.log("Auth callback: \(newStatus.rawValue)")
                DispatchQueue.main.async {
                    self?.beginCapture(speechEnabled: newStatus == .authorized)
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.beginCapture(speechEnabled: status == .authorized)
            }
        }
    }

    private func beginCapture(speechEnabled: Bool) {
        GigiDebugLogger.log("beginCapture: speechEnabled=\(speechEnabled)")
        guard !isCapturing, !isWaitingForFinal else { 
            GigiDebugLogger.log("beginCapture aborted: isCapturing=\(isCapturing), isWaitingForFinal=\(isWaitingForFinal)")
            return 
        }
        isCapturing                 = true
        hasSpeechStarted            = false
        latestTranscription         = ""
        silenceDuration             = 0
        consecutiveSpeechDuration   = 0
        lastWordCount               = 0
        requiredSilence             = 0.8   // start fast; grows as partials arrive

        GigiDebugLogger.log("seizeControl in VAD")
        GigiAudioSequestrator.shared.seizeControl()

        // Setup STT
        if speechEnabled, let recognizer = speechRecognizer, recognizer.isAvailable {
            GigiDebugLogger.log("Setting up SFSpeechAudioBufferRecognitionRequest")
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            recognitionRequest = req

            recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    self?.handleSTTResult(result: result, error: error)
                }
            }
            GigiDebugLogger.log("recognitionTask created")
        }

        // Reset stale hardware format — required after audio session deactivation/reactivation.
        // Without this, AVAudioEngine caches a 0 Hz format and crashes on installTap.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()

        let inputNode = audioEngine.inputNode

        inputNode.removeTap(onBus: 0)

        // Use nil format: AVAudioEngine uses the hardware's actual native format at tap time.
        // Reading outputFormat(forBus:) after reset() returns stale data → NSException crash.
        GigiDebugLogger.log("installTap")
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, self.isCapturing else { return }
            self.recognitionRequest?.append(buffer)
            self.analyzeAudio(buffer: buffer)
        }

        do {
            GigiDebugLogger.log("audioEngine.prepare()")
            audioEngine.prepare()
            GigiDebugLogger.log("audioEngine.start()")
            try audioEngine.start()
            GigiDebugLogger.log("GIGI VAD: started (STT \(speechEnabled ? "active" : "unauthorized — VAD only"))")
            GigiDebugLogger.log("VAD started successfully")
        } catch {
            GigiDebugLogger.log("GIGI VAD: AudioEngine error — \(error.localizedDescription)")
            GigiDebugLogger.log("audioEngine start error: \(error.localizedDescription)")
            isCapturing = false
            inputNode.removeTap(onBus: 0)
            cleanupSTT()
            GigiAudioSequestrator.shared.releaseControl()
            onListeningFailed?()
        }
    }

    // MARK: - STT result handler

    private func handleSTTResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            latestTranscription = result.bestTranscription.formattedString
            GigiDebugLogger.log("GIGI STT partial: '\(latestTranscription)'")
            updateSilenceThreshold(for: latestTranscription)

            if result.isFinal {
                GigiDebugLogger.log("GIGI STT final: '\(latestTranscription)'")
                let text = latestTranscription
                isWaitingForFinal = false
                cleanupSTT()
                if !text.isEmpty {
                    onTranscription?(text)
                } else {
                    onListeningFailed?()
                }
            }
        } else if let error {
            GigiDebugLogger.log("GIGI STT error: \(error.localizedDescription)")
            let text = latestTranscription
            isWaitingForFinal = false
            cleanupSTT()
            if !text.isEmpty {
                onTranscription?(text)
            } else {
                // No speech — notify orchestrator so it can release audio and reset state.
                onListeningFailed?()
            }
        }
    }

    // MARK: - Stop audio capture (on silence — keep STT task alive to get isFinal)

    private func stopAudioCapture() {
        guard isCapturing else { return }
        isCapturing = false

        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()  // clear stale format for next session

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        silenceDuration             = 0
        consecutiveSpeechDuration   = 0
        lastWordCount               = 0
        GigiAudioSequestrator.shared.releaseControl()
        GigiDebugLogger.log("GIGI VAD: audio capture stopped — waiting for STT final")
    }

    // MARK: - Full stop

    func stopListening() {
        // Only release if we're actively capturing — stopAudioCapture() already released on silence.
        let shouldRelease = isCapturing
        isCapturing       = false
        isWaitingForFinal = false
        hasSpeechStarted  = false
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()  // clear stale format for next session
        cleanupSTT()
        silenceDuration             = 0
        consecutiveSpeechDuration   = 0
        lastWordCount               = 0
        requiredSilence             = 0.8
        if shouldRelease {
            GigiAudioSequestrator.shared.releaseControl()
        }
        GigiDebugLogger.log("GIGI VAD: stopped")
    }

    private func cleanupSTT() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask    = nil
    }

    // MARK: - Audio analysis (VAD)

    private func analyzeAudio(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, buffer.frameCapacity > 0,
              buffer.audioBufferList.pointee.mBuffers.mDataByteSize > 0 else { return }
        let array = Array(UnsafeBufferPointer(start: channelData, count: frames))

        var rms: Float = 0
        vDSP_rmsqv(array, 1, &rms, vDSP_Length(frames))
        let db        = rms > 0 ? 20 * log10(rms) : -100.0
        let frameDuration = Double(frames) / buffer.format.sampleRate

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing else { return }

            if db >= self.silenceThreshold {
                // SPEECH: accumulate consecutive speech; once ≥ noise gate, confirm real speech
                // and reset silence timer. Short spikes (door, cough < 100ms) don't reset.
                self.consecutiveSpeechDuration += frameDuration
                if self.consecutiveSpeechDuration >= self.noiseSpikeGate {
                    self.hasSpeechStarted = true
                    self.silenceDuration  = 0
                }
            } else {
                // SILENCE: accumulate only after real speech has been confirmed.
                // Without hasSpeechStarted, a quiet room fires VAD immediately at launch.
                self.consecutiveSpeechDuration = 0
                if self.hasSpeechStarted {
                    self.silenceDuration += frameDuration
                }
            }

            if self.hasSpeechStarted, self.silenceDuration >= self.requiredSilence {
                GigiDebugLogger.log("GIGI VAD: silence (\(String(format: "%.1f", db)) dB, req \(String(format: "%.1f", self.requiredSilence))s) — '\(self.latestTranscription)'")
                self.isWaitingForFinal = true
                self.stopAudioCapture()
                self.onSilenceDetected?()

                // Fallback: if STT doesn't respond within 3s, use current transcript
                let snapshot = self.latestTranscription
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self, self.isWaitingForFinal else { return }
                    GigiDebugLogger.log("GIGI VAD: STT timeout — using snapshot: '\(snapshot)'")
                    self.isWaitingForFinal = false
                    self.cleanupSTT()
                    if !snapshot.isEmpty {
                        self.onTranscription?(snapshot)
                    } else {
                        self.onListeningFailed?()
                    }
                }
            }
        }
    }

    // MARK: - Adaptive silence threshold (2.2.1)

    /// Recalculates `requiredSilence` from a partial transcript.
    /// Called on every new partial — debounced to word boundaries.
    private func updateSilenceThreshold(for partial: String) {
        let words = partial.split(separator: " ").filter { !$0.isEmpty }
        let count = words.count

        // Debounce: skip if word count hasn't changed
        guard count != lastWordCount else { return }
        lastWordCount = count

        requiredSilence = adaptiveSilenceThreshold(for: partial)
        GigiDebugLogger.log("GIGI VAD: threshold → \(String(format: "%.1f", requiredSilence))s (\(count) words)")
    }

    func adaptiveSilenceThreshold(for partial: String) -> TimeInterval {
        let words = partial.split(separator: " ").filter { !$0.isEmpty }
        let count = words.count

        let base: TimeInterval
        switch count {
        case 0...2:  base = 0.8
        case 3...8:  base = 1.2
        default:     base = 1.8
        }

        // Extend timeout if last word is a connective — user likely mid-thought
        let connectiveExtension: TimeInterval = lastWordIsConnective(words) ? 0.5 : 0.0
        return base + connectiveExtension
    }

    private func lastWordIsConnective(_ words: [Substring]) -> Bool {
        guard let last = words.last else { return false }
        let w = last.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let connectives: Set<String> = [
            // Italian
            "e", "ed", "ma", "però", "quindi", "perché", "perche", "che",
            "con", "per", "di", "a", "da", "in", "su", "tra", "fra",
            "o", "oppure", "anche", "poi", "quando", "se", "mentre",
            // English
            "and", "but", "or", "so", "yet", "for", "nor",
            "with", "because", "then", "when", "while", "also",
            "plus", "after", "before", "if", "although", "unless",
        ]
        return connectives.contains(w)
    }
}
