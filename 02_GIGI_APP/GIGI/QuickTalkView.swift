import SwiftUI

// MARK: - QuickTalkView
//
// Minimal overlay sheet for Quick Talk mode.
// Shows listening waveform → thinking dots → response text.

struct QuickTalkView: View {
    @ObservedObject private var controller = QuickTalkController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 14) {
                    phaseIndicator

                    Text(controller.phase.displayName)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                if !controller.transcript.isEmpty {
                    Text("\"\(controller.transcript)\"")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .transition(.opacity)
                }

                if !controller.response.isEmpty {
                    Text(controller.response)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer()

                stopButton
                    .padding(.bottom, 40)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controller.phase)
        .onChange(of: controller.phase) { _, phase in
            if phase == .idle { dismiss() }
        }
    }

    // MARK: - Phase Indicator

    @ViewBuilder
    private var phaseIndicator: some View {
        switch controller.phase {
        case .listening:
            WaveformView()
                .frame(width: 120, height: 60)
        case .thinking:
            ThinkingDotsView()
        case .speaking:
            SpeakingPulseView()
        case .error(let msg):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 36))
                    .foregroundColor(.red.opacity(0.7))
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        case .idle:
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.purple.opacity(0.7))
        }
    }

    // MARK: - Stop Button

    private var stopButton: some View {
        Button {
            controller.stop()
        } label: {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(.white.opacity(0.15))
        }
    }
}

// MARK: - Waveform Animation

private struct WaveformView: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.purple.opacity(0.8))
                    .frame(width: 5)
                    .scaleEffect(y: animating ? CGFloat.random(in: 0.4...1.4) : 0.5, anchor: .center)
                    .animation(
                        Animation.easeInOut(duration: Double.random(in: 0.3...0.6))
                            .repeatForever()
                            .delay(Double(i) * 0.05),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

// MARK: - Thinking Dots

private struct ThinkingDotsView: View {
    @State private var dotIndex = 0

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(dotIndex == i ? 0.9 : 0.25))
                    .frame(width: 10, height: 10)
                    .scaleEffect(dotIndex == i ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.25), value: dotIndex)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { t in
                dotIndex = (dotIndex + 1) % 3
            }
        }
    }
}

// MARK: - Speaking Pulse

private struct SpeakingPulseView: View {
    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(Color.purple.opacity(0.3))
            .frame(width: 64, height: 64)
            .overlay(
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.purple)
            )
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    scale = 1.15
                }
            }
    }
}
