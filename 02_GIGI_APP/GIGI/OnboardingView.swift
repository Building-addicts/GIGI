import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import AVFoundation
import Speech
import Contacts
import EventKit
import UserNotifications

// MARK: - OnboardingView
//
// Multi-step onboarding: welcome → permissions → API keys (Groq + Gemini) →
// harness (Mac backend URL+secret, skippable) → profile → wake word → done.
// Only shown once (UserDefaults flag). Permissions are requested in-flow.

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var step = 0
    @State private var apiKey = ""
    @State private var geminiKey = ""
    @State private var showKey = false
    @State private var showGemini = false
    @State private var micGranted = false
    @State private var contactsGranted = false
    @State private var calendarGranted = false
    @State private var notifGranted = false
    @State private var isRequestingPermissions = false
    @State private var shortcutSetupStatus = ""

    // Harness step
    @State private var harnessURL = ""
    @State private var harnessSecret = ""
    @State private var harnessStatus = ""   // "", "testing", "ok:<pid>", "fail:<err>"
    @State private var isTestingHarness = false
    @State private var showPairingSheet = false

    // Profile step
    @State private var profileName = ""
    @State private var profileEmail = ""
    @State private var profilePhone = ""
    @State private var profileAddress = ""
    @State private var profileCity = ""
    @State private var profileZip = ""
    @State private var isSavingProfile = false

    private let totalSteps = 7

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress dots
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Circle()
                            .fill(i <= step ? Color.purple : Color.white.opacity(0.2))
                            .frame(width: 8, height: 8)
                            .animation(.easeInOut, value: step)
                    }
                }
                .padding(.top, 56)

                Spacer()

                // Step content
                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: permissionsStep
                    case 2: apiKeyStep
                    case 3: harnessStep
                    case 4: profileStep
                    case 5: hardwareTriggerStep
                    case 6: doneStep
                    default: EmptyView()
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.35), value: step)

                Spacer()

                // Navigation
                HStack {
                    if step > 0 {
                        Button("Back") { withAnimation { step -= 1 } }
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Button(step < totalSteps - 1 ? "Continue" : "Let's go") {
                        handleContinue()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Color.purple)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
            }
        }
        .preferredColorScheme(.dark)
        .task { loadExistingKey() }
        .fullScreenCover(isPresented: $showPairingSheet) {
            GigiPairingSheet(onPaired: { deviceName in
                showPairingSheet = false
                if let u = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL) { harnessURL = u }
                if let s = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret) { harnessSecret = s }
                harnessStatus = "ok:\(deviceName)"
            })
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.purple)

            Text("GIGI")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("Your autonomous AI on iPhone.\nVoice-first in the app, with Presence when you enable it.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 32)
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            Text("Permissions")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("GIGI needs these to act on your behalf.")
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                permissionRow("Microphone", icon: "mic.fill", granted: micGranted)
                permissionRow("Contacts", icon: "person.fill", granted: contactsGranted)
                permissionRow("Calendar", icon: "calendar", granted: calendarGranted)
                permissionRow("Notifications", icon: "bell.fill", granted: notifGranted)
            }
            .padding(.horizontal, 24)

            if !isRequestingPermissions {
                Button("Request all permissions") {
                    Task { await requestAllPermissions() }
                }
                .foregroundColor(.purple)
                .padding(.top, 8)
            } else {
                ProgressView().tint(.purple)
            }
        }
    }

    private var apiKeyStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "key.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.purple)

                Text("Connect your AI")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("GIGI is free forever. Plug in your own keys — we never bill you.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 28)

                // Groq (brain)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Groq key — brain (required)")
                        .font(.caption).foregroundColor(.white.opacity(0.5))
                    HStack {
                        if showKey {
                            TextField("gsk_...", text: $apiKey)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Paste Groq key (gsk_...)", text: $apiKey)
                                .font(.system(.body, design: .monospaced))
                        }
                        Button(action: { showKey.toggle() }) {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.4), lineWidth: 1))
                    Text("Free at console.groq.com → API Keys")
                        .font(.caption2).foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 24)

                // Gemini (realtime voice)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gemini key — realtime voice (optional)")
                        .font(.caption).foregroundColor(.white.opacity(0.5))
                    HStack {
                        if showGemini {
                            TextField("AIza...", text: $geminiKey)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Paste Gemini key (AIza...)", text: $geminiKey)
                                .font(.system(.body, design: .monospaced))
                        }
                        Button(action: { showGemini.toggle() }) {
                            Image(systemName: showGemini ? "eye.slash" : "eye")
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.4), lineWidth: 1))
                    Text("Free tier at aistudio.google.com/apikey. Without it, voice falls back to on-device TTS (slower, flat).")
                        .font(.caption2).foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 8)
        }
    }

    private var harnessStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.purple)

                Text("Connect your Mac brain")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("Optional but unlocks computer-use, proactive briefings and cross-device.\nRun the harness on your Mac, then paste URL + secret here.\nSkip if you don't have one yet.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 24)

                // QR scan shortcut
                Button {
                    showPairingSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                        Text("Scan QR from Mac terminal")
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Color.purple)
                    .clipShape(Capsule())
                }

                Text("— or enter manually —")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.3))

                VStack(spacing: 10) {
                    TextField("http://10.0.0.5:7779", text: $harnessURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .padding(14)
                        .background(Color.white.opacity(0.07))
                        .cornerRadius(12)

                    SecureField("shared secret 32 char", text: $harnessSecret)
                        .font(.system(.body, design: .monospaced))
                        .padding(14)
                        .background(Color.white.opacity(0.07))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)

                if isTestingHarness {
                    ProgressView().tint(.purple)
                } else if !harnessStatus.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: harnessStatus.hasPrefix("ok") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(harnessStatus.hasPrefix("ok") ? .green : .red)
                        Text(harnessStatus.hasPrefix("ok") ? "Connected ✓" : harnessStatus)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }

                Button("Test & save") { Task { await testAndSaveHarness() } }
                    .foregroundColor(.white)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Color.purple)
                    .clipShape(Capsule())
                    .disabled(harnessURL.isEmpty || harnessSecret.isEmpty || isTestingHarness)
            }
            .padding(.vertical, 8)
        }
    }

    private var profileStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.purple)

                Text("Your Profile")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("GIGI uses this to fill forms, book restaurants, and order for you automatically. You can skip and add later.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 24)

                VStack(spacing: 10) {
                    profileField("Full name", text: $profileName,
                                 icon: "person.fill", keyboard: .default)
                    profileField("Email", text: $profileEmail,
                                 icon: "envelope.fill", keyboard: .emailAddress)
                    profileField("Phone", text: $profilePhone,
                                 icon: "phone.fill", keyboard: .phonePad)

                    Divider().background(Color.white.opacity(0.15)).padding(.vertical, 4)

                    Text("Delivery address")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    profileField("Street address", text: $profileAddress,
                                 icon: "house.fill", keyboard: .default)
                    profileField("City", text: $profileCity,
                                 icon: "mappin.circle.fill", keyboard: .default)
                    profileField("ZIP / Postal code", text: $profileZip,
                                 icon: "number", keyboard: .numberPad)
                }
                .padding(.horizontal, 24)

                if isSavingProfile {
                    ProgressView().tint(.purple)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func profileField(
        _ placeholder: String,
        text: Binding<String>,
        icon: String,
        keyboard: UIKeyboardType
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.purple)
                .frame(width: 22)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .foregroundColor(.white)
        }
        .padding(14)
        .background(Color.white.opacity(0.07))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color.purple.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Hardware trigger step (#102)
    //
    // Replaces the old wake-word step. iOS does not allow continuous background
    // mic for non-VoIP apps, so wake word is paused for MVP. Hardware triggers
    // (Back Tap on iPhone 14, Action Button on iPhone 15 Pro+) plus Siri phrases
    // open GIGI in <1s from any state. We can't deep-link into iOS Accessibility
    // settings, so we walk the user through the steps and provide a quick test
    // button that fires the same code path the trigger will hit.

    private var hardwareTriggerStep: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.purple)

                Text("Talk to GIGI without opening the app")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("GIGI uses two Shortcuts as a bridge. Listen wakes the app into Dynamic Island listening; Execute is the hidden native-action executor that GIGI calls after it understands you.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 28)

                // ── Setup 1: explain and install the split Shortcuts ──
                //
                // GIGI-Listen is the visible hardware trigger and only opens
                // gigi://listen. GIGI-Execute is a hidden marker executor
                // called by the app after the orchestrator routes a command.
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Step 1 — Connect app + Shortcuts", systemImage: "1.circle.fill")
                    triggerRow(number: "a", title: "GIGI-Listen = the bridge. It opens gigi://listen and drops GIGI into Dynamic Island listening.")
                    triggerRow(number: "b", title: "GIGI-Execute = the worker. You install it once, but never tap it manually.")
                    triggerRow(number: "c", title: "When you speak a phone command, GIGI routes it first, then sends a marker like SYS:torch:on to GIGI-Execute.")
                    triggerRow(number: "d", title: "Already installed both? Skip the install buttons and run the two tests below.")
                    triggerRow(number: "e", title: "If you rebuild GIGI-Listen manually, do not pick a GIGI app action: add Apple URL with gigi://listen, then Apple Open URLs.")

                    Text("Result: your hardware trigger opens GIGI, GIGI listens, the orchestrator decides, and Shortcuts only executes the final native iOS action.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.55))

                    Button { openUniversalShortcutInstall() } label: {
                        Label("Install or update GIGI-Listen", systemImage: "square.and.arrow.down.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.purple.opacity(0.85))
                            .cornerRadius(10)
                    }
                    .padding(.top, 4)

                    Button { openExecutorShortcutInstall() } label: {
                        Label("Install or update GIGI-Execute", systemImage: "gearshape.2.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                    }

                    Button { openShortcutsApp() } label: {
                        Label("Open Shortcuts app", systemImage: "square.stack.3d.up.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(10)
                    }

                    if !shortcutSetupStatus.isEmpty {
                        Text(shortcutSetupStatus)
                            .font(.caption2)
                            .foregroundColor(.green.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.05))
                .cornerRadius(14)
                .padding(.horizontal, 20)

                // ── Verify app and Shortcut bridge separately ──
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Step 2 — Verify the bridge", systemImage: "2.circle.fill")
                    triggerRow(number: "a", title: "Test app listener proves gigi://listen works even before Shortcuts.")
                    triggerRow(number: "b", title: "Test GIGI-Listen proves the installed Shortcut calls back into the app.")
                    triggerRow(number: "c", title: "Test GIGI-Execute proves the app can pass a safe marker to the hidden executor.")

                    Button { openDirectListenURL() } label: {
                        Label("Test app listener", systemImage: "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.blue.opacity(0.8))
                            .cornerRadius(10)
                    }

                    Button { runShortcutByName(GigiHardwareShortcut.shortcutName) } label: {
                        Label("Test installed GIGI-Listen", systemImage: "play.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.green.opacity(0.85))
                            .cornerRadius(10)
                    }

                    Button { runExecutorSmokeTest() } label: {
                        Label("Test installed GIGI-Execute", systemImage: "bolt.badge.checkmark.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                    }

                    Text("The Execute test uses SYS:battery:, a safe read-only marker. If Shortcuts says it cannot find the Shortcut, the installed name is missing or different.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(14)
                .background(Color.white.opacity(0.05))
                .cornerRadius(14)
                .padding(.horizontal, 20)

                // ── Setup 3: bind the Shortcut to a hardware trigger ──
                //
                // Critical: bind the user Shortcut named GIGI-Listen, not the
                // hidden executor and not the generic App Shortcut entry.
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Step 3 — Bind it to your iPhone", systemImage: "3.circle.fill")
                    triggerRow(number: "a", title: "Open the iOS Settings app")
                    triggerRow(number: "b", title: hardwareTriggerPath)
                    triggerRow(number: "c", title: "Pick GIGI-Listen — not GIGI-Execute")

                    Text("If you pick GIGI-Execute, nothing will listen. GIGI-Execute is only the hidden native-action arm.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(14)
                .background(Color.white.opacity(0.05))
                .cornerRadius(14)
                .padding(.horizontal, 20)

                Text("No hardware setup? Say \"Hey Siri, GIGI-Listen\" after the Shortcut is installed, or open GIGI and tap the mic.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundColor(.purple)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
            Spacer()
        }
    }

    /// Opens the iOS Shortcuts app via its `shortcuts://` URL scheme. If the
    /// app is not installed (Shortcuts ships with iOS, so this is rare), the
    /// call is a no-op rather than a crash.
    private func openShortcutsApp() {
        #if canImport(UIKit)
        guard let url = URL(string: "shortcuts://") else { return }
        UIApplication.shared.open(url) { success in
            if !success {
                shortcutSetupStatus = "Could not open Shortcuts. Open the Shortcuts app manually and check that GIGI-Listen and GIGI-Execute exist."
            }
        }
        #endif
    }

    private func openUniversalShortcutInstall() {
        #if canImport(UIKit)
        if GigiShortcutInstaller.shared.presentInstallSheet(resourceName: GigiHardwareShortcut.listenResourceName) {
            shortcutSetupStatus = "Install sheet opened. Add or replace GIGI-Listen, then return here for the tests."
            return
        }
        if let url = GigiHardwareShortcut.listenICloudDownloadURL {
            UIApplication.shared.open(url)
        } else {
            openShortcutsApp()
        }
        #endif
    }

    private func openExecutorShortcutInstall() {
        #if canImport(UIKit)
        if GigiShortcutInstaller.shared.presentInstallSheet(resourceName: GigiHardwareShortcut.executorResourceName) {
            shortcutSetupStatus = "Install sheet opened. Add or replace GIGI-Execute, then return here for the tests."
            return
        }
        if let url = GigiHardwareShortcut.executorICloudDownloadURL {
            UIApplication.shared.open(url)
        } else {
            openShortcutsApp()
        }
        #endif
    }

    private func openDirectListenURL() {
        #if canImport(UIKit)
        shortcutSetupStatus = "Starting the same listener used by gigi://listen. Dynamic Island/listening should start now."
        PresenceSessionController.shared.beginListeningSession(reason: "onboarding-test")
        #endif
    }

    /// Runs a saved user Shortcut by name. This verifies the installed Shortcut
    /// exists with the expected name; Shortcuts surfaces a clear error sheet if
    /// no match is found.
    private func runShortcutByName(_ name: String) {
        #if canImport(UIKit)
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else {
            shortcutSetupStatus = "Could not build the Shortcuts URL for \(name)."
            return
        }
        shortcutSetupStatus = "Running \(name). If Shortcuts says it cannot find it, the installed Shortcut name is different."
        UIApplication.shared.open(url) { success in
            if !success {
                shortcutSetupStatus = "Could not open Shortcuts. Open Shortcuts manually and check the Shortcut name: \(name)."
            }
        }
        #endif
    }

    private func runExecutorSmokeTest() {
        #if canImport(UIKit)
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: GigiHardwareShortcut.executorShortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: "SYS:battery:"),
            URLQueryItem(name: "x-success", value: GigiHardwareShortcut.executorSuccessURLString),
            URLQueryItem(name: "x-cancel", value: GigiHardwareShortcut.executorCancelURLString),
        ]
        guard let url = components.url else {
            shortcutSetupStatus = "Could not build the GIGI-Execute test URL."
            return
        }
        shortcutSetupStatus = "Running GIGI-Execute with SYS:battery:. If Shortcuts says it cannot find it, install/rename GIGI-Execute."
        UIApplication.shared.open(url) { success in
            if !success {
                shortcutSetupStatus = "Could not open Shortcuts for GIGI-Execute. Open Shortcuts manually and check that GIGI-Execute exists."
            }
        }
        #endif
    }

    private func triggerRow(number: String, title: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.subheadline.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.purple))
            Text(title)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Picks Action Button copy for iPhone 15 Pro / 16 Pro / 17 Pro and Back Tap
    /// copy for everything else. We detect via the device model identifier rather
    /// than `UIDevice.current.model` (which only returns "iPhone").
    private var hardwareTriggerPath: String {
        if hasActionButton {
            return "Go to Action Button → Shortcut"
        } else {
            return "Go to Accessibility → Touch → Back Tap → Double Tap"
        }
    }

    private var hasActionButton: Bool {
        #if canImport(UIKit)
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "" }
        }
        // Action Button ships on iPhone 15 Pro family (iPhone16,1 / 16,2),
        // the entire iPhone 16 line (iPhone17,*), and the iPhone 17 family
        // (iPhone18,*). Anything older falls through to Back Tap.
        return identifier.hasPrefix("iPhone16,")
            || identifier.hasPrefix("iPhone17,")
            || identifier.hasPrefix("iPhone18,")
        #else
        return false
        #endif
    }

    private var doneStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            Text("You're all set.")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("Tap the mic to talk, or use the hardware shortcut you just set up.\n\nTry: \"Call Marco\", \"What's the weather?\", \"Set a timer for 10 minutes\"")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Permission row

    private func permissionRow(_ title: String, icon: String, granted: Bool) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.purple)
                .frame(width: 28)
            Text(title)
                .foregroundColor(.white)
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundColor(granted ? .green : .white.opacity(0.3))
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Actions

    private func handleContinue() {
        // Save keys when leaving step 2
        if step == 2 {
            let g = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !g.isEmpty { GigiConfig.setGroqAPIKey(g) }
            let gem = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gem.isEmpty {
                GigiKeychain.save(gem, forKey: GigiKeychain.Key.geminiAPIKey)
            }
        }
        // Save profile when leaving step 4
        if step == 4 {
            isSavingProfile = true
            Task {
                var p = UserProfileData()
                p.name            = profileName.trimmingCharacters(in: .whitespaces)
                p.email           = profileEmail.trimmingCharacters(in: .whitespaces)
                p.phone           = profilePhone.trimmingCharacters(in: .whitespaces)
                p.deliveryAddress = profileAddress.trimmingCharacters(in: .whitespaces)
                p.city            = profileCity.trimmingCharacters(in: .whitespaces)
                p.zip             = profileZip.trimmingCharacters(in: .whitespaces)
                await GigiUserProfile.shared.save(p)
                isSavingProfile = false
            }
        }
        if step == totalSteps - 1 {
            UserDefaults.standard.set(true, forKey: "gigi.onboarding.complete")
            withAnimation { isPresented = false }
        } else {
            withAnimation { step += 1 }
        }
    }

    private func testAndSaveHarness() async {
        isTestingHarness = true
        let url = harnessURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let sec = harnessSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        GigiKeychain.save(url, forKey: GigiKeychain.Key.harnessBaseURL)
        GigiKeychain.save(sec, forKey: GigiKeychain.Key.harnessSecret)
        _ = GigiHarnessClient.ensureDeviceId()
        switch await GigiHarnessClient.shared.health() {
        case .success(let h): harnessStatus = "ok:\(h.pid)"
        case .failure(let e): harnessStatus = "fail: \(e)"
        }
        await MainActor.run { GigiApnsSync.onConfigChanged() }
        isTestingHarness = false
    }

    private func pasteFromClipboard() {
        #if canImport(UIKit)
        if let s = UIPasteboard.general.string {
            apiKey = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
    }

    private func loadExistingKey() {
        let existing = GigiConfig.groqAPIKey
        if !existing.isEmpty, existing != "$(GROQ_API_KEY)" {
            apiKey = existing
        }
        if let g = GigiKeychain.load(forKey: GigiKeychain.Key.geminiAPIKey), !g.isEmpty {
            geminiKey = g
        }
        if let u = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL) { harnessURL = u }
        if let s = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret) { harnessSecret = s }
    }

    private func requestAllPermissions() async {
        isRequestingPermissions = true
        // Microphone
        if await AVCaptureDevice.requestAccess(for: .audio) { micGranted = true }
        // Speech
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
        }
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        // Contacts
        let cn = CNContactStore()
        if (try? await cn.requestAccess(for: .contacts)) == true { contactsGranted = true }
        // Calendar
        let ek = EKEventStore()
        _ = try? await ek.requestFullAccessToEvents()
        calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        // Notifications
        let nc = UNUserNotificationCenter.current()
        _ = try? await nc.requestAuthorization(options: [.alert, .sound, .badge])
        let settings = await nc.notificationSettings()
        notifGranted = settings.authorizationStatus == .authorized
        isRequestingPermissions = false
    }
}
