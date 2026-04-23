import SwiftUI

// MARK: - SettingsView (T-24)
//
// All configuration in one place: API keys, wake word, privacy, debug.

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

    var body: some View {
        NavigationStack {
            List {
                brainSection
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
                        .onSubmit { saveGeminiKey() }
                } else {
                    SecureField("Groq API Key", text: $geminiKey)
                        .font(.system(.body, design: .monospaced))
                        .submitLabel(.done)
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
