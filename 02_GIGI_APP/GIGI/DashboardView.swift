import AVFoundation
import Combine
import SwiftUI
import WebKit

// MARK: - DashboardView
// Status overview + quick setup actions. Replaces the old "AI Providers" layout
// which referenced dead Gemini/Google integrations.

struct DashboardView: View {
    @AppStorage(GigiWakeWordEngine.userDefaultsEnabledKey) private var wakeWordEnabled = false
    @State private var groqReady = false
    @State private var whatsappLinked = false
    @State private var profileScore: Int = 0   // 0-4 fields filled
    @State private var memoryCount = 0
    @State private var homeKitCount = 0
    @State private var showWhatsAppSheet = false
    @State private var showProfileSheet = false
    @State private var showGuidedSetup = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    headerRow
                        .padding(.top, 56)

                    // ── Setup status cards ─────────────────────────
                    SectionHeader(title: "Setup")

                    setupCard(
                        icon: "brain.filled.head.profile",
                        iconColor: .purple,
                        title: "GIGI Brain (Groq)",
                        subtitle: groqReady ? "Connected — llama-3.3-70b" : "API key required",
                        status: groqReady ? .ok : .required,
                        action: nil  // managed in Settings
                    )

                    setupCard(
                        icon: "message.badge.filled.fill",
                        iconColor: .green,
                        title: "WhatsApp Web",
                        subtitle: whatsappLinked ? "Linked — messages send automatically" : "Tap to link — scan QR once",
                        status: whatsappLinked ? .ok : .action,
                        action: { showWhatsAppSheet = true }
                    )

                    setupCard(
                        icon: "person.crop.circle.fill",
                        iconColor: .blue,
                        title: "Your Profile",
                        subtitle: profileScore == 0
                            ? "Not set — GIGI can't fill forms for you"
                            : "\(profileScore)/4 fields set — used for checkout & booking",
                        status: profileScore >= 2 ? .ok : .action,
                        action: { showProfileSheet = true }
                    )

                    // ── Capabilities status ────────────────────────
                    SectionHeader(title: "Capabilities")

                    capabilityRow("Calls & Messages",  icon: "phone.bubble.fill",     color: .green,  active: true)
                    capabilityRow("Calendar & Reminders", icon: "calendar.badge.clock", color: .red,   active: true)
                    capabilityRow("Navigation & Maps",  icon: "map.fill",              color: .blue,   active: true)
                    capabilityRow("HomeKit",            icon: "house.fill",             color: .orange, active: homeKitCount > 0,
                                  detail: homeKitCount > 0 ? "\(homeKitCount) accessories" : "No HomeKit home found")
                    capabilityRow("Web Automation",     icon: "safari.fill",            color: .cyan,   active: groqReady,
                                  detail: groqReady ? "Vision loop active" : "Needs Groq key")
                    capabilityRow("Long-term Memory",   icon: "brain",                  color: .purple, active: memoryCount > 0,
                                  detail: "\(memoryCount) memories saved")
                    capabilityRow("Wake Word",          icon: "ear.fill",               color: .yellow, active: wakeWordEnabled)
                    capabilityRow("Music (Apple)",      icon: "music.note",             color: .pink,   active: true)
                    capabilityRow("Spotify",            icon: "music.mic",              color: .green,  active: false,
                                  detail: "Opens app, tap to play")

                    // ── Guided setup ───────────────────────────────
                    SectionHeader(title: "Setup Wizard")

