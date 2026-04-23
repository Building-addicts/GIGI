import SwiftUI

struct ChatView: View {

    @StateObject private var gigi    = GigiSmartOrchestrator.shared
    @StateObject private var memory  = GigiConversationMemory.shared
    @State private var userInput     = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Header ────────────────────────────────────────────────────
                headerView
                    .padding(.top, 56)
                    .padding(.bottom, 8)

                // ── Conversation history ──────────────────────────────────────
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {

                            if memory.messages.isEmpty {
                                emptyStateView
                                    .padding(.top, 60)
                            }

                            ForEach(memory.messages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .onAppear { scrollProxy = proxy }
                    .onChange(of: memory.messages.count) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                }

                Divider().background(Color.white.opacity(0.08))

                // ── Input bar ─────────────────────────────────────────────────
                inputBar
                    .padding(.bottom, 24)
            }

            // ── Action banner (top pill) ──────────────────────────────────────
            if !gigi.bannerMessage.isEmpty {
                bannerView
                    .padding(.top, 56)
                    .zIndex(99)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: gigi.bannerMessage)
        .animation(.easeInOut(duration: 0.2), value: memory.messages.count)
    }

    // MARK: - Sub-views

    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("GIGI")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(gigi.status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }
            Spacer()
            // Brain indicator
            HStack(spacing: 6) {
                if GigiFoundationAgent.isSupported {
                    Image(systemName: "apple.intelligence")
                        .font(.system(size: 13))
                        .foregroundStyle(.purple)
                    Text("Apple Intelligence")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.purple.opacity(0.8))
                } else {
                    Image(systemName: "brain")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("Local AI")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(GigiFoundationAgent.isSupported ? Color.purple.opacity(0.12) : Color.white.opacity(0.05))
            .clipShape(Capsule())
            // Clear conversation
            if !memory.messages.isEmpty {
                Button {
                    memory.clear()
                    GigiFoundationSession.shared.resetContext()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 20)
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.purple.opacity(0.06 - Double(i) * 0.015))
                        .frame(width: CGFloat(90 + i * 28))
                }
                Image(systemName: "mic.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.purple.opacity(0.6))
            }
            VStack(spacing: 6) {
                Text("Hey, I'm GIGI.")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                Text("Tap the mic or type to get started.")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var inputBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Text field
                TextField("Message GIGI...", text: $userInput)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(22)
                    .onSubmit { sendText() }

                // Send button
                if !userInput.isEmpty {
                    Button(action: sendText) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundColor(.purple)
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                // Mic button
                Button {
                    if gigi.isListening {
                        gigi.stopListening()
                    } else {
                        gigi.startListening()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(gigi.isListening ? Color.purple : Color.white.opacity(0.1))
                            .frame(width: 46, height: 46)
                            .scaleEffect(gigi.isListening ? pulseScale : 1.0)
                            .animation(
                                gigi.isListening
                                    ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                    : .default,
                                value: pulseScale
                            )
                        Image(systemName: gigi.isListening ? "waveform" : "mic.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                .onChange(of: gigi.isListening) { _, listening in
                    pulseScale = listening ? 1.12 : 1.0
                }
            }
            .padding(.horizontal, 16)
            .animation(.easeInOut(duration: 0.15), value: userInput.isEmpty)

            // Thinking indicator
            if gigi.isThinking {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(.purple)
                    Text("GIGI is thinking...")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.purple.opacity(0.7))
                }
                .transition(.opacity)
            }
        }
        .padding(.top, 10)
    }

    private var bannerView: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView().tint(.white).scaleEffect(0.7)
                Text(gigi.bannerMessage)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            Spacer()
        }
    }

    // MARK: - Actions

    private func sendText() {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        userInput = ""
        Task { await gigi.process(text: text) }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let last = memory.messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

// MARK: - MessageBubble

private struct MessageBubble: View {
    let message: GigiMessage

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 48) }

            if !isUser {
                // GIGI avatar dot
                Circle()
                    .fill(Color.purple)
                    .frame(width: 6, height: 6)
                    .padding(.bottom, 8)
            }

            Group {
                if message.isThinking {
                    thinkingBubble
                } else {
                    Text(message.text)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundColor(isUser ? .black : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(isUser ? Color.white : Color.white.opacity(0.1))
                        .clipShape(BubbleShape(isUser: isUser))
                }
            }

            if !isUser { Spacer(minLength: 48) }
        }
    }

    private var thinkingBubble: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever()
                            .delay(Double(i) * 0.13),
                        value: message.isThinking
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.1))
        .clipShape(BubbleShape(isUser: false))
    }
}

// MARK: - Bubble shape (rounded, with tail)

private struct BubbleShape: Shape {
    let isUser: Bool
    let radius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let tailR: CGFloat = 5
        var path = Path()

        if isUser {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        } else {
            // Same for GIGI for now — can add tail later
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}
