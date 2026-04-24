import SwiftUI

// MARK: - SettingsView (T-24)
//
// All configuration in one place: API keys, wake word, privacy, debug.

enum SettingsField: Hashable {
    case geminiKey, harnessURL, harnessSecret
}

struct SettingsView: View {
    @State private var geminiKey = ""   // bound to Groq key slot
    @State private var picoKey = ""
    @State private var showKey = false
    @State private var connectionStatus: String = "—"
    @State private var isTestingConnection = false
    @State private var wakeWordEnabled = UserDefaults.standard.bool(forKey: GigiWakeWordEngine.userDefaultsEnabledKey)
    @State private var ttsRate: Double = 0.52
    @State private var memoryCount = 0
    @State private var showClearMemoryAlert = false
    @State private var showResetOnboarding = false
    @State private var accessoryList: [String] = []
    @State private var showWhatsApp = false
    @State private var showProfile = false
    @State private var harnessURL = ""
    @State private var harnessSecret = ""
    @State private var harnessStatus = "—"
    @State private var isTestingHarness = false
    @State private var showPairingSheet = false
    @State private var pairedDeviceName: String? = nil
    @FocusState var focusedField: SettingsField?

    var body: some View {
        NavigationStack {
            List {
                brainSection
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
            .sheet(isPresented: $showWhatsApp) { WhatsAppLinkSheet() }
            .sheet(isPresented: $showProfile) { ProfileEditSheet() }
        }
    }

    // MARK: - Brain section

    private var brainSection: some View {
        Section {
            // Inline key editor
            HStack {
                if showKey {
                    TextField("gsk_...", text: $geminiKey)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focusedField, equals: .geminiKey)
                        .onSubmit { saveGeminiKey() }
                } else {
                    SecureField("Groq API Key", text: $geminiKey)
                        .font(.system(.body, design: .monospaced))
                        .submitLabel(.done)
                        .focused($focusedField, equals: .geminiKey)
                        .onSubmit { saveGeminiKey() }
                }
                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                Button(action: saveGeminiKey) {
                    Text("Save")
                        .foregroundColor(.purple)
                        .fontWeight(.semibold)
                }
                .disabled(geminiKey.isEmpty)
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

    // MARK: - Harness section (backend GIGI)

    private var harnessSection: some View {
        Section {
            // Primary action: pair via QR
            Button {
                showPairingSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18))
                    Text(harnessIsPaired ? "Ri-pair con Harness" : "Pair con Harness")
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .foregroundColor(.purple)
                .padding(.vertical, 4)
            }

            // Status line
            HStack {
                Text("Stato")
                Spacer()
                if isTestingHarness {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text(harnessStatus)
                        .foregroundColor(harnessStatus.contains("✓") ? .green : .secondary)
                        .font(.subheadline)
                }
            }

            // Re-test + unpair
            if harnessIsPaired {
                Button("Verifica connessione") {
                    Task { await testHarnessHealthOnly() }
                }
                .foregroundColor(.purple)
                .disabled(isTestingHarness)

                Button(role: .destructive) {
                    removePairing()
                } label: {
                    Text("Rimuovi pairing")
                }
            }

            // Advanced: manual config still available for power users / debug.
            DisclosureGroup("Configurazione manuale (avanzata)") {
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
                    SecureField("shared secret 32 char", text: $harnessSecret)
                        .font(.system(.body, design: .monospaced))
                        .focused($focusedField, equals: .harnessSecret)
                }
                Button("Salva e testa") {
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
            Text("Installa Tailscale su PC + iPhone (stesso account), apri localhost:7777/pair nel browser del PC e scansiona il QR. Una-tantum, poi funziona da qualsiasi rete.")
                .font(.caption)
        }
        .sheet(isPresented: $showPairingSheet) {
            GigiPairingSheet { deviceName in
                pairedDeviceName = deviceName
                harnessStatus = "✓ Connesso a \(deviceName)"
            }
        }
    }

    private var harnessIsPaired: Bool {
        (GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL)?.isEmpty == false) &&
        (GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret)?.isEmpty == false)
    }

    private func removePairing() {
        GigiKeychain.delete(forKey: GigiKeychain.Key.harnessBaseURL)
        GigiKeychain.delete(forKey: GigiKeychain.Key.harnessSecret)
        harnessURL = ""
        harnessSecret = ""
        harnessStatus = "non configurato"
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
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }

            let picoSet = !GigiConfig.picovoiceAccessKey.isEmpty
            HStack {
                Text("Picovoice Key")
                Spacer()
                Image(systemName: picoSet ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(picoSet ? .green : .orange)
                Text(picoSet ? "Set" : "Required for custom keyword")
                    .foregroundColor(picoSet ? .green : .orange)
                    .font(.caption)
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
        if !existing.isEmpty { geminiKey = existing }
        harnessURL = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL) ?? ""
        harnessSecret = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret) ?? ""
        harnessStatus = GigiHarnessClient.shared.isConfigured ? "configurato (non testato)" : "non configurato"
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
            harnessStatus = "URL e secret non possono essere vuoti"
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
        isTestingHarness = false
    }

    /// Idempotent health-only check. Reads the Keychain (authoritative
    /// source, populated by the pair sheet) and pings `/api/ios/health`.
    /// Never writes. This is the only action safe to expose post-pair.
    private func testHarnessHealthOnly() async {
        isTestingHarness = true
        defer { isTestingHarness = false }
        guard GigiHarnessClient.shared.isConfigured else {
            harnessStatus = "✗ Harness non configurato (URL/secret mancanti)"
            return
        }
        switch await GigiHarnessClient.shared.health() {
        case .success(let h):
            harnessStatus = "✓ OK · pid \(h.pid) · uptime \(h.uptime_s)s"
        case .failure(let e):
            harnessStatus = "✗ \(e)"
        }
    }

    private func saveGeminiKey() {
        let trimmed = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        GigiConfig.setGroqAPIKey(trimmed)
        connectionStatus = "Key saved"
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
