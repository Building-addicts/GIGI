import SwiftUI

struct ChatView: View {

    @StateObject private var gigi        = GigiSmartOrchestrator.shared
    @StateObject private var memory      = GigiConversationMemory.shared
    @StateObject private var quickTalk   = QuickTalkController.shared
    @ObservedObject private var presence = PresenceSessionController.shared
    @State private var userInput         = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var pulseScale: CGFloat = 1.0
    // showQuickTalk removed (2026-05-11): MainTabView auto-presents the sheet
    // on quickTalk.phase changes — no need for a second presentation point here.
    @State private var showPresence      = false
    @FocusState private var isInputFocused: Bool
    // Auto-redraw banner when override changes from Settings tab.
    @AppStorage("gigi.debug.brainPath") private var brainPathOverrideRaw: String = "auto"

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Header ────────────────────────────────────────────────────
                headerView
                    .padding(.top, 56)
                    .padding(.bottom, 8)

                // ── Brain Path Override banner ───────────────────────────────
                // When Brain Path Override ≠ Auto, the 5-path router is bypassed
                // and every query goes straight to one path. Without this banner
                // users (and demo viewers) cannot tell whether the router is
                // engaged, leading to silently passing all tests through Ollama
                // and misinterpreting hallucinations as router behavior.
                overrideBannerView

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
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture { isInputFocused = false }
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

            // ── Memory hint toast (#79) ──────────────────────────────────────
            VStack {
                MemoryHintView()
                    .padding(.top, 96)
                Spacer()
            }
            .zIndex(60)

            // Debug FABs removed (2026-05-11) — consolidated draft/voice-intercept
            // tests in Settings → Debug. ChatView UI now clean for demo testing.
        }
        .animation(.easeInOut(duration: 0.25), value: gigi.bannerMessage)
        .animation(.easeInOut(duration: 0.2), value: memory.messages.count)
        .sheet(isPresented: $gigi.showDraftPreview) {
            DraftMessagePreviewSheet()
        }
    }

    // MARK: - Sub-views

    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("GIGI")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(voiceStateLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }
            Spacer()
            // Brain indicator consolidated to Settings → Brain section.
            // Single dot here for at-a-glance status (purple if Apple FM available, else gray).
            Circle()
                .fill(GigiFoundationAgent.isSupported ? Color.purple : Color.white.opacity(0.25))
                .frame(width: 8, height: 8)
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

    // Bound via @AppStorage so the banner auto-redraws when Settings changes the override.
    // Returns nil when override is .auto (banner hidden).
    private var activeOverrideLabel: String? {
        switch brainPathOverrideRaw {
        case "appleFM": return "APPLE FM"
        case "ollama":  return "OLLAMA (Path 3)"
        case "claude":  return "CLAUDE CODE (Path 4)"
        default:        return nil
        }
    }

    @ViewBuilder
    private var overrideBannerView: some View {
        if let label = activeOverrideLabel {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("OVERRIDE: \(label) · router bypassed")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                Text("Settings → Auto")
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundColor(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.yellow)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
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
                    .focused($isInputFocused)
                    .submitLabel(.send)
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
                    if presence.isActive {
                        showPresence = true
                    } else if gigi.isListening {
                        gigi.stopListening()
                    } else {
                        gigi.startListening()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(micButtonColor)
                            .frame(width: 46, height: 46)
                            .scaleEffect(gigi.isListening ? pulseScale : 1.0)
                            .animation(
                                gigi.isListening
                                    ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                    : .default,
                                value: pulseScale
                            )
                        Image(systemName: micButtonIcon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                .onChange(of: gigi.isListening) { _, listening in
                    pulseScale = listening ? 1.12 : 1.0
                }

                // Quick Talk button — MainTabView auto-presents the sheet
                // when quickTalk.phase becomes active.
                Button {
                    quickTalk.start()
                } label: {
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.purple.opacity(0.7))
                }
                .disabled(quickTalk.phase.isActive || gigi.isListening || presence.isActive)
                .opacity(presence.isActive ? 0.35 : 1.0)
            }
            .padding(.horizontal, 16)
            .animation(.easeInOut(duration: 0.15), value: userInput.isEmpty)
            .sheet(isPresented: $showPresence) {
                PresenceView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.black)
            }

            // Thinking indicator
            if gigi.isThinking {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(.purple)
                    Text("Thinking")
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

    private var voiceStateLabel: String {
        if presence.isActive {
            return "Presence: \(presenceStateLabel)"
        }
        if quickTalk.phase.isActive {
            return "QuickTalk: \(quickTalk.phase.displayName)"
        }
        if gigi.isListening { return "Listening" }
        if gigi.isThinking { return "Thinking" }
        return "Ready"
    }

    private var presenceStateLabel: String {
        switch presence.state {
        case .inactive: return "Ready"
        case .sleeping: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .muted: return "Muted"
        case .error: return "Needs Attention"
        }
    }

    private var micButtonIcon: String {
        if presence.isActive { return "person.wave.2.fill" }
        return gigi.isListening ? "waveform" : "mic.fill"
    }

    private var micButtonColor: Color {
        if presence.isActive { return .purple.opacity(0.7) }
        return gigi.isListening ? .purple : .white.opacity(0.1)
    }

    // MARK: - Actions

    private func sendText() {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        userInput = ""
        isInputFocused = false
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
        switch message.role {
        case .thinking:
            thoughtLine
        case .toolEvent:
            toolEventLine
        default:
            standardBubble
        }
    }

    private var standardBubble: some View {
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

    private var thoughtLine: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("💭")
                .font(.caption2)
            Text(message.text)
                .font(.caption2)
                .italic()
                .foregroundColor(.white.opacity(0.6))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    private var toolEventLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape.fill")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
            Text(message.text)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.55))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
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
