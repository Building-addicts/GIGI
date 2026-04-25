import SwiftUI

// MARK: - SettingsView (T-24)
//
// All configuration in one place: API keys, harness backend, wake word, privacy, debug.

struct SettingsView: View {
    // API keys
    @State private var groqKey = ""
    @State private var geminiKey = ""
    @State private var showKey = false
    @State private var showGeminiKey = false
    @State private var revealConnectedKeys = false
    @State private var groqUsage = GigiAPIKeyUsageStore.snapshot(provider: "groq")
    @State private var geminiUsage = GigiAPIKeyUsageStore.snapshot(provider: "gemini")
    @State private var connectionStatus: String = "—"
    @State private var isTestingConnection = false
    // Wake word
    @State private var picoKey = ""
    @State private var wakeWordEnabled = UserDefaults.standard.bool(forKey: GigiWakeWordEngine.userDefaultsEnabledKey)
    @State private var ttsRate: Double = 0.52
    // Memory / privacy
    @State private var memoryCount = 0
    @State private var showClearMemoryAlert = false
    @State private var showResetOnboarding = false
    @State private var accessoryList: [String] = []
    // Sheets
    @State private var showWhatsApp = false
    @State private var showProfile = false
    @State private var showPairing = false
    @State private var showDiagnostics = false
    // Harness
    @State private var harnessURL = ""
    @State private var harnessSecret = ""
    @State private var harnessStatus = "—"
    @State private var isTestingHarness = false
    @State private var manualConfigExpanded = false
    @State private var pairedDeviceName: String? = nil
    // Brain Mode
    @State private var forceClaude: Bool = GigiKeychain.loadBool(forKey: GigiKeychain.Key.forceClaude)
    @State private var autoFallback: Bool = GigiKeychain.loadBool(forKey: GigiKeychain.Key.autoFallback)

