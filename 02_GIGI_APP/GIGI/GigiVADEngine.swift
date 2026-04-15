import Foundation
import AVFoundation
import Accelerate

class GigiVADEngine {
    static let shared = GigiVADEngine()

    private let audioEngine = AVAudioEngine()
    private var silenceDuration: TimeInterval = 0
    private let silenceThreshold: Float = -45.0
    private let requiredSilence: TimeInterval = 0.6

    // FIX A: flag atomico per evitare doppio stop
    private var isListening = false

    var onSilenceDetected: (() -> Void)?

    func startListening() {
        // FIX A: non reinstallare tap se già attivo
        guard !isListening else { return }
        isListening = true

        GigiAudioSequestrator.shared.seizeControl()

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Pulizia preventiva sempre, prima di installare
        inputNode.removeTap(onBus: 0)

        // FIX A: [weak self] — nessun retain cycle, nessun buffer appeso
        inputNode.installTap(onBus: 0, bufferSize: 512, format: recordingFormat) { [weak self] buffer, _ in
            self?.analyzeAudio(buffer: buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            print("GIGI VAD: Ascolto avviato.")
        } catch {
            print("GIGI VAD: Errore AudioEngine: \(error.localizedDescription)")
            // FIX A: se start() fallisce, resetta il flag e pulisci
            isListening = false
            inputNode.removeTap(onBus: 0)
            GigiAudioSequestrator.shared.releaseControl()
        }
    }

    func stopListening() {
        // FIX A: guard isRunning — nessuna doppia chiamata, nessun crash
        guard audioEngine.isRunning else {
            isListening = false
            return
        }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        silenceDuration = 0
        isListening = false
        GigiAudioSequestrator.shared.releaseControl()
        print("GIGI VAD: Ascolto fermato, tap rimosso.")
    }

    private func analyzeAudio(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let channelDataArray = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))

        var rms: Float = 0
        vDSP_rmsqv(channelDataArray, 1, &rms, vDSP_Length(buffer.frameLength))

        let db = rms > 0 ? 20 * log10(rms) : -100.0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if db < self.silenceThreshold {
                self.silenceDuration += Double(buffer.frameLength) / buffer.format.sampleRate
            } else {
                self.silenceDuration = 0
            }

            if self.silenceDuration >= self.requiredSilence {
                print("GIGI VAD: Silenzio rilevato (\(String(format: "%.1f", db)) dB)")
                self.stopListening()
                self.onSilenceDetected?()
            }
        }
    }
}
