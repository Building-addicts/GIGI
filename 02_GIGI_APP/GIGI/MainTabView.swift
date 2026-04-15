import SwiftUI

struct MainTabView: View {
    @StateObject var auth = GigiAuthManager.shared

    var body: some View {
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
        }
        .tint(.purple)
        .preferredColorScheme(.dark)
    }
}