    var body: some View {
        NavigationStack {
            List {
                connectedKeysSection
                brainSection
                geminiSection
                brainModeSection
                harnessSection
                whatsAppSection
                profileSection
                wakeWordSection
                homeKitSection
                voiceSection
                privacySection
                debugSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .preferredColorScheme(.dark)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .task { await loadState() }
            .sheet(isPresented: $showWhatsApp) { WhatsAppLinkSheet() }
            .sheet(isPresented: $showProfile) { ProfileEditSheet() }
            .sheet(isPresented: $showPairing) {
                GigiPairingSheet { deviceName in
                    pairedDeviceName = deviceName
                    harnessStatus = "\u{2713} Connected to \(deviceName)"
                    showPairing = false
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                SetupDiagnosticView(
                    onNeedsRepair: {
                        harnessStatus = "Not configured — scan a fresh QR"
                        pairedDeviceName = nil
                        harnessURL = ""
                        harnessSecret = ""
                        showDiagnostics = false
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            showPairing = true
                        }
                    },
                    onFinalize: {
                        harnessStatus = "\u{2713} Harness ready"
                        showDiagnostics = false
                    }
                )
            }
        }
    }

    // MARK: - Connected Keys section

    private var connectedKeysSection: some View {
        Section {
            apiKeyStatusRow(
                title: "Groq",
                subtitle: "Brain, tool calling, web vision",
                key: GigiConfig.groqAPIKey,
                usage: groqUsage,
                provider: "groq",
                remove: removeGroqKey
            )

            apiKeyStatusRow(
                title: "Gemini",
                subtitle: "Realtime/native audio",
                key: GigiConfig.geminiAPIKey,
                usage: geminiUsage,
                provider: "gemini",
                remove: removeGeminiKey
            )

            Toggle("Show keys", isOn: $revealConnectedKeys)
                .tint(.purple)
        } header: {
            Text("🔑 Connected Keys")
        } footer: {
            Text("Keys are stored locally in this app's Keychain. Usage is local usage recorded by GIGI on this device, not the provider account limit.")
                .font(.caption)
        }
    }

    private func apiKeyStatusRow(
        title: String,
        subtitle: String,
        key: String,
        usage: GigiAPIKeyUsageSnapshot,
        provider: String,
        remove: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: key.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundColor(key.isEmpty ? .orange : .green)
            }

            Text(keyDisplay(key))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(key.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack {
                Text(usageDisplay(usage))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Reset usage") {
                    GigiAPIKeyUsageStore.reset(provider: provider)
                    refreshKeyUsage()
                }
                .font(.caption)
                .foregroundColor(.purple)
                .disabled(usage.requests == 0)

                Button("Remove", role: .destructive) { remove() }
                    .font(.caption)
                    .disabled(key.isEmpty)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Brain section (Groq key entry)

    private var brainSection: some View {
        Section {
            HStack {
                if showKey {
                    TextField("gsk_...", text: $groqKey)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { saveGroqKey() }
                } else {
                    SecureField("Groq API Key", text: $groqKey)
                        .font(.system(.body, design: .monospaced))
                        .submitLabel(.done)
                        .onSubmit { saveGroqKey() }
                }
                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye").foregroundColor(.secondary)
                }
                Button(action: saveGroqKey) {
                    Text("Save").foregroundColor(.purple).fontWeight(.semibold)
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

            Button("Test Connection") { Task { await testConnection() } }
                .foregroundColor(.purple)

        } header: {
            Text("🧠 AI Brain (Groq)")
        } footer: {
            Text("Required for GIGI's main brain, tool calling, and web vision. Free key at console.groq.com — stored securely in Keychain.")
                .font(.caption)
        }
    }

    // MARK: - Gemini section

    private var geminiSection: some View {
        Section {
            HStack {
                if showGeminiKey {
                    TextField("AIza...", text: $geminiKey)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { saveGeminiKey() }
                } else {
                    SecureField("Gemini API Key", text: $geminiKey)
                        .font(.system(.body, design: .monospaced))
                        .submitLabel(.done)
                        .onSubmit { saveGeminiKey() }
                }
                Button(action: { showGeminiKey.toggle() }) {
                    Image(systemName: showGeminiKey ? "eye.slash" : "eye").foregroundColor(.secondary)
                }
                Button(action: saveGeminiKey) {
                    Text("Save").foregroundColor(.purple).fontWeight(.semibold)
                }
                .disabled(geminiKey.isEmpty)
            }

            HStack {
                Text("Realtime voice")
                Spacer()
                let configured = !GigiConfig.geminiAPIKey.isEmpty
                Image(systemName: configured ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(configured ? .green : .secondary)
                Text(configured ? "Configured" : "Optional")
                    .foregroundColor(configured ? .green : .secondary)
                    .font(.subheadline)
            }
        } header: {
            Text("🎧 Realtime Voice (Gemini)")
        } footer: {
            Text("Optional. Used only by realtime/native audio paths. GIGI's main brain does not use this key.")
                .font(.caption)
        }
    }

    // MARK: - Brain Mode section (Force Claude)

    private var brainModeSection: some View {
        Section {
            Toggle(isOn: $forceClaude) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Force Claude").font(.body.weight(.medium))
                    Text("Route every turn through Claude on your PC, bypassing Groq.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .tint(.purple)
            .onChange(of: forceClaude) { _, new in
                GigiKeychain.saveBool(new, forKey: GigiKeychain.Key.forceClaude)
            }

            Toggle(isOn: $autoFallback) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Fallback to Groq").font(.body.weight(.medium))
                    Text("If the harness is unreachable, silently use Groq instead of failing.")
                        .font(.caption).foregroundColor(.secondary)
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
            Text("Force Claude is slower but smarter — web search, computer-use, full reasoning. Default off uses Groq for fast turns and escalates to Claude only when needed.")
                .font(.caption)
        }
    }

    // MARK: - Harness section

    @ViewBuilder
    private var migrationBannerIfNeeded: some View {
        if shouldShowMigrationBanner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cloud.bolt").foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tip: switch to Cloudflare Tunnel")
                        .font(.subheadline.weight(.semibold))
                    Text("You're paired via a Tailscale 100.* address. Cloudflare Tunnel works without Tailscale and reconnects faster across networks. Open localhost:7777/setup on your PC.")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Don't show again") {
                        UserDefaults.standard.set(true, forKey: "gigi.migration.cf.dismissed")
                    }
                    .font(.caption2).foregroundColor(.purple)
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
        return host.hasPrefix("100.")
    }

    private var harnessSection: some View {
        Section {
            migrationBannerIfNeeded

            Button {
                showPairing = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 18))
                    Text(harnessIsPaired ? "Re-pair with Harness" : "Pair with Harness")
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .foregroundColor(.purple)
                .padding(.vertical, 4)
            }

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

            if harnessIsPaired {
                HarnessStatusCard(deviceName: pairedDeviceName)
            }

            if harnessIsPaired {
                Button("Test connection") { Task { await testHarnessHealthOnly() } }
                    .foregroundColor(.purple)
                    .disabled(isTestingHarness)

                Button("Run diagnostics") { showDiagnostics = true }
                    .foregroundColor(.purple)

                Button(role: .destructive) {
                    removePairing()
                } label: {
                    Text("Remove pairing")
                }
            }

            DisclosureGroup("Manual configuration (advanced)", isExpanded: $manualConfigExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL").font(.caption).foregroundColor(.secondary)
                    TextField("http://10.0.0.5:7779", text: $harnessURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bearer secret").font(.caption).foregroundColor(.secondary)
                    SecureField("32+ char shared secret", text: $harnessSecret)
                        .font(.system(.body, design: .monospaced))
                }
                Button("Save and test") { Task { await saveAndTestHarness() } }
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
                showWhatsApp = true
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
            Button("Edit Profile") { showProfile = true }
                .foregroundColor(.purple)
        } header: {
            Text("👤 Your Profile")
        } footer: {
            Text("Name, email, phone, address — GIGI uses this to fill forms and complete orders automatically.")
                .font(.caption)
        }
    }

    // MARK: - Wake word section

    private var wakeWordSection: some View {
        Section {
            Toggle("Enable Wake Word", isOn: $wakeWordEnabled)
                .tint(.purple)
                .onChange(of: wakeWordEnabled) { _, new in
                    GigiWakeWordEngine.shared.setUserEnabled(new)
                }

            HStack {
                Text("Keyword")
                Spacer()
                let hasCustom = Bundle.main.path(forResource: "HeyGIGI", ofType: "ppn") != nil
                Text(hasCustom ? "\"Hey GIGI\"" : "\"Jarvis\" (built-in)")
                    .foregroundColor(.secondary).font(.subheadline)
            }

            let picoSet = !GigiConfig.picovoiceAccessKey.isEmpty
            HStack {
                Text("Picovoice Key")
                Spacer()
                Image(systemName: picoSet ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(picoSet ? .green : .orange)
                Text(picoSet ? "Set" : "Required for custom keyword")
                    .foregroundColor(picoSet ? .green : .orange).font(.caption)
            }
        } header: {
            Text("🎙️ Wake Word")
        } footer: {
            Text("Requires PICOVOICE_ACCESS_KEY in Config.xcconfig. For \"Hey GIGI\" add HeyGIGI.ppn to bundle.")
                .font(.caption)
        }
    }

    // MARK: - HomeKit section

    private var homeKitSection: some View {
        Section {
            if accessoryList.isEmpty {
                Text("No accessories found").foregroundColor(.secondary)
            } else {
                ForEach(accessoryList.prefix(5), id: \.self) { name in
                    HStack {
                        Image(systemName: "lightbulb.fill").foregroundColor(.yellow)
                        Text(name)
                    }
                }
                if accessoryList.count > 5 {
                    Text("+ \(accessoryList.count - 5) more")
                        .foregroundColor(.secondary).font(.subheadline)
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
                Text(String(format: "%.2f", ttsRate)).foregroundColor(.secondary).monospacedDigit()
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
                Text("\(memoryCount)").foregroundColor(.secondary).monospacedDigit()
            }
            Button("Clear All Memory", role: .destructive) { showClearMemoryAlert = true }
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
            Button("Run Brain Diagnostics") { GigiBrainDiagnostics.log() }
                .foregroundColor(.purple)

            HStack(alignment: .top) {
                Text("Harness pairing")
                Spacer()
                Text(GigiHarnessClient.shared.pairingState.debugLabel)
                    .foregroundColor(.secondary).font(.caption).multilineTextAlignment(.trailing)
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
                    .foregroundColor(.secondary).font(.subheadline)
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
        refreshKeyUsage()
        let existingGroq = GigiConfig.groqAPIKey
        if !existingGroq.isEmpty { groqKey = existingGroq }
        let existingGemini = GigiConfig.geminiAPIKey
        if !existingGemini.isEmpty { geminiKey = existingGemini }
        harnessURL = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL) ?? ""
        harnessSecret = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret) ?? ""
        let pairingState = GigiHarnessClient.shared.pairingState
        harnessStatus = pairingState.isConfigured ? "Configured (not tested)" : "Not configured — \(pairingState.debugLabel)"
    }

    // MARK: - Harness actions

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
        switch await GigiHarnessClient.shared.health() {
        case .success(let h): harnessStatus = "✓ OK · pid \(h.pid) · uptime \(h.uptime_s)s"
        case .failure(let e): harnessStatus = "✗ \(e)"
        }
        await GigiAPNSSync.shared.sync(reason: "config-changed")
        isTestingHarness = false
    }

    private func testHarnessHealthOnly() async {
        isTestingHarness = true
        defer { isTestingHarness = false }
        guard GigiHarnessClient.shared.isConfigured else {
            harnessStatus = "✗ Harness not configured (URL/secret missing)"
            return
        }
        switch await GigiHarnessClient.shared.health() {
        case .success(let h): harnessStatus = "✓ OK · pid \(h.pid) · uptime \(h.uptime_s)s"
        case .failure(let e): harnessStatus = "✗ \(e)"
        }
    }

    // MARK: - Key actions

    private func saveGroqKey() {
        let trimmed = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        GigiConfig.setGroqAPIKey(trimmed)
        connectionStatus = "Key saved"
        refreshKeyUsage()
    }

    private func saveGeminiKey() {
        let trimmed = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        GigiConfig.setGeminiAPIKey(trimmed)
        refreshKeyUsage()
    }

    private func removeGroqKey() {
        GigiKeychain.delete(forKey: GigiKeychain.Key.groqAPIKey)
        groqKey = ""
        connectionStatus = "Removed"
        refreshKeyUsage()
    }

    private func removeGeminiKey() {
        GigiKeychain.delete(forKey: GigiKeychain.Key.geminiAPIKey)
        geminiKey = ""
        refreshKeyUsage()
    }

    private func refreshKeyUsage() {
        groqUsage = GigiAPIKeyUsageStore.snapshot(provider: "groq")
        geminiUsage = GigiAPIKeyUsageStore.snapshot(provider: "gemini")
    }

    private func keyDisplay(_ key: String) -> String {
        guard !key.isEmpty else { return "No local key saved" }
        if revealConnectedKeys { return key }
        let prefix = key.prefix(6)
        let suffix = key.suffix(4)
        return "\(prefix)...\(suffix)"
    }

    private func usageDisplay(_ usage: GigiAPIKeyUsageSnapshot) -> String {
        guard usage.requests > 0 else { return "Local usage: no requests yet" }
        let tokenText = usage.totalTokens > 0 ? "\(usage.totalTokens.formatted()) tokens" : "tokens unavailable"
        let last = usage.lastUsedAt.map { relativeDateFormatter.localizedString(for: $0, relativeTo: Date()) } ?? "unknown"
        return "Local usage: \(usage.requests) req · \(tokenText) · \(last)"
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


private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
}()

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
