import SwiftUI

struct MainTabView: View {
    @StateObject var auth = GigiAuthManager.shared
    @ObservedObject private var orchestrator = GigiSmartOrchestrator.shared

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "gigi.onboarding.complete")

    var body: some View {
        ZStack {
            TabView {
                ChatView()
                    .tabItem {
                        Image(systemName: "waveform.badge.mic")
                        Text("GIGI")
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
    }
}
