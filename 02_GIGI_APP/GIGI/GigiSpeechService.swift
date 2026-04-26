import Foundation
import AVFoundation

// MARK: - SpeechTone
enum SpeechTone {
    case normal      // default Jarvis pace
    case urgent      // faster, for confirmations
    case calm        // slower, for emotional moments
    case excited     // slightly higher pitch
}

// MARK: - GigiSpeechService
// Single owner of AVSpeechSynthesizer. Supports adaptive TTS based on tone.
@MainActor
final class GigiSpeechService: NSObject {
    static let shared = GigiSpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Primary speak

    func speak(_ text: String, tone: SpeechTone = .normal) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice()
        utterance.volume = 1.0

        switch tone {
        case .normal:  utterance.rate = 0.52; utterance.pitchMultiplier = 1.0
        case .urgent:  utterance.rate = 0.58; utterance.pitchMultiplier = 1.0
        case .calm:    utterance.rate = 0.46; utterance.pitchMultiplier = 0.95
        case .excited: utterance.rate = 0.55; utterance.pitchMultiplier = 1.08
        }

        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    // MARK: - Voice selection (prefer enhanced/premium en-US)

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        // Query installed en-US voices at runtime; prefer premium > default > compact.
        // Avoids hardcoded bundle IDs (unreliable on iOS 16+) while keeping Siri neural
        // when available (quality == .premium on supported devices).
        let enUS = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        let ordered = enUS.sorted { lhs, rhs in
            func rank(_ v: AVSpeechSynthesisVoice) -> Int {
                switch v.quality {
                case .premium: return 0
                case .enhanced: return 1
                default: return 2
                }
            }
            return rank(lhs) < rank(rhs)
        }
        return ordered.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension GigiSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in GigiAudioManager.shared.notifySpeakingStarted() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in GigiAudioManager.shared.notifySpeakingFinished() }
    }
    // didCancel fires when stopSpeaking(at:) is called (barge-in, interruption, etc.).
    // Without this, state stays stuck at .speaking and wake word never resumes.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in GigiAudioManager.shared.notifySpeakingFinished() }
    }
}
