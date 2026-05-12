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

    // Phase 2 GATE 4 — Ollama (Path 3) status snapshot. Refreshed on appear
    // and on explicit "Re-check" tap. Driven by GigiHarnessClient.localLLMStatus.
    @State private var ollamaStatus: GigiHarnessClient.LocalLLMStatus? = nil
    @State private var ollamaTier: String = UserDefaults.standard.string(forKey: "gigi.ollama.tier") ?? "default"
    @State private var ollamaProbing: Bool = false

    // 2026-05-12 batch 4 — Fix-Automatically (install ollama + pull model)
    @State private var ollamaInstall: GigiHarnessClient.OllamaInstallStatus? = nil
    @State private var ollamaFixing: Bool = false
    @State private var ollamaFixLog: String = ""
    @State private var ollamaFixProgress: Int = 0
    @State private var showModelPicker: Bool = false
    @State private var pickerSelectedTier: String = "default"
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
                myShortcutsSection
                voiceSection
                privacySection
                modesSection
                ollamaSection
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

    // MARK: - My Shortcuts section (GATE 14.B.2 lite)
    //
    // User-declared registry of Apple Shortcuts that GIGI can invoke for
    // limit cases (Apple-closed APIs like Notes write) and for natural-
    // language aliasing of user-installed Shortcuts.

    private var myShortcutsSection: some View {
        Section {
            NavigationLink {
                MyShortcutsView()
            } label: {
                HStack {
                    Image(systemName: "command.square.fill")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("My Shortcuts")
                        let count = GigiShortcutRegistry.shared.shortcuts.count
                        if count > 0 {
                            Text("\(count) registered")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("None registered")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("⚡️ Shortcuts Integration")
        } footer: {
            Text("Register your Apple Shortcuts so GIGI can invoke them — for Notes append, custom routines, or natural-language aliases.")
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

            // Phase 2 — Apple FM Tool calling feature flag
            Toggle(isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "gigi.feature.path2_apple_fm_tools") == nil
                       || UserDefaults.standard.bool(forKey: "gigi.feature.path2_apple_fm_tools") },
                set: { UserDefaults.standard.set($0, forKey: "gigi.feature.path2_apple_fm_tools") }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Apple FM Tool calling (Path 2)")
                    Text("When ON, native_tool dispatch runs through respondWithTools (1-2s, best slot quality). When OFF, slots from the router are mapped directly to bridge.execute (80-200ms).")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // 2026-05-12 batch 7+9 — Captured logs viewer with live reload
            CapturedLogsView()

            // Phase 2 — Last router decision viewer (debug overlay, auto-reload)
            LastRouterDecisionView()
            #endif
        } header: {
            Text("🔧 Debug")
        }
    }

    // MARK: - Modes section (Phase 2 — GATE 7)

    private var modesSection: some View {
        Section {
            NavigationLink {
                ModesSelectionView()
            } label: {
                HStack {
                    Image(systemName: "switch.2")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Operating Mode")
                            .font(.body)
                        Text(currentModeLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        } header: {
            Text("⚙️ Modes")
        } footer: {
            Text("Switch between Minimal · Local-First · Apple Optimized · Full Power based on which infrastructure you have available.")
        }
    }

    private var currentModeLabel: String {
        let raw = UserDefaults.standard.string(forKey: "gigi.user.mode") ?? GigiMode.fullPower.rawValue
        let mode = GigiMode(rawValue: raw) ?? .fullPower
        return "Active: \(mode.displayName)"
    }

    // MARK: - Ollama section (Phase 2 — GATE 4)

    private var ollamaSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: ollamaStatusIcon)
                    .foregroundColor(ollamaStatusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ollama (Path 3)")
                        .font(.body)
                    Text(ollamaStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if ollamaProbing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await refreshOllamaStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            Picker("Tier", selection: $ollamaTier) {
                Text("Lite (4-8GB · qwen3:4b)").tag("lite")
                Text("Standard (8-16GB · qwen3:8b)").tag("standard")
                Text("Default (16-32GB · qwen3:14b)").tag("default")
                Text("Pro (32GB+ · qwen3.6:27b)").tag("pro")
            }
            .onChange(of: ollamaTier) { _, new in
                UserDefaults.standard.set(new, forKey: "gigi.ollama.tier")
            }

            if let s = ollamaStatus, let models = s.models, !models.isEmpty {
                DisclosureGroup("Installed models (\(models.count))") {
                    ForEach(models, id: \.self) { m in
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            Text(m).font(.caption.monospaced())
                        }
                    }
                }
                .font(.caption)
            }

            // 2026-05-12 batch 4 — Fix Automatically
            ollamaFixAutomaticallyRow

        } header: {
            Text("🦙 Ollama")
        } footer: {
            Text("Path 3 runs reasoning locally on the harness via Ollama (no cloud, no API). Pick a tier that fits your harness RAM. Recommended: \(ollamaStatus?.currentTier ?? "default").")
        }
        .task { await refreshOllamaStatus() }
        .sheet(isPresented: $showModelPicker) {
            ollamaModelPickerSheet
        }
    }

    // MARK: - Ollama Fix Automatically (2026-05-12 batch 4)

    @ViewBuilder
    private var ollamaFixAutomaticallyRow: some View {
        if !GigiHarnessClient.shared.isConfigured {
            // 2026-05-12 fix: was showing "Probing Ollama install state..."
            // infinite when harness not paired (it's a chicken-egg — we can't
            // probe Ollama without the harness). Now: clear actionable status.
            HStack(spacing: 8) {
                Image(systemName: "link.badge.plus")
                    .foregroundColor(.orange)
                Text("Harness not paired — pair it from Settings → Harness first to probe Ollama.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else if let install = ollamaInstall {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: install.nextAction == "ready" ? "checkmark.seal.fill" : "wand.and.sparkles")
                        .foregroundColor(install.nextAction == "ready" ? .green : .accentColor)
                    Text(ollamaFixSubtitle(install))
                        .font(.subheadline)
                    Spacer()
                }

                if ollamaFixing {
                    if ollamaFixProgress > 0 {
                        ProgressView(value: Double(ollamaFixProgress), total: 100)
                    }
                    if !ollamaFixLog.isEmpty {
                        ScrollView {
                            Text(ollamaFixLog)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(6)
                    }
                } else if install.nextAction != "ready" {
                    Button {
                        Task { await runOllamaFixAutomatically(start: install) }
                    } label: {
                        HStack {
                            Image(systemName: "wand.and.sparkles")
                            Text("Fix Automatically").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Probing Ollama install state...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func ollamaFixSubtitle(_ install: GigiHarnessClient.OllamaInstallStatus) -> String {
        switch install.nextAction {
        case "install-ollama":     return "Ollama not installed on harness host."
        case "start-ollama-daemon": return "Ollama installed but daemon not running."
        case "pull-model":         return "No compatible model installed. Pick a tier to pull."
        case "ready":              return "Ollama ready · \(install.installedCompatibleModels.count) compatible model(s)."
        default:                    return install.nextAction
        }
    }

    @ViewBuilder
    private var ollamaModelPickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Which model tier do you want to pull? Larger models give better answers but need more RAM and disk.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(["lite", "standard", "default", "pro"], id: \.self) { tier in
                    let modelName = ollamaInstall?.compatibleTiers[tier] ?? "?"
                    let alreadyInstalled = (ollamaInstall?.installedModels ?? []).contains(modelName)
                    Button {
                        showModelPicker = false
                        Task { await runOllamaPull(model: modelName, tier: tier) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(tier.capitalized).fontWeight(.medium)
                                    if alreadyInstalled {
                                        Text("INSTALLED")
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundColor(.green)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(modelName)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                                Text(ollamaTierHint(tier))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if !alreadyInstalled {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(alreadyInstalled)
                }
            }
            .navigationTitle("Pull Ollama Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showModelPicker = false }
                }
            }
        }
    }

    private func ollamaTierHint(_ tier: String) -> String {
        switch tier {
        case "lite":     return "Min 4-8GB RAM · ~2.5GB disk · fastest"
        case "standard": return "Min 8-16GB RAM · ~5GB disk · balanced"
        case "default":  return "Min 16-32GB RAM · ~9GB disk · recommended"
        case "pro":      return "Min 32GB+ RAM · ~16GB disk · max quality"
        default:         return ""
        }
    }

    @MainActor
    private func runOllamaFixAutomatically(start install: GigiHarnessClient.OllamaInstallStatus) async {
        ollamaFixing = true
        ollamaFixLog = ""
        ollamaFixProgress = 0
        defer { ollamaFixing = false }

        switch install.nextAction {
        case "install-ollama":
            ollamaFixLog = "Installing Ollama via platform package manager...\n"
            for await ev in GigiHarnessClient.shared.installOllama() {
                handleSetupEvent(ev)
            }
            // After install, re-probe + chain to pull-model if needed
            await refreshOllamaStatus()
            if let after = ollamaInstall, after.nextAction == "pull-model" {
                showModelPicker = true
            }
        case "start-ollama-daemon":
            ollamaFixLog = "Ollama is installed but daemon is not running. On the harness, run: ollama serve\n"
        case "pull-model":
            showModelPicker = true
        case "ready":
            ollamaFixLog = "Already ready."
        default:
            ollamaFixLog = "Unknown state: \(install.nextAction)\n"
        }
    }

    @MainActor
    private func runOllamaPull(model: String, tier: String) async {
        ollamaFixing = true
        ollamaFixLog = "Pulling \(model)...\n"
        ollamaFixProgress = 0
        defer { ollamaFixing = false }
        for await ev in GigiHarnessClient.shared.pullOllamaModel(model) {
            handleSetupEvent(ev)
        }
        // Save tier choice + re-probe
        UserDefaults.standard.set(tier, forKey: "gigi.ollama.tier")
        ollamaTier = tier
        await refreshOllamaStatus()
    }

    @MainActor
    private func handleSetupEvent(_ ev: GigiHarnessClient.OllamaSetupEvent) {
        switch ev {
        case .thought(let text):
            ollamaFixLog += text + "\n"
            if ollamaFixLog.count > 4000 {
                ollamaFixLog = String(ollamaFixLog.suffix(4000))
            }
        case .progress(let pct, let status):
            ollamaFixProgress = pct
            ollamaFixLog += "  [\(pct)%] \(status)\n"
            if ollamaFixLog.count > 4000 {
                ollamaFixLog = String(ollamaFixLog.suffix(4000))
            }
        case .done(let status):
            ollamaFixLog += "✓ Done · \(status)\n"
            ollamaFixProgress = 100
        case .error(let msg):
            ollamaFixLog += "✗ Error · \(msg)\n"
        }
    }

    private var ollamaStatusIcon: String {
        if let s = ollamaStatus { return s.reachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
        return "circle.dotted"
    }
    private var ollamaStatusColor: Color {
        if let s = ollamaStatus { return s.reachable ? .green : .orange }
        return .secondary
    }
    private var ollamaStatusText: String {
        // Fix 2026-05-12: distinguish "probing" from "not paired" from "result"
        guard GigiHarnessClient.shared.isConfigured else {
            return "Harness not paired"
        }
        guard let s = ollamaStatus else {
            return ollamaProbing ? "Probing..." : "No data — tap refresh"
        }
        if !s.reachable { return "Unreachable. Start `ollama serve` on the harness." }
        let count = s.models?.count ?? 0
        return "Reachable · \(count) model\(count == 1 ? "" : "s") installed"
    }

    @MainActor
    private func refreshOllamaStatus() async {
        ollamaProbing = true
        defer { ollamaProbing = false }
        guard GigiHarnessClient.shared.isConfigured else {
            ollamaStatus = nil
            ollamaInstall = nil
            return
        }
        // Parallel probe: lightweight status + granular install state
        async let s = GigiHarnessClient.shared.localLLMStatus()
        async let i = GigiHarnessClient.shared.ollamaInstallStatus()
        let (status, install) = await (s, i)
        ollamaStatus = status
        ollamaInstall = install
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
            return "Normal flow: NLU fast-path → GigiRequestRouter 5-path (Apple FM router → native_tool / delegate_local / delegate_cloud / ask_clarification / reject)."
        case .appleFM:
            return "Force Apple FM Tool calling (Path 2). Bypasses the router and dispatches directly via GigiFoundationAgent. Requires iOS 18.1+ with Apple Intelligence."
        case .ollama:
            return "Force Ollama Path 3. Streams response from the harness Ollama bridge. Requires `ollama serve` on the harness host + Qwen 3 model pulled."
        case .claude:
            return "Force Claude Code Path 4. Spawns Claude Code subprocess on the harness via GigiClaudeBridge.run (legacy fallback active until GATE 5 finalization)."
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
