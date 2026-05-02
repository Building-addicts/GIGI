import SwiftUI

// MARK: - SettingsView (T-24)
//
// All configuration in one place: API keys, wake word, privacy, debug.

enum SettingsField: Hashable {
    case groqKey, geminiKey, harnessURL, harnessSecret
}

private enum SettingsSheet: String, Identifiable {
    case whatsApp
    case profile
    case pairing
    case diagnostics

    var id: String { rawValue }
}

struct SettingsView: View {
    @State private var groqKey = ""
    @State private var geminiKey = ""
    @State private var showQRScanner = false
    @State private var showKey = false
    @State private var connectionStatus: String = "—"
    @State private var isTestingConnection = false
    @ObservedObject private var audioManager = GigiAudioManager.shared
    @ObservedObject private var presence = PresenceSessionController.shared
    @State private var ttsRate: Double = 0.52
    @State private var memoryCount = 0
    @State private var showClearMemoryAlert = false
    @State private var showResetOnboarding = false
    @State private var accessoryList: [String] = []
    @State private var activeSheet: SettingsSheet? = nil
    @State private var harnessURL = ""
    @State private var harnessSecret = ""
    @State private var harnessStatus = "—"
    @State private var isTestingHarness = false
    @State private var manualConfigExpanded = false
    @State private var pairedDeviceName: String? = nil
    @State private var forceClaude: Bool = GigiKeychain.loadBool(forKey: GigiKeychain.Key.forceClaude)
    @State private var autoFallback: Bool = GigiKeychain.loadBool(forKey: GigiKeychain.Key.autoFallback)
    @FocusState var focusedField: SettingsField?

