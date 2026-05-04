import SwiftUI

/// Top-edge banner shown when the harness is unreachable.
/// Bound to `GigiBrainDiagnostics.shared.harnessStatus` — appears on `.offline`,
/// auto-dismisses on recovery via SwiftUI's animated transition.
struct HarnessOfflineBanner: View {
    @ObservedObject var diagnostics: GigiBrainDiagnostics = .shared

    var body: some View {
        Group {
            if diagnostics.harnessStatus == .offline {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 14, weight: .semibold))
                    Text("GIGI offline — running on local intelligence")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.95))
                .foregroundColor(.white)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: diagnostics.harnessStatus)
    }
}
