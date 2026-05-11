import AVFoundation
import Combine
import SwiftUI
import WebKit

// MARK: - DashboardView
// Status overview + quick setup actions. Replaces the old "AI Providers" layout
// which referenced dead Gemini/Google integrations.

struct DashboardView: View {
    // Wake word UserDefaults key removed (2026-05-11) — engine in _legacy/ (ADR-0003),
    // no UI row depends on it anymore. PresenceSessionController still reads the
    // key for "always available" persistence — it owns the storage now.
    // groqReady removed (2026-05-11): Groq backend removed from main flow.
    // Brain readiness is now harnessConfigured (computed below).
    private var harnessConfigured: Bool { GigiHarnessClient.shared.isConfigured }
    @State private var whatsappLinked = false
    @State private var profileScore: Int = 0   // 0-4 fields filled
    @State private var memoryCount = 0
    @State private var homeKitCount = 0
    // showWhatsAppSheet removed (2026-05-11): WhatsApp linking lives only in
    // Settings → WhatsApp section now (D5 consolidation).
    @State private var showProfileSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    headerRow
                        .padding(.top, 56)

                    // First-config banner (Bug #001 fix 2026-05-12)
                    // Previously shown when !harnessConfigured — but the
                    // MainTabView already shows a global "Connect GIGI to
                    // your PC" purple banner in that case. The Groq banner
                    // is now shown ONLY after pairing, only if no Groq key
                    // is set, and only if the user hasn't dismissed it.
                    // Groq is optional (Apple FM + Ollama cover most paths).
                    if harnessConfigured && groqKeyMissing && !optionalBrainBannerDismissed {
                        optionalBrainBanner
                    }

                    // ── Setup status cards ─────────────────────────
                    SectionHeader(title: "Setup")

                    setupCard(
                        icon: "brain.filled.head.profile",
                        iconColor: .purple,
                        title: "GIGI Brain",
                        subtitle: harnessConfigured ? "Harness Claude paired" : "Pair harness to enable AI brain",
                        status: harnessConfigured ? .ok : .required,
                        action: nil  // managed in Settings → Harness section
                    )

                    // WhatsApp Web card removed (2026-05-11): consolidated to
                    // Settings → WhatsApp section.

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
                    capabilityRow("Web Automation",     icon: "safari.fill",            color: .cyan,   active: harnessConfigured,
                                  detail: harnessConfigured ? "Claude + MCP harness-browser" : "Needs harness paired")
                    capabilityRow("Long-term Memory",   icon: "brain",                  color: .purple, active: memoryCount > 0,
                                  detail: "\(memoryCount) memories saved")
                    // Wake Word row removed — engine disconnected in _legacy/ (ADR-0003).
                    // Talk to GIGI via Back Tap / Action Button / Siri AppIntent, see Settings.
                    capabilityRow("Music (Apple)",      icon: "music.note",             color: .pink,   active: true)
                    // Spotify row removed (2026-05-11): hardcoded inactive,
                    // no integration. Apple Music covers MVP music path.

                    // Setup Wizard (Voice Setup) section removed (2026-05-11):
                    // GuidedSetupSheet duplicated ProfileEditSheet fields + had
                    // an Italian seed string. Profile editing lives in
                    // ProfileEditSheet (single source of truth).

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
            }
        }
        .task { await loadStatus() }
        .sheet(isPresented: $showProfileSheet, onDismiss: { Task { await loadStatus() } }) {
            ProfileEditSheet()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Dashboard")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Spacer()

            // Single brain dot — green if AI brain is ready, red otherwise.
            // Full status info lives in Settings → Brain section.
            // HarnessOfflineBanner (MainTabView) covers harness offline state.
            Circle()
                .fill(harnessConfigured ? Color.green : Color.red)
                .frame(width: 10, height: 10)
        }
    }

    // MARK: - Optional cloud-brain banner (Bug #001 fix)
    //
    // Replaces the prior "Groq key required" banner which:
    //   (1) Showed before pairing — duplicating MainTabView's purple "Connect
    //       GIGI to PC" card, creating onboarding clutter.
    //   (2) Used "required" wording — Groq is optional after the 5-path
    //       router (Apple FM + Ollama cover most paths without any cloud key).
    //   (3) Couldn't be dismissed — testers who skip cloud reasoning saw it
    //       indefinitely.
    //
    // New behavior: shown only AFTER pairing, only if Groq key is missing,
    // only if user hasn't dismissed. Softer copy + info icon + dismiss "x".

    private var groqKeyMissing: Bool {
        GigiConfig.groqAPIKey.isEmpty
    }

    @AppStorage("gigi.dashboard.optionalBrainBannerDismissed")
    private var optionalBrainBannerDismissed: Bool = false

    private var optionalBrainBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundColor(.blue)
                .frame(width: 36, height: 36)
                .background(Color.blue.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Optional: cloud AI brain")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text("Add a free Groq API key in Settings → AI Brain for advanced cloud reasoning. Apple Intelligence and local Ollama already cover most tasks.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(3)
            }

            Spacer()

            Button {
                optionalBrainBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(Color.blue.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.20), lineWidth: 1))
        .cornerRadius(14)
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
        // Groq readiness check removed (2026-05-11): brain readiness now reads
        // harness pairing state directly via `harnessConfigured` computed prop.

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
