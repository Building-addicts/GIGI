import SwiftUI

// MARK: - SettingsView (T-24)
//
// All configuration in one place: API keys, wake word, privacy, debug.

enum SettingsField: Hashable {
    case harnessURL, harnessSecret
}

private enum SettingsSheet: String, Identifiable {
    case whatsApp
    case profile
    case pairing
    case diagnostics

    var id: String { rawValue }
}

struct SettingsView: View {
    // Groq-related @State removed (2026-05-11): groqKey, showKey,
    // connectionStatus, isTestingConnection. Groq backend gone.
    @State private var showQRScanner = false
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
    #if DEBUG
    // D1 — Brain Path Override picker (DEBUG only). Lets you force a specific
    // routing path during testing instead of relying on automatic gate decisions.
    // - .auto: normal flow (NLU fast-path → Groq planner/agent loop)
    // - .appleFM: forces a direct GigiFoundationAgent.process() call (stub-equivalent
    //   for Path 2 of the 5-path plan)
    // - .ollama: stub — shows "not configured" toast (Path 3 not yet implemented)
    // - .claude: same effect as forceClaude=true
    @State private var brainPathOverride: BrainPathOverride =
        BrainPathOverride(rawValue: UserDefaults.standard.string(forKey: "gigi.debug.brainPath") ?? "auto") ?? .auto
    #endif
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

    // MARK: - Brain section (no-Groq, 2026-05-11)
    //
    // Groq backend removed from the main flow. The AI brain is now the harness
    // Claude bridge for any non-NLU query. Apple FM router upfront comes in
    // GATE 2 of the 5-path plan. Local NLU fast-path covers 24 instant intents.

