import SwiftUI

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var auth = GigiAuthManager.shared
    @ObservedObject private var orchestrator = GigiSmartOrchestrator.shared

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "gigi.onboarding.complete")
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

            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .transition(.opacity)
                    .zIndex(99)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showOnboarding)
        .animation(.easeInOut(duration: 0.3), value: harnessConfigured)
        .sheet(isPresented: $showPairingSheet) {
            GigiPairingSheet { _ in
                refreshHarnessConfiguredState()
            }
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
