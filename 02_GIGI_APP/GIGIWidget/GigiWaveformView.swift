import SwiftUI

// MARK: - GigiWaveformView
//
// Audio-reactive waveform for the Dynamic Island `.listening` phase. Five
// vertical bars whose heights track the rolling input level 0.0–1.0
// supplied via `GigiActivityAttributes.ContentState.audioLevel`.
//
// When `audioLevel` is nil (idle / pre-capture), bars fall back to a
// gentle synchronized pulse so the pill never looks frozen.
//
// The view targets the Live Activity render budget (~16 ms / refresh).
// Bars are pure shapes with implicit animations; no timers, no Combine.

struct GigiWaveformView: View {

    /// Latest mic input level (0.0–1.0). nil = idle.
    let audioLevel: Float?

    /// Tint of the bars. Defaults to white (DI dark background).
    var tint: Color = .white

    /// Bar count. Odd values look more centered. Default 5.
    var barCount: Int = 5

    /// Total view height in points. Bars max out at this value.
    var maxHeight: CGFloat = 22

    /// Width of each bar.
    var barWidth: CGFloat = 3

    /// Gap between bars.
    var spacing: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: barWidth, height: barHeight(at: i))
                    .opacity(barOpacity(at: i))
                    .animation(.easeInOut(duration: 0.18), value: audioLevel)
            }
        }
        .frame(height: maxHeight)
        .accessibilityHidden(true)
    }

    // MARK: - Bar height computation

    private func barHeight(at index: Int) -> CGFloat {
        let baseFraction = idleFraction(at: index)
        guard let level = audioLevel else {
            return clamp(maxHeight * baseFraction)
        }
        // Distribute level across bars with a center-heavy curve so the
        // middle bar is most reactive (Apple's Siri-style profile).
        let centered = abs(Double(index) - Double(barCount - 1) / 2.0)
        let positionFalloff = 1.0 - (centered / Double(barCount)) * 0.55
        let dynamic = CGFloat(min(1.0, max(0.0, Double(level)))) * positionFalloff
        // Blend a small idle component so quiet moments still show life.
        let h = (baseFraction * 0.35) + (dynamic * 0.85)
        return clamp(maxHeight * h)
    }

    private func barOpacity(at index: Int) -> Double {
        // Edge bars slightly dimmer than the centre to draw the eye in.
        let centered = abs(Double(index) - Double(barCount - 1) / 2.0)
        return max(0.55, 1.0 - centered * 0.12)
    }

    private func idleFraction(at index: Int) -> CGFloat {
        // Static idle skyline so when nil we still get a pleasing shape
        // instead of all-equal bars. Uses the bar's index parity to vary.
        let pattern: [CGFloat] = [0.30, 0.55, 0.78, 0.55, 0.30,
                                  0.42, 0.66, 0.42, 0.30, 0.55]
        return pattern[index % pattern.count]
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        max(maxHeight * 0.18, min(maxHeight, value))
    }
}

// MARK: - Previews

#Preview("Idle (audioLevel = nil)", traits: .sizeThatFitsLayout) {
    GigiWaveformView(audioLevel: nil)
        .padding()
        .background(Color.black)
}

#Preview("Quiet (0.15)", traits: .sizeThatFitsLayout) {
    GigiWaveformView(audioLevel: 0.15)
        .padding()
        .background(Color.black)
}

#Preview("Loud (0.85)", traits: .sizeThatFitsLayout) {
    GigiWaveformView(audioLevel: 0.85)
        .padding()
        .background(Color.black)
}

#Preview("Compact (size 14)", traits: .sizeThatFitsLayout) {
    GigiWaveformView(audioLevel: 0.6, maxHeight: 14, barWidth: 2, spacing: 2)
        .padding()
        .background(Color.black)
}
