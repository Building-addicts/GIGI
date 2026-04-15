import SwiftUI
import GoogleSignIn

struct DashboardView: View {
    @ObservedObject var auth = GigiAuthManager.shared
    @State private var showingPrivacy = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {

                    // Header
                    Text("Dashboard")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.top, 60)

                    // ── AI PROVIDERS ──────────────────────────────
                    SectionHeader(title: "AI Providers")

                    // Google / Gemini
                    ProviderRow(
                        icon: "g.circle.fill",
                        iconColor: .blue,
                        title: "Google Gemini",
                        subtitle: auth.isSignedIn
                            ? "Connected as \(auth.userEmail)"
                            : "Connect to unlock AI responses",
                        isConnected: auth.isSignedIn,
                        action: {
                            if auth.isSignedIn {
                                auth.signOut()
                            } else {
                                auth.signIn()
                            }
                        },
                        actionLabel: auth.isSignedIn ? "Disconnect" : "Connect"
                    )

                    // Coming soon
                    ProviderRow(
                        icon: "brain.head.profile",
                        iconColor: .orange,
                        title: "OpenAI (ChatGPT)",
                        subtitle: "Coming soon",
                        isConnected: false,
                        action: {},
                        actionLabel: "Soon",
                        disabled: true
                    )

                    ProviderRow(
                        icon: "sparkles",
                        iconColor: .purple,
                        title: "Anthropic (Claude)",
                        subtitle: "Coming soon",
                        isConnected: false,
                        action: {},
                        actionLabel: "Soon",
                        disabled: true
                    )

                    // ── EXTENSIONS ────────────────────────────────
                    SectionHeader(title: "Extensions")

                    ExtensionRow(
                        icon: "house.fill",
                        iconColor: .orange,
                        title: "HomeKit",
                        subtitle: "Control your smart home",
                        available: false
                    )

                    ExtensionRow(
                        icon: "calendar",
                        iconColor: .red,
                        title: "Calendar",
                        subtitle: "Read and create events",
                        available: true
                    )

                    ExtensionRow(
                        icon: "envelope.fill",
                        iconColor: .blue,
                        title: "Mail",
                        subtitle: "Read your emails",
                        available: true
                    )

                    ExtensionRow(
                        icon: "music.note",
                        iconColor: .green,
                        title: "Spotify",
                        subtitle: "Control music playback",
                        available: false
                    )

                    // ── INFO ──────────────────────────────────────
                    SectionHeader(title: "Info")

                    InfoRow(title: "Version", value: "1.0.0")
                    InfoRow(title: "NLU Model", value: "GigiNLU — 99% accuracy")
                    InfoRow(title: "Intents", value: "33 commands")
                    InfoRow(title: "Cloud", value: auth.isSignedIn ? "Gemini 1.5 Flash" : "Offline only")

                    // Privacy
                    Button {
                        showingPrivacy = true
                    } label: {
                        HStack {
                            Text("Privacy Policy")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.4))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.2))
                        }
                        .padding(.vertical, 8)
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
            }
        }
        .sheet(isPresented: $showingPrivacy) {
            PrivacyView()
        }
    }
}

// MARK: - Components

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.4))
            .padding(.top, 8)
    }
}

struct ProviderRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let isConnected: Bool
    let action: () -> Void
    let actionLabel: String
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(disabled ? .white.opacity(0.2) : iconColor)
                .frame(width: 44, height: 44)
                .background(disabled ? Color.white.opacity(0.05) : iconColor.opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(disabled ? .white.opacity(0.3) : .white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: action) {
                Text(actionLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(disabled ? .white.opacity(0.2) : (isConnected ? .red.opacity(0.8) : .purple))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        disabled ? Color.white.opacity(0.05) :
                        (isConnected ? Color.red.opacity(0.1) : Color.purple.opacity(0.15))
                    )
                    .cornerRadius(8)
            }
            .disabled(disabled)
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(14)
    }
}

struct ExtensionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let available: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(iconColor)
                .frame(width: 44, height: 44)
                .background(iconColor.opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()

            Text(available ? "Active" : "Soon")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(available ? .green : .white.opacity(0.2))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(available ? Color.green.opacity(0.1) : Color.white.opacity(0.05))
                .cornerRadius(6)
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(14)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.vertical, 4)
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("GIGI does not collect, store, or share any personal data. Voice commands are processed locally on your device. If you connect a Google account, your queries are sent directly to Google Gemini API using your own credentials. We never see your data.")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.8))
                            .padding()
                    }
                }
            }
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.purple)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