    var body: some View {
        NavigationStack {
            List {
                brainSection
                brainModeSection
                harnessSection
                whatsAppSection
                profileSection
                hardwareTriggerSection
                homeKitSection
                voiceSection
                privacySection
                debugSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollIndicators(.hidden)
            .preferredColorScheme(.dark)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.purple)
                }
            }
            .task { await loadState() }
            .sheet(item: $activeSheet) { sheet in
                settingsSheet(sheet)
            }
        }
    }

    // MARK: - Brain section

    private var brainSection: some View {
        Section {
            // Inline key editor
            HStack {
                if showKey {
                    TextField("gsk_...", text: $groqKey)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focusedField, equals: .groqKey)
                        .onSubmit { saveGroqKey() }
                } else {
                    SecureField("Groq API Key", text: $groqKey)
                        .font(.system(.body, design: .monospaced))
                        .submitLabel(.done)
                        .focused($focusedField, equals: .groqKey)
                        .onSubmit { saveGroqKey() }
                }
                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                Button(action: saveGroqKey) {
                    Text("Save")
                        .foregroundColor(.purple)
                        .fontWeight(.semibold)
                }
                .disabled(groqKey.isEmpty)
            }

            HStack {
                Text("Connection")
                Spacer()
                if isTestingConnection {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text(connectionStatus)
                        .foregroundColor(connectionStatus.contains("✓") ? .green : .secondary)
                        .font(.subheadline)
                }
            }

            Button("Test Connection") {
                Task { await testConnection() }
            }
            .foregroundColor(.purple)

        } header: {
            Text("🧠 AI Brain (Groq)")
        } footer: {
            Text("Free key at console.groq.com — stored securely in your Keychain.")
                .font(.caption)
        }
    }

    // MARK: - Brain Mode section (Phase 2 — Force Claude toggle)

    private var brainModeSection: some View {
        Section {
            Toggle(isOn: $forceClaude) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Force Claude")
                        .font(.body.weight(.medium))
                    Text("Route every turn through Claude on your PC, bypassing Groq.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(.purple)
            .onChange(of: forceClaude) { _, new in
                GigiKeychain.saveBool(new, forKey: GigiKeychain.Key.forceClaude)
            }

            Toggle(isOn: $autoFallback) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Fallback to Groq")
                        .font(.body.weight(.medium))
                    Text("If the harness is unreachable, silently use Groq instead of failing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(.purple)
            .disabled(!forceClaude)
            .onChange(of: autoFallback) { _, new in
                GigiKeychain.saveBool(new, forKey: GigiKeychain.Key.autoFallback)
            }
        } header: {
            Text("🧠 Brain Mode")
        } footer: {
            Text("Force Claude is slower but smarter — Claude has web search, computer-use, and full reasoning. Default off uses Groq for fast turns and escalates to Claude only when needed.")
                .font(.caption)
        }
    }

    // MARK: - Harness section (backend GIGI)

    // Phase 5.11 — migration banner: shown when the paired URL is a
    // Tailscale 100.* address, suggesting the user upgrade to Cloudflare
    // Tunnel for a smoother cross-network experience.
    @ViewBuilder
    private var migrationBannerIfNeeded: some View {
        if shouldShowMigrationBanner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cloud.bolt")
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tip: switch to Cloudflare Tunnel")
                        .font(.subheadline.weight(.semibold))
                    Text("You're paired via a Tailscale 100.* address. Cloudflare Tunnel works without Tailscale and reconnects faster across networks. Open localhost:7777/setup on your PC.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Don't show again") {
                        UserDefaults.standard.set(true, forKey: "gigi.migration.cf.dismissed")
                    }
                    .font(.caption2)
                    .foregroundColor(.purple)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.purple.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.3), lineWidth: 1))
            .cornerRadius(10)
        }
    }

    private var shouldShowMigrationBanner: Bool {
        if UserDefaults.standard.bool(forKey: "gigi.migration.cf.dismissed") { return false }
        guard let host = GigiHarnessClient.shared.pairedBaseURL?.host else { return false }
        return host.hasPrefix("100.") // Tailscale CGNAT range
    }

    private var harnessSection: some View {
        Section {
            migrationBannerIfNeeded

            // Primary action: pair via QR
            Button {
                activeSheet = .pairing
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18))
                    Text(harnessIsPaired ? "Re-pair with Harness" : "Pair with Harness")
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .foregroundColor(.purple)
                .padding(.vertical, 4)
            }

            // Status line
            HStack {
                Text("Status")
                Spacer()
                if isTestingHarness {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text(harnessStatus)
                        .foregroundColor(harnessStatus.contains("✓") ? .green : .secondary)
                        .font(.subheadline)
                }
            }

            // Phase 6C — rich runtime status card (only when paired).
            if harnessIsPaired {
                HarnessStatusCard(deviceName: pairedDeviceName)
            }

            // Re-test + diagnostics + unpair
            if harnessIsPaired {
                Button("Test connection") {
                    Task { await testHarnessHealthOnly() }
                }
                .foregroundColor(.purple)
                .disabled(isTestingHarness)

                Button("Run diagnostics") {
                    activeSheet = .diagnostics
                }
                .foregroundColor(.purple)

                Button(role: .destructive) {
                    removePairing()
                } label: {
                    Text("Remove pairing")
                }
            }

            // Advanced: manual config still available for power users / debug.
            DisclosureGroup("Manual configuration (advanced)", isExpanded: $manualConfigExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL").font(.caption).foregroundColor(.secondary)
                    TextField("http://10.0.0.5:7779", text: $harnessURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .focused($focusedField, equals: .harnessURL)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bearer secret").font(.caption).foregroundColor(.secondary)
                    SecureField("32+ char shared secret", text: $harnessSecret)
                        .font(.system(.body, design: .monospaced))
                        .focused($focusedField, equals: .harnessSecret)
                }
                Button("Save and test") {
                    Task { await saveAndTestHarness() }
                }
                .foregroundColor(.purple)
                .disabled(harnessURL.isEmpty || harnessSecret.isEmpty || isTestingHarness)
            }
            .font(.caption)
            .tint(.secondary)
        } header: {
            Text("🖥 Harness Backend")
        } footer: {
            Text("Open localhost:7777/setup in your PC browser to choose the tunnel mode, then localhost:7777/pair for the QR. One-time setup, then works from any network.")
                .font(.caption)
        }
    }


    @ViewBuilder
    private func settingsSheet(_ sheet: SettingsSheet) -> some View {
        switch sheet {
        case .whatsApp:
            WhatsAppLinkSheet()
        case .profile:
            ProfileEditSheet()
        case .pairing:
            GigiPairingSheet { deviceName in
                pairedDeviceName = deviceName
                harnessStatus = "\u{2713} Connected to \(deviceName)"
            }
        case .diagnostics:
            // Re-running diagnostics from Settings: when the user taps
            // Finalize we just close the sheet (no pair side-effect).
            SetupDiagnosticView(
                onNeedsRepair: {
                    harnessStatus = "Not configured - scan a fresh QR"
                    pairedDeviceName = nil
                    harnessURL = ""
                    harnessSecret = ""
                    activeSheet = nil
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        activeSheet = .pairing
                    }
                },
                onFinalize: {
                    harnessStatus = "\u{2713} Harness ready"
                    activeSheet = nil
                }
            )
        }
    }

    private var harnessIsPaired: Bool {
        GigiHarnessClient.shared.pairingState.isConfigured
    }

    private func removePairing() {
        GigiKeychain.delete(forKey: GigiKeychain.Key.harnessBaseURL)
        GigiKeychain.delete(forKey: GigiKeychain.Key.harnessSecret)
        harnessURL = ""
        harnessSecret = ""
        harnessStatus = "Not configured"
        pairedDeviceName = nil
    }

    // MARK: - WhatsApp section

    private var whatsAppSection: some View {
        Section {
            let linked = UserDefaults.standard.bool(forKey: "gigi.whatsapp.linked")
            HStack {
                Text("Status")
                Spacer()
                Image(systemName: linked ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(linked ? .green : .orange)
                Text(linked ? "Linked" : "Not linked")
                    .foregroundColor(linked ? .green : .orange)
                    .font(.subheadline)
            }
            Button(linked ? "Re-link WhatsApp Web" : "Link WhatsApp Web") {
                activeSheet = .whatsApp
            }
            .foregroundColor(.purple)
        } header: {
            Text("💬 WhatsApp Web")
        } footer: {
            Text("Scan QR once to let GIGI send messages automatically without opening the app.")
                .font(.caption)
        }
    }

    // MARK: - Profile section

    private var profileSection: some View {
        Section {
            Button("Edit Profile") { activeSheet = .profile }
                .foregroundColor(.purple)
        } header: {
            Text("👤 Your Profile")
        } footer: {
            Text("Name, email, phone, address — GIGI uses this to fill forms and complete orders automatically.")
                .font(.caption)
        }
    }

    // MARK: - Hardware trigger section
    //
    // MVP (#102): wake word is disabled (iOS does not allow continuous background
    // mic for non-VoIP apps). Replaced by hardware triggers — Back Tap on iPhone 14
    // and earlier, Action Button on iPhone 15 Pro+, plus Siri AppIntent phrase.
    // Setup walkthrough lives in Onboarding; this section explains the available
    // triggers and lets the user re-run setup at any time.

    private var hardwareTriggerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.tap.fill")
                    .font(.title3)
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Double-tap the back of your iPhone")
                        .font(.subheadline.weight(.semibold))
                    Text("Bind \(GigiHardwareShortcut.shortcutName) under Accessibility → Touch → Back Tap → Double Tap → Shortcuts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "button.programmable")
                    .font(.title3)
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action Button (iPhone 15 Pro+)")
                        .font(.subheadline.weight(.semibold))
                    Text("Settings → Action Button → Shortcut → pick \(GigiHardwareShortcut.shortcutName) (NOT the Open GIGI App Shortcut). Its CALL: branch should pass the stripped phone number into Shortcuts' native Call action, so iOS owns the compliant call flow over your current app.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mic.circle")
                    .font(.title3)
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hey Siri")
                        .font(.subheadline.weight(.semibold))
                    Text("Say \"Hey Siri, talk to GIGI\" — or \"Ehi Siri, parla con GIGI\" on Italian Siri. GIGI opens in conversation mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button {
                UserDefaults.standard.set(false, forKey: "gigi.onboarding.complete")
                NotificationCenter.default.post(name: .gigiReopenOnboarding, object: nil)
            } label: {
                Label("Run setup walkthrough", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(.purple)
            }
        } header: {
            Text("🎙️ Talk to GIGI")
        } footer: {
            Text("Wake word (\"Hey GIGI\") is paused for this release. iOS does not allow continuous background listening for non-VoIP apps; we will revisit it in v1.1 with a different approach. For now, hardware triggers open GIGI in under one second from anywhere — even with the screen locked.")
                .font(.caption)
        }
    }

    private var audioStateLabel: String {
        switch audioManager.state {
        case .idle: return presence.isActive ? "Ready" : "Off"
        case .wakeWordListening: return "Ready"
        case .recording: return "Listening"
        case .speaking: return "Speaking"
        }
    }

    // MARK: - HomeKit section

    private var homeKitSection: some View {
        Section {
            if accessoryList.isEmpty {
                Text("No accessories found")
                    .foregroundColor(.secondary)
            } else {
                ForEach(accessoryList.prefix(5), id: \.self) { name in
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                        Text(name)
                    }
                }
                if accessoryList.count > 5 {
                    Text("+ \(accessoryList.count - 5) more")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }

            Button("Refresh Accessories") {
                Task {
                    GigiHomeKit.shared.invalidateCache()
                    accessoryList = await GigiHomeKit.shared.accessoryNames()
                }
            }
            .foregroundColor(.purple)
        } header: {
            Text("🏠 HomeKit")
        } footer: {
            Text("Requires HomeKit capability in Xcode + NSHomeKitUsageDescription in Info.plist.")
                .font(.caption)
        }
    }

    // MARK: - Voice section

    private var voiceSection: some View {
        Section {
            HStack {
                Text("TTS Rate")
                Spacer()
                Text(String(format: "%.2f", ttsRate))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $ttsRate, in: 0.3...0.7, step: 0.01)
                .tint(.purple)
                .onChange(of: ttsRate) { _, new in
                    UserDefaults.standard.set(new, forKey: "gigi.tts.rate")
                }

            Button("Test Voice") {
                GigiSpeechService.shared.speak("I'm GIGI — your personal Jarvis. Running at full speed.")
            }
            .foregroundColor(.purple)

            #if DEBUG
            Button("Force Empty TTS (Debug)") {
                GigiSpeechService.shared.speak("")
            }
            .foregroundColor(.orange)
            #endif
        } header: {
            Text("🔊 Voice")
        }
    }

    // MARK: - Privacy section

    private var privacySection: some View {
        Section {
            HStack {
                Text("Memories saved")
                Spacer()
                Text("\(memoryCount)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            Button("Clear All Memory", role: .destructive) {
                showClearMemoryAlert = true
            }
            .alert("Clear All Memory?", isPresented: $showClearMemoryAlert) {
                Button("Clear", role: .destructive) {
                    Task {
                        let all = await GigiMemory.shared.mostUsed(limit: 1000)
                        for (key, _) in all { await GigiMemory.shared.forget(key) }
                        memoryCount = 0
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes all saved facts from CloudKit and local cache. Cannot be undone.")
            }
        } header: {
            Text("🔒 Privacy")
        } footer: {
            Text("Memories are stored in your private iCloud. GIGI never shares your data.")
                .font(.caption)
        }
    }

    // MARK: - Debug section

    private var debugSection: some View {
        Section {
            Button("Run Brain Diagnostics") {
                GigiBrainDiagnostics.log()
            }
            .foregroundColor(.purple)

            HStack(alignment: .top) {
                Text("Harness pairing")
                Spacer()
                Text(GigiHarnessClient.shared.pairingState.debugLabel)
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
            }

            Button("Reset Onboarding") {
                UserDefaults.standard.removeObject(forKey: "gigi.onboarding.complete")
                showResetOnboarding = true
            }
            .foregroundColor(.orange)
            .alert("Onboarding Reset", isPresented: $showResetOnboarding) {
                Button("OK") {}
            } message: {
                Text("Restart the app to see onboarding again.")
            }
        } header: {
            Text("🔧 Debug")
        }
    }

    // MARK: - About section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Build")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Brain")
                Spacer()
                Text(GigiFoundationAgent.isSupported ? "Groq + Apple Intelligence" : "Groq llama-3.3-70b")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
        } header: {
            Text("ℹ️ About GIGI")
        }
    }

    // MARK: - Load state

    private func loadState() async {
        ttsRate = UserDefaults.standard.double(forKey: "gigi.tts.rate").nonZero ?? 0.52
        let all = await GigiMemory.shared.mostUsed(limit: 1000)
        memoryCount = all.count
        accessoryList = await GigiHomeKit.shared.accessoryNames()
        let existing = GigiConfig.groqAPIKey
        if !existing.isEmpty { groqKey = existing }
        harnessURL = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL) ?? ""
        harnessSecret = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret) ?? ""
        let pairingState = GigiHarnessClient.shared.pairingState
        harnessStatus = pairingState.isConfigured ? "Configured (not tested)" : "Not configured - \(pairingState.debugLabel)"
    }

    /// Used only by the "Salva e testa" button inside the manual/advanced
    /// DisclosureGroup. Reads the TextField @State bindings and writes them
    /// to the Keychain. Safe only when the user has just typed URL+secret
    /// manually. DO NOT call from the primary "Verifica connessione" button
    /// post-QR-pair — that would wipe the Keychain because the @State
    /// bindings are empty (the pair sheet writes directly to Keychain,
    /// not to our @State).
    private func saveAndTestHarness() async {
        isTestingHarness = true
        let url    = harnessURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = harnessSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !secret.isEmpty else {
            harnessStatus = "URL and secret cannot be empty"
            isTestingHarness = false
            return
        }
        GigiKeychain.save(url,    forKey: GigiKeychain.Key.harnessBaseURL)
        GigiKeychain.save(secret, forKey: GigiKeychain.Key.harnessSecret)
        _ = GigiHarnessClient.ensureDeviceId()
        GigiApnsSync.onConfigChanged()
        switch await GigiHarnessClient.shared.health() {
        case .success(let h): harnessStatus = "✓ OK · pid \(h.pid) · uptime \(h.uptime_s)s"
        case .failure(let e): harnessStatus = "✗ \(e)"
        }
        // GigiApnsSync.onConfigChanged() already called above; no per-call sync API exists.
        isTestingHarness = false
    }

    /// Idempotent health-only check. Reads the Keychain (authoritative
    /// source, populated by the pair sheet) and pings `/api/ios/health`.
    /// Never writes. This is the only action safe to expose post-pair.
    private func testHarnessHealthOnly() async {
        isTestingHarness = true
        defer { isTestingHarness = false }
        guard GigiHarnessClient.shared.isConfigured else {
            harnessStatus = "✗ Harness not configured (URL/secret missing)"
            return
        }
        switch await GigiHarnessClient.shared.health() {
        case .success(let h):
            harnessStatus = "✓ OK · pid \(h.pid) · uptime \(h.uptime_s)s"
        case .failure(let e):
            harnessStatus = "✗ \(e)"
        }
    }

    private func saveGroqKey() {
        let trimmed = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        GigiConfig.setGroqAPIKey(trimmed)
        connectionStatus = "Key saved"
    }

    private func saveGeminiKey() {
        let trimmed = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        GigiConfig.setGeminiAPIKey(trimmed)
        connectionStatus = "Gemini key saved"
    }

    private func testConnection() async {
        isTestingConnection = true
        let key = GigiConfig.groqAPIKey
        guard !key.isEmpty else {
            connectionStatus = "✗ No API key"
            isTestingConnection = false
            return
        }
        let prefix = String(key.prefix(8)) + "..."
        connectionStatus = "Testing \(prefix)"
        let result = await GigiCloudService.shared.testKey(key)
        connectionStatus = result
        isTestingConnection = false
    }
}


private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