                    Button {
                        showGuidedSetup = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "mic.badge.xmark")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.purple)
                                .cornerRadius(10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Voice Setup")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("GIGI guides you through config by voice")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(14)
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
            }
        }
        .task { await loadStatus() }
        .sheet(isPresented: $showWhatsAppSheet, onDismiss: { Task { await loadStatus() } }) {
            WhatsAppLinkSheet()
        }
        .sheet(isPresented: $showProfileSheet, onDismiss: { Task { await loadStatus() } }) {
            ProfileEditSheet()
        }
        .sheet(isPresented: $showGuidedSetup) {
            GuidedSetupSheet()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(groqReady ? "GIGI is ready" : "Complete setup below")
                    .font(.system(size: 13))
                    .foregroundColor(groqReady ? .green : .orange)
            }
            Spacer()
            ZStack {
                Circle()
                    .fill(groqReady ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: groqReady ? "checkmark" : "exclamationmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(groqReady ? .green : .orange)
            }
        }
    }

    // MARK: - Setup card

    enum SetupStatus { case ok, required, action }

    private func setupCard(
        icon: String, iconColor: Color, title: String, subtitle: String,
        status: SetupStatus, action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(width: 44, height: 44)
                .background(iconColor.opacity(0.12))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(2)
            }

            Spacer()

            switch status {
            case .ok:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 20))
            case .required:
                Text("Required")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(6)
            case .action:
                if let action {
                    Button("Setup", action: action)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color.purple.opacity(0.15))
                        .cornerRadius(8)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(14)
        .onTapGesture { action?() }
    }

    // MARK: - Capability row

    private func capabilityRow(_ title: String, icon: String, color: Color, active: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(active ? color : .white.opacity(0.2))
                .frame(width: 28)
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(active ? .white : .white.opacity(0.35))
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
            }
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundColor(active ? .green : .white.opacity(0.15))
        }
        .padding(.vertical, 6)
    }

    // MARK: - Load status

    private func loadStatus() async {
        let key = GigiConfig.groqAPIKey
        if !key.isEmpty {
            // Real API ping (reuses existing GigiCloudService.testKey which sends a minimal request)
            let result = await GigiCloudService.shared.testKey(key)
            groqReady = result.contains("✓")
        } else {
            groqReady = false
        }

        // WhatsApp: check UserDefaults flag + silently verify session if webview loaded
        let udLinked = UserDefaults.standard.bool(forKey: "gigi.whatsapp.linked")
        if udLinked, GigiWebAgent.shared.webView.url?.host == "web.whatsapp.com" {
            let live = (try? await GigiWebAgent.shared.js(
                "document.querySelector('[data-testid=\"chat-list\"]') !== null"
            )) as? Bool ?? false
            whatsappLinked = live
            if !live { UserDefaults.standard.set(false, forKey: "gigi.whatsapp.linked") }
        } else {
            whatsappLinked = udLinked
        }

        homeKitCount = await GigiHomeKit.shared.accessoryNames().count
        let all = await GigiMemory.shared.mostUsed(limit: 1000)
        memoryCount = all.count
        let p = await GigiUserProfile.shared.load()
        profileScore = [!p.name.isEmpty, !p.email.isEmpty, !p.phone.isEmpty, !p.deliveryAddress.isEmpty].filter { $0 }.count
    }
}

// MARK: - WhatsApp Link Sheet

struct WhatsAppLinkSheet: View {
    @Environment(\.dismiss) var dismiss
    // Initialize from persisted flag so reopening shows correct state immediately
    @State private var isLinked = UserDefaults.standard.bool(forKey: "gigi.whatsapp.linked")

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    if isLinked {
                        linkedView
                    } else {
                        instructionBanner
                        WebViewRepresentable(webView: GigiWebAgent.shared.webView,
                                            onLinked: { isLinked = true })
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
            }
            .navigationTitle("WhatsApp Web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.purple)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Bring webview on-screen for QR scanning
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first?.windows.first {
                GigiWebAgent.shared.showInWindow(window)
            }
            // Navigate to WA Web only if not already there
            if GigiWebAgent.shared.webView.url?.host != "web.whatsapp.com" {
                let url = URL(string: "https://web.whatsapp.com")!
                GigiWebAgent.shared.webView.load(URLRequest(url: url))
            }
        }
        .onDisappear {
            // Return to off-screen headless state
            GigiWebAgent.shared.hideFromWindow()
        }
    }

    private var instructionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder")
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan with WhatsApp on your phone")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("Open WhatsApp → ··· → Linked Devices → Link a Device")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.12))
    }

    private var linkedView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.green)
            Text("WhatsApp Linked!")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("GIGI can now send messages automatically without opening the app.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 32)
            Spacer()
            Button("Done") { dismiss() }
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 40).padding(.vertical, 14)
                .background(Color.purple)
                .clipShape(Capsule())
            Spacer()
        }
    }
}

// MARK: - WebView wrapper (shows the existing hidden GigiWebAgent webView full-screen)

struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    let onLinked: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        // Frame and visibility are managed by GigiWebAgent.showInWindow/hideFromWindow.
        // Only override the nav delegate so Coordinator can detect QR link completion.
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onLinked: onLinked) }

    // CRITICAL: restore GigiWebAgent as nav delegate so future navigate() calls work.
    // Also restores off-screen headless state (frame + alpha + interaction).
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        uiView.navigationDelegate = GigiWebAgent.shared
        // Note: frame/alpha restored by WhatsAppLinkSheet.onDisappear → hideFromWindow()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onLinked: () -> Void
        private var pollTimer: Timer?
        private var hasLinked = false

        init(onLinked: @escaping () -> Void) { self.onLinked = onLinked }

        func stop() {
            pollTimer?.invalidate()
            pollTimer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Also forward to GigiWebAgent so any pending navContinuation resolves
            GigiWebAgent.shared.webView(webView, didFinish: navigation)
            startPolling(webView: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            GigiWebAgent.shared.webView(webView, didFail: navigation, withError: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
            GigiWebAgent.shared.webView(webView, didFailProvisionalNavigation: nav, withError: error)
        }

        private func startPolling(webView: WKWebView) {
            guard !hasLinked else { return }
            pollTimer?.invalidate()
            // WhatsApp Web loads incrementally: header first, then chat list.
            // Poll every 1.5s for up to 2 minutes.
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self, weak webView] _ in
                guard let self, !self.hasLinked, let webView else { return }
                webView.evaluateJavaScript(
                    "document.querySelector('[data-testid=\"chat-list\"]') !== null"
                ) { result, _ in
                    guard result as? Bool == true else { return }
                    self.hasLinked = true
                    self.pollTimer?.invalidate()
                    UserDefaults.standard.set(true, forKey: "gigi.whatsapp.linked")
                    DispatchQueue.main.async { self.onLinked() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                self?.pollTimer?.invalidate()
            }
        }

        deinit { pollTimer?.invalidate() }
    }
}

// MARK: - Profile Edit Sheet

struct ProfileEditSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var address = ""
    @State private var city = ""
    @State private var zip = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        profileField("Full name",     text: $name,    keyboard: .default,     icon: "person.fill")
                        profileField("Email",          text: $email,   keyboard: .emailAddress, icon: "envelope.fill")
                        profileField("Phone",          text: $phone,   keyboard: .phonePad,     icon: "phone.fill")

                        Divider().background(Color.white.opacity(0.12)).padding(.vertical, 4)

                        Text("Delivery address")
                            .font(.caption).foregroundColor(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        profileField("Street",        text: $address, keyboard: .default,     icon: "house.fill")
                        profileField("City",           text: $city,    keyboard: .default,     icon: "mappin.circle.fill")
                        profileField("ZIP",            text: $zip,     keyboard: .numberPad,   icon: "number")

                        if isSaving {
                            ProgressView().tint(.purple).padding(.top, 8)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Your Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { Task { await saveProfile() } }
                        .fontWeight(.semibold).foregroundColor(.purple)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadProfile() }
    }

    private func profileField(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.purple).frame(width: 22)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .foregroundColor(.white)
        }
        .padding(14)
        .background(Color.white.opacity(0.07))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.3), lineWidth: 1))
    }

    private func loadProfile() async {
        let p = await GigiUserProfile.shared.load()
        name = p.name; email = p.email; phone = p.phone
        address = p.deliveryAddress; city = p.city; zip = p.zip
    }

    private func saveProfile() async {
        isSaving = true
        var p = UserProfileData()
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.email = email.trimmingCharacters(in: .whitespaces)
        p.phone = phone.trimmingCharacters(in: .whitespaces)
        p.deliveryAddress = address.trimmingCharacters(in: .whitespaces)
        p.city = city.trimmingCharacters(in: .whitespaces)
        p.zip = zip.trimmingCharacters(in: .whitespaces)
        await GigiUserProfile.shared.save(p)
        isSaving = false
        dismiss()
    }
}

// MARK: - Guided Setup Sheet (voice-driven config wizard)

