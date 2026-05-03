import SwiftUI

/// Audio-reactive waveform shown in Dynamic Island during the .listening phase.
/// 5 vertical bars whose height tracks the latest mic amplitude (0–1). When
/// amplitude is nil the bars idle in a slow pulse so the DI never looks frozen.
/// Sub #145 — wired by GigiLiveActivityController.updateAudioLevel().
struct GigiWaveformView: View {
    let audioLevel: Float?
    var tint: Color = .white

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 18

    @State private var idlePhase: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: barWidth, height: barHeight(at: i))
                    .animation(.easeInOut(duration: 0.1), value: audioLevel)
            }
        }
        .frame(height: maxHeight)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                idlePhase = 1
            }
        }
    }

    private func barHeight(at index: Int) -> CGFloat {
        guard let level = audioLevel else {
            // Idle: gentle symmetric pulse around the middle bar.
            let center = Double(barCount - 1) / 2
            let offset = abs(Double(index) - center) / center
            let amp = 0.4 + 0.4 * (1 - offset) * idlePhase
            return minHeight + (maxHeight - minHeight) * CGFloat(amp)
        }
        // Active: each bar slightly offset so the waveform looks alive even
        // on a near-constant amplitude. Center bar tracks the raw level.
        let center = Double(barCount - 1) / 2
        let bias = 1.0 - abs(Double(index) - center) / center * 0.3
        let scaled = max(0.0, min(1.0, Double(level) * bias))
        return minHeight + (maxHeight - minHeight) * CGFloat(scaled)
    }
}
