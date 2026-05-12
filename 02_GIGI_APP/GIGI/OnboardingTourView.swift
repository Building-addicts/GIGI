import SwiftUI

// MARK: - OnboardingTourView (GATE 9.D — Discovery Layer A)
//
// Three-step conversational mini-tour shown to new users at first launch
// AFTER permissions + pairing (handled by `OnboardingView`). Designed to
// feel like GIGI speaking, not a typical "wizard" — purple bullet anchor,
// chat-bubble styling, ≤ 60 seconds total walkthrough.
//
// All copy in English (CLAUDE.md §Lingua hard rule). User input that
// triggers GIGI capabilities can be in any language (Apple FM is bilingual)
// but GIGI always responds in English.

struct OnboardingTourView: View {

    @ObservedObject private var flow = GigiOnboardingFlow.shared

    var body: some View {
        ZStack {
            // Dark backdrop matching the chat aesthetic.
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 60)

                // Header — GIGI logo + step indicator
                VStack(spacing: 8) {
                    Text("GIGI")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Quick tour · Step \(flow.currentStep + 1) of \(flow.totalSteps)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.top, 20)

                Spacer(minLength: 20)

                // Active step content (chat bubble style)
                stepContent
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(flow.currentStep)

                Spacer()

                // Footer buttons
                HStack(spacing: 16) {
                    Button(role: .cancel) {
                        flow.skip()
                    } label: {
                        Text("Skip")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            flow.advance()
                        }
                    } label: {
                        Text(flow.currentStep == flow.totalSteps - 1 ? "Got it" : "Next")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(Color.purple)
                            .cornerRadius(22)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch flow.currentStep {
        case 0: stepIntro
        case 1: stepTry
        case 2: stepEnumerate
        default: EmptyView()
        }
    }

    /// Step 0 — Welcome + first example prompt.
    private var stepIntro: some View {
        chatBubble(
            title: "Hi, I'm GIGI",
            body: "I'm your on-device voice assistant. Try saying or typing things like:",
            examples: [
                "Set a timer for 5 minutes",
                "What's the weather today?",
                "Call mom"
            ]
        )
    }

    /// Step 1 — Show breadth of capabilities by category.
    private var stepTry: some View {
        chatBubble(
            title: "What I can do",
            body: "I can help across seven areas — just ask in plain language:",
            examples: [
                "📅 Calendar — create events, find free slots",
                "🏠 Smart home — turn on lights, activate scenes",
                "💬 Messages — send WhatsApp, call, FaceTime",
                "🎵 Media — play music, podcasts",
                "🌐 Web — search, get directions, navigate"
            ]
        )
    }

    /// Step 2 — Discovery affordance + setup wrap-up.
    private var stepEnumerate: some View {
        chatBubble(
            title: "Discover anytime",
            body: "Not sure what to ask? Just say 'what can you do?' or 'how do I ...?' and I'll suggest something relevant. Let's go!",
            examples: nil
        )
    }

    // MARK: - Reusable chat bubble

    private func chatBubble(title: String, body: String, examples: [String]?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.purple)
                .frame(width: 8, height: 8)
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Text(body)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)

                if let examples = examples {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(examples, id: \.self) { example in
                            HStack(spacing: 8) {
                                Text("›")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.purple.opacity(0.8))
                                Text(example)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.purple.opacity(0.25), lineWidth: 1)
            )
            .cornerRadius(14)

            Spacer(minLength: 0)
        }
    }
}

#Preview {
    OnboardingTourView()
        .preferredColorScheme(.dark)
}