struct GuidedSetupSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var session = GuidedSetupSession()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Conversation transcript
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(session.messages.indices, id: \.self) { i in
                                    let msg = session.messages[i]
                                    HStack(alignment: .bottom) {
                                        if msg.isUser { Spacer(minLength: 60) }
                                        Text(msg.text)
                                            .font(.system(size: 15, design: .rounded))
                                            .foregroundColor(msg.isUser ? .black : .white)
                                            .padding(.horizontal, 14).padding(.vertical, 10)
                                            .background(msg.isUser ? Color.white : Color.white.opacity(0.1))
                                            .clipShape(Capsule())
                                        if !msg.isUser { Spacer(minLength: 60) }
                                    }
                                    .id(i)
                                }
                            }
                            .padding(16)
                        }
                        .onChange(of: session.messages.count) { _, _ in
                            proxy.scrollTo(session.messages.count - 1, anchor: .bottom)
                        }
                    }

                    Divider().background(Color.white.opacity(0.1))

                    // Mic button
                    VStack(spacing: 16) {
                        if session.savedFlash {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Saved!")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.green)
                            }
                            .transition(.scale.combined(with: .opacity))
                        } else if session.isListening {
                            Text("Listening...")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.purple.opacity(0.8))
                        } else if session.isThinking {
                            ProgressView().tint(.purple)
                        } else if !session.isDone {
                            Text("Tap mic to answer")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.4))
                        }

                        if session.isDone {
                            Button("Done") { dismiss() }
                                .fontWeight(.semibold).foregroundColor(.white)
                                .padding(.horizontal, 40).padding(.vertical, 14)
                                .background(Color.purple).clipShape(Capsule())
                        } else {
                            Button {
                                session.isListening ? session.stopListening() : session.startListening()
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(session.isListening ? Color.purple : Color.white.opacity(0.1))
                                        .frame(width: 64, height: 64)
                                    Image(systemName: session.isListening ? "waveform" : "mic.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle("Voice Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Skip") { dismiss() }.foregroundColor(.secondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await session.start() }
    }
}

// MARK: - GuidedSetupSession

@MainActor
final class GuidedSetupSession: ObservableObject {
    struct Message { let text: String; let isUser: Bool }

    @Published var messages: [Message] = []
    @Published var isListening = false
    @Published var isThinking = false
    @Published var isDone = false
    @Published var savedFlash = false   // triggers green checkmark flash in UI

    private let steps: [(prompt: String, key: String)] = [
        ("What's your full name?", "pref:nome"),
        ("What's your email address?", "pref:email"),
        ("And your phone number?", "pref:telefono"),
        ("What's your delivery address? Say the street and number.", "pref:indirizzo_consegna"),
        ("City?", "pref:citta"),
        ("ZIP or postal code?", "pref:cap"),
    ]
    private var currentStep = 0
    private var savedTranscriptionHandler: ((String) -> Void)?
    private var interruptionObserver: NSObjectProtocol?
    private var isInterrupted = false

    init() {
        // Pause/resume on phone call or other audio interruptions
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }

            switch type {
            case .began:
                // Interruption started (e.g. phone call) — pause listening without losing state
                self.isInterrupted = true
                if self.isListening {
                    self.isListening = false
                    GigiAudioManager.shared.stopRecording()
                    // Restore orchestrator's handler so other audio still works
                    if let saved = self.savedTranscriptionHandler {
                        GigiAudioManager.shared.onTranscription = saved
                    }
                }
            case .ended:
                self.isInterrupted = false
                // Re-ask the current question when audio resumes
                if !self.isDone {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        self?.addGigi("Welcome back! " + (self?.steps[self?.currentStep ?? 0].prompt ?? ""))
                    }
                }
            @unknown default: break
            }
        }
    }

    deinit {
        if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
    }

    func start() async {
        let intro = "Hi! I'll set you up in about a minute. Answer by voice — say 'skip' for anything you prefer not to share."
        addGigi(intro)
        GigiSpeechService.shared.speak(intro)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        await askCurrentStep()
    }

    func startListening() {
        guard !isInterrupted else { return }
        isListening = true
        // Save orchestrator's handler, intercept for this session only
        savedTranscriptionHandler = GigiAudioManager.shared.onTranscription
        GigiAudioManager.shared.onTranscription = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Restore immediately so any parallel audio (TTS etc.) still works
                GigiAudioManager.shared.onTranscription = self.savedTranscriptionHandler
                self.isListening = false
                await self.handleAnswer(text)
            }
        }
        GigiAudioManager.shared.startRecording()
    }

    func stopListening() {
        isListening = false
        if let saved = savedTranscriptionHandler {
            GigiAudioManager.shared.onTranscription = saved
        }
        GigiAudioManager.shared.stopRecording()
    }

    private func askCurrentStep() async {
        guard currentStep < steps.count else { await finish(); return }
        let q = steps[currentStep].prompt
        addGigi(q)
        GigiSpeechService.shared.speak(q)
    }

    private func handleAnswer(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { await askCurrentStep(); return }

        addUser(trimmed)

        let isSkip = trimmed.lowercased().contains("skip") || trimmed.lowercased() == "no"
        if !isSkip, currentStep < steps.count {
            await GigiMemory.shared.remember(key: steps[currentStep].key, value: trimmed)
            // Visual + haptic feedback: green flash
            SoundEngine.play(.taskDone)
            savedFlash = true
            try? await Task.sleep(nanoseconds: 700_000_000)
            savedFlash = false
        }

        currentStep += 1
        try? await Task.sleep(nanoseconds: 400_000_000)
        await askCurrentStep()
    }

    private func finish() async {
        let ending = "All done! Your profile is saved. You can update it anytime in Dashboard → Your Profile."
        addGigi(ending)
        GigiSpeechService.shared.speak(ending)
        SoundEngine.play(.taskDone)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        isDone = true
    }

    private func addGigi(_ text: String) { messages.append(Message(text: text, isUser: false)) }
    private func addUser(_ text: String)  { messages.append(Message(text: text, isUser: true)) }
}

// MARK: - Shared UI components

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.4))
            .padding(.top, 8)
    }
}
