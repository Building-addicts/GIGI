import SwiftUI

/// 2-second toast affordance that surfaces "GIGI used a preference" so the
/// demo audience sees that personalization is real (#79). Listens for
/// `.gigiPreferenceApplied` notifications and shows only the first hint
/// per turn to avoid spam.
struct MemoryHintView: View {
    @State private var visible = false
    @State private var line: String = ""
    @State private var lastTurnId: String? = nil

    var body: some View {
        Group {
            if visible {
                HStack(spacing: 6) {
                    Text("💭")
                    Text(line)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: visible)
        .onReceive(NotificationCenter.default.publisher(for: .gigiPreferenceApplied)) { note in
            guard let pref = note.userInfo?["pref"] as? String,
                  let value = note.userInfo?["value"] as? String else { return }
            let turnId = note.userInfo?["turnId"] as? String
            // Throttle: only the first hint per turn.
            if let turnId, turnId == lastTurnId, visible { return }
            lastTurnId = turnId
            line = "Memory used: \(pref) = \(value)"
            visible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                visible = false
            }
        }
    }
}

extension Notification.Name {
    static let gigiPreferenceApplied = Notification.Name("gigi.preferenceApplied")
}
