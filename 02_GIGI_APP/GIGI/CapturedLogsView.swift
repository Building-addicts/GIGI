import SwiftUI

// MARK: - CapturedLogsView (Settings → 🔧 Debug)
//
// Shows the in-app ring buffer maintained by GigiDebugLogger
// (UserDefaults key "gigi_crash_logs"). Live-reloads while the disclosure
// is open so newly-emitted log lines appear without the user having to
// close/reopen or switch tab.
//
// Previously inlined in SettingsView.debugSection — extracted into its
// own view because the inline DisclosureGroup only re-read UserDefaults
// at render time and never auto-refreshed, leading the user to think
// "no captured logs yet" when in fact logs were piling up.

struct CapturedLogsView: View {
    @State private var logs: [String] = []
    @State private var isExpanded: Bool = false
    @State private var timer: Timer?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .onAppear { reloadAndStart() }
                .onDisappear { stop() }
                .onChange(of: isExpanded) { _, open in
                    if open { reloadAndStart() } else { stop() }
                }
        } label: {
            HStack {
                Text("📋 Captured GIGI logs (last 200)")
                Spacer()
                if !logs.isEmpty {
                    Text("\(logs.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if logs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("(no captured logs yet — pronounce a query to populate)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button("Force reload") { reload() }
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        } else {
            ScrollView {
                Text(logs.suffix(200).joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(maxHeight: 280)
            .background(Color(.systemGray6))
            .cornerRadius(6)
            HStack(spacing: 12) {
                Button("Copy all") {
                    UIPasteboard.general.string = logs.joined(separator: "\n")
                }
                .font(.caption)
                Button("Reload") { reload() }
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Button("Clear") {
                    UserDefaults.standard.removeObject(forKey: "gigi_crash_logs")
                    logs = []
                }
                .font(.caption)
                .foregroundColor(.orange)
                Spacer()
                Text("auto-reloads · \(logs.count) entries")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func reload() {
        logs = UserDefaults.standard.stringArray(forKey: "gigi_crash_logs") ?? []
    }

    private func reloadAndStart() {
        reload()
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            DispatchQueue.main.async { reload() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
