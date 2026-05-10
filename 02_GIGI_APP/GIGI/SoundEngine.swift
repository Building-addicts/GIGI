import AVFoundation
import UIKit

// MARK: - EarconEvent

enum EarconEvent {
    case wakeWord        // ascending sweep 440→880 Hz, 120 ms — "I heard you"
    case taskDone        // C4+E4 double blip, 200 ms — "done"
    case error           // descending sweep 880→440 Hz, 180 ms — "something went wrong"
    case thinking        // haptic-only (no audio) — battery efficient, non-irritating
    case confirmRequired // trill 440/660 Hz, 300 ms — "needs your approval"
}

// MARK: - SoundEngine

@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    private let engine     = AVAudioEngine()
    private let player     = AVAudioPlayerNode()
    private let sampleRate: Double = 44100
    private var buffers:    [String: AVAudioPCMBuffer] = [:]
    private var engineRunning = false

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        precomputeAllBuffers(format: format)
    }

    // MARK: - Public API

    static func play(_ event: EarconEvent) {
        Task { @MainActor in shared.fire(event) }
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Call when GIGI returns to idle — ensures no other app stays ducked.
    /// Was guarded against wake word monitoring (causing restart loop) — wake word
    /// disconnected to _legacy/ (ADR-0003), guard removed.
    static func releaseSession() {
        // Don't deactivate in background — iOS starts 30s kill timer if audio session goes inactive
        // while app is backgrounded.
        guard UIApplication.shared.applicationState == .active else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Internal

    private func fire(_ event: EarconEvent) {
        // thinking = haptic only — keeping audio engine idle saves CPU/battery
        if event == .thinking {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        let hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch event {
        case .wakeWord:        hapticStyle = .light
        case .taskDone:        hapticStyle = .soft    // subtle — "premium" feel on US market
        case .error:           hapticStyle = .light   // not rigid — avoids "crash" sensation
        case .confirmRequired: hapticStyle = .soft
        case .thinking:        hapticStyle = .light
        }

        // Haptic fires immediately; audio follows 50 ms later for perceptual sync
        UIImpactFeedbackGenerator(style: hapticStyle).impactOccurred()

        guard let buffer = buffers[key(event)] else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self.schedulePlay(buffer)
        }
    }

    private func schedulePlay(_ buffer: AVAudioPCMBuffer) {
        // Do NOT change the AVAudioSession category here — GigiAudioSequestrator owns it.
        // Switching to .ambient mid-flight corrupts the .playAndRecord session and causes
        // "player did not see an IO cycle" crash on the very next play() call.

        if !engineRunning {
            do {
                try engine.start()
                engineRunning = true
            } catch {
                print("SoundEngine: engine start failed — \(error)")
                return
            }
            // Must wait ≥1 IO cycle (≈23 ms at 44100/1024) before calling player.play().
            // Calling play() immediately after engine.start() crashes: "player did not see an IO cycle".
            let capturedBuffer = buffer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.030) { [weak self] in
                guard let self, self.engineRunning else { return }
                self.player.scheduleBuffer(capturedBuffer, at: nil, options: []) { [weak self] in
                    Task { @MainActor [weak self] in self?.didFinishPlaying() }
                }
                self.player.play()
            }
            return
        }

        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in self?.didFinishPlaying() }
        }
        player.play()
    }

    private func didFinishPlaying() {
        engine.pause()
        engineRunning = false
        // Skip deactivation when GigiAudioSequestrator already owns the session (TTS playing,
        // mic active). Calling setActive(false) here would kill the concurrent session.
        // Example race: confirmRequired earcon (~380ms) overlaps TTS didStart (~100ms).
        guard !GigiAudioSequestrator.shared.isSessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Key helpers

    private func key(_ event: EarconEvent) -> String { "\(event)" }

    // MARK: - Buffer synthesis (all pre-computed at init)

    private func precomputeAllBuffers(format: AVAudioFormat) {
        buffers[key(.wakeWord)]        = makeSweep(from: 440, to: 880, duration: 0.120, format: format)
        buffers[key(.taskDone)]        = makeDoubleBlip(f1: 261.63, f2: 329.63, blip: 0.090, gap: 0.020, format: format)
        buffers[key(.error)]           = makeSweep(from: 880, to: 440, duration: 0.180, format: format)
        buffers[key(.confirmRequired)] = makeTrill(f1: 440, f2: 660, duration: 0.300, segLen: 0.050, format: format)
    }

    /// Exponential frequency sweep with 10 ms fade in/out.
    private func makeSweep(from startHz: Double, to endHz: Double, duration: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let data = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frameCount

        var phase = 0.0
        let fadeFrames = 0.010 * sampleRate
        let total = Double(frameCount)

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            // Exponential sweep: f(t) = start * (end/start)^(t/T)
            let freq = startHz * pow(endHz / startHz, t / duration)
            let fi = Double(i)
            let amp = envLinear(fi, total: total, fadeFrames: fadeFrames)
            phase += 2 * .pi * freq / sampleRate
            data[i] = Float(sin(phase) * amp * 0.5)
        }
        return buf
    }

    /// Two pure tones separated by silence.
    private func makeDoubleBlip(f1: Double, f2: Double, blip: Double, gap: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let blipF = Int(sampleRate * blip)
        let gapF  = Int(sampleRate * gap)
        let total = AVAudioFrameCount(blipF * 2 + gapF)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let data = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = total

        let fadeFrames = 0.010 * sampleRate
        writeTone(into: data, offset: 0,           freq: f1, count: blipF, sampleRate: sampleRate, fadeFrames: fadeFrames)
        // gap region is already zero (PCM buffer is zero-initialised by iOS)
        writeTone(into: data, offset: blipF + gapF, freq: f2, count: blipF, sampleRate: sampleRate, fadeFrames: fadeFrames)
        return buf
    }

    /// Alternating tones — each segment has its own micro-fade.
    private func makeTrill(f1: Double, f2: Double, duration: Double, segLen: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let totalFrames = AVAudioFrameCount(sampleRate * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let data = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = totalFrames

        let segFrames  = Int(sampleRate * segLen)
        let fadeFrames = min(0.008 * sampleRate, Double(segFrames) * 0.2)
        var phase = 0.0

        for i in 0..<Int(totalFrames) {
            let segIdx  = i / segFrames
            let posInSeg = i % segFrames
            let freq    = segIdx % 2 == 0 ? f1 : f2
            let amp     = envLinear(Double(posInSeg), total: Double(segFrames), fadeFrames: fadeFrames)
            phase += 2 * .pi * freq / sampleRate
            data[i] = Float(sin(phase) * amp * 0.45)
        }
        return buf
    }

    // MARK: - Helpers

    private func writeTone(into data: UnsafeMutablePointer<Float>, offset: Int, freq: Double, count: Int, sampleRate: Double, fadeFrames: Double) {
        var phase = 0.0
        for j in 0..<count {
            let amp = envLinear(Double(j), total: Double(count), fadeFrames: fadeFrames)
            phase += 2 * .pi * freq / sampleRate
            data[offset + j] = Float(sin(phase) * amp * 0.5)
        }
    }

    /// Linear fade-in for first `fadeFrames` samples, fade-out for last `fadeFrames`.
    private func envLinear(_ i: Double, total: Double, fadeFrames: Double) -> Double {
        if i < fadeFrames           { return i / fadeFrames }
        if i > total - fadeFrames   { return (total - i) / fadeFrames }
        return 1.0
    }
}