    private var brainSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Harness Claude (primary)")
                        .font(.body.weight(.medium))
                    Text(GigiHarnessClient.shared.isConfigured
                         ? "Paired — handling non-NLU turns"
                         : "Not paired — pair from Harness section below")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "applelogo")
                    .foregroundColor(.purple.opacity(0.7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence (Phase 2)")
                        .font(.body.weight(.medium))
                    Text(GigiFoundationAgent.isSupported
                         ? "Available — router upfront in GATE 2"
                         : "Not available on this device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("🧠 AI Brain")
        } footer: {
            Text("Groq backend removed on 2026-05-11. The 5-path plan introduces Apple FM router + Ollama harness + Claude Code subprocess across GATE 2-5. Until then, every non-NLU query is routed to the harness Claude bridge.")
                .font(.caption)
        }
    }

    // MARK: - Brain Mode section (no-Groq, DEBUG only)

    @ViewBuilder
    private var brainModeSection: some View {
        #if DEBUG
        Section {
            Toggle(isOn: $forceClaude) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Force Claude")
                        .font(.body.weight(.medium))
                    Text("Already the default after Groq removal — kept as a DEBUG toggle for parity with the legacy code path.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(.purple)
            .onChange(of: forceClaude) { _, new in
                GigiKeychain.saveBool(new, forKey: GigiKeychain.Key.forceClaude)
            }
        } header: {
            Text("🧠 Brain Mode (DEBUG)")
        } footer: {
            Text("Force Claude toggle is a vestigial flag — the main flow now always routes non-NLU queries to harness Claude. Removed entirely when GATE 2 lands the Apple FM router.")
                .font(.caption)
        }
        #endif
    }

    // MARK: - Harness section (backend GIGI)

    // Tailscale migration banner removed (2026-05-11): post-Phase 4 the only
    // supported pairing transport is Cloudflare Tunnel via QR scan. Tailscale
    // is no longer a fallback path. ADR-0001 §pairing-cloudflare-tunnel-mvp.

    private var harnessSection: some View {
        Section {

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

            // Manual configuration (DEBUG only — power users / pairing recovery).
            // QR pair flow is the official path; this is a fallback for testing.
            #if DEBUG
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
            #endif
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
    //
    // 2026-05-11 D2 trim: simplified accessory list rendering with icon
    // inference, replaced dev-noise footer with user-facing copy, removed
    // dead "Refresh Accessories" — `loadState()` already refreshes on app
    // focus + sheet dismiss. Accessory voice control runs through
    // GigiActionDispatcher → GigiHomeKit (homekit_on / homekit_off /
    // homekit_dim / homekit_scene tools).

    private var homeKitSection: some View {
        Section {
            if accessoryList.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No accessories detected")
                        .foregroundColor(.secondary)
                    Text("Open the Home app on iPhone to pair accessories, then return here.")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            } else {
                ForEach(accessoryList.prefix(5), id: \.self) { name in
                    HStack {
                        Image(systemName: homeKitIcon(for: name))
                            .foregroundColor(.orange)
                        Text(name)
                    }
                }
                if accessoryList.count > 5 {
                    Text("+ \(accessoryList.count - 5) more")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }
        } header: {
            Text("🏠 HomeKit")
        } footer: {
            Text("Control accessories with your voice — \"turn off the kitchen light\", \"set the thermostat to 21\".")
                .font(.caption)
        }
    }

    /// Pick an SF Symbol that loosely matches the accessory name.
    private func homeKitIcon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("light") || n.contains("lamp") || n.contains("bulb") { return "lightbulb.fill" }
        if n.contains("therm") || n.contains("heat") || n.contains("cool") { return "thermometer.medium" }
        if n.contains("lock") || n.contains("door") { return "lock.fill" }
        if n.contains("plug") || n.contains("outlet") || n.contains("switch") { return "poweroutlet.type.b.fill" }
        if n.contains("cam") { return "video.fill" }
        if n.contains("speaker") || n.contains("audio") { return "hifispeaker.fill" }
        if n.contains("fan") { return "fanblades" }
        return "house.fill"
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
    //
    // 2026-05-11 trim: removed 5 one-off test buttons (Brain Diagnostics, Task
    // Extractor tests x3, Tone Enrichment playground with Italian seed). Kept:
    // - Harness pairing state info
    // - Replay Onboarding (testing convenience)
    // - Brain Path Override picker (D1, DEBUG only) — lets you force routing
    //   to Apple FM / Ollama / Claude for testing the 5-path plan before it
    //   is fully wired in.

    private var debugSection: some View {
        Section {
            HStack(alignment: .top) {
                Text("Harness pairing")
                Spacer()
                Text(GigiHarnessClient.shared.pairingState.debugLabel)
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
            }

            Button("Replay Onboarding") {
                UserDefaults.standard.removeObject(forKey: "gigi.onboarding.complete")
                showResetOnboarding = true
            }
            .foregroundColor(.orange)
            .alert("Onboarding Reset", isPresented: $showResetOnboarding) {
                Button("OK") {}
            } message: {
                Text("Restart the app to see onboarding again.")
            }

            #if DEBUG
            // D1 — Brain Path Override (5-path plan testing harness)
            VStack(alignment: .leading, spacing: 8) {
                Text("Brain Path Override (DEBUG)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Brain Path", selection: $brainPathOverride) {
                    ForEach(BrainPathOverride.allCases, id: \.self) { path in
                        Text(path.displayLabel).tag(path)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: brainPathOverride) { _, newValue in
                    UserDefaults.standard.set(newValue.rawValue, forKey: "gigi.debug.brainPath")
                    print("DEBUG[D1] brain path override → \(newValue.rawValue)")
                }
                Text(brainPathOverride.helpText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            #endif
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
                Text(GigiFoundationAgent.isSupported ? "Harness Claude + Apple Intelligence (Phase 2 ready)" : "Harness Claude")
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
        // groqKey load removed (2026-05-11): Groq backend removed from main flow.
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

    // saveGroqKey() + testConnection() removed (2026-05-11): Groq backend
    // removed from main flow. AI brain is now harness Claude (no API key needed).
}


private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

#if DEBUG
// MARK: - Brain Path Override (D1, debug-only)
//
// Lets the developer force a specific routing path during testing — useful for
// previewing how the 5-path plan will feel before it is fully wired up.
// Persisted in UserDefaults so changes survive across app launches.
//
// Read in GigiAgentEngine.process() — see overrideBrainPath() helper.

enum BrainPathOverride: String, CaseIterable {
    case auto      // normal flow (NLU fast-path → Groq planner/agent loop)
    case appleFM   // forces direct call to GigiFoundationAgent.process()
    case ollama    // stub — surfaces "Path 3 not configured" message
    case claude    // forces Claude Code path (equivalent to forceClaude=true)

    var displayLabel: String {
        switch self {
        case .auto:    return "Auto"
        case .appleFM: return "Apple FM"
        case .ollama:  return "Ollama"
        case .claude:  return "Claude"
        }
    }

    var helpText: String {
        switch self {
        case .auto:
            return "Normal flow: NLU fast-path → Groq planner / agent loop."
        case .appleFM:
            return "Path 2 (5-path plan): direct Apple Foundation Models call. Requires iOS 18.1+ with Apple Intelligence."
        case .ollama:
            return "Path 3 (5-path plan): STUB — surfaces a 'not configured' message until harness Ollama lands."
        case .claude:
            return "Path 4 (5-path plan): forces Claude Code subprocess via harness (same effect as Brain Mode → Force Claude)."
        }
    }
}

/// Helper read by GigiAgentEngine.process() to honor the debug override.
@MainActor
enum DebugBrainPath {
    static var current: BrainPathOverride {
        BrainPathOverride(rawValue: UserDefaults.standard.string(forKey: "gigi.debug.brainPath") ?? "auto") ?? .auto
    }
}
#endif
