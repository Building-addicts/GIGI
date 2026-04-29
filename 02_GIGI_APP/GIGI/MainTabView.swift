import SwiftUI

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var auth = GigiAuthManager.shared
    @ObservedObject private var orchestrator = GigiSmartOrchestrator.shared
    @ObservedObject private var presence = PresenceSessionController.shared
    @ObservedObject private var liveActivity = GigiLiveActivityController.shared

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "gigi.onboarding.complete")
    @State private var showPresence = false
    @State private var selection: Int = 0
    @State private var showPairingSheet = false
    @State private var harnessConfigured = GigiHarnessClient.shared.pairingState.isConfigured

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selection) {
                ChatView()
                    .tag(0)
                    .tabItem {
                        Image(systemName: "waveform.badge.mic")
                        Text("GIGI")
                    }

                // Presence Mode tab
                PresenceModeTabView(showPresence: $showPresence)
                    .tabItem {
                        Image(systemName: presence.isActive ? "person.wave.2.fill" : "person.wave.2")
                        Text("Presence")
                    }

                DashboardView()
                    .tag(1)
                    .tabItem {
                        Image(systemName: "square.grid.2x2")
                        Text("Dashboard")
                    }

                SettingsView()
                    .tag(2)
                    .tabItem {
                        Image(systemName: "gearshape.fill")
                        Text("Settings")
                    }
            }
            .tint(.purple)
            .preferredColorScheme(.dark)
            .simultaneousGesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        let h = value.translation.width
                        let v = value.translation.height
                        guard abs(h) > abs(v) * 1.5 else { return }
                        if h < -50 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                selection = min(selection + 1, 2)
                            }
                        } else if h > 50 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                selection = max(selection - 1, 0)
                            }
                        }
                    }
            )

            if !harnessConfigured && !showOnboarding {
                pairingBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(50)
            }

            if let err = liveActivity.lastActivityError, !showOnboarding {
                liveActivityBanner(err)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(49)
            }

            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .transition(.opacity)
                    .zIndex(99)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showOnboarding)
        .animation(.easeInOut(duration: 0.3), value: harnessConfigured)
        .sheet(isPresented: $showPresence) {
            PresenceView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
        }
        .sheet(isPresented: $showPairingSheet) {
            GigiPairingSheet { _ in
                refreshHarnessConfiguredState()
            }
        }
        .sheet(item: $orchestrator.pendingPermissionPayload) { payload in
            PermissionConfirmationSheet(payload: payload) { result in
                orchestrator.resolvePermissionConfirmation(result)
            }
            .interactiveDismissDisabled()
        }
        .onAppear { refreshHarnessConfiguredState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshHarnessConfiguredState() }
        }
        .onChange(of: selection) { _, _ in
            refreshHarnessConfiguredState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gigiHarnessPairingDidChange)) { _ in
            refreshHarnessConfiguredState()
        }
    }


    private func refreshHarnessConfiguredState() {
        // Do not use `isReady` for this banner. `isReady` depends on the
        // in-memory diagnostics cache, which is intentionally lost when the
        // app is killed. The top banner only means "pair this phone with a
        // PC", so persisted Keychain config is the correct source of truth.
        harnessConfigured = GigiHarnessClient.shared.pairingState.isConfigured
    }

    private func liveActivityBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.orange.opacity(0.9))
        .cornerRadius(12)
        .padding(.horizontal, 14)
        .padding(.top, harnessConfigured ? 56 : 116)
    }

    private var pairingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect GIGI to your PC")
                    .font(.subheadline.weight(.semibold))
                Text("Tap to set up & pair")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.75))
            }
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 18))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(
            LinearGradient(colors: [Color.purple, Color.purple.opacity(0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(.horizontal, 14)
        .padding(.top, 56)
        .onTapGesture { showPairingSheet = true }
    }
}

// MARK: - Presence Tab Entry

private struct PresenceModeTabView: View {
    @Binding var showPresence: Bool
    @ObservedObject private var presence = PresenceSessionController.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: presence.isActive ? "person.wave.2.fill" : "person.wave.2")
                    .font(.system(size: 52))
                    .foregroundColor(presence.isActive ? .purple : .white.opacity(0.3))
                Text(presence.isActive ? "Presence: \(presenceStateLabel)" : "Presence Mode")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(presence.isActive ? "Live Activity mirrors this state" : "Start iOS-compliant wake-word Presence")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.4))
                Button {
                    if presence.isActive {
                        showPresence = true
                    } else {
                        presence.startSession()
                        showPresence = true
                    }
                } label: {
                    Text(presence.isActive ? "Open" : "Start")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 14)
                        .background(presence.isActive ? Color.purple : Color.purple.opacity(0.7))
                        .clipShape(Capsule())
                }
                Spacer()
            }
        }
    }

    private var presenceStateLabel: String {
        switch presence.state {
        case .inactive: return "Ready"
        case .sleeping: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .muted: return "Muted"
        case .error: return "Needs Attention"
        }
    }
}
