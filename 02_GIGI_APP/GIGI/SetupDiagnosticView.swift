import SwiftUI

// MARK: - SetupDiagnosticView
//
// The post-bootstrap-pair screen. Runs a 5-second poll against
// /api/setup/diagnostics and renders one row per check, color-coded by
// severity, with copyable action hints. The "Finalize pair" button
// activates once every critical check is green.
//
// Polling is automatic while the view is visible. Tapping a row reveals
// its hint + action; long-pressing the action copies it to the
// clipboard so the user can paste it into a terminal on the PC.
//
// Phase 6.5 — depends on P6.3 (backend endpoint) and P6.4 (client + struct).
//
// Three explicit phase states, one of which is the "live" mode:
//   .loading    initial fetch in flight, no report yet
//   .running    we have a report, polling continues every 5s
//   .error(s)   the most recent fetch failed (network / 401)
//
// On dismiss the view publishes its last successful report into
// `GigiHarnessClient.shared.cacheDiagnostics(_:)` so the rest of the app
// (banner, chat gate) can read `isReady` without re-fetching.

struct SetupDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case loading
        case running(GigiHarnessClient.DiagnosticsReport)
        case error(String)
    }

    @State private var phase: Phase = .loading
    @State private var pollTask: Task<Void, Never>?
    @State private var expandedCheckId: String?
    @State private var copiedToast: String?
    @State private var isFinalizing = false

    /// Called when the user taps "Finalize pair". The hosting sheet
    /// (GigiPairingSheet) listens for this to flip its own state.
    let onFinalize: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
                if let toast = copiedToast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.footnote.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Color.black.opacity(0.85)))
                            .padding(.bottom, 80)
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Phase rendering

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 16) {
                ProgressView().tint(.purple).scaleEffect(1.3)
                Text("Checking your PC…")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
        case .running(let report):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryHeader(report: report)
                    checkList(report: report)
                    finalizeButton(report: report)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
        case .error(let msg):
            VStack(spacing: 18) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundColor(.yellow)
                Text("Couldn't reach the harness")
                    .font(.headline)
                    .foregroundColor(.white)
                Text(msg)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") {
                    Task { await fetchOnce(force: true) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Capsule().fill(Color.purple))
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private func summaryHeader(report: GigiHarnessClient.DiagnosticsReport) -> some View {
        let s = report.summary
        let allOk = s.allCriticalOk
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: allOk ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(allOk ? .green : .yellow)
                Text(allOk ? "All checks pass" : "Some checks need attention")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
            HStack(spacing: 14) {
                badge(label: "critical", ok: s.counts.critical.ok, total: s.counts.critical.total, color: .pink)
                badge(label: "warning",  ok: s.counts.warning.ok,  total: s.counts.warning.total,  color: .yellow)
                badge(label: "info",     ok: s.counts.info.ok,     total: s.counts.info.total,     color: .blue)
            }
            Text("Polling every 5 seconds. Fix issues on your PC and they'll turn green here automatically.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
                .padding(.top, 4)
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    private func badge(label: String, ok: Int, total: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(ok)/\(total)")
                .font(.headline.monospacedDigit())
                .foregroundColor(.white)
            Text(label)
                .font(.caption2)
                .foregroundColor(color.opacity(0.85))
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.12))
        .cornerRadius(8)
    }

    // MARK: - Check rows

    private func checkList(report: GigiHarnessClient.DiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(report.checks) { check in
                checkRow(check)
            }
        }
    }

    @ViewBuilder
    private func checkRow(_ check: GigiHarnessClient.DiagnosticsCheck) -> some View {
        let icon = check.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        let iconColor = check.ok ? Color.green : severityColor(check.severity)
        let isExpanded = expandedCheckId == check.id
        let canExpand = !check.ok && (check.hint != nil || check.action != nil)

        VStack(alignment: .leading, spacing: 8) {
            Button {
                if canExpand {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        expandedCheckId = isExpanded ? nil : check.id
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(iconColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                        Text(check.severity.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(severityColor(check.severity).opacity(0.7))
                    }
                    Spacer()
                    if canExpand {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let hint = check.hint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let action = check.action {
                        Button {
                            UIPasteboard.general.string = action
                            withAnimation { copiedToast = "Action copied" }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_400_000_000)
                                await MainActor.run { withAnimation { copiedToast = nil } }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                Text(action)
                                    .font(.system(.footnote, design: .monospaced))
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .foregroundColor(.purple)
                            .padding(10)
                            .background(Color.purple.opacity(0.08))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(12)
        .background(Color.white.opacity(check.ok ? 0.03 : 0.06))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(check.ok ? Color.green.opacity(0.2) : iconColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func severityColor(_ s: String) -> Color {
        switch s {
        case "critical": return .pink
        case "warning":  return .yellow
        case "info":     return .blue
        default:         return .gray
        }
    }

    // MARK: - Finalize

    @ViewBuilder
    private func finalizeButton(report: GigiHarnessClient.DiagnosticsReport) -> some View {
        let canFinalize = report.summary.allCriticalOk

        Button {
            isFinalizing = true
            GigiHarnessClient.shared.cacheDiagnostics(report)
            onFinalize()
            // Tiny beat for visual feedback before parent dismisses us.
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await MainActor.run { dismiss() }
            }
        } label: {
            HStack {
                Spacer()
                if isFinalizing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "checkmark.seal.fill")
                    Text("Finalize pair").font(.body.weight(.semibold))
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .background(canFinalize ? Color.purple : Color.purple.opacity(0.25))
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .disabled(!canFinalize || isFinalizing)
        .padding(.top, 4)

        if !canFinalize {
            Text("Fix the critical checks above to enable.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTask = Task {
            // Initial fetch fast (no delay)
            await fetchOnce(force: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await fetchOnce(force: false)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func fetchOnce(force: Bool) async {
        let result = await GigiHarnessClient.shared.diagnostics(forceRefresh: force)
        await MainActor.run {
            switch result {
            case .success(let report):
                phase = .running(report)
                GigiHarnessClient.shared.cacheDiagnostics(report)
            case .failure(let err):
                phase = .error(String(describing: err))
            }
        }
    }
}
