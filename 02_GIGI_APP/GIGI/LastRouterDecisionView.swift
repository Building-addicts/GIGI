import SwiftUI

// MARK: - LastRouterDecisionView (Settings → 🔧 Debug)
//
// Live-reloading viewer for UserDefaults("gigi.debug.lastRouterDecision")
// written by GigiFoundationSession.routeRequest after every Apple FM
// router decision. The previous inline DisclosureGroup body re-read the
// value only at render time, so users saw "(no decision yet)" forever
// even after issuing a query.

struct LastRouterDecisionView: View {
    @State private var json: String = ""
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
                Text("Last router decision (JSON)")
                Spacer()
                if !isEmpty {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
            }
        }
    }

    private var isEmpty: Bool {
        json.isEmpty || json.hasPrefix("(")
    }

    @ViewBuilder
    private var content: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(isEmpty ? "(no decision yet — issue a query first)" : json)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(6)
        }
        HStack(spacing: 12) {
            Button("Copy") {
                if !isEmpty { UIPasteboard.general.string = json }
            }
            .font(.caption)
            .disabled(isEmpty)
            Button("Reload") { reload() }
                .font(.caption)
                .foregroundColor(.accentColor)
            Button("Clear") {
                UserDefaults.standard.removeObject(forKey: "gigi.debug.lastRouterDecision")
                json = ""
            }
            .font(.caption)
            .foregroundColor(.orange)
            Spacer()
            Text("auto-reloads")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func reload() {
        json = UserDefaults.standard.string(forKey: "gigi.debug.lastRouterDecision") ?? ""
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
