import SwiftUI

struct MainTabView: View {
    @StateObject var auth = GigiAuthManager.shared
    @ObservedObject private var orchestrator = GigiSmartOrchestrator.shared
    @ObservedObject private var presence = PresenceSessionController.shared

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "gigi.onboarding.complete")
    @State private var showPresence = false

    var body: some View {
        ZStack {
            TabView {
                ChatView()
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
                    .tabItem {
                        Image(systemName: "square.grid.2x2")
                        Text("Dashboard")
                    }

                SettingsView()
                    .tabItem {
                        Image(systemName: "gearshape.fill")
                        Text("Settings")
                    }
            }
            .tint(.purple)
            .preferredColorScheme(.dark)

            // Onboarding overlay
            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .transition(.opacity)
                    .zIndex(99)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showOnboarding)
        .sheet(isPresented: $showPresence) {
            PresenceView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
        }
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
                Text(presence.isActive ? "Presence Active" : "Presence Mode")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(presence.isActive ? "GIGI is with you" : "Stay connected with GIGI")
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
}
