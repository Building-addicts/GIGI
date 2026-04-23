import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import AVFoundation
import Speech
import Contacts
import EventKit
import UserNotifications

// MARK: - OnboardingView (T-23)
//
// Multi-step onboarding: welcome → permissions → API key → wake word → done.
// Only shown once (UserDefaults flag). Permissions are requested in-flow.

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var step = 0
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var micGranted = false
    @State private var contactsGranted = false
    @State private var calendarGranted = false
    @State private var notifGranted = false
    @State private var isRequestingPermissions = false

    // Profile step
    @State private var profileName = ""
    @State private var profileEmail = ""
    @State private var profilePhone = ""
    @State private var profileAddress = ""
    @State private var profileCity = ""
    @State private var profileZip = ""
    @State private var isSavingProfile = false

    private let totalSteps = 6

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
                    case 3: profileStep
                    case 4: wakeWordStep
                    case 5: doneStep
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

            Text("Your autonomous AI on iPhone.\nZero taps. Zero interruptions.")
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
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 56))
                .foregroundStyle(.purple)

            Text("Connect your AI")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("GIGI uses Groq as its brain — ultra fast, **free**, no credit card needed.\nGet your key at console.groq.com → API Keys.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 28)

            VStack(spacing: 12) {
                HStack {
                    keyInputField
                    Button(action: { showKey.toggle() }) {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.07))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.4), lineWidth: 1))

                Button(action: pasteFromClipboard) {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                        .foregroundColor(.purple)
                }
            }
            .padding(.horizontal, 24)

            let keyLooksValid = !apiKey.isEmpty && apiKey.hasPrefix("gsk_")
            HStack(spacing: 8) {
                Image(systemName: keyLooksValid ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundColor(keyLooksValid ? .green : .white.opacity(0.3))
                Text(keyLooksValid ? "Key looks valid" : "Paste your key above")
                    .foregroundColor(keyLooksValid ? .green : .white.opacity(0.4))
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var keyInputField: some View {
        if showKey {
            TextField("gsk_...", text: $apiKey)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
        } else {
            SecureField("Paste your API key here", text: $apiKey)
                .font(.system(.body, design: .monospaced))
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

    private var wakeWordStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "ear.fill")
                .font(.system(size: 56))
                .foregroundStyle(.purple)

            Text("Wake Word")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("Say **\"Jarvis\"** to wake GIGI without touching your phone.\n\nFor a custom \"Hey GIGI\" wake word, add `HeyGIGI.ppn` from Picovoice Console + your `PICOVOICE_ACCESS_KEY` in Config.xcconfig.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 28)

            Toggle("Enable wake word", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: GigiWakeWordEngine.userDefaultsEnabledKey) },
                set: { GigiWakeWordEngine.shared.setUserEnabled($0) }
            ))
            .tint(.purple)
            .padding(.horizontal, 40)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            Text("You're all set.")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("Say **\"Jarvis\"** or tap the mic button to command GIGI.\n\nTry: \"Call Marco\", \"Buonanotte\", \"What's the weather?\"")
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
        // Save Groq key when leaving step 2
        if step == 2, !apiKey.isEmpty {
            GigiConfig.setGroqAPIKey(apiKey)
        }
        // Save profile when leaving step 3 (async, non-blocking)
        if step == 3 {
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
        if #available(iOS 17, *) {
            _ = try? await ek.requestFullAccessToEvents()
        } else {
            _ = await withCheckedContinuation { cont in
                ek.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        // Notifications
        let nc = UNUserNotificationCenter.current()
        _ = try? await nc.requestAuthorization(options: [.alert, .sound, .badge])
        let settings = await nc.notificationSettings()
        notifGranted = settings.authorizationStatus == .authorized
        isRequestingPermissions = false
    }
}
