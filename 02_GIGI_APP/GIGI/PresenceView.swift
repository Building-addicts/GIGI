import SwiftUI

// MARK: - PresenceView
//
// In-app companion for Presence Mode. Shows session state, last transcript,
// and mute/stop controls. The Dynamic Island mirrors this state externally.

struct PresenceView: View {
    @ObservedObject private var controller = PresenceSessionController.shared
    @ObservedObject private var audioManager = GigiAudioManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // State orb
                stateOrb

                // State label
                Text(stateLabel)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .animation(.easeInOut, value: controller.state)

                // Last transcript
                if !controller.lastTranscript.isEmpty {
                    Text("\"\(controller.lastTranscript)\"")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .transition(.opacity)
                }

                // Duration
                Text(durationString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.25))

                Spacer()

                // Controls
                HStack(spacing: 40) {
                    muteButton
                    stopButton
                }
                .padding(.bottom, 48)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.state)
        .onChange(of: controller.state) { _, state in
            if state == .inactive { dismiss() }
        }
    }

    // MARK: - State Orb

    @ViewBuilder
    private var stateOrb: some View {
        let color = orbColor
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color.opacity(0.06 - Double(i) * 0.015))
                    .frame(width: CGFloat(90 + i * 28))
            }
            orbIcon
                .font(.system(size: 32))
                .foregroundColor(color)
        }
    }

    @ViewBuilder
    private var orbIcon: some View {
        switch controller.state {
        case .sleeping:
            Image(systemName: "moon.stars.fill")
        case .listening:
            Image(systemName: isFollowUpWindow ? "arrowshape.turn.up.left.circle.fill" : "waveform.circle.fill")
        case .thinking:
            Image(systemName: "brain")
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
        case .muted:
            Image(systemName: "mic.slash.fill")
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
        case .inactive:
            EmptyView()
        }
    }

    private var orbColor: Color {
        switch controller.state {
        case .sleeping:  return .white.opacity(0.3)
        case .listening: return .purple
        case .thinking:  return .blue
        case .speaking:  return .purple
        case .muted:     return .gray
        case .error:     return .red
        case .inactive:  return .clear
        }
    }

    // MARK: - Labels

    private var stateLabel: String {
        switch controller.state {
        case .inactive: return ""
        case .sleeping: return "Ready"
        case .listening: return isFollowUpWindow ? "Follow-up" : "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .muted: return "Muted"
        case .error: return "Needs Attention"
        }
    }

    private var isFollowUpWindow: Bool {
        controller.state == .listening &&
        audioManager.state == .recording &&
        !controller.lastTranscript.isEmpty
    }

    private var durationString: String {
        let s = Int(controller.sessionDuration)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Controls

    private var muteButton: some View {
        Button {
            if controller.state == .muted {
                controller.unmute()
            } else {
                controller.mute()
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: controller.state == .muted ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 24))
                    .foregroundColor(controller.state == .muted ? .purple : .white.opacity(0.6))
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
                Text(controller.state == .muted ? "Unmute" : "Mute")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    private var stopButton: some View {
        Button {
            controller.stopSession()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
                Text("Stop")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }
}
