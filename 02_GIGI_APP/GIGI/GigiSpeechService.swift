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
    private var _isSpeaking = false

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
        // Priority: Siri neural > enhanced > default
        let candidates = [
            "com.apple.ttsbundle.siri_female_en-US_compact",
            "com.apple.ttsbundle.Samantha-premium",
            "com.apple.ttsbundle.Samantha-compact",
        ]
        for id in candidates {
            if let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        }
        return AVSpeechSynthesisVoice(language: "en-US")
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
}
