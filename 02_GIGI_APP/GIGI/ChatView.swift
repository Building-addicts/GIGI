import SwiftUI

struct ChatView: View {
    /// `itms-services://…` per installazione OTA da killsiri.xyz
    private static var otaManifestItmsURL: URL {
        let manifest = "https://killsiri.xyz/deploy/manifest.plist"
        let enc = manifest.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? manifest
        return URL(string: "itms-services://?action=download-manifest&url=\(enc)")!
    }

    @StateObject var gigi = GigiSmartOrchestrator.shared
    @StateObject var dialogue = GigiDialogueEngine.shared
    @State private var userInput = ""
    @State private var animating = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Header ────────────────────────────────────────────────
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GIGI")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(gigi.status)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()

                    // Indicatore dialogo attivo
                    if dialogue.isInDialogue {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .scaleEffect(animating ? 1.3 : 1.0)
                                .animation(.easeInOut(duration: 0.6).repeatForever(), value: animating)
                            Text("Listening for reply")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 60)
                .padding(.bottom, 20)

                Spacer()

                // ── Area principale ────────────────────────────────────────
                if !gigi.lastResponse.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {

                        // Badge GIGI
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.purple)
                                .frame(width: 8, height: 8)
                            Text("GIGI")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.purple)
                        }

                        // Risposta principale
                        Text(gigi.lastResponse)
                            .font(.system(size: 17, weight: .regular, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        // Azioni eseguite (multiple)
                        if gigi.executedActions.count > 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(gigi.executedActions, id: \.self) { action in
                                    HStack(spacing: 8) {
                                        Image(systemName: iconForAction(action))
                                            .font(.system(size: 12))
                                            .foregroundColor(.green)
                                            .frame(width: 16)
                                        Text(labelForAction(action))
                                            .font(.system(size: 13))
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }

                        // Prompt dialogo
                        if dialogue.isInDialogue && !dialogue.currentPrompt.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                                Text(dialogue.currentPrompt)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.orange)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(20)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(16)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                } else if gigi.isThinking {
                    // Stato thinking
                    VStack(spacing: 16) {
                        ZStack {
                            ForEach(0..<3) { i in
                                Circle()
                                    .fill(Color.purple.opacity(0.15 - Double(i) * 0.04))
                                    .frame(width: CGFloat(80 + i * 25), height: CGFloat(80 + i * 25))
                                    .scaleEffect(animating ? 1.1 : 0.95)
                                    .animation(
                                        .easeInOut(duration: 1.0 + Double(i) * 0.2)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(i) * 0.15),
                                        value: animating
                                    )
                            }
                            Image(systemName: "brain")
                                .font(.system(size: 28))
                                .foregroundColor(.purple)
                        }
                        Text("Understanding...")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                    }

                } else {
                    // Stato idle
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.purple.opacity(0.08))
                                .frame(width: 120, height: 120)
                                .scaleEffect(gigi.isListening ? pulseScale : 1.0)
                                .animation(
                                    gigi.isListening
                                        ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                        : .default,
                                    value: pulseScale
                                )
                            Circle()
                                .fill(Color.purple.opacity(0.12))
                                .frame(width: 80, height: 80)
                            Image(systemName: gigi.isListening ? "waveform" : "mic.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.purple)
                        }
                        Text(gigi.isListening ? "Listening..." : "Tap mic or type")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }

                Spacer()

                // ── Bottom controls ────────────────────────────────────────
                VStack(spacing: 14) {

                    // Mic button
                    Button {
                        if gigi.isListening {
                            gigi.stopListening()
                            animating = false
                            pulseScale = 1.0
                        } else {
                            gigi.startListening()
                            animating = true
                            pulseScale = 1.15
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(gigi.isListening ? Color.purple : Color.white.opacity(0.08))
                                .frame(width: 72, height: 72)
                                .overlay(
                                    Circle()
                                        .stroke(Color.purple.opacity(0.4), lineWidth: 1)
                                )
                            Image(systemName: gigi.isListening ? "stop.fill" : "mic.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.white)
                        }
                    }

                    // Text input
                    HStack(spacing: 10) {
                        TextField(
                            dialogue.isInDialogue ? dialogue.currentPrompt : "Ask GIGI anything...",
                            text: $userInput
                        )
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.07))
                        .cornerRadius(12)
                        .onSubmit { sendText() }

                        Button { sendText() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(userInput.isEmpty ? .white.opacity(0.15) : .purple)
                        }
                        .disabled(userInput.isEmpty)
                    }
                                       .padding(.horizontal, 24)

                    // OTA / MDM (killsiri.xyz) — Safari apre profilo e itms-services
                    VStack(spacing: 8) {
                        Text("Deploy")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.25))
                        HStack(spacing: 16) {
                            Link(destination: URL(string: "https://killsiri.xyz/profiles/gigi_access_pro.mobileconfig")!) {
                                Label("Profilo", systemImage: "arrow.down.doc")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.cyan.opacity(0.9))
                            }
                            Link(destination: Self.otaManifestItmsURL) {
                                Label("App OTA", systemImage: "app.badge.checkmark")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.green.opacity(0.9))
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear { animating = true }
        .animation(.easeInOut(duration: 0.3), value: gigi.lastResponse)
        .animation(.easeInOut(duration: 0.3), value: gigi.isThinking)
    }

    private func sendText() {
        guard !userInput.isEmpty else { return }
        let text = userInput
        userInput = ""
        Task { await gigi.process(text: text) }
    }

    private func iconForAction(_ action: String) -> String {
        let icons: [String: String] = [
            "create_event": "calendar.badge.plus",
            "set_alarm": "alarm.fill",
            "set_reminder": "bell.fill",
            "set_timer": "timer",
            "send_message": "message.fill",
            "make_call": "phone.fill",
            "navigation": "location.fill",
            "open_app": "app.fill",
            "play_music": "music.note",
            "torch_on": "flashlight.on.fill",
            "set_brightness_up": "sun.max.fill",
            "find_nearby": "mappin.circle.fill",
            "search_web": "magnifyingglass"
        ]
        return icons[action] ?? "checkmark.circle.fill"
    }

    private func labelForAction(_ action: String) -> String {
        let labels: [String: String] = [
            "create_event": "Event added to calendar",
            "set_alarm": "Alarm set",
            "set_reminder": "Reminder created",
            "set_timer": "Timer started",
            "send_message": "Message sent",
            "make_call": "Call placed",
            "navigation": "Navigation ready",
            "open_app": "App opened",
            "play_music": "Music playing",
            "torch_on": "Flashlight on",
            "set_brightness_up": "Brightness increased",
            "find_nearby": "Searching nearby",
            "search_web": "Web search opened"
        ]
        return labels[action] ?? action.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
